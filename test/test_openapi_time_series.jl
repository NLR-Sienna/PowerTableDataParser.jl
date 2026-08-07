function _built()
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    return PDP.build_openapi_system(data)
end

@testset "category maps to candidate component types" begin
    @test "LoadZone" in PDP.category_to_type_names("LoadZone")
    @test "ThermalStandard" in PDP.category_to_type_names("Generator")
    @test !("Area" in PDP.category_to_type_names("LoadZone"))
    @test_throws IS.DataFormatError PDP.category_to_type_names("Weather")
end

@testset "one association per owner, both resolutions kept" begin
    sys = _built()
    # 260 pointer entries, of which the 6 zone load series fan out to the loads.
    @test length(PDP.get_document(sys).time_series_associations) == 362
    resolutions = Set(
        PDP.get_value(a, :resolution) for
        a in PDP.get_document(sys).time_series_associations
    )
    @test resolutions == Set(["PT3600S", "PT300S"])
    @test length(sys.time_series) == 260
end

@testset "a zone's load series fans out to the loads under it" begin
    sys = _built()
    loads = [
        a for a in PDP.get_document(sys).time_series_associations if
        PDP.get_value(a, :owner_type) == "PowerLoad"
    ]
    # 51 loads at each of the two resolutions.
    @test length(loads) == 102
    @test all(
        PDP.get_value(a, :scaling_factor_multiplier) == "get_max_active_power" for
        a in loads
    )

    zones = [
        a for a in PDP.get_document(sys).time_series_associations if
        PDP.get_value(a, :owner_type) == "LoadZone"
    ]
    @test length(zones) == 6
    # The aggregation reads the same data through its own accessor.
    @test all(
        PDP.get_value(a, :scaling_factor_multiplier) == "get_peak_active_power" for
        a in zones
    )

    # The fan-out is association rows against one series, not copied data.
    by_uuid = Dict{String, Vector{String}}()
    for association in vcat(loads, zones)
        push!(
            get!(by_uuid, PDP.get_value(association, :time_series_uuid), String[]),
            PDP.get_value(association, :owner_type),
        )
    end
    @test length(by_uuid) == 6
    for owners in values(by_uuid)
        # One zone plus the loads beneath it share each series.
        @test count(==("LoadZone"), owners) == 1
        @test count(==("PowerLoad"), owners) == length(owners) - 1
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
    zone_by_uuid = Dict(
        PDP.get_value(a, :time_series_uuid) => PDP.get_value(a, :owner_id) for
        a in PDP.get_document(sys).time_series_associations if
        PDP.get_value(a, :owner_type) == "LoadZone"
    )
    for association in PDP.get_document(sys).time_series_associations
        if PDP.get_value(association, :owner_type) != "PowerLoad"
            continue
        end
        uuid = PDP.get_value(association, :time_series_uuid)
        @test zone_of_load[PDP.get_value(association, :owner_id)] == zone_by_uuid[uuid]
    end
end

@testset "every association owner resolves" begin
    sys = _built()
    ids = Set{Int}()
    for type_name in PDP.component_type_names(sys)
        union!(
            ids,
            Set(PDP.get_value(c, :id) for c in PDP.get_components(sys, type_name)),
        )
    end
    for association in PDP.get_document(sys).time_series_associations
        @test PDP.get_value(association, :owner_id) in ids
        @test PDP.get_value(association, :owner_category) == "Component"
        @test !isempty(PDP.get_value(association, :time_series_uuid))
        @test PDP.get_value(association, :length) > 0
        @test PDP.OpenAPI.check_required(association)
    end
end

@testset "LoadZone series resolve to the zone, not the area" begin
    sys = _built()
    zone_ids = Set(PDP.get_value(z, :id) for z in PDP.get_components(sys, "LoadZone"))
    zone_assocs = [
        a for a in PDP.get_document(sys).time_series_associations if
        PDP.get_value(a, :owner_type) == "LoadZone"
    ]
    @test length(zone_assocs) == 6
    for association in zone_assocs
        @test PDP.get_value(association, :owner_id) in zone_ids
    end
end

@testset "reserve requirements are associated with the reserve" begin
    sys = _built()
    reserve_assocs = [
        a for a in PDP.get_document(sys).time_series_associations if
        PDP.get_value(a, :owner_type) == "OnlineReserve"
    ]
    @test length(reserve_assocs) == 12
    @test all(a -> PDP.get_value(a, :name) == "requirement", reserve_assocs)
end

@testset "the initial timestamp is stated in UTC" begin
    sys = _built()
    association = first(PDP.get_document(sys).time_series_associations)
    timestamp = PDP.get_value(association, :initial_timestamp)
    @test TimeZones.timezone(timestamp) == TimeZones.tz"UTC"
end

@testset "write_time_series emits one group per uuid" begin
    sys = _built()
    mktempdir() do dir
        path = joinpath(dir, "ts.h5")
        PDP.write_time_series(sys, path)
        uuids = Set(
            PDP.get_value(a, :time_series_uuid) for
            a in PDP.get_document(sys).time_series_associations
        )
        HDF5.h5open(path, "r") do f
            @test length(keys(f["time_series"])) == length(uuids)
        end
    end
end
