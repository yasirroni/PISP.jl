# # REZ resource potential versus connection cost
#
# This analysis asks whether Renewable Energy Zones (REZs) with larger workbook-derived resource potential also have higher expected connection cost, or whether resource potential and connection cost are effectively separate dimensions.
#
# The evidence comes from the AEMO 2024 ISP Inputs and Assumptions workbook at `data/pisp-downloads/2024-isp-inputs-and-assumptions-workbook.xlsx`.
# The workbook sheets named most naturally for the question are not directly joinable: `Renewable Energy Zones` identifies REZ geography without numeric resource limits, while `REZ Costs forecast` gives named cost trajectories without REZ-level capacity figures.
# The evidence therefore uses `Build limits` for `total_resource_limit_mw` and `REZ Augmentations Options` for the primary option's `expected_cost_million`, joined by REZ identifier and name.
#
# No AEMO report-PDF page citation is currently verified for this specific workbook-derived join, so this page cites only the local workbook-derived evidence.

using CSV
using DataFrames
using Printf

const EDA11_EVIDENCE_DIR = joinpath(
    normpath(get(ENV, "PISP_DOCS_REPO_ROOT", joinpath(@__DIR__, "..", ".."))),
    "eda", "tables", "julia", "11_rez_resource_vs_cost",
)

function read_eda11(table_name)
    path = joinpath(EDA11_EVIDENCE_DIR, "$(table_name).csv")
    isfile(path) || error("missing EDA evidence table: $path")
    return CSV.read(path, DataFrame)
end

function rounded_columns(frame, columns; digits = 3)
    copy_frame = copy(frame)
    for column in columns
        copy_frame[!, column] = round.(copy_frame[!, column]; digits = digits)
    end
    return copy_frame
end

# ## Evidence tables loaded from the EDA producer
#
# The producer writes the workbook-derived join and a compact correlation summary.
# The summary records the method, the exact source columns, the joined-row count, the zero-resource exclusion count, and the usable row count used for the coefficient.

correlation_summary = read_eda11("rez_resource_cost_correlation_summary")
correlation_summary

# The joined evidence still contains the zero-resource REZ before ratio and correlation exclusions, making the exclusion visible instead of silently dropping the row.

joined_rez = read_eda11("rez_resource_vs_cost")
first(joined_rez, 8)

zero_resource_rez = read_eda11("rez_zero_resource_limit_excluded")
zero_resource_rez[:, [:rez_id, :rez_name, :total_resource_limit_mw, :expected_cost_million]]

# The cost-efficiency ranking excludes zero-resource rows because expected cost divided by zero resource potential is not a meaningful finite ratio.

ranking = read_eda11("rez_cost_efficiency_ranking");

# Lowest cost per MW of workbook-derived resource potential:

first(rounded_columns(ranking, [:cost_per_resource_mw]; digits = 4), 6)

# Highest cost per MW of workbook-derived resource potential:

last(rounded_columns(ranking, [:cost_per_resource_mw]; digits = 4), 6)

# ## Interpreting the evidence

coefficient = only(correlation_summary.coefficient)
usable_rows = only(correlation_summary.usable_row_count)
joined_rows = only(correlation_summary.joined_row_count)
zero_exclusions = only(correlation_summary.zero_resource_exclusion_count)
most_cost_efficient = first(ranking)
least_cost_efficient = last(ranking)
largest_expected_cost = ranking[argmax(ranking.expected_cost_million), :]

@printf(
    "Pearson coefficient %.3f from %d usable rows (%d joined rows, %d zero-resource exclusion).\n",
    coefficient,
    usable_rows,
    joined_rows,
    zero_exclusions,
)
@printf(
    "Largest expected cost: %s (%s), \$%.0fM.\n",
    largest_expected_cost.rez_id,
    largest_expected_cost.rez_name,
    largest_expected_cost.expected_cost_million,
)
@printf(
    "Most cost-efficient: %s (%s), %.4f \$M per MW of resource.\n",
    most_cost_efficient.rez_id,
    most_cost_efficient.rez_name,
    most_cost_efficient.cost_per_resource_mw,
)
@printf(
    "Least cost-efficient: %s (%s), %.4f \$M per MW of resource.\n",
    least_cost_efficient.rez_id,
    least_cost_efficient.rez_name,
    least_cost_efficient.cost_per_resource_mw,
)

# A Pearson coefficient of 0.016 across 22 usable REZ rows is effectively zero for this workbook-derived join: the REZs with the highest resource potential do not also tend to have the highest primary-option expected connection cost.
# The join contains 23 rows before ratio/correlation filtering, and N12 (Illawarra) is the single excluded zero-resource row; it remains visible in the evidence because its `0 MW` resource limit is part of the workbook-derived data and makes a finite cost-per-resource ratio undefined.
# N4 (Broken Hill) has the largest expected cost at \$5,098M, while T4 (North Tasmania Coast) is the most cost-efficient joined REZ at about \$0.0051M per MW of resource.
# N8 (Cooma-Monaro) is the least cost-efficient joined REZ at \$1.0100M per MW of resource.
#
# The main limitation is source structure: this is not a direct join between `Renewable Energy Zones` and `REZ Costs forecast`, because those sheets do not contain the numeric fields needed for the question.
# The result should therefore be interpreted as a workbook-derived comparison between REZ resource limits and first-listed standalone augmentation-option cost, not as a complete cost-benefit assessment of every possible augmentation pathway.
