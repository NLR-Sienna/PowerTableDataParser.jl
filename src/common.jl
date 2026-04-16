# copied from PowerSystems/src/parsers/common.jl

const GENERATOR_MAPPING_FILE_CDM =
    joinpath(dirname(pathof(PowerTableDataParser)), "generator_mapping_cdm.yaml")

const DEFAULT_BASE_MVA = 100.0

"""Return a dict where keys are a tuple of input parameters (fuel, unit_type) and values are
generator types."""
function get_generator_mapping(filename::String)
    genmap = open(filename) do file
        YAML.load(file)
    end

    mappings = Dict{NamedTuple, String}()
    for (gen_type, vals) in genmap
        if gen_type == "GenericBattery"
            @warn "GenericBattery type is no longer supported. The new type is EnergyReservoirStorage"
            gen = "EnergyReservoirStorage"
        else
            gen = gen_type
        end
        for val in vals
            key = (fuel = val["fuel"], unit_type = val["type"])
            if haskey(mappings, key)
                error("duplicate generator mappings: $gen $(key.fuel) $(key.unit_type)")
            end
            mappings[key] = gen
        end
    end

    return mappings
end
