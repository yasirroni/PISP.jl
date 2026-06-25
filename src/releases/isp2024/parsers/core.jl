"""
    initialise_time_structures()

Create and return fresh `ParseISPtimeConfig`, `ParseISPtimeStatic`, and `ParseISPtimeVarying`
containers. Encapsulating this logic in one helper keeps the script consistent
any time new runs are started or when the structures are re-created in tests.

# Returns
- `Tuple{ParseISPtimeConfig,ParseISPtimeStatic,ParseISPtimeVarying}`: The three empty
  containers required by the subsequent population routines.
"""
function initialise_time_structures()
    return (ParseISPtimeConfig(), ParseISPtimeStatic(), ParseISPtimeVarying())
end

"""
    fill_problem_example(tc)

Example to populate the `tc.problem` table with a week-long block for each scenario
registered for `ISP2024`. The helper constructs start and end dates by
stepping from 1 January 2025 and wrapping at the June boundary so that no
interval spans financial years.

# Arguments
- `tc::ParseISPtimeConfig`: Time configuration container whose `problem` DataFrame
  receives the generated rows.
"""
function fill_problem_example(tc::ParseISPtimeConfig)
    start_date = DateTime(2030, 1, 1, 0, 0, 0)
    step_ = Day(120)
    nblocks = 3
    date_blocks = ParseISP.OrderedDict()
    ref_year = 2025

    for i in 1:nblocks
        dstart = start_date + (i - 1) * step_
        dend = dstart + Day(6) + Hour(23)

        if month(dend) >= 7 && month(dstart) <= 6
            dend = DateTime(year(dstart), month(dstart), 30, 23, 0, 0)
        end

        if i > 1 && day(date_blocks[i - 1][2]) == 30 && month(date_blocks[i - 1][2]) == 6
            dstart = DateTime(year(dstart), month(dstart), 1, 0, 0, 0)
        end

        date_blocks[i] = (dstart, dend)
    end

    i = 1
    scenario_labels = ParseISP.scenario_id_labels(ISP2024())
    for sc in keys(scenario_labels)
        pbname = "$(scenario_labels[sc])_$(i)"
        nd_yr = ref_year
        dstart = DateTime(nd_yr, month(date_blocks[i][1]), day(date_blocks[i][1]), 0, 0, 0)
        dend = DateTime(nd_yr, month(date_blocks[i][2]), day(date_blocks[i][2]), 23, 0, 0)
        arr = [i, replace(pbname, " " => "_"), sc, 1, "UC", dstart, dend, 60]
        push!(tc.problem, arr)
        i += 1
    end
end

"""
    populate_time_config!(tc)

Fill the time-configuration container with scenario metadata. This wrapper keeps
the mutation steps for `tc` in a single call-site so that new configuration
sections can be added in one place.

# Arguments
- `tc::ParseISPtimeConfig`: The configuration container to populate.

# Returns
- `ParseISPtimeConfig`: The same instance that was mutated, which permits piping the
  result into subsequent functions when convenient.
"""
function populate_time_config!(tc::ParseISPtimeConfig, fill_problem_function::Function)
    fill_problem_function(tc)
    return tc
end

"""
    populate_time_static!(tc, ts, tv, paths)

Construct the time-static portion of the ISP model. The function loads bus,
demand, line, generator, ESS and DER metadata using the file paths provided by
`paths` and stores the results in `ts` (with the required auxiliary data kept
for later steps).

# Arguments
- `tc::ParseISPtimeConfig`: Configuration container that supplies time blocks for demand processing.
- `ts::ParseISPtimeStatic`: Static data container that receives the tabular data.
- `tv::ParseISPtimeVarying`: Passed through so that `ParseISP.dem_load` can populate the static and varying demand components together.
- `paths::NamedTuple`: Must contain `profiledata`, `ispdata19`, and `ispdata24`.

# Returns
- `NamedTuple`: Contains `txdata` (line metadata) and `generator_tables`
  (currently exposing the `SYNC4`, `GENERATORS`, and `PS` tables) that are
  required by the time-varying stage.
"""
function _neutral_isp2024_paths(paths::NamedTuple)
    :inputs_workbook in keys(paths) && return paths
    return (
        inputs_workbook = paths.ispdata24,
        legacy_inputs_workbook = paths.ispdata19,
        ev_inputs_workbook = paths.iasr23_ev_workbook,
        isp_model_dir = paths.ispmodel,
        trace_dir = paths.profiledata,
        core_outlook_dir = paths.outlookdata,
        capacity_outlook_workbook = paths.outlookAEMO,
        storage_capacity_outlook_workbook = paths.vpp_cap,
        storage_energy_outlook_workbook = paths.vpp_ene,
    )
end

function populate_static!(release::ISP2024, ts::ParseISPtimeStatic, tv::ParseISPtimeVarying, paths::NamedTuple; refyear::Int64=2011, poe::Int64=10)
    paths = _neutral_isp2024_paths(paths)
    ParseISP.bus_table(ts)
    ParseISP.dem_load(ts)

    txdata = ParseISP.line_table(ts, tv, paths.inputs_workbook; release = release)
    ParseISP.line_invoptions(ts, paths.inputs_workbook)

    SYNC4, GENERATORS, PS = ParseISP.generator_table(ts, paths.legacy_inputs_workbook, paths.inputs_workbook)
    ParseISP.ess_tables(ts, tv, PS, paths.inputs_workbook; release = release)
    ParseISP.der_tables(ts)
    ParseISP.ev_der_tables(ts)

    return (
        txdata = txdata,
        generator_tables = (SYNC4 = SYNC4, GENERATORS = GENERATORS, PS = PS),
    )
end

populate_time_static!(ts::ParseISPtimeStatic, tv::ParseISPtimeVarying, paths::NamedTuple; kwargs...) =
    populate_static!(ISP2024(), ts, tv, paths; kwargs...)

"""
    populate_time_varying!(tc, ts, tv, paths, static_artifacts; refyear::Int64=2011)

Populate the time-varying data structures such as schedules, inflows and DER
profiles. The function expects the `static_artifacts` output of
`populate_time_static!` so that line schedules and generator schedules can be
derived without recomputing inputs.

# Arguments
- `tc::ParseISPtimeConfig`: Provides the configured periods for time-varying traces.
- `ts::ParseISPtimeStatic`: Supplies static context for inflows and DER schedules.
- `tv::ParseISPtimeVarying`: Target container for time-varying tables.
- `paths::NamedTuple`: Must include `profiledata`, `ispdata24`, `outlookdata`,
  `outlookAEMO`, `vpp_cap`, `vpp_ene`, and `dsp_data`.
- `static_artifacts::NamedTuple`: A direct output of
  `populate_time_static!`, providing `txdata`, `SYNC4`, and `GENERATORS`.

# Returns
- `NamedTuple`: Contains `SNOWY_GENS`, which may be needed by downstream
  post-processing utilities.
"""
function populate_varying!(release::ISP2024, tc::ParseISPtimeConfig, ts::ParseISPtimeStatic, tv::ParseISPtimeVarying,
        paths::NamedTuple, static_artifacts::NamedTuple; refyear::Int64=2011, poe::Int64=10, skip_traces::Bool=false)
    paths = _neutral_isp2024_paths(paths)
    txdata = static_artifacts.txdata
    generator_tables = static_artifacts.generator_tables
    ParseISP.dem_load_sched(tc, tv, paths.trace_dir; refyear=refyear, poe=poe, release=release)
    ParseISP.line_sched_table(tc, tv, txdata)
    ParseISP.gen_n_sched_table(tv, generator_tables.SYNC4, generator_tables.GENERATORS; release=release)
    ParseISP.gen_retirements(ts, tv;
        retirements = ParseISP.generator_retirements(release),
        reductions = ParseISP.capacity_reductions(release),
        scenario_ids = keys(ParseISP.scenario_id_labels(release)))
    ParseISP.gen_pmax_distpv(tc, ts, tv, paths.trace_dir; refyear=refyear, poe=poe, release=release, skip_traces=skip_traces)
    ParseISP.gen_pmax_solar(tc, ts, tv, paths.inputs_workbook, paths.core_outlook_dir, paths.capacity_outlook_workbook, paths.trace_dir; refyear=refyear, release=release, skip_traces=skip_traces)
    ParseISP.gen_pmax_wind(tc, ts, tv, paths.inputs_workbook, paths.core_outlook_dir, paths.capacity_outlook_workbook, paths.trace_dir; refyear=refyear, release=release, skip_traces=skip_traces)
    SNOWY_GENS = ParseISP.gen_inflow_sched(ts, tv, tc, paths.inputs_workbook, paths.isp_model_dir; release=release)

    ParseISP.ess_vpps(tc, ts, tv, paths.storage_capacity_outlook_workbook, paths.storage_energy_outlook_workbook; release=release, skip_traces=skip_traces)
    ParseISP.ess_inflow_sched(ts, tv, tc, paths.inputs_workbook, SNOWY_GENS; release=release)
    ParseISP.der_pred_sched(ts, tv, paths.inputs_workbook; release=release)
    ParseISP.ev_der_sched(tc, ts, tv, paths.inputs_workbook, paths.ev_inputs_workbook)
end

populate_time_varying!(tc::ParseISPtimeConfig, ts::ParseISPtimeStatic, tv::ParseISPtimeVarying,
        paths::NamedTuple, static_artifacts::NamedTuple; kwargs...) =
    populate_varying!(ISP2024(), tc, ts, tv, paths, static_artifacts; kwargs...)

"""
    write_time_data(ts, tv; csv_static_path, csv_varying_path,
                    arrow_static_path, arrow_varying_path,
                    write_static, write_varying)

Persist the populated static and time-varying tables to CSV and Arrow formats.
Output paths default to the test folders used prior to the refactor but can be
overridden via keyword arguments.

# Keyword Arguments
- `csv_static_path`:    Target directory for static CSV exports.
- `csv_varying_path`:   Target directory for time-varying CSV exports.
- `arrow_static_path`:  Target directory for static Arrow exports.
- `arrow_varying_path`: Target directory for time-varying Arrow exports.
- `write_static`:       Set to `false` to skip writing the static tables.
- `write_varying`:      Set to `false` to skip writing the time-varying tables.
"""
function write_time_data(
        ts::ParseISPtimeStatic,
        tv::ParseISPtimeVarying;
        csv_static_path::AbstractString,
        csv_varying_path::AbstractString,
        arrow_static_path::AbstractString,
        arrow_varying_path::AbstractString,
        write_static::Bool  = true,
        write_varying::Bool = true,
        output_root::Union{Nothing,AbstractString} = nothing,
        write_csv::Bool = true,
        write_arrow::Bool = true
)
    to_path(p) = isnothing(output_root) ? p : normpath(output_root, p)

    if write_static
        if write_csv ParseISP.ParseISPwritedataCSV(ts, to_path(csv_static_path)) end
        if write_arrow ParseISP.ParseISPwritedataArrow(ts, to_path(arrow_static_path)) end
    end

    if write_varying
        if write_csv ParseISP.ParseISPwritedataCSV(tv, to_path(csv_varying_path)) end
        if write_arrow ParseISP.ParseISPwritedataArrow(tv, to_path(arrow_varying_path)) end
    end
end
