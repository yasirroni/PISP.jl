module ParseISP
    using Dates
    using DataFrames
    using OrderedCollections
    using XLSX
    using CSV
    using Arrow
    using SHA
    export DataFrames

    include("releases/common/release.jl")
    include("releases/common/paths.jl")
    include("ParseISPdatamodel.jl")
    include("ParseISPstructures.jl")
    include("ParseISPutils.jl")
    include("ParseISPparameters.jl")
    include("releases/isp2026/readers.jl")
    include("releases/isp2026/validation.jl")
    include("releases/isp2026/reconciliation.jl")
    include("releases/isp2026/fixes.jl")
    include("releases/common/builders.jl")
    include("ParseISPparsers.jl")
    include("ParseISPscrappers.jl")
    include("releases/common/sources.jl")
    include("releases/common/pipeline.jl")

    export ISPRelease,
        ISP2024,
        ISP2026,
        release_year,
        release_name,
        build_datasets,
        download_source_files,
        inspect_sources,
        prepare_sources,
        default_data_paths,
        source_targets,
        validate_sources,
        build_pipeline,
        download_isp26_source_files,
        prepare_isp26_outlook_aux,
        extract_downloads,
        prepare_isp26_trace_inputs,
        build_refyear4006_traces,
        build_ISP24_datasets,
        build_ISP26_datasets
end
