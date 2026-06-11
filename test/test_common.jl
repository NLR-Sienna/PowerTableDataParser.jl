@testset "get_generator_mapping" begin
    # happy path — package default
    mappings = PDP.get_generator_mapping(PDP.GENERATOR_MAPPING_FILE_CDM)
    @test mappings isa Dict{NamedTuple, String}
    @test !isempty(mappings)

    # GenericBattery rename → EnergyReservoirStorage with a warning
    tmp = tempname() * ".yaml"
    write(
        tmp,
        """
        GenericBattery:
        - {fuel: Battery, type: BA}
        """,
    )
    renamed = @test_logs (:warn,) PDP.get_generator_mapping(tmp)
    @test renamed[(fuel = "Battery", unit_type = "BA")] == "EnergyReservoirStorage"

    # duplicate (fuel, type) across two generator entries → error
    dup = tempname() * ".yaml"
    write(
        dup,
        """
        ThermalStandard:
        - {fuel: NG, type: ST}
        HydroDispatch:
        - {fuel: NG, type: ST}
        """,
    )
    @test_throws ErrorException PDP.get_generator_mapping(dup)
end
