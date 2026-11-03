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

A pointer that declares a multiplier stores its values normalized by `normalization_factor`
— per unit on the owner's own base — and says so: `unit_system` is the component base,
`quantity_kind` names the physical quantity the values scale to, and `per_unit_of` the owner
field they are a fraction of. Owners PowerSystems takes in natural units only get the
profile converted instead; see [`_own_association`](@ref).

`units` stays unset throughout: a per-unit basis is not a units label.

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
    associations = Tuple{Any, PSY.SingleTimeSeries}[]
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
            unit_system = _series_unit_system(multiplier),
            units = nothing,
            per_unit_of = _per_unit_of(multiplier),
            quantity_kind = PDP.quantity_kind_for_multiplier(
                multiplier,
                () -> _reservoir_level_data_type(sys, component),
            ),
        )
        push!(associations, _own_association(sys, component, series, multiplier))
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
[`_own_association`](@ref), which drops the label.
"""
_per_unit_of(::Nothing) = nothing
_per_unit_of(multiplier::AbstractString) =
    haskey(PDP.RESERVOIR_QUANTITY_KINDS, multiplier) ? "storage_capacity" : "base_power"

"""The multiplier a pointer entry declares, as a `String`, or `nothing`."""
function _pointer_multiplier(entry)
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
function _normalized(values::Vector{Float64}, factor, multiplier)
    isnothing(multiplier) && return values
    return PDP._normalized(values, PDP._normalization_factor(factor))
end

"""The basis the values are stored in: the component's own base once normalized, and
nothing declared otherwise — which is deliberately not the same as natural units."""
_series_unit_system(multiplier) = PDP._series_unit_system(multiplier)

"""
The component a pointer's series belongs on. A series normalized by a reservoir field but
filed under the turbine it feeds (both spellings are in circulation) belongs on the reservoir
naming that turbine downstream, as in the document path.
"""
_series_owner(_sys, component, _multiplier) = component

function _series_owner(
    sys::PSY.System,
    turbine::Union{PSY.HydroTurbine, PSY.HydroPumpTurbine},
    multiplier,
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
_reservoir_level_data_type(::PSY.System, component) = throw(
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
How a pointer's series attaches to the component it names. PowerSystems takes `CU` only for
a device's power and a battery's levels, so the other owners' methods below convert their
normalized profile to natural units, the profile times the field its multiplier names.
"""
_own_association(_sys, component, series, multiplier) =
    (component, series)

"""`series` scaled by `scale` into natural `units`, keeping its name and quantity."""
_natural(series, scale, units) = PSY.SingleTimeSeries(
    IS.get_name(series),
    IS.get_data(series) .* scale;
    unit_system = IS.NU,
    units = units,
    quantity_kind = IS.get_quantity_kind(series),
)

"""
A zone's or area's own row. The profile is shared by the zone's loads, each scaling it by its
own maximum, so the zone's row is the profile times the sum of those maxima: its total load.
"""
function _own_association(sys, zone::PSY.AggregationTopology, series, multiplier)
    multiplier in _AGGREGATION_LOAD_MULTIPLIERS ||
        return (zone, series)
    active = multiplier == "get_max_active_power"
    maximum_of = active ? PSY.get_max_active_power : PSY.get_max_reactive_power
    total = sum(_load_maximum(maximum_of, load) for load in _loads_under(sys, zone);
        init = 0.0)
    return (zone, _natural(series, total, active ? "MW" : "MVAr"))
end

"""A reserve's requirement row, in MW: the profile times its `requirement`."""
function _own_association(_sys, reserve::PSY.Service, series, multiplier)
    multiplier == "get_requirement" || return (reserve, series)
    return (reserve, _natural(series, PSY.get_requirement(reserve, u"MW"), "MW"))
end

"""
A reservoir's row. A level is the profile times `storage_level_limits.max`, in the natural
unit of its quantity. A flow is the profile times the `inflow`/`outflow` field, which the
psy5 hydro formulations read as per unit of the system base, so it is power and only an
`ENERGY` reservoir's flow is converted, as the document path does.
"""
function _own_association(sys, reservoir::PSY.HydroReservoir, series, multiplier)
    haskey(PDP.RESERVOIR_QUANTITY_KINDS, multiplier) ||
        return (reservoir, series)
    if multiplier in PDP.RESERVOIR_FLOW_MULTIPLIERS
        PSY.get_level_data_type(reservoir) == PSY.ReservoirDataType.ENERGY || throw(
            IS.DataFormatError(
                "$multiplier on a $(PSY.get_level_data_type(reservoir)) reservoir; only " *
                "ENERGY reservoir flows are converted",
            ),
        )
        flow = multiplier == "get_inflow" ? PSY.get_inflow : PSY.get_outflow
        scale = flow(reservoir) * PSY.get_base_power(sys)
        return (reservoir, _natural(series, scale, "MW"))
    end
    scale = PSY.get_storage_level_limits(reservoir).max
    units = PDP.RESERVOIR_LEVEL_UNITS[IS.get_quantity_kind(series)]
    return (reservoir, _natural(series, scale, units))
end

# A load with no maximum (a `FixedAdmittance`, whose draw depends on voltage) has no share
# of a zone's total; the getters fall back to throwing for it.
function _load_maximum(maximum_of, load)
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
    associations,
    seen,
    sys::PSY.System,
    component::PSY.AggregationTopology,
    entry,
    series::PSY.SingleTimeSeries,
)
    multiplier = _pointer_multiplier(entry)
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

_fan_out_aggregation_time_series!(
    associations,
    seen,
    ::PSY.System,
    component,
    entry,
    series::PSY.SingleTimeSeries,
) = nothing

end
