# [Parse Tabular Data from .csv Files](@id table_data)

```@meta
CurrentModule = PowerTableDataParser
```

This guide walks through parsing a directory of CSV files into a
[`PowerSystemTableData`](@ref) object and handing it to `PowerSystems.jl` to
build a `System`. For the conceptual background on *how* the parser combines
CSV, YAML, and time-series inputs, see
[Parser Structure and Inputs](@ref structure).

## Minimal usage

If your CSV files already follow the PowerSystems-standard column names and
units, a minimal invocation looks like this:

```julia
using PowerTableDataParser
using PowerSystems

data_dir = "/data/my-data-dir"
base_power = 100.0
descriptors = joinpath(data_dir, "user_descriptors.yaml")

data = PowerSystemTableData(data_dir, base_power, descriptors)
sys = System(data; time_series_in_memory = true)
```

This call will:

 1. Discover and read every `*.csv` in `data_dir` (and one level of
    sub-directories).
 2. Require that `bus.csv` exists; other category files are optional.
 3. Load `user_descriptors.yaml` and merge it with the built-in default
    descriptor [`power_system_inputs.json`](https://github.com/NLR-Sienna/PowerTableDataParser.jl/blob/main/src/power_system_inputs.json).
 4. Load the bundled default
    [`generator_mapping_cdm.yaml`](https://github.com/NLR-Sienna/PowerTableDataParser.jl/blob/main/src/generator_mapping_cdm.yaml)
    to resolve `(fuel, type)` pairs in `gen.csv` to concrete `Generator`
    subtypes.
 5. Look for a `timeseries_pointers.json` (or `.csv`) in `data_dir`; if found,
    attach it so `System` can load time series.

## Full usage with overrides

To override both the generator mapping and the time-series pointer file:

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
    generator_mapping_file = generator_mapping_file,
    timeseries_metadata_file = timeseries_metadata_file,
)
sys = System(data; time_series_in_memory = true)
```

Example configuration files can be found in the
[RTS-GMLC](https://github.com/GridMod/RTS-GMLC/) repository:

  - [user_descriptors.yaml](https://github.com/GridMod/RTS-GMLC/blob/master/RTS_Data/FormattedData/SIIP/user_descriptors.yaml)
  - [generator_mapping.yaml](https://github.com/GridMod/RTS-GMLC/blob/master/RTS_Data/FormattedData/SIIP/generator_mapping.yaml)
  - [timeseries_pointers.json](https://github.com/GridMod/RTS-GMLC/blob/master/RTS_Data/FormattedData/SIIP/timeseries_pointers.json)

## Supported categories

Components for each category must be defined in their own CSV file. The
following categories are currently supported:

  - `bus.csv` (**required**)
    
      + Columns named `area` and `zone` create a corresponding set of `Area`
        and `LoadZone` objects.
      + Columns named `max_active_power` or `max_reactive_power` create
        `PowerLoad` objects when nonzero values are encountered, and
        contribute to the `peak_active_power` / `peak_reactive_power` of the
        corresponding `LoadZone`.

  - `branch.csv`
  - `dc_branch.csv`
  - `gen.csv`
  - `load.csv`
  - `reserves.csv`
  - `storage.csv`

All of these files must reside in the directory passed to
[`PowerSystemTableData`](@ref), or inside a single level of alphabetical
sub-folders within it.

## [CSV data configurations](@id csv_data)

### [Custom construction of generators](@id csv_genmap)

`PowerTableDataParser` constructs concrete subtypes of `Generator` based on
the `fuel` and `type` columns in `gen.csv` and the `generator_mapping_file`.
The default file is [`src/generator_mapping_cdm.yaml`](https://github.com/NLR-Sienna/PowerTableDataParser.jl/blob/main/src/generator_mapping_cdm.yaml);
override it by passing your own via the `generator_mapping_file` keyword.

Each top-level key in the YAML is a target `Generator` subtype, and its value
is a list of `(fuel, type)` pairs that should map to that subtype:

```yaml
ThermalStandard:
  - {fuel: COAL, type: null}
  - {fuel: NG,   type: null}

RenewableDispatch:
  - {fuel: SOLAR, type: PV}
  - {fuel: WIND,  type: WIND}
```

A `null` `type` acts as a wildcard for any `type` value with that `fuel`.
Duplicate `(fuel, type)` entries raise an error.

### [Column names](@id csv_columns)

`PowerTableDataParser` provides an input-mapping layer so you can keep your
own column names. For example, when parsing raw data for a generator the
parser expects a column called `name`. If the raw data instead defines that
column as `GEN UID`, set the `custom_name` field under the `generator`
category in your `user_descriptors.yaml`:

```yaml
generator:
  - name: name
    custom_name: GEN UID
```

To build a complete `user_descriptors.yaml` from scratch, start from the
defaults defined in
[`src/power_system_inputs.json`](https://github.com/NLR-Sienna/PowerTableDataParser.jl/blob/main/src/power_system_inputs.json)
and copy the entries you need, adding `custom_name`, `unit`, or `unit_system`
overrides as appropriate. The user-specific customizations are intentionally
kept in YAML rather than JSON to make them easier to edit by hand. *Do not
edit the default JSON file.*

### [Per-unit conversion](@id csv_per_unit)

`PowerTableDataParser` defines whether it expects a column value to be
per-unit system base, per-unit device base, or in natural units via the
`unit_system` field in `power_system_inputs.json`. If it expects a per-unit
convention that differs from your values, set `unit_system` in
`user_descriptors.yaml` and the parser will automatically convert the values.

For example, if you have a `max_active_power` column stored in natural units
(MW) but `power_system_inputs.json` specifies `unit_system: device_base`, add
`unit_system: natural_units` in `user_descriptors.yaml` and the parser will
divide the value by the entry in the column identified by the
`base_reference` field in `power_system_inputs.json`. You can also override
`base_reference` by adding `base_reference: My Column` to make the device-base
per-unit conversion divide by `My Column` instead. System-base per-unit
conversions always divide by the `base_power` passed to the
`PowerSystemTableData` constructor.

### [Unit conversion](@id csv_units)

The parser supports a limited set of unit conversions. For example, if
`power_system_inputs.json` indicates a value's unit is `degree` but your
values are in radians, set `unit: radian` in your YAML file. Other valid
`unit` entries include `GW`, `GWh`, `MW`, `MWh`, `kW`, and `kWh`.

## Attaching time series

`PowerSystems.jl` requires a metadata file that associates components with
their time-series data. `PowerTableDataParser` accepts either a JSON or CSV
pointer file via the `timeseries_metadata_file` keyword; the default search
path is `joinpath(directory, "timeseries_pointers")`, with `.json` and `.csv`
tried in that order.

Each entry in the pointer file must provide:

  - `simulation` — user description of the simulation
  - `resolution` — resolution of the time series in seconds
  - `module` — module that defines the abstract type of the component
  - `category` — component type (`Bus`, `ElectricLoad`, `Generator`,
    `LoadZone`, `Reserve`)
  - `component_name` — name of the component
  - `name` — user-defined name for the time-series data
  - `normalization_factor` — `1.0` for pre-normalized data, `"Max"` to divide
    by the column max, or a numeric scaling factor
  - `scaling_factor_multiplier_module` — module that defines the scaling
    factor accessor
  - `scaling_factor_multiplier` — accessor function name
  - `data_file` — path to the time-series data file

The `module`, `category`, and `component_name` entries must be valid
arguments to `get_component(${module}.${category}, sys, $name)`. The
`scaling_factor_multiplier_module` and `scaling_factor_multiplier` entries
must be sufficient to return the scaling factor data via
`${scaling_factor_multiplier_module}.${scaling_factor_multiplier}(component)`.

See
[RTS-GMLC](https://github.com/GridMod/RTS-GMLC/blob/master/RTS_Data/FormattedData/SIIP/timeseries_pointers.json)
for a worked example.

!!! note "Time-series storage"
    
    By default `PowerSystems.jl` stores time-series data in HDF5 files and
    reads them on demand. Pass `time_series_in_memory = true` to `System`
    when your data fits in memory; pass `time_series_directory = X` to point
    the HDF5 store at a specific directory, or set the environment variable
    `SIENNA_TIME_SERIES_DIRECTORY`.

## Extending the tabular parser

This section is for developers who want to teach the parser about new
columns. It assumes familiarity with the sections above.

The key rule is: do not read hard-coded column names out of DataFrames. Use
the descriptor layer so PowerSystems-standard names stay decoupled from
whatever the user happens to call their column.

### Procedure

 1. Add an entry to the array of parameters for your category in
    [`src/power_system_inputs.json`](https://github.com/NLR-Sienna/PowerTableDataParser.jl/blob/main/src/power_system_inputs.json)
    following these rules:
    
     1. Use `snake_case` for `name`.
     2. `name` and `description` are required.
     3. Prefer a name that is generic and not dataset-specific.
     4. Define `unit` when applicable.
     5. If the parser should treat the value as system per-unit, set
        `system_per_unit: true`.

 2. If you maintain widely-used user descriptor files (e.g. the RTS-GMLC
    SIIP config), update them and submit pull requests so downstream users
    pick up the new field.
 3. Consume the new column in your parsing code like this:

```julia
function demo_bus_csv_parser!(data::PowerSystemTableData)
    for bus in iterate_rows(data, InputCategory.BUS)
        @show bus.name, bus.max_active_power, bus.max_reactive_power
    end
end
```

`iterate_rows` returns a `NamedTuple` whose fields are the `name` entries
defined in `power_system_inputs.json`, already translated from the user's
column names and unit conventions.

!!! warning "Deprecation"
    
    The tabular parser is in long-term maintenance mode. `PowerSystems.jl`
    will eventually move to a database-backed data layer, and new datasets
    are encouraged to ship a small custom Julia importer rather than depend
    on this parser. This package exists to keep existing CDM-based workflows
    working while that transition proceeds.
