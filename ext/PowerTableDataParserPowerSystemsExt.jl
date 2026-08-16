# Pointer-file time series ingestion into a live `PowerSystems.System`, migrated from
# PowerSystemCaseBuilder's `_add_time_series_from_pointers!`. Lives in an extension so
# the core package keeps no PowerSystems dependency (the OpenAPI document path reads the
# same pointer files without one).

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
    T = getproperty(PSY, sym)
    return T isa Type ? T : PSY.Component
end

"""
Read a `timeseries_pointers.json` metadata file and attach the referenced time series
by reading each CSV directly and constructing `SingleTimeSeries` objects.

This replaces the former file-metadata ingestion in InfrastructureSystems. A pointer that
declares a multiplier stores its values normalized by `normalization_factor` — per unit on
the owner's own base — and says so: `unit_system` is the component base and `quantity_kind`
names the physical quantity the values scale to. That replaces the removed
`scaling_factor_multiplier`, which named an accessor for a reader to resolve and multiply by
on every read; the declaration carries the same meaning without the function name, and
leaves the scaling to the consumer.

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
        # The old file-metadata parser deduplicated (component, name) assignments;
        # the rust store rejects duplicate associations, so skip repeats here.
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

        # A pointer on an AggregationTopology (a LoadZone/Area) with a max-power multiplier
        # does not describe that topology's own device series: it is a normalized zonal
        # *shape* that every load in the zone shares, each scaling it by its own peak. Every
        # such load is associated with the very same series object, so the store keeps one
        # array for all of them — the shape is one series, and materializing a scaled copy
        # per load would both lose that and bake in a scaling the consumer now applies.
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
    return isnothing(multiplier) ? nothing : String(multiplier)
end

"""
Apply the pointer's `normalization_factor`, making the values per unit on the owner's base.

Only for an entry that declares a multiplier: without one the values are the device
quantities the file states and nothing normalizes them. `"max"` divides by the series' own
peak, a number divides by itself — the same semantics as the retired InfrastructureSystems
file ingestion, and as [`PowerTableDataParser._normalized`](@ref) on the document path.
"""
function _normalized(values::Vector{Float64}, factor, multiplier)
    isnothing(multiplier) && return values
    if factor isa AbstractString
        lowercase(factor) == "max" ||
            throw(IS.DataFormatError("unsupported normalization_factor=$factor"))
        return values ./ maximum(values)
    end
    iszero(factor) && throw(IS.DataFormatError("normalization_factor cannot be zero"))
    return Float64(factor) == 1.0 ? values : values ./ Float64(factor)
end

"""The basis the values are stored in: the component's own base once normalized, and
nothing declared otherwise — which is deliberately not the same as natural units."""
_series_unit_system(multiplier) = isnothing(multiplier) ? nothing : IS.DU

"""
How the reservoir behind a reservoir-normalized entry accounts its levels.

The owner is the reservoir when the pointer files the entry under `Component`, and the
turbine it feeds when the pointer files it under `Generator`; both spellings are in
circulation. Falls back to the system's reservoirs in that second case, and requires them to
agree — with the owner not naming one, a mixed system gives no way to tell which convention
applies.
"""
function _reservoir_level_data_type(sys::PSY.System, component)
    component isa PSY.HydroReservoir &&
        return string(PSY.get_level_data_type(component))
    level_types =
        unique(
            string(PSY.get_level_data_type(r))
            for r in PSY.get_components(PSY.HydroReservoir, sys)
        )
    length(level_types) == 1 || throw(
        IS.DataFormatError(
            "a reservoir-normalized series is owned by a $(typeof(component)) rather than " *
            "the reservoir, and the system's reservoirs state " *
            "$(isempty(level_types) ? "no level_data_type" :
               "several: $(join(sort(level_types), ", "))") — so the quantity its values " *
            "scale to cannot be determined",
        ),
    )
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
function _fan_out_aggregation_time_series!(associations, seen, sys::PSY.System, component,
    entry, series::PSY.SingleTimeSeries)
    component isa PSY.AggregationTopology || return
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

end
