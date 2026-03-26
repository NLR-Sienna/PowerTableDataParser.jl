isdefined(Base, :__precompile__) && __precompile__()

module PowerTableDataParser

#################################################################################
# Exports

export PowerSystemTableData
#export System
#export make_database
#export create_poly_cost

#################################################################################
# Imports

import CSV
import DataFrames
import JSON3
#import SiennaOpenAPIModels
import SQLite
import Unicode: normalize
import YAML

import InfrastructureSystems
const IS = InfrastructureSystems
#=
import PowerSystems
const PSY = PowerSystems

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
    check,
    get_components,
    QuadraticCurve,
    PiecewisePointCurve,
    get_rating,
    PiecewiseLinearData,
    get_operation_cost,
    get_active_power_limits_from,
    add_time_series!,
    get_start_up,
    get_shut_down,
    get_variable,
    get_fixed,
    get_available,
    get_status,
    get_active_power,
    get_reactive_power,
    get_prime_mover_type,
    get_fuel,
    get_active_power_limits,
    get_reactive_power_limits,
    get_ramp_limits,
    get_time_limits,
    get_time_at_status,
    get_must_run
=#
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
