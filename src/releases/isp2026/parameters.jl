const ID2SCE2026 = OrderedDict(
    1 => "Slower Growth",
    2 => "Step Change",
    3 => "Accelerated Transition",
)

const SCE2026 = OrderedDict(
    "Slower Growth" => 1,
    "Step Change" => 2,
    "Accelerated Transition" => 3,
)

const DEMSCE2026 = OrderedDict(
    "Slower Growth" => "SLOWER_GROWTH",
    "Step Change" => "STEP_CHANGE",
    "Accelerated Transition" => "ACCELERATED_TRANSITION",
)

const HYDROSCE2026 = OrderedDict(
    "Slower Growth" => "Flat",
    "Step Change" => "Flat",
    "Accelerated Transition" => "Flat",
)

const WEATHER_YEARS_ISP2026 = Dict(
    ("2024-07-01", "2025-06-30") => "2019",
    ("2025-07-01", "2026-06-30") => "2020",
    ("2026-07-01", "2027-06-30") => "2021",
    ("2027-07-01", "2028-06-30") => "2022",
    ("2028-07-01", "2029-06-30") => "2023",
    ("2029-07-01", "2030-06-30") => "2015",
    ("2030-07-01", "2031-06-30") => "2011",
    ("2031-07-01", "2032-06-30") => "2012",
    ("2032-07-01", "2033-06-30") => "2013",
    ("2033-07-01", "2034-06-30") => "2014",
    ("2034-07-01", "2035-06-30") => "2015",
    ("2035-07-01", "2036-06-30") => "2016",
    ("2036-07-01", "2037-06-30") => "2017",
    ("2037-07-01", "2038-06-30") => "2018",
    ("2038-07-01", "2039-06-30") => "2019",
    ("2039-07-01", "2040-06-30") => "2020",
    ("2040-07-01", "2041-06-30") => "2021",
    ("2041-07-01", "2042-06-30") => "2022",
    ("2042-07-01", "2043-06-30") => "2023",
    ("2043-07-01", "2044-06-30") => "2015",
    ("2044-07-01", "2045-06-30") => "2011",
    ("2045-07-01", "2046-06-30") => "2012",
    ("2046-07-01", "2047-06-30") => "2013",
    ("2047-07-01", "2048-06-30") => "2014",
    ("2048-07-01", "2049-06-30") => "2015",
    ("2049-07-01", "2050-06-30") => "2016",
    ("2050-07-01", "2051-06-30") => "2017",
    ("2051-07-01", "2052-06-30") => "2018",
)

# Final ISP2026 uses the final 2026 outlook workbooks for capacity trajectories.
# No manual 2024 CDP14 retirement overlay is applied on the ISP2026 path.
const Reduction2026 = [Dict{String,Vector{Tuple{Int,Int,Int,Int}}}() for _ in 1:3]
const Retirements2026 = [Dict{String,Vector{Tuple{Int,Int,Int,Int}}}() for _ in 1:3]

scenario_definitions(::ISP2026) = copy(SCE2026)

scenario_id_labels(::ISP2026) = copy(ID2SCE2026)

demand_scenario_labels(::ISP2026) = copy(DEMSCE2026)

hydro_scenario_labels(::ISP2026) = copy(HYDROSCE2026)

weather_year_mapping(::ISP2026) = copy(WEATHER_YEARS_ISP2026)

capacity_reductions(::ISP2026) = Reduction2026

generator_retirements(::ISP2026) = Retirements2026
