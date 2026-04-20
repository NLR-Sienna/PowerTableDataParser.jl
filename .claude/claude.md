# PowerTableDataParser.jl

Standalone home for the CSV / tabular-data parser (CDM) that was historically inside `PowerSystems.jl`. PSY support ends at v6; this package is the continuation.

**Current state:** in-progress extraction. `PowerSystemTableData` struct (duplicated from PSY) is exported, but the `System(::PowerSystemTableData)` constructor and `*_csv_parser!` / `create_poly_cost` / `make_thermal_generator_multistart` helpers still live in PSY. Tests therefore build via `PSY.PowerSystemTableData` + `PSY.System(...)` until the parser code is ported in.

## Layout

- `src/PowerTableDataParser.jl` — module, imports, re-exports.
- `src/common.jl` — small shared helpers.
- `src/enums.jl` — `InputCategory` scoped enum (mirrors PSY).
- `src/power_system_table_data.jl` — `PowerSystemTableData` struct + directory-reading constructor.
- `src/power_system_inputs.json` — column descriptor file (copy of PSY's until PSY drops its version).
- `src/generator_mapping_cdm.yaml` — default generator type mapping.
- `test/runtests.jl` — Sienna classic runner (`julia --project=test test/runtests.jl`).
- `test/test_power_system_table_data.jl` — parser tests (use PSY's struct for end-to-end).
- `test/common.jl`, `test/rts_loading_utils.jl` — RTS-GMLC test helpers.
- `scripts/formatter/formatter_code.jl` — JuliaFormatter config; run before claiming done.

## Conventions

- Julia compat: `^1.10`. Run tests with `julia --project=test test/runtests.jl`, not bare `Pkg.test()`.
- See [Sienna.md](Sienna.md) for stack-wide performance / style / contribution rules.
