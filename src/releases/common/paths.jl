function default_data_paths(::ISP2024, root::AbstractString)
    base = normpath(root)
    return (
        inputs_workbook = normpath(base, "2024-isp-inputs-and-assumptions-workbook.xlsx"),
        legacy_inputs_workbook = normpath(base, "2019-input-and-assumptions-workbook-v1-3-dec-19.xlsx"),
        ev_inputs_workbook = normpath(base, "2023-iasr-ev-workbook.xlsx"),
        isp_model_dir = normpath(base, "2024 ISP Model"),
        trace_dir = normpath(base, "Traces"),
        core_outlook_dir = normpath(base, "Core"),
        capacity_outlook_workbook = normpath(base, "Auxiliary", "CapacityOutlook2024_Condensed.xlsx"),
        storage_capacity_outlook_workbook = normpath(base, "Auxiliary", "StorageCapacityOutlook_2024_ISP.xlsx"),
        storage_energy_outlook_workbook = normpath(base, "Auxiliary", "StorageEnergyOutlook_2024_ISP.xlsx"),
    )
end

function default_data_paths(::ISP2026, root::AbstractString)
    base = normpath(root)
    inputs_workbook = normpath(base, "2026-isp-inputs-and-assumptions-workbook.xlsm")
    return (
        inputs_workbook = inputs_workbook,
        legacy_inputs_workbook = inputs_workbook,
        ev_inputs_workbook = normpath(base, "aemo-2025-iasr-ev-workbook.xlsx"),
        outlook_generation_storage_zip = normpath(base, "2026-isp-generation-and-storage-outlook.zip"),
        isp_model_zip = normpath(base, "2026-isp-model.zip"),
        solar_traces_zip = normpath(base, "zip", "Traces", "2026-isp-solar-traces.zip"),
        wind_traces_zip = normpath(base, "zip", "Traces", "2026-isp-wind-traces.zip"),
        isp_model_dir = normpath(base, "2026 ISP Model"),
        trace_dir = normpath(base, "Traces"),
        core_outlook_dir = normpath(base, "Core"),
        capacity_outlook_workbook = normpath(base, "Auxiliary", "CapacityOutlook2026_Condensed.xlsx"),
        storage_capacity_outlook_workbook = normpath(base, "Auxiliary", "StorageCapacityOutlook_2026_ISP.xlsx"),
        storage_energy_outlook_workbook = normpath(base, "Auxiliary", "StorageEnergyOutlook_2026_ISP.xlsx"),
    )
end

function legacy_data_paths(::ISP2024, paths::NamedTuple)
    return (
        ispdata19 = paths.legacy_inputs_workbook,
        ispdata24 = paths.inputs_workbook,
        iasr23_ev_workbook = paths.ev_inputs_workbook,
        ispmodel = paths.isp_model_dir,
        profiledata = paths.trace_dir,
        outlookdata = paths.core_outlook_dir,
        outlookAEMO = paths.capacity_outlook_workbook,
        vpp_cap = paths.storage_capacity_outlook_workbook,
        vpp_ene = paths.storage_energy_outlook_workbook,
    )
end

function legacy_data_paths(::ISP2026, paths::NamedTuple)
    return (
        ispdata26 = paths.inputs_workbook,
        outlook_generation_storage = paths.outlook_generation_storage_zip,
        ispmodel_zip = paths.isp_model_zip,
        solar_traces_zip = paths.solar_traces_zip,
        wind_traces_zip = paths.wind_traces_zip,
        ispmodel = paths.isp_model_dir,
        ispdata24 = paths.inputs_workbook,
        ispdata19 = paths.inputs_workbook,
        iasr23_ev_workbook = paths.inputs_workbook,
        profiledata = paths.trace_dir,
        outlookdata = paths.core_outlook_dir,
        outlookAEMO = paths.capacity_outlook_workbook,
        vpp_cap = paths.storage_capacity_outlook_workbook,
        vpp_ene = paths.storage_energy_outlook_workbook,
    )
end
