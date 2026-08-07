@testset "build_openapi_system assembles RTS" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)
    @test PDP.get_base_power(sys) == 100.0
    @test length(PDP.get_components(sys, "ACBus")) == 73
    @test !isempty(PDP.get_components(sys, "ThermalStandard"))
    @test !isempty(PDP.get_components(sys, "OnlineReserve"))
    # RTS has no load.csv, so the only loads are the ones the bus rows carry.
    @test length(PDP.get_components(sys, "PowerLoad")) == 51
end

@testset "every component id is unique across all types" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)
    ids = Int[]
    for type_name in PDP.component_type_names(sys)
        append!(ids, [PDP.get_value(c, :id) for c in PDP.get_components(sys, type_name)])
    end
    @test length(ids) == length(unique(ids))
    @test !isempty(ids)
end

@testset "every component satisfies its required properties" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)
    for type_name in PDP.component_type_names(sys)
        for component in PDP.get_components(sys, type_name)
            @test PDP.OpenAPI.check_required(component)
        end
    end
end

@testset "the assembled system holds every expected type" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    sys = PDP.build_openapi_system(data)
    expected = [
        "ACBus",
        "Arc",
        "Area",
        "EnergyReservoirStorage",
        "HydroDispatch",
        "HydroReservoir",
        "HydroTurbine",
        "Line",
        "LoadZone",
        "OnlineReserve",
        "PowerLoad",
        "RenewableDispatch",
        "RenewableNonDispatch",
        "SynchronousCondenser",
        "ThermalStandard",
        "TransformerCircuit",
        "TwoTerminalGenericHVDCLine",
        "TwoWindingTransformer",
    ]
    @test PDP.component_type_names(sys) == expected
end
