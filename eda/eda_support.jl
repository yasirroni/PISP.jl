module EdaSupport

using CSV
using DataFrames
using Dates
using Pkg

export TABLE_ROOT, FIGURE_ROOT, table_dir, table_path, write_table, figure_dir, figure_path, snapshot_metadata_line

const TABLE_ROOT = joinpath(normpath(joinpath(@__DIR__, "..")), "eda", "tables")
const FIGURE_ROOT = joinpath(normpath(joinpath(@__DIR__, "..")), "eda", "figures")

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

function figure_dir(script_stem; producer = "julia", root = FIGURE_ROOT)
    path = joinpath(root, producer, script_stem)
    mkpath(path)
    return path
end

function figure_path(script_stem, figure_name; producer = "julia", root = FIGURE_ROOT)
    filename = endswith(figure_name, ".png") ? figure_name : "$(figure_name).png"
    return joinpath(figure_dir(script_stem; producer = producer, root = root), filename)
end

function pisp_git_revision(repo_root)
    try
        sha = strip(read(`git -C $(repo_root) rev-parse --short HEAD`, String))
        dirty = !isempty(strip(read(`git -C $(repo_root) status --porcelain`, String)))
        return dirty ? "$(sha)+dirty" : sha
    catch
        return "unknown"
    end
end

# Prints a portable, machine-path-free provenance line for a snapshot page:
# the PISP.jl commit this analysis was generated from, the generation date,
# and a short description of which dated source or generated-data build the
# page describes (e.g. "2024 ISP raw trace downloads", "schedule-2030
# generated output"). Does not print REPO_ROOT or any other absolute path.
function snapshot_metadata_line(repo_root; context = "")
    sha = pisp_git_revision(repo_root)
    generated = Dates.format(Dates.today(), "yyyy-mm-dd")
    suffix = isempty(context) ? "" : " — $(context)"
    println("Snapshot: PISP.jl commit $(sha), generated $(generated)$(suffix)")
    return nothing
end

end # module EdaSupport
