# copied from PowerSystems.jl/test/common.jl

"""Return the Branch in the system that matches another by case-insensitive arc
names."""
function get_branch(sys::System, other::Branch)
    for branch in get_components(Branch, sys)
        if lowercase(other.arc.from.name) == lowercase(branch.arc.from.name) &&
           lowercase(other.arc.to.name) == lowercase(branch.arc.to.name)
            return branch
        end
    end

    error("Did not find branch with buses $(other.arc.from.name) ", "$(other.arc.to.name)")
end
#=
function create_rts_system(time_series_resolution = Dates.Hour(1))
    data = PDP.PowerSystemTableData(RTS_GMLC_DIR, 100.0, DESCRIPTORS)
    return System(data; time_series_resolution = time_series_resolution)
end
