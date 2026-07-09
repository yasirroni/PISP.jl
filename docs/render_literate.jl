# Regenerate committed tutorial Markdown under docs/src/generated/.
#
# Run this script explicitly when a tutorial source changes.
# The ordinary Documenter build in docs/make.jl does not call it.

using Literate

const DOCS_DIR = @__DIR__
const LITERATE_DIR = joinpath(DOCS_DIR, "literate")
const GENERATED_DIR = joinpath(DOCS_DIR, "src", "generated")
const REPO_ROOT = joinpath(DOCS_DIR, "..")
const PISP_DATA_ROOT = joinpath(
    REPO_ROOT, "data", "pisp-datasets", "out-ref4006-poe10", "csv",
)

mkpath(GENERATED_DIR)

const LITERATE_SOURCES = [
    "problem_table.jl",
    "pisp_outputs_validation.jl",
]

for source_name in LITERATE_SOURCES
    source_path = joinpath(LITERATE_DIR, source_name)

    if source_name == "pisp_outputs_validation.jl" && !isdir(PISP_DATA_ROOT)
        error(
            "expected local PISP output data at \"$PISP_DATA_ROOT\"; " *
            "build data/pisp-datasets/out-ref4006-poe10/csv/ before " *
            "regenerating docs/literate/pisp_outputs_validation.jl",
        )
    end

    Literate.markdown(
        source_path,
        GENERATED_DIR;
        flavor = Literate.DocumenterFlavor(),
        execute = true,
        credit = false,
    )
end
