abstract type ISPRelease end

struct ISP2024 <: ISPRelease end
struct ISP2026 <: ISPRelease end

release_year(release::ISPRelease) = _release_interface_error(:release_year, release)
release_year(::ISP2024) = 2024
release_year(::ISP2026) = 2026

release_name(release::ISPRelease) = "ISP$(release_year(release))"

function _release_interface_error(method::Symbol, release::ISPRelease)
    reltype = typeof(release)
    throw(ArgumentError(
        "Release $(reltype) does not implement `$(method)`. " *
        "Add a release-specific method for `$(method)(::$(reltype))`."
    ))
end

build_datasets(release::ISPRelease; kwargs...) = _release_interface_error(:build_datasets, release)
download_source_files(release::ISPRelease, downloadpath::AbstractString; kwargs...) =
    _release_interface_error(:download_source_files, release)
inspect_sources(release::ISPRelease, downloadpath::AbstractString; kwargs...) =
    _release_interface_error(:inspect_sources, release)
prepare_sources(release::ISPRelease, downloadpath::AbstractString; kwargs...) =
    _release_interface_error(:prepare_sources, release)

default_data_paths(release::ISPRelease, root::AbstractString) =
    _release_interface_error(:default_data_paths, release)
legacy_data_paths(release::ISPRelease, paths::NamedTuple) =
    _release_interface_error(:legacy_data_paths, release)
source_targets(release::ISPRelease) = _release_interface_error(:source_targets, release)
validate_sources(release::ISPRelease, paths::NamedTuple) =
    _release_interface_error(:validate_sources, release)

scenario_definitions(release::ISPRelease) = _release_interface_error(:scenario_definitions, release)
scenario_id_labels(release::ISPRelease) = _release_interface_error(:scenario_id_labels, release)
demand_scenario_labels(release::ISPRelease) = _release_interface_error(:demand_scenario_labels, release)
hydro_scenario_labels(release::ISPRelease) = _release_interface_error(:hydro_scenario_labels, release)
weather_year_mapping(release::ISPRelease) = _release_interface_error(:weather_year_mapping, release)
capacity_reductions(release::ISPRelease) = _release_interface_error(:capacity_reductions, release)
generator_retirements(release::ISPRelease) = _release_interface_error(:generator_retirements, release)
populate_static!(release::ISPRelease, ts, tv, paths; kwargs...) =
    _release_interface_error(:populate_static!, release)
populate_varying!(release::ISPRelease, tc, ts, tv, paths, static_artifacts; kwargs...) =
    _release_interface_error(:populate_varying!, release)

prepare_outlook_aux(::ISPRelease, paths; kwargs...) = nothing
build_reference_traces(::ISPRelease, paths; kwargs...) = nothing
apply_release_fixes!(::ISPRelease, data; kwargs...) = data
