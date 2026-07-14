#!/usr/bin/env julia

using CSV
using DataFrames
using XLSX
using Printf
using Statistics

const SCRIPT_STEM = "11_rez_resource_vs_cost"
const DOWNLOADS = joinpath("data", "pisp-downloads")
const IASR_WORKBOOK = joinpath(DOWNLOADS, "2024-isp-inputs-and-assumptions-workbook.xlsx")
const TABLE_ROOT = joinpath(@__DIR__, "tables")

# Question (final question 2 of tasks/done/0076-isp-2024-raw-data-eda-questions.md):
# joining Renewable Energy Zones (resource limits) to REZ Costs forecast
# (transmission-augmentation cost) by REZ identifier, do the highest-potential
# REZs also tend to be the costliest to connect, or is there no clear
# resource-vs-cost relationship -- and which REZs are the outliers?
#
# Data-grounding note: the "Renewable Energy Zones" sheet named in the
# question does NOT itself carry numeric resource limits -- it is a
# REZ-identity/geography table (ID, Name, NEM Region, NTNDP Zone, ISP
# Sub-region, a categorical "Regional Cost Zones" label). The actual
# REZ-level numeric wind/solar resource limits (MW) live on the "Build
# limits" sheet, keyed by the same REZ ID. Similarly, "REZ Costs forecast"
# holds only a multi-year escalated cost trajectory per named augmentation
# option with no capacity figure attached; the sibling "REZ Augmentations
# Options" sheet carries both the capacity increase (MW) AND a single
# reference cost ($M) for the same REZ/option identifiers, already including
# a precomputed $M/MW column. This script therefore joins "Build limits"
# (resource limits) to "REZ Augmentations Options" (capacity + cost per
# augmentation option) by REZ ID -- the two sheets that actually carry
# joinable numeric data -- rather than the two sheets named literally in the
# question, which was written before this sheet-level detail was confirmed.
#
# EDA insight (from the executed `rez_resource_vs_cost` join): of the 43 REZs
# on the "Build limits" sheet, only 23 join to a REZ that also has a
# standalone primary augmentation option with both a capacity and cost
# figure on the "REZ Augmentations Options" sheet -- the rest either have no
# option of their own (a bare cross-reference to a shared subregional/group-
# constraint augmentation, e.g. Q3 "See NQ-CQ subregional augmentations") or
# don't appear on both sheets under the same identifier. Of those 23, one
# (N12, Illawarra) carries a genuine 0 MW total resource limit in this
# workbook and is excluded from the ratio/correlation separately (a real
# modelled value, not a parsing artifact -- confirmed by direct inspection),
# leaving 22. The Pearson correlation between total resource limit (MW) and
# the primary option's expected cost ($M) is 0.016 -- essentially zero. So
# no, the highest-potential REZs do not tend to be the costliest to connect;
# resource potential and connection cost are effectively uncorrelated in this
# data. The clearest outliers on cost-per-MW efficiency: T4 (North Tasmania
# Coast) is the cheapest at $0.0051M/MW for 40,550 MW of resource, while N4
# (Broken Hill) has both the single largest expected cost of all 22 joined
# REZs ($5,098M, more than 2.7x the next-highest, Q1 at $1,836M) and a
# well-below-median efficiency ($0.432M/MW) despite an 11,800 MW resource
# limit; N8 (Cooma-Monaro) is the single least cost-efficient REZ overall
# ($1.0100M/MW, roughly 1.5x the next-worst, Q1 at $0.6534M/MW) despite a
# small 200 MW resource limit.

function table_dir(script_stem; producer = "julia", root = TABLE_ROOT)
    path = joinpath(root, producer, script_stem)
    mkpath(path)
    return path
end

function table_path(script_stem, table_name; producer = "julia", root = TABLE_ROOT)
    filename = endswith(table_name, ".csv") ? table_name : "$(table_name).csv"
    return joinpath(table_dir(script_stem; producer = producer, root = root), filename)
end

function write_table(frame::DataFrame, script_stem, table_name; producer = "julia", root = TABLE_ROOT)
    path = table_path(script_stem, table_name; producer = producer, root = root)
    CSV.write(path, frame; missingstring = "")
    println("Saved table: ", path)
    return path
end

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
# A handful of "Build limits" cells hold text rather than a bare number: "-"
# (no value; confirmed against the sheet's own dash convention elsewhere) and
# "5696 (Note 14)" (N11's offshore-floating limit, with the sheet's own inline
# footnote reference kept in the cell). The footnote itself (row 65: "Values
# shown are as per modelled. If updated to the recently declared area ...
# values would change to 0 MW fixed capacity, and 4,452 MW floating
# capacity.") is a caveat about a boundary redeclaration, not a reason to
# distrust the modelled number -- so this uses the modelled 5696 MW figure
# and keeps the footnote text out of the parsed value.
function as_float(x::AbstractString)
    stripped = strip(x)
    stripped == "-" && return missing
    m = match(r"^-?[\d,]+\.?\d*", stripped)
    m === nothing && return missing
    return parse(Float64, replace(m.match, "," => ""))
end

# "Build limits" sheet: two-row merged header (row 6 group labels, row 7 wind
# sub-labels), one row per REZ from row 8 to the last REZ row (before the
# "Notes" section). REZs with onshore wind data have High/Medium (MW)
# populated and Offshore columns missing, and vice versa for the two
# offshore-only REZs (S10, T4) -- confirmed by direct inspection.
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

# "REZ Augmentations Options" sheet: repeated region sub-header rows (bare
# region name, e.g. "QLD", with every other column missing) interleaved with
# REZ blocks. A genuine data row is any row where the Option column (6) is
# not missing; REZ ID/Name are only populated on an option's first row and
# must be forward-filled for that REZ's later options (e.g. Q1's "Option 2"
# row carries no REZ ID/Name of its own).
function load_rez_augmentation_options(matrix)
    rows = NamedTuple[]
    nrows = size(matrix, 1)
    current_id = missing
    current_name = missing
    for r in 12:nrows
        option = matrix[r, 4]
        option === missing && continue  # region sub-header or blank row
        option == "Option" && continue  # the header row repeats before every region block (rows 11, 37, 69, 93, 105)
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

# One representative option per REZ: the first-listed option in sheet order
# (typically labelled "Option 1"), the foundational augmentation that later
# options build on (many later options are explicitly "Pre-requisite:
# Option 1" in the sheet's own description text) -- excludes any REZ whose
# first-listed option has no numeric capacity or cost of its own. Most such
# exclusions are a bare cross-reference to a shared subregional/group-
# constraint augmentation (e.g. "See NQ-CQ subregional augmentations"), but a
# few (e.g. N6, N7, N10) are a literal "Option 1" whose capacity/cost cells
# are themselves blank or non-numeric in the sheet -- both cases are
# excluded here for the same reason (no usable standalone figure), not only
# the cross-reference case.
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

function main()
    println("Workbook exists: ", isfile(IASR_WORKBOOK))
    isfile(IASR_WORKBOOK) || error("IASR workbook not found at $IASR_WORKBOOK")

    resource_matrix, augmentation_matrix = XLSX.openxlsx(IASR_WORKBOOK) do xf
        trim_sheet(xf["Build limits"][:]), trim_sheet(xf["REZ Augmentations Options"][:])
    end

    resource_limits = load_rez_resource_limits(resource_matrix)
    println("REZ resource-limit rows (Build limits sheet): ", nrow(resource_limits))
    write_table(resource_limits, SCRIPT_STEM, "rez_resource_limits")

    augmentation_options = load_rez_augmentation_options(augmentation_matrix)
    println("REZ augmentation-option rows (REZ Augmentations Options sheet): ", nrow(augmentation_options))
    write_table(augmentation_options, SCRIPT_STEM, "rez_augmentation_options")

    primary_options, excluded = primary_option_per_rez(augmentation_options)
    println("REZs with a usable primary (first-listed) option: ", nrow(primary_options))
    println("REZs excluded (first-listed option has no standalone numeric capacity/cost -- a cross-reference to a shared augmentation, or a named option with blank/non-numeric figures): ", nrow(excluded))
    for row in eachrow(excluded)
        println("  excluded: ", row.rez_id, " (", row.rez_name, ") -> \"", row.option, "\"")
    end

    joined = innerjoin(resource_limits, primary_options, on = [:rez_id, :rez_name])
    println("Joined REZs (resource limit + primary augmentation option): ", nrow(joined))
    write_table(joined, SCRIPT_STEM, "rez_resource_vs_cost")

    # One REZ (N12, Illawarra) carries a genuine 0 MW total resource limit in
    # this workbook (both wind and solar limits are 0) -- a real modelled
    # value, not a parsing artifact, confirmed by direct inspection of the
    # sheet. It is excluded from the correlation and cost-per-MW ranking
    # (undefined/infinite ratio) and reported separately rather than dropped
    # silently.
    zero_resource = filter(:total_resource_limit_mw => iszero, joined)
    if nrow(zero_resource) > 0
        println("REZ(s) excluded from correlation/ranking for having a 0 MW total resource limit:")
        for row in eachrow(zero_resource)
            println("  ", row.rez_id, " (", row.rez_name, ") -- expected_cost_million=", row.expected_cost_million)
        end
        write_table(zero_resource, SCRIPT_STEM, "rez_zero_resource_limit_excluded")
    end
    joined = filter(:total_resource_limit_mw => (v -> v > 0), joined)

    correlation = pearson_correlation(joined.total_resource_limit_mw, joined.expected_cost_million)
    println(@sprintf("Pearson correlation (total resource limit MW vs. expected cost \$M), n=%d: %.3f", nrow(joined), correlation))

    joined.cost_per_resource_mw = joined.expected_cost_million ./ joined.total_resource_limit_mw
    ranked = sort(joined, :cost_per_resource_mw)
    write_table(
        select(ranked, [:rez_id, :rez_name, :total_resource_limit_mw, :expected_cost_million, :dollar_million_per_mw, :cost_per_resource_mw]),
        SCRIPT_STEM,
        "rez_cost_efficiency_ranking",
    )

    println("\n=== Most cost-efficient REZs (lowest \$M expected cost per MW of total resource limit) ===")
    for row in first(ranked, 5) |> eachrow
        @printf("  %-6s %-28s resource=%6.0f MW  cost=\$%.0fM  \$%.4fM/MW\n", row.rez_id, row.rez_name, row.total_resource_limit_mw, row.expected_cost_million, row.cost_per_resource_mw)
    end
    println("=== Least cost-efficient REZs (highest \$M expected cost per MW of total resource limit) ===")
    for row in last(ranked, 5) |> eachrow
        @printf("  %-6s %-28s resource=%6.0f MW  cost=\$%.0fM  \$%.4fM/MW\n", row.rez_id, row.rez_name, row.total_resource_limit_mw, row.expected_cost_million, row.cost_per_resource_mw)
    end

    return resource_limits, augmentation_options, joined
end

main()
