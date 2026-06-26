"""
    default_data_paths(; filepath = @__DIR__)

Return the default ISP/IASR input locations as a named tuple, rooted at
`filepath` (defaults to the directory of this file). The tuple points to the
expected workbook filenames, the ISP model directory, trace folders, and
auxiliary outlook files required by the build pipeline.

# Keyword Arguments
- `filepath::AbstractString = @__DIR__`: Base directory that already contains
  the downloaded ISP data structure. Paths are combined using `normpath`.
"""
function default_data_paths(;filepath=@__DIR__)
    return legacy_data_paths(ISP2024(), default_data_paths(ISP2024(), filepath))
end

"""
    default_data_paths_2026(; filepath = @__DIR__)

Return the final 2026 ISP input paths. These point only to artefacts published
with the final 2026 ISP on 25 June 2026.
"""
function default_data_paths_2026(; filepath=@__DIR__)
    return legacy_data_paths(ISP2026(), default_data_paths(ISP2026(), filepath))
end

function _require_existing_files(paths::NamedTuple, keys)
    missing = Pair{Symbol,String}[]
    for key in keys
        path = getfield(paths, key)
        ParseISP._reject_nonfinal_isp2026_path(path)
        isfile(path) || push!(missing, key => path)
    end
    isempty(missing) && return nothing
    message = join(["$(key): $(path)" for (key, path) in missing], "\n")
    throw(ArgumentError("Missing required ISP2026 input file(s):\n$(message)"))
end

"""
    fill_problem_table_year(tc, year; release = ISP2024(), sce = keys(scenario_id_labels(release)))

Populate `tc.problem` with half-year blocks for each scenario in `sce`. For the
given `year`, two entries are created (Jan–Jun and Jul–Dec) with a 60-minute
time step, unit weight, and problem type `"UC"`.

# Arguments
- `tc::ParseISPtimeConfig`: Target time-configuration container mutated in place.
- `year::Int`: Calendar year to populate.

# Keyword Arguments
- `release`: ISP release whose scenario labels should be used.
- `sce`: Iterable of scenario IDs to include for the selected release.
"""
function fill_problem_table_year(tc::ParseISPtimeConfig, year::Int;
        release::ISPRelease = ISP2024(),
        sce = keys(ParseISP.scenario_id_labels(release)))
    # Generate date blocks from 2025 to 2035, with periods starting 01/01 and 01/07
    date_blocks = ParseISP.OrderedDict()
    block_id = 1

    if release isa ISP2026
        # Final ISP2026 traces are financial-year traces starting 1 July.
        dstart_jul = DateTime(year, 7, 1, 0, 0, 0)
        dend_jul = DateTime(year, 12, 31, 23, 0, 0)
        date_blocks[block_id] = (dstart_jul, dend_jul, year)
        block_id += 1

        dstart_jan = DateTime(year + 1, 1, 1, 0, 0, 0)
        dend_jan = DateTime(year + 1, 6, 30, 23, 0, 0)
        date_blocks[block_id] = (dstart_jan, dend_jan, year)
        block_id += 1
    else
        # First block: January 1 to June 30
        dstart_jan = DateTime(year, 1, 1, 0, 0, 0)
        dend_jan = DateTime(year, 6, 30, 23, 0, 0)
        date_blocks[block_id] = (dstart_jan, dend_jan, year)
        block_id += 1

        # Second block: July 1 to December 31
        dstart_jul = DateTime(year, 7, 1, 0, 0, 0)
        dend_jul = DateTime(year, 12, 31, 23, 0, 0)
        date_blocks[block_id] = (dstart_jul, dend_jul, year)
        block_id += 1
    end

    # Create problem entries for each scenario and each date block
    row_id = 1
    scenario_labels = ParseISP.scenario_id_labels(release)
    for (block_num, (dstart, dend, year)) in date_blocks
        for sc in sce
            pbname = "$(scenario_labels[sc])_$(year)_$(month(dstart) == 1 ? "H1" : "H2")" # H1 for first half, H2 for second half
            arr = [row_id, replace(pbname, " " => "_"), sc, 1, "UC", dstart, dend, 60]
            push!(tc.problem, arr)
            row_id += 1
        end
    end
end

function _to_datetime(d, bound::Symbol)
    dt = d isa DateTime ? d :
         d isa Date     ? DateTime(d) :
         DateTime(Date(string(d), dateformat"dd-mm-yyyy"))
    bound === :end ? DateTime(year(dt), month(dt), day(dt), 23, 0, 0) :
                     DateTime(year(dt), month(dt), day(dt),  0, 0, 0)
end

"""
    fill_problem_table_drange(tc, dstart, dend; release = ISP2024(), sce = keys(scenario_id_labels(release)))

Populate `tc.problem` for an arbitrary date range. If the range crosses the
July 1 half-year boundary it is automatically split into two blocks (H1/H2),
matching the structure used by `fill_problem_table_year`. One problem row per
block per scenario is created with a 60-minute time step, unit weight, and
problem type `"UC"`.

# Arguments
- `tc::ParseISPtimeConfig`: Target time-configuration container mutated in place.
- `dstart::DateTime`: Start of the date range (inclusive, at 00:00:00).
- `dend::DateTime`: End of the date range (inclusive, at 23:00:00).

# Keyword Arguments
- `release`: ISP release whose scenario labels should be used.
- `sce`: Iterable of scenario IDs to include for the selected release.
"""
function fill_problem_table_drange(tc::ParseISPtimeConfig, dstart::DateTime, dend::DateTime;
        release::ISPRelease = ISP2024(),
        sce = keys(ParseISP.scenario_id_labels(release)))
    july1 = DateTime(year(dstart), 7, 1, 0, 0, 0)
    blocks = if dstart < july1 && dend >= july1
        [(dstart, DateTime(year(dstart), 6, 30, 23, 0, 0)),
         (july1, dend)]
    else
        [(dstart, dend)]
    end

    row_id = 1
    scenario_labels = ParseISP.scenario_id_labels(release)
    for (ds, de) in blocks
        for sc in sce
            start_str = Dates.format(ds, "ddmmyyyy")
            end_str   = Dates.format(de, "ddmmyyyy")
            pbname = replace("$(scenario_labels[sc])_$(start_str)-$(end_str)", " " => "_")
            push!(tc.problem, [row_id, pbname, sc, 1, "UC", ds, de, 60])
            row_id += 1
        end
    end
end

function _apply_buildouts!(ts, tv, filepath::AbstractString, sc_buildouts::Dict{Int,String})
    if isempty(sc_buildouts)
        add_buildouts!(ts, tv, filepath; sheetname="buildout_1")
    else
        add_buildouts!(ts, tv, filepath; sc_buildouts=sc_buildouts)
    end
end

"""
    build_ISP24_datasets(; kwargs...)

Download (optionally), assemble, and export ISP 2024 datasets for one or more
planning years. For each year it initializes fresh time structures, fills
static/varying tables from the ISP inputs, and writes CSV/Arrow outputs under
`output_root` with a name prefix reflecting the reference trace and POE.

# Keyword Arguments
- `downloadpath::AbstractString = normpath(@__DIR__, "../../", "data-download")`:
  Base directory holding (or receiving) ISP inputs.
- `poe::Integer = 10`: Probability of exceedance for demand (e.g., 10 or 50).
- `reftrace::Integer = 4006`: Reference weather trace ID (2011–2023 or 4006).
- `years::Union{Nothing,AbstractVector{<:Integer}} = nothing`: Planning years to
  build (must be within 2025–2050). Defaults to `[2025]` when neither `years`
  nor `drange` is given. Mutually exclusive with `drange`.
- `drange::Union{Nothing,AbstractVector} = nothing`: Alternative to `years`. An
  array of 2-tuples `(start, end)` where each element may be a `Date`,
  `DateTime`, or `AbstractString` in `"DD-MM-YYYY"` format. One problem entry
  is created per tuple per scenario. Ranges crossing July 1 are automatically
  split into two half-year blocks. Output folders are named
  `schedule-DDMMYYYY-DDMMYYYY`. Mutually exclusive with `years`.
- `output_name::AbstractString = "out"`: Folder name prefix for outputs.
- `output_root::Union{Nothing,AbstractString} = nothing`: Optional root path for
  outputs; when `nothing`, uses relative paths.
- `write_csv::Bool = true`: Enable CSV exports.
- `write_arrow::Bool = true`: Enable Arrow exports.
- `download_from_AEMO::Bool = true`: Download ISP files before building when
  true; otherwise expects them to already be present.
- `scenarios`: Scenario IDs to include in the build.
- `write_traces::Bool = true`: Set to `false` to skip heavy time-varying trace
  computation.
- `check_exist_trace::Bool = false`: When `true`, skip trace computation for a
  schedule whose key output files already exist.
- `buildout_filepath::Union{Nothing,AbstractString} = nothing`: Path to an Excel
  workbook containing buildout schedules. When `nothing` (default), no buildouts
  are applied. When provided, new-entrant assets are injected into `ts.gen`,
  `ts.ess`, `tv.gen_n`, and `tv.ess_n` after static tables are populated.
- `sc_buildouts::Dict{Int,String} = Dict{Int,String}()`: Optional per-scenario
  sheet mapping. When empty (default) and `buildout_filepath` is set, uniform
  mode is used with sheet `"buildout_1"`.
"""
function _build_ISP24_datasets_impl(;
    downloadpath::AbstractString = normpath(@__DIR__, "../../", "data-download"),
    poe::Integer = 10,
    reftrace::Integer = 4006,
    years::Union{Nothing,AbstractVector{<:Integer}} = nothing,
    drange::Union{Nothing,AbstractVector} = nothing,
    output_name::AbstractString = "out",
    output_root::Union{Nothing,AbstractString} = nothing,
    write_csv::Bool = true,
    write_arrow::Bool = true,
    download_from_AEMO::Bool = true,
    scenarios::AbstractVector{<:Int64} = collect(keys(ParseISP.scenario_id_labels(ParseISP.ISP2024()))),
    write_traces::Bool = true,
    check_exist_trace::Bool = false,
    buildout_filepath::Union{Nothing,AbstractString} = nothing,
    sc_buildouts::Dict{Int,String} = Dict{Int,String}(),
)
    release = ParseISP.ISP2024()
    if years !== nothing && drange !== nothing
        throw(ArgumentError("Only one of `years` or `drange` may be specified, not both."))
    end
    if years === nothing && drange === nothing
        throw(ArgumentError("At least one of `years` or `drange` must be specified."))
    end
    if years !== nothing && any(y -> y < 2025 || y > 2050, years)
        throw(ArgumentError("Years must be between 2025 and 2050 (got $(years))."))
    end

    data_paths = ParseISP.default_data_paths(release, downloadpath)

    # Download/extract/build inputs once
    ParseISP.build_pipeline(data_root = downloadpath, poe = poe, download_files = download_from_AEMO, overwrite_extracts = false)

    base_name = "$(output_name)-ref$(reftrace)-poe$(poe)"

    function _traces_exist(tag::AbstractString)::Bool
        to_path(p) = isnothing(output_root) ? p : normpath(output_root, p)
        csv_ok   = !write_csv   || isfile(joinpath(to_path("$(base_name)/csv/schedule-$(tag)"),   "Generator_pmax_sched.csv"))
        arrow_ok = !write_arrow || isfile(joinpath(to_path("$(base_name)/arrow/schedule-$(tag)"), "Generator_pmax_sched.arrow"))
        return csv_ok && arrow_ok
    end

    items = years !== nothing ? years : drange
    mode  = years !== nothing ? :year : :drange

    for item in items
        tc, ts, tv = ParseISP.initialise_time_structures()

        if mode === :year
            fill_problem_table_year(tc, item, release = release, sce=scenarios)
            tag = string(item)
        else
            (raw_start, raw_end) = item
            ds = _to_datetime(raw_start, :start)
            de = _to_datetime(raw_end,   :end)
            fill_problem_table_drange(tc, ds, de, release = release, sce=scenarios)
            tag = "$(Dates.format(ds, "ddmmyyyy"))-$(Dates.format(de, "ddmmyyyy"))"
        end

        skip_traces = !write_traces || (check_exist_trace && _traces_exist(tag))
        if skip_traces
            @info "Skipping heavy trace computation for schedule $(tag) (write_traces=$(write_traces), check_exist_trace=$(check_exist_trace))"
        end

        static_params = ParseISP.populate_static!(release, ts, tv, data_paths; refyear = reftrace, poe = poe)
        @info "Populating time-varying data from ISP 2024 - POE $(poe) - reference weather trace $(reftrace) - schedule $(tag) ..."
        ParseISP.populate_varying!(release, tc, ts, tv, data_paths, static_params; refyear = reftrace, poe = poe, skip_traces = skip_traces)

        if buildout_filepath !== nothing
            _apply_buildouts!(ts, tv, buildout_filepath, sc_buildouts)
        end

        ParseISP.write_time_data(ts, tv;
            csv_static_path    = "$(base_name)/csv",
            csv_varying_path   = "$(base_name)/csv/schedule-$(tag)",
            arrow_static_path  = "$(base_name)/arrow",
            arrow_varying_path = "$(base_name)/arrow/schedule-$(tag)",
            write_static       = true,
            write_varying      = !skip_traces,
            output_root        = output_root,
            write_csv          = write_csv,
            write_arrow        = write_arrow,
        )
    end
end

build_ISP24_datasets(; kwargs...) = build_datasets(ISP2024(); kwargs...)

"""
    build_ISP26_datasets(; kwargs...)

Build datasets from the final 2026 ISP inputs using the same output contract as
`build_ISP24_datasets`. This path is intentionally final-2026-only: preliminary
artefacts, 2024 ISP model files, and 2019 workbooks are not valid inputs.
"""
function _build_ISP26_datasets_impl(;
    downloadpath::AbstractString = normpath(@__DIR__, "../../", "data-download"),
    poe::Integer = 10,
    reftrace::Integer = 4006,
    years::Union{Nothing,AbstractVector{<:Integer}} = nothing,
    drange::Union{Nothing,AbstractVector} = nothing,
    output_name::AbstractString = "out-isp2026",
    output_root::Union{Nothing,AbstractString} = nothing,
    write_csv::Bool = true,
    write_arrow::Bool = true,
    download_from_AEMO::Bool = true,
    prepare_outlook::Bool = true,
    prepare_supporting_assets::Bool = download_from_AEMO,
    build_traces::Bool = true,
    scenario_map = Dict{String,String}(),
    scenarios::AbstractVector{<:Int64} = collect(keys(ParseISP.scenario_id_labels(ParseISP.ISP2026()))),
)
    release = ParseISP.ISP2026()
    if years !== nothing && drange !== nothing
        throw(ArgumentError("Only one of `years` or `drange` may be specified, not both."))
    end
    if years === nothing && drange === nothing
        throw(ArgumentError("At least one of `years` or `drange` must be specified."))
    end
    if years !== nothing && any(y -> y < 2026 || y > 2050, years)
        throw(ArgumentError("Final ISP2026 trace sources cover planning years 2026 through 2050. Years must be between 2026 and 2050 (got $(years))."))
    end

    data_paths = ParseISP.default_data_paths(release, downloadpath)

    if download_from_AEMO
        ParseISP.download_isp26_source_files(downloadpath; skip_existing = true)
    end

    if prepare_supporting_assets
        ParseISP.extract_downloads(data_root = downloadpath, overwrite = false, quiet = true)
    end

    _require_existing_files(data_paths, (:inputs_workbook, :ev_inputs_workbook, :outlook_generation_storage_zip, :isp_model_zip, :solar_traces_zip, :wind_traces_zip))

    if prepare_outlook
        _require_existing_files(data_paths, (:outlook_generation_storage_zip,))
        ParseISP.prepare_isp26_outlook_aux(data_paths.outlook_generation_storage_zip;
            data_root = downloadpath,
            scenario_map = scenario_map)
    end

    if build_traces
        ParseISP.prepare_isp26_trace_inputs(;
            data_root = downloadpath,
            refyear = reftrace,
            poe = poe,
        )
    end

    base_name = "$(output_name)-ref$(reftrace)-poe$(poe)"
    items = years !== nothing ? years : drange
    mode  = years !== nothing ? :year : :drange

    for item in items
        tc, ts, tv = ParseISP.initialise_time_structures()

        if mode === :year
            fill_problem_table_year(tc, item, release = release, sce = scenarios)
            tag = string(item)
        else
            (raw_start, raw_end) = item
            ds = _to_datetime(raw_start, :start)
            de = _to_datetime(raw_end, :end)
            fill_problem_table_drange(tc, ds, de, release = release, sce = scenarios)
            tag = "$(Dates.format(ds, "ddmmyyyy"))-$(Dates.format(de, "ddmmyyyy"))"
        end

        static_params = ParseISP.populate_static!(release, ts, tv, data_paths; refyear = reftrace, poe = poe)
        @info "Populating time-varying data from final ISP 2026 - POE $(poe) - reference weather trace $(reftrace) - schedule $(tag) ..."
        ParseISP.populate_varying!(release, tc, ts, tv, data_paths, static_params; refyear = reftrace, poe = poe)
        ParseISP.require_unique_primary_keys!(ts)
        ParseISP.require_unique_time_varying_keys!(tv)

        ParseISP.write_time_data(ts, tv;
            csv_static_path    = "$(base_name)/csv",
            csv_varying_path   = "$(base_name)/csv/schedule-$(tag)",
            arrow_static_path  = "$(base_name)/arrow",
            arrow_varying_path = "$(base_name)/arrow/schedule-$(tag)",
            write_static       = true,
            write_varying      = true,
            output_root        = output_root,
            write_csv          = write_csv,
            write_arrow        = write_arrow,
        )
    end
end

build_ISP26_datasets(; kwargs...) = build_datasets(ISP2026(); kwargs...)
