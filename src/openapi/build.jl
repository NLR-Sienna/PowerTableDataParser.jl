# Zones and buses are parsed unconditionally and in that order: a bus resolves its
# load zone by name. Everything else is parsed only if its table has rows, which
# is how a dataset like RTS — with no load.csv — passes through.

"""
Assemble an `OpenAPISystem` from parsed table data.

`power_units` selects the convention the values are stored in: `NATURAL_UNITS`,
which is what the schema annotations describe, or `COMPONENT_BASE`, which applies
the descriptors' per-unit targets and so reproduces what PowerSystems stores.
The choice is stamped onto every emitted component that declares the field.

Time series are read when the data names a pointer file. The values are held in
memory; `write_time_series` puts them in an InfraStore sidecar pair whose
catalog carries the owner associations.
"""
function build_openapi_system(
    data::PowerSystemTableData;
    power_units::AbstractString = "NATURAL_UNITS",
)
    sys = OpenAPISystem(data.base_power; power_units = power_units)

    loadzone_csv_parser!(sys, data)
    bus_csv_parser!(sys, data)

    parsers = (
        (InputCategory.BRANCH, branch_csv_parser!),
        (InputCategory.DC_BRANCH, dc_branch_csv_parser!),
        (InputCategory.GENERATOR, gen_csv_parser!),
        (InputCategory.LOAD, load_csv_parser!),
        (InputCategory.RESERVE, services_csv_parser!),
    )
    _run_parsers!(sys, data, parsers)

    # Supplemental attributes describe components, so they run once those exist.
    attribute_parsers = (
        (InputCategory.BUS, geographic_info_csv_parser!),
        (InputCategory.GENERATOR, emissions_csv_parser!),
        (InputCategory.GENERATOR, outages_csv_parser!),
        (InputCategory.BUS, ext_csv_parser!),
    )
    _run_parsers!(sys, data, attribute_parsers)

    if !isnothing(data.timeseries_metadata_file)
        add_time_series!(sys, data.timeseries_metadata_file)
    end

    return sys
end

"""Run each `(category, parser!)` pair whose category has rows."""
function _run_parsers!(sys::OpenAPISystem, data::PowerSystemTableData, parsers)
    for (category, parser) in parsers
        if !isempty(get_dataframe(data, category))
            parser(sys, data)
        end
    end
    return
end
