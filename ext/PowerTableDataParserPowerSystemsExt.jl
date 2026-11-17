# Pointer-file time series ingestion into a live `PowerSystems.System`. Lives in an
# extension so the core package keeps no PowerSystems dependency (the OpenAPI document
# path reads the same pointer files without one).

module PowerTableDataParserPowerSystemsExt

import CSV
import DataFrames
import Dates
import JSON
import TimeSeries

import InfrastructureSystems
import PowerSystems
# `u"NU"` resolves only where `PerUnit` is bound.
using PowerSystems: @u_str, PerUnit
import PowerTableDataParser

const IS = InfrastructureSystems
const PSY = PowerSystems
const PDP = PowerTableDataParser

"""
Resolve the component supertype referenced by a pointer entry's `category` field. Names
are only unique within a concrete type, so `get_component(Component, ...)` is ambiguous
when e.g. a load and a bus share a name; narrowing to the entry's category disambiguates.
Falls back to the abstract `Component` for the generic `"Component"` category or any
unrecognized value.
"""
function _pointer_component_type(category::AbstractString)
    sym = Symbol(category)
    isdefined(PSY, sym) || return PSY.Component
    return _as_component_type(getproperty(PSY, sym))
end

_as_component_type(T::Type) = T
_as_component_type(::Any) = PSY.Component

"""
Read a `timeseries_pointers.json` metadata file and attach the referenced time series
by reading each CSV directly and constructing `SingleTimeSeries` objects.

A pointer that states `units` and `quantity_kind` is stored as its CSV gives it, under those
labels ([`PowerTableDataParser.stated_labels`](@ref)). The rest is the legacy convention.

A pointer that declares a multiplier stores its values normalized by `normalization_factor`
— per unit on the owner's own base — and says so: `per_unit_of` names the owner field they
are a fraction of (from which IS derives the component base), and `quantity_kind` the
physical quantity the values scale to. Owners PowerSystems takes in natural units only get the
profile converted instead; see [`_series_for`](@ref).

`units` stays unset on a legacy CU series: a per-unit basis is not a units label.

The CSVs use either a single `DateTime` index column or `Year, Month, Day, Period` index
columns, followed by one value column per `component_name`.
"""
function PDP.add_time_series_from_pointers!(
    sys::PSY.System,
    metadata_file::AbstractString;
    resolution = nothing,
)
    entries = open(metadata_file) do io
        JSON.parse(io; dicttype = Dict{String, Any})
    end
    base_dir = dirname(metadata_file)
    csv_cache = Dict{String, DataFrames.DataFrame}()
    seen = Set{Tuple{Int, String}}()
    # Gathered while reading CSVs, written in one block afterwards: an open block
    # holds the store's write lock, so the slow parsing stays outside it.
    associations = Tuple{PSY.Component, PSY.SingleTimeSeries}[]
    for entry in entries
        get(entry, "type", "SingleTimeSeries") == "SingleTimeSeries" || continue
        entry_res = Dates.Second(entry["resolution"])
        if !isnothing(resolution) && entry_res != Dates.Second(resolution)
            continue
        end
        component_name = String(entry["component_name"])
        name = String(entry["name"])
        component_type = _pointer_component_type(String(entry["category"]))
        component = PSY.get_component(component_type, sys, component_name)
        isnothing(component) && continue
        units, quantity_kind = PDP.stated_labels(entry)
        multiplier = _pointer_multiplier(entry)
        component = _series_owner(sys, component, multiplier)
        # (component, name) pairs are recorded once: a repeat is skipped rather than
        # assigned twice.
        key = (IS.get_id(component), name)
        key in seen && continue
        push!(seen, key)

        path = normpath(joinpath(base_dir, String(entry["data_file"])))
        df = get!(() -> CSV.read(path, DataFrames.DataFrame), csv_cache, path)
        parsed = PDP.read_pointer_csv_values(df, component_name, entry_res)
        isnothing(parsed) && continue
        values, initial_timestamp = parsed
        timestamps = range(initial_timestamp; step = entry_res, length = length(values))
        ta = TimeSeries.TimeArray(
            timestamps,
            _normalized(values, get(entry, "normalization_factor", 1.0), multiplier),
        )
        series = PSY.SingleTimeSeries(
            name,
            ta;
            units = units,
            per_unit_of = _per_unit_of(multiplier),
            quantity_kind = isnothing(multiplier) ? quantity_kind :
                            PDP.quantity_kind_for_multiplier(
                multiplier,
                () -> _reservoir_level_data_type(sys, component),
            ),
        )
        push!(associations, (component, _series_for(sys, component, series, multiplier)))
        _fan_out_aggregation_time_series!(associations, seen, sys, component, entry, series)
    end
    if !isempty(associations)
        PSY.time_series_transaction(sys) do txn
            for (component, ts) in associations
                PSY.add_time_series!(txn, component, ts)
            end
        end
    end
    return
end

"""
The owner field a series kept in CU is a fraction of, its `per_unit_of` label: a battery's
`storage_capacity` for its levels, the device's `base_power` for power. `nothing` for an
unnormalized series. Series PowerSystems takes in natural units only are converted by
[`_series_for`](@ref), which drops the label.
"""
_per_unit_of(::Nothing) = nothing
_per_unit_of(multiplier::AbstractString) =
    haskey(PDP.RESERVOIR_QUANTITY_KINDS, multiplier) ? "storage_capacity" : "base_power"

"""The multiplier a pointer entry declares, as a `String`, or `nothing`."""
function _pointer_multiplier(entry::Dict{String, Any})
    multiplier = get(entry, "scaling_factor_multiplier", nothing)
    if isnothing(multiplier)
        return nothing
    end
    return String(multiplier)
end

"""
Apply the pointer's `normalization_factor`, making the values per unit on the owner's base.

Only for an entry that declares a multiplier: without one the values are the device
quantities the file states and nothing normalizes them. The actual normalization is
[`PowerTableDataParser._normalized`](@ref).
"""
function _normalized(
    values::Vector{Float64},
    factor::Union{Real, AbstractString},
    multiplier::Union{Nothing, String},
)
    isnothing(multiplier) && return values
    return PDP._normalized(values, PDP._normalization_factor(factor))
end

"""
The component a pointer's series belongs on. A series normalized by a reservoir field but
filed under the turbine it feeds (both spellings are in circulation) belongs on the reservoir
naming that turbine downstream, as in the document path.
"""
_series_owner(::PSY.System, component::PSY.Component, ::Union{Nothing, String}) =
    component

function _series_owner(
    sys::PSY.System,
    turbine::Union{PSY.HydroTurbine, PSY.HydroPumpTurbine},
    multiplier::Union{Nothing, String},
)
    haskey(PDP.RESERVOIR_QUANTITY_KINDS, something(multiplier, "")) || return turbine
    for reservoir in PSY.get_components(PSY.HydroReservoir, sys)
        turbine in PSY.get_downstream_turbines(reservoir) && return reservoir
    end
    throw(IS.DataFormatError("no HydroReservoir feeds $(summary(turbine))"))
end

"""
How the owner of a reservoir-normalized entry accounts its levels: a reservoir by its
`level_data_type`, a battery in energy. PowerSystems takes these series on nothing else.
"""
_reservoir_level_data_type(::PSY.System, component::PSY.HydroReservoir) =
    string(PSY.get_level_data_type(component))
_reservoir_level_data_type(::PSY.System, ::PSY.EnergyReservoirStorage) = "ENERGY"
_reservoir_level_data_type(::PSY.System, component::PSY.Component) = throw(
    IS.DataFormatError(
        "a reservoir-normalized series on $(summary(component)); reservoir series belong " *
        "on the HydroReservoir",
    ),
)

"""The multipliers that mean "this zonal profile is shared by the loads in the zone, each
scaling it by its own peak"."""
const _AGGREGATION_LOAD_MULTIPLIERS = ("get_max_active_power", "get_max_reactive_power")

"""The loads on the buses of an aggregation topology."""
function _loads_under(sys::PSY.System, component::PSY.AggregationTopology)
    bus_ids = Set(IS.get_id(bus) for bus in PSY.get_buses(sys, component))
    return [
        load for load in PSY.get_components(PSY.ElectricLoad, sys) if
        IS.get_id(PSY.get_bus(load)) in bus_ids
    ]
end

"""
The series as PowerSystems takes it on `owner`. PowerSystems takes `CU` only for a device's
power and a battery's levels, so those keep the pointer's series as it is, and the other
owners' methods below convert the normalized profile to natural units: the profile times the
field its multiplier names.
"""
_series_for(
    ::PSY.System,
    ::PSY.Component,
    series::PSY.SingleTimeSeries,
    ::Union{Nothing, String},
) = series

"""`series` scaled by `scale` into natural `units`, keeping its name and quantity."""
_natural(series::PSY.SingleTimeSeries, scale::Real, units::String) = PSY.SingleTimeSeries(
    IS.get_name(series),
    IS.get_data(series) .* scale;
    units = units,
    quantity_kind = IS.get_quantity_kind(series),
)

"""
A zone's or area's own row. The profile is shared by the zone's loads, each scaling it by its
own maximum, so the zone's row is the profile times the sum of those maxima: its total load.
"""
function _series_for(
    sys::PSY.System,
    zone::PSY.AggregationTopology,
    series::PSY.SingleTimeSeries,
    multiplier::Union{Nothing, String},
)
    multiplier in _AGGREGATION_LOAD_MULTIPLIERS || return series
    active = multiplier == "get_max_active_power"
    maximum_of = active ? PSY.get_max_active_power : PSY.get_max_reactive_power
    total = sum(_load_maximum(maximum_of, load) for load in _loads_under(sys, zone);
        init = 0.0)
    return _natural(series, total, active ? "MW" : "MVAr")
end

"""A reserve's requirement row, in MW: the profile times its `requirement`."""
function _series_for(
    ::PSY.System,
    reserve::PSY.Service,
    series::PSY.SingleTimeSeries,
    multiplier::Union{Nothing, String},
)
    multiplier == "get_requirement" || return series
    return _natural(series, PSY.get_requirement(reserve, u"MW"), "MW")
end

"""
A reservoir's row. A level is the profile times `storage_level_limits.max`, in the natural
unit of its quantity. A flow is the profile times the `inflow`/`outflow` field, which the
psy5 hydro formulations read as per unit of the system base, so it is power and only an
`ENERGY` reservoir's flow is converted, as the document path does.
"""
function _series_for(
    sys::PSY.System,
    reservoir::PSY.HydroReservoir,
    series::PSY.SingleTimeSeries,
    multiplier::Union{Nothing, String},
)
    haskey(PDP.RESERVOIR_QUANTITY_KINDS, multiplier) || return series
    if multiplier in PDP.RESERVOIR_FLOW_MULTIPLIERS
        PSY.get_level_data_type(reservoir) == PSY.ReservoirDataType.ENERGY || throw(
            IS.DataFormatError(
                "$multiplier on a $(PSY.get_level_data_type(reservoir)) reservoir; only " *
                "ENERGY reservoir flows are converted",
            ),
        )
        flow = multiplier == "get_inflow" ? PSY.get_inflow : PSY.get_outflow
        scale = flow(reservoir) * PSY.get_base_power(sys)
        return _natural(series, scale, "MW")
    end
    scale = PSY.get_storage_level_limits(reservoir).max
    units = PDP.RESERVOIR_LEVEL_UNITS[IS.get_quantity_kind(series)]
    return _natural(series, scale, units)
end

# A load with no maximum (a `FixedAdmittance`, whose draw depends on voltage) has no share
# of a zone's total; the getters fall back to throwing for it.
function _load_maximum(maximum_of::Function, load::PSY.ElectricLoad)
    try
        return maximum_of(load, u"NU")
    catch e
        e isa ArgumentError || rethrow()
        return 0.0
    end
end

"""
Associate an `AggregationTopology`'s load profile with the loads underneath it.

RTS-style pointers attach a load profile to a `LoadZone`/`Area` with
`scaling_factor_multiplier = get_max_active_power` and a `normalization_factor` equal to the
topology's peak. That combination means: the profile is a normalized shape every load on a
bus in the topology follows, each against its own peak.

`series` is associated as-is with each of them — one array, many owners, which is what the
store deduplicates to and what lets a consumer scale each load by its own base. No-op for
any other pointer.
"""
function _fan_out_aggregation_time_series!(
    associations::Vector{Tuple{PSY.Component, PSY.SingleTimeSeries}},
    seen::Set{Tuple{Int, String}},
    sys::PSY.System,
    component::PSY.AggregationTopology,
    entry::Dict{String, Any},
    series::PSY.SingleTimeSeries,
)
    multiplier = _pointer_multiplier(entry)
    if isnothing(multiplier)
        quantity = IS.get_quantity_kind(series)
        haskey(_LOAD_SHARE_GETTERS, something(quantity, "")) || return
        return _share_out!(associations, seen, sys, component, series,
            _LOAD_SHARE_GETTERS[quantity])
    end
    multiplier in _AGGREGATION_LOAD_MULTIPLIERS || return

    name = IS.get_name(series)
    for load in _loads_under(sys, component)
        key = (IS.get_id(load), name)
        key in seen && continue
        push!(seen, key)
        push!(associations, (load, series))
    end
    return
end

"""The load maximum a stated zone or area series of each quantity is shared out by."""
const _LOAD_SHARE_GETTERS = Dict(
    "active_power" => PSY.get_max_active_power,
    "reactive_power" => PSY.get_max_reactive_power,
)

"""
Give each load under `zone` its share of the zone's stated series, upstream RTS-GMLC's rule:
the series times `max / Σ max`, stored in CU of the load's own `base_power`. Loads rebased so
their maximum is their `base_power` share one series. A load with no maximum (a
`FixedAdmittance`) takes no share.
"""
function _share_out!(
    associations::Vector{Tuple{PSY.Component, PSY.SingleTimeSeries}},
    seen::Set{Tuple{Int, String}},
    sys::PSY.System,
    zone::PSY.AggregationTopology,
    series::PSY.SingleTimeSeries,
    maximum_of::Function,
)
    loads = filter(l -> _load_maximum(maximum_of, l) > 0, _loads_under(sys, zone))
    total = sum(l -> _load_maximum(maximum_of, l), loads; init = 0.0)
    name = IS.get_name(series)
    by_share = Dict{Float64, PSY.SingleTimeSeries}()
    for load in loads
        key = (IS.get_id(load), name)
        key in seen && continue
        push!(seen, key)
        share = maximum_of(load, u"CU") / total
        shared = get!(by_share, share) do
            PSY.SingleTimeSeries(
                name,
                IS.get_data(series) .* share;
                quantity_kind = IS.get_quantity_kind(series),
                per_unit_of = "base_power",
            )
        end
        push!(associations, (load, shared))
    end
    return
end

_fan_out_aggregation_time_series!(
    ::Vector{Tuple{PSY.Component, PSY.SingleTimeSeries}},
    ::Set{Tuple{Int, String}},
    ::PSY.System,
    ::PSY.Component,
    ::Dict{String, Any},
    ::PSY.SingleTimeSeries,
) = nothing

end
