@testset "get_enum_value" begin
    @test PDP.get_enum_value(PDP.InputCategory, "bus") == PDP.InputCategory.BUS
    # case-insensitive
    @test PDP.get_enum_value(PDP.InputCategory, "BUS") == PDP.InputCategory.BUS
    @test PDP.get_enum_value(PDP.InputCategory, "Branch") == PDP.InputCategory.BRANCH

    # invalid enum type — anything not in PDP.ENUM_MAPPINGS
    @test_throws ArgumentError PDP.get_enum_value(Int, "bus")

    # invalid value within a known enum
    @test_throws ArgumentError PDP.get_enum_value(PDP.InputCategory, "not_a_category")
end
