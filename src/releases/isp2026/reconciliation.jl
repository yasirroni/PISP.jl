const ISP2026_OUTPUT_SCHEDULE_KEY_BY_FILE = Dict(
    "Demand_load_sched.csv" => :id_dem,
    "DER_pred_sched.csv" => :id_der,
    "ESS_emax_sched.csv" => :id_ess,
    "ESS_inflow_sched.csv" => :id_ess,
    "ESS_lmax_sched.csv" => :id_ess,
    "ESS_n_sched.csv" => :id_ess,
    "ESS_pmax_sched.csv" => :id_ess,
    "Generator_inflow_sched.csv" => :id_gen,
    "Generator_n_sched.csv" => :id_gen,
    "Generator_pmax_sched.csv" => :id_gen,
    "Line_fwcap_sched.csv" => :id_lin,
    "Line_rvcap_sched.csv" => :id_lin,
)

_isp2026_table(source::DataFrame) = copy(source)
_isp2026_table(source::AbstractString) = CSV.read(source, DataFrame)

function _isp2026_sha256(path::AbstractString)
    return open(path, "r") do io
        bytes2hex(sha256(io))
    end
end

function _isp2026_financial_year_label(value)
    dt = value isa DateTime ? value :
         value isa Date ? DateTime(value) :
         DateTime(string(value))
    start_year = month(dt) >= 7 ? year(dt) : year(dt) - 1
    return "$(start_year)-$(lpad(string((start_year + 1) % 100), 2, '0'))"
end

function isp2026_source_inventory(downloadpath::AbstractString)
    rows = NamedTuple[]
    for source in ISPFileDownloader.isp2026_source_metadata()
        path = normpath(downloadpath, source.local_path)
        exists = isfile(path)
        push!(rows, (
            key = source.key,
            title = source.title,
            status = source.status,
            local_path = source.local_path,
            path = path,
            exists = exists,
            bytes = exists ? filesize(path) : missing,
            sha256 = exists ? _isp2026_sha256(path) : missing,
            note = source.note,
        ))
    end
    return DataFrame(rows)
end

function validation_findings_dataframe(reports)
    rows = NamedTuple[]
    for report in reports
        for finding in report.findings
            push!(rows, (
                source = report.source,
                layout = report.layout,
                severity = finding.severity,
                code = finding.code,
                message = finding.message,
                row = finding.row,
                column = finding.column,
                source_file = finding.source_file,
                sheet = finding.sheet,
                field = finding.field,
                suggestion = finding.suggestion,
            ))
        end
    end
    return DataFrame(rows)
end

function _isp2026_reconcile_der_id_by_bus_suffix(der::DataFrame)
    lookup = Dict{Tuple{String,String},Int}()
    for row in eachrow(der)
        string(row.tech) == "DSP" || continue
        m = match(r"^DEM_(.+)_DSP_(BAND\d+|BANDRR)$", string(row.name))
        m === nothing && continue
        lookup[(String(m.captures[1]), String(m.captures[2]))] = Int(row.id_der)
    end
    return lookup
end

function expected_isp2026_dsp_schedule(inputs_workbook::AbstractString; der_table = nothing)
    raw = ParseISP.read_xlsx_with_header(inputs_workbook, "DSP", "B9:AG164")
    report = ParseISP.validate_isp2026_dsp_table(raw; source_file = inputs_workbook)
    ParseISP.require_clean_validation!(report)

    year_columns = ParseISP._isp2026_year_columns(raw)
    cumulative = Dict{Tuple{String,String,String,String},Dict{String,Float64}}()
    for row_number in 1:nrow(raw)
        region = ParseISP._isp2026_text_or_empty(raw[row_number, "Region"])
        band = ParseISP._isp2026_text_or_empty(raw[row_number, "Price band"])
        scenario = ParseISP._isp2026_text_or_empty(raw[row_number, "Scenario"])
        season = ParseISP._isp2026_text_or_empty(raw[row_number, "Season"])
        ParseISP._isp2026_dsp_nondata_row(region, band, scenario, season) && continue
        haskey(ParseISP.ISP2026_DSP_BAND_TO_DER_SUFFIX, band) || continue

        for year_column in year_columns
            value = ParseISP.parse_isp2026_number(raw[row_number, year_column])
            value === nothing && continue
            key = (region, scenario, season, String(year_column))
            values = get!(cumulative, key, Dict{String,Float64}())
            values[band] = value
        end
    end

    scenario_ids = ParseISP.scenario_definitions(ParseISP.ISP2026())
    der_lookup = der_table === nothing ? Dict{Tuple{String,String},Int}() :
        _isp2026_reconcile_der_id_by_bus_suffix(_isp2026_table(der_table))
    rows = NamedTuple[]

    for key in sort(collect(keys(cumulative)))
        region, scenario_name, season, year_label = key
        haskey(scenario_ids, scenario_name) || continue
        haskey(ParseISP.ISP2026_DSP_REGION_BUS_SHARES, region) || continue
        values = cumulative[key]
        previous = 0.0

        for band in ["\$300-\$500", "\$500-\$7500", "\$7500+"]
            haskey(values, band) || continue
            suffix = ParseISP.ISP2026_DSP_BAND_TO_DER_SUFFIX[band]
            source_region_value = max(values[band] - previous, 0.0)
            previous = values[band]
            for (bus, share) in ParseISP.ISP2026_DSP_REGION_BUS_SHARES[region]
                share == 0.0 && continue
                der_key = (bus, suffix)
                push!(rows, (
                    region = region,
                    bus = bus,
                    price_band = band,
                    der_suffix = suffix,
                    scenario_name = scenario_name,
                    scenario = scenario_ids[scenario_name],
                    season = season,
                    year_label = year_label,
                    date = _isp2026_dsp_schedule_date(year_label, season),
                    id_der = haskey(der_lookup, der_key) ? der_lookup[der_key] : missing,
                    source_value = source_region_value * share,
                ))
            end
        end

        band = "Reliability Response"
        if haskey(values, band)
            suffix = ParseISP.ISP2026_DSP_BAND_TO_DER_SUFFIX[band]
            for (bus, share) in ParseISP.ISP2026_DSP_REGION_BUS_SHARES[region]
                share == 0.0 && continue
                der_key = (bus, suffix)
                push!(rows, (
                    region = region,
                    bus = bus,
                    price_band = band,
                    der_suffix = suffix,
                    scenario_name = scenario_name,
                    scenario = scenario_ids[scenario_name],
                    season = season,
                    year_label = year_label,
                    date = _isp2026_dsp_schedule_date(year_label, season),
                    id_der = haskey(der_lookup, der_key) ? der_lookup[der_key] : missing,
                    source_value = max(values[band], 0.0) * share,
                ))
            end
        end
    end

    return DataFrame(rows)
end

function reconcile_isp2026_dsp_schedule(inputs_workbook::AbstractString, der_table, der_pred_schedule)
    expected = expected_isp2026_dsp_schedule(inputs_workbook; der_table = der_table)
    if any(ismissing, expected.id_der)
        missing_rows = expected[ismissing.(expected.id_der), [:bus, :der_suffix]]
        error("Cannot reconcile DSP schedule because DER ids are missing for: $(unique(missing_rows))")
    end

    actual = _isp2026_table(der_pred_schedule)
    actual = combine(groupby(actual, [:id_der, :scenario, :date]), :value => sum => :output_value)
    reconciled = leftjoin(expected, actual; on = [:id_der, :scenario, :date])
    reconciled.output_value = coalesce.(reconciled.output_value, 0.0)
    reconciled.diff = reconciled.output_value .- reconciled.source_value
    return reconciled
end

function summarize_isp2026_dsp_reconciliation(reconciled::DataFrame)
    grouped = combine(groupby(reconciled, [:scenario_name, :year_label, :region, :price_band, :season]),
        :source_value => sum => :source_value,
        :output_value => sum => :output_value,
        :diff => (x -> maximum(abs.(x))) => :max_abs_row_diff)
    grouped.diff = grouped.output_value .- grouped.source_value
    sort!(grouped, [:scenario_name, :year_label, :region, :price_band, :season])
    return grouped
end

function summarize_isp2026_der_pred_by_tech(der_table, der_pred_schedule)
    der = _isp2026_table(der_table)
    pred = _isp2026_table(der_pred_schedule)
    joined = leftjoin(pred, der[:, [:id_der, :name, :tech]]; on = :id_der)
    joined.financial_year = _isp2026_financial_year_label.(joined.date)
    grouped = combine(groupby(joined, [:tech, :scenario, :financial_year]),
        nrow => :rows,
        :value => sum => :value_sum,
        :value => minimum => :min_value,
        :value => maximum => :max_value)
    sort!(grouped, [:tech, :scenario, :financial_year])
    return grouped
end

function _isp2026_hydro_trace_kind(filename::AbstractString)
    startswith(filename, "MaxEnergyYear") && return :annual
    startswith(filename, "HalfHourlyNaturalInflow") && return :halfhourly
    startswith(filename, "DailyNaturalInflow") && return :daily
    startswith(filename, "MonthlyNaturalInflow") && return :monthly
    return :unknown
end

function isp2026_hydro_trace_inventory(isp_model_dir::AbstractString;
        release::ISPRelease = ISP2026(),
        validate::Bool = true)
    rows = NamedTuple[]
    hydro_model_prefix = "$(ParseISP.release_year(release)) ISP"

    for (scenario_name, scenario_id) in ParseISP.scenario_definitions(release)
        hydro_root = normpath(isp_model_dir, "$(hydro_model_prefix) $(scenario_name)", "Traces", "hydro")
        if !isdir(hydro_root)
            push!(rows, (
                scenario_name = scenario_name,
                scenario = scenario_id,
                path = hydro_root,
                file = missing,
                trace_key = missing,
                kind = :missing_directory,
                mapped_generators = "",
                mapped_ess = "",
                blocker_findings = 1,
                warning_findings = 0,
                info_findings = 0,
            ))
            continue
        end

        for file in sort(filter(f -> endswith(f, ".csv") && !startswith(f, "._"), readdir(hydro_root)))
            path = normpath(hydro_root, file)
            trace_key = _isp2026_hydro_trace_key(path)
            report = if validate
                ParseISP.validate_isp2026_hydro_trace(CSV.read(path, DataFrame), path)
            else
                ISPValidationReport(file, _isp2026_hydro_trace_kind(file), ISPDataFinding[])
            end
            push!(rows, (
                scenario_name = scenario_name,
                scenario = scenario_id,
                path = path,
                file = file,
                trace_key = trace_key,
                kind = _isp2026_hydro_trace_kind(file),
                mapped_generators = join(get(ParseISP.ISP2026_HYDRO_TRACE_TO_GENERATORS, trace_key, String[]), "; "),
                mapped_ess = join(get(ParseISP.ISP2026_HYDRO_TRACE_TO_ESS, trace_key, String[]), "; "),
                blocker_findings = count(f -> f.severity == :blocker, report.findings),
                warning_findings = count(f -> f.severity == :warning, report.findings),
                info_findings = count(f -> f.severity == :info, report.findings),
            ))
        end
    end

    return DataFrame(rows)
end

function summarize_schedule_file(path::AbstractString; id_column::Union{Nothing,Symbol} = nothing)
    df = CSV.read(path, DataFrame)
    key_column = id_column === nothing ? get(ISP2026_OUTPUT_SCHEDULE_KEY_BY_FILE, basename(path), nothing) : id_column
    duplicate_keys = if key_column !== nothing && all(name -> name in names(df), String.([key_column, :scenario, :date]))
        counts = combine(groupby(df, [key_column, :scenario, :date]), nrow => :count)
        nrow(filter(row -> row.count > 1, counts))
    else
        missing
    end

    return (
        path = path,
        file = basename(path),
        rows = nrow(df),
        min_date = "date" in names(df) && nrow(df) > 0 ? minimum(df.date) : missing,
        max_date = "date" in names(df) && nrow(df) > 0 ? maximum(df.date) : missing,
        min_value = "value" in names(df) && nrow(df) > 0 ? minimum(df.value) : missing,
        max_value = "value" in names(df) && nrow(df) > 0 ? maximum(df.value) : missing,
        negative_values = "value" in names(df) ? count(<(0), df.value) : missing,
        duplicate_keys = duplicate_keys,
    )
end

function summarize_isp2026_output_root(output_root::AbstractString;
        base_name::AbstractString = "out-isp2026-ref4006-poe10")
    schedule_root = normpath(output_root, base_name, "csv")
    isdir(schedule_root) || error("CSV output root not found: $(schedule_root)")

    rows = NamedTuple[]
    for entry in sort(readdir(schedule_root))
        startswith(entry, "schedule-") || continue
        schedule_dir = normpath(schedule_root, entry)
        isdir(schedule_dir) || continue
        for file in sort(filter(f -> endswith(f, ".csv"), readdir(schedule_dir)))
            summary = summarize_schedule_file(normpath(schedule_dir, file))
            push!(rows, merge((schedule = replace(entry, "schedule-" => ""),), summary))
        end
    end
    return DataFrame(rows)
end
