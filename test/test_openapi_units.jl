@testset "set_value! stores a matching unit unchanged" begin
    bus = PDP.PO.ACBus()
    PDP.set_value!(bus, :base_voltage, 138.0, "kV")
    @test bus.base_voltage == 138.0
end

@testset "set_value! assigns units that have no conversion factor" begin
    # to_default is 0.0 for Angle and null for pu bases, so no factor exists.
    # Assignment must still work when source and target already agree.
    bus = PDP.PO.ACBus()
    PDP.set_value!(bus, :angle, 0.3, "rad")
    @test bus.angle == 0.3

    line = PDP.PO.Line()
    PDP.set_value!(line, :r, 0.003, "pu")
    @test line.r == 0.003
end

@testset "set_value! converts within a quantity" begin
    reserve = PDP.PO.OnlineReserve()
    PDP.set_value!(reserve, :time_frame, 60.0, "min")
    @test reserve.time_frame ≈ 60.0

    storage = PDP.PO.EnergyReservoirStorage()
    PDP.set_value!(storage, :storage_capacity, 3600.0, "MJ")
    @test storage.storage_capacity ≈ 1.0
end

@testset "set_value! rejects a cross-quantity conversion" begin
    bus = PDP.PO.ACBus()
    @test_throws IS.DataFormatError PDP.set_value!(bus, :base_voltage, 138.0, "MW")

    gen = PDP.PO.ThermalStandard()
    @test_throws IS.DataFormatError PDP.set_value!(gen, :base_power, 100.0, "MWh")
end

@testset "set_value! converts degrees to radians" begin
    bus = PDP.PO.ACBus()
    PDP.set_value!(bus, :angle, 180.0, "deg")
    @test bus.angle ≈ pi
    PDP.set_value!(bus, :angle, 0.0, "deg")
    @test bus.angle == 0.0
end

@testset "set_value! rejects pu, which needs a base rather than a factor" begin
    bus = PDP.PO.ACBus()
    # magnitude is declared pu on base_voltage; kV cannot be converted into it.
    @test_throws IS.DataFormatError PDP.set_value!(bus, :magnitude, 138.0, "kV")
end

@testset "set_value! rejects units absent from the vocabulary" begin
    gen = PDP.PO.ThermalStandard()
    @test_throws IS.DataFormatError PDP.set_value!(gen, :base_power, 100_000.0, "kW")
end

@testset "arity enforces the unit rule in both directions" begin
    bus = PDP.PO.ACBus()
    @test_throws IS.DataFormatError PDP.set_value!(bus, :name, "Abel", "kV")
    @test_throws IS.DataFormatError PDP.set_value!(bus, :base_voltage, 138.0)

    PDP.set_value!(bus, :name, "Abel")
    PDP.set_value!(bus, :available, true)
    PDP.set_value!(bus, :number, 101)
    @test bus.name == "Abel"
    @test bus.available
    @test bus.number == 101
end

@testset "set_value! runs the generated property validation" begin
    bus = PDP.PO.ACBus()
    @test_throws Exception PDP.set_value!(bus, :bustype, "Ref")
    PDP.set_value!(bus, :bustype, "REF")
    @test bus.bustype == "REF"
end

@testset "compound properties take the unit at object level" begin
    bus = PDP.PO.ACBus()
    PDP.set_value!(bus, :voltage_limits, (min = 0.95, max = 1.05), "pu")
    @test bus.voltage_limits.min == 0.95
    @test bus.voltage_limits.max == 1.05

    gen = PDP.PO.ThermalStandard()
    PDP.set_value!(gen, :active_power_limits, (min = 15.2, max = 76.0), "MW")
    @test gen.active_power_limits.min == 15.2
    @test gen.active_power_limits.max == 76.0

    PDP.set_value!(gen, :ramp_limits, (up = 3.0, down = 3.0), "MW/min")
    @test gen.ramp_limits.up == 3.0
    @test gen.ramp_limits.down == 3.0

    line = PDP.PO.Line()
    PDP.set_value!(line, :b, (from = 0.0225, to = 0.0225), "pu")
    @test line.b.from == 0.0225
end

@testset "compound properties convert every member" begin
    gen = PDP.PO.ThermalStandard()
    PDP.set_value!(gen, :time_limits, (up = 120.0, down = 60.0), "min")
    @test gen.time_limits.up ≈ 120.0
    @test gen.time_limits.down ≈ 60.0
end

@testset "discriminated units are read off the instance" begin
    line = PDP.PO.TwoTerminalLCCLine()
    PDP.set_value!(line, :parameter_units, "NATURAL_UNITS")
    PDP.set_value!(line, :r, 5.0, "ohm")
    @test line.r == 5.0

    other = PDP.PO.TwoTerminalLCCLine()
    PDP.set_value!(other, :parameter_units, "DEVICE_BASE")
    @test_throws IS.DataFormatError PDP.set_value!(other, :r, 5.0, "ohm")
    PDP.set_value!(other, :r, 0.01, "pu")
    @test other.r == 0.01
end

@testset "get_value returns the stored value and converts on request" begin
    bus = PDP.PO.ACBus()
    PDP.set_value!(bus, :base_voltage, 138.0, "kV")
    @test PDP.get_value(bus, :base_voltage) == 138.0
    @test PDP.get_value(bus, :base_voltage, "kV") == 138.0
    @test_throws IS.DataFormatError PDP.get_value(bus, :base_voltage, "MW")

    reserve = PDP.PO.OnlineReserve()
    PDP.set_value!(reserve, :time_frame, 60.0, "min")
    @test PDP.get_value(reserve, :time_frame, "min") ≈ 60.0
end
