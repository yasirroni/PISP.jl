"""
    lead2year(str)

Translate textual lead-time classes from the ISP spreadsheets into the number of
years (e.g. "Long" => 8 years).
"""
function lead2year(str)
        s = lowercase(strip(string(str)))
        startswith(s, "long") && return 8
        startswith(s, "short") && return 2
        startswith(s, "medium") && return 4
        isempty(s) && return 4
        return 4
end

"""
    flow2num(str)

Coerce a textual flow entry (often containing commas or NA) into a `Float64`
value so that line limits can be manipulated numerically.
"""
function flow2num(str)
    s = lowercase(strip(string(str)))
    (isempty(s) || s == "na" || s == "missing" || s == "x") && return 0.0
    parsed = tryparse(Float64, replace(split(string(str), ['(', '\n'])[1], "," => ""))
    return parsed === nothing ? 0.0 : parsed
end

"""
    inv2num(str)

Convert investment cost strings that may contain descriptive text or two-part
values into a single numeric estimate. Non-network placeholders are mapped to a
large value (9999.0) to highlight missing cost data.
"""
function inv2num(str)
    isempty(str) && return 9999.0
    first = strip(string(str[1]))
    normalized = lowercase(first)
    if isempty(normalized) || normalized in ("missing", "x")
        return 9999.0
    end
    if first == "Non-network option costs to be provided by interested parties" || first == "Anticipated project."
        return 9999.0
    end

    first_num = tryparse(Float64, replace(first, "," => ""))
    first_num === nothing && return 9999.0
    length(str) < 6 && return first_num

    second = strip(string(str[3]))
    second_num = tryparse(Float64, replace(second, "," => ""))
    second_num === nothing && return first_num
    return first_num + second_num
end

"""
    fiscal_year(year)

Given a string like "2025-26", return a `DateTime` pointing to the start of the
fiscal year (1 July of the first year).
"""
function fiscal_year(year)
        # Given a year in the format "YYYY-YY", return the fiscal year starting in July 1st.
        y = split(year, "-")
        return DateTime(parse(Int, y[1]), 7, 1)
end

"""
    available_dsp(df_in)

Convert cumulative DSP availability bands into incremental values by differencing
each column. The first column (region/band identifiers) is preserved so the
output mirrors the input schema.
"""
function available_dsp(df_in)
    col1 = df_in[!, names(df_in)[1]]
    df   = df_in[!, 2:end]
    i=1
    for col in eachcol(df)
        v_diff = diff(col)
        v_diff = vcat(col[1], v_diff)
        df[!, i] = v_diff
        i+=1
    end
    df_new = hcat(col1, df)
    return df_new
end

"""
    inputDB_dsp(tv, df, der_ids, scenario; multiplier=1, release=ISP2024())

Transform DSP workbook data into DER load reduction entries and append them to
`tv.der_pred`. The helper handles seasonal dating (winter vs summer), scales each
band by `multiplier`, and maps bands onto supplied DER ids for the specified
scenario.
"""
function inputDB_dsp(tv, df, der_ids, scenario, multiplier=1; release::ParseISP.ISPRelease = ParseISP.ISP2024())
    df = available_dsp(df)
    der_pred_sched = tv.der_pred
    idx = isempty(der_pred_sched) ? 1 : maximum(der_pred_sched.id) + 1
    scenario_definitions = ParseISP.scenario_definitions(release)
    for yr in names(df)[2:end]
        if length(yr) == 4      # winter
            date_cost = DateTime(parse(Int64,yr[1:4]))+Month(3)
        elseif length(yr) == 7  # summer
            date_cost = DateTime(parse(Int64,yr[1:4]))+Month(10)
        else
            error("wrong year format")
        end
        dsp_pmax = df[!, yr]
        for band in 1:5 # LOOP OVER DSP BANDS (FROM CHEAPER TO EXPENSIVE, including reliability response (RR))
            dsp_pred = dsp_pmax[band]*multiplier
            row_der_predmax_ched = [idx, der_ids[band], scenario_definitions[scenario], date_cost, dsp_pred]
            push!(tv.der_pred, row_der_predmax_ched)
            idx+=1
        end
    end
end
