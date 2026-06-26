# ISP2026 Parsing Correctness Report

Date: 2026-06-26

## Scope

This report covers the local implementation of the ISP2026 parsing plan for the non-placeholder schedule outputs:

- `DER_pred_sched.csv`
- `Generator_inflow_sched.csv`
- `ESS_inflow_sched.csv`

The implementation was verified against the locally downloaded AEMO inputs under `data-download` and a 2026-only build using POE 10 and reference weather trace 4006.

## Source Artefacts

The ISP2026 build validates these local source artefacts before parsing:

| Local path | Bytes | SHA-256 |
| --- | ---: | --- |
| `data-download/2026-isp-inputs-and-assumptions-workbook.xlsm` | 24076526 | `4a9c04b3ce099a3c8d1866953a15fece4650959a88024d7e8be64c0eee52b55c` |
| `data-download/aemo-2025-iasr-ev-workbook.xlsx` | 676541 | `ddab92d099b051f85f57745e1b5540a328981332dc60c4ef9bd719214c88b609` |
| `data-download/2026-isp-generation-and-storage-outlook.zip` | 83893796 | `57c94c22356eed3724ef8faf7e76a5b1d42e5103afd9f648e06dbcefc08911d6` |
| `data-download/2026-isp-model.zip` | 133239039 | `8974b72b84fc1ef0b6aaf046a6f0ccf84778e7a1054ff3926fac3f84ce01de42` |
| `data-download/zip/Traces/2026-isp-solar-traces.zip` | 103470007 | `ce364d7c6eddfebaf23a56569732fb90bdb93f051007df79d3d6dda6d50fb689` |
| `data-download/zip/Traces/2026-isp-wind-traces.zip` | 159258886 | `7a14094b68437356c20da1048714b62c1a082b030573531e690b3bf6df22d844` |

The EV support workbook is required because the final ISP2026 `Battery & Plug-in EVs` sheet states that the detailed charge profiles are provided in AEMO's 2025 IASR EV workbook.

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

- `aemo-2025-iasr-ev-workbook.xlsx` for EV profiles, vehicle numbers, and charging shares. This workbook is explicitly required by the ISP2026 build because it is referenced by the final 2026 ISP workbook for detailed EV assumptions.
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

Clean-output verification for this pass:

```sh
env JULIA_DEPOT_PATH=/private/tmp/parseisp_julia_depot:/Users/aperezguille/.julia JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=. -e 'using Dates, ParseISP; outroot = joinpath("/private/tmp", "parseisp_isp2026_verify_" * Dates.format(now(), "yyyymmdd_HHMMSS")); mkpath(outroot); ParseISP.build_datasets(ParseISP.ISP2026(); downloadpath = "data-download", years = [2026], output_root = outroot, prepare_outlook = true, prepare_supporting_assets = true, build_traces = true)'
```

Result: passed. Output root used for verification: `/private/tmp/parseisp_isp2026_verify_20260626_122035`.

Future-year smoke verification:

```sh
env JULIA_DEPOT_PATH=/private/tmp/parseisp_julia_depot:/Users/aperezguille/.julia JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=. -e 'using Dates, ParseISP; outroot = joinpath("/private/tmp", "parseisp_isp2026_verify_2030_" * Dates.format(now(), "yyyymmdd_HHMMSS")); mkpath(outroot); ParseISP.build_datasets(ParseISP.ISP2026(); downloadpath = "data-download", years = [2030], output_root = outroot, prepare_outlook = true, prepare_supporting_assets = true, build_traces = true)'
```

Result: passed. Output root used for verification: `/private/tmp/parseisp_isp2026_verify_2030_20260626_122709`.

Generated schedule line counts, including headers:

```text
318721 out-isp2026-ref4006-poe10/csv/schedule-2026/DER_pred_sched.csv
788401 out-isp2026-ref4006-poe10/csv/schedule-2026/Generator_inflow_sched.csv
 52561 out-isp2026-ref4006-poe10/csv/schedule-2026/ESS_inflow_sched.csv
```

The generated files are no longer header-only. Data row counts are 318720 DER prediction rows, 788400 generator inflow rows, and 52560 ESS inflow rows.

Additional output sanity checks on the clean-output build:

- `DER_pred_sched.csv`: 0 negative values.
- `Generator_inflow_sched.csv`: 0 negative values; date range `2026-07-01T00:00:00` to `2027-06-30T23:00:00`.
- `ESS_inflow_sched.csv`: 0 negative values; date range `2026-07-01T00:00:00` to `2027-06-30T23:00:00`.
- The same key row counts and zero-negative DER/inflow checks passed for `years = [2030]`; generator and ESS inflows cover `2030-07-01T00:00:00` to `2031-06-30T23:00:00`.

## Residual Caveats

- Hydro trace-to-asset mappings and the cumec-to-MW conversion are explicit but remain domain assumptions.
- DSP allocation uses representative buses because the current static model does not expose all ISP2026 subregions as buses.
- Clean real-data builds have been verified for `years = [2026]` and a future-year smoke run `years = [2030]`; the full production year range should still be run before release packaging.
