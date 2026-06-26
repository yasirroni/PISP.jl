struct ISPDataFinding
    severity::Symbol
    code::Symbol
    message::String
    row::Union{Nothing,Int}
    column::Union{Nothing,Int}
    source_file::Union{Nothing,String}
    sheet::Union{Nothing,String}
    field::Union{Nothing,String}
    suggestion::Union{Nothing,String}
end

ISPDataFinding(severity::Symbol, code::Symbol, message::String,
    row::Union{Nothing,Int}, column::Union{Nothing,Int}) =
    ISPDataFinding(severity, code, message, row, column, nothing, nothing, nothing, nothing)

struct ISPValidationReport
    source::String
    layout::Symbol
    findings::Vector{ISPDataFinding}
end

const ISP2026_MISSING_TOKENS = Set(["", "na", "n/a", "missing", "x", "-"])
const ISP2026_OUTLOOK_CORE_PREFIXES = ("Cores/", "Core scenarios/")
const ISP2026_OUTLOOK_SENSITIVITY_PREFIXES = ("Sensitivities/",)
const ISP2026_STATIC_PRIMARY_KEYS = Dict(
    :bus => :id_bus,
    :dem => :id_dem,
    :ess => :id_ess,
    :gen => :id_gen,
    :line => :id_lin,
    :der => :id_der,
)
const ISP2026_TIME_VARYING_KEY_COLUMNS = Dict(
    :dem_load => :id_dem,
    :ess_emax => :id_ess,
    :ess_lmax => :id_ess,
    :ess_n => :id_ess,
    :ess_pmax => :id_ess,
    :ess_inflow => :id_ess,
    :gen_n => :id_gen,
    :gen_pmax => :id_gen,
    :gen_inflow => :id_gen,
    :line_fwcap => :id_lin,
    :line_rvcap => :id_lin,
    :der_pred => :id_der,
)

_isp2026_is_core_outlook_entry(entry::AbstractString) =
    any(prefix -> startswith(entry, prefix), ISP2026_OUTLOOK_CORE_PREFIXES)

_isp2026_is_sensitivity_outlook_entry(entry::AbstractString) =
    any(prefix -> startswith(entry, prefix), ISP2026_OUTLOOK_SENSITIVITY_PREFIXES)

function _ispdata_addfinding!(findings, severity::Symbol, code::Symbol, message::AbstractString;
        row::Union{Nothing,Int} = nothing,
        column::Union{Nothing,Int} = nothing,
        source_file::Union{Nothing,AbstractString} = nothing,
        sheet::Union{Nothing,AbstractString} = nothing,
        field::Union{Nothing,AbstractString} = nothing,
        suggestion::Union{Nothing,AbstractString} = nothing)
    push!(findings, ISPDataFinding(
        severity,
        code,
        String(message),
        row,
        column,
        source_file === nothing ? nothing : String(source_file),
        sheet === nothing ? nothing : String(sheet),
        field === nothing ? nothing : String(field),
        suggestion === nothing ? nothing : String(suggestion),
    ))
end

function _ispdata_is_missing_token(cell)
    cell isa AbstractString || return false
    return lowercase(strip(cell)) in ISP2026_MISSING_TOKENS
end

function _isp2026_text_or_empty(cell)
    (cell === missing || _ispdata_is_missing_token(cell)) && return ""
    return strip(string(cell))
end

function _isp2026_dsp_nondata_row(region::AbstractString, band::AbstractString,
        scenario::AbstractString, season::AbstractString)
    fields = (region, band, scenario, season)
    all(isempty, fields) && return true
    if lowercase(region) == "region" && lowercase(band) == "price band" &&
            lowercase(scenario) == "scenario" && lowercase(season) == "season"
        return true
    end
    return region in ("Summer", "Winter") && isempty(band) && isempty(scenario) && isempty(season)
end

function _ispdata_tryparse_float(cell)
    cell === missing && return nothing
    cell isa Number && return Float64(cell)
    text = strip(replace(string(cell), "," => ""))
    isempty(text) && return nothing
    text = split(text, ['(', '[', '\n'])[1]
    m = match(r"^[-+]?\d+(?:\.\d+)?", text)
    m === nothing && return nothing
    return tryparse(Float64, m.match)
end

function parse_isp2026_number(cell; percent_as_fraction::Bool = false)
    cell === missing && return nothing
    cell isa Number && return Float64(cell)
    _ispdata_is_missing_token(cell) && return nothing

    text = strip(string(cell))
    isempty(text) && return nothing
    has_percent = occursin("%", text)
    cleaned = replace(text, "," => "", "%" => "")
    cleaned = split(cleaned, ['(', '[', '\n'])[1]
    m = match(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?", cleaned)
    m === nothing && return nothing

    value = tryparse(Float64, m.match)
    value === nothing && return nothing
    return percent_as_fraction && has_percent ? value / 100.0 : value
end

function parse_isp2026_date(cell)
    cell === missing && return nothing
    cell isa DateTime && return cell
    cell isa Date && return DateTime(cell)
    if cell isa Number
        return DateTime(Date(1899, 12, 30) + Day(round(Int, Float64(cell))))
    end

    text = strip(string(cell))
    isempty(text) && return nothing
    for fmt in (dateformat"yyyy-mm-dd", dateformat"dd/mm/yyyy", dateformat"d/mm/yyyy",
            dateformat"dd-mm-yyyy", dateformat"d-mm-yyyy", dateformat"yyyy/mm/dd")
        parsed = try
            Date(text, fmt)
        catch
            nothing
        end
        parsed === nothing || return DateTime(parsed)
    end

    return try
        DateTime(text)
    catch
        nothing
    end
end

_isp2026_year_columns(df::DataFrame) =
    filter(name -> occursin(r"^\d{4}(?:-\d{2})?$", String(name)), names(df))

function _isp2026_require_columns!(findings, df::DataFrame, required::Vector{String};
        source_file = nothing, sheet = nothing)
    present = Set(names(df))
    for column in required
        column in present && continue
        _ispdata_addfinding!(findings, :blocker, :missing_column,
            "Missing required column `$(column)`.",
            source_file = source_file,
            sheet = sheet,
            field = column,
            suggestion = "Check the source range and header row.")
    end
end

function _isp2026_validate_numeric_field!(findings, value, label::AbstractString;
        row::Union{Nothing,Int} = nothing,
        source_file = nothing,
        sheet = nothing,
        percent_as_fraction::Bool = false,
        allow_missing::Bool = false)
    if value === missing || _ispdata_is_missing_token(value)
        severity = allow_missing ? :warning : :blocker
        _ispdata_addfinding!(findings, severity, :missing_value_token,
            "Missing value in `$(label)`.",
            row = row,
            source_file = source_file,
            sheet = sheet,
            field = label,
            suggestion = "Confirm whether the source should be blank or parser-fillable.")
        return nothing
    end

    parsed = parse_isp2026_number(value; percent_as_fraction = percent_as_fraction)
    if parsed === nothing
        _ispdata_addfinding!(findings, :blocker, :invalid_numeric_value,
            "Cannot parse `$(label)` as a number.",
            row = row,
            source_file = source_file,
            sheet = sheet,
            field = label,
            suggestion = "Use a numeric value, percentage, or documented missing token.")
        return nothing
    end

    if value isa AbstractString
        _ispdata_addfinding!(findings, :warning, :numeric_as_string,
            "Numeric value stored as text in `$(label)`.",
            row = row,
            source_file = source_file,
            sheet = sheet,
            field = label,
            suggestion = "Parser will normalize this value explicitly.")
    end

    return parsed
end

function validate_isp2026_dsp_table(raw::DataFrame;
        source::AbstractString = "DSP",
        source_file::Union{Nothing,AbstractString} = nothing,
        sheet::AbstractString = "DSP")
    findings = ISPDataFinding[]
    required = ["Region", "Price band", "Scenario", "Season"]
    _isp2026_require_columns!(findings, raw, required; source_file = source_file, sheet = sheet)
    isempty(filter(f -> f.severity == :blocker, findings)) || return ISPValidationReport(source, :isp2026, findings)

    year_columns = _isp2026_year_columns(raw)
    isempty(year_columns) && _ispdata_addfinding!(findings, :blocker, :missing_year_columns,
        "No financial-year or calendar-year columns found.",
        source_file = source_file,
        sheet = sheet,
        suggestion = "Expected columns like `2026-27` or `2027`.")

    allowed_regions = Set(["NSW", "QLD", "SA", "TAS", "VIC"])
    allowed_scenarios = Set(keys(ParseISP.scenario_definitions(ParseISP.ISP2026())))
    allowed_seasons = Set(["Summer", "Winter"])
    allowed_bands = Set(["\$300-\$500", "\$500-\$7500", "\$7500+", "Reliability Response",
        "Reliability Response in % of Peak Demand*"])
    seen = Set{Tuple{String,String,String,String}}()

    for row_number in 1:nrow(raw)
        region = _isp2026_text_or_empty(raw[row_number, "Region"])
        band = _isp2026_text_or_empty(raw[row_number, "Price band"])
        scenario = _isp2026_text_or_empty(raw[row_number, "Scenario"])
        season = _isp2026_text_or_empty(raw[row_number, "Season"])
        _isp2026_dsp_nondata_row(region, band, scenario, season) && continue

        region in allowed_regions || _ispdata_addfinding!(findings, :blocker, :unknown_region_label,
            "Unknown DSP region `$(region)`.",
            row = row_number,
            source_file = source_file,
            sheet = sheet,
            field = "Region",
            suggestion = "Add an explicit region alias or reject the source row.")
        scenario in allowed_scenarios || _ispdata_addfinding!(findings, :blocker, :unknown_scenario_label,
            "Unknown DSP scenario `$(scenario)`.",
            row = row_number,
            source_file = source_file,
            sheet = sheet,
            field = "Scenario",
            suggestion = "Map the source scenario to an ISP2026 scenario id.")
        season in allowed_seasons || _ispdata_addfinding!(findings, :blocker, :unknown_season_label,
            "Unknown DSP season `$(season)`.",
            row = row_number,
            source_file = source_file,
            sheet = sheet,
            field = "Season",
            suggestion = "Expected `Summer` or `Winter`.")
        band in allowed_bands || _ispdata_addfinding!(findings, :blocker, :unknown_price_band,
            "Unknown DSP price band `$(band)`.",
            row = row_number,
            source_file = source_file,
            sheet = sheet,
            field = "Price band",
            suggestion = "Add a band mapping before consuming this row.")

        key = (region, band, scenario, season)
        if key in seen
            _ispdata_addfinding!(findings, :blocker, :duplicate_key,
                "Duplicate DSP row for $(join(key, " / ")).",
                row = row_number,
                source_file = source_file,
                sheet = sheet,
                suggestion = "Keep exactly one row per region, band, scenario, and season.")
        else
            push!(seen, key)
        end

        percent_row = occursin("%", band)
        percent_row && _ispdata_addfinding!(findings, :info, :informational_percent_band,
            "DSP percentage row is informational and will not be scheduled.",
            row = row_number,
            source_file = source_file,
            sheet = sheet,
            field = "Price band")

        for year_column in year_columns
            parsed = _isp2026_validate_numeric_field!(findings, raw[row_number, year_column], year_column;
                row = row_number,
                source_file = source_file,
                sheet = sheet,
                percent_as_fraction = percent_row)
            if parsed !== nothing && parsed < 0
                _ispdata_addfinding!(findings, :blocker, :negative_numeric_value,
                    "Negative DSP value in `$(year_column)`.",
                    row = row_number,
                    source_file = source_file,
                    sheet = sheet,
                    field = year_column,
                    suggestion = "DSP availability should be non-negative.")
            end
        end
    end

    return ISPValidationReport(source, :isp2026, findings)
end

function validate_isp2026_ev_subregional_allocation(raw::DataFrame;
        source::AbstractString = "Battery & Plug-in EVs energy allocation",
        source_file::Union{Nothing,AbstractString} = nothing,
        sheet::AbstractString = "Battery & Plug-in EVs")
    findings = ISPDataFinding[]
    required = ["Region", "Subregion", "Scenario"]
    _isp2026_require_columns!(findings, raw, required; source_file = source_file, sheet = sheet)
    isempty(filter(f -> f.severity == :blocker, findings)) || return ISPValidationReport(source, :isp2026, findings)

    year_columns = _isp2026_year_columns(raw)
    isempty(year_columns) && _ispdata_addfinding!(findings, :blocker, :missing_year_columns,
        "No EV allocation year columns found.",
        source_file = source_file,
        sheet = sheet,
        suggestion = "Expected columns like `2026-27`.")

    allowed_regions = Set(["NSW", "QLD", "SA", "TAS", "VIC", "WEM"])
    allowed_scenarios = Set(keys(ParseISP.scenario_definitions(ParseISP.ISP2026())))
    allowed_subregions = Set(vcat(collect(keys(ParseISP.NEMBUSNAME)), ["MEL", "SEV", "WNV", "NSA", "WEM"]))
    seen = Set{Tuple{String,String,String}}()

    for row_number in 1:nrow(raw)
        region = strip(string(raw[row_number, "Region"]))
        isempty(region) && continue
        subregion = strip(string(raw[row_number, "Subregion"]))
        scenario = strip(string(raw[row_number, "Scenario"]))

        region in allowed_regions || _ispdata_addfinding!(findings, :blocker, :unknown_region_label,
            "Unknown EV region `$(region)`.",
            row = row_number,
            source_file = source_file,
            sheet = sheet,
            field = "Region")
        subregion in allowed_subregions || _ispdata_addfinding!(findings, :blocker, :unknown_subregion_label,
            "Unknown EV subregion `$(subregion)`.",
            row = row_number,
            source_file = source_file,
            sheet = sheet,
            field = "Subregion",
            suggestion = "Add an explicit subregion-to-bus alias.")
        scenario in allowed_scenarios || _ispdata_addfinding!(findings, :blocker, :unknown_scenario_label,
            "Unknown EV scenario `$(scenario)`.",
            row = row_number,
            source_file = source_file,
            sheet = sheet,
            field = "Scenario")

        key = (region, subregion, scenario)
        if key in seen
            _ispdata_addfinding!(findings, :blocker, :duplicate_key,
                "Duplicate EV allocation row for $(join(key, " / ")).",
                row = row_number,
                source_file = source_file,
                sheet = sheet)
        else
            push!(seen, key)
        end

        for year_column in year_columns
            parsed = _isp2026_validate_numeric_field!(findings, raw[row_number, year_column], year_column;
                row = row_number,
                source_file = source_file,
                sheet = sheet)
            if parsed !== nothing && parsed < 0
                _ispdata_addfinding!(findings, :blocker, :negative_numeric_value,
                    "Negative EV allocation in `$(year_column)`.",
                    row = row_number,
                    source_file = source_file,
                    sheet = sheet,
                    field = year_column)
            end
        end
    end

    return ISPValidationReport(source, :isp2026, findings)
end

function validate_isp2026_hydro_trace(df::DataFrame, path::AbstractString)
    findings = ISPDataFinding[]
    filename = basename(path)
    nameset = Set(names(df))

    "Year" in nameset || _ispdata_addfinding!(findings, :blocker, :missing_column,
        "Hydro trace is missing `Year`.",
        source_file = path,
        field = "Year")

    expected = if startswith(filename, "MaxEnergyYear")
        :annual
    elseif startswith(filename, "HalfHourlyNaturalInflow")
        :halfhourly
    elseif startswith(filename, "DailyNaturalInflow") || startswith(filename, "MonthlyNaturalInflow")
        :daily
    else
        :unknown
    end

    if expected == :unknown
        _ispdata_addfinding!(findings, :warning, :unknown_hydro_trace_kind,
            "Hydro trace filename does not match a known ISP2026 pattern.",
            source_file = path,
            suggestion = "Document whether this file is applicable.")
    elseif expected == :annual
        ncol(df) > 1 || _ispdata_addfinding!(findings, :blocker, :missing_value_columns,
            "Annual hydro trace has no asset columns.",
            source_file = path)
    elseif expected == :halfhourly
        for column in vcat(["Month", "Day"], lpad.(string.(1:48), 2, '0'))
            column in nameset || _ispdata_addfinding!(findings, :blocker, :missing_column,
                "Half-hourly hydro trace is missing `$(column)`.",
                source_file = path,
                field = column)
        end
    elseif expected == :daily
        for column in ["Month", "Day"]
            column in nameset || _ispdata_addfinding!(findings, :blocker, :missing_column,
                "Daily hydro trace is missing `$(column)`.",
                source_file = path,
                field = column)
        end
        ("Inflows" in nameset || "1" in nameset) || _ispdata_addfinding!(findings, :blocker, :missing_value_columns,
            "Daily hydro trace needs `Inflows` or `1` value column.",
            source_file = path)
    end

    for column in names(df)
        column == "Year" && continue
        if column in ("Month", "Day")
            continue
        end
        for row_number in 1:nrow(df)
            value = df[row_number, column]
            parsed = _isp2026_validate_numeric_field!(findings, value, column;
                row = row_number,
                source_file = path,
                allow_missing = false)
            if parsed !== nothing && parsed < 0
                severity = expected == :annual ? :blocker : :warning
                _ispdata_addfinding!(findings, severity, :negative_numeric_value,
                    "Negative hydro trace value in `$(column)`.",
                    row = row_number,
                    source_file = path,
                    field = column,
                    suggestion = expected == :annual ? "Annual energy limits should be non-negative." : "Natural inflow schedules clamp negative net inflows to zero.")
            end
        end
    end

    return ISPValidationReport(filename, expected, findings)
end

function _ispdata_bus_name(token)
    cleaned = strip(replace(string(token), '–' => '-', '—' => '-'))
    isempty(cleaned) && return nothing
    haskey(ParseISP.NEMBUSNAME, cleaned) && return ParseISP.NEMBUSNAME[cleaned]
    for (_, name) in ParseISP.NEMBUSNAME
        lowercase(strip(name)) == lowercase(cleaned) && return name
    end
    return nothing
end

function _ispdata_buspair_tokens(cell; from_option_name::Bool = false)
    ismissing(cell) && return nothing
    text = strip(replace(string(cell), '–' => '-', '—' => '-'))
    isempty(text) && return nothing
    if from_option_name && occursin(r"(?i)\s+Option\b", text)
        text = strip(split(text, r"(?i)\s+Option\b"; limit = 2)[1])
        occursin(r"(?i)\bto\b", text) || occursin("->", text) || occursin("-", text) || return nothing
    end

    parts = if occursin(r"(?i)\bto\b", text)
        split(text, r"(?i)\s+to\s+"; limit = 2)
    elseif occursin("->", text)
        split(text, "->"; limit = 2)
    elseif occursin("-", text)
        split(text, "-"; limit = 2)
    else
        String[]
    end

    length(parts) == 2 || return nothing
    return (strip(parts[1]), strip(parts[2]))
end

function _ispdata_bus_id(token)
    cleaned = strip(replace(string(token), '–' => '-', '—' => '-'))
    isempty(cleaned) && return nothing
    for (idx, code) in enumerate(keys(ParseISP.NEMBUSES))
        if code == cleaned || lowercase(strip(ParseISP.NEMBUSNAME[code])) == lowercase(cleaned)
            return idx
        end
    end
    return nothing
end

function _ispdata_parse_buspair(cell; from_option_name::Bool = false)
    parts = _ispdata_buspair_tokens(cell; from_option_name = from_option_name)
    parts === nothing && return nothing
    left = _ispdata_bus_name(parts[1])
    right = _ispdata_bus_name(parts[2])
    return left === nothing || right === nothing ? nothing : (left, right)
end

function _ispdata_first_buspair(row)
    for col in (7, 1, 6)
        col > length(row) && continue
        pair = _ispdata_parse_buspair(row[col])
        pair !== nothing && return (pair, col)
    end
    length(row) >= 4 || return nothing
    pair = _ispdata_parse_buspair(row[4]; from_option_name = true)
    pair !== nothing && return (pair, 1)
    return nothing
end

function _ispdata_numeric_findings!(findings, row, col, label; row_number::Int)
    col > length(row) && begin
        _ispdata_addfinding!(findings, :blocker, :missing_column, "Missing $(label) column", row = row_number, column = col)
        return nothing
    end

    cell = row[col]
    cell === missing && begin
        _ispdata_addfinding!(findings, :warning, :missing_value_token, "Missing value in $(label)", row = row_number, column = col)
        return nothing
    end
    if _ispdata_is_missing_token(cell)
        _ispdata_addfinding!(findings, :warning, :missing_value_token, "Known missing-value token in $(label)", row = row_number, column = col)
        return nothing
    end

    value = _ispdata_tryparse_float(cell)
    if value === nothing
        _ispdata_addfinding!(findings, :blocker, :invalid_numeric_value, "Cannot parse $(label) as a number", row = row_number, column = col)
        return nothing
    end

    if cell isa AbstractString
        _ispdata_addfinding!(findings, :warning, :numeric_as_string, "Numeric value stored as text in $(label)", row = row_number, column = col)
    end

    if value < 0
        _ispdata_addfinding!(findings, :blocker, :negative_numeric_value, "Negative value found in $(label)", row = row_number, column = col)
    end

    return value
end

function validate_isp2026_line_invoptions(raw::DataFrame; source::AbstractString = "Flow Path Augmentation options")
    findings = ISPDataFinding[]
    layout = :legacy
    seen_keys = Set{Tuple{String,String,String}}()
    has_rows = false

    ncol(raw) < 14 && _ispdata_addfinding!(findings, :blocker, :unexpected_schema, "Expected at least 14 columns in $(source)")

    for row_number in 1:nrow(raw)
        row = raw[row_number, :]
        option_cell = raw[row_number, 4]
        option_text = strip(string(option_cell))
        if ismissing(option_cell) || isempty(option_text) || lowercase(option_text) == "option name"
            continue
        end

        has_rows = true
        buspair = nothing
        buspair_col = nothing
        saw_buspair_tokens = false
        unknown_buspair_tokens = false
        for (col, from_option_name) in ((7, false), (1, false), (6, false), (4, true))
            col > length(row) && continue
            parts = _ispdata_buspair_tokens(row[col]; from_option_name = from_option_name)
            parts === nothing && continue
            saw_buspair_tokens = true

            left = _ispdata_bus_name(parts[1])
            right = _ispdata_bus_name(parts[2])
            if left === nothing || right === nothing
                unknown_buspair_tokens = true
                col in (1, 4, 7) && (layout = :isp2026)
                continue
            end

            buspair = (left, right)
            buspair_col = col
            layout = col in (1, 4, 7) ? :isp2026 : :legacy
            break
        end

        buspair === nothing && begin
            if saw_buspair_tokens && unknown_buspair_tokens
                _ispdata_addfinding!(findings, :blocker, :unknown_bus_label, "Unknown bus label in $(option_text)", row = row_number)
            else
                _ispdata_addfinding!(findings, :blocker, :missing_buspair, "No bus pair could be parsed for $(option_text)", row = row_number)
            end
            continue
        end

        pair = buspair
        bus_from, bus_to = pair

        key = (option_text, bus_from, bus_to)
        if key in seen_keys
            _ispdata_addfinding!(findings, :blocker, :duplicate_option, "Duplicate option row for $(option_text) and $(bus_from) -> $(bus_to)", row = row_number)
        else
            push!(seen_keys, key)
        end

        if _ispdata_bus_name(bus_from) === nothing || _ispdata_bus_name(bus_to) === nothing
            _ispdata_addfinding!(findings, :blocker, :unknown_bus_label, "Unknown bus label in $(option_text)", row = row_number)
        end

        fwd_col  = layout == :isp2026 ? 8  : 7
        rev_col  = layout == :isp2026 ? 9  : 8
        cost_col = layout == :isp2026 ? 10 : 9
        lead_col = layout == :isp2026 ? 14 : 13

        _ispdata_numeric_findings!(findings, row, fwd_col,  "forward capacity"; row_number = row_number)
        _ispdata_numeric_findings!(findings, row, rev_col,  "reverse capacity"; row_number = row_number)
        _ispdata_numeric_findings!(findings, row, cost_col, "investment cost"; row_number = row_number)

        lead_cell = row[lead_col]
        if lead_cell === missing || _ispdata_is_missing_token(lead_cell)
            _ispdata_addfinding!(findings, :warning, :missing_value_token, "Known missing-value token in lead time", row = row_number, column = lead_col)
        else
            lead_text = lowercase(strip(string(lead_cell)))
            if startswith(lead_text, "long") || startswith(lead_text, "short") || startswith(lead_text, "medium")
                nothing
            elseif _ispdata_tryparse_float(lead_cell) !== nothing
                _ispdata_addfinding!(findings, :warning, :numeric_as_string, "Lead time stored as text in $(source)", row = row_number, column = lead_col)
            else
                _ispdata_addfinding!(findings, :blocker, :invalid_lead_value, "Cannot parse lead time label", row = row_number, column = lead_col)
            end
        end
    end

    if !has_rows
        _ispdata_addfinding!(findings, :blocker, :no_candidate_rows, "No candidate rows were found in $(source)")
    end

    return ISPValidationReport(source, layout, findings)
end

function validate_isp2026_outlook_entries(entries::AbstractVector{<:AbstractString})
    findings = ISPDataFinding[]
    workbook_entries = filter(entry -> endswith(lowercase(entry), ".xlsx") && !startswith(splitpath(entry)[end], "._"), entries)
    core_entries = filter(_isp2026_is_core_outlook_entry, workbook_entries)
    sensitivity_entries = filter(_isp2026_is_sensitivity_outlook_entry, workbook_entries)

    if isempty(core_entries)
        _ispdata_addfinding!(findings, :blocker, :missing_core_entries, "No core workbook entries were found in the outlook archive")
    end
    if isempty(sensitivity_entries)
        _ispdata_addfinding!(findings, :warning, :missing_sensitivity_entries, "No sensitivity workbook entries were found in the outlook archive")
    end

    if length(unique(entries)) != length(entries)
        _ispdata_addfinding!(findings, :blocker, :duplicate_archive_entry, "Duplicate file names were found in the outlook archive")
    end

    return (workbook_entries = workbook_entries,
            core_entries = core_entries,
            sensitivity_entries = sensitivity_entries,
            findings = findings)
end

function validate_time_static_primary_keys(ts::ParseISPtimeStatic;
        source::AbstractString = "time-static tables",
        max_findings::Int = 25)
    findings = ISPDataFinding[]

    for table_name in fieldnames(ParseISPtimeStatic)
        haskey(ISP2026_STATIC_PRIMARY_KEYS, table_name) || continue
        df = getfield(ts, table_name)
        isempty(df) && continue
        id_column = ISP2026_STATIC_PRIMARY_KEYS[table_name]

        if !(String(id_column) in names(df))
            _ispdata_addfinding!(findings, :blocker, :missing_column,
                "Static table `$(table_name)` is missing primary key `$(id_column)`.",
                field = string(table_name),
                suggestion = "Check the static table schema before writing output.")
            continue
        end

        counts = combine(groupby(df, id_column), nrow => :count)
        duplicate_rows = filter(row -> row.count > 1, counts)
        for row in Iterators.take(eachrow(duplicate_rows), max_findings)
            _ispdata_addfinding!(findings, :blocker, :duplicate_primary_key,
                "Static table `$(table_name)` has duplicate `$(id_column)` value `$(row[id_column])`.",
                field = string(table_name),
                suggestion = "Primary identifiers must be unique before output is written.")
        end
        if nrow(duplicate_rows) > max_findings
            _ispdata_addfinding!(findings, :blocker, :duplicate_primary_key_summary,
                "Static table `$(table_name)` has $(nrow(duplicate_rows)) duplicate primary-key values; first $(max_findings) are reported.",
                field = string(table_name))
        end
    end

    return ISPValidationReport(source, :primary_keys, findings)
end

function validate_time_varying_keys(tv::ParseISPtimeVarying;
        source::AbstractString = "time-varying schedules",
        max_findings::Int = 25)
    findings = ISPDataFinding[]

    for table_name in fieldnames(ParseISPtimeVarying)
        haskey(ISP2026_TIME_VARYING_KEY_COLUMNS, table_name) || continue
        df = getfield(tv, table_name)
        isempty(df) && continue
        id_column = ISP2026_TIME_VARYING_KEY_COLUMNS[table_name]
        required = [String(id_column), "scenario", "date"]

        missing_columns = setdiff(required, names(df))
        if !isempty(missing_columns)
            _ispdata_addfinding!(findings, :blocker, :missing_column,
                "Schedule `$(table_name)` is missing key column(s): $(join(missing_columns, ", ")).",
                field = string(table_name),
                suggestion = "Check the time-varying table schema before writing output.")
            continue
        end

        counts = combine(groupby(df, [id_column, :scenario, :date]), nrow => :count)
        duplicate_rows = filter(row -> row.count > 1, counts)
        for row in Iterators.take(eachrow(duplicate_rows), max_findings)
            _ispdata_addfinding!(findings, :blocker, :duplicate_time_key,
                "Schedule `$(table_name)` has duplicate key (`$(id_column)`=$(row[id_column]), scenario=$(row.scenario), date=$(row.date)).",
                field = string(table_name),
                suggestion = "Aggregate or remove duplicate schedule entries before writing output.")
        end
        if nrow(duplicate_rows) > max_findings
            _ispdata_addfinding!(findings, :blocker, :duplicate_time_key_summary,
                "Schedule `$(table_name)` has $(nrow(duplicate_rows)) duplicate keys; first $(max_findings) are reported.",
                field = string(table_name))
        end
    end

    return ISPValidationReport(source, :schedule_keys, findings)
end

has_blockers(report::ISPValidationReport) = any(f -> f.severity == :blocker, report.findings)

function require_clean_validation!(report::ISPValidationReport)
    blockers = filter(f -> f.severity == :blocker, report.findings)
    isempty(blockers) && return report
    messages = join(map(f -> "$(f.code): $(f.message)", blockers), "\n")
    error("Validation failed for $(report.source)\n$(messages)")
end

function require_unique_primary_keys!(ts::ParseISPtimeStatic; kwargs...)
    report = validate_time_static_primary_keys(ts; kwargs...)
    require_clean_validation!(report)
    return report
end

function require_unique_time_varying_keys!(tv::ParseISPtimeVarying; kwargs...)
    report = validate_time_varying_keys(tv; kwargs...)
    require_clean_validation!(report)
    return report
end
