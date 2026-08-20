@testset "IdRegistry assigns one global id space" begin
    reg = PDP.IdRegistry(PDP.PD.SystemDocument(100.0))
    @test PDP.register!(reg, "Area", "1") == 1
    @test PDP.register_bus!(reg, 101, "Abel") == 2
    @test PDP.register!(reg, "ThermalStandard", "101_STEAM_3") == 3
    @test PDP.next_id!(reg) == 4
end

@testset "IdRegistry lookups" begin
    reg = PDP.IdRegistry(PDP.PD.SystemDocument(100.0))
    PDP.register_bus!(reg, 101, "Abel")
    @test PDP.has_bus_id(reg, 101)
    @test PDP.get_bus_id(reg, 101) == 1
    @test !PDP.has_bus_id(reg, 999)
    @test_throws IS.DataFormatError PDP.get_bus_id(reg, 999)
    @test PDP.has_id(reg, "ACBus", "Abel")
    @test PDP.get_id(reg, "ACBus", "Abel") == 1
    @test !PDP.has_id(reg, "ACBus", "Nowhere")
    @test_throws IS.DataFormatError PDP.get_id(reg, "ACBus", "Nowhere")
end

@testset "IdRegistry rejects duplicates within a type" begin
    reg = PDP.IdRegistry(PDP.PD.SystemDocument(100.0))
    PDP.register!(reg, "Area", "1")
    @test_throws IS.DataFormatError PDP.register!(reg, "Area", "1")
end

@testset "IdRegistry rejects duplicate bus numbers" begin
    reg = PDP.IdRegistry(PDP.PD.SystemDocument(100.0))
    PDP.register_bus!(reg, 101, "Abel")
    @test_throws IS.DataFormatError PDP.register_bus!(reg, 101, "Adams")
end

@testset "IdRegistry allows the same name across types" begin
    reg = PDP.IdRegistry(PDP.PD.SystemDocument(100.0))
    @test PDP.register!(reg, "Area", "1") != PDP.register!(reg, "LoadZone", "1")
end

@testset "arc_id! deduplicates and respects direction" begin
    reg = PDP.IdRegistry(PDP.PD.SystemDocument(100.0))
    from = PDP.register_bus!(reg, 101, "Abel")
    to = PDP.register_bus!(reg, 102, "Adams")
    id1, created1 = PDP.arc_id!(reg, from, to)
    id2, created2 = PDP.arc_id!(reg, from, to)
    id3, created3 = PDP.arc_id!(reg, to, from)
    @test created1
    @test !created2
    @test created3
    @test id1 == id2
    @test id1 != id3
end

@testset "find_by_name narrows by candidate types" begin
    reg = PDP.IdRegistry(PDP.PD.SystemDocument(100.0))
    area = PDP.register!(reg, "Area", "1")
    zone = PDP.register!(reg, "LoadZone", "1")
    @test PDP.find_by_name(reg, ["LoadZone"], "1") == ("LoadZone", zone)
    @test PDP.find_by_name(reg, ["Area"], "1") == ("Area", area)
    @test_throws IS.DataFormatError PDP.find_by_name(reg, ["Area", "LoadZone"], "1")
    @test_throws IS.DataFormatError PDP.find_by_name(reg, ["Area"], "missing")
end
