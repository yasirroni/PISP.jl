# # Inspecting the trace input contract
#
# Before interpreting demand, solar, or wind traces, a reader needs to know whether the expected files are present, whether their schemas are compatible, which dates they cover, and whether their values occupy plausible ranges.
# This page turns the evidence produced by `eda/01_data_loading.jl` into a source-level data check.
#
# The page intentionally does not claim that the traces are valid for modelling.
# It establishes the observable file and schema contract that later EDA pages depend on.

using CSV
using DataFrames

const EDA01_EVIDENCE_DIR = joinpath(
    @__DIR__, "..", "..", "..", "eda", "tables", "julia", "01_data_loading",
)

function read_eda01(table_name)
    path = joinpath(EDA01_EVIDENCE_DIR, "$(table_name).csv")
    isfile(path) || error("missing EDA evidence table: $path")
    return CSV.read(path, DataFrame)
end


# ## Which reference-year files are available?
#
# The availability check samples the historical solar trace folders used by later analyses.
# Missing years should be resolved before interpreting interannual comparisons.

available_year_checks = read_eda01("available_year_checks")
available_year_checks

# ## Do the sample traces share a usable schema?
#
# Shape and column evidence identifies whether solar and wind traces expose the expected date fields and half-hourly value columns.

trace_shape_columns = read_eda01("trace_shape_columns")
trace_shape_columns

# Date coverage is a separate check because a file can have the expected columns while covering an unexpected period.

trace_date_ranges = read_eda01("trace_date_ranges")
trace_date_ranges

# ## Are the trace values within an interpretable range?
#
# The minimum and maximum values provide a first screening check for capacity-factor-like traces.
# This is not a substitute for source validation or a technology-specific physical plausibility review.

trace_value_ranges = read_eda01("trace_value_ranges")
trace_value_ranges

# The solar low-output summary records the threshold and column window used by the EDA rather than presenting the resulting count without context.

solar_midday_low_days = read_eda01("solar_midday_low_days")
solar_midday_low_days

# ## What does one demand trace look like?
#
# Demand traces use a different file family and schema from solar and wind traces.
# The metadata table records the file count, sample shape, and value-column span needed by downstream parsers.

demand_sample_metadata = read_eda01("demand_sample_metadata")
demand_sample_metadata

# ## Interpretation after execution
#
# Replace this section after inspecting the rendered evidence.
# The final interpretation should state which files and years are present, whether date and value columns are consistent across the sampled trace families, and which missing or anomalous inputs would block later EDA.
# It should distinguish an observed schema property from a judgement that the data are physically or historically valid.
