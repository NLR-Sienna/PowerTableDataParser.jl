"""
Export system data to JSON in both unit systems for manual verification.

This script loads test data from RTS-GMLC using PowerTableDataParser and exports
the resulting system to JSON files in both SI and natural gas unit systems.

Usage:
    julia --project=. scripts/export_system_json.jl [output_dir]

Args:
    output_dir: Directory to write JSON files (default: ./system_exports)
"""

using PowerTableDataParser
using PowerSystems
using LazyArtifacts
using JSON
using Dates

const PDP = PowerTableDataParser
const PSY = PowerSystems

function main()
    output_dir = get(ARGS, 1, "system_exports")
    mkpath(output_dir)

    println("=" ^ 70)
    println("System JSON Export for Manual Verification")
    println("=" ^ 70)
    println()

    # Load test data paths
    data_dir = joinpath(artifact"CaseData", "PowerSystemsTestData-5.0-dev3")
    rts_gmlc_dir = joinpath(data_dir, "RTS_GMLC")
    descriptors = joinpath(@__DIR__, "..", "test", "descriptors", "rts_user_descriptors.yaml")

    println("Loading RTS-GMLC data from: $rts_gmlc_dir")
    println("Using descriptors: $descriptors")
    println()

    # Load PowerSystemTableData
    println("Loading PowerSystemTableData...")
    pst_data = PDP.PowerSystemTableData(rts_gmlc_dir, 100.0, descriptors)
    println("✓ Loaded $(length(pst_data.category_to_df)) categories")

    for (category, df) in pst_data.category_to_df
        println("  - $category: $(nrow(df)) rows")
    end
    println()

    # Create PowerSystem
    println("Creating PowerSystem from table data...")
    try
        sys = PSY.System(pst_data)
        println("✓ System created successfully")
        println("  - Buses: $(length(PSY.get_components(PSY.Bus, sys)))")
        println("  - Branches: $(length(PSY.get_components(PSY.Branch, sys)))")
        println("  - Generators: $(length(PSY.get_components(PSY.Generator, sys)))")
        println("  - Loads: $(length(PSY.get_components(PSY.Load, sys)))")
        println()

        # Export in SI units
        si_file = joinpath(output_dir, "system_si_units.json")
        println("Exporting system in SI units to: $si_file")
        PSY.to_json(si_file, sys; units=PSY.UnitSystem.SI_UNITS)
        si_size = filesize(si_file)
        println("✓ SI units export complete ($(round(si_size / 1024 / 1024; digits=2)) MB)")
        println()

        # Export in natural gas units
        ng_file = joinpath(output_dir, "system_natural_gas_units.json")
        println("Exporting system in natural gas units to: $ng_file")
        PSY.to_json(ng_file, sys; units=PSY.UnitSystem.NATURAL_GAS_UNITS)
        ng_size = filesize(ng_file)
        println("✓ Natural gas units export complete ($(round(ng_size / 1024 / 1024; digits=2)) MB)")
        println()

        # Create metadata file
        metadata_file = joinpath(output_dir, "export_metadata.json")
        metadata = Dict(
            "export_date" => string(now()),
            "source" => "RTS-GMLC test data",
            "base_power_mva" => pst_data.base_power,
            "system_stats" => Dict(
                "buses" => length(PSY.get_components(PSY.Bus, sys)),
                "branches" => length(PSY.get_components(PSY.Branch, sys)),
                "generators" => length(PSY.get_components(PSY.Generator, sys)),
                "loads" => length(PSY.get_components(PSY.Load, sys)),
                "storage" => length(PSY.get_components(PSY.Storage, sys)),
            ),
            "files" => Dict(
                "si_units" => "system_si_units.json",
                "natural_gas_units" => "system_natural_gas_units.json",
            ),
        )

        open(metadata_file, "w") do io
            JSON.print(io, metadata; indent=2)
        end
        println("✓ Metadata file created: $metadata_file")
        println()

        println("=" ^ 70)
        println("Export Complete")
        println("=" ^ 70)
        println("Output directory: $output_dir")
        println()
        println("Files for manual verification:")
        println("  1. system_si_units.json")
        println("  2. system_natural_gas_units.json")
        println("  3. export_metadata.json")
        println()

    catch e
        println("ERROR: Failed to create system")
        println(e)
        rethrow()
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
