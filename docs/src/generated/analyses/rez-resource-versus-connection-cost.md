```@meta
EditURL = "../../../literate/analysis/rez_resource_versus_connection_cost.jl"
```

# REZ resource potential versus connection cost

This analysis asks whether Renewable Energy Zones (REZs) with larger workbook-derived resource potential also have higher expected connection cost, or whether resource potential and connection cost are effectively separate dimensions.

The evidence comes from the AEMO 2024 ISP Inputs and Assumptions workbook at `data/2024/pisp-downloads/2024-isp-inputs-and-assumptions-workbook.xlsx`.
The workbook sheets named most naturally for the question are not directly joinable: `Renewable Energy Zones` identifies REZ geography without numeric resource limits, while `REZ Costs forecast` gives named cost trajectories without REZ-level capacity figures.
The evidence therefore uses `Build limits` for `total_resource_limit_mw` and `REZ Augmentations Options` for the primary option's `expected_cost_million`, joined by REZ identifier and name, all computed live on this page.

No AEMO report-PDF page citation is currently verified for this specific workbook-derived join, so this page cites only the local workbook-derived evidence.

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

EdaSupport.snapshot_metadata_line(REPO_ROOT; context = "2024 ISP Inputs and Assumptions workbook, Build limits + REZ Augmentations Options")

const SCRIPT_STEM = "11_rez_resource_vs_cost"
const DOWNLOADS = joinpath("data", "2024", "pisp-downloads")  # kept relative: this is the path form recorded below
const IASR_WORKBOOK = joinpath(DOWNLOADS, "2024-isp-inputs-and-assumptions-workbook.xlsx")
abs_path(relative_path) = joinpath(REPO_ROOT, relative_path)  # resolves a DOWNLOADS-relative path to an absolute location for reading

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

as_float(x::Missing) = missing
as_float(x::Real) = Float64(x)
````

```@raw html
</details>
```

````
Snapshot: PISP.jl commit 53d7330+dirty, generated 2026-07-17 — 2024 ISP Inputs and Assumptions workbook, Build limits + REZ Augmentations Options

````

A handful of "Build limits" cells hold text rather than a bare number: "-"
(no value; confirmed against the sheet's own dash convention elsewhere) and
"5696 (Note 14)" (N11's offshore-floating limit, with the sheet's own inline
footnote reference kept in the cell). The footnote itself (row 65: "Values
shown are as per modelled. If updated to the recently declared area ...
values would change to 0 MW fixed capacity, and 4,452 MW floating
capacity.") is a caveat about a boundary redeclaration, not a reason to
distrust the modelled number -- so this uses the modelled 5696 MW figure
and keeps the footnote text out of the parsed value.

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
function as_float(x::AbstractString)
    stripped = strip(x)
    stripped == "-" && return missing
    m = match(r"^-?[\d,]+\.?\d*", stripped)
    m === nothing && return missing
    return parse(Float64, replace(m.match, "," => ""))
end
````

```@raw html
</details>
```

"Build limits" sheet: two-row merged header (row 6 group labels, row 7 wind
sub-labels), one row per REZ from row 8 to the last REZ row (before the
"Notes" section). REZs with onshore wind data have High/Medium (MW)
populated and Offshore columns missing, and vice versa for the two
offshore-only REZs (S10, T4) -- confirmed by direct inspection.

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
function load_rez_resource_limits(matrix)
    rows = NamedTuple[]
    nrows = size(matrix, 1)
    for r in 8:nrows
        rez_id = matrix[r, 2]
        rez_id === missing && break  # "Notes" section starts once REZ ID runs out
        rez_id == "Notes" && break
        push!(
            rows,
            (
                rez_id = String(rez_id),
                rez_name = matrix[r, 3] === missing ? missing : String(matrix[r, 3]),
                region = matrix[r, 4] === missing ? missing : String(matrix[r, 4]),
                wind_high_mw = as_float(matrix[r, 7]),
                wind_medium_mw = as_float(matrix[r, 8]),
                wind_offshore_fixed_mw = as_float(matrix[r, 9]),
                wind_offshore_floating_mw = as_float(matrix[r, 10]),
                solar_mw = as_float(matrix[r, 11]),
            ),
        )
    end
    df = DataFrame(rows)
    # A single wind-resource figure per REZ: onshore REZs use the more
    # permissive of the two onshore land-use assumptions (Medium, always >=
    # High in this sheet); the two offshore-only REZs (S10, T4) have
    # High/Medium at 0 and carry their resource in the offshore columns
    # instead, so those are added in (they are mutually exclusive with
    # onshore in every row observed).
    df.wind_resource_mw = [
        coalesce(row.wind_medium_mw, 0.0) +
        coalesce(row.wind_offshore_fixed_mw, 0.0) +
        coalesce(row.wind_offshore_floating_mw, 0.0) for row in eachrow(df)
    ]
    df.total_resource_limit_mw = df.wind_resource_mw .+ [coalesce(v, 0.0) for v in df.solar_mw]
    return df
end
````

```@raw html
</details>
```

"REZ Augmentations Options" sheet: repeated region sub-header rows (bare
region name, e.g. "QLD", with every other column missing) interleaved with
REZ blocks. A genuine data row is any row where the Option column (6) is
not missing; REZ ID/Name are only populated on an option's first row and
must be forward-filled for that REZ's later options (e.g. Q1's "Option 2"
row carries no REZ ID/Name of its own).

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
function load_rez_augmentation_options(matrix)
    rows = NamedTuple[]
    nrows = size(matrix, 1)
    current_id = missing
    current_name = missing
    for r in 12:nrows
        option = matrix[r, 4]
        option === missing && continue  # region sub-header or blank row
        option == "Option" && continue  # the header row repeats before every region block
        if matrix[r, 2] !== missing
            current_id = String(matrix[r, 2])
            current_name = matrix[r, 3] === missing ? missing : String(matrix[r, 3])
        end
        current_id === missing && continue
        push!(
            rows,
            (
                rez_id = current_id,
                rez_name = current_name,
                option = String(option),
                additional_capacity_mw = as_float(matrix[r, 6]),
                expected_cost_million = as_float(matrix[r, 7]),
                dollar_million_per_mw = as_float(matrix[r, 10]),
            ),
        )
    end
    return DataFrame(rows)
end
````

```@raw html
</details>
```

One representative option per REZ: the first-listed option in sheet order
(typically labelled "Option 1"), the foundational augmentation that later
options build on. Excludes any REZ whose first-listed option has no
numeric capacity or cost of its own -- most such exclusions are a bare
cross-reference to a shared subregional/group-constraint augmentation
(e.g. "See NQ-CQ subregional augmentations"), but a few are a literal
"Option 1" whose capacity/cost cells are themselves blank or non-numeric
in the sheet.

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
function primary_option_per_rez(augmentation_options)
    rows = NamedTuple[]
    excluded = NamedTuple[]
    for key_df in groupby(augmentation_options, :rez_id)
        first_row = first(key_df)
        if first_row.additional_capacity_mw === missing || first_row.expected_cost_million === missing
            push!(excluded, (rez_id = first_row.rez_id, rez_name = first_row.rez_name, option = first_row.option))
            continue
        end
        push!(
            rows,
            (
                rez_id = first_row.rez_id,
                rez_name = first_row.rez_name,
                primary_option = first_row.option,
                additional_capacity_mw = first_row.additional_capacity_mw,
                expected_cost_million = first_row.expected_cost_million,
                dollar_million_per_mw = first_row.dollar_million_per_mw,
            ),
        )
    end
    return DataFrame(rows), DataFrame(excluded)
end

function pearson_correlation(x, y)
    n = length(x)
    mx, my = mean(x), mean(y)
    cov_xy = sum((x .- mx) .* (y .- my)) / (n - 1)
    sx, sy = std(x), std(y)
    return cov_xy / (sx * sy)
end

function rounded_columns(frame, columns; digits = 3)
    copy_frame = copy(frame)
    for column in columns
        copy_frame[!, column] = round.(copy_frame[!, column]; digits = digits)
    end
    return copy_frame
end
````

```@raw html
</details>
```

## Step 1 — load and trim the "Build limits" and "REZ Augmentations Options" sheets

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
println("Workbook exists: ", isfile(abs_path(IASR_WORKBOOK)))
isfile(abs_path(IASR_WORKBOOK)) || error("IASR workbook not found at $IASR_WORKBOOK")

resource_matrix, augmentation_matrix = XLSX.openxlsx(abs_path(IASR_WORKBOOK)) do xf
    trim_sheet(xf["Build limits"][:]), trim_sheet(xf["REZ Augmentations Options"][:])
end
````

```@raw html
</details>
```

````
Workbook exists: true

````

## Step 2 — resource limits and augmentation options per REZ

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
resource_limits = load_rez_resource_limits(resource_matrix)
write_table(resource_limits, SCRIPT_STEM, "rez_resource_limits")
println("REZ resource-limit rows (Build limits sheet): ", nrow(resource_limits))
first(resource_limits, 8)
````

```@raw html
</details>
```

```@raw html
<div><div style = "float: left;"><span>8×10 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">rez_id</th><th style = "text-align: left;">rez_name</th><th style = "text-align: left;">region</th><th style = "text-align: left;">wind_high_mw</th><th style = "text-align: left;">wind_medium_mw</th><th style = "text-align: left;">wind_offshore_fixed_mw</th><th style = "text-align: left;">wind_offshore_floating_mw</th><th style = "text-align: left;">solar_mw</th><th style = "text-align: left;">wind_resource_mw</th><th style = "text-align: left;">total_resource_limit_mw</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">Q1</td><td style = "text-align: left;">Far North QLD</td><td style = "text-align: left;">QLD</td><td style = "text-align: right;">570.0</td><td style = "text-align: right;">1710.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">1100.0</td><td style = "text-align: right;">1710.0</td><td style = "text-align: right;">2810.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">Q2</td><td style = "text-align: left;">North Qld Clean Energy Hub</td><td style = "text-align: left;">QLD</td><td style = "text-align: right;">4700.0</td><td style = "text-align: right;">13900.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">8000.0</td><td style = "text-align: right;">13900.0</td><td style = "text-align: right;">21900.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">Q3</td><td style = "text-align: left;">Northern Qld</td><td style = "text-align: left;">QLD</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">0.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">3400.0</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">3400.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">Q4</td><td style = "text-align: left;">Isaac</td><td style = "text-align: left;">QLD</td><td style = "text-align: right;">1000.0</td><td style = "text-align: right;">2800.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">6900.0</td><td style = "text-align: right;">2800.0</td><td style = "text-align: right;">9700.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">Q5</td><td style = "text-align: left;">Barcaldine</td><td style = "text-align: left;">QLD</td><td style = "text-align: right;">1000.0</td><td style = "text-align: right;">2900.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">8000.0</td><td style = "text-align: right;">2900.0</td><td style = "text-align: right;">10900.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">Q6</td><td style = "text-align: left;">Fitzroy</td><td style = "text-align: left;">QLD</td><td style = "text-align: right;">900.0</td><td style = "text-align: right;">2600.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">7533.0</td><td style = "text-align: right;">2600.0</td><td style = "text-align: right;">10133.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">Q7</td><td style = "text-align: left;">Wide Bay</td><td style = "text-align: left;">QLD</td><td style = "text-align: right;">300.0</td><td style = "text-align: right;">800.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">2200.0</td><td style = "text-align: right;">800.0</td><td style = "text-align: right;">3000.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">Q8</td><td style = "text-align: left;">Darling Downs</td><td style = "text-align: left;">QLD</td><td style = "text-align: right;">1400.0</td><td style = "text-align: right;">4200.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">6992.0</td><td style = "text-align: right;">4200.0</td><td style = "text-align: right;">11192.0</td></tr></tbody></table></div>
```

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
augmentation_options = load_rez_augmentation_options(augmentation_matrix)
write_table(augmentation_options, SCRIPT_STEM, "rez_augmentation_options")
println("REZ augmentation-option rows (REZ Augmentations Options sheet): ", nrow(augmentation_options))
first(augmentation_options, 8)
````

```@raw html
</details>
```

```@raw html
<div><div style = "float: left;"><span>8×6 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">rez_id</th><th style = "text-align: left;">rez_name</th><th style = "text-align: left;">option</th><th style = "text-align: left;">additional_capacity_mw</th><th style = "text-align: left;">expected_cost_million</th><th style = "text-align: left;">dollar_million_per_mw</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">Q1</td><td style = "text-align: left;">Far North QLD</td><td style = "text-align: left;">Option 1</td><td style = "text-align: right;">1290.0</td><td style = "text-align: right;">1836.0</td><td style = "text-align: right;">1.42326</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">Q1</td><td style = "text-align: left;">Far North QLD</td><td style = "text-align: left;">Option 2</td><td style = "text-align: right;">1290.0</td><td style = "text-align: right;">2780.0</td><td style = "text-align: right;">2.15504</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">Q2</td><td style = "text-align: left;">North Qld Clean Energy Hub</td><td style = "text-align: left;">CopperString</td><td style = "text-align: right;">1500.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">Q2</td><td style = "text-align: left;">North Qld Clean Energy Hub</td><td style = "text-align: left;">Option 1</td><td style = "text-align: right;">500.0</td><td style = "text-align: right;">651.0</td><td style = "text-align: right;">0.434</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">Q2</td><td style = "text-align: left;">North Qld Clean Energy Hub</td><td style = "text-align: left;">Option 2</td><td style = "text-align: right;">1000.0</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">Q3</td><td style = "text-align: left;">Northern Qld</td><td style = "text-align: left;">See NQ-CQ subregional augmentations</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">Q4</td><td style = "text-align: left;">Isaac</td><td style = "text-align: left;">See NQ2 group constraint augmentations</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">Q5</td><td style = "text-align: left;">Barcaldine</td><td style = "text-align: left;">Option 1</td><td style = "text-align: right;">500.0</td><td style = "text-align: right;">1068.0</td><td style = "text-align: right;">0.791111</td></tr></tbody></table></div>
```

## Step 3 — primary option per REZ and the resource-vs-cost join

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
primary_options, excluded = primary_option_per_rez(augmentation_options)
write_table(excluded, SCRIPT_STEM, "rez_augmentation_excluded")
println("REZs with a usable primary (first-listed) option: ", nrow(primary_options))
println("REZs excluded (first-listed option has no standalone numeric capacity/cost -- a cross-reference to a shared augmentation, or a named option with blank/non-numeric figures): ", nrow(excluded))
excluded
````

```@raw html
</details>
```

```@raw html
<div><div style = "float: left;"><span>19×3 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">rez_id</th><th style = "text-align: left;">rez_name</th><th style = "text-align: left;">option</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">Q2</td><td style = "text-align: left;">North Qld Clean Energy Hub</td><td style = "text-align: left;">CopperString</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">Q3</td><td style = "text-align: left;">Northern Qld</td><td style = "text-align: left;">See NQ-CQ subregional augmentations</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">Q4</td><td style = "text-align: left;">Isaac</td><td style = "text-align: left;">See NQ2 group constraint augmentations</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">Q6</td><td style = "text-align: left;">Fitzroy</td><td style = "text-align: left;">See CQ-GG subregional augmentations</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">Q7</td><td style = "text-align: left;">Wide Bay</td><td style = "text-align: left;">See SQ1 group constraint augmentations</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">Q8</td><td style = "text-align: left;">Darling Downs</td><td style = "text-align: left;">See SWQLD1 Transmission Limit constraint augmentations</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">N3</td><td style = "text-align: left;">Central-West Orana</td><td style = "text-align: left;">Central West Orana REZ transmission link</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">N6</td><td style = "text-align: left;">Wagga Wagga</td><td style = "text-align: left;">Option 1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">9</td><td style = "text-align: left;">N7</td><td style = "text-align: left;">Tumut</td><td style = "text-align: left;">Option 1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">10</td><td style = "text-align: left;">N10</td><td style = "text-align: left;">Hunter Coast</td><td style = "text-align: left;">Option 1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">11</td><td style = "text-align: left;">S1</td><td style = "text-align: left;">South East SA</td><td style = "text-align: left;">See S1-TBMO transmission limit constraint augmentation and VIC-SESA and SESA-SA sub-regional augmentations</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">12</td><td style = "text-align: left;">S3</td><td style = "text-align: left;">Mid-North SA</td><td style = "text-align: left;">See MN1 group constraint augmentations</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">13</td><td style = "text-align: left;">S5</td><td style = "text-align: left;">Northern SA</td><td style = "text-align: left;">See NSA1 group constraint augmentations</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">14</td><td style = "text-align: left;">S10</td><td style = "text-align: left;">South East SA Coast</td><td style = "text-align: left;">See VIC-SESA and SESA-SA sub-regional augmentations</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">15</td><td style = "text-align: left;">V3</td><td style = "text-align: left;">Western Victoria</td><td style = "text-align: left;">See V3-EAST secondary transmission limit constraint augmentations</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">16</td><td style = "text-align: left;">V4</td><td style = "text-align: left;">South West Victoria</td><td style = "text-align: left;">See SWV1 group constraint augmentations</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">17</td><td style = "text-align: left;">V5</td><td style = "text-align: left;">Gippsland</td><td style = "text-align: left;">See SEVIC1 transmission limit constraint augmentations</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">18</td><td style = "text-align: left;">V8</td><td style = "text-align: left;">Southern Ocean</td><td style = "text-align: left;">See SWV1 group constraint augmentations</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">19</td><td style = "text-align: left;">SWV1</td><td style = "text-align: left;">Group Constraint - South West Victoria</td><td style = "text-align: left;">Option 1</td></tr></tbody></table></div>
```

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
joined = innerjoin(resource_limits, primary_options, on = [:rez_id, :rez_name])
joined_row_count = nrow(joined)
write_table(joined, SCRIPT_STEM, "rez_resource_vs_cost")
println("Joined REZs (resource limit + primary augmentation option): ", joined_row_count)
first(joined, 8)
````

```@raw html
</details>
```

```@raw html
<div><div style = "float: left;"><span>8×14 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">rez_id</th><th style = "text-align: left;">rez_name</th><th style = "text-align: left;">region</th><th style = "text-align: left;">wind_high_mw</th><th style = "text-align: left;">wind_medium_mw</th><th style = "text-align: left;">wind_offshore_fixed_mw</th><th style = "text-align: left;">wind_offshore_floating_mw</th><th style = "text-align: left;">solar_mw</th><th style = "text-align: left;">wind_resource_mw</th><th style = "text-align: left;">total_resource_limit_mw</th><th style = "text-align: left;">primary_option</th><th style = "text-align: left;">additional_capacity_mw</th><th style = "text-align: left;">expected_cost_million</th><th style = "text-align: left;">dollar_million_per_mw</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">Q1</td><td style = "text-align: left;">Far North QLD</td><td style = "text-align: left;">QLD</td><td style = "text-align: right;">570.0</td><td style = "text-align: right;">1710.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">1100.0</td><td style = "text-align: right;">1710.0</td><td style = "text-align: right;">2810.0</td><td style = "text-align: left;">Option 1</td><td style = "text-align: right;">1290.0</td><td style = "text-align: right;">1836.0</td><td style = "text-align: right;">1.42326</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">Q5</td><td style = "text-align: left;">Barcaldine</td><td style = "text-align: left;">QLD</td><td style = "text-align: right;">1000.0</td><td style = "text-align: right;">2900.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">8000.0</td><td style = "text-align: right;">2900.0</td><td style = "text-align: right;">10900.0</td><td style = "text-align: left;">Option 1</td><td style = "text-align: right;">500.0</td><td style = "text-align: right;">1068.0</td><td style = "text-align: right;">0.791111</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">Q9</td><td style = "text-align: left;">Banana</td><td style = "text-align: left;">QLD</td><td style = "text-align: right;">900.0</td><td style = "text-align: right;">2500.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">6100.0</td><td style = "text-align: right;">2500.0</td><td style = "text-align: right;">8600.0</td><td style = "text-align: left;">Option 1</td><td style = "text-align: right;">3000.0</td><td style = "text-align: right;">1078.0</td><td style = "text-align: right;">0.359333</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">N2</td><td style = "text-align: left;">New England</td><td style = "text-align: left;">NSW</td><td style = "text-align: right;">1800.0</td><td style = "text-align: right;">5600.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">2985.0</td><td style = "text-align: right;">5600.0</td><td style = "text-align: right;">8585.0</td><td style = "text-align: left;">Option 1</td><td style = "text-align: right;">1000.0</td><td style = "text-align: right;">370.0</td><td style = "text-align: right;">0.37</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">N4</td><td style = "text-align: left;">Broken Hill</td><td style = "text-align: left;">NSW</td><td style = "text-align: right;">1300.0</td><td style = "text-align: right;">3800.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">8000.0</td><td style = "text-align: right;">3800.0</td><td style = "text-align: right;">11800.0</td><td style = "text-align: left;">Option 1</td><td style = "text-align: right;">1750.0</td><td style = "text-align: right;">5098.0</td><td style = "text-align: right;">2.91314</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">N5</td><td style = "text-align: left;">South West NSW</td><td style = "text-align: left;">NSW</td><td style = "text-align: right;">1000.0</td><td style = "text-align: right;">2900.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">2256.0</td><td style = "text-align: right;">2900.0</td><td style = "text-align: right;">5156.0</td><td style = "text-align: left;">Option 1</td><td style = "text-align: right;">2500.0</td><td style = "text-align: right;">1418.0</td><td style = "text-align: right;">0.5672</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">N8</td><td style = "text-align: left;">Cooma-Monaro</td><td style = "text-align: left;">NSW</td><td style = "text-align: right;">100.0</td><td style = "text-align: right;">200.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">200.0</td><td style = "text-align: right;">200.0</td><td style = "text-align: left;">Option 1</td><td style = "text-align: right;">150.0</td><td style = "text-align: right;">202.0</td><td style = "text-align: right;">1.34667</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">N9</td><td style = "text-align: left;">Hunter-Central Coast</td><td style = "text-align: left;">NSW</td><td style = "text-align: right;">400.0</td><td style = "text-align: right;">1000.0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "text-align: right;">516.0</td><td style = "text-align: right;">1000.0</td><td style = "text-align: right;">1516.0</td><td style = "text-align: left;">Option 1</td><td style = "text-align: right;">950.0</td><td style = "text-align: right;">307.0</td><td style = "text-align: right;">0.323158</td></tr></tbody></table></div>
```

## Step 4 — zero-resource exclusion, correlation, and cost-efficiency ranking

One REZ (N12, Illawarra) carries a genuine 0 MW total resource limit in this workbook (both wind and solar limits are 0) -- a real modelled value, not a parsing artifact, confirmed by direct inspection of the sheet. It is excluded from the correlation and cost-per-MW ranking (undefined/infinite ratio) and reported separately rather than dropped silently.

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
zero_resource_rez = filter(:total_resource_limit_mw => iszero, joined)
zero_resource_exclusion_count = nrow(zero_resource_rez)
zero_resource_exclusion_count > 0 && write_table(zero_resource_rez, SCRIPT_STEM, "rez_zero_resource_limit_excluded")
joined = filter(:total_resource_limit_mw => (v -> v > 0), joined)
zero_resource_rez[:, [:rez_id, :rez_name, :total_resource_limit_mw, :expected_cost_million]]
````

```@raw html
</details>
```

```@raw html
<div><div style = "float: left;"><span>1×4 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">rez_id</th><th style = "text-align: left;">rez_name</th><th style = "text-align: left;">total_resource_limit_mw</th><th style = "text-align: left;">expected_cost_million</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">N12</td><td style = "text-align: left;">Illawarra</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">814.0</td></tr></tbody></table></div>
```

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
correlation = pearson_correlation(joined.total_resource_limit_mw, joined.expected_cost_million)
correlation_summary = DataFrame(
    method = ["Pearson correlation"],
    coefficient = [correlation],
    usable_row_count = [nrow(joined)],
    zero_resource_exclusion_count = [zero_resource_exclusion_count],
    joined_row_count = [joined_row_count],
    source_column_x = ["total_resource_limit_mw"],
    source_column_y = ["expected_cost_million"],
)
write_table(correlation_summary, SCRIPT_STEM, "rez_resource_cost_correlation_summary")
correlation_summary
````

```@raw html
</details>
```

```@raw html
<div><div style = "float: left;"><span>1×7 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">method</th><th style = "text-align: left;">coefficient</th><th style = "text-align: left;">usable_row_count</th><th style = "text-align: left;">zero_resource_exclusion_count</th><th style = "text-align: left;">joined_row_count</th><th style = "text-align: left;">source_column_x</th><th style = "text-align: left;">source_column_y</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">Pearson correlation</td><td style = "text-align: right;">0.0159535</td><td style = "text-align: right;">22</td><td style = "text-align: right;">1</td><td style = "text-align: right;">23</td><td style = "text-align: left;">total_resource_limit_mw</td><td style = "text-align: left;">expected_cost_million</td></tr></tbody></table></div>
```

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
joined.cost_per_resource_mw = joined.expected_cost_million ./ joined.total_resource_limit_mw
ranking = sort(joined, :cost_per_resource_mw)
ranking = select(ranking, [:rez_id, :rez_name, :total_resource_limit_mw, :expected_cost_million, :dollar_million_per_mw, :cost_per_resource_mw])
write_table(ranking, SCRIPT_STEM, "rez_cost_efficiency_ranking")
nrow(ranking)
````

```@raw html
</details>
```

````
22
````

Lowest cost per MW of workbook-derived resource potential:

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
first(rounded_columns(ranking, [:cost_per_resource_mw]; digits = 4), 6)
````

```@raw html
</details>
```

```@raw html
<div><div style = "float: left;"><span>6×6 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">rez_id</th><th style = "text-align: left;">rez_name</th><th style = "text-align: left;">total_resource_limit_mw</th><th style = "text-align: left;">expected_cost_million</th><th style = "text-align: left;">dollar_million_per_mw</th><th style = "text-align: left;">cost_per_resource_mw</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">T4</td><td style = "text-align: left;">North Tasmania Coast</td><td style = "text-align: right;">40550.0</td><td style = "text-align: right;">206.0</td><td style = "text-align: right;">0.151471</td><td style = "text-align: right;">0.0051</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">V7</td><td style = "text-align: left;">Gippsland Coast</td><td style = "text-align: right;">59996.0</td><td style = "text-align: right;">684.0</td><td style = "text-align: right;">0.342</td><td style = "text-align: right;">0.0114</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">S8</td><td style = "text-align: left;">Eastern Eyre Peninsula</td><td style = "text-align: right;">6700.0</td><td style = "text-align: right;">100.0</td><td style = "text-align: right;">0.333333</td><td style = "text-align: right;">0.0149</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">S2</td><td style = "text-align: left;">Riverland</td><td style = "text-align: right;">5000.0</td><td style = "text-align: right;">100.0</td><td style = "text-align: right;">0.142857</td><td style = "text-align: right;">0.02</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">N2</td><td style = "text-align: left;">New England</td><td style = "text-align: right;">8585.0</td><td style = "text-align: right;">370.0</td><td style = "text-align: right;">0.37</td><td style = "text-align: right;">0.0431</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">T3</td><td style = "text-align: left;">Central Highlands</td><td style = "text-align: right;">2650.0</td><td style = "text-align: right;">201.0</td><td style = "text-align: right;">0.628986</td><td style = "text-align: right;">0.0758</td></tr></tbody></table></div>
```

Highest cost per MW of workbook-derived resource potential:

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
last(rounded_columns(ranking, [:cost_per_resource_mw]; digits = 4), 6)
````

```@raw html
</details>
```

```@raw html
<div><div style = "float: left;"><span>6×6 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">rez_id</th><th style = "text-align: left;">rez_name</th><th style = "text-align: left;">total_resource_limit_mw</th><th style = "text-align: left;">expected_cost_million</th><th style = "text-align: left;">dollar_million_per_mw</th><th style = "text-align: left;">cost_per_resource_mw</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">N5</td><td style = "text-align: left;">South West NSW</td><td style = "text-align: right;">5156.0</td><td style = "text-align: right;">1418.0</td><td style = "text-align: right;">0.5672</td><td style = "text-align: right;">0.275</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">T1</td><td style = "text-align: left;">North East Tasmania</td><td style = "text-align: right;">1300.0</td><td style = "text-align: right;">400.0</td><td style = "text-align: right;">0.5</td><td style = "text-align: right;">0.3077</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">N4</td><td style = "text-align: left;">Broken Hill</td><td style = "text-align: right;">11800.0</td><td style = "text-align: right;">5098.0</td><td style = "text-align: right;">2.91314</td><td style = "text-align: right;">0.432</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">S4</td><td style = "text-align: left;">Yorke Peninsula</td><td style = "text-align: right;">1000.0</td><td style = "text-align: right;">566.0</td><td style = "text-align: right;">1.25778</td><td style = "text-align: right;">0.566</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">Q1</td><td style = "text-align: left;">Far North QLD</td><td style = "text-align: right;">2810.0</td><td style = "text-align: right;">1836.0</td><td style = "text-align: right;">1.42326</td><td style = "text-align: right;">0.6534</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">N8</td><td style = "text-align: left;">Cooma-Monaro</td><td style = "text-align: right;">200.0</td><td style = "text-align: right;">202.0</td><td style = "text-align: right;">1.34667</td><td style = "text-align: right;">1.01</td></tr></tbody></table></div>
```

## Interpreting the evidence

```@raw html
<details class="source-code"><summary>Show source code</summary>
```

````julia
coefficient = only(correlation_summary.coefficient)
usable_rows = only(correlation_summary.usable_row_count)
joined_rows = only(correlation_summary.joined_row_count)
zero_exclusions = only(correlation_summary.zero_resource_exclusion_count)
most_cost_efficient = first(ranking)
least_cost_efficient = last(ranking)
largest_expected_cost = ranking[argmax(ranking.expected_cost_million), :]

@printf(
    "Pearson coefficient %.3f from %d usable rows (%d joined rows, %d zero-resource exclusion).\n",
    coefficient,
    usable_rows,
    joined_rows,
    zero_exclusions,
)
@printf(
    "Largest expected cost: %s (%s), \$%.0fM.\n",
    largest_expected_cost.rez_id,
    largest_expected_cost.rez_name,
    largest_expected_cost.expected_cost_million,
)
@printf(
    "Most cost-efficient: %s (%s), %.4f \$M per MW of resource.\n",
    most_cost_efficient.rez_id,
    most_cost_efficient.rez_name,
    most_cost_efficient.cost_per_resource_mw,
)
@printf(
    "Least cost-efficient: %s (%s), %.4f \$M per MW of resource.\n",
    least_cost_efficient.rez_id,
    least_cost_efficient.rez_name,
    least_cost_efficient.cost_per_resource_mw,
)
````

```@raw html
</details>
```

````
Pearson coefficient 0.016 from 22 usable rows (23 joined rows, 1 zero-resource exclusion).
Largest expected cost: N4 (Broken Hill), $5098M.
Most cost-efficient: T4 (North Tasmania Coast), 0.0051 $M per MW of resource.
Least cost-efficient: N8 (Cooma-Monaro), 1.0100 $M per MW of resource.

````

A Pearson coefficient of 0.016 across 22 usable REZ rows is effectively zero for this workbook-derived join: the REZs with the highest resource potential do not also tend to have the highest primary-option expected connection cost.
The join contains 23 rows before ratio/correlation filtering, and N12 (Illawarra) is the single excluded zero-resource row; it remains visible in the evidence because its `0 MW` resource limit is part of the workbook-derived data and makes a finite cost-per-resource ratio undefined.
N4 (Broken Hill) has the largest expected cost at \$5,098M, while T4 (North Tasmania Coast) is the most cost-efficient joined REZ at about \$0.0051M per MW of resource.
N8 (Cooma-Monaro) is the least cost-efficient joined REZ at \$1.0100M per MW of resource.

The main limitation is source structure: this is not a direct join between `Renewable Energy Zones` and `REZ Costs forecast`, because those sheets do not contain the numeric fields needed for the question.
The result should therefore be interpreted as a workbook-derived comparison between REZ resource limits and first-listed standalone augmentation-option cost, not as a complete cost-benefit assessment of every possible augmentation pathway.

