#!/usr/bin/env julia

using CSV
using DataFrames
using Dates
using Printf
using Statistics

const SCRIPT_STEM = "02_plot_4006_traces"
const TRACES = joinpath("data", "pisp-downloads", "Traces")
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

function read_trace(path)
    return CSV.read(path, DataFrame)
end

function add_datetime!(df::DataFrame)
    df.datetime = Date.(df.Year, df.Month, df.Day)
    return df
end

function daily_cf(df::DataFrame, half_hour_cols)
    return [mean(row[col] for col in half_hour_cols) for row in eachrow(df)]
end

function load_traces(tech, trace_year, locations)
    dfs = Dict{String, DataFrame}()
    base = joinpath(TRACES, "$(tech)_$(trace_year)")
    for loc in locations
        file = joinpath(base, "$(loc)_RefYear$(trace_year).csv")
        if isfile(file)
            df = read_trace(file)
            add_datetime!(df)
            dfs[loc] = df
        end
    end
    return dfs
end

# State-representative solar locations
const SOLAR_LOCATIONS = [
    ("VIC", "Bannerton_SAT"),
    ("NSW", "Darlington_Point_SAT"),
    ("QLD", "Banksia_SAT"),
    ("SA", "Bungala_One_SAT"),
    ("TAS", "Derby_SAT"),
]

# State-representative wind locations
const WIND_LOCATIONS = [
    ("VIC", "DUNDWF1"),
    ("NSW", "GULLRWF1"),
    ("QLD", "KABANWF1"),
    ("SA", "CLEMGPWF"),
    ("TAS", "MUSSELR1"),
]

const HH_COLS_SOL = string.(1:48)
const HH_COLS_WIND = [lpad(i, 2, '0') for i in 1:48]
const HALF_HOURS = collect(0.5:0.5:24.0)

# Rolling mean matching pandas' `Series.rolling(window).mean()` default
# `min_periods == window`: the first `window - 1` entries are missing.
function rolling_mean(values, window)
    n = length(values)
    result = Vector{Union{Missing, Float64}}(missing, n)
    for i in window:n
        result[i] = mean(values[(i - window + 1):i])
    end
    return result
end

# Replicates `(date + pd.offsets.MonthEnd(n)).year`, used by the Python
# script to bucket each day into an Australian financial year (ending June).
# pandas MonthEnd rolls a non-month-end date forward to its month's end
# first (consuming one of the `n` steps), then advances `n - 1` more
# month-ends; a date already on a month end advances the full `n` steps.
function fy_year(date::Date, n::Int = 6)
    absolute_month = year(date) * 12 + (month(date) - 1)
    on_offset = day(date) == daysinmonth(date)
    shifted = absolute_month + n - (on_offset ? 0 : 1)
    return fld(shifted, 12)
end

function write_loaded_locations_table(sol_dict, wind_dict)
    rows = NamedTuple[]
    for (state, loc) in SOLAR_LOCATIONS
        df = get(sol_dict, loc, nothing)
        push!(rows, (
            tech = "solar",
            state = state,
            location = loc,
            file_name = "$(loc)_RefYear4006.csv",
            loaded = df === nothing ? 0 : 1,
            rows = df === nothing ? missing : nrow(df),
            columns = df === nothing ? missing : ncol(df),
        ))
    end
    for (state, loc) in WIND_LOCATIONS
        df = get(wind_dict, loc, nothing)
        push!(rows, (
            tech = "wind",
            state = state,
            location = loc,
            file_name = "$(loc)_RefYear4006.csv",
            loaded = df === nothing ? 0 : 1,
            rows = df === nothing ? missing : nrow(df),
            columns = df === nothing ? missing : ncol(df),
        ))
    end
    write_table(DataFrame(rows), SCRIPT_STEM, "loaded_locations")
end

function daily_cf_row(tech, state, loc, df::DataFrame, hh_cols)
    daily = daily_cf(df, hh_cols)
    rolling7 = rolling_mean(daily, 7)
    return (
        tech = tech,
        state = state,
        location = loc,
        n_days = length(daily),
        mean_daily_cf = mean(daily),
        std_daily_cf = std(daily),
        min_daily_cf = minimum(daily),
        max_daily_cf = maximum(daily),
        mean_rolling7_cf = mean(skipmissing(rolling7)),
    )
end

function write_daily_cf_summary_table(sol_dict, wind_dict)
    rows = NamedTuple[]
    for (state, loc) in SOLAR_LOCATIONS
        df = get(sol_dict, loc, nothing)
        df === nothing && continue
        push!(rows, daily_cf_row("solar", state, loc, df, HH_COLS_SOL))
    end
    for (state, loc) in WIND_LOCATIONS
        df = get(wind_dict, loc, nothing)
        df === nothing && continue
        push!(rows, daily_cf_row("wind", state, loc, df, HH_COLS_WIND))
    end
    write_table(DataFrame(rows), SCRIPT_STEM, "daily_cf_summary")
end

function write_solar_diurnal_profile_table(sol_dict, prof_loc)
    df_prof = sol_dict[prof_loc]
    summer_mask = in.(df_prof.Month, Ref((12, 1, 2)))
    winter_mask = in.(df_prof.Month, Ref((6, 7, 8)))

    rows = NamedTuple[]
    for (season, mask) in (("Summer", summer_mask), ("Winter", winter_mask))
        df_season = df_prof[mask, :]
        n_days_season = nrow(df_season)
        for (hh, hh_col) in zip(HALF_HOURS, HH_COLS_SOL)
            vals = df_season[!, hh_col]
            push!(rows, (
                location = prof_loc,
                season = season,
                half_hour = hh,
                n_days = n_days_season,
                mean_cf = mean(vals),
                p10_cf = quantile(vals, 0.1),
                p90_cf = quantile(vals, 0.9),
            ))
        end
    end
    write_table(DataFrame(rows), SCRIPT_STEM, "solar_diurnal_profile")
end

function write_wind_monthly_diurnal_profile_table(wind_dict, wind_loc)
    df_wind_prof = wind_dict[wind_loc]
    rows = NamedTuple[]
    for m in 1:12
        mask = df_wind_prof.Month .== m
        any(mask) || continue
        df_month = df_wind_prof[mask, :]
        for (hh, hh_col) in zip(HALF_HOURS, HH_COLS_WIND)
            push!(rows, (
                location = wind_loc,
                month = m,
                half_hour = hh,
                mean_cf = mean(df_month[!, hh_col]),
            ))
        end
    end
    write_table(DataFrame(rows), SCRIPT_STEM, "wind_monthly_diurnal_profile")
end

function write_wind_monthly_mean_cf_table(wind_dict, wind_loc)
    df_wind_prof = wind_dict[wind_loc]
    daily_wind = daily_cf(df_wind_prof, HH_COLS_WIND)
    month_starts = [Date(year(d), month(d), 1) for d in df_wind_prof.datetime]

    grouped = DataFrame(month_start = month_starts, cf = daily_wind)
    summary = combine(groupby(grouped, :month_start), :cf => mean => :mean_cf)

    rows = [
        (location = wind_loc, month_start = Dates.format(row.month_start, "yyyy-mm-dd"), mean_cf = row.mean_cf)
        for row in eachrow(summary)
    ]
    write_table(DataFrame(rows), SCRIPT_STEM, "wind_monthly_mean_cf")
end

function write_annual_cf_by_fy_table(sol_dict, wind_dict)
    rows = NamedTuple[]

    df_s = get(sol_dict, "Bannerton_SAT", nothing)
    if df_s !== nothing
        fy = fy_year.(df_s.datetime)
        cf = daily_cf(df_s, HH_COLS_SOL)
        grouped = DataFrame(fy = fy, cf = cf)
        summary = combine(groupby(grouped, :fy), :cf => mean => :mean_cf)
        for row in eachrow(summary)
            push!(rows, (tech = "solar", location = "Bannerton_SAT", financial_year = row.fy, mean_cf = row.mean_cf))
        end
    end

    df_w = get(wind_dict, "DUNDWF1", nothing)
    if df_w !== nothing
        fy = fy_year.(df_w.datetime)
        cf = daily_cf(df_w, HH_COLS_WIND)
        grouped = DataFrame(fy = fy, cf = cf)
        summary = combine(groupby(grouped, :fy), :cf => mean => :mean_cf)
        for row in eachrow(summary)
            push!(rows, (tech = "wind", location = "DUNDWF1", financial_year = row.fy, mean_cf = row.mean_cf))
        end
    end

    write_table(DataFrame(rows), SCRIPT_STEM, "annual_cf_by_fy")
end

function main()
    sol_4006 = load_traces("solar", 4006, last.(SOLAR_LOCATIONS))
    wind_4006 = load_traces("wind", 4006, last.(WIND_LOCATIONS))

    println("Loaded $(length(sol_4006)) solar locations, $(length(wind_4006)) wind locations for trace 4006")

    write_loaded_locations_table(sol_4006, wind_4006)
    write_daily_cf_summary_table(sol_4006, wind_4006)
    write_solar_diurnal_profile_table(sol_4006, "Bannerton_SAT")
    write_wind_monthly_diurnal_profile_table(wind_4006, "DUNDWF1")
    write_wind_monthly_mean_cf_table(wind_4006, "DUNDWF1")
    write_annual_cf_by_fy_table(sol_4006, wind_4006)

    println("\nDone.")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
