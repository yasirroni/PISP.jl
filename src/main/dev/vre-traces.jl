using PISP
using DataFrames, CSV, Tables, Dates

# ── parameters ───────────────────────────────────────────────────────────────
downloadpath       = normpath("/Volumes/Seagate/CSIRO AR-PST Stage 5/PISP-downloads")
download_from_AEMO = false
poe                = 10
reftrace           = 4006
# years            = [2025, 2030, 2035, 2040]   # full run
year               = 2025                        # fixed for deep testing
output_root        = normpath("/Volumes/Seagate/CSIRO AR-PST Stage 5/PISP-outputs")
write_csv          = true
write_arrow        = false
scenarios          = [1, 2, 3]
output_name        = "out"

data_paths = PISP.default_data_paths(filepath=downloadpath)

PISP.build_pipeline(data_root=downloadpath, poe=poe, download_files=download_from_AEMO, overwrite_extracts=false)

base_name = "$(output_name)-ref$(reftrace)-poe$(poe)"

# for year in years   # commented out — single year above

    tc, ts, tv = PISP.initialise_time_structures()

    PISP.fill_problem_table_year(tc, year; sce=scenarios)

    @info "Populating time-static data - year $(year) ..."
    static_params = PISP.populate_time_static!(ts, tv, data_paths; refyear=reftrace, poe=poe)

    txdata           = static_params.txdata
    generator_tables = static_params.generator_tables

    @info "Populating time-varying data - year $(year) ..."
    PISP.line_sched_table(tc, tv, txdata)
    PISP.gen_n_sched_table(tv, generator_tables.SYNC4, generator_tables.GENERATORS)
    PISP.gen_retirements(ts, tv)
    PISP.dem_load_sched(tc, tv, data_paths.profiledata; refyear=reftrace, poe=poe)
    PISP.gen_pmax_distpv(tc, ts, tv, data_paths.profiledata; refyear=reftrace, poe=poe, skip_traces=false)

    # ── gen_pmax_solar (inlined from src/parsers/PISP-2024parser.jl:1173) ────
    @info "gen_pmax_solar ..."
    let ispdata24    = data_paths.ispdata24,
        outlookdata  = data_paths.outlookdata,
        outlookAEMO  = data_paths.outlookAEMO,
        profilespath = data_paths.profiledata,
        refyear      = reftrace,
        skip_traces  = false

        probs  = tc.problem
        bust   = ts.bus

        gid    = isempty(ts.gen.id_gen)    ? 0 : maximum(ts.gen.id_gen)
        pmaxid = isempty(tv.gen_pmax.id)   ? 0 : maximum(tv.gen_pmax.id)

        tch        = "Solar"
        EXIST_TECH  = PISP.read_xlsx_with_header(ispdata24, "Existing Gen Data Summary", "B11:K297")
        EXIST_SOLAR = EXIST_TECH[occursin.(tch[2:end], coalesce.(EXIST_TECH[!,2],"")),:]
        REZ_BUS     = PISP.read_xlsx_with_header(ispdata24, "Renewable Energy Zones", "B7:G50")

        genid = Dict()
        for st in setdiff(keys(PISP.NEMBUSNAME), ["GG", "SNW"])
            gid += 1
            bus_data = bust[bust[!,:name] .== st, :]
            bus_id   = bus_data[!, :id_bus][1]
            bus_lat  = bus_data[!, :latitude][1]
            bus_lon  = bus_data[!, :longitude][1]
            capaux   = st == "TAS" ? 0.0 : sum(EXIST_SOLAR[EXIST_SOLAR[!,4] .== st, 7])
            genid[st] = [gid, capaux]
            arrgen = [gid, "LSPV_$(st)", "LSPV_$(st)", "Solar", "LargePV", "LargePV",
                      capaux, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, bus_id, 0.0, capaux, 9999.9,
                      9999.9, 0, 1, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0,
                      0, 0, 0, 0, 1.0, bus_lat, bus_lon, 1, 0, 0.0, 0.0, 0.0, 0.0, 0.0,
                      0.0, 0.0, 0.0, 0.0]
            push!(ts.gen, arrgen)
        end

        if !skip_traces
            name_ex   = Dict()
            foldertech = string(profilespath, "solar_$(refyear)/")
            scid2cdp  = Dict(1 => "CDP14", 2 => "CDP14", 3 => "CDP14", 4 => "CDP14")
            auxf = []
            auxk = []

            for p in 1:nrow(probs)
                scid   = probs[p, :scenario][1]
                sc     = PISP.ID2SCE[scid]
                dstart = probs[p, :dstart]
                dend   = probs[p, :dend]
                yr     = Dates.year(dstart)
                ms     = Dates.month(dstart)
                outlookfile = normpath(outlookdata, "..", "Auxiliary", "2024 ISP - $(sc) - Core_REZCAP.xlsx")

                TECH_CAP  = PISP.read_xlsx_with_header(outlookAEMO, "CapacityOutlook", "A1:G14356")
                SOLAR_CAP = PISP.read_xlsx_with_header(outlookfile, "REZ Generation Capacity", "A1:AG2238")
                SOLAR_CAP = dropmissing(SOLAR_CAP, :CDP)

                y = ms < 7 ? yr - 1 : yr

                for st in setdiff(keys(PISP.NEMBUSNAME), ["GG", "SNW"])
                    REZs    = REZ_BUS[(REZ_BUS[!, Symbol("ISP Sub-region")] .== st), :ID]
                    REZSUM  = REZ_BUS[(REZ_BUS[!, Symbol("ISP Sub-region")] .== st),
                                      [:ID, :Name, Symbol("ISP Sub-region")]]
                    SOLARAUX = SOLAR_CAP[
                        in.(SOLAR_CAP[!, :REZ], [REZs]) .&
                        (SOLAR_CAP[!, :CDP] .== scid2cdp[scid]) .&
                        (SOLAR_CAP[!, :Technology] .== tch),
                        [:REZ, Symbol("$(y)-$(string(y+1)[3:end])")]]
                    rename!(SOLARAUX, Dict(:REZ => :ID))
                    SOLARAUX = innerjoin(SOLARAUX, REZSUM, on=:ID)
                    SOLARAUX[!, :EXISTING] = [0.0 for _ in 1:nrow(SOLARAUX)]

                    dataexi = zeros(Int64(Dates.Hour(dend - dstart) / Dates.Hour(1) + 1) * 2)
                    exi_cap = 0.0
                    df2 = DataFrame()
                    for r in 1:nrow(EXIST_SOLAR)
                        k   = EXIST_SOLAR[r, 1]
                        reg = EXIST_SOLAR[r, 5]
                        if EXIST_SOLAR[r, 4] == st
                            for sexp in 1:nrow(SOLARAUX)
                                if SOLARAUX[sexp, :Name] == reg
                                    SOLARAUX[sexp, :EXISTING] += EXIST_SOLAR[r, 10]
                                end
                            end
                            file = ""
                            if k in keys(name_ex)
                                file = name_ex[k]
                            else
                                for f in filter(f -> !startswith(f, "._"), readdir(foldertech))
                                    if f[1:3] != "REZ" && occursin(split(k, " ")[1], f)
                                        push!(auxf, f)
                                        push!(auxk, k)
                                        file = f
                                        break
                                    end
                                end
                            end
                            df      = CSV.File(string(foldertech, file)) |> DataFrame
                            df2     = PISP.select_trace_date_window(df, dstart, dend)
                            dataexi = dataexi .+ vec(permutedims(Tables.matrix(df2[:, 4:end]))) * EXIST_SOLAR[r, 10]
                            exi_cap += EXIST_SOLAR[r, 10]
                        end
                    end
                    SOLARAUX[!, :DIFF] = SOLARAUX[!, 2] .- SOLARAUX[!, :EXISTING]

                    naux    = 0
                    datanew = zeros(Int64(Dates.Hour(dend - dstart) / Dates.Hour(1) + 1) * 2)
                    datarez = zeros(Int64(Dates.Hour(dend - dstart) / Dates.Hour(1) + 1) * 2)
                    drezcap = 0
                    tch_    = "Utility solar"

                    if dstart > DateTime(2024, 7, 1, 0, 0, 0)
                        instcap = TECH_CAP[
                            (TECH_CAP[!, :Scenario]   .== sc)  .&
                            (TECH_CAP[!, :Subregion]  .== st)  .&
                            (TECH_CAP[!, :Technology] .== tch_) .&
                            (Dates.year.(TECH_CAP[!, :date]) .== y), 7][1]
                        for f in filter(f -> !startswith(f, "._"), readdir(foldertech))
                            sub = split(f, ['_', '.'])
                            if "REZ" in sub && "SAT" in sub && sub[2] in REZs
                                df      = CSV.File(string(foldertech, f)) |> DataFrame
                                df2     = PISP.select_trace_date_window(df, dstart, dend)
                                datanew = datanew .+ vec(permutedims(Tables.matrix(df2[:, 4:end])))
                                naux   += 1
                                if nrow(SOLARAUX) > 0
                                    for r in 1:nrow(SOLARAUX)
                                        if SOLARAUX[r, :ID] == sub[2] && SOLARAUX[r, :DIFF] >= 0.01
                                            datarez = datarez .+ vec(permutedims(Tables.matrix(df2[:, 4:end]))) * SOLARAUX[r, :DIFF]
                                            drezcap += SOLARAUX[r, :DIFF]
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
                        data  = (dataexi .+ datarez) .+ dataN
                    elseif instcap - exi_cap < drezcap
                        dataN = datanew / naux * abs(instcap - exi_cap)
                        data  = dataexi .+ dataN
                        if ((instcap - exi_cap) < 0) && (abs(instcap - exi_cap) > 100) end
                    else
                        dataN = naux == 0 ? datanew : datanew / naux * 0.0
                        data  = (dataexi .+ datarez) .+ dataN
                    end

                    data2 = [(data[2*i-1] + data[2*i]) / 2 for i in 1:Int64(length(data) / 2)]
                    for h in 1:Int64(Dates.Hour(dend - dstart) / Dates.Hour(1) + 1)
                        pmaxid += 1
                        push!(tv.gen_pmax, [pmaxid, genid[st][1], scid, dstart + Dates.Hour(h-1), data2[h]])
                    end
                end
            end
        end
    end
    # ── end gen_pmax_solar ────────────────────────────────────────────────────

    # ── gen_pmax_wind (inlined from src/parsers/PISP-2024parser.jl:1349) ─────
    @info "gen_pmax_wind ..."
    let ispdata24    = data_paths.ispdata24,
        outlookdata  = data_paths.outlookdata,
        outlookAEMO  = data_paths.outlookAEMO,
        profilespath = data_paths.profiledata,
        refyear      = reftrace,
        skip_traces  = false

        probs  = tc.problem
        bust   = ts.bus

        gid    = isempty(ts.gen.id_gen)    ? 0 : maximum(ts.gen.id_gen)
        pmaxid = isempty(tv.gen_pmax.id)   ? 0 : maximum(tv.gen_pmax.id)

        tch       = "Wind"
        EXIST_TECH = PISP.read_xlsx_with_header(ispdata24, "Existing Gen Data Summary", "B11:K297")
        EXIST_WIND = EXIST_TECH[occursin.(tch[2:end], coalesce.(EXIST_TECH[!, 2], "")), :]
        REZ_BUS    = PISP.read_xlsx_with_header(ispdata24, "Renewable Energy Zones", "B7:G50")

        genid = Dict()
        for st in setdiff(keys(PISP.NEMBUSNAME), ["GG"])
            gid += 1
            bus_data = bust[bust[!, :name] .== st, :]
            bus_id   = bus_data[!, :id_bus][1]
            bus_lat  = bus_data[!, :latitude][1]
            bus_lon  = bus_data[!, :longitude][1]
            if st == "SNW"
                capaux    = 0.0
                genid[st] = [gid, capaux]
                arrgen    = [gid, "WIND_$(st)", "WIND_$(st)", "Wind", "Wind", "Wind",
                             capaux, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, bus_id, 0.0, capaux,
                             9999.9, 9999.9, 0, 1, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0,
                             0.0, 0.0, 0.0, 0, 0, 0, 0, 1.0, bus_lat, bus_lon, 1, 0,
                             0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
            else
                capaux    = sum(EXIST_WIND[EXIST_WIND[!, 4] .== st, 7])
                genid[st] = [gid, capaux]
                arrgen    = [gid, "WIND_$(st)", "WIND_$(st)", "Wind", "Wind", "Wind",
                             capaux, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, bus_id, 0.0, capaux,
                             9999.9, 9999.9, 0, 1, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0,
                             0.0, 0.0, 0.0, 0, 0, 0, 0, 1.0, bus_lat, bus_lon, 1, 0,
                             0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
            end
            push!(ts.gen, arrgen)
        end

        if !skip_traces
            foldertech = string(profilespath, "wind_$(refyear)/")
            scid2cdp   = Dict(1 => "CDP14", 2 => "CDP14", 3 => "CDP14", 4 => "CDP14")
            auxf = []
            auxk = []

            for p in 1:nrow(probs)
                scid   = probs[p, :scenario][1]
                sc     = PISP.ID2SCE[scid]
                dstart = probs[p, :dstart]
                dend   = probs[p, :dend]
                yr     = Dates.year(dstart)
                ms     = Dates.month(dstart)
                outlookfile = normpath(outlookdata, "..", "Auxiliary", "2024 ISP - $(sc) - Core_REZCAP.xlsx")

                TECH_CAP = PISP.read_xlsx_with_header(outlookAEMO, "CapacityOutlook", "A1:G14356")
                WIND_CAP = PISP.read_xlsx_with_header(outlookfile, "REZ Generation Capacity", "A1:AG2238")
                WIND_CAP = dropmissing(WIND_CAP, :CDP)

                y = ms < 7 ? yr - 1 : yr

                for st in setdiff(keys(PISP.NEMBUSNAME), ["GG"])
                    REZs   = REZ_BUS[(REZ_BUS[!, Symbol("ISP Sub-region")] .== st), :ID]
                    REZSUM = REZ_BUS[(REZ_BUS[!, Symbol("ISP Sub-region")] .== st),
                                     [:ID, :Name, Symbol("ISP Sub-region")]]
                    WINDAUX = WIND_CAP[
                        in.(WIND_CAP[!, :REZ], [REZs]) .&
                        (WIND_CAP[!, :CDP] .== scid2cdp[scid]) .&
                        (WIND_CAP[!, :Technology] .== tch),
                        [:REZ, Symbol("$(y)-$(string(y+1)[3:end])")]]
                    rename!(WINDAUX, Dict(:REZ => :ID))
                    WINDAUX = innerjoin(WINDAUX, REZSUM, on=:ID)
                    WINDAUX[!, :EXISTING] = [0.0 for _ in 1:nrow(WINDAUX)]

                    dataexi = zeros(Int64(Dates.Hour(dend - dstart) / Dates.Hour(1) + 1) * 2)
                    exi_cap = 0.0
                    df2 = DataFrame()
                    for r in 1:nrow(EXIST_WIND)
                        k   = EXIST_WIND[r, 1]
                        reg = EXIST_WIND[r, 5]
                        if EXIST_WIND[r, 4] == st
                            for sexp in 1:nrow(WINDAUX)
                                if WINDAUX[sexp, :Name] == reg
                                    WINDAUX[sexp, :EXISTING] += EXIST_WIND[r, 7]
                                end
                            end
                            file = ""
                            name_ex_weather_year = PISP.get_name_ex(refyear)
                            if k in keys(name_ex_weather_year)
                                file = name_ex_weather_year[k]
                            else
                                for f in filter(f -> !startswith(f, "._"), readdir(foldertech))
                                    if f[1:3] != "REZ" && occursin(split(k, " ")[1], f)
                                        push!(auxf, f)
                                        push!(auxk, k)
                                        file = f
                                        break
                                    end
                                end
                            end
                            df      = CSV.File(string(foldertech, file)) |> DataFrame
                            df2     = PISP.select_trace_date_window(df, dstart, dend)
                            dataexi = dataexi .+ vec(permutedims(Tables.matrix(df2[:, 4:end]))) * EXIST_WIND[r, 7]
                            exi_cap += EXIST_WIND[r, 7]
                        end
                    end
                    WINDAUX[!, :DIFF] = WINDAUX[!, 2] .- WINDAUX[!, :EXISTING]

                    naux    = 0
                    datanew = zeros(Int64(Dates.Hour(dend - dstart) / Dates.Hour(1) + 1) * 2)
                    datarez = zeros(Int64(Dates.Hour(dend - dstart) / Dates.Hour(1) + 1) * 2)
                    drezcap = 0
                    tch_    = "Wind"

                    if dstart > DateTime(2024, 7, 1, 0, 0, 0)
                        instcap = TECH_CAP[
                            (TECH_CAP[!, :Scenario]   .== sc)  .&
                            (TECH_CAP[!, :Subregion]  .== st)  .&
                            (TECH_CAP[!, :Technology] .== tch_) .&
                            (Dates.year.(TECH_CAP[!, :date]) .== y), 7][1]
                        for f in filter(f -> !startswith(f, "._"), readdir(foldertech))
                            sub = split(f, ['_', '.'])
                            if sub[1] in REZs && "WH" in sub
                                df      = CSV.File(string(foldertech, f)) |> DataFrame
                                df2     = PISP.select_trace_date_window(df, dstart, dend)
                                datanew = datanew .+ vec(permutedims(Tables.matrix(df2[:, 4:end])))
                                naux   += 1
                                if nrow(WINDAUX) > 0
                                    for r in 1:nrow(WINDAUX)
                                        if WINDAUX[r, :ID] == sub[1] && WINDAUX[r, :DIFF] >= 0.01
                                            datarez = datarez .+ vec(permutedims(Tables.matrix(df2[:, 4:end]))) * WINDAUX[r, :DIFF]
                                            drezcap += WINDAUX[r, :DIFF]
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
                        data  = (dataexi .+ datarez) .+ dataN
                    elseif instcap - exi_cap < drezcap
                        dataN = datanew / naux * abs(instcap - exi_cap)
                        data  = dataexi .+ dataN
                        if ((instcap - exi_cap) < 0) && (abs(instcap - exi_cap) > 100) end
                    else
                        dataN = naux == 0 ? datanew : datanew / naux * 0.0
                        data  = (dataexi .+ datarez) .+ dataN
                    end

                    data2 = [(data[2*i-1] + data[2*i]) / 2 for i in 1:Int64(length(data) / 2)]
                    for h in 1:Int64(Dates.Hour(dend - dstart) / Dates.Hour(1) + 1)
                        pmaxid += 1
                        push!(tv.gen_pmax, [pmaxid, genid[st][1], scid, dstart + Dates.Hour(h-1), data2[h]])
                    end
                end
            end
        end
    end
    # ── end gen_pmax_wind ─────────────────────────────────────────────────────

    PISP.ess_vpps(tc, ts, tv, data_paths.vpp_cap, data_paths.vpp_ene; skip_traces=false)
    SNOWY_GENS = PISP.gen_inflow_sched(ts, tv, tc, data_paths.ispdata24, data_paths.ispmodel)
    PISP.ess_inflow_sched(ts, tv, tc, data_paths.ispdata24, SNOWY_GENS)
    PISP.der_pred_sched(ts, tv, data_paths.ispdata24)
    PISP.ev_der_sched(tc, ts, tv, data_paths.ispdata24, data_paths.iasr23_ev_workbook)

    PISP.write_time_data(ts, tv;
        csv_static_path    = "$(base_name)/csv",
        csv_varying_path   = "$(base_name)/csv/schedule-$(year)",
        arrow_static_path  = "$(base_name)/arrow",
        arrow_varying_path = "$(base_name)/arrow/schedule-$(year)",
        write_static       = true,
        write_varying      = true,
        output_root        = output_root,
        write_csv          = write_csv,
        write_arrow        = write_arrow,
    )

# end   # for year in years
