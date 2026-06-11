@testset "Directory constructor edge cases" begin
    # Empty directory
    empty_dir = mktempdir()
    @test_throws ErrorException PDP.PowerSystemTableData(
        empty_dir,
        100.0,
        BUS118_DESCRIPTORS,
    )

    # Directory with only non-CSV / non-folder files
    no_csv = mktempdir()
    write(joinpath(no_csv, "README.md"), "nothing here")
    @test_throws ErrorException PDP.PowerSystemTableData(
        no_csv,
        100.0,
        BUS118_DESCRIPTORS,
    )

    # Bad generator mapping path → rethrown (parser also @errors, expected)
    staging = mktempdir()
    cp(joinpath(BUS118_SRC, "Buses.csv"), joinpath(staging, "bus.csv"))
    cp(joinpath(BUS118_SRC, "Lines.csv"), joinpath(staging, "branch.csv"))
    cp(joinpath(BUS118_SRC, "gen.csv"), joinpath(staging, "gen.csv"))
    @test_logs (:error,) match_mode = :any begin
        @test_throws Exception PDP.PowerSystemTableData(
            staging,
            100.0,
            BUS118_DESCRIPTORS;
            generator_mapping_file = joinpath(staging, "does_not_exist.yaml"),
        )
    end
end

@testset "Dict constructor: missing keys" begin
    descriptors = Dict{Symbol, Vector}()
    user_descriptors = Dict{Symbol, Vector}()
    gen_mapping = Dict{NamedTuple, String}()

    # Missing 'bus' key
    @test_throws IS.DataFormatError PDP.PowerSystemTableData(
        Dict{String, Any}(),
        mktempdir(),
        user_descriptors,
        descriptors,
        gen_mapping,
    )

    # Missing 'base_power' → warns and falls back to DEFAULT_BASE_MVA
    bus_df = DataFrames.DataFrame(; bus_id = [1])
    data = Dict{String, Any}("bus" => bus_df)
    sys_data = @test_logs (:warn,) match_mode = :any PDP.PowerSystemTableData(
        data,
        mktempdir(),
        user_descriptors,
        descriptors,
        gen_mapping,
    )
    @test sys_data.base_power == PDP.DEFAULT_BASE_MVA
    @test haskey(sys_data.category_to_df, :BUS)
end

@testset "Timeseries metadata fallback" begin
    descriptors = Dict{Symbol, Vector}()
    user_descriptors = Dict{Symbol, Vector}()
    gen_mapping = Dict{NamedTuple, String}()
    bus_df = DataFrames.DataFrame(; bus_id = [1])
    data() = Dict{String, Any}("bus" => bus_df, "base_power" => 100.0)

    # .json present
    d_json = mktempdir()
    write(joinpath(d_json, "timeseries_pointers.json"), "{}")
    sd_json = PDP.PowerSystemTableData(
        data(),
        d_json,
        user_descriptors,
        descriptors,
        gen_mapping,
    )
    @test endswith(sd_json.timeseries_metadata_file, ".json")

    # .csv present (no .json)
    d_csv = mktempdir()
    write(joinpath(d_csv, "timeseries_pointers.csv"), "")
    sd_csv = PDP.PowerSystemTableData(
        data(),
        d_csv,
        user_descriptors,
        descriptors,
        gen_mapping,
    )
    @test endswith(sd_csv.timeseries_metadata_file, ".csv")

    # Neither present
    d_none = mktempdir()
    sd_none = PDP.PowerSystemTableData(
        data(),
        d_none,
        user_descriptors,
        descriptors,
        gen_mapping,
    )
    @test sd_none.timeseries_metadata_file === nothing
end

@testset "_read_config_file: reserves rename + Symbol uppercasing" begin
    tmp = tempname() * ".yaml"
    write(
        tmp,
        """
        bus:
        - {custom_name: Number, name: bus_id}
        reserves:
        - {custom_name: R, name: name}
        """,
    )
    cfg = PDP._read_config_file(tmp)
    @test haskey(cfg, :BUS)
    @test haskey(cfg, :RESERVE)
    @test !haskey(cfg, :RESERVES)
end
