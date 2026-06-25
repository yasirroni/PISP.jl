using Test
using DataFrames
using Dates
using HTTP
using XLSX
using Tables
using PISP

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

            extracted_paths = PISP.PISPScrapperUtils.extract_all_zips(src_dir, dest_dir; skip_existing = false)

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

        result = PISP.download_isp26_source_files(dir; download_targets_fn = fake_download)

        @test seen_keys == [:isp26_inputs, :isp26_outlook, :isp26_model, :isp26_solar_traces, :isp26_wind_traces]
        @test result.targets.automatic == (:isp26_inputs, :isp26_outlook, :isp26_model, :isp26_solar_traces, :isp26_wind_traces)
        @test result.downloaded.ispdata26 == joinpath(dir, "2026-isp-inputs-and-assumptions-workbook.xlsm")
        @test result.downloaded.outlook_generation_storage == joinpath(dir, "2026-isp-generation-and-storage-outlook.zip")
        @test result.downloaded.ispmodel_zip == joinpath(dir, "2026-isp-model.zip")
        @test result.downloaded.solar_traces_zip == joinpath(dir, "zip", "Traces", "2026-isp-solar-traces.zip")
        @test result.downloaded.wind_traces_zip == joinpath(dir, "zip", "Traces", "2026-isp-wind-traces.zip")
        @test result.outlook === nothing
    end
end

@testset "AEMO Cloudflare download detection" begin
    response = HTTP.Response(403, ["server" => "cloudflare", "cf-mitigated" => "challenge"], Vector{UInt8}("challenge"))
    @test PISP.PISPScrapperUtils._looks_like_cloudflare_challenge(response)
    err = PISP.PISPScrapperUtils.DownloadBlockedError("https://www.aemo.com.au/file.zip", 403, "Cloudflare challenge or access policy")
    @test occursin("interactive browser session", sprint(showerror, err))
end

@testset "ISP2026 readers" begin
    mktempdir() do dir
        workbook = joinpath(dir, "flow.xlsx")
        write_line_invoptions_fixture(workbook)

        raw = PISP.read_isp2026_line_invoptions_raw(workbook)
        @test raw[1, 4] == "Mini Option"
        @test nrow(raw) >= 1

        tc, ts, tv = PISP.initialise_time_structures()
        PISP.bus_table(ts)
        PISP.line_invoptions(ts, workbook)
        @test nrow(ts.line) == 1
        @test ts.line[1, :name] == "Mini Option"
        @test ts.line[1, :capacity] == 1100.0
    end

    mktempdir() do dir
        workbook = joinpath(dir, "dr" * "aft-2026-isp-inputs-and-assumptions-workbook.xlsx")
        write_line_invoptions_fixture(workbook)
        @test_throws ArgumentError PISP.read_isp2026_line_invoptions_raw(workbook)
    end
end

@testset "ISP2026 validators and fixes" begin
    mktempdir() do dir
        workbook = joinpath(dir, "flow.xlsx")
        write_line_invoptions_fixture(workbook; buspair = "WNV to NQ")
        raw = PISP.read_isp2026_line_invoptions_raw(workbook)

        report = PISP.validate_isp2026_line_invoptions(raw)
        @test report.layout == :isp2026
        @test PISP.has_blockers(report)
        @test any(f -> f.code == :unknown_bus_label, report.findings)

        fixed = PISP.fix_isp2026_line_invoptions(raw, report)
        @test nrow(fixed.canonical) == 1
        @test fixed.canonical[1, :name] == "Mini Option"
        @test fixed.canonical[1, :busA] == "VIC"
        @test fixed.canonical[1, :idbusA] == PISP._ispdata_bus_id("VIC")
        @test fixed.canonical[1, :active] == 1
        @test fixed.canonical[1, :invcost] == 12345.0
    end

    for alias in ("WNV", "SEV")
        mktempdir() do dir
            workbook = joinpath(dir, "flow_$(alias).xlsx")
            write_line_invoptions_fixture(workbook; buspair = "$(alias) to NQ")
            raw = PISP.read_isp2026_line_invoptions_raw(workbook)

            report = PISP.validate_isp2026_line_invoptions(raw)
            @test any(f -> f.code == :unknown_bus_label, report.findings)

            fixed = PISP.fix_isp2026_line_invoptions(raw, report)
            @test fixed.canonical[1, :busA] == "VIC"
            @test fixed.canonical[1, :idbusA] == PISP._ispdata_bus_id("VIC")
        end
    end
end

@testset "ISP2026 failure detection" begin
    mktempdir() do dir
        workbook = joinpath(dir, "bad_flow.xlsx")
        write_line_invoptions_fixture(workbook; buspair = "ABC to NQ")
        raw = PISP.read_isp2026_line_invoptions_raw(workbook)

        report = PISP.validate_isp2026_line_invoptions(raw)
        @test PISP.has_blockers(report)
        @test any(f -> f.code == :unknown_bus_label, report.findings)
        @test_throws ErrorException PISP.fix_isp2026_line_invoptions(raw, report)
        @test_throws ErrorException PISP.require_clean_validation!(report)
        tc, ts, tv = PISP.initialise_time_structures()
        PISP.bus_table(ts)
        @test_throws ErrorException PISP.line_invoptions(ts, workbook)
    end
end

@testset "ISP2026 outlook ZIP" begin
    mktempdir() do dir
        cores = joinpath(dir, "Cores")
        sens = joinpath(dir, "Sensitivities")
        mkpath(cores)
        mkpath(sens)

        core_wb = write_outlook_workbook(joinpath(cores, "2026 ISP - Accelerated Transition - Core.xlsx"))
        sens_wb = write_outlook_workbook(joinpath(sens, "2026 ISP - Accelerated Transition - Sensitivity - High Case.xlsx"))
        zip_path = joinpath(dir, "2026-isp-generation-and-storage-outlook.zip")
        run(Cmd(`zip -qr $zip_path Cores Sensitivities`; dir = dir))

        entries = PISP.read_isp2026_outlook_entries(zip_path)
        @test any(endswith.(entries, ".xlsx"))

        validation = PISP.validate_isp2026_outlook_entries(entries)
        @test isempty(filter(f -> f.severity == :blocker, validation.findings))

        preview = PISP.read_isp2026_outlook_workbook(zip_path, "Cores/2026 ISP - Accelerated Transition - Core.xlsx", "Capacity", "A3:F12")
        @test preview[1, :Technology] == "Black coal"

        inspection = PISP.inspect_isp26_generation_storage_outlook(zip_path; parse_tables = true, preview_range = "A3:F12")
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
        cores = joinpath(dir, "Cores")
        mkpath(cores)
        write_full_outlook_workbook(joinpath(cores, "2026 ISP - Accelerated Transition - Core.xlsx"))
        zip_path = joinpath(dir, "2026-isp-generation-and-storage-outlook.zip")
        run(Cmd(`zip -qr $zip_path Cores`; dir = dir))

        result = PISP.prepare_isp26_outlook_aux(zip_path;
            data_root = dir,
            scenario_map = Dict("Accelerated Transition" => "Step Change"))

        @test length(result.installed_core_workbooks) == 1
        @test isfile(joinpath(dir, "Auxiliary", "CapacityOutlook2024_Condensed.xlsx"))
        @test isfile(joinpath(dir, "Auxiliary", "StorageCapacityOutlook_2024_ISP.xlsx"))
        @test isfile(joinpath(dir, "Auxiliary", "StorageEnergyOutlook_2024_ISP.xlsx"))
        @test isfile(joinpath(dir, "Auxiliary", "2024 ISP - Step Change - Core_REZCAP.xlsx"))
        @test result.capacity_outlook.condensed[1, :Scenario] == "Step Change"
        @test result.capacity_outlook.condensed[1, :date] == Date("2025-07-01")
        @test result.storage_outlook.capacity[1, :Scenario] == "Step Change"
    end
end

@testset "ISP2026 dataset entrypoint validation" begin
    @test isdefined(PISP, :build_ISP26_datasets)
    mktempdir() do dir
        @test_throws ArgumentError PISP.build_ISP26_datasets(
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
