@testset "PowerSystemTableData from RTS-GMLC" begin
    sys_data = load_rts_data()
    @test sys_data isa PDP.PowerSystemTableData
    @test sys_data.base_power == 100.0
    for key in (:BUS, :BRANCH, :GENERATOR, :RESERVE, :DC_BRANCH, :STORAGE)
        @test haskey(sys_data.category_to_df, key)
    end
    @test sys_data.timeseries_metadata_file !== nothing
    @test endswith(sys_data.timeseries_metadata_file, ".json") ||
          endswith(sys_data.timeseries_metadata_file, ".csv")
    @test !isempty(sys_data.generator_mapping)
    @test !isempty(sys_data.user_descriptors)
    @test !isempty(sys_data.descriptors)
end

@testset "PowerSystemTableData from 118-Bus" begin
    sys_data = load_118_bus_data()
    @test sys_data isa PDP.PowerSystemTableData
    @test sys_data.base_power == 100.0
    for key in (:BUS, :BRANCH, :GENERATOR)
        @test haskey(sys_data.category_to_df, key)
    end
    @test DataFrames.nrow(sys_data.category_to_df[:BUS]) == 118
    @test DataFrames.nrow(sys_data.category_to_df[:BRANCH]) == 186
    @test sys_data.timeseries_metadata_file === nothing
end
