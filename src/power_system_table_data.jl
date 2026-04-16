# power_system_inputs.json is used in PSY for things other than parsing
# so for now the json file is copied in both repos, however the constant
# POWER_SYSTEM_DESCRIPTOR_FILE is only needed here, so its commented out
# of PSY
const POWER_SYSTEM_DESCRIPTOR_FILE =
    joinpath(dirname(pathof(PowerTableDataParser)), "power_system_inputs.json")

# constant INPUT_CATEGORY_NAMES and IS.@scoped_enum(InputCategory...) are
# used here and in PSY, so for now they're both defined in both repos
const INPUT_CATEGORY_NAMES = [
    ("branch", InputCategory.BRANCH),
    ("bus", InputCategory.BUS),
    ("dc_branch", InputCategory.DC_BRANCH),
    ("gen", InputCategory.GENERATOR),
    ("load", InputCategory.LOAD),
    ("reserves", InputCategory.RESERVE),
    ("storage", InputCategory.STORAGE),
]

# Convert InputCategory enum to Symbol key for dictionary lookup.
# Using Symbol keys avoids type incompatibility with PowerSystems.jl's InputCategory.
_category_key(category::InputCategory) = Symbol(string(category))

struct PowerSystemTableData
    base_power::Float64
    category_to_df::Dict{Symbol, DataFrames.DataFrame}
    timeseries_metadata_file::Union{String, Nothing}
    directory::String
    user_descriptors::Dict
    descriptors::Dict
    generator_mapping::Dict{NamedTuple, String}
end

function PowerSystemTableData(
    data::Dict{String, Any},
    directory::String,
    user_descriptors::Union{String, Dict},
    descriptors::Union{String, Dict},
    generator_mapping::Dict;
    timeseries_metadata_file = joinpath(directory, "timeseries_pointers"),
)
    category_to_df = Dict{Symbol, DataFrames.DataFrame}()

    if !haskey(data, "bus")
        throw(DataFormatError("key 'bus' not found in input data"))
    end

    if !haskey(data, "base_power")
        @warn "key 'base_power' not found in input data; using default=$(DEFAULT_BASE_MVA)"
    end
    base_power = get(data, "base_power", DEFAULT_BASE_MVA)

    for (name, category) in INPUT_CATEGORY_NAMES
        val = get(data, name, nothing)
        if isnothing(val)
            @debug "key '$name' not found in input data, set to nothing" _group =
                IS.LOG_GROUP_PARSING
        else
            # Use Symbol key for compatibility with PowerSystems.jl
            category_to_df[Symbol(string(category))] = val
        end
    end

    if !isfile(timeseries_metadata_file)
        if isfile(string(timeseries_metadata_file, ".json"))
            timeseries_metadata_file = string(timeseries_metadata_file, ".json")
        elseif isfile(string(timeseries_metadata_file, ".csv"))
            timeseries_metadata_file = string(timeseries_metadata_file, ".csv")
        else
            timeseries_metadata_file = nothing
        end
    end

    if user_descriptors isa AbstractString
        user_descriptors = _read_config_file(user_descriptors)
    end

    if descriptors isa AbstractString
        descriptors = _read_config_file(descriptors)
    end

    return PowerSystemTableData(
        base_power,
        category_to_df,
        timeseries_metadata_file,
        directory,
        user_descriptors,
        descriptors,
        generator_mapping,
    )
end

"""
Reads in all the data stored in csv files in a `directory`

!!! warning

    This parser is planned for deprecation. `PowerSystems.jl` will be
    moving to a database solution for handling data. There are plans to eventually include
    utility functions to translate from .csv files to the database, but there will probably
    be a gap in support. **Users are recommended to write their own custom Julia code to
    import data from their unique data formats, rather than relying on this parsing
    code.** See [How-to Build a `System` from CSV Files](@ref system_from_csv) for an example.

# Arguments
- `directory::AbstractString`: directory containing CSV files
- `base_power::Float64`: base power for [`System`](@ref)
- `user_descriptor_file::AbstractString`: customized input descriptor file. [Example](https://github.com/NREL-Sienna/PowerSystemsTestData/blob/master/RTS_GMLC/user_descriptors.yaml)
- `descriptor_file=POWER_SYSTEM_DESCRIPTOR_FILE`: `PowerSystems.jl` descriptor file. [Default](https://github.com/NREL-Sienna/PowerSystems.jl/blob/main/src/descriptors/power_system_inputs.json)
- `generator_mapping_file=GENERATOR_MAPPING_FILE_CDM`: generator mapping configuration file. [Default](https://github.com/NREL-Sienna/PowerSystems.jl/blob/main/src/parsers/generator_mapping_cdm.yaml)
- `timeseries_metadata_file = joinpath(directory, "timeseries_pointers")`: Time series pointers .json file. [Example](https://github.com/NREL-Sienna/PowerSystemsTestData/blob/master/RTS_GMLC/timeseries_pointers.json)

The general format for data in the `directory` is:
- bus.csv (required)
    + columns specifying `area` and `zone` will create a corresponding set of `Area` and `LoadZone` objects.
    + columns specifying `max_active_power` or `max_reactive_power` will create `PowerLoad` objects when nonzero values are encountered and will contribute to the `peak_active_power` and `peak_reactive_power` values for the
        corresponding `LoadZone` object.
- branch.csv
- dc_branch.csv
- gen.csv
- load.csv
- reserves.csv
- storage.csv

# Custom construction of generators

Each generator will be defined as a concrete subtype of [`Generator`](@ref),
based on the `fuel` and `type` columns in `gen.csv` and the `generator_mapping_file`.
The default mapping file
is [`src/parsers/generator_mapping.yaml`](https://github.com/NREL-Sienna/PowerSystems.jl/blob/main/src/parsers/generator_mapping.yaml). You can override this behavior by specifying your own file.

# Custom Column names

`PowerSystems` provides am input mapping capability that allows you to keep your own
column names. For example, when parsing raw data for a generator the code expects a column
called `name`. If the raw data instead defines that column as `GEN UID` then
you can change the `custom_name` field under the `generator` category to
`GEN UID` in your YAML file.

To enable the parsing of a custom set of csv files, you can generate a configuration
file (such as `user_descriptors.yaml`) from the defaults, which are stored
in [`src/descriptors/power_system_inputs.json`](https://github.com/NREL-Sienna/PowerSystems.jl/blob/main/src/descriptors/power_system_inputs.json).

```python
python ./bin/generate_config_file.py ./user_descriptors.yaml
```

Next, edit this file with your customizations.

Note that the user-specific customizations are stored in YAML rather than JSON
to allow for easier editing. The next few sections describe changes you can
make to this YAML file.  Do not edit the default JSON file.

## Per-unit conversion

`PowerSystems` defines whether it expects a column value to be per-unit system base,
per-unit device base, or natural units in `power_system_inputs.json`. If it expects a
per-unit convention that differs from your values then you can set the `unit_system` in
`user_descriptors.yaml` and `PowerSystems` will automatically convert the values. For
example, if you have a `max_active_power` value stored in natural units (MW), but
`power_system_inputs.json` specifies `unit_system: device_base`, you can enter
`unit_system: natural_units` in `user_descriptors.yaml` and `PowerSystems` will divide
the value by the value of the corresponding entry in the column identified by the
`base_reference` field in `power_system_inputs.json`. You can also override the
`base_reference` setting by adding `base_reference: My Column` to make device base
per-unit conversion by dividing the value by the entry in `My Column`. System base
per-unit conversions always divide the value by the system `base_power` value
instantiated when constructing a `System`.

`PowerSystems` provides a limited set of unit conversions. For example, if
`power_system_inputs.json` indicates that a value's unit is degrees but
your values are in radians then you can set `unit: radian` in
your YAML file. Other valid `unit` entries include `GW`, `GWh`, `MW`, `MWh`, `kW`,
and `kWh`.

# Examples
```julia
data_dir = "/data/my-data-dir"
base_power = 100.0
descriptors = "./user_descriptors.yaml"
timeseries_metadata_file = "./timeseries_pointers.json"
generator_mapping_file = "./generator_mapping.yaml"
data = PowerSystemTableData(
    data_dir,
    base_power,
    descriptors;
    timeseries_metadata_file = timeseries_metadata_file,
    generator_mapping_file = generator_mapping_file,
)
sys = System(data; time_series_in_memory = true)
```
"""
function PowerSystemTableData(
    directory::AbstractString,
    base_power::Float64,
    user_descriptor_file::AbstractString;
    descriptor_file = POWER_SYSTEM_DESCRIPTOR_FILE,
    generator_mapping_file = GENERATOR_MAPPING_FILE_CDM,
    timeseries_metadata_file = joinpath(directory, "timeseries_pointers"),
)
    files = readdir(directory)
    REGEX_DEVICE_TYPE = r"(.*?)\.csv"
    REGEX_IS_FOLDER = r"^[A-Za-z]+$"
    data = Dict{String, Any}()

    if length(files) == 0
        error("No files in the folder")
    else
        data["base_power"] = base_power
    end

    encountered_files = 0
    for d_file in files
        try
            if match(REGEX_IS_FOLDER, d_file) !== nothing
                @info "Parsing csv files in $d_file ..."
                d_file_data = Dict{String, Any}()
                for file in readdir(joinpath(directory, d_file))
                    if match(REGEX_DEVICE_TYPE, file) !== nothing
                        @info "Parsing csv data in $file ..."
                        encountered_files += 1
                        fpath = joinpath(directory, d_file, file)
                        raw_data = DataFrames.DataFrame(CSV.File(fpath))
                        d_file_data[split(file, r"[.]")[1]] = raw_data
                    end
                end

                if length(d_file_data) > 0
                    data[d_file] = d_file_data
                    @info "Successfully parsed $d_file"
                end

            elseif match(REGEX_DEVICE_TYPE, d_file) !== nothing
                @info "Parsing csv data in $d_file ..."
                encountered_files += 1
                fpath = joinpath(directory, d_file)
                raw_data = DataFrames.DataFrame(CSV.File(fpath))
                data[split(d_file, r"[.]")[1]] = raw_data
                @info "Successfully parsed $d_file"
            end
        catch ex
            @error "Error occurred while parsing $d_file" exception = ex
            throw(ex)
        end
    end
    if encountered_files == 0
        error("No csv files or folders in $directory")
    end

    generator_mapping = Dict{NamedTuple, String}()
    try
        generator_mapping = get_generator_mapping(generator_mapping_file)
    catch e
        @error "Error loading generator mapping $(generator_mapping_file)"
        rethrow(e)
    end

    return PowerSystemTableData(
        data,
        directory,
        user_descriptor_file,
        descriptor_file,
        generator_mapping;
        timeseries_metadata_file = timeseries_metadata_file,
    )
end

function _read_config_file(file_path::String)
    return open(file_path) do io
        data = YAML.load(io)
        # Use Symbol keys for compatibility with PowerSystems.jl
        config_data = Dict{Symbol, Vector}()
        for (key, val) in data
            # TODO: need to change user_descriptors.yaml to use reserve instead.
            if key == "reserves"
                key = "reserve"
            end
            config_data[Symbol(uppercase(key))] = val
        end
        return config_data
    end
end
