module ISP2026SourceTraceInventory

using CSV
using DataFrames
using Dates

export classify_trace_schema, validate_date_sequence, inspect_csv, inventory_root, require_download_roots, main

const OUTPUT_STEM = "isp2026_source_trace_inventory"
const OUTPUT_COLUMNS = ["subject", "evidence_class", "locator", "statement", "inspection_scope", "limitation"]

"Classify only observed header shapes; a four-column file has no inferred cadence or role."
function classify_trace_schema(headers)
    h = String.(headers)
    if length(h) == 51 && h[1:3] == ["Year", "Month", "Day"] && h[4:end] == lpad.(string.(1:48), 2, '0')
        return :daily_half_hourly_zero_padded
    elseif length(h) == 51 && h[1:3] == ["Year", "Month", "Day"] && h[4:end] == string.(1:48)
        return :daily_half_hourly_unpadded
    elseif length(h) == 4 && h[1:3] == ["Year", "Month", "Day"]
        return :value_file
    else
        return :unsupported
    end
end

function validate_date_sequence(year, month, day)
    dates = try
        Date.(Int.(year), Int.(month), Int.(day))
    catch
        Date[]
    end
    isempty(dates) && return (valid=false, cadence=:invalid, first_date=nothing, last_date=nothing)
    unique_dates = unique(dates)
    cadence = length(unique_dates) == 1 ? :single :
        all(diff(unique_dates) .== Day(1)) ? :daily : :non_contiguous
    (valid=cadence in (:single, :daily), cadence=cadence,
        first_date=first(dates), last_date=last(dates))
end

function _csv_paths(root)
    paths = String[]
    for (dir, dirs, files) in walkdir(root)
        filter!(d -> !startswith(d, ".") && !startswith(d, "._"), dirs)
        for file in files
            (startswith(file, ".") || startswith(file, "._") || !endswith(lowercase(file), ".csv")) && continue
            push!(paths, joinpath(dir, file))
        end
    end
    sort!(paths)
end

function _scenario_family(path, root)
    rel = splitpath(relpath(path, root))
    trace_index = findfirst(==("Traces"), rel)
    if trace_index === nothing
        return (scenario="unknown", family="unknown")
    end
    scenario = trace_index > 1 ? rel[trace_index - 1] : "unknown"
    family = trace_index < length(rel) - 1 ? rel[trace_index + 1] : "unknown"
    directories = lowercase.(rel[trace_index + 1:end-1])
    if "load_subtractor" in directories
        family = "load_subtractor"
    elseif any(d -> d == "solar" || startswith(d, "solar_"), directories) || any(occursin("solar traces", d) for d in directories)
        family = "solar"
    elseif any(d -> d == "wind" || startswith(d, "wind_"), directories) || any(occursin("wind traces", d) for d in directories)
        family = "wind"
    elseif "rooftop pv" in directories
        family = "rooftop pv"
    elseif "demand" in directories
        family = "demand"
    elseif "dnsp" in directories
        family = "dnsp"
    elseif "gas" in directories
        family = "gas"
    elseif "hydro" in directories
        family = "hydro"
    end
    (scenario=scenario, family=family)
end

function _date_cadence(df, schema)
    all(n -> n in propertynames(df), [:Year, :Month, :Day]) || return :no_date_fields
    values = validate_date_sequence(df.Year, df.Month, df.Day)
    schema == :daily_half_hourly && return :daily_half_hourly
    values.cadence
end

function _inspect(path, root, edition)
    table = CSV.File(path; normalizenames=false)
    headers = String.(propertynames(table))
    schema = classify_trace_schema(headers)
    rows = 0
    dates = Date[]
    numeric_min, numeric_max = nothing, nothing
    date_fields = all(n -> n in propertynames(table), [:Year, :Month, :Day])
    for row in table
        rows += 1
        if date_fields
            date = try
                Date(Int(row.Year), Int(row.Month), Int(row.Day))
            catch
                nothing
            end
            date === nothing || push!(dates, date)
        end
        for name in propertynames(table)
            name in (:Year, :Month, :Day) && continue
            value = getproperty(row, name)
            value isa Missing && continue
            parsed = tryparse(Float64, string(value))
            parsed === nothing && continue
            numeric_min = numeric_min === nothing ? parsed : min(numeric_min, parsed)
            numeric_max = numeric_max === nothing ? parsed : max(numeric_max, parsed)
        end
    end
    date_result = isempty(dates) ? (valid=false, cadence=:no_date_fields, first_date=nothing, last_date=nothing) : validate_date_sequence(year.(dates), month.(dates), day.(dates))
    sf = _scenario_family(path, root)
    (edition=edition, scenario=sf.scenario, family=sf.family,
        path=relpath(path, root), filename=basename(path), schema=schema,
        rows=rows, columns=length(headers), first_date=date_result.first_date,
        last_date=date_result.last_date, cadence=date_result.cadence,
        numeric_min=numeric_min, numeric_max=numeric_max)
end

function inventory_root(root, edition)
    isdir(root) || error("missing $(edition) download root: $(root)")
    paths = _csv_paths(root)
    # ISP 2024 is retained as the solar/wind source-contract baseline; the full
    # all-family inventory is intentionally the ISP 2026 release under study.
    if edition == "ISP 2024"
        paths = filter(paths) do path
            rel = replace(relpath(path, root), '\\' => '/')
            startswith(rel, "Traces/solar_4006/") || startswith(rel, "Traces/wind_4006/")
        end
    end
    [_inspect(path, root, edition) for path in paths]
end

inspect_csv(path; edition="synthetic", root=dirname(path)) = _inspect(path, root, edition)

function require_download_roots(root24=get(ENV, "PISP_ISP2024_DOWNLOAD_ROOT", ""), root26=get(ENV, "PISP_ISP2026_DOWNLOAD_ROOT", ""))
    isempty(root24) && error("missing PISP_ISP2024_DOWNLOAD_ROOT: explicit root is required")
    isempty(root26) && error("missing PISP_ISP2026_DOWNLOAD_ROOT: explicit root is required")
    (root24=root24, root26=root26)
end

function _write(path, rows, columns)
    mkpath(dirname(path))
    CSV.write(path, DataFrame([c => [something(getproperty(row, Symbol(c)), missing) for row in rows] for c in columns]))
end

function _capability_rows()
    [
        (subject="trace role", evidence_class="report-supported semantic", locator="2026-isp-plexos-model-instructions.pdf, physical pp. 5--7", statement="The model instructions describe trace families and rolling-reference-year context.", inspection_scope="named report pages", limitation="Report semantics do not establish raw CSV fields."),
        (subject="REZ generation constraint", evidence_class="report-supported semantic", locator="2025-isp-methodology.pdf, physical pp. 21--22", statement="The equation and term definitions describe instantaneous dispatch, including wind and solar, against a transmission limit plus any augmentation.", inspection_scope="complete named physical pages", limitation="Report-supported semantic only; not a parser claim."),
        (subject="REZ generation constraint field", evidence_class="raw-source observation", locator="complete inspected trace inventory", statement="No inspected source-trace CSV field represents that equation or term set.", inspection_scope="all inventoried CSV headers and values", limitation="Not proof about all AEMO assets or uninspected source material."),
        (subject="REZ generation constraint support", evidence_class="code-scope statement", locator="src/PISPparsers.jl; src/parsers/PISP-2024parser.jl; src/parsers/PISP-2024core.jl; src/utils/writing/PISPutils-writing.jl (fwcap, rvcap, wind schedule searches)", statement="No support was found in the bounded integrated PISP parser/preprocess inspection.", inspection_scope="current integrated PISP.jl paths only", limitation="Not proof about uninspected ParseISP.jl work."),
    ]
end

function _contract_rows(records)
    rows = NamedTuple[]
    for edition in ("ISP 2024", "ISP 2026")
        expected_rows = edition == "ISP 2024" ? 10227 : 9131
        subset = filter(r -> r.edition == edition && r.family in ("solar", "wind") && r.rows == expected_rows && r.columns == 51, records)
        isempty(subset) && continue
        push!(rows, (edition=edition, family="solar/wind", files=length(subset), observed_shapes=join(sort(unique("$(r.rows) x $(r.columns)" for r in subset)), ";"), observed_dates=join(sort(unique("$(r.first_date) through $(r.last_date)" for r in subset)), ";"), limitation="Raw-source observation; editions are not equality tests."))
    end
    rows
end

function main(; output_dir=joinpath(@__DIR__, "tables", "julia", OUTPUT_STEM))
    roots = require_download_roots()
    records = vcat(inventory_root(roots.root24, "ISP 2024"), inventory_root(roots.root26, "ISP 2026"))
    _write(joinpath(output_dir, "trace_family_inventory.csv"), records, ["edition", "scenario", "family", "path", "filename", "schema", "rows", "columns"])
    _write(joinpath(output_dir, "trace_schema_date_ranges.csv"), records, ["edition", "scenario", "family", "path", "schema", "rows", "columns", "first_date", "last_date", "cadence"])
    _write(joinpath(output_dir, "trace_numeric_ranges.csv"), records, ["edition", "scenario", "family", "path", "numeric_min", "numeric_max"])
    _write(joinpath(output_dir, "edition_trace_contract.csv"), _contract_rows(records), ["edition", "family", "files", "observed_shapes", "observed_dates", "limitation"])
    _write(joinpath(output_dir, "report_code_raw_capability_matrix.csv"), _capability_rows(), OUTPUT_COLUMNS)
    println("wrote source-trace evidence to $(output_dir)")
    records
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

end
