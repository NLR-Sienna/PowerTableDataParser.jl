# The attribute-to-entity link is a generated Core type. It was hand-written here
# while SiennaSchemas had no schema for it; the schema now exists, so both this
# parser and the power-flow-file path emit the same record.

"""
The document PTDP emits: components grouped by type, the association tables, and
the time series destined for the HDF5 sidecar.

`components` values are concrete `Vector{T}`, so per-type iteration stays
inferable behind a function barrier even though the field is untyped.

`registry` is build-time scaffolding and is not serialized: every id it holds is
recoverable from the emitted components.

`unit_system` records which convention the stored values follow. It is set once at
construction and read by the parsers, so a system cannot hold a mixture.
"""
struct OpenAPISystem
    base_power::Float64
    unit_system::String
    components::Dict{String, Vector}
    supplemental_attributes::Vector{OpenAPI.APIModel}
    supplemental_attribute_associations::Vector{PC.SupplementalAttributeAssociation}
    time_series_associations::Vector{PC.TimeSeriesAssociation}
    time_series::Vector{IS.TimeSeriesData}
    ext::Dict{Int, Dict{String, Any}}
    registry::IdRegistry
end

"""
Unit conventions a document may be written in, from the schemas' `UnitSystem`.

The schemas offer no system-base option: per-unit data historically on the system
base records that base in the component's own `base_power` and rides as
`DEVICE_BASE`.
"""
const UNIT_SYSTEMS = ("NATURAL_UNITS", "DEVICE_BASE")

function OpenAPISystem(
    base_power::Float64;
    unit_system::AbstractString = "NATURAL_UNITS",
)
    if !(unit_system in UNIT_SYSTEMS)
        throw(
            IS.DataFormatError(
                "unit_system must be one of $(join(UNIT_SYSTEMS, ", ")); got $unit_system",
            ),
        )
    end
    return OpenAPISystem(
        base_power,
        String(unit_system),
        Dict{String, Vector}(),
        Vector{OpenAPI.APIModel}(),
        Vector{PC.SupplementalAttributeAssociation}(),
        Vector{PC.TimeSeriesAssociation}(),
        Vector{IS.TimeSeriesData}(),
        Dict{Int, Dict{String, Any}}(),
        IdRegistry(),
    )
end

"""
Record the table columns the data model has no field for, against a component.

Kept beside the components rather than inside them: the schemas describe what a
component is, and this is whatever else the source table happened to state.
"""
function set_ext!(sys::OpenAPISystem, component_id::Int, extras::Dict{String, Any})
    if isempty(extras)
        return
    end
    sys.ext[component_id] = extras
    return
end

get_ext(sys::OpenAPISystem, component_id::Int) =
    get(sys.ext, component_id, Dict{String, Any}())

get_base_power(sys::OpenAPISystem) = sys.base_power
get_registry(sys::OpenAPISystem) = sys.registry

get_unit_system(sys::OpenAPISystem) = sys.unit_system

"""
Whether values are stored per unit rather than in the schemas' natural units.

`DEVICE_BASE` reproduces PowerSystems' storage convention: the descriptors' own
per-unit targets, which is device base for injectors and system base where the
descriptors say so. The `x-unit` annotations still name the natural unit, so a
per-unit document is for comparison against PowerSystems rather than for a
consumer that reads the annotations — which is why the document states the
convention it was written in.
"""
uses_per_unit(sys::OpenAPISystem) = sys.unit_system == "DEVICE_BASE"

function add_component!(sys::OpenAPISystem, component::T) where {T <: OpenAPI.APIModel}
    bucket = get!(sys.components, string(nameof(T))) do
        return Vector{T}()
    end
    push!(bucket, component)
    return
end

"""
Record a supplemental attribute and the entity it describes.

Attributes are held in one list rather than bucketed by type: nothing iterates
them per type, and the association carries the link a consumer needs.
"""
function add_supplemental_attribute!(
    sys::OpenAPISystem,
    attribute::OpenAPI.APIModel,
    entity_id::Int,
)
    push!(sys.supplemental_attributes, attribute)
    push!(
        sys.supplemental_attribute_associations,
        PC.SupplementalAttributeAssociation(;
            attribute_id = get_value(attribute, :id),
            entity_id = entity_id,
            attribute_type = string(nameof(typeof(attribute))),
        ),
    )
    return
end

"""
Record that `entity_id` contributes to the service `service_id`.

A service membership is a row in the same unified `supplemental_attribute_associations`
table as every other attribute link (D10): `service_id` is emitted as `attribute_id` and
`attribute_type` names the service's own type, so a reader distinguishes a membership row
from a plain attribute by looking `attribute_id` up as a component rather than by any field
here. Neither `group_index` nor `role` applies to a membership row.

One row per pair, so each membership is individually addressable. Duplicate pairs are
rejected: the tables express membership as overlapping eligibility rules, so the same
device can match one reserve twice, and silently collapsing that would hide a malformed
rule set.
"""
function add_service_association!(
    sys::OpenAPISystem,
    service_id::Int,
    entity_id::Int,
    attribute_type::AbstractString,
)
    for existing in sys.supplemental_attribute_associations
        if get_value(existing, :attribute_id) == service_id &&
           get_value(existing, :entity_id) == entity_id
            throw(
                IS.DataFormatError(
                    "duplicate service membership: service_id=$service_id entity_id=$entity_id",
                ),
            )
        end
    end
    push!(
        sys.supplemental_attribute_associations,
        PC.SupplementalAttributeAssociation(;
            attribute_id = service_id,
            entity_id = entity_id,
            attribute_type = String(attribute_type),
        ),
    )
    return
end

"""Attributes of one type, in the order they were added."""
function get_supplemental_attributes(sys::OpenAPISystem, type_name::AbstractString)
    return [
        a for a in sys.supplemental_attributes if
        string(nameof(typeof(a))) == String(type_name)
    ]
end

function get_components(sys::OpenAPISystem, type_name::AbstractString)
    return get(sys.components, String(type_name), Vector{OpenAPI.APIModel}())
end

"""Type names in sorted order, so serialized output is deterministic."""
component_type_names(sys::OpenAPISystem) = sort!(collect(keys(sys.components)))
