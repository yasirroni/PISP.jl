# # Understanding reference trace 4006 profiles
#
# Reference trace `4006` combines location-specific solar and wind profiles with a planning-horizon weather-year mapping.
# This page organises the evidence produced by `eda/02_plot_4006_traces.jl` around three questions: which representative locations were loaded, how daily capacity factors vary, and how diurnal or monthly structure should be interpreted.
#
# Reference trace `4006` is not a climate projection.
# Its planning-year behaviour depends on the historical-year composition documented in [Parameters and mappings](@ref).

using CSV
using DataFrames

const EDA02_EVIDENCE_DIR = joinpath(
    @__DIR__, "..", "..", "..", "eda", "tables", "julia", "02_plot_4006_traces",
)

function read_eda02(table_name)
    path = joinpath(EDA02_EVIDENCE_DIR, "$(table_name).csv")
    isfile(path) || error("missing EDA evidence table: $path")
    return CSV.read(path, DataFrame)
end

preview_eda02(table; rows = 12) = first(table, min(rows, nrow(table)))

# ## Representative locations
#
# The loaded-location inventory makes the spatial sample explicit before any state-level comparison is made.

loaded_locations = read_eda02("loaded_locations")
loaded_locations

# ## Daily capacity-factor distribution
#
# The daily summary provides comparable descriptive statistics for the selected solar and wind locations.
# Any final prose should identify the aggregation rule and avoid treating one site as a complete state-wide resource model.

daily_cf_summary = read_eda02("daily_cf_summary")
daily_cf_summary

# ## Solar diurnal structure
#
# The solar profile summarises half-hourly behaviour at the selected Victorian location.
# Percentile bands should be interpreted as variation within the trace, not as forecast uncertainty unless the underlying construction supports that interpretation.

solar_diurnal_profile = read_eda02("solar_diurnal_profile")
preview_eda02(solar_diurnal_profile; rows = 16)

# ## Wind monthly and diurnal structure
#
# Wind is represented by both a monthly diurnal profile and a monthly mean series.
# These tables support different questions and should not be collapsed into one statistic.

wind_monthly_diurnal_profile = read_eda02("wind_monthly_diurnal_profile")
preview_eda02(wind_monthly_diurnal_profile; rows = 16)

wind_monthly_mean_cf = read_eda02("wind_monthly_mean_cf")
preview_eda02(wind_monthly_mean_cf; rows = 12)

# ## Financial-year aggregation
#
# The financial-year table links the profile statistics to the July-June convention used by the build pipeline.

annual_cf_by_fy = read_eda02("annual_cf_by_fy")
annual_cf_by_fy

# ## Interpretation after execution
#
# Replace this section after rendering the complete tables and any figures added during revision.
# The final interpretation should identify the dominant diurnal and seasonal patterns, state the limitations of the representative-site selection, and explain how the financial-year convention affects comparison with calendar-year summaries.
