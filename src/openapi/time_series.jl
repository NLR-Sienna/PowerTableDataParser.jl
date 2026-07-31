# Time series come from the pointer file, are read through InfrastructureSystems'
# CSV readers, and are recorded as TimeSeriesAssociation rows. The values
# themselves go to an HDF5 sidecar written by `write_time_series`.
#
# One association per owner (design D10). RTS points every series at two
# resolutions, and resolution is part of a series' identity in IS4, so the pairs
# are not deduplicated on (owner, name). A series stated for a zone gains one row
# per load underneath it, all against the same series — see `series_owners`.

"""
Component types a pointer file's `category` may name.

The owner search is narrowed by category because a bare name is not unique: RTS
aliases the zone column to the area column, so "1", "2" and "3" each name both an
`Area` and a `LoadZone`.
"""
const CATEGORY_TO_TYPES = Dict(
    "Generator" => [
        "ThermalStandard",
        "RenewableDispatch",
        "RenewableNonDispatch",
        "HydroTurbine",
        "HydroDispatch",
        "SynchronousCondenser",
        "EnergyReservoirStorage",
    ],
    "ElectricLoad" => ["PowerLoad", "StandardLoad"],
    "LoadZone" => ["LoadZone"],
    "Area" => ["Area"],
    "Reserve" => ["VariableReserve", "ConstantReserve"],
    "Storage" => ["EnergyReservoirStorage"],
)

function category_to_type_names(category::AbstractString)
    key = String(category)
    if !haskey(CATEGORY_TO_TYPES, key)
        throw(IS.DataFormatError("unmapped time series category=$category"))
    end
    return CATEGORY_TO_TYPES[key]
end

"""ISO 8601 duration, which is how the schemas state a resolution."""
function _iso_duration(period::Dates.Period)
    return string("PT", Dates.value(Dates.Second(period)), "S")
end

"""
One entry of a time series pointer file.

`IS.read_time_series_file_metadata` cannot be used here: it resolves the entry's
`module` field through the loaded-module table, and every RTS entry names
`PowerSystems`, which this package deliberately does not depend on. The type it
names, `SingleTimeSeries`, is an InfrastructureSystems type regardless, so the
field is read and checked rather than resolved.
"""
struct TimeSeriesPointer
    category::String
    component_name::String
    name::String
    normalization_factor::Union{Float64, String}
    data_file::String
    resolution::Dates.Period
    scaling_factor_multiplier::Union{Nothing, String}
end

function _pointer(item::Dict, directory::AbstractString)
    series_type = get(item, "type", "SingleTimeSeries")
    if series_type != "SingleTimeSeries"
        throw(
            IS.DataFormatError(
                "only SingleTimeSeries pointers are supported, got $series_type for " *
                "$(item["component_name"])",
            ),
        )
    end
    normalization_factor = item["normalization_factor"]
    if !isa(normalization_factor, AbstractString)
        normalization_factor = Float64(normalization_factor)
    end
    multiplier = get(item, "scaling_factor_multiplier", nothing)
    if !isnothing(multiplier)
        multiplier = String(multiplier)
    end
    return TimeSeriesPointer(
        item["category"],
        item["component_name"],
        item["name"],
        normalization_factor,
        abspath(joinpath(directory, item["data_file"])),
        Dates.Millisecond(Dates.Second(item["resolution"])),
        multiplier,
    )
end

"""Read a pointer file, resolving each data file against the pointer's own directory."""
function read_time_series_pointers(metadata_file::AbstractString)
    if !endswith(metadata_file, ".json")
        throw(
            IS.DataFormatError(
                "time series pointers must be a .json file, got $metadata_file",
            ),
        )
    end
    directory = dirname(metadata_file)
    items = open(metadata_file) do io
        return JSON.parse(io; dicttype = Dict{String, Any})
    end
    return [_pointer(item, directory) for item in items]
end

"""
Bus property that places a bus inside each aggregation topology.

A load series stated for an aggregation belongs to the loads underneath it, so
membership is resolved through the buses.
"""
const AGGREGATION_BUS_PROPERTIES = Dict("LoadZone" => "load_zone", "Area" => "area")

"""Multipliers that make a series belong to the loads rather than the aggregation."""
const FANNED_OUT_MULTIPLIERS = ("get_max_active_power", "get_max_reactive_power")

"""Component types that carry a load series."""
const LOAD_TYPES = ("PowerLoad", "StandardLoad")

"""
Loads sitting under an aggregation topology.

Mirrors what PowerSystems does when it reads a zone's load series: it walks the
buses of the aggregation and collects every `ElectricLoad` on them.
"""
function _loads_under(sys::OpenAPISystem, owner_type::AbstractString, owner_id::Int)
    property = Symbol(AGGREGATION_BUS_PROPERTIES[owner_type])
    bus_ids = Set(
        get_value(bus, :id) for
        bus in get_components(sys, "ACBus") if get_value(bus, property) == owner_id
    )
    owners = Tuple{String, Int}[]
    for type_name in LOAD_TYPES
        for load in get_components(sys, type_name)
            if get_value(load, :bus) in bus_ids
                push!(owners, (type_name, get_value(load, :id)))
            end
        end
    end
    return owners
end

"""
Every owner a pointer entry produces, with the multiplier each one applies.

Usually the entry names its owner directly. A load series stated for a zone or an
area is different: the values describe the loads underneath, so PowerSystems
attaches that one series to each of them and keeps a copy on the aggregation
under its own accessor — `peak_active_power` rather than `max_active_power`. The
association table expresses that directly, one row per owner against a single
series, so nothing is duplicated in the HDF5 sidecar.
"""
function series_owners(
    sys::OpenAPISystem,
    entry::TimeSeriesPointer,
    owner_type::AbstractString,
    owner_id::Int,
)
    multiplier = entry.scaling_factor_multiplier
    if !haskey(AGGREGATION_BUS_PROPERTIES, owner_type) ||
       isnothing(multiplier) ||
       !(multiplier in FANNED_OUT_MULTIPLIERS)
        return [(owner_type, owner_id, multiplier)]
    end

    owners = Tuple{String, Int, Union{Nothing, String}}[
        (type_name, id, multiplier) for
        (type_name, id) in _loads_under(sys, owner_type, owner_id)
    ]
    push!(owners, (owner_type, owner_id, replace(multiplier, "max" => "peak")))
    return owners
end

function _scaling_factor_multiplier!(association, multiplier::AbstractString)
    set_value!(association, :scaling_factor_multiplier, String(multiplier))
    return
end

function _scaling_factor_multiplier!(association, ::Nothing)
    return
end

"""
Read every series the pointer file names and record its association.

The reader returns every column of the source CSV, so the column for this entry's
component is selected explicitly.
"""
function add_time_series!(sys::OpenAPISystem, metadata_file::AbstractString)
    reg = get_registry(sys)
    for entry in read_time_series_pointers(metadata_file)
        owner_type, owner_id = find_by_name(
            reg,
            category_to_type_names(entry.category),
            entry.component_name,
        )
        raw = IS.read_time_series(
            IS.SingleTimeSeries,
            entry.data_file,
            entry.component_name,
        )
        values = IS.make_time_array(raw, entry.component_name, entry.resolution)
        series = IS.SingleTimeSeries(
            entry.name,
            values;
            normalization_factor = entry.normalization_factor,
        )
        push!(sys.time_series, series)

        for (target_type, target_id, multiplier) in
            series_owners(sys, entry, owner_type, owner_id)
            _add_association!(sys, entry, series, raw, target_type, target_id, multiplier)
        end
    end
    return
end

"""One row of the association table: this series, this owner."""
function _add_association!(
    sys::OpenAPISystem,
    entry::TimeSeriesPointer,
    series::IS.TimeSeriesData,
    raw,
    owner_type::AbstractString,
    owner_id::Int,
    multiplier,
)
    association = PC.TimeSeriesAssociation()
    set_value!(association, :id, length(sys.time_series_associations) + 1)
    set_value!(association, :time_series_uuid, string(IS.get_uuid(series)))
    set_value!(association, :time_series_type, "SingleTimeSeries")
    set_value!(
        association,
        :initial_timestamp,
        TimeZones.ZonedDateTime(raw.initial_time, TimeZones.tz"UTC"),
    )
    set_value!(association, :resolution, _iso_duration(entry.resolution))
    set_value!(association, :length, length(series))
    set_value!(association, :name, entry.name)
    set_value!(association, :owner_id, owner_id)
    set_value!(association, :owner_type, owner_type)
    set_value!(association, :owner_category, "Component")
    set_value!(association, :features, Dict{String, PC.FeatureValue}[])
    _scaling_factor_multiplier!(association, multiplier)
    set_value!(association, :metadata_uuid, string(UUIDs.uuid4()))
    push!(sys.time_series_associations, association)
    return
end

"""
Write the series values to an HDF5 sidecar.

The store keys on the series UUID, which is what keeps a group per series even
when two entries share an owner and a name at different resolutions.
"""
function write_time_series(sys::OpenAPISystem, h5_path::AbstractString)
    storage = IS.Hdf5TimeSeriesStorage(true; filename = String(h5_path))
    for series in sys.time_series
        IS.serialize_time_series!(storage, series)
    end
    return
end
