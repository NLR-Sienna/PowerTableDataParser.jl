isdefined(Base, :__precompile__) && __precompile__()

module PowerTableDataParser

#################################################################################
# Exports

export PowerSystemTableData

#################################################################################
# Imports

import CSV
import DataFrames
import JSON3
import SQLite
import Unicode: normalize
import YAML

import InfrastructureSystems
const IS = InfrastructureSystems
import InfrastructureSystems:
    DataFormatError

#################################################################################
# Includes

include("common.jl")
include("enums.jl")
include("power_system_table_data.jl")

#################################################################################

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                 $(TYPEDSIGNATURES)
                                 $(DOCSTRING)
                                 """

#################################################################################

end
