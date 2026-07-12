#!/usr/bin/env julia

using CSV
using DataFrames
using XLSX
using Printf
using Statistics

const SCRIPT_STEM = "10_build_cost_trajectories"
const DOWNLOADS = joinpath("data", "pisp-downloads")
const IASR_WORKBOOK = joinpath(DOWNLOADS, "2024-isp-inputs-and-assumptions-workbook.xlsx")
const TABLE_ROOT = joinpath(@__DIR__, "tables")
const SHEET_NAME = "Build costs"

# Question (final question 1 of tasks/done/0076-isp-2024-raw-data-eda-questions.md):
# in the IASR "Build costs" sheet, how do projected capital costs for the main
# VRE and storage technologies (utility-scale solar, onshore/offshore wind,
# battery storage) evolve across the projection years, and does the
# annualized rate of cost decline differ materially by technology?
#
# EDA insight (from the executed `build_cost_decline_summary` table, 2022-23
# to 2053-54, all 6 GenCost/ISP scenario columns): every matched technology's
# build cost falls in every scenario, but the annualized decline rate spans
# roughly a 5.5x range across technologies and scenarios — from -0.78%/yr
# (Wind - offshore (fixed), GenCost Current Policies / Progressive Change) to
# -4.30%/yr (Battery storage 8hrs storage, GenCost Global NZE by 2050 / Green
# Energy Exports). The fastest-declining technology is itself
# scenario-dependent, not fixed: in the two lower-decarbonization scenarios
# (GenCost Current Policies, Progressive Change), Large scale Solar PV
# declines fastest (-2.72%/yr), ahead of every battery duration, with Wind -
# offshore (fixed) slowest (-0.78%/yr); in the four higher-decarbonization
# scenarios (Global NZE post 2050, Global NZE by 2050, Green Energy Exports,
# Step Change), the longer-duration battery storage technologies decline
# fastest instead (8hrs storage fastest of all at -4.30%/yr and -3.34%/yr),
# with onshore Wind alone slowest in all four (-1.54%/yr in Global NZE by
# 2050/Green Energy Exports, -1.26%/yr in Global NZE post 2050/Step Change) —
# Wind - offshore (fixed) declines faster than onshore Wind in every one of
# these four scenarios and is only ever the slowest in the two
# lower-decarbonization scenarios above. So yes, the rate of cost decline
# differs materially by technology, but which technology declines fastest
# (and slowest) is a function of the decarbonization scenario assumed, not a
# single fixed ranking.

function table_dir(script_stem; producer = "julia", root = TABLE_ROOT)
    path = joinpath(root, producer, script_stem)
    mkpath(path)
    return path
end

function table_path(script_stem, table_name; producer = "julia", root = TABLE_ROOT)
    filename = endswith(table_name, ".csv") ? table_name : "$(table_name).csv"
    return joinpath(table_dir(script_stem; producer = producer, root = root), filename)
end

function write_table(frame::DataFrame, script_stem, table_name; producer = "julia", root = TABLE_ROOT)
    path = table_path(script_stem, table_name; producer = producer, root = root)
    CSV.write(path, frame; missingstring = "")
    println("Saved table: ", path)
    return path
end

# Trim a raw XLSX matrix down to the bounding box of non-missing cells,
# reused from eda/05_temperature_analysis.jl: this workbook's declared sheet
# dimension carries trailing all-missing rows/columns beyond its real
# content (confirmed here too: "Build costs" reports max_row 1191 but its
# last populated row is 223).
function trim_sheet(matrix)
    nrows, ncols = size(matrix)
    last_row = 0
    for r in 1:nrows
        if any(x -> x !== missing, view(matrix, r, :))
            last_row = r
        end
    end
    last_col = 0
    for c in 1:ncols
        if any(x -> x !== missing, view(matrix, :, c))
            last_col = c
        end
    end
    (last_row == 0 || last_col == 0) && return Matrix{Any}(undef, 0, 0)
    return matrix[1:last_row, 1:last_col]
end

# The sheet keyword-matches "utility-scale solar" to Large scale Solar PV
# only (not Solar Thermal, a distinct CSP technology), "onshore/offshore
# wind" to all 3 Wind rows, and "battery storage" to all 4 duration
# variants. Pumped hydro/BOTN rows are excluded here: they are pumped-hydro
# storage, the subject of the separate PHES-vs-battery EDA (0079).
const TARGET_KEYWORDS = ["solar pv", "wind", "battery storage"]

is_target_technology(tech) = any(kw -> occursin(kw, lowercase(tech)), TARGET_KEYWORDS)

# The sheet lays out one "Build cost by technology ($/kW)" master table: a
# header row ("Technology", "Scenario", then one column per financial year),
# followed by 19 technologies x 6 scenarios in 6-row blocks, each block
# preceded by a repeated copy of the same header row and followed by a blank
# separator row. This locates that header by literal content rather than a
# hardcoded row number, since earlier rows on the sheet hold unrelated
# GenCost-scenario-mapping tables with their own, differently-shaped blocks.
function find_master_header_row(matrix)
    nrows = size(matrix, 1)
    for r in 1:nrows
        if isequal(matrix[r, 2], "Technology") && isequal(matrix[r, 3], "Scenario")
            return r
        end
    end
    error("Could not locate the \"Build cost by technology\" master header row in sheet \"$SHEET_NAME\"")
end

function year_columns(matrix, header_row)
    ncols = size(matrix, 2)
    years = String[]
    col_indices = Int[]
    for c in 4:ncols
        label = matrix[header_row, c]
        label === missing && continue
        push!(years, string(label))
        push!(col_indices, c)
    end
    return years, col_indices
end

function build_cost_long_table(matrix, header_row, years, col_indices)
    rows = NamedTuple[]
    nrows = size(matrix, 1)
    for r in (header_row + 1):nrows
        tech = matrix[r, 2]
        scenario = matrix[r, 3]
        (tech === missing || scenario === missing) && continue
        tech == "Technology" && continue  # repeated mini-header before each block
        for (year, c) in zip(years, col_indices)
            value = matrix[r, c]
            push!(
                rows,
                (
                    technology = String(tech),
                    scenario = String(scenario),
                    year = year,
                    cost_dollar_per_kw = value === missing ? missing : Float64(value),
                ),
            )
        end
    end
    return DataFrame(rows)
end

# Per (technology, scenario): first/last available projection year and cost,
# the annualized (CAGR-style) decline rate between them, and the total
# percentage change — directly answers "does the rate of decline differ
# materially by technology."
function decline_summary(long_table)
    rows = NamedTuple[]
    for key_df in groupby(long_table, [:technology, :scenario])
        complete = filter(:cost_dollar_per_kw => !ismissing, key_df)
        nrow(complete) < 2 && continue
        complete = sort(complete, :year)  # "YYYY-YY" financial-year labels sort correctly as strings
        first_row = first(complete)
        last_row = last(complete)
        n_years = nrow(complete) - 1
        first_cost = first_row.cost_dollar_per_kw
        last_cost = last_row.cost_dollar_per_kw
        cagr_pct = first_cost > 0 ? ((last_cost / first_cost)^(1 / n_years) - 1) * 100 : missing
        total_pct_change = first_cost > 0 ? (last_cost - first_cost) / first_cost * 100 : missing
        push!(
            rows,
            (
                technology = first_row.technology,
                scenario = first_row.scenario,
                first_year = first_row.year,
                last_year = last_row.year,
                first_cost_dollar_per_kw = first_cost,
                last_cost_dollar_per_kw = last_cost,
                annualized_decline_rate_pct = cagr_pct,
                total_pct_change_pct = total_pct_change,
            ),
        )
    end
    return DataFrame(rows)
end

function main()
    println("Workbook exists: ", isfile(IASR_WORKBOOK))
    isfile(IASR_WORKBOOK) || error("IASR workbook not found at $IASR_WORKBOOK")

    matrix = XLSX.openxlsx(IASR_WORKBOOK) do xf
        trim_sheet(xf[SHEET_NAME][:])
    end
    println("Trimmed \"$SHEET_NAME\" sheet shape: ", size(matrix))

    header_row = find_master_header_row(matrix)
    years, col_indices = year_columns(matrix, header_row)
    println("Master table header at row $header_row, ", length(years), " projection years: ", first(years), " .. ", last(years))

    long_table = build_cost_long_table(matrix, header_row, years, col_indices)
    all_technologies = unique(long_table.technology)
    println("Technologies found (", length(all_technologies), "): ", join(all_technologies, ", "))

    matched_technologies = filter(is_target_technology, all_technologies)
    println("Target (solar/wind/battery) technologies matched (", length(matched_technologies), "): ", join(matched_technologies, ", "))

    technology_match_df = DataFrame(
        technology = all_technologies,
        is_target_technology = [is_target_technology(t) ? 1 : 0 for t in all_technologies],
    )
    write_table(technology_match_df, SCRIPT_STEM, "technology_match")

    target_long = filter(:technology => is_target_technology, long_table)
    write_table(target_long, SCRIPT_STEM, "build_cost_trajectory")

    decline = decline_summary(target_long)
    decline = sort(decline, :annualized_decline_rate_pct)
    write_table(decline, SCRIPT_STEM, "build_cost_decline_summary")

    println("\n=== Decline summary (target technologies, all scenarios) ===")
    for row in eachrow(decline)
        @printf(
            "%-32s %-28s %s->%s: %.1f -> %.1f \$/kW (%.2f%% total, %.2f%%/yr annualized)\n",
            row.technology,
            row.scenario,
            row.first_year,
            row.last_year,
            row.first_cost_dollar_per_kw,
            row.last_cost_dollar_per_kw,
            row.total_pct_change_pct,
            row.annualized_decline_rate_pct,
        )
    end

    return technology_match_df, target_long, decline
end

main()
