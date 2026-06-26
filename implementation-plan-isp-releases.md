# ISP2026 Completion and Audit Plan

Updated: 2026-06-26

## Current Status

The local ISP2026 pipeline runs end to end against the real AEMO artefacts in
`data-download` for a 2026-only build. The previously placeholder ISP2026
schedule outputs for DER/DSP, generator inflows, and ESS inflows are now
populated.

Verified command:

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

Additional output sanity check:

- `DER_pred_sched.csv`: 0 negative values.
- `Generator_inflow_sched.csv`: 0 negative values.
- `ESS_inflow_sched.csv`: 0 negative values.

Unit tests:

```sh
env JULIA_DEPOT_PATH=/private/tmp/parseisp_julia_depot:/Users/aperezguille/.julia JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=. -e 'using Pkg; Pkg.test()'
```

Result: passed.

## Completed In This Implementation Pass

### Phase 0: Reproduce The Baseline

Status: complete.

- Confirmed the repository started from a clean working tree.
- Ran the package tests before implementation.
- Ran the real ISP2026 build before implementation.
- Confirmed the target schedule files existed and were header-only before the
  missing parser work began.

### Phase 1: Add Source Schema Validation

Status: partially complete.

Implemented validation and normalization for the new ISP2026 sources consumed
in this pass:

- DSP workbook table validation.
- EV subregional allocation validation.
- Hydro trace CSV validation.
- Shared ISP2026 number/date parsing helpers.
- Structured validation findings with source file, sheet, field, severity,
  code, message, and suggestion metadata.

Remaining validation work:

- Extend the same validation rigor to every existing ISP2026 parser, not only
  the newly populated schedule paths.

### Phase 2: Implement ISP2026 DER/DSP

Status: implemented, partially verified.

Source:

- `2026-isp-inputs-and-assumptions-workbook.xlsm`
- Sheet `DSP`
- Range `B9:AG164`

Implemented behavior:

- Skips blank rows, repeated header rows, and seasonal section labels.
- Maps ISP2026 scenario labels to scenario ids.
- Treats `$300-$500`, `$500-$7500`, and `$7500+` as cumulative bands.
- Treats `Reliability Response` as a direct availability row.
- Treats `Reliability Response in % of Peak Demand*` as informational and does
  not schedule it.
- Writes non-empty `DER_pred_sched.csv`.

Remaining work:

- Domain review of representative region-to-bus allocation:
  - `QLD` -> `SQ`
  - `NSW` -> `SNW`
  - `VIC` -> `VIC`
  - `TAS` -> `TAS`
  - `SA` -> `CSA`
- Aggregate reconciliation against source DSP totals with documented tolerance.

### Phase 3: Implement ISP2026 EV

Status: implemented, partially verified.

Sources:

- `aemo-2025-iasr-ev-workbook.xlsx` for vehicle numbers, profiles, and charge
  type shares.
- `2026-isp-inputs-and-assumptions-workbook.xlsm`, sheet
  `Battery & Plug-in EVs`, range `B14:AG62`, for ISP2026 subregional
  allocation.

Implemented behavior:

- Maps 2026 scenario labels to ISP2026 scenario ids.
- Skips WEM sections from the EV workbook because the current static network is
  NEM-only.
- Maps final 2026 allocation subregions onto existing buses:
  - `MEL`, `SEV`, `WNV` -> `VIC`
  - `NSA` -> `CSA`
- Aggregates mapped subregions and normalizes shares by state, scenario, and
  financial year.
- Writes EV-derived rows into `DER_pred_sched.csv`.

Remaining work:

- Reconcile EV state/scenario/year totals against source workbooks.
- Confirm WEM exclusion is correct for this package's intended ISP2026 scope.
- Add broader tests for financial-year and profile edge cases.

### Phase 4: Implement ISP2026 Hydro And Pumped Storage Inflows

Status: implemented, partially verified.

Source:

```text
data-download/2026 ISP Model/2026 ISP <Scenario>/Traces/hydro/
```

Implemented behavior:

- Reads daily, monthly, and half-hourly natural inflow traces.
- Maps natural inflow trace files explicitly to known hydro generators and
  pumped-hydro ESS rows.
- Clamps negative natural inflows to zero in schedule output while recording
  validation warnings.
- Keeps annual max-energy negatives as blockers.
- Uses annual max-energy values for hydro generators without natural-trace
  coverage.
- Writes non-empty `Generator_inflow_sched.csv` and `ESS_inflow_sched.csv`.

Remaining work:

- Domain review of hydro trace-to-asset mappings.
- Domain review of the pragmatic cumec-to-MW conversion:

```text
cumecs * 1000 * 9.81 * 100 * 0.9 / 1e6
```

- Reconcile aggregate annual/monthly inflows against source files.
- Document every hydro CSV as consumed or intentionally not applicable.

### Phase 5: Audit Existing ISP2026 Parsers For Correctness

Status: not complete.

The newly implemented parser paths were exercised with real data and tests, but
the broader ISP2026 parser audit is still outstanding.

Parsers still requiring source-to-output audit:

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

For each parser, verify:

- source file, sheet, range, or trace directory
- header matching and row filtering
- type coercions and rejected values
- unit conversions
- scenario mapping
- bus, region, and subregion mapping
- date and financial-year logic
- output row counts
- duplicate IDs or duplicate time keys
- aggregate reconciliation against source totals
- whether pragmatic defaults are used and why

### Phase 6: Produce The Correctness Report

Status: created, partial.

Tracked report:

```text
docs/isp2026-parsing-correctness-report.md
```

The report currently covers the new non-placeholder schedule outputs and the
known assumptions from this implementation pass.

Remaining work:

- Add file sizes or checksums for exact source artefacts.
- Add validation finding summaries by source and severity.
- Add aggregate reconciliation tables.
- Expand report coverage to every parser listed in Phase 5.

## What Is Left To Do

1. Run a broader clean-output real-data build beyond `years = [2026]`.
2. Perform domain review of the documented modelling assumptions:
   - hydro trace-to-asset mappings
   - hydro cumec-to-MW conversion
   - DSP representative bus allocation
   - EV WEM exclusion and subregion aggregation
3. Reconcile generated aggregates to source workbook/trace totals.
4. Extend schema validation to the older ISP2026 parser paths.
5. Complete the Phase 5 parser audit.
6. Expand the correctness report to cover every ISP2026 parser, not only the
   newly implemented schedules.
7. Add CI-safe real-data smoke tests if suitable source fixtures can be
   committed or generated.
8. Review performance of hydro validation/trace expansion for multi-year
   builds.

## Final Acceptance Criteria

Do not call ISP2026 fully complete until all of these are true:

- `Pkg.test()` passes.
- A clean-output real-data ISP2026 build passes for the required production
  year range.
- DER/DSP is implemented and reconciled to source data, or documented as
  intentionally empty with source proof.
- EV is implemented and reconciled to source data, or documented as
  intentionally empty with source proof.
- Hydro generation inflows are implemented and reconciled to source data, or
  documented as intentionally empty with source proof.
- Pumped-storage/ESS inflows are implemented and reconciled to source data, or
  documented as intentionally empty with source proof.
- Source validation reports blockers for malformed critical data across all
  ISP2026 parser inputs.
- Fixture tests cover mixed source column types and label mismatches.
- The correctness report covers every parser listed in Phase 5.
- Remaining modelling assumptions are visible in the report and have an owner
  for domain sign-off.

## Notes For The Next Agent

- Keep changes release-scoped.
- Do not reintroduce 2024 globals into the ISP2026 path.
- Prefer explicit source schema declarations over positional assumptions.
- Preserve the existing output contract unless the user approves a breaking
  change.
- Use the writable Julia depot command above to avoid compiled-cache pidfile
  failures.
- Generated data, downloaded workbooks, CSVs, Arrow files, and ZIPs are ignored
  and should not be committed.
