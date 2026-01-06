# copied from PowerSystems.jl/src/utils/print.jl so this method for show is still available

function Base.show(io::IO, ::MIME"text/plain", data::PowerSystemTableData)
    println(io, "$(typeof(data)):")
    println(io, "  directory:  $(data.directory)")
    if !isnothing(data.timeseries_metadata_file)
        println(io, "  timeseries_metadata_file:  $(data.timeseries_metadata_file)")
    end
    println(io, "  base_power:  $(data.base_power)")
    for (field, df) in data.category_to_df
        print(io, "  $field:  ")
        println(io, "$(summary(df))")
    end
end
