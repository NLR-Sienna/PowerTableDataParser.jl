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
Units label for values stored per unit of the owning component's own base
quantity for the named attribute.

The legacy `scaling_factor_multiplier` concept is replaced by this: a pointer
that declared a multiplier stores its values normalized, and the label tells the
reader to scale by the owner's corresponding base quantity (e.g. its max active
power for a `max_active_power` series) instead of naming an accessor.
"""
const DEVICE_BASE_UNITS = "DEVICE_BASE"

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

_series_units(entry::TimeSeriesPointer) =
    isnothing(entry.scaling_factor_multiplier) ? nothing : DEVICE_BASE_UNITS

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
            units = _series_units(entry),
        )
        for (target_type, target_id) in series_owners(sys, entry, owner_type, owner_id)
            push!(sys.time_series, StagedTimeSeries(target_type, target_id, series))
        end
    end
    return
end

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
