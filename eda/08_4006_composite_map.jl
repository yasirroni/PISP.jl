#!/usr/bin/env julia

using CSV
using DataFrames
using Dates
using Printf
using Statistics
using Plots

const SCRIPT_STEM = "08_4006_composite_map"
const TRACES = joinpath("data", "2024", "pisp-downloads", "Traces")
const TABLE_ROOT = joinpath(@__DIR__, "tables")
const FIGURE_ROOT = joinpath(@__DIR__, "figures")

gr()

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

function figure_dir(script_stem; producer = "julia", root = FIGURE_ROOT)
    path = joinpath(root, producer, script_stem)
    mkpath(path)
    return path
end

function figure_path(script_stem, figure_name; producer = "julia", root = FIGURE_ROOT)
    filename = endswith(figure_name, ".png") ? figure_name : "$(figure_name).png"
    return joinpath(figure_dir(script_stem; producer = producer, root = root), filename)
end

const HH_COLS_SOL = string.(1:48)
const HH_COLS_WIND = [lpad(i, 2, '0') for i in 1:48]

const SOLAR_LOC = "Bannerton_SAT"
const WIND_LOC = "DUNDWF1"

const NEAR_YEARS = [2025, 2026, 2027, 2028, 2029]
const FAR_YEARS = [2045, 2046, 2047, 2048, 2049]

# The hardcoded DATE_RANGES_REFYEARS mapping from PISP.jl
const DATE_RANGES_REFYEARS = [
    ("2024-07-01", "2025-06-30", 2019),
    ("2025-07-01", "2026-06-30", 2020),
    ("2026-07-01", "2027-06-30", 2021),
    ("2027-07-01", "2028-06-30", 2022),
    ("2028-07-01", "2029-06-30", 2023),
    ("2029-07-01", "2030-06-30", 2015),
    ("2030-07-01", "2031-06-30", 2011),
    ("2031-07-01", "2032-06-30", 2012),
    ("2032-07-01", "2033-06-30", 2013),
    ("2033-07-01", "2034-06-30", 2014),
    ("2034-07-01", "2035-06-30", 2015),
    ("2035-07-01", "2036-06-30", 2016),
    ("2036-07-01", "2037-06-30", 2017),
    ("2037-07-01", "2038-06-30", 2018),
    ("2038-07-01", "2039-06-30", 2019),
    ("2039-07-01", "2040-06-30", 2020),
    ("2040-07-01", "2041-06-30", 2021),
    ("2041-07-01", "2042-06-30", 2022),
    ("2042-07-01", "2043-06-30", 2023),
    ("2043-07-01", "2044-06-30", 2015),
    ("2044-07-01", "2045-06-30", 2011),
    ("2045-07-01", "2046-06-30", 2012),
    ("2046-07-01", "2047-06-30", 2013),
    ("2047-07-01", "2048-06-30", 2014),
    ("2048-07-01", "2049-06-30", 2015),
    ("2049-07-01", "2050-06-30", 2016),
    ("2050-07-01", "2051-06-30", 2017),
    ("2051-07-01", "2052-06-30", 2018),
]

function build_mapping_table()
    fy_start = [t[1] for t in DATE_RANGES_REFYEARS]
    fy_end = [t[2] for t in DATE_RANGES_REFYEARS]
    ref_year = [t[3] for t in DATE_RANGES_REFYEARS]
    fy_label = ["FY$(e[1:4])" for e in fy_end]
    ref_label = string.(ref_year)
    return DataFrame(
        fy_start = fy_start,
        fy_end = fy_end,
        ref_year = ref_year,
        fy_label = fy_label,
        ref_label = ref_label,
    )
end

read_trace(path) = CSV.read(path, DataFrame)

trace_path(tech, yr, loc) = joinpath(TRACES, "$(tech)_$(yr)", "$(loc)_RefYear$(yr).csv")

daily_cf(df::DataFrame, hh_cols) = [mean(row[col] for col in hh_cols) for row in eachrow(df)]

# Mirrors `mapping_df[mapping_df['fy_end'].str.startswith(str(yr))]['ref_year'].values[0]`:
# `yr` is a financial-year-END year (e.g. 2025, 2045), not a historical/ref year, and must
# be translated through the mapping table before loading a trace file.
function ref_year_for_fy_end(yr::Int)
    idx = findfirst(t -> startswith(t[2], string(yr)), DATE_RANGES_REFYEARS)
    idx === nothing && return nothing
    return DATE_RANGES_REFYEARS[idx][3]
end

function load_year_cf(years, tech, loc, hh_cols)
    all_cfs = Vector{Float64}[]
    for yr in years
        ref = ref_year_for_fy_end(yr)
        ref === nothing && continue
        path = trace_path(tech, ref, loc)
        isfile(path) || continue
        push!(all_cfs, daily_cf(read_trace(path), hh_cols))
    end
    isempty(all_cfs) && return nothing
    n = length(all_cfs[1])
    return [mean(cfs[i] for cfs in all_cfs) for i in 1:n]
end

function write_historical_year_vre_stats_table(mapping::DataFrame)
    rows = NamedTuple[]
    for yr in sort(unique(mapping.ref_year))
        for (tech, loc, hh_cols) in (("solar", SOLAR_LOC, HH_COLS_SOL), ("wind", WIND_LOC, HH_COLS_WIND))
            path = trace_path(tech, yr, loc)
            isfile(path) || continue
            df = read_trace(path)
            summer = df[in.(df.Month, Ref((12, 1, 2))), :]
            nrow(summer) == 0 && continue
            summer_cf = daily_cf(summer, hh_cols)
            push!(
                rows,
                (
                    ref_year = yr,
                    tech = tech,
                    annual_mean_cf = mean(daily_cf(df, hh_cols)),
                    summer_mean_cf = mean(summer_cf),
                    summer_min_cf = minimum(summer_cf),
                    summer_p5_cf = quantile(summer_cf, 0.05),
                ),
            )
        end
    end
    write_table(DataFrame(rows), SCRIPT_STEM, "historical_year_vre_stats")
end

function write_near_vs_far_term_table()
    rows = NamedTuple[]
    for (tech, loc, hh_cols) in (("solar", SOLAR_LOC, HH_COLS_SOL), ("wind", WIND_LOC, HH_COLS_WIND))
        near_cf = load_year_cf(NEAR_YEARS, tech, loc, hh_cols)
        far_cf = load_year_cf(FAR_YEARS, tech, loc, hh_cols)
        if near_cf !== nothing
            for (day, cf) in enumerate(near_cf)
                push!(rows, (tech = tech, term = "near", day_of_year = day, daily_cf = cf))
            end
        end
        if far_cf !== nothing
            for (day, cf) in enumerate(far_cf)
                push!(rows, (tech = tech, term = "far", day_of_year = day, daily_cf = cf))
            end
        end
    end
    write_table(DataFrame(rows), SCRIPT_STEM, "near_vs_far_term_daily_cf")
end

function write_vre_heatmap_table(mapping::DataFrame)
    years_unique = sort(unique(mapping.ref_year))
    rows = NamedTuple[]
    for (tech, loc, hh_cols) in (("solar", SOLAR_LOC, HH_COLS_SOL), ("wind", WIND_LOC, HH_COLS_WIND))
        for yr in years_unique
            path = trace_path(tech, yr, loc)
            val = isfile(path) ? mean(daily_cf(read_trace(path), hh_cols)) : missing
            push!(rows, (tech = tech, ref_year = yr, annual_mean_cf = val))
        end
    end
    write_table(DataFrame(rows), SCRIPT_STEM, "vre_heatmap")
end

function write_ref_year_counts_table(mapping::DataFrame)
    counts = combine(groupby(mapping, :ref_year), nrow => :count)
    sort!(counts, :ref_year)
    write_table(counts, SCRIPT_STEM, "ref_year_counts")
end

function main()
    mapping = build_mapping_table()
    write_table(mapping, SCRIPT_STEM, "mapping_table")

    println("=== 4006 Composite Mapping ===")
    for row in eachrow(mapping)
        println("  ", row.fy_start[1:4], " → ref ", row.ref_year)
    end

    write_historical_year_vre_stats_table(mapping)
    write_near_vs_far_term_table()
    write_vre_heatmap_table(mapping)

    println("\n=== 4006 COMPOSITE STATS ===")
    println("Total years: ", nrow(mapping))
    println("Unique historical years used: ", sort(unique(mapping.ref_year)))
    write_ref_year_counts_table(mapping)

    # ====== Figure 1: Timeline of historical years in 4006 ======
    unique_years = sort(unique(mapping.ref_year))
    color_map = Dict(yr => palette(:tab20)[i % 20 + 1] for (i, yr) in enumerate(unique_years))

    # Create the timeline plot using a bar chart
    p1 = plot(xlim=(0, nrow(mapping)), ylim=(0.5, 1.5), legend=:none, title="4006 Reference Trace — Historical Year Mapping\n(Each bar = one financial year, color = source historical year)",
             xlabel="Financial Year", ylabel="", yticks=([1], ["4006 Trace"]), size=(1400, 400), grid=false)

    for (idx, row) in enumerate(eachrow(mapping))
        color = color_map[row.ref_year]
        bar!(p1, [idx], [1.0], color=color, alpha=0.8, legend=false, width=1)
        # Add text label for the reference year
        if idx % 2 == 1
            annotate!(p1, idx, 1.1, text("$(row.ref_year)", 7, :center))
        end
    end

    savefig(p1, figure_path(SCRIPT_STEM, "08_4006_timeline_map.png"))
    println("Saved: 08_4006_timeline_map.png")

    # ====== Figure 2: VRE CF by historical year ======
    write_historical_year_vre_stats_table(mapping)
    stats = CSV.read(table_path(SCRIPT_STEM, "historical_year_vre_stats"), DataFrame)

    p2 = plot(layout=(1,2), size=(1000, 500))

    for (idx, tech) in enumerate(("solar", "wind"))
        tech_df = filter(row -> row.tech == tech, stats)
        sort!(tech_df, :ref_year)
        colors = [color_map[yr] for yr in tech_df.ref_year]

        years_labels = string.(tech_df.ref_year)
        for (i, (year, cf, p5_cf)) in enumerate(zip(tech_df.ref_year, tech_df.summer_mean_cf, tech_df.summer_p5_cf))
            bar!(p2[idx], [i], [cf], color=colors[i], alpha=0.8, legend=false, width=0.8)
        end

        # Error caps
        errors = tech_df.summer_mean_cf .- tech_df.summer_p5_cf
        scatter!(p2[idx], 1:nrow(tech_df), tech_df.summer_mean_cf, color=:black, markersize=3, label="")

        plot!(p2[idx], title="$(uppercase(tech)) $(SOLAR_LOC) — Summer CF by Historical Year",
              xlabel="Historical Year", ylabel="Summer Daily Mean CF", xticks=(1:nrow(tech_df), years_labels),
              ylim=(0, 0.5), grid=true, gridalpha=0.3)
    end

    savefig(p2, figure_path(SCRIPT_STEM, "08_vre_by_historical_year.png"))
    println("Saved: 08_vre_by_historical_year.png")

    # ====== Figure 3: Near-term vs far-term daily CF ======
    write_near_vs_far_term_table()

    p3 = plot(layout=(2,1), size=(1200, 800))

    for (idx, (tech, loc, hh_cols, color)) in enumerate([("solar", SOLAR_LOC, HH_COLS_SOL, :orange), ("wind", WIND_LOC, HH_COLS_WIND, :steelblue)])
        near_cf = load_year_cf(NEAR_YEARS, tech, loc, hh_cols)
        far_cf = load_year_cf(FAR_YEARS, tech, loc, hh_cols)

        ax_idx = idx

        if near_cf !== nothing
            plot!(p3[ax_idx], near_cf, color=color, linewidth=0.5, alpha=0.5, label="Near-term 2025-2029")
            near_rolling = [i < 30 ? NaN : mean(near_cf[max(1,i-29):i]) for i in 1:length(near_cf)]
            plot!(p3[ax_idx], near_rolling, color=color, linewidth=2, label="Near-term 30d avg")
        end

        if far_cf !== nothing
            plot!(p3[ax_idx], far_cf, color=:grey, linewidth=0.5, alpha=0.5, label="Far-term 2045-2049")
            far_rolling = [i < 30 ? NaN : mean(far_cf[max(1,i-29):i]) for i in 1:length(far_cf)]
            plot!(p3[ax_idx], far_rolling, color=:black, linewidth=2, linestyle=:dash, label="Far-term 30d avg")
        end

        plot!(p3[ax_idx], title="$(uppercase(tech)) $(loc) — Near-term vs Far-term Daily CF",
              xlabel="Day of Year", ylabel="Daily Mean CF", ylim=(0, 0.6), legend=:topright, grid=true, gridalpha=0.3)
    end

    savefig(p3, figure_path(SCRIPT_STEM, "08_near_vs_far_term.png"))
    println("Saved: 08_near_vs_far_term.png")

    # ====== Figure 4: Year-by-year CF heatmap ======
    write_vre_heatmap_table(mapping)
    heatmap_df = CSV.read(table_path(SCRIPT_STEM, "vre_heatmap"), DataFrame)

    years_unique = sort(unique(heatmap_df.ref_year))
    solar_data = filter(row -> row.tech == "solar", heatmap_df)
    wind_data = filter(row -> row.tech == "wind", heatmap_df)

    sort!(solar_data, :ref_year)
    sort!(wind_data, :ref_year)

    solar_vals = solar_data.annual_mean_cf
    wind_vals = wind_data.annual_mean_cf

    heatmap_matrix = [solar_vals'; wind_vals']

    p4 = heatmap(years_unique, ["Solar", "Wind"], heatmap_matrix, c=:YlOrRd,
                title="Annual Mean CF by Historical Year and Technology",
                xlabel="Historical Year", ylabel="", size=(1200, 400), clim=(0, 0.35),
                colorbar_title="Annual Mean CF")

    # Annotate cells
    for (i, tech) in enumerate(["Solar", "Wind"])
        for (j, yr) in enumerate(years_unique)
            val = heatmap_matrix[i, j]
            if !ismissing(val) && !isnan(val)
                text_color = val > 0.25 ? :black : :white
                annotate!(p4, j - 1, i - 1, text(@sprintf("%.3f", val), 7, text_color), legend=false)
            end
        end
    end

    savefig(p4, figure_path(SCRIPT_STEM, "08_vre_heatmap.png"))
    println("Saved: 08_vre_heatmap.png")

    println("\nDone.")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
