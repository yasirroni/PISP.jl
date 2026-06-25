struct ISPDataFinding
    severity::Symbol
    code::Symbol
    message::String
    row::Union{Nothing,Int}
    column::Union{Nothing,Int}
end

struct ISPValidationReport
    source::String
    layout::Symbol
    findings::Vector{ISPDataFinding}
end

const ISP2026_MISSING_TOKENS = Set(["", "na", "n/a", "missing", "x", "-"])

function _ispdata_addfinding!(findings, severity::Symbol, code::Symbol, message::AbstractString;
        row::Union{Nothing,Int} = nothing, column::Union{Nothing,Int} = nothing)
    push!(findings, ISPDataFinding(severity, code, String(message), row, column))
end

function _ispdata_is_missing_token(cell)
    cell isa AbstractString || return false
    return lowercase(strip(cell)) in ISP2026_MISSING_TOKENS
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

function _ispdata_bus_name(token)
    cleaned = strip(replace(string(token), '–' => '-', '—' => '-'))
    isempty(cleaned) && return nothing
    haskey(PISP.NEMBUSNAME, cleaned) && return PISP.NEMBUSNAME[cleaned]
    for (_, name) in PISP.NEMBUSNAME
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
    for (idx, code) in enumerate(keys(PISP.NEMBUSES))
        if code == cleaned || lowercase(strip(PISP.NEMBUSNAME[code])) == lowercase(cleaned)
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
    core_entries = filter(entry -> startswith(entry, "Cores/"), workbook_entries)
    sensitivity_entries = filter(entry -> startswith(entry, "Sensitivities/"), workbook_entries)

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

has_blockers(report::ISPValidationReport) = any(f -> f.severity == :blocker, report.findings)

function require_clean_validation!(report::ISPValidationReport)
    blockers = filter(f -> f.severity == :blocker, report.findings)
    isempty(blockers) && return report
    messages = join(map(f -> "$(f.code): $(f.message)", blockers), "\n")
    error("Validation failed for $(report.source)\n$(messages)")
end
