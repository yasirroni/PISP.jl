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

## Full Supported Real-Data QA Update

The original plan asked for `years = collect(2025:2050)`. The final ISP2026 model and prepared 4006 traces contain `2026-07-01` through `2051-06-30`, not `2025-07-01` through `2026-06-30`. An initial run with `years = collect(2025:2050)` failed before writing output at schedule 2025 with an empty demand trace selection. The ISP2026 adapter now rejects 2025 with an explicit source-coverage error.

Failed unsupported-year attempt:

```sh
env JULIA_DEPOT_PATH=/private/tmp/parseisp_julia_depot:/Users/aperezguille/.julia JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=. -e 'using Dates, ParseISP; outroot = joinpath("/private/tmp", "parseisp_isp2026_full_real_qa_" * Dates.format(now(), "yyyymmdd_HHMMSS")); mkpath(outroot); elapsed = @elapsed ParseISP.build_datasets(ParseISP.ISP2026(); downloadpath = "data-download", years = collect(2025:2050), output_root = outroot, prepare_outlook = true, prepare_supporting_assets = true, build_traces = true, write_csv = true, write_arrow = true); println("OUTPUT_ROOT=", outroot); println("ELAPSED_SECONDS=", round(elapsed; digits = 2))'
```

Result: failed at schedule 2025 before output was written. Output root created: `/private/tmp/parseisp_isp2026_full_real_qa_20260626_131125`.

Supported chunked verification:

```sh
env JULIA_DEPOT_PATH=/private/tmp/parseisp_julia_depot:/Users/aperezguille/.julia JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=. -e 'using Dates, ParseISP; outroot = joinpath("/private/tmp", "parseisp_isp2026_full_real_qa_" * Dates.format(now(), "yyyymmdd_HHMMSS")); mkpath(outroot); elapsed = @elapsed ParseISP.build_datasets(ParseISP.ISP2026(); downloadpath = "data-download", years = collect(2026:2050), output_root = outroot, prepare_outlook = true, prepare_supporting_assets = true, build_traces = true, write_csv = true, write_arrow = true); println("OUTPUT_ROOT=", outroot); println("ELAPSED_SECONDS=", round(elapsed; digits = 2))'
```

Result: generated schedules 2026 through 2049, then failed at schedule 2050 because AEMO's VPP outlook workbooks stop at `2049-50` and do not provide `2050-51`. The parser now carries forward the final available VPP outlook column when the requested ISP2026 year is beyond the workbook horizon. The 2050 chunk was then run into the same output root:

```sh
env JULIA_DEPOT_PATH=/private/tmp/parseisp_julia_depot:/Users/aperezguille/.julia JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=. -e 'using Dates, ParseISP; outroot = "/private/tmp/parseisp_isp2026_full_real_qa_20260626_131531"; elapsed = @elapsed ParseISP.build_datasets(ParseISP.ISP2026(); downloadpath = "data-download", years = [2050], output_root = outroot, prepare_outlook = true, prepare_supporting_assets = true, build_traces = true, write_csv = true, write_arrow = true); println("OUTPUT_ROOT=", outroot); println("YEARS=2050"); println("ELAPSED_SECONDS=", round(elapsed; digits = 2))'
```

Result: passed. Elapsed time for the 2050 chunk: 176.76 seconds.

Final supported QA output root: `/private/tmp/parseisp_isp2026_full_real_qa_20260626_131531`.

CSV and Arrow schedule directories both cover every supported year:

```text
2026,2027,2028,2029,2030,2031,2032,2033,2034,2035,2036,2037,2038,2039,2040,2041,2042,2043,2044,2045,2046,2047,2048,2049,2050
```

Output size: `4.9G`.

### Full-Range Output Summary

CSV schedules across 2026-2050:

| Schedule file | Rows | Negative values | Duplicate keys | Min date | Max date |
| --- | ---: | ---: | ---: | --- | --- |
| `DER_pred_sched.csv` | 7,973,184 | 0 | 0 | 2025-11-01T00:00:00 | 2053-04-01T00:00:00 |
| `Demand_load_sched.csv` | 7,889,184 | 112,035 | 0 | 2026-07-01T00:00:00 | 2051-06-30T23:00:00 |
| `ESS_emax_sched.csv` | 1,800 | 0 | 0 | 2026-07-01T00:00:00 | 2051-01-01T00:00:00 |
| `ESS_inflow_sched.csv` | 1,314,864 | 0 | 0 | 2026-07-01T00:00:00 | 2051-06-30T23:00:00 |
| `ESS_lmax_sched.csv` | 1,800 | 0 | 0 | 2026-07-01T00:00:00 | 2051-01-01T00:00:00 |
| `ESS_n_sched.csv` | 8,925 | 0 | 0 | 2025-01-01T00:00:00 | 2032-04-01T00:00:00 |
| `ESS_pmax_sched.csv` | 1,800 | 0 | 0 | 2026-07-01T00:00:00 | 2051-01-01T00:00:00 |
| `Generator_inflow_sched.csv` | 19,719,288 | 0 | 0 | 2026-07-01T00:00:00 | 2051-06-30T23:00:00 |
| `Generator_n_sched.csv` | 6,150 | 0 | 0 | 2020-01-01T00:00:00 | 2029-08-01T00:00:00 |
| `Generator_pmax_sched.csv` | 23,667,552 | 0 | 0 | 2026-07-01T00:00:00 | 2051-06-30T23:00:00 |
| `Line_fwcap_sched.csv` | 4,500 | 0 | 0 | 2026-07-01T00:00:00 | 2051-06-01T00:00:00 |
| `Line_rvcap_sched.csv` | 4,500 | 0 | 0 | 2026-07-01T00:00:00 | 2051-06-01T00:00:00 |

Demand negatives are retained as valid net-load behavior. Other negative-value checks passed with zero findings. Duplicate time-key checks passed for every generated schedule file.

Static CSV line counts, including headers:

```text
13 Bus.csv
73 DER.csv
13 Demand.csv
170 ESS.csv
202 Generator.csv
63 Line.csv
```

Schedule 2050 line counts, including headers:

```text
318721 DER_pred_sched.csv
315361 Demand_load_sched.csv
    73 ESS_emax_sched.csv
 52561 ESS_inflow_sched.csv
    73 ESS_lmax_sched.csv
   358 ESS_n_sched.csv
    73 ESS_pmax_sched.csv
788401 Generator_inflow_sched.csv
   247 Generator_n_sched.csv
946081 Generator_pmax_sched.csv
   181 Line_fwcap_sched.csv
   181 Line_rvcap_sched.csv
```

### Reconciliation Results

DSP reconciliation against `2026-isp-inputs-and-assumptions-workbook.xlsm`, sheet `DSP`, range `B9:AG164`, passed exactly for schedule 2050:

| Price band | Source MW | Output MW | Max row diff |
| --- | ---: | ---: | ---: |
| `$300-$500` | 30,471.4 | 30,471.4 | 0.0 |
| `$500-$7500` | 44,837.0 | 44,837.0 | 0.0 |
| `$7500+` | 114,279.0 | 114,279.0 | 0.0 |
| `Reliability Response` | 326,570.0 | 326,570.0 | 0.0 |

EV-derived DER rows in schedule 2050:

| Scenario | Financial year | Rows | Output value sum |
| ---: | --- | ---: | ---: |
| 1 | 2050-51 | 105,120 | 43,457,600 |
| 2 | 2050-51 | 105,120 | 32,096,000 |
| 3 | 2050-51 | 105,120 | 42,272,600 |

Hydro trace inventory:

| Kind | Files | Blockers | Warnings |
| --- | ---: | ---: | ---: |
| annual | 3 | 0 | 0 |
| daily | 30 | 0 | 11,529 |
| halfhourly | 18 | 0 | 0 |
| monthly | 18 | 0 | 2,940 |

All 69 hydro CSVs were inspected. The three annual files are consumed through annual max-energy fallback logic rather than natural-inflow trace maps. Natural-inflow warnings are negative source values; parser policy clamps them to zero for generator and ESS inflow schedules. Annual max-energy files had no blockers.

Validation finding counts for workbook-level validators:

| Source | Severity | Count | Notes |
| --- | --- | ---: | --- |
| DSP | info | 30 | Percentage rows are informational and intentionally not scheduled. |
| Flow Path Augmentation options | blocker | 7 | Fixable unknown bus aliases such as WNV/SEV; canonicalized before line rows are built. |
| Flow Path Augmentation options | warning | 17 | Missing lead-time tokens and numeric-as-string cells normalized by the fix layer. |

### Parser Audit Notes

- `line_table_isp2026`: reads `Network Capability` and `Transmission Reliability`; validates fixed flow-path labels through `ISP2026_FLOW_PATH_MAP`; writes static line rows and seasonal line schedules.
- `line_invoptions`: reads `Flow Path Augmentation options`; validates numeric columns and bus pairs; fix layer canonicalizes ISP2026 subregion aliases before investment lines are appended.
- `generator_table_isp2026`: reads existing generator summary, maximum capacity, commissioning, ramp-rate, and reliability inputs; filters VRE and pumped storage out of synchronous rows; maps subregions through explicit aliases.
- `ess_tables_isp2026`: reads storage properties, maximum capacity, summary mapping, and pumped-storage rows; creates BESS and PS rows; seeds ESS availability changes for future assets.
- `dem_load_sched`: reads prepared demand traces from `data-download/Traces/demand_<bus>_<scenario>`; date coverage is source-backed from `2026-07-01` to `2051-06-30`.
- `gen_pmax_distpv`, `gen_pmax_solar_isp2026`, and `gen_pmax_wind_isp2026`: read prepared rooftop PV, solar, and wind traces and aggregate output to bus-level generator pmax schedules.
- `ess_vpps`: reads prepared storage capacity and energy outlook workbooks; uses the requested financial-year column where present and carries forward `2049-50` for schedule 2050 because the source workbook has no `2050-51` column.
- `prepare_isp26_outlook_aux`: extracts core outlook workbooks from the final 2026 outlook ZIP and writes normalized auxiliary workbooks for generation, storage capacity, storage energy, and REZ generation capacity.
- `prepare_isp26_trace_inputs`: extracts/copies final ISP2026 demand, rooftop PV, solar, and wind traces into the parser's expected trace layout.
- `fill_problem_table_year(...; release = ISP2026())`: creates financial-year blocks from July through June. The ISP2026 build now rejects 2025 because final source traces begin at `2026-07-01`.

## Residual Caveats

- Hydro trace-to-asset mappings and the cumec-to-MW conversion are explicit but remain domain assumptions.
- DSP allocation uses representative buses because the current static model does not expose all ISP2026 subregions as buses.
- Full real-data builds have been verified for every source-backed ISP2026 planning year, 2026 through 2050. Year 2025 is intentionally unsupported because final ISP2026 trace sources do not contain that financial year.
- VPP outlook values for schedule 2050 carry forward the source workbook's final available `2049-50` values; this should be domain-reviewed before release sign-off.
