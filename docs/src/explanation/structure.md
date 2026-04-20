# [Parser Structure and Inputs](@id structure)

```@meta
CurrentModule = PowerTableDataParser
```

This page explains *how* `PowerTableDataParser.jl` turns a directory of
spreadsheet-style inputs into a [`PowerSystemTableData`](@ref) object. It is
meant to be read once to build a mental model of the pieces involved; the
[Parse Tabular Data from .csv Files](@ref table_data) how-to covers the
step-by-step mechanics.

## The four kinds of input

Building a `PowerSystemTableData` requires four kinds of input:

 1. **CSV files** — one per component category (`bus.csv`, `gen.csv`, ...).
    These carry the actual numerical and string data for each component.
 2. **A user descriptor YAML** (`user_descriptors.yaml`) — tells the parser how
    *your* column names and units map onto the PowerSystems-standard field
    names and per-unit conventions.
 3. **A generator mapping YAML** (`generator_mapping.yaml`) — tells the parser
    which concrete `Generator` subtype to instantiate for each
    `(fuel, unit_type)` pair in `gen.csv`.
 4. **A time-series pointer file** (`timeseries_pointers.json` or `.csv`,
    optional) — associates components with time-series data on disk.

In addition, the package ships a built-in **default descriptor JSON**
([`power_system_inputs.json`](https://github.com/NLR-Sienna/PowerTableDataParser.jl/blob/main/src/power_system_inputs.json))
that defines the PowerSystems-standard schema. You almost never edit this file
directly: the user descriptor YAML overrides entries in it.

## The parsing flow

At a high level, construction of `PowerSystemTableData(directory, base_power,
user_descriptor_file; ...)` proceeds in four phases:

```text
 ┌─────────────────┐    ┌──────────────────┐    ┌──────────────────────┐
 │  directory/     │    │ user_descriptors │    │ generator_mapping    │
 │  ├─ bus.csv     │    │  .yaml           │    │  .yaml               │
 │  ├─ branch.csv  │    │ (your column     │    │ (fuel, type) →       │
 │  ├─ gen.csv     │    │  names / units)  │    │  Generator subtype   │
 │  └─ ...         │    └──────────────────┘    └──────────────────────┘
 └────────┬────────┘             │                        │
          │ (1) discover &       │                        │
          │     read CSVs        │                        │
          ▼                      │                        │
   Dict{String, DataFrame}       │                        │
          │                      │                        │
          │ (2) attach            │                        │
          │     descriptors ◄─────┘                        │
          │                                                │
          │ (3) load generator mapping ◄───────────────────┘
          ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │                     PowerSystemTableData                            │
 │  base_power | category_to_df | user_descriptors | descriptors |     │
 │  generator_mapping | timeseries_metadata_file  | directory          │
 └─────────────────────────────────────────────────────────────────────┘
          │
          │ (4) later: PowerSystems.System(data; ...)
          ▼
      System
```

### 1. Discover and read the CSV files

The constructor walks `directory` with two regular expressions:

  - `^[A-Za-z]+$` — treats a plain alphabetic sub-directory as a *grouping*
    folder and recurses into it for its own `*.csv` files.
  - `(.*?)\.csv` — matches CSV files in `directory` itself.

Each matching file is read with `CSV.File` into a `DataFrames.DataFrame` and
stored under its stem name (`bus.csv` becomes key `"bus"`). The raw layout is
a `Dict{String, Any}` whose keys are either a top-level category name
(`"bus"`, `"gen"`, ...) or a sub-folder name mapping to a nested dict.

If no CSVs are found, the constructor errors. If `bus.csv` is missing, the
next phase raises `DataFormatError("key 'bus' not found in input data")`:
bus data is the only *required* input.

### 2. Associate DataFrames with categories

The dictionary of DataFrames is re-keyed by
`InputCategory` enum values (`BUS`, `BRANCH`, `GEN`, `LOAD`,
`DC_BRANCH`, `RESERVE`, `STORAGE`). The mapping from CSV name to enum is the
`INPUT_CATEGORY_NAMES` constant in `src/power_system_table_data.jl`.
Categories that are not present in the directory are simply omitted from
`category_to_df` (so, for example, a system with no storage just has no
`STORAGE` entry).

At the same time, the two descriptor inputs are loaded:

  - The **default descriptor JSON** (always loaded from the package) defines
    the canonical field names, default values, expected units, and per-unit
    conventions.
  - The **user descriptor YAML** is loaded and re-keyed by uppercased category
    symbol (`:BUS`, `:GENERATOR`, ...). The special case `"reserves"` is
    renamed to `"reserve"` to match the enum.

The user descriptors effectively overlay the defaults: for each PowerSystems
field the user YAML can provide a `custom_name` (the column name as it appears
in *your* CSV), a `unit`, a `unit_system`, or a `base_reference`. Fields left
blank in the user YAML fall back to the default descriptor's entry.

### 3. Load the generator mapping

`get_generator_mapping(generator_mapping_file)` reads
`generator_mapping.yaml` and returns a `Dict{NamedTuple, String}` where each
key is `(fuel = "...", unit_type = "...")` and the value is the name of a
concrete `Generator` subtype (e.g. `ThermalStandard`, `RenewableDispatch`).
A bundled default lives at
[`src/generator_mapping_cdm.yaml`](https://github.com/NLR-Sienna/PowerTableDataParser.jl/blob/main/src/generator_mapping_cdm.yaml).

Duplicate `(fuel, type)` entries in the YAML raise an error — the mapping must
be unambiguous. Legacy `GenericBattery` entries are silently translated to
`EnergyReservoirStorage` with a warning.

### 4. Resolve the time-series pointer file

The constructor accepts a `timeseries_metadata_file` keyword (default
`joinpath(directory, "timeseries_pointers")`). If that path does not exist as
given, the parser tries appending `.json` and then `.csv`; if neither exists,
the field is set to `nothing` and no time series will be attached when the
system is built. This makes time-series data strictly opt-in.

The pointer file itself is not parsed here — it is stored on the
`PowerSystemTableData` and consumed later by `PowerSystems.jl` when you call
`System(data; ...)`.

## How the YAML files are used

The two YAML inputs play very different roles:

### `user_descriptors.yaml` — schema translation

This file answers the question: *"What do my CSV columns mean in PowerSystems
terms?"* A minimal snippet for the `generator` category might look like:

```yaml
generator:
  - name: name
    custom_name: GEN UID
  - name: bus_id
    custom_name: Bus ID
  - name: fuel
    custom_name: Fuel
  - name: active_power
    custom_name: MW
    unit: MW
    unit_system: natural_units
```

The `name` field is the PowerSystems-standard name (must exist in the default
descriptor JSON); `custom_name` is the column header in your CSV;
`unit` and `unit_system` declare the physical units and per-unit convention of
your data. When `PowerSystems.jl` later iterates over rows of this category,
the parser uses these mappings to:

  - pull the right column from the DataFrame, even if you renamed it;
  - convert your values into the per-unit convention PowerSystems expects
    (system base, device base, or natural units);
  - apply simple unit conversions (`GW`↔`MW`, `radian`↔`degree`, ...).

Entries you do not override are taken verbatim from the default descriptor
JSON, so you only need to list the columns you actually want to customize.

### `generator_mapping.yaml` — type dispatch

This file answers the question: *"Given a `fuel` and `type` in `gen.csv`,
which concrete `Generator` subtype should I construct?"* The bundled default
looks like:

```yaml
HydroDispatch:
  - {fuel: HYDRO, type: ROR}

RenewableDispatch:
  - {fuel: SOLAR, type: PV}
  - {fuel: WIND, type: WIND}

ThermalStandard:
  - {fuel: COAL, type: null}
  - {fuel: NG,   type: null}
  - {fuel: NUCLEAR, type: null}
```

A `null` `type` means "match any `type` for this fuel". At parse time the
parser looks up `(fuel, unit_type)` in this dictionary and creates the
corresponding struct. Any row whose `(fuel, type)` pair is not in the mapping
will raise an error — if you introduce a new technology, you extend this
YAML.

## Supported CSV categories

The package currently recognizes the categories listed in
`INPUT_CATEGORY_NAMES`:

| CSV file        | Category enum               | Required? |
|-----------------|-----------------------------|-----------|
| `bus.csv`       | `InputCategory.BUS`         | **yes**   |
| `branch.csv`    | `InputCategory.BRANCH`      | no        |
| `dc_branch.csv` | `InputCategory.DC_BRANCH`   | no        |
| `gen.csv`       | `InputCategory.GENERATOR`   | no        |
| `load.csv`      | `InputCategory.LOAD`        | no        |
| `reserves.csv`  | `InputCategory.RESERVE`     | no        |
| `storage.csv`   | `InputCategory.STORAGE`     | no        |

Two conventions on `bus.csv` are worth calling out explicitly:

  - Columns named `area` and `zone` are promoted into `Area` and `LoadZone`
    objects automatically.
  - Columns named `max_active_power` / `max_reactive_power` create `PowerLoad`
    objects for nonzero rows and contribute to the `peak_active_power` /
    `peak_reactive_power` of the corresponding `LoadZone`.

Other enum values (`SIMULATION_OBJECTS`, `FACTS`, `DCBRTYPE`, `DCBRSTATUS`,
`TICT`) exist in the schema for forward compatibility with PowerSystems, but
there is no corresponding top-level CSV file name wired up in
`INPUT_CATEGORY_NAMES` today.

## The `PowerSystemTableData` object

After construction, `PowerSystemTableData` is simply a container holding the
pieces above:

| Field                         | What it holds                                               |
|-------------------------------|-------------------------------------------------------------|
| `base_power`                  | System base MVA (defaults to 100.0 if not provided)         |
| `category_to_df`              | `Dict{Symbol, DataFrame}`, keyed by `InputCategory` symbol  |
| `user_descriptors`            | Parsed `user_descriptors.yaml` (keyed by uppercased symbol) |
| `descriptors`                 | Parsed default `power_system_inputs.json`                   |
| `generator_mapping`           | `Dict{NamedTuple, String}` from `(fuel, type)` to subtype   |
| `timeseries_metadata_file`    | Absolute path to pointer file, or `nothing`                 |
| `directory`                   | Original input directory (used to resolve relative paths)   |

Nothing in this object depends on `PowerSystems.jl`; the handoff happens only
when you pass `data` to `PowerSystems.System(data; ...)`, which iterates the
DataFrames row-by-row using the descriptors and mapping to build concrete
system components.

## Deprecation notice

The tabular parser — originally part of `PowerSystems.jl`'s `CDM` subsystem —
is in long-term maintenance mode. `PowerSystems.jl` is moving toward a
database-backed data layer; users starting a new dataset are encouraged to
write a small custom Julia importer rather than depend on this parser. This
package exists to give existing CDM-based workflows a stable home while that
transition plays out.
