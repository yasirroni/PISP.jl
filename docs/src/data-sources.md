# Data sources

The 2024 ISP does not publish every quantity needed by PISP in one file or one data shape.
Static asset assumptions, development outlooks, EV inputs, hydro information, and half-hourly demand and renewable traces come from different publications.
PISP reconciles those source families into a common dataset while retaining a small number of package-defined mappings where the published files do not share a single identifier system.

This page describes the source material encoded by the current build path.
It does not independently verify that an existing local download is the newest revision on the AEMO website.

## Why several source families are required

| Source family | Role in the dataset | Why it is separate |
|---|---|---|
| 2024 ISP Inputs and Assumptions workbook | Network capabilities, existing assets, reliability inputs, costs, and other planning assumptions. | This is the main structured workbook for the 2024 build. |
| 2024 ISP model archive | Model-side files, including hydro inflow material used by the parser. | Some operational time-series inputs are distributed with the model rather than the assumptions workbook. |
| 2024 generation and storage outlook | Future generation and storage development information. | Planned build-out changes across scenario and planning year and therefore cannot be represented only by the existing-asset sheets. |
| 2024 demand, solar, and wind traces | Half-hourly profiles used to construct time-varying schedules. | Trace data are published as multiple downloadable archives rather than as one workbook. |
| 2023 IASR EV workbook | EV-related inputs used for demand-side and DER schedules. | The current parser supplements the 2024 ISP material with the dedicated EV publication it was designed against. |
| 2019 Inputs and Assumptions workbook v1.3 | Minimum up/down-time information for selected legacy thermal units. | The 2024 inputs do not provide every historical unit constraint used by the current PISP mapping. |

!!! note "Why is a 2019 workbook still required?"
    The 2019 workbook is a targeted supplementary source for selected minimum up/down-time values.
    It does not make PISP a general 2019 ISP parser, and it should not be interpreted as the primary data vintage for the generated case.

## Primary, supplementary, and package-defined information

PISP outputs combine three trust domains:

| Status | Meaning in PISP |
|---|---|
| Source-derived | Values read directly from a named AEMO workbook, archive, model file, or trace. |
| Code-derived | Values produced from package schemas, formulas, identifier mappings, and writer conventions. |
| Assumed or mapped | Values that reconcile source naming, fill a documented modelling gap, or define the package's canonical representation. |

The distinction matters because a source refresh and a package-code review answer different validation questions.
A changed AEMO workbook may require parser review, while a changed mapping or formula may alter outputs even when the downloaded files are identical.

## Encoded download inventory

The current downloader is configured for the following published artifacts and local filenames:

| Published artifact | Local filename |
|---|---|
| 2024 ISP Inputs and Assumptions workbook | `2024-isp-inputs-and-assumptions-workbook.xlsx` |
| 2023 IASR EV workbook | `2023-iasr-ev-workbook.xlsx` |
| 2024 ISP Model | `2024-isp-model.zip` |
| 2024 ISP generation and storage outlook | `2024-isp-generation-and-storage-outlook.zip` |
| 2019 Inputs and Assumptions workbook v1.3 | `2019-input-and-assumptions-workbook-v1-3-dec-19.xlsx` |

Demand, solar, and wind traces are collected separately from the 2024 ISP publication page.
The downloader recognises the three trace families from their published link names and preserves a deterministic local filename for each downloaded archive.

## Expected local input layout

`PISP.default_data_paths(filepath = downloadpath)` expects the downloaded and extracted material under one input root.
The important paths are:

| Path under `downloadpath` | Used for |
|---|---|
| `2019-input-and-assumptions-workbook-v1-3-dec-19.xlsx` | Legacy minimum up/down-time input for selected units. |
| `2024-isp-inputs-and-assumptions-workbook.xlsx` | Main 2024 workbook. |
| `2023-iasr-ev-workbook.xlsx` | EV-related input. |
| `2024 ISP Model/` | ISP model files, including hydro inflow data. |
| `Traces/` | Demand, solar, and wind profile traces. |
| `Core/` | Core generation and storage outlook material. |
| `Auxiliary/CapacityOutlook2024_Condensed.xlsx` | Condensed capacity outlook. |
| `Auxiliary/StorageCapacityOutlook_2024_ISP.xlsx` | VPP and storage power-capacity input. |
| `Auxiliary/StorageEnergyOutlook_2024_ISP.xlsx` | VPP and storage energy-capacity input. |

## How sources feed the dataset

| Dataset area | Main source role |
|---|---|
| `Bus` | Package-defined sub-regional names, coordinates, and area relationships. |
| `Demand` | Package-defined demand-node identities combined with hourly demand traces. |
| `DER` | Demand-side participation and EV inputs linked through demand nodes. |
| `Generator` | Existing-generator sheets, technology and identifier mappings, development outlooks, reliability inputs, and renewable or hydro traces. |
| `ESS` | Storage properties, storage outlooks, project mappings, reliability inputs, and inflow logic. |
| `Line` | Transfer capability, reliability, and augmentation information from the 2024 assumptions material. |

The source-to-output relationship is many-to-many.
For example, a generator row can combine a source-derived asset identity with code-defined technology classification and a schedule derived from a separate trace or outlook file.
That is why the output tables should be reviewed together with [Parameters and mappings](@ref), not treated as a verbatim transcription of one workbook.

## Reproducibility and source vintage

For a reproducible study, preserve the exact downloaded artifacts, record checksums, and record the PISP commit used to produce the outputs.
The local filenames identify what the parser expects, but filenames alone do not prove that two downloads contain the same revision.

A study should also record the selected `reftrace`, `poe`, scenarios, and planning periods because those choices determine which source traces and mappings contribute to each schedule.

## See also

- [Parameters and mappings](@ref) documents package-defined values and identifier reconciliation.
- [Output tables](@ref) shows which source-derived and code-derived quantities appear in each exported table.
- [Assumptions and scope](@ref) explains what still requires external or study-specific validation.
