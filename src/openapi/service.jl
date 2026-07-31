# Ported from PowerSystemCaseBuilder/src/parsers/power_system_table_data.jl:534-655.
#
# The reserve-to-device contribution PSCB resolves here is a many-to-many
# relation that SiennaSchemas has no representation for, so it is deliberately
# not emitted: the eligibility columns are read only to decide nothing. Task 16
# asserts the omission so it cannot pass for an oversight.

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
A stated requirement makes the reserve variable; its absence makes it constant.

This is PSCB's rule. The table's `timeframe` is in seconds while the schema
declares `time_frame` in minutes, so the conversion runs on the way in.
"""
function _add_reserve!(sys::OpenAPISystem, reserve, requirement::Real)
    component = PO.VariableReserve()
    set_value!(
        component,
        :id,
        register!(get_registry(sys), "VariableReserve", reserve.name),
    )
    set_value!(component, :name, reserve.name)
    set_value!(component, :available, true)
    set_value!(component, :time_frame, reserve.timeframe, "s")
    set_value!(component, :requirement, requirement, "MW")
    set_value!(component, :reserve_direction, get_reserve_direction(reserve.direction))
    add_component!(sys, component)
    return
end

function _add_reserve!(sys::OpenAPISystem, reserve, ::Nothing)
    component = PO.ConstantReserve()
    set_value!(
        component,
        :id,
        register!(get_registry(sys), "ConstantReserve", reserve.name),
    )
    set_value!(component, :name, reserve.name)
    set_value!(component, :available, true)
    set_value!(component, :time_frame, reserve.timeframe, "s")
    set_value!(component, :requirement, 0.0, "MW")
    set_value!(component, :reserve_direction, get_reserve_direction(reserve.direction))
    add_component!(sys, component)
    return
end

function services_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    for reserve in iterate_rows(data, InputCategory.RESERVE; per_unit = uses_per_unit(sys))
        _add_reserve!(sys, reserve, get(reserve, :requirement, nothing))
    end
    return
end
