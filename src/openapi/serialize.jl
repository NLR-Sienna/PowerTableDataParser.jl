# The document holds the model objects themselves and is encoded once.
# `JSON.lower(::APIModel)` returns a wrapper that iterates properties and skips
# the unset ones, so nesting and optional fields need no handling here. Encoding a
# component on its own with `OpenAPI.to_json` would yield a String and produce a
# double-encoded document.

"""HDF5 sidecar name for a document, following the PowerSystems convention."""
function time_series_filename(filename::AbstractString)
    return string(splitext(basename(filename))[1], "_time_series_storage.h5")
end

"""Function barrier: one specialization per concrete component vector."""
function _bucket(components::Vector{T}) where {T <: OpenAPI.APIModel}
    return collect(components)
end

"""
The document, as a tree of model objects.

Component type keys come from `component_type_names`, so their order is stable
across builds. The values themselves are not: time series UUIDs are random, so
two builds of the same data differ.
"""
function serialize(sys::OpenAPISystem, ts_basename::AbstractString)
    components = Dict{String, Any}()
    for type_name in component_type_names(sys)
        components[type_name] = _bucket(get_components(sys, type_name))
    end
    return Dict{String, Any}(
        "base_power" => get_base_power(sys),
        # Values are only interpretable against the convention they were written
        # in, and the x-unit annotations name the natural unit either way.
        "unit_system" => get_unit_system(sys),
        "components" => components,
        "supplemental_attributes" => sys.supplemental_attributes,
        "supplemental_attribute_associations" =>
            sys.supplemental_attribute_associations,
        # `sys.ext` is deliberately NOT emitted. It holds source columns no schema field
        # claims; a consumer has nowhere to put them, so writing them would only be data
        # that round-trips into nothing. They stay on the container for callers that want
        # the raw table values in-process.
        "ext" => Dict{String, Any}(),
        "time_series_associations" => sys.time_series_associations,
        "time_series_storage_file" => ts_basename,
    )
end

"""
Write the document and its time series sidecar.

The sidecar is named after the document and sits beside it, so the pair can be
moved together.
"""
function to_json(
    sys::OpenAPISystem,
    filename::AbstractString;
    force = false,
    pretty = false,
)
    ts_basename = time_series_filename(filename)
    ts_path = joinpath(dirname(abspath(filename)), ts_basename)
    if !force && (isfile(filename) || isfile(ts_path))
        error("$filename or $ts_path already exists. Set force = true to overwrite.")
    end
    rm(ts_path; force = true)

    write_time_series(sys, ts_path)
    data = serialize(sys, ts_basename)
    open(filename, "w") do io
        if pretty
            JSON.print(io, data, 2)
        else
            JSON.print(io, data)
        end
    end
    @info "Serialized OpenAPISystem to $filename and $ts_path"
    return
end
