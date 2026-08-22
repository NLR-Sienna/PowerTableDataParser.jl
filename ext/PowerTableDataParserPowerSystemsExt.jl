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
— per unit on the owner's own base — and says so: `unit_system` is the component base and
`quantity_kind` names the physical quantity the values scale to.

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
        multiplier = _pointer_multiplier(entry)
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
            quantity_kind = PDP.quantity_kind_for_multiplier(
                multiplier,
                () -> _reservoir_level_data_type(sys, component),
            ),
        )
        push!(associations, (component, series))
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
How the reservoir behind a reservoir-normalized entry accounts its levels.

The owner is the reservoir when the pointer files the entry under `Component`, and the
turbine it feeds when the pointer files it under `Generator`; both spellings are in
circulation. Falls back to the system's reservoirs in that second case, and requires them to
agree — with the owner not naming one, a mixed system gives no way to tell which convention
applies.
"""
_reservoir_level_data_type(::PSY.System, component::PSY.HydroReservoir) =
    string(PSY.get_level_data_type(component))

function _reservoir_level_data_type(sys::PSY.System, component)
    level_types =
        unique(
            string(PSY.get_level_data_type(r))
            for r in PSY.get_components(PSY.HydroReservoir, sys)
        )
    if length(level_types) != 1
        stated = "several: $(join(sort(level_types), ", "))"
        if isempty(level_types)
            stated = "no level_data_type"
        end
        throw(
            IS.DataFormatError(
                "a reservoir-normalized series is owned by a $(typeof(component)) rather " *
                "than the reservoir, and the system's reservoirs state $stated — so the " *
                "quantity its values scale to cannot be determined",
            ),
        )
    end
    return only(level_types)
end

"""The multipliers that mean "this zonal profile is shared by the loads in the zone, each
scaling it by its own peak"."""
const _AGGREGATION_LOAD_MULTIPLIERS = ("get_max_active_power", "get_max_reactive_power")

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
    bus_ids = Set(IS.get_id(bus) for bus in PSY.get_buses(sys, component))
    for load in PSY.get_components(PSY.ElectricLoad, sys)
        IS.get_id(PSY.get_bus(load)) in bus_ids || continue
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
