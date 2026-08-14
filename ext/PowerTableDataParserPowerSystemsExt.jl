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

This replaces the former file-metadata ingestion in InfrastructureSystems. The raw CSV
values are stored directly (the legacy `scaling_factor_multiplier` / `normalization_factor`
mechanism has been removed), so the stored data are the actual per-device quantities.
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
        timestamps = range(initial_timestamp; step = entry_res, length = length(values))
        ta = TimeSeries.TimeArray(timestamps, values)
        push!(associations, (component, PSY.SingleTimeSeries(name, ta)))

        # A pointer on an AggregationTopology (a LoadZone/Area) with a max-power
        # multiplier does not describe that topology's own device series: it is a
        # normalized zonal *shape* that every load in the zone shares, each scaling it by
        # its own peak. The legacy `scaling_factor_multiplier` applied that scaling lazily
        # on read; now that raw values are stored directly, materialize one series per
        # load here instead — otherwise the loads end up with no time series at all.
        #
        # `normalization_factor` is the topology's own peak, so the topology's raw series
        # pushed above is already correctly scaled and is left alone.
        _fan_out_aggregation_time_series!(
            associations,
            seen,
            sys,
            component,
            entry,
            name,
            values,
            timestamps,
        )
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

# The multipliers that mean "this zonal profile is shared by the loads in the zone,
# scaled by each load's own peak", mapped to the per-load getter that supplies the scale.
const _AGGREGATION_LOAD_SCALERS = Dict(
    "get_max_active_power" => PSY.get_max_active_power,
    "get_max_reactive_power" => PSY.get_max_reactive_power,
)

"""
Materialize the per-load series implied by an `AggregationTopology` time series pointer.

RTS-style pointers attach a load profile to a `LoadZone`/`Area` with
`scaling_factor_multiplier = get_max_active_power` and a `normalization_factor` equal to
the topology's peak. That combination means: normalize the profile to 0-1, then give every
load on a bus in the topology its own series scaled by that load's peak. The legacy
multiplier applied the scaling lazily on read; raw values are now stored directly, so the
per-load values are computed and stored here. No-op for any other pointer.
"""
function _fan_out_aggregation_time_series!(
    associations,
    seen,
    sys::PSY.System,
    component,
    entry,
    name::AbstractString,
    values::Vector{Float64},
    timestamps,
)
    component isa PSY.AggregationTopology || return
    sfm = get(entry, "scaling_factor_multiplier", nothing)
    isnothing(sfm) && return
    scaler = get(_AGGREGATION_LOAD_SCALERS, String(sfm), nothing)
    isnothing(scaler) && return

    normalization = get(entry, "normalization_factor", nothing)
    if isnothing(normalization) || !(normalization isa Number) || iszero(normalization)
        @warn "Cannot fan out $(summary(component)) time series '$name' to its loads: " *
              "normalization_factor is missing or zero"
        return
    end
    profile = values ./ Float64(normalization)

    bus_ids = Set(IS.get_id(bus) for bus in PSY.get_buses(sys, component))
    for load in PSY.get_components(PSY.ElectricLoad, sys)
        IS.get_id(PSY.get_bus(load)) in bus_ids || continue
        key = (IS.get_id(load), name)
        key in seen && continue

        # Natural units: the stored values are the load's actual MW / MVAr, matching the
        # raw device quantities every other pointer stores.
        peak = try
            scaler(load, PSY.NU)
        catch err
            err isa ArgumentError || rethrow()
            # Some ElectricLoads have no peak power to scale a profile by — a
            # `FixedAdmittance` is a voltage-dependent shunt, not a rated load — and the
            # accessor throws for them. Those legitimately take no load profile.
            @debug "Skipping $(summary(load)): no max power to scale '$name' by"
            continue
        end

        push!(seen, key)
        scaled = profile .* peak
        push!(
            associations,
            (load, PSY.SingleTimeSeries(name, TimeSeries.TimeArray(timestamps, scaled))),
        )
    end
    return
end

end
