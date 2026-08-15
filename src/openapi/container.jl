"""
The document PTDP emits, as a thin wrapper over `PC.SystemDocument`.

`document` is the only serialized artifact: components, the association tables,
`ext` and the unit convention all live on it.

`registry` is build-time scaffolding and is not serialized: it keeps the lookup
indices (by name, by bus number, by arc) the document has no use for once built.

`time_series` is the payload written to the HDF5 sidecar; `document` carries
only the `TimeSeriesAssociation` rows pointing at it.
"""
struct OpenAPISystem
    document::PC.SystemDocument
    registry::IdRegistry
    time_series::Vector{IS.TimeSeriesData}
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
    document = PC.SystemDocument(base_power; unit_system = unit_system)
    return OpenAPISystem(document, IdRegistry(document), Vector{IS.TimeSeriesData}())
end

get_document(sys::OpenAPISystem) = sys.document

get_supplemental_attribute_associations(sys::OpenAPISystem) =
    get_document(sys).supplemental_attribute_associations
get_service_associations(sys::OpenAPISystem) = get_document(sys).service_associations
get_time_series_associations(sys::OpenAPISystem) =
    get_document(sys).time_series_associations

"""Record the table columns the data model has no field for, against a component."""
function set_ext!(sys::OpenAPISystem, component_id::Int, extras::Dict{String, Any})
    PC.set_ext!(get_document(sys), component_id, extras)
    return
end

get_ext(sys::OpenAPISystem, component_id::Int) = PC.get_ext(get_document(sys), component_id)

get_base_power(sys::OpenAPISystem) = PC.get_base_power(get_document(sys))
get_registry(sys::OpenAPISystem) = sys.registry

get_unit_system(sys::OpenAPISystem) = PC.get_unit_system(get_document(sys))

"""
Whether values are stored per unit rather than in the schemas' natural units.

`DEVICE_BASE` reproduces PowerSystems' storage convention: the descriptors' own
per-unit targets, which is device base for injectors and system base where the
descriptors say so. The `x-unit` annotations still name the natural unit, so a
per-unit document is for comparison against PowerSystems rather than for a
consumer that reads the annotations — which is why the document states the
convention it was written in.
"""
uses_per_unit(sys::OpenAPISystem) = PC.uses_per_unit(get_document(sys))

function add_component!(sys::OpenAPISystem, component::T) where {T <: OpenAPI.APIModel}
    PC.add_component!(get_document(sys), component)
    return
end

"""
Record a supplemental attribute and the entity it describes.

Neither plant-family groupings nor service memberships apply to anything this parser
emits: it has no plant-family attributes, and reserve membership goes through
`add_service_association!` below, which uses its own table.
"""
function add_supplemental_attribute!(
    sys::OpenAPISystem,
    attribute::OpenAPI.APIModel,
    entity_id::Int,
)
    PC.add_supplemental_attribute!(get_document(sys), attribute, entity_id)
    return
end

"""
Record that `entity_id` contributes to the service `service_id`.

A service membership is a row in the dedicated `service_associations` table: `entity_id`
may name a Device, a Branch, or another Service, so no member-type discriminator is
needed.

One row per pair, so each membership is individually addressable. Duplicate pairs are
rejected: the tables express membership as overlapping eligibility rules, so the same
device can match one reserve twice, and silently collapsing that would hide a malformed
rule set.
"""
function add_service_association!(
    sys::OpenAPISystem,
    service_id::Int,
    entity_id::Int,
)
    associations = get_service_associations(sys)
    for existing in associations
        if get_value(existing, :service_id) == service_id &&
           get_value(existing, :entity_id) == entity_id
            throw(
                IS.DataFormatError(
                    "duplicate service membership: service_id=$service_id entity_id=$entity_id",
                ),
            )
        end
    end
    push!(
        associations,
        PO.ServiceAssociation(; service_id = service_id, entity_id = entity_id),
    )
    return
end

"""Attributes of one type, in the order they were added."""
function get_supplemental_attributes(sys::OpenAPISystem, type_name::AbstractString)
    return PC.get_supplemental_attributes(get_document(sys), type_name)
end

function get_components(sys::OpenAPISystem, type_name::AbstractString)
    return PC.get_components(get_document(sys), type_name)
end

"""Type names in sorted order, so serialized output is deterministic."""
component_type_names(sys::OpenAPISystem) = PC.component_type_names(get_document(sys))
