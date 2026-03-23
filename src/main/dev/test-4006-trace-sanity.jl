using CSV
using DataFrames
using Dates

const DEFAULT_TRACE_ROOT = normpath("/Volumes/Seagate/CSIRO AR-PST Stage 5/PISP-downloads", "Traces", "demand_TAS_Step Change")
const DEFAULT_OUTPUT_DIR = normpath("/Volumes/Seagate/CSIRO AR-PST Stage 5/PISP-outputs", "out-sanity-ref4006-poe10", "sanity-checks")
const DEFAULT_PISP_OUTPUT_ROOT = normpath("/Volumes/Seagate/CSIRO AR-PST Stage 5/PISP-outputs", "out-sanity-ref4006-poe10", "csv")
const DEFAULT_REGION = "TAS"
const DEFAULT_SCENARIO_FILE = "STEP_CHANGE"
const DEFAULT_POE = 10
const DEFAULT_PISP_YEAR = 2030
const DEFAULT_PISP_ID_DEM = 10
const DEFAULT_PISP_SCENARIO = 2
const DEFAULT_TRACE_KINDS = ("OPSO_MODELLING_PVLITE", "PV_TOT")
const COMPARISON_WINDOWS = (
    (label = "2015_block", refyear = 2015, start_date = Date(2029, 7, 1), end_date = Date(2030, 6, 30)),
    (label = "2011_block", refyear = 2011, start_date = Date(2030, 7, 1), end_date = Date(2031, 6, 30)),
)
const WEEKLY_SCREEN_WINDOWS = (
    (label = "week_2029-07-01", start_dt = DateTime(2029, 7, 1), end_dt = DateTime(2029, 7, 7, 23, 30)),
    (label = "week_2030-06-24", start_dt = DateTime(2030, 6, 24), end_dt = DateTime(2030, 6, 30, 23, 30)),
    (label = "week_2030-07-01", start_dt = DateTime(2030, 7, 1), end_dt = DateTime(2030, 7, 7, 23, 30)),
)
const SWITCH_WINDOW = (start_dt = DateTime(2030, 6, 29), end_dt = DateTime(2030, 7, 2, 23, 30))
const SWITCH_DATE = Date(2030, 7, 1)

const HAS_PLOTLYJS = let
    try
        @eval using PlotlyJS
        true
    catch
        false
    end
end

function trace_path(refyear::Integer, trace_kind::AbstractString; root::AbstractString=DEFAULT_TRACE_ROOT,
        region::AbstractString=DEFAULT_REGION, scenario_file::AbstractString=DEFAULT_SCENARIO_FILE, poe::Integer=DEFAULT_POE)
    joinpath(root, "$(region)_RefYear_$(refyear)_$(scenario_file)_POE$(poe)_$(trace_kind).csv")
end

function halfhour_columns(df::DataFrame)
    sort(filter(name -> occursin(r"^\d{2}$", String(name)), names(df)); by=name -> parse(Int, String(name)))
end

function load_trace_wide(refyear::Integer, trace_kind::AbstractString; root::AbstractString=DEFAULT_TRACE_ROOT)
    path = trace_path(refyear, trace_kind; root=root)
    isfile(path) || error("Trace file not found: $(path)")

    df = CSV.read(path, DataFrame)
    df.date = Date.(df.Year, df.Month, df.Day)
    sort!(df, :date)
    df
end

function filter_daily_window(df::DataFrame, start_date::Date, end_date::Date)
    filter(:date => d -> start_date <= d <= end_date, df)
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

function load_trace_long(refyear::Integer, trace_kind::AbstractString; root::AbstractString=DEFAULT_TRACE_ROOT)
    trace_wide_to_long(load_trace_wide(refyear, trace_kind; root=root))
end

function demand_sched_path(year::Integer; output_root::AbstractString=DEFAULT_PISP_OUTPUT_ROOT)
    joinpath(output_root, "schedule-$(year)", "Demand_load_sched.csv")
end

function load_pisp_demand_schedule(; year::Integer=DEFAULT_PISP_YEAR, output_root::AbstractString=DEFAULT_PISP_OUTPUT_ROOT,
        id_dem::Integer=DEFAULT_PISP_ID_DEM, scenario::Integer=DEFAULT_PISP_SCENARIO)
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
    sort!(df, :date)
    rename!(select(df, :date, :value), :date => :datetime, :value => :pisp_demand_load_sched)
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

function compare_long_window(df4006::DataFrame, df2015::DataFrame, df2011::DataFrame, start_dt::DateTime, end_dt::DateTime;
        pisp_hourly::Union{Nothing,DataFrame}=nothing)
    slice_4006 = rename(select_long_window(df4006, start_dt, end_dt), :value => :value_4006)
    slice_2015 = rename(select_long_window(df2015, start_dt, end_dt), :value => :value_2015)
    slice_2011 = rename(select_long_window(df2011, start_dt, end_dt), :value => :value_2011)

    merged = outerjoin(slice_4006, slice_2015, on=:datetime)
    merged = outerjoin(merged, slice_2011, on=:datetime)
    sort!(merged, :datetime)

    merged.expected_refyear = ifelse.(Date.(merged.datetime) .< SWITCH_DATE, 2015, 2011)
    merged.expected_value = Vector{Float64}(undef, nrow(merged))
    for i in 1:nrow(merged)
        merged.expected_value[i] = merged.expected_refyear[i] == 2015 ? merged.value_2015[i] : merged.value_2011[i]
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

function comparison_summary(trace_kind::AbstractString, df4006::DataFrame, df2015::DataFrame, df2011::DataFrame;
        pisp_hourly::Union{Nothing,DataFrame}=nothing)
    rows = NamedTuple[]
    for window in COMPARISON_WINDOWS
        start_dt = DateTime(window.start_date)
        end_dt = DateTime(window.end_date, Time(23, 30))
        merged = compare_long_window(df4006, df2015, df2011, start_dt, end_dt; pisp_hourly=pisp_hourly)
        max_abs_diff = maximum(abs.(merged.diff_4006_vs_expected))
        pisp_diffs = hasproperty(merged, :diff_pisp_vs_expected_hourly) ? collect(skipmissing(merged.diff_pisp_vs_expected_hourly)) : Float64[]
        push!(rows, (
            trace_kind = trace_kind,
            window = window.label,
            expected_refyear = window.refyear,
            start_datetime = start_dt,
            end_datetime = end_dt,
            n_halfhours = nrow(merged),
            max_abs_diff = max_abs_diff,
            exact_numeric_match = iszero(max_abs_diff),
            pisp_hourly_points = length(pisp_diffs),
            pisp_max_abs_diff = isempty(pisp_diffs) ? missing : maximum(abs.(pisp_diffs)),
            pisp_exact_numeric_match = isempty(pisp_diffs) ? missing : iszero(maximum(abs.(pisp_diffs))),
        ))
    end
    DataFrame(rows)
end

function build_aemo_switch_plot(trace_kind::AbstractString, switch_slice::DataFrame; output_html::Union{Nothing,AbstractString}=nothing)
    HAS_PLOTLYJS || error(
        "PlotlyJS.jl is required for this script. Install it with " *
        "`julia --project -e 'using Pkg; Pkg.add(\"PlotlyJS\")'` and rerun."
    )

    plot_df = unique(select(switch_slice, :datetime, :value_4006, :value_2015, :value_2011))
    sort!(plot_df, :datetime)

    traces = [
        PlotlyJS.scatter(
            x=plot_df.datetime,
            y=plot_df.value_4006,
            mode="lines",
            name="AEMO 4006",
            line=PlotlyJS.attr(color="#1f77b4", width=2.0),
            hovertemplate="AEMO 4006<br>%{x|%Y-%m-%d %H:%M}<br>%{y:.4f}<extra></extra>",
        ),
        PlotlyJS.scatter(
            x=plot_df.datetime,
            y=plot_df.value_2015,
            mode="lines",
            name="AEMO 2015",
            line=PlotlyJS.attr(color="#d62728", width=1.5),
            hovertemplate="AEMO 2015<br>%{x|%Y-%m-%d %H:%M}<br>%{y:.4f}<extra></extra>",
        ),
        PlotlyJS.scatter(
            x=plot_df.datetime,
            y=plot_df.value_2011,
            mode="lines",
            name="AEMO 2011",
            line=PlotlyJS.attr(color="#2ca02c", width=1.5),
            hovertemplate="AEMO 2011<br>%{x|%Y-%m-%d %H:%M}<br>%{y:.4f}<extra></extra>",
        ),
    ]

    if hasproperty(switch_slice, :pisp_demand_load_sched)
        pisp_df = filter(row -> !ismissing(row.pisp_demand_load_sched), switch_slice)
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

    layout = PlotlyJS.Layout(
        template="plotly_white",
        width=1400,
        height=700,
        hovermode="x unified",
        title_text="AEMO trace check: TAS STEP_CHANGE $(trace_kind) around 4006 switch",
        xaxis=PlotlyJS.attr(title="Datetime"),
        yaxis=PlotlyJS.attr(title="Value"),
        legend=PlotlyJS.attr(orientation="h", x=0.0, y=1.05, xanchor="left", yanchor="bottom"),
        shapes=[
            PlotlyJS.attr(
                type="line",
                x0=DateTime(2030, 7, 1),
                x1=DateTime(2030, 7, 1),
                y0=0,
                y1=1,
                xref="x",
                yref="paper",
                line=PlotlyJS.attr(color="#444444", width=1, dash="dash"),
            ),
        ],
        annotations=[
            PlotlyJS.attr(
                x=DateTime(2030, 7, 1),
                y=1.02,
                xref="x",
                yref="paper",
                text="switch to 2011",
                showarrow=false,
            ),
        ],
    )

    fig = PlotlyJS.plot(traces, layout)
    if output_html !== nothing
        mkpath(dirname(output_html))
        PlotlyJS.savefig(fig, output_html)
        println("Switch-window plot written to $(output_html)")
    end

    fig
end

function build_pisp_switch_plot(trace_kind::AbstractString, switch_slice::DataFrame; output_html::Union{Nothing,AbstractString}=nothing)
    HAS_PLOTLYJS || error(
        "PlotlyJS.jl is required for this script. Install it with " *
        "`julia --project -e 'using Pkg; Pkg.add(\"PlotlyJS\")'` and rerun."
    )

    hasproperty(switch_slice, :pisp_demand_load_sched) || return nothing
    hourly_slice = filter(row -> !ismissing(row.expected_hourly_from_trace) || !ismissing(row.pisp_demand_load_sched), switch_slice)
    isempty(hourly_slice) && return nothing
    hourly_slice = unique(select(hourly_slice, :datetime, :expected_hourly_from_trace, :pisp_demand_load_sched, :diff_pisp_vs_expected_hourly))
    sort!(hourly_slice, :datetime)

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
        width=1400,
        height=650,
        hovermode="x unified",
        title_text="PISP hourly check: TAS STEP_CHANGE $(trace_kind) against AEMO-derived hourly expectation",
        xaxis=PlotlyJS.attr(title="Datetime"),
        yaxis=PlotlyJS.attr(title="Hourly value"),
        legend=PlotlyJS.attr(orientation="h", x=0.0, y=1.05, xanchor="left", yanchor="bottom"),
        shapes=[
            PlotlyJS.attr(
                type="line",
                x0=DateTime(2030, 7, 1),
                x1=DateTime(2030, 7, 1),
                y0=0,
                y1=1,
                xref="x",
                yref="paper",
                line=PlotlyJS.attr(color="#444444", width=1, dash="dash"),
            ),
        ],
        annotations=[
            PlotlyJS.attr(
                x=DateTime(2030, 7, 1),
                y=1.02,
                xref="x",
                yref="paper",
                text="switch to 2011",
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

function write_slice_csvs(trace_kind::AbstractString, df4006::DataFrame, df2015::DataFrame, df2011::DataFrame;
        output_dir::AbstractString=DEFAULT_OUTPUT_DIR, pisp_hourly::Union{Nothing,DataFrame}=nothing)
    mkpath(output_dir)
    slice_paths = String[]
    for window in WEEKLY_SCREEN_WINDOWS
        slice_df = compare_long_window(df4006, df2015, df2011, window.start_dt, window.end_dt; pisp_hourly=pisp_hourly)
        path = joinpath(output_dir, "$(trace_kind)_$(window.label).csv")
        CSV.write(path, slice_df)
        push!(slice_paths, path)
    end
    slice_paths
end

function run_trace_sanity(trace_kind::AbstractString; root::AbstractString=DEFAULT_TRACE_ROOT,
        output_dir::AbstractString=DEFAULT_OUTPUT_DIR)
    df4006 = load_trace_long(4006, trace_kind; root=root)
    df2015 = load_trace_long(2015, trace_kind; root=root)
    df2011 = load_trace_long(2011, trace_kind; root=root)
    pisp_hourly = trace_kind == "OPSO_MODELLING_PVLITE" ? load_pisp_demand_schedule() : nothing

    summary_df = comparison_summary(trace_kind, df4006, df2015, df2011; pisp_hourly=pisp_hourly)
    summary_path = joinpath(output_dir, "$(trace_kind)_summary.csv")
    mkpath(output_dir)
    CSV.write(summary_path, summary_df)

    weekly_slice_paths = write_slice_csvs(trace_kind, df4006, df2015, df2011; output_dir=output_dir, pisp_hourly=pisp_hourly)

    switch_slice = compare_long_window(df4006, df2015, df2011, SWITCH_WINDOW.start_dt, SWITCH_WINDOW.end_dt; pisp_hourly=pisp_hourly)
    switch_slice_path = joinpath(output_dir, "$(trace_kind)_switch_window.csv")
    CSV.write(switch_slice_path, switch_slice)

    aemo_plot_path = joinpath(output_dir, "$(trace_kind)_switch_window_aemo.html")
    aemo_plot = build_aemo_switch_plot(trace_kind, switch_slice; output_html=aemo_plot_path)

    pisp_plot_path = trace_kind == "OPSO_MODELLING_PVLITE" ?
        joinpath(output_dir, "$(trace_kind)_switch_window_pisp.html") : nothing
    pisp_plot = trace_kind == "OPSO_MODELLING_PVLITE" ?
        build_pisp_switch_plot(trace_kind, switch_slice; output_html=pisp_plot_path) : nothing

    println(summary_df)
    return (
        trace_kind = trace_kind,
        summary = summary_df,
        summary_path = summary_path,
        weekly_slice_paths = weekly_slice_paths,
        switch_slice = switch_slice,
        switch_slice_path = switch_slice_path,
        plot = aemo_plot,
        plot_path = aemo_plot_path,
        aemo_plot = aemo_plot,
        aemo_plot_path = aemo_plot_path,
        pisp_plot = pisp_plot,
        pisp_plot_path = pisp_plot_path,
    )
end

function main(; trace_kinds::AbstractVector{<:AbstractString}=collect(DEFAULT_TRACE_KINDS),
        root::AbstractString=DEFAULT_TRACE_ROOT,
        output_dir::AbstractString=DEFAULT_OUTPUT_DIR)
    Dict(kind => run_trace_sanity(kind; root=root, output_dir=output_dir) for kind in trace_kinds)
end

function run_and_display(; trace_kinds::AbstractVector{<:AbstractString}=collect(DEFAULT_TRACE_KINDS),
        root::AbstractString=DEFAULT_TRACE_ROOT,
        output_dir::AbstractString=DEFAULT_OUTPUT_DIR)
    results = main(; trace_kinds=trace_kinds, root=root, output_dir=output_dir)
    for kind in trace_kinds
        display(results[String(kind)].aemo_plot)
        if !isnothing(results[String(kind)].pisp_plot)
            display(results[String(kind)].pisp_plot)
        end
    end
    results
end

run_and_display()
