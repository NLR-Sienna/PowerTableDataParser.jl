# `PC.write_document` owns the JSON envelope now: it builds the tree, validates the
# document and encodes it in one pass. This file supplies only what PC's document does
# not: the HDF5 sidecar's name and its values.

"""HDF5 sidecar name for a document, following the PowerSystems convention."""
function time_series_filename(filename::AbstractString)
    return string(splitext(basename(filename))[1], "_time_series_storage.h5")
end

"""
`doc`, pointed at `ts_basename` (or unpointed when the system carries no time series).

`PC.SystemDocument`'s scalar fields, `time_series_storage_file` included, are immutable,
so the document built while parsing cannot be told its eventual filename as parsing goes.
This reconstructs the struct through PC's own default positional constructor, sharing every
mutable container (`components`, `ext`, the association vectors, the id counter) with `doc`
by reference rather than copying them, so it is the same document under a different name.
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
together. `PC.write_document` validates the document before it reaches disk; a system with
no time series points at no sidecar rather than an empty one.
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
    @info "Serialized OpenAPISystem to $filename" *
          (isnothing(ts_basename) ? "" : " and its sidecar $ts_basename")
    return
end
