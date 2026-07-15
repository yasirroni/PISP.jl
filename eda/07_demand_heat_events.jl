#!/usr/bin/env julia

using CSV
using DataFrames
using Dates
using Printf
using Statistics
using Plots

const SCRIPT_STEM = "07_demand_heat_events"
const TRACES = joinpath("data", "2024", "pisp-downloads", "Traces")
const OUT = joinpath("data", "2024", "pisp-datasets", "out-ref4006-poe10", "csv")
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

function daily_cf(df::DataFrame, half_hour_cols)
    return [mean(Float64(row[col]) for col in half_hour_cols) for row in eachrow(df)]
end

function load_solar_4006(loc)
    file = joinpath(TRACES, "solar_4006", "$(loc)_RefYear4006.csv")
    isfile(file) || return nothing
    df = CSV.read(file, DataFrame)
    df.datetime = Date.(df.Year, df.Month, df.Day)
    return df
end

# Maps each exact calendar date in a composite RefYear4006 trace to its
# half-hourly-mean solar capacity factor for that date.
function solar_cf_by_date(df::DataFrame)
    cfs = daily_cf(df, HH_COLS_SOL)
    return Dict(zip(df.datetime, cfs))
end

function main()
    # ---- Demand trace inventory ----
    dem_dir = joinpath(TRACES, "demand_VIC_Step Change")
    dem_files = sort(filter(name -> endswith(name, "_POE10_OPSO_MODELLING.csv"), readdir(dem_dir)))
    println("Found $(length(dem_files)) demand trace files")
    write_table(DataFrame(file = dem_files), SCRIPT_STEM, "demand_trace_inventory")

    # ---- Load demand schedule from PISP output ----
    dem_load = CSV.read(joinpath(OUT, "schedule-2030", "Demand_load_sched.csv"), DataFrame)
    dem_df = CSV.read(joinpath(OUT, "Demand.csv"), DataFrame)
    bus_df = CSV.read(joinpath(OUT, "Bus.csv"), DataFrame)

    area_map = Dict(row.id_bus => row.id_area for row in eachrow(bus_df))
    bus_of_dem = Dict(row.id_dem => row.id_bus for row in eachrow(dem_df))

    dem_load.area = [area_map[bus_of_dem[d]] for d in dem_load.id_dem]
    dem_load.date_only = Date.(dem_load.date)

    # ---- Aggregate daily demand by area ----
    dem_daily = combine(groupby(dem_load, [:date_only, :area]), :value => mean => :demand_mw)
    rename!(dem_daily, :date_only => :date)
    write_table(dem_daily, SCRIPT_STEM, "demand_by_area_daily")

    # ---- Load solar 4006 for VIC ----
    locations = ["Bannerton_SAT", "Darlington_Point_SAT"]
    sol_4006 = Dict{String, DataFrame}()
    for loc in locations
        df = load_solar_4006(loc)
        df === nothing || (sol_4006[loc] = df)
    end
    println("Loaded $(length(sol_4006)) solar locations for 4006")

    # ---- VIC daily demand ----
    vic_dem = dem_load[dem_load.area .== 3, :]
    vic_daily = combine(groupby(vic_dem, :date_only), :value => mean => :demand)
    sort!(vic_daily, :date_only)

    # ---- VIC demand + solar CF merged summary ----
    merged = DataFrame(date = Date[], demand = Float64[], solar_cf = Float64[])
    if haskey(sol_4006, "Bannerton_SAT")
        cf_of_date = solar_cf_by_date(sol_4006["Bannerton_SAT"])
        for row in eachrow(vic_daily)
            haskey(cf_of_date, row.date_only) || continue
            push!(merged, (date = row.date_only, demand = row.demand, solar_cf = cf_of_date[row.date_only]))
        end
        write_table(merged, SCRIPT_STEM, "vic_demand_solar_merged")

        # ---- High-demand + low-solar day threshold summary ----
        threshold_demand = quantile(merged.demand, 0.9)
        threshold_solar = quantile(merged.solar_cf, 0.1)
        bad_days = merged[(merged.demand .> threshold_demand) .& (merged.solar_cf .< threshold_solar), :]
        @printf("\nHigh-demand + Low-solar days: %d\n", nrow(bad_days))
        @printf("  Threshold: demand > %.0f MW, solar CF < %.3f\n", threshold_demand, threshold_solar)
        write_table(
            DataFrame(
                demand_quantile = 0.9,
                solar_quantile = 0.1,
                threshold_demand_mw = threshold_demand,
                threshold_solar_cf = threshold_solar,
                bad_day_count = nrow(bad_days),
                total_day_count = nrow(merged),
            ),
            SCRIPT_STEM,
            "high_demand_low_solar_summary",
        )
    end

    # ---- Heat event vs normal day thresholds ----
    demand_p90 = quantile(vic_daily.demand, 0.9)
    demand_p95 = quantile(vic_daily.demand, 0.95)

    heat_days = vic_daily[vic_daily.demand .>= demand_p95, :date_only]
    normal_days = Set(vic_daily[vic_daily.demand .< demand_p90, :date_only])
    heat_days_set = Set(heat_days)

    @printf("\nDemand thresholds: P90=%.0f MW, P95=%.0f MW\n", demand_p90, demand_p95)
    println("Heat event days (>P95): ", length(heat_days))
    println("Normal days (<P90): ", length(normal_days))

    # ---- Hourly profile for heat days vs normal days ----
    heat_df = vic_dem[in.(vic_dem.date_only, Ref(heat_days_set)), :]
    normal_df = vic_dem[in.(vic_dem.date_only, Ref(normal_days)), :]
    heat_df = transform(heat_df, :date => ByRow(hour) => :hour)
    normal_df = transform(normal_df, :date => ByRow(hour) => :hour)

    heat_hourly = Dict(row.hour => row.value_mean for row in eachrow(combine(groupby(heat_df, :hour), :value => mean => :value_mean)))
    normal_hourly = Dict(row.hour => row.value_mean for row in eachrow(combine(groupby(normal_df, :hour), :value => mean => :value_mean)))

    write_table(
        DataFrame(
            hour = 0:23,
            heat_mean_demand_mw = [get(heat_hourly, h, missing) for h in 0:23],
            normal_mean_demand_mw = [get(normal_hourly, h, missing) for h in 0:23],
        ),
        SCRIPT_STEM,
        "heat_normal_hourly_profile",
    )

    # ---- Demand duration curve ----
    sorted_demand = sort(vic_daily.demand; rev = true)
    write_table(
        DataFrame(day_rank = 1:length(sorted_demand), demand_mw = sorted_demand),
        SCRIPT_STEM,
        "demand_duration_curve",
    )

    # ---- Normalized VRE vs demand summary (sorted by demand) ----
    if nrow(merged) > 0
        merged_sorted = sort(merged, :demand)
        write_table(
            DataFrame(
                day_rank = 1:nrow(merged_sorted),
                demand_norm = merged_sorted.demand ./ maximum(merged_sorted.demand),
                solar_norm = merged_sorted.solar_cf ./ maximum(merged_sorted.solar_cf),
            ),
            SCRIPT_STEM,
            "normalized_vre_demand_summary",
        )
    end

    # ---- Print key statistics ----
    total_days = nrow(vic_daily)
    peak_row = vic_daily[argmax(vic_daily.demand), :]
    println("\n=== DEMAND HEAT EVENT ANALYSIS ===")
    println("Total days: ", total_days)
    @printf("Heat event days (>P95): %d (%.1f%%)\n", length(heat_days), 100 * length(heat_days) / total_days)
    @printf("Peak demand: %.0f MW on %s\n", peak_row.demand, peak_row.date_only)
    @printf("Mean demand: %.0f MW\n", mean(vic_daily.demand))

    # ---- Solar CF on the hottest demand days ----
    if haskey(sol_4006, "Bannerton_SAT")
        cf_of_date = solar_cf_by_date(sol_4006["Bannerton_SAT"])
        top10_days = heat_days[1:min(10, length(heat_days))]
        hot_day_cfs = Float64[]
        for hd in top10_days
            haskey(cf_of_date, hd) || continue
            push!(hot_day_cfs, cf_of_date[hd])
        end
        mean_cf = mean(hot_day_cfs)
        @printf("\nSolar CF on top 10 heat event days: mean=%.4f\n", mean_cf)
        println("  Individual CFs: ", [@sprintf("%.4f", c) for c in hot_day_cfs])

        write_table(
            DataFrame(
                rank = 1:length(hot_day_cfs),
                date = top10_days[1:length(hot_day_cfs)],
                solar_cf = hot_day_cfs,
                mean_solar_cf_top10 = fill(mean_cf, length(hot_day_cfs)),
            ),
            SCRIPT_STEM,
            "hot_day_solar_cf_detail",
        )
    end

    write_table(
        DataFrame(
            total_days = total_days,
            demand_p90_mw = demand_p90,
            demand_p95_mw = demand_p95,
            heat_day_count = length(heat_days),
            normal_day_count = length(normal_days),
            heat_event_pct = 100 * length(heat_days) / total_days,
            peak_demand_mw = peak_row.demand,
            peak_date = peak_row.date_only,
            mean_demand_mw = mean(vic_daily.demand),
        ),
        SCRIPT_STEM,
        "demand_heat_event_summary",
    )

    # ====== Figure 1: VIC demand + solar CF time series ======
    p1 = plot(layout=(2,1), size=(1400, 900), left_margin=6Plots.mm, right_margin=3Plots.mm, top_margin=5Plots.mm, bottom_margin=4Plots.mm)

    if haskey(sol_4006, "Bannerton_SAT")
        sol_vic = sol_4006["Bannerton_SAT"]
        sol_vic_daily = daily_cf(sol_vic, HH_COLS_SOL)
        sol_vic_dates = sol_vic.datetime
        sol_rolling = [i < 7 ? NaN : mean(sol_vic_daily[max(1,i-6):i]) for i in 1:length(sol_vic_daily)]

        plot!(p1[1], sol_vic_dates, sol_vic_daily, color=:orange, linewidth=0.5, alpha=0.7, label="Solar CF (Bannerton)")
        plot!(p1[1], sol_vic_dates, sol_rolling, color=:darkred, linewidth=2, label="7-day avg")
        plot!(p1[1], title="4006 Solar CF — Bannerton VIC (Full Period)", ylabel="Daily Mean CF",
              ylim=(0, 0.4), legend=:topright, grid=true, gridalpha=0.3)
    end

    vic_dem_dates = vic_daily.date_only
    vic_dem_values = vic_daily.demand
    vic_rolling = [i < 7 ? NaN : mean(vic_dem_values[max(1,i-6):i]) for i in 1:length(vic_dem_values)]

    plot!(p1[2], vic_dem_dates, vic_dem_values, color=:grey, linewidth=0.5, alpha=0.7, label="VIC Demand")
    plot!(p1[2], vic_dem_dates, vic_rolling, color=:black, linewidth=2, label="7-day avg")
    plot!(p1[2], title="2030 VIC Daily Mean Demand (MW)", xlabel="Date", ylabel="Demand (MW)",
          legend=:topright, grid=true, gridalpha=0.3)

    savefig(p1, figure_path(SCRIPT_STEM, "07_vic_demand_solar_4006.png"))
    println("Saved: 07_vic_demand_solar_4006.png")

    # ====== Figure 2: Scatter plot demand vs solar CF ======
    p2 = plot(size=(800, 600), title="VIC Demand vs Solar CF (2030, Bannerton)",
             xlabel="Daily Mean Solar CF", ylabel="Daily Mean Demand (MW)",
             legend=:bottomright, grid=true, gridalpha=0.3)

    if nrow(merged) > 0
        scatter!(p2, merged.solar_cf, merged.demand, markersize=2, alpha=0.3, color=:purple, label="")

        threshold_demand = quantile(merged.demand, 0.9)
        threshold_solar = quantile(merged.solar_cf, 0.1)
        bad_days = merged[(merged.demand .> threshold_demand) .& (merged.solar_cf .< threshold_solar), :]

        scatter!(p2, bad_days.solar_cf, bad_days.demand, markersize=4, color=:red,
                label="High demand (>$(round(Int, threshold_demand)) MW) + Low solar (<$(round(threshold_solar, digits=3)) CF)")
    end

    savefig(p2, figure_path(SCRIPT_STEM, "07_demand_vs_solar_scatter.png"))
    println("Saved: 07_demand_vs_solar_scatter.png")

    # ====== Figure 3: Demand heat events (2x2 subplots) ======
    month_labels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    p3 = plot(layout=(2,2), size=(1200, 1000), left_margin=6Plots.mm, right_margin=3Plots.mm, top_margin=5Plots.mm, bottom_margin=5Plots.mm)

    # Hourly profile for heat days vs normal days
    hours = 0:23
    heat_vals = [get(heat_hourly, h, NaN) for h in hours]
    normal_vals = [get(normal_hourly, h, NaN) for h in hours]

    plot!(p3[1], hours, heat_vals, color=:red, linewidth=2, marker=:o, markersize=3,
          label="Heat days (>$(round(Int, demand_p95)) MW, n=$(length(heat_days)))")
    plot!(p3[1], hours, normal_vals, color=:blue, linewidth=2, marker=:s, markersize=3,
          label="Normal days (<$(round(Int, demand_p90)) MW, n=$(length(normal_days)))")
    plot!(p3[1], title="VIC Demand: Heat Event Days vs Normal Days", xlabel="Hour", ylabel="Demand (MW)",
          legend=:topright, grid=true, gridalpha=0.3)

    # Duration curve
    sorted_demand = sort(vic_daily.demand; rev=true)
    plot!(p3[2], sorted_demand, color=:grey, linewidth=1.5, label="", legend=false)
    hline!(p3[2], [demand_p90], color=:blue, linestyle=:dash, label="P90=$(round(Int, demand_p90))")
    hline!(p3[2], [demand_p95], color=:red, linestyle=:dash, label="P95=$(round(Int, demand_p95))")
    plot!(p3[2], title="VIC Demand Duration Curve (2030)", xlabel="Day Rank", ylabel="Demand (MW)",
          legend=:topright, grid=true, gridalpha=0.3)

    # Heatmap: demand by month and hour
    dem_load_heat = deepcopy(vic_dem)
    dem_load_heat = transform(dem_load_heat, :date => ByRow(x -> month(x)) => :month_int)
    dem_load_heat = transform(dem_load_heat, :date => ByRow(x -> hour(x)) => :hour)
    heatmap_data = zeros(12, 24)
    counts = zeros(12, 24)
    for row in eachrow(dem_load_heat)
        m = row.month_int
        h = row.hour + 1
        if 1 <= m <= 12 && 1 <= h <= 24
            heatmap_data[m, h] += row.value
            counts[m, h] += 1
        end
    end
    heatmap_data = heatmap_data ./ max.(counts, 1)

    heatmap!(p3[3], 0:23, 1:12, heatmap_data, c=:YlOrRd, title="VIC Demand Heatmap: Month vs Hour",
            xlabel="Hour", ylabel="Month", yticks=(1:12, month_labels), legend=false)

    # Normalized demand and solar
    if nrow(merged) > 0
        merged_sorted = sort(merged, :demand)
        day_ranks = 1:nrow(merged_sorted)
        demand_norm = merged_sorted.demand ./ maximum(merged_sorted.demand)
        solar_norm = merged_sorted.solar_cf ./ maximum(merged_sorted.solar_cf)

        bar!(p3[4], day_ranks, demand_norm, alpha=0.5, color=:grey, label="VIC Demand (norm)", legend=:topright)
        plot!(p3[4], day_ranks, solar_norm, color=:orange, linewidth=1, label="Solar CF (norm)")
        plot!(p3[4], title="Normalized Demand & Solar CF (sorted by demand)", xlabel="Day Rank",
              grid=true, gridalpha=0.3)
    end

    savefig(p3, figure_path(SCRIPT_STEM, "07_demand_heat_events.png"))
    println("Saved: 07_demand_heat_events.png")

    println("\nDone.")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
