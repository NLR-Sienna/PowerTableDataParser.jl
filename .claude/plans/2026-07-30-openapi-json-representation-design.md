# Design: OpenAPI JSON Representation for PowerTableDataParser

**Date:** 2026-07-30
**Status:** approved (brainstorming complete)
**Repos touched:** `PowerTableDataParser.jl` (primary), `PowerOpenAPIModels` (prerequisite)

## Problem

`PowerTableDataParser` reads CSV tables into `DataFrames` and stops there. The code that
turns those tables into components lives in `PowerSystemCaseBuilder`
(`src/parsers/power_system_table_data.jl`, 1671 lines) and targets `PowerSystems.jl` types.

We want a second, independent output target: tabular data rendered as the Sienna OpenAPI
JSON representation, paired with an HDF5 time series file — the same two-file shape
`PowerSystems.to_json` produces.

## Goal

```julia
data = PowerSystemTableData(RTS_GMLC_DIR, 100.0, user_descriptors)
sys  = build_openapi_system(data)
to_json(sys, "rts.json")
# -> rts.json
# -> rts_time_series_storage.h5
```

## Non-goals

- `from_json` / round-trip reading. Write only.
- Any change to `PowerSystems.jl` or `PowerSystemCaseBuilder`. The PSY parser stays put.
- Building a `System`. PTDP emits JSON + HDF5; PSY6 deserializes it later. The schemas are
  the contract, so neither side depends on the other. PTDP depends only on
  `InfrastructureSystems` (IS4) and the generated OpenAPI model packages.
- Components RTS-GMLC does not exercise: `ThermalMultiStart`, hydro pump storage,
  `MarketBidCost`, `HybridSystem`.

## Decisions

Each of these was chosen explicitly during brainstorming; the rejected alternatives are
recorded because they will look attractive again later.

### D1 — The container is hand-written in PTDP

SiennaSchemas defines 111 per-component schemas and no top-level system schema. Rather
than add one, PTDP owns the container struct and its JSON layout. Component payloads are
still generated OpenAPI structs, so each component validates against its schema even
though the envelope does not.

*Rejected:* adding `System.json` to SiennaSchemas (blocks on a Schemas release and
regeneration); mirroring PSY's `__metadata__`/UUID document shape (imports IS
serialization conventions into an integer-id world).

*Consequence:* the envelope has no schema behind it. Combined with D8 (write only),
nothing validates the envelope's shape. Accepted knowingly; see Risks.

### D2 — Units are generated as methods on the type

`openapi-generator` strips `x-unit` vendor extensions, so the generated Julia structs carry
units only as prose in docstrings. `PowerOpenAPIModels/scripts/reorganize.jl` gains a step
that reads SiennaSchemas' `dist/openapi-*-bundled.json` and `Core/units.json` and emits a
`units.jl` into each package.

Both the structs and their units come out of the same generation run, so they cannot drift.

*Rejected:* a runtime lookup table vendored into PTDP (drifts); Unitful-typed fields
(needs custom mustache templates, a synthetic `pu` outside Unitful's dimensional system,
and breaks every existing consumer); `{value, unit}` pairs in the JSON (reverses the
`x-unit` design that just landed in SiennaSchemas PR #15, ~410 redundant strings per
system, GridDB column-mapping churn).

The schemas already split this correctly and the generated API mirrors the split:

| Annotation | Count | Emitted as |
|---|---:|---|
| `x-unit` — fixed per type | 410 | `declared_unit(::Type{T}, ::Val{P})` |
| `x-units` + discriminator — varies per instance | 49 | `declared_unit(o::T, ::Val{P})`, reading a sibling field |
| `x-unit-base` — pu on a sibling property | 5 | `unit_base(::Type{T}, ::Val{P})` |

### D3 — Construct empty, then set; every setter is unit-checked

**No keyword-argument construction.** The builder allocates an empty component and
populates it one property at a time:

```julia
gen = PO.ThermalStandard()
set_value!(gen, :name, "101_STEAM_3")
set_value!(gen, :base_power, 76.0, "MVA")
set_value!(gen, :active_power_limits, (min = 15.2, max = 76.0), "MW")
```

This mirrors how OpenAPI.jl itself moves data in and out of these types:

| Direction | OpenAPI.jl | PTDP |
|---|---|---|
| in | `from_json(::Type{T}, json) = from_json(T(), json)` then per-property (`json.jl:62`, `91–97`) | `T()` then per-property `set_value!` |
| out | `lower(o) = JSONWrapper(o)`, iterating properties and skipping `nothing` (`json.jl:9`, `26`) | same — unset properties are simply absent |

Kwarg construction was the earlier design and it was wrong: it routes most numerics —
`voltage_limits`, `b`, `g`, `angle_limits`, `active_power_limits`, every `MinMax`/`UpDown`
member — around the unit check entirely, leaving D3 decorative. Empty-construct-then-set
has no such bypass, because there is only one way in.

Unlike OpenAPI.jl's deserializer, which populates with `setfield!`, `set_value!` goes
through `setproperty!`. That triggers the generated `validate_property`
(`OpenAPI/src/client.jl:225`), so enum and range validation runs on every assignment.

**The two arities are the enforcement.**

- `set_value!(o, prop, value, unit)` — required when the property declares a unit; throws
  if it does not.
- `set_value!(o, prop, value)` — for properties with no declared unit; throws if the
  property *does* declare one.

Neither arity can be used where the other belongs, so a united property cannot be written
without naming its unit, and the check cannot be skipped by picking the shorter call.

**Compound properties carry the unit at the object level.** `ACBus.voltage_limits` is
annotated `x-unit: pu` on the `MinMax` itself, not its members. `set_value!` accepts a
`NamedTuple` for these and applies the unit to every member:

```julia
set_value!(bus, :voltage_limits, (min = 0.95, max = 1.05), "pu")   # -> PC.MinMax
set_value!(gen, :ramp_limits, (up = 3.0, down = 3.0), "MW/min")    # -> PC.UpDown
set_value!(line, :b, (from = 0.0225, to = 0.0225), "pu")           # -> PC.FromTo
```

**Getters mirror the setters.** `get_value(o, prop)` returns the stored value;
`get_value(o, prop, unit)` returns it converted to the requested unit, throwing on a
quantity mismatch.

Where `units.json` records no conversion factor — `to_default: 0.0` for `Angle`, `null`
for pu bases — conversion throws rather than guessing. Same-unit assignment always
succeeds, so this only blocks genuine conversions.

RTS-GMLC does declare `unit:` in three places (`degree` for bus angle, `GWh` and `GW` for
storage), none of which `units.json` can convert. Those are handled upstream by the ported
PSCB `convert_units!` (`common.jl:191–252`) during `_read_data_row`, so values reach
`set_value!` already in the descriptor's target unit.

### D4 — One global id space

GridDB assigns component ids from a single `entities` table, unique across all types.
PTDP matches that: one monotonic counter, no per-type numbering.

Source bus numbers are not ids. `ACBus` has both `id` (assigned) and `number` (from the
CSV), so RTS's bus numbering survives without colliding with the id space.

### D5 — Associations get their own tables

Mirroring GridDB's `supplemental_attributes` / `supplemental_attributes_association`
split, links live in dedicated top-level tables rather than embedded in components.

`TimeSeriesAssociation` already exists as a SiennaSchemas type generated into
`PowerCoreOpenAPIModels`, including a `units` field. It is used as-is.

There is **no** `SupplementalAttributeAssociation` schema in SiennaSchemas. That link
record is hand-written in the container using GridDB's column names (`attribute_id`,
`entity_id`). RTS produces zero supplemental attributes — PSCB's table parser creates
none — so both supplemental tables serialize empty. The shape exists for later use.

### D6 — Time series via IS's storage layer, associations in JSON

`IS.serialize_time_series!(storage::Hdf5TimeSeriesStorage, ts::TimeSeriesData)` requires
only the time series — no owning component. `IS.SingleTimeSeries(name, data)` likewise.
So PTDP drives IS's HDF5 layer directly without ever constructing an IS component, and the
resulting file matches PSY's layout (`/time_series/<uuid>` groups).

IS's SQLite metadata store is skipped. The JSON's `time_series_associations` table is the
single source of association truth.

*Rejected:* wrapping OpenAPI components in a thin IS component to use the full
`TimeSeriesManager` (duplicates association truth across the JSON and the h5's embedded
metadata db); writing HDF5 by hand (reimplements a versioned format IS owns).

### D7 — Mirror PSCB's structure

Same function names, same call order, same decomposition as
`PowerSystemCaseBuilder/src/parsers/power_system_table_data.jl`, so the two are diffable
and validation is a mechanical comparison. Diverge only where the OpenAPI target forces it
(see D9).

`_get_field_infos` and `_read_data_row` port over unchanged — they already implement the
descriptor-driven per-unit machinery.

### D8 — Write only

No `from_json`. Acceptance is validating emitted components against their schemas plus
structural assertions on the document.

### D9 — Structural divergences from PSY

The OpenAPI model is not a field-for-field copy of PSY at the component level. Two
divergences change the parser:

**Transformers are a pair.** PSY's `TwoWindingTransformer` carries `r`, `x`, `tap`,
`arc`, and ratings. The OpenAPI `TwoWindingTransformer` carries only
`id, name, circuit, magnetizing_shunt, shunt_location`; the electrical parameters live in
`TransformerCircuit` (`arc, tap, alpha, r, x, rating, rating_b, rating_c,
base_voltage_primary, base_voltage_secondary, …`). `TransformerCircuit` has no `name`
field. Each RTS transformer therefore emits two components with two ids.

**Arcs are first-class.** `Line.arc`, `TransformerCircuit.arc`, and
`TwoTerminalLCCLine.arc` are `Int64` references to `Arc` components, which must be created
and registered before the branches that reference them.

### D12 — Cost construction mirrors PSCB exactly, including its oddities

PSCB is what the modeling stack actually uses, so PTDP reproduces its arithmetic rather
than correcting it. Any error is then visible at the PSY deserialization step instead of
being masked by a divergence between the two parsers.

RTS supplies **incremental heat rates**, not cost points, so `make_cost` takes the
`_HeatRateColumns` branch: `heat_rate_a0/a1/a2` are all `nothing`, so `create_poly_cost` is
skipped and `create_pwinc_cost` runs. `create_pwl_cost` is unreachable for this dataset —
it belongs to the `_CostPointColumns` branch.

For `101_STEAM_3` (PMax 76 MW):

```julia
ThermalGenerationCost(
  variable = FuelCurve(
    variable_cost_type = "FUEL",
    power_units        = "NATURAL_UNITS",
    fuel_cost          = 0.00211399,               # Fuel Price $/MMBTU / 1000
    value_curve = IncrementalCurve(
      curve_type    = "INCREMENTAL",
      initial_input = 398100.0,                    # HR_avg_0 * x_coords[1]
      function_data = PiecewiseStepData(
        x_coords = [30.0, 45.333, 60.667, 76.0],   # Output_pct * PMax, MW
        y_coords = [6713.0, 8028.0, 8549.0],       # HR_incr, one per segment
      ),
    ),
    vom_cost = InputOutputCurve(LinearFunctionData(...)),
  ),
  fixed = 0.0, start_up = …, shut_down = …,
)
```

`y_coords` are per-segment slopes, so `length(y_coords) == length(x_coords) - 1`. The count
is data-dependent: `get_cost_pairs` truncates at the first non-increasing `x`, which is how
RTS's `NA` columns in `Output_pct_4` / `HR_incr_4` are dropped.

Three PSCB behaviours reproduced deliberately, flagged because they are not self-evident:

- `initial_input = HR_avg_0 * x_coords[1]` multiplies a rate by a power to get total heat
  at the first point.
- `fuel_price = gen.fuel_price / 1000.0`, an unexplained scaling that touches every thermal
  cost.
- `get_cost_pairs` computes `base_power = gen.base_mva * gen.active_power_limits_max`,
  undoing the device-base conversion `_read_data_row` applied, to recover MW.

**No cost type declares a unit.** `FuelCurve`, `IncrementalCurve`, `PiecewiseStepData`,
`CostCurve` and `XYCoords` carry zero `x-unit` annotations, so every cost numeric uses the
3-argument `set_value!` and is unchecked. The units above hold by convention only.

### D13 — PTDP owns its RTS descriptor; the zero sync-condenser base is upstream

The fixture's `user_descriptors.yaml` mapped `base_mva` to the `MATPOWER BaseMVA`
column, which is `100.0` for all 158 generators, and flagged itself
`#TODO just for testing`. The real column is `Base MVA`: 24 for `101_CT_1`, 89 for
`101_STEAM_3`, up to 847.

PTDP now ships `test/descriptors/rts_user_descriptors.yaml`, a copy with that one line
corrected, rather than inheriting a fixture that lives inside PowerSystemCaseBuilder's
artifact — which the dependency boundary excludes anyway.

The natural-units mode makes most fields immune to this: `active_power_limits` no longer
divides by a base at all. What it fixes is `base_power`, emitted straight from `base_mva`,
which would otherwise have carried the system base for every generator.

**Open, needs a decision at Task 11.** Correcting the mapping exposed genuine bad data
upstream: the three synchronous condensers declare `Base MVA = 0` while injecting 103–167
MVAr with `QMax = 200`. Verified in `GridMod/RTS-GMLC v0.2.2`
`RTS_Data/SourceData/gen.csv`, so it is not a Sienna fixture artifact. It was invisible
before because every generator read 100.0.

Three options, none obviously right:

- Mirror PSCB (`power_system_table_data.jl:701-705`): warn and substitute the system base.
  Keeps PSY parity per D12, but writes 100 MVA for a 200 MVAr machine.
- Error out. Honest, but no RTS system can be built until the source data is fixed.
- Derive the base from the reactive rating, `max(|QMax|, |QMin|)` = 200 MVA. Physically
  sensible, but invents a value and diverges from PSCB.

### D11 — `Arc.from` / `Arc.to` renamed to `from_id` / `to_id`

`from` is a Python keyword, so datamodel-codegen emitted
`from_: int = Field(..., alias="from")`. It worked — pydantic round-tripped the `"from"`
JSON key correctly — but every Python consumer had to know that one attribute is spelled
differently from its serialized name.

Renamed in `Operations/Topology/Arc.json`, the only schema with a bare `from`/`to`
property. Both stacks regenerate clean: Julia gets `Arc(id, from_id, to_id)`, Python gets
plain `from_id`/`to_id` with no alias.

`from_id`/`to_id` rather than `from_bus`/`to_bus` because GridDB's `arcs` table already
uses exactly those column names, so the schema and the database now agree instead of
carrying a third spelling between them.

This makes SiennaSchemas a fourth repo in scope, which the original non-goals excluded,
and the rename is a breaking schema change for anything already reading `Arc`.

*Not renamed:* `Core/common.json`'s `FromTo`, whose members are also `from`/`to` and hit
the same Python collision (`from_` with an alias). Its members are values at each end of a
branch — shunt susceptance on `Line.b`, conductance on `Line.g` — not id references, so an
`_id` suffix would be wrong. It is also a shared value type, so the blast radius is far
wider than `Arc`'s single use. Left as-is pending a separate decision.

### D10 — Every resolution of a series is kept

RTS ships each series twice: DAY_AHEAD at 3600 s and REAL_TIME at 300 s, 260 pointer
entries in total. Both are emitted, one `TimeSeriesAssociation` per pointer entry.

This matches PSY, where resolution is part of a series' identity rather than a filter.
`InfrastructureSystems/src/system_data.jl:545` — "interval are skipped, allowing multiple
calls with different resolutions to coexist" — and the associations table keys on
`["owner_uuid", "time_series_type", "name", "resolution", "interval", "features"]` with
`resolution TEXT NOT NULL`. `TimeSeriesAssociation` already requires `resolution`, so the
OpenAPI document carries the distinction natively.

Collapsing to a single resolution would lose data PSY serialization already preserves.
That is a regression, not a simplification.

The `DataFormatError` on mixed resolutions in PSCB's `make_system` docstring is stale
relative to IS4 and does not apply.

*Consequence for Task 14:* `_resolve_owner` must not deduplicate on (owner, name) — the
DA and RT entries share both. One association per pointer entry, distinguished by
`resolution`.

## Architecture

```
PowerSystemTableData  (existing — CSV -> DataFrames + descriptors)
        |
        v
build_openapi_system                        src/openapi/build.jl
  |-- IdRegistry                            src/openapi/identity.jl
  |-- set_value! (unit-checked)             src/openapi/units.jl
  |-- *_csv_parser!  (mirrors PSCB)         src/openapi/{topology,branch,generation,load,service}.jl
  |-- make_cost helpers                     src/openapi/cost.jl
  v
OpenAPISystem                               src/openapi/container.jl
  |-- add_time_series!                      src/openapi/time_series.jl
  v
to_json                                     src/openapi/serialize.jl
  -> <base>.json + <base>_time_series_storage.h5
```

### Component ordering

Topology first, then everything that references it, matching PSCB:

1. `loadzone_csv_parser!` — `LoadZone`
2. `bus_csv_parser!` — `Area`, `ACBus`, plus `PowerLoad` / `FixedAdmittance` for nonzero bus rows
3. `branch_csv_parser!` — `Arc`, `Line`, `TwoWindingTransformer` + `TransformerCircuit`
4. `dc_branch_csv_parser!` — `Arc`, `TwoTerminalLCCLine`
5. `gen_csv_parser!` — thermal / renewable / hydro / sync cond / storage
6. `load_csv_parser!` — `PowerLoad`
7. `services_csv_parser!` — `VariableReserve`, `ConstantReserve`
8. `add_time_series!` — HDF5 + associations

### Document shape

```json
{
  "base_power": 100.0,
  "components": {
    "ACBus": [ {"id": 1, "number": 101, "name": "Abel", ...} ],
    "Line":  [ {"id": 200, "name": "A1", "arc": 150, "r": 0.003, ...} ]
  },
  "supplemental_attributes": [],
  "supplemental_attribute_associations": [],
  "time_series_associations": [
    {"id": 1, "owner_id": 42, "owner_type": "ThermalStandard",
     "owner_category": "Component", "name": "max_active_power",
     "time_series_uuid": "…", "time_series_type": "SingleTimeSeries",
     "initial_timestamp": "2020-01-01T00:00:00+00:00", "resolution": "PT1H",
     "length": 8784, "features": [], "metadata_uuid": "…"}
  ],
  "time_series_storage_file": "rts_time_series_storage.h5"
}
```

`components` keys are sorted at write time so output is byte-deterministic.

### Identity resolution

RTS references components three ways, so `IdRegistry` keeps three indices:

| Reference style | Example | Index |
|---|---|---|
| bus number | `branch.csv` `From Bus` = 101 | `bus_number => id` |
| component name | `gen.csv` `GEN UID` | `(type_name, name) => id` |
| area / zone name | `bus.csv` `Area` = "1" | `(type_name, name) => id` |

Arcs are deduplicated on `(from_id, to_id)` so parallel circuits share one `Arc`.

## Testing

Acceptance is RTS-GMLC end to end:

- component counts per type (73 buses, 158 generators, 120 branches, 1 DC line, reserves)
- referential integrity: every `arc`, `bus`, `area`, `load_zone` and `owner_id` resolves
  to a registered id
- every emitted component validates against its SiennaSchemas definition
- the h5 contains exactly one group per distinct `time_series_uuid`
- unit tests for `IdRegistry` and for `set_value!` conversion and rejection

## Risks

**Two-repo sequencing.** `PowerOpenAPIModels` must emit `units.jl` before PTDP can build
against it. That work is Task 1 and gates everything else.

**Unvalidated envelope.** D1 plus D8 means nothing checks the container's shape. Component
payloads are schema-validated; the envelope is covered only by structural assertions in
the acceptance test. Adding `from_json` with a write→read→write equality test would close
this and remains the obvious follow-up.

**Type instability in the container.** `components` holds heterogeneous vectors keyed by
type name. Serialization must go through a function barrier to stay inferable.

**Divergence drift.** D9 lists the structural differences from PSY known today. More will
surface during the port; each one is a place where mirroring PSCB (D7) breaks down and
needs a recorded decision.
