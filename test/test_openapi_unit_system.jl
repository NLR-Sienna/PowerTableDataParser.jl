function _system(unit_system)
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    return PDP.build_openapi_system(data; unit_system = unit_system)
end

function _named(sys, type_name, name)
    return first(
        c for c in PDP.get_components(sys, type_name) if PDP.get_value(c, :name) == name
    )
end

@testset "the container states its convention and rejects an unknown one" begin
    @test PDP.get_unit_system(PDP.OpenAPISystem(100.0)) == "NATURAL_UNITS"
    @test !PDP.uses_per_unit(PDP.OpenAPISystem(100.0))
    @test PDP.uses_per_unit(PDP.OpenAPISystem(100.0; unit_system = "DEVICE_BASE"))
    # SYSTEM_BASE is a UnitSystem value the parsers cannot produce.
    @test_throws IS.DataFormatError PDP.OpenAPISystem(100.0; unit_system = "SYSTEM_BASE")
    @test_throws IS.DataFormatError PDP.OpenAPISystem(100.0; unit_system = "PU")
end

@testset "generator power quantities move onto the device base" begin
    natural = _named(_system("NATURAL_UNITS"), "ThermalStandard", "101_STEAM_3")
    per_unit = _named(_system("DEVICE_BASE"), "ThermalStandard", "101_STEAM_3")

    @test PDP.get_value(natural, :active_power_limits).max ≈ 76.0
    # 76 MW on an 89 MVA machine.
    @test PDP.get_value(per_unit, :active_power_limits).max ≈ 76.0 / 89.0
    @test PDP.get_value(per_unit, :active_power_limits).min ≈ 30.0 / 89.0
    @test PDP.get_value(per_unit, :rating) ≈ sqrt((76.0 / 89.0)^2 + (30.0 / 89.0)^2)

    # base_power is the base itself, so it stays in MVA either way.
    @test PDP.get_value(natural, :base_power) ≈ 89.0
    @test PDP.get_value(per_unit, :base_power) ≈ 89.0
end

@testset "quantities the tables already state per unit are untouched" begin
    natural = _named(_system("NATURAL_UNITS"), "Line", "A1")
    per_unit = _named(_system("DEVICE_BASE"), "Line", "A1")
    for property in (:r, :x)
        @test PDP.get_value(natural, property) == PDP.get_value(per_unit, property)
    end
    @test PDP.get_value(natural, :b).from == PDP.get_value(per_unit, :b).from

    # The rating is stated in MVA and the descriptor targets the system base.
    @test PDP.get_value(natural, :rating) ≈ 175.0
    @test PDP.get_value(per_unit, :rating) ≈ 1.75

    # Angles are an absolute unit in both conventions.
    natural_bus = _named(_system("NATURAL_UNITS"), "ACBus", "Abel")
    per_unit_bus = _named(_system("DEVICE_BASE"), "ACBus", "Abel")
    @test PDP.get_value(natural_bus, :angle) == PDP.get_value(per_unit_bus, :angle)
    @test PDP.get_value(natural_bus, :base_voltage) ==
          PDP.get_value(per_unit_bus, :base_voltage)
    @test PDP.get_value(natural_bus, :magnitude) == PDP.get_value(per_unit_bus, :magnitude)
end

@testset "loads and reserves follow the descriptors' own targets" begin
    natural = _named(_system("NATURAL_UNITS"), "PowerLoad", "Abel")
    per_unit = _named(_system("DEVICE_BASE"), "PowerLoad", "Abel")
    @test PDP.get_value(natural, :max_active_power) ≈ 108.0
    # The bus load's base is the system base.
    @test PDP.get_value(per_unit, :max_active_power) ≈ 1.08

    natural_reserve = _named(_system("NATURAL_UNITS"), "OnlineReserve", "Spin_Up_R1")
    per_unit_reserve = _named(_system("DEVICE_BASE"), "OnlineReserve", "Spin_Up_R1")
    @test PDP.get_value(natural_reserve, :requirement) ≈ 40.413
    @test PDP.get_value(per_unit_reserve, :requirement) ≈ 0.40413
    # The time frame is a duration, not a power.
    @test PDP.get_value(natural_reserve, :time_frame) ==
          PDP.get_value(per_unit_reserve, :time_frame)
end

@testset "cost curve power coordinates stay in MW in both conventions" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    natural_row = first(
        g for
        g in PDP.iterate_rows(data, PDP.InputCategory.GENERATOR; per_unit = false)
        if g.name == "101_STEAM_3"
    )
    per_unit_row = first(
        g for g in PDP.iterate_rows(data, PDP.InputCategory.GENERATOR; per_unit = true)
        if g.name == "101_STEAM_3"
    )
    @test PDP.active_power_max_mw(natural_row, false) ≈ 76.0
    @test PDP.active_power_max_mw(per_unit_row, true) ≈ 76.0

    natural_pairs = PDP.get_cost_pairs(natural_row, PDP.COST_COLUMN_NAMES)
    per_unit_pairs =
        PDP.get_cost_pairs(per_unit_row, PDP.COST_COLUMN_NAMES; per_unit = true)
    @test [first(p) for p in natural_pairs] ≈ [first(p) for p in per_unit_pairs]
    @test [last(p) for p in natural_pairs] ≈ [last(p) for p in per_unit_pairs]
end

@testset "the document states the convention it was written in" begin
    for unit_system in ("NATURAL_UNITS", "DEVICE_BASE")
        sys = _system(unit_system)
        mktempdir() do dir
            path = joinpath(dir, "rts.json")
            PDP.to_json(sys, path)
            doc = JSON.parse(read(path, String))
            @test doc["unit_system"] == unit_system
            @test length(doc["components"]["ACBus"]) == 73
            @test length(doc["time_series_associations"]) == 362
        end
    end
end

@testset "the convention changes values, never the structure" begin
    natural = _system("NATURAL_UNITS")
    per_unit = _system("DEVICE_BASE")
    @test PDP.component_type_names(natural) == PDP.component_type_names(per_unit)
    for type_name in PDP.component_type_names(natural)
        left = PDP.get_components(natural, type_name)
        right = PDP.get_components(per_unit, type_name)
        @test length(left) == length(right)
        @test [PDP.get_value(c, :id) for c in left] ==
              [PDP.get_value(c, :id) for c in right]
    end
    @test length(PDP.get_time_series_associations(natural)) ==
          length(PDP.get_time_series_associations(per_unit))
end
