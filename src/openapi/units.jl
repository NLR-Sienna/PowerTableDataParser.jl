"""
Unit-checked assignment onto generated OpenAPI components.

Components are built empty and populated one property at a time. Every numeric
assignment names the unit of the incoming value; the declared unit comes from the schema
annotations generated into PowerOpenAPIModels.

The two arities are the enforcement. A property that declares a unit can only be
written by the 4-argument form, and one that does not can only be written by the
3-argument form, so the check cannot be skipped by choosing the shorter call.

Assignment goes through `setproperty!` rather than `setfield!`, which runs the
generated `validate_property` and so keeps enum and range checks in force.
"""

"""
Constructor for a compound property, e.g. `MinMax` for `ACBus.voltage_limits`.

Generated property types are `Union{Nothing, T}`; drop the `Nothing` arm.
"""
function _compound_type(o::OpenAPI.APIModel, prop::Symbol)
    ftype = OpenAPI.property_type(typeof(o), prop)
    concrete = filter(t -> t !== Nothing, Base.uniontypes(ftype))
    if length(concrete) != 1
        throw(
            IS.DataFormatError(
                "$(nameof(typeof(o))).$prop is not a single compound type: $ftype",
            ),
        )
    end
    return only(concrete)
end

"""
A power-bearing component's own `power_units` governs the declared unit of every
power-family field on it (schema instance dispatch), so it must hold a real value before
any such field is assigned — but a freshly constructed component has it unset, and every
reader in this package always writes `"MW"`/`"MVAr"`-labeled values regardless of the
run's actual convention, relying on `per_unit`-aware callers (`iterate_rows`,
`get_cost_pairs`, ...) to have already computed the right number (`add_component!`
restamps `power_units` to the run's actual convention once the component is complete).
Default it to `"NATURAL_UNITS"` here, the first time it is needed, rather than requiring
every construction site to stamp it.
"""
function _default_power_units!(o::OpenAPI.APIModel)
    T = typeof(o)
    if hasfield(T, :power_units) && getproperty(o, :power_units) === nothing
        setproperty!(o, :power_units, "NATURAL_UNITS")
    end
    return
end

function _declared(o::OpenAPI.APIModel, prop::Symbol)
    T = typeof(o)
    if !IC.has_declared_unit(T, Val(prop))
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop declares no unit; use the 3-argument set_value!",
            ),
        )
    end
    _default_power_units!(o)
    # Instance dispatch: for discriminated properties both the unit and the
    # quantity depend on a sibling field.
    return IC.declared_unit(o, Val(prop)), IC.declared_quantity(o, Val(prop))
end

function _reject_declared(o::OpenAPI.APIModel, prop::Symbol)
    T = typeof(o)
    if IC.has_declared_unit(T, Val(prop))
        unit = IC.declared_unit(o, Val(prop))
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop declares unit \"$unit\"; use the 4-argument set_value!",
            ),
        )
    end
    return
end

function _convert(
    o::OpenAPI.APIModel,
    prop::Symbol,
    value::Float64,
    source_unit::AbstractString,
    target::AbstractString,
    quantity::AbstractString,
)
    if source_unit == target
        return value
    end
    T = typeof(o)
    if !IC.has_conversion_factor(quantity, source_unit)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop is $quantity in \"$target\"; " *
                "\"$source_unit\" is not a convertible $quantity unit",
            ),
        )
    end
    if !IC.has_conversion_factor(quantity, target)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop: the unit vocabulary records no conversion factor " *
                "for $quantity in \"$target\"",
            ),
        )
    end
    return value * IC.conversion_factor(quantity, source_unit) /
           IC.conversion_factor(quantity, target)
end

"""Convert `value` from `source_unit` into the unit `prop` declares."""
function convert_to_declared(
    o::OpenAPI.APIModel,
    prop::Symbol,
    value::Real,
    source_unit::AbstractString,
)
    target, quantity = _declared(o, prop)
    return _convert(o, prop, Float64(value), source_unit, target, quantity)
end

"""Assign a numeric property, converting from `source_unit` to the declared unit."""
function set_value!(
    o::OpenAPI.APIModel,
    prop::Symbol,
    value::Real,
    source_unit::AbstractString,
)
    setproperty!(o, prop, convert_to_declared(o, prop, value, source_unit))
    return
end

"""
Assign a compound property such as `MinMax`, `UpDown`, `FromTo` or `InOut`.

The schemas annotate these at the object level rather than per member, so one
unit applies to every field of the tuple.
"""
function set_value!(
    o::OpenAPI.APIModel,
    prop::Symbol,
    value::NamedTuple,
    source_unit::AbstractString,
)
    target, quantity = _declared(o, prop)
    converted = map(
        v -> _convert(o, prop, Float64(v), source_unit, target, quantity),
        values(value),
    )
    ctor = _compound_type(o, prop)
    setproperty!(o, prop, ctor(; NamedTuple{keys(value)}(converted)...))
    return
end

"""
Reject a unit supplied for something that cannot carry one.

Either the property declares no unit, or the value is neither a number nor a
compound tuple. Both are caller mistakes worth naming precisely rather than
surfacing as a MethodError.
"""
function set_value!(
    o::OpenAPI.APIModel,
    prop::Symbol,
    value,
    source_unit::AbstractString,
)
    _reject_declared(o, prop)
    throw(
        IS.DataFormatError(
            "$(nameof(typeof(o))).$prop: a unit applies only to a number or a compound " *
            "tuple, got $(typeof(value))",
        ),
    )
end

"""Assign a property that declares no unit: names, ids, flags, enum strings."""
function set_value!(o::OpenAPI.APIModel, prop::Symbol, value)
    _reject_declared(o, prop)
    setproperty!(o, prop, value)
    return
end

"""Return the stored value of `prop`."""
get_value(o::OpenAPI.APIModel, prop::Symbol) = getproperty(o, prop)

"""Return the value of `prop` expressed in `unit`."""
function get_value(o::OpenAPI.APIModel, prop::Symbol, unit::AbstractString)
    source, quantity = _declared(o, prop)
    value = getproperty(o, prop)
    if source == unit
        return value
    end
    T = typeof(o)
    if !IC.has_conversion_factor(quantity, unit) ||
       !IC.has_conversion_factor(quantity, source)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop is $quantity in \"$source\"; cannot express in \"$unit\"",
            ),
        )
    end
    return value * IC.conversion_factor(quantity, source) /
           IC.conversion_factor(quantity, unit)
end
