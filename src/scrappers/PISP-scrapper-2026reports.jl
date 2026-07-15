module ISP2026ReportDownloader

    using HTTP
    using PISP.PISPScrapperUtils: DEFAULT_FILE_HEADERS

    struct ISPReportTarget
        key::Symbol
        title::String
        filename::String
        url::String
    end

    ISPReportTarget(key::Symbol,
                    title::AbstractString,
                    filename::AbstractString,
                    url::AbstractString) =
        ISPReportTarget(key, String(title), String(filename), String(url))

    const DEFAULT_REPORTS_OUTDIR = "data/2026/pisp-reports"
    const PDF_SIGNATURE = UInt8[0x25, 0x50, 0x44, 0x46, 0x2d] # %PDF-

    const ISP_REPORT_TARGETS = ISPReportTarget[
        ISPReportTarget(:integrated_system_plan,
                        "2026 Integrated System Plan",
                        "2026-integrated-system-plan.pdf",
                        "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/2026-integrated-system-plan-isp.pdf?rev=7f5dfd18aa1b4a3aab704c424f75afd3&sc_lang=en"),
        ISPReportTarget(:plexos_model_instructions,
                        "2026 ISP PLEXOS Model Instructions",
                        "2026-isp-plexos-model-instructions.pdf",
                        "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/isp-model/2026-isp-plexos-model-instructions.pdf?la=en"),
        ISPReportTarget(:iasr_2025,
                        "2025 Inputs, Assumptions and Scenarios Report",
                        "2025-inputs-assumptions-and-scenarios-report.pdf",
                        "https://www.aemo.com.au/-/media/files/stakeholder_consultation/consultations/nem-consultations/2024/2025-iasr-scenarios/final-docs/2025-inputs-assumptions-and-scenarios-report.pdf?rev=63268acd3f044adb9f5f3a32b6880c27&sc_lang=en"),
        ISPReportTarget(:iasr_2025_addendum,
                        "Addendum to the 2025 Inputs, Assumptions and Scenarios Report",
                        "addendum-to-2025-inputs-assumptions-and-scenarios-report.pdf",
                        "https://www.aemo.com.au/-/media/files/major-publications/isp/draft-2026/addendum-to-2025-inputs-assumptions-and-scenarios-report.pdf?rev=00798523a25e42078034d1878c337f19&sc_lang=en"),
        ISPReportTarget(:isp_methodology_2025,
                        "ISP Methodology (June 2025)",
                        "2025-isp-methodology.pdf",
                        "https://www.aemo.com.au/-/media/files/stakeholder_consultation/consultations/nem-consultations/2024/2026-isp-methodology/isp-methodology-june-2025.pdf"),
        ISPReportTarget(:appendix_a2_generation_storage,
                        "A2 ISP Development Opportunities",
                        "a2-isp-development-opportunities.pdf",
                        "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/appendices/a2-isp-development-opportunities.pdf?rev=d81062e7cdcf4af8a04fbccdfc3c9fb4&sc_lang=en"),
        ISPReportTarget(:appendix_a3_rez,
                        "A3 Renewable Energy Zones",
                        "a3-renewable-energy-zones.pdf",
                        "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/appendices/a3-renewable-energy-zones.pdf?la=en"),
        ISPReportTarget(:appendix_a4_operability,
                        "A4 System Operability",
                        "a4-system-operability.pdf",
                        "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/appendices/a4-system-operability.pdf?la=en"),
        ISPReportTarget(:appendix_a6_cost_benefit,
                        "A6 Cost Benefit Analysis",
                        "a6-cost-benefit-analysis.pdf",
                        "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/appendices/a6-cost-benefit-analysis.pdf?la=en"),
        ISPReportTarget(:appendix_a7_security,
                        "A7 System Security",
                        "a7-system-security.pdf",
                        "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/appendices/a7-system-security.pdf?la=en"),
    ]

    isp_report_targets() = copy(ISP_REPORT_TARGETS)

    """
        download_isp_reports(; outdir = "data/2026/pisp-reports", overwrite = false, throttle_seconds = nothing)

    Download the ten selected 2026 ISP report PDFs from AEMO. Existing valid PDFs are
    retained unless `overwrite = true`; invalid existing files are re-downloaded.
    """
    function download_isp_reports(; outdir = DEFAULT_REPORTS_OUTDIR,
                                  overwrite = false,
                                  throttle_seconds = nothing)
        return download_report_targets(ISP_REPORT_TARGETS;
                                       outdir = outdir,
                                       overwrite = overwrite,
                                       throttle_seconds = throttle_seconds)
    end

    function download_report_targets(targets::AbstractVector{ISPReportTarget};
                                     outdir::AbstractString = DEFAULT_REPORTS_OUTDIR,
                                     overwrite::Bool = false,
                                     throttle_seconds::Union{Nothing,Real} = nothing,
                                     download_function::Function = download_report_file)
        throttle_seconds !== nothing && throttle_seconds < 0 &&
            throw(ArgumentError("throttle_seconds must be non-negative."))

        saved_paths = String[]
        for target in targets
            path, downloaded = download_report_target(target;
                                                       outdir = outdir,
                                                       overwrite = overwrite,
                                                       download_function = download_function)
            push!(saved_paths, path)
            downloaded && throttle_seconds !== nothing && sleep(throttle_seconds)
        end

        return saved_paths
    end

    function download_report_target(target::ISPReportTarget;
                                    outdir::AbstractString,
                                    overwrite::Bool,
                                    download_function::Function)
        destination = joinpath(outdir, target.filename)
        temporary_path = nothing

        try
            mkpath(dirname(destination))
            isdir(destination) && throw(ArgumentError("destination is a directory: $(destination)"))

            if !overwrite && is_valid_pdf(destination)
                return destination, false
            end

            temporary_path = create_temporary_path(dirname(destination))
            download_function(target.url, temporary_path; headers = DEFAULT_FILE_HEADERS)
            is_valid_pdf(temporary_path) ||
                throw(ArgumentError("downloaded payload is not a non-empty PDF."))

            mv(temporary_path, destination; force = true)
            return destination, true
        catch err
            throw(ErrorException("Failed to download ISP report $(target.key) ($(target.title)) from $(target.url): $(sprint(showerror, err))"))
        finally
            temporary_path !== nothing && ispath(temporary_path) && rm(temporary_path; force = true)
        end
    end

    function download_report_file(url::AbstractString,
                                  destination::AbstractString;
                                  headers::Vector{Pair{String,String}} = DEFAULT_FILE_HEADERS)
        response = HTTP.get(url; headers = headers, status_exception = false)
        response.status == 200 || throw(ArgumentError("HTTP GET returned status $(response.status)."))

        open(destination, "w") do io
            write(io, response.body)
        end
        return destination
    end

    function is_valid_pdf(path::AbstractString)
        isfile(path) || return false
        filesize(path) >= length(PDF_SIGNATURE) || return false
        return open(path, "r") do io
            read(io, length(PDF_SIGNATURE)) == PDF_SIGNATURE
        end
    end

    function create_temporary_path(destination_dir::AbstractString)
        path, io = mktemp(destination_dir; cleanup = false)
        close(io)
        return path
    end

end
