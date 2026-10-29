const _HEX_HASH_RE = r"^[0-9a-f]{64}$"

function _built()
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    return PDP.build_openapi_system(data)
end

# Staged rows grouped by the series they reference. The fan-out shares one
# series object across its owners, so those rows always group; separately
# constructed series never collide because no two entries agree on all of
# (name, resolution, data).
function _rows_by_series(rows)
    groups = Dict{IS.SingleTimeSeries, Vector{PDP.StagedTimeSeries}}()
    for row in rows
        push!(get!(groups, row.series, PDP.StagedTimeSeries[]), row)
    end
    return groups
end

@testset "category maps to candidate component types" begin
    @test "LoadZone" in PDP.category_to_type_names("LoadZone")
    @test "ThermalStandard" in PDP.category_to_type_names("Generator")
    @test !("Area" in PDP.category_to_type_names("LoadZone"))
    @test_throws IS.DataFormatError PDP.category_to_type_names("Weather")
end

@testset "one staged row per owner, both resolutions kept" begin
    sys = _built()
    # 256 pointer entries (after the fixture filter), of which the 6 zone load series fan
    # out to the loads; each zone keeps a natural-units series of its own.
    @test length(sys.time_series) == 358
    @test length(_rows_by_series(sys.time_series)) == 262
    resolutions = Set(IS.get_resolution(row.series) for row in sys.time_series)
    @test resolutions ==
          Set([Dates.Millisecond(Dates.Hour(1)), Dates.Millisecond(Dates.Minute(5))])
end

@testset "keep_time_series_resolution! drops the other resolution" begin
    sys = _built()
    total = length(sys.time_series)
    hourly = count(r -> IS.get_resolution(r.series) == Dates.Hour(1), sys.time_series)
    @test 0 < hourly < total

    PDP.keep_time_series_resolution!(sys, Dates.Hour(1))
    @test length(sys.time_series) == hourly
    @test all(IS.get_resolution(r.series) == Dates.Hour(1) for r in sys.time_series)

    # The staging is what the sidecar is written from, so the drop reaches the store and
    # the document rows alike. Going through `write_time_series` is the real path: the rows
    # describe the catalog that was committed, not the staged objects.
    mktempdir() do dir
        rows = PDP.write_time_series(sys, joinpath(dir, "ts.h5"))
        @test length(rows) == hourly
    end

    # `nothing` keeps everything; a resolution nothing was staged at errors rather than
    # silently emptying the bundle.
    PDP.keep_time_series_resolution!(sys, nothing)
    @test length(sys.time_series) == hourly
    @test_throws IS.DataFormatError PDP.keep_time_series_resolution!(sys, Dates.Minute(5))
end

# Owners whose series PowerSystems takes in natural units, so the parser converts them.
_is_natural(row) =
    row.owner_type == "LoadZone" || IS.get_name(row.series) in ("inflow", "outflow")

@testset "a multiplier becomes device-base units on normalized values" begin
    sys = _built()
    # Every RTS pointer entry declares a scaling_factor_multiplier. Series PowerSystems
    # takes per unit keep the normalized values, tagged with the device-base label in place
    # of the removed multiplier metadata; the rest are converted to MW.
    for row in sys.time_series
        expected = _is_natural(row) ? IS.NU : PDP.COMPONENT_BASE_UNIT_SYSTEM
        @test IS.get_unit_system(row.series) == expected
    end
    # A zone's series is its total load: the profile times its peak, never above the peak.
    for row in filter(r -> r.owner_type == "LoadZone", sys.time_series)
        zone = PDP._component(sys, "LoadZone", row.owner_id)
        peak = PDP.get_value(zone, :peak_active_power, "MW")
        @test 1.0 < maximum(IS.get_array(row.series)) <= peak
    end
end

@testset "a normalized series declares its basis and the quantity it scales to" begin
    sys = _built()
    # Every RTS pointer declares a multiplier, so every series states a basis. `units` is
    # set only on the natural-units ones: a per-unit basis is not a units label.
    for row in sys.time_series
        @test IS.get_units(row.series) == (_is_natural(row) ? "MW" : nothing)
        @test !isnothing(IS.get_quantity_kind(row.series))
    end

    # The quantity is the multiplier's own, not the accessor name. RTS reservoirs are
    # accounted in ENERGY, so a level is energy and an inflow active power.
    by_name = Dict(
        IS.get_name(r.series) => IS.get_quantity_kind(r.series) for r in sys.time_series
    )
    @test by_name["max_active_power"] == "active_power"
    @test by_name["requirement"] == "active_power"
    @test by_name["storage_capacity"] == "energy"
    @test by_name["inflow"] == "active_power"
end

@testset "a reservoir series filed under a turbine lands on its reservoir" begin
    sys = _built()
    # The RTS pointer file files inflow and storage capacity under the turbines.
    reservoir_rows = filter(
        r -> IS.get_name(r.series) in ("inflow", "storage_capacity"),
        sys.time_series,
    )
    @test !isempty(reservoir_rows)
    @test all(r -> r.owner_type == "HydroReservoir", reservoir_rows)
    # An inflow is in MW: the profile times the reservoir's 1.0 inflow, read on the system
    # base as psy5's formulations did.
    raw = only(
        p for p in PDP.read_time_series_pointers(
            joinpath(RTS_GMLC_DIR, "timeseries_pointers.json"),
        )
        if p.name == "inflow" && p.component_name == "122_HYDRO_1" &&
        p.resolution == Dates.Millisecond(Dates.Hour(1))
    )
    turbine_id = PDP.get_id(PDP.get_registry(sys), "HydroTurbine", "122_HYDRO_1")
    row = only(
        r for r in reservoir_rows if IS.get_name(r.series) == "inflow" &&
        r.owner_id == PDP._head_reservoir_id(sys, "HydroTurbine", turbine_id) &&
        IS.get_resolution(r.series) == raw.resolution
    )
    df = DataFrames.DataFrame(PDP.CSV.File(raw.data_file))
    values, _ = PDP.read_pointer_csv_values(df, raw.component_name, raw.resolution)
    @test IS.get_array(row.series) ≈
          PDP._normalized(values, raw.normalization_factor) .* PDP.get_base_power(sys)

    # A generator with no reservoir cannot carry one.
    entry = PDP.TimeSeriesPointer(
        "Generator", "201_HYDRO_4", "inflow", 1.0, "f.csv", Dates.Hour(1), "get_inflow",
    )
    dispatch_id = PDP.get_id(PDP.get_registry(sys), "HydroDispatch", "201_HYDRO_4")
    @test_throws IS.DataFormatError PDP._series_basis(
        sys, entry, "HydroDispatch", dispatch_id,
    )
end

@testset "an unmapped or unnormalized multiplier is not silently unstated" begin
    sys = _built()
    reservoir = first(PDP.get_components(sys, "HydroReservoir"))
    entry = PDP.TimeSeriesPointer(
        "Component", "x", "inflow", 1.0, "f.csv", Dates.Hour(1), "get_weather",
    )
    @test_throws IS.DataFormatError PDP._series_quantity_kind(
        sys, entry, "HydroReservoir", PDP.get_value(reservoir, :id),
    )

    # No multiplier means no declared basis, so no quantity to name either.
    bare = PDP.TimeSeriesPointer(
        "Component", "x", "inflow", 1.0, "f.csv", Dates.Hour(1), nothing,
    )
    @test isnothing(
        PDP._series_quantity_kind(
            sys, bare, "HydroReservoir", PDP.get_value(reservoir, :id),
        ),
    )
    @test isnothing(PDP._series_unit_system(bare))
end

@testset "a zone's load series fans out to the loads under it" begin
    sys = _built()
    loads = [r for r in sys.time_series if r.owner_type == "PowerLoad"]
    # 51 loads at each of the two resolutions.
    @test length(loads) == 102

    zones = [r for r in sys.time_series if r.owner_type == "LoadZone"]
    @test length(zones) == 6

    # The fan-out is rows against one shared series per zone, not copied data. The zone's
    # own series is in MW, so it is a separate one.
    @test length(_rows_by_series(loads)) == 6
    @test isempty(intersect(Set(r.series for r in loads), Set(r.series for r in zones)))
end

@testset "each fanned-out load belongs to the zone that owns the series" begin
    sys = _built()
    zone_of_bus = Dict(
        PDP.get_value(b, :id) => PDP.get_value(b, :load_zone) for
        b in PDP.get_components(sys, "ACBus")
    )
    zone_of_load = Dict(
        PDP.get_value(l, :id) => zone_of_bus[PDP.get_value(l, :bus)] for
        l in PDP.get_components(sys, "PowerLoad")
    )
    # The zone's MW series is its loads' shared profile times the zone peak.
    zone_series = Dict(
        (r.owner_id, IS.get_resolution(r.series)) => r.series for
        r in sys.time_series if r.owner_type == "LoadZone"
    )
    for row in sys.time_series
        if row.owner_type != "PowerLoad"
            continue
        end
        zone_id = zone_of_load[row.owner_id]
        zone = PDP._component(sys, "LoadZone", zone_id)
        zone_mw = zone_series[(zone_id, IS.get_resolution(row.series))]
        @test IS.get_array(zone_mw) ≈
              IS.get_array(row.series) .* PDP.get_value(zone, :peak_active_power, "MW")
    end
end

@testset "every staged owner resolves" begin
    sys = _built()
    ids = Set{Int}()
    for type_name in PDP.component_type_names(sys)
        union!(
            ids,
            Set(PDP.get_value(c, :id) for c in PDP.get_components(sys, type_name)),
        )
    end
    for row in sys.time_series
        @test row.owner_id in ids
        @test length(IS.get_array(row.series)) > 0
    end
end

@testset "LoadZone series resolve to the zone, not the area" begin
    sys = _built()
    zone_ids = Set(PDP.get_value(z, :id) for z in PDP.get_components(sys, "LoadZone"))
    zone_rows = [r for r in sys.time_series if r.owner_type == "LoadZone"]
    @test length(zone_rows) == 6
    for row in zone_rows
        @test row.owner_id in zone_ids
    end
end

@testset "reserve requirements are associated with the reserve" begin
    sys = _built()
    reserve_rows = [r for r in sys.time_series if r.owner_type == "OnlineReserve"]
    @test length(reserve_rows) == 12
    @test all(r -> IS.get_name(r.series) == "requirement", reserve_rows)
    @test all(
        r -> IS.get_unit_system(r.series) == PDP.COMPONENT_BASE_UNIT_SYSTEM,
        reserve_rows,
    )
end

@testset "write_time_series persists the catalog and dedups arrays" begin
    sys = _built()
    mktempdir() do dir
        path = joinpath(dir, "ts.h5")
        PDP.write_time_series(sys, path)
        @test isfile(path)
        @test isfile(path * ".sqlite")

        store = InfraStore.open_store(path; read_only = true)
        try
            metadata = InfraStore.list_metadata(store)
            # One catalog row per staged association.
            @test length(metadata) == length(sys.time_series)

            # The arrays are content-addressed: the store holds exactly the
            # distinct value arrays that were staged, however many owners
            # reference each.
            staged_arrays = Set(IS.get_array(row.series) for row in sys.time_series)
            @test length(Set(m.data_hash for m in metadata)) == length(staged_arrays)

            # The basis declaration survives the round trip. It rides on unit_system, not
            # the units label: a per-unit basis is not a unit.
            natural = count(_is_natural, sys.time_series)
            @test count(m -> m.unit_system == InfraStore.NaturalUnits, metadata) == natural
            @test count(m -> m.unit_system == InfraStore.ComponentBase, metadata) ==
                  length(metadata) - natural

            # A full value round trip for one association: resolve the catalog id from
            # the metadata already listed above, then read by id.
            row = first(r for r in sys.time_series if r.owner_type == "OnlineReserve")
            match = only(
                m for m in metadata if
                m.owner_type == row.owner_type &&
                m.owner_id == row.owner_id &&
                m.name == IS.get_name(row.series) &&
                m.resolution == IS.get_resolution(row.series)
            )
            stored = InfraStore.read_by_id(store, match.id)
            @test stored.data == IS.get_array(row.series)
            @test stored.initial_timestamp == IS.get_initial_timestamp(row.series)
        finally
            InfraStore.close!(store)
        end
    end
end

@testset "write_time_series orders its rows deterministically across builds" begin
    # The catalog is read back in raw store order, which is not guaranteed stable across
    # separate builds. `IS.openapi_time_series_association_rows` sorts by identity in the
    # store itself, so a document written twice lists its series identically.
    sys1 = _built()
    sys2 = _built()
    PDP.keep_time_series_resolution!(sys1, Dates.Hour(1))
    PDP.keep_time_series_resolution!(sys2, Dates.Hour(1))
    mktempdir() do dir
        rows1 = PDP.write_time_series(sys1, joinpath(dir, "ts1.h5"))
        rows2 = PDP.write_time_series(sys2, joinpath(dir, "ts2.h5"))
        key(row) = (row.value.owner_id, row.value.name)
        @test key.(rows1) == key.(rows2)
        @test issorted(key.(rows1))

        # The store speaks unit-style ISO durations (`PT1H`), not the seconds spelling
        # (`PT3600S`) IS's now-deleted `_openapi_duration` used to produce.
        @test all(row.value.resolution == "PT1H" for row in rows1)
        # `uri`/`data_hash` are the store's own content hash, not a caller-supplied
        # locator — the same hex string in both fields.
        @test all(occursin(_HEX_HASH_RE, row.value.uri) for row in rows1)
        @test all(row.value.data_hash == row.value.uri for row in rows1)
        @test all(occursin(_HEX_HASH_RE, row.value.uri) for row in rows2)
        @test all(row.value.data_hash == row.value.uri for row in rows2)
    end
end
