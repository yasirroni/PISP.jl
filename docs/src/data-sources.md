# Data sources

PISP's 2024 build path is source-specific. It downloads and parses a defined set of public AEMO files, then combines them with package constants and mapping tables. This page describes what the code is configured to use; it is not an independent audit that the URLs still point to the newest AEMO revisions.

## Encoded download targets

The file downloader in `src/scrappers/PISP-scrapper-2024files.jl` defines these fixed targets:

| Key | Encoded title | Local filename |
|---|---|---|
| `:isp24_inputs` | 2024 ISP Inputs and Assumptions workbook | `2024-isp-inputs-and-assumptions-workbook.xlsx` |
| `:iasr23_ev_workbook` | 2023 IASR EV workbook | `2023-iasr-ev-workbook.xlsx` |
| `:isp24_model` | 2024 ISP Model | `2024-isp-model.zip` |
| `:isp24_outlook` | 2024 ISP generation and storage outlook | `2024-isp-generation-and-storage-outlook.zip` |
| `:isp19_inputs_v13` | 2019 input and assumptions workbook v1.3 | `2019-input-and-assumptions-workbook-v1-3-dec-19.xlsx` |

The 2019 workbook is a targeted secondary input used for minimum up/down-time information for a subset of older thermal units. It does not make PISP a general 2019 ISP parser.

## Trace downloads

The trace downloader in `src/scrappers/PISP-scrapper-2024traces.jl` scrapes the 2024 ISP publication page using the CSS selector `div.field-link a`, then keeps links whose URL contains one of these substrings:

| Link filter | Intended trace family |
|---|---|
| `isp_demand_traces_` | Demand traces. |
| `isp_solar_traces_` | Solar traces. |
| `isp_wind_traces_` | Wind traces. |

Downloaded trace files are named from the link text, sanitised, suffixed with `.zip` if necessary, and prefixed with a two-digit download index. The default trace output directory in the scraper module is `scrapped/ISP_2024_traces`.

## Expected local input layout

`PISP.default_data_paths(filepath = downloadpath)` expects the downloaded/extracted files under a single input root. The important paths are:

| Path under `downloadpath` | Used for |
|---|---|
| `2019-input-and-assumptions-workbook-v1-3-dec-19.xlsx` | Legacy minimum up/down-time input for selected units. |
| `2024-isp-inputs-and-assumptions-workbook.xlsx` | Main 2024 workbook. |
| `2023-iasr-ev-workbook.xlsx` | EV-related input. |
| `2024 ISP Model/` | ISP model files, including hydro inflow data. |
| `Traces/` | Demand, solar, and wind profile traces. |
| `Core/` | Core generation/storage outlook material. |
| `Auxiliary/CapacityOutlook2024_Condensed.xlsx` | Condensed capacity outlook. |
| `Auxiliary/StorageCapacityOutlook_2024_ISP.xlsx` | VPP/storage capacity input. |
| `Auxiliary/StorageEnergyOutlook_2024_ISP.xlsx` | VPP/storage energy input. |

## Source use by output table

The static and schedule tables draw from different source families:

| Output area | Main source role |
|---|---|
| `Bus` | Package constants: bus names, coordinates, and area map. |
| `Demand` | Static placeholder rows from package logic; hourly load from demand traces. |
| `Line` | Network capability, reliability, and augmentation data from the 2024 Inputs and Assumptions workbook. |
| `Generator` | Existing-generator, capacity, mapping, and reliability sheets from the 2024 workbook; solar/wind schedules also use outlook and trace files; hydro inflows use ISP model data. |
| `ESS` | Storage properties, capacities, mappings, reliability data, outlook inputs, and hydro/storage inflow logic. |
| `DER` | Demand-side participation and EV-derived rows/schedules, linked through demand/bus tables. |

## Reproducibility status

PISP documents and uses the encoded source paths, filenames, and parser rules. It does not, by itself, prove that a local download root corresponds to the latest AEMO publication revision. For reproducible studies, record the exact downloaded files, checksums, and package commit alongside generated PISP outputs.
