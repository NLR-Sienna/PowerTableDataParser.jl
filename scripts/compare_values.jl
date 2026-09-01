# Compare the numbers, not just the shape: every field the OpenAPI document and
# the psy5 system both carry, for every component they share.
#
# This reads the COMPONENT_BASE document, so both sides are in PowerSystems' storage
# convention and the comparison is direct. Run it after:
#   julia --project=scripts/psy5_reference scripts/build_psy5_reference.jl
#   julia --project=test data/emit_rts.jl
#   julia --project=test scripts/compare_values.jl [psy5.json] [device_base.json]
#
# Exits non-zero on any value difference that is not one of the known data fixes
# declared below.

import JSON

const REFERENCE = get(ARGS, 1, joinpath(@__DIR__, "..", "data", "rts_psy5.json"))
const DOCUMENT = get(ARGS, 2, joinpath(@__DIR__, "..", "data", "rts_device_base.json"))

const TOLERANCE = 1e-9

const TYPE_ALIASES = Dict(
    "TapTransformer" => "TwoWindingTransformer",
    "Transformer2W" => "TwoWindingTransformer",
    "PhaseShiftingTransformer" => "TwoWindingTransformer",
)

"""
psy5 field names the psy6 schemas renamed.

Keyed by the psy5 name; the value is what to look for in the document.
"""
const FIELD_ALIASES = Dict(
    "primary_shunt" => "magnetizing_shunt",
    "tap_limits" => "control_limits",
    # PSS/E states a controlled quantity as a band, so psy5's scalar setpoint is
    # the band whose ends coincide. `close_enough` compares them on those terms.
    "voltage_setpoint" => "controlled_quantity_limits",
)

"""
Differences that are the point of the exercise rather than a defect.

Each entry is a (type, field) pair whose disagreement is explained, so a
disagreement anywhere else cannot hide among them.
"""
const KNOWN_DIFFERENCES = Dict(
    ("Line", "angle_limits") =>
        "psy5 clamps line angle limits to ±π/2 in sanitize_angle_limits! when it " *
        "builds the System; both descriptors state ±π, which is what the document " *
        "records. Validation of that kind belongs to whatever consumes the document.",
    ("Area", "peak_active_power") =>
        "psy5 leaves area peaks at zero though the bus rows carry the load; the " *
        "document sums them, exactly as both sides already do for zones.",
    ("Area", "peak_reactive_power") =>
        "psy5 leaves area peaks at zero though the bus rows carry the load; the " *
        "document sums them, exactly as both sides already do for zones.",
    ("VariableReserve", "time_frame") =>
        "psy5 stores the table's seconds unconverted in a field its own docstring " *
        "calls minutes, so RTS's 10-minute products read as 600. The schema declares " *
        "min and the document converts, so this is a fix rather than a divergence.",
)

mutable struct Report
    compared::Int
    matched::Int
    failures::Int
end

"""Numeric fields of a psy5 component, flattened one level."""
function reference_values(component)
    values = Dict{String, Any}()
    for (field, value) in component
        startswith(field, "__") && continue
        record!(values, field, value)
    end
    return values
end

record!(values, field::AbstractString, value::Bool) = (values[field] = value; nothing)
record!(values, field::AbstractString, value::Real) = (values[field] = Float64(value); nothing)

function record!(values, field::AbstractString, value::AbstractDict)
    numeric = Dict{String, Float64}()
    for (key, inner) in value
        if inner isa Real && !(inner isa Bool)
            numeric[key] = Float64(inner)
        end
    end
    if !isempty(numeric) && length(numeric) == length(value)
        values[field] = numeric
    end
    return
end

record!(values, field::AbstractString, value) = nothing

"""
Document values for a component, with the split-out circuit merged back in.

psy6 moves a transformer's electrical parameters onto a `TransformerCircuit`;
psy5 keeps them on the transformer, so the pair is compared as one.
"""
function document_values(item, circuits)
    values = reference_values(item)
    if haskey(item, "circuit") && haskey(circuits, item["circuit"])
        for (field, value) in reference_values(circuits[item["circuit"]])
            values[field] = value
        end
    end
    return values
end

function close_enough(left::Real, right::Real)
    return isapprox(left, right; rtol = TOLERANCE, atol = TOLERANCE)
end

close_enough(left::Bool, right::Bool) = left == right

function close_enough(left::AbstractDict, right::AbstractDict)
    keys(left) == keys(right) || return false
    return all(close_enough(left[k], right[k]) for k in keys(left))
end

"""
A setpoint equals a band whose ends both sit on it.

psy5 names a single target voltage; the schemas state the controlled quantity as
VMA/VMI, and holding a value exactly is the band that begins and ends there.
"""
function close_enough(left::Real, right::AbstractDict)
    if Set(keys(right)) != Set(["min", "max"])
        return false
    end
    return close_enough(left, right["min"]) && close_enough(left, right["max"])
end

close_enough(left, right) = false

function main()
    reference = JSON.parsefile(REFERENCE)["data"]["components"]
    doc = JSON.parsefile(DOCUMENT)

    component_power_units = Set(
        String(item["power_units"])
        for (_type, items) in doc["components"] for
        item in items if haskey(item, "power_units")
    )
    if component_power_units != Set(["COMPONENT_BASE"])
        println(
            "This compares against PowerSystems' storage convention, so every " *
            "power-bearing component must be COMPONENT_BASE; got $component_power_units. " *
            "Build it with build_openapi_system(data; power_units = \"COMPONENT_BASE\").",
        )
        return 1
    end

    circuits = Dict(c["id"] => c for c in get(doc["components"], "TransformerCircuit", []))
    ours = Dict{Tuple{String, String}, Any}()
    for (type_name, items) in doc["components"]
        for item in items
            haskey(item, "name") || continue
            ours[(type_name, item["name"])] = document_values(item, circuits)
        end
    end

    report = Report(0, 0, 0)
    differences = Dict{Tuple{String, String}, Vector{String}}()
    only_psy5 = Dict{Tuple{String, String}, Int}()
    compared_fields = Set{Tuple{String, String}}()

    for component in reference
        psy5_type = component["__metadata__"]["type"]
        type_name = get(TYPE_ALIASES, psy5_type, psy5_type)
        haskey(component, "name") || continue
        key = (type_name, component["name"])
        if !haskey(ours, key)
            continue
        end
        theirs = reference_values(component)
        mine = ours[key]
        for (field, value) in theirs
            document_field = get(FIELD_ALIASES, field, field)
            if !haskey(mine, document_field)
                only_psy5[(type_name, field)] = get(only_psy5, (type_name, field), 0) + 1
                continue
            end
            report.compared += 1
            push!(compared_fields, (type_name, document_field))
            if close_enough(value, mine[document_field])
                report.matched += 1
            else
                push!(
                    get!(differences, (type_name, document_field), String[]),
                    "$(component["name"]): psy5 $(value), document $(mine[document_field])",
                )
            end
        end
    end

    println("compared $(report.compared) values across $(length(ours)) named components")
    println()

    for key in sort!(collect(keys(differences)))
        type_name, field = key
        examples = differences[key]
        if haskey(KNOWN_DIFFERENCES, key)
            println("known $(type_name).$(field) differs on $(length(examples)): $(KNOWN_DIFFERENCES[key])")
            continue
        end
        report.failures += length(examples)
        println("FAIL  $(type_name).$(field): $(length(examples)) differ")
        for example in examples[1:min(3, length(examples))]
            println("        ", example)
        end
    end

    if !isempty(only_psy5)
        println()
        println("psy5 fields with no counterpart in the schemas:")
        for key in sort!(collect(keys(only_psy5)))
            println("      $(key[1]).$(key[2]) ($(only_psy5[key]))")
        end
    end

    only_document = Dict{Tuple{String, String}, Int}()
    for ((type_name, _), values) in ours
        for field in keys(values)
            field == "id" && continue
            key = (type_name, field)
            if !(key in compared_fields)
                only_document[key] = get(only_document, key, 0) + 1
            end
        end
    end
    if !isempty(only_document)
        println()
        println("document fields not compared (psy5 holds them as UUID references, or not at all):")
        for key in sort!(collect(keys(only_document)))
            println("      $(key[1]).$(key[2]) ($(only_document[key]))")
        end
    end

    println()
    if iszero(report.failures)
        println("VALUES MATCH: $(report.matched) of $(report.compared) compared values agree.")
        return 0
    end
    println("$(report.failures) value difference(s) not accounted for.")
    return 1
end

exit(main())
