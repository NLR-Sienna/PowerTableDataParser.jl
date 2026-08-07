# Ported from PowerSystemCaseBuilder/src/parsers/power_system_table_data.jl:534-655.
#
# Reserve-to-device contribution is a many-to-many relation, emitted as rows in the unified
# `supplemental_attribute_associations` table (D10; one row per pair, `attribute_type` naming
# the service's own type). PSCB resolves it against a built `System`; here it is resolved
# against the tables and the id registry, which is why the eligibility rules are re-evaluated
# rather than read off components.

"""Reserve direction as the schema's enum value."""
function get_reserve_direction(direction::AbstractString)
    normalized = uppercase(strip(direction))
    if normalized == "UP"
        return "UP"
    end
    if normalized == "DOWN"
        return "DOWN"
    end
    throw(IS.DataFormatError("invalid reserve direction=$direction"))
end

"""
Reserve time frame in minutes.

The table states seconds (RTS names the column `Timeframe (sec)`) but the schema
declares `min`, and `UNIT_VOCABULARY` carries no second for OperationalDuration,
so the conversion happens here rather than in the unit layer.
"""
_seconds_to_minutes(seconds::Real) = Float64(seconds) / 60.0

"""
Requirement absent in the table means no stated requirement, which is `0.0`.

Constant-vs-variable is no longer a type distinction: one `OnlineReserve` carries the
requirement as a field, and whether it is scaled by a `"requirement"` time series is
decided downstream from time series presence. The table's `timeframe` is in seconds
while the schema declares `time_frame` in minutes, so the conversion runs on the way in.
"""
function _add_reserve!(sys::OpenAPISystem, reserve)
    component = PO.OnlineReserve()
    service_id = register!(get_registry(sys), "OnlineReserve", reserve.name)
    set_value!(component, :id, service_id)
    set_value!(component, :name, reserve.name)
    set_value!(component, :available, true)
    set_value!(component, :time_frame, _seconds_to_minutes(reserve.timeframe), "min")
    set_value!(component, :requirement, get(reserve, :requirement, 0.0), "MW")
    set_value!(component, :reserve_direction, get_reserve_direction(reserve.direction))
    add_component!(sys, component)
    return service_id
end

"""
Parse a `"(a,b,c)"` tuple column into its members, or an empty vector when absent.

The tables wrap these lists in parentheses and pad after commas.
"""
function _tuple_column(value)
    if value === nothing
        return String[]
    end
    text = strip(String(value), ['(', ')'])
    if isempty(text)
        return String[]
    end
    return [strip(part) for part in split(text, ",")]
end

"""
Area of the bus a generator row sits on, as a string, for matching `eligible_regions`.

The reserve tables state regions as area labels while the generator row names only its
bus, so the bus table is the join.
"""
function _generator_area(data::PowerSystemTableData, bus_number::Int)
    buses = get_dataframe(data, InputCategory.BUS)
    id_column = get_user_field(data, InputCategory.BUS, "bus_id")
    area_column = get_user_field(data, InputCategory.BUS, "area")
    rows = buses[buses[!, id_column] .== bus_number, area_column]
    if isempty(rows)
        throw(IS.DataFormatError("no bus row for bus_id=$bus_number"))
    end
    return string(rows[1])
end

"""Resolve `device_name` to its registered id, or error if it isn't registered yet."""
function _contributing_device_id(reg::IdRegistry, device_types, device_name, reserve_name)
    if !any(type_name -> has_id(reg, type_name, device_name), device_types)
        throw(
            IS.DataFormatError(
                "reserve $reserve_name matched contributing device $device_name, but no " *
                "component is registered under that name; device components must be " *
                "parsed before services",
            ),
        )
    end
    _, entity_id = find_by_name(reg, device_types, device_name)
    return entity_id
end

"""
Emit one unified supplemental-attribute-association row per (reserve, contributing device)
pair.

Mirrors PSCB's rule: an explicit `contributing_devices` list wins, and otherwise a
generator contributes when its `category` is in `eligible_device_subcategories` **and**
its bus's area is in `eligible_regions`. Both are re-evaluated from the tables because at
this stage there is no `System` to read membership off.
"""
function _add_reserve_membership!(
    sys::OpenAPISystem,
    data::PowerSystemTableData,
    reserve,
    service_id::Int,
    attribute_type::AbstractString,
)
    reg = get_registry(sys)
    device_types = category_to_type_names("Generator")
    subcategories = _tuple_column(get(reserve, :eligible_device_subcategories, nothing))
    named_devices = _tuple_column(get(reserve, :contributing_devices, nothing))

    if isempty(subcategories)
        for device_name in named_devices
            entity_id =
                _contributing_device_id(reg, device_types, device_name, reserve.name)
            add_service_association!(sys, service_id, entity_id, attribute_type)
        end
        return
    end

    regions = _tuple_column(reserve.eligible_regions)
    for gen in iterate_rows(data, InputCategory.GENERATOR; per_unit = uses_per_unit(sys))
        if !(string(gen.category) in subcategories)
            continue
        end
        if !(_generator_area(data, Int(gen.bus_id)) in regions)
            continue
        end
        entity_id = _contributing_device_id(reg, device_types, gen.name, reserve.name)
        add_service_association!(sys, service_id, entity_id, attribute_type)
    end
    return
end

"""Type name emitted for every reserve `_add_reserve!` builds. A named constant rather than a
literal at each call site, since every reserve this parser emits is one `PO.OnlineReserve`."""
const RESERVE_ATTRIBUTE_TYPE = "OnlineReserve"

function services_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    for reserve in iterate_rows(data, InputCategory.RESERVE; per_unit = uses_per_unit(sys))
        service_id = _add_reserve!(sys, reserve)
        _add_reserve_membership!(sys, data, reserve, service_id, RESERVE_ATTRIBUTE_TYPE)
    end
    return
end
