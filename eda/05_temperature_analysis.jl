#!/usr/bin/env julia

using CSV
using DataFrames
using XLSX
using Printf
using Statistics
using Plots

const SCRIPT_STEM = "05_temperature_analysis"
const TRACES = joinpath("data", "2024", "pisp-downloads", "Traces")
const DOWNLOADS = joinpath("data", "2024", "pisp-downloads")
const TABLE_ROOT = joinpath(@__DIR__, "tables")
const FIGURE_ROOT = joinpath(@__DIR__, "figures")

gr()

const TEMP_KEYWORDS = ["temp", "heat", "thermal", "derate", "pv", "solar", "wind", "rooftop", "inverter"]
const HH_COLS_SOL = string.(1:48)
const CLIMATE_ZONES = [
    ("Hot_Inland", "Bomen_SAT"),
    ("Hot_SA", "Cultana_SAT"),
    ("Moderate_VIC", "Bannerton_SAT"),
    ("Cool_TAS", "Derby_SAT"),
]

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

is_keyword_match(name) = any(kw -> occursin(kw, lowercase(name)), TEMP_KEYWORDS)
is_rooftop_match(name) = occursin("rooftop", lowercase(name)) || occursin("rtpv", lowercase(name))
function is_reliability_match(name)
    lname = lowercase(name)
    return occursin("reliability", lname) || occursin("outage", lname) || occursin("generator", lname)
end

# Trim a raw XLSX matrix down to the bounding box of non-missing cells. A
# worksheet's declared dimension (and hence XLSX.jl's `sheet[:]`) can report
# extra trailing all-empty rows/columns beyond the sheet's real content;
# pandas' openpyxl-based reader trims these trailing empties before
# `pd.read_excel(header=None)` reports its shape. Verified against this
# workbook: e.g. "Rooftop PV" raw is
# (64, 35) but both pandas and this trim give (62, 33) — rows 63-64 and columns
# 34-35 are entirely `missing`.
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

# Mirrors pandas' "Unnamed: N" convention (0-based column index) for blank header cells.
function header_names(row)
    return [ismissing(v) ? "Unnamed: $(j - 1)" : string(v) for (j, v) in enumerate(row)]
end

function empty_df(schema::Vector{Pair{Symbol, DataType}})
    return DataFrame([name => Type[] for (name, Type) in schema]...)
end

function workbook_tables(workbook_path)
    sheet_inventory_rows = NamedTuple[]
    relevant_shape_rows = NamedTuple[]
    rooftop_rows = NamedTuple[]
    reliability_shape_rows = NamedTuple[]

    println("Workbook exists: ", isfile(workbook_path))

    if isfile(workbook_path)
        XLSX.openxlsx(workbook_path) do xf
            sheet_names = XLSX.sheetnames(xf)
            println("\n=== ISP Assumptions Workbook Sheets ($(length(sheet_names))) ===")
            for (i, name) in enumerate(sheet_names)
                println(@sprintf("  %2d. %s", i, name))
            end

            println("\n=== Potentially Relevant Sheets ===")
            for name in sheet_names
                is_keyword_match(name) && println("  - ", name)
            end

            for (i, name) in enumerate(sheet_names)
                push!(
                    sheet_inventory_rows,
                    (
                        sheet_index = i,
                        sheet_name = name,
                        is_keyword_match = is_keyword_match(name) ? 1 : 0,
                        is_rooftop_match = is_rooftop_match(name) ? 1 : 0,
                        is_reliability_match = is_reliability_match(name) ? 1 : 0,
                    ),
                )
            end

            relevant_sheets = [name for name in sheet_names if is_keyword_match(name)]

            for sheet in first(relevant_sheets, min(10, length(relevant_sheets)))
                m = trim_sheet(xf[sheet][:])
                n_rows, n_cols = size(m)
                println("\n--- Sheet: $sheet (shape: ($n_rows, $n_cols)) ---")
                push!(relevant_shape_rows, (sheet_name = sheet, n_rows = n_rows, n_cols = n_cols, read_ok = 1))
            end

            for sheet in sheet_names
                if is_rooftop_match(sheet)
                    m = trim_sheet(xf[sheet][:])
                    total_rows, n_cols = size(m)
                    n_rows = max(total_rows - 1, 0)
                    cols = total_rows > 0 ? header_names(m[1, :]) : String[]
                    println("\n=== Rooftop PV Sheet ($sheet) ===")
                    println("Columns: ", cols)
                    push!(
                        rooftop_rows,
                        (
                            sheet_name = sheet,
                            n_rows = n_rows,
                            n_cols = n_cols,
                            columns_preview = join(cols[1:min(5, length(cols))], "|"),
                        ),
                    )
                end
            end

            for sheet in sheet_names
                if is_reliability_match(sheet)
                    m = trim_sheet(xf[sheet][:])
                    n_rows, n_cols = size(m)
                    println("\n=== Reliability Sheet: $sheet (shape: ($n_rows, $n_cols)) ===")
                    push!(reliability_shape_rows, (sheet_name = sheet, n_rows = n_rows, n_cols = n_cols))
                end
            end
        end
    end

    sheet_inventory_df = isempty(sheet_inventory_rows) ?
        empty_df([:sheet_index => Int, :sheet_name => String, :is_keyword_match => Int, :is_rooftop_match => Int, :is_reliability_match => Int]) :
        DataFrame(sheet_inventory_rows)
    relevant_shape_df = isempty(relevant_shape_rows) ?
        empty_df([:sheet_name => String, :n_rows => Int, :n_cols => Int, :read_ok => Int]) :
        DataFrame(relevant_shape_rows)
    rooftop_df = isempty(rooftop_rows) ?
        empty_df([:sheet_name => String, :n_rows => Int, :n_cols => Int, :columns_preview => String]) :
        DataFrame(rooftop_rows)
    reliability_shape_df = isempty(reliability_shape_rows) ?
        empty_df([:sheet_name => String, :n_rows => Int, :n_cols => Int]) :
        DataFrame(reliability_shape_rows)

    return sheet_inventory_df, relevant_shape_df, rooftop_df, reliability_shape_df
end

function pisp_output_inventory(csv_dir, sched_dir)
    rows = NamedTuple[]
    println("\n=== PISP Output Files ===")
    if isdir(csv_dir)
        for name in sort(filter(n -> endswith(lowercase(n), ".csv"), readdir(csv_dir)))
            println("  CSV: ", name)
            push!(rows, (kind = "csv", name = name))
        end
    end

    if isdir(sched_dir)
        for name in sort(filter(n -> startswith(n, "schedule-"), readdir(sched_dir)))
            if isdir(joinpath(sched_dir, name))
                println("  Schedule: ", name)
                push!(rows, (kind = "schedule", name = name))
            end
        end
    end

    return isempty(rows) ? empty_df([:kind => String, :name => String]) : DataFrame(rows)
end

function generator_tables(gen_path)
    details_rows = NamedTuple[]
    temp_row = (generator_table_exists = 0, total_columns = missing, n_temp_columns = missing, temp_columns_list = "")

    if isfile(gen_path)
        gen_df = CSV.read(gen_path, DataFrame)
        println("\n=== Generator Table (shape: $(size(gen_df))) ===")
        println("Columns: ", names(gen_df))

        is_solar(tech) = occursin(r"PV|SOLAR|DISTPV"i, tech)
        is_wind(tech) = occursin(r"WIND"i, tech)
        solar_gens = filter(row -> is_solar(row.tech), gen_df)
        wind_gens = filter(row -> is_wind(row.tech), gen_df)

        println("\nSolar generators: ", nrow(solar_gens))
        println("\nWind generators: ", nrow(wind_gens))

        for (category, subset) in (("solar", solar_gens), ("wind", wind_gens))
            for row in eachrow(subset)
                push!(
                    details_rows,
                    (
                        category = category,
                        id_gen = row.id_gen,
                        name = row.name,
                        tech = row.tech,
                        forate = row.forate,
                        derate = row.derate,
                        pmin = row.pmin,
                        pmax = row.pmax,
                        n = row.n,
                    ),
                )
            end
        end

        temp_cols = [col for col in names(gen_df) if any(kw -> occursin(kw, lowercase(col)), ["temp", "heat", "thermal"])]
        println("\nTemperature-related columns in Generator: ", temp_cols)
        temp_row = (
            generator_table_exists = 1,
            total_columns = ncol(gen_df),
            n_temp_columns = length(temp_cols),
            temp_columns_list = join(temp_cols, "|"),
        )
    end

    details_df = isempty(details_rows) ?
        empty_df([:category => String, :id_gen => Int, :name => String, :tech => String, :forate => Float64, :derate => Float64, :pmin => Float64, :pmax => Float64, :n => Int]) :
        DataFrame(details_rows)

    return details_df, DataFrame([temp_row])
end

function climate_zone_summary()
    rows = NamedTuple[]
    println("\n=== Solar CF by Climate Zone (Summer 2019) ===")
    for (zone, loc) in CLIMATE_ZONES
        f = joinpath(TRACES, "solar_2019", "$(loc)_RefYear2019.csv")
        isfile(f) || continue
        df = CSV.read(f, DataFrame)
        summer = filter(row -> row.Month in (12, 1, 2), df)
        nrow(summer) == 0 && continue

        daily = [mean(row[col] for col in HH_COLS_SOL) for row in eachrow(summer)]
        midday_cols = string.(24:35)
        midday = [mean(row[col] for col in midday_cols) for row in eachrow(summer)]

        mean_daily = mean(daily)
        mean_midday = mean(midday)
        min_midday = minimum(midday)
        p5_midday = quantile(midday, 0.05)

        println(
            @sprintf(
                "  %s (%s): mean_daily=%.3f, mean_midday=%.3f, min_midday=%.3f, p5_midday=%.3f",
                zone, loc, mean_daily, mean_midday, min_midday, p5_midday,
            ),
        )

        push!(
            rows,
            (
                zone = zone,
                location = loc,
                n_summer_days = nrow(summer),
                mean_daily_cf = mean_daily,
                mean_midday_cf = mean_midday,
                min_midday_cf = min_midday,
                p5_midday_cf = p5_midday,
            ),
        )
    end

    return isempty(rows) ?
        empty_df([:zone => String, :location => String, :n_summer_days => Int, :mean_daily_cf => Float64, :mean_midday_cf => Float64, :min_midday_cf => Float64, :p5_midday_cf => Float64]) :
        DataFrame(rows)
end

function main()
    workbook_path = joinpath(DOWNLOADS, "2024-isp-inputs-and-assumptions-workbook.xlsx")
    sheet_inventory_df, relevant_shape_df, rooftop_df, reliability_shape_df = workbook_tables(workbook_path)

    path = write_table(sheet_inventory_df, SCRIPT_STEM, "workbook_sheet_inventory")
    println("Saved table: ", path)
    path = write_table(relevant_shape_df, SCRIPT_STEM, "workbook_relevant_sheet_shapes")
    println("Saved table: ", path)
    path = write_table(rooftop_df, SCRIPT_STEM, "workbook_rooftop_sheet_summary")
    println("Saved table: ", path)
    path = write_table(reliability_shape_df, SCRIPT_STEM, "workbook_reliability_sheet_shapes")
    println("Saved table: ", path)

    csv_dir = joinpath("data", "2024", "pisp-datasets", "out-ref4006-poe10", "csv")
    sched_dir = joinpath("data", "2024", "pisp-datasets", "out-ref4006-poe10")
    output_inventory_df = pisp_output_inventory(csv_dir, sched_dir)
    path = write_table(output_inventory_df, SCRIPT_STEM, "pisp_output_inventory")
    println("Saved table: ", path)

    gen_path = joinpath(csv_dir, "Generator.csv")
    details_df, temp_df = generator_tables(gen_path)
    path = write_table(details_df, SCRIPT_STEM, "generator_solar_wind_details")
    println("Saved table: ", path)
    path = write_table(temp_df, SCRIPT_STEM, "generator_temperature_columns")
    println("Saved table: ", path)

    zone_summary_df = climate_zone_summary()
    path = write_table(zone_summary_df, SCRIPT_STEM, "climate_zone_summer_cf_summary")
    println("Saved table: ", path)

    # ====== Figure: CF distribution by climate zone ======
    p1 = plot(legend=:topright, title="Summer 2019 — Daily Solar CF Distribution by Climate Zone",
              xlabel="Daily Mean Capacity Factor", ylabel="Density", size=(800, 600))
    for (zone, loc) in CLIMATE_ZONES
        f = joinpath(TRACES, "solar_2019", "$(loc)_RefYear2019.csv")
        isfile(f) || continue
        df = CSV.read(f, DataFrame)
        summer = filter(row -> row.Month in (12, 1, 2), df)
        nrow(summer) == 0 && continue
        daily = [mean(row[col] for col in HH_COLS_SOL) for row in eachrow(summer)]
        histogram!(p1, daily, bins=50, alpha=0.5, label="$(zone) ($(loc))", normalize=:pdf)
    end
    savefig(p1, figure_path(SCRIPT_STEM, "05_cf_by_climate_zone.png"))
    println("Saved: 05_cf_by_climate_zone.png")

    # ====== Figure: Midday CF vs daily mean (scatter) ======
    p2 = plot(layout=(2,2), figsize=(14,10), size=(1000, 800))
    for (idx, (zone, loc)) in enumerate(CLIMATE_ZONES)
        f = joinpath(TRACES, "solar_2019", "$(loc)_RefYear2019.csv")
        isfile(f) || continue
        df = CSV.read(f, DataFrame)
        summer = filter(row -> row.Month in (12, 1, 2), df)
        nrow(summer) == 0 && continue
        daily = [mean(row[col] for col in HH_COLS_SOL) for row in eachrow(summer)]
        midday = [mean(row[col] for col in string.(24:35)) for row in eachrow(summer)]
        scatter!(p2[idx], daily, midday, markersize=2, alpha=0.3, color=:orange, label="", legend=false)
        plot!(p2[idx], [0, 0.5], [0, 0.5], label="1:1", color=:black, linestyle=:dash, alpha=0.3, linewidth=1)
        plot!(p2[idx], title="$(zone) ($(loc))", xlabel="Daily Mean CF", ylabel="Midday Mean CF",
              xlim=(0, 0.5), ylim=(0, 0.8), grid=true, gridstyle=:dash, gridalpha=0.3)
    end
    savefig(p2, figure_path(SCRIPT_STEM, "05_midday_vs_daily_scatter.png"))
    println("Saved: 05_midday_vs_daily_scatter.png")

    println("\nDone.")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
