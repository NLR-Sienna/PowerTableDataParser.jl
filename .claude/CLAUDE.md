# PowerTableDataParser.jl

Standalone home for the CSV / tabular-data parser (CDM) that was historically inside `PowerSystems.jl`. PSY support ends at v6; this package is the continuation.

## Layout — the non-obvious parts

- `src/power_system_inputs.json` — the column descriptor file, a **copy of PSY's** kept here until
  PSY drops its version. The two can drift.
- `src/enums.jl` — `InputCategory` scoped enum, mirrors PSY's.
- `ext/PowerTableDataParserPowerSystemsExt.jl` — time series pointer-file ingestion into a
  live `PSY.System` (`add_time_series_from_pointers!`), migrated from PowerSystemCaseBuilder.
  A weakdep extension so the core package (and its OpenAPI path) stays PSY-free;
  PSB imports this package and calls it.
- `[sources]` git-pins InfrastructureSystems to branch `IS4`. Its InfraStore backend is registered and stays
  **encapsulated inside IS** — this package never imports it; tests reach the backend
  reader via `IS.InfraStore` only to verify emitted store files independently.
- `test/` uses the Sienna classic runner (`julia --project=test test/runtests.jl`); end-to-end
  parser tests use PSY's own struct, so they need PSY resolvable.

## Conventions

- Julia compat: `^1.10`. Run tests with `julia --project=test test/runtests.jl`, not bare `Pkg.test()`.

## Shared rules and agents

The shared Sienna rules load from the import below; the `sienna-dev` skill holds the cross-package
context; the `sienna-dev` and `sienna-reviewer` subagents implement and review.

@Sienna.md
