# ISP2026 Next Steps For The Next AI

Updated: 2026-06-26

## Objective

Finish ISP2026 implementation and data QA to a release-quality standard.

Do not mark ISP2026 complete until the full supported real-data build and source
reconciliation are finished. Single-year or subset checks are not acceptance
evidence.

## Required Inputs

Use only the ISP2026 release path:

```julia
ParseISP.build_datasets(ParseISP.ISP2026(); ...)
```

Required local inputs under `data-download`:

- `2026-isp-inputs-and-assumptions-workbook.xlsm`
- `aemo-2025-iasr-ev-workbook.xlsx`
- `2026-isp-generation-and-storage-outlook.zip`
- `2026-isp-model.zip`
- `zip/Traces/2026-isp-solar-traces.zip`
- `zip/Traces/2026-isp-wind-traces.zip`

The EV workbook is required because the final 2026 ISP workbook references it
for detailed EV charge profiles and charge-type assumptions. Do not substitute
2023 EV data or 2024 ISP artefacts.

## Required Full Real-Data Verification

Run package tests:

```sh
env JULIA_DEPOT_PATH=/private/tmp/parseisp_julia_depot:/Users/aperezguille/.julia JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=. -e 'using Pkg; Pkg.test()'
```

Run a clean-output build for every supported ISP2026 planning year:

```sh
env JULIA_DEPOT_PATH=/private/tmp/parseisp_julia_depot:/Users/aperezguille/.julia JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=. -e 'using ParseISP; ParseISP.build_datasets(ParseISP.ISP2026(); downloadpath = "data-download", years = collect(2025:2050), output_root = "/private/tmp/parseisp_isp2026_full_real_qa", prepare_outlook = true, prepare_supporting_assets = true, build_traces = true, write_csv = true, write_arrow = true)'
```

If the full run is too slow or too memory-heavy, split it into year chunks, but
every year from 2025 through 2050 must pass against real local ISP2026 sources.
Record the exact commands, output roots, elapsed time, failures, fixes, and final
pass status.

## Data QA Tasks

1. Reconcile `DER_pred_sched.csv` against the `DSP` sheet.
   - Source: `2026-isp-inputs-and-assumptions-workbook.xlsm`, sheet `DSP`,
     range `B9:AG164`.
   - Verify scenario labels, financial-year labels, seasonal date mapping,
     cumulative price-band handling, reliability response handling, and
     region-to-bus allocation.
   - Produce aggregate source-vs-output tables by scenario, year, region or bus,
     price band, and season with documented tolerances.

2. Reconcile EV-derived `DER_pred_sched.csv` rows.
   - Sources:
     `aemo-2025-iasr-ev-workbook.xlsx` and
     `2026-isp-inputs-and-assumptions-workbook.xlsm`, sheet
     `Battery & Plug-in EVs`, range `B14:AG62`.
   - Verify vehicle numbers, charge-type shares, weekday/weekend profiles,
     scenario mapping, financial-year mapping, WEM exclusion, subregion
     aggregation, and final bus allocation.
   - Produce state/scenario/year source-vs-output energy or capacity
     reconciliation tables with documented tolerances.

3. Reconcile hydro generator inflows.
   - Source: `data-download/2026 ISP Model/2026 ISP <Scenario>/Traces/hydro/`.
   - Verify every hydro CSV is either consumed or explicitly documented as not
     applicable.
   - Reconcile daily, monthly, half-hourly, and annual max-energy values to
     `Generator_inflow_sched.csv`.
   - Review and either justify or replace the current natural-inflow conversion:
     `cumecs * 1000 * 9.81 * 100 * 0.9 / 1e6`.

4. Reconcile pumped-storage and ESS inflows.
   - Source: the same ISP2026 hydro trace folders.
   - Reconcile mapped hydro traces to `ESS_inflow_sched.csv`.
   - Verify all pumped-hydro ESS rows have intended inflow behavior.

5. Audit every existing ISP2026 parser from source to output:
   - `line_table_isp2026`
   - `line_invoptions`
   - `generator_table_isp2026`
   - `ess_tables_isp2026`
   - `dem_load_sched`
   - `gen_pmax_distpv`
   - `gen_pmax_solar_isp2026`
   - `gen_pmax_wind_isp2026`
   - `ess_vpps`
   - `prepare_isp26_outlook_aux`
   - `prepare_isp26_trace_inputs`
   - `fill_problem_table_year(...; release = ISP2026())`

For each parser, document:

- source file, sheet, range, archive entry, or trace directory
- header matching and row filtering
- required columns and schema validation
- type coercions and rejected values
- unit conversions
- scenario mapping
- bus, region, and subregion mapping
- date and financial-year logic
- output row counts
- duplicate IDs or duplicate time keys
- aggregate source-vs-output reconciliation
- pragmatic defaults and why they are acceptable

## Validation Work

Extend ISP2026 source validation so malformed critical inputs fail before output
is written. At minimum, add validation or tests for:

- required sheets, ranges, and columns for all ISP2026 parsers
- unknown scenario, region, subregion, bus, technology, and asset labels
- mixed numeric cell types, percentages, dates, missing values, and non-data rows
- duplicate keys in time-varying schedules
- negative values where they are invalid, with explicit exceptions where they
  are valid net-load behavior

## Required Report Updates

Update `docs/isp2026-parsing-correctness-report.md` with:

- exact full real-data commands and output roots
- source file sizes and checksums
- validation findings by source and severity
- reconciliation tables for DER/DSP, EV, hydro, ESS inflows, demand, VRE,
  storage, generator, line, and outlook-derived outputs
- every parser audit listed above
- unresolved assumptions, owner, and sign-off status

## Acceptance Criteria

ISP2026 is complete only when all are true:

- `Pkg.test()` passes.
- The full `years = collect(2025:2050)` real-data build passes, or chunked runs
  collectively cover every year from 2025 through 2050 with no skipped years.
- CSV and Arrow outputs are produced for the full required year range.
- DER/DSP, EV, hydro generator inflows, and pumped-storage/ESS inflows are
  reconciled to source data or explicitly documented as intentionally empty with
  source proof.
- Every parser audit item is complete and recorded in the report.
- Critical malformed ISP2026 inputs fail with actionable validation errors.
- Fixture tests cover mixed source column types and label mismatches.
- Remaining modelling assumptions are visible in the report and have domain
  owner sign-off.

## Guardrails

- Keep changes release-scoped.
- Do not reintroduce 2024 globals into the ISP2026 path.
- Do not rely on generated outputs already present in the repository.
- Preserve the existing output contract unless the user approves a breaking
  change.
- Generated data, downloaded workbooks, CSVs, Arrow files, and ZIPs are ignored
  and should not be committed.
