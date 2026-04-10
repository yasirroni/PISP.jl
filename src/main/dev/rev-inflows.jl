downloadpath = normpath(@__DIR__, "../../", "data-download")
poe = 10
reftrace = 4006
years = [2025]
output_name = "out", # Output folder name
output_root = nothing,
write_csv = true,
write_arrow = true,
download_from_AEMO = true,
scenarios::AbstractVector{<:Int64} = keys(PISP.ID2SCE),

    if any(y -> y < 2025 || y > 2050, years)
        throw(ArgumentError("Years must be between 2025 and 2050 (got $(years))."))
    end

    data_paths = PISP.default_data_paths(filepath=downloadpath)

    # Download/extract/build inputs once
    PISP.build_pipeline(data_root = downloadpath, poe = poe, download_files = download_from_AEMO, overwrite_extracts = false)

    base_name = "$(output_name)-ref$(reftrace)-poe$(poe)"

    for year in years
        tc, ts, tv = PISP.initialise_time_structures()
        fill_problem_table_year(tc, year, sce=scenarios)
        static_params = PISP.populate_time_static!(ts, tv, data_paths; refyear = reftrace, poe = poe)
        @info "Populating time-varying data from ISP 2024 - POE $(poe) - reference weather trace $(reftrace) - planning year $(year) ..."
        PISP.populate_time_varying!(tc, ts, tv, data_paths, static_params; refyear = reftrace, poe = poe)

        PISP.write_time_data(ts, tv;
            csv_static_path    = "$(base_name)/csv",
            csv_varying_path   = "$(base_name)/csv/schedule-$(year)",
            arrow_static_path  = "$(base_name)/arrow",
            arrow_varying_path = "$(base_name)/arrow/schedule-$(year)",
            write_static       = true,
            write_varying      = true,
            output_root        = output_root,
            write_csv          = write_csv,
            write_arrow        = write_arrow,
        )
    end