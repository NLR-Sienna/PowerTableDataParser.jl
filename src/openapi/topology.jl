# Ported from PowerSystemCaseBuilder/src/parsers/power_system_table_data.jl
# (bus_csv_parser! and the load-zone accumulation it performs inline).
#
# Every parser reads rows under the system's unit convention. The default
# suppresses the descriptors' rebasing, which is what the schemas want: natural
# units for power, and per-unit only where the raw column already is per-unit.
# A DEVICE_BASE system applies the rebasing instead, reproducing what
# PowerSystems stores. See `iterate_rows` and `uses_per_unit`.
#
# No FixedAdmittance branch: RTS maps its shunt columns to names absent from
# power_system_inputs.json, so shunt_g and shunt_b always hold their 0 defaults
# and PSCB emits nothing either.

function _zone_name(bus)
    return string(get(bus, :zone, "zone"))
end

function _area_name(bus)
    return string(get(bus, :area, "area"))
end

"""
Sum the bus load under whichever grouping `name_of` names.

Areas and zones are both collections of buses, so they take their peak the same
way; only the column differs.
"""
function _peak_loads(sys::OpenAPISystem, data::PowerSystemTableData, name_of)
    peaks = Dict{String, Tuple{Float64, Float64}}()
    for bus in iterate_rows(data, InputCategory.BUS; per_unit = uses_per_unit(sys))
        group = name_of(bus)
        active, reactive = get(peaks, group, (0.0, 0.0))
        peaks[group] = (active + bus.max_active_power, reactive + bus.max_reactive_power)
    end
    return peaks
end

"""
Create one `LoadZone` per distinct zone, with the summed bus load as its peak.

Runs before `bus_csv_parser!`, which resolves each bus's `load_zone` id.
"""
function loadzone_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    reg = get_registry(sys)
    peaks = _peak_loads(sys, data, _zone_name)
    for zone in sort!(collect(keys(peaks)))
        active, reactive = peaks[zone]
        component = PO.LoadZone()
        set_value!(component, :id, register!(reg, "LoadZone", zone))
        set_value!(component, :name, zone)
        set_value!(component, :peak_active_power, active, "MW")
        set_value!(component, :peak_reactive_power, reactive, "MVAr")
        add_component!(sys, component)
    end
    return
end

"""
Return the id of the named `Area`, creating it on first sight.

An area takes its peak from the buses it holds, exactly as a zone does. PSCB
leaves both at zero; the bus rows carry the data either way.
"""
function _ensure_area!(sys::OpenAPISystem, name::AbstractString, peaks)
    reg = get_registry(sys)
    if has_id(reg, "Area", name)
        return get_id(reg, "Area", name)
    end
    active, reactive = get(peaks, name, (0.0, 0.0))
    area = PO.Area()
    id = register!(reg, "Area", name)
    set_value!(area, :id, id)
    set_value!(area, :name, name)
    set_value!(area, :peak_active_power, active, "MW")
    set_value!(area, :peak_reactive_power, reactive, "MVAr")
    add_component!(sys, area)
    return id
end

"""
Create an `ACBus` per row, plus a `PowerLoad` for every row carrying load.

`number` is the table's bus number and is distinct from `id`: ids come from the
registry's single counter, shared across every component type.
"""
function bus_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    reg = get_registry(sys)
    area_peaks = _peak_loads(sys, data, _area_name)
    for (ix, bus) in
        enumerate(iterate_rows(data, InputCategory.BUS; per_unit = uses_per_unit(sys)))
        area_id = _ensure_area!(sys, _area_name(bus), area_peaks)
        number = bus.bus_id
        if isnothing(number)
            number = ix
        end

        ps_bus = PO.ACBus()
        set_value!(ps_bus, :id, register_bus!(reg, Int(number), bus.name))
        set_value!(ps_bus, :number, Int(number))
        set_value!(ps_bus, :name, bus.name)
        set_value!(ps_bus, :available, true)
        # RTS writes "Ref"; the enum wants "REF".
        set_value!(ps_bus, :bustype, uppercase(bus.bus_type))
        set_value!(ps_bus, :area, area_id)
        set_value!(ps_bus, :load_zone, get_id(reg, "LoadZone", _zone_name(bus)))
        set_value!(ps_bus, :angle, bus.angle, "rad")
        set_value!(ps_bus, :magnitude, bus.voltage, "pu")
        set_value!(ps_bus, :base_voltage, bus.base_voltage, "kV")
        set_value!(
            ps_bus,
            :voltage_limits,
            (min = bus.voltage_limits_min, max = bus.voltage_limits_max),
            "pu",
        )
        add_component!(sys, ps_bus)

        if !iszero(bus.max_active_power) || !iszero(bus.max_reactive_power)
            load = PO.PowerLoad()
            set_value!(load, :id, register!(reg, "PowerLoad", bus.name))
            set_value!(load, :name, bus.name)
            set_value!(load, :available, true)
            set_value!(load, :bus, get_value(ps_bus, :id))
            set_value!(load, :active_power, bus.active_power, "MW")
            set_value!(load, :reactive_power, bus.reactive_power, "MVAr")
            set_value!(load, :base_power, bus.base_power, "MVA")
            set_value!(load, :max_active_power, bus.max_active_power, "MW")
            set_value!(load, :max_reactive_power, bus.max_reactive_power, "MVAr")
            add_component!(sys, load)
        end
    end
    return
end
