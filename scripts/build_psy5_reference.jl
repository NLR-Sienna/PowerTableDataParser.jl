# Build the RTS-GMLC system the way the released stack does today — psy5's own
# table parser over PowerSystemCaseBuilder's data — and serialize it. The result
# is the reference `scripts/compare_structure.jl` checks the OpenAPI document
# against.
#
# Run:
#   julia --project=scripts/psy5_reference scripts/build_psy5_reference.jl [out.json]
#
# The environment is separate on purpose: this must resolve the registered
# PowerSystems 5.x, not the psy6 checkout the package environment points at.

using PowerSystems
using PowerSystemCaseBuilder
import Dates
import JSON

const OUT = get(ARGS, 1, joinpath(@__DIR__, "..", "data", "rts_psy5.json"))

# psy5 keys a time series on (type, owner, name) and errors on a second entry for
# the same triple, so it cannot ingest RTS's pointer file whole: every series is
# stated at 3600 s and again at 300 s. IS4 includes resolution in that key, which
# is why the OpenAPI document holds all 260. Feeding psy5 one simulation is the
# only way to get a reference system at all; the comparison script accounts for
# the entries dropped here.
const SIMULATION = "DAY_AHEAD"

function write_filtered_pointers(rts_dir::AbstractString, out_dir::AbstractString)
    entries = JSON.parsefile(joinpath(rts_dir, "timeseries_pointers.json"))
    kept = [e for e in entries if e["simulation"] == SIMULATION]
    # data_file is relative to the pointer file, and this copy does not live beside
    # the tables, so the paths are resolved before they are written out.
    for entry in kept
        entry["data_file"] = abspath(joinpath(rts_dir, entry["data_file"]))
    end
    path = joinpath(out_dir, "rts_psy5_pointers_$(lowercase(SIMULATION)).json")
    open(path, "w") do io
        JSON.print(io, kept)
    end
    @info "filtered pointers" total = length(entries) kept = length(kept) path
    return path
end

# PSCB ships the RTS tables as an artifact and states where they live; the parse
# itself is psy5's, which is what makes this the reference rather than a port of
# it.
const RTS_DIR = joinpath(PowerSystemCaseBuilder.DATA_DIR, "RTS_GMLC")

# Both sides read the same descriptor on purpose. The fixture's own copy points
# base_mva at MATPOWER BaseMVA, which is 100.0 for all 158 generators; PTDP ships
# a corrected copy. Using the fixture's here would make every generator's
# base_power differ for a reason that has nothing to do with either parser. Set
# PSY5_USE_FIXTURE_DESCRIPTORS=1 to compare against the released behaviour instead.
function descriptor_file()
    if get(ENV, "PSY5_USE_FIXTURE_DESCRIPTORS", "0") == "1"
        return joinpath(RTS_DIR, "user_descriptors.yaml")
    end
    return joinpath(@__DIR__, "..", "test", "descriptors", "rts_user_descriptors.yaml")
end

const DESCRIPTORS = descriptor_file()

"""
Numeric state of a component, read through the getters under `units`.

The getters apply the unit system, which is the whole reason for reading them
rather than the stored fields. Both systems are recorded because the schemas do
not use one basis throughout: power and energy are natural units, while the
branch impedances stay per unit — and psy5's natural units put those in ohms.
"""
function component_values(sys::System, units::String)
    set_units_base_system!(sys, units)
    values = Dict{String, Dict{String, Any}}()
    for component in get_components(Component, sys)
        key = string(nameof(typeof(component)), "|", structural_name(component))
        fields = Dict{String, Any}()
        for field in fieldnames(typeof(component))
            getter = Symbol("get_", field)
            isdefined(PowerSystems, getter) || continue
            record_value!(fields, string(field), getfield(PowerSystems, getter)(component))
        end
        values[key] = fields
    end
    return values
end

record_value!(fields, name::String, value::Bool) = (fields[name] = value; nothing)
record_value!(fields, name::String, value::Real) = (fields[name] = Float64(value); nothing)

function record_value!(fields, name::String, value::Complex)
    fields[name] = Dict("real" => real(value), "imag" => imag(value))
    return
end

function record_value!(fields, name::String, value::NamedTuple)
    if all(v -> v isa Real, values(value))
        fields[name] = Dict(string(k) => Float64(v) for (k, v) in pairs(value))
    end
    return
end

record_value!(fields, name::String, value) = nothing

"""
Name a component for comparison purposes.

`Arc` carries no name, so it is identified by the buses it joins — the same
identity the OpenAPI `Arc` has once its integer endpoints are resolved to names.
"""
function structural_name(component::Arc)
    return string(get_name(get_from(component)), " -> ", get_name(get_to(component)))
end

function structural_name(component::Component)
    return get_name(component)
end

"""
A structural view of the system: what exists and what owns what, no values.

Written by the reference build rather than derived from the serialized JSON
because psy5 keeps time series metadata in its HDF5 store, not in the document.
"""
function structure(sys::System)
    components = Dict{String, Vector{String}}()
    for component in get_components(Component, sys)
        type_name = string(nameof(typeof(component)))
        push!(get!(components, type_name, String[]), structural_name(component))
    end
    for names in values(components)
        sort!(names)
    end

    series = Vector{Dict{String, Any}}()
    for component in get_components(Component, sys)
        for key in get_time_series_keys(component)
            push!(
                series,
                Dict{String, Any}(
                    "owner_type" => string(nameof(typeof(component))),
                    "owner_name" => structural_name(component),
                    "name" => get_name(key),
                    "resolution_seconds" =>
                        Dates.value(Dates.Second(get_resolution(key))),
                ),
            )
        end
    end
    sort!(series; by = s -> (s["owner_type"], s["owner_name"], s["name"]))

    return Dict{String, Any}(
        "source" => "psy5",
        "powersystems_version" => string(pkgversion(PowerSystems)),
        "powersystemcasebuilder_version" => string(pkgversion(PowerSystemCaseBuilder)),
        "rts_directory" => RTS_DIR,
        "descriptors" => DESCRIPTORS,
        "time_series_simulation" => SIMULATION,
        "base_power" => get_base_power(sys),
        "components" => components,
        "time_series" => series,
        "values_natural" => component_values(sys, "NATURAL_UNITS"),
    )
end

function main()
    @info "psy5 reference build" PowerSystems = pkgversion(PowerSystems) PowerSystemCaseBuilder =
        pkgversion(PowerSystemCaseBuilder) RTS_DIR

    out_dir = dirname(abspath(OUT))
    mkpath(out_dir)
    data = PowerSystems.PowerSystemTableData(
        RTS_DIR,
        100.0,
        DESCRIPTORS;
        generator_mapping_file = joinpath(RTS_DIR, "generator_mapping.yaml"),
        timeseries_metadata_file = write_filtered_pointers(RTS_DIR, out_dir),
    )
    sys = System(data; time_series_in_memory = true)

    to_json(sys, OUT; force = true)

    manifest = structure(sys)
    manifest_path = joinpath(out_dir, "rts_psy5_structure.json")
    open(manifest_path, "w") do io
        JSON.print(io, manifest, 2)
    end

    for type_name in sort!(collect(keys(manifest["components"])))
        println(rpad(type_name, 34), length(manifest["components"][type_name]))
    end
    println(rpad("TOTAL", 34), sum(length.(values(manifest["components"]))))
    println(rpad("time series", 34), length(manifest["time_series"]))
    @info "wrote" system = abspath(OUT) manifest = manifest_path
    return
end

main()
