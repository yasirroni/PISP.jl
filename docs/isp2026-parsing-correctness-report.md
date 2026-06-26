# ISP2026 Parsing Correctness Report

Date: 2026-06-26

## Scope

This report covers the local implementation of the ISP2026 parsing plan for the non-placeholder schedule outputs:

- `DER_pred_sched.csv`
- `Generator_inflow_sched.csv`
- `ESS_inflow_sched.csv`

The implementation was verified against the locally downloaded AEMO inputs under `data-download` and a 2026-only build using POE 10 and reference weather trace 4006.

## Source Tables And Rules

### DSP / DER Prediction

Source: `2026-isp-inputs-and-assumptions-workbook.xlsm`, sheet `DSP`, range `B9:AG164`.

Implemented behavior:

- Blank rows, repeated header rows, and seasonal section labels are ignored.
- Required fields are validated: `Region`, `Price band`, `Scenario`, `Season`, and financial-year columns.
- The first three price bands are treated as cumulative availability:
  - `$300-$500`
  - `$500-$7500`
  - `$7500+`
- `Reliability Response` is treated as a direct availability row, not an increment over `$7500+`.
- `Reliability Response in % of Peak Demand*` is validated as informational and is not scheduled.

Representative region-to-bus allocation follows the existing static NEM topology:

- `QLD` -> `SQ`
- `NSW` -> `SNW`
- `VIC` -> `VIC`
- `TAS` -> `TAS`
- `SA` -> `CSA`

### EV DER Prediction

Sources:

- `aemo-2025-iasr-ev-workbook.xlsx` for EV profiles, vehicle numbers, and charging shares.
- `2026-isp-inputs-and-assumptions-workbook.xlsm`, sheet `Battery & Plug-in EVs`, range `B14:AG62`, for ISP2026 subregional allocation.

Implemented behavior:

- 2026 scenario labels are mapped to ISP2026 scenario ids.
- WEM sections in the 2025 EV workbook are skipped because the current static model is NEM-only.
- ISP2026 allocation subregions are validated and mapped into available buses:
  - `MEL`, `SEV`, `WNV` -> `VIC`
  - `NSA` -> `CSA`
- Allocation values are aggregated by mapped bus and normalized to shares by state, scenario, and financial year.

### Hydro And ESS Inflows

Source: `2026 ISP Model/2026 ISP <Scenario>/Traces/hydro`.

Implemented behavior:

- Natural inflow traces are read from daily, monthly, and half-hourly CSVs.
- Negative natural inflow values are validation warnings and are clamped to zero for schedule output.
- Annual `MaxEnergyYear_RefYear5000_Flat.csv` values remain strict: negative annual energy is a blocker.
- Natural trace files are mapped explicitly to known hydro generators and pumped-hydro ESS rows.
- Hydro generators without natural-trace coverage use annual max-energy values spread uniformly across the problem hours.

Hydro natural inflows use a pragmatic conversion from cumecs to MW:

`cumecs * 1000 * 9.81 * 100 * 0.9 / 1e6`

This assumes 100 m head and 90% efficiency. It is implemented explicitly and should be reviewed before relying on plant-specific energy fidelity.

## Validation Coverage

The ISP2026 validation layer now records source file, sheet, field, and suggested resolution metadata where available. Focused unit tests cover:

- ISP2026 number and date parsing.
- DSP non-data row filtering and invalid label/value detection.
- EV subregional allocation validation.
- Hydro natural negative warnings vs annual negative blockers.
- WEM EV profile section skipping.

## Verification

Package tests:

```sh
env JULIA_DEPOT_PATH=/private/tmp/parseisp_julia_depot:/Users/aperezguille/.julia JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=. -e 'using Pkg; Pkg.test()'
```

Result: passed.

Real-data build:

```sh
env JULIA_DEPOT_PATH=/private/tmp/parseisp_julia_depot:/Users/aperezguille/.julia JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=. -e 'using ParseISP; ParseISP.build_datasets(ParseISP.ISP2026(); downloadpath = "data-download", years = [2026], prepare_outlook = true, prepare_supporting_assets = true, build_traces = true)'
```

Result: passed.

Generated schedule line counts, including headers:

```text
318721 out-isp2026-ref4006-poe10/csv/schedule-2026/DER_pred_sched.csv
788401 out-isp2026-ref4006-poe10/csv/schedule-2026/Generator_inflow_sched.csv
 52561 out-isp2026-ref4006-poe10/csv/schedule-2026/ESS_inflow_sched.csv
```

The generated files are no longer header-only. Data row counts are 318720 DER prediction rows, 788400 generator inflow rows, and 52560 ESS inflow rows.

## Residual Caveats

- Hydro trace-to-asset mappings and the cumec-to-MW conversion are explicit but remain domain assumptions.
- DSP allocation uses representative buses because the current static model does not expose all ISP2026 subregions as buses.
- The verified real-data build covered `years = [2026]`; broader multi-year builds should be run before release packaging.
