@testset "Test printing of system and components" begin
    sys = PSB.build_system(PSITestSystems, "test_RTS_GMLC_sys")
        
    io = IOBuffer()
    component = first(get_components(ThermalGen, sys))
    show(io, "text/plain", component)
    text = String(take!(io))
    expected_sa = string(has_supplemental_attributes(component))
    expected_ts = string(has_time_series(component))

    @test isnothing(
        show(
            IOBuffer(),
            "text/plain",
            PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS),
        ),
    )
end
