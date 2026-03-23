using CSV
using DataFrames
using Dates

const SCRAPPER_BUILD_PATH = normpath(@__DIR__, "..", "scrappers", "PISP-scrapper-build.jl")
const DEFAULT_TRACES_ROOT = normpath("/Volumes/Seagate/CSIRO AR-PST Stage 5/PISP-downloads", "Traces")
const DEFAULT_PISP_OUTPUT_ROOT = normpath("/Volumes/Seagate/CSIRO AR-PST Stage 5/PISP-outputs", "out-sanity-ref4006-poe10", "csv")
const DEFAULT_OUTPUT_ROOT = normpath("/Volumes/Seagate/CSIRO AR-PST Stage 5/PISP-outputs", "out-sanity-ref4006-poe10", "sanity-checks-4006")
const DEFAULT_SCENARIO_FILE = "STEP_CHANGE"
const DEFAULT_SCENARIO_DIR = "Step Change"
const DEFAULT_PISP_SCENARIO = 2
const DEFAULT_POE = 10
const DEFAULT_TRACE_KIND = "OPSO_MODELLING_PVLITE"
const DEFAULT_SYNTHETIC_REFYEAR = 4006
const DEFAULT_SWITCH_DAYS_BEFORE = 2
const DEFAULT_SWITCH_DAYS_AFTER = 2

const HAS_PLOTLYJS = let
    try
        @eval using PlotlyJS
        true
    catch
        false
    end
end

function load_date_ranges_refyears()
    if !isdefined(Main, :ISPdatabuilder)
        Base.invokelatest(Base.include, Main, SCRAPPER_BUILD_PATH)
    end
    builder = Base.invokelatest(getfield, Main, :ISPdatabuilder)
    Base.invokelatest(getfield, builder, :DATE_RANGES_REFYEARS)
end

function scenario_dir_name(scenario_file::AbstractString)
    mapping = Dict(
        "STEP_CHANGE" => "Step Change",
        "PROGRESSIVE_CHANGE" => "Progressive Change",
        "GREEN_ENERGY_EXPORTS" => "Green Energy Exports",
    )
    get(mapping, uppercase(String(scenario_file)), replace(titlecase(lowercase(String(scenario_file))), "_" => " "))
end

function trace_dir(region::AbstractString; traces_root::AbstractString=DEFAULT_TRACES_ROOT,
        scenario_dir::AbstractString=DEFAULT_SCENARIO_DIR)
    joinpath(traces_root, "demand_$(region)_$(scenario_dir)")
end

function trace_path(refyear::Integer, trace_kind::AbstractString; traces_root::AbstractString=DEFAULT_TRACES_ROOT,
        region::AbstractString, scenario_file::AbstractString=DEFAULT_SCENARIO_FILE,
        scenario_dir::AbstractString=DEFAULT_SCENARIO_DIR, poe::Integer=DEFAULT_POE)
    root = trace_dir(region; traces_root=traces_root, scenario_dir=scenario_dir)
    joinpath(root, "$(region)_RefYear_$(refyear)_$(scenario_file)_POE$(poe)_$(trace_kind).csv")
end

function demand_sched_path(year::Integer; output_root::AbstractString=DEFAULT_PISP_OUTPUT_ROOT)
    joinpath(output_root, "schedule-$(year)", "Demand_load_sched.csv")
end

function halfhour_columns(df::DataFrame)
    sort(filter(name -> occursin(r"^\d{2}$", String(name)), names(df)); by=name -> parse(Int, String(name)))
end

function load_trace_wide(refyear::Integer, trace_kind::AbstractString; traces_root::AbstractString=DEFAULT_TRACES_ROOT,
        region::AbstractString, scenario_file::AbstractString=DEFAULT_SCENARIO_FILE,
        scenario_dir::AbstractString=DEFAULT_SCENARIO_DIR, poe::Integer=DEFAULT_POE)
    path = trace_path(refyear, trace_kind; traces_root=traces_root, region=region,
        scenario_file=scenario_file, scenario_dir=scenario_dir, poe=poe)
    isfile(path) || error("Trace file not found: $(path)")

    df = CSV.read(path, DataFrame)
    df.date = Date.(df.Year, df.Month, df.Day)
    sort!(df, :date)
    df
end

function trace_wide_to_long(df::DataFrame)
    hh_cols = halfhour_columns(df)
    total_rows = nrow(df) * length(hh_cols)
    datetimes = Vector{DateTime}(undef, total_rows)
    values = Vector{Float64}(undef, total_rows)

    idx = 1
    for row in eachrow(df)
        base_dt = DateTime(row.date)
        for (slot_index, col) in enumerate(hh_cols)
            datetimes[idx] = base_dt + Minute(30 * (slot_index - 1))
            values[idx] = Float64(row[col])
            idx += 1
        end
    end

    DataFrame(datetime=datetimes, value=values)
end

function load_trace_long(refyear::Integer, trace_kind::AbstractString; traces_root::AbstractString=DEFAULT_TRACES_ROOT,
        region::AbstractString, scenario_file::AbstractString=DEFAULT_SCENARIO_FILE,
        scenario_dir::AbstractString=DEFAULT_SCENARIO_DIR, poe::Integer=DEFAULT_POE)
    trace_wide_to_long(load_trace_wide(refyear, trace_kind; traces_root=traces_root, region=region,
        scenario_file=scenario_file, scenario_dir=scenario_dir, poe=poe))
end

function load_pisp_demand_schedule(year::Integer; output_root::AbstractString=DEFAULT_PISP_OUTPUT_ROOT,
        id_dem::Integer, scenario::Integer=DEFAULT_PISP_SCENARIO)
    path = demand_sched_path(year; output_root=output_root)
    isfile(path) || error("Demand_load_sched file not found: $(path)")

    df = CSV.read(
        path,
        DataFrame;
        types=Dict(
            :id => Int,
            :id_dem => Int,
            :scenario => Int,
            :date => DateTime,
            :value => Float64,
        ),
        dateformat=dateformat"yyyy-mm-ddTHH:MM:SS.s",
    )

    df = filter(row -> row.id_dem == id_dem && row.scenario == scenario, df)
    isempty(df) && error("No Demand_load_sched rows matched id_dem=$(id_dem), scenario=$(scenario), year=$(year)")
    sort!(df, :date)
    rename!(select(df, :date, :value), :date => :datetime, :value => :pisp_demand_load_sched)
end

function normalize_block(block)
    start_date = hasproperty(block, :start_date) ? Date(getproperty(block, :start_date)) : Date(block[1])
    end_date = hasproperty(block, :end_date) ? Date(getproperty(block, :end_date)) : Date(block[2])
    refyear = hasproperty(block, :refyear) ? Int(getproperty(block, :refyear)) : Int(block[3])
    label = hasproperty(block, :label) ? String(getproperty(block, :label)) :
        "$(Dates.format(start_date, "yyyy-mm-dd"))_to_$(Dates.format(end_date, "yyyy-mm-dd"))"
    (label=label, start_date=start_date, end_date=end_date, refyear=refyear)
end

function calendar_year_blocks(year::Integer; date_ranges=load_date_ranges_refyears())
    calendar_start = Date(year, 1, 1)
    calendar_end = Date(year, 12, 31)
    blocks = NamedTuple[]

    for raw_block in date_ranges
        block = normalize_block(raw_block)
        start_date = max(block.start_date, calendar_start)
        end_date = min(block.end_date, calendar_end)
        if start_date <= end_date
            push!(blocks, (
                label="$(Dates.format(start_date, "yyyy-mm-dd"))_to_$(Dates.format(end_date, "yyyy-mm-dd"))",
                start_date=start_date,
                end_date=end_date,
                refyear=block.refyear,
            ))
        end
    end

    sort!(blocks; by=block -> block.start_date)
end

function block_mapping_dataframe(blocks)
    DataFrame(
        block_index=1:length(blocks),
        label=getproperty.(blocks, :label),
        start_date=getproperty.(blocks, :start_date),
        end_date=getproperty.(blocks, :end_date),
        refyear=getproperty.(blocks, :refyear),
    )
end

function build_weekly_windows(blocks)
    windows = NamedTuple[]
    seen = Set{Tuple{DateTime,DateTime}}()

    for block in blocks
        first_start = DateTime(block.start_date)
        first_end = DateTime(min(block.end_date, block.start_date + Day(6)), Time(23, 30))
        key = (first_start, first_end)
        if !(key in seen)
            push!(windows, (label="week_start_$(Dates.format(block.start_date, "yyyy-mm-dd"))", start_dt=first_start, end_dt=first_end))
            push!(seen, key)
        end

        last_start_date = max(block.start_date, block.end_date - Day(6))
        last_start = DateTime(last_start_date)
        last_end = DateTime(block.end_date, Time(23, 30))
        key = (last_start, last_end)
        if !(key in seen)
            push!(windows, (label="week_end_$(Dates.format(block.end_date, "yyyy-mm-dd"))", start_dt=last_start, end_dt=last_end))
            push!(seen, key)
        end
    end

    sort!(windows; by=window -> window.start_dt)
end

function build_switch_windows(blocks; days_before::Integer=DEFAULT_SWITCH_DAYS_BEFORE, days_after::Integer=DEFAULT_SWITCH_DAYS_AFTER)
    windows = NamedTuple[]
    for idx in 1:(length(blocks) - 1)
        previous_block = blocks[idx]
        next_block = blocks[idx + 1]
        switch_date = next_block.start_date
        start_dt = DateTime(max(previous_block.start_date, switch_date - Day(days_before)))
        end_dt = DateTime(min(next_block.end_date, switch_date + Day(days_after)), Time(23, 30))
        push!(windows, (
            label="switch_$(Dates.format(switch_date, "yyyy-mm-dd"))_$(previous_block.refyear)_to_$(next_block.refyear)",
            switch_date=switch_date,
            previous_refyear=previous_block.refyear,
            next_refyear=next_block.refyear,
            start_dt=start_dt,
            end_dt=end_dt,
        ))
    end
    windows
end

function block_refyear_for_date(date::Date, blocks)
    for block in blocks
        if block.start_date <= date <= block.end_date
            return block.refyear
        end
    end
    error("No refyear block found for date $(date)")
end

function select_long_window(df::DataFrame, start_dt::DateTime, end_dt::DateTime)
    filter(:datetime => dt -> start_dt <= dt <= end_dt, df)
end

function halfhour_to_hourly_average(df::DataFrame; value_col::Symbol=:expected_value)
    sort!(df, :datetime)
    datetimes = DateTime[]
    values = Float64[]

    i = 1
    while i <= nrow(df) - 1
        dt = df.datetime[i]
        if minute(dt) != 0
            i += 1
            continue
        end

        next_dt = df.datetime[i + 1]
        next_dt == dt + Minute(30) || error("Expected consecutive half-hour rows at $(dt), found $(next_dt)")
        push!(datetimes, dt)
        push!(values, (Float64(df[i, value_col]) + Float64(df[i + 1, value_col])) / 2)
        i += 2
    end

    DataFrame(datetime=datetimes, expected_hourly_from_trace=values)
end

function compare_long_window(df4006::DataFrame, source_traces::Dict{Int,DataFrame}, blocks, start_dt::DateTime, end_dt::DateTime;
        pisp_hourly::Union{Nothing,DataFrame}=nothing)
    merged = rename(select_long_window(df4006, start_dt, end_dt), :value => :value_4006)

    for refyear in sort!(collect(keys(source_traces)))
        source_slice = select_long_window(source_traces[refyear], start_dt, end_dt)
        rename!(source_slice, :value => Symbol("value_refyear_$(refyear)"))
        merged = outerjoin(merged, source_slice, on=:datetime)
    end

    sort!(merged, :datetime)
    merged.expected_refyear = [block_refyear_for_date(Date(dt), blocks) for dt in merged.datetime]
    merged.expected_value = Vector{Float64}(undef, nrow(merged))

    for row_index in 1:nrow(merged)
        refyear = merged.expected_refyear[row_index]
        ref_col = Symbol("value_refyear_$(refyear)")
        merged.expected_value[row_index] = Float64(merged[row_index, ref_col])
    end

    merged.diff_4006_vs_expected = merged.value_4006 .- merged.expected_value

    if pisp_hourly !== nothing
        expected_hourly = halfhour_to_hourly_average(select(merged, :datetime, :expected_value))
        pisp_slice = select_long_window(pisp_hourly, start_dt, end_dt)
        hourly_compare = leftjoin(expected_hourly, pisp_slice, on=:datetime)
        hourly_compare.diff_pisp_vs_expected_hourly =
            hourly_compare.pisp_demand_load_sched .- hourly_compare.expected_hourly_from_trace
        merged = leftjoin(merged, hourly_compare, on=:datetime)
        sort!(merged, :datetime)
    end

    merged
end

function summary_dataframe(trace_kind::AbstractString, year::Integer, blocks, df4006::DataFrame, source_traces::Dict{Int,DataFrame};
        pisp_hourly::Union{Nothing,DataFrame}=nothing)
    rows = NamedTuple[]
    for block in blocks
        start_dt = DateTime(block.start_date)
        end_dt = DateTime(block.end_date, Time(23, 30))
        merged = compare_long_window(df4006, source_traces, blocks, start_dt, end_dt; pisp_hourly=pisp_hourly)
        max_abs_diff = maximum(abs.(merged.diff_4006_vs_expected))
        pisp_diffs = hasproperty(merged, :diff_pisp_vs_expected_hourly) ? collect(skipmissing(merged.diff_pisp_vs_expected_hourly)) : Float64[]
        push!(rows, (
            trace_kind=trace_kind,
            calendar_year=year,
            block_label=block.label,
            start_datetime=start_dt,
            end_datetime=end_dt,
            expected_refyear=block.refyear,
            n_halfhours=nrow(merged),
            max_abs_diff=max_abs_diff,
            exact_numeric_match=iszero(max_abs_diff),
            pisp_hourly_points=length(pisp_diffs),
            pisp_max_abs_diff=isempty(pisp_diffs) ? missing : maximum(abs.(pisp_diffs)),
            pisp_exact_numeric_match=isempty(pisp_diffs) ? missing : iszero(maximum(abs.(pisp_diffs))),
        ))
    end
    DataFrame(rows)
end

function region_output_dir(region::AbstractString, year::Integer, trace_kind::AbstractString;
        output_root::AbstractString=DEFAULT_OUTPUT_ROOT, scenario_file::AbstractString=DEFAULT_SCENARIO_FILE)
    joinpath(output_root, "$(region)_$(scenario_file)_$(trace_kind)_calendar$(year)")
end

function build_aemo_switch_plot(region::AbstractString, scenario_file::AbstractString, trace_kind::AbstractString,
        switch_window, switch_slice::DataFrame; output_html::Union{Nothing,AbstractString}=nothing)
    HAS_PLOTLYJS || error(
        "PlotlyJS.jl is required for this script. Install it with " *
        "`julia --project -e 'using Pkg; Pkg.add(\"PlotlyJS\")'` and rerun."
    )

    traces = PlotlyJS.GenericTrace[]
    plot_df = unique(select(switch_slice, Not([:expected_refyear, :expected_value, :diff_4006_vs_expected,
        :expected_hourly_from_trace, :diff_pisp_vs_expected_hourly])))
    sort!(plot_df, :datetime)

    push!(traces, PlotlyJS.scatter(
        x=plot_df.datetime,
        y=plot_df.value_4006,
        mode="lines",
        name="AEMO 4006",
        line=PlotlyJS.attr(color="#1f77b4", width=2.1),
        hovertemplate="AEMO 4006<br>%{x|%Y-%m-%d %H:%M}<br>%{y:.4f}<extra></extra>",
    ))

    refyear_columns = sort(filter(name -> startswith(String(name), "value_refyear_"), names(plot_df)); by=name -> parse(Int, split(String(name), "_")[end]))
    palette = ["#d62728", "#2ca02c", "#9467bd", "#8c564b", "#e377c2", "#17becf"]

    for (idx, col) in enumerate(refyear_columns)
        refyear = parse(Int, split(String(col), "_")[end])
        push!(traces, PlotlyJS.scatter(
            x=plot_df.datetime,
            y=plot_df[!, col],
            mode="lines",
            name="AEMO $(refyear)",
            line=PlotlyJS.attr(color=palette[mod1(idx, length(palette))], width=1.5),
            hovertemplate="AEMO $(refyear)<br>%{x|%Y-%m-%d %H:%M}<br>%{y:.4f}<extra></extra>",
        ))
    end

    if hasproperty(plot_df, :pisp_demand_load_sched)
        pisp_df = filter(row -> !ismissing(row.pisp_demand_load_sched), plot_df)
        if !isempty(pisp_df)
            pisp_df = unique(select(pisp_df, :datetime, :pisp_demand_load_sched))
            sort!(pisp_df, :datetime)
            push!(traces, PlotlyJS.scatter(
                x=pisp_df.datetime,
                y=pisp_df.pisp_demand_load_sched,
                mode="lines+markers",
                name="PISP Demand_load_sched",
                line=PlotlyJS.attr(color="#ff7f0e", width=1.8),
                marker=PlotlyJS.attr(size=6),
                hovertemplate="PISP Demand_load_sched<br>%{x|%Y-%m-%d %H:%M}<br>%{y:.4f}<extra></extra>",
            ))
        end
    end

    switch_dt = DateTime(switch_window.switch_date)
    layout = PlotlyJS.Layout(
        template="plotly_white",
        width=1450,
        height=720,
        hovermode="x unified",
        title_text="AEMO trace check: $(region) $(scenario_file) $(trace_kind) around 4006 switch $(switch_window.previous_refyear) -> $(switch_window.next_refyear)",
        xaxis=PlotlyJS.attr(title="Datetime"),
        yaxis=PlotlyJS.attr(title="Value"),
        legend=PlotlyJS.attr(orientation="h", x=0.0, y=1.05, xanchor="left", yanchor="bottom"),
        shapes=[
            PlotlyJS.attr(
                type="line",
                x0=switch_dt,
                x1=switch_dt,
                y0=0,
                y1=1,
                xref="x",
                yref="paper",
                line=PlotlyJS.attr(color="#444444", width=1, dash="dash"),
            ),
        ],
        annotations=[
            PlotlyJS.attr(
                x=switch_dt,
                y=1.02,
                xref="x",
                yref="paper",
                text="switch to $(switch_window.next_refyear)",
                showarrow=false,
            ),
        ],
    )

    fig = PlotlyJS.plot(traces, layout)
    if output_html !== nothing
        mkpath(dirname(output_html))
        PlotlyJS.savefig(fig, output_html)
        println("AEMO switch-window plot written to $(output_html)")
    end

    fig
end

function build_pisp_switch_plot(region::AbstractString, scenario_file::AbstractString, trace_kind::AbstractString,
        switch_window, switch_slice::DataFrame; output_html::Union{Nothing,AbstractString}=nothing)
    HAS_PLOTLYJS || error(
        "PlotlyJS.jl is required for this script. Install it with " *
        "`julia --project -e 'using Pkg; Pkg.add(\"PlotlyJS\")'` and rerun."
    )

    hasproperty(switch_slice, :pisp_demand_load_sched) || return nothing
    hourly_slice = filter(row -> !ismissing(row.expected_hourly_from_trace) || !ismissing(row.pisp_demand_load_sched), switch_slice)
    isempty(hourly_slice) && return nothing
    hourly_slice = unique(select(hourly_slice, :datetime, :expected_hourly_from_trace, :pisp_demand_load_sched, :diff_pisp_vs_expected_hourly))
    sort!(hourly_slice, :datetime)
    switch_dt = DateTime(switch_window.switch_date)

    traces = [
        PlotlyJS.scatter(
            x=hourly_slice.datetime,
            y=hourly_slice.expected_hourly_from_trace,
            mode="lines",
            name="Expected hourly from AEMO 4006",
            line=PlotlyJS.attr(color="#1f77b4", width=2.0),
            hovertemplate="Expected hourly from AEMO 4006<br>%{x|%Y-%m-%d %H:%M}<br>%{y:.4f}<extra></extra>",
        ),
        PlotlyJS.scatter(
            x=hourly_slice.datetime,
            y=hourly_slice.pisp_demand_load_sched,
            mode="lines+markers",
            name="PISP Demand_load_sched",
            line=PlotlyJS.attr(color="#ff7f0e", width=1.8),
            marker=PlotlyJS.attr(size=6),
            hovertemplate="PISP Demand_load_sched<br>%{x|%Y-%m-%d %H:%M}<br>%{y:.4f}<extra></extra>",
        ),
    ]

    layout = PlotlyJS.Layout(
        template="plotly_white",
        width=1450,
        height=680,
        hovermode="x unified",
        title_text="PISP hourly check: $(region) $(scenario_file) $(trace_kind) around 4006 switch $(switch_window.previous_refyear) -> $(switch_window.next_refyear)",
        xaxis=PlotlyJS.attr(title="Datetime"),
        yaxis=PlotlyJS.attr(title="Hourly value"),
        legend=PlotlyJS.attr(orientation="h", x=0.0, y=1.05, xanchor="left", yanchor="bottom"),
        shapes=[
            PlotlyJS.attr(
                type="line",
                x0=switch_dt,
                x1=switch_dt,
                y0=0,
                y1=1,
                xref="x",
                yref="paper",
                line=PlotlyJS.attr(color="#444444", width=1, dash="dash"),
            ),
        ],
        annotations=[
            PlotlyJS.attr(
                x=switch_dt,
                y=1.02,
                xref="x",
                yref="paper",
                text="switch to $(switch_window.next_refyear)",
                showarrow=false,
            ),
        ],
    )

    fig = PlotlyJS.plot(traces, layout)
    if output_html !== nothing
        mkpath(dirname(output_html))
        PlotlyJS.savefig(fig, output_html)
        println("PISP switch-window plot written to $(output_html)")
    end

    fig
end

function write_weekly_slices(output_dir::AbstractString, trace_kind::AbstractString, df4006::DataFrame,
        source_traces::Dict{Int,DataFrame}, blocks, weekly_windows; pisp_hourly::Union{Nothing,DataFrame}=nothing)
    slice_paths = String[]
    for window in weekly_windows
        slice_df = compare_long_window(df4006, source_traces, blocks, window.start_dt, window.end_dt; pisp_hourly=pisp_hourly)
        path = joinpath(output_dir, "$(trace_kind)_$(window.label).csv")
        CSV.write(path, slice_df)
        push!(slice_paths, path)
    end
    slice_paths
end

function run_region_trace_4006_sanity(year::Integer; region::AbstractString, id_dem::Integer,
        trace_kind::AbstractString=DEFAULT_TRACE_KIND, traces_root::AbstractString=DEFAULT_TRACES_ROOT,
        pisp_output_root::AbstractString=DEFAULT_PISP_OUTPUT_ROOT, output_root::AbstractString=DEFAULT_OUTPUT_ROOT,
        scenario_file::AbstractString=DEFAULT_SCENARIO_FILE, scenario_dir::AbstractString=scenario_dir_name(DEFAULT_SCENARIO_FILE),
        pisp_scenario::Integer=DEFAULT_PISP_SCENARIO, poe::Integer=DEFAULT_POE,
        synthetic_refyear::Integer=DEFAULT_SYNTHETIC_REFYEAR, blocks=nothing, weekly_windows=nothing,
        switch_windows=nothing, switch_days_before::Integer=DEFAULT_SWITCH_DAYS_BEFORE,
        switch_days_after::Integer=DEFAULT_SWITCH_DAYS_AFTER)
    region = uppercase(String(region))
    active_blocks = isnothing(blocks) ? calendar_year_blocks(year) : [normalize_block(block) for block in blocks]
    isempty(active_blocks) && error("No DATE_RANGES_REFYEARS blocks overlap calendar year $(year)")
    active_blocks = sort!(active_blocks; by=block -> block.start_date)
    refyears = sort!(unique(getproperty.(active_blocks, :refyear)))

    df4006 = load_trace_long(synthetic_refyear, trace_kind; traces_root=traces_root, region=region,
        scenario_file=scenario_file, scenario_dir=scenario_dir, poe=poe)
    source_traces = Dict(
        refyear => load_trace_long(refyear, trace_kind; traces_root=traces_root, region=region,
            scenario_file=scenario_file, scenario_dir=scenario_dir, poe=poe)
        for refyear in refyears
    )

    pisp_hourly = trace_kind == "OPSO_MODELLING_PVLITE" ?
        load_pisp_demand_schedule(year; output_root=pisp_output_root, id_dem=id_dem, scenario=pisp_scenario) : nothing

    weekly_windows = isnothing(weekly_windows) ? build_weekly_windows(active_blocks) : collect(weekly_windows)
    switch_windows = isnothing(switch_windows) ? build_switch_windows(active_blocks;
        days_before=switch_days_before, days_after=switch_days_after) : collect(switch_windows)

    output_dir = region_output_dir(region, year, trace_kind; output_root=output_root, scenario_file=scenario_file)
    mkpath(output_dir)

    block_map_df = block_mapping_dataframe(active_blocks)
    block_map_path = joinpath(output_dir, "calendar_year_block_map.csv")
    CSV.write(block_map_path, block_map_df)

    summary_df = summary_dataframe(trace_kind, year, active_blocks, df4006, source_traces; pisp_hourly=pisp_hourly)
    summary_path = joinpath(output_dir, "$(trace_kind)_summary.csv")
    CSV.write(summary_path, summary_df)

    weekly_slice_paths = write_weekly_slices(output_dir, trace_kind, df4006, source_traces, active_blocks, weekly_windows; pisp_hourly=pisp_hourly)

    switch_results = NamedTuple[]
    for window in switch_windows
        switch_slice = compare_long_window(df4006, source_traces, active_blocks, window.start_dt, window.end_dt; pisp_hourly=pisp_hourly)
        switch_csv_path = joinpath(output_dir, "$(trace_kind)_$(window.label).csv")
        CSV.write(switch_csv_path, switch_slice)

        aemo_plot_path = joinpath(output_dir, "$(trace_kind)_$(window.label)_aemo.html")
        aemo_plot = build_aemo_switch_plot(region, scenario_file, trace_kind, window, switch_slice; output_html=aemo_plot_path)

        pisp_plot_path = trace_kind == "OPSO_MODELLING_PVLITE" ?
            joinpath(output_dir, "$(trace_kind)_$(window.label)_pisp.html") : nothing
        pisp_plot = trace_kind == "OPSO_MODELLING_PVLITE" ?
            build_pisp_switch_plot(region, scenario_file, trace_kind, window, switch_slice; output_html=pisp_plot_path) : nothing

        push!(switch_results, (
            window=window,
            slice=switch_slice,
            slice_path=switch_csv_path,
            aemo_plot=aemo_plot,
            aemo_plot_path=aemo_plot_path,
            pisp_plot=pisp_plot,
            pisp_plot_path=pisp_plot_path,
        ))
    end

    println("Wrote 4006 sanity outputs for $(region) calendar year $(year) to $(output_dir)")
    println(summary_df)

    (
        region=region,
        id_dem=id_dem,
        year=year,
        trace_kind=trace_kind,
        refyears=refyears,
        block_map=block_map_df,
        block_map_path=block_map_path,
        summary=summary_df,
        summary_path=summary_path,
        weekly_windows=weekly_windows,
        weekly_slice_paths=weekly_slice_paths,
        switch_windows=switch_windows,
        switch_results=switch_results,
        output_dir=output_dir,
    )
end

function main(year::Integer=2030, regions::AbstractVector{<:AbstractString}=["TAS"], id_dems::AbstractVector{<:Integer}=[10];
        trace_kind::AbstractString=DEFAULT_TRACE_KIND, traces_root::AbstractString=DEFAULT_TRACES_ROOT,
        pisp_output_root::AbstractString=DEFAULT_PISP_OUTPUT_ROOT, output_root::AbstractString=DEFAULT_OUTPUT_ROOT,
        scenario_file::AbstractString=DEFAULT_SCENARIO_FILE, scenario_dir::AbstractString=scenario_dir_name(scenario_file),
        pisp_scenario::Integer=DEFAULT_PISP_SCENARIO, poe::Integer=DEFAULT_POE,
        synthetic_refyear::Integer=DEFAULT_SYNTHETIC_REFYEAR, blocks=nothing, weekly_windows=nothing,
        switch_windows=nothing, switch_days_before::Integer=DEFAULT_SWITCH_DAYS_BEFORE,
        switch_days_after::Integer=DEFAULT_SWITCH_DAYS_AFTER, display_plots::Bool=true)
    length(regions) == length(id_dems) || error("`regions` and `id_dems` must have the same length")

    results = Dict{String,Any}()
    for (region, id_dem) in zip(regions, id_dems)
        result = run_region_trace_4006_sanity(year; region=region, id_dem=Int(id_dem), trace_kind=trace_kind,
            traces_root=traces_root, pisp_output_root=pisp_output_root, output_root=output_root,
            scenario_file=scenario_file, scenario_dir=scenario_dir, pisp_scenario=pisp_scenario,
            poe=poe, synthetic_refyear=synthetic_refyear, blocks=blocks, weekly_windows=weekly_windows,
            switch_windows=switch_windows, switch_days_before=switch_days_before, switch_days_after=switch_days_after)
        results[String(region)] = result

        if display_plots
            for switch_result in result.switch_results
                display(switch_result.aemo_plot)
                if switch_result.pisp_plot !== nothing
                    display(switch_result.pisp_plot)
                end
            end
        end
    end

    results
end

# Example execution from the Julia REPL:
# include("src/main/trace-4006-full-sanity-check.jl")
#
# SNW example for calendar year 2030:
snw_results = main(2030, ["SNW"], [7])

# TAS example for calendar year 2030:
tas_results = main(2030, ["TAS"], [10])

# VIC example for calendar year 2031:
vic_results = main(2031, ["VIC"], [9])
