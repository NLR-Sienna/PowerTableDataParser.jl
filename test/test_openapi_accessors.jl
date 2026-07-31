@testset "get_enum_value resolves UnitSystem from descriptor strings" begin
    @test PDP.get_enum_value(IS.UnitSystem, "natural_units") == IS.UnitSystem.NATURAL_UNITS
    @test PDP.get_enum_value(IS.UnitSystem, "device_base") == IS.UnitSystem.DEVICE_BASE
    @test PDP.get_enum_value(IS.UnitSystem, "SYSTEM_BASE") == IS.UnitSystem.SYSTEM_BASE
    @test_throws ArgumentError PDP.get_enum_value(IS.UnitSystem, "nonsense")
end

@testset "get_dataframe returns the table for a category" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    @test DataFrames.nrow(PDP.get_dataframe(data, PDP.InputCategory.BRANCH)) == 120
    @test DataFrames.nrow(PDP.get_dataframe(data, PDP.InputCategory.BUS)) == 73
end

@testset "get_user_field resolves a custom column name" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    @test PDP.get_user_field(data, PDP.InputCategory.GENERATOR, "name") == "GEN UID"
    @test PDP.get_user_field(data, PDP.InputCategory.BUS, "name") == "Bus Name"
end

@testset "get_user_fields lists the descriptor field names" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    fields = PDP.get_user_fields(data, PDP.InputCategory.BUS)
    @test "name" in fields
    @test "base_voltage" in fields
end

@testset "iterate_rows yields one NamedTuple per row" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    rows = collect(PDP.iterate_rows(data, PDP.InputCategory.BUS))
    @test length(rows) == 73

    first_bus = rows[1]
    @test hasproperty(first_bus, :name)
    @test hasproperty(first_bus, :base_voltage)
    @test hasproperty(first_bus, :bus_id)
end

@testset "iterate_rows applies the descriptor per-unit conversion" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    gens = collect(PDP.iterate_rows(data, PDP.InputCategory.GENERATOR))
    steam = first(g for g in gens if g.name == "101_STEAM_3")

    # PMax MW = 76 is declared natural_units and the descriptor target is
    # device_base, so in per-unit mode it arrives divided by base_mva = 89.
    @test steam.base_mva == 89.0
    @test steam.active_power_limits_max ≈ 76.0 / 89.0

    # get_cost_pairs multiplies these back together to recover PMax in MW, which
    # is what puts the cost curve x-coordinates in natural units. The product
    # holds whatever base_mva is, which is why the cost curve was unaffected by
    # the descriptor pointing at the wrong column.
    @test steam.base_mva * steam.active_power_limits_max ≈ 76.0

    @test steam.fuel == "Coal"
    @test steam.unit_type == "STEAM"
end

@testset "iterate_rows converts NA to nothing" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    gens = collect(PDP.iterate_rows(data, PDP.InputCategory.GENERATOR))
    steam = first(g for g in gens if g.name == "101_STEAM_3")
    # Output_pct_4 and HR_incr_4 are "NA" for this unit.
    @test isnothing(steam.output_point_4)
    @test isnothing(steam.heat_rate_incr_4)
end

@testset "get_generator_type is case-insensitive and honours null unit types" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    m = data.generator_mapping

    # Thermal entries are keyed with type: null, so they match on fuel alone.
    @test PDP.get_generator_type("Coal", "STEAM", m) == "ThermalStandard"
    @test PDP.get_generator_type("NG", "CT", m) == "ThermalStandard"
    @test PDP.get_generator_type("Nuclear", "NUCLEAR", m) == "ThermalStandard"

    # Hydro is split by unit type.
    @test PDP.get_generator_type("Hydro", "HYDRO", m) == "HydroTurbine"
    @test PDP.get_generator_type("Hydro", "ROR", m) == "HydroDispatch"

    @test PDP.get_generator_type("Sync_Cond", "SYNC_COND", m) == "SynchronousCondenser"
    @test PDP.get_generator_type("Storage", "STORAGE", m) == "EnergyReservoirStorage"
end

@testset "get_generator_type covers every RTS generator row" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    m = data.generator_mapping
    types = String[]
    for gen in PDP.iterate_rows(data, PDP.InputCategory.GENERATOR)
        push!(types, PDP.get_generator_type(gen.fuel, gen.unit_type, m))
    end
    @test length(types) == 158
    @test count(==("ThermalStandard"), types) == 73
    @test count(==("HydroTurbine"), types) == 19
    @test count(==("HydroDispatch"), types) == 1
    @test count(==("SynchronousCondenser"), types) == 3
    @test count(==("EnergyReservoirStorage"), types) == 1
end

@testset "per_unit = false yields the raw column values" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    gens = collect(
        PDP.iterate_rows(data, PDP.InputCategory.GENERATOR; per_unit = false),
    )
    steam = first(g for g in gens if g.name == "101_STEAM_3")

    # The schemas declare these in natural units, so no rebasing is applied and
    # the values arrive exactly as the CSV states them.
    @test steam.active_power_limits_max ≈ 76.0     # PMax MW
    @test steam.active_power_limits_min ≈ 30.0     # PMin MW
    @test steam.ramp_limits ≈ 2.0                  # Ramp Rate MW/Min
end

@testset "base_mva is the per-generator equipment rating" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    gens = collect(
        PDP.iterate_rows(data, PDP.InputCategory.GENERATOR; per_unit = false),
    )
    by_name = Dict(g.name => g for g in gens)

    # Not the system base of 100: the upstream fixture mapped base_mva to
    # MATPOWER BaseMVA, which is 100.0 for all 158 rows.
    @test by_name["101_STEAM_3"].base_mva == 89.0
    @test by_name["101_CT_1"].base_mva == 24.0
    @test count(g -> g.base_mva == 100.0, gens) < length(gens)

    # PMax never exceeds the equipment rating.
    for g in gens
        if g.base_mva > 0.0
            @test g.active_power_limits_max <= g.base_mva
        end
    end

    # The three synchronous condensers carry no active rating, so base_mva is 0
    # and the generation parser substitutes the system base.
    zero_base = [g.name for g in gens if g.base_mva == 0.0]
    @test length(zero_base) == 3
    @test all(endswith("SYNC_COND_1"), zero_base)
end

@testset "per_unit = false leaves impedances on their existing base" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    with_pu = first(PDP.iterate_rows(data, PDP.InputCategory.BRANCH))
    raw = first(PDP.iterate_rows(data, PDP.InputCategory.BRANCH; per_unit = false))

    # RTS declares r and x as already device_base and the descriptor targets the
    # same, so both modes agree: the schemas want these in pu and that is what
    # the column holds.
    @test raw.r == with_pu.r
    @test raw.x == with_pu.x
end

@testset "symbol conversions still run, because the schema pins the unit" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    buses = collect(PDP.iterate_rows(data, PDP.InputCategory.BUS; per_unit = false))
    # RTS declares bus angle in degrees; ACBus.angle is declared rad.
    @test all(b -> abs(b.angle) <= 2pi, buses)
end

@testset "convert_units! handles the conversions RTS declares" begin
    @test PDP.convert_units!(180.0, (From = "degree", To = "radian")) ≈ pi
    @test PDP.convert_units!(1.0, (From = "GWh", To = "MWh")) ≈ 1000.0
    @test PDP.convert_units!(1.0, (From = "GW", To = "MW")) ≈ 1000.0
end
