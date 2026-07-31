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
    types = [PDP.get_value(b, :bustype) for b in PDP.get_components(sys, "ACBus")]
    @test Set(types) ⊆ Set(["PQ", "PV", "REF", "ISOLATED", "SLACK"])
    # RTS writes "Ref"; the generated validate_property only accepts "REF".
    @test count(==("REF"), types) == 1
    @test count(==("PQ"), types) == 40
    @test count(==("PV"), types) == 32
end

@testset "references resolve and number is distinct from id" begin
    sys, _ = _topology()
    reg = PDP.get_registry(sys)
    area_ids = Set(PDP.get_value(a, :id) for a in PDP.get_components(sys, "Area"))
    zone_ids = Set(PDP.get_value(z, :id) for z in PDP.get_components(sys, "LoadZone"))
    for bus in PDP.get_components(sys, "ACBus")
        @test PDP.get_value(bus, :area) in area_ids
        @test PDP.get_value(bus, :load_zone) in zone_ids
        @test PDP.get_bus_id(reg, PDP.get_value(bus, :number)) == PDP.get_value(bus, :id)
    end
    # The number cannot double as the id: ids come from the counter shared with
    # every other type, so bus 101 is not id 101.
    abel = first(
        b for b in PDP.get_components(sys, "ACBus") if
        PDP.get_value(b, :number) == 101
    )
    @test PDP.get_value(abel, :id) != 101
end

@testset "bus quantities arrive in the units the schema declares" begin
    sys, _ = _topology()
    buses = PDP.get_components(sys, "ACBus")
    abel = first(b for b in buses if PDP.get_value(b, :name) == "Abel")
    @test PDP.get_value(abel, :number) == 101
    @test PDP.get_value(abel, :base_voltage) ≈ 138.0
    @test PDP.get_value(abel, :magnitude) ≈ 1.04777
    # RTS states V Angle in degrees; ACBus.angle is declared rad.
    @test PDP.get_value(abel, :angle) ≈ deg2rad(-7.74152)
    @test PDP.get_value(abel, :angle, "deg") ≈ -7.74152
    limits = PDP.get_value(abel, :voltage_limits)
    @test limits.min ≈ 0.95
    @test limits.max ≈ 1.05
    @test all(PDP.get_value(b, :available) for b in buses)
end

@testset "nonzero bus load rows emit a PowerLoad" begin
    sys, _ = _topology()
    loads = PDP.get_components(sys, "PowerLoad")
    # 51 of the 73 rows carry load; the rest emit nothing.
    @test length(loads) == 51

    abel = first(l for l in loads if PDP.get_value(l, :name) == "Abel")
    # Natural units, not rebased onto the 100 MVA system base.
    @test PDP.get_value(abel, :active_power) ≈ 108.0
    @test PDP.get_value(abel, :reactive_power) ≈ 22.0
    @test PDP.get_value(abel, :max_active_power) ≈ 108.0
    @test PDP.get_value(abel, :max_reactive_power) ≈ 22.0
    @test PDP.get_value(abel, :base_power) ≈ 100.0

    bus_ids = Set(PDP.get_value(b, :id) for b in PDP.get_components(sys, "ACBus"))
    @test all(l -> PDP.get_value(l, :bus) in bus_ids, loads)
    @test sum(PDP.get_value(l, :active_power) for l in loads) ≈ 8550.0
end

@testset "zone peaks are the summed bus loads" begin
    sys, _ = _topology()
    zones = PDP.get_components(sys, "LoadZone")
    @test Set(PDP.get_value(z, :name) for z in zones) == Set(["1", "2", "3"])
    for zone in zones
        @test PDP.get_value(zone, :peak_active_power) ≈ 2850.0
        @test PDP.get_value(zone, :peak_reactive_power) ≈ 580.0
    end
end

@testset "every component satisfies its required properties" begin
    sys, _ = _topology()
    for type_name in PDP.component_type_names(sys)
        for component in PDP.get_components(sys, type_name)
            @test PDP.OpenAPI.check_required(component)
        end
    end
end

@testset "areas take their peak from the buses they hold" begin
    sys, _ = _topology()
    areas = PDP.get_components(sys, "Area")
    @test Set(PDP.get_value(a, :name) for a in areas) == Set(["1", "2", "3"])
    for area in areas
        # Each RTS area carries a third of the system load, as its zone does.
        @test PDP.get_value(area, :peak_active_power) ≈ 2850.0
        @test PDP.get_value(area, :peak_reactive_power) ≈ 580.0
    end
    @test sum(PDP.get_value(a, :peak_active_power) for a in areas) ≈ 8550.0
end
