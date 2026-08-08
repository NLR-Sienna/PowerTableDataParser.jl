# `PC.write_document` owns the JSON envelope; this file supplies only what the document
# does not carry: the HDF5 sidecar's name and its values.

"""HDF5 sidecar name for a document, following the PowerSystems convention."""
function time_series_filename(filename::AbstractString)
    return string(splitext(basename(filename))[1], "_time_series_storage.h5")
end

"""
`doc`, pointed at `ts_basename`.

`time_series_storage_file` is immutable and only known once the output filename is, so the
struct is rebuilt around the same mutable containers — by reference, not copied.
"""
function _document_for_write(doc::PC.SystemDocument, ts_basename::Union{Nothing, String})
    return PC.SystemDocument(
        doc.base_power,
        doc.unit_system,
        doc.name,
        doc.description,
        doc.frequency,
        doc.components,
        doc.supplemental_attributes,
        doc.supplemental_attribute_associations,
        doc.time_series_associations,
        doc.ext,
        ts_basename,
        doc.counter,
    )
end

"""
Write the document and its time series sidecar.

The sidecar is named after the document and sits beside it, so the pair can be moved
together. A system with no time series points at no sidecar rather than an empty one.
"""
function to_json(
    sys::OpenAPISystem,
    filename::AbstractString;
    force::Bool = false,
    pretty::Bool = false,
)
    ts_basename = nothing
    if !isempty(sys.time_series)
        ts_basename = time_series_filename(filename)
        ts_path = joinpath(dirname(abspath(filename)), ts_basename)
        if !force && isfile(ts_path)
            error("$ts_path already exists. Set force = true to overwrite.")
        end
        rm(ts_path; force = true)
        write_time_series(sys, ts_path)
    end
    document = _document_for_write(get_document(sys), ts_basename)
    PC.write_document(document, filename; pretty = pretty, force = force)
    if isnothing(ts_basename)
        @info "Serialized OpenAPISystem to $filename"
    else
        @info "Serialized OpenAPISystem to $filename and its sidecar $ts_basename"
    end
    return
end
