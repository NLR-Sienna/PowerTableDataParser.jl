# PowerTableDataParser.jl

```@meta
CurrentModule = PowerTableDataParser
```

## Overview

`PowerTableDataParser.jl` is a [`Julia`](http://www.julialang.org) package that
parses a directory of CSV files describing a power system (buses, branches,
generators, loads, DC branches, reserves, storage) together with user-supplied
YAML configuration files into a [`PowerSystemTableData`](@ref) object. That
object can then be passed to `PowerSystems.jl`'s `System` constructor to build
a fully-typed system.

This package is a stand-alone extraction of the tabular "CDM" (Component Data
Model) parser that previously lived inside `PowerSystems.jl`. Support for the
tabular parser inside `PowerSystems.jl` is removed starting with
`PowerSystems.jl` v6, so new users should depend on this package directly.

## When to use this package

Use `PowerTableDataParser.jl` when:

  - Your input data is a collection of CSV files (one per component category)
    produced by spreadsheet workflows, RTS-style datasets, or internal tools.
  - You want to keep your own column names and units and map them to
    `PowerSystems.jl` field names via a YAML descriptor file, rather than
    editing your raw CSVs.
  - You want to map generator rows to concrete `Generator` subtypes using a
    small `(fuel, type) -> Generator` YAML mapping.

If your data is already in a MATPOWER, PSS/e RAW/DYR, or a serialized
`PowerSystems.jl` format, use the corresponding `PowerSystems.jl` parsers
directly instead.

## Documentation layout

The documentation follows the [Diataxis](https://diataxis.fr/) framework:

  - **Tutorials** — hands-on walkthroughs (coming soon).
  - **How to...** — task-oriented recipes, e.g.
    [Parse Tabular Data from .csv Files](@ref table_data).
  - **Explanation** — conceptual background on
    [how the parser combines CSV, YAML, and time-series inputs](@ref structure).
  - **Reference** — auto-generated API documentation for
    [`PowerSystemTableData`](@ref) and related internals.

## About

`PowerTableDataParser` is part of the
[Sienna platform](https://www.nrel.gov/analysis/sienna.html), an open source
framework for scheduling problems and dynamic simulations for power systems.
The Sienna ecosystem can be
[found on github](https://github.com/NREL-Sienna/Sienna). It contains three
applications:

  - [Sienna\Data](https://github.com/NREL-Sienna/Sienna?tab=readme-ov-file#siennadata) enables
    efficient data input, analysis, and transformation.
  - [Sienna\Ops](https://github.com/NREL-Sienna/Sienna?tab=readme-ov-file#siennaops) enables
    system scheduling simulations by formulating and solving optimization problems.
  - [Sienna\Dyn](https://github.com/NREL-Sienna/Sienna?tab=readme-ov-file#siennadyn) enables
    system transient analysis including small signal stability and full system dynamic
    simulations.

Each application uses multiple packages in the [`Julia`](http://www.julialang.org)
programming language.
