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
    # Includes FixedAdmittance: any ElectricLoad subtype sharing a bus is a candidate,
    # not just PowerLoad/StandardLoad.
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

Such a pointer stores its values normalized against the owner's corresponding base quantity
(e.g. its max active power for a `max_active_power` series), which is exactly what
`ComponentBaseUnit` declares.

`units` is for a units label ("MW"); a per-unit basis is not one.
"""
const COMPONENT_BASE_UNIT_SYSTEM = IS.CU

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
    "ENERGY" => "active_power",
    "USABLE_VOLUME" => "volume_flow_rate",
    "TOTAL_VOLUME" => "volume_flow_rate",
    "HEAD" => "volume_flow_rate",
)

"""
Multipliers whose quantity depends on how the owning reservoir accounts its levels, rather
than being fixed by the multiplier alone.
"""
const RESERVOIR_QUANTITY_KINDS = Dict(
    "get_storage_capacity" => RESERVOIR_LEVEL_QUANTITIES,
    # `get_storage_target` is what the 5-bus pointer files write; `get_level_targets` is the
    # accessor a `HydroReservoir` actually has. Both spellings are in circulation.
    "get_storage_target" => RESERVOIR_LEVEL_QUANTITIES,
    "get_level_targets" => RESERVOIR_LEVEL_QUANTITIES,
    "get_inflow" => RESERVOIR_FLOW_QUANTITIES,
    "get_outflow" => RESERVOIR_FLOW_QUANTITIES,
)

"""
One entry of a time series pointer file.

The `type` field is read and checked directly rather than resolved through IS's
module-loading path: every RTS entry names `PowerSystems`, which this package does not
depend on.
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

"""A pointer's `normalization_factor`, as the `"max"` string or a `Float64`."""
_normalization_factor(x::AbstractString) = x
_normalization_factor(x) = Float64(x)

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
    normalization_factor = _normalization_factor(item["normalization_factor"])
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

Includes `FixedAdmittance`: any `ElectricLoad` subtype sharing a bus with the aggregation is
a candidate, not just `PowerLoad`/`StandardLoad`."""
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

"""Generator types that draw on a reservoir."""
const TURBINE_TYPES = ("HydroTurbine", "HydroPumpTurbine")

"""The id of the reservoir that feeds a turbine: the one naming it downstream."""
function _head_reservoir_id(sys::OpenAPISystem, owner_type::AbstractString, owner_id::Int)
    for reservoir in get_components(sys, "HydroReservoir")
        owner_id in get_value(reservoir, :downstream_turbines) &&
            return get_value(reservoir, :id)
    end
    throw(IS.DataFormatError("no HydroReservoir feeds $owner_type id=$owner_id"))
end

"""
Every owner a pointer entry produces.

Usually the entry names its owner directly. A series normalized by a reservoir field but
filed under a turbine belongs to the reservoir feeding it, which is where PowerSystems keeps
that field. A load series stated for a zone or an
area is different: the normalized values describe the loads underneath, so each of
them gets a row against the same series, and the aggregation keeps a row of its
own. With the values stored per unit (`COMPONENT_BASE`), no per-owner scaling
metadata is needed: every owner scales by its own base quantity.
"""
function series_owners(
    sys::OpenAPISystem,
    entry::TimeSeriesPointer,
    owner_type::AbstractString,
    owner_id::Int,
)
    multiplier = entry.scaling_factor_multiplier
    if haskey(RESERVOIR_QUANTITY_KINDS, multiplier) && owner_type in TURBINE_TYPES
        return [("HydroReservoir", _head_reservoir_id(sys, owner_type, owner_id))]
    end
    if !haskey(AGGREGATION_BUS_PROPERTIES, owner_type) ||
       isnothing(multiplier) ||
       !(multiplier in FANNED_OUT_MULTIPLIERS)
        return [(owner_type, owner_id)]
    end

    owners = _loads_under(sys, owner_type, owner_id)
    push!(owners, (owner_type, owner_id))
    return owners
end

"""Apply the pointer's normalization: `"max"` divides by the series' own peak, a
number divides by itself."""
function _normalized(values::Vector{Float64}, factor::Float64)
    iszero(factor) && throw(IS.DataFormatError("normalization_factor cannot be zero"))
    if isone(factor)
        return values
    end
    return values ./ factor
end

function _normalized(values::Vector{Float64}, factor::AbstractString)
    if lowercase(factor) != "max"
        throw(IS.DataFormatError("unsupported normalization_factor=$factor"))
    end
    return values ./ maximum(values)
end

"""The basis a pointer's values are stored in. `nothing` when no multiplier is declared:
the values are then as the source file gave them, and no basis was declared — which is
deliberately not the same as declaring natural units."""
function _series_unit_system(multiplier::Union{Nothing, AbstractString})
    if isnothing(multiplier)
        return nothing
    end
    return COMPONENT_BASE_UNIT_SYSTEM
end

_series_unit_system(entry::TimeSeriesPointer) =
    _series_unit_system(entry.scaling_factor_multiplier)

"""The staged component of type `owner_type` with id `owner_id`."""
function _component(sys::OpenAPISystem, owner_type::AbstractString, owner_id::Int)
    for component in get_components(sys, owner_type)
        get_value(component, :id) == owner_id && return component
    end
    throw(IS.DataFormatError("no $owner_type carries id=$owner_id"))
end

"""
The accounting convention of the reservoir a reservoir-normalized entry is stated against.

Only a reservoir has one: [`_series_basis`](@ref) rejects a reservoir multiplier on any
other owner before this is reached.
"""
_reservoir_level_data_type(sys::OpenAPISystem, owner_type::AbstractString, owner_id::Int) =
    get_value(_component(sys, owner_type, owner_id), :level_data_type)

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

"""Multipliers that name a reservoir's flow rather than its level."""
const RESERVOIR_FLOW_MULTIPLIERS = ("get_inflow", "get_outflow")

"""
How a pointer's normalized values are stored on one owner: the factor they are multiplied by
and the units labels they carry.

PowerSystems fixes what a `CU` series is a fraction of for each owner and quantity, so a
multiplier naming some other field is converted to natural units here rather than
relabeled:

- A zone or area's own row is in MW. Its `peak_active_power` is the sum of its loads'
  `max_active_power` (`topology.jl`) and each load scales the profile by its own maximum, so
  the profile times the peak is the zone's total load.
- A reservoir's inflow and outflow are in MW. The `inflow`/`outflow` fields hold 1.0, which
  the psy5 hydro formulations read as per unit of the system base; only `ENERGY` reservoirs
  are built here, so the flow is power.
- Every other multiplier keeps its values as `CU` of the owner.

A reservoir multiplier on an owner that is not a reservoir is an error: PowerSystems takes
fluid series on reservoirs only.
"""
function _series_basis(
    sys::OpenAPISystem,
    entry::TimeSeriesPointer,
    owner_type::AbstractString,
    owner_id::Int,
)
    multiplier = entry.scaling_factor_multiplier
    isnothing(multiplier) && return 1.0, (;)
    if haskey(AGGREGATION_BUS_PROPERTIES, owner_type)
        multiplier == "get_max_active_power" || throw(
            IS.DataFormatError(
                "$multiplier on $owner_type id=$owner_id; an aggregation's series must " *
                "be normalized by get_max_active_power",
            ),
        )
        owner = _component(sys, owner_type, owner_id)
        # Per unit, an aggregation's peak is on the system base, its only base.
        peak = if uses_per_unit(sys)
            get_value(owner, :peak_active_power) * get_base_power(sys)
        else
            get_value(owner, :peak_active_power, "MW")
        end
        return peak,
        (unit_system = IS.NU, units = "MW", quantity_kind = "active_power")
    end
    if haskey(RESERVOIR_QUANTITY_KINDS, multiplier) && owner_type != "HydroReservoir"
        throw(
            IS.DataFormatError(
                "$(entry.name) on $owner_type $(entry.component_name) is normalized by " *
                "$multiplier, a reservoir field; reservoir series belong on the " *
                "HydroReservoir",
            ),
        )
    end
    if multiplier in RESERVOIR_FLOW_MULTIPLIERS
        reservoir = _component(sys, owner_type, owner_id)
        level_type = get_value(reservoir, :level_data_type)
        level_type == "ENERGY" || throw(
            IS.DataFormatError(
                "$multiplier on a $level_type reservoir; only ENERGY reservoir flows " *
                "are converted",
            ),
        )
        field = Symbol(chopprefix(multiplier, "get_"))
        return get_value(reservoir, field) * get_base_power(sys),
        (unit_system = IS.NU, units = "MW", quantity_kind = "active_power")
    end
    return 1.0,
    (
        unit_system = COMPONENT_BASE_UNIT_SYSTEM,
        quantity_kind = _series_quantity_kind(sys, entry, owner_type, owner_id),
    )
end

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
        normalized = _normalized(values, entry.normalization_factor)
        # Owners on the same basis share one series; the store dedups the rest by content.
        by_basis = Dict{Any, IS.SingleTimeSeries}()
        for (target_type, target_id) in series_owners(sys, entry, owner_type, owner_id)
            scale, labels = _series_basis(sys, entry, target_type, target_id)
            series = get!(by_basis, (scale, labels)) do
                IS.SingleTimeSeries(
                    entry.name,
                    initial_timestamp,
                    entry.resolution,
                    normalized .* scale;
                    labels...,
                )
            end
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
`path * ".sqlite"` (the catalog), and stamp in the document's supplemental-attribute
association rows before persisting — the sidecar is authoritative for both association
tables, so whatever `add_supplemental_attribute!` has recorded on the document travels
with it.

The whole run commits as one transaction, and the store dedups arrays by content hash —
a fanned-out series lands once no matter how many owners reference it.

Returns the store's own `TimeSeriesAssociation` rows, already sorted by identity and
stamped with `uri`/`data_hash`, read back from the store rather than derived from
`sys.time_series` so `element_type`/`element_shape` come from the store itself.
"""
function write_time_series(sys::OpenAPISystem, path::AbstractString)
    category = IS.get_owner_category(IS.InfrastructureSystemsComponent)
    store = IS.Store(; in_memory = true)
    try
        # Each add writes straight through; the transaction is what makes the run
        # atomic and lets the store pack the arrays into blocks instead of spilling
        # one dataset per add.
        IS.InfraStore.transaction(store.inner) do
            for staged in sys.time_series
                IS.add_time_series!(
                    store,
                    staged.owner_id,
                    staged.owner_type,
                    category,
                    staged.series,
                )
            end
        end
        _stamp_supplemental_attribute_associations!(store, sys)
        IS.serialize(store, String(path))
        return IS.openapi_time_series_association_rows(store)
    finally
        IS.close!(store)
    end
end

"""
Ingest the document's `supplemental_attribute_associations` rows into `store`'s own
association table in one bulk call, so the sidecar is authoritative for attribute
attachments the same way it already is for time series. A no-op when the document names
none — an empty document should not force a needless transaction.
"""
function _stamp_supplemental_attribute_associations!(store::IS.Store, sys::OpenAPISystem)
    associations = get_supplemental_attribute_associations(sys)
    if isempty(associations)
        return
    end
    IS.import_supplemental_attribute_association_rows!(
        store,
        JSON.json(IC.encode(associations)),
    )
    return
end
