function _services()
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.OpenAPISystem(100.0)
    PDP.loadzone_csv_parser!(sys, data)
    PDP.bus_csv_parser!(sys, data)
    PDP.services_csv_parser!(sys, data)
    return sys, data
end

@testset "get_reserve_direction maps to the enum" begin
    @test PDP.get_reserve_direction("Up") == "UP"
    @test PDP.get_reserve_direction("Down") == "DOWN"
    @test PDP.get_reserve_direction(" up ") == "UP"
    @test_throws IS.DataFormatError PDP.get_reserve_direction("Sideways")
end

@testset "every reserve product is emitted" begin
    sys, data = _services()
    n =
        length(PDP.get_components(sys, "VariableReserve")) +
        length(PDP.get_components(sys, "ConstantReserve"))
    @test n == DataFrames.nrow(PDP.get_dataframe(data, PDP.InputCategory.RESERVE))
    @test n == 7
    # RTS states a requirement for every product, so all seven are variable.
    @test length(PDP.get_components(sys, "VariableReserve")) == 7
end

@testset "reserves carry direction, requirement and time frame" begin
    sys, _ = _services()
    for reserve in PDP.get_components(sys, "VariableReserve")
        @test PDP.get_value(reserve, :reserve_direction) in ("UP", "DOWN")
        @test PDP.get_value(reserve, :requirement) >= 0
        @test PDP.get_value(reserve, :time_frame) > 0
        @test PDP.OpenAPI.check_required(reserve)
    end
end

@testset "the time frame is converted from seconds to minutes" begin
    sys, _ = _services()
    reserves = Dict(
        PDP.get_value(r, :name) => r for r in PDP.get_components(sys, "VariableReserve")
    )
    # Spin_Up_R1 states 600 s.
    @test PDP.get_value(reserves["Spin_Up_R1"], :time_frame) ≈ 10.0
    @test PDP.get_value(reserves["Spin_Up_R1"], :time_frame, "s") ≈ 600.0
    @test PDP.get_value(reserves["Spin_Up_R1"], :requirement) ≈ 40.413
    @test PDP.get_value(reserves["Reg_Down"], :reserve_direction) == "DOWN"
    @test PDP.get_value(reserves["Reg_Down"], :time_frame) ≈ 5.0
end

@testset "contributing devices are not emitted" begin
    sys, _ = _services()
    # A reserve-to-device link is many-to-many and has no schema; the eligibility
    # columns are read and deliberately dropped.
    reserve = first(PDP.get_components(sys, "VariableReserve"))
    @test !hasproperty(reserve, :contributing_devices)
end

@testset "a separately stated load is named apart from its bus load" begin
    sys = PDP.OpenAPISystem(100.0)
    reg = PDP.get_registry(sys)
    PDP.register!(reg, "PowerLoad", "Abel")
    @test PDP._load_name(reg, "Abel") == "load_Abel"
    @test PDP._load_name(reg, "Adams") == "Adams"
end
