source_target_keys(::ISP2024) = (
    :isp24_inputs,
    :iasr23_ev_workbook,
    :isp19_inputs_v13,
    :isp24_model,
    :isp24_outlook,
)

source_target_keys(::ISP2026) = (
    :isp26_inputs,
    :isp26_outlook,
    :isp26_model,
    :isp26_solar_traces,
    :isp26_wind_traces,
)

source_targets(release::Union{ISP2024,ISP2026}) =
    [ISPFileDownloader.get_target(key) for key in source_target_keys(release)]

function download_source_files(::ISP2024, downloadpath::AbstractString = ISPdatabuilder.DEFAULT_DATA_ROOT;
        confirm_overwrite::Bool = true,
        skip_existing::Bool = true,
        throttle_seconds::Union{Nothing,Real} = nothing)
    return ISPdatabuilder.download_isp_assets(;
        data_root = downloadpath,
        confirm_overwrite = confirm_overwrite,
        skip_existing = skip_existing,
        throttle_seconds = throttle_seconds,
    )
end

function download_source_files(::ISP2026, downloadpath::AbstractString = ISPdatabuilder.DEFAULT_DATA_ROOT;
        confirm_overwrite::Bool = true,
        skip_existing::Bool = true,
        throttle_seconds::Union{Nothing,Real} = nothing,
        download_targets_fn::Function = ISPFileDownloader.download_isp_files)
    dirs = ISPdatabuilder.data_dirs(downloadpath)
    files_options = ParseISPScrapperUtils.FileDownloadOptions(
        outdir = dirs.root,
        confirm_overwrite = confirm_overwrite,
        skip_existing = skip_existing,
        throttle_seconds = ISPdatabuilder.maybe_throttle(throttle_seconds),
    )
    automatic_targets = source_targets(ISP2026())
    downloaded_paths = download_targets_fn(automatic_targets; options = files_options)
    release_paths = default_data_paths(ISP2026(), downloadpath)
    legacy_paths = legacy_data_paths(ISP2026(), release_paths)

    return (
        paths = legacy_paths,
        release_paths = release_paths,
        legacy_paths = legacy_paths,
        downloaded = (
            ispdata26 = downloaded_paths[1],
            outlook_generation_storage = downloaded_paths[2],
            ispmodel_zip = downloaded_paths[3],
            solar_traces_zip = downloaded_paths[4],
            wind_traces_zip = downloaded_paths[5],
        ),
        targets = (automatic = source_target_keys(ISP2026()),),
        outlook = isfile(release_paths.outlook_generation_storage_zip) ?
            inspect_isp26_generation_storage_outlook(release_paths.outlook_generation_storage_zip; parse_tables = false) :
            nothing,
        metadata = ISPFileDownloader.isp2026_source_metadata(),
    )
end

function inspect_sources(::ISP2024, downloadpath::AbstractString; kwargs...)
    paths = default_data_paths(ISP2024(), downloadpath)
    return (paths = paths,)
end

function inspect_sources(::ISP2026, downloadpath::AbstractString;
        parse_tables::Bool = false,
        kwargs...)
    paths = default_data_paths(ISP2026(), downloadpath)
    outlook = isfile(paths.outlook_generation_storage_zip) ?
        inspect_isp26_generation_storage_outlook(paths.outlook_generation_storage_zip; parse_tables = parse_tables, kwargs...) :
        nothing
    return (paths = paths, outlook = outlook)
end

function validate_sources(::ISP2024, paths::NamedTuple)
    required_keys = (:legacy_inputs_workbook, :inputs_workbook, :ev_inputs_workbook)
    missing = Pair{Symbol,String}[]
    for key in required_keys
        path = getfield(paths, key)
        isfile(path) || push!(missing, key => path)
    end
    return (ok = isempty(missing), missing = missing)
end

function validate_sources(::ISP2026, paths::NamedTuple)
    required_keys = (
        :inputs_workbook,
        :ev_inputs_workbook,
        :outlook_generation_storage_zip,
        :isp_model_zip,
        :solar_traces_zip,
        :wind_traces_zip,
    )
    missing = Pair{Symbol,String}[]
    for key in required_keys
        path = getfield(paths, key)
        _reject_nonfinal_isp2026_path(path)
        isfile(path) || push!(missing, key => path)
    end
    return (ok = isempty(missing), missing = missing)
end

function prepare_sources(::ISP2024, downloadpath::AbstractString; kwargs...)
    return build_pipeline(; data_root = downloadpath, download_files = false, kwargs...)
end

function prepare_sources(::ISP2026, downloadpath::AbstractString;
        prepare_outlook::Bool = true,
        prepare_supporting_assets::Bool = true,
        build_traces::Bool = false,
        scenario_map = Dict{String,String}(),
        overwrite_extracts::Bool = false,
        quiet_extracts::Bool = true,
        poe::Real = 10.0,
        years = 2011:2023,
        verbose_traces::Bool = false)
    paths = default_data_paths(ISP2026(), downloadpath)
    legacy_paths = legacy_data_paths(ISP2026(), paths)

    extraction = prepare_supporting_assets ?
        extract_downloads(data_root = downloadpath, overwrite = overwrite_extracts, quiet = quiet_extracts) :
        nothing

    outlook = prepare_outlook ?
        prepare_isp26_outlook_aux(paths.outlook_generation_storage_zip;
            data_root = downloadpath,
            scenario_map = scenario_map) :
        nothing

    traces = build_traces ?
        build_refyear4006_traces(;
            data_root = downloadpath,
            years = years,
            poe = poe,
            release = ISP2026(),
            verbose = verbose_traces) :
        nothing

    return (
        paths = paths,
        legacy_paths = legacy_paths,
        extraction = extraction,
        outlook = outlook,
        traces = traces,
    )
end
