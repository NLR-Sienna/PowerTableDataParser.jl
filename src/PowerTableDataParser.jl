isdefined(Base, :__precompile__) && __precompile__()

module PowerTableDataParser

#################################################################################
# Exports

export PowerSystemTableData
export System
export make_database

#################################################################################
# Imports

import CSV
import DataFrames
import JSON3
import SiennaOpenAPIModels
import SQLite
import Unicode: normalize
import YAML

import InfrastructureSystems
const IS = InfrastructureSystems

import PowerSystems
const PSY = PowerSystems

# should I import entire model library? end user might build a system with any
# object in model library, but at the same time we only want to support the
# current objects we build in this repo

import PowerSystems:
    AngleUnits,
    ACBusTypes,
    FACTSOperationModes,
    DiscreteControlledBranchType,
    DiscreteControlledBranchStatus,
    WindingCategory,
    ImpedanceCorrectionTransformerControlMode,
    GeneratorCostModels,
    InputCategory,
    PrimeMovers,
    StateTypes,
    ReservoirDataType,
    ReservoirLocation,
    ThermalFuels,
    UnitSystem,
    LoadConformity,
    WindingGroupNumber,
    HydroTurbineType,
    TransformerControlObjective,
    get_enum_value, # from PSY/src/parsers/enums.jl; function used elsewhere in PSY so couldn't be deleted from there
    System,
    ThermalGen,
    HydroGen,
    RenewableGen,
    ACBus,
    Generator,
    Service,
    LoadZone,
    ElectricLoad,
    Storage,
    get_generator_mapping,
    DEFAULT_BASE_MVA,
    set_units_base_system!,
    convert_units!,
    add_component!,
    get_component,
    Area,
    PowerLoad,
    get_bus,
    get_name,
    Arc,
    Line,
    TapTransformer,
    Transformer2W,
    LinearCurve,
    TwoTerminalGenericHVDCLine,
    get_generator_type,
    ThermalStandard,
    calculate_gen_rating,
    parse_enum_mapping,
    PiecewiseIncrementalCurve,
    ThermalGenerationCost,
    FuelCurve,
    get_base_power,
    ThermalMultiStart,
    SynchronousCondenser,
    HydroDispatch,
    HydroTurbine,
    HydroGenerationCost,
    HydroReservoirCost,
    HydroReservoir,
    set_downstream_turbines!,
    add_components!,
    HydroPumpTurbine,
    CostCurve,
    RenewableGenerationCost,
    RenewableDispatch,
    RenewableNonDispatch,
    EnergyReservoirStorage,
    StorageTech,
    StorageCost,
    Device,
    supports_services,
    get_number,
    get_components_by_name,
    ReserveUp,
    VariableReserve,
    add_service!,
    ReserveDown,
    check

#################################################################################
# Includes

include("power_system_table_data.jl")
   
#################################################################################

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                 $(TYPEDSIGNATURES)
                                 $(DOCSTRING)
                                 """

#################################################################################

end
