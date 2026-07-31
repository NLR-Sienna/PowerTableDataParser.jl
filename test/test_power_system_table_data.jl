@testset "PowerSystemTableData parsing invalid directory" begin
    @test_throws ErrorException PDP.PowerSystemTableData(DATA_DIR, 100.0, DESCRIPTORS)
end

@testset "PowerSystemTableData reads the RTS-GMLC tables" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)

    @test data.base_power == 100.0
    @test data.directory == RTS_GMLC_DIR
    @test !isnothing(data.timeseries_metadata_file)
    @test isfile(data.timeseries_metadata_file)

    for category in (:BUS, :BRANCH, :DC_BRANCH, :GENERATOR, :RESERVE, :STORAGE)
        @test haskey(data.category_to_df, category)
    end

    @test DataFrames.nrow(data.category_to_df[:BUS]) == 73
    @test DataFrames.nrow(data.category_to_df[:BRANCH]) == 120
    @test DataFrames.nrow(data.category_to_df[:GENERATOR]) == 158
    @test DataFrames.nrow(data.category_to_df[:DC_BRANCH]) == 1
end

@testset "PowerSystemTableData loads descriptors and generator mapping" begin
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)

    @test !isempty(data.descriptors)
    @test !isempty(data.user_descriptors)
    @test haskey(data.user_descriptors, :GENERATOR)

    @test !isempty(data.generator_mapping)
    @test data.generator_mapping[(fuel = "HYDRO", unit_type = "HYDRO")] == "HydroTurbine"
    @test data.generator_mapping[(fuel = "HYDRO", unit_type = "ROR")] == "HydroDispatch"
end

@testset "get_generator_mapping rejects duplicate entries" begin
    mktemp() do path, io
        write(
            io,
            """
            ThermalStandard:
            - {fuel: COAL, type: STEAM}
            HydroTurbine:
            - {fuel: COAL, type: STEAM}
            """,
        )
        close(io)
        @test_throws ErrorException PDP.get_generator_mapping(path)
    end
end
