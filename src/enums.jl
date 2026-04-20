# copied from PSY/src/parsers/enums.jl

IS.@scoped_enum(
    InputCategory,
    BRANCH = 1,
    BUS = 2,
    DC_BRANCH = 3,
    GENERATOR = 4,
    LOAD = 5,
    RESERVE = 6,
    SIMULATION_OBJECTS = 7,
    STORAGE = 8,
    FACTS = 9,
    DCBRTYPE = 10,
    DCBRSTATUS = 11,
    TICT = 12,
)

const ENUMS = (
    InputCategory,
)

const ENUM_MAPPINGS = Dict()

for enum in ENUMS
    ENUM_MAPPINGS[enum] = Dict()
    for value in instances(enum)
        ENUM_MAPPINGS[enum][normalize(string(value); casefold = true)] = value
    end
end

# get_enum_value used once in PowerSystemTableData(), but only with the enum type InputCategory
"""Get the enum value for the string. Case insensitive."""
function get_enum_value(enum, value::AbstractString)
    if !haskey(ENUM_MAPPINGS, enum)
        throw(ArgumentError("enum=$enum is not valid"))
    end

    val = normalize(value; casefold = true)
    if !haskey(ENUM_MAPPINGS[enum], val)
        throw(ArgumentError("enum=$enum does not have value=$val"))
    end

    return ENUM_MAPPINGS[enum][val]
end
