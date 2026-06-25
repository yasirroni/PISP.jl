function populate_static!(release::ISP2026, ts::ParseISPtimeStatic, tv::ParseISPtimeVarying, paths::NamedTuple; refyear::Int64=2011, poe::Int64=10)
    ParseISP.bus_table(ts)
    ParseISP.dem_load(ts)

    txdata = ParseISP.line_table(ts, tv, paths.inputs_workbook; release = release)
    ParseISP.line_invoptions(ts, paths.inputs_workbook)

    SYNC4, GENERATORS, PS = ParseISP.generator_table_isp2026(ts, paths.inputs_workbook)
    ParseISP.ess_tables(ts, tv, PS, paths.inputs_workbook; release = release)
    ParseISP.der_tables(ts)
    ParseISP.ev_der_tables(ts)

    return (
        txdata = txdata,
        generator_tables = (SYNC4 = SYNC4, GENERATORS = GENERATORS, PS = PS),
    )
end

function populate_varying!(release::ISP2026, tc::ParseISPtimeConfig, ts::ParseISPtimeStatic, tv::ParseISPtimeVarying,
        paths::NamedTuple, static_artifacts::NamedTuple; refyear::Int64=2011, poe::Int64=10)
    txdata = static_artifacts.txdata
    generator_tables = static_artifacts.generator_tables

    ParseISP.dem_load_sched(tc, tv, paths.trace_dir; refyear=refyear, poe=poe, release=release)
    ParseISP.line_sched_table(tc, tv, txdata)
    ParseISP.gen_n_sched_table(tv, generator_tables.SYNC4, generator_tables.GENERATORS; release=release)
    ParseISP.gen_retirements(ts, tv;
        retirements = ParseISP.generator_retirements(release),
        reductions = ParseISP.capacity_reductions(release),
        scenario_ids = keys(ParseISP.scenario_id_labels(release)))
    ParseISP.gen_pmax_distpv(tc, ts, tv, paths.trace_dir; refyear=refyear, poe=poe, release=release)
    ParseISP.gen_pmax_solar(tc, ts, tv, paths.inputs_workbook, paths.core_outlook_dir, paths.capacity_outlook_workbook, paths.trace_dir; refyear=refyear, release=release)
    ParseISP.gen_pmax_wind(tc, ts, tv, paths.inputs_workbook, paths.core_outlook_dir, paths.capacity_outlook_workbook, paths.trace_dir; refyear=refyear, release=release)
    snowy_gens = ParseISP.gen_inflow_sched(ts, tv, tc, paths.inputs_workbook, paths.isp_model_dir; release=release)

    ParseISP.ess_vpps(tc, ts, tv, paths.storage_capacity_outlook_workbook, paths.storage_energy_outlook_workbook; release=release)
    ParseISP.ess_inflow_sched(ts, tv, tc, paths.inputs_workbook, snowy_gens; release=release)
    ParseISP.der_pred_sched(ts, tv, paths.inputs_workbook; release=release)
    ParseISP.ev_der_sched(tc, ts, tv, paths.inputs_workbook, paths.ev_inputs_workbook; release=release)
end
