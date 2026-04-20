import LazyArtifacts

const RTS_SRC = joinpath(
    LazyArtifacts.artifact"rts",
    "RTS-GMLC-0.2.3",
    "RTS_Data",
    "SourceData",
)
const RTS_DESCRIPTORS = joinpath(@__DIR__, "data", "rts", "user_descriptors.yaml")

const BUS118_SRC = joinpath(
    LazyArtifacts.artifact"CaseData",
    "PowerSystemsTestData-4.0.2",
    "118-Bus",
)
const BUS118_DESCRIPTORS = joinpath(@__DIR__, "data", "118_bus", "user_descriptors.yaml")
const BUS118_GEN_MAPPING = joinpath(@__DIR__, "data", "118_bus", "generator_mapping.yaml")

load_rts_data() = PDP.PowerSystemTableData(RTS_SRC, 100.0, RTS_DESCRIPTORS)

# 118-Bus CSVs ship with PLEXOS-style filenames (Buses.csv / Lines.csv) but the
# parser keys off lowercase stems (bus / branch / gen). Stage them in a tmpdir.
function load_118_bus_data()
    tmpdir = mktempdir()
    cp(joinpath(BUS118_SRC, "Buses.csv"), joinpath(tmpdir, "bus.csv"))
    cp(joinpath(BUS118_SRC, "Lines.csv"), joinpath(tmpdir, "branch.csv"))
    cp(joinpath(BUS118_SRC, "gen.csv"), joinpath(tmpdir, "gen.csv"))
    return PDP.PowerSystemTableData(
        tmpdir,
        100.0,
        BUS118_DESCRIPTORS;
        generator_mapping_file = BUS118_GEN_MAPPING,
    )
end
