using DataFrames
using Dates
using OrderedCollections
using XLSX
using PISP
# =============================== #
# Data from other PISP elements
years = [2030]
scenarios = [2]
reftrace = 2011
poe = 10
downloadpath = normpath("/Users/papablaza/git/ARPST-CSIRO-STAGE-5/PISP-dev-pub.jl/data/PISP-downloads")
data_paths = PISP.default_data_paths(filepath=downloadpath)

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

function is_state_header_row(row)
    if is_blank_cell(row[1]) || !all(is_blank_cell, row[2:end])
        return false
    end

    return haskey(STATE_CODE_BY_NAME, strip(String(row[1])))
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
    vehicle_class = strip(first(pieces))
    charging_profile = length(pieces) == 2 ? strip(pieces[2]) : ""
    return vehicle_class, charging_profile
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

function build_bev_phev_profile_dataframe(workbook_path::AbstractString, sheet_name::AbstractString; day_type::AbstractString)
    raw_sheet = XLSX.readdata(workbook_path, sheet_name, "B:AY")
    non_empty_rows = [collect(raw_sheet[row_index, :]) for row_index in axes(raw_sheet, 1) if !is_blank_row(raw_sheet[row_index, :])]

    current_state = nothing
    profile_time_indices = Int[]
    profile_time_columns = Symbol[]

    column_order = Symbol[:state, :vehicle_class, :charging_profile, :day_type]
    columns = Dict{Symbol, Vector}(
        :state => String[],
        :vehicle_class => String[],
        :charging_profile => String[],
        :day_type => String[],
    )

    for row in non_empty_rows
        if is_state_header_row(row)
            current_state = map_state_name_to_code(String(strip(row[1])))
            continue
        end

        if is_time_header_row(row)
            profile_time_indices = findall(value -> !is_blank_cell(value), row[2:end])
            profile_time_columns = [time_column_name(row[index + 1]) for index in profile_time_indices]

            if isempty(profile_time_indices)
                error("No half-hour columns were found in sheet `$sheet_name`.")
            end

            for time_column in profile_time_columns
                if !haskey(columns, time_column)
                    columns[time_column] = Vector{Union{Missing, Float64}}()
                    push!(column_order, time_column)
                end
            end

            continue
        end

        if current_state === nothing || isempty(profile_time_indices) || is_blank_cell(row[1])
            continue
        end

        label = strip(String(row[1]))
        vehicle_class, charging_profile = split_profile_label(label)

        push!(columns[:state], current_state)
        push!(columns[:vehicle_class], vehicle_class)
        push!(columns[:charging_profile], charging_profile)
        push!(columns[:day_type], day_type)

        for (relative_index, time_column) in zip(profile_time_indices, profile_time_columns)
            value = row[relative_index + 1]
            push!(columns[time_column], ismissing(value) ? missing : Float64(value))
        end
    end

    return DataFrame([column => columns[column] for column in column_order])
end

function build_vehicle_numbers_dataframe(workbook_path::AbstractString, sheet_name::AbstractString)
    raw_sheet = XLSX.readdata(workbook_path, sheet_name, "B:AZ")
    non_empty_rows = [collect(raw_sheet[row_index, :]) for row_index in axes(raw_sheet, 1) if !is_blank_row(raw_sheet[row_index, :])]

    current_scenario = nothing
    current_state = nothing
    year_indices = Int[]
    year_columns = Symbol[]

    column_order = Symbol[:scenario, :state, :type, :category]
    columns = Dict{Symbol, Vector}(
        :scenario => Int[],
        :state => String[],
        :type => String[],
        :category => String[],
    )

    for row in non_empty_rows
        if !is_blank_cell(row[1]) && all(is_blank_cell, row[2:end])
            label = strip(String(row[1]))

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
            year_indices = findall(value -> !is_blank_cell(value), row[2:end])
            year_columns = [year_column_name(row[index + 1]) for index in year_indices]

            for year_column in year_columns
                if !haskey(columns, year_column)
                    columns[year_column] = Int[]
                    push!(column_order, year_column)
                end
            end

            continue
        end

        if current_scenario === nothing || current_state === nothing || isempty(year_indices) || is_blank_cell(row[1])
            continue
        end

        vehicle_type = strip(String(row[1]))
        category = map_vehicle_type_to_category(vehicle_type)

        push!(columns[:scenario], current_scenario)
        push!(columns[:state], current_state)
        push!(columns[:type], vehicle_type)
        push!(columns[:category], category)

        for (relative_index, year_column) in zip(year_indices, year_columns)
            value = row[relative_index + 1]
            push!(columns[year_column], Int(round(Float64(value))))
        end
    end

    return DataFrame([column => columns[column] for column in column_order])
end

function get_vehicle_numbers_sheet_names(workbook_path::AbstractString)
    return XLSX.openxlsx(workbook_path) do workbook
        filter(sheet_name -> endswith(sheet_name, VEHICLE_NUMBERS_SHEET_SUFFIX), XLSX.sheetnames(workbook))
    end
end

function melt_vehicle_numbers_dataframe(df::DataFrame, number_column::Symbol)
    id_columns = [:scenario, :state, :type, :category]
    year_columns = filter(name -> occursin(r"^\d{4}_\d{2}$", String(name)), names(df))

    long_df = stack(
        df,
        year_columns;
        variable_name = :year,
        value_name = number_column,
    )

    long_df.year = String.(long_df.year)
    return long_df[:, [id_columns..., :year, number_column]]
end

function build_bev_phev_charge_type_dataframe(workbook_path::AbstractString, sheet_name::AbstractString)
    raw_sheet = XLSX.readdata(workbook_path, sheet_name, "B:BF")
    non_empty_rows = [collect(raw_sheet[row_index, :]) for row_index in axes(raw_sheet, 1) if !is_blank_row(raw_sheet[row_index, :])]

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
        if !is_blank_cell(row[1]) && all(is_blank_cell, row[2:end])
            label = strip(String(row[1]))
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
            year_indices = findall(value -> !is_blank_cell(value), row[2:end])
            year_labels = [replace(strip(String(row[index + 1])), "-" => "_") for index in year_indices]
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
    raw_sheet = XLSX.readdata(workbook_path, "Sub-regional demand allocation", "B127:AG182")
    non_empty_rows = [collect(raw_sheet[row_index, :]) for row_index in axes(raw_sheet, 1) if !is_blank_row(raw_sheet[row_index, :])]

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
        if !is_blank_cell(row[1]) && all(is_blank_cell, row[2:end])
            label = strip(String(row[1]))

            if haskey(SCENARIO_ID_BY_NAME, label)
                current_scenario = SCENARIO_ID_BY_NAME[label]
                continue
            end

            continue
        end

        if is_year_only_header_row(row)
            year_indices = findall(value -> !is_blank_cell(value), row[2:end])
            year_columns = [year_column_name(row[index + 1]) for index in year_indices]

            for year_column in year_columns
                if !haskey(columns, year_column)
                    columns[year_column] = Float64[]
                    push!(column_order, year_column)
                end
            end

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

    return DataFrame([column => columns[column] for column in column_order])
end

function melt_subregional_demand_allocation_dataframe(df::DataFrame)
    id_columns = [:state, :subregion, :scenario]
    year_columns = filter(name -> occursin(r"^\d{4}_\d{2}$", String(name)), names(df))

    long_df = stack(
        df,
        year_columns;
        variable_name = :year,
        value_name = :share,
    )

    long_df.year = String.(long_df.year)
    filtered_df = filter(row ->
        !(row.state == row.subregion && row.share == 1.0 && row.state ∉ ("TAS", "VIC")),
        long_df,
    )

    return filtered_df[:, [id_columns..., :year, :share]]
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
    "BEV_Numbers"   => melt_vehicle_numbers_dataframe(vehicle_numbers_wide_dfs["BEV_Numbers"], :number_bev),
    "PHEV_Numbers"  => melt_vehicle_numbers_dataframe(vehicle_numbers_wide_dfs["PHEV_Numbers"], :number_phev),
    "FCEV_Numbers"  => melt_vehicle_numbers_dataframe(vehicle_numbers_wide_dfs["FCEV_Numbers"], :number_fcev),
    "ICE_Numbers"   => melt_vehicle_numbers_dataframe(vehicle_numbers_wide_dfs["ICE_Numbers"], :number_ice),
)

bev_numbers_df  = vehicle_numbers_dfs["BEV_Numbers"]
phev_numbers_df = vehicle_numbers_dfs["PHEV_Numbers"]
fcev_numbers_df = vehicle_numbers_dfs["FCEV_Numbers"]
ice_numbers_df  = vehicle_numbers_dfs["ICE_Numbers"]

ev_numbers_join_keys = [:scenario, :state, :type, :category, :year]
ev_numbers = outerjoin(
    bev_numbers_df,
    phev_numbers_df;
    on = ev_numbers_join_keys,
)
ev_numbers = outerjoin(ev_numbers, fcev_numbers_df; on = ev_numbers_join_keys)
ev_numbers = outerjoin(ev_numbers, ice_numbers_df; on = ev_numbers_join_keys)

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

# ======================================= #
# Implementation of the profile calculation
# ======================================= #
profiles    = profiles
shares      = bev_phev_charge_type_df
numbers     = ev_numbers
subregional = subregional_demand_allocation_df

# Filter profiles, shares, numbers and subregional, for the year 2030_31 and scenario 2
shares = filter(row -> row.year == "2030_31" && row.scenario == 2, shares)
numbers = filter(row -> row.year == "2030_31" && row.scenario == 2, numbers)
subregional = filter(row -> row.year == "2030_31" && row.scenario == 2, subregional)
# ======================================= #
# Combine the data into one dataframe
_profiles          = leftjoin(profiles, numbers, on=["state", "vehicle_type"])
_profiles.category = [VEHICLE_CATEGORY_BY_TYPE[string(t)] for t in _profiles.vehicle_type]
_profiles          = leftjoin(_profiles, shares[:, [:state, :category, :charging, :share]], on=[:state, :category, :charging_profile => :charging])

start_dt             = DateTime("2030-01-01 00:00:00", dateformat"yyyy-mm-dd HH:MM:SS") # This is parameterised via the tc.problem
scenario = 2
target_year = "2030_31"

filtered_profiles    = filter(row -> row.scenario == scenario && row.year == target_year, _profiles)
filtered_subregional = filter(row -> row.scenario == scenario && row.year == target_year, subregional)

filtered_profiles              = copy(filtered_profiles)
filtered_profiles.total_number = filtered_profiles.number_bev .+ filtered_profiles.number_phev
filtered_profiles.total_number_share   .= filtered_profiles.total_number .* filtered_profiles.share

profile_start_index = findfirst(==("00_00"), names(filtered_profiles))
profile_end_index   = findfirst(==("23_30"), names(filtered_profiles))

if !isnothing(profile_start_index) && !isnothing(profile_end_index) && profile_start_index <= profile_end_index
    leading_columns = names(filtered_profiles)[1:(profile_start_index - 1)]
    profile_columns = names(filtered_profiles)[profile_start_index:profile_end_index]
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
all_times = collect(start_dt:Hour(1):start_dt + Year(1) - Hour(1))
weekday   = dayofweek.(all_times) .<= 5

final_profiles = DataFrame(date=all_times)
for region in unique(subregional.region_id)
    final_profiles[!, "$region"] = zeros(length(all_times))
end
