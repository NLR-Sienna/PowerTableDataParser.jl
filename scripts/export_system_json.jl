"""
Export the RTS-GMLC system for manual verification.

Parses the RTS-GMLC table data into an OpenAPI document, reads it into a
`PowerSystems.System`, and writes it back out three ways:

  - `rts_openapi.json`         the parser's own document (+ `rts_openapi.h5` sidecar)
  - `rts_natural_units.json`   the System re-exported in natural units (MW, MVAr, MVA)
  - `rts.sns`                  the lossless Sienna archive

Usage:
    julia --project=test scripts/export_system_json.jl [output_dir]

Args:
    output_dir: Directory to write the files (default: ./system_exports)
"""

using PowerTableDataParser
using PowerSystems
import Pkg
using JSON
using Dates

const PDP = PowerTableDataParser
const PSY = PowerSystems

function _system_stats(sys::PSY.System)
    return Dict(
        "buses" => length(PSY.get_components(PSY.ACBus, sys)),
        "branches" => length(PSY.get_components(PSY.Branch, sys)),
        "generators" => length(PSY.get_components(PSY.Generator, sys)),
        "loads" => length(PSY.get_components(PSY.ElectricLoad, sys)),
        "storage" => length(PSY.get_components(PSY.Storage, sys)),
    )
end

function _report(path::AbstractString)
    println("✓ $(basename(path)) ($(round(filesize(path) / 1024 / 1024; digits = 2)) MB)")
    return
end

function main()
    output_dir = abspath(get(ARGS, 1, "system_exports"))
    mkpath(output_dir)

    # The test data artifact is bound in the test project, not beside this script.
    artifacts_toml = joinpath(@__DIR__, "..", "test", "Artifacts.toml")
    case_data = Pkg.Artifacts.ensure_artifact_installed("CaseData", artifacts_toml)
    data_dir = joinpath(case_data, "PowerSystemsTestData-5.0-dev3")
    rts_gmlc_dir = joinpath(data_dir, "RTS_GMLC")
    descriptors =
        joinpath(@__DIR__, "..", "test", "descriptors", "rts_user_descriptors.yaml")

    println("Loading RTS-GMLC data from: $rts_gmlc_dir")
    pst_data = PDP.PowerSystemTableData(rts_gmlc_dir, 100.0, descriptors)

    document_file = joinpath(output_dir, "rts_openapi.json")
    PDP.to_json(PDP.build_openapi_system(pst_data), document_file; force = true)
    _report(document_file)

    sys = PSY.from_file(document_file)
    stats = _system_stats(sys)
    println("✓ System read back: $stats")

    natural_file = joinpath(output_dir, "rts_natural_units.json")
    PSY.to_file(sys, natural_file; units = PSY.NU, force = true, pretty = true)
    _report(natural_file)

    archive_file = joinpath(output_dir, "rts" * PSY.SYSTEM_ARCHIVE_EXTENSION)
    PSY.to_file(sys, archive_file; force = true)
    _report(archive_file)

    metadata_file = joinpath(output_dir, "export_metadata.json")
    metadata = Dict(
        "export_date" => string(now()),
        "source" => "RTS-GMLC test data",
        "base_power_mva" => pst_data.base_power,
        "system_stats" => stats,
        "files" => Dict(
            "openapi_document" => basename(document_file),
            "natural_units" => basename(natural_file),
            "archive" => basename(archive_file),
        ),
    )
    open(metadata_file, "w") do io
        JSON.print(io, metadata, 2)
    end
    _report(metadata_file)
    println("Output directory: $output_dir")
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
