using CSV
using DataFrames
using Dates

#%%

# Comments about the data
#      - The names in "BHV_PHEV_Profile_kW" dont exactly match the names in "BEV_PHEV_Charge_Type". Need to make adjustments: 
#         - Split both up into type and charging mode       
#         - Remove additional " - vehicle charging" in "BHV_PHEV_Profile_kW"
#      - Create additional mapping dict:
car_type_mapping = Dict(
    "Articulated Truck"       => "Buses and Trucks",
    "Bus"                     => "Buses and Trucks",
    "Large Light Commercial"  => "Commercial",
    "Large Residential"       => "Residential",
    "Medium Light Commercial" => "Commercial",
    "Medium Residential"      => "Residential",
    "Motorcycle"              => "Residential",
    "Rigid Truck"             => "Buses and Trucks",
    "Small Light Commercial"  => "Commercial",
    "Small Residential"       => "Residential"
)

#%%



#%%

scenario = 2
target_year = 2030

exclude_charging = [] # "Convenience Charging", "Daytime Charging", "Highway Fast Charging", "Nighttime Charging", "Vehicle to Grid", "Vehicle to Home"


#%%

# Read in the data
profiles = CSV.read("_personal scripts/DER/data/EVprofiles.csv", DataFrame)
shares = CSV.read("_personal scripts/DER/data/EVshares.csv", DataFrame)
numbers = CSV.read("_personal scripts/DER/data/EVnumbers.csv", DataFrame)
subregional = CSV.read("_personal scripts/DER/data/EVsubregional.csv", DataFrame)

# Creating relevant datetime vectors
start_dt = DateTime("$(target_year)-01-01 00:00:00", dateformat"yyyy-mm-dd HH:MM:SS")
profile_times = [start_dt + Minute(30*(i-1)) for i in 1:48]
profile_column_names = ["$(Dates.format(t, dateformat"H:MM"))" for t in profile_times]

# Filter the data for the relevant scenario and year
numbers = filter(row -> row.scenario == scenario && row.year == target_year, numbers)
shares = filter(row -> row.scenario == scenario && row.year == target_year, shares)
subregional = filter(row -> row.scenario == scenario && row.year == target_year, subregional)

# Combine the data into one dataframe
profiles = leftjoin(profiles, numbers, on=["state", "type"])
profiles.category = [car_type_mapping[string(t)] for t in profiles.type]
profiles = leftjoin(profiles, shares[:, [:state, :category, :charging, :share]], on=["state", "category", "charging"])

# Remove excluded charging types
profiles = filter(row -> !(row.charging in exclude_charging), profiles)

# Calculate the number of BEVs and PHEVs for each profile
profiles.numberBEV = profiles.numberBEV .* profiles.share
profiles.numberPHEV = profiles.numberPHEV .* profiles.share
profiles.total_number = profiles.numberBEV .+ profiles.numberPHEV

# And then calculate the total load for each profile
idxs_weekday = findall(profiles.day .== "weekday")
idxs_weekend = findall(profiles.day .== "weekend")
total_profiles_weekday = profiles[idxs_weekday, profile_column_names] .* profiles.total_number[idxs_weekday]
total_profiles_weekday.state = profiles.state[idxs_weekday]
total_profiles_weekend = profiles[idxs_weekend, profile_column_names] .* profiles.total_number[idxs_weekend]
total_profiles_weekend.state = profiles.state[idxs_weekend]

# Then aggregate to get hourly profiles for each state
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
weekday = dayofweek.(all_times) .<= 5

final_profiles = DataFrame(date=all_times)
for region in unique(subregional.region_id)
    final_profiles[!, "$region"] = zeros(length(all_times))
end

for state in unique(profiles.state)
    weekday_profile = sum(Matrix(total_profiles_weekday[total_profiles_weekday.state .== state, Not(:state)]), dims=1)[:] ./ 1e3 # Convert to MW
    weekend_profile = sum(Matrix(total_profiles_weekend[total_profiles_weekend.state .== state, Not(:state)]), dims=1)[:] ./ 1e3 # Convert to MW

    subregional_shares = subregional[subregional.state .== state, :share]
    subregional_idxs = subregional[subregional.state .== state, :region_id]

    for i in eachindex(all_times)
        if weekday[i]
            final_profiles[i, string.(subregional_idxs)] .= weekday_profile[hour(all_times[i]) + 1] .* subregional_shares
        else
            final_profiles[i, string.(subregional_idxs)] .= weekend_profile[hour(all_times[i]) + 1] .* subregional_shares
        end
    end
end

# Stack the results into long format and write to CSV
stacked_profiles = stack(final_profiles, Not(:date), variable_name=:bus_id, value_name=:value)
stacked_profiles.bus_id = parse.(Int, stacked_profiles.bus_id)
stacked_profiles.scenario .= scenario
stacked_profiles.year .= target_year
stacked_profiles.value .= round.(stacked_profiles.value, digits=3)

CSV.write("_personal scripts/DER/data/EVprofiles_final.csv", stacked_profiles)




#%%

#Integrating this into the pisp-files

# Add the following rows to the DER.csv file (maybe different cost?):
base_path = joinpath("F:", "PhD Data", "pisp-datasets", "out-ref4006-poe10-ev", "csv")
DER = CSV.read(joinpath(base_path, "DER.csv"), DataFrame)
#= 
61	DEM_NQ_EV	EV	1	TRUE	FALSE	0	TRUE	0	41480	1
62	DEM_CQ_EV	EV	2	TRUE	FALSE	0	TRUE	0	41480	1
63	DEM_GG_EV	EV	3	TRUE	FALSE	0	TRUE	0	41480	1
64	DEM_SQ_EV	EV	4	TRUE	FALSE	0	TRUE	0	41480	1
65	DEM_NNSW_EV	EV	5	TRUE	FALSE	0	TRUE	0	41480	1
66	DEM_CNSW_EV	EV	6	TRUE	FALSE	0	TRUE	0	41480	1
67	DEM_SNW_EV	EV	7	TRUE	FALSE	0	TRUE	0	41480	1
68	DEM_SNSW_EV	EV	8	TRUE	FALSE	0	TRUE	0	41480	1
69	DEM_VIC_EV	EV	9	TRUE	FALSE	0	TRUE	0	41480	1
70	DEM_TAS_EV	EV	10	TRUE	FALSE	0	TRUE	0	41480	1
71	DEM_CSA_EV	EV	11	TRUE	FALSE	0	TRUE	0	41480	1
72	DEM_SESA_EV	EV	12	TRUE	FALSE	0	TRUE	0	41480	1 
=#

# And then add the profiles to the DER_pred_sched.csv file
DERsched = CSV.read(joinpath(base_path, "schedule-$target_year", "DER_pred_sched.csv"), DataFrame)

stacked_profiles.id_der = stacked_profiles.bus_id .+ 60 # Assuming that the bus IDs for the EV profiles start from 61, as per the DER.csv file
stacked_profiles.id = collect(1:nrow(stacked_profiles)) .+ maximum(DERsched.id) # Create unique IDs for the new rows

new_DERsched = vcat(DERsched, stacked_profiles[:, names(DERsched)])
CSV.write(joinpath(base_path, "schedule-$target_year", "DER_pred_sched.csv"), new_DERsched)

