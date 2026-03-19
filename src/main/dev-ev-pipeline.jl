using DataFrames
using Dates
using OrderedCollections
using XLSX
using PISP
using CSV
# =============================== #
# Data from other PISP elements
years        = [2030,2031,2032]
scenarios    = [1,2,3]
reftrace     = 2011
poe          = 10
downloadpath = normpath("/Users/papablaza/git/ARPST-CSIRO-STAGE-5/PISP-dev-pub.jl/data/PISP-downloads")
data_paths   = PISP.default_data_paths(filepath=downloadpath)

tc, ts, tv = nothing, nothing, nothing # Just handling this as a placeholder here to avoid warnings about unused variables, the actual structures are created and populated in the loop below
for year in years
    tc, ts, tv = PISP.initialise_time_structures()
    PISP.fill_problem_table_year(tc, year, sce=scenarios)
    static_params = PISP.populate_time_static!(ts, tv, data_paths; refyear = reftrace, poe = poe)
    @info "Populating time-varying data from ISP 2024 - POE $(poe) - reference weather trace $(reftrace) - planning year $(year) ..."
    PISP.populate_time_varying!(tc, ts, tv, data_paths, static_params; refyear = reftrace, poe = poe)
end

# =============================== #

ev_workbook_path   = "/Users/papablaza/git/ARPST-CSIRO-STAGE-5/PISP-dev-pub.jl/data/PISP-downloads/2023-iasr-ev-workbook.xlsx"
iasr_workbook_path = "/Users/papablaza/git/ARPST-CSIRO-STAGE-5/PISP-dev-pub.jl/data/PISP-downloads/2024-isp-inputs-and-assumptions-workbook.xlsx"

const BEV_PHEV_PROFILE_WEEKEND_SHEET = "BEV_PHEV_Profile_kW (Weekend)"
const BEV_PHEV_PROFILE_WEEKDAY_SHEET = "BEV_PHEV_Profile_kW (Weekday)"
const BEV_PHEV_CHARGE_TYPE_SHEET     = "BEV_PHEV_Charge_Type (%)"
const VEHICLE_NUMBERS_SHEET_SUFFIX   = "_Numbers"
const SUBREGIONAL_DEMAND_ALLOCATION_SHEET = "Sub-regional demand allocation"
const VEHICLE_NUMBER_VALUE_COLUMN_BY_SHEET = OrderedDict(
    "BEV_Numbers" => :number_bev,
    "PHEV_Numbers" => :number_phev,
    "FCEV_Numbers" => :number_fcev,
    "ICE_Numbers" => :number_ice,
)

include(joinpath(dirname(@__DIR__), "parameters", "general2024ISP.jl"))

const STATE_CODE_BY_NAME        = Dict(state_name => state_code for (state_code, state_name) in NEMAREAS)
const SCENARIO_ID_BY_NAME       = Dict(scenario_name => scenario_id for (scenario_name, scenario_id) in SCE)
const VEHICLE_CATEGORY_BY_TYPE  = Dict(
                                            "Articulated Truck"       => "Buses and Trucks",
                                            "Bus"                     => "Buses and Trucks",
                                            "Large Light Commercial"  => "Commercial",
                                            "Large Residential"       => "Residential",
                                            "Medium Light Commercial" => "Commercial",
                                            "Medium Residential"      => "Residential",
                                            "Motorcycle"              => "Residential",
                                            "Rigid Truck"             => "Buses and Trucks",
                                            "Small Light Commercial"  => "Commercial",
                                            "Small Residential"       => "Residential",
)

is_blank_cell(value) = ismissing(value) || (value isa AbstractString && isempty(strip(value)))

function is_blank_row(row)
    return all(is_blank_cell, row)
end

is_singleton_label_row(row) = !is_blank_cell(row[1]) && all(is_blank_cell, row[2:end])
singleton_label(row) = strip(String(row[1]))
nonblank_indices(values) = findall(value -> !is_blank_cell(value), values)

function read_non_empty_rows(workbook_path::AbstractString, sheet_name::AbstractString, range_ref::AbstractString)
    raw_sheet = XLSX.readdata(workbook_path, sheet_name, range_ref)
    return [collect(raw_sheet[row_index, :]) for row_index in axes(raw_sheet, 1) if !is_blank_row(raw_sheet[row_index, :])]
end

function ensure_columns!(columns::Dict{Symbol, Vector}, column_order::Vector{Symbol}, new_columns::Vector{Symbol}, factory::Function)
    for column in new_columns
        if !haskey(columns, column)
            columns[column] = factory()
            push!(column_order, column)
        end
    end
end

dataframe_from_columns(column_order::Vector{Symbol}, columns::Dict{Symbol, Vector}) =
    DataFrame([column => columns[column] for column in column_order])

function is_state_header_row(row)
    if !is_singleton_label_row(row)
        return false
    end

    return haskey(STATE_CODE_BY_NAME, singleton_label(row))
end

function is_time_header_row(row)
    first_cell_is_blank = is_blank_cell(row[1])
    later_cells = row[2:end]
    has_time_cells = any(value -> !is_blank_cell(value), later_cells)
    all_time_cells = all(value -> is_blank_cell(value) || value isa Time, later_cells)
    return first_cell_is_blank && has_time_cells && all_time_cells
end

function split_profile_label(label::AbstractString)
    pieces = split(strip(label), ","; limit = 2)
    vehicle_type = strip(first(pieces))
    charging_profile = length(pieces) == 2 ? strip(pieces[2]) : ""
    charging_profile = replace(charging_profile, r"\s*-\s*vehicle charging$" => "")
    return vehicle_type, charging_profile
end

function time_column_name(value::Time)
    return Symbol(Dates.format(value, "HH_MM"))
end

function map_state_name_to_code(state_name::AbstractString)
    state_code = get(STATE_CODE_BY_NAME, state_name, nothing)
    state_code === nothing && error("State `$state_name` was not found in NEMAREAS.")
    return state_code
end

function normalize_numbers_state_name(state_name::AbstractString)
    return strip(replace(state_name, r"\s*\(includes ACT\)$" => ""))
end

function is_numbers_header_row(row)
    if is_blank_cell(row[1]) || strip(String(row[1])) != "Vehicle Type"
        return false
    end

    return any(value -> !is_blank_cell(value), row[2:end])
end

function is_year_only_header_row(row)
    if !is_blank_cell(row[1])
        return false
    end

    later_cells = row[2:end]
    has_year_cells = any(value -> !is_blank_cell(value), later_cells)
    all_year_cells = all(value ->
        is_blank_cell(value) || (
            value isa AbstractString &&
            occursin(r"^\d{4}-\d{2}$", strip(value))
        ),
        later_cells,
    )

    return has_year_cells && all_year_cells
end

function year_column_name(value)
    return Symbol(replace(strip(String(value)), "-" => "_"))
end

function parse_year_header(row)
    indices = nonblank_indices(row[2:end])
    labels = [replace(strip(String(row[index + 1])), "-" => "_") for index in indices]
    return indices, labels
end

function map_vehicle_type_to_category(vehicle_type::AbstractString)
    category = get(VEHICLE_CATEGORY_BY_TYPE, vehicle_type, nothing)
    category === nothing && error("Vehicle type `$vehicle_type` was not found in VEHICLE_CATEGORY_BY_TYPE.")
    return category
end

function split_charge_type_label(label::AbstractString)
    pieces = split(strip(label), "-"; limit = 2)
    category = strip(first(pieces))
    charging = length(pieces) == 2 ? strip(pieces[2]) : ""
    return category, charging
end

function extract_subregion_code(label::AbstractString)
    match_result = match(r"\(([^)]+)\)\s*$", strip(label))
    return isnothing(match_result) ? strip(label) : strip(only(match_result.captures))
end

function melt_year_columns_dataframe(df::DataFrame, id_columns::Vector{Symbol}, value_name::Symbol; row_filter::Union{Nothing, Function} = nothing)
    year_columns = filter(name -> occursin(r"^\d{4}_\d{2}$", String(name)), names(df))
    long_df = stack(df, year_columns; variable_name = :year, value_name = value_name)
    long_df.year = String.(long_df.year)

    if !isnothing(row_filter)
        long_df = filter(row_filter, long_df)
    end

    return long_df[:, [id_columns..., :year, value_name]]
end

function build_bev_phev_profile_dataframe(workbook_path::AbstractString, sheet_name::AbstractString; day_type::AbstractString)
    non_empty_rows = read_non_empty_rows(workbook_path, sheet_name, "B:AY")

    current_state = nothing
    profile_time_indices = Int[]
    profile_time_columns = Symbol[]

    column_order = Symbol[:state, :vehicle_type, :charging_profile, :day_type]
    columns = Dict{Symbol, Vector}(
        :state => String[],
        :vehicle_type => String[],
        :charging_profile => String[],
        :day_type => String[],
    )

    for row in non_empty_rows
        if is_state_header_row(row)
            current_state = map_state_name_to_code(singleton_label(row))
            continue
        end

        if is_time_header_row(row)
            profile_time_indices = nonblank_indices(row[2:end])
            profile_time_columns = [time_column_name(row[index + 1]) for index in profile_time_indices]

            if isempty(profile_time_indices)
                error("No half-hour columns were found in sheet `$sheet_name`.")
            end

            ensure_columns!(columns, column_order, profile_time_columns, () -> Vector{Union{Missing, Float64}}())

            continue
        end

        if current_state === nothing || isempty(profile_time_indices) || is_blank_cell(row[1])
            continue
        end

        label = strip(String(row[1]))
        vehicle_type, charging_profile = split_profile_label(label)

        push!(columns[:state], current_state)
        push!(columns[:vehicle_type], vehicle_type)
        push!(columns[:charging_profile], charging_profile)
        push!(columns[:day_type], day_type)

        for (relative_index, time_column) in zip(profile_time_indices, profile_time_columns)
            value = row[relative_index + 1]
            push!(columns[time_column], ismissing(value) ? missing : Float64(value))
        end
    end

    return dataframe_from_columns(column_order, columns)
end

function build_vehicle_numbers_dataframe(workbook_path::AbstractString, sheet_name::AbstractString)
    non_empty_rows = read_non_empty_rows(workbook_path, sheet_name, "B:AZ")

    current_scenario = nothing
    current_state = nothing
    year_indices = Int[]
    year_columns = Symbol[]

    column_order = Symbol[:scenario, :state, :vehicle_type, :category]
    columns = Dict{Symbol, Vector}(
        :scenario => Int[],
        :state => String[],
        :vehicle_type => String[],
        :category => String[],
    )

    for row in non_empty_rows
        if is_singleton_label_row(row)
            label = singleton_label(row)

            if haskey(SCENARIO_ID_BY_NAME, label)
                current_scenario = SCENARIO_ID_BY_NAME[label]
                current_state = nothing
                continue
            end

            normalized_state_name = normalize_numbers_state_name(label)

            if haskey(STATE_CODE_BY_NAME, normalized_state_name)
                current_state = map_state_name_to_code(normalized_state_name)
                continue
            end

            continue
        end

        if is_numbers_header_row(row)
            year_indices, year_labels = parse_year_header(row)
            year_columns = Symbol.(year_labels)
            ensure_columns!(columns, column_order, year_columns, () -> Int[])

            continue
        end

        if current_scenario === nothing || current_state === nothing || isempty(year_indices) || is_blank_cell(row[1])
            continue
        end

        vehicle_type = strip(String(row[1]))
        category = map_vehicle_type_to_category(vehicle_type)

        push!(columns[:scenario], current_scenario)
        push!(columns[:state], current_state)
        push!(columns[:vehicle_type], vehicle_type)
        push!(columns[:category], category)

        for (relative_index, year_column) in zip(year_indices, year_columns)
            value = row[relative_index + 1]
            push!(columns[year_column], Int(round(Float64(value))))
        end
    end

    return dataframe_from_columns(column_order, columns)
end

function get_vehicle_numbers_sheet_names(workbook_path::AbstractString)
    return XLSX.openxlsx(workbook_path) do workbook
        filter(sheet_name -> endswith(sheet_name, VEHICLE_NUMBERS_SHEET_SUFFIX), XLSX.sheetnames(workbook))
    end
end

function melt_vehicle_numbers_dataframe(df::DataFrame, number_column::Symbol)
    return melt_year_columns_dataframe(df, [:scenario, :state, :vehicle_type, :category], number_column)
end

function build_bev_phev_charge_type_dataframe(workbook_path::AbstractString, sheet_name::AbstractString)
    non_empty_rows = read_non_empty_rows(workbook_path, sheet_name, "B:BF")

    current_state = nothing
    current_scenario = nothing
    year_indices = Int[]
    year_labels = String[]

    columns = Dict{Symbol, Vector}(
        :state => String[],
        :scenario => Int[],
        :category => String[],
        :charging => String[],
        :year => String[],
        :share => Float64[],
    )

    for row in non_empty_rows
        if is_singleton_label_row(row)
            label = singleton_label(row)
            normalized_state_name = normalize_numbers_state_name(label)

            if haskey(STATE_CODE_BY_NAME, normalized_state_name)
                current_state = map_state_name_to_code(normalized_state_name)
                continue
            end

            if haskey(SCENARIO_ID_BY_NAME, label)
                current_scenario = SCENARIO_ID_BY_NAME[label]
                continue
            end

            continue
        end

        if is_year_only_header_row(row)
            year_indices, year_labels = parse_year_header(row)
            continue
        end

        if current_state === nothing || current_scenario === nothing || isempty(year_indices) || is_blank_cell(row[1])
            continue
        end

        category, charging = split_charge_type_label(String(row[1]))

        for (relative_index, year_label) in zip(year_indices, year_labels)
            value = row[relative_index + 1]
            push!(columns[:state], current_state)
            push!(columns[:scenario], current_scenario)
            push!(columns[:category], category)
            push!(columns[:charging], charging)
            push!(columns[:year], year_label)
            push!(columns[:share], Float64(value))
        end
    end

    return DataFrame([
        :state => columns[:state],
        :scenario => columns[:scenario],
        :category => columns[:category],
        :charging => columns[:charging],
        :year => columns[:year],
        :share => columns[:share],
    ])
end

function build_subregional_demand_allocation_dataframe(workbook_path::AbstractString)
    non_empty_rows = read_non_empty_rows(workbook_path, SUBREGIONAL_DEMAND_ALLOCATION_SHEET, "B127:AG182")

    current_scenario = nothing
    current_state = nothing
    year_indices = Int[]
    year_columns = Symbol[]

    column_order = Symbol[:state, :subregion, :scenario]
    columns = Dict{Symbol, Vector}(
        :state => String[],
        :subregion => String[],
        :scenario => Int[],
    )

    for row in non_empty_rows
        if is_singleton_label_row(row)
            label = singleton_label(row)

            if haskey(SCENARIO_ID_BY_NAME, label)
                current_scenario = SCENARIO_ID_BY_NAME[label]
                continue
            end

            continue
        end

        if is_year_only_header_row(row)
            year_indices, year_labels = parse_year_header(row)
            year_columns = Symbol.(year_labels)
            ensure_columns!(columns, column_order, year_columns, () -> Float64[])

            continue
        end

        if is_blank_cell(row[1]) || current_scenario === nothing || isempty(year_indices)
            continue
        end

        label = strip(String(row[1]))
        subregion = extract_subregion_code(label)

        if haskey(NEMAREAS, subregion)
            current_state = map_state_name_to_code(NEMAREAS[subregion])
        end

        current_state === nothing && error("Could not determine state for subregional label `$label`.")

        push!(columns[:state], current_state)
        push!(columns[:subregion], subregion)
        push!(columns[:scenario], current_scenario)

        for (relative_index, year_column) in zip(year_indices, year_columns)
            value = row[relative_index + 1]
            push!(columns[year_column], Float64(value))
        end
    end

    return dataframe_from_columns(column_order, columns)
end

function melt_subregional_demand_allocation_dataframe(df::DataFrame)
    return melt_year_columns_dataframe(
        df,
        [:state, :subregion, :scenario],
        :share;
        row_filter = row ->
            !(row.state == row.subregion && row.share == 1.0 && row.state ∉ ("TAS", "VIC")),
    )
end

# ---------------------------------- #
# EV profiles 
# ---------------------------------- #
bev_phev_profile_weekend_df = build_bev_phev_profile_dataframe(
    ev_workbook_path,
    BEV_PHEV_PROFILE_WEEKEND_SHEET;
    day_type = "Weekend",
)

bev_phev_profile_weekday_df = build_bev_phev_profile_dataframe(
    ev_workbook_path,
    BEV_PHEV_PROFILE_WEEKDAY_SHEET;
    day_type = "Weekday",
)

profiles = vcat(bev_phev_profile_weekend_df, bev_phev_profile_weekday_df)
# ---------------------------------- #
# EV numbers
# ---------------------------------- #
vehicle_numbers_wide_dfs = OrderedDict(
    sheet_name => build_vehicle_numbers_dataframe(ev_workbook_path, sheet_name)
    for sheet_name in get_vehicle_numbers_sheet_names(ev_workbook_path)
)

vehicle_numbers_dfs = OrderedDict(
    sheet_name => melt_vehicle_numbers_dataframe(vehicle_numbers_wide_dfs[sheet_name], number_column)
    for (sheet_name, number_column) in VEHICLE_NUMBER_VALUE_COLUMN_BY_SHEET
)

bev_numbers_df  = vehicle_numbers_dfs["BEV_Numbers"]
phev_numbers_df = vehicle_numbers_dfs["PHEV_Numbers"]
fcev_numbers_df = vehicle_numbers_dfs["FCEV_Numbers"]
ice_numbers_df  = vehicle_numbers_dfs["ICE_Numbers"]

ev_numbers_join_keys = [:scenario, :state, :vehicle_type, :category, :year]
ev_numbers = reduce(
    (left_df, right_df) -> outerjoin(left_df, right_df; on = ev_numbers_join_keys),
    [bev_numbers_df, phev_numbers_df]#, fcev_numbers_df, ice_numbers_df], # Here I'm not including FCEV and ICE into the full number dataframe
)

# ---------------------------------- #
# EV charging type share
# ---------------------------------- #
bev_phev_charge_type_df = build_bev_phev_charge_type_dataframe(
    ev_workbook_path,
    BEV_PHEV_CHARGE_TYPE_SHEET,
)
# ---------------------------------- #
# EV subregional demand allocation
# ---------------------------------- #
subregional_demand_allocation_df = melt_subregional_demand_allocation_dataframe(
    build_subregional_demand_allocation_dataframe(iasr_workbook_path),
)

bus_id_by_name = Dict(row.name => row.id_bus for row in eachrow(ts.bus))
missing_subregions = unique(
    filter(subregion -> !haskey(bus_id_by_name, subregion), subregional_demand_allocation_df.subregion),
)

isempty(missing_subregions) || error(
    "No matching bus found for subregions: $(join(string.(missing_subregions), ", ")).",
)

subregional_demand_allocation_df.id_bus =
    [bus_id_by_name[subregion] for subregion in subregional_demand_allocation_df.subregion]

# ======================================= #
# Implementation of the profile calculation
# ======================================= #
function format_ev_profile_year(date_value::TimeType)
    current_year = year(date_value)

    if month(date_value) <= 6
        return "$(current_year - 1)_$(lpad(string(mod(current_year, 100)), 2, '0'))"
    end

    return "$(current_year)_$(lpad(string(mod(current_year + 1, 100)), 2, '0'))"
end

function collect_ev_data_dates(problem_df::AbstractDataFrame)
    ev_data_dates = String[]
    problem_dates = vcat(collect(problem_df.dstart), collect(problem_df.dend))

    for problem_date in problem_dates
        ismissing(problem_date) && continue
        profile_year = format_ev_profile_year(problem_date)
        profile_year in ev_data_dates || push!(ev_data_dates, profile_year)
    end

    return ev_data_dates
end

ev_data_dates = collect_ev_data_dates(tc.problem)
scenarios     = unique(tc.problem.scenario)

profiles    = profiles
shares      = bev_phev_charge_type_df
numbers     = ev_numbers
subregional = subregional_demand_allocation_df

# Filter profiles, shares, numbers and subregional, for the ev_data_dates and scenaros array
ev_data_years = Set(ev_data_dates)
scenario_ids  = Set(scenarios)

shares      = filter(row -> row.year in ev_data_years && row.scenario in scenario_ids, shares)
numbers     = filter(row -> row.year in ev_data_years && row.scenario in scenario_ids, numbers)
subregional = filter(row -> row.year in ev_data_years && row.scenario in scenario_ids, subregional)
# ======================================= #
# Combine the data into one dataframe
_profiles          = leftjoin(profiles, numbers, on=["state", "vehicle_type"])
_profiles.category = [VEHICLE_CATEGORY_BY_TYPE[string(t)] for t in _profiles.vehicle_type]
_profiles          = leftjoin(_profiles, shares[:, [:state, :category, :charging, :share]], on=[:state, :category, :charging_profile => :charging])
all_stacked = DataFrame()
for sc in scenario_ids
    for date_fy in ev_data_years
        filtered_profiles    = filter(row -> row.year == date_fy && row.scenario == sc, _profiles)
        filtered_subregional = filter(row -> row.year == date_fy && row.scenario == sc, subregional)

        filtered_profiles                     = copy(filtered_profiles)
        filtered_profiles.total_number        = filtered_profiles.number_bev .+ filtered_profiles.number_phev
        filtered_profiles.total_number_share .= filtered_profiles.total_number .* filtered_profiles.share

        profile_start_index = findfirst(==("00_00"), names(filtered_profiles))
        profile_end_index   = findfirst(==("23_30"), names(filtered_profiles))

        if !isnothing(profile_start_index) && !isnothing(profile_end_index) && profile_start_index <= profile_end_index
            leading_columns  = names(filtered_profiles)[1:(profile_start_index - 1)]
            profile_columns  = names(filtered_profiles)[profile_start_index:profile_end_index]
            trailing_columns = names(filtered_profiles)[(profile_end_index + 1):end]
            select!(filtered_profiles, vcat(leading_columns, trailing_columns, profile_columns))
        end

        function get_profile_column_names(df::DataFrame)
            return filter(name -> occursin(r"^\d{2}_\d{2}$", name), names(df))
        end

        profile_column_names = get_profile_column_names(filtered_profiles)

        idxs_weekday = findall(filtered_profiles.day_type .== "Weekday")
        idxs_weekend = findall(filtered_profiles.day_type .== "Weekend")
        total_profiles_weekday       = filtered_profiles[idxs_weekday, profile_column_names] .* filtered_profiles.total_number_share[idxs_weekday]
        total_profiles_weekday.state = filtered_profiles.state[idxs_weekday]
        total_profiles_weekend       = filtered_profiles[idxs_weekend, profile_column_names] .* filtered_profiles.total_number_share[idxs_weekend]
        total_profiles_weekend.state = filtered_profiles.state[idxs_weekend]

        for col in profile_column_names
            if col[end-1:end] == "00"
                total_profiles_weekday[!, col] = (total_profiles_weekday[!, col] .+ total_profiles_weekday[!, string(col[1:end-2], "30")]) ./ 2
                total_profiles_weekend[!, col] = (total_profiles_weekend[!, col] .+ total_profiles_weekend[!, string(col[1:end-2], "30")]) ./ 2
            end
        end
        total_profiles_weekday = total_profiles_weekday[:, Not(profile_column_names[2:2:end])] # Drop the half-hourly columns
        total_profiles_weekend = total_profiles_weekend[:, Not(profile_column_names[2:2:end])] # Drop the half-hourly columns

        # Finally sum up the profiles and assign to each state then subregion for the whole year
        # collect start_dt as the earliest date in tc.problem.dstart

        start_dt  = minimum(tc.problem.dstart)
        end_dt    = maximum(tc.problem.dend)
        all_times = collect(start_dt:Hour(1):end_dt)
        weekday   = dayofweek.(all_times) .<= 5

        final_profiles = DataFrame(date=all_times)
        for region in sort!(unique(subregional.id_bus))
            final_profiles[!, "$region"] = zeros(length(all_times))
        end

        for state in unique(profiles.state)
            weekday_profile = sum(Matrix(total_profiles_weekday[total_profiles_weekday.state .== state, Not(:state)]), dims=1)[:] ./ 1e3 # Convert to MW
            weekend_profile = sum(Matrix(total_profiles_weekend[total_profiles_weekend.state .== state, Not(:state)]), dims=1)[:] ./ 1e3 # Convert to MW

            subregional_shares   = subregional[subregional.state .== state, :share]
            subregional_idxs     = subregional[subregional.state .== state, :id_bus]
            subregional_year_ids = subregional[subregional.state .== state, :year]

            for i in eachindex(all_times)
                t  = all_times[i] # Current timestep (needed to collect the correct share value depending on the financial year)
                fy = format_ev_profile_year(t)

                # this filters the `state` column equal to state variable and `year` column equal to fy
                # order subr_share by unique(string.(subregional_idxs)) via the id_bus column
                subr_share              = subregional[(subregional.state .== state) .& (subregional.year .== fy) .& (subregional.scenario .== sc), :]
                ordered_subregional_ids = parse.(Int64, unique(string.(subregional_idxs)))
                subr_share_order        = indexin(ordered_subregional_ids, subr_share.id_bus)
                any(isnothing, subr_share_order) && error("Could not order subregional shares for state `$state` and year `$fy`.")
                ordered_subr_share = subr_share[Int64.(something.(subr_share_order, 0)), :]

                if weekday[i]
                    final_profiles[i, string.(ordered_subr_share.id_bus)] .= weekday_profile[hour(all_times[i]) + 1] .* ordered_subr_share.share
                else
                    final_profiles[i, string.(ordered_subr_share.id_bus)] .= weekend_profile[hour(all_times[i]) + 1] .* ordered_subr_share.share
                end
            end
        end

        stacked_profiles           = stack(final_profiles, Not(:date), variable_name=:id_bus, value_name=:value)
        stacked_profiles.scenario .= sc
        stacked_profiles.value    .= round.(stacked_profiles.value, digits=3)
        all_stacked = vcat(all_stacked, stacked_profiles)
    end
end
# for all_stacked, add the column `id` at the beginning of the dataframe with unique integer values starting from 1
all_stacked.id = 1:nrow(all_stacked)
select!(all_stacked, [:id, :id_bus, :scenario,  :date, :value])
CSV.write(joinpath(downloadpath, "ev_profiles_test.csv"), all_stacked, header=true)
