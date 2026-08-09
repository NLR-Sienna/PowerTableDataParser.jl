# OpenAPI JSON Representation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `PowerSystemTableData` into Sienna OpenAPI structs and serialize them as a JSON document plus an HDF5 time series file.

**Architecture:** PTDP gains an `src/openapi/` subtree mirroring `PowerSystemCaseBuilder/src/parsers/power_system_table_data.jl`, emitting generated `PowerOpenAPIModels` structs into a hand-written `OpenAPISystem` container. Components are built empty and populated through unit-checked setters, mirroring OpenAPI.jl's own `from_json(T(), json)` pattern. Units come from methods generated into `PowerOpenAPIModels` from SiennaSchemas' `x-unit` annotations. Time series go through `InfrastructureSystems`' HDF5 layer, with links recorded as `TimeSeriesAssociation` rows.

**Tech Stack:** Julia ≥1.10, `PowerCoreOpenAPIModels`, `PowerOperationsOpenAPIModels`, `OpenAPI` 0.2, `InfrastructureSystems` (IS4), `DataFrames`, `CSV`, `JSON`, `JSON3`, `TimeZones`, `UUIDs`.

**Design doc:** `.claude/plans/2026-07-30-openapi-json-representation-design.md`
**Review this plan answers:** `.claude/plans/2026-07-30-openapi-json-representation-review.md`

> **Revision note.** This is revision 2. Revision 1 was reviewed and found to have 13
> blocking defects. Every one is addressed below; the fix is called out inline as
> **[fixes review defect N]** so it can be checked off against the review.

## Global Constraints

- Julia compat `^1.10`. Run tests with `julia --project=test test/runtests.jl` — never bare `--project` or `julia`.
- Instantiate with `julia --project=test -e 'using Pkg; Pkg.instantiate()'`.
- **Never `git commit` or `git push`.** Leave changes unstaged. `git add -N` for new files so they show in `git diff`.
- Formatter before any task is done: `julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'`.
- After each edit verify compilation: `julia --project=test -e 'using PowerTableDataParser'`.
- **No `isa` / `<:Type` runtime checks** — use dispatch, including in tests.
- **No ternary operators.**
- **No `nothing`-returning absence sentinels** in new API: `Bool` predicate + accessor.
- **No silent `=== nothing && continue`.** `error()` with type, name, and expectation.
- Explicit `function … end` with explicit `return` for non-trivial bodies.
- `iszero(x)`, never `x == 0`.
- Terse comments; only non-obvious *why*.
- **Never construct components with keyword arguments** (design D3). Allocate empty, then `set_value!`.
- Do not modify `PowerSystems.jl`, `PowerSystemCaseBuilder`, or SiennaSchemas.
- **Every parser reads rows with `iterate_rows(data, category; per_unit = false)`.** The
  task snippets below omit the keyword (Tasks 7, 8, 11, 12); that is a transcription
  error, not the intent. The default `per_unit = true` rebases power columns onto the
  descriptor's target base, so `MW Load` would arrive as 1.08 and then be labelled
  `"MW"`. Corrected while implementing Task 7.

## Reference Paths

| What | Where |
|---|---|
| Reference parser | `/Users/jdlara/cache/psy6/PowerSystemCaseBuilder.jl/src/parsers/power_system_table_data.jl` |
| Reference helpers | `/Users/jdlara/cache/psy6/PowerSystemCaseBuilder.jl/src/parsers/common.jl` |
| Generated models | `/Users/jdlara/cache/psy6/PowerOpenAPIModels/` |
| Schema bundles | `/Users/jdlara/cache/psy6/SiennaSchemas/dist/openapi-*-bundled.json` |
| Unit vocabulary | `/Users/jdlara/cache/psy6/SiennaSchemas/Core/units.json` |
| OpenAPI.jl | `/Users/jdlara/.julia/packages/OpenAPI/5LBLo/src/` |
| RTS-GMLC | `PowerSystemCaseBuilder.DATA_DIR/RTS_GMLC` |

## Verified Ground Truth

Confirmed against source while writing this revision. Do not re-derive; do not contradict.

| Fact | Evidence |
|---|---|
| `OpenAPI.to_json(o)` returns a **String** | `json.jl:59` |
| `JSON.lower(::APIModel)` → `JSONWrapper`, skipping `nothing` properties | `json.jl:9, 26` |
| `from_json(::Type{T}, json) = from_json(T(), json)` | `json.jl:62` |
| `setproperty!` on `APIModel` runs `validate_property` | `client.jl:225` |
| OpenAPI.jl version is **0.2.2** | `OpenAPI/5LBLo/Project.toml` |
| `PC.ComplexNumber` fields are `real`, `imag` | `model_ComplexNumber.jl` |
| RTS `Bus Type` values: `PQ` 40, `PV` 32, **`Ref`** 1 | `bus.csv`; enum wants `REF` |
| `{HYDRO, HYDRO}` → `HydroTurbine` (19), `{HYDRO, ROR}` → `HydroDispatch` (1) | `generator_mapping_cdm.yaml` |
| Mapping keys are UPPERCASE with `type: null` for thermals | `generator_mapping_cdm.yaml`, `src/common.jl:10–33` |
| `units.json` has **no** `kW`/`GW`/`GWh` | 55 entries, 45 unique units |
| Ambiguous units: `pu`, `ohm`, `S`, `1`, **`m`** (Length 0.001 vs Elevation 1.0) | `Core/units.json` |
| Only 3 properties use `m`, all elevations | `HydroTurbine.powerhouse_elevation`, `HydroPumpTurbine.powerhouse_elevation`, `HydroReservoir.intake_elevation` |
| RTS `timeseries_pointers.json`: 260 entries, all `SingleTimeSeries`, 3600 s and 300 s | Generator 121+121, Reserve 7+5, LoadZone 3+3 |
| RTS aliases zone column to area column → `"1"`,`"2"`,`"3"` are both `Area` and `LoadZone` | `user_descriptors.yaml` |
| IS4 keeps multiple resolutions; resolution is part of series identity | `system_data.jl:545`; associations key includes `resolution` |
| `IS.read_time_series(metadata::TimeSeriesFileMetadata; kwargs...)` returns `RawTimeSeries` (Dict of **all** CSV columns) | `time_series_formats.jl:34, 201–213` |
| `read_time_series_file_metadata` already absolutizes `data_file` | `time_series_parser.jl:147–150` |
| Counts: 73 buses, 158 gens, 120 branches (105 line / 15 xfmr), 1 DC, 3 Areas, 3 LoadZones, 7 reserves | RTS CSVs |
| `openapi-operations-bundled.json` does **not** contain Core types | `MinMax` absent |
| RTS `user_descriptors.yaml` **does** declare `unit:` — `degree`, `GWh`, `GW` | handled by ported `convert_units!` |

---

### Task 1: Generate unit methods in PowerOpenAPIModels

**Repo:** `PowerOpenAPIModels`. Gates everything else.

**Files:**
- Create: `scripts/emit_units.jl`
- Modify: `scripts/reorganize.jl`, `Makefile`
- Test: `test/test_units.jl`

**Interfaces** — all defined in `PowerCoreOpenAPIModels`, all *extended* (never redefined) elsewhere:
- `PowerCoreOpenAPIModels.has_declared_unit(::Type{<:OpenAPI.APIModel}, ::Val) -> Bool`
- `PowerCoreOpenAPIModels.declared_unit(::Type{T}, ::Val{P}) -> String`
- `PowerCoreOpenAPIModels.declared_unit(o::T, ::Val{P}) -> String`
- `PowerCoreOpenAPIModels.declared_quantity(::Type{T}, ::Val{P}) -> String`
- `PowerCoreOpenAPIModels.has_unit_base(::Type{<:OpenAPI.APIModel}, ::Val) -> Bool`
- `PowerCoreOpenAPIModels.unit_base(::Type{T}, ::Val{P}) -> Symbol`
- `PowerCoreOpenAPIModels.has_conversion_factor(quantity::AbstractString, unit::AbstractString) -> Bool`
- `PowerCoreOpenAPIModels.conversion_factor(quantity::AbstractString, unit::AbstractString) -> Float64`
- `const UNIT_VOCABULARY::Dict{Tuple{String, String}, Float64}` keyed `(quantity_type, unit)`

**[fixes review defect 1]** Non-core packages emit *qualified* method definitions
(`PowerCoreOpenAPIModels.declared_unit(::Type{ACBus}, …) = …`). Unqualified definitions
inside a package that only does `using PowerCoreOpenAPIModels` create a new local function
and silently fail to extend. Fallbacks and the vocabulary are emitted **once**, in Core.

**[fixes review defect 2]** The vocabulary is keyed by `(quantity_type, unit)` and every
conversion compares quantity. Unit strings are not unique: `m` maps to Length (0.001) and
Elevation (1.0).

- [x] **Step 1: Write the failing test**

Create `test/test_units.jl`:

```julia
using Test
using OpenAPI
using PowerCoreOpenAPIModels
using PowerOperationsOpenAPIModels
const PC = PowerCoreOpenAPIModels
const PO = PowerOperationsOpenAPIModels

@testset "fixed x-unit resolves through Core's function" begin
    @test PC.has_declared_unit(PO.ACBus, Val(:angle))
    @test PC.declared_unit(PO.ACBus, Val(:angle)) == "rad"
    @test PC.declared_unit(PO.ACBus, Val(:base_voltage)) == "kV"
    @test PC.declared_unit(PO.Line, Val(:r)) == "pu"
    @test !PC.has_declared_unit(PO.ACBus, Val(:name))
end

@testset "every property also declares a quantity" begin
    @test PC.declared_quantity(PO.ACBus, Val(:base_voltage)) == "Voltage"
    @test PC.declared_quantity(PO.ACBus, Val(:angle)) == "Angle"
    @test PC.declared_quantity(PO.ThermalStandard, Val(:base_power)) == "ApparentPower"
end

@testset "ambiguous unit m resolves to Elevation, not Length" begin
    @test PC.declared_unit(PO.HydroTurbine, Val(:powerhouse_elevation)) == "m"
    @test PC.declared_quantity(PO.HydroTurbine, Val(:powerhouse_elevation)) == "Elevation"
end

@testset "x-unit-base" begin
    @test PC.has_unit_base(PO.ACBus, Val(:magnitude))
    @test PC.unit_base(PO.ACBus, Val(:magnitude)) == :base_voltage
end

@testset "discriminated x-units read the instance" begin
    line = PO.TwoTerminalLCCLine()
    line.parameter_units = "SYSTEM_BASE"
    @test PC.declared_unit(line, Val(:r)) == "pu"
    line.parameter_units = "NATURAL_UNITS"
    @test PC.declared_unit(line, Val(:r)) == "ohm"
end

@testset "vocabulary is keyed by quantity and unit" begin
    @test PC.has_conversion_factor("ActivePower", "MW")
    @test PC.conversion_factor("ActivePower", "MW") == 1.0
    @test PC.conversion_factor("ElectricalEnergy", "MJ") ≈ 0.0002777777777777778
    @test PC.conversion_factor("Length", "m") ≈ 0.001
    @test PC.conversion_factor("Elevation", "m") == 1.0
    @test !PC.has_conversion_factor("Angle", "rad")        # to_default 0.0
    @test !PC.has_conversion_factor("Resistance", "pu")    # to_default null
    @test !PC.has_conversion_factor("ActivePower", "kW")   # not in the vocabulary
end
```

- [x] **Step 2: Run test to verify it fails**

Run: `julia --project=PowerOpenAPIModels.jl test/test_units.jl`
Expected: FAIL with `UndefVarError: has_declared_unit not defined in PowerCoreOpenAPIModels`

- [x] **Step 3: Write the emitter**

Create `scripts/emit_units.jl`:

```julia
import JSON3

const DOMAIN_TO_PKG = Dict(
    "core" => "PowerCoreOpenAPIModels.jl",
    "operations" => "PowerOperationsOpenAPIModels.jl",
    "investments" => "PowerInvestmentsOpenAPIModels.jl",
    "dynamics" => "PowerDynamicsOpenAPIModels.jl",
)

# A unit string can belong to several quantity types with DIFFERENT factors
# ("m": Length 0.001, Elevation 1.0). Where that happens the unit alone cannot
# identify the quantity, so the property must be listed here. Generation fails
# on any unlisted ambiguous property rather than guessing.
const QUANTITY_OVERRIDES = Dict(
    ("HydroTurbine", "powerhouse_elevation") => "Elevation",
    ("HydroPumpTurbine", "powerhouse_elevation") => "Elevation",
    ("HydroReservoir", "intake_elevation") => "Elevation",
)

function _load_vocabulary(units_path)
    raw = JSON3.read(read(units_path, String))
    factors = Dict{Tuple{String, String}, Float64}()
    by_unit = Dict{String, Vector{Tuple{String, Float64}}}()
    for entry in raw["allowed_units"]
        quantity = String(entry["quantity_type"])
        unit = String(entry["unit"])
        factor = entry["to_default"]
        # null: context-dependent (pu bases). 0.0: this layer deliberately does
        # not convert (Angle). Neither is a usable factor, but both are valid
        # quantity/unit pairings, so record the pairing without a factor.
        push!(get!(by_unit, unit, Vector{Tuple{String, Float64}}()), (quantity, _as_factor(factor)))
        if _is_convertible(factor)
            factors[(quantity, unit)] = Float64(factor)
        end
    end
    return factors, by_unit
end

_is_convertible(::Nothing) = false
function _is_convertible(factor::Real)
    return !iszero(factor)
end

_as_factor(::Nothing) = 0.0
_as_factor(factor::Real) = Float64(factor)

function _resolve_quantity(by_unit, type_name, prop, unit)
    key = (String(type_name), String(prop))
    if haskey(QUANTITY_OVERRIDES, key)
        return QUANTITY_OVERRIDES[key]
    end
    if !haskey(by_unit, unit)
        error("$type_name.$prop declares x-unit=\"$unit\", absent from units.json")
    end
    candidates = by_unit[unit]
    quantities = unique(first.(candidates))
    if length(quantities) == 1
        return quantities[1]
    end
    if length(unique(last.(candidates))) == 1
        # Several quantities, one factor: any of them converts identically.
        return quantities[1]
    end
    error(
        "$type_name.$prop declares ambiguous x-unit=\"$unit\" across quantities " *
        "$(join(quantities, \", \")) with differing factors. Add it to QUANTITY_OVERRIDES.",
    )
end

function _emit_vocabulary(io, factors)
    println(io, "const UNIT_VOCABULARY = Dict{Tuple{String, String}, Float64}(")
    for key in sort!(collect(keys(factors)))
        println(io, "    (\"", key[1], "\", \"", key[2], "\") => ", factors[key], ",")
    end
    println(io, ")\n")
    println(
        io,
        "has_conversion_factor(q::AbstractString, u::AbstractString) = haskey(UNIT_VOCABULARY, (String(q), String(u)))",
    )
    println(
        io,
        "conversion_factor(q::AbstractString, u::AbstractString) = UNIT_VOCABULARY[(String(q), String(u))]\n",
    )
    return
end

function _emit_fallbacks(io)
    println(io, "has_declared_unit(::Type{<:OpenAPI.APIModel}, ::Val) = false")
    println(io, "has_unit_base(::Type{<:OpenAPI.APIModel}, ::Val) = false")
    println(
        io,
        "has_declared_unit(o::T, v::Val) where {T <: OpenAPI.APIModel} = has_declared_unit(T, v)",
    )
    println(
        io,
        "declared_unit(o::T, v::Val) where {T <: OpenAPI.APIModel} = declared_unit(T, v)",
    )
    println(
        io,
        "declared_quantity(o::T, v::Val) where {T <: OpenAPI.APIModel} = declared_quantity(T, v)",
    )
    return
end

function _emit_type(io, prefix, by_unit, type_name, schema)
    for (prop, spec) in pairs(get(schema, "properties", Dict()))
        if haskey(spec, "x-unit") && spec["x-unit"] isa AbstractString
            unit = String(spec["x-unit"])
            quantity = _resolve_quantity(by_unit, type_name, prop, unit)
            println(io, "$(prefix)has_declared_unit(::Type{$type_name}, ::Val{:$prop}) = true")
            println(io, "$(prefix)declared_unit(::Type{$type_name}, ::Val{:$prop}) = \"$unit\"")
            println(
                io,
                "$(prefix)declared_quantity(::Type{$type_name}, ::Val{:$prop}) = \"$quantity\"",
            )
        end
        if haskey(spec, "x-unit-base")
            println(io, "$(prefix)has_unit_base(::Type{$type_name}, ::Val{:$prop}) = true")
            println(
                io,
                "$(prefix)unit_base(::Type{$type_name}, ::Val{:$prop}) = :$(spec["x-unit-base"])",
            )
        end
        if haskey(spec, "x-units") && haskey(spec, "x-unit-discriminator")
            _emit_discriminated(io, prefix, by_unit, type_name, prop, spec)
        end
    end
    return
end

function _emit_discriminated(io, prefix, by_unit, type_name, prop, spec)
    disc = spec["x-unit-discriminator"]
    mapping = spec["x-units"]
    flat = [(String(k), String(v)) for (k, v) in pairs(mapping) if v isa AbstractString]
    if isempty(flat)
        # Nested discriminators are not flattened. Emitting nothing means
        # has_declared_unit stays false and set_value! rejects the property,
        # which is correct: we cannot determine its unit.
        return
    end
    quantity = _resolve_quantity(by_unit, type_name, prop, flat[1][2])
    println(io, "$(prefix)has_declared_unit(::Type{$type_name}, ::Val{:$prop}) = true")
    println(io, "$(prefix)declared_quantity(::Type{$type_name}, ::Val{:$prop}) = \"$quantity\"")
    println(io, "function $(prefix)declared_unit(o::$type_name, ::Val{:$prop})")
    for (key, unit) in flat
        println(io, "    if string(o.$disc) == \"$key\"")
        println(io, "        return \"$unit\"")
        println(io, "    end")
    end
    println(
        io,
        "    error(\"$type_name.$prop: no unit declared for $disc=\$(o.$disc)\")",
    )
    println(io, "end")
    return
end

function emit_units(schema_dir, repo_root)
    factors, by_unit = _load_vocabulary(joinpath(schema_dir, "Core", "units.json"))
    for (domain, pkg) in DOMAIN_TO_PKG
        bundle = joinpath(schema_dir, "dist", "openapi-$domain-bundled.json")
        isfile(bundle) || continue
        spec = JSON3.read(read(bundle, String))
        prefix = ""
        if domain != "core"
            prefix = "PowerCoreOpenAPIModels."
        end
        dest = joinpath(repo_root, pkg, "src", "units.jl")
        open(dest, "w") do io
            println(io, "# Generated from SiennaSchemas x-unit annotations. Do not edit.\n")
            if domain == "core"
                _emit_vocabulary(io, factors)
                _emit_fallbacks(io)
            end
            for (type_name, schema) in pairs(spec["components"]["schemas"])
                _emit_type(io, prefix, by_unit, type_name, schema)
            end
        end
        @info "Wrote $dest"
    end
    return
end
```

- [x] **Step 4: Wire it in**

Append to `scripts/reorganize.jl`:

```julia
include(joinpath(@__DIR__, "emit_units.jl"))
emit_units(get(ENV, "SCHEMA_DIR", joinpath(dirname(REPO), "SiennaSchemas")), REPO)
```

**[fixes review significant problem 6]** In the `Makefile` `generate` target, replace the
final `julia scripts/reorganize.jl` with:

```make
	SCHEMA_DIR=$(abspath $(SCHEMA_DIR)) julia --project=PowerOpenAPIModels.jl scripts/reorganize.jl
```

`SCHEMA_DIR` is currently a make variable only, so `ENV["SCHEMA_DIR"]` would be unset;
and the bare `julia` call has no environment, so `import JSON3` would fail.

Add `include("units.jl")` to each package module after the last model include. Export the
eight names **from Core only** — exporting from all four makes unqualified calls ambiguous.

- [x] **Step 5: Regenerate and test**

```bash
cd /Users/jdlara/cache/psy6/PowerOpenAPIModels
make generate SCHEMA_DIR=/Users/jdlara/cache/psy6/SiennaSchemas
julia --project=PowerOpenAPIModels.jl test/test_units.jl
```
Expected: PASS. Verify method count:
```bash
grep -ho 'declared_unit(::Type{[A-Za-z0-9_]*}' */src/units.jl | wc -l
```
Expected: ≥ 410.

- [x] **Step 6: Verify existing validation**

Run: `make validate`
Expected: PASS.

- [x] **Step 7: Stage**

```bash
git add -N scripts/emit_units.jl test/test_units.jl */src/units.jl
```

---

### Task 2: Dependencies and module scaffolding

**Files:** `Project.toml`, `test/Project.toml`, `src/PowerTableDataParser.jl`, `src/openapi/container.jl` (stub)

**[fixes review defect 13]** `OpenAPI` compat is `"0.2"`, not `"0.1"`.
**[fixes review significant problem 5]** `HDF5` and `JSON3` go in `test/Project.toml`, not
the package `[deps]` — src reaches HDF5 only through IS, and `Aqua.test_stale_deps`
(`test/runtests.jl:20`) fails on an unused dep.

- [x] **Step 1: Package Project.toml**

`[deps]` — add:
```toml
JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
OpenAPI = "d5e62ea6-ddf3-4d43-8e4c-ad5e6c8bfd7d"
PowerCoreOpenAPIModels = "b7b40286-e793-417d-a9a0-b1583e4da1cb"
PowerOperationsOpenAPIModels = "a372b6d7-45a2-44c2-8199-6a724b72e8ff"
TimeZones = "f269a46b-ccf7-5d73-abea-4c690281aa53"
UUIDs = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"
```

`[sources]` — add:
```toml
PowerCoreOpenAPIModels = {url = "https://github.com/Sienna-Platform/PowerOpenAPIModels.git", rev = "main", subdir = "PowerCoreOpenAPIModels.jl"}
PowerOperationsOpenAPIModels = {url = "https://github.com/Sienna-Platform/PowerOpenAPIModels.git", rev = "main", subdir = "PowerOperationsOpenAPIModels.jl"}
```

`[compat]` — add:
```toml
JSON = "0.21"
OpenAPI = "0.2"
TimeZones = "1"
UUIDs = "1"
```

`JSON` (not JSON3) is the package dependency because `OpenAPI.jl` defines
`JSON.lower(::APIModel)` — see Task 15.

- [x] **Step 2: test/Project.toml**

Add `HDF5 = "f67ccb44-e63f-5c2f-98bd-6dc0ccc4ba2f"` and
`JSON3 = "0f8b85d8-7281-11e9-16c2-39a750bddbf1"` to `[deps]`, plus the same two
`[sources]` entries as above.

- [x] **Step 3: Module imports**

In `src/PowerTableDataParser.jl`, after `import YAML`:

```julia
import Dates
import JSON
import OpenAPI
import TimeZones
import UUIDs
import PowerCoreOpenAPIModels
import PowerOperationsOpenAPIModels
const PC = PowerCoreOpenAPIModels
const PO = PowerOperationsOpenAPIModels
```

Add exports `OpenAPISystem`, `build_openapi_system`, `to_json`, and after
`include("power_system_table_data.jl")` add `include("openapi/container.jl")`.

- [x] **Step 4: Placeholder container**

Create `src/openapi/container.jl`:

```julia
struct OpenAPISystem
    base_power::Float64
end
```

- [x] **Step 5: Instantiate and verify**

```bash
julia --project=test -e 'using Pkg; Pkg.instantiate()'
julia --project=test -e 'using PowerTableDataParser; println(PowerTableDataParser.PO.ACBus)'
```
Expected: prints `ACBus`.

- [x] **Step 6: Stage**

```bash
git add -N src/openapi/container.jl
```

---

### Task 3: IdRegistry

Unchanged from revision 1 — the review found no defects here.

**Files:** Create `src/openapi/identity.jl`; Test `test/test_openapi_identity.jl`

**Interfaces:**
- `IdRegistry()`, `next_id!(reg) -> Int`
- `register!(reg, type_name, name) -> Int`, `register_bus!(reg, number, name) -> Int`
- `has_id(reg, type_name, name) -> Bool`, `get_id(reg, type_name, name) -> Int`
- `has_bus_id(reg, number) -> Bool`, `get_bus_id(reg, number) -> Int`
- `arc_id!(reg, from_id, to_id) -> Tuple{Int, Bool}`
- `find_by_name(reg, type_names, name) -> Tuple{String, Int}` — **new**, used by Task 14

- [x] **Step 1: Write the failing test**

Create `test/test_openapi_identity.jl`:

```julia
@testset "IdRegistry assigns one global id space" begin
    reg = PDP.IdRegistry()
    @test PDP.register!(reg, "Area", "1") == 1
    @test PDP.register_bus!(reg, 101, "Abel") == 2
    @test PDP.register!(reg, "ThermalStandard", "101_STEAM_3") == 3
end

@testset "IdRegistry lookups" begin
    reg = PDP.IdRegistry()
    PDP.register_bus!(reg, 101, "Abel")
    @test PDP.has_bus_id(reg, 101)
    @test PDP.get_bus_id(reg, 101) == 1
    @test !PDP.has_bus_id(reg, 999)
    @test PDP.has_id(reg, "ACBus", "Abel")
    @test !PDP.has_id(reg, "ACBus", "Nowhere")
end

@testset "IdRegistry rejects duplicates within a type" begin
    reg = PDP.IdRegistry()
    PDP.register!(reg, "Area", "1")
    @test_throws IS.DataFormatError PDP.register!(reg, "Area", "1")
end

@testset "IdRegistry allows the same name across types" begin
    reg = PDP.IdRegistry()
    @test PDP.register!(reg, "Area", "1") != PDP.register!(reg, "LoadZone", "1")
end

@testset "arc_id! deduplicates and respects direction" begin
    reg = PDP.IdRegistry()
    f = PDP.register_bus!(reg, 101, "Abel")
    t = PDP.register_bus!(reg, 102, "Adams")
    id1, created1 = PDP.arc_id!(reg, f, t)
    id2, created2 = PDP.arc_id!(reg, f, t)
    id3, _ = PDP.arc_id!(reg, t, f)
    @test created1
    @test !created2
    @test id1 == id2
    @test id1 != id3
end

@testset "find_by_name narrows by candidate types" begin
    reg = PDP.IdRegistry()
    area = PDP.register!(reg, "Area", "1")
    zone = PDP.register!(reg, "LoadZone", "1")
    @test PDP.find_by_name(reg, ["LoadZone"], "1") == ("LoadZone", zone)
    @test PDP.find_by_name(reg, ["Area"], "1") == ("Area", area)
    @test_throws IS.DataFormatError PDP.find_by_name(reg, ["Area", "LoadZone"], "1")
    @test_throws IS.DataFormatError PDP.find_by_name(reg, ["Area"], "nope")
end
```

Add `include("test_openapi_identity.jl")` to `test/runtests.jl`.

- [x] **Step 2: Run test to verify it fails**

Run: `julia --project=test test/runtests.jl`
Expected: FAIL with `UndefVarError: IdRegistry not defined`

- [x] **Step 3: Implement**

Create `src/openapi/identity.jl`:

```julia
struct IdRegistry
    counter::Base.RefValue{Int}
    by_name::Dict{Tuple{String, String}, Int}
    by_bus_number::Dict{Int, Int}
    arcs::Dict{Tuple{Int, Int}, Int}
end

function IdRegistry()
    return IdRegistry(
        Ref(0),
        Dict{Tuple{String, String}, Int}(),
        Dict{Int, Int}(),
        Dict{Tuple{Int, Int}, Int}(),
    )
end

function next_id!(reg::IdRegistry)
    reg.counter[] += 1
    return reg.counter[]
end

function register!(reg::IdRegistry, type_name::AbstractString, name::AbstractString)
    key = (String(type_name), String(name))
    if haskey(reg.by_name, key)
        throw(
            IS.DataFormatError(
                "duplicate component: type=$type_name name=$name already has id=$(reg.by_name[key])",
            ),
        )
    end
    id = next_id!(reg)
    reg.by_name[key] = id
    return id
end

function register_bus!(reg::IdRegistry, number::Int, name::AbstractString)
    if haskey(reg.by_bus_number, number)
        throw(IS.DataFormatError("duplicate bus number=$number"))
    end
    id = register!(reg, "ACBus", name)
    reg.by_bus_number[number] = id
    return id
end

has_id(reg::IdRegistry, t::AbstractString, n::AbstractString) =
    haskey(reg.by_name, (String(t), String(n)))

function get_id(reg::IdRegistry, type_name::AbstractString, name::AbstractString)
    key = (String(type_name), String(name))
    if !haskey(reg.by_name, key)
        throw(IS.DataFormatError("unknown component: type=$type_name name=$name"))
    end
    return reg.by_name[key]
end

has_bus_id(reg::IdRegistry, number::Int) = haskey(reg.by_bus_number, number)

function get_bus_id(reg::IdRegistry, number::Int)
    if !haskey(reg.by_bus_number, number)
        throw(IS.DataFormatError("unknown bus number=$number"))
    end
    return reg.by_bus_number[number]
end

function arc_id!(reg::IdRegistry, from_id::Int, to_id::Int)
    key = (from_id, to_id)
    if haskey(reg.arcs, key)
        return reg.arcs[key], false
    end
    id = next_id!(reg)
    reg.arcs[key] = id
    return id, true
end

function find_by_name(reg::IdRegistry, type_names, name::AbstractString)
    matches = Tuple{String, Int}[]
    for type_name in type_names
        key = (String(type_name), String(name))
        if haskey(reg.by_name, key)
            push!(matches, (String(type_name), reg.by_name[key]))
        end
    end
    if isempty(matches)
        throw(
            IS.DataFormatError(
                "no component named $name among types [$(join(type_names, ", "))]",
            ),
        )
    end
    if length(matches) > 1
        found = join([m[1] for m in matches], ", ")
        throw(IS.DataFormatError("ambiguous name=$name matches types [$found]"))
    end
    return matches[1]
end
```

Add `include("openapi/identity.jl")` before the container include.

- [x] **Step 4: Run test to verify it passes**

Run: `julia --project=test test/runtests.jl`
Expected: PASS

- [x] **Step 5: Format and stage**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
git add -N src/openapi/identity.jl test/test_openapi_identity.jl
```

---

### Task 4: Unit-checked setters and getters

**Files:** Create `src/openapi/units.jl`; Test `test/test_openapi_units.jl`

**Interfaces:**
- `set_value!(o, prop::Symbol, value)` — property must declare **no** unit
- `set_value!(o, prop::Symbol, value, unit::AbstractString)` — property **must** declare a unit
- `set_value!(o, prop::Symbol, value::NamedTuple, unit::AbstractString)` — compound (`MinMax`/`UpDown`/`FromTo`/`InOut`)
- `get_value(o, prop::Symbol)`, `get_value(o, prop::Symbol, unit::AbstractString)`

**[fixes review defects 2 and 3, and significant problem 7]** Conversion compares
`quantity_type`, so kV↛MW. Same-unit assignment never consults the vocabulary, so `rad`
and `pu` work despite having no factor. Compound properties are covered, closing the kwarg
bypass.

Compound member names, verified: `PC.MinMax(max, min)`, `PC.UpDown(down, up)`,
`PC.FromTo(from, to)`, `PC.InOut(in, out)`.

- [x] **Step 1: Write the failing test**

Create `test/test_openapi_units.jl`:

```julia
@testset "same unit stores unchanged" begin
    bus = PDP.PO.ACBus()
    PDP.set_value!(bus, :base_voltage, 138.0, "kV")
    @test bus.base_voltage == 138.0
end

@testset "units with no factor still assign when they match" begin
    bus = PDP.PO.ACBus()
    PDP.set_value!(bus, :angle, 0.3, "rad")
    @test bus.angle == 0.3
    line = PDP.PO.Line()
    PDP.set_value!(line, :r, 0.003, "pu")
    @test line.r == 0.003
end

@testset "converts within a quantity" begin
    res = PDP.PO.HydroReservoir()
    PDP.set_value!(res, :intake_elevation, 1.0, "m")
    @test res.intake_elevation == 1.0
end

@testset "rejects a cross-quantity conversion" begin
    bus = PDP.PO.ACBus()
    @test_throws IS.DataFormatError PDP.set_value!(bus, :base_voltage, 138.0, "MW")
end

@testset "rejects a real conversion with no factor" begin
    bus = PDP.PO.ACBus()
    @test_throws IS.DataFormatError PDP.set_value!(bus, :angle, 30.0, "deg")
end

@testset "arity enforces the unit rule both ways" begin
    bus = PDP.PO.ACBus()
    @test_throws IS.DataFormatError PDP.set_value!(bus, :name, "Abel", "kV")
    @test_throws IS.DataFormatError PDP.set_value!(bus, :base_voltage, 138.0)
    PDP.set_value!(bus, :name, "Abel")
    @test bus.name == "Abel"
end

@testset "setters run generated validation" begin
    bus = PDP.PO.ACBus()
    @test_throws Exception PDP.set_value!(bus, :bustype, "Ref")
    PDP.set_value!(bus, :bustype, "REF")
    @test bus.bustype == "REF"
end

@testset "compound properties take the unit at object level" begin
    bus = PDP.PO.ACBus()
    PDP.set_value!(bus, :voltage_limits, (min = 0.95, max = 1.05), "pu")
    @test bus.voltage_limits.min == 0.95
    @test bus.voltage_limits.max == 1.05

    gen = PDP.PO.ThermalStandard()
    PDP.set_value!(gen, :ramp_limits, (up = 3.0, down = 3.0), "MW/min")
    @test gen.ramp_limits.up == 3.0
end

@testset "discriminated units are read off the instance" begin
    line = PDP.PO.TwoTerminalLCCLine()
    PDP.set_value!(line, :parameter_units, "NATURAL_UNITS")
    PDP.set_value!(line, :r, 5.0, "ohm")
    @test line.r == 5.0

    line2 = PDP.PO.TwoTerminalLCCLine()
    PDP.set_value!(line2, :parameter_units, "SYSTEM_BASE")
    @test_throws IS.DataFormatError PDP.set_value!(line2, :r, 5.0, "ohm")
end

@testset "get_value round-trips and converts" begin
    bus = PDP.PO.ACBus()
    PDP.set_value!(bus, :base_voltage, 138.0, "kV")
    @test PDP.get_value(bus, :base_voltage) == 138.0
    @test PDP.get_value(bus, :base_voltage, "kV") == 138.0
    @test_throws IS.DataFormatError PDP.get_value(bus, :base_voltage, "MW")
end
```

Add `include("test_openapi_units.jl")` to `test/runtests.jl`.

- [x] **Step 2: Run test to verify it fails**

Run: `julia --project=test test/runtests.jl`
Expected: FAIL with `UndefVarError: set_value! not defined`

- [x] **Step 3: Implement**

Create `src/openapi/units.jl`:

```julia
const COMPOUND_TYPES = Dict(
    :MinMax => PC.MinMax,
    :UpDown => PC.UpDown,
    :FromTo => PC.FromTo,
    :InOut => PC.InOut,
)

function _require_declared(o::OpenAPI.APIModel, prop::Symbol)
    T = typeof(o)
    if !PC.has_declared_unit(T, Val(prop))
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop declares no unit; use the 3-argument set_value!",
            ),
        )
    end
    return PC.declared_unit(o, Val(prop)), PC.declared_quantity(T, Val(prop))
end

function _require_undeclared(o::OpenAPI.APIModel, prop::Symbol)
    T = typeof(o)
    if PC.has_declared_unit(T, Val(prop))
        unit = PC.declared_unit(o, Val(prop))
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop declares unit \"$unit\"; use the 4-argument set_value!",
            ),
        )
    end
    return
end

function convert_to_declared(
    o::OpenAPI.APIModel,
    prop::Symbol,
    value::Float64,
    source_unit::AbstractString,
)
    target, quantity = _require_declared(o, prop)
    if source_unit == target
        return value
    end
    T = typeof(o)
    if !PC.has_conversion_factor(quantity, source_unit)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop is $quantity in \"$target\"; \"$source_unit\" is not a " *
                "convertible $quantity unit",
            ),
        )
    end
    if !PC.has_conversion_factor(quantity, target)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop: the vocabulary records no conversion factor for " *
                "$quantity in \"$target\"",
            ),
        )
    end
    return value * PC.conversion_factor(quantity, source_unit) /
           PC.conversion_factor(quantity, target)
end

function set_value!(
    o::OpenAPI.APIModel,
    prop::Symbol,
    value::Real,
    source_unit::AbstractString,
)
    setproperty!(o, prop, convert_to_declared(o, prop, Float64(value), source_unit))
    return
end

function set_value!(
    o::OpenAPI.APIModel,
    prop::Symbol,
    value::NamedTuple,
    source_unit::AbstractString,
)
    ctor = _compound_type(o, prop)
    converted = map(v -> convert_to_declared(o, prop, Float64(v), source_unit), values(value))
    setproperty!(o, prop, ctor(; NamedTuple{keys(value)}(converted)...))
    return
end

function set_value!(o::OpenAPI.APIModel, prop::Symbol, value)
    _require_undeclared(o, prop)
    setproperty!(o, prop, value)
    return
end

function get_value(o::OpenAPI.APIModel, prop::Symbol)
    return getproperty(o, prop)
end

function get_value(o::OpenAPI.APIModel, prop::Symbol, unit::AbstractString)
    source, quantity = _require_declared(o, prop)
    value = getproperty(o, prop)
    if source == unit
        return value
    end
    if !PC.has_conversion_factor(quantity, unit) ||
       !PC.has_conversion_factor(quantity, source)
        throw(
            IS.DataFormatError(
                "$(nameof(typeof(o))).$prop is $quantity in \"$source\"; cannot express in \"$unit\"",
            ),
        )
    end
    return value * PC.conversion_factor(quantity, source) /
           PC.conversion_factor(quantity, unit)
end
```

`_compound_type(o, prop)` reads the generated `_property_types_<T>` table to pick the
constructor. Confirm the accessor before writing it:
```bash
grep -n '_property_types_ACBus' \
  /Users/jdlara/cache/psy6/PowerOpenAPIModels/PowerOperationsOpenAPIModels.jl/src/models/model_ACBus.jl
```
`OpenAPI.property_type(T, prop)` is the public route and returns `Union{Nothing, MinMax}`;
strip `Nothing` to get the constructor.

Add `include("openapi/units.jl")` to the module.

- [x] **Step 4: Run test to verify it passes**

Run: `julia --project=test test/runtests.jl`
Expected: PASS

- [x] **Step 5: Format and stage**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
git add -N src/openapi/units.jl test/test_openapi_units.jl
```

---

### Task 5: OpenAPISystem container

Unchanged from revision 1 except that `time_series` is typed. Review found no defects.

**Files:** Modify `src/openapi/container.jl`; Test `test/test_openapi_container.jl`

**Interfaces:** `SupplementalAttributeAssociation(attribute_id, entity_id)`,
`OpenAPISystem(base_power)`, `add_component!`, `get_components`, `get_registry`,
`get_base_power`, `component_type_names` (sorted).

- [x] **Step 1: Write the failing test**

Create `test/test_openapi_container.jl`:

```julia
@testset "OpenAPISystem starts empty" begin
    sys = PDP.OpenAPISystem(100.0)
    @test PDP.get_base_power(sys) == 100.0
    @test isempty(PDP.component_type_names(sys))
end

@testset "add_component! groups by type name, sorted" begin
    sys = PDP.OpenAPISystem(100.0)
    line = PDP.PO.Line()
    PDP.set_value!(line, :name, "L1")
    bus = PDP.PO.ACBus()
    PDP.set_value!(bus, :name, "Abel")
    PDP.add_component!(sys, line)
    PDP.add_component!(sys, bus)
    @test PDP.component_type_names(sys) == ["ACBus", "Line"]
    @test length(PDP.get_components(sys, "ACBus")) == 1
end

@testset "get_components on an absent type is empty" begin
    sys = PDP.OpenAPISystem(100.0)
    @test isempty(PDP.get_components(sys, "ACBus"))
end
```

Add `include("test_openapi_container.jl")` to `test/runtests.jl`.

- [x] **Step 2: Run test to verify it fails**

Run: `julia --project=test test/runtests.jl`
Expected: FAIL — `add_component!` undefined.

- [x] **Step 3: Implement**

Replace `src/openapi/container.jl`:

```julia
struct SupplementalAttributeAssociation
    attribute_id::Int
    entity_id::Int
end

struct OpenAPISystem
    base_power::Float64
    components::Dict{String, Vector}
    supplemental_attributes::Vector{OpenAPI.APIModel}
    supplemental_attribute_associations::Vector{SupplementalAttributeAssociation}
    time_series_associations::Vector{PC.TimeSeriesAssociation}
    time_series::Vector{IS.TimeSeriesData}
    registry::IdRegistry
end

function OpenAPISystem(base_power::Float64)
    return OpenAPISystem(
        base_power,
        Dict{String, Vector}(),
        Vector{OpenAPI.APIModel}(),
        Vector{SupplementalAttributeAssociation}(),
        Vector{PC.TimeSeriesAssociation}(),
        Vector{IS.TimeSeriesData}(),
        IdRegistry(),
    )
end

get_base_power(sys::OpenAPISystem) = sys.base_power
get_registry(sys::OpenAPISystem) = sys.registry

function add_component!(sys::OpenAPISystem, component::T) where {T <: OpenAPI.APIModel}
    bucket = get!(sys.components, string(nameof(T))) do
        return Vector{T}()
    end
    push!(bucket, component)
    return
end

function get_components(sys::OpenAPISystem, type_name::AbstractString)
    return get(sys.components, String(type_name), Vector{OpenAPI.APIModel}())
end

component_type_names(sys::OpenAPISystem) = sort!(collect(keys(sys.components)))
```

- [x] **Step 4: Run test to verify it passes**

Run: `julia --project=test test/runtests.jl`
Expected: PASS

- [x] **Step 5: Format and stage**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
git add -N test/test_openapi_container.jl
```

---

### Task 6: Port the descriptor accessors and generator-type lookup

**Files:** Create `src/openapi/accessors.jl`; Test `test/test_openapi_accessors.jl`

**[fixes review defect 5]** `get_generator_type` must be ported. Mapping keys are
UPPERCASE with `type: null` for thermals, so a direct
`haskey(mapping, (fuel = "Coal", unit_type = "STEAM"))` is false for all 73 thermal rows.

**Interfaces:** `get_user_field`, `get_user_fields`, `get_dataframe`, `iterate_rows`,
`_FieldInfo`, `_get_field_infos`, `_read_data_row`, `convert_units!`, `string_compare`,
`get_generator_type(fuel, unit_type, mappings) -> String`.

Sources to transcribe, changing only the type qualification:

| From | Lines |
|---|---|
| `PSCB/src/parsers/power_system_table_data.jl` | 15–90 |
| `PSCB/src/parsers/power_system_table_data.jl` | 1493–1671 |
| `PSCB/src/parsers/common.jl` | 102–120 (`get_generator_type`) |
| `PSCB/src/parsers/common.jl` | 191–252 (`convert_units!`) + `string_compare` |

Drop `_get_component_type_from_category` / `CATEGORY_STR_TO_COMPONENT` — they map to PSY
abstract types. Task 14 uses `find_by_name` instead.

- [x] **Step 1: Write the failing test**

Create `test/test_openapi_accessors.jl`:

```julia
@testset "iterate_rows yields one NamedTuple per bus" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    rows = collect(PDP.iterate_rows(data, PDP.InputCategory.BUS))
    @test length(rows) == 73
end

@testset "get_dataframe returns the branch table" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    @test DataFrames.nrow(PDP.get_dataframe(data, PDP.InputCategory.BRANCH)) == 120
end

@testset "get_user_field resolves a custom column name" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    @test PDP.get_user_field(data, PDP.InputCategory.GENERATOR, "name") == "GEN UID"
end

@testset "get_generator_type handles case and null unit types" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    m = data.generator_mapping
    @test PDP.get_generator_type("Coal", "STEAM", m) == "ThermalStandard"
    @test PDP.get_generator_type("NG", "CT", m) == "ThermalStandard"
    @test PDP.get_generator_type("Hydro", "HYDRO", m) == "HydroTurbine"
    @test PDP.get_generator_type("Hydro", "ROR", m) == "HydroDispatch"
    @test PDP.get_generator_type("Solar", "RTPV", m) == "RenewableNonDispatch"
    @test PDP.get_generator_type("Sync_Cond", "SYNC_COND", m) == "SynchronousCondenser"
end
```

Add `include("test_openapi_accessors.jl")` to `test/runtests.jl` and `import DataFrames`
to the preamble.

Before running, confirm the expected mapping targets:
```bash
grep -B1 -A6 'RenewableNonDispatch\|SynchronousCondenser' src/generator_mapping_cdm.yaml
```

- [x] **Step 2: Run test to verify it fails**

Run: `julia --project=test test/runtests.jl`
Expected: FAIL with `UndefVarError: iterate_rows not defined`

- [x] **Step 3: Copy the source**

Transcribe the four blocks above into `src/openapi/accessors.jl`. Add
`include("openapi/accessors.jl")` before `identity.jl`.

- [x] **Step 4: Run test to verify it passes**

Run: `julia --project=test test/runtests.jl`
Expected: PASS

- [x] **Step 5: Format and stage**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
git add -N src/openapi/accessors.jl test/test_openapi_accessors.jl
```

---

### Task 7: Topology parser

**Files:** Create `src/openapi/topology.jl`; Test `test/test_openapi_topology.jl`

**Interfaces:** `loadzone_csv_parser!(sys, data)`, `bus_csv_parser!(sys, data)`

**[fixes review defect 9]** Bus type must be normalized: RTS has `Ref`, the enum wants
`REF`. `PO.ACBus`'s generated `validate_property` rejects `"Ref"`.
**[fixes review defect 11]** No `FixedAdmittance` branch. RTS's `user_descriptors.yaml`
maps shunts to `mw_shunt_g`/`mvar_shut_b`, names absent from `power_system_inputs.json`,
so `shunt_g`/`shunt_b` always take their defaults of 0 and PSCB emits nothing either. If a
future dataset does populate them, note that `PC.ComplexNumber` fields are `real`/`imag`.

Field mapping — `ACBus`:

| Descriptor field | Property | Unit | Setter |
|---|---|---|---|
| `bus_id` | `number` | — | 3-arg |
| `name` | `name` | — | 3-arg |
| `bus_type` | `bustype` | — | 3-arg, uppercased |
| `angle` | `angle` | `rad` | 4-arg |
| `voltage` | `magnitude` | `pu` | 4-arg |
| `voltage_limits_min`/`_max` | `voltage_limits` | `pu` | 4-arg NamedTuple |
| `base_voltage` | `base_voltage` | `kV` | 4-arg |
| `area` | `area` | — | 3-arg (id) |
| `zone` | `load_zone` | — | 3-arg (id) |

- [x] **Step 1: Write the failing test**

Create `test/test_openapi_topology.jl`:

```julia
function _topology()
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.OpenAPISystem(100.0)
    PDP.loadzone_csv_parser!(sys, data)
    PDP.bus_csv_parser!(sys, data)
    return sys, data
end

@testset "buses, areas and zones" begin
    sys, _ = _topology()
    @test length(PDP.get_components(sys, "ACBus")) == 73
    @test length(PDP.get_components(sys, "Area")) == 3
    @test length(PDP.get_components(sys, "LoadZone")) == 3
end

@testset "bus type is normalized to the enum" begin
    sys, _ = _topology()
    types = Set(b.bustype for b in PDP.get_components(sys, "ACBus"))
    @test types ⊆ Set(["PQ", "PV", "REF", "ISOLATED", "SLACK"])
    @test "REF" in types
end

@testset "references resolve and number is distinct from id" begin
    sys, _ = _topology()
    reg = PDP.get_registry(sys)
    area_ids = Set(a.id for a in PDP.get_components(sys, "Area"))
    for bus in PDP.get_components(sys, "ACBus")
        @test bus.area in area_ids
        @test PDP.get_bus_id(reg, bus.number) == bus.id
    end
end

@testset "nonzero bus load rows emit a PowerLoad" begin
    sys, _ = _topology()
    @test !isempty(PDP.get_components(sys, "PowerLoad"))
end
```

Add `include("test_openapi_topology.jl")` to `test/runtests.jl`.

- [x] **Step 2: Run test to verify it fails**

Run: `julia --project=test test/runtests.jl`
Expected: FAIL with `UndefVarError: bus_csv_parser! not defined`

- [x] **Step 3: Implement**

Create `src/openapi/topology.jl`:

```julia
function loadzone_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    reg = get_registry(sys)
    peaks = Dict{String, Tuple{Float64, Float64}}()
    for bus in iterate_rows(data, InputCategory.BUS; per_unit = false)
        zone = string(get(bus, :zone, "zone"))
        active, reactive = get(peaks, zone, (0.0, 0.0))
        peaks[zone] = (active + bus.max_active_power, reactive + bus.max_reactive_power)
    end
    for zone in sort!(collect(keys(peaks)))
        active, reactive = peaks[zone]
        component = PO.LoadZone()
        set_value!(component, :id, register!(reg, "LoadZone", zone))
        set_value!(component, :name, zone)
        set_value!(component, :peak_active_power, active, "MW")
        set_value!(component, :peak_reactive_power, reactive, "MVAr")
        add_component!(sys, component)
    end
    return
end

function _ensure_area!(sys::OpenAPISystem, name::AbstractString)
    reg = get_registry(sys)
    if has_id(reg, "Area", name)
        return get_id(reg, "Area", name)
    end
    area = PO.Area()
    id = register!(reg, "Area", name)
    set_value!(area, :id, id)
    set_value!(area, :name, name)
    add_component!(sys, area)
    return id
end

function bus_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    reg = get_registry(sys)
    for (ix, bus) in enumerate(iterate_rows(data, InputCategory.BUS; per_unit = false))
        area_id = _ensure_area!(sys, string(get(bus, :area, "area")))
        number = bus.bus_id
        if isnothing(number)
            number = ix
        end

        ps_bus = PO.ACBus()
        set_value!(ps_bus, :id, register_bus!(reg, Int(number), bus.name))
        set_value!(ps_bus, :number, Int(number))
        set_value!(ps_bus, :name, bus.name)
        set_value!(ps_bus, :available, true)
        set_value!(ps_bus, :bustype, uppercase(bus.bus_type))
        set_value!(ps_bus, :area, area_id)
        set_value!(
            ps_bus,
            :load_zone,
            get_id(reg, "LoadZone", string(get(bus, :zone, "zone"))),
        )
        set_value!(ps_bus, :angle, bus.angle, "rad")
        set_value!(ps_bus, :magnitude, bus.voltage, "pu")
        set_value!(ps_bus, :base_voltage, bus.base_voltage, "kV")
        set_value!(
            ps_bus,
            :voltage_limits,
            (min = bus.voltage_limits_min, max = bus.voltage_limits_max),
            "pu",
        )
        add_component!(sys, ps_bus)

        if !iszero(bus.max_active_power) || !iszero(bus.max_reactive_power)
            load = PO.PowerLoad()
            set_value!(load, :id, register!(reg, "PowerLoad", bus.name))
            set_value!(load, :name, bus.name)
            set_value!(load, :available, true)
            set_value!(load, :bus, ps_bus.id)
            set_value!(load, :active_power, bus.active_power, "MW")
            set_value!(load, :reactive_power, bus.reactive_power, "MVAr")
            set_value!(load, :base_power, bus.base_power, "MVA")
            set_value!(load, :max_active_power, bus.max_active_power, "MW")
            set_value!(load, :max_reactive_power, bus.max_reactive_power, "MVAr")
            add_component!(sys, load)
        end
    end
    return
end
```

Add `include("openapi/topology.jl")` to the module.

- [x] **Step 4: Run test to verify it passes**

Run: `julia --project=test test/runtests.jl`
Expected: PASS

- [x] **Step 5: Format and stage**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
git add -N src/openapi/topology.jl test/test_openapi_topology.jl
```

---

### Task 8: AC branch parser

**Files:** Create `src/openapi/branch.jl`; Test `test/test_openapi_branch.jl`

**Interfaces:** `get_branch_type(tap, is_transformer) -> Symbol`,
`branch_csv_parser!(sys, data)`, `_add_arc!(sys, from_id, to_id) -> Int`

**[fixes review significant problem 2]** Set `magnetizing_shunt` and
`base_voltage_primary`/`_secondary`, and read `angle_limits` from the descriptor rather
than hardcoding ±π/2. Per PSCB lines 280–295.

D9 divergence: a transformer emits **two** components. `TransformerCircuit` holds the
electrical parameters and the `arc`; `TwoWindingTransformer` holds the name and references
the circuit. `TransformerCircuit` has **no** `name`.

- [x] **Step 1: Write the failing test**

Create `test/test_openapi_branch.jl`:

```julia
function _branches()
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.OpenAPISystem(100.0)
    PDP.loadzone_csv_parser!(sys, data)
    PDP.bus_csv_parser!(sys, data)
    PDP.branch_csv_parser!(sys, data)
    return sys, data
end

@testset "get_branch_type distinguishes lines from transformers" begin
    @test PDP.get_branch_type(1.0, nothing) == :Line
    @test PDP.get_branch_type(0.98, nothing) == :TwoWindingTransformer
    @test PDP.get_branch_type(1.0, true) == :TwoWindingTransformer
    @test PDP.get_branch_type(0.98, false) == :Line
end

@testset "120 branches total, split 105/15" begin
    sys, _ = _branches()
    @test length(PDP.get_components(sys, "Line")) == 105
    @test length(PDP.get_components(sys, "TwoWindingTransformer")) == 15
end

@testset "each transformer emits a paired circuit" begin
    sys, _ = _branches()
    circuits = PDP.get_components(sys, "TransformerCircuit")
    ids = Set(c.id for c in circuits)
    xfmrs = PDP.get_components(sys, "TwoWindingTransformer")
    @test length(circuits) == length(xfmrs)
    for x in xfmrs
        @test x.circuit in ids
    end
end

@testset "arcs are deduplicated and every reference resolves" begin
    sys, _ = _branches()
    arcs = PDP.get_components(sys, "Arc")
    @test length(Set((a.from_id, a.to_id) for a in arcs)) == length(arcs)
    ids = Set(a.id for a in arcs)
    for line in PDP.get_components(sys, "Line")
        @test line.arc in ids
    end
    for circuit in PDP.get_components(sys, "TransformerCircuit")
        @test circuit.arc in ids
    end
end
```

Add `include("test_openapi_branch.jl")` to `test/runtests.jl`.

- [x] **Step 2: Run test to verify it fails**

Run: `julia --project=test test/runtests.jl`
Expected: FAIL with `UndefVarError: get_branch_type not defined`

- [x] **Step 3: Implement**

Create `src/openapi/branch.jl`:

```julia
function get_branch_type(tap::Float64, is_transformer::Union{Bool, Nothing})
    if isnothing(is_transformer)
        if !iszero(tap) && tap != 1.0
            return :TwoWindingTransformer
        end
        return :Line
    end
    if is_transformer
        return :TwoWindingTransformer
    end
    return :Line
end

function _add_arc!(sys::OpenAPISystem, from_id::Int, to_id::Int)
    id, created = arc_id!(get_registry(sys), from_id, to_id)
    if created
        arc = PO.Arc()
        set_value!(arc, :id, id)
        set_value!(arc, :from_id, from_id)
        set_value!(arc, :to_id, to_id)
        add_component!(sys, arc)
    end
    return id
end

function _add_line!(sys::OpenAPISystem, branch, arc::Int)
    line = PO.Line()
    set_value!(line, :id, register!(get_registry(sys), "Line", branch.name))
    set_value!(line, :name, branch.name)
    set_value!(line, :available, true)
    set_value!(line, :arc, arc)
    set_value!(line, :active_power_flow, 0.0, "MW")
    set_value!(line, :reactive_power_flow, 0.0, "MVAr")
    set_value!(line, :r, branch.r, "pu")
    set_value!(line, :x, branch.x, "pu")
    set_value!(line, :base_power, get_base_power(sys), "MVA")
    set_value!(line, :rating, branch.rate, "MVA")
    set_value!(
        line,
        :b,
        (from = branch.primary_shunt / 2, to = branch.primary_shunt / 2),
        "pu",
    )
    set_value!(line, :g, (from = 0.0, to = 0.0), "pu")
    set_value!(
        line,
        :angle_limits,
        (min = branch.min_angle_limits, max = branch.max_angle_limits),
        "rad",
    )
    add_component!(sys, line)
    return
end

function _add_transformer!(sys::OpenAPISystem, branch, arc::Int, from_kv, to_kv)
    reg = get_registry(sys)
    circuit = PO.TransformerCircuit()
    set_value!(circuit, :id, next_id!(reg))
    set_value!(circuit, :available, true)
    set_value!(circuit, :arc, arc)
    set_value!(circuit, :tap, branch.tap)
    set_value!(circuit, :r, branch.r, "pu")
    set_value!(circuit, :x, branch.x, "pu")
    set_value!(circuit, :rating, branch.rate, "MVA")
    set_value!(circuit, :base_power, get_base_power(sys), "MVA")
    set_value!(circuit, :base_voltage_primary, from_kv, "kV")
    set_value!(circuit, :base_voltage_secondary, to_kv, "kV")
    add_component!(sys, circuit)

    xfmr = PO.TwoWindingTransformer()
    set_value!(xfmr, :id, register!(reg, "TwoWindingTransformer", branch.name))
    set_value!(xfmr, :name, branch.name)
    set_value!(xfmr, :circuit, circuit.id)
    add_component!(sys, xfmr)
    return
end

function branch_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    reg = get_registry(sys)
    kv = Dict(b.id => b.base_voltage for b in get_components(sys, "ACBus"))
    for branch in iterate_rows(data, InputCategory.BRANCH)
        from_id = get_bus_id(reg, Int(branch.connection_points_from))
        to_id = get_bus_id(reg, Int(branch.connection_points_to))
        arc = _add_arc!(sys, from_id, to_id)
        kind = get_branch_type(branch.tap, get(branch, :is_transformer, nothing))
        if kind == :Line
            _add_line!(sys, branch, arc)
        else
            _add_transformer!(sys, branch, arc, kv[from_id], kv[to_id])
        end
    end
    return
end
```

`magnetizing_shunt` is a `ComplexNumber4`; PSCB sets it from `branch.primary_shunt`.
Confirm the member names before writing that line:
```bash
grep -A 6 'kwdef mutable struct ComplexNumber4' \
  /Users/jdlara/cache/psy6/PowerOpenAPIModels/PowerOperationsOpenAPIModels.jl/src/models/model_ComplexNumber4.jl
```

Confirm the descriptor names `connection_points_from/to`, `primary_shunt`, `tap`, `rate`,
`min_angle_limits`, `max_angle_limits`, `is_transformer` exist under `branch`:
```bash
python3 -c "import json;print(sorted(i['name'] for i in json.load(open('src/power_system_inputs.json'))['branch']))"
```

Add `include("openapi/branch.jl")` to the module.

- [x] **Step 4: Run test to verify it passes**

Run: `julia --project=test test/runtests.jl`
Expected: PASS

- [x] **Step 5: Format and stage**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
git add -N src/openapi/branch.jl test/test_openapi_branch.jl
```

---

### Task 9: DC branch parser

**Files:** Create `src/openapi/dc_branch.jl`; Test `test/test_openapi_dc_branch.jl`

**[fixes review defect 6]** Revision 1 invented every descriptor name here. The actual
`dc_branch` descriptor fields, verified from `src/power_system_inputs.json`, are exactly:

```
active_power_flow, connection_points_from, connection_points_to, control_mode,
dc_line_category, inverter_firing_angle_max, inverter_firing_angle_min,
inverter_tap_limits_max, inverter_tap_limits_min, inverter_xrc, loss,
max_active_power_limit_from, max_active_power_limit_to,
max_reactive_power_limit_from, max_reactive_power_limit_to,
min_active_power_limit_from, min_active_power_limit_to,
min_reactive_power_limit_from, min_reactive_power_limit_to, mw_load, name, rate,
rectifier_firing_angle_max, rectifier_firing_angle_min,
rectifier_tap_limits_max, rectifier_tap_limits_min, rectifier_xrc
```

**Target type is `TwoTerminalGenericHVDCLine`, not `TwoTerminalLCCLine`.** PSCB
(`power_system_table_data.jl:307–370`) selects on `control_mode`; RTS's DC1 has
`Control Mode = "Power"`, which is the generic branch.
`model_TwoTerminalGenericHVDCLine.jl` exists in the generated models. The LCC path is
unreachable from these descriptor fields — commutating resistances, bridge counts, and
DC voltages are columns in `dc_branch.csv` that the descriptor does not expose.

**Interfaces:** `dc_branch_csv_parser!(sys, data)`

- [x] **Step 1: Establish the target type's fields**

Run:
```bash
awk '/^Base.@kwdef mutable struct/,/^end # type/' \
  /Users/jdlara/cache/psy6/PowerOpenAPIModels/PowerOperationsOpenAPIModels.jl/src/models/model_TwoTerminalGenericHVDCLine.jl
sed -n '307,370p' \
  /Users/jdlara/cache/psy6/PowerSystemCaseBuilder.jl/src/parsers/power_system_table_data.jl
```
Write the descriptor→property mapping table into this task before continuing. Every
property must come from the verified descriptor list above.

- [x] **Step 2: Write the failing test**

Create `test/test_openapi_dc_branch.jl`:

```julia
function _dc()
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.OpenAPISystem(100.0)
    PDP.loadzone_csv_parser!(sys, data)
    PDP.bus_csv_parser!(sys, data)
    PDP.dc_branch_csv_parser!(sys, data)
    return sys, data
end

@testset "one DC line named DC1" begin
    sys, _ = _dc()
    lines = PDP.get_components(sys, "TwoTerminalGenericHVDCLine")
    @test length(lines) == 1
    @test only(lines).name == "DC1"
end

@testset "the DC arc connects buses 113 and 316" begin
    sys, _ = _dc()
    reg = PDP.get_registry(sys)
    arc = only(PDP.get_components(sys, "Arc"))
    @test arc.from == PDP.get_bus_id(reg, 113)
    @test arc.to == PDP.get_bus_id(reg, 316)
end

@testset "power limits are populated from the descriptor" begin
    sys, _ = _dc()
    line = only(PDP.get_components(sys, "TwoTerminalGenericHVDCLine"))
    @test line.active_power_limits_from.max >= line.active_power_limits_from.min
end
```

Add `include("test_openapi_dc_branch.jl")` to `test/runtests.jl`.

- [x] **Step 3: Run test to verify it fails**

Run: `julia --project=test test/runtests.jl`
Expected: FAIL with `UndefVarError: dc_branch_csv_parser! not defined`

- [x] **Step 4: Implement**

Follow the structure of `_add_line!` in Task 8: allocate `PO.TwoTerminalGenericHVDCLine()`,
register the name, `_add_arc!` for the connection points, then `set_value!` each property
from the mapping table written in Step 1. Use the 4-arg form with `"MW"` for active power
limits and `"MVAr"` for reactive, and the NamedTuple form for the four `MinMax` limit
pairs.

Add `include("openapi/dc_branch.jl")` to the module.

- [x] **Step 5: Run test to verify it passes**

Run: `julia --project=test test/runtests.jl`
Expected: PASS

- [x] **Step 6: Format and stage**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
git add -N src/openapi/dc_branch.jl test/test_openapi_dc_branch.jl
```

---

### Task 10: Cost helpers

**Files:** Create `src/openapi/cost.jl`; Test `test/test_openapi_cost.jl`

**[fixes review significant problem 1]** Revision 1 invented the cost semantics. RTS
supplies heat-rate columns (`HR_avg_0`, `HR_incr_*`) and `fuel_price`, with
`heat_rate_a0/a1/a2` defaulting to `nothing`. PSCB's
`make_cost(::Type{<:ThermalGen}, …, ::_HeatRateColumns)` (lines 710–744) therefore takes
the `create_pwinc_cost` branch (line 921) and wraps the result in a **`FuelCurve`** with
`fuel_price / 1000` — not a `CostCurve`. `create_poly_cost` (line 891) *reads*
a-coefficients; it does not fit a quadratic.

**Interfaces:**
- `get_cost_pairs(gen, cost_colnames) -> Vector{Tuple{Float64, Float64}}`
- `create_pwl_cost(cost_pairs) -> PC.PiecewiseLinearData`
- `create_pwinc_cost(cost_pairs) -> PC.PiecewiseStepData`
- `create_poly_cost(gen) -> PC.QuadraticFunctionData`
- `make_thermal_cost(data, gen) -> PC.ThermalGenerationCost`
- `make_renewable_cost(data, gen) -> PC.RenewableGenerationCost`
- `make_hydro_cost(data, gen) -> PC.HydroGenerationCost`
- `const COST_COLUMN_NAMES`

- [x] **Step 1: Establish the reference behaviour**

Run and read before writing anything:
```bash
sed -n '710,760p;841,960p' \
  /Users/jdlara/cache/psy6/PowerSystemCaseBuilder.jl/src/parsers/power_system_table_data.jl
ls /Users/jdlara/cache/psy6/PowerOpenAPIModels/PowerCoreOpenAPIModels.jl/src/models/ \
  | grep -iE 'fuelcurve|piecewise|xy|valuecurve'
```
Record which PSCB branch RTS actually takes and the exact Core type names.

- [x] **Step 2: Write the failing test**

Create `test/test_openapi_cost.jl`:

```julia
@testset "RTS thermal cost is a FuelCurve, not a CostCurve" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    gen = first(
        g for g in PDP.iterate_rows(data, PDP.InputCategory.GENERATOR) if g.fuel == "Coal"
    )
    cost = PDP.make_thermal_cost(data, gen)
    @test cost.cost_type == "THERMAL"
    @test cost.variable.variable_cost_type == "FUEL"
    @test cost.variable.fuel_cost > 0
end

@testset "create_pwl_cost preserves point order" begin
    curve = PDP.create_pwl_cost([(0.0, 0.0), (10.0, 100.0), (20.0, 250.0)])
    @test curve.function_type == "PIECEWISE_LINEAR"
    @test length(curve.points) == 3
end

@testset "get_cost_pairs drops incomplete points" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    gen = first(PDP.iterate_rows(data, PDP.InputCategory.GENERATOR))
    pairs = PDP.get_cost_pairs(gen, PDP.COST_COLUMN_NAMES)
    @test !isempty(pairs)
    @test all(p -> !isnothing(p[1]) && !isnothing(p[2]), pairs)
end
```

Add `include("test_openapi_cost.jl")` to `test/runtests.jl`.

- [x] **Step 3: Run test to verify it fails**

Run: `julia --project=test test/runtests.jl`
Expected: FAIL with `UndefVarError: make_thermal_cost not defined`

- [x] **Step 4: Implement**

Transcribe PSCB's cost functions, substituting constructors:

| PSY | OpenAPI |
|---|---|
| `PiecewiseLinearData(points)` | `PC.PiecewiseLinearData` with `points` of the Core XY type |
| `PiecewiseStepData(x, y)` | `PC.PiecewiseStepData` |
| `QuadraticFunctionData(a, b, c)` | `PC.QuadraticFunctionData` |
| `FuelCurve(value_curve, fuel_cost)` | `PC.FuelCurve`, `variable_cost_type = "FUEL"` |
| `CostCurve(value_curve)` | `PC.CostCurve`, `power_units = "NATURAL_UNITS"` |
| `ThermalGenerationCost(...)` | `PC.ThermalGenerationCost`, `cost_type = "THERMAL"` |

Cost objects are Core value types, not components; build them with kwargs. The D3
empty-construct rule applies to components entering the container, not to nested value
objects — but any *numeric with a declared unit* on a component still goes through
`set_value!`.

Add `include("openapi/cost.jl")` to the module.

- [x] **Step 5: Run test to verify it passes**

Run: `julia --project=test test/runtests.jl`
Expected: PASS

- [x] **Step 6: Format and stage**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
git add -N src/openapi/cost.jl test/test_openapi_cost.jl
```

---

### Task 11: Generation parser

**Files:** Create `src/openapi/generation.jl`; Test `test/test_openapi_generation.jl`

**[fixes review defects 4 and 5]** Corrected generator type distribution:

| Fuel / Unit Type | Count | Target |
|---|---:|---|
| NG/CT, NG/CC, Oil/CT, Oil/STEAM, Coal/STEAM, Nuclear/NUCLEAR | 73 | `ThermalStandard` |
| Solar/PV, Solar/CSP, Wind/WIND | — | `RenewableDispatch` |
| Solar/RTPV | 31 | `RenewableNonDispatch` |
| **Hydro/HYDRO** | **19** | **`HydroTurbine` + `HydroReservoir`** |
| Hydro/ROR | 1 | `HydroDispatch` |
| Sync_Cond/SYNC_COND | 3 | `SynchronousCondenser` |
| Storage/STORAGE | 1 | `EnergyReservoirStorage` |

Confirm the Solar split against `src/generator_mapping_cdm.yaml` in Step 1 — the
dispatch/non-dispatch boundary comes from the mapping file, not from this table.

Hydro is the big correction. `{HYDRO, HYDRO}` maps to `HydroTurbine`, which PSCB builds
via `make_hydro_turbine` (line 1272) plus `_make_hydro_reservoirs` (line 1208), consuming
`storage.csv`'s 22 head/tail rows. `PO.HydroTurbine` and `PO.HydroReservoir` both exist.

**Interfaces:**
- `gen_csv_parser!(sys, data)`
- `make_thermal_generator(sys, data, gen, bus_id) -> PO.ThermalStandard`
- `make_renewable_generator(sys, data, gen, bus_id, ::Val) -> PO.RenewableDispatch | PO.RenewableNonDispatch`
- `make_hydro_turbine(sys, data, gen, bus_id, storage) -> PO.HydroTurbine`
- `make_hydro_dispatch(sys, data, gen, bus_id) -> PO.HydroDispatch`
- `make_hydro_reservoirs!(sys, data, gen, storage) -> Vector{Int}`
- `make_synchronous_condenser(sys, data, gen, bus_id) -> PO.SynchronousCondenser`
- `make_storage(sys, data, gen, bus_id, storage) -> PO.EnergyReservoirStorage`
- `cache_storage(data)`

- [x] **Step 1: Establish the reference behaviour**

```bash
sed -n '382,470p;1032,1475p' \
  /Users/jdlara/cache/psy6/PowerSystemCaseBuilder.jl/src/parsers/power_system_table_data.jl
cat src/generator_mapping_cdm.yaml
awk '/kwdef mutable struct/,/^end # type/' \
  /Users/jdlara/cache/psy6/PowerOpenAPIModels/PowerOperationsOpenAPIModels.jl/src/models/model_HydroTurbine.jl \
  /Users/jdlara/cache/psy6/PowerOpenAPIModels/PowerOperationsOpenAPIModels.jl/src/models/model_HydroReservoir.jl
```
Note `cache_storage` (PSCB line 435) returns a `Tuple` when there is no storage table and
a `Dict` otherwise. Normalize it to always return a `Dict` — do not import the wart.

- [x] **Step 2: Write the failing test**

Create `test/test_openapi_generation.jl`:

```julia
function _generation()
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.OpenAPISystem(100.0)
    PDP.loadzone_csv_parser!(sys, data)
    PDP.bus_csv_parser!(sys, data)
    PDP.branch_csv_parser!(sys, data)
    PDP.dc_branch_csv_parser!(sys, data)
    PDP.gen_csv_parser!(sys, data)
    return sys, data
end

@testset "158 generators across the mapped types" begin
    sys, _ = _generation()
    counts = Dict(
        t => length(PDP.get_components(sys, t)) for t in [
            "ThermalStandard",
            "RenewableDispatch",
            "RenewableNonDispatch",
            "HydroTurbine",
            "HydroDispatch",
            "SynchronousCondenser",
            "EnergyReservoirStorage",
        ]
    )
    @test sum(values(counts)) == 158
    @test counts["ThermalStandard"] == 73
    @test counts["HydroTurbine"] == 19
    @test counts["HydroDispatch"] == 1
    @test counts["SynchronousCondenser"] == 3
    @test counts["EnergyReservoirStorage"] == 1
end

@testset "hydro turbines get reservoirs" begin
    sys, _ = _generation()
    @test !isempty(PDP.get_components(sys, "HydroReservoir"))
end

@testset "every generator bus reference resolves" begin
    sys, _ = _generation()
    bus_ids = Set(b.id for b in PDP.get_components(sys, "ACBus"))
    for t in ["ThermalStandard", "RenewableDispatch", "HydroTurbine", "SynchronousCondenser"]
        for g in PDP.get_components(sys, t)
            @test g.bus in bus_ids
        end
    end
end

@testset "thermal generators carry cost and limits" begin
    sys, _ = _generation()
    gen = first(PDP.get_components(sys, "ThermalStandard"))
    @test gen.operation_cost.cost_type == "THERMAL"
    @test gen.active_power_limits.max >= gen.active_power_limits.min
    @test gen.base_power > 0
end
```

Add `include("test_openapi_generation.jl")` to `test/runtests.jl`.

- [x] **Step 3: Run test to verify it fails**

Run: `julia --project=test test/runtests.jl`
Expected: FAIL with `UndefVarError: gen_csv_parser! not defined`

- [x] **Step 4: Implement the dispatch spine**

```julia
function _make_generator(::Val{T}, sys, data, gen, bus_id, storage) where {T}
    throw(
        IS.DataFormatError(
            "no OpenAPI mapping for generator type $T (name=$(gen.name), " *
            "fuel=$(gen.fuel), unit_type=$(gen.unit_type))",
        ),
    )
end

_make_generator(::Val{:ThermalStandard}, sys, data, gen, bus_id, storage) =
    make_thermal_generator(sys, data, gen, bus_id)
_make_generator(::Val{:RenewableDispatch}, sys, data, gen, bus_id, storage) =
    make_renewable_generator(sys, data, gen, bus_id, Val(:RenewableDispatch))
_make_generator(::Val{:RenewableNonDispatch}, sys, data, gen, bus_id, storage) =
    make_renewable_generator(sys, data, gen, bus_id, Val(:RenewableNonDispatch))
_make_generator(::Val{:HydroTurbine}, sys, data, gen, bus_id, storage) =
    make_hydro_turbine(sys, data, gen, bus_id, storage)
_make_generator(::Val{:HydroDispatch}, sys, data, gen, bus_id, storage) =
    make_hydro_dispatch(sys, data, gen, bus_id)
_make_generator(::Val{:SynchronousCondenser}, sys, data, gen, bus_id, storage) =
    make_synchronous_condenser(sys, data, gen, bus_id)
_make_generator(::Val{:EnergyReservoirStorage}, sys, data, gen, bus_id, storage) =
    make_storage(sys, data, gen, bus_id, storage)

function gen_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    reg = get_registry(sys)
    storage = cache_storage(data)
    for gen in iterate_rows(data, InputCategory.GENERATOR)
        bus_id = get_bus_id(reg, Int(gen.bus_id))
        type_name = get_generator_type(gen.fuel, gen.unit_type, data.generator_mapping)
        component = _make_generator(Val(Symbol(type_name)), sys, data, gen, bus_id, storage)
        add_component!(sys, component)
    end
    return
end
```

- [x] **Step 5: Implement each maker**

Transcribe the PSCB originals using the Task 7 pattern — allocate empty, `set_value!` each
property. Units: `"MW"` for active power, `"MVAr"` for reactive, `"MVA"` for `rating` and
`base_power`, `"MW/min"` for ramps, `"h"` for time limits, `"1"` for fractions.
Compound properties use the NamedTuple form: `active_power_limits`,
`reactive_power_limits` (`MinMax`), `ramp_limits`, `time_limits` (`UpDown`), storage
`efficiency` (`InOut`).

`make_hydro_turbine` must also call `make_hydro_reservoirs!`, add each reservoir to the
system, and link them. Read PSCB lines 1208–1315 for the head/tail semantics.

- [x] **Step 6: Run test to verify it passes**

Run: `julia --project=test test/runtests.jl`
Expected: PASS

- [x] **Step 7: Format and stage**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
git add -N src/openapi/generation.jl test/test_openapi_generation.jl
```

---

### Task 12: Load and service parsers

**Files:** Create `src/openapi/load.jl`, `src/openapi/service.jl`;
Test `test/test_openapi_load_service.jl`

**Interfaces:** `load_csv_parser!(sys, data)`, `services_csv_parser!(sys, data)`,
`get_reserve_direction(direction) -> String`

RTS has no `load.csv`, so `get_dataframe` returns empty and Task 13's loop skips the load
parser. Implement it anyway for other datasets. Reserve→device contribution is a
many-to-many relation with no SiennaSchemas representation; it is **not** emitted, and
Task 16 asserts that omission explicitly rather than leaving it silent.

- [x] **Step 1: Write the failing test**

Create `test/test_openapi_load_service.jl`:

```julia
@testset "get_reserve_direction maps to the enum" begin
    @test PDP.get_reserve_direction("Up") == "UP"
    @test PDP.get_reserve_direction("Down") == "DOWN"
    @test_throws IS.DataFormatError PDP.get_reserve_direction("Sideways")
end

@testset "every reserve product is emitted" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.OpenAPISystem(100.0)
    PDP.loadzone_csv_parser!(sys, data)
    PDP.bus_csv_parser!(sys, data)
    PDP.services_csv_parser!(sys, data)
    n =
        length(PDP.get_components(sys, "VariableReserve")) +
        length(PDP.get_components(sys, "ConstantReserve"))
    @test n == DataFrames.nrow(PDP.get_dataframe(data, PDP.InputCategory.RESERVE))
    @test n == 7
end

@testset "reserves carry direction, requirement and time frame" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.OpenAPISystem(100.0)
    PDP.loadzone_csv_parser!(sys, data)
    PDP.bus_csv_parser!(sys, data)
    PDP.services_csv_parser!(sys, data)
    for r in PDP.get_components(sys, "VariableReserve")
        @test r.reserve_direction in ("UP", "DOWN")
        @test r.requirement >= 0
        @test r.time_frame > 0
    end
end
```

Add `include("test_openapi_load_service.jl")` to `test/runtests.jl`.

- [x] **Step 2: Run test to verify it fails**

Run: `julia --project=test test/runtests.jl`
Expected: FAIL with `UndefVarError: get_reserve_direction not defined`

- [x] **Step 3: Implement**

```julia
function get_reserve_direction(direction::AbstractString)
    normalized = uppercase(strip(direction))
    if normalized == "UP"
        return "UP"
    end
    if normalized == "DOWN"
        return "DOWN"
    end
    throw(IS.DataFormatError("invalid reserve direction=$direction"))
end
```

Build reserves and loads with the Task 7 pattern. In `load_csv_parser!`, names may collide
with the `PowerLoad` entries `bus_csv_parser!` already registered; prefix colliding names
with `"load_"` and let `register!` throw if the prefixed name also collides.

Add both includes to the module.

- [x] **Step 4: Run test to verify it passes**

Run: `julia --project=test test/runtests.jl`
Expected: PASS

- [x] **Step 5: Format and stage**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
git add -N src/openapi/load.jl src/openapi/service.jl test/test_openapi_load_service.jl
```

---

### Task 13: build_openapi_system

**Files:** Create `src/openapi/build.jl`; Test `test/test_openapi_build.jl`

**Interfaces:** `build_openapi_system(data; time_series_directory = nothing) -> OpenAPISystem`

- [x] **Step 1: Write the failing test**

Create `test/test_openapi_build.jl`:

```julia
@testset "build_openapi_system assembles RTS" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)
    @test PDP.get_base_power(sys) == 100.0
    @test length(PDP.get_components(sys, "ACBus")) == 73
    @test !isempty(PDP.get_components(sys, "ThermalStandard"))
    @test !isempty(PDP.get_components(sys, "VariableReserve"))
end

@testset "every component id is unique across all types" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)
    ids = Int[]
    for t in PDP.component_type_names(sys)
        append!(ids, [c.id for c in PDP.get_components(sys, t)])
    end
    @test length(ids) == length(unique(ids))
end
```

Add `include("test_openapi_build.jl")` to `test/runtests.jl`.

- [x] **Step 2: Run test to verify it fails**

Run: `julia --project=test test/runtests.jl`
Expected: FAIL with `UndefVarError: build_openapi_system not defined`

- [x] **Step 3: Implement**

```julia
function build_openapi_system(
    data::PowerSystemTableData;
    time_series_directory = nothing,
)
    sys = OpenAPISystem(data.base_power)

    loadzone_csv_parser!(sys, data)
    bus_csv_parser!(sys, data)

    parsers = (
        (get_dataframe(data, InputCategory.BRANCH), branch_csv_parser!),
        (get_dataframe(data, InputCategory.DC_BRANCH), dc_branch_csv_parser!),
        (get_dataframe(data, InputCategory.GENERATOR), gen_csv_parser!),
        (get_dataframe(data, InputCategory.LOAD), load_csv_parser!),
        (get_dataframe(data, InputCategory.RESERVE), services_csv_parser!),
    )
    for (df, parser) in parsers
        if !isempty(df)
            parser(sys, data)
        end
    end

    if !isnothing(data.timeseries_metadata_file)
        add_time_series!(sys, data.timeseries_metadata_file)
    end

    return sys
end
```

`add_time_series!` arrives in Task 14. Stub it as a no-op here and delete the stub then.

Add `include("openapi/build.jl")` last among the parser includes.

- [x] **Step 4: Run test to verify it passes**

Run: `julia --project=test test/runtests.jl`
Expected: PASS

- [x] **Step 5: Format and stage**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
git add -N src/openapi/build.jl test/test_openapi_build.jl
```

---

### Task 14: Time series and HDF5

**Files:** Create `src/openapi/time_series.jl`; Modify `src/openapi/build.jl`;
Test `test/test_openapi_time_series.jl`

**[fixes review defect 7]** `IS.read_time_series(entry, path)` does not exist. The real
method is `read_time_series(metadata::TimeSeriesFileMetadata; kwargs...)`
(`time_series_formats.jl:34`), and it returns a `RawTimeSeries` whose `data` is a `Dict`
of **every column in the CSV** (lines 201–213) — not a `TimeArray`, not filtered to
`component_name`. The column-selection and timestamp-construction step must be written
explicitly. `read_time_series_file_metadata` already absolutizes `data_file`
(`time_series_parser.jl:147–150`), so do not re-join the path.

**[fixes review defect 8]** Owner lookup narrows by `entry.category` via `find_by_name`.
A name-only search is ambiguous: RTS aliases the zone column to the area column, so `"1"`,
`"2"`, `"3"` each match both an `Area` and a `LoadZone`.

**Per design D10**, emit one association per pointer entry — **260** for RTS. Each series
appears at 3600 s and 300 s, sharing owner and name. Do not deduplicate on (owner, name).

**Interfaces:**
- `add_time_series!(sys, metadata_file) -> Nothing`
- `write_time_series(sys, h5_path) -> Nothing`
- `category_to_type_names(category::AbstractString) -> Vector{String}`

- [x] **Step 1: Establish the reading path**

```bash
sed -n '1,80p;190,230p' /Users/jdlara/cache/psy6/InfrastructureSystems.jl/src/time_series_formats.jl
grep -n 'function Hdf5TimeSeriesStorage' -A 25 \
  /Users/jdlara/cache/psy6/InfrastructureSystems.jl/src/hdf5_time_series_storage.jl
```
Record how `RawTimeSeries.data` is keyed and how to select the column for
`component_name`.

- [x] **Step 2: Write the failing test**

Create `test/test_openapi_time_series.jl`:

```julia
@testset "category maps to candidate component types" begin
    @test "LoadZone" in PDP.category_to_type_names("LoadZone")
    @test "ThermalStandard" in PDP.category_to_type_names("Generator")
    @test !("Area" in PDP.category_to_type_names("LoadZone"))
end

@testset "one association per pointer entry, both resolutions kept" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)
    @test length(sys.time_series_associations) == 260
    resolutions = Set(a.resolution for a in sys.time_series_associations)
    @test length(resolutions) == 2
end

@testset "every association owner resolves" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)
    ids = Set{Int}()
    for t in PDP.component_type_names(sys)
        union!(ids, Set(c.id for c in PDP.get_components(sys, t)))
    end
    for a in sys.time_series_associations
        @test a.owner_id in ids
        @test a.owner_category == "Component"
        @test !isempty(a.time_series_uuid)
    end
end

@testset "LoadZone series resolve to the zone, not the area" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)
    zone_ids = Set(z.id for z in PDP.get_components(sys, "LoadZone"))
    zone_assocs = [a for a in sys.time_series_associations if a.owner_type == "LoadZone"]
    @test length(zone_assocs) == 6
    for a in zone_assocs
        @test a.owner_id in zone_ids
    end
end

@testset "write_time_series emits one group per uuid" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)
    mktempdir() do dir
        path = joinpath(dir, "ts.h5")
        PDP.write_time_series(sys, path)
        uuids = Set(a.time_series_uuid for a in sys.time_series_associations)
        HDF5.h5open(path, "r") do f
            @test length(keys(f["time_series"])) == length(uuids)
        end
    end
end
```

Add `include("test_openapi_time_series.jl")` to `test/runtests.jl` and `import HDF5` to
the preamble.

- [x] **Step 3: Run test to verify it fails**

Run: `julia --project=test test/runtests.jl`
Expected: FAIL with `UndefVarError: category_to_type_names not defined`

- [x] **Step 4: Implement**

```julia
const CATEGORY_TO_TYPES = Dict(
    "Generator" => [
        "ThermalStandard",
        "RenewableDispatch",
        "RenewableNonDispatch",
        "HydroTurbine",
        "HydroDispatch",
        "SynchronousCondenser",
        "EnergyReservoirStorage",
    ],
    "ElectricLoad" => ["PowerLoad", "StandardLoad"],
    "LoadZone" => ["LoadZone"],
    "Area" => ["Area"],
    "Reserve" => ["VariableReserve", "ConstantReserve"],
    "Storage" => ["EnergyReservoirStorage"],
)

function category_to_type_names(category::AbstractString)
    key = String(category)
    if !haskey(CATEGORY_TO_TYPES, key)
        throw(IS.DataFormatError("unmapped time series category=$category"))
    end
    return CATEGORY_TO_TYPES[key]
end

function _iso_duration(period::Dates.Period)
    return string("PT", Dates.value(Dates.Second(period)), "S")
end
```

`add_time_series!` iterates `IS.read_time_series_file_metadata(metadata_file)`, and for
each entry:

1. `owner_type, owner_id = find_by_name(reg, category_to_type_names(entry.category), entry.component_name)`
2. Read the raw file with `IS.read_time_series(entry)` (no path argument), then select the
   column for `entry.component_name` from `RawTimeSeries.data` and build a
   `TimeSeries.TimeArray` from `entry.resolution` and `RawTimeSeries.initial_time`.
3. `ts = IS.SingleTimeSeries(entry.name, ta; normalization_factor = entry.normalization_factor)`
4. `push!(sys.time_series, ts)`
5. Build a `PC.TimeSeriesAssociation` with `id = ix`, `time_series_uuid = string(IS.get_uuid(ts))`,
   `time_series_type = "SingleTimeSeries"`, `initial_timestamp` as a `ZonedDateTime` in UTC,
   `resolution = _iso_duration(entry.resolution)`, `length = length(ts)`, `name = entry.name`,
   `owner_id`, `owner_type`, `owner_category = "Component"`, `features = []`,
   `scaling_factor_multiplier = entry.scaling_factor_multiplier`,
   `metadata_uuid = string(UUIDs.uuid4())`.

`write_time_series` opens an `IS.Hdf5TimeSeriesStorage` at `h5_path` and calls
`IS.serialize_time_series!(storage, ts)` for each stored series. That call deduplicates on
UUID, which is what makes the group-count assertion hold.

Remove the `add_time_series!` stub from `build.jl`; add
`include("openapi/time_series.jl")` before it.

- [x] **Step 5: Run test to verify it passes**

Run: `julia --project=test test/runtests.jl`
Expected: PASS

- [x] **Step 6: Format and stage**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
git add -N src/openapi/time_series.jl test/test_openapi_time_series.jl
```

---

### Task 15: to_json

**Files:** Create `src/openapi/serialize.jl`; Test `test/test_openapi_serialize.jl`

**[fixes review defect 10]** `OpenAPI.to_json(o)` returns a **String** (`json.jl:59`).
Revision 1 nested those strings inside a Dict and re-encoded, producing double-encoded
JSON that the shape tests still passed. The fix: build the tree holding the **raw model
objects** and call `JSON.json` once. `JSON.lower(::APIModel)` returns a `JSONWrapper`
(`json.jl:9, 26`) that iterates properties and skips `nothing`, so nesting and optional
fields are handled.

**[fixes review defect 12]** The byte-determinism test is removed. Time series UUIDs come
from `uuid4`, so two builds differ by construction. Determinism would require
content-derived UUIDs — a format decision, out of scope for this plan. Key ordering is
still made deterministic via `component_type_names`, and the test asserts that instead.

**Interfaces:** `to_json(sys, filename; force = false, pretty = false)`,
`time_series_filename(filename) -> String`, `serialize(sys, ts_basename) -> Dict`

- [x] **Step 1: Write the failing test**

Create `test/test_openapi_serialize.jl`:

```julia
@testset "time_series_filename follows the PSY sibling convention" begin
    @test PDP.time_series_filename("rts.json") == "rts_time_series_storage.h5"
    @test PDP.time_series_filename("/a/b/rts.json") == "rts_time_series_storage.h5"
end

@testset "to_json writes both files" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)
    mktempdir() do dir
        path = joinpath(dir, "rts.json")
        PDP.to_json(sys, path)
        @test isfile(path)
        @test isfile(joinpath(dir, "rts_time_series_storage.h5"))
    end
end

@testset "to_json refuses to overwrite without force" begin
    sys = PDP.OpenAPISystem(100.0)
    mktempdir() do dir
        path = joinpath(dir, "x.json")
        PDP.to_json(sys, path)
        @test_throws ErrorException PDP.to_json(sys, path)
        PDP.to_json(sys, path; force = true)
    end
end

@testset "components serialize as objects, not encoded strings" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)
    mktempdir() do dir
        path = joinpath(dir, "rts.json")
        PDP.to_json(sys, path)
        doc = JSON3.read(read(path, String))
        bus = doc["components"]["ACBus"][1]
        @test haskey(bus, "name")
        @test bus["base_voltage"] isa Number
    end
end

@testset "document top-level shape" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)
    mktempdir() do dir
        path = joinpath(dir, "rts.json")
        PDP.to_json(sys, path)
        doc = JSON3.read(read(path, String))
        @test doc["base_power"] == 100.0
        @test doc["time_series_storage_file"] == "rts_time_series_storage.h5"
        @test length(doc["components"]["ACBus"]) == 73
        @test length(doc["time_series_associations"]) == 260
        @test haskey(doc, "supplemental_attributes")
        @test haskey(doc, "supplemental_attribute_associations")
    end
end

@testset "unset optional properties are omitted, not null" begin
    sys = PDP.OpenAPISystem(100.0)
    bus = PDP.PO.ACBus()
    PDP.set_value!(bus, :id, 1)
    PDP.set_value!(bus, :name, "Abel")
    PDP.add_component!(sys, bus)
    mktempdir() do dir
        path = joinpath(dir, "x.json")
        PDP.to_json(sys, path)
        doc = JSON3.read(read(path, String))
        @test !haskey(doc["components"]["ACBus"][1], "base_voltage")
    end
end

@testset "component type keys are sorted" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)
    @test PDP.component_type_names(sys) == sort(PDP.component_type_names(sys))
end
```

Add `include("test_openapi_serialize.jl")` to `test/runtests.jl` and `import JSON3` to the
preamble.

- [x] **Step 2: Run test to verify it fails**

Run: `julia --project=test test/runtests.jl`
Expected: FAIL with `UndefVarError: time_series_filename not defined`

- [x] **Step 3: Implement**

```julia
function time_series_filename(filename::AbstractString)
    return string(splitext(basename(filename))[1], "_time_series_storage.h5")
end

function _bucket(components::Vector{T}) where {T <: OpenAPI.APIModel}
    return collect(components)
end

function serialize(sys::OpenAPISystem, ts_basename::AbstractString)
    components = Dict{String, Any}()
    for type_name in component_type_names(sys)
        components[type_name] = _bucket(get_components(sys, type_name))
    end
    return Dict{String, Any}(
        "base_power" => get_base_power(sys),
        "components" => components,
        "supplemental_attributes" => sys.supplemental_attributes,
        "supplemental_attribute_associations" => [
            Dict("attribute_id" => a.attribute_id, "entity_id" => a.entity_id) for
            a in sys.supplemental_attribute_associations
        ],
        "time_series_associations" => sys.time_series_associations,
        "time_series_storage_file" => ts_basename,
    )
end

function to_json(
    sys::OpenAPISystem,
    filename::AbstractString;
    force = false,
    pretty = false,
)
    ts_basename = time_series_filename(filename)
    ts_path = joinpath(dirname(abspath(filename)), ts_basename)
    if !force && (isfile(filename) || isfile(ts_path))
        error("$filename or $ts_path already exists. Set force=true to overwrite.")
    end
    rm(ts_path; force = true)

    write_time_series(sys, ts_path)
    data = serialize(sys, ts_basename)
    open(filename, "w") do io
        if pretty
            JSON.print(io, data, 2)
        else
            JSON.print(io, data)
        end
    end
    @info "Serialized OpenAPISystem to $filename and $ts_path"
    return
end
```

`_bucket` is the function barrier — one specialization per concrete component vector, so
the inner work stays inferable despite `components` being `Dict{String, Vector}`.

- [x] **Step 4: Run test to verify it passes**

Run: `julia --project=test test/runtests.jl`
Expected: PASS

- [x] **Step 5: Format and stage**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
git add -N src/openapi/serialize.jl test/test_openapi_serialize.jl
```

---

### Task 16: RTS-GMLC acceptance

**Files:** Create `test/test_openapi_acceptance.jl`

**[fixes review significant problem 4]** The schema validation must merge Core into the
operations schema store and use a resolver — `openapi-operations-bundled.json` holds 68
schemas and does **not** contain Core types (`MinMax` is absent), and
`jsonschema.validate` against a bare subschema cannot resolve `#/components/schemas/...`
references.

- [x] **Step 1: Write the acceptance test**

Create `test/test_openapi_acceptance.jl`:

```julia
@testset "RTS-GMLC acceptance" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)

    @testset "component counts" begin
        @test length(PDP.get_components(sys, "ACBus")) == 73
        @test length(PDP.get_components(sys, "Area")) == 3
        @test length(PDP.get_components(sys, "LoadZone")) == 3
        @test length(PDP.get_components(sys, "Line")) == 105
        @test length(PDP.get_components(sys, "TwoWindingTransformer")) == 15
        @test length(PDP.get_components(sys, "TwoTerminalGenericHVDCLine")) == 1
        @test length(PDP.get_components(sys, "ThermalStandard")) == 73
        @test length(PDP.get_components(sys, "HydroTurbine")) == 19
    end

    @testset "referential integrity" begin
        ids = Set{Int}()
        for t in PDP.component_type_names(sys)
            union!(ids, Set(c.id for c in PDP.get_components(sys, t)))
        end
        arc_ids = Set(a.id for a in PDP.get_components(sys, "Arc"))
        bus_ids = Set(b.id for b in PDP.get_components(sys, "ACBus"))

        for bus in PDP.get_components(sys, "ACBus")
            @test bus.area in ids
            @test bus.load_zone in ids
        end
        for line in PDP.get_components(sys, "Line")
            @test line.arc in arc_ids
        end
        for gen in PDP.get_components(sys, "ThermalStandard")
            @test gen.bus in bus_ids
        end
        for a in sys.time_series_associations
            @test a.owner_id in ids
        end
    end

    @testset "required properties are populated" begin
        for t in PDP.component_type_names(sys)
            for c in PDP.get_components(sys, t)
                @test OpenAPI.check_required(c)
            end
        end
    end

    @testset "both files, both resolutions" begin
        mktempdir() do dir
            path = joinpath(dir, "rts.json")
            PDP.to_json(sys, path; pretty = true)
            h5 = joinpath(dir, "rts_time_series_storage.h5")
            @test isfile(path)
            @test isfile(h5)
            uuids = Set(a.time_series_uuid for a in sys.time_series_associations)
            HDF5.h5open(h5, "r") do f
                @test length(keys(f["time_series"])) == length(uuids)
            end
        end
    end

    @testset "known omissions are asserted, not silent" begin
        # Reserve -> device contribution is many-to-many with no SiennaSchemas
        # representation (design D5). Deliberately not emitted.
        @test isempty(sys.supplemental_attributes)
        @test isempty(sys.supplemental_attribute_associations)
    end
end
```

Add `include("test_openapi_acceptance.jl")` to `test/runtests.jl`, last, and `import OpenAPI`
to the preamble.

- [x] **Step 2: Run the full suite**

Run: `julia --project=test test/runtests.jl`
Expected: PASS.

- [x] **Step 3: Validate against SiennaSchemas**

```bash
julia --project=test -e '
using PowerTableDataParser, PowerSystemCaseBuilder
const PDP = PowerTableDataParser
d = joinpath(PowerSystemCaseBuilder.DATA_DIR, "RTS_GMLC")
data = PDP.PowerSystemTableData(d, 100.0, joinpath(d, "user_descriptors.yaml"))
PDP.to_json(PDP.build_openapi_system(data), "/tmp/rts.json"; force = true, pretty = true)'

python3 - <<'PY'
import json
from jsonschema import Draft202012Validator
from referencing import Registry, Resource

S = "/Users/jdlara/cache/psy6/SiennaSchemas/dist"
schemas = {}
for domain in ("core", "operations"):
    spec = json.load(open(f"{S}/openapi-{domain}-bundled.json"))
    schemas.update(spec["components"]["schemas"])

root = {"components": {"schemas": schemas}}
registry = Registry().with_resource("", Resource.from_contents(root, default_specification=Draft202012Validator.META_SCHEMA))

doc = json.load(open("/tmp/rts.json"))
bad = 0
for type_name, items in doc["components"].items():
    if type_name not in schemas:
        print("NO SCHEMA:", type_name)
        continue
    v = Draft202012Validator(schemas[type_name], registry=registry)
    for item in items:
        for e in v.iter_errors(item):
            bad += 1
            print(type_name, item.get("name"), e.message)
            if bad > 30:
                raise SystemExit(1)
print("validation failures:", bad)
PY
```
Expected: `validation failures: 0` and no `NO SCHEMA` lines.

- [x] **Step 4: Format and stage**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
git add -N test/test_openapi_acceptance.jl
```

- [x] **Step 5: Report**

Report component counts per type, association count (expect 260), h5 size, and the schema
validation result. Leave everything unstaged.

---

## Self-Review

**Design coverage:**

| Decision | Task |
|---|---|
| D1 hand-written container | 5 |
| D2 generated unit methods | 1 |
| D3 empty-construct + unit-checked setters | 4, and 7–12 call sites |
| D4 one global id space | 3 |
| D5 association tables | 5, 14, 15 |
| D6 IS storage + JSON associations | 14 |
| D7 mirror PSCB | 6–13 |
| D8 write only | 15 |
| D9 transformer pair, first-class arcs | 8 |
| D10 keep every resolution | 14 |
| RTS acceptance | 16 |

**Review defect coverage:**

| Defect | Task | Fix |
|---|---|---|
| 1 unqualified unit methods | 1 | qualified extensions, fallbacks in Core only |
| 2 cross-quantity conversion | 1, 4 | vocabulary keyed `(quantity, unit)`, quantity compared |
| 3 kW test / missing units | 4 | test uses real vocabulary units |
| 4 hydro mapping | 11 | `HydroTurbine` + `HydroReservoir` path |
| 5 generator lookup | 6 | `get_generator_type` ported |
| 6 DC descriptor names | 9 | verified field list, `TwoTerminalGenericHVDCLine` |
| 7 `read_time_series` | 14 | correct signature, explicit column selection |
| 8 ambiguous owner | 3, 14 | `find_by_name` narrowed by category |
| 9 bus enum | 7 | `uppercase(bus.bus_type)` |
| 10 double-encoded JSON | 15 | single `JSON.print` over raw models |
| 11 `ComplexNumber` fields | 7 | branch removed; names recorded |
| 12 determinism test | 15 | removed, replaced with key-ordering test |
| 13 OpenAPI compat | 2 | `"0.2"` |
| SP1 cost semantics | 10 | `FuelCurve` + `create_pwinc_cost` |
| SP2 transformer data loss | 8 | shunt, base voltages, descriptor angle limits |
| SP3 dual resolution | 14 | withdrawn; D10 keeps both |
| SP4 python validation | 16 | merged core+operations, `referencing` registry |
| SP5 Aqua stale deps | 2 | HDF5/JSON3 to `test/Project.toml` |
| SP6 Task 1 tooling | 1 | `SCHEMA_DIR=` export, `--project` on the julia call |
| SP7 D3 contradiction | 4, 7–12 | no kwarg construction; compound setters |

**Remaining soft spots**, flagged rather than hidden:

1. Tasks 9, 10, 11 open with a "establish the reference behaviour" step instead of finished
   code. That is deliberate — revision 1 guessed at exactly these three and was wrong in all
   three. The commands are exact; the transcription is real work.
2. Task 11's Solar dispatch/non-dispatch split is stated as 31 `RenewableNonDispatch` from
   RTPV, but the boundary comes from `generator_mapping_cdm.yaml` and must be confirmed in
   Step 1.
3. The 105/15 Line/transformer split comes from applying PSCB's tap rule to `branch.csv`.
   If Task 8 fails only on that split, re-derive before changing code.
4. `HydroReservoir` count has no asserted value — PSCB's head/tail semantics over
   `storage.csv`'s 22 rows determine it, and it was not derived while writing this plan.
