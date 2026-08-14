# PowerTableDataParser.jl

Standalone home for the CSV / tabular-data parser (CDM) that was historically inside `PowerSystems.jl`. PSY support ends at v6; this package is the continuation.

**Current state:** in-progress extraction. `PowerSystemTableData` struct (duplicated from PSY) is exported, but the `System(::PowerSystemTableData)` constructor and `*_csv_parser!` / `create_poly_cost` / `make_thermal_generator_multistart` helpers still live in PSY. Tests therefore build via `PSY.PowerSystemTableData` + `PSY.System(...)` until the parser code is ported in.

## Layout — the non-obvious parts

- `src/power_system_inputs.json` — the column descriptor file, a **copy of PSY's** kept here until
  PSY drops its version. The two can drift.
- `src/enums.jl` — `InputCategory` scoped enum, mirrors PSY's.
- `ext/PowerTableDataParserPowerSystemsExt.jl` — time series pointer-file ingestion into a
  live `PSY.System` (`add_time_series_from_pointers!`), migrated from PowerSystemCaseBuilder.
  A weakdep extension so the core package (and its OpenAPI path) stays PSY-free;
  PSCB imports this package and calls it.
- `[sources]` points InfrastructureSystems at `../IS3.jl`, the working checkout of the
  rust-backed time series store branch. Its InfraStore backend is registered and stays
  **encapsulated inside IS** — this package never imports it; tests reach the backend
  reader via `IS.InfraStore` only to verify emitted store files independently.
- `test/` uses the Sienna classic runner (`julia --project=test test/runtests.jl`); end-to-end
  parser tests use PSY's own struct, so they need PSY resolvable.

## Conventions

- Julia compat: `^1.10`. Run tests with `julia --project=test test/runtests.jl`, not bare `Pkg.test()`.
- Stack-wide performance, style, and contribution rules: the `sienna-psy6` skill.
