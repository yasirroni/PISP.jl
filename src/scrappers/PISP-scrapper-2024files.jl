module ISPFileDownloader

    using PISP.PISPScrapperUtils: DEFAULT_FILE_HEADERS,
        FileDownloadOptions,
        download_file,
        interactive_overwrite_prompt,
        prompt_skip_existing

    export ISPFileTarget,
        FileDownloadOptions,
        isp_file_targets,
        isp2026_source_metadata,
        download_isp_files,
        download_all_isp_files,
        download_isp24_inputs_workbook,
        download_iasr23_ev_workbook,
        download_isp24_model_archive,
        download_isp24_generation_storage_archive,
        download_isp24_outlook,
        download_isp19_inputs_workbook,
        download_isp26_inputs_workbook

    const DEFAULT_FILES_OUTDIR = "scrapped/ISP_reference_files"

    function default_file_download_options(; outdir::AbstractString = DEFAULT_FILES_OUTDIR,
                                            confirm_overwrite::Bool = true,
                                            skip_existing::Bool = false,
                                            throttle_seconds::Union{Nothing,Real} = nothing,
                                            file_headers::Vector{Pair{String,String}} = DEFAULT_FILE_HEADERS)
        return FileDownloadOptions(; outdir = outdir,
                                    confirm_overwrite = confirm_overwrite,
                                    skip_existing = skip_existing,
                                    throttle_seconds = throttle_seconds,
                                    file_headers = file_headers)
    end

    struct ISPFileTarget
        key::Symbol
        title::String
        url::String
        filename::Union{Nothing,String}
        subdir::Union{Nothing,String}
    end

    ISPFileTarget(key::Symbol, title::AbstractString, url::AbstractString;
                filename::Union{Nothing,AbstractString} = nothing,
                subdir::Union{Nothing,AbstractString} = nothing) =
        ISPFileTarget(key,
                      String(title),
                      String(url),
                      filename === nothing ? nothing : String(filename),
                      subdir === nothing ? nothing : String(subdir))

    const ISP_FILE_TARGETS = ISPFileTarget[
        ISPFileTarget(:isp24_inputs,
                      "2024 ISP Inputs and Assumptions workbook",
                      "https://www.aemo.com.au/-/media/files/major-publications/isp/2024/2024-isp-inputs-and-assumptions-workbook.xlsx?rev=c75116cf5a834eeaa6b4ed68cff9b117&sc_lang=en";
                      filename = "2024-isp-inputs-and-assumptions-workbook.xlsx",
                      subdir = ""),
        ISPFileTarget(:iasr23_ev_workbook,
                      "2023 IASR EV workbook",
                      "https://www.aemo.com.au/-/media/files/major-publications/isp/2023/2023-iasr-ev-workbook.xlsx";
                      filename = "2023-iasr-ev-workbook.xlsx",
                      subdir = ""),
        ISPFileTarget(:isp24_model,
                      "2024 ISP Model",
                      "https://www.aemo.com.au/-/media/files/major-publications/isp/2024/supporting-materials/2024-isp-model.zip?rev=3b35a0a57f564ec88098985782d2932c&sc_lang=en";
                      filename = "2024-isp-model.zip",
                      subdir = ""),
        ISPFileTarget(:isp24_outlook,
                      "2024 ISP generation and storage outlook",
                      "https://www.aemo.com.au/-/media/files/major-publications/isp/2024/supporting-materials/2024-isp-generation-and-storage-outlook.zip?rev=986359059f934cc0bbbd94d0b5280e68&sc_lang=en";
                      filename = "2024-isp-generation-and-storage-outlook.zip",
                      subdir = ""),
        ISPFileTarget(:isp19_inputs_v13,
                       "2019 input and assumptions workbook v1.3",
                       "https://www.aemo.com.au/-/media/files/electricity/nem/planning_and_forecasting/inputs-assumptions-methodologies/2019/2019-input-and-assumptions-workbook-v1-3-dec-19.xlsx?rev=b6fb3a0d7bd849eea781e99f8c89544a&sc_lang=en";
                       filename = "2019-input-and-assumptions-workbook-v1-3-dec-19.xlsx",
                       subdir = ""),
        ISPFileTarget(:isp26_inputs,
                      "2026 ISP Inputs and Assumptions workbook",
                      "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/supporting-materials/2026-isp-inputs-and-assumptions-workbook.xlsm?rev=de6f5853cd5e4d5cbb06bc90bdf0e378&sc_lang=en";
                      filename = "2026-isp-inputs-and-assumptions-workbook.xlsm",
                      subdir = ""),
        ISPFileTarget(:isp26_outlook,
                      "2026 ISP generation and storage outlook",
                      "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/supporting-materials/2026-isp-generation-and-storage-outlook.zip?rev=b64eda28a46b4d3eb3e4b3cbafea3f84&sc_lang=en";
                      filename = "2026-isp-generation-and-storage-outlook.zip",
                      subdir = ""),
        ISPFileTarget(:isp26_model,
                      "2026 ISP Model",
                      "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/isp-model/2026-isp-model.zip?rev=78bfcf05ad414a8f9ba01f6a7c329fc2&sc_lang=en";
                      filename = "2026-isp-model.zip",
                      subdir = ""),
        ISPFileTarget(:isp26_solar_traces,
                      "2026 ISP Solar traces",
                      "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/isp-model/2026-isp-solar-traces.zip?rev=3ad06155b7b94628bc77b90efe94588e&sc_lang=en";
                      filename = "2026-isp-solar-traces.zip",
                      subdir = "zip/Traces"),
        ISPFileTarget(:isp26_wind_traces,
                      "2026 ISP Wind traces",
                      "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/isp-model/2026-isp-wind-traces.zip?rev=73674cd5bc6b4b7fbbc7d0e68ee0bc7c&sc_lang=en";
                      filename = "2026-isp-wind-traces.zip",
                      subdir = "zip/Traces")
    ]

    const ISP_FILE_LOOKUP = Dict(target.key => target for target in ISP_FILE_TARGETS)

    const ISP2026_SOURCE_METADATA = [
        (key = :isp26_inputs,
         title = "2026 ISP Inputs and Assumptions workbook",
         url = "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/supporting-materials/2026-isp-inputs-and-assumptions-workbook.xlsm?rev=de6f5853cd5e4d5cbb06bc90bdf0e378&sc_lang=en",
         filename = "2026-isp-inputs-and-assumptions-workbook.xlsm",
         status = :downloadable,
         local_path = "2026-isp-inputs-and-assumptions-workbook.xlsm",
         note = "Authoritative final 2026 ISP input workbook."),
        (key = :isp26_outlook,
         title = "2026 ISP generation and storage outlook",
         url = "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/supporting-materials/2026-isp-generation-and-storage-outlook.zip?rev=b64eda28a46b4d3eb3e4b3cbafea3f84&sc_lang=en",
         filename = "2026-isp-generation-and-storage-outlook.zip",
         status = :downloadable,
         local_path = "2026-isp-generation-and-storage-outlook.zip",
         note = "Authoritative final 2026 ISP generation and storage outlook."),
        (key = :isp26_model,
         title = "2026 ISP Model",
         url = "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/isp-model/2026-isp-model.zip?rev=78bfcf05ad414a8f9ba01f6a7c329fc2&sc_lang=en",
         filename = "2026-isp-model.zip",
         status = :downloadable,
         local_path = "2026-isp-model.zip",
         note = "Authoritative final 2026 ISP model archive."),
        (key = :isp26_solar_traces,
         title = "2026 ISP Solar traces",
         url = "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/isp-model/2026-isp-solar-traces.zip?rev=3ad06155b7b94628bc77b90efe94588e&sc_lang=en",
         filename = "2026-isp-solar-traces.zip",
         status = :downloadable,
         local_path = "zip/Traces/2026-isp-solar-traces.zip",
         note = "Authoritative final 2026 ISP solar traces."),
        (key = :isp26_wind_traces,
         title = "2026 ISP Wind traces",
         url = "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/isp-model/2026-isp-wind-traces.zip?rev=73674cd5bc6b4b7fbbc7d0e68ee0bc7c&sc_lang=en",
         filename = "2026-isp-wind-traces.zip",
         status = :downloadable,
         local_path = "zip/Traces/2026-isp-wind-traces.zip",
         note = "Authoritative final 2026 ISP wind traces."),
    ]

    isp_file_targets() = copy(ISP_FILE_TARGETS)

    function download_all_isp_files(; options::FileDownloadOptions = default_file_download_options())
        return download_isp_files(ISP_FILE_TARGETS; options = options)
    end

    download_isp24_inputs_workbook(; options::FileDownloadOptions = default_file_download_options()) =
        download_single_target(:isp24_inputs; options = options)

    download_iasr23_ev_workbook(; options::FileDownloadOptions = default_file_download_options()) =
        download_single_target(:iasr23_ev_workbook; options = options)

    download_isp24_model_archive(; options::FileDownloadOptions = default_file_download_options()) =
        download_single_target(:isp24_model; options = options)

    download_isp24_outlook(; options::FileDownloadOptions = default_file_download_options()) =
        download_single_target(:isp24_outlook; options = options)

    # download_isp24_outlook(; options::FileDownloadOptions = default_file_download_options()) =
    #     download_isp24_generation_storage_archive(; options = options)

    download_isp19_inputs_workbook(; options::FileDownloadOptions = default_file_download_options()) =
        download_single_target(:isp19_inputs_v13; options = options)

    download_isp26_inputs_workbook(; options::FileDownloadOptions = default_file_download_options()) =
        download_single_target(:isp26_inputs; options = options)

    isp2026_source_metadata() = copy(ISP2026_SOURCE_METADATA)

    function download_isp_files(targets::AbstractVector{ISPFileTarget};
                                options::FileDownloadOptions = default_file_download_options(),
                                overwrite_policy::Function = interactive_overwrite_prompt)
        isempty(targets) && return String[]
        saved_paths = String[]
        skip_existing = options.skip_existing
        skip_prompted = false
        nonreplace_count = 0

        for (idx, target) in enumerate(targets)
            dest_dir = target_outdir(target, options.outdir)
            mkpath(dest_dir)
            filename = destination_filename(target)
            dest = joinpath(dest_dir, filename)

            println("[$idx/$(length(targets))] Downloading")
            println("  Title: ", target.title)
            println("  URL  : ", target.url)
            println("  File : ", dest, "\n")

            if isfile(dest)
                if skip_existing
                    println("  ↺ Skipping file download (global no-replace enabled).\n")
                    push!(saved_paths, dest)
                    continue
                elseif options.confirm_overwrite && !overwrite_policy(dest)
                    nonreplace_count += 1
                    if nonreplace_count > 2 && !skip_prompted
                        skip_existing = prompt_skip_existing()
                        skip_prompted = true
                        if skip_existing
                            println("  ↺ Global no-replace enabled. Existing files will be kept.\n")
                            push!(saved_paths, dest)
                            continue
                        end
                    end
                    println("  ↺ Keeping existing file.\n")
                    push!(saved_paths, dest)
                    continue
                end
            end

            try
                download_file(target.url, dest; headers = options.file_headers)
                println("  ✅ Done\n")
            catch err
                isfile(dest) && rm(dest; force = true)
                println("  ❌ Failed\n")
                error("Failed to download $(target.title) from $(target.url) to $(dest).\n$(sprint(showerror, err))")
            end

            options.throttle_seconds === nothing || sleep(options.throttle_seconds)
            push!(saved_paths, dest)
        end

        return saved_paths
    end

    function download_single_target(key::Symbol;
                                    options::FileDownloadOptions = default_file_download_options())
        target = get_target(key)
        paths = download_isp_files([target]; options = options)
        return isempty(paths) ? "" : paths[1]
    end

    function download_file_target(title::AbstractString, url::AbstractString, filename::AbstractString;
                                  options::FileDownloadOptions = default_file_download_options())
        dest_dir = target_outdir(ISPFileTarget(:tmp, title, url; filename = filename, subdir = ""), options.outdir)
        mkpath(dest_dir)
        dest = joinpath(dest_dir, filename)
        try
            download_file(url, dest; headers = options.file_headers)
        catch err
            isfile(dest) && rm(dest; force = true)
            error("Failed to download $(title) from $(url) to $(dest).\n$(sprint(showerror, err))")
        end
        return dest
    end

    function get_target(key::Symbol)
        return get(ISP_FILE_LOOKUP, key) do
            error("Unknown ISP file target $(key).")
        end
    end

    function target_outdir(target::ISPFileTarget, base::AbstractString)
        subdir = something(target.subdir, "")
        return isempty(subdir) ? base : joinpath(base, subdir)
    end

    function destination_filename(target::ISPFileTarget)
        return something(target.filename, filename_from_url(target.url))
    end

    function filename_from_url(url::AbstractString)
        stripped = split(url, '?'; limit = 2)[1]
        parts = split(stripped, '/')
        return parts[end]
    end

end
