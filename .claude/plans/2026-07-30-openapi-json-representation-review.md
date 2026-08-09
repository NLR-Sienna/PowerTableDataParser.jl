# Adversarial Review — OpenAPI JSON Representation Plan

**Date:** 2026-07-30
**Reviewer:** Fable (adversarial pass), spot-checked against source
**Reviews:** `2026-07-30-openapi-json-representation-design.md`, `2026-07-30-openapi-json-representation-plan.md`
**Status:** plan is NOT safe to execute as written

## Verdict

Scaffolding tasks (3, 5, and most of 7–8) are sound, and the RTS counts are right. But
five independent show-stoppers hit in sequence: the Task 1 unit emitter produces methods
`PC.has_declared_unit` can never see, which kills `set_value!` for every Operations type;
the generator-type lookup fails for all 73 thermal units; the hydro mapping is wrong for
19 of 20 hydro units; Task 9's DC-branch descriptor fields do not exist; and Task 14 calls
an `IS.read_time_series` method that does not exist and misuses its return type. Separately,
`OpenAPI.to_json` returns a JSON *string*, so the serializer emits double-encoded output
that the plan's own shape tests would not catch.

## Blocking defects

1. **Emitted unit methods never extend Core's functions.** `emit_units.jl` writes
   unqualified `has_declared_unit(...) = ...` into every package and re-emits fallbacks in
   each. `PowerOperationsOpenAPIModels.jl:4` does `using PowerCoreOpenAPIModels`, so those
   definitions create a *new local function* rather than extending `PC.has_declared_unit`.
   Task 4's `convert_to_declared` calls `PC.has_declared_unit`, hits only Core's fallback,
   and returns `false` for every `PO.` type — every `set_value!` in Tasks 7–12 throws.
   Exporting the same eight names from two packages also makes the Task 1 test ambiguous.
   *Fix:* emit qualified extensions (`PowerCoreOpenAPIModels.has_declared_unit(...)`) in
   non-core packages; emit fallbacks once, in Core.

2. **`convert_to_declared` allows cross-quantity conversion.** The emitter drops
   `quantity_type` (`Dict{String, Float64}`), contradicting the Task 1 Interfaces block
   which promises a `NamedTuple{(:quantity_type, :to_default)}`. MW and kV both have
   `to_default: 1.0`, so Task 4's "rejects a mismatched quantity" test *fails* — the value
   converts silently. MWh→MW and MW→MVA convert too. Worse, unit strings are not unique
   keys: 55 entries / 45 unique units, with `pu`, `ohm`, `S`, `m`, `1` duplicated and `m`
   carrying conflicting factors `{1.0, 0.001}`. *Fix:* carry `quantity_type` and compare it
   before converting.

3. **Task 4's kW test cannot pass.** `kW`, `GW`, and `GWh` are absent from `units.json`, so
   `set_value!(gen, :base_power, 100_000.0, "kW")` throws instead of converting. It also
   contradicts the schema — `base_power` is `MVA` (ApparentPower), making kW→MVA exactly
   the cross-quantity case defect 2 should reject. Design D3's claim that RTS never
   declares `unit:` is **false**: RTS `user_descriptors.yaml` has `unit: degree`,
   `unit: GWh`, `unit: GW`, handled only by the ported PSCB `convert_units!`.

4. **Hydro mapping is wrong for 19 of 20 units.** Both `src/generator_mapping_cdm.yaml` and
   RTS's own mapping send `{fuel: HYDRO, type: HYDRO}` → `HydroTurbine`; only
   `{HYDRO, ROR}` (1 unit) → `HydroDispatch`. PSCB routes HydroTurbine through
   `make_hydro_turbine` (line 1272) + `_make_hydro_reservoirs` (line 1208), consuming
   `storage.csv`'s 22 head/tail rows. Task 11 has no `HydroTurbine`/`HydroReservoir` path;
   19 generators hit the catch-all error and the 158-total test fails. `PO.HydroTurbine`
   and `PO.HydroReservoir` exist in the generated models.

5. **Generator-type lookup throws for every thermal unit.** Mapping keys are uppercase with
   `unit_type = nothing` for thermals (`{fuel: COAL, type: null}`); `gen.csv` supplies
   `fuel="Coal"`, `unit_type="STEAM"`. The plan's direct `haskey` is false for all 73
   thermal rows. PSCB's `get_generator_type` (PSCB `common.jl:102–120`) uppercases and
   retries with `(unit_type, nothing) × (fuel, nothing)`. That function must be ported.

6. **Task 9's DC-branch field mapping is fabricated.** Actual `dc_branch` descriptor names:
   `connection_points_from/to, active_power_flow, mw_load, rate, control_mode,
   dc_line_category, loss, rectifier_firing_angle_max/min, rectifier_xrc,
   rectifier_tap_limits_max/min, inverter_firing_angle_max/min, inverter_xrc,
   inverter_tap_limits_max/min, min/max_active/reactive_power_limit_from/to`. **None** of
   `r`, `rectifier_bridges`, `inverter_bridges`, `transfer_setpoint`,
   `scheduled_dc_voltage`, `rectifier_rc`, `rectifier_xc`, `inverter_rc`, `inverter_xc`,
   `rectifier_base_voltage`, `inverter_base_voltage`, or the delay/extinction-angle-limit
   names exist. Every row access errors. Unrecorded divergence: PSCB emits
   `TwoTerminalGenericHVDCLine` for `Control Mode == "Power"` (RTS's DC1), not an LCC line.

7. **Task 14's time-series core cannot work.**
   `IS.read_time_series(entry, path)` is a MethodError — the methods are
   `read_time_series(metadata::TimeSeriesFileMetadata; kwargs...)`
   (`time_series_formats.jl:34`) and `read_time_series(::Type{T}, data_file, component_name)`
   (line 15); the path fix-up is redundant since `read_time_series_file_metadata` already
   absolutizes `data_file` (`time_series_parser.jl:147–150`). The return is a
   `RawTimeSeries` holding a `Dict` of *every* CSV column, not a `TimeArray` and not
   filtered to `component_name`, so `IS.SingleTimeSeries(; data = raw, …)` fails. The plan
   skips the column-selection and timestamp-construction step entirely.

8. **`_resolve_owner` throws "ambiguous" for all six LoadZone series.** RTS's zone column is
   aliased to the Area column, so the registry holds both `("Area","1")` and
   `("LoadZone","1")`. Name-only search finds two matches and throws. `entry.category`
   (`"LoadZone"`) is available and ignored. *Fix:* narrow by category.

9. **`bustype = bus.bus_type` fails enum validation.** RTS `Bus Type` values are
   `{PQ: 40, PV: 32, Ref: 1}`; generated validation requires
   `["PQ","PV","REF","ISOLATED","SLACK"]` (`model_ACBus.jl:86`). The `"Ref"` bus throws in
   the inner constructor. PSCB normalizes via `get_enum_value(ACBusTypes, …)` (line 169).

10. **`OpenAPI.to_json` returns a `String`** (`OpenAPI/src/json.jl:59`: `to_json(o) = JSON.json(o)`).
    Task 15 puts those strings in a Dict written with `JSON3.write`, so `components.ACBus`
    becomes an array of 73 JSON-containing strings. The plan's shape test
    (`length(doc["components"]["ACBus"]) == 73`) still passes, so this ships silently.
    *Fix:* use `JSON.json` on raw models (OpenAPI defines `JSON.lower(::APIModel)`,
    `json.jl:26`) or convert to Dicts first.

11. **`PC.ComplexNumber` has fields `real`/`imag`, not `re`/`im`.** Task 7's kwargs error.
    Moot for RTS: `user_descriptors.yaml` maps shunts to `mw_shunt_g`/`mvar_shut_b`, names
    absent from `power_system_inputs.json`, so no `FixedAdmittance` is ever emitted.

12. **Task 15's byte-determinism test cannot pass.** Time series UUIDs come from
    `InfrastructureSystemsInternal()` (uuid4) and `UUIDs.uuid4()`. Two builds differ by
    construction. Determinism needs content-derived UUIDs — a design decision, not a test
    tweak.

13. **`OpenAPI = "0.1"` compat is wrong.** Installed and required is **0.2.2**
    (`~/.julia/packages/OpenAPI/5LBLo/Project.toml`). Breaks resolution at Task 2 Step 4.

## Significant problems

1. **Task 10 invents cost semantics.** RTS supplies heat-rate columns and `fuel_price`;
   `heat_rate_a0/a1/a2` default to `nothing`. PSCB therefore takes the `create_pwinc_cost`
   branch (line 921) wrapped in a **`FuelCurve`** with `fuel_price/1000` — not
   `CostCurve(InputOutputCurve(...))`. PSCB's `create_poly_cost` (line 891) reads
   a-coefficients and never fits a quadratic. The plan drops fuel price and encodes the
   invented behavior in its tests, so they pass while diverging from D7.

2. **Transformer output drops data.** PSCB sets `magnetizing_shunt = branch.primary_shunt`
   and `base_voltage_primary/secondary` from the buses (lines 280–295); `_add_transformer!`
   sets neither. Line `angle_limits` are hardcoded to ±π/2 although
   `min_angle_limits`/`max_angle_limits` descriptors exist and PSCB uses them.

3. ~~**DA/RT multi-resolution ingestion is an unrecorded decision.**~~ **WITHDRAWN — the
   review was wrong here.** IS4 treats resolution as part of a series' identity, not as a
   filter: `system_data.jl:545` states "interval are skipped, allowing multiple calls with
   different resolutions to coexist", and the associations table carries
   `resolution TEXT NOT NULL` inside its lookup key
   (`["owner_uuid", "time_series_type", "name", "resolution", "interval", "features"]`).
   The `DataFormatError` claim traces to PSCB's `make_system` docstring, which is stale
   relative to IS4. `TimeSeriesAssociation` already requires `resolution`, so the OpenAPI
   format carries DA and RT natively. Ingesting both is correct; collapsing to one
   resolution would be a regression against PSY serialization. The plan already emits one
   association per pointer entry (260) and needs no change. Recorded as design decision D10.

4. **Task 16 Step 3's Python validation cannot work.** `openapi-operations-bundled.json`
   holds 68 schemas and does **not** contain Core types (`MinMax` absent), and
   `jsonschema.validate` on a bare subschema cannot resolve `#/components/schemas/...`
   refs. Needs a merged core+operations store and a resolver.

5. **Aqua will fail.** `test/runtests.jl:20` runs `Aqua.test_stale_deps`. Task 2 puts `HDF5`
   in package `[deps]` but only test code uses it — src goes through IS. Move to
   `test/Project.toml`.

6. **Task 1 tooling gaps.** `make generate` ends with plain `julia scripts/reorganize.jl`
   (no `--project`), so `import JSON3` depends on the default environment. The Makefile
   `SCHEMA_DIR` export is required, not optional. Task 2 modifies `test/Project.toml` with
   no content given (PowerCore/PowerOperations `[sources]`, HDF5, JSON3 all needed).

7. **D3 and the plan contradict each other.** Most numerics enter through constructor
   kwargs (`voltage_limits`, `b`, `g`, `angle_limits`, LoadZone peaks, reserve
   `requirement`, every MinMax/UpDown member), bypassing `set_value!` and unit checking.
   Either D3 is aspirational or compound fields need coverage.

## Minor issues

- `unit isa AbstractString` in the emitter and `isa AbstractString`/`isa Real` in the
  Task 6 test violate the stated no-`isa` rule.
- `get_branch_type(…, ::Union{Bool, Nothing})` + `isnothing` keeps a nothing-sentinel;
  mirrors PSCB, but Global Constraints forbid it without noting the exception.
- Exported `to_json` collides with `PowerSystems.to_json` in the test env.
- `cache_storage` (PSCB line 435) returns a `Tuple` on the no-storage path and a `Dict`
  otherwise — a wart "transcribe the original" imports silently.
- `_iso_duration` output (`PT3600S`) is fine; the schema's `resolution` is free-form ISO-8601.
- 410 fixed `x-unit` count verified correct; the 49/5 discriminated/unit-base counts were
  not independently verified.

## Verified correct

- Counts: 73 buses, 158 generators, 120 branches (105 Line / 15 transformer under PSCB's
  tap rule), 1 DC branch, 3 Areas, 3 LoadZones (correct only because `user_descriptors.yaml`
  aliases `zone` to the Area column — worth a comment), 7 reserves, 60 dc_branch columns,
  gen distribution 73/61/20/3/1, 12 parallel bus pairs justifying arc dedup on
  `(from_id, to_id)`.
- API: `IS.read_time_series_file_metadata`, `IS.Hdf5TimeSeriesStorage(true; filename=…)`,
  `IS.serialize_time_series!` (UUID-deduping, matching the h5-group test logic),
  `IS.get_uuid`, `IS.get_initial_timestamp`, `Base.length(::StaticTimeSeries)`,
  `TimeSeriesFileMetadata` fields, `SingleTimeSeries` kwargs incl. `normalization_factor`,
  OpenAPI `setproperty!` interception at `client.jl:225`, per-model `OpenAPI.check_required`.
- Structs: `PC.MinMax/UpDown/FromTo/InOut/XYCoords/FeatureValue/TimeSeriesAssociation`
  (all 17 association fields used, incl. `units`), `PO.ACBus`, `PO.Arc(from_id,to_id)`,
  `PO.LoadZone(peak_*)`, `PO.FixedAdmittance.Y`, the D9 transformer split, every
  `TwoTerminalLCCLine` field named, `VariableReserve.time_frame`, `CostCurve.power_units`
  default, `ThermalGenerationCost.cost_type` default.
- All 19 cited PSCB line numbers are accurate. Package UUIDs match the real `Project.toml`s.
  No `SupplementalAttributeAssociation` schema exists in SiennaSchemas (D5 checks out).

## Required plan revisions

Before execution, Tasks 1, 4, 9, 10, 11, 14, 15 need rework, and Task 2's compat pin fixed.
Tasks 3, 5, 6, 7 (minus the enum and `ComplexNumber` fixes), 8, 12, 13, and 16's structure
survive. Design D3 needs either a scope narrowing or compound-field coverage. Dual-resolution
pointers need no change — see withdrawn item 3 and design D10.
