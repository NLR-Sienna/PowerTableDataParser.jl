# Time series come from the pointer file, are read straight off the source CSVs,
# and are staged as `StagedTimeSeries` rows — one per owner. `write_time_series`
# hands them to InfrastructureSystems' time series store, whose catalog is the
# association table; the document carries no association rows of its own.
#
# One row per owner. RTS points every series at two resolutions, and resolution
# is part of a series' identity in the store, so the pairs are not deduplicated
# on (owner, name). A series stated for a zone gains one row per load underneath
# it, all against the same series — see `series_owners`.

"""
Component types a pointer file's `category` may name.

The owner search is narrowed by category because a bare name is not unique: RTS
aliases the zone column to the area column, so "1", "2" and "3" each name both an
`Area` and a `LoadZone`.
"""
const CATEGORY_TO_TYPES = Dict(
    "Generator" => [
        "ThermalStandard",
        "RenewableDispatch",
        "RenewableNonDispatch",
        "HydroTurbine",
        "HydroDispatch",
        "SynchronousCondenser",
        "EnergyReservoirStorage",
    ],
    # The deleted PSCB parser dispatched this category on the abstract PSY type
    # `ElectricLoad` (`get_components(ElectricLoad, sys)`), so any subtype sharing a
    # bus — including `FixedAdmittance`, confirmed by the oracle comparison — was a
    # candidate, not just PowerLoad/StandardLoad.
    "ElectricLoad" => ["PowerLoad", "StandardLoad", "FixedAdmittance"],
    "LoadZone" => ["LoadZone"],
    "Area" => ["Area"],
    "Reserve" => ["OnlineReserve"],
    "Storage" => ["EnergyReservoirStorage"],
    "Component" => ["HydroReservoir"],
)

function category_to_type_names(category::AbstractString)
    key = String(category)
    if !haskey(CATEGORY_TO_TYPES, key)
        throw(IS.DataFormatError("unmapped time series category=$category"))
    end
    return CATEGORY_TO_TYPES[key]
end

"""
The unit system values are stored in when a pointer declared a multiplier.

The legacy `scaling_factor_multiplier` concept is replaced by this: such a pointer stores its
values normalized against the owner's corresponding base quantity (e.g. its max active power
for a `max_active_power` series), which is exactly what `DeviceBaseUnit` declares — so the
reader scales by that base rather than resolving an accessor name.

This was carried in the series' `units` label until InfraStore grew a real `unit_system`
column. `units` is for a units label ("MW"); a per-unit basis is not one.
"""
const DEVICE_BASE_UNIT_SYSTEM = IS.DU

"""
The physical quantity a normalized pointer's values scale to, for the series'
`quantity_kind`.

The multiplier used to name the accessor a reader multiplied the profile by. That name is
not what a consumer needs — the quantity is. Storing the quantity says the same thing
without making the reader resolve a function out of a string, and it stays meaningful for a
consumer that is not PowerSystems.
"""
const MULTIPLIER_QUANTITY_KINDS = Dict(
    "get_max_active_power" => "active_power",
    "get_max_reactive_power" => "reactive_power",
    "get_requirement" => "active_power",
    "get_rating" => "apparent_power",
)

"""
A reservoir level, in whichever of the three ways `level_data_type` says the reservoir
accounts one.
"""
const RESERVOIR_LEVEL_QUANTITIES = Dict(
    "ENERGY" => "energy",
    "USABLE_VOLUME" => "volume",
    "TOTAL_VOLUME" => "volume",
    "HEAD" => "head",
)

"""
A flow into or out of a reservoir. Follows the same choice as the level, except that a
head-accounted reservoir still takes its inflow as a volume — a head is a state, not
something that flows.
"""
const RESERVOIR_FLOW_QUANTITIES = Dict(
    "ENERGY" => "power",
    "USABLE_VOLUME" => "volume_flow",
    "TOTAL_VOLUME" => "volume_flow",
    "HEAD" => "volume_flow",
)

"""
Multipliers whose quantity depends on how the owning reservoir accounts its levels, rather
than being fixed by the multiplier alone.
"""
const RESERVOIR_QUANTITY_KINDS = Dict(
    "get_storage_capacity" => RESERVOIR_LEVEL_QUANTITIES,
    # `get_storage_target` is what the 5-bus pointer files write; PowerSystemCaseBuilder
    # rewrites it to `get_level_targets`, the accessor a `HydroReservoir` actually has, so
    # both spellings reach here depending on whether that pass ran.
    "get_storage_target" => RESERVOIR_LEVEL_QUANTITIES,
    "get_level_targets" => RESERVOIR_LEVEL_QUANTITIES,
    "get_inflow" => RESERVOIR_FLOW_QUANTITIES,
    "get_outflow" => RESERVOIR_FLOW_QUANTITIES,
)

"""
One entry of a time series pointer file.

`IS.read_time_series_file_metadata` cannot be used here: it resolves the entry's
`module` field through the loaded-module table, and every RTS entry names
`PowerSystems`, which this package deliberately does not depend on. The type it
names, `SingleTimeSeries`, is an InfrastructureSystems type regardless, so the
field is read and checked rather than resolved.
"""
struct TimeSeriesPointer
    category::String
    component_name::String
    name::String
    normalization_factor::Union{Float64, String}
    data_file::String
    resolution::Dates.Period
    scaling_factor_multiplier::Union{Nothing, String}
end

function _pointer(item::Dict, directory::AbstractString)
    series_type = get(item, "type", "SingleTimeSeries")
    if series_type != "SingleTimeSeries"
        throw(
            IS.DataFormatError(
                "only SingleTimeSeries pointers are supported, got $series_type for " *
                "$(item["component_name"])",
            ),
        )
    end
    normalization_factor = item["normalization_factor"]
    if !isa(normalization_factor, AbstractString)
        normalization_factor = Float64(normalization_factor)
    end
    multiplier = get(item, "scaling_factor_multiplier", nothing)
    if !isnothing(multiplier)
        multiplier = String(multiplier)
    end
    return TimeSeriesPointer(
        item["category"],
        item["component_name"],
        item["name"],
        normalization_factor,
        abspath(joinpath(directory, item["data_file"])),
        Dates.Millisecond(Dates.Second(item["resolution"])),
        multiplier,
    )
end

"""Read a pointer file, resolving each data file against the pointer's own directory."""
function read_time_series_pointers(metadata_file::AbstractString)
    if !endswith(metadata_file, ".json")
        throw(
            IS.DataFormatError(
                "time series pointers must be a .json file, got $metadata_file",
            ),
        )
    end
    directory = dirname(metadata_file)
    items = open(metadata_file) do io
        return JSON.parse(io; dicttype = Dict{String, Any})
    end
    return [_pointer(item, directory) for item in items]
end

"""
Bus property that places a bus inside each aggregation topology.

A load series stated for an aggregation belongs to the loads underneath it, so
membership is resolved through the buses.
"""
const AGGREGATION_BUS_PROPERTIES = Dict("LoadZone" => "load_zone", "Area" => "area")

"""Multipliers that make a series belong to the loads rather than the aggregation."""
const FANNED_OUT_MULTIPLIERS = ("get_max_active_power", "get_max_reactive_power")

"""Component types that carry a load series.

Mirrors the deleted PSCB parser's abstract-type dispatch (`get_components(ElectricLoad,
sys)`): every `ElectricLoad` subtype sharing a bus with the aggregation is a candidate,
including `FixedAdmittance` — confirmed materially real by the oracle comparison, which
found RTS-GMLC-0.2.3's 3 shunt buses (Alber/Bajer/Camus, each also carrying a `PowerLoad`)
fanned their zone's load series out to the shunt too under the old parser."""
const LOAD_TYPES = ("PowerLoad", "StandardLoad", "FixedAdmittance")

"""
Loads sitting under an aggregation topology.

Mirrors what PowerSystems does when it reads a zone's load series: it walks the
buses of the aggregation and collects every `ElectricLoad` on them.
"""
function _loads_under(sys::OpenAPISystem, owner_type::AbstractString, owner_id::Int)
    property = Symbol(AGGREGATION_BUS_PROPERTIES[owner_type])
    bus_ids = Set(
        get_value(bus, :id) for
        bus in get_components(sys, "ACBus") if get_value(bus, property) == owner_id
    )
    owners = Tuple{String, Int}[]
    for type_name in LOAD_TYPES
        for load in get_components(sys, type_name)
            if get_value(load, :bus) in bus_ids
                push!(owners, (type_name, get_value(load, :id)))
            end
        end
    end
    return owners
end

"""
Every owner a pointer entry produces.

Usually the entry names its owner directly. A load series stated for a zone or an
area is different: the normalized values describe the loads underneath, so each of
them gets a row against the same series, and the aggregation keeps a row of its
own. With the values stored per unit (`DEVICE_BASE`), no per-owner scaling
metadata is needed: every owner scales by its own base quantity.
"""
function series_owners(
    sys::OpenAPISystem,
    entry::TimeSeriesPointer,
    owner_type::AbstractString,
    owner_id::Int,
)
    multiplier = entry.scaling_factor_multiplier
    if !haskey(AGGREGATION_BUS_PROPERTIES, owner_type) ||
       isnothing(multiplier) ||
       !(multiplier in FANNED_OUT_MULTIPLIERS)
        return [(owner_type, owner_id)]
    end

    owners = _loads_under(sys, owner_type, owner_id)
    push!(owners, (owner_type, owner_id))
    return owners
end

"""
Apply the pointer's normalization: `"max"` divides by the series' own peak, a
number divides by itself. Matches the semantics the removed
InfrastructureSystems file ingestion applied.
"""
function _normalized(values::Vector{Float64}, factor::Float64)
    if factor == 0.0
        throw(IS.DataFormatError("normalization_factor cannot be zero"))
    end
    return factor == 1.0 ? values : values ./ factor
end

function _normalized(values::Vector{Float64}, factor::AbstractString)
    if lowercase(factor) != "max"
        throw(IS.DataFormatError("unsupported normalization_factor=$factor"))
    end
    return values ./ maximum(values)
end

"""The basis a pointer's values are stored in. `nothing` when it declared no multiplier:
the values are then as the source file gave them, and no basis was declared — which is
deliberately not the same as declaring natural units."""
_series_unit_system(entry::TimeSeriesPointer) =
    isnothing(entry.scaling_factor_multiplier) ? nothing : DEVICE_BASE_UNIT_SYSTEM

"""
The reservoir accounting convention a reservoir-normalized entry is stated against.

The owner is not always the reservoir. A pointer files the entry under a `category`, and the
two RTS pointer files in circulation disagree: one files reservoir series under `Component`,
so they land on the `HydroReservoir`, and the other under `Generator`, so they land on the
`HydroTurbine` the reservoir feeds. The convention is the reservoir's either way, so it is
read off the owner when the owner is one and off the document's reservoirs when it is not.

Requires the document's reservoirs to agree in that second case: with the owner not naming
one, a mixed document gives no way to tell which convention applies, and guessing would
mislabel the quantity rather than fail.
"""
function _reservoir_level_data_type(
    sys::OpenAPISystem,
    owner_type::AbstractString,
    owner_id::Int,
)
    reservoirs = get_components(sys, "HydroReservoir")
    if owner_type == "HydroReservoir"
        for reservoir in reservoirs
            get_value(reservoir, :id) == owner_id &&
                return get_value(reservoir, :level_data_type)
        end
        throw(IS.DataFormatError("no HydroReservoir carries id=$owner_id"))
    end
    level_types = unique(get_value(r, :level_data_type) for r in reservoirs)
    length(level_types) == 1 || throw(
        IS.DataFormatError(
            "a reservoir-normalized series is owned by a $owner_type rather than the " *
            "reservoir, and the document's reservoirs state $(isempty(level_types) ?
            "no level_data_type" : "several: $(join(sort(level_types), ", "))") — so the " *
            "quantity its values scale to cannot be determined",
        ),
    )
    return only(level_types)
end

"""
The physical quantity a multiplier's normalized values scale to; `nothing` for no multiplier,
matching [`_series_unit_system`](@ref) — an unnormalized series states no basis, so naming
the quantity its values would scale to would be a claim about nothing.

`resolve_level_data_type` is called only for the reservoir multipliers, whose quantity
depends on how the reservoir accounts its levels; the two callers reach that convention
differently (a staged document vs. a live `System`), and neither should pay for it on the
multipliers that do not need it.

Errors on a multiplier with no mapping rather than silently leaving the quantity unstated:
the values are per unit either way, and a consumer that cannot tell what of is stuck.
"""
function quantity_kind_for_multiplier(
    multiplier::Union{Nothing, AbstractString},
    resolve_level_data_type,
)
    isnothing(multiplier) && return nothing
    haskey(MULTIPLIER_QUANTITY_KINDS, multiplier) &&
        return MULTIPLIER_QUANTITY_KINDS[multiplier]
    if haskey(RESERVOIR_QUANTITY_KINDS, multiplier)
        by_level_type = RESERVOIR_QUANTITY_KINDS[multiplier]
        level_type = resolve_level_data_type()
        haskey(by_level_type, level_type) || throw(
            IS.DataFormatError(
                "$multiplier on a reservoir with level_data_type=$level_type, which names " *
                "no quantity; expected one of $(join(sort(collect(keys(by_level_type))), ", "))",
            ),
        )
        return by_level_type[level_type]
    end
    throw(
        IS.DataFormatError(
            "unmapped scaling_factor_multiplier=$multiplier; it names no physical quantity " *
            "for the normalized values to scale to",
        ),
    )
end

"""[`quantity_kind_for_multiplier`](@ref) for a pointer entry staged into a document."""
_series_quantity_kind(
    sys::OpenAPISystem,
    entry::TimeSeriesPointer,
    owner_type::AbstractString,
    owner_id::Int,
) = quantity_kind_for_multiplier(
    entry.scaling_factor_multiplier,
    () -> _reservoir_level_data_type(sys, owner_type, owner_id),
)

"""
Read every series the pointer file names and stage one row per owner.

The source CSV holds every component's column, so the column for this entry's
component is selected explicitly; a file is read once and shared by its entries.
"""
function add_time_series!(sys::OpenAPISystem, metadata_file::AbstractString)
    reg = get_registry(sys)
    csv_cache = Dict{String, DataFrames.DataFrame}()
    for entry in read_time_series_pointers(metadata_file)
        owner_type, owner_id = find_by_name(
            reg,
            category_to_type_names(entry.category),
            entry.component_name,
        )
        df = get!(
            () -> CSV.read(entry.data_file, DataFrames.DataFrame),
            csv_cache,
            entry.data_file,
        )
        parsed = read_pointer_csv_values(df, entry.component_name, entry.resolution)
        if isnothing(parsed)
            throw(
                IS.DataFormatError(
                    "$(entry.data_file) has no column for $(entry.component_name) " *
                    "and is not period-pivoted",
                ),
            )
        end
        values, initial_timestamp = parsed
        series = IS.SingleTimeSeries(
            entry.name,
            initial_timestamp,
            entry.resolution,
            _normalized(values, entry.normalization_factor);
            unit_system = _series_unit_system(entry),
            quantity_kind = _series_quantity_kind(sys, entry, owner_type, owner_id),
        )
        for (target_type, target_id) in series_owners(sys, entry, owner_type, owner_id)
            push!(sys.time_series, StagedTimeSeries(target_type, target_id, series))
        end
    end
    return
end

"""
Keep only the staged series whose resolution is `resolution`; `nothing` keeps all of them.

Filters the staging rather than the document's association rows. The rows are rebuilt from
the staging at serialize time, so a filter applied to them would not survive `to_json` — and
would not matter anyway: the sidecar's catalog is what a consumer reads the series back
through, and a series left staged lands in the store whether or not a row names it. Dropping
it here is what keeps the store, the rows and the request agreeing.

Errors when nothing matches, rather than yielding a bundle with silently no time series.
"""
function keep_time_series_resolution!(sys::OpenAPISystem, resolution::Dates.Period)
    matches(staged) = IS.get_resolution(staged.series) == resolution
    if !any(matches, sys.time_series)
        throw(
            IS.DataFormatError(
                "no time series at resolution $resolution; the system carries " *
                "$(unique(IS.get_resolution(s.series) for s in sys.time_series))",
            ),
        )
    end
    filter!(matches, sys.time_series)
    return
end

keep_time_series_resolution!(::OpenAPISystem, ::Nothing) = nothing

"""
Write the staged series to the store's sidecar pair: `path` (the arrays) and
`path * ".sqlite"` (the catalog, which is the association table).

Everything goes through InfrastructureSystems' store wrappers — the InfraStore
backend is an implementation detail encapsulated there. The whole batch commits
as one transaction, and the store dedups arrays by content hash — a fanned-out
series lands once no matter how many owners reference it, and identical arrays
from different entries collapse too.
"""
function write_time_series(sys::OpenAPISystem, path::AbstractString)
    category = IS.get_owner_category(IS.InfrastructureSystemsComponent)
    store = IS.Store(; in_memory = true)
    try
        batch = IS.make_add_batch()
        for staged in sys.time_series
            IS.serialize_single!(
                batch,
                staged.owner_id,
                staged.owner_type,
                category,
                IS.get_name(staged.series),
                staged.series,
            )
        end
        IS.commit_batch!(store, batch)
        IS.serialize(store, String(path))
    finally
        IS.close!(store)
    end
    return
end

# ── document rows ──────────────────────────────────────────────────────────────

"""ISO 8601 duration, the spelling `TimeSeriesAssociation.resolution` takes."""
_iso8601_duration(period::Dates.Period) =
    string("PT", Dates.value(Dates.Second(period)), "S")

"""The document's spelling for a series' declared basis. `nothing` stays `nothing`:
unspecified is deliberately not `NATURAL_UNITS`."""
_document_unit_system(::Nothing) = nothing
_document_unit_system(::IS.NaturalUnit) = "NATURAL_UNITS"
_document_unit_system(::IS.DeviceBaseUnit) = "DEVICE_BASE"
_document_unit_system(::IS.SystemBaseUnit) = throw(
    IS.DataFormatError(
        "a staged series declares the system-base unit system, which the document cannot " *
        "express — the schemas offer NATURAL_UNITS and DEVICE_BASE only",
    ),
)

"""
One `TimeSeriesAssociation` row per staged series.

The sidecar holds the values; these rows let a consumer see what a document's bundle
contains — and in what units, on what basis — without opening the store. Keyed the way the
store keys its own catalog, so the two describe the same series.

Every staged series is a `SingleTimeSeries` against a component, so `time_series_type` and
`owner_category` are fixed and `features` is empty: this parser emits no forecasts and no
feature-discriminated series.
"""
function time_series_rows(sys::OpenAPISystem)
    doc = get_document(sys)
    rows = PC.TimeSeriesAssociation[]
    for staged in sys.time_series
        series = staged.series
        push!(
            rows,
            PC.TimeSeriesAssociation(;
                id = PC.next_id!(doc),
                time_series_type = "SingleTimeSeries",
                initial_timestamp = PC.ZonedDateTime(
                    IS.get_initial_timestamp(series), PC.TimeZone("UTC"),
                ),
                resolution = _iso8601_duration(IS.get_resolution(series)),
                length = length(series),
                name = IS.get_name(series),
                owner_id = staged.owner_id,
                owner_type = staged.owner_type,
                owner_category = "Component",
                features = Dict{String, PC.FeatureValue}[],
                units = IS.get_units(series),
                quantity_kind = IS.get_quantity_kind(series),
                unit_system = _document_unit_system(IS.get_unit_system(series)),
            ),
        )
    end
    return rows
end
