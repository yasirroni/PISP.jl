const ISP2026_FIXABLE_BLOCKERS = Set([:unknown_bus_label])
const ISP2026_BUS_ALIASES = Dict("WNV" => "VIC", "SEV" => "VIC")

function _isp2026_line_option_active(option_name::AbstractString)
    return option_name in ["SQ-CQ Option 3", "NNSW–SQ Option 3"] ? 0 : 1
end

function _isp2026_bus_name(token)
    cleaned = strip(replace(string(token), '–' => '-', '—' => '-'))
    isempty(cleaned) && return nothing
    haskey(ISP2026_BUS_ALIASES, cleaned) && return ISP2026_BUS_ALIASES[cleaned]
    haskey(PISP.NEMBUSNAME, cleaned) && return PISP.NEMBUSNAME[cleaned]
    for (_, name) in PISP.NEMBUSNAME
        lowercase(strip(name)) == lowercase(cleaned) && return name
    end
    return nothing
end

function _isp2026_parse_buspair(cell; from_option_name::Bool = false)
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
    left = _isp2026_bus_name(parts[1])
    right = _isp2026_bus_name(parts[2])
    return left === nothing || right === nothing ? nothing : (left, right)
end

function _isp2026_first_buspair(row)
    for col in (7, 1, 6)
        col > length(row) && continue
        pair = _isp2026_parse_buspair(row[col])
        pair !== nothing && return (pair, col)
    end
    length(row) >= 4 || return nothing
    pair = _isp2026_parse_buspair(row[4]; from_option_name = true)
    pair !== nothing && return (pair, 1)
    return nothing
end

function canonicalize_line_invoptions(raw::DataFrame, report::ISPValidationReport)
    rows = DataFrame(source_row = Int[], layout = Symbol[], name = String[], busA = String[], busB = String[], idbusA = Int64[], idbusB = Int64[], fwd = Float64[], rev = Float64[], invcost = Float64[], lead = Float64[], active = Int[])

    for row_number in 1:nrow(raw)
        option_cell = raw[row_number, 4]
        option_text = strip(string(option_cell))
        if ismissing(option_cell) || isempty(option_text) || lowercase(option_text) == "option name"
            continue
        end

        buspair = _isp2026_first_buspair(raw[row_number, :])
        buspair === nothing && error("Unsupported ISP2026 bus pair or alias in $(option_text)")
        ((bus_from, bus_to), buspair_col) = buspair
        bus_from_id = PISP._ispdata_bus_id(bus_from)
        bus_to_id = PISP._ispdata_bus_id(bus_to)
        bus_from_id === nothing && error("Unsupported ISP2026 bus label in $(option_text)")
        bus_to_id === nothing && error("Unsupported ISP2026 bus label in $(option_text)")

        fwd_col  = buspair_col in (1, 4, 7) ? 8  : 7
        rev_col  = buspair_col in (1, 4, 7) ? 9  : 8
        cost_col = buspair_col in (1, 4, 7) ? 10 : 9
        lead_col = buspair_col in (1, 4, 7) ? 14 : 13

        fwd = PISP.flow2num(raw[row_number, fwd_col])
        rev = PISP.flow2num(raw[row_number, rev_col])
        cost = PISP.inv2num(split(string(raw[row_number, cost_col]), ['(', '\n']))
        lead = PISP.lead2year(split(string(raw[row_number, lead_col]), ['(', '\n'])[1])

        push!(rows, (row_number, report.layout, option_text, bus_from, bus_to, bus_from_id, bus_to_id, fwd, rev, cost, Float64(lead), _isp2026_line_option_active(option_text)))
    end

    return rows
end

function fix_isp2026_line_invoptions(raw::DataFrame, report::ISPValidationReport)
    report.layout == :isp2026 || error("ISP2026 fix requires the ISP2026 line-invoptions layout")

    unsupported = filter(report.findings) do finding
        finding.severity == :blocker && finding.code ∉ ISP2026_FIXABLE_BLOCKERS
    end
    isempty(unsupported) || error("Unsupported ill data in ISP2026 flow-path sheet")

    return (raw = raw, canonical = canonicalize_line_invoptions(raw, report), report = report)
end
