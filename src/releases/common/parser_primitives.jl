"""
    bus_table(ts)

Populate the `ts.bus` time-static table with every transmission node defined in
`ParseISP.NEMBUSES`. Each entry captures the bus id, name, alias, geographic coordinates, and area identifier so downstream routines can
refer to a consistent index of locations.

# Arguments
- `ts::ParseISPtimeStatic`: Static container whose `bus` table is mutated in place.
"""
function bus_table(ts::ParseISPtimeStatic)
    idx = 1
    for b in keys(ParseISP.NEMBUSES)
        push!(ts.bus,(idx, b, ParseISP.NEMBUSNAME[b], 1, ParseISP.NEMBUSES[b][1], ParseISP.NEMBUSES[b][2], ParseISP.STID[ParseISP.BUS2AREA[b]]))
        idx += 1
    end
end

# Select daily trace rows whose Year/Month/Day fall inside the requested window.
function select_trace_date_window(df::DataFrame, dstart::DateTime, dend::DateTime)
    trace_dates = Date.(df.Year, df.Month, df.Day)
    mask = (trace_dates .>= Date(dstart)) .& (trace_dates .<= Date(dend))
    df[mask, :]
end

function _parse_line_capacity(cell)
    text = split(string(cell), ['.', ' ', '\n'])[1]
    return parse(Int64, replace(text, "," => ""))
end

_numeric_or_default(value, default::Float64) = ismissing(value) ? default : Float64(value)

const ISP2026_FLOW_PATH_MAP = Dict(
    "CQ-NQ" => ("CQ", "NQ", "CQ->NQ"),
    "CQ-GG" => ("CQ", "GG", "CQ->GG"),
    "SQ-CQ" => ("SQ", "CQ", "SQ->CQ"),
    "NNSW-SQ" => ("NNSW", "SQ", "QNI South"),
    "NNSW-SQ (Terranora)" => ("NNSW", "SQ", "Terranora"),
    "CNSW-NNSW" => ("CNSW", "NNSW", "CNSW->NNSW"),
    "CNSW-SNW-NTH" => ("CNSW", "SNW", "CNSW->SNW North"),
    "CNSW-SNW-STH" => ("CNSW", "SNW", "CNSW->SNW South"),
    "SNSW-CNSW" => ("SNSW", "CNSW", "SNSW->CNSW"),
    "SNSW-CSA" => ("SNSW", "CSA", "Project EnergyConnect"),
    "WNV-SNSW" => ("VIC", "SNSW", "VNI North"),
    "TAS-SEV" => ("TAS", "VIC", "Basslink"),
    "WNV-SESA" => ("VIC", "SESA", "Heywood"),
    "WNV-CSA (Murraylink)" => ("VIC", "CSA", "Murraylink"),
    "SESA-CSA" => ("SESA", "CSA", "SESA->CSA"),
)

function line_table_isp2026(ts::ParseISPtimeStatic, inputs_workbook::String)
    bust = ts.bus
    datalines = ParseISP.read_xlsx_with_header(inputs_workbook, "Network Capability", "B6:H30")
    relialines = ParseISP.read_xlsx_with_header(inputs_workbook, "Transmission Reliability", "B7:G11")
    reliamap = Dict(
        "Heywood" => relialines[1, :],
        "Murraylink" => relialines[2, :],
        "Basslink" => relialines[3, :],
        "QNI South" => relialines[4, :],
    )
    results = DataFrame(name = String[], busA = String[], busB = String[], idbusA = Int64[], idbusB = Int64[], fwd_peak = Float64[], fwd_summer = Float64[], fwd_winter = Float64[], rev_peak = Float64[], rev_summer = Float64[], rev_winter = Float64[])

    for row in 2:nrow(datalines)
        flow_path = string(datalines[row, 1])
        haskey(ISP2026_FLOW_PATH_MAP, flow_path) || continue
        (bus_a, bus_b, alias) = ISP2026_FLOW_PATH_MAP[flow_path]
        id_a = bust[bust[!, :name] .== bus_a, :id_bus][1]
        id_b = bust[bust[!, :name] .== bus_b, :id_bus][1]
        capacities = [_parse_line_capacity(datalines[row, col]) for col in 2:7]
        push!(results, [string(bus_a, "->", bus_b), bus_a, bus_b, id_a, id_b, capacities...])

        line_id = nrow(results)
        maxcap = maximum((results[line_id, :fwd_winter], results[line_id, :rev_winter]))
        relia = get(reliamap, alias, nothing)
        push!(ts.line, (
            id_lin = line_id,
            name = results[line_id, :name],
            alias = alias,
            tech = "DC",
            capacity = maxcap,
            id_bus_from = id_a,
            id_bus_to = id_b,
            investment = 0,
            active = true,
            r = 0.01,
            x = 0.1,
            rvcap = results[line_id, :rev_winter],
            fwcap = results[line_id, :fwd_winter],
            fullout = relia === nothing ? 0.0 : _numeric_or_default(relia[3], 0.0),
            mttrfull = relia === nothing ? 1.0 : _numeric_or_default(relia[5], 1.0),
            voltage = 220.0,
            segments = 1,
            latitude = "",
            longitude = "",
            length = 1.0,
            n = 1,
            contingency = 0,
        ))
    end

    return results
end

"""
    line_table(ts, tv, inputs_workbook)

Read the ISP 2024 workbook to build the transmission line table: seasonal
forward/reverse limits, interconnector reliability parameters, and a manual
record for Project EnergyConnect. Static information is written to `ts.line`
while a summary `DataFrame` of raw limits is returned for use by schedule
generation routines.

# Arguments
- `ts::ParseISPtimeStatic`: Receives the static line rows.
- `tv::ParseISPtimeVarying`: Used to seed the staged commissioning entries for
  Project EnergyConnect.
- `inputs_workbook::String`: Path to the ISP inputs workbook.

# Returns
- `DataFrame`: Raw seasonal capacity data keyed by line alias.
"""
function line_table(ts::ParseISPtimeStatic, tv::ParseISPtimeVarying, inputs_workbook::String; release::ParseISP.ISPRelease = ParseISP.ISP2024())
    if release isa ParseISP.ISP2026
        return line_table_isp2026(ts, inputs_workbook)
    end

    bust = ts.bus
    # Read ISP Workbook with line capacities
    DATALINES   = ParseISP.read_xlsx_with_header(inputs_workbook, "Network Capability", "B6:H21")
    RELIALINES  = ParseISP.read_xlsx_with_header(inputs_workbook, "Transmission Reliability", "B7:G11")
    Results = DataFrame(name = String[], busA = String[], busB = String[], idbusA = Int64[], idbusB = Int64[], fwd_peak = Float64[], fwd_summer = Float64[], fwd_winter = Float64[], rev_peak = Float64[], rev_summer = Float64[], rev_winter = Float64[])
    # Link names
    NEMTX = ["CQ->NQ", "CQ->GG", "SQ->CQ", "QNI North", "Terranora", "QNI South","CNSW->SNW North","CNSW->SNW South", "VNI North","VNI South","Heywood","SESA->CSA","Murraylink", "Basslink"]
    RELIAMAP = Dict(NEMTX[11] => RELIALINES[1,:], # Heywood
                NEMTX[13] => RELIALINES[2,:], # Murraylink
                NEMTX[14] => RELIALINES[3,:], # Basslink
                NEMTX[4]  => RELIALINES[4,:], # QNI North
                NEMTX[6]  => RELIALINES[4,:]  # QNI South
            )
    # Link is Interconnector?
    INT = [false, false, false, true, true, false, false, false, false, true, true, false, true, true]
    NEMTYPE = ["DC", "DC", "DC", "DC", "DC", "DC", "DC", "DC", "DC", "DC", "DC", "DC", "DC", "DC"]
    #Build summary of capacities
    for a in 2:nrow(DATALINES)
        aux = []
        nar = split(DATALINES[a,1]," "); 
        length(nar) == 1 ? nar = split(DATALINES[a,1],"-") : nar = nar
        if length(nar) > 2 deleteat!(nar, 2) end
        bn1 = string(nar[1]); bn2 = string(nar[2]);
        # NAME_LINK, BUS_FROM, BUS_TO, BUS_ID_FROM, BUS_ID_TO
        aux = [string(bn1, "->", bn2), bn1, bn2, bust[bust[!,:name] .== bn1,:id_bus][1], bust[bust[!,:name] .== bn2,:id_bus][1]]
        # Add columns 
        for b in 2:ncol(DATALINES)
            #FWD_PEAK, FWD_SUMMER, FWD_WINTER, REV_PEAK, REV_SUMMER, REV_WINTER
            data = _parse_line_capacity(DATALINES[a, b])
            append!(aux, data)
        end
        push!(Results, aux)
    end

    #Populate Line table
    for a in 1:nrow(Results)
        #ID, NAME, ALIAS, TECH, CAPACITY, BUS_ID_FROM, BUS_ID_TO, INVESTMENT, ACTIVE, R, X, TMIN, TMAX, VOLTAGE, SEGMENTS, LATITUDE, LONGITUDE, LENGTH, N, CONTINGENCY
        maxcap = maximum([Results[a, :fwd_winter], Results[a, :rev_winter]])
        alias = NEMTX[a]
        vallin = (
                id_lin     = a,
                name        = Results[a, :name],
                alias       = NEMTX[a],
                tech        = NEMTYPE[a],
                capacity    = maxcap,
                id_bus_from = Results[a, :idbusA],
                id_bus_to   = Results[a, :idbusB],
                investment  = 0,
                active      = true,
                r           = 0.01,
                x           = 0.1,
                rvcap       = Results[a, :rev_winter],
                fwcap       = Results[a, :fwd_winter],
                fullout     = haskey(RELIAMAP, alias) ? RELIAMAP[alias][3] : 0, # reliability values for interconnectors that have data available
                mttrfull    = haskey(RELIAMAP, alias) ? RELIAMAP[alias][5] : 1, 
                voltage     = 220.0,
                segments    = 1,
                latitude    = "",
                longitude   = "",
                length      = 1.0,
                n           = 1,
                contingency = 0
            )
            push!(ts.line, vallin)
    end

    # Manual register of Project EnergyConnect 
    npln        = nrow(ts.line) 
    maxidlin    = isempty(ts.line) ? 0 : maximum(ts.line.id_lin)

    # Build the new row
    new_line = (
        id_lin      = maxidlin + 1,
        name        = "SNSW->CSA",
        alias       = "Project EnergyConnect",
        tech        = "DC",
        capacity    = 800,
        id_bus_from = 8,
        id_bus_to   = 11,
        investment  = 0,
        active      = 1,
        r           = 0.01,
        x           = 0.1,
        rvcap       = 800,
        fwcap       = 800,
        fullout     = 0, # reliability values for interconnectors that have data available
        mttrfull    = 1, 
        voltage     = 220.0,
        segments    = 1,
        latitude    = "",
        longitude   = "",
        length      = 1.0,
        n           = 1,
        contingency = 0
    )
    push!(ts.line, new_line)

    function insert_line_schedule!(df::DataFrame, line_id, scenario, date, capacity)
        newrow = (
            id       = nrow(df) + 1,
            id_lin   = line_id,
            scenario = scenario,
            date     = date,
            value    = capacity
        )
        push!(df, newrow)
    end

    # Project EnergyConnect Stage 1: 150MW in 2024
    for s in keys(ParseISP.scenario_id_labels(release))
        insert_line_schedule!(tv.line_fwcap, 15, s, DateTime(2024, 7, 1), 150)
        insert_line_schedule!(tv.line_rvcap, 15, s, DateTime(2024, 7, 1), 150)
    end

    # Stage 2
    for s in keys(ParseISP.scenario_id_labels(release))
        insert_line_schedule!(tv.line_fwcap, 15, s, DateTime(2026, 7, 1), 800)
        insert_line_schedule!(tv.line_rvcap, 15, s, DateTime(2026, 7, 1), 800)
    end
    return Results
end

"""
    line_sched_table(tc, tv, TXdata)

Convert the static line ratings returned by `line_table` into time-varying
limits for every scenario. A winter/summer split is applied at the
problem level so each week inherits the appropriate seasonal value, adding an
extra transition row when a window straddles the boundary.

# Arguments
- `tc::ParseISPtimeConfig`: Supplies start/end timestamps for each problem block.
- `tv::ParseISPtimeVarying`: Target schedule tables (`line_fwcap`, `line_rvcap`).
- `TXdata::DataFrame`: Raw ratings from `line_table` indexed by line.
"""
function line_sched_table(tc::ParseISPtimeConfig, tv::ParseISPtimeVarying, TXdata::DataFrame)
    wmonths = [4,5,6,7,8,9]     # Winter months
    smonths = [10,11,12,1,2,3]  # Summer months
    probs   = tc.problem        # Call problem table 

    txd_max = isempty(tv.line_fwcap) ? 1 : maximum(tv.line_fwcap.id) + 1
    txd_min = isempty(tv.line_rvcap) ? 1 : maximum(tv.line_rvcap.id) + 1
    
    for txid in 1:nrow(TXdata)
        for p in 1:nrow(probs)
            scid = probs[p,:scenario][1]    # Scenario ID
            dstart = probs[p,:dstart]       # Start date of a week
            dend = probs[p,:dend]           # End date of a week
            ys = Dates.year(dstart)         # Start year of a week
            ds = Dates.day(dstart)          # Start day of a week
            de = Dates.day(dend)            # End day of a week
            ms = Dates.month(dstart)        # Start month of a week
            me = Dates.month(dend)          # End month of a week

            if ms in wmonths                # If starting month is in winter months
                push!(tv.line_fwcap, (id=txd_max, id_lin=txid, scenario=scid, date=DateTime(dstart), value=TXdata[txid,8]))
                push!(tv.line_rvcap, (id=txd_min, id_lin=txid, scenario=scid, date=DateTime(dstart), value=TXdata[txid,11]))
            else
                push!(tv.line_fwcap, (id=txd_max, id_lin=txid, scenario=scid, date=DateTime(dstart), value=TXdata[txid,7]))
                push!(tv.line_rvcap, (id=txd_min, id_lin=txid, scenario=scid, date=DateTime(dstart), value=TXdata[txid,10]))
            end
            txd_max += 1
            txd_min += 1

            if (ms in wmonths && me in smonths) || (ms in smonths && me in wmonths)
                # @warn "Problem start month is in winter and end month is in summer, check written data."
                if me in wmonths
                    push!(tv.line_fwcap, (id=txd_max, id_lin=txid, scenario=scid, date=DateTime(ys,me,1), value=TXdata[txid,8]))
                    push!(tv.line_rvcap, (id=txd_min, id_lin=txid, scenario=scid, date=DateTime(ys,me,1), value=TXdata[txid,11]))
                else
                    push!(tv.line_fwcap, (id=txd_max, id_lin=txid, scenario=scid, date=DateTime(ys,me,1), value=TXdata[txid,7]))
                    push!(tv.line_rvcap, (id=txd_min, id_lin=txid, scenario=scid, date=DateTime(ys,me,1), value=TXdata[txid,10]))
                end
                txd_max += 1
                txd_min += 1
            end
        end
    end
end

"""
    line_invoptions(ts, inputs_workbook)

Parse the flow-path augmentation options sheet and append candidate lines to the
static line table.
"""
function line_invoptions(ts::ParseISPtimeStatic, inputs_workbook::String)
    raw = ParseISP.read_isp2026_line_invoptions_raw(inputs_workbook)
    report = ParseISP.validate_isp2026_line_invoptions(raw)

    canonical = if report.layout == :isp2026
        ParseISP.fix_isp2026_line_invoptions(raw, report).canonical
    else
        ParseISP.require_clean_validation!(report)
        ParseISP.canonicalize_line_invoptions(raw, report)
    end

    ParseISP.build_line_invoptions_from_canonical!(ts, canonical)
    return ts
end

const ISP2026_GENERATOR_BUS_ALIASES = Dict(
    "MEL" => "VIC",
    "SEV" => "VIC",
    "WNV" => "VIC",
    "NSA" => "CSA",
)

const ISP2026_PUMPED_STORAGE_STATIONS = Set([
    "Borumba",
    "Kidston ",
    "Shoalhaven",
    "Snowy 2.0",
    "Tumut 3",
    "Wivenhoe",
])

function _isp2026_cell_string(value)
    ismissing(value) && return ""
    return string(value)
end

function _isp2026_number(value, default::Float64 = 0.0)
    ismissing(value) && return default
    value isa Number && return Float64(value)
    text = strip(replace(string(value), "," => ""))
    isempty(text) && return default
    lowercase(text) in ("not found", "n/a", "na", "-") && return default
    parsed = tryparse(Float64, text)
    return parsed === nothing ? default : parsed
end

function _isp2026_excel_date(value, default::DateTime = DateTime(2020, 1, 1))
    ismissing(value) && return default
    value isa DateTime && return value
    value isa Date && return DateTime(value)
    value isa Number && return DateTime(1899, 12, 30) + Day(round(Int, value))

    text = strip(string(value))
    isempty(text) && return default
    parsed_dt = tryparse(DateTime, text)
    parsed_dt !== nothing && return parsed_dt
    parsed_d = tryparse(Date, text)
    parsed_d !== nothing && return DateTime(parsed_d)
    return default
end

function _isp2026_station_name(name)
    text = _isp2026_cell_string(name)
    text == "Bogong / Mackay" && return "Bogong / MacKay"
    text == "Devils Gate" && return "Devils gate"
    return text
end

function _isp2026_bus_code(subregion)
    code = _isp2026_cell_string(subregion)
    return get(ISP2026_GENERATOR_BUS_ALIASES, code, code)
end

function _isp2026_bus_id(bust::DataFrame, subregion)
    bus_code = _isp2026_bus_code(subregion)
    matches = bust[bust[!, :name] .== bus_code, :id_bus]
    isempty(matches) && error("Unsupported ISP2026 generator sub-region `$(subregion)` mapped to `$(bus_code)`.")
    return Int64(matches[1])
end

function _isp2026_model_fuel_tech(name, raw_tech, raw_fuel, region)
    station = _isp2026_station_name(name)
    if haskey(ParseISP.units, station)
        unit = ParseISP.units[station]
        return (fuel = unit[2], tech = unit[3], type = unit[4], lat = Float64(unit[5]), lon = Float64(unit[6]))
    end

    tech_text = _isp2026_cell_string(raw_tech)
    fuel_text = _isp2026_cell_string(raw_fuel)
    region_text = _isp2026_cell_string(region)

    if fuel_text == "Water"
        tech = occursin("Pumped Hydro", tech_text) ? "Pumped-Storage" : "Reservoir"
        return (fuel = "Hydro", tech = tech, type = tech_text, lat = 0.0, lon = 0.0)
    elseif fuel_text == "Black Coal"
        tech = region_text == "QLD" ? "Black Coal QLD" : "Black Coal NSW"
        return (fuel = "Coal", tech = tech, type = tech_text, lat = 0.0, lon = 0.0)
    elseif fuel_text == "Brown Coal"
        return (fuel = "Coal", tech = "Brown Coal VIC", type = tech_text, lat = 0.0, lon = 0.0)
    elseif fuel_text == "Gas"
        tech = occursin("CCGT", tech_text) ? "CCGT" :
            occursin("Reciprocating", tech_text) ? "Reciprocating Engine" : "OCGT"
        return (fuel = "Natural Gas", tech = tech, type = tech_text, lat = 0.0, lon = 0.0)
    elseif fuel_text == "Liquid Fuel"
        return (fuel = "Diesel", tech = "Diesel", type = tech_text, lat = 0.0, lon = 0.0)
    elseif fuel_text == "Biomass"
        return (fuel = "Biomass", tech = "Biomass", type = tech_text, lat = 0.0, lon = 0.0)
    end

    return (fuel = fuel_text, tech = tech_text, type = tech_text, lat = 0.0, lon = 0.0)
end

function _isp2026_reliability(fuel, tech, capacity)
    fullout = if tech in ("Brown Coal", "Brown Coal VIC", "Black Coal NSW", "Black Coal QLD")
        0.07
    elseif fuel == "Hydro"
        0.06
    elseif fuel == "Biomass"
        0.04
    elseif tech in ("OCGT", "CCGT", "Reciprocating Engine", "Diesel")
        0.085
    else
        0.08
    end
    return (fullout = fullout, partialout = 0.0, derate = 0.0, mttrfull = 24.0, mttrpart = 1.0)
end

function _isp2026_slope(tech)
    if tech in ("Black Coal", "Black Coal NSW", "Black Coal QLD", "Brown Coal", "Brown Coal VIC")
        return 0.3
    elseif tech == "CCGT"
        return 0.4
    else
        return 0.6
    end
end

function _isp2026_inertia(tech)
    if tech in ("Reservoir", "Run-of-River")
        return 2.5
    elseif tech == "Pumped-Storage"
        return 2.2
    else
        return 4.0
    end
end

function _isp2026_generator_summary(inputs_workbook::String)
    summary = ParseISP.read_xlsx_with_header(inputs_workbook, "Existing Gen Data Summary", "B10:W600")
    summary = summary[.!ismissing.(summary[!, Symbol("IASR ID")]), :]
    filter!(row -> string(row[Symbol("IASR ID")]) != "IASR ID", summary)
    return summary
end

function _isp2026_commissioning_dates(inputs_workbook::String)
    raw = ParseISP.read_xlsx_with_header(inputs_workbook, "Maximum capacity", "B10:J600")
    dates = Dict{String, DateTime}()
    for row in eachrow(raw)
        iasr = _isp2026_cell_string(row[Symbol("IASR ID")])
        isempty(iasr) && continue
        iasr == "IASR ID" && continue
        dates[iasr] = _isp2026_excel_date(row[Symbol("Commissioning date")])
    end
    return dates
end

function _isp2026_ramp_rates(inputs_workbook::String)
    raw = ParseISP.read_xlsx_with_header(inputs_workbook, "Max Ramp Rates", "B8:F600")
    rates = Dict{String, Tuple{Float64, Float64}}()
    up_col = Symbol("Max Ramp Up\r\n(MW/min)")
    down_col = Symbol("Max Ramp Down\r\n(MW/min)")
    for row in eachrow(raw)
        iasr = _isp2026_cell_string(row[Symbol("IASR ID")])
        isempty(iasr) && continue
        rates[iasr] = (
            _isp2026_number(row[up_col], 9999.0),
            _isp2026_number(row[down_col], 9999.0),
        )
    end
    return rates
end

function _isp2026_summary_for_static(summary::DataFrame; pumped_storage::Bool)
    rows = filter(summary) do row
        tech = _isp2026_cell_string(row[Symbol("Technology Type")])
        fuel = _isp2026_cell_string(row[Symbol("Fuel Type")])
        station = _isp2026_station_name(row[Symbol("Power Station")])
        is_vre = fuel in ("Solar", "Wind") || tech in ("Large scale Solar PV", "Wind")
        is_ps = station in ISP2026_PUMPED_STORAGE_STATIONS || occursin("Pumped Hydro", tech)
        !is_vre && (pumped_storage ? is_ps : !is_ps)
    end
    return rows
end

function generator_table_isp2026(ts::ParseISPtimeStatic, inputs_workbook::String)
    isdir(".tmp") || mkdir(".tmp")
    bust = ts.bus
    summary = _isp2026_generator_summary(inputs_workbook)
    commissioning = _isp2026_commissioning_dates(inputs_workbook)
    ramp_rates = _isp2026_ramp_rates(inputs_workbook)

    sync_source = _isp2026_summary_for_static(summary; pumped_storage = false)
    ps_source = _isp2026_summary_for_static(summary; pumped_storage = true)

    sync_rows = NamedTuple[]
    gen_id = isempty(ts.gen.id_gen) ? 0 : maximum(ts.gen.id_gen)

    for sub in groupby(sync_source, Symbol("Power Station"))
        first_row = first(eachrow(sub))
        station = _isp2026_station_name(first_row[Symbol("Power Station")])
        model = _isp2026_model_fuel_tech(
            station,
            first_row[Symbol("Technology Type")],
            first_row[Symbol("Fuel Type")],
            first_row[Symbol("Region")],
        )

        unit_count = nrow(sub)
        total_capacity = sum(_isp2026_number(v) for v in sub[!, Symbol("Maximum capacity (MW)")])
        cap = unit_count == 0 ? 0.0 : total_capacity / unit_count
        msg = sum(_isp2026_number(v) for v in sub[!, Symbol("Minimum Stable Limit")]) / max(unit_count, 1)
        hrate = sum(_isp2026_number(v) for v in sub[!, Symbol("Marginal Heat Rate")]) / max(unit_count, 1)
        no_load = sum(_isp2026_number(v) for v in sub[!, Symbol("No-Load  Heat Rate")]) / max(unit_count, 1)
        id_bus = _isp2026_bus_id(bust, first_row[Symbol("Sub-region")])
        bus_data = bust[bust[!, :id_bus] .== id_bus, :]
        lat = model.lat == 0.0 ? Float64(bus_data[1, :latitude]) : model.lat
        lon = model.lon == 0.0 ? Float64(bus_data[1, :longitude]) : model.lon

        aliases = _isp2026_cell_string.(sub[!, Symbol("IASR ID")])
        rup = maximum([get(ramp_rates, alias, (9999.0, 9999.0))[1] for alias in aliases])
        rdw = maximum([get(ramp_rates, alias, (9999.0, 9999.0))[2] for alias in aliases])
        comm_dates = [get(commissioning, alias, DateTime(2020, 1, 1)) for alias in aliases]
        comm_date = minimum(comm_dates)
        reliability = _isp2026_reliability(model.fuel, model.tech, cap)
        gen_id += 1

        push!(sync_rows, (
            id_gen = gen_id,
            Generator = station,
            DUID = first(aliases),
            var"Commissioning date" = comm_date,
            id_bus = id_bus,
            MSG = msg,
            rup = rup,
            rdw = rdw,
            srmc = 0.0,
            fuel_cost = 0.0,
            vom = 0.0,
            fom = 0.0,
            hrate = hrate,
            Emissions = 0.0,
            fuel = model.fuel,
            tech = model.tech,
            type = model.type,
            CAPACITY = total_capacity,
            cap = cap,
            lat = lat,
            lon = lon,
            n = unit_count,
            fullout = reliability.fullout,
            partialout = reliability.partialout,
            derate = reliability.derate,
            mttrfull = reliability.mttrfull,
            mttrpart = reliability.mttrpart,
            no_load_heat_rate = no_load,
        ))
    end

    SYNC4 = DataFrame(sync_rows)
    sort!(SYNC4, [:fuel, :Generator])

    for (idx, row) in enumerate(eachrow(SYNC4))
        reliability_forate = 1.0 - (row.fullout + row.partialout * (1.0 - row.derate))
        pmin = row.MSG
        if row.fuel == "Natural Gas"
            if row.tech == "CCGT" && pmin == 0.0
                pmin = round(0.52 * row.cap, digits = 2)
            elseif row.tech == "OCGT" && pmin == 0.0
                pmin = round(0.33 * row.cap, digits = 2)
            end
        elseif row.fuel in ("Hydro", "Diesel") && pmin == 0.0
            pmin = round(0.2 * row.cap, digits = 2)
        end

        push!(ts.gen, (
            id_gen = idx,
            name = row.Generator,
            alias = ismissing(row.DUID) || isempty(string(row.DUID)) ? row.Generator : string(row.DUID),
            fuel = row.fuel,
            tech = row.tech,
            type = row.type,
            capacity = row.cap,
            forate = reliability_forate,
            fullout = row.fullout,
            partialout = row.partialout,
            derate = row.derate,
            mttrfull = row.mttrfull,
            mttrpart = row.mttrpart,
            id_bus = row.id_bus,
            pmin = pmin,
            pmax = row.cap,
            rup = row.rup,
            rdw = row.rdw,
            investment = 0,
            active = 1,
            cvar = row.srmc,
            cfuel = row.fuel_cost,
            cvom = row.vom,
            cfom = row.fom * 1000.0,
            co2 = row.Emissions,
            slope = _isp2026_slope(row.tech),
            hrate = row.hrate,
            pfrmax = row.cap * 0.1,
            g = 0.0,
            inertia = _isp2026_inertia(row.tech),
            ffr = 0,
            pfr = 1,
            res2 = 1,
            res3 = 0,
            powerfactor = 0.85,
            latitude = row.lat,
            longitude = row.lon,
            n = row.n,
            contingency = 1,
            down_time = 0.0,
            up_time = 0.0,
            last_state = 0.0,
            last_state_period = 0.0,
            last_state_output = 0.0,
            start_up_cost = row.fuel == "Coal" ? row.srmc * row.cap * 4.0 : 0.0,
            shut_down_cost = 0.0,
            start_up_time = 0.0,
            shut_down_time = 0.0,
        ))
    end

    id_by_name = Dict(row.name => row.id_gen for row in eachrow(ts.gen))
    SYNC4[!, :id_gen] = [id_by_name[row.Generator] for row in eachrow(SYNC4)]
    GENERATORS = select(ts.gen, [:id_gen, :name, :alias, :fuel, :tech, :type, :capacity, :id_bus, :pmax, :n])

    ps_rows = NamedTuple[]
    for sub in groupby(ps_source, Symbol("Power Station"))
        first_row = first(eachrow(sub))
        station = _isp2026_station_name(first_row[Symbol("Power Station")])
        unit_count = nrow(sub)
        total_capacity = sum(_isp2026_number(v) for v in sub[!, Symbol("Maximum capacity (MW)")])
        cap = unit_count == 0 ? 0.0 : total_capacity / unit_count
        aliases = _isp2026_cell_string.(sub[!, Symbol("IASR ID")])
        comm_dates = [get(commissioning, alias, DateTime(2020, 1, 1)) for alias in aliases]
        push!(ps_rows, (
            Generator = station,
            DUID = first(aliases),
            var"Commissioning date" = minimum(comm_dates),
            id_bus = _isp2026_bus_id(bust, first_row[Symbol("Sub-region")]),
            CAPACITY = total_capacity,
            cap = cap,
            n = unit_count,
            emax = sum(_isp2026_number(v) for v in sub[!, Symbol("Storage capacity (MWh)")]),
            pump_efficiency = sum(_isp2026_number(v, 70.0) for v in sub[!, Symbol("Pumping efficiency (%)")]) / max(unit_count, 1),
        ))
    end
    PS = DataFrame(ps_rows)

    XLSX.writetable(".tmp/SYNC4_ISP2026.xlsx", Tables.columntable(SYNC4); sheetname = "SYNC4", overwrite = true)
    XLSX.writetable(".tmp/GENERATORS_ISP2026.xlsx", Tables.columntable(ts.gen); sheetname = "Generators", overwrite = true)
    return SYNC4, GENERATORS, PS
end

"""
    generator_table(ts, legacy_inputs_workbook, inputs_workbook)

Consolidate all generator-related metadata: bus locations, capacities,
commitments, retirements, reliability, ramp rates and UC parameters. The helper
reads both the 2019 IASR (for coal-fired generator parameters) and 2024 ISP workbooks, 
writes the merged dataset into `ts.gen`, and returns auxiliary DataFrames required later  
for time-varying tables(synchronous unit limits, the full generator table, and the pumped-storage subset).

# Arguments
- `ts::ParseISPtimeStatic`: Static container that receives the combined generator
  table.
- `legacy_inputs_workbook::String`: Path to the historical assumptions workbook used for
  supplementary attributes.
- `inputs_workbook::String`: Path to the 2024 ISP workbook containing the latest
  capacities and commissioning data.

# Returns
- `Tuple{DataFrame,DataFrame,DataFrame}`: `(SYNC4, GENERATORS, PS)` for use by
  scheduling, ESS, and inflow routines.
"""
function generator_table(ts::ParseISPtimeStatic, legacy_inputs_workbook::String, inputs_workbook::String)
    # ============================================ #
    # ============== Generator data ============== #
    # ============================================ #
    isdir(".tmp") || mkdir(".tmp")
    bust = ts.bus
    # areat = PSO.gettable(socketSYS, "Area")

    # Month to number dict
    m2n = Dict( "jan" => 1, "feb" => 2, "mar" => 3, "apr" => 4, "may" => 5, "jun" => 6, "jul" => 7, "aug" => 8, "sep" => 9, "oct" => 10, "nov" => 11, "dec" => 12,
                "january" => 1, "february" => 2, "march" => 3, "april" => 4, "may" => 5, "june" => 6, "july" => 7, "august" => 8, "september" => 9, "october" => 10, "november" => 11, "december" => 12)

    str2date(date) = date isa Number ? Dates.DateTime(1899, 12, 30) + Dates.Day(date) : DateTime(parse(Int64,split(date,' ')[2]),m2n[lowercase(split(date,' ')[1])])
    MAPPING  = ParseISP.read_xlsx_with_header(inputs_workbook, "Summary Mapping", "B6:B680")      # EXISTING GENERATOR
    MAPPING2 = ParseISP.read_xlsx_with_header(inputs_workbook, "Summary Mapping", "AA6:AA680")    # MLF
    namedict = ParseISP.OrderedDict(zip(MAPPING[!,1], MAPPING2[!,1]))

    # ====================================== #
    # ==== General list of Power Plants ==== #
    # ====================================== #
    GENS = ParseISP.read_xlsx_with_header(inputs_workbook, "Maximum capacity", "B8:D260")
    GENS[!, :Generator] = [k == "Bogong / Mackay" ? "Bogong / MacKay" : k for k in GENS[!, :Generator]] # Fix for Bogong / Mackay
    GENS[!, :Generator] = [k == "Lincoln Gap Wind Farm - Stage 2" ? "Lincoln Gap Wind Farm - stage 2" : k for k in GENS[!, :Generator]] # Fix for Bogong / Mackay

    COMGEN_MAXCAP = ParseISP.read_xlsx_with_header(inputs_workbook, "Maximum capacity", "F8:I35")
    ADVGEN_MAXCAP = ParseISP.read_xlsx_with_header(inputs_workbook, "Maximum capacity", "K8:N24")

    MAPPING3 = ParseISP.read_xlsx_with_header(inputs_workbook, "Summary Mapping", "B4:I680")
    MAPPING3 = MAPPING3[completecases(MAPPING3),:]                              # SELECT ONLY ROWS OF MAPPING3 WITHOUT MISSING VALUES
    rename!(MAPPING3, 1 => :Generator)                                          # Rename first column to "Generator" 

    ngen = size(GENS, 1) # Number of existing generators
    GENS[!, Symbol("Commissioning date")] = [DateTime(2020) for k in 1:ngen]
    rename!(COMGEN_MAXCAP, [1,2,3,4] .=> names(GENS)) # Rename columns as columns in GENS
    rename!(ADVGEN_MAXCAP, [1,2,3,4] .=> names(GENS))

    append!(GENS, COMGEN_MAXCAP) # Create a unique dataframe with existing, commited and anticipated projects 
    append!(GENS, ADVGEN_MAXCAP) # TOTAL = EXISTING + COMMITED + ANTICIPATED = 295 GENERATORS

    GENS = leftjoin(GENS, MAPPING3, on = :Generator, makeunique=true)

    rename!(GENS, Symbol("Sub-region") => :Bus)
    select!(GENS, Not([:Region_1])) 
    GENS.id_bus = [bust[bust[!,:name] .== k, :id_bus][1] for k in GENS.Bus] 
    GENS.area_id .= 0
    GENS[!,:Generator] = [namedict[n] for n in GENS[!,:Generator]]
    # Transform columns id_bus and area_id to Int64 to save in database
    GENS.id_bus = Int64.(GENS.id_bus)
    GENS.area_id = Int64.(GENS.area_id)

    GENS[!, :Generator] = [k == "Devils Gate" ? "Devils gate" : k for k in GENS[!, :Generator]]
    GENS[!, :Generator] = [k == "Bungala One Solar Farm" ? "Bungala one Solar Farm" : k for k in GENS[!, :Generator]]
    GENS[!, :Generator] = [k == "Tallawarra B*" ? "Tallawarra B" : k for k in GENS[!, :Generator]] 

    XLSX.writetable(".tmp/GENS.xlsx", Tables.columntable(GENS); sheetname="Generators", overwrite=true)

    # ====================================== #
    # Units with unit commitment and ramping #
    # ====================================== #
    # Generation limits and stable levels for coal and gas generators
    DATA_COALMSG = ParseISP.read_xlsx_with_header(inputs_workbook, "Generation limits", "B8:D52")
    DATA_GPGMSG = ParseISP.read_xlsx_with_header(inputs_workbook, "GPG Min Stable Level", "B9:E34")
    select!(DATA_GPGMSG, Not(Symbol("Technology Type")))

    # Minimum up times for different units
    DATA_MINUP_UNITS = ParseISP.read_xlsx_with_header(inputs_workbook, "Min Up&Down Times", "B8:E25")
    DATA_MINUP_UNITS19 = ParseISP.read_xlsx_with_header(legacy_inputs_workbook, "Generation limits", "O9:Q69") # Min UP and DW - GAS+COAL UNITS (2019)
    select!(DATA_MINUP_UNITS, Not(Symbol("Technology Type")))
    XLSX.writetable(".tmp/DATA_MINUP_UNITS19.xlsx", Tables.columntable(DATA_MINUP_UNITS19); sheetname="Generators19", overwrite=true)
    # Ramp rates for different units
    UC = ParseISP.read_xlsx_with_header(inputs_workbook, "Max Ramp Rates", "B8:F72")
    select!(UC, Not(Symbol("Technology Type")))
    XLSX.writetable(".tmp/UC.xlsx", Tables.columntable(UC); sheetname="UC", overwrite=true)

    #DUID -> Dispatchable Unit Identifier
    rename!(UC, Dict(2 => Symbol("DUID"), 3 => :rup, 4 => :rdw));
    rename!(DATA_COALMSG, 2 => Symbol("DUID")); 
    rename!(DATA_GPGMSG, 2 => Symbol("DUID")); 
    rename!(DATA_MINUP_UNITS, [2,3] .=> [Symbol("DUID"),Symbol("MinUpTime")]); 
    rename!(DATA_COALMSG, 3 => Symbol("MSG")); 
    rename!(DATA_GPGMSG, 3 => Symbol("MSG")); 
    rename!(DATA_MINUP_UNITS19, [2,3] .=> [Symbol("DUID"),Symbol("MinUpTime")]);

    # ==> 5 DATAFRAMES: UC, DATA_COALMSG, DATA_GPGMSG, DATA_MINUP_UNITS, DATA_MINUP_UNITS19
    ## DATA_COALMSG -> Limits of Coal generation (Minimum Stable Generation)
    ## DATA_GPGMSG -> Limits of Gas turbines (Minimum Stable Generation)
    ## DATA_MINUP_UNITS -> Min UP and DW - GAS UNITS
    ## DATA_MINUP_UNITS19 -> Min UP and DW - GAS+COAL UNITS (2019)
    ## UC -> Max ramp up and down of generators

    # DATA_COALMSG contains the minimum stable generation for coal and gas
    append!(DATA_COALMSG, DATA_GPGMSG)
    XLSX.writetable(".tmp/DATA_COALGASMSG.xlsx", Tables.columntable(DATA_COALMSG); sheetname="CoalGasMSG", overwrite=true)

    # DATA_MINUP_UNITS contains the minimum up time for coal and gas units
    append!(DATA_MINUP_UNITS, DATA_MINUP_UNITS19)
    XLSX.writetable(".tmp/DATA_MINUP_UNITS.xlsx", Tables.columntable(DATA_MINUP_UNITS); sheetname="MinUpUnits", overwrite=true)

    # JOIN UC (Ramp Rates) with DATA_COALMSG (Minimum Stable Generation)
    UC = outerjoin(UC, DATA_COALMSG,on = :DUID,makeunique=true)
    XLSX.writetable(".tmp/UC1.xlsx", Tables.columntable(UC); sheetname="UC1", overwrite=true)

    # JOIN UC with DATA_MINUP_UNITS (Minimum Up Time)
    UC = outerjoin(UC,DATA_MINUP_UNITS,on = :DUID,makeunique=true)
    XLSX.writetable(".tmp/UC2.xlsx", Tables.columntable(UC); sheetname="UC2", overwrite=true)
    # Delete rows that if the string in column DUID contains "LD" - Asociated with Lidell Station (decommissioned)
    UC = UC[.!occursin.("LD",UC[!,:DUID]),:]
    # Create a unique column with the generator station name 
    UC[!,1] = [ismissing(UC[k,1]) ? UC[k,5] : UC[k,1] for k in eachindex(UC[:,1])]
    UC[!,1] = [ismissing(UC[k,1]) ? UC[k,7] : UC[k,1] for k in eachindex(UC[:,1])]
    select!(UC, Not([5,7])) # Eliminate columns 5 and 7
    UC = unique(UC) # Eliminate rows with the exact same information 
    filter!((row) -> !(row[1] == "Tallawarra" && row[6] == 6), UC)
    filter!((row) -> !(row[1] == "Townsville Power Station" && row[2] == "YABULU" && row[6] == 3), UC)
    filter!((row) -> !(row[1] == "Condamine A" && row[2] == "CPSA" && row[6] == 6), UC)
    filter!((row) -> !(row[1] == "Darling Downs" && row[2] == "DDPS1" && row[6] == 6), UC)
    filter!((row) -> !(row[1] == "Osborne" && row[2] == "OSB-AG" && row[6] == 6), UC)
    filter!((row) -> !(row[1] == "Pelican Point" && row[2] == "PPCCGT" && row[6] == 4), UC)
    filter!((row) -> !(row[1] == "Tamar Valley Combined Cycle" && row[2] == "TVCC201" && row[6] == 6), UC)
    XLSX.writetable(".tmp/UC2__.xlsx", Tables.columntable(UC); sheetname="UC2__", overwrite=true)
    # this is the rename as per the DUIDs are in the Retirement sheet
    DUIDar = Dict(      "CPSA_GT1"      => "CPSA", 
                        "CPSA_GT2"      => "CPSA", 
                        "CPSA_ST"      => "CPSA", 
                        "DDPS1_GT1"     => "DDPS1", 
                        "DDPS1_GT2"     => "DDPS1", 
                        "DDPS1_GT3"     => "DDPS1", 
                        "DDPS1_ST"     => "DDPS1",
                        "OsborneGT"     => "OSB-AG", 
                        "OsborneST"     => "OSB-AG",
                        "PPCCGTGT1"     => "PPCCGT", 
                        "PPCCGTGT2"     => "PPCCGT", 
                        "PPCCGTST"     => "PPCCGT",
                        "TVCC201_GT"    => "TVCC201")
    UC[!,:DUID] = [n in keys(DUIDar) ? DUIDar[n] : n for n in UC[!,:DUID]]
    XLSX.writetable(".tmp/UC3.xlsx", Tables.columntable(UC); sheetname="UC3", overwrite=true)

    # ====================================== #
    # ============= RETIREMENTS ============ #
    # ====================================== #
    UNITS = ParseISP.read_xlsx_with_header(inputs_workbook, "Retirement", "B9:D460")
    rename!(UNITS, 1 => "Generator")
    UNITS[!,:RETIRE] = DateTime.(ParseISP.parseif(UNITS[:,3]))

    # FIX SOME MISMATCHES BETWEEN NAMES IN SHEETS
    UNITS[!,:Generator] = [n == "Bogong / Mackay" ? "Bogong / MacKay" : n for n in UNITS[!,:Generator]]
    UNITS[!,:Generator] = [n == "Eraring*" ? "Eraring" : n for n in UNITS[!,:Generator]]

    # FIX DUID OF SOME UNITS THAT DO NOT HAVE DUID
    UNITS[UNITS[!,:Generator] .== "Kogan Gas", :DUID] .= "Kogan Gas"
    UNITS[UNITS[!,:Generator] .== "SA Hydrogen Turbine", :DUID] .= "SA Hydrogen Turbine"

    select!(UNITS,Not(3))
    XLSX.writetable(".tmp/RETIREMENTS.xlsx", Tables.columntable(UNITS); sheetname="Retirements", overwrite=true)

    # ====================================== #
    # ============= RELIABILITY ============ #
    # ====================================== #
    RELIA = ParseISP.read_xlsx_with_header(inputs_workbook, "Generator Reliability Settings", "B20:G28")
    RELIANEW = ParseISP.read_xlsx_with_header(inputs_workbook, "Generator Reliability Settings", "I20:N40")


    # ====================================== #
    # ========= GENERATION SUMMARY ========= #
    # ====================================== #
    GENSUM     = ParseISP.read_xlsx_with_header(inputs_workbook, "Existing Gen Data Summary", "B10:U319")
    GENSUM_ADD = ParseISP.read_xlsx_with_header(inputs_workbook, "Existing Gen Data Summary", "B382:U397")
    GENSUM     = vcat(GENSUM, GENSUM_ADD)
    GENSUM     = GENSUM[3:end,:]
    flagrow    = [!all(ismissing.(Matrix(GENSUM[k:k,2:end]))) for k in 1:nrow(GENSUM)]
    GENSUM     = GENSUM[flagrow,:]
    GENSUM     = GENSUM[.!ismissing.(GENSUM[!,2]),:]
    GENSUM     = GENSUM[GENSUM[!,2] .!= "Generator type",:]
    GENSUM     = GENSUM[GENSUM[!,2] .!= "Battery Storage",:]
    GENSUM[!,:Generator] = [namedict[n] for n in GENSUM[!,:Generator]]
    GENSUM[!,:Generator] = [n == "Tallawarra B*" ? "Tallawarra B" : n for n in GENSUM[!,:Generator]]
    GENSUM[!,:Generator] = [n == "Bungala One Solar Farm" ? "Bungala one Solar Farm" : n for n in GENSUM[!,:Generator]]
    GENSUM[!,:Generator] = [n == "Devils Gate" ? "Devils gate" : n for n in GENSUM[!,:Generator]]
    XLSX.writetable(".tmp/GENSUM.xlsx", Tables.columntable(GENSUM); sheetname="GENSUM", overwrite=true)

    FULL = outerjoin(UNITS, GENS, on = :Generator)
    XLSX.writetable(".tmp/FULL.xlsx", Tables.columntable(FULL); sheetname="FULL", overwrite=true)

    FULL = outerjoin(FULL, UC, on = :DUID, matchmissing=:equal)
    rename!(FULL, Dict(:Region => :Area,  Symbol("Installed capacity (MW)") => :CAPACITY, Symbol("Generator Station") => :NAME))
    XLSX.writetable(".tmp/FULL2.xlsx", Tables.columntable(FULL); sheetname="FULL2", overwrite=true)

    FULL = outerjoin(FULL, GENSUM, on = :Generator, matchmissing=:equal, makeunique=true)
    FULL.id_bus = [ismissing(k) ? missing : bust[bust[!,:name] .== k, :id_bus][1] for k in FULL[!,Symbol("ISP \nsub-region")]] 
    # FULL.area_id = [ismissing(k) ? missing : areat[areat[!,:name] .== k, :id][1] for k in FULL[!,Symbol("Region")]]
    FULL.id_bus = [ismissing(k) ? missing : Int64(k) for k in FULL.id_bus]
    # FULL.area_id = [ismissing(k) ? missing : Int64(k) for k in FULL.area_id]
    FULL.Area = [ismissing(k) ? missing : k for k in FULL.Region]
    FULL[!,Symbol("Technology type")] = [ismissing(k) ? missing : k for k in FULL[!,Symbol("Generator type")]]
    FULL[!,Symbol("Fuel type")] = [ismissing(k) ? missing : k for k in FULL[!,Symbol("Fuel/technology type")]]
    FULL.Bus = [ismissing(k) ? missing : k for k in FULL[!,Symbol("ISP \nsub-region")]]
    FULL[!,Symbol("REZ location")] = [ismissing(k) ? missing : k for k in FULL[!,Symbol("REZ location_1")]]
    XLSX.writetable(".tmp/FULL3.xlsx", Tables.columntable(FULL); sheetname="FULL3", overwrite=true)

    for c in [:NAME,:Region,Symbol("Generator type"),Symbol("Regional build cost zone"),
        Symbol("ISP \nsub-region"), Symbol("Fuel/technology type"), Symbol("REZ location_1")] select!(FULL, Not(c)) end 
    FULL[!,:CAPACITY] = coalesce.(FULL[!,:CAPACITY], FULL[!,18]) # Assign maximum capacity to generators with missing capacity
    # remove rows with missing values in column Generator
    FULL = FULL[.!ismissing.(FULL[!,:Generator]),:]
    XLSX.writetable(".tmp/GENERATORS.xlsx", Tables.columntable(FULL); sheetname="Generators", overwrite=true)

    # ====================================== #
    # ======== RENEWABLE GENERATION ======== #
    # ====================================== #
    GENLIST = FULL[!,:Generator]
    vretunit = (occursin.("solar",  GENLIST) .| 
                occursin.("wind",   GENLIST) .| 
                occursin.("Solar",  GENLIST) .| 
                occursin.("Wind",   GENLIST) .|
                occursin.("Wind",   coalesce.(FULL[!,Symbol("Technology type")],"")) .| 
                occursin.("solar",  coalesce.(FULL[!,Symbol("Technology type")],"")) .| 
                occursin.("Solar",  coalesce.(FULL[!,Symbol("Technology type")],""))
                )

    bessunit = (    occursin.("Hornsdale Power Reserve",    FULL[!,:Generator]) .| 
                    occursin.("BESS",                       FULL[!,:Generator]) .| 
                    occursin.("Storage",                    FULL[!,:Generator]) .| 
                    occursin.("Battery",                    FULL[!,:Generator]) .|
                    occursin.("Renewable Energy Hub",                       FULL[!,:Generator])
                    )

    syncunit = vretunit .| bessunit

    VRET = FULL[vretunit,:]
    BESS = FULL[bessunit,:]
    SYNC = FULL[.!syncunit,:]

    XLSX.writetable(".tmp/VRET.xlsx", Tables.columntable(VRET); sheetname="VRET", overwrite=true)
    XLSX.writetable(".tmp/BESS.xlsx", Tables.columntable(BESS); sheetname="BESS", overwrite=true)
    XLSX.writetable(".tmp/SYNC.xlsx", Tables.columntable(SYNC); sheetname="SYNC", overwrite=true)

    sort!(SYNC, [Symbol("Fuel type"), :Generator]) #sort table
    gens = unique(SYNC[!,:Generator])
    gensfreq = ParseISP.OrderedDict([(g,count(x->x==g,SYNC[!,:Generator])) for g in gens]) # Count number of units per generator

    selar = Bool[]
    nar = Int64[]
    for r in keys(gensfreq) 
        append!(selar,true); append!(nar,gensfreq[r]);
        for k in 1:(gensfreq[r]-1) append!(selar,false); append!(nar,0); end
    end

    SYNC[!,:n] = nar
    SYNC2 = SYNC[selar,:]
    sort!(SYNC2, [Symbol("Fuel type"), :Generator])
    XLSX.writetable(".tmp/SYNC3.xlsx", Tables.columntable(SYNC2); sheetname="SYNC3", overwrite=true)


    SYNC3 = copy(SYNC2)
    lat = Union{Missing, Float64}[]
    lon = Union{Missing, Float64}[]
    fuel = String[]
    tech = String[]
    type = String[]

    for r in 1:nrow(SYNC3)
        # println(r)
        gty = SYNC3[r, :Generator]                  # Generator name
        fty = SYNC3[r, Symbol("Technology type")]   # Technologytype
        tty = SYNC3[r, Symbol("Fuel type")]         #  Fuel type
        # println(gty, " // ", fty, " // ", tty)

        if gty in keys(ParseISP.units)
            SYNC3[r,:n] = ParseISP.units[gty][1]
            push!(fuel, ParseISP.units[gty][2])
            push!(tech, ParseISP.units[gty][3])
            push!(type, ParseISP.units[gty][4])
            push!(lat,  ParseISP.units[gty][5])
            push!(lon,  ParseISP.units[gty][6])
        else
            for t in ParseISP.fueltype
                if fty in t[2]
                    push!(fuel,t[1])
                    if t[1] == "Coal" 
                        push!(tech,tty) 
                    else 
                        push!(tech,fty) 
                    end
                    push!(type,fty)
                else
                    # println("NO DATA ---> ", gty, " ", fty, " ", tty)
                end
            end
            push!(lat, 0.0); push!(lon, 0.0);
        end
    end

    SYNC3[!,:fuel] = fuel
    SYNC3[!,:tech] = tech
    SYNC3[!,:type] = type
    SYNC3[!,:lat]  = lat
    SYNC3[!,:lon]  = lon

    for k in 1:length(SYNC3[!,:fuel])
        if SYNC3[k,:fuel] == "Diesel" 
            SYNC3[k,:tech] = "Diesel" 
        end
        if SYNC3[k,:tech] == "Gas-powered steam turbine" 
            SYNC3[k,:tech] = "OCGT" 
        end
    end

    SYNC3[!,:cap] = SYNC3[!,:CAPACITY] ./ SYNC3[!,:n]
    XLSX.writetable(".tmp/SYNC4.xlsx", Tables.columntable(SYNC3); sheetname="SYNC4", overwrite=true)

    # ====================================== #
    # ============ EMMISSIONS ============== #
    # ====================================== #
    EMI = ParseISP.read_xlsx_with_header(inputs_workbook, "Emissions intensity", "B7:D73")
    select!(EMI, Not(2))
    rename!(EMI, 2 => "Emissions")
    EMI[!,:Generator] = strip.(EMI[!,:Generator])
    EMI[!,:Generator] = [string(k) for k in EMI[!,:Generator]]

    genemi =  Dict( 
                    # "Mt Piper" => "Mount Piper", 
                    "Callide C" => "Callide C", 
                    # "Loy Yang A Power Station" => "Loy Yang A", 
                    "Yabulu Steam Turbine" => "Yabulu Steam Turbine ", 
                    "Port Lincoln Gt" => "Port Lincoln GT", 
                    "Yarwun Cogen" => "Yarwun 1" )
    for k in 1:length(EMI[!,:Generator]) EMI[k,:Generator] in keys(genemi) ? EMI[k,:Generator] = genemi[EMI[k,:Generator]] : 0.0 end
    filteremi = .![n in [k+j for k in 1:length(EMI[!,:Generator]) for j in 0:2 if ismissing.(EMI[!,:Generator])[k]] for n in 1:length(EMI[!,:Generator])]
    EMI = EMI[filteremi,:]
    SYNC3 = leftjoin(SYNC3, EMI, on = :Generator)
    SYNC3[!,:Emissions] = [ismissing(e) ? 0.0 : e for e in SYNC3[!,:Emissions]]
    XLSX.writetable(".tmp/SYNC5.xlsx", Tables.columntable(SYNC3); sheetname="SYNC5", overwrite=true)

    SYNC4 = SYNC3[.!(SYNC3[!,:tech] .== "Pumped-Storage"),:]
    PS = SYNC3[(SYNC3[!,:tech] .== "Pumped-Storage"),:]
    XLSX.writetable(".tmp/SYNC6.xlsx", Tables.columntable(SYNC4); sheetname="SYNC6", overwrite=true)
    XLSX.writetable(".tmp/PS.xlsx", Tables.columntable(PS); sheetname="PS", overwrite=true)

    # ====================================== #
    # ======== FILLING GENERATORS ========== #
    # ====================================== #
    slopear = Dict( "OCGT"              => 0.6, 
                    "Black Coal"        => 0.3,
                    "Black Coal NSW"    => 0.3, 
                    "Black Coal QLD"    => 0.3,
                    "Brown Coal"        => 0.3, 
                    "Brown Coal VIC"    => 0.3,
                    "Reservoir"         => 0.6, 
                    "Run-of-River"      => 0.6, 
                    "Pumped-Storage"    => 0.6, 
                    "Diesel"            => 0.6, 
                    "CCGT"              => 0.4,
                    "Hydrogen-based gas turbines" => 0.4)
                    
    # @warn("Slope for Hydrogen-based gas turbines is defined as 0.4. CHECK!")
    inertiaar = Dict(   "OCGT"              => 4.0, 
                        "Black Coal"        => 4.0, 
                        "Black Coal NSW"    => 4.0,
                        "Black Coal QLD"    => 4.0,
                        "Brown Coal"        => 4.0, 
                        "Brown Coal VIC"    => 4.0,
                        "Reservoir"         => 2.5, 
                        "Run-of-River"      => 2.5, 
                        "Pumped-Storage"    => 2.2, 
                        "Diesel"            => 4.0, 
                        "CCGT"              => 4.0,
                        "Hydrogen-based gas turbines" => 4.0)
    # @warn("Inertia for Hydrogen-based gas turbines is defined as 4.0. CHECK!")
    sort!(SYNC4, [Symbol("fuel"), :Generator]) #sort table to solve problem with unit Quarantine


    GENERATORS = DataFrame(id_gen = 1:nrow(SYNC4))
    GENERATORS[!,:name] = SYNC4[!,:Generator]
    GENERATORS[!,:alias] = [ismissing(SYNC4[n,:DUID]) ? SYNC4[n,:Generator] : SYNC4[n,:DUID] for n in 1:length(SYNC4[!,:DUID])]
    GENERATORS[!,:fuel] = SYNC4[!,:fuel]
    GENERATORS[!,:tech] = SYNC4[!,:tech]
    GENERATORS[!,:type] = SYNC4[!,:type]
    GENERATORS[!,:capacity] = SYNC4[!,:cap]

    fullout = []
    partialout = []
    derate = []
    mttrfull = []
    mttrpart = []
    for k in 1:nrow(GENERATORS)
        if ((GENERATORS[k,:tech] == "OCGT" || GENERATORS[k,:tech] == "Diesel") && GENERATORS[k,:capacity] >= 150)       tgt = (RELIA[!,1] .== "OCGT");                              push!(fullout, RELIA[tgt, 2][1]); push!(partialout, RELIA[tgt, 3][1]); push!(mttrfull, RELIA[tgt, 4][1]); push!(mttrpart, RELIA[tgt, 5][1]); push!(derate, RELIA[tgt, 6][1])
        elseif ((GENERATORS[k,:tech] == "OCGT" || GENERATORS[k,:tech] == "Diesel") && GENERATORS[k,:capacity] < 150)    tgt = (RELIA[!,1] .== "Small peaking plants");              push!(fullout, RELIA[tgt, 2][1]); push!(partialout, RELIA[tgt, 3][1]); push!(mttrfull, RELIA[tgt, 4][1]); push!(mttrpart, RELIA[tgt, 5][1]); push!(derate, RELIA[tgt, 6][1])
        elseif GENERATORS[k,:tech] == "CCGT"                                                                            tgt = (RELIA[!,1] .== "CCGT + Steam Turbine");              push!(fullout, RELIA[tgt, 2][1]); push!(partialout, RELIA[tgt, 3][1]); push!(mttrfull, RELIA[tgt, 4][1]); push!(mttrpart, RELIA[tgt, 5][1]); push!(derate, RELIA[tgt, 6][1])
        elseif GENERATORS[k,:fuel] == "Hydro"                                                                           tgt = (RELIA[!,1] .== "Hydro");                             push!(fullout, RELIA[tgt, 2][1]); push!(partialout, RELIA[tgt, 3][1]); push!(mttrfull, RELIA[tgt, 4][1]); push!(mttrpart, RELIA[tgt, 5][1]); push!(derate, RELIA[tgt, 6][1])
        elseif GENERATORS[k,:tech] == "Reciprocating Engine"                                                            tgt = (RELIA[!,1] .== "Small peaking plants");              push!(fullout, RELIA[tgt, 2][1]); push!(partialout, RELIA[tgt, 3][1]); push!(mttrfull, RELIA[tgt, 4][1]); push!(mttrpart, RELIA[tgt, 5][1]); push!(derate, RELIA[tgt, 6][1])
        elseif GENERATORS[k,:tech] == "Brown Coal"                                                                      tgt = (RELIA[!,1] .== "Brown Coal");                        push!(fullout, RELIA[tgt, 2][1]); push!(partialout, RELIA[tgt, 3][1]); push!(mttrfull, RELIA[tgt, 4][1]); push!(mttrpart, RELIA[tgt, 5][1]); push!(derate, RELIA[tgt, 6][1])
        elseif GENERATORS[k,:tech] == "Brown Coal VIC"                                                                  tgt = (RELIA[!,1] .== "Brown Coal");                        push!(fullout, RELIA[tgt, 2][1]); push!(partialout, RELIA[tgt, 3][1]); push!(mttrfull, RELIA[tgt, 4][1]); push!(mttrpart, RELIA[tgt, 5][1]); push!(derate, RELIA[tgt, 6][1])
        elseif GENERATORS[k,:tech] == "Black Coal NSW"                                                                  tgt = (RELIA[!,1] .== "Black Coal NSW");                    push!(fullout, RELIA[tgt, 2][1]); push!(partialout, RELIA[tgt, 3][1]); push!(mttrfull, RELIA[tgt, 4][1]); push!(mttrpart, RELIA[tgt, 5][1]); push!(derate, RELIA[tgt, 6][1])
        elseif GENERATORS[k,:tech] == "Black Coal QLD"                                                                  tgt = (RELIA[!,1] .== "Black Coal QLD");                    push!(fullout, RELIA[tgt, 2][1]); push!(partialout, RELIA[tgt, 3][1]); push!(mttrfull, RELIA[tgt, 4][1]); push!(mttrpart, RELIA[tgt, 5][1]); push!(derate, RELIA[tgt, 6][1])
        elseif GENERATORS[k,:tech] == "Hydrogen-based gas turbines"                                                     tgt = (RELIANEW[!,1] .== "Hydrogen-based gas turbines");    push!(fullout, RELIANEW[tgt, 2][1]/100); push!(partialout, RELIANEW[tgt, 3][1]/100); push!(mttrfull, RELIANEW[tgt, 4][1]); push!(mttrpart, RELIANEW[tgt, 5][1]); push!(derate, RELIANEW[tgt, 6][1]/100)
        else 
            push!(derate, "XXX")
            # println(GENERATORS[k,:name]," ", GENERATORS[k,:tech]," ", GENERATORS[k,:capacity]," ", GENERATORS[k,:fuel])
        end
    end

    # @warn("Partialout and derating factor are missing for some hydrogen-based generators. Replacing with 0.0")
    fullout     = [ismissing(k) ? 0.0 : k for k in fullout]
    partialout  = [ismissing(k) ? 0.0 : k for k in partialout]
    derate      = [ismissing(k) ? 0.0 : k for k in derate]
    mttrfull    = [ismissing(k) ? 0.0 : k for k in mttrfull]
    mttrpart    = [ismissing(k) ? 0.0 : k for k in mttrpart]

    GENERATORS[!,:forate] = ones(nrow(SYNC4)) .- (fullout  .+ partialout  .* (ones(nrow(SYNC4)) .- derate))
    GENERATORS[!,:fullout]      = fullout
    GENERATORS[!,:partialout]   = partialout
    GENERATORS[!,:derate]       = derate
    GENERATORS[!,:mttrfull]     = mttrfull
    GENERATORS[!,:mttrpart]     = mttrpart
    XLSX.writetable(".tmp/GENERATORS2.xlsx", Tables.columntable(GENERATORS); sheetname="GENERATORS2", overwrite=true)

    GENERATORS[!,:id_bus] = SYNC4[!,:id_bus]
    GENERATORS[!,:pmin] = coalesce.(SYNC4[!,:MSG], 0.0)
    GENERATORS[!,:pmax] = SYNC4[!,:cap]
    GENERATORS[!,:rup] = coalesce.(SYNC4[!,:rup], 9999.0)
    GENERATORS[!,:rdw] = coalesce.(SYNC4[!,:rdw], 9999.0)
    GENERATORS[!,:investment] = Int64.([ false for k in 1:nrow(SYNC4)])
    GENERATORS[!,:active] = Int64.([ true for k in 1:nrow(SYNC4)])
    GENERATORS[!,:cvar] = SYNC4[!,Symbol("SRMC (\$/MWh)")]
    GENERATORS[!,:cfuel] = SYNC4[!, Symbol("Fuel cost (\$/GJ)")]
    GENERATORS[!,:cvom] = SYNC4[!, Symbol("VOM (\$/MWh sent-out)")]
    GENERATORS[!,:cfom] = SYNC4[!, Symbol("FOM (\$/kW/annum)")].*1000
    GENERATORS[!,:co2] = SYNC4[!,:Emissions]
    GENERATORS[!,:slope] = [slopear[GENERATORS[k,:tech]] for k in 1:nrow(SYNC4) ]
    GENERATORS[!,:hrate] = SYNC4[!, Symbol("Heat rate (GJ/MWh HHV s.o.)")]
    GENERATORS[!,:pfrmax] = GENERATORS[!,:pmax] * 0.1
    # @warn("PFRMAX is set to 10% of Pmax")
    GENERATORS[!,:g] = zeros(nrow(SYNC4))
    GENERATORS[!,:inertia] = [inertiaar[GENERATORS[k,:tech]] for k in 1:nrow(SYNC4) ]
    GENERATORS[!,:ffr] = Int64.([ false for k in 1:nrow(SYNC4)])
    GENERATORS[!,:pfr] = Int64.([ true for k in 1:nrow(SYNC4)])
    GENERATORS[!,:res2] = Int64.([ true for k in 1:nrow(SYNC4)])
    GENERATORS[!,:res3] = Int64.([ false for k in 1:nrow(SYNC4)])
    GENERATORS[!,:powerfactor] = ones(nrow(SYNC4)) * 0.85
    # @warn("Power factor is set to 85%")
    GENERATORS[!,:latitude] = SYNC4[!,:lat]
    GENERATORS[!,:longitude] = SYNC4[!,:lon]
    GENERATORS[!,:n] = SYNC4[!,:n]
    GENERATORS[!,:contingency] = Int64.([ true for k in 1:nrow(SYNC4)])
    XLSX.writetable(".tmp/GENERATORS3.xlsx", Tables.columntable(GENERATORS); sheetname="GENERATORS3", overwrite=true)
    # @warn("Check fuel cost for Hydrogen-based units")

    for r in 1:nrow(GENERATORS)
        if GENERATORS[r,:fuel] == "Natural Gas"
            if GENERATORS[r,:tech] == "CCGT" && GENERATORS[r,:pmin] == 0.0
                GENERATORS[r,:pmin] = round(0.52 * GENERATORS[r,:pmax], digits=2)
            elseif GENERATORS[r,:tech] == "OCGT" && GENERATORS[r,:pmin] == 0.0
                GENERATORS[r,:pmin] = round(0.33 * GENERATORS[r,:pmax], digits=2)
            end
        elseif GENERATORS[r,:fuel] == "Hydro" && GENERATORS[r,:pmin] == 0.0
            GENERATORS[r,:pmin] = round(0.2 * GENERATORS[r,:pmax], digits=2)
        elseif GENERATORS[r,:fuel] == "Diesel" && GENERATORS[r,:pmin] == 0.0
            GENERATORS[r,:pmin] = round(0.2 * GENERATORS[r,:pmax], digits=2)
        end
    end
    
    # Manual fix for Quarantine pmin
    if any(GENERATORS[!,:name] .== "Quarantine")
        r = findfirst(GENERATORS[!,:name] .== "Quarantine")
        GENERATORS[r,:pmin] = 3.0
    end

    # Manual fix for Murray
    if any(GENERATORS[!,:name] .== "Murray 1")
        r = findfirst(GENERATORS[!,:name] .== "Murray 1")
        GENERATORS[r,:alias] = "MURRAY1"
    end

    if any(GENERATORS[!,:name] .== "Murray 2")
        r = findfirst(GENERATORS[!,:name] .== "Murray 2")
        GENERATORS[r,:alias] = "MURRAY2"
    end

    # ====================================== #
    # ============= COMMITMENT ============= #
    # ====================================== #

    COMMITMENT = DataFrame(id = 1:nrow(SYNC4))
    COMMITMENT[!,:gen_id]            = 1:nrow(SYNC4)
    COMMITMENT[!,:down_time]         = coalesce.(SYNC4[!,:MinUpTime], 0.0)
    COMMITMENT[!,:up_time]           = coalesce.(SYNC4[!,:MinUpTime], 0.0)
    COMMITMENT[!,:last_state]        = zeros(nrow(SYNC4))
    COMMITMENT[!,:last_state_period] = zeros(nrow(SYNC4))
    COMMITMENT[!,:last_state_output] = zeros(nrow(SYNC4))
    COMMITMENT[!,:start_up_cost]     = [GENERATORS[GENERATORS[!,:id_gen] .== k, :fuel][1] == "Coal" ? GENERATORS[GENERATORS[!,:id_gen] .== k, :cvar][1] * GENERATORS[GENERATORS[!,:id_gen] .== k, :pmax][1] * 4.0 : 0.0 for k in COMMITMENT[!,:gen_id] ] # 
    COMMITMENT[!,:shut_down_cost]    = zeros(nrow(SYNC4))
    COMMITMENT[!,:start_up_time]     = zeros(nrow(SYNC4))
    COMMITMENT[!,:shut_down_time]    = zeros(nrow(SYNC4))

    # MERGE GENERATOR AND COMMITMENT IN left `id` and right `gen_id`. Fill missing values in COMMITMENT with 0
    merged = leftjoin(GENERATORS, COMMITMENT, on = [:id_gen => :gen_id], makeunique=true)
    select!(merged, Not(:id))
    ts.gen = merged
    XLSX.writetable(".tmp/GENERATORS_FULL.xlsx", Tables.columntable(merged); sheetname="GENERATORS", overwrite=true)
    # rm(".tmp"; recursive=true) # TODO force remove 
    return SYNC4, GENERATORS, PS
end

"""
    gen_n_sched_table(tv, SYNC4, GENERATORS)

Populate the generator-availability schedule (`tv.gen_n`) with commissioning
events derived from synchronous unit data and the aggregated generator table.
The function handles missing dates, seeds pre-commissioning inactive periods,
and activates units across every configured scenario once their start date is
reached.

# Arguments
- `tv::ParseISPtimeVarying`: Receives the availability schedule records.
- `SYNC4::DataFrame`: Structured UC-friendly view of synchronous units.
- `GENERATORS::DataFrame`: Master generator table used to map names to ids.
"""
function gen_n_sched_table(tv::ParseISPtimeVarying, SYNC4::DataFrame, GENERATORS::DataFrame; release::ParseISP.ISPRelease = ParseISP.ISP2024())
    # COMMITED AND ANTICIPATED PROJECTS DATES
    MISSING_DATES = ParseISP.OrderedDict("Kogan Gas" => "2026-07-01T00:00:00")
    N_SCHED_COMM = DataFrame([Symbol(k) => Vector{Any}() for k in keys(ParseISP.MOD_GEN_N)])
    i = isempty(tv.gen_n.id) ? 1 : maximum(tv.gen_n.id) + 1
    for r in 1:nrow(SYNC4) 
        # FIX COMMISSIONING DATE FOR GENERATORS
        d = SYNC4[r, Symbol("Commissioning date")] # Comissioning date
        if ismissing(d)
            if SYNC4[r,:Generator] in keys(MISSING_DATES)
                SYNC4[r, Symbol("Commissioning date")] = DateTime(MISSING_DATES[SYNC4[r,:Generator]])
            else
                @warn("No commissioning date for ", SYNC4[r,:Generator])
            end
        end
        # GENERATE DATAFRAME WITH SCHEDULED COMMISSIONING
        d = SYNC4[r, Symbol("Commissioning date")] # Comissioning date
        if d > DateTime("2020-01-01T01:00:00")
            genid = GENERATORS[GENERATORS[!,:name] .== SYNC4[r,:Generator], :id_gen][1]
            genname = GENERATORS[GENERATORS[!,:name] .== SYNC4[r,:Generator], :name][1]
            # @warn("Setting commissioning date for $(SYNC4[r,:Generator]) to $(d)")
            for sc in keys(ParseISP.scenario_id_labels(release))
                # BEFORE COMMISSIONING -> deactivated
                row = [i, genid, sc, DateTime("2020-01-01T00:00:00"), 0]
                push!(N_SCHED_COMM, row)
                i+=1
                # COMMISSIONING DATE -> activated
                if genname == "Kurri Kurri OCGT"
                    row = [i, genid, sc, d, 2]
                    push!(N_SCHED_COMM, row)
                else
                    row = [i, genid, sc, d, 1]
                    push!(N_SCHED_COMM, row)
                end
                i+=1
            end
        end
    end
    # @info("\n✓ GENERATOR_n_sched - Commissioned & Anticipated projects")

    # Fill commitment table
    for k in 1:nrow(N_SCHED_COMM) push!(tv.gen_n, collect(N_SCHED_COMM[k,:])) end
end

"""
    gen_retirements(ts, tv; retirements, reductions, scenario_ids)

Write time-varying retirement and capacity-reduction events into `tv.gen_n` and
`tv.gen_pmax` based on release-specific retirement and reduction tables.
This ensures each scenario reflects the staged withdrawal or derating of
specific units.

# Arguments
- `ts::ParseISPtimeStatic`: Supplies the generator id mapping.
- `tv::ParseISPtimeVarying`: Mutated to include the retirement/pmax events.
"""
function gen_retirements(ts, tv;
        retirements = ParseISP.generator_retirements(ParseISP.ISP2024()),
        reductions = ParseISP.capacity_reductions(ParseISP.ISP2024()),
        scenario_ids = keys(ParseISP.scenario_id_labels(ParseISP.ISP2024())))
    gent = ts.gen

    pnid    = isempty(tv.gen_n) ? 0 : maximum(tv.gen_n.id)
    ppmaxid = isempty(tv.gen_pmax) ? 0 : maximum(tv.gen_pmax.id)

    for scid in scenario_ids
        for unit in retirements[scid]
            genid = gent[gent[!,:name] .== unit[1], :id_gen][1]
            for ndata in unit[2]
                pnid+=1; 
                push!(tv.gen_n, [pnid, genid, scid, DateTime(ndata[3],ndata[2],ndata[1]), ndata[4]])
            end
        end

        for unit in reductions[scid]
            genid = gent[gent[!,:name] .== unit[1], :id_gen][1]
            for ndata in unit[2]
                ppmaxid+=1; 
                push!(tv.gen_pmax, [ppmaxid, genid, scid, DateTime(ndata[3],ndata[2],ndata[1]), ndata[4]])
            end
        end
    end
end

function _isp2026_summary_mapping_subregions(inputs_workbook::String)
    raw = ParseISP.read_xlsx_with_header(inputs_workbook, "Summary Mapping", "B6:AB900")
    mapping = Dict{String, String}()
    for row in eachrow(raw)
        length(row) >= 6 || continue
        iasr = _isp2026_cell_string(row[2])
        isempty(iasr) && continue
        subregion = _isp2026_cell_string(row[6])
        isempty(subregion) && continue
        mapping[iasr] = subregion
    end
    return mapping
end

function _isp2026_region_bus_code(region)
    return get(Dict(
        "QLD" => "SQ",
        "NSW" => "SNW",
        "VIC" => "VIC",
        "SA" => "CSA",
        "TAS" => "TAS",
    ), _isp2026_cell_string(region), "SNW")
end

function _isp2026_storage_prop(storage_props::DataFrame, technology, col::Symbol, default::Float64)
    tech = _isp2026_cell_string(technology)
    idx = findfirst(value -> !ismissing(value) && string(value) == tech, storage_props[!, :Technology])
    idx === nothing && return default
    return _isp2026_number(storage_props[idx, col], default)
end

function _isp2026_storage_type(technology)
    tech = _isp2026_cell_string(technology)
    occursin("8hrs", tech) && return "DEEP"
    occursin("4hrs", tech) && return "MEDIUM"
    return "SHALLOW"
end

function _isp2026_ess_push_schedule!(tv, ess_id::Int, comm_date::DateTime, scenario_ids)
    comm_date <= DateTime(2024, 1, 1) && return
    idk = isempty(tv.ess_n) ? 1 : maximum(tv.ess_n[!, :id]) + 1
    for scid in scenario_ids
        push!(tv.ess_n, [idk, ess_id, scid, DateTime(Dates.year(comm_date), Dates.month(comm_date), 1), 1])
        idk += 1
    end
end

function ess_tables_isp2026(ts::ParseISPtimeStatic, tv::ParseISPtimeVarying, PSESS::DataFrame, inputs_workbook::String; release::ParseISP.ISPRelease = ParseISP.ISP2026())
    bust = ts.bus
    scenario_ids = keys(ParseISP.scenario_id_labels(release))
    subregions = _isp2026_summary_mapping_subregions(inputs_workbook)
    storage_props = ParseISP.read_xlsx_with_header(inputs_workbook, "Storage properties", "B4:K40")
    maxcap = ParseISP.read_xlsx_with_header(inputs_workbook, "Maximum capacity", "B10:J900")
    maxcap = maxcap[.!ismissing.(maxcap[!, Symbol("IASR ID")]), :]
    filter!(row -> string(row[Symbol("IASR ID")]) != "IASR ID", maxcap)

    id_ess = isempty(ts.ess.id_ess) ? 0 : maximum(ts.ess.id_ess)

    bess_rows = filter(maxcap) do row
        occursin("Battery storage", _isp2026_cell_string(row[Symbol("Technology")]))
    end

    for row in eachrow(bess_rows)
        id_ess += 1
        iasr = _isp2026_cell_string(row[Symbol("IASR ID")])
        name = _isp2026_cell_string(row[Symbol("Power Station")])
        technology = _isp2026_cell_string(row[Symbol("Technology")])
        capacity = _isp2026_number(row[Symbol("Installed capacity (MW)")])
        energy = _isp2026_number(row[Symbol("Storage Capacity (MWh)")], capacity * 2.0)
        comm_date = _isp2026_excel_date(row[Symbol("Commissioning date")])
        subregion = get(subregions, iasr, _isp2026_region_bus_code(row[Symbol("Region")]))
        id_bus = _isp2026_bus_id(bust, subregion)
        bus_data = bust[bust[!, :id_bus] .== id_bus, :]
        ch_eff = _isp2026_storage_prop(storage_props, technology, Symbol("Charge efficiency"), 92.0) / 100.0
        dch_eff = _isp2026_storage_prop(storage_props, technology, Symbol("Discharge efficiency"), 92.0) / 100.0
        max_soc = _isp2026_storage_prop(storage_props, technology, Symbol("Allowable max state of charge3"), 100.0)
        min_soc = _isp2026_storage_prop(storage_props, technology, Symbol("Allowable min state of charge"), 0.0)
        is_existing = _isp2026_cell_string(row[Symbol("Status5")]) == "Existing"

        push!(ts.ess, (
            id_ess = id_ess,
            name = name,
            alias = isempty(iasr) ? name : iasr,
            tech = "BESS",
            type = _isp2026_storage_type(technology),
            capacity = capacity,
            investment = 0,
            active = 1,
            id_bus = id_bus,
            ch_eff = ch_eff,
            dch_eff = dch_eff,
            eini = min_soc,
            emin = min_soc,
            emax = energy * max_soc / 100.0,
            pmin = 0.0,
            pmax = capacity,
            lmin = 0.0,
            lmax = capacity,
            fullout = 0.02,
            partialout = 0.0,
            mttrfull = 4.0,
            mttrpart = 1.0,
            inertia = 0.0,
            powerfactor = 1.0,
            ffr = 1,
            pfr = 0,
            res2 = 1,
            res3 = 0,
            fr_db = 0.0,
            fr_ad = 0.3,
            fr_dt = 0.05,
            fr_frt = 1000.0,
            fr_fr = 70.0,
            longitude = Float64(bus_data[1, :longitude]),
            latitude = Float64(bus_data[1, :latitude]),
            n = is_existing ? 1 : 0,
            contingency = 0,
        ))
        is_existing || _isp2026_ess_push_schedule!(tv, id_ess, comm_date, scenario_ids)
    end

    for row in eachrow(PSESS)
        station = row.Generator
        haskey(ParseISP.dataps, station) || continue
        id_ess += 1
        psdata = ParseISP.dataps[station]
        comm_date = row[Symbol("Commissioning date")]
        existing = comm_date < DateTime(2024, 1, 1)
        pmax = _isp2026_number(row.CAPACITY, Float64(max(psdata[3], psdata[4])))
        emax = _isp2026_number(row.emax, Float64(psdata[5]))
        eff = _isp2026_number(row.pump_efficiency, Float64(psdata[1])) / 100.0

        push!(ts.ess, (
            id_ess = id_ess,
            name = station,
            alias = psdata[8],
            tech = "PS",
            type = psdata[9],
            capacity = pmax,
            investment = 0,
            active = 1,
            id_bus = Int64(row.id_bus),
            ch_eff = eff,
            dch_eff = eff,
            eini = 10.0,
            emin = 10.0,
            emax = emax,
            pmin = 0.0,
            pmax = pmax,
            lmin = 0.0,
            lmax = pmax,
            fullout = 0.02,
            partialout = 0.0,
            mttrfull = 24.0,
            mttrpart = 1.0,
            inertia = 2.2,
            powerfactor = 0.85,
            ffr = 0,
            pfr = 1,
            res2 = 1,
            res3 = 0,
            fr_db = 0.0,
            fr_ad = 0.0,
            fr_dt = 0.0,
            fr_frt = 0.0,
            fr_fr = 70.0,
            longitude = Float64(psdata[7]),
            latitude = Float64(psdata[6]),
            n = existing ? 1 : 0,
            contingency = 0,
        ))
        existing || _isp2026_ess_push_schedule!(tv, id_ess, comm_date, scenario_ids)
    end

    return ts
end

"""
    ess_tables(ts, tv, PSESS, inputs_workbook)

Build static representations for energy storage systems (ESS) and seed any
required time-varying placeholders. The function fuses ISP workbook information
with pumped-storage metadata to describe batteries, charge/discharge limits, and
loss factors.

# Arguments
- `ts::ParseISPtimeStatic`: Destination for static ESS tables.
- `tv::ParseISPtimeVarying`: Receives supporting indices when needed.
- `PSESS::DataFrame`: Pumped-storage subset returned by `generator_table`.
- `inputs_workbook::String`: Path to ISP workbook for BESS proposals and limits.
"""
function ess_tables(ts::ParseISPtimeStatic, tv::ParseISPtimeVarying, PSESS::DataFrame, inputs_workbook::String; release::ParseISP.ISPRelease = ParseISP.ISP2024())
    if release isa ParseISP.ISP2026
        return ess_tables_isp2026(ts, tv, PSESS, inputs_workbook; release = release)
    end

    bust = ts.bus

    BESS_PROP   = ParseISP.read_xlsx_with_header(inputs_workbook, "Storage properties", "B4:H13")
    PS_PROP     = ParseISP.read_xlsx_with_header(inputs_workbook, "Storage properties", "B22:K26")
    BESS_CAP    = ParseISP.read_xlsx_with_header(inputs_workbook, "Maximum capacity", "P8:U62")
    BESS_SUM    = ParseISP.read_xlsx_with_header(inputs_workbook, "Summary Mapping", "B314:AB370")
    RELIANEW    = ParseISP.read_xlsx_with_header(inputs_workbook, "Generator Reliability Settings", "I20:N40")

    BESS_SUM = BESS_SUM[3:end,:]
    BESS_SUM[!,:cheff] = [replace(BESS_SUM[i,Symbol("VOM (\$/MWh sent-out)")], "All " => "") for i in 1:nrow(BESS_SUM)]
    BESS_SUM[!,:dcheff] = [replace(BESS_SUM[i,Symbol("VOM (\$/MWh sent-out)")], "All " => "") for i in 1:nrow(BESS_SUM)]

    BESS = BESS_CAP
    BESS_FOR = DataFrame(id_ess = 1:nrow(BESS))
    BESS_FOR[!,:name] = BESS[!,:Storage]
    BESS_FOR[!,:alias] = [ParseISP.databess[BESS[!,:Storage][k]][2] for k in 1:length(BESS[!,:Storage])]
    BESS_FOR[!,:tech] = ["BESS" for k in 1:nrow(BESS)]
    BESS_FOR[!,:type] = ["SHALLOW" for k in 1:nrow(BESS)]
    BESS_FOR[!,:capacity] = BESS[!,Symbol("Installed capacity (MW)")]
    BESS_FOR[!,:investment] = [0 for k in 1:nrow(BESS)]
    BESS_FOR[!,:active] = [ 1 for k in 1:nrow(BESS)]
    BESS_FOR[!,:id_bus] = Int64.([bust[bust[!,:name] .== BESS_SUM[BESS_SUM[!,:Batteries] .== k, Symbol("Sub-region")][1],:id_bus][1] for k in BESS[!,:Storage]])
    BESS_FOR[!,:ch_eff] = round.([BESS_PROP[BESS_PROP[!,:Property] .== "Charge efficiency (utility)", Symbol(BESS_SUM[k,:cheff])][1] for k in 1:nrow(BESS)],digits=4) ./ 100
    BESS_FOR[!,:dch_eff] = round.([BESS_PROP[BESS_PROP[!,:Property] .== "Discharge efficiency (utility)", Symbol(BESS_SUM[k,:dcheff])][1] for k in 1:nrow(BESS)],digits=4) ./ 100
    BESS_FOR[!,:eini] = [BESS_PROP[BESS_PROP[!,:Property] .== "Allowable min state of charge", Symbol("Battery storage (2hrs storage)")][1] for k in 1:nrow(BESS)] 
    BESS_FOR[!,:emin] = [BESS_PROP[BESS_PROP[!,:Property] .== "Allowable min state of charge", Symbol("Battery storage (2hrs storage)")][1] for k in 1:nrow(BESS)]
    BESS_FOR[!,:emax] = BESS[!,Symbol("Energy (MWh)")] 
    BESS_FOR[!,:pmin] = [ 0.0 for k in 1:nrow(BESS)]
    BESS_FOR[!,:pmax] = BESS[!,Symbol("Installed capacity (MW)")] 
    BESS_FOR[!,:lmin] = [ 0.0 for k in 1:nrow(BESS)]
    BESS_FOR[!,:lmax] = BESS[!,Symbol("Installed capacity (MW)")]
    BESS_FOR[!,:fullout] = [RELIANEW[8,2]/100 for k in 1:nrow(BESS)]
    BESS_FOR[!,:partialout] = [0 for k in 1:nrow(BESS)]
    BESS_FOR[!,:mttrfull] = [RELIANEW[8,4] for k in 1:nrow(BESS)]
    BESS_FOR[!,:mttrpart] = [1.0 for k in 1:nrow(BESS)]
    BESS_FOR[!,:inertia] = [ 0.0 for k in 1:nrow(BESS)]
    BESS_FOR[!,:powerfactor] = [ 1.0 for k in 1:nrow(BESS)]
    BESS_FOR[!,:ffr] = [ 1 for k in 1:nrow(BESS)]
    BESS_FOR[!,:pfr] = [ 0 for k in 1:nrow(BESS)]
    BESS_FOR[!,:res2] = [ 1 for k in 1:nrow(BESS)]
    BESS_FOR[!,:res3] = [ 0 for k in 1:nrow(BESS)]
    BESS_FOR[!,:fr_db] = [ 0.0 for k in 1:nrow(BESS)]
    BESS_FOR[!,:fr_ad] = [ 0.3 for k in 1:nrow(BESS)]
    BESS_FOR[!,:fr_dt] = [ 0.05 for k in 1:nrow(BESS)]
    BESS_FOR[!,:fr_frt] = [ 1000.0 for k in 1:nrow(BESS)]
    BESS_FOR[!,:fr_fr] = [ 70 for k in 1:nrow(BESS)]
    BESS_FOR[!,:longitude] = [ ParseISP.databess[k][1][2] for k in BESS[!,:Storage]]
    BESS_FOR[!,:latitude] = [ ParseISP.databess[k][1][1] for k in BESS[!,:Storage]]
    BESS_FOR[!,:n] = Int64.(BESS_CAP[!,Symbol("Project status")] .!= "Anticipated")
    # @warn("Anticipated BESS projects are deactivated initially")
    BESS_FOR[!,:contingency] = [ 0 for k in 1:nrow(BESS)]

    PS_FOR = DataFrame(id_ess = (nrow(BESS)+1):(nrow(BESS)+nrow(PSESS)))
    PS_FOR[!,:name] = string.(PSESS[!,:Generator])
    PS_FOR[!,:alias] = [ParseISP.dataps[k][8] for k in PSESS[!,:Generator]]
    PS_FOR[!,:tech] = ["PS" for k in 1:nrow(PSESS)]
    PS_FOR[!,:type] = [ParseISP.dataps[k][9] for k in PSESS[!,:Generator] ]
    PS_FOR[!,:capacity] = [Float64(max(ParseISP.dataps[k][3], ParseISP.dataps[k][4])) for k in PSESS[!,:Generator] ]#PSESS[!,Symbol("CAPACITY")] 
    PS_FOR[!,:investment] = [ 0 for k in 1:nrow(PSESS) ]
    PS_FOR[!,:active] = [ 1 for k in 1:nrow(PSESS) ]
    PS_FOR[!,:id_bus] = Int64.(PSESS[!,:id_bus])
    PS_FOR[!,:ch_eff] = [ ParseISP.dataps[k][1] for k in PSESS[!,:Generator] ] ./ 100
    PS_FOR[!,:dch_eff] = [ ParseISP.dataps[k][2] for k in PSESS[!,:Generator] ] ./ 100
    PS_FOR[!,:eini] = [10.0 for k in PSESS[!,:Generator] ]
    PS_FOR[!,:emin] = [10.0 for k in PSESS[!,:Generator] ]
    PS_FOR[!,:emax] = [ ParseISP.dataps[k][5] for k in PSESS[!,:Generator] ]
    PS_FOR[!,:pmin] = [ 0.0 for k in PSESS[!,:Generator] ]
    PS_FOR[!,:pmax] = [ ParseISP.dataps[k][3] for k in PSESS[!,:Generator] ]
    PS_FOR[!,:lmin] = [ 0.0 for k in PSESS[!,:Generator] ]
    PS_FOR[!,:lmax] = [ ParseISP.dataps[k][4] for k in PSESS[!,:Generator] ]
    PS_FOR[!,:fullout] = [RELIANEW[15,2]/100 for k in 1:nrow(PSESS)]
    PS_FOR[!,:partialout] = [0 for k in 1:nrow(PSESS)]
    PS_FOR[!,:mttrfull] = [RELIANEW[15,4] for k in 1:nrow(PSESS)]
    PS_FOR[!,:mttrpart] = [1.0 for k in 1:nrow(PSESS)]
    PS_FOR[!,:inertia] = [ 2.2 for k in PSESS[!,:Generator] ]
    PS_FOR[!,:powerfactor] = [ 0.85 for k in 1:nrow(PSESS)]
    PS_FOR[!,:ffr] = [ 0 for k in 1:nrow(PSESS)]
    PS_FOR[!,:pfr] = [ 1 for k in 1:nrow(PSESS)]
    PS_FOR[!,:res2] = [ 1 for k in 1:nrow(PSESS)]
    PS_FOR[!,:res3] = [ 0 for k in 1:nrow(PSESS)]
    PS_FOR[!,:fr_db] = [ 0.0 for k in 1:nrow(PSESS)]
    PS_FOR[!,:fr_ad] = [ 0.0 for k in 1:nrow(PSESS)]
    PS_FOR[!,:fr_dt] = [ 0.0 for k in 1:nrow(PSESS)]
    PS_FOR[!,:fr_frt] = [ 0.0 for k in 1:nrow(PSESS)]
    PS_FOR[!,:fr_fr] = [ 70 for k in 1:nrow(PSESS)]
    PS_FOR[!,:longitude] = [ ParseISP.dataps[k][7] for k in PSESS[!,:Generator]]
    PS_FOR[!,:latitude] = [ ParseISP.dataps[k][6] for k in PSESS[!,:Generator]]
    PS_FOR[!,:n] = Int64.(PSESS[!,Symbol("Commissioning date")] .< DateTime(2024,1,1))
    # @warn("Storage comissioned after 01-01-2024 is set as inactive")
    PS_FOR[!,:contingency] = [ 0 for k in 1:nrow(PSESS)]

    l_cethana = [maximum(PS_FOR[!,:id_ess])+1, "Cethana", ParseISP.dataps["Cethana"][end-1], "PS", ParseISP.dataps["Cethana"][end], ParseISP.dataps["Cethana"][3], 0, 0, 10,ParseISP.dataps["Cethana"][1]/100, ParseISP.dataps["Cethana"][2]/100, 10,10,ParseISP.dataps["Cethana"][5],0,ParseISP.dataps["Cethana"][3], 0, ParseISP.dataps["Cethana"][4],RELIANEW[15,2],0,RELIANEW[15,4],0 , 2.2,0.85,0,1,1,0,0,0,0,0,70,ParseISP.dataps["Cethana"][7],ParseISP.dataps["Cethana"][6],1,0]
    push!(PS_FOR, l_cethana)

    # Combine BESS and PS DataFrames
    ts.ess = vcat(ts.ess, BESS_FOR, PS_FOR)

    # ENTRY DATES FOR ANTICIPATED/COMMISSIONED ENERGY STORAGE 
    idk = isempty(tv.ess_n) ? 1 : maximum(tv.ess_n[!,:id]) + 1
    for k in 1:nrow(BESS_CAP) 
        if BESS_FOR[k,:n] == 0 
            for sc in keys(ParseISP.scenario_id_labels(release))
                tgtdate = BESS_CAP[k,Symbol("Indicative commissioning date")]
                push!(tv.ess_n, [idk, BESS_FOR[k,:id_ess], sc, DateTime(Dates.year(tgtdate), Dates.month(tgtdate), 1, 0, 0, 0), 1])
                idk+=1
            end
        end
    end

    for k in 1:nrow(PS_FOR)
        if PS_FOR[k,:name] == "Cethana"
            continue
        end 
        tgtdate = PSESS[k,Symbol("Commissioning date")]
        if tgtdate >= DateTime(2024,1,1)
            for sc in keys(ParseISP.scenario_id_labels(release))
                push!(tv.ess_n, [idk, PS_FOR[k,:id_ess], sc, DateTime(Dates.year(tgtdate), Dates.month(tgtdate), 1, 0, 0, 0), 1])
                idk+=1
            end
        end
    end
end

"""
    gen_pmax_distpv(tc, ts, tv, profilespath)

Create distributed PV maximum-capacity traces by reading profile files per
region. The resulting schedules are injected into `tv.gen_pmax` and linked back
to the generator entries defined in `ts` so rooftop PV contributes to the
time-varying fleet.

# Arguments
- `tc::ParseISPtimeConfig`: Indicates which days and durations to sample from the
  profiles.
- `ts::ParseISPtimeStatic`: Provides generator ids for distributed PV entries.
- `tv::ParseISPtimeVarying`: Receives the computed pmax time series.
- `profilespath::String`: Directory holding the DER traces.
"""
function gen_pmax_distpv(tc::ParseISPtimeConfig, ts::ParseISPtimeStatic, tv::ParseISPtimeVarying, profilespath::String; refyear::Int64=2011, poe::Int64=10, release::ParseISP.ISPRelease = ParseISP.ISP2024(), skip_traces::Bool=false)
    probs = tc.problem;
    bust = ts.bus;
    scenario_labels = ParseISP.scenario_id_labels(release)
    demand_labels = ParseISP.demand_scenario_labels(release)

    gid = isempty(ts.gen.id_gen) ? 0 : maximum(ts.gen.id_gen);
    pmaxid = isempty(tv.gen_pmax.id) ? 0 : maximum(tv.gen_pmax.id);

    for st in keys(ParseISP.NEMBUSNAME)
        gid += 1
        bus_data = bust[bust[!,:name] .== st, :]
        bus_id = bus_data[!, :id_bus][1]
        bus_lat = bus_data[!, :latitude][1]
        bus_lon = bus_data[!, :longitude][1]
        arrgen = [gid,"RTPV_$(st)","RTPV_$(st)","Solar","RoofPV","RoofPV", 100.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, bus_id, 0.0, 100.0, 9999.9, 9999.9, 0, 1, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0, 0, 1.0, bus_lat, bus_lon, 1, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        push!(ts.gen, arrgen)
        if !skip_traces
        for p in 1:nrow(probs)
            scid = probs[p,:scenario][1]
            sc = scenario_labels[scid]
            demand_label = demand_labels[sc]

            df = CSV.File(joinpath(profilespath, "demand_$(st)_$(sc)", "$(st)_RefYear_$(refyear)_$(demand_label)_POE$(poe)_PV_TOT.csv")) |> DataFrame

            dstart = probs[p,:dstart]
            dend = probs[p,:dend]
            df2 = select_trace_date_window(df, dstart, dend)

            data = vec(permutedims(Tables.matrix(df2[:,4:end])))
            data2 = round.([ (data[2*i-1]+data[2*i])/2 for i in 1:Int64(length(data)/2) ], digits=4)

            for h in 1:Int64(Dates.Hour(dend - dstart)/Dates.Hour(1)+1)
                pmaxid += 1
                push!(tv.gen_pmax, [pmaxid, gid, scid, dstart+Dates.Hour(h-1), data2[h]])
            end
        end
        end
    end
end

"""
    dem_load(tc, ts, tv, profilespath)

Populate both static and time-varying demand tables. Static demand metadata is
stored in `ts.dem`, while scenario-specific load traces derived from the profile
directory are written into `tv.dem_sched` for each period defined in `tc`.

# Arguments
- `tc::ParseISPtimeConfig`: Specifies schedule windows to generate.
- `ts::ParseISPtimeStatic`: Receives regional demand descriptors.
- `tv::ParseISPtimeVarying`: Receives chronological demand schedules.
- `profilespath::String`: Root folder containing demand trace files.
"""
function dem_load(ts::ParseISPtimeStatic)
    bust  = ts.bus
    did     = isempty(ts.dem.id_dem) ? 0 : maximum(ts.dem.id_dem)

    for st in keys(ParseISP.NEMBUSNAME)
        did += 1
        bus_data = bust[bust[!,:name] .== st, :]
        bus_id = bus_data[!, :id_bus][1]

        arrdem = [did,"DEM_$(st)", 0.0, bus_id, 1, 1, 17500.0, 1]
        push!(ts.dem, arrdem)
    end
end

"""
    dem_load_sched(tc, ts, tv, profilespath)

Populate both static demand tables. Scenario-specific load traces derived from the profile
directory are written into `tv.dem_sched` for each period defined in `tc`.

# Arguments
- `tc::ParseISPtimeConfig`: Specifies schedule windows to generate.
- `ts::ParseISPtimeStatic`: Receives regional demand descriptors.
- `tv::ParseISPtimeVarying`: Receives chronological demand schedules.
- `profilespath::String`: Root folder containing demand trace files.
"""
function dem_load_sched(tc::ParseISPtimeConfig, tv::ParseISPtimeVarying, profilespath::String; refyear::Int64=2011, poe::Int64=10, release::ParseISP.ISPRelease = ParseISP.ISP2024())
    probs = tc.problem
    did     = 0 # Demands counter
    lmaxid  = isempty(tv.dem_load.id) ? 0 : maximum(tv.dem_load.id)
    scenario_labels = ParseISP.scenario_id_labels(release)
    demand_labels = ParseISP.demand_scenario_labels(release)

    for st in keys(ParseISP.NEMBUSNAME)
        did += 1
        for p in 1:nrow(probs)
            scid = probs[p,:scenario][1]
            sc = scenario_labels[scid]
            demand_label = demand_labels[sc]

            df = CSV.File(joinpath(profilespath, "demand_$(st)_$(sc)", "$(st)_RefYear_$(refyear)_$(demand_label)_POE$(poe)_OPSO_MODELLING_PVLITE.csv")) |> DataFrame

            dstart = probs[p,:dstart]
            dend   = probs[p,:dend]
            df2 = select_trace_date_window(df, dstart, dend)

            data = vec(permutedims(Tables.matrix(df2[:,4:end])))
            data2 = [ (data[2*i-1]+data[2*i])/2 for i in 1:Int64(length(data)/2) ]

            for h in 1:Int64(Dates.Hour(dend - dstart)/Dates.Hour(1)+1)
                lmaxid += 1
                push!(tv.dem_load, [lmaxid, did, scid, dstart+Dates.Hour(h-1), data2[h]])
            end
        end
    end
end

const ISP2026_VRE_PREFIXES_BY_BUS = Dict(
    "NQ" => ("Q1", "Q2", "Q3", "NQ"),
    "CQ" => ("Q4", "Q5", "Q6", "Q7", "Q9", "Q10", "CQ"),
    "GG" => ("GG",),
    "SQ" => ("Q8", "SQ"),
    "NNSW" => ("N1", "N2", "N9", "NNSW"),
    "CNSW" => ("N3", "N4", "N5", "N13", "CNSW"),
    "SNW" => ("N0", "N10", "N11", "N12", "SNW"),
    "SNSW" => ("N6", "N7", "N8", "SNSW"),
    "VIC" => ("V0", "V1", "V2", "V3", "V4", "V5", "V6", "V7", "V8", "V9", "MEL", "SEV", "WNV", "VIC"),
    "TAS" => ("T1", "T2", "T3", "T4", "TAS"),
    "CSA" => ("S2", "S3", "S4", "S5", "S6", "S7", "S8", "CSA", "NSA"),
    "SESA" => ("S1", "SESA"),
)

function _isp2026_vre_capacity_by_bus(inputs_workbook::String, fuel::String)
    summary = _isp2026_generator_summary(inputs_workbook)
    caps = Dict(st => 0.0 for st in keys(ParseISP.NEMBUSNAME))
    for row in eachrow(summary)
        _isp2026_cell_string(row[Symbol("Fuel Type")]) == fuel || continue
        bus = _isp2026_bus_code(row[Symbol("Sub-region")])
        haskey(caps, bus) || continue
        caps[bus] += _isp2026_number(row[Symbol("Maximum capacity (MW)")])
    end
    return caps
end

function _isp2026_vre_trace_files(folder::String, bus::String)
    prefixes = get(ISP2026_VRE_PREFIXES_BY_BUS, bus, (bus,))
    files = sort(filter(f -> !startswith(f, "._") && endswith(f, ".csv"), readdir(folder)))
    matches = filter(files) do f
        any(prefixes) do prefix
            startswith(f, "$(prefix)_") ||
                occursin("_$(prefix)_", f) ||
                occursin("Resources_$(prefix)_", f) ||
                occursin("REZ_$(prefix)_", f)
        end
    end
    isempty(matches) && return files[1:min(length(files), 1)]
    return matches[1:min(length(matches), 12)]
end

function _isp2026_average_vre_trace(folder::String, files, dstart::DateTime, dend::DateTime)
    nhours = Int64(Dates.Hour(dend - dstart) / Dates.Hour(1) + 1)
    data = zeros(nhours * 2)
    nfiles = 0
    for file in files
        df = CSV.File(joinpath(folder, file)) |> DataFrame
        df2 = select_trace_date_window(df, dstart, dend)
        nrow(df2) == 0 && continue
        raw = vec(permutedims(Tables.matrix(df2[:, 4:end])))
        length(raw) == length(data) || continue
        data .+= raw
        nfiles += 1
    end
    nfiles == 0 && return zeros(nhours)
    data ./= nfiles
    return [(data[2*i-1] + data[2*i]) / 2 for i in 1:nhours]
end

function _release_bus_value(df::DataFrame, st::String, col::Symbol, release::ParseISP.ISPRelease)
    if release isa ParseISP.ISP2026
        values = Float64[]
        for row in eachrow(df)
            _isp2026_bus_code(row.bus) == st || continue
            push!(values, _isp2026_number(row[col]))
        end
        return sum(values)
    end
    matches = df[df[!, :bus] .== st, col]
    isempty(matches) && return 0.0
    return matches[1]
end

function _isp2026_push_vre_generator!(ts::ParseISPtimeStatic, gid::Int, st::String, name::String, fuel::String, tech::String, cap::Float64)
    bust = ts.bus
    bus_data = bust[bust[!, :name] .== st, :]
    bus_id = bus_data[!, :id_bus][1]
    bus_lat = bus_data[!, :latitude][1]
    bus_lon = bus_data[!, :longitude][1]
    push!(ts.gen, [gid, name, name, fuel, tech, tech, cap, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, bus_id, 0.0, cap, 9999.9, 9999.9, 0, 1, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0, 0, 1.0, bus_lat, bus_lon, 1, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
end

function gen_pmax_solar_isp2026(tc::ParseISPtimeConfig, ts::ParseISPtimeStatic, tv::ParseISPtimeVarying, inputs_workbook::String, profilespath::String; refyear::Int64=4006)
    probs = tc.problem
    gid = isempty(ts.gen.id_gen) ? 0 : maximum(ts.gen.id_gen)
    pmaxid = isempty(tv.gen_pmax.id) ? 0 : maximum(tv.gen_pmax.id)
    caps = _isp2026_vre_capacity_by_bus(inputs_workbook, "Solar")
    foldertech = joinpath(profilespath, "solar_$(refyear)")

    genid = Dict{String, Int}()
    for st in keys(ParseISP.NEMBUSNAME)
        gid += 1
        genid[st] = gid
        _isp2026_push_vre_generator!(ts, gid, st, "LSPV_$(st)", "Solar", "LargePV", get(caps, st, 0.0))
    end

    file_cache = Dict(st => _isp2026_vre_trace_files(foldertech, st) for st in keys(ParseISP.NEMBUSNAME))
    for p in 1:nrow(probs)
        scid = probs[p, :scenario][1]
        dstart = probs[p, :dstart]
        dend = probs[p, :dend]
        for st in keys(ParseISP.NEMBUSNAME)
            cap = get(caps, st, 0.0)
            profile = cap == 0.0 ? zeros(Int64(Dates.Hour(dend - dstart) / Dates.Hour(1) + 1)) : _isp2026_average_vre_trace(foldertech, file_cache[st], dstart, dend)
            for (h, cf) in enumerate(profile)
                pmaxid += 1
                push!(tv.gen_pmax, [pmaxid, genid[st], scid, dstart + Dates.Hour(h - 1), cf * cap])
            end
        end
    end
end

function gen_pmax_wind_isp2026(tc::ParseISPtimeConfig, ts::ParseISPtimeStatic, tv::ParseISPtimeVarying, inputs_workbook::String, profilespath::String; refyear::Int64=4006)
    probs = tc.problem
    gid = isempty(ts.gen.id_gen) ? 0 : maximum(ts.gen.id_gen)
    pmaxid = isempty(tv.gen_pmax.id) ? 0 : maximum(tv.gen_pmax.id)
    caps = _isp2026_vre_capacity_by_bus(inputs_workbook, "Wind")
    foldertech = joinpath(profilespath, "wind_$(refyear)")

    genid = Dict{String, Int}()
    for st in keys(ParseISP.NEMBUSNAME)
        gid += 1
        genid[st] = gid
        _isp2026_push_vre_generator!(ts, gid, st, "WIND_$(st)", "Wind", "Wind", get(caps, st, 0.0))
    end

    file_cache = Dict(st => _isp2026_vre_trace_files(foldertech, st) for st in keys(ParseISP.NEMBUSNAME))
    for p in 1:nrow(probs)
        scid = probs[p, :scenario][1]
        dstart = probs[p, :dstart]
        dend = probs[p, :dend]
        for st in keys(ParseISP.NEMBUSNAME)
            cap = get(caps, st, 0.0)
            profile = cap == 0.0 ? zeros(Int64(Dates.Hour(dend - dstart) / Dates.Hour(1) + 1)) : _isp2026_average_vre_trace(foldertech, file_cache[st], dstart, dend)
            for (h, cf) in enumerate(profile)
                pmaxid += 1
                push!(tv.gen_pmax, [pmaxid, genid[st], scid, dstart + Dates.Hour(h - 1), cf * cap])
            end
        end
    end
end

"""
    gen_pmax_solar(tc, ts, tv, inputs_workbook, core_outlook_dir, capacity_outlook_workbook, profilespath)

Assemble grid-scale solar pmax schedules by combining ISP workbook metadata,
capacity outlook spreadsheets and hourly trace files. The function interpolates
scenario trajectories, maps them to generator ids and appends the time-varying
limits into `tv.gen_pmax` for every study block in `tc`.

# Arguments
- `tc::ParseISPtimeConfig`: Defines the time horizon to populate.
- `ts::ParseISPtimeStatic`: Supplies generator identifiers and mapping info.
- `tv::ParseISPtimeVarying`: Receives the pmax schedules.
- `inputs_workbook::String`: Source of installed capacity and mapping tables.
- `core_outlook_dir::String`: Storage/generation outlook workbook path.
- `capacity_outlook_workbook::String`: Melted capacity outlook file providing scenario series.
- `profilespath::String`: Directory with solar trace profiles.
"""
function gen_pmax_solar(tc::ParseISPtimeConfig, ts::ParseISPtimeStatic, tv::ParseISPtimeVarying, inputs_workbook::String, core_outlook_dir::String, capacity_outlook_workbook::String, profilespath::String; refyear::Int64=2011, release::ParseISP.ISPRelease = ParseISP.ISP2024(), skip_traces::Bool=false)
    if release isa ParseISP.ISP2026
        return gen_pmax_solar_isp2026(tc, ts, tv, inputs_workbook, profilespath; refyear = refyear)
    end

    probs = tc.problem
    bust = ts.bus
    scenario_labels = ParseISP.scenario_id_labels(release)
    outlook_prefix = "$(ParseISP.release_year(release)) ISP"

    gid = isempty(ts.gen.id_gen) ? 0 : maximum(ts.gen.id_gen);
    pmaxid = isempty(tv.gen_pmax.id) ? 0 : maximum(tv.gen_pmax.id);

    tch = "Solar"
    EXIST_TECH = ParseISP.read_xlsx_with_header(inputs_workbook, "Existing Gen Data Summary", "B11:K297")
    EXIST_SOLAR = EXIST_TECH[occursin.(tch[2:end], coalesce.(EXIST_TECH[!,2],"")),:]
    # @warn("Anticipated solar PV projects not considered in the existing data")

    REZ_BUS = ParseISP.read_xlsx_with_header(inputs_workbook, "Renewable Energy Zones", "B7:G50")
    # println(REZ_BUS)

    genid = Dict()
    for st in setdiff(keys(ParseISP.NEMBUSNAME),["GG", "SNW"]) ## Buses with no large-scale solar projects or REZ are not considered
        gid += 1
        bus_data = bust[bust[!,:name] .== st, :]
        bus_id = bus_data[!, :id_bus][1]    
        bus_lat = bus_data[!, :latitude][1]
        bus_lon = bus_data[!, :longitude][1]
        exs_gen_sol = EXIST_SOLAR[EXIST_SOLAR[!,4] .== st,:];
        if st == "TAS" capaux = 0.0 else capaux = sum(EXIST_SOLAR[EXIST_SOLAR[!,4] .== st,7]) end
        genid[st] = [gid, capaux]
        arrgen = [gid,"LSPV_$(st)","LSPV_$(st)","Solar","LargePV","LargePV", capaux, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, bus_id, 0.0, capaux, 9999.9,  9999.9, 0, 1, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0, 0, 1.0, bus_lat, bus_lon, 1, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        push!(ts.gen, arrgen)
    end

    if !skip_traces
    name_ex = Dict()

    foldertech = joinpath(profilespath, "solar_$(refyear)")

    scid2cdp = Dict(1 => "CDP14", 2 => "CDP14", 3 => "CDP14", 4 => "CDP14")
    auxf = []
    auxk = []

    for p in 1:nrow(probs)
        scid = probs[p,:scenario][1]
        sc = scenario_labels[scid]
        dstart = probs[p,:dstart]
        dend = probs[p,:dend]
        yr = Dates.year(dstart)
        ms = Dates.month(dstart)
        outlookfile = normpath(core_outlook_dir, "..", "Auxiliary", "$(outlook_prefix) - $(sc) - Core_REZCAP.xlsx")

        TECH_CAP = ParseISP.read_xlsx_with_header(capacity_outlook_workbook, "CapacityOutlook", "A1:G14356")
        SOLAR_CAP = ParseISP.read_xlsx_with_header(outlookfile, "REZ Generation Capacity", "A1:AG2238")
        # println(SOLAR_CAP)
        # print first rows of SOLAR_CAP
        # println(first(SOLAR_CAP,5))
        SOLAR_CAP = dropmissing(SOLAR_CAP,:CDP)
        
        y = ms < 7 ? yr - 1 : yr

        for st in setdiff(keys(ParseISP.NEMBUSNAME),["GG", "SNW"]) # Buses with no large-scale solar projects are not considered

            REZs = REZ_BUS[(REZ_BUS[!,Symbol("ISP Sub-region")] .== st),:ID]
            REZSUM = REZ_BUS[(REZ_BUS[!,Symbol("ISP Sub-region")] .== st),[:ID,:Name,Symbol("ISP Sub-region")]]

            SOLARAUX = SOLAR_CAP[in.(SOLAR_CAP[!,:REZ],[REZs]) .& (SOLAR_CAP[!,:CDP] .== scid2cdp[scid]) .& (SOLAR_CAP[!,:Technology] .== tch), [:REZ,Symbol("$(y)-$(string(y+1)[3:end])")]]

            rename!(SOLARAUX, Dict(:REZ => :ID))
            SOLARAUX = innerjoin(SOLARAUX,REZSUM, on = :ID)
            SOLARAUX[!,:EXISTING] = [0.0 for s in 1:nrow(SOLARAUX)]

            dataexi = zeros(Int64(Dates.Hour(dend - dstart)/Dates.Hour(1)+1)*2)
            exi_cap = 0.0
            df2 = DataFrame()
            for r in 1:nrow(EXIST_SOLAR)
                k = EXIST_SOLAR[r,1]
                reg = EXIST_SOLAR[r,5]

                if EXIST_SOLAR[r,4] == st # IF GENERATOR IS IN THE SUBREGION
                    for sexp in 1:nrow(SOLARAUX)
                        if SOLARAUX[sexp,:Name] == reg # IF THE REZ IS EQUAL TO THE REZ OF THE GENERATOR
                            SOLARAUX[sexp,:EXISTING] = SOLARAUX[sexp,:EXISTING] + EXIST_SOLAR[r,10] # ADD CAPACITY TO THE REZ IF THE GENERATOR IS IN THE REZ
                        end
                    end

                    file = ""
                    if k in keys(name_ex)
                        file = name_ex[k]
                    else
                        for f in filter(f -> !startswith(f, "._"), readdir(foldertech))
                            if f[1:3] != "REZ" && occursin(split(k," ")[1],f)
                                push!(auxf,f)
                                push!(auxk,k)
                                file = f
                                break
                            end
                        end
                    end

                    df = CSV.File(joinpath(foldertech, file)) |> DataFrame

                    df2 = select_trace_date_window(df, dstart, dend)
                    dataexi = dataexi .+ vec(permutedims(Tables.matrix(df2[:,4:end]))) * EXIST_SOLAR[r,10]
                    exi_cap += EXIST_SOLAR[r,10] # EXISTING CAPACITY FROM WINTER RATING
                end
            end
            SOLARAUX[!,:DIFF] = SOLARAUX[!,2] .- SOLARAUX[!,:EXISTING] # REZ capacity utilised 

            naux = 0    
            datanew = zeros(Int64(Dates.Hour(dend - dstart)/Dates.Hour(1)+1)*2)
            nauxrez = 0
            datarez = zeros(Int64(Dates.Hour(dend - dstart)/Dates.Hour(1)+1)*2)  

            drezcap = 0
            rezcap = 0
            tch_ = "Utility solar"

                if dstart > DateTime(2024,7,1,0,0,0)
                    instcap = TECH_CAP[(TECH_CAP[!,:Scenario] .== sc) .& (TECH_CAP[!,:Subregion] .== st) .& (TECH_CAP[!,:Technology] .== tch_) .& (year.(TECH_CAP[!,:date]) .== y), 7][1]
                    # future capacity profile (average of REZ profiles in the area)
                    for f in filter(f -> !startswith(f, "._"), readdir(foldertech))
                        sub = split(f,['_','.'])
                        if "REZ" in sub && "SAT" in sub && sub[2] in REZs
                            df = CSV.File(joinpath(foldertech, f)) |> DataFrame
                            df2 = select_trace_date_window(df, dstart, dend)
                            datanew = datanew .+ vec(permutedims(Tables.matrix(df2[:,4:end])))
                            naux += 1

                        #check if specific REZ capacity is available
                        if nrow(SOLARAUX) > 0
                            for r in 1:nrow(SOLARAUX)
                                if SOLARAUX[r,:ID] == sub[2] && SOLARAUX[r,:DIFF] >= 0.01
                                    datarez = datarez .+ vec(permutedims(Tables.matrix(df2[:,4:end]))) * SOLARAUX[r,:DIFF]
                                    drezcap += SOLARAUX[r,:DIFF]
                                end
                            end
                        end

                    end
                end
            else
                instcap = exi_cap
            end

            if (instcap - exi_cap - drezcap) > 0
                dataN = datanew / naux * (instcap - exi_cap - drezcap)
                data = (dataexi .+ datarez) .+ dataN
            elseif instcap - exi_cap < drezcap
                dataN = datanew / naux * abs(instcap - exi_cap)
                data = dataexi .+ dataN
                if ((instcap - exi_cap) < 0 )&& (abs(instcap - exi_cap) > 100)  end #@warn("$(st) $(sc) $(abs(instcap - exi_cap))")
            else
                dataN = naux == 0 ? datanew : datanew / naux * 0.0
                data = (dataexi .+ datarez) .+ dataN
            end

            data2 = [ (data[2*i-1]+data[2*i])/2 for i in 1:Int64(length(data)/2) ]
            let _tc = TECH_CAP[(TECH_CAP[!,:Scenario].==sc).&(TECH_CAP[!,:Subregion].==st).&(TECH_CAP[!,:Technology].==tch_).&(year.(TECH_CAP[!,:date]).==y+1), 7]
                if !isempty(_tc) && maximum(data2) > 0.0 && (Float64(_tc[1]) - maximum(data2)) > 5.0
                    data2 .= data2 .* (Float64(_tc[1]) / maximum(data2))
                end
            end
            for h in 1:Int64(Dates.Hour(dend - dstart)/Dates.Hour(1)+1)
                pmaxid += 1
                push!(tv.gen_pmax, [pmaxid, genid[st][1], scid, dstart+Dates.Hour(h-1), data2[h]])
            end
        end
    end
    end
end

"""
    gen_pmax_wind(tc, ts, tv, inputs_workbook, core_outlook_dir, capacity_outlook_workbook, profilespath)

Generate wind pmax traces following the same process as solar: combine ISP
metadata, scenario outlooks and wind traces to populate `tv.gen_pmax` for each
scenario block.

# Arguments
- `tc::ParseISPtimeConfig`, `ts::ParseISPtimeStatic`, `tv::ParseISPtimeVarying`: See
  `gen_pmax_solar`.
- `inputs_workbook::String`, `core_outlook_dir::String`, `capacity_outlook_workbook::String`,
  `profilespath::String`: Data sources containing wind capacities and traces.
"""
function gen_pmax_wind(tc::ParseISPtimeConfig, ts::ParseISPtimeStatic, tv::ParseISPtimeVarying, inputs_workbook::String, core_outlook_dir::String, capacity_outlook_workbook::String, profilespath::String; refyear::Int64=2011, release::ParseISP.ISPRelease = ParseISP.ISP2024(), skip_traces::Bool=false)
    if release isa ParseISP.ISP2026
        return gen_pmax_wind_isp2026(tc, ts, tv, inputs_workbook, profilespath; refyear = refyear)
    end

    probs = tc.problem
    bust = ts.bus
    scenario_labels = ParseISP.scenario_id_labels(release)
    outlook_prefix = "$(ParseISP.release_year(release)) ISP"

    gid = isempty(ts.gen.id_gen) ? 0 : maximum(ts.gen.id_gen);
    pmaxid = isempty(tv.gen_pmax.id) ? 0 : maximum(tv.gen_pmax.id);

    tch = "Wind"
    EXIST_TECH = ParseISP.read_xlsx_with_header(inputs_workbook, "Existing Gen Data Summary", "B11:K297")
    EXIST_WIND = EXIST_TECH[occursin.(tch[2:end], coalesce.(EXIST_TECH[!,2],"")),:]
    REZ_BUS = ParseISP.read_xlsx_with_header(inputs_workbook, "Renewable Energy Zones", "B7:G50")

    genid = Dict()
    for st in setdiff(keys(ParseISP.NEMBUSNAME),["GG"]) ## Buses with no large-scale solar projects or REZ are not considered
        gid += 1
        bus_data = bust[bust[!,:name] .== st, :]
        bus_id = bus_data[!, :id_bus][1]    
        bus_lat = bus_data[!, :latitude][1]
        bus_lon = bus_data[!, :longitude][1]

        arrgen = []
        if st == "SNW"
            capaux = 0.0
            genid[st] = [gid, capaux]
            arrgen = [gid,"WIND_$(st)","WIND_$(st)","Wind","Wind","Wind",        capaux, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, bus_id, 0.0, capaux, 9999.9,  9999.9, 0, 1, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0, 0, 1.0, bus_lat, bus_lon, 1, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        else
            capaux = sum(EXIST_WIND[EXIST_WIND[!,4] .== st,7])
            genid[st] = [gid, capaux]
            arrgen = [gid,"WIND_$(st)","WIND_$(st)","Wind","Wind","Wind",        capaux, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, bus_id, 0.0, capaux, 9999.9,  9999.9, 0, 1, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0, 0, 1.0, bus_lat, bus_lon, 1, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        end
        push!(ts.gen, arrgen)
    end

    if !skip_traces
    foldertech = joinpath(profilespath, "wind_$(refyear)")

    scid2cdp = Dict(1 => "CDP14", 2 => "CDP14", 3 => "CDP14", 4 => "CDP14")
    auxf = []
    auxk = []

    for p in 1:nrow(probs)
        scid = probs[p,:scenario][1]
        sc = scenario_labels[scid]
        dstart = probs[p,:dstart]
        dend = probs[p,:dend]
        yr = Dates.year(dstart)
        ms = Dates.month(dstart)
        outlookfile = normpath(core_outlook_dir, "..", "Auxiliary", "$(outlook_prefix) - $(sc) - Core_REZCAP.xlsx")

        TECH_CAP = ParseISP.read_xlsx_with_header(capacity_outlook_workbook, "CapacityOutlook", "A1:G14356")
        WIND_CAP = ParseISP.read_xlsx_with_header(outlookfile, "REZ Generation Capacity", "A1:AG2238")
        WIND_CAP = dropmissing(WIND_CAP,:CDP)
        
        y = ms < 7 ? yr - 1 : yr

        for st in setdiff(keys(ParseISP.NEMBUSNAME),["GG"]) # Buses with no large-scale wind are not considered

            REZs = REZ_BUS[(REZ_BUS[!,Symbol("ISP Sub-region")] .== st),:ID]
            REZSUM = REZ_BUS[(REZ_BUS[!,Symbol("ISP Sub-region")] .== st),[:ID,:Name,Symbol("ISP Sub-region")]]

            WINDAUX = WIND_CAP[in.(WIND_CAP[!,:REZ],[REZs]) .& (WIND_CAP[!,:CDP] .== scid2cdp[scid]) .& (WIND_CAP[!,:Technology] .== tch), [:REZ,Symbol("$(y)-$(string(y+1)[3:end])")]]

            rename!(WINDAUX, Dict(:REZ => :ID))
            WINDAUX = innerjoin(WINDAUX,REZSUM, on = :ID)
            WINDAUX[!,:EXISTING] = [0.0 for s in 1:nrow(WINDAUX)]

            dataexi = zeros(Int64(Dates.Hour(dend - dstart)/Dates.Hour(1)+1)*2)
            exi_cap = 0.0
            df2 = DataFrame()
            for r in 1:nrow(EXIST_WIND)
                k = EXIST_WIND[r,1]
                reg = EXIST_WIND[r,5]
                if EXIST_WIND[r,4] == st # IF GENERATOR IS IN THE SUBREGION
                    for sexp in 1:nrow(WINDAUX)
                        if WINDAUX[sexp,:Name] == reg # IF THE REZ IS EQUAL TO THE REZ OF THE GENERATOR
                            WINDAUX[sexp,:EXISTING] = WINDAUX[sexp,:EXISTING] + EXIST_WIND[r,7] # ADD CAPACITY TO THE REZ IF THE GENERATOR IS IN THE REZ
                        end
                    end
                    # println(" =============== $(k) ============== ")
                    file = ""
                    name_ex_weather_year = ParseISP.get_name_ex(refyear)
                    if k in keys(name_ex_weather_year)
                        file = name_ex_weather_year[k]
                    else
                        for f in filter(f -> !startswith(f, "._"), readdir(foldertech))
                            if f[1:3] != "REZ" && occursin(split(k," ")[1],f)
                                push!(auxf,f)
                                push!(auxk,k)
                                file = f
                                # println(k, " ==> ", f)
                                break
                            end
                        end
                    end
                    # println(" $(k) ======>", file)

                    df = CSV.File(joinpath(foldertech, file)) |> DataFrame

                    df2 = select_trace_date_window(df, dstart, dend)
                    dataexi = dataexi .+ vec(permutedims(Tables.matrix(df2[:,4:end]))) * EXIST_WIND[r,7]
                    exi_cap += EXIST_WIND[r,7] # EXISTING CAPACITY FROM WINTER RATING
                end
            end
            WINDAUX[!,:DIFF] = WINDAUX[!,2] .- WINDAUX[!,:EXISTING] # REZ capacity utilised 

            naux = 0    
            datanew = zeros(Int64(Dates.Hour(dend - dstart)/Dates.Hour(1)+1)*2)
            nauxrez = 0
            datarez = zeros(Int64(Dates.Hour(dend - dstart)/Dates.Hour(1)+1)*2)  

            drezcap = 0
            rezcap = 0
            tch_ = "Wind"

            if dstart > DateTime(2024,7,1,0,0,0)
                instcap = TECH_CAP[(TECH_CAP[!,:Scenario] .== sc) .& (TECH_CAP[!,:Subregion] .== st) .& (TECH_CAP[!,:Technology] .== tch_) .& (year.(TECH_CAP[!,:date]) .== y), 7][1]
                # future capacity profile (average of REZ profiles in the area)
                for f in filter(f -> !startswith(f, "._"), readdir(foldertech))
                    sub = split(f,['_','.'])
                    if sub[1] in REZs && "WH" in sub#f[1] == st[1]
                        df = CSV.File(joinpath(foldertech, f)) |> DataFrame
                        df2 = select_trace_date_window(df, dstart, dend)
                        datanew = datanew .+ vec(permutedims(Tables.matrix(df2[:,4:end])))
                        naux += 1

                        #check if specific REZ capacity is available
                        if nrow(WINDAUX) > 0
                            for r in 1:nrow(WINDAUX)
                                if WINDAUX[r,:ID] == sub[1] && WINDAUX[r,:DIFF] >= 0.01
                                    datarez = datarez .+ vec(permutedims(Tables.matrix(df2[:,4:end]))) * WINDAUX[r,:DIFF]
                                    drezcap += WINDAUX[r,:DIFF]
                                end
                            end
                        end

                    end
                end
            else
                instcap = exi_cap
            end

            if (instcap - exi_cap - drezcap) > 0
                dataN = datanew / naux * (instcap - exi_cap - drezcap)
                data = (dataexi .+ datarez) .+ dataN
            elseif instcap - exi_cap < drezcap
                # print(instcap - exi_cap)
                dataN = datanew / naux * abs(instcap - exi_cap)
                data = dataexi .+ dataN
                if ((instcap - exi_cap) < 0 )&& (abs(instcap - exi_cap) > 100) end #@warn("$(st) $(sc) $(abs(instcap - exi_cap))") 
            else
                dataN = naux == 0 ? datanew : datanew / naux * 0.0
                data = (dataexi .+ datarez) .+ dataN
            end

            data2 = [ (data[2*i-1]+data[2*i])/2 for i in 1:Int64(length(data)/2) ]
            let _tc_wind     = TECH_CAP[(TECH_CAP[!,:Scenario].==sc).&(TECH_CAP[!,:Subregion].==st).&(TECH_CAP[!,:Technology].=="Wind").&(year.(TECH_CAP[!,:date]).==y+1), 7],
                _tc_offshore = TECH_CAP[(TECH_CAP[!,:Scenario].==sc).&(TECH_CAP[!,:Subregion].==st).&(TECH_CAP[!,:Technology].=="Offshore wind").&(year.(TECH_CAP[!,:date]).==y+1), 7]
                _tc_total = (isempty(_tc_wind) ? 0.0 : Float64(_tc_wind[1])) + (isempty(_tc_offshore) ? 0.0 : Float64(_tc_offshore[1]))
                if _tc_total > 0.0 && maximum(data2) > 0.0 && (_tc_total - maximum(data2)) > 5.0
                    data2 .= data2 .* (_tc_total / maximum(data2))
                end
            end
            for h in 1:Int64(Dates.Hour(dend - dstart)/Dates.Hour(1)+1)
                pmaxid += 1
                push!(tv.gen_pmax, [pmaxid, genid[st][1], scid, dstart+Dates.Hour(h-1), data2[h]])
            end
        end
    end
    end
end

"""
    ess_vpps(tc, ts, tv, storage_capacity_outlook_workbook, storage_energy_outlook_workbook)

Load the virtual power plant (VPP) capacity and energy outlook spreadsheets and
add the resulting storage schedules to the ESS tables. This augments the static
VPP definitions with time-varying commissioning and power/energy trajectories.

# Arguments
- `tc`, `ts`, `tv`: Standard ISP containers used for indexing and storage.
- `storage_capacity_outlook_workbook::String`: Path to the capacity outlook workbook.
- `storage_energy_outlook_workbook::String`: Path to the energy outlook workbook.
"""
function ess_vpps(tc::ParseISPtimeConfig, ts::ParseISPtimeStatic, tv::ParseISPtimeVarying, storage_capacity_outlook_workbook::String, storage_energy_outlook_workbook::String; release::ParseISP.ISPRelease = ParseISP.ISP2024(), skip_traces::Bool=false)
    bust = ts.bus
    probs = tc.problem
    scenario_definitions = ParseISP.scenario_definitions(release)
    scenario_labels = ParseISP.scenario_id_labels(release)

    bmid = isempty(ts.ess.id_ess) ? 0 : maximum(ts.ess.id_ess)
    bmpmid = isempty(tv.ess_pmax.id) ? 0 : maximum(tv.ess_pmax.id)
    bmlmid = isempty(tv.ess_lmax.id) ? 0 : maximum(tv.ess_lmax.id)
    bmemid = isempty(tv.ess_emax.id) ? 0 : maximum(tv.ess_emax.id)
    BMBESSid = Dict()

    sc = collect(keys(scenario_definitions))[2]
    # CER STORAGE CAPACITY
    VPPCAP = ParseISP.read_xlsx_with_header(storage_capacity_outlook_workbook, "$(sc)", "A1:AG1769")
    VPPCAP = VPPCAP[(VPPCAP[!,1] .== "CDP14") .& (VPPCAP[!,Symbol("storage category")] .== "Coordinated CER storage"),:]
    rename!(VPPCAP, Dict(:Subregion => :bus))

    #CER STORAGE ENERGY
    VPPENE = ParseISP.read_xlsx_with_header(storage_energy_outlook_workbook, "$(sc)", "A1:AG1769")
    VPPENE = VPPENE[(VPPENE[!,1] .== "CDP14") .& (VPPENE[!,Symbol("Technology")] .== "Coordinated CER storage"),:]
    rename!(VPPENE, Dict(:Subregion => :bus))

    first_start = minimum(probs.dstart)
    seed_year = Dates.month(first_start) < 7 ? Dates.year(first_start) - 1 : Dates.year(first_start)

    for st in keys(ParseISP.NEMBUSES)
        yr = seed_year
        bmid += 1
        bus_id = bust[bust[!,:name] .== st, :id_bus][1]
        year_col = Symbol("$(yr)-$(string(yr+1)[3:end])")
        data_cap = _release_bus_value(VPPCAP, st, year_col, release)
        data_ene = _release_bus_value(VPPENE, st, year_col, release) * 1000
        BMBESSid[st] = [bmid, data_cap, data_ene]
        arrbmss = [bmid,"VPP_CER_$(st)","VPP_CER_$(st)","BESS","SHALLOW", data_cap, 0, 1, bus_id, 0.9, 0.9, 10.0, 10.0, data_ene, 0.0, data_cap, 0.0, data_cap, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0, 0, 0, 0, 0, 0.0, 0.0, 0.0, 0.0, 0.0, ParseISP.NEMBUSES[st][2], ParseISP.NEMBUSES[st][1], 1, 0]
        push!(ts.ess, arrbmss)
    end

    if !skip_traces
    for p in 1:nrow(probs)
        scid = probs[p,:scenario][1]
        sc = scenario_labels[scid]
        dstart = probs[p,:dstart]
        dend = probs[p,:dend]
        yr = Dates.year(dstart)
        ds = Dates.day(dstart)
        de = Dates.day(dend)
        ms = Dates.month(dstart)
        me = Dates.month(dend)

        yr = ms < 7 ? yr - 1 : yr
        # VPPCAP = ParseISP.read_xlsx_with_header(storage_capacity_outlook_workbook, "$(sc)", "A1:AE2080")
        # VPPENE = ParseISP.read_xlsx_with_header(storage_energy_outlook_workbook, "$(sc)", "A1:AE2080")
        VPPCAP = ParseISP.read_xlsx_with_header(storage_capacity_outlook_workbook, "$(sc)", "A1:AG1769")
        VPPENE = ParseISP.read_xlsx_with_header(storage_energy_outlook_workbook, "$(sc)", "A1:AG1769")
        for st in keys(ParseISP.NEMBUSES)
            # CER STORAGE CAPACITY
            VPPCAP = VPPCAP[(VPPCAP[!,1] .== "CDP14") .& (VPPCAP[!,Symbol("storage category")] .== "Coordinated CER storage"),:]
            rename!(VPPCAP, names(VPPCAP)[4] => :bus)

            #CER STORAGE ENERGY
            VPPENE = VPPENE[(VPPENE[!,1] .== "CDP14") .& (VPPENE[!,Symbol("Technology")] .== "Coordinated CER storage"),:]
            rename!(VPPENE, names(VPPENE)[4] => :bus)

            year_col = Symbol("$(yr)-$(string(yr+1)[3:end])")
            data_cap = _release_bus_value(VPPCAP, st, year_col, release)
            data_ene = _release_bus_value(VPPENE, st, year_col, release) * 1000

            bmpmid+=1; bmlmid+=1; bmemid+=1;
            push!(tv.ess_pmax, [bmpmid, BMBESSid[st][1], scid, dstart, data_cap])
            push!(tv.ess_lmax, [bmlmid, BMBESSid[st][1], scid, dstart, data_cap])
            push!(tv.ess_emax, [bmemid, BMBESSid[st][1], scid, dstart, data_ene])
        end
    end
    end
end

"""
    der_tables(ts)

Initialise distributed energy resource (DER) static tables with the regional
placeholders expected by downstream schedulers. These tables track aggregated
DER participation factors and ids used when scheduling DER forecasts.

# Arguments
- `ts::ParseISPtimeStatic`: Mutated with DER metadata rows.
"""
function der_tables(ts::ParseISPtimeStatic)
    # ============================================ #
    # DSP table development  ===================== #
    # ============================================ #
    # dem = ts.dem
    # maxiddem = isempty(dem) ? 1 : maximum(dem.id_dem) + 1
    # cdem_dsp = Dict()
    # for row in eachrow(dem)
    #     cdem_name = replace(row["name"], "DEM"=>"DSP")
    #     row_cdem = (maxiddem, cdem_name, 0, row["id_bus"], 1, 1 ,17500, 1)
    #     push!(ts.dem, row_cdem)
    #     cdem_dsp[cdem_name] = maxiddem
    #     maxiddem += 1
    # end
    # ======================================== #
    # DSP VALUES
    # ======================================== #
    der       = ts.der
    dem       = ts.dem
    cont_dem  = dem[dem[!, :controllable] .== 1,:]
    deridx    = isempty(der) ? 1 : maximum(der.id_der) + 1
    cost_band = Dict(1 => 300,
                     2 => 500,
                     3 => 1000,
                     4 => 7500,
                     "RR" => 41480,) # Reliability Response (Based on the value of customer reliability VCR: https://www.aer.gov.au/industry/registers/resources/reviews/values-customer-reliability-2024 )
    bands     = length(cost_band)

    for row in eachrow(cont_dem)
        for band in push!(Any[collect(1:4)...], "RR")#collect(1:bands)
            dem_name = row["name"]*"_DSP_BAND$band"
            id_dem   = row["id_dem"]
            row_der = [ deridx,             # ID_DER
                        dem_name,           # NAME
                        "DSP",              # TECH
                        id_dem,             # ID_DEMAND
                        1,                  # ACTIVE
                        0,                  # INVESTMENT
                        0,                  # CAPACITY
                        1,                  # REDUCT
                        0,                  # PRED_MAX
                        cost_band[band],    # COST_RED
                        1,]                 # N
            push!(ts.der, row_der)
            deridx += 1
        end
    end
end

"""
    der_pred_sched(ts, tv, dsp_data)

Load demand-side participation (DSP) datasets and generate DER prediction
schedules. The resulting time-varying traces are linked back to the DER entries
inserted by `der_tables`.

# Arguments
- `ts::ParseISPtimeStatic`: Provides DER ids.
- `tv::ParseISPtimeVarying`: Receives DER time series.
- `dsp_data::String`: Path to the DSP workbook or data file.
"""
function der_pred_sched(ts::ParseISPtimeStatic, tv::ParseISPtimeVarying, inputs_workbook::String; release::ParseISP.ISPRelease = ParseISP.ISP2024())
    if release isa ParseISP.ISP2026
        return tv
    end

    sce_dsp = Dict("Progressive Change"     => Dict("QLD" => Dict("SUMMER"  => "B128:AG133", "WINTER"  =>"B137:AG142"), 
                                                    "NSW" => Dict("SUMMER"  => "B108:AG113", "WINTER"  =>"B118:AG123"), 
                                                    "SA"  => Dict("SUMMER"  => "B147:AG152", "WINTER"  => "B156:AG161"),
                                                    "TAS" => Dict("SUMMER"  => "B166:AG171", "WINTER"  => "B175:AG180"),
                                                    "VIC" => Dict("SUMMER"  => "B185:AG190", "WINTER"  => "B194:AG199")),

                   "Step Change"            => Dict("QLD" => Dict("SUMMER" => "B226:AG231", "WINTER" => "B235:AG240"), 
                                                    "NSW" => Dict("SUMMER" => "B206:AG211", "WINTER" => "B216:AG221"), 
                                                    "SA"  => Dict("SUMMER" => "B245:AG250", "WINTER" => "B254:AG259"),
                                                    "TAS" => Dict("SUMMER" => "B264:AG269", "WINTER" => "B273:AG278"),
                                                    "VIC" => Dict("SUMMER" => "B283:AG288", "WINTER" => "B292:AG297")),

                   "Green Energy Exports"   => Dict("QLD" => Dict("SUMMER"  => "B30:AG35", "WINTER" =>"B39:AG44"), 
                                                    "NSW" => Dict("SUMMER"  => "B10:AG15", "WINTER" => "B20:AG25"), 
                                                    "SA"  => Dict("SUMMER"  =>"B49:AG54", "WINTER"  =>"B58:AG63"), 
                                                    "TAS" => Dict("SUMMER"  =>"B68:AG73", "WINTER"  =>"B77:AG82"),
                                                    "VIC" => Dict("SUMMER"  =>"B87:AG92", "WINTER"  =>"B96:AG101")))

    for scenario in collect(keys(ParseISP.scenario_definitions(release)))
        sce_map = sce_dsp[scenario]
        QLD_SUM = ParseISP.read_xlsx_with_header(inputs_workbook, "DSP", sce_map["QLD"]["SUMMER"])
        QLD_WIN = ParseISP.read_xlsx_with_header(inputs_workbook, "DSP", sce_map["QLD"]["WINTER"])

        NSW_SUM = ParseISP.read_xlsx_with_header(inputs_workbook, "DSP", sce_map["NSW"]["SUMMER"])
        NSW_WIN = ParseISP.read_xlsx_with_header(inputs_workbook, "DSP", sce_map["NSW"]["WINTER"])

        SA_SUM = ParseISP.read_xlsx_with_header(inputs_workbook, "DSP", sce_map["SA"]["SUMMER"])
        SA_WIN = ParseISP.read_xlsx_with_header(inputs_workbook, "DSP", sce_map["SA"]["WINTER"])

        TAS_SUM = ParseISP.read_xlsx_with_header(inputs_workbook, "DSP", sce_map["TAS"]["SUMMER"])
        TAS_WIN = ParseISP.read_xlsx_with_header(inputs_workbook, "DSP", sce_map["TAS"]["WINTER"])

        VIC_SUM = ParseISP.read_xlsx_with_header(inputs_workbook, "DSP", sce_map["VIC"]["SUMMER"])
        VIC_WIN = ParseISP.read_xlsx_with_header(inputs_workbook, "DSP", sce_map["VIC"]["WINTER"])
        # ======================================== #
        # <><><> QLD
        # ++ NQ
        perc = 0.0
        der_ids = ts.der[occursin.("NQ", ts.der[!, :name]), :].id_der
        ParseISP.inputDB_dsp(tv, QLD_SUM, der_ids, scenario, perc; release = release)
        ParseISP.inputDB_dsp(tv, QLD_WIN, der_ids, scenario, perc; release = release)

        # ++ CQ
        perc = 0.0
        der_ids = ts.der[occursin.("CQ", ts.der[!, :name]), :].id_der
        ParseISP.inputDB_dsp(tv, QLD_SUM, der_ids, scenario, perc; release = release)
        ParseISP.inputDB_dsp(tv, QLD_WIN, der_ids, scenario, perc; release = release)

        # ++ GG
        perc = 0.0
        der_ids = ts.der[occursin.("GG", ts.der[!, :name]), :].id_der
        ParseISP.inputDB_dsp(tv, QLD_SUM, der_ids, scenario, perc; release = release)
        ParseISP.inputDB_dsp(tv, QLD_WIN, der_ids, scenario, perc; release = release)

        # ++ SQ
        perc = 1.0 # Total assigned to SQ
        der_ids = ts.der[occursin.("SQ", ts.der[!, :name]), :].id_der
        ParseISP.inputDB_dsp(tv, QLD_SUM, der_ids, scenario, perc; release = release)
        ParseISP.inputDB_dsp(tv, QLD_WIN, der_ids, scenario, perc; release = release)
        # ======================================== #
        # ======================================== #
        # <><><> NSW
        # ++ NNSW
        perc = 0.0
        der_ids = ts.der[occursin.("NNSW", ts.der[!, :name]), :].id_der
        ParseISP.inputDB_dsp(tv, NSW_SUM, der_ids, scenario, perc; release = release)
        ParseISP.inputDB_dsp(tv, NSW_WIN, der_ids, scenario, perc; release = release)

        # ++ CNSW
        perc = 0.0
        der_ids = ts.der[occursin.("CNSW", ts.der[!, :name]), :].id_der
        ParseISP.inputDB_dsp(tv, NSW_SUM, der_ids, scenario, perc; release = release)
        ParseISP.inputDB_dsp(tv, NSW_WIN, der_ids, scenario, perc; release = release)

        # ++ SNW
        perc = 1.0 # Total assigned to Sydney, Newcastle and Wollongong
        der_ids = ts.der[occursin.("SNW", ts.der[!, :name]), :].id_der
        ParseISP.inputDB_dsp(tv, NSW_SUM, der_ids, scenario, perc; release = release)
        ParseISP.inputDB_dsp(tv, NSW_WIN, der_ids, scenario, perc; release = release)

        # ++ SNSW
        perc = 0.0
        der_ids = ts.der[occursin.("SNSW", ts.der[!, :name]), :].id_der
        ParseISP.inputDB_dsp(tv, NSW_SUM, der_ids, scenario, perc; release = release)
        ParseISP.inputDB_dsp(tv, NSW_WIN, der_ids, scenario, perc; release = release)
        # ======================================== #
        # VIC
        perc = 1.0 # Total assigned to VIC
        der_ids = ts.der[occursin.("VIC", ts.der[!, :name]), :].id_der
        ParseISP.inputDB_dsp(tv, VIC_SUM, der_ids, scenario, perc; release = release)
        ParseISP.inputDB_dsp(tv, VIC_WIN, der_ids, scenario, perc; release = release)

        # ======================================== #
        # TAS
        perc = 1.0 # Total assigned to TAS
        der_ids = ts.der[occursin.("TAS", ts.der[!, :name]), :].id_der
        ParseISP.inputDB_dsp(tv, TAS_SUM, der_ids, scenario, perc; release = release)
        ParseISP.inputDB_dsp(tv, TAS_WIN, der_ids, scenario, perc; release = release)

        # ======================================== #
        # <><><> SA
        # ++ CSA
        perc = 1.0
        der_ids = ts.der[occursin.("CSA", ts.der[!, :name]), :].id_der
        ParseISP.inputDB_dsp(tv, SA_SUM, der_ids, scenario, perc; release = release)
        ParseISP.inputDB_dsp(tv, SA_WIN, der_ids, scenario, perc; release = release)

        # ++ SESA
        perc = 0.0
        der_ids = ts.der[occursin.("SESA", ts.der[!, :name]), :].id_der
        ParseISP.inputDB_dsp(tv, SA_SUM, der_ids, scenario, perc; release = release)
        ParseISP.inputDB_dsp(tv, SA_WIN, der_ids, scenario, perc; release = release)
    end
end

"""
    gen_inflow_sched(ts, tv, tc, inputs_workbook)

Construct Hydro generation inflow schedules and other hydro inflow constraints based
on ISP workbook assumptions. The helper ties reservoir inflows to generator ids
and returns the Snowy subset for re-use by ESS inflow routines (specific for TUMUT 3 pumped).

# Arguments
- `ts::ParseISPtimeStatic`, `tv::ParseISPtimeVarying`, `tc::ParseISPtimeConfig`: Standard
  ISP containers.
- `inputs_workbook::String`: Workbook providing inflow/release assumptions.

# Returns
- `DataFrame`: Snowy generator inflow schedule used by `ess_inflow_sched`.
"""
function gen_inflow_sched(ts::ParseISPtimeStatic, tv::ParseISPtimeVarying, tc::ParseISPtimeConfig, inputs_workbook::String, ispmodel::String; release::ParseISP.ISPRelease = ParseISP.ISP2024())
    if release isa ParseISP.ISP2026
        hydro_model_prefix = "$(ParseISP.release_year(release)) ISP"
        for scenario in keys(ParseISP.scenario_definitions(release))
            hydro_root = normpath(ispmodel, "$(hydro_model_prefix) $(scenario)", "Traces", "hydro")
            isdir(hydro_root) || error("Missing ISP2026 hydro trace directory: $(hydro_root)")
            any(f -> endswith(f, ".csv"), readdir(hydro_root)) || error("No ISP2026 hydro trace CSVs found in $(hydro_root)")
        end
        return DataFrame(id_gen = Int[], partial = Float64[])
    end

    HOURS_PER_DAY = 24
    scenario_definitions = ParseISP.scenario_definitions(release)
    hydro_scenario_labels = ParseISP.hydro_scenario_labels(release)
    hydro_model_prefix = "$(ParseISP.release_year(release)) ISP"

    gen       = ts.gen
    hydro_gen = filter(row -> row.fuel == "Hydro", gen)
    hydro_gen[!, :gen_totcap] = hydro_gen.pmax .* hydro_gen.n # Total installed capacity of hydro generators
    gen_inflow_dummy = deepcopy(tv.gen_inflow)

    hourly_snowy = build_hourly_snowy(inputs_workbook); # Generate hourly values for the Snowy scheme (Tumut, Murray, etc) using the inflows from the IASR 
    df_snowy_capacity = nothing

    # Pre-group generators by inflow file
    gens_by_file = Dict{String, Vector{typeof(first(first(ParseISP.HYDRO2FILE)))}}()
    for (gen_id, fname) in ParseISP.HYDRO2FILE
        push!(get!(Vector{typeof(gen_id)}, gens_by_file, fname), gen_id)
    end

    gens_by_file_sorted = Dict(fname => sort!(copy(ids)) for (fname, ids) in gens_by_file) # Associate each inflow file to a sorted list of generator that receive the corresponding inflow
    hydro_groups = Dict(
        fname => subset(hydro_gen, :id_gen => ByRow(in(ids)))
        for (fname, ids) in gens_by_file_sorted
    )

    # 1 - Hydro Inflows
    for scenario in keys(scenario_definitions)
        hydro_root    = "$(ispmodel)/$(hydro_model_prefix) $(scenario)/Traces/hydro/"
        sce_label     = scenario_definitions[scenario]      # Scenario number
        hydro_sce     = hydro_scenario_labels[scenario] # Hydro scenario from PLEXOS model

        for (file_name, gen_ids) in gens_by_file_sorted
            startswith(file_name, "MonthlyNaturalInflow") || continue # Skip file with energy constraints and only process inflow files

            gen_entries = hydro_groups[file_name]
            total_cap   = sum(gen_entries.gen_totcap)
            gen_entries[!, :partial] .= gen_entries.gen_totcap ./ total_cap
            #print gen_entries id_gen, gen_totcap, partial
            # println(gen_entries[:, [:id_gen, :name, :gen_totcap, :partial]])

            filepath = normpath(hydro_root, file_name * "_" * hydro_sce * ".csv")
            inflow_data = CSV.read(filepath, DataFrame)

            # Create timestamped DataFrame with daily inflows
            df_timestamped = select(
                transform(inflow_data, [:Year, :Month, :Day] => ByRow(DateTime) => :date),
                :date, :Inflows
            )

            n_days       = nrow(df_timestamped)
            n_hours      = n_days * HOURS_PER_DAY
            base_dates   = Vector{DateTime}(undef, n_hours)
            base_inflows = Vector{Float64}(undef, n_hours)

            idx = 1
            for row in eachrow(df_timestamped)
                # Potential energy = ρgQHη (Water density * gravity * Inflow * head * turbine efficiency) [W] / 10^6 = MW  
                per_hour = row.Inflows * 1000 * 9.81 * 100 * 0.9 / 10^6  #/ HOURS_PER_DAY # Distribute daily inflow equally over 24 hours // Multiply here to transform from hourly cumec to MWh (inflow)
                for h in 0:HOURS_PER_DAY-1
                    base_dates[idx]   = row.date + Hour(h)
                    base_inflows[idx] = per_hour
                    idx += 1
                end
            end

            base_ids = collect(1:n_hours)

            # Pro-rate inflows among generators based on their capacity share
            for row in eachrow(gen_entries)
                scaled = base_inflows .* row.partial ./ row.n
                append!(gen_inflow_dummy, DataFrame(
                    id       = base_ids,
                    id_gen   = fill(row.id_gen, n_hours),
                    scenario = fill(sce_label, n_hours),
                    date     = base_dates,
                    value    = scaled,
                ))
            end
        end
    end

    # 2 - Yearly Energy Limits
    for scenario in keys(scenario_definitions)
        hydro_root    = "$(ispmodel)/$(hydro_model_prefix) $(scenario)/Traces/hydro/"
        sce_label     = scenario_definitions[scenario]      # Scenario number
        hydro_sce     = hydro_scenario_labels[scenario] # Hydro scenario from PLEXOS model

        for (file_name, gen_ids) in gens_by_file_sorted
            startswith(file_name, "MaxEnergyYear") || continue # Skip file with energy constraints and only process inflow files

            gen_entries = hydro_groups[file_name]
            gen_entries[!, :constraint] = [ParseISP.HYDRO2CNS[row.id_gen] for row in eachrow(gen_entries)] # Map generator to its energy constraint

            filepath    = normpath(hydro_root, file_name * "_" * hydro_sce * ".csv") # Path to energy constraint file
            inflow_data = CSV.read(filepath, DataFrame) # Read energy constraint data

            for constraint in unique(values(ParseISP.HYDRO2CNS))                        # Loop over unique constraints (many generators may be associated to one constraint)
                cns_gens = filter(row -> row.constraint == constraint, gen_entries) # Get generators under this constraint

                total_cns_cap          = sum(cns_gens.gen_totcap)               # Total capacity of generators under this constraint
                cns_gens[!, :partial] .= cns_gens.gen_totcap ./ total_cns_cap   # Proportion of each generator's capacity to total constraint capacity

                df_energy                  = select(inflow_data, [:Year, Symbol(constraint)])  # Extract energy constraint data for this constraint
                df_energy[!, :HourlyLimit] = df_energy[!, Symbol(constraint)] ./ (8760.0/1000) # Convert annual energy (GWh) to `hourly power inflow` (MW)
                df_energy[!, :date]        = [DateTime(row.Year, 7, 1, 0, 0, 0) for row in eachrow(df_energy)] 

                df_energy_hourly = expand_yearly_to_hourly(df_energy) # Expand yearly limits to hourly limits

                for row in eachrow(cns_gens)
                    # Pro-rate energy limits among generators based on their capacity share
                    scaled_limits = df_energy_hourly.HourlyLimit .* row.partial ./ row.n
                    append!(gen_inflow_dummy, DataFrame(
                        id       = collect(1:nrow(df_energy_hourly)),
                        id_gen   = fill(row.id_gen, nrow(df_energy_hourly)),
                        scenario = fill(sce_label, nrow(df_energy_hourly)),
                        date     = df_energy_hourly.date,
                        value    = scaled_limits,
                    ))
                end
            end
        end
    end

    # 3 - Snowy Scheme Inflows
    for scenario in keys(scenario_definitions)
        sce_label     = scenario_definitions[scenario]      # Scenario number
        for (file_name, gen_ids) in gens_by_file_sorted
            startswith(file_name, "SNOWY_SCHEME") || continue   # Skip file with energy constraints and only process inflow files
            # Work on a copy to avoid mutating the original hydro_groups lookup
            gen_entries = deepcopy(hydro_groups[file_name])

            # For each Snowy group keep only the generator with the largest capacity (avoid double counting)
            for group in values(ParseISP.SNOWY_HYDRO_GROUPS)
                present = filter(row -> row.id_gen in group, gen_entries)
                if nrow(present) > 1
                    # find index of the generator with the largest capacity and keep it
                    _, rel_idx = findmax(present.gen_totcap)
                    to_keep = present[rel_idx, :id_gen]
                    to_remove = setdiff(group, [to_keep])
                    if !isempty(to_remove)
                        gen_entries = filter(row -> !(row.id_gen in to_remove), gen_entries)
                    end
                end
            end

            # Recalculate totals and partial shares
            total_cap = sum(gen_entries.gen_totcap)
            gen_entries[!, :partial] .= gen_entries.gen_totcap ./ total_cap

            # Precompute hourly vectors once for this Snowy dataset
            n_hourly = nrow(hourly_snowy)
            hourly_ids = collect(1:n_hourly)
            hourly_dates = hourly_snowy.date
            hourly_values = hourly_snowy.value

            gen_n_lookup = Dict(row.id_gen => row.n for row in eachrow(hydro_gen))

            for group in values(ParseISP.SNOWY_HYDRO_GROUPS)
                # Generators associated to the Snowy group
                group_entries = filter(row -> row.id_gen in group, gen_entries)
                share_group   = sum(group_entries.partial) # Generation share of the group (%)

                for id_gen in group # Generators forming the Snowy group
                    hydro_dam = ParseISP.HYDRO_DAMS_GENS[id_gen]
                    share_dam = get(ParseISP.DAM_SHARES, hydro_dam, 0.0)
                    share_gen = share_group * share_dam
                    # println("Scenario: ", sce_label, " Gen: ", id_gen, " Share gen: ", share_gen)
                    n_units = get(gen_n_lookup, id_gen, 1)
                    scaled_inflows = hourly_values .* share_gen * 1000.0 ./ n_units

                    append!(gen_inflow_dummy, DataFrame(
                        id       = hourly_ids,
                        id_gen   = fill(id_gen, n_hourly),
                        scenario = fill(sce_label, n_hourly),
                        date     = hourly_dates,
                        value    = scaled_inflows,
                    ))
                end
            end
            df_snowy_capacity = gen_entries
        end
    end

    # Final order of the inflow dataframe
    for row in eachrow(tc.problem)
        sce    = row.scenario
        dstart = row.dstart
        dend   = row.dend

        df_filt = filter(r -> r.scenario == sce && r.date >= dstart && r.date <= dend, gen_inflow_dummy)
        append!(tv.gen_inflow, df_filt)
    end
    sort!(tv.gen_inflow, [:id_gen, :scenario, :date])
    tv.gen_inflow[!, :id] = collect(1:nrow(tv.gen_inflow))

    return df_snowy_capacity
end

"""
    ess_inflow_sched(ts, tv, tc, inputs_workbook, df_snowy_capacity)

Extend the hydro inflow logic to storage assets by mapping reservoir inflows to
ESS units, using the Snowy capacity outputs from `gen_inflow_sched` to cap
charge/discharge schedules.

# Arguments
- `ts::ParseISPtimeStatic`, `tv::ParseISPtimeVarying`, `tc::ParseISPtimeConfig`: Core ISP
  containers mutated/read as part of schedule construction.
- `inputs_workbook::String`: Source workbook for inflow assumptions.
- `df_snowy_capacity::DataFrame`: Snowy-specific inflow data for ESS linkage.
"""
function ess_inflow_sched(ts::ParseISPtimeStatic, tv::ParseISPtimeVarying, tc::ParseISPtimeConfig, inputs_workbook::String, df_snowy_capacity::DataFrame; release::ParseISP.ISPRelease = ParseISP.ISP2024())
    if release isa ParseISP.ISP2026
        return tv
    end

    ess       = ts.ess
    gen       = ts.gen
    tumut_ps  = filter(row -> row.name == "Tumut 3", ess)
    id_tumut  = tumut_ps.id_ess[1]
    hourly_snowy = build_hourly_snowy(inputs_workbook); # Generate hourly values for the Snowy scheme (Tumut, Murray, etc) using the inflows from the IASR
    ess_inflow_dummy = deepcopy(tv.ess_inflow)

    # Calculate dam share
    t3_dams  = ParseISP.HYDRO_DAMS_STORAGE[id_tumut]
    t3_share = 0.0
    for dam in t3_dams
        t3_share += get(ParseISP.DAM_SHARES, dam, 0.0)
    end

    # Calculate generator share
    tumut_gen = ParseISP.HYDRO_STORAGE_GEN[id_tumut]
    tumut_entry = filter(row -> row.id_gen == tumut_gen, df_snowy_capacity)
    tumut_partial = tumut_entry.partial

    t3_total_share = t3_share * tumut_partial[1]
    tumut_gen_n    = gen[gen.id_gen .== tumut_gen, :n][1]

    hourly_values = hourly_snowy.value
    n_hourly      = nrow(hourly_snowy)
    hourly_ids    = collect(1:n_hourly)
    scenario_definitions = ParseISP.scenario_definitions(release)
    for scenario in keys(scenario_definitions)
        sce_label      = scenario_definitions[scenario]      # Scenario number
        scaled_inflows = hourly_values .* t3_total_share * 1000.0 ./ tumut_gen_n
        append!(ess_inflow_dummy, DataFrame(
            id       = hourly_ids,
            id_ess   = fill(id_tumut, n_hourly),
            scenario = fill(sce_label, n_hourly),
            date     = hourly_snowy.date,
            value    = scaled_inflows,
        ))
    end

    # Final order of the inflow dataframe
    for row in eachrow(tc.problem)
        sce    = row.scenario
        dstart = row.dstart
        dend   = row.dend

        df_filt = filter(r -> r.scenario == sce && r.date >= dstart && r.date <= dend, ess_inflow_dummy)
        # println(df_filt)
        append!(tv.ess_inflow, df_filt)
    end
    sort!(tv.ess_inflow, [:id_ess, :scenario, :date])
    tv.ess_inflow[!, :id] = collect(1:nrow(tv.ess_inflow))
end

"""
    ev_der_tables(ts)

Create one EV DER entry for each bus in `ts.bus` and append it to `ts.der`.
Each EV DER is linked to the demand entry on the same bus and uses the
standard EV reduction cost expected by the downstream scheduling pipeline.

# Arguments
- `ts`: Time-static container with populated `bus`, `dem`, and `der` tables.

# Returns
- The mutated `ts.der` table.
"""
function ev_der_tables(ts)
    demand_by_bus = Dict(row.id_bus => (row.id_dem, row.name) for row in eachrow(ts.dem))
    missing_demand_bus_ids = unique(filter(id_bus -> !haskey(demand_by_bus, id_bus), ts.bus.id_bus))

    isempty(missing_demand_bus_ids) || error(
        "Could not create EV DER rows because these bus ids have no matching demand rows: $(join(string.(missing_demand_bus_ids), ", ")).",
    )

    next_der_id = isempty(ts.der) ? 1 : maximum(ts.der.id_der) + 1

    for id_bus in ts.bus.id_bus
        demand_id, demand_name = demand_by_bus[id_bus]
        der_name = "$(demand_name)_EV"

        push!(ts.der, [
            next_der_id, # ID_DER
            der_name,    # NAME
            "EV",        # TECH
            demand_id,   # ID_DEMAND
            1,           # ACTIVE
            0,           # INVESTMENT
            0,           # CAPACITY
            1,           # REDUCT
            0,           # PRED_MAX
            41480.0,     # COST_RED
            1,           # N
        ])

        next_der_id += 1
    end

    return ts.der
end

"""
    ev_der_sched(tc, ts, tv, iasr2024_path, evworkbook_path; release = ISP2024())

Build EV DER schedules from the 2023 IASR EV workbook and the 2024 ISP
subregional allocation workbook, ensure matching EV DER entries exist in
`ts.der`, and append the resulting schedule rows to `tv.der_pred`.

# Arguments
- `tc`: Time-configuration container with the populated `problem` table.
- `ts`: Time-static container with populated `bus`, `dem`, and `der` tables.
- `tv`: Time-varying container whose `der_pred` table is mutated in place.
- `iasr2024_path::AbstractString`: Path to the 2024 ISP inputs and assumptions workbook.
- `evworkbook_path::AbstractString`: Path to the 2023 IASR EV workbook.

# Returns
- `DataFrame`: The EV DER schedule rows appended to `tv.der_pred`.
"""
function ev_der_sched(tc, ts, tv, iasr2024_path::AbstractString, evworkbook_path::AbstractString; release::ParseISP.ISPRelease = ParseISP.ISP2024())
    if release isa ParseISP.ISP2026
        return DataFrame(id = Int[], id_der = Int[], scenario = Int[], date = DateTime[], value = Float64[])
    end

    bev_phev_profile_weekend_df = ev_build_bev_phev_profile_dataframe(
        evworkbook_path,
        EV_2024_BEV_PHEV_PROFILE_WEEKEND_SHEET;
        day_type = "Weekend",
    )
    bev_phev_profile_weekday_df = ev_build_bev_phev_profile_dataframe(
        evworkbook_path,
        EV_2024_BEV_PHEV_PROFILE_WEEKDAY_SHEET;
        day_type = "Weekday",
    )
    profiles = vcat(bev_phev_profile_weekend_df, bev_phev_profile_weekday_df)

    vehicle_numbers_wide_dfs = OrderedDict(
        sheet_name => ev_build_vehicle_numbers_dataframe(evworkbook_path, sheet_name)
        for sheet_name in ev_get_vehicle_numbers_sheet_names(evworkbook_path)
    )
    vehicle_numbers_dfs = OrderedDict(
        sheet_name => ev_melt_vehicle_numbers_dataframe(vehicle_numbers_wide_dfs[sheet_name], number_column)
        for (sheet_name, number_column) in EV_2024_VEHICLE_NUMBER_VALUE_COLUMN_BY_SHEET
    )

    bev_numbers_df = vehicle_numbers_dfs["BEV_Numbers"]
    phev_numbers_df = vehicle_numbers_dfs["PHEV_Numbers"]
    ev_numbers_join_keys = [:scenario, :state, :vehicle_type, :category, :year]
    ev_numbers = reduce(
        (left_df, right_df) -> outerjoin(left_df, right_df; on = ev_numbers_join_keys),
        [bev_numbers_df, phev_numbers_df],
    )

    bev_phev_charge_type_df = ev_build_bev_phev_charge_type_dataframe(
        evworkbook_path,
        EV_2024_BEV_PHEV_CHARGE_TYPE_SHEET,
    )
    subregional_demand_allocation_df = ev_melt_subregional_demand_allocation_dataframe(
        ev_build_subregional_demand_allocation_dataframe(iasr2024_path),
    )
    ev_assign_subregional_bus_ids!(subregional_demand_allocation_df, ts)

    ev_data_years = Set(ev_collect_data_dates(tc.problem))
    scenario_ids = sort(collect(unique(tc.problem.scenario)))

    shares = filter(row -> row.year in ev_data_years && row.scenario in scenario_ids, bev_phev_charge_type_df)
    numbers = filter(row -> row.year in ev_data_years && row.scenario in scenario_ids, ev_numbers)
    subregional = filter(row -> row.year in ev_data_years && row.scenario in scenario_ids, subregional_demand_allocation_df)

    _profiles = leftjoin(profiles, numbers, on = ["state", "vehicle_type"])
    _profiles.category = [ev_map_vehicle_type_to_category(string(vehicle_type)) for vehicle_type in _profiles.vehicle_type]
    _profiles = leftjoin(
        _profiles,
        shares[:, [:state, :category, :charging, :share, :scenario, :year]],
        on = [:state, :category, :charging_profile => :charging, :scenario, :year],
    )

    all_times = collect(minimum(tc.problem.dstart):Hour(1):maximum(tc.problem.dend))
    stacked_chunks = DataFrame[]

    for sc in scenario_ids
        for date_fy in sort(collect(ev_data_years))
            filtered_profiles = filter(row -> row.year == date_fy && row.scenario == sc, _profiles)
            filtered_subregional = filter(row -> row.year == date_fy && row.scenario == sc, subregional)

            if isempty(filtered_profiles) || isempty(filtered_subregional)
                continue
            end

            filtered_profiles = copy(filtered_profiles)
            filtered_profiles.total_number =
                coalesce.(filtered_profiles.number_bev, 0) .+ coalesce.(filtered_profiles.number_phev, 0)
            filtered_profiles.total_number_share =
                filtered_profiles.total_number .* coalesce.(filtered_profiles.share, 0.0)

            profile_start_index = findfirst(==("00_00"), names(filtered_profiles))
            profile_end_index = findfirst(==("23_30"), names(filtered_profiles))

            if !isnothing(profile_start_index) && !isnothing(profile_end_index) && profile_start_index <= profile_end_index
                leading_columns = names(filtered_profiles)[1:(profile_start_index - 1)]
                profile_columns = names(filtered_profiles)[profile_start_index:profile_end_index]
                trailing_columns = names(filtered_profiles)[(profile_end_index + 1):end]
                select!(filtered_profiles, vcat(leading_columns, trailing_columns, profile_columns))
            end

            profile_column_names = ev_get_profile_column_names(filtered_profiles)
            isempty(profile_column_names) && continue

            idxs_weekday = findall(filtered_profiles.day_type .== "Weekday")
            idxs_weekend = findall(filtered_profiles.day_type .== "Weekend")
            total_profiles_weekday = filtered_profiles[idxs_weekday, profile_column_names] .* filtered_profiles.total_number_share[idxs_weekday]
            total_profiles_weekday.state = filtered_profiles.state[idxs_weekday]
            total_profiles_weekend = filtered_profiles[idxs_weekend, profile_column_names] .* filtered_profiles.total_number_share[idxs_weekend]
            total_profiles_weekend.state = filtered_profiles.state[idxs_weekend]

            for col in profile_column_names
                if col[end-1:end] == "00"
                    total_profiles_weekday[!, col] =
                        (total_profiles_weekday[!, col] .+ total_profiles_weekday[!, string(col[1:end-2], "30")]) ./ 2
                    total_profiles_weekend[!, col] =
                        (total_profiles_weekend[!, col] .+ total_profiles_weekend[!, string(col[1:end-2], "30")]) ./ 2
                end
            end

            total_profiles_weekday = total_profiles_weekday[:, Not(profile_column_names[2:2:end])]
            total_profiles_weekend = total_profiles_weekend[:, Not(profile_column_names[2:2:end])]

            fy_times = [t for t in all_times if ev_format_profile_year(t) == date_fy]
            isempty(fy_times) && continue

            weekday_mask = dayofweek.(fy_times) .<= 5
            final_profiles = DataFrame(date = fy_times)

            for region in sort(unique(filtered_subregional.id_bus))
                final_profiles[!, string(region)] = zeros(length(fy_times))
            end

            for state in unique(filtered_profiles.state)
                weekday_profile =
                    sum(Matrix(total_profiles_weekday[total_profiles_weekday.state .== state, Not(:state)]), dims = 1)[:] ./ 1e3
                weekend_profile =
                    sum(Matrix(total_profiles_weekend[total_profiles_weekend.state .== state, Not(:state)]), dims = 1)[:] ./ 1e3

                state_subregional = filtered_subregional[filtered_subregional.state .== state, :]
                isempty(state_subregional) && continue
                sort!(state_subregional, :id_bus)

                state_bus_columns = string.(state_subregional.id_bus)
                state_shares = state_subregional.share

                for (i, t) in pairs(fy_times)
                    if weekday_mask[i]
                        final_profiles[i, state_bus_columns] .= weekday_profile[hour(t) + 1] .* state_shares
                    else
                        final_profiles[i, state_bus_columns] .= weekend_profile[hour(t) + 1] .* state_shares
                    end
                end
            end

            stacked_profiles = stack(final_profiles, Not(:date), variable_name = :id_bus, value_name = :value)
            stacked_profiles.id_bus = parse.(Int64, stacked_profiles.id_bus)
            stacked_profiles.scenario .= sc
            stacked_profiles.value .= round.(stacked_profiles.value, digits = 3)
            push!(stacked_chunks, stacked_profiles[:, [:id_bus, :scenario, :date, :value]])
        end
    end

    if isempty(stacked_chunks)
        return DataFrame(id = Int[], id_der = Int[], scenario = Int[], date = DateTime[], value = Float64[])
    end

    all_stacked = reduce(vcat, stacked_chunks)
    # ev_der_tables!(ts)
    der_id_by_bus = ev_der_id_by_bus(ts)

    missing_ev_profile_bus_ids = unique(filter(id_bus -> !haskey(der_id_by_bus, id_bus), all_stacked.id_bus))
    isempty(missing_ev_profile_bus_ids) || error(
        "Missing `id_der` mapping for EV profile bus ids: $(join(string.(missing_ev_profile_bus_ids), ", ")).",
    )

    all_stacked.id_der = [der_id_by_bus[id_bus] for id_bus in all_stacked.id_bus]
    all_stacked.id = zeros(Int, nrow(all_stacked))
    select!(all_stacked, [:id, :id_der, :scenario, :date, :value])
    sort!(all_stacked, [:id_der, :scenario, :date])

    first_pred_id = isempty(tv.der_pred) ? 1 : maximum(tv.der_pred.id) + 1
    all_stacked.id = first_pred_id:(first_pred_id + nrow(all_stacked) - 1)
    append!(tv.der_pred, all_stacked)

    return all_stacked
end
