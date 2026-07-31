# Check the OpenAPI document against the psy5 reference system: same components,
# same owners, same time series. Field values are not compared — psy5 stores per
# unit on a device base while the schemas store natural units, so equal structure
# is the strongest claim available here.
#
# Run:
#   julia --project=scripts/psy5_reference scripts/build_psy5_reference.jl
#   julia --project=test data/emit_rts.jl
#   julia --project=test scripts/compare_structure.jl [reference.json] [openapi.json]
#
# Exits non-zero if anything differs that is not one of the differences declared
# below. Those are declared as data so an unexpected one cannot pass as expected.

import JSON

const REFERENCE = get(ARGS, 1, joinpath(@__DIR__, "..", "data", "rts_psy5_structure.json"))
const DOCUMENT = get(ARGS, 2, joinpath(@__DIR__, "..", "data", "rts.json"))

"""
psy5 type names that psy6 renamed. The name of the component itself is preserved
across the rename, so these compare member-for-member.
"""
const TYPE_ALIASES = Dict(
    "TapTransformer" => "TwoWindingTransformer",
    "Transformer2W" => "TwoWindingTransformer",
    "PhaseShiftingTransformer" => "TwoWindingTransformer",
)

"""
Types the psy6 schemas split out of a psy5 component.

psy5's transformer carries its own electrical parameters; psy6 moves them to a
`TransformerCircuit` the transformer references. The circuit has no name, so it
is checked by count against the type it was split from rather than by name.
"""
const SPLIT_TYPES = Dict("TwoWindingTransformer" => "TransformerCircuit")

"""
Time series expected on the psy5 side only.

Empty: the document reproduces psy5's fan-out of a zone's load series to the
loads beneath it, so every series psy5 holds should now have a counterpart.
"""
const DERIVED_SERIES = Tuple{String, String}[]

"""The resolution psy5 was given; it cannot hold two per series."""
const REFERENCE_RESOLUTION = "PT3600S"

mutable struct Report
    failures::Int
end

function fail(report::Report, message::AbstractString)
    report.failures += 1
    println("FAIL  ", message)
    return
end

function ok(message::AbstractString)
    println("ok    ", message)
    return
end

function note(message::AbstractString)
    println("note  ", message)
    return
end

"""Component names per type, with `Arc` named by the buses it joins."""
function document_components(doc)
    bus_names = Dict{Int, String}()
    for bus in get(doc["components"], "ACBus", [])
        bus_names[bus["id"]] = bus["name"]
    end

    components = Dict{String, Vector{String}}()
    for (type_name, items) in doc["components"]
        names = String[]
        for item in items
            push!(names, component_name(type_name, item, bus_names))
        end
        components[type_name] = sort!(names)
    end
    return components
end

function component_name(type_name::AbstractString, item, bus_names::Dict{Int, String})
    if type_name == "Arc"
        return string(bus_names[item["from_id"]], " -> ", bus_names[item["to_id"]])
    end
    if !haskey(item, "name")
        # TransformerCircuit and anything else the schemas leave unnamed is
        # compared by count, so an id keeps the entries distinct.
        return string(type_name, "#", item["id"])
    end
    return item["name"]
end

function compare_components(report::Report, reference, document)
    reference_mapped = Dict{String, Vector{String}}()
    for (type_name, names) in reference
        mapped = get(TYPE_ALIASES, type_name, type_name)
        if mapped != type_name
            note("$type_name is $mapped in psy6")
        end
        append!(get!(reference_mapped, mapped, String[]), names)
    end

    for type_name in sort!(collect(keys(reference_mapped)))
        expected = sort(reference_mapped[type_name])
        if !haskey(document, type_name)
            fail(report, "$type_name: absent from the document, $(length(expected)) expected")
            continue
        end
        found = document[type_name]
        missing_names = setdiff(Set(expected), Set(found))
        extra_names = setdiff(Set(found), Set(expected))
        if isempty(missing_names) && isempty(extra_names)
            ok("$type_name: $(length(found)) components match")
        else
            fail(
                report,
                "$type_name: $(length(missing_names)) missing, $(length(extra_names)) extra " *
                "(psy5 $(length(expected)), document $(length(found)))",
            )
            for name in sort!(collect(missing_names))[1:min(5, length(missing_names))]
                println("        missing: ", name)
            end
            for name in sort!(collect(extra_names))[1:min(5, length(extra_names))]
                println("        extra:   ", name)
            end
        end
    end

    accounted = Set(keys(reference_mapped))
    for (split_from, split_type) in SPLIT_TYPES
        if !haskey(document, split_type)
            continue
        end
        push!(accounted, split_type)
        expected = length(get(reference_mapped, split_from, String[]))
        found = length(document[split_type])
        if found == expected
            ok("$split_type: $found, one per $split_from (psy6 splits the series data out)")
        else
            fail(report, "$split_type: $found, expected one per $split_from ($expected)")
        end
    end

    for type_name in sort!(collect(setdiff(Set(keys(document)), accounted)))
        fail(report, "$type_name: $(length(document[type_name])) in the document, absent from psy5")
    end
    return
end

function series_key(entry)
    owner_type = get(TYPE_ALIASES, entry["owner_type"], entry["owner_type"])
    return (owner_type, entry["owner_name"], entry["name"])
end

function compare_time_series(report::Report, reference, doc, document_names)
    owner_names = Dict{Tuple{String, Int}, String}()
    for (type_name, names) in document_names
        for (ix, item) in enumerate(doc["components"][type_name])
            owner_names[(type_name, item["id"])] = component_name_of(type_name, item)
        end
    end

    ours = Dict{Tuple{String, String, String}, Vector{String}}()
    for association in doc["time_series_associations"]
        owner_type = association["owner_type"]
        key = (
            owner_type,
            owner_names[(owner_type, association["owner_id"])],
            association["name"],
        )
        push!(get!(ours, key, String[]), association["resolution"])
    end

    reference_keys = Set(series_key(entry) for entry in reference)
    derived = Set{Tuple{String, String, String}}()
    for entry in reference
        if (entry["owner_type"], entry["name"]) in DERIVED_SERIES
            push!(derived, series_key(entry))
        end
    end

    missing_keys = setdiff(setdiff(reference_keys, Set(keys(ours))), derived)
    if isempty(missing_keys)
        ok(
            "time series: all $(length(reference_keys) - length(derived)) psy5 series " *
            "the pointer file states are present",
        )
    else
        fail(report, "time series: $(length(missing_keys)) psy5 series absent from the document")
        for key in sort!(collect(missing_keys))[1:min(5, length(missing_keys))]
            println("        missing: ", key)
        end
    end

    if !isempty(derived)
        note(
            "time series: $(length(derived)) psy5 series are derived, not stated by the " *
            "pointer file (zone load fanned out to bus loads); not expected in the document",
        )
    end

    extra_keys = setdiff(Set(keys(ours)), reference_keys)
    if !isempty(extra_keys)
        fail(report, "time series: $(length(extra_keys)) document series unknown to psy5")
        for key in sort!(collect(extra_keys))[1:min(5, length(extra_keys))]
            println("        extra:   ", key)
        end
    end

    at_reference = count(r -> REFERENCE_RESOLUTION in r, values(ours))
    total = sum(length.(values(ours)))
    if at_reference == length(reference_keys) - length(derived)
        ok("time series: $at_reference at $REFERENCE_RESOLUTION, $total including the finer resolution")
    else
        fail(
            report,
            "time series: $at_reference at $REFERENCE_RESOLUTION, expected " *
            "$(length(reference_keys) - length(derived))",
        )
    end
    note(
        "time series: psy5 cannot hold the same series at two resolutions, so the " *
        "reference covers $REFERENCE_RESOLUTION only",
    )
    return
end

"""Name used for a document component when resolving a time series owner."""
function component_name_of(type_name::AbstractString, item)
    if haskey(item, "name")
        return item["name"]
    end
    return string(type_name, "#", item["id"])
end

function main()
    reference = JSON.parsefile(REFERENCE)
    doc = JSON.parsefile(DOCUMENT)

    println("psy5 reference : ", REFERENCE)
    println("  PowerSystems ", reference["powersystems_version"], ", PowerSystemCaseBuilder ",
        reference["powersystemcasebuilder_version"])
    println("  data         ", reference["rts_directory"])
    println("openapi document: ", DOCUMENT)
    println()

    report = Report(0)
    if reference["base_power"] == doc["base_power"]
        ok("base_power: $(doc["base_power"])")
    else
        fail(report, "base_power: psy5 $(reference["base_power"]), document $(doc["base_power"])")
    end

    document_names = document_components(doc)
    compare_components(report, reference["components"], document_names)
    println()
    compare_time_series(report, reference["time_series"], doc, document_names)

    println()
    if iszero(report.failures)
        println("STRUCTURE MATCHES: every psy5 component and stated time series is present.")
        return 0
    end
    println("$(report.failures) structural difference(s) not accounted for.")
    return 1
end

exit(main())
