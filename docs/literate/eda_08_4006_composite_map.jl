# # Interpreting the reference trace 4006 composite map
#
# Reference trace `4006` assigns historical weather years to successive financial years in the planning horizon.
# Understanding that map is necessary before comparing near-term and far-term renewable profiles because a change in planning year can also change the historical trace being reused.
#
# This page uses the evidence from `eda/08_4006_composite_map.jl` to expose the mapping, its repeated historical years, and the renewable statistics associated with those years.

using CSV
using DataFrames

const EDA08_EVIDENCE_DIR = joinpath(
    @__DIR__, "..", "..", "..", "eda", "tables", "julia", "08_4006_composite_map",
)

function read_eda08(table_name)
    path = joinpath(EDA08_EVIDENCE_DIR, "$(table_name).csv")
    isfile(path) || error("missing EDA evidence table: $path")
    return CSV.read(path, DataFrame)
end

preview_eda08(table; rows = 16) = first(table, min(rows, nrow(table)))

# ## Financial-year to historical-year mapping
#
# The mapping table is the primary evidence for interpreting the composite trace.
# It should remain visible next to any planning-horizon comparison.

mapping_table = read_eda08("mapping_table")
mapping_table

# ## How often is each historical year reused?
#
# Repeated reference years mean that the planning horizon does not represent a monotonic sequence of new weather conditions.

ref_year_counts = read_eda08("ref_year_counts")
ref_year_counts

# ## Renewable statistics by historical year
#
# The historical-year summary records annual and summer statistics for the selected solar and wind locations.
# These values describe the reused source traces, not an endogenous change in renewable technology or climate over the planning horizon.

historical_year_vre_stats = read_eda08("historical_year_vre_stats")
historical_year_vre_stats

# ## Near-term and far-term profile comparison
#
# The near and far groups average profiles selected through the mapping.
# Any difference can arise from the composition of historical years in each group and should not be labelled a trend without a separate trend model.

near_vs_far_term_daily_cf = read_eda08("near_vs_far_term_daily_cf")
preview_eda08(near_vs_far_term_daily_cf; rows = 20)

# ## Historical-year renewable matrix
#
# The heatmap evidence provides a compact comparison across the unique historical years used by the composite.

vre_heatmap = read_eda08("vre_heatmap")
vre_heatmap

# ## Interpretation after execution
#
# Replace this section after inspecting the complete mapping and renewable statistics.
# The final interpretation should identify which historical years dominate each planning-period group, separate composition effects from planning-year effects, and avoid interpreting the composite sequence as a climate-change projection.
