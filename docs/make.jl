using Documenter
import DataStructures: OrderedDict
using PowerTableDataParser

pages = OrderedDict(
    "Welcome Page" => "index.md",
    "Tutorials" => Any["Overview" => "tutorials/intro_page.md"],
    "How to..." => Any[
        "Parse Tabular Data from .csv Files" => "how_to_guides/parse_tabular_data.md",
    ],
    "Explanation" => Any[
        "Parser Structure and Inputs" => "explanation/structure.md",
    ],
    "Reference" => Any[
        "Developers" => ["Developer Guidelines" => "reference/developer_guidelines.md",
            "Internals" => "reference/internal.md"],
        "Public API" => "reference/public.md",
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
