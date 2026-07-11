# Regenerate committed tutorial Markdown under docs/src/generated/.
#
# Run this script explicitly when a Literate source changes.
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

const PUBLISHED_LITERATE_SOURCES = [
    "problem_table.jl",
    "eda_06_pisp_outputs.jl",
]

const EDA_DRAFT_LITERATE_SOURCES = [
    "eda_01_data_loading.jl",
    "eda_02_plot_4006_traces.jl",
    "eda_03_year_comparison.jl",
    "eda_04_seasonal_extremes.jl",
    "eda_05_temperature_analysis.jl",
    "eda_07_demand_heat_events.jl",
    "eda_08_4006_composite_map.jl",
    "eda_09_download_inventory.jl",
]

const EDA_SOURCE_TO_SCRIPT_STEM = Dict(
    "eda_01_data_loading.jl" => "01_data_loading",
    "eda_02_plot_4006_traces.jl" => "02_plot_4006_traces",
    "eda_03_year_comparison.jl" => "03_year_comparison",
    "eda_04_seasonal_extremes.jl" => "04_seasonal_extremes",
    "eda_05_temperature_analysis.jl" => "05_temperature_analysis",
    "eda_07_demand_heat_events.jl" => "07_demand_heat_events",
    "eda_08_4006_composite_map.jl" => "08_4006_composite_map",
    "eda_09_download_inventory.jl" => "09_download_inventory",
)

const SOURCE_SET = get(ENV, "PISP_LITERATE_SET", "published")
const LITERATE_SOURCES = if SOURCE_SET == "published"
    PUBLISHED_LITERATE_SOURCES
elseif SOURCE_SET == "eda-drafts"
    EDA_DRAFT_LITERATE_SOURCES
else
    error(
        "unsupported PISP_LITERATE_SET=\"$SOURCE_SET\"; " *
        "use \"published\" or \"eda-drafts\"",
    )
end

function validate_source_preconditions(source_name)
    if source_name == "eda_06_pisp_outputs.jl" && !isdir(PISP_DATA_ROOT)
        error(
            "expected local PISP output data at \"$PISP_DATA_ROOT\"; " *
            "build data/pisp-datasets/out-ref4006-poe10/csv/ before " *
            "regenerating docs/literate/eda_06_pisp_outputs.jl",
        )
    end

    if haskey(EDA_SOURCE_TO_SCRIPT_STEM, source_name)
        script_stem = EDA_SOURCE_TO_SCRIPT_STEM[source_name]
        evidence_dir = joinpath(REPO_ROOT, "eda", "tables", "julia", script_stem)
        if !isdir(evidence_dir)
            error(
                "expected EDA evidence at \"$evidence_dir\"; " *
                "run julia --project=. eda/$script_stem.jl from the repository root " *
                "before rendering $source_name",
            )
        end
    end
end

for source_name in LITERATE_SOURCES
    validate_source_preconditions(source_name)
    source_path = joinpath(LITERATE_DIR, source_name)

    Literate.markdown(
        source_path,
        GENERATED_DIR;
        flavor = Literate.DocumenterFlavor(),
        execute = true,
        credit = false,
    )
end
