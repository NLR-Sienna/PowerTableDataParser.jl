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
    # 260 pointer entries, of which the 6 zone load series fan out to the loads.
    @test length(sys.time_series) == 362
    @test length(_rows_by_series(sys.time_series)) == 260
    resolutions = Set(IS.get_resolution(row.series) for row in sys.time_series)
    @test resolutions ==
          Set([Dates.Millisecond(Dates.Hour(1)), Dates.Millisecond(Dates.Minute(5))])
end

@testset "a multiplier becomes device-base units on normalized values" begin
    sys = _built()
    # Every RTS pointer entry declares a scaling_factor_multiplier, so every
    # series stores normalized values tagged with the device-base units label
    # in place of the removed multiplier metadata.
    @test all(IS.get_units(row.series) == PDP.DEVICE_BASE_UNITS for row in sys.time_series)
    zone_rows = [r for r in sys.time_series if r.owner_type == "LoadZone"]
    # Normalized by the zone peak: per-unit values, nothing above 1.
    for row in zone_rows
        @test maximum(IS.get_array(row.series)) <= 1.0
    end
end

@testset "a zone's load series fans out to the loads under it" begin
    sys = _built()
    loads = [r for r in sys.time_series if r.owner_type == "PowerLoad"]
    # 51 loads at each of the two resolutions.
    @test length(loads) == 102

    zones = [r for r in sys.time_series if r.owner_type == "LoadZone"]
    @test length(zones) == 6

    # The fan-out is rows against one shared series, not copied data.
    groups = _rows_by_series(vcat(loads, zones))
    @test length(groups) == 6
    for rows in values(groups)
        # One zone plus the loads beneath it share each series.
        @test count(r -> r.owner_type == "LoadZone", rows) == 1
        @test count(r -> r.owner_type == "PowerLoad", rows) == length(rows) - 1
    end
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
    zone_by_series = Dict(
        r.series => r.owner_id for r in sys.time_series if r.owner_type == "LoadZone"
    )
    for row in sys.time_series
        if row.owner_type != "PowerLoad"
            continue
        end
        @test zone_of_load[row.owner_id] == zone_by_series[row.series]
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
    @test all(r -> IS.get_units(r.series) == PDP.DEVICE_BASE_UNITS, reserve_rows)
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
            metadata = InfraStore.list_time_series(store)
            # One catalog row per staged association.
            @test length(metadata) == length(sys.time_series)

            # The arrays are content-addressed: the store holds exactly the
            # distinct value arrays that were staged, however many owners
            # reference each.
            staged_arrays = Set(IS.get_array(row.series) for row in sys.time_series)
            @test length(Set(m.data_hash for m in metadata)) == length(staged_arrays)

            # The device-base units label survives the round trip.
            @test all(m.units == PDP.DEVICE_BASE_UNITS for m in metadata)

            # A full value round trip for one association.
            row = first(r for r in sys.time_series if r.owner_type == "OnlineReserve")
            stored = InfraStore.get_time_series(
                InfraStore.SingleTimeSeries,
                store,
                row.owner_id,
                InfraStore.Component,
                IS.get_name(row.series);
                resolution = IS.get_resolution(row.series),
            )
            @test stored.data == IS.get_array(row.series)
            @test stored.initial_timestamp == IS.get_initial_timestamp(row.series)
        finally
            InfraStore.close!(store)
        end
    end
end
