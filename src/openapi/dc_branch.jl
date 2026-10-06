# The target is TwoTerminalGenericHVDCLine. The LCC model is unreachable from
# table data: commutating resistances, bridge counts and DC voltages are columns
# in dc_branch.csv that the input descriptors do not expose, so `control_mode`
# other than "Power" is an error rather than a second code path.

"""
Read a limit pair where only the maximum need be stated.

A stated maximum with no minimum means a symmetric limit, which is how the tables
express a bidirectional converter. Neither stated is a data error: a converter
with no power limit is not a modelling choice worth guessing at.
"""
function make_dc_limits(dc_branch, min_field::Symbol, max_field::Symbol)
    min_limit = getproperty(dc_branch, min_field)
    max_limit = getproperty(dc_branch, max_field)
    if isnothing(min_limit) && isnothing(max_limit)
        throw(IS.DataFormatError("valid limits required for $min_field, $max_field"))
    end
    if isnothing(min_limit)
        min_limit = max_limit * -1.0
    end
    return (min = min_limit, max = max_limit)
end

"""
Transfer rating of a DC branch: the largest active power magnitude either end allows.
"""
function _dc_rating(limits_from, limits_to)
    return maximum(abs, (limits_from.min, limits_from.max, limits_to.min, limits_to.max))
end

"""
Directional flow limits of a DC branch. The `from` limits bound the flow leaving the `from`
bus, where a negative value is flow in the reverse direction, so the positive part of each
bound limits `from_to` and the negated negative part limits `to_from`.
"""
function _dc_flow_limit(limits_from)
    return (
        from_to_min = max(limits_from.min, 0.0),
        from_to_max = max(limits_from.max, 0.0),
        to_from_min = max(-limits_from.max, 0.0),
        to_from_max = max(-limits_from.min, 0.0),
    )
end

function dc_branch_csv_parser!(sys::OpenAPISystem, data::PowerSystemTableData)
    reg = get_registry(sys)
    for dc_branch in
        iterate_rows(data, InputCategory.DC_BRANCH; per_unit = uses_per_unit(sys))
        if dc_branch.control_mode != "Power"
            throw(
                IS.DataFormatError(
                    "only control_mode = Power is supported for DC branch " *
                    "$(dc_branch.name), got $(dc_branch.control_mode)",
                ),
            )
        end

        from_id = get_bus_id(reg, Int(dc_branch.connection_points_from))
        to_id = get_bus_id(reg, Int(dc_branch.connection_points_to))
        arc = _add_arc!(sys, from_id, to_id)

        line = stage(PO.TwoTerminalGenericHVDCLine)
        set_value!(
            line,
            :id,
            register!(reg, "TwoTerminalGenericHVDCLine", dc_branch.name),
        )
        set_value!(line, :name, dc_branch.name)
        set_value!(line, :available, true)
        set_value!(line, :arc, arc)
        set_value!(line, :active_power_flow, dc_branch.active_power_flow, "MW")
        limits_from = make_dc_limits(
            dc_branch,
            :min_active_power_limit_from,
            :max_active_power_limit_from,
        )
        limits_to = make_dc_limits(
            dc_branch,
            :min_active_power_limit_to,
            :max_active_power_limit_to,
        )
        set_value!(line, :rating, _dc_rating(limits_from, limits_to), "MVA")
        set_value!(line, :operational_flow_limit, _dc_flow_limit(limits_from), "MW")
        set_value!(
            line,
            :reactive_power_limits_from,
            make_dc_limits(
                dc_branch,
                :min_reactive_power_limit_from,
                :max_reactive_power_limit_from,
            ),
            "MVAr",
        )
        set_value!(
            line,
            :reactive_power_limits_to,
            make_dc_limits(
                dc_branch,
                :min_reactive_power_limit_to,
                :max_reactive_power_limit_to,
            ),
            "MVAr",
        )
        # The tables give one loss margin, so the loss is proportional with no
        # constant term. `LossCurve` wraps the value curve with the basis both its axes
        # are read in, matching the run's own convention.
        set_value!(
            line,
            :loss,
            PC.LossCurve(;
                power_units = IC.UnitSystem(get_power_units(sys)),
                value_curve = PC.LossValueCurve(linear_curve(_as_float(dc_branch.loss))),
            ),
        )
        # No device base of its own: base_power records the system base.
        set_value!(line, :base_power, get_base_power(sys), "MVA")
        add_component!(sys, line)
    end
    return
end
