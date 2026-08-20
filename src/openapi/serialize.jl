# `PD.write_document` owns the JSON envelope; this file supplies only what the document
# does not carry: the InfraStore sidecar's name and its contents.

"""
InfraStore sidecar name for a document, following the PowerSystems convention.
The store writes this file plus a `.sqlite` sibling holding the catalog.
"""
function time_series_filename(filename::AbstractString)
    return string(splitext(basename(filename))[1], "_time_series_storage.h5")
end

"""
`doc`, pointed at `ts_basename`.

`time_series_storage_file` is immutable and only known once the output filename is, so the
struct is rebuilt around the same mutable containers — by reference, not copied.

Fields are copied by name rather than listed positionally: this is a container owned by
another package, and spelling out its field order here means every field added there (the
plant/combined-cycle/service association tables, most recently) silently breaks this call.
"""
function _document_for_write(doc::PD.SystemDocument, ts_basename::Union{Nothing, String})
    args = map(fieldnames(PD.SystemDocument)) do field
        field === :time_series_storage_file ? ts_basename : getfield(doc, field)
    end
    return PD.SystemDocument(args...)
end

"""
Write the document and its time series sidecar pair.

The sidecar is named after the document and sits beside it (with its `.sqlite`
catalog sibling), so the set can be moved together. A system with no time series
points at no sidecar rather than an empty one.
"""
function to_json(
    sys::OpenAPISystem,
    filename::AbstractString;
    force::Bool = false,
    pretty::Bool = false,
)
    ts_basename = nothing
    # Rebuilt rather than appended, so a second `to_json` on the same system does not stack a
    # duplicate set of rows. The rows describe the catalog that was just written, so they are
    # built from what `write_time_series` committed rather than from the staged series.
    associations = get_document(sys).time_series_associations
    empty!(associations)
    if !isempty(sys.time_series)
        ts_basename = time_series_filename(filename)
        ts_path = joinpath(dirname(abspath(filename)), ts_basename)
        for artifact in (ts_path, ts_path * ".sqlite")
            if !force && isfile(artifact)
                error("$artifact already exists. Set force = true to overwrite.")
            end
            rm(artifact; force = true)
        end
        append!(associations, write_time_series(sys, ts_path, ts_basename))
    end
    document = _document_for_write(get_document(sys), ts_basename)
    PD.write_document(document, filename; pretty = pretty, force = force)
    if isnothing(ts_basename)
        @info "Serialized OpenAPISystem to $filename"
    else
        @info "Serialized OpenAPISystem to $filename and its sidecar pair $ts_basename (+ .sqlite)"
    end
    return
end
