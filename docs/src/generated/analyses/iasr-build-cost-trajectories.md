```@meta
EditURL = "../../../literate/analysis/iasr_build_cost_trajectories.jl"
```

# IASR build-cost trajectories by technology

This analysis asks how projected capital costs for the main VRE and storage technologies (utility-scale solar, onshore/offshore wind, battery storage) evolve across the projection years in the IASR "Build costs" sheet, and whether the annualized rate of cost decline differs materially by technology.

The evidence comes from the AEMO 2024 ISP Inputs and Assumptions workbook at `data/2024/pisp-downloads/2024-isp-inputs-and-assumptions-workbook.xlsx`, sheet `Build costs`, computed live on this page.

No AEMO report-PDF page citation is currently verified for this question, so this page cites only the local workbook-derived evidence.

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
using CSV
using DataFrames
using XLSX
using Printf
using Statistics

const REPO_ROOT = normpath(get(
    ENV,
    "PISP_DOCS_REPO_ROOT",
    joinpath(@__DIR__, "..", "..", ".."),
))

include(joinpath(REPO_ROOT, "eda", "eda_support.jl"))
using .EdaSupport

EdaSupport.snapshot_metadata_line(REPO_ROOT; context = "2024 ISP Inputs and Assumptions workbook, Build costs sheet")

const SCRIPT_STEM = "10_build_cost_trajectories"
const DOWNLOADS = joinpath("data", "2024", "pisp-downloads")  # kept relative: this is the path form recorded below
const IASR_WORKBOOK = joinpath(DOWNLOADS, "2024-isp-inputs-and-assumptions-workbook.xlsx")
const SHEET_NAME = "Build costs"
abs_path(relative_path) = joinpath(REPO_ROOT, relative_path)  # resolves a DOWNLOADS-relative path to an absolute location for reading
````

```@raw html
</details>
```

````
Snapshot: PISP.jl commit 53d7330+dirty, generated 2026-07-17 — 2024 ISP Inputs and Assumptions workbook, Build costs sheet

````

Trim a raw XLSX matrix down to the bounding box of non-missing cells: this
workbook's declared sheet dimension carries trailing all-missing rows/columns
beyond its real content (this sheet reports max_row 1191 but its last
populated row is 223).

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
function trim_sheet(matrix)
    nrows, ncols = size(matrix)
    last_row = 0
    for r in 1:nrows
        if any(x -> x !== missing, view(matrix, r, :))
            last_row = r
        end
    end
    last_col = 0
    for c in 1:ncols
        if any(x -> x !== missing, view(matrix, :, c))
            last_col = c
        end
    end
    (last_row == 0 || last_col == 0) && return Matrix{Any}(undef, 0, 0)
    return matrix[1:last_row, 1:last_col]
end
````

```@raw html
</details>
```

The sheet keyword-matches "utility-scale solar" to Large scale Solar PV
only (not Solar Thermal, a distinct CSP technology), "onshore/offshore
wind" to all 3 Wind rows, and "battery storage" to all 4 duration
variants. Pumped hydro/BOTN rows are excluded here: they are pumped-hydro
storage, the subject of the separate PHES-versus-battery storage
characteristics page.

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
const TARGET_KEYWORDS = ["solar pv", "wind", "battery storage"]

is_target_technology(tech) = any(kw -> occursin(kw, lowercase(tech)), TARGET_KEYWORDS)
````

```@raw html
</details>
```

The sheet lays out one "Build cost by technology ($/kW)" master table: a
header row ("Technology", "Scenario", then one column per financial year),
followed by 19 technologies x 6 scenarios in 6-row blocks, each block
preceded by a repeated copy of the same header row and followed by a blank
separator row. This locates that header by literal content rather than a
hardcoded row number, since earlier rows on the sheet hold unrelated
GenCost-scenario-mapping tables with their own, differently-shaped blocks.

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
function find_master_header_row(matrix)
    nrows = size(matrix, 1)
    for r in 1:nrows
        if isequal(matrix[r, 2], "Technology") && isequal(matrix[r, 3], "Scenario")
            return r
        end
    end
    error("Could not locate the \"Build cost by technology\" master header row in sheet \"$SHEET_NAME\"")
end

function year_columns(matrix, header_row)
    ncols = size(matrix, 2)
    years = String[]
    col_indices = Int[]
    for c in 4:ncols
        label = matrix[header_row, c]
        label === missing && continue
        push!(years, string(label))
        push!(col_indices, c)
    end
    return years, col_indices
end

function build_cost_long_table(matrix, header_row, years, col_indices)
    rows = NamedTuple[]
    nrows = size(matrix, 1)
    for r in (header_row + 1):nrows
        tech = matrix[r, 2]
        scenario = matrix[r, 3]
        (tech === missing || scenario === missing) && continue
        tech == "Technology" && continue  # repeated mini-header before each block
        for (year, c) in zip(years, col_indices)
            value = matrix[r, c]
            push!(
                rows,
                (
                    technology = String(tech),
                    scenario = String(scenario),
                    year = year,
                    cost_dollar_per_kw = value === missing ? missing : Float64(value),
                ),
            )
        end
    end
    return DataFrame(rows)
end
````

```@raw html
</details>
```

Per (technology, scenario): first/last available projection year and cost,
the annualized (CAGR-style) decline rate between them, and the total
percentage change -- directly answers whether the rate of decline differs
materially by technology.

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
function decline_summary(long_table)
    rows = NamedTuple[]
    for key_df in groupby(long_table, [:technology, :scenario])
        complete = filter(:cost_dollar_per_kw => !ismissing, key_df)
        nrow(complete) < 2 && continue
        complete = sort(complete, :year)  # "YYYY-YY" financial-year labels sort correctly as strings
        first_row = first(complete)
        last_row = last(complete)
        n_years = nrow(complete) - 1
        first_cost = first_row.cost_dollar_per_kw
        last_cost = last_row.cost_dollar_per_kw
        cagr_pct = first_cost > 0 ? ((last_cost / first_cost)^(1 / n_years) - 1) * 100 : missing
        total_pct_change = first_cost > 0 ? (last_cost - first_cost) / first_cost * 100 : missing
        push!(
            rows,
            (
                technology = first_row.technology,
                scenario = first_row.scenario,
                first_year = first_row.year,
                last_year = last_row.year,
                first_cost_dollar_per_kw = first_cost,
                last_cost_dollar_per_kw = last_cost,
                annualized_decline_rate_pct = cagr_pct,
                total_pct_change_pct = total_pct_change,
            ),
        )
    end
    return DataFrame(rows)
end
````

```@raw html
</details>
```

## Step 1 — load and trim the "Build costs" sheet

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
println("Workbook exists: ", isfile(abs_path(IASR_WORKBOOK)))
isfile(abs_path(IASR_WORKBOOK)) || error("IASR workbook not found at $IASR_WORKBOOK")

matrix = XLSX.openxlsx(abs_path(IASR_WORKBOOK)) do xf
    trim_sheet(xf[SHEET_NAME][:])
end
println("Trimmed \"$SHEET_NAME\" sheet shape: ", size(matrix))
````

```@raw html
</details>
```

````
Workbook exists: true
Trimmed "Build costs" sheet shape: (223, 35)

````

## Step 2 — locate the master build-cost table and its projection years

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
header_row = find_master_header_row(matrix)
years, col_indices = year_columns(matrix, header_row)
println("Master table header at row $header_row, ", length(years), " projection years: ", first(years), " .. ", last(years))
````

```@raw html
</details>
```

````
Master table header at row 81, 32 projection years: 2022-23 .. 2053-54

````

## Step 3 — long-format build-cost table and target-technology filter

All 19 technologies on the sheet are listed in `technology_match` for transparency; the analysis itself only follows the utility-scale solar, onshore/offshore wind, and battery-storage rows matched by `is_target_technology`. The full long-format target table (technology x scenario x year) is written as evidence; the table below previews only its first rows.

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
long_table = build_cost_long_table(matrix, header_row, years, col_indices)
all_technologies = unique(long_table.technology)
println("Technologies found (", length(all_technologies), "): ", join(all_technologies, ", "))

matched_technologies = filter(is_target_technology, all_technologies)
println("Target (solar/wind/battery) technologies matched (", length(matched_technologies), "): ", join(matched_technologies, ", "))

technology_match = DataFrame(
    technology = all_technologies,
    is_target_technology = [is_target_technology(t) ? 1 : 0 for t in all_technologies],
)
write_table(technology_match, SCRIPT_STEM, "technology_match")
technology_match
````

```@raw html
</details>
```

```@raw html
<div><div style = "float: left;"><span>19×2 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">technology</th><th style = "text-align: left;">is_target_technology</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "Int64" style = "text-align: left;">Int64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">OCGT (small GT)</td><td style = "text-align: right;">0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">OCGT (large GT)</td><td style = "text-align: right;">0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">CCGT</td><td style = "text-align: right;">0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">CCGT with CCS</td><td style = "text-align: right;">0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">Hydrogen reciprocating engines</td><td style = "text-align: right;">0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">Biomass</td><td style = "text-align: right;">0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">Large scale Solar PV</td><td style = "text-align: right;">1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">Solar Thermal (15hrs Storage)</td><td style = "text-align: right;">0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">9</td><td style = "text-align: left;">Battery storage (1hr storage)</td><td style = "text-align: right;">1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">10</td><td style = "text-align: left;">Battery storage (2hrs storage)</td><td style = "text-align: right;">1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">11</td><td style = "text-align: left;">Battery storage (4hrs storage)</td><td style = "text-align: right;">1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">12</td><td style = "text-align: left;">Battery storage (8hrs storage)</td><td style = "text-align: right;">1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">13</td><td style = "text-align: left;">Wind</td><td style = "text-align: right;">1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">14</td><td style = "text-align: left;">Wind - offshore (fixed)</td><td style = "text-align: right;">1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">15</td><td style = "text-align: left;">Wind - offshore (floating)</td><td style = "text-align: right;">1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">16</td><td style = "text-align: left;">Pumped Hydro (8hrs storage)</td><td style = "text-align: right;">0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">17</td><td style = "text-align: left;">Pumped Hydro (24hrs storage)</td><td style = "text-align: right;">0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">18</td><td style = "text-align: left;">Pumped Hydro (48hrs storage)</td><td style = "text-align: right;">0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">19</td><td style = "text-align: left;">BOTN - Cethana</td><td style = "text-align: right;">0</td></tr></tbody></table></div>
```

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
target_long = filter(:technology => is_target_technology, long_table)
write_table(target_long, SCRIPT_STEM, "build_cost_trajectory")
println("Target-technology long-format rows written as evidence: ", nrow(target_long))
first(target_long, 8)
````

```@raw html
</details>
```

```@raw html
<div><div style = "float: left;"><span>8×4 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">technology</th><th style = "text-align: left;">scenario</th><th style = "text-align: left;">year</th><th style = "text-align: left;">cost_dollar_per_kw</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">Large scale Solar PV</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2022-23</td><td style = "text-align: right;">1680.94</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">Large scale Solar PV</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2023-24</td><td style = "text-align: right;">1621.06</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">Large scale Solar PV</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2024-25</td><td style = "text-align: right;">1504.51</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">Large scale Solar PV</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2025-26</td><td style = "text-align: right;">1391.16</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">Large scale Solar PV</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2026-27</td><td style = "text-align: right;">1279.95</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">Large scale Solar PV</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2027-28</td><td style = "text-align: right;">1220.07</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">Large scale Solar PV</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2028-29</td><td style = "text-align: right;">1179.44</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">Large scale Solar PV</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2029-30</td><td style = "text-align: right;">1166.61</td></tr></tbody></table></div>
```

## Step 4 — annualized decline rate by technology and scenario

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
decline = decline_summary(target_long)
decline = sort(decline, :annualized_decline_rate_pct)
write_table(decline, SCRIPT_STEM, "build_cost_decline_summary")
decline
````

```@raw html
</details>
```

```@raw html
<div><div style = "float: left;"><span>48×8 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">technology</th><th style = "text-align: left;">scenario</th><th style = "text-align: left;">first_year</th><th style = "text-align: left;">last_year</th><th style = "text-align: left;">first_cost_dollar_per_kw</th><th style = "text-align: left;">last_cost_dollar_per_kw</th><th style = "text-align: left;">annualized_decline_rate_pct</th><th style = "text-align: left;">total_pct_change_pct</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">Battery storage (8hrs storage)</td><td style = "text-align: left;">GenCost Global NZE by 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">4148.88</td><td style = "text-align: right;">1060.75</td><td style = "text-align: right;">-4.30419</td><td style = "text-align: right;">-74.433</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">Battery storage (8hrs storage)</td><td style = "text-align: left;">Green Energy Exports</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">4148.88</td><td style = "text-align: right;">1060.75</td><td style = "text-align: right;">-4.30419</td><td style = "text-align: right;">-74.433</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">Wind - offshore (floating)</td><td style = "text-align: left;">GenCost Global NZE by 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">8417.53</td><td style = "text-align: right;">2377.05</td><td style = "text-align: right;">-3.99682</td><td style = "text-align: right;">-71.7607</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">Wind - offshore (floating)</td><td style = "text-align: left;">Green Energy Exports</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">8417.53</td><td style = "text-align: right;">2377.05</td><td style = "text-align: right;">-3.99682</td><td style = "text-align: right;">-71.7607</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">Battery storage (4hrs storage)</td><td style = "text-align: left;">GenCost Global NZE by 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">2335.35</td><td style = "text-align: right;">671.52</td><td style = "text-align: right;">-3.94081</td><td style = "text-align: right;">-71.2454</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">Battery storage (4hrs storage)</td><td style = "text-align: left;">Green Energy Exports</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">2335.35</td><td style = "text-align: right;">671.52</td><td style = "text-align: right;">-3.94081</td><td style = "text-align: right;">-71.2454</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">Large scale Solar PV</td><td style = "text-align: left;">GenCost Global NZE by 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">1680.94</td><td style = "text-align: right;">542.135</td><td style = "text-align: right;">-3.58448</td><td style = "text-align: right;">-67.7481</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">Large scale Solar PV</td><td style = "text-align: left;">Green Energy Exports</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">1680.94</td><td style = "text-align: right;">542.135</td><td style = "text-align: right;">-3.58448</td><td style = "text-align: right;">-67.7481</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">9</td><td style = "text-align: left;">Battery storage (2hrs storage)</td><td style = "text-align: left;">GenCost Global NZE by 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">1439.28</td><td style = "text-align: right;">496.155</td><td style = "text-align: right;">-3.37717</td><td style = "text-align: right;">-65.5275</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">10</td><td style = "text-align: left;">Battery storage (2hrs storage)</td><td style = "text-align: left;">Green Energy Exports</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">1439.28</td><td style = "text-align: right;">496.155</td><td style = "text-align: right;">-3.37717</td><td style = "text-align: right;">-65.5275</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">11</td><td style = "text-align: left;">Battery storage (8hrs storage)</td><td style = "text-align: left;">GenCost Global NZE post 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">4148.88</td><td style = "text-align: right;">1445.69</td><td style = "text-align: right;">-3.34363</td><td style = "text-align: right;">-65.1546</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">12</td><td style = "text-align: left;">Battery storage (8hrs storage)</td><td style = "text-align: left;">Step Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">4148.88</td><td style = "text-align: right;">1445.69</td><td style = "text-align: right;">-3.34363</td><td style = "text-align: right;">-65.1546</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">13</td><td style = "text-align: left;">Large scale Solar PV</td><td style = "text-align: left;">GenCost Global NZE post 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">1680.94</td><td style = "text-align: right;">610.57</td><td style = "text-align: right;">-3.21404</td><td style = "text-align: right;">-63.6768</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">14</td><td style = "text-align: left;">Large scale Solar PV</td><td style = "text-align: left;">Step Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">1680.94</td><td style = "text-align: right;">610.57</td><td style = "text-align: right;">-3.21404</td><td style = "text-align: right;">-63.6768</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">15</td><td style = "text-align: left;">Battery storage (4hrs storage)</td><td style = "text-align: left;">GenCost Global NZE post 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">2335.35</td><td style = "text-align: right;">863.994</td><td style = "text-align: right;">-3.15669</td><td style = "text-align: right;">-63.0037</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">16</td><td style = "text-align: left;">Battery storage (4hrs storage)</td><td style = "text-align: left;">Step Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">2335.35</td><td style = "text-align: right;">863.994</td><td style = "text-align: right;">-3.15669</td><td style = "text-align: right;">-63.0037</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">17</td><td style = "text-align: left;">Battery storage (2hrs storage)</td><td style = "text-align: left;">GenCost Global NZE post 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">1439.28</td><td style = "text-align: right;">588.115</td><td style = "text-align: right;">-2.84574</td><td style = "text-align: right;">-59.1382</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">18</td><td style = "text-align: left;">Battery storage (2hrs storage)</td><td style = "text-align: left;">Step Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">1439.28</td><td style = "text-align: right;">588.115</td><td style = "text-align: right;">-2.84574</td><td style = "text-align: right;">-59.1382</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">19</td><td style = "text-align: left;">Battery storage (1hr storage)</td><td style = "text-align: left;">GenCost Global NZE by 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">995.518</td><td style = "text-align: right;">422.373</td><td style = "text-align: right;">-2.72783</td><td style = "text-align: right;">-57.5725</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">20</td><td style = "text-align: left;">Battery storage (1hr storage)</td><td style = "text-align: left;">Green Energy Exports</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">995.518</td><td style = "text-align: right;">422.373</td><td style = "text-align: right;">-2.72783</td><td style = "text-align: right;">-57.5725</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">21</td><td style = "text-align: left;">Large scale Solar PV</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">1680.94</td><td style = "text-align: right;">715.362</td><td style = "text-align: right;">-2.71824</td><td style = "text-align: right;">-57.4427</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">22</td><td style = "text-align: left;">Large scale Solar PV</td><td style = "text-align: left;">Progressive Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">1680.94</td><td style = "text-align: right;">715.362</td><td style = "text-align: right;">-2.71824</td><td style = "text-align: right;">-57.4427</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">23</td><td style = "text-align: left;">Wind - offshore (fixed)</td><td style = "text-align: left;">GenCost Global NZE by 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">6075.76</td><td style = "text-align: right;">2698.91</td><td style = "text-align: right;">-2.58365</td><td style = "text-align: right;">-55.579</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">24</td><td style = "text-align: left;">Wind - offshore (fixed)</td><td style = "text-align: left;">Green Energy Exports</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">6075.76</td><td style = "text-align: right;">2698.91</td><td style = "text-align: right;">-2.58365</td><td style = "text-align: right;">-55.579</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">25</td><td style = "text-align: left;">Battery storage (8hrs storage)</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">4148.88</td><td style = "text-align: right;">1873.41</td><td style = "text-align: right;">-2.53215</td><td style = "text-align: right;">-54.8454</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">26</td><td style = "text-align: left;">Battery storage (8hrs storage)</td><td style = "text-align: left;">Progressive Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">4148.88</td><td style = "text-align: right;">1873.41</td><td style = "text-align: right;">-2.53215</td><td style = "text-align: right;">-54.8454</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">27</td><td style = "text-align: left;">Battery storage (1hr storage)</td><td style = "text-align: left;">GenCost Global NZE post 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">995.518</td><td style = "text-align: right;">456.591</td><td style = "text-align: right;">-2.48309</td><td style = "text-align: right;">-54.1353</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">28</td><td style = "text-align: left;">Battery storage (1hr storage)</td><td style = "text-align: left;">Step Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">995.518</td><td style = "text-align: right;">456.591</td><td style = "text-align: right;">-2.48309</td><td style = "text-align: right;">-54.1353</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">29</td><td style = "text-align: left;">Battery storage (4hrs storage)</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">2335.35</td><td style = "text-align: right;">1086.41</td><td style = "text-align: right;">-2.43844</td><td style = "text-align: right;">-53.4799</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">30</td><td style = "text-align: left;">Battery storage (4hrs storage)</td><td style = "text-align: left;">Progressive Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">2335.35</td><td style = "text-align: right;">1086.41</td><td style = "text-align: right;">-2.43844</td><td style = "text-align: right;">-53.4799</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">31</td><td style = "text-align: left;">Battery storage (2hrs storage)</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">1439.28</td><td style = "text-align: right;">710.015</td><td style = "text-align: right;">-2.25361</td><td style = "text-align: right;">-50.6686</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">32</td><td style = "text-align: left;">Battery storage (2hrs storage)</td><td style = "text-align: left;">Progressive Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">1439.28</td><td style = "text-align: right;">710.015</td><td style = "text-align: right;">-2.25361</td><td style = "text-align: right;">-50.6686</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">33</td><td style = "text-align: left;">Battery storage (1hr storage)</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">995.518</td><td style = "text-align: right;">545.343</td><td style = "text-align: right;">-1.92272</td><td style = "text-align: right;">-45.2202</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">34</td><td style = "text-align: left;">Battery storage (1hr storage)</td><td style = "text-align: left;">Progressive Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">995.518</td><td style = "text-align: right;">545.343</td><td style = "text-align: right;">-1.92272</td><td style = "text-align: right;">-45.2202</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">35</td><td style = "text-align: left;">Wind - offshore (floating)</td><td style = "text-align: left;">GenCost Global NZE post 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">8417.53</td><td style = "text-align: right;">4749.83</td><td style = "text-align: right;">-1.8289</td><td style = "text-align: right;">-43.5722</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">36</td><td style = "text-align: left;">Wind - offshore (floating)</td><td style = "text-align: left;">Step Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">8417.53</td><td style = "text-align: right;">4749.83</td><td style = "text-align: right;">-1.8289</td><td style = "text-align: right;">-43.5722</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">37</td><td style = "text-align: left;">Wind</td><td style = "text-align: left;">GenCost Global NZE by 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">2825.09</td><td style = "text-align: right;">1748.31</td><td style = "text-align: right;">-1.53612</td><td style = "text-align: right;">-38.1151</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">38</td><td style = "text-align: left;">Wind</td><td style = "text-align: left;">Green Energy Exports</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">2825.09</td><td style = "text-align: right;">1748.31</td><td style = "text-align: right;">-1.53612</td><td style = "text-align: right;">-38.1151</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">39</td><td style = "text-align: left;">Wind - offshore (fixed)</td><td style = "text-align: left;">GenCost Global NZE post 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">6075.76</td><td style = "text-align: right;">3933.95</td><td style = "text-align: right;">-1.39235</td><td style = "text-align: right;">-35.2517</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">40</td><td style = "text-align: left;">Wind - offshore (fixed)</td><td style = "text-align: left;">Step Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">6075.76</td><td style = "text-align: right;">3933.95</td><td style = "text-align: right;">-1.39235</td><td style = "text-align: right;">-35.2517</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">41</td><td style = "text-align: left;">Wind</td><td style = "text-align: left;">GenCost Global NZE post 2050</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">2825.09</td><td style = "text-align: right;">1906.56</td><td style = "text-align: right;">-1.2605</td><td style = "text-align: right;">-32.5132</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">42</td><td style = "text-align: left;">Wind</td><td style = "text-align: left;">Step Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">2825.09</td><td style = "text-align: right;">1906.56</td><td style = "text-align: right;">-1.2605</td><td style = "text-align: right;">-32.5132</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">43</td><td style = "text-align: left;">Wind - offshore (floating)</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">8417.53</td><td style = "text-align: right;">5921.78</td><td style = "text-align: right;">-1.12804</td><td style = "text-align: right;">-29.6494</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">44</td><td style = "text-align: left;">Wind - offshore (floating)</td><td style = "text-align: left;">Progressive Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">8417.53</td><td style = "text-align: right;">5921.78</td><td style = "text-align: right;">-1.12804</td><td style = "text-align: right;">-29.6494</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">45</td><td style = "text-align: left;">Wind</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">2825.09</td><td style = "text-align: right;">2055.19</td><td style = "text-align: right;">-1.02111</td><td style = "text-align: right;">-27.2521</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">46</td><td style = "text-align: left;">Wind</td><td style = "text-align: left;">Progressive Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">2825.09</td><td style = "text-align: right;">2055.19</td><td style = "text-align: right;">-1.02111</td><td style = "text-align: right;">-27.2521</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">47</td><td style = "text-align: left;">Wind - offshore (fixed)</td><td style = "text-align: left;">GenCost Current Policies</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">6075.76</td><td style = "text-align: right;">4773.36</td><td style = "text-align: right;">-0.775231</td><td style = "text-align: right;">-21.4361</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">48</td><td style = "text-align: left;">Wind - offshore (fixed)</td><td style = "text-align: left;">Progressive Change</td><td style = "text-align: left;">2022-23</td><td style = "text-align: left;">2053-54</td><td style = "text-align: right;">6075.76</td><td style = "text-align: right;">4773.36</td><td style = "text-align: right;">-0.775231</td><td style = "text-align: right;">-21.4361</td></tr></tbody></table></div>
```

## Interpreting the evidence

Every matched technology's build cost falls in every scenario, but the annualized decline rate spans roughly a 5.5x range across technologies and scenarios -- from about -0.78%/yr (Wind - offshore (fixed), GenCost Current Policies / Progressive Change) to about -4.30%/yr (Battery storage 8hrs storage, GenCost Global NZE by 2050 / Green Energy Exports).
The fastest-declining technology is itself scenario-dependent, not fixed: in the two lower-decarbonization scenarios (GenCost Current Policies, Progressive Change), Large scale Solar PV declines fastest, ahead of every battery duration, with Wind - offshore (fixed) slowest; in the four higher-decarbonization scenarios (Global NZE post 2050, Global NZE by 2050, Green Energy Exports, Step Change), the longer-duration battery storage technologies decline fastest instead, with onshore Wind alone slowest in all four.
So yes, the rate of cost decline differs materially by technology, but which technology declines fastest (and slowest) is a function of the decarbonization scenario assumed, not a single fixed ranking -- see `build_cost_decline_summary` above for the exact figures behind this claim.

