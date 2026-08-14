# Time series pointer files ("timeseries_pointers.json") are this package's feature:
# InfrastructureSystems dropped its file-metadata ingestion, and the reimplementation
# that briefly lived in PowerSystemCaseBuilder now lives here. The PowerSystems-facing
# method is provided by the PowerTableDataParserPowerSystemsExt extension, so the core
# package stays free of a PowerSystems dependency; the OpenAPI document path in
# `openapi/time_series.jl` reads the same files without it.

"""
Attach the time series named by a pointer/metadata file to a `PowerSystems.System`.

Each pointer's CSV is read directly and stored as a `SingleTimeSeries` holding the
raw values — the legacy lazy `scaling_factor_multiplier` / `normalization_factor`
mechanism no longer exists in storage, so a normalized zonal load shape is
materialized as one scaled series per load in the zone instead.

Defined by the extension that loads with PowerSystems:
`add_time_series_from_pointers!(sys::PowerSystems.System, metadata_file; resolution = nothing)`.
`resolution` (a `Dates.Period`) skips every entry stated at a different resolution.
"""
function add_time_series_from_pointers! end

"""
Values and initial timestamp for one component in a pointer entry's CSV.

The CSVs use either a column-per-component layout — one row per timestep, indexed
by a single `DateTime` column or by `Year, Month, Day, Period` columns — or the
period-pivoted layout of [`read_period_pivoted_csv`](@ref). Returns
`(values, initial_timestamp)`, or `nothing` when the frame has neither a column
for the component nor the pivoted shape.
"""
function read_pointer_csv_values(
    df::DataFrames.DataFrame,
    component_name::AbstractString,
    resolution::Dates.Period,
)
    col = Symbol(component_name)
    DataFrames.hasproperty(df, col) || return read_period_pivoted_csv(df)
    initial_timestamp = if DataFrames.hasproperty(df, :DateTime)
        Dates.DateTime(df[1, :DateTime])
    else
        Dates.DateTime(df[1, :Year], df[1, :Month], df[1, :Day]) +
        (df[1, :Period] - 1) * resolution
    end
    return (Float64.(df[!, col]), initial_timestamp)
end

"""
Read a period-pivoted forecast CSV: one row per day, indexed by `Year, Month, Day`, with
one column per period of that day (`1, 2, ... 24`) rather than a column named after the
component. Such a file holds exactly one component's series, so the periods are flattened
row-major into a single vector.

Returns `(values, initial_timestamp)`, or `nothing` if `df` is not in this layout.
"""
function read_period_pivoted_csv(df::DataFrames.DataFrame)
    period_cols = filter(!isnothing ∘ _period_index, DataFrames.names(df))
    isempty(period_cols) && return nothing
    all(c -> DataFrames.hasproperty(df, Symbol(c)), ("Year", "Month", "Day")) ||
        return nothing
    sort!(period_cols; by = _period_index)

    values = Float64[]
    sizehint!(values, DataFrames.nrow(df) * length(period_cols))
    for row in 1:DataFrames.nrow(df)
        for c in period_cols
            push!(values, Float64(df[row, Symbol(c)]))
        end
    end
    initial_timestamp = Dates.DateTime(df[1, :Year], df[1, :Month], df[1, :Day])
    return (values, initial_timestamp)
end

# A column is a period column iff its name is a bare integer (e.g. "1" ... "24").
_period_index(name) = tryparse(Int, String(name))
