# get_generator_type returns the mapped type name as a String rather than resolving it to
# a PowerSystems type, since this package does not depend on PowerSystems.

"""
Return the mapped component type name for a fuel and unit type.

Mapping keys are uppercase, and thermal entries carry `type: null` so they match
on fuel alone. Falling back through `(unit_type, nothing) x (fuel, nothing)` is
what makes `("Coal", "STEAM")` resolve.
"""
function get_generator_type(fuel, unit_type, mappings::Dict{NamedTuple, String})
    normalized_fuel = ""
    if !isnothing(fuel)
        normalized_fuel = uppercase(fuel)
    end
    normalized_unit_type = ""
    if !isnothing(unit_type)
        normalized_unit_type = uppercase(unit_type)
    end

    for ut in (normalized_unit_type, nothing), fu in (normalized_fuel, nothing)
        key = (fuel = fu, unit_type = ut)
        if haskey(mappings, key)
            return mappings[key]
        end
    end

    throw(
        IS.DataFormatError(
            "no generator mapping for fuel=$fuel unit_type=$unit_type",
        ),
    )
end

"""
Conversions PC's vocabulary states, keyed by the casefolded (From, To) the descriptors
spell and valued with the quantity plus each unit's spelling in `IC.UNIT_VOCABULARY` —
which abbreviates the angles the descriptors write out in full.
"""
const _PC_CONVERSIONS = Dict(
    ("degree", "radian") => ("Angle", "deg", "rad"),
    ("radian", "degree") => ("Angle", "rad", "deg"),
    ("tw", "mw") => ("ActivePower", "TW", "MW"),
    ("gw", "mw") => ("ActivePower", "GW", "MW"),
    ("kw", "mw") => ("ActivePower", "kW", "MW"),
    ("twh", "mwh") => ("ElectricalEnergy", "TWh", "MWh"),
    ("gwh", "mwh") => ("ElectricalEnergy", "GWh", "MWh"),
    ("kwh", "mwh") => ("ElectricalEnergy", "kWh", "MWh"),
)

# hour/minute/second are deliberately absent from UNIT_VOCABULARY (the schemas' time-tier
# design keeps a field to one declared unit rather than letting every duration quantity carry
# every tier), so those three conversions stay hand-rolled rather than routed through PC.
const _TIME_CONVERSIONS = Dict(
    ("hour", "second") => 3600.0,
    ("minute", "second") => 60.0,
    ("hour", "minute") => 60.0,
    ("minute", "hour") => 1 / 60,
    ("second", "minute") => 1 / 60,
    ("second", "hour") => 1 / 3600,
)

function convert_units!(
    value::Float64,
    unit_conversion::NamedTuple{(:From, :To), Tuple{String, String}},
)
    key = (
        normalize(unit_conversion.From; casefold = true),
        normalize(unit_conversion.To; casefold = true),
    )
    if haskey(_PC_CONVERSIONS, key)
        quantity, from, to = _PC_CONVERSIONS[key]
        return value * IC.conversion_factor(quantity, from) /
               IC.conversion_factor(quantity, to)
    end
    if haskey(_TIME_CONVERSIONS, key)
        return value * _TIME_CONVERSIONS[key]
    end
    throw(
        IS.DataFormatError(
            "Unit conversion from $(unit_conversion.From) to $(unit_conversion.To) not supported",
        ),
    )
end

function convert_units!(
    value::Int,
    unit_conversion::NamedTuple{(:From, :To), Tuple{String, String}},
)
    return convert_units!(convert(Float64, value), unit_conversion)
end

"""
Return the custom name stored in the user descriptor file.

Throws DataFormatError if a required value is not found in the file.
"""
function get_user_field(
    data::PowerSystemTableData,
    category::InputCategory,
    field::AbstractString,
)
    key = _category_key(category)
    if !haskey(data.user_descriptors, key)
        throw(IS.DataFormatError("Invalid category=$category"))
    end

    for item in data.user_descriptors[key]
        if item["name"] == field
            return item["custom_name"]
        end
    end

    throw(
        IS.DataFormatError(
            "Failed to find category=$category field=$field in input descriptors",
        ),
    )
end

"""Return a vector of user-defined fields for the category."""
function get_user_fields(data::PowerSystemTableData, category::InputCategory)
    key = _category_key(category)
    if !haskey(data.user_descriptors, key)
        throw(IS.DataFormatError("Invalid category=$category"))
    end

    return [x["name"] for x in data.user_descriptors[key]]
end

"""Return the dataframe for the category."""
function get_dataframe(data::PowerSystemTableData, category::InputCategory)
    df = get(data.category_to_df, _category_key(category), DataFrames.DataFrame())
    isempty(df) && @warn("Missing $category data.")
    return df
end

"""
Return a Vector of NamedTuples, one per row of a dataframe, holding the parameters
declared in the descriptor file with type conversions applied.

`extras = true` adds an `ext` entry holding every column the descriptors do not
declare, so a table can carry data the data model has no field for without it
being dropped at the door.

`per_unit = false` suppresses the descriptor's per-unit conversions, yielding the
raw column values. This is what the OpenAPI path wants: the descriptors target
PowerSystems' per-unit conventions, while the schemas want natural units for
power quantities and per-unit only for impedances — and the raw columns are
already in exactly that form. Symbol conversions such as degree to radian still
apply, since those are genuine unit changes rather than a change of base.
"""
function iterate_rows(
    data::PowerSystemTableData,
    category;
    na_to_nothing = true,
    per_unit = true,
    extras = false,
)
    df = get_dataframe(data, category)
    df_names = Set(DataFrames.names(df))
    field_infos = _get_field_infos(data, category, df_names; per_unit = per_unit)
    # Invariant across every row of this call, so this is where it's built: once, not
    # once per row (`_read_data_row` used to rebuild the same Symbol tuple per row).
    field_names = Tuple(Symbol(field_info.name) for field_info in field_infos)
    declared = Set(field_info.custom_name for field_info in field_infos)

    function row_object(row)
        obj = _read_data_row(
            data,
            row,
            field_infos,
            field_names,
            df_names;
            na_to_nothing = na_to_nothing,
        )
        if extras
            return merge(obj, (ext = _extra_columns(row, declared, df_names),))
        end
        return obj
    end

    return [row_object(row) for row in DataFrames.eachrow(df)]
end

"""
Columns of a row that no descriptor field claims.

Empty cells are left out rather than recorded as blanks: an absent value and an
empty string are not the same statement about the data.
"""
function _extra_columns(row, declared::Set{String}, df_names::Set{String})
    extras = Dict{String, Any}()
    for name in df_names
        if name in declared
            continue
        end
        value = row[name]
        if ismissing(value) || value == ""
            continue
        end
        extras[name] = _ext_value(value)
    end
    return extras
end

_ext_value(value::Real) = value
_ext_value(value::Bool) = value
_ext_value(value::AbstractString) = String(value)
_ext_value(value) = string(value)

"""Stores user-customized information for required dataframe columns."""
struct _FieldInfo
    name::String
    custom_name::String
    per_unit_conversion::NamedTuple{
        (:From, :To, :Reference),
        Tuple{IS.UnitSystem, IS.UnitSystem, String},
    }
    unit_conversion::Union{NamedTuple{(:From, :To), Tuple{String, String}}, Nothing}
    default_value::Any
end

function _get_field_infos(
    data::PowerSystemTableData,
    category::InputCategory,
    df_names;
    per_unit = true,
)
    key = _category_key(category)
    if !haskey(data.user_descriptors, key)
        throw(IS.DataFormatError("Invalid category=$category"))
    end

    if !haskey(data.descriptors, key)
        throw(IS.DataFormatError("Invalid category=$category"))
    end

    # The user's descriptors state what unit system the raw columns are already in.
    source_unit_system = Dict{String, IS.UnitSystem}()
    unit = Dict{String, Union{String, Nothing}}()
    custom_names = Dict{String, String}()
    for descriptor in data.user_descriptors[key]
        custom_name = descriptor["custom_name"]
        if descriptor["custom_name"] in df_names
            source_unit_system[descriptor["name"]] = get_enum_value(
                IS.UnitSystem,
                get(descriptor, "unit_system", "NATURAL_UNITS"),
            )
            unit[descriptor["name"]] = get(descriptor, "unit", nothing)
            custom_names[descriptor["name"]] = custom_name
        else
            @warn "User-defined column name $custom_name is not in dataframe."
        end
    end

    fields = Vector{_FieldInfo}()

    for item in data.descriptors[key]
        name = item["name"]
        item_unit_system =
            get_enum_value(IS.UnitSystem, get(item, "unit_system", "NATURAL_UNITS"))
        per_unit_reference = get(item, "base_reference", "base_power")
        default_value = get(item, "default_value", "required")
        if default_value == "system_base_power"
            default_value = data.base_power
        end

        if name in keys(custom_names)
            custom_name = custom_names[name]
            source = source_unit_system[name]

            if item_unit_system == IS.UnitSystem.NATURAL_UNITS &&
               source != IS.UnitSystem.NATURAL_UNITS
                throw(IS.DataFormatError("$name cannot be defined as $source"))
            end

            # Targeting the source system leaves the value on whatever base the
            # raw column already uses, which is what the schemas want.
            target = item_unit_system
            if !per_unit
                target = source
            end

            pu_conversion =
                (From = source, To = target, Reference = per_unit_reference)

            expected_unit = get(item, "unit", nothing)
            if !isnothing(expected_unit) &&
               !isnothing(unit[name]) &&
               expected_unit != unit[name]
                unit_conversion = (From = unit[name], To = expected_unit)
            else
                unit_conversion = nothing
            end
        else
            custom_name = name
            pu_conversion = (
                From = item_unit_system,
                To = item_unit_system,
                Reference = per_unit_reference,
            )
            unit_conversion = nothing
        end

        push!(
            fields,
            _FieldInfo(name, custom_name, pu_conversion, unit_conversion, default_value),
        )
    end

    return fields
end

_coerce_numeric(value::AbstractString) = tryparse(Float64, value)
_coerce_numeric(value) = value

function _divide_or_zero(value, denominator)
    if iszero(denominator)
        return 0.0
    end
    return value / denominator
end

"""
Reads values from dataframe row and performs necessary conversions.

`field_names` is the Symbol tuple naming the result, in the same order as
`field_infos`; the caller builds it once per `_get_field_infos` result rather than
here, since it is identical for every row of a call.
"""
function _read_data_row(
    data::PowerSystemTableData,
    row,
    field_infos,
    field_names::Tuple,
    df_names::Set{String};
    na_to_nothing = true,
)
    vals = Vector{Any}(undef, length(field_infos))
    for (i, field_info) in enumerate(field_infos)
        if field_info.custom_name in df_names
            value = row[field_info.custom_name]
        else
            value = field_info.default_value
            value == "required" &&
                throw(IS.DataFormatError("$(field_info.name) is required"))
            @debug "Column $(field_info.custom_name) doesn't exist in df, enabling use of default value of $(field_info.default_value)" _group =
                IS.LOG_GROUP_PARSING maxlog = 1
        end
        if ismissing(value)
            throw(IS.DataFormatError("$(field_info.custom_name) value missing"))
        end
        if na_to_nothing && value == "NA"
            value = nothing
        end

        if !isnothing(value)
            if field_info.per_unit_conversion.From == IS.UnitSystem.NATURAL_UNITS &&
               field_info.per_unit_conversion.To == IS.UnitSystem.SYSTEM_BASE
                @debug "convert to $(field_info.per_unit_conversion.To)" _group =
                    IS.LOG_GROUP_PARSING field_info.custom_name
                value = _coerce_numeric(value)
                value = _divide_or_zero(value, data.base_power)
            elseif field_info.per_unit_conversion.From == IS.UnitSystem.NATURAL_UNITS &&
                   field_info.per_unit_conversion.To == IS.UnitSystem.DEVICE_BASE
                reference_idx = findfirst(
                    x -> x.name == field_info.per_unit_conversion.Reference,
                    field_infos,
                )
                isnothing(reference_idx) && throw(
                    IS.DataFormatError(
                        "$(field_info.per_unit_conversion.Reference) not found in table with $(field_info.custom_name)",
                    ),
                )
                reference_info = field_infos[reference_idx]
                @debug "convert to $(field_info.per_unit_conversion.To) using $(reference_info.custom_name)" _group =
                    IS.LOG_GROUP_PARSING field_info.custom_name maxlog = 1
                reference_value =
                    get(row, reference_info.custom_name, reference_info.default_value)
                reference_value == "required" && throw(
                    IS.DataFormatError(
                        "$(reference_info.name) is required for p.u. conversion",
                    ),
                )
                value = _coerce_numeric(value)
                value = _divide_or_zero(value, reference_value)
            elseif field_info.per_unit_conversion.From != field_info.per_unit_conversion.To
                throw(
                    IS.DataFormatError(
                        "conversion not supported from $(field_info.per_unit_conversion.From) to $(field_info.per_unit_conversion.To) for $(field_info.custom_name)",
                    ),
                )
            end
        else
            @debug "$(field_info.custom_name) is nothing" _group = IS.LOG_GROUP_PARSING maxlog =
                1
        end

        if !isnothing(field_info.unit_conversion)
            @debug "convert units" _group = IS.LOG_GROUP_PARSING field_info.custom_name maxlog =
                1
            value = convert_units!(value, field_info.unit_conversion)
        end
        vals[i] = value
    end
    return NamedTuple{field_names}(Tuple(vals))
end
