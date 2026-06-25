scenario_definitions(::ISP2024) = copy(SCE)

scenario_id_labels(::ISP2024) = copy(ID2SCE)

demand_scenario_labels(::ISP2024) = copy(DEMSCE)

hydro_scenario_labels(::ISP2024) = copy(HYDROSCE)

weather_year_mapping(::ISP2024) = copy(WEATHER_YEARS_ISP)

capacity_reductions(::ISP2024) = Reduction2024

generator_retirements(::ISP2024) = Retirements2024
