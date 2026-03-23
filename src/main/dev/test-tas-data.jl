using CSV
using DataFrames
using Dates

const DEFAULT_OUTPUT_ROOT = normpath("/Volumes/Seagate/CSIRO AR-PST Stage 5/PISP-outputs", "out-ref4006-poe10", "csv")
const DEFAULT_PLOT_DIR    = normpath("/Volumes/Seagate/CSIRO AR-PST Stage 5/PISP-outputs", "out-ref4006-poe10", "plots")
const DEFAULT_YEAR        = 2030
const DEFAULT_SCENARIO    = 1

const HAS_PLOTLYJS = let
    try
        @eval using PlotlyJS
        true
    catch
        false
    end
end

function demand_path(output_root::AbstractString=DEFAULT_OUTPUT_ROOT)
    joinpath(output_root, "Demand.csv")
end

function schedule_path(year::Integer; output_root::AbstractString=DEFAULT_OUTPUT_ROOT)
    joinpath(output_root, "schedule-$(year)", "Demand_load_sched.csv")
end

function default_html_output(year::Integer, scenario::Integer; output_dir::AbstractString=DEFAULT_PLOT_DIR)
    joinpath(output_dir, "Demand_load_sched_$(year)_scenario$(scenario).html")
end

function axis_key(prefix::AbstractString, index::Integer)
    Symbol(index == 1 ? prefix : "$(prefix)$(index)")
end

function load_demand_metadata(output_root::AbstractString=DEFAULT_OUTPUT_ROOT)
    path = demand_path(output_root)
    isfile(path) || error("Demand metadata file not found: $(path)")

    demand_df = CSV.read(path, DataFrame; types=Dict(:id_dem => Int, :name => String))
    select!(demand_df, :id_dem, :name)
    sort!(unique!(demand_df), :id_dem)
    demand_df
end

function load_demand_schedule(year::Integer; output_root::AbstractString=DEFAULT_OUTPUT_ROOT)
    path = schedule_path(year; output_root=output_root)
    isfile(path) || error("Demand schedule file not found: $(path)")

    CSV.read(
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
end

function prepare_demand_data(year::Integer; output_root::AbstractString=DEFAULT_OUTPUT_ROOT, demand_ids=nothing)
    demand_df = load_demand_metadata(output_root)
    sched_df = load_demand_schedule(year; output_root=output_root)

    if demand_ids !== nothing
        requested_ids = sort!(unique!(collect(Int.(demand_ids))))
        demand_df = filter(:id_dem => in(requested_ids), demand_df)
        sched_df = filter(:id_dem => in(requested_ids), sched_df)
        isempty(demand_df) && error("No demands matched the requested id_dem values: $(requested_ids)")
    end

    merged_df = innerjoin(sched_df, demand_df; on=:id_dem)
    isempty(merged_df) && error("No schedule rows matched Demand.csv on id_dem for year $(year)")
    sort!(merged_df, [:scenario, :id_dem, :date])

    demand_df, merged_df
end

function build_demand_plot(
    year::Integer=DEFAULT_YEAR;
    scenarios::Union{Nothing,AbstractVector{<:Integer}}=nothing,
    output_root::AbstractString=DEFAULT_OUTPUT_ROOT,
    demand_ids=nothing,
    start_dt::Union{Nothing,DateTime}=nothing,
    end_dt::Union{Nothing,DateTime}=nothing,
    output_html::Union{Nothing,AbstractString}=nothing,
)
    HAS_PLOTLYJS || error(
        "PlotlyJS.jl is required for this script. Install it with " *
        "`julia --project -e 'using Pkg; Pkg.add(\"PlotlyJS\")'` and rerun."
    )

    demand_df, merged_df = prepare_demand_data(year; output_root=output_root, demand_ids=demand_ids)

    if start_dt !== nothing
        merged_df = filter(:date => dt -> dt >= start_dt, merged_df)
    end
    if end_dt !== nothing
        merged_df = filter(:date => dt -> dt <= end_dt, merged_df)
    end
    isempty(merged_df) && error("No schedule rows remain after applying the requested datetime window")

    available_scenarios = sort!(unique(merged_df.scenario))
    selected_scenarios = scenarios === nothing ? collect(available_scenarios) : sort!(unique!(collect(Int.(scenarios))))
    all(sc -> sc in available_scenarios, selected_scenarios) ||
        error("Requested scenarios $(selected_scenarios) are not all available. Available scenarios: $(available_scenarios)")
    merged_df = filter(:scenario => in(selected_scenarios), merged_df)
    default_scenario = first(selected_scenarios)

    n_demands = nrow(demand_df)
    subplot_titles = Matrix{Union{Missing,String}}(missing, 1, n_demands)
    for (row_index, demand_row) in enumerate(eachrow(demand_df))
        subplot_titles[1, row_index] = "$(demand_row.name) (id_dem=$(demand_row.id_dem))"
    end
    palette = [
        "#1f77b4", "#d62728", "#2ca02c", "#ff7f0e", "#9467bd", "#8c564b",
        "#e377c2", "#7f7f7f", "#bcbd22", "#17becf", "#003f5c", "#ffa600",
    ]

    fig = PlotlyJS.make_subplots(
        rows=n_demands,
        cols=1,
        shared_xaxes=true,
        vertical_spacing=max(0.003, 0.05 / max(n_demands, 1)),
        subplot_titles=subplot_titles,
        x_title="Date",
        y_title="MW",
    )

    for sc in selected_scenarios
        sc_df = filter(:scenario => ==(sc), merged_df)
        for (row_index, demand_row) in enumerate(eachrow(demand_df))
            series_df = filter(:id_dem => ==(demand_row.id_dem), sc_df)
            trace = PlotlyJS.scatter(
                x=series_df.date,
                y=series_df.value,
                mode="lines",
                name="$(demand_row.name) (id_dem=$(demand_row.id_dem))",
                legendgroup="id_dem_$(demand_row.id_dem)",
                line=PlotlyJS.attr(color=palette[mod1(row_index, length(palette))], width=1.4),
                visible=sc == default_scenario,
                showlegend=true,
                hovertemplate=
                    "name=$(demand_row.name)<br>" *
                    "id_dem=$(demand_row.id_dem)<br>" *
                    "scenario=$(sc)<br>" *
                    "date=%{x|%Y-%m-%d %H:%M}<br>" *
                    "load=%{y:.2f}<extra></extra>",
            )
            PlotlyJS.add_trace!(fig, trace, row=row_index, col=1)
        end
    end

    trace_count_per_scenario = n_demands
    buttons = [
        PlotlyJS.attr(
            label="Scenario $(sc)",
            method="update",
            args=[
                PlotlyJS.attr(
                    visible=[
                        div(trace_index - 1, trace_count_per_scenario) + 1 == scenario_index
                        for trace_index in 1:(trace_count_per_scenario * length(selected_scenarios))
                    ],
                ),
                PlotlyJS.attr(title_text="Demand load schedule by id_dem, year $(year), scenario $(sc)"),
            ],
        ) for (scenario_index, sc) in enumerate(selected_scenarios)
    ]

    layout_updates = Dict{Symbol,Any}(
        :template => "plotly_white",
        :height => max(900, 240 * n_demands),
        :width => 1400,
        :hovermode => "x",
        :title_text => "Demand load schedule by id_dem, year $(year), scenario $(default_scenario)",
        :margin => PlotlyJS.attr(l=90, r=40, t=90, b=70),
        :legend => PlotlyJS.attr(orientation="h", x=0.0, y=1.04, xanchor="left", yanchor="bottom"),
        :updatemenus => [
            PlotlyJS.attr(
                type="dropdown",
                direction="down",
                x=1.02,
                y=1.01,
                xanchor="left",
                yanchor="top",
                showactive=true,
                buttons=buttons,
            ),
        ],
    )

    PlotlyJS.relayout!(fig, layout_updates)

    if output_html !== nothing
        mkpath(dirname(output_html))
        PlotlyJS.savefig(fig, output_html)
        println("Interactive plot written to $(output_html)")
    end

    fig
end

function main(
    year::Integer=DEFAULT_YEAR,
    scenarios::AbstractVector{<:Integer}=[DEFAULT_SCENARIO],
    id_dems::AbstractVector{<:Integer}=Int[];
    start_dt::Union{Nothing,DateTime}=nothing,
    end_dt::Union{Nothing,DateTime}=nothing,
    output_html::Union{Nothing,AbstractString}=nothing,
    output_root::AbstractString=DEFAULT_OUTPUT_ROOT,
)
    scenario_list = sort!(unique!(collect(Int.(scenarios))))
    isempty(scenario_list) && error("At least one scenario must be provided")
    demand_list = isempty(id_dems) ? nothing : sort!(unique!(collect(Int.(id_dems))))
    html_path = isnothing(output_html) ? default_html_output(year, first(scenario_list)) : output_html

    fig = build_demand_plot(
        year;
        scenarios=scenario_list,
        output_root=output_root,
        demand_ids=demand_list,
        start_dt=start_dt,
        end_dt=end_dt,
        output_html=html_path,
    )
    fig
end

# Example execution from the Julia REPL:
# include("src/main/test-tas-data.jl")
fig = main(
    2030,
    [2],
    [1,2,3,4,5,6,7,8,9,10,11,12];
    start_dt=DateTime(2030, 01, 01),
    end_dt=DateTime(2030, 10, 2, 23, 30),
)
display(fig)
