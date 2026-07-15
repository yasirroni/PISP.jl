#!/usr/bin/env julia

using CSV
using DataFrames
using Dates
using Printf
using Statistics
using Plots

const SCRIPT_STEM = "01_data_loading"
const TRACES = joinpath("data", "2024", "pisp-downloads", "Traces")
const TABLE_ROOT = joinpath(@__DIR__, "tables")
const FIGURE_ROOT = joinpath(@__DIR__, "figures")

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

function read_trace(path)
    return CSV.read(path, DataFrame)
end

function column_preview(df::DataFrame, n = 10)
    cols = names(df)
    return cols[1:min(n, length(cols))]
end

function first_three_text(df::DataFrame, row)
    cols = names(df)[1:3]
    parts = ["$(col): $(df[row, col])" for col in cols]
    return "{" * join(parts, ", ") * "}"
end

function value_minmax(df::DataFrame)
    value_cols = names(df)[4:end]
    min_value = minimum(minimum(skipmissing(df[!, col])) for col in value_cols)
    max_value = maximum(maximum(skipmissing(df[!, col])) for col in value_cols)
    return min_value, max_value
end

function trace_shape_columns(label, path, df::DataFrame)
    cols = names(df)
    preview = cols[1:min(10, length(cols))]
    return (
        trace_type = label,
        file = path,
        file_name = basename(path),
        rows = nrow(df),
        columns = ncol(df),
        metadata_columns = join(cols[1:3], ","),
        value_columns = max(length(cols) - 3, 0),
        first_value_column = length(cols) > 3 ? cols[4] : "",
        last_value_column = length(cols) > 3 ? cols[end] : "",
        columns_preview = join(preview, "|"),
    )
end

function trace_date_range(label, path, df::DataFrame)
    first = df[1, :]
    last = df[end, :]
    return (
        trace_type = label,
        file_name = basename(path),
        first_year = Int(first["Year"]),
        first_month = Int(first["Month"]),
        first_day = Int(first["Day"]),
        last_year = Int(last["Year"]),
        last_month = Int(last["Month"]),
        last_day = Int(last["Day"]),
    )
end

function trace_value_range(label, path, df::DataFrame)
    min_value, max_value = value_minmax(df)
    return (
        trace_type = label,
        file_name = basename(path),
        min_value = min_value,
        max_value = max_value,
    )
end

function write_trace_tables(sol_file, df_sol::DataFrame, wind_file, df_wind::DataFrame, midday_cols, n_low, n_total)
    traces = [("solar", sol_file, df_sol), ("wind", wind_file, df_wind)]
    write_table(DataFrame([trace_shape_columns(trace...) for trace in traces]), SCRIPT_STEM, "trace_shape_columns")
    write_table(DataFrame([trace_date_range(trace...) for trace in traces]), SCRIPT_STEM, "trace_date_ranges")
    write_table(DataFrame([trace_value_range(trace...) for trace in traces]), SCRIPT_STEM, "trace_value_ranges")
    write_table(
        DataFrame(
            [
                (
                    trace_type = "solar",
                    file_name = basename(sol_file),
                    midday_columns = join(midday_cols, "|"),
                    low_threshold = 0.1,
                    low_days = Int(n_low),
                    total_days = Int(n_total),
                    low_percent = 100 * n_low / n_total,
                ),
            ],
        ),
        SCRIPT_STEM,
        "solar_midday_low_days",
    )
end

function demand_files(demand_dir)
    isdir(demand_dir) || return String[]
    return sort(filter(name -> endswith(name, "_PV_TOT.csv"), readdir(demand_dir)))
end

function write_demand_table(demand_dir, dem_files, df_dem)
    if !isempty(dem_files)
        cols = names(df_dem)
        rows = [
            (
                demand_dir = demand_dir,
                file_count = length(dem_files),
                sample_file = dem_files[1],
                sample_rows = nrow(df_dem),
                sample_columns = ncol(df_dem),
                metadata_columns = join(cols[1:3], ","),
                value_columns = max(length(cols) - 3, 0),
                first_value_column = length(cols) > 3 ? cols[4] : "",
                last_value_column = length(cols) > 3 ? cols[end] : "",
                columns_list = join(cols, "|"),
            ),
        ]
    else
        rows = [
            (
                demand_dir = demand_dir,
                file_count = 0,
                sample_file = "",
                sample_rows = missing,
                sample_columns = missing,
                metadata_columns = "",
                value_columns = missing,
                first_value_column = "",
                last_value_column = "",
                columns_list = "",
            ),
        ]
    end
    write_table(DataFrame(rows), SCRIPT_STEM, "demand_sample_metadata")
end

function available_year_rows()
    rows = NamedTuple[]
    for yr in [2011, 2015, 2019, 2023]
        test_file = joinpath(TRACES, "solar_$(yr)", "Bannerton_SAT_RefYear$(yr).csv")
        exists = isfile(test_file)
        first_year = missing
        first_month = missing
        first_day = missing
        if exists
            df_check = CSV.read(test_file, DataFrame; limit = 1)
            first_year = Int(df_check[1, "Year"])
            first_month = Int(df_check[1, "Month"])
            first_day = Int(df_check[1, "Day"])
        end
        push!(
            rows,
            (
                year = yr,
                solar_file = test_file,
                exists = exists ? 1 : 0,
                first_year = first_year,
                first_month = first_month,
                first_day = first_day,
            ),
        )
    end
    return rows
end

function main()
    gr()  # Select GR backend for static PNG output

    sol_file = joinpath(TRACES, "solar_4006", "Bannerton_SAT_RefYear4006.csv")
    df_sol = read_trace(sol_file)
    println("=== SOLAR TRACE EXAMPLE ===")
    println("File: ", sol_file)
    println("Shape: ", (nrow(df_sol), ncol(df_sol)))
    println("Columns: ", column_preview(df_sol), "...")
    println("Date range: ", first_three_text(df_sol, 1), " to ", first_three_text(df_sol, nrow(df_sol)))
    sol_min, sol_max = value_minmax(df_sol)
    println(@sprintf("Value range: [%.4f, %.4f]", sol_min, sol_max))

    midday_cols = string.(24:35)
    daily_max = [maximum(row[col] for col in midday_cols) for row in eachrow(df_sol)]
    n_low = count(<(0.1), daily_max)
    n_total = nrow(df_sol)
    println(@sprintf("Days with midday max < 0.1: %d/%d (%.1f%%)", n_low, n_total, 100 * n_low / n_total))

    wind_file = joinpath(TRACES, "wind_4006", "ARWF1_RefYear4006.csv")
    df_wind = read_trace(wind_file)
    println("\n=== WIND TRACE EXAMPLE ===")
    println("File: ", wind_file)
    println("Shape: ", (nrow(df_wind), ncol(df_wind)))
    println("Date range: ", first_three_text(df_wind, 1), " to ", first_three_text(df_wind, nrow(df_wind)))
    wind_min, wind_max = value_minmax(df_wind)
    println(@sprintf("Value range: [%.4f, %.4f]", wind_min, wind_max))

    demand_dir = joinpath(TRACES, "demand_VIC_Step Change")
    dem_files = demand_files(demand_dir)
    df_dem = nothing
    if !isempty(dem_files)
        df_dem = read_trace(joinpath(demand_dir, dem_files[1]))
        println("\n=== DEMAND TRACE EXAMPLE ===")
        println("File: ", dem_files[1])
        println("Shape: ", (nrow(df_dem), ncol(df_dem)))
        println("Columns: ", names(df_dem))
        println("Head:")
        show(stdout, first(df_dem, 3); allrows = true, allcols = true)
        println()
    end

    println("\n=== SUMMARY ===")
    n_solar = count(endswith(".csv"), readdir(joinpath(TRACES, "solar_4006")))
    n_wind = count(endswith(".csv"), readdir(joinpath(TRACES, "wind_4006")))
    println("Solar locations in 4006: ", n_solar)
    println("Wind locations in 4006: ", n_wind)

    for row in available_year_rows()
        print("Solar $(row.year) exists: ", row.exists == 1 ? "true" : "false")
        if row.exists == 1
            println("  (first date: {Year: $(row.first_year), Month: $(row.first_month), Day: $(row.first_day)})")
        else
            println()
        end
    end

    # ---- Plot example traces ----
    # First 30 days
    sol_sub = df_sol[1:30, :]
    sol_datetime = Date.(sol_sub.Year, sol_sub.Month, sol_sub.Day)
    sol_hourly = vec(mean(Matrix(sol_sub[!, 4:51]), dims=2))

    wind_sub = df_wind[1:30, :]
    wind_datetime = Date.(wind_sub.Year, wind_sub.Month, wind_sub.Day)
    wind_hourly = vec(mean(Matrix(wind_sub[!, 4:51]), dims=2))

    p1 = plot(sol_datetime, sol_hourly, linewidth=0.8, color=:orange, label="", title="Solar 4006 — Bannerton_SAT (first 30 days)", ylabel="Mean half-hourly CF", legend=false)
    p2 = plot(wind_datetime, wind_hourly, linewidth=0.8, color=:steelblue, label="", title="Wind 4006 — ARWF1 (first 30 days)", ylabel="Mean half-hourly CF", legend=false)
    p = plot(p1, p2, layout=(2,1), size=(1400, 800))
    savefig(p, figure_path(SCRIPT_STEM, "01_sample_traces.png"))
    println("Saved: $(figure_path(SCRIPT_STEM, "01_sample_traces.png"))")

    write_trace_tables(sol_file, df_sol, wind_file, df_wind, midday_cols, n_low, n_total)
    write_demand_table(demand_dir, dem_files, df_dem)
    write_table(DataFrame(available_year_rows()), SCRIPT_STEM, "available_year_checks")

    println("\nDone.")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
