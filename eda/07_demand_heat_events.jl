#!/usr/bin/env julia

using CSV
using DataFrames
using Dates
using Printf
using Statistics

const SCRIPT_STEM = "07_demand_heat_events"
const TRACES = joinpath("data", "pisp-downloads", "Traces")
const OUT = joinpath("data", "pisp-datasets", "out-ref4006-poe10", "csv")
const TABLE_ROOT = joinpath(@__DIR__, "tables")

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

    println("\nDone.")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
