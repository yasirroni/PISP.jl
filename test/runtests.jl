using Test
using DataFrames
using Dates
using HTTP
using XLSX
using Tables
using ParseISP

struct ISP2099 <: ParseISP.ISPRelease end

function write_line_invoptions_fixture(path::AbstractString; sheetname::AbstractString = "flow path augmentation options", layout::Symbol = :isp2026, option_name::AbstractString = "Mini Option", buspair::AbstractString = "CQ to NQ")
    if layout == :isp2026
        df = DataFrame(
            Symbol("Bus pair") => [buspair],
            Symbol("Unused 2") => ["x"],
            Symbol("Unused 3") => ["x"],
            Symbol("Option Name") => [option_name],
            Symbol("Unused 5") => ["x"],
            Symbol("Unused 6") => ["x"],
            Symbol("Unused 7") => ["x"],
            Symbol("Forward") => ["1100"],
            Symbol("Reverse") => ["900"],
            Symbol("Cost") => ["12345"],
            Symbol("Unused 11") => ["x"],
            Symbol("Unused 12") => ["x"],
            Symbol("Unused 13") => ["x"],
            Symbol("Lead time") => ["Long"],
        )
    else
        df = DataFrame(
            Symbol("Unused 1") => ["x"],
            Symbol("Unused 2") => ["x"],
            Symbol("Unused 3") => ["x"],
            Symbol("Option Name") => [option_name],
            Symbol("Unused 5") => ["x"],
            Symbol("Bus pair") => ["CQ to NQ"],
            Symbol("Forward") => ["1100"],
            Symbol("Reverse") => ["900"],
            Symbol("Cost") => ["12345"],
            Symbol("Unused 10") => ["x"],
            Symbol("Unused 11") => ["x"],
            Symbol("Unused 12") => ["x"],
            Symbol("Lead time") => ["Long"],
        )
    end

    XLSX.writetable(path, Tables.columntable(df); sheetname = sheetname, anchor_cell = "B11", overwrite = true)
    return path
end

function write_outlook_workbook(path::AbstractString; scenario::AbstractString = "Accelerated Transition")
    df = DataFrame(
        :Scenario => [scenario],
        :Subregion => ["NSW"],
        :Technology => ["Black coal"],
        :CDP => ["CDP14"],
        Symbol("2025-26") => [0],
        Symbol("2026-27") => [1],
    )
    XLSX.writetable(path, Tables.columntable(df); sheetname = "Capacity", anchor_cell = "A3", overwrite = true)
    return path
end

function write_full_outlook_workbook(path::AbstractString)
    sheets = [
        "Capacity" => (["Subregion", "Technology", "CDP", "2025-26", "2026-27"], ["NSW", "Black coal", "CDP14", 0, 1]),
        "Storage Capacity" => (["Subregion", "Technology", "CDP", "2025-26", "2026-27"], ["NSW", "Battery", "CDP14", 10, 20]),
        "Storage Energy" => (["Subregion", "Technology", "CDP", "2025-26", "2026-27"], ["NSW", "Battery", "CDP14", 40, 80]),
        "REZ Generation Capacity" => (["REZ", "Subregion", "Technology", "CDP", "2025-26", "2026-27"], ["N1", "NSW", "Wind", "CDP14", 5, 6]),
    ]
    XLSX.openxlsx(path, mode = "w") do xf
        for (idx, (sheetname, (headers, values))) in enumerate(sheets)
            sheet = idx == 1 ? xf[1] : XLSX.addsheet!(xf, sheetname)
            idx == 1 && XLSX.rename!(sheet, sheetname)
            for (col, header) in enumerate(headers)
                sheet[XLSX.CellRef(3, col)] = header
            end
            for (col, value) in enumerate(values)
                sheet[XLSX.CellRef(4, col)] = value
            end
        end
    end
    return path
end

@testset "release interface" begin
    @test ParseISP.release_year(ParseISP.ISP2024()) == 2024
    @test ParseISP.release_year(ParseISP.ISP2026()) == 2026
    @test ParseISP.release_name(ParseISP.ISP2026()) == "ISP2026"
    @test collect(values(ParseISP.scenario_id_labels(ParseISP.ISP2026()))) == ["Slower Growth", "Step Change", "Accelerated Transition"]
    @test ParseISP.demand_scenario_labels(ParseISP.ISP2026())["Slower Growth"] == "SLOWER_GROWTH"
    @test ParseISP.hydro_scenario_labels(ParseISP.ISP2026())["Accelerated Transition"] == "Flat"
    @test hasmethod(ParseISP.build_datasets, Tuple{ParseISP.ISP2024})
    @test hasmethod(ParseISP.build_datasets, Tuple{ParseISP.ISP2026})

    missing_period_err = try
        ParseISP.build_datasets(ParseISP.ISP2024(); download_from_AEMO = false)
        nothing
    catch caught
        caught
    end
    @test missing_period_err isa ArgumentError
    @test occursin("At least one of `years` or `drange`", sprint(showerror, missing_period_err))

    mktempdir() do dir
        paths = ParseISP.default_data_paths(ParseISP.ISP2026(), dir)
        @test paths.inputs_workbook == normpath(dir, "2026-isp-inputs-and-assumptions-workbook.xlsm")
        @test paths.ev_inputs_workbook == normpath(dir, "aemo-2025-iasr-ev-workbook.xlsx")
        @test paths.outlook_generation_storage_zip == normpath(dir, "2026-isp-generation-and-storage-outlook.zip")
        @test paths.capacity_outlook_workbook == normpath(dir, "Auxiliary", "CapacityOutlook2026_Condensed.xlsx")
        @test paths.storage_capacity_outlook_workbook == normpath(dir, "Auxiliary", "StorageCapacityOutlook_2026_ISP.xlsx")
        @test paths.storage_energy_outlook_workbook == normpath(dir, "Auxiliary", "StorageEnergyOutlook_2026_ISP.xlsx")
        @test isempty(intersect(keys(paths), (:ispdata24, :ispdata26, :ispdata19, :iasr23_ev_workbook, :outlookdata, :outlookAEMO)))

        legacy_paths = ParseISP.legacy_data_paths(ParseISP.ISP2026(), paths)
        @test legacy_paths.ispdata26 == paths.inputs_workbook
        @test legacy_paths.ispdata24 == paths.inputs_workbook
        @test legacy_paths.iasr23_ev_workbook == paths.ev_inputs_workbook

        validation = ParseISP.validate_sources(ParseISP.ISP2026(), paths)
        @test !validation.ok
        @test :ev_inputs_workbook in first.(validation.missing)
    end

    err = try
        ParseISP.source_targets(ISP2099())
        nothing
    catch caught
        caught
    end
    @test err isa ArgumentError
    @test occursin("source_targets", sprint(showerror, err))
end

@testset "release source targets" begin
    @test [target.key for target in ParseISP.source_targets(ParseISP.ISP2024())] ==
        [:isp24_inputs, :iasr23_ev_workbook, :isp19_inputs_v13, :isp24_model, :isp24_outlook]
    @test [target.key for target in ParseISP.source_targets(ParseISP.ISP2026())] ==
        [:isp26_inputs, :isp26_outlook, :isp26_model, :isp26_solar_traces, :isp26_wind_traces]
end

@testset "release layout" begin
    srcroot = dirname(pathof(ParseISP))
    @test !isdir(joinpath(srcroot, "parameters"))
    @test !isdir(joinpath(srcroot, "parsers"))
    @test !isdir(joinpath(srcroot, "scrappers"))
    @test isfile(joinpath(srcroot, "releases", "isp2024", "parameters", "general.jl"))
    @test isfile(joinpath(srcroot, "releases", "isp2024", "parameters", "release_methods.jl"))
    @test isfile(joinpath(srcroot, "releases", "common", "parser_primitives.jl"))
    @test isfile(joinpath(srcroot, "releases", "isp2026", "parameters.jl"))
    @test isfile(joinpath(srcroot, "releases", "isp2026", "parsers", "core.jl"))
    @test isfile(joinpath(srcroot, "releases", "common", "file_downloader.jl"))
end

@testset "extract_all_zips ignores AppleDouble files" begin
    zip_cmd = Sys.which("zip")
    unzip_cmd = Sys.which("unzip")

    if zip_cmd === nothing || unzip_cmd === nothing
        @test_skip "zip/unzip not available in test environment"
    else
        mktempdir() do tmpdir
            src_dir = joinpath(tmpdir, "src")
            dest_dir = joinpath(tmpdir, "dest")
            mkpath(src_dir)

            payload_path = joinpath(src_dir, "payload.txt")
            write(payload_path, "payload")

            cd(src_dir) do
                run(`$(zip_cmd) -q archive.zip payload.txt`)
            end
            write(joinpath(src_dir, "._archive.zip"), "appledouble metadata")

            extracted_paths = ParseISP.ParseISPScrapperUtils.extract_all_zips(src_dir, dest_dir; skip_existing = false)

            @test extracted_paths == [normpath(dest_dir)]
            @test isfile(joinpath(dest_dir, "payload.txt"))
            @test !isfile(joinpath(dest_dir, "._archive.zip"))
        end
    end
end

@testset "ISP2026 acquisition entrypoint" begin
    mktempdir() do dir
        seen_keys = Symbol[]
        fake_download(targets; options) = begin
            append!(seen_keys, [target.key for target in targets])
            [target.subdir === nothing || isempty(target.subdir) ?
                joinpath(options.outdir, target.filename) :
                joinpath(options.outdir, target.subdir, target.filename) for target in targets]
        end

        result = ParseISP.download_isp26_source_files(dir; download_targets_fn = fake_download)

        @test seen_keys == [:isp26_inputs, :isp26_outlook, :isp26_model, :isp26_solar_traces, :isp26_wind_traces]
        @test result.targets.automatic == (:isp26_inputs, :isp26_outlook, :isp26_model, :isp26_solar_traces, :isp26_wind_traces)
        @test result.paths.ispdata26 == joinpath(dir, "2026-isp-inputs-and-assumptions-workbook.xlsm")
        @test result.paths.iasr23_ev_workbook == joinpath(dir, "aemo-2025-iasr-ev-workbook.xlsx")
        @test result.release_paths.inputs_workbook == joinpath(dir, "2026-isp-inputs-and-assumptions-workbook.xlsm")
        @test result.release_paths.ev_inputs_workbook == joinpath(dir, "aemo-2025-iasr-ev-workbook.xlsx")
        @test result.downloaded.ispdata26 == joinpath(dir, "2026-isp-inputs-and-assumptions-workbook.xlsm")
        @test result.downloaded.outlook_generation_storage == joinpath(dir, "2026-isp-generation-and-storage-outlook.zip")
        @test result.downloaded.ispmodel_zip == joinpath(dir, "2026-isp-model.zip")
        @test result.downloaded.solar_traces_zip == joinpath(dir, "zip", "Traces", "2026-isp-solar-traces.zip")
        @test result.downloaded.wind_traces_zip == joinpath(dir, "zip", "Traces", "2026-isp-wind-traces.zip")
        @test any(source -> source.key == :isp26_ev_support && source.status == :required_local, result.metadata)
        @test result.outlook === nothing
    end
end

@testset "AEMO Cloudflare download detection" begin
    response = HTTP.Response(403, ["server" => "cloudflare", "cf-mitigated" => "challenge"], Vector{UInt8}("challenge"))
    @test ParseISP.ParseISPScrapperUtils._looks_like_cloudflare_challenge(response)
    err = ParseISP.ParseISPScrapperUtils.DownloadBlockedError("https://www.aemo.com.au/file.zip", 403, "Cloudflare challenge or access policy")
    @test occursin("interactive browser session", sprint(showerror, err))
end

@testset "ISP2026 readers" begin
    mktempdir() do dir
        workbook = joinpath(dir, "flow.xlsx")
        write_line_invoptions_fixture(workbook)

        raw = ParseISP.read_isp2026_line_invoptions_raw(workbook)
        @test raw[1, 4] == "Mini Option"
        @test nrow(raw) >= 1

        tc, ts, tv = ParseISP.initialise_time_structures()
        ParseISP.bus_table(ts)
        ParseISP.line_invoptions(ts, workbook)
        @test nrow(ts.line) == 1
        @test ts.line[1, :name] == "Mini Option"
        @test ts.line[1, :capacity] == 1100.0
    end

    mktempdir() do dir
        workbook = joinpath(dir, "dr" * "aft-2026-isp-inputs-and-assumptions-workbook.xlsx")
        write_line_invoptions_fixture(workbook)
        @test_throws ArgumentError ParseISP.read_isp2026_line_invoptions_raw(workbook)
    end
end

@testset "ISP2026 validators and fixes" begin
    @test ParseISP.parse_isp2026_number("1,234.5") == 1234.5
    @test ParseISP.parse_isp2026_number("12.5%"; percent_as_fraction = true) == 0.125
    @test ParseISP.parse_isp2026_number("N/A") === nothing
    @test ParseISP.parse_isp2026_date(2) == DateTime(1900, 1, 1)
    @test ParseISP.parse_isp2026_date("2026-07-01") == DateTime(2026, 7, 1)

    dsp = DataFrame(
        "Region" => ["Region", missing, "Winter", "QLD", "Mars", "QLD"],
        "Price band" => ["Price band", missing, missing, "\$300-\$500", "\$300-\$500", "\$300-\$500"],
        "Scenario" => ["Scenario", missing, missing, "Slower Growth", "Slower Growth", "Slower Growth"],
        "Season" => ["Season", missing, missing, "Summer", "Summer", "Summer"],
        "2026-27" => [missing, missing, missing, "1,234.5", -1.0, "not a number"],
    )
    dsp_report = ParseISP.validate_isp2026_dsp_table(dsp)
    @test ParseISP.has_blockers(dsp_report)
    @test any(f -> f.code == :unknown_region_label && f.message == "Unknown DSP region `Mars`.", dsp_report.findings)
    @test any(f -> f.code == :invalid_numeric_value && f.field == "2026-27", dsp_report.findings)
    @test !any(f -> f.message == "Unknown DSP region `missing`.", dsp_report.findings)

    ev_alloc = DataFrame(
        "Region" => ["NSW"],
        "Subregion" => ["BAD"],
        "Scenario" => ["Slower Growth"],
        "2026-27" => [1.0],
    )
    ev_report = ParseISP.validate_isp2026_ev_subregional_allocation(ev_alloc)
    @test ParseISP.has_blockers(ev_report)
    @test any(f -> f.code == :unknown_subregion_label, ev_report.findings)

    natural_hydro = DataFrame("Year" => [2026], "Month" => [7], "Day" => [1], "Inflows" => [-1.0])
    natural_report = ParseISP.validate_isp2026_hydro_trace(natural_hydro, "DailyNaturalInflow_Test_RefYear5000_Flat.csv")
    @test !ParseISP.has_blockers(natural_report)
    @test any(f -> f.severity == :warning && f.code == :negative_numeric_value, natural_report.findings)

    annual_hydro = DataFrame("Year" => [2026], "Gordon" => [-1.0])
    annual_report = ParseISP.validate_isp2026_hydro_trace(annual_hydro, "MaxEnergyYear_RefYear5000_Flat.csv")
    @test ParseISP.has_blockers(annual_report)
    @test any(f -> f.severity == :blocker && f.code == :negative_numeric_value, annual_report.findings)

    mktempdir() do dir
        workbook = joinpath(dir, "flow.xlsx")
        write_line_invoptions_fixture(workbook; buspair = "WNV to NQ")
        raw = ParseISP.read_isp2026_line_invoptions_raw(workbook)

        report = ParseISP.validate_isp2026_line_invoptions(raw)
        @test report.layout == :isp2026
        @test ParseISP.has_blockers(report)
        @test any(f -> f.code == :unknown_bus_label, report.findings)

        fixed = ParseISP.fix_isp2026_line_invoptions(raw, report)
        @test nrow(fixed.canonical) == 1
        @test fixed.canonical[1, :name] == "Mini Option"
        @test fixed.canonical[1, :busA] == "VIC"
        @test fixed.canonical[1, :idbusA] == ParseISP._ispdata_bus_id("VIC")
        @test fixed.canonical[1, :active] == 1
        @test fixed.canonical[1, :invcost] == 12345.0
    end

    for alias in ("WNV", "SEV")
        mktempdir() do dir
            workbook = joinpath(dir, "flow_$(alias).xlsx")
            write_line_invoptions_fixture(workbook; buspair = "$(alias) to NQ")
            raw = ParseISP.read_isp2026_line_invoptions_raw(workbook)

            report = ParseISP.validate_isp2026_line_invoptions(raw)
            @test any(f -> f.code == :unknown_bus_label, report.findings)

            fixed = ParseISP.fix_isp2026_line_invoptions(raw, report)
            @test fixed.canonical[1, :busA] == "VIC"
            @test fixed.canonical[1, :idbusA] == ParseISP._ispdata_bus_id("VIC")
        end
    end
end

@testset "EV WEM sections are skipped" begin
    mktempdir() do dir
        workbook = joinpath(dir, "ev.xlsx")
        XLSX.openxlsx(workbook, mode = "w") do xf
            sheet = xf[1]
            XLSX.rename!(sheet, "BEV_PHEV_Profile_kW (Weekend)")
            sheet[XLSX.CellRef(1, 2)] = "New South Wales"
            sheet[XLSX.CellRef(2, 3)] = Time(0, 0)
            sheet[XLSX.CellRef(2, 4)] = Time(0, 30)
            sheet[XLSX.CellRef(3, 2)] = "Small Residential, Convenience - vehicle charging"
            sheet[XLSX.CellRef(3, 3)] = 1.0
            sheet[XLSX.CellRef(3, 4)] = 2.0
            sheet[XLSX.CellRef(4, 2)] = "WEM"
            sheet[XLSX.CellRef(5, 3)] = Time(0, 0)
            sheet[XLSX.CellRef(5, 4)] = Time(0, 30)
            sheet[XLSX.CellRef(6, 2)] = "WEM"
            sheet[XLSX.CellRef(6, 3)] = 99.0
            sheet[XLSX.CellRef(6, 4)] = 99.0
        end

        profiles = ParseISP.ev_build_bev_phev_profile_dataframe(workbook, "BEV_PHEV_Profile_kW (Weekend)"; day_type = "Weekend")
        @test nrow(profiles) == 1
        @test profiles.vehicle_type == ["Small Residential"]
        @test profiles.state == ["NSW"]
    end
end

@testset "ISP2026 failure detection" begin
    mktempdir() do dir
        workbook = joinpath(dir, "bad_flow.xlsx")
        write_line_invoptions_fixture(workbook; buspair = "ABC to NQ")
        raw = ParseISP.read_isp2026_line_invoptions_raw(workbook)

        report = ParseISP.validate_isp2026_line_invoptions(raw)
        @test ParseISP.has_blockers(report)
        @test any(f -> f.code == :unknown_bus_label, report.findings)
        @test_throws ErrorException ParseISP.fix_isp2026_line_invoptions(raw, report)
        @test_throws ErrorException ParseISP.require_clean_validation!(report)
        tc, ts, tv = ParseISP.initialise_time_structures()
        ParseISP.bus_table(ts)
        @test_throws ErrorException ParseISP.line_invoptions(ts, workbook)
    end
end

@testset "ISP2026 outlook ZIP" begin
    mktempdir() do dir
        cores = joinpath(dir, "Core scenarios")
        sens = joinpath(dir, "Sensitivities")
        mkpath(cores)
        mkpath(sens)

        core_wb = write_outlook_workbook(joinpath(cores, "2026 ISP - Accelerated Transition - Core.xlsx"))
        sens_wb = write_outlook_workbook(joinpath(sens, "2026 ISP - Accelerated Transition - Sensitivity - High Case.xlsx"))
        zip_path = joinpath(dir, "2026-isp-generation-and-storage-outlook.zip")
        run(Cmd(Cmd(["zip", "-qr", zip_path, "Core scenarios", "Sensitivities"]); dir = dir))

        entries = ParseISP.read_isp2026_outlook_entries(zip_path)
        @test any(endswith.(entries, ".xlsx"))

        validation = ParseISP.validate_isp2026_outlook_entries(entries)
        @test isempty(filter(f -> f.severity == :blocker, validation.findings))

        preview = ParseISP.read_isp2026_outlook_workbook(zip_path, "Core scenarios/2026 ISP - Accelerated Transition - Core.xlsx", "Capacity", "A3:F12")
        @test preview[1, :Technology] == "Black coal"

        inspection = ParseISP.inspect_isp26_generation_storage_outlook(zip_path; parse_tables = true, preview_range = "A3:F12")
        @test length(inspection.core_entries) == 1
        @test length(inspection.sensitivity_entries) == 1
        @test inspection.core_workbooks[1].scenario == "Accelerated Transition"
        @test inspection.core_workbooks[1].capacity[1, :Technology] == "Black coal"
        @test inspection.core_workbooks[1].capacity[1, Symbol("2025-26")] == 0
        @test inspection.validation isa NamedTuple
    end
end

@testset "ISP2026 outlook preparation" begin
    mktempdir() do dir
        cores = joinpath(dir, "Core scenarios")
        mkpath(cores)
        write_full_outlook_workbook(joinpath(cores, "2026 ISP - Accelerated Transition - Core.xlsx"))
        zip_path = joinpath(dir, "2026-isp-generation-and-storage-outlook.zip")
        run(Cmd(Cmd(["zip", "-qr", zip_path, "Core scenarios"]); dir = dir))

        result = ParseISP.prepare_isp26_outlook_aux(zip_path;
            data_root = dir,
            scenario_map = Dict("Accelerated Transition" => "Step Change"))

        @test length(result.installed_core_workbooks) == 1
        @test isfile(joinpath(dir, "Auxiliary", "CapacityOutlook2026_Condensed.xlsx"))
        @test isfile(joinpath(dir, "Auxiliary", "StorageCapacityOutlook_2026_ISP.xlsx"))
        @test isfile(joinpath(dir, "Auxiliary", "StorageEnergyOutlook_2026_ISP.xlsx"))
        @test isfile(joinpath(dir, "Auxiliary", "2026 ISP - Step Change - Core_REZCAP.xlsx"))
        @test result.capacity_outlook.condensed[1, :Scenario] == "Step Change"
        @test result.capacity_outlook.condensed[1, :date] == Date("2025-07-01")
        @test result.storage_outlook.capacity[1, :Scenario] == "Step Change"
    end
end

@testset "ISP2026 dataset entrypoint validation" begin
    @test isdefined(ParseISP, :build_ISP26_datasets)
    @test isdefined(ParseISP, :build_datasets)
    mktempdir() do dir
        missing_sources_err = try
            ParseISP.build_datasets(
                ParseISP.ISP2026(),
                downloadpath = dir,
                years = [2026],
                download_from_AEMO = false,
                prepare_outlook = false,
                build_traces = false,
                write_csv = false,
                write_arrow = false,
            )
            nothing
        catch caught
            caught
        end
        @test missing_sources_err isa ArgumentError
        @test occursin("Missing required ISP2026 input file", sprint(showerror, missing_sources_err))
        @test_throws ArgumentError ParseISP.build_ISP26_datasets(
            downloadpath = dir,
            years = [2026],
            download_from_AEMO = false,
            prepare_outlook = false,
            build_traces = false,
            write_csv = false,
            write_arrow = false,
        )
    end
end
