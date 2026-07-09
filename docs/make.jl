# Documenter.jl site build for PISP.jl.
#
# A normal docs build publishes the Markdown already present under docs/src/.
# Literate tutorial regeneration is intentionally a separate maintainer step in
# docs/render_literate.jl so this build does not require local AEMO/PISP output
# data.

using Documenter
using PISP

const DOCS_DIR = @__DIR__
const SRC = joinpath(DOCS_DIR, "src")
const BUILD = joinpath(DOCS_DIR, "build")

format = Documenter.HTML(;
    prettyurls = get(ENV, "CI", "false") == "true",
    inventory_version = "dev",
    edit_link = "main",
)

makedocs(;
    sitename = "PISP.jl",
    format = format,
    build = BUILD,
    source = SRC,
    pages = [
        "Home" => "index.md",
        "Data sources" => "data-sources.md",
        "Domain concepts" => "concepts.md",
        "Output tables" => "outputs.md",
        "Parameters and mappings" => "parameters.md",
        "Assumptions and scope" => "assumptions.md",
        "Tutorials" => [
            "Problem table" => "generated/problem_table.md",
            "Output validation" => "generated/pisp_outputs_validation.md",
        ],
        "API Reference" => "api.md",
    ],
)
