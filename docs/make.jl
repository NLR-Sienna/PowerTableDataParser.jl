using Documenter
import DataStructures: OrderedDict
using PowerTableDataParser

pages = OrderedDict(
    "Welcome Page" => "index.md",
    "Tutorials" => Any["stub" => "tutorials/stub.md"],
    "How to..." => Any["stub" => "how_to_guides/stub.md"],
    "Explanation" => Any["stub" => "explanation/stub.md"],
    "Reference" => Any[
        "Developers" => ["Developer Guidelines" => "reference/developer_guidelines.md",
        "Internals" => "reference/internal.md"],
        "Public API" => "reference/public.md",
        "Stub" => "reference/stub.md"
    ],
)

makedocs(
    modules = [PowerTableDataParser],
    format = Documenter.HTML(
        prettyurls = haskey(ENV, "GITHUB_ACTIONS"),
        size_threshold = nothing,),
    sitename = "github.com/NLR-Sienna/PowerTableDataParser.jl",
    authors = "José Daniel Lara",
    pages = Any[p for p in pages],
    draft = false,
)

deploydocs(
    repo="github.com/NLR-Sienna/PowerTableDataParser.jl",
    target="build",
    branch="gh-pages",
    devbranch="main",
    devurl="dev",
    push_preview=true,
    versions=["stable" => "v^", "v#.#"],
)
