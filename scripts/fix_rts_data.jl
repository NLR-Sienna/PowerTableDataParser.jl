#!/usr/bin/env julia
#
# Correct known data defects in an RTS-GMLC source tree.
#
# Reads an RTS_GMLC directory, writes a corrected copy, and reports every change
# so the edits can be applied upstream. The input is never modified: the Julia
# artifact directories are read-only, and the point is to produce a patch you can
# review rather than to mutate a fixture in place.
#
# Usage:
#   julia --project=test scripts/fix_rts_data.jl <input_dir> <output_dir>
#   julia --project=test scripts/fix_rts_data.jl <input_dir>            # report only
#
# Defect 1 - gen.csv, `Base MVA` = 0 on synchronous condensers.
#   114/214/314_SYNC_COND_1 declare a zero equipment base while injecting
#   103-167 MVAr with QMax 200. Present in GridMod/RTS-GMLC v0.2.2
#   RTS_Data/SourceData/gen.csv, so it is upstream rather than a Sienna artifact.
#   A zero base is not a usable denominator and GridDB rejects it
#   (`CHECK (base_power > 0)`). Corrected to the machine's reactive rating,
#   max(|QMax MVAR|, |QMin MVAR|).
#
# Defect 2 - user_descriptors.yaml, `base_mva` mapped to the wrong column.
#   The Sienna fixture maps base_mva to `MATPOWER BaseMVA`, which is 100.0 for
#   every generator, and marks the line `#TODO just for testing`. The real
#   per-generator rating is the `Base MVA` column.

import CSV
import DataFrames

const SYNC_COND_TYPE = "SYNC_COND"

struct Change
    file::String
    row::String
    column::String
    from::String
    to::String
end

function _parse_magnitude(value)
    if value === missing || isempty(strip(value)) || strip(value) == "NA"
        return 0.0
    end
    parsed = tryparse(Float64, strip(value))
    if isnothing(parsed)
        return 0.0
    end
    return abs(parsed)
end

"""
Set `Base MVA` from the reactive rating wherever it is zero or blank.

Returns the corrected dataframe and the list of changes.
"""
function fix_generator_base_mva(df::DataFrames.DataFrame)
    changes = Change[]
    for column in ("Base MVA", "QMax MVAR", "QMin MVAR", "GEN UID", "Unit Type")
        if !(column in DataFrames.names(df))
            error("gen.csv is missing the '$column' column")
        end
    end

    for row in DataFrames.eachrow(df)
        current = _parse_magnitude(row["Base MVA"])
        if current > 0.0
            continue
        end

        rating = max(_parse_magnitude(row["QMax MVAR"]), _parse_magnitude(row["QMin MVAR"]))
        name = row["GEN UID"]
        if iszero(rating)
            @warn "No reactive rating to derive a base from; leaving as-is" generator = name
            continue
        end

        original = row["Base MVA"]
        replacement = string(Int(round(rating)))
        row["Base MVA"] = replacement
        push!(changes, Change("gen.csv", name, "Base MVA", string(original), replacement))
    end
    return df, changes
end

"""Repoint `base_mva` at the real per-generator column."""
function fix_descriptor_base_mva(text::AbstractString)
    changes = Change[]
    marker = "custom_name: MATPOWER BaseMVA, name: base_mva"
    if !occursin(marker, text)
        return text, changes
    end
    corrected = replace(
        text,
        r"- \{custom_name: MATPOWER BaseMVA, name: base_mva\}[^\n]*" =>
            "- {custom_name: Base MVA, name: base_mva}",
    )
    push!(
        changes,
        Change(
            "user_descriptors.yaml",
            "base_mva",
            "custom_name",
            "MATPOWER BaseMVA",
            "Base MVA",
        ),
    )
    return corrected, changes
end

function report(changes::Vector{Change})
    if isempty(changes)
        println("No changes needed.")
        return
    end
    println("$(length(changes)) change(s):")
    for c in changes
        println("  $(c.file)  $(c.row)  $(c.column): $(c.from) -> $(c.to)")
    end
    return
end

function fix_rts_data(input_dir::AbstractString, output_dir)
    isdir(input_dir) || error("input directory not found: $input_dir")
    changes = Change[]

    gen_path = joinpath(input_dir, "gen.csv")
    isfile(gen_path) || error("gen.csv not found in $input_dir")
    # Read every column as a string so untouched cells round-trip byte-for-byte
    # instead of being reformatted by the CSV writer.
    gen = DataFrames.DataFrame(CSV.File(gen_path; types = String))
    gen, gen_changes = fix_generator_base_mva(gen)
    append!(changes, gen_changes)

    descriptor_path = joinpath(input_dir, "user_descriptors.yaml")
    descriptor_text = ""
    if isfile(descriptor_path)
        descriptor_text, descriptor_changes =
            fix_descriptor_base_mva(read(descriptor_path, String))
        append!(changes, descriptor_changes)
    end

    report(changes)

    if isnothing(output_dir)
        println("\nReport only. Pass an output directory to write the corrected tree.")
        return changes
    end

    mkpath(output_dir)
    cp(input_dir, output_dir; force = true)
    # cp preserves the artifact's read-only bits.
    for (root, _, files) in walkdir(output_dir), file in files
        chmod(joinpath(root, file), 0o644)
    end

    CSV.write(joinpath(output_dir, "gen.csv"), gen)
    if !isempty(descriptor_text)
        write(joinpath(output_dir, "user_descriptors.yaml"), descriptor_text)
    end
    println("\nWrote corrected tree to $output_dir")
    return changes
end

if abspath(PROGRAM_FILE) == @__FILE__
    if length(ARGS) < 1
        println("Usage: julia --project=test scripts/fix_rts_data.jl <input_dir> [output_dir]")
        exit(1)
    end
    output = nothing
    if length(ARGS) >= 2
        output = ARGS[2]
    end
    fix_rts_data(ARGS[1], output)
end
