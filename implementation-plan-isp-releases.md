# ISP2026 Completion and Audit Plan

## Current Status

The final ISP2026 pipeline now executes end to end against the real AEMO
artefacts downloaded into `data-download`.

Verified on 2026-06-25:

- `Pkg.test()` passes with:

```sh
env JULIA_DEPOT_PATH=/private/tmp/parseisp_julia_depot:/Users/aperezguille/.julia JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=. -e 'using Pkg; Pkg.test()'
```

- The real-data build succeeds with:

```sh
env JULIA_DEPOT_PATH=/private/tmp/parseisp_julia_depot:/Users/aperezguille/.julia JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=. -e 'using ParseISP; ParseISP.build_datasets(ParseISP.ISP2026(); downloadpath = "data-download", years = [2026], prepare_outlook = true, prepare_supporting_assets = true, build_traces = true)'
```

- Output is written to `out-isp2026-ref4006-poe10/`.
- Static and time-varying CSV/Arrow files are produced for schedule `2026`.
- Demand, line, generator, storage, VPP, solar, wind, distributed PV, and
  trace normalization paths are populated enough for the pipeline to complete.

This is not a correctness sign-off. The current implementation contains
release-scoped fallbacks and pragmatic parser assumptions that must be audited.

## Known Missing Work

These items must be addressed before calling ISP2026 complete.

1. DER/DSP schedules are not implemented for ISP2026.
   - `der_pred_sched(...; release = ISP2026())` currently returns without
     populating `tv.der_pred`.
   - `out-isp2026-ref4006-poe10/csv/schedule-2026/DER_pred_sched.csv` is
     header-only except for the CSV header row.

2. EV schedules are not implemented for ISP2026.
   - `ev_der_sched(...; release = ISP2026())` currently returns an empty
     schedule.
   - The old ISP2024 EV parser expects `Sub-regional demand allocation` in the
     ISP inputs workbook. That sheet is not present in the final 2026 workbook.
   - The source of 2026 EV allocation by scenario, financial year, state, and
     subregion must be identified before implementation.

3. Hydro generation and pumped-storage inflows are not implemented for ISP2026.
   - `gen_inflow_sched(...; release = ISP2026())` validates that hydro CSV
     directories exist but does not parse them into `tv.gen_inflow`.
   - `ess_inflow_sched(...; release = ISP2026())` returns without populating
     `tv.ess_inflow`.
   - The final model hydro files under
     `data-download/2026 ISP Model/2026 ISP <Scenario>/Traces/hydro/` must be
     mapped to ParseISP generator and ESS IDs.

4. Source parsing correctness has not been fully audited.
   - Do not assume source workbook columns, cell types, labels, units, or date
     formats are correct.
   - Do not assume numeric values are already numeric. They may appear as
     strings, strings with commas, percentages, blanks, `x`, `N/A`, Excel
     serial dates, or mixed-type columns.
   - Do not assume scenario, region, subregion, station, technology, or file
     labels match exactly across workbooks and trace files.

## Required Work Plan For The Next Agent

### Phase 0: Reproduce The Baseline

1. Run `git status --short` and confirm the working tree state.
2. Run the unit test command shown above.
3. Run the real ISP2026 build command shown above.
4. Confirm these files exist:
   - `out-isp2026-ref4006-poe10/csv/Generator.csv`
   - `out-isp2026-ref4006-poe10/csv/ESS.csv`
   - `out-isp2026-ref4006-poe10/csv/schedule-2026/Demand_load_sched.csv`
   - `out-isp2026-ref4006-poe10/csv/schedule-2026/Generator_pmax_sched.csv`
5. Confirm the known placeholder schedules are still header-only before
   starting the missing parser work:
   - `DER_pred_sched.csv`
   - `Generator_inflow_sched.csv`
   - `ESS_inflow_sched.csv`

### Phase 1: Add Source Schema Validation

Build a validation layer before extending parsers. The goal is to make source
data problems visible and actionable instead of silently coercing bad values.

Add release-scoped validation helpers for each ISP2026 source table/range:

- workbook path and sheet existence
- expected header labels and tolerated aliases
- required and optional columns
- row count expectations or minimum row counts
- expected scenario labels and scenario IDs
- expected region/subregion labels and canonical aliases
- date column formats, including Excel serial dates and string dates
- numeric fields, including strings with commas, percentages, units, blanks, and
  missing tokens
- uniqueness constraints for IDs, station names, bus mappings, and time keys
- allowed categorical values for technology, fuel, storage type, and status
- unit expectations, especially MW, MWh, GWh, per unit, percentage, and dollars

Validation output should be structured, not plain text only. Reuse or extend
`ISPValidationReport` where practical. Every finding should include:

- source file
- sheet or trace file
- range or row number where available
- field name
- severity: `:blocker`, `:warning`, or `:info`
- machine-readable code
- human-readable message
- suggested fix or parser action

Acceptance criteria:

- Parsers call validation before consuming the source table.
- Blockers fail fast with useful errors.
- Known benign type variations are normalized explicitly and recorded.
- Tests cover mixed int/string numeric columns, comma-formatted numbers,
  percentages, missing tokens, unknown labels, duplicate keys, and date formats.

### Phase 2: Implement ISP2026 DER/DSP

1. Identify the final 2026 source workbook sheets/ranges for demand-side
   participation or equivalent DER forecast data.
2. Document each source in the audit report before coding the parser.
3. Map final 2026 scenario labels to `scenario_id_labels(ISP2026())`.
4. Map source regions/subregions to ParseISP bus IDs using explicit aliases.
5. Parse values with the validation/coercion layer from Phase 1.
6. Populate `tv.der_pred` for ISP2026 without reusing 2024 sheet ranges unless
   the 2026 source has been verified to match.
7. Add fixture tests and, if feasible, one real-data smoke test that checks
   non-empty output for `years = [2026]`.

Acceptance criteria:

- `DER_pred_sched.csv` is no longer header-only for a normal 2026 build unless
  the final source explicitly contains zero DER/DSP for every scenario.
- Row counts equal expected buses x scenarios x hours after accounting for
  source-specific sparsity.
- Aggregate values reconcile to the source workbook within documented tolerance.

### Phase 3: Implement ISP2026 EV

1. Identify the authoritative 2026 EV sources.
   - Check the 2025 IASR EV workbook and the final 2026 ISP inputs workbook.
   - Find the replacement for the old 2024 `Sub-regional demand allocation`
     sheet, or document that no equivalent exists.
2. Validate vehicle number sheets, charging profiles, charge-type shares,
   scenario labels, financial years, state labels, and any subregional
   allocation tables.
3. Decide whether EV should remain in `tv.der_pred` or get a clearer internal
   split before writing the existing output contract.
4. Implement `ev_der_sched(...; release = ISP2026())` with explicit 2026
   sheet/range definitions.
5. Ensure `ev_der_tables(ts)` creates only DER rows that can be scheduled, or
   document why static EV DER rows are present without a schedule.

Acceptance criteria:

- EV schedule generation is populated for ISP2026, or the report proves that no
  source exists and the output should intentionally remain empty.
- Scenario/year/state totals reconcile with the EV source.
- Weekday/weekend profile handling is tested for leap years, financial years,
  daylight-free hourly expansion, and missing profile intervals.

### Phase 4: Implement ISP2026 Hydro and Pumped Storage Inflows

1. Inventory every CSV under:

```text
data-download/2026 ISP Model/2026 ISP <Scenario>/Traces/hydro/
```

2. For each file, document:
   - scenario directory
   - file name
   - header layout
   - units
   - time resolution
   - date range
   - hydro asset or constraint represented
3. Build an explicit mapping from hydro files to ParseISP generator IDs and ESS
   IDs. Do not rely on ISP2024 `HYDRO_GENS`, `HYDRO_DAMS_GENS`, or `DAM_SHARES`
   unless each mapping has been verified against final 2026 source names.
4. Parse generation inflows into `tv.gen_inflow`.
5. Parse pumped-storage/reservoir inflows into `tv.ess_inflow`.
6. Validate scenario coverage, date coverage, duplicate timestamps, unit
   conversion, and missing values.

Acceptance criteria:

- `Generator_inflow_sched.csv` and `ESS_inflow_sched.csv` are no longer
  header-only for normal 2026 builds if the final model provides inflow data.
- Every hydro CSV is either consumed or explicitly documented as not applicable.
- Aggregate annual/monthly inflows reconcile to source files within documented
  tolerance.

### Phase 5: Audit Existing ISP2026 Parsers For Correctness

Audit every ISP2026 parser added to make the pipeline run. Pipeline completion
is not enough.

Check at least these parser areas:

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

- exact source file, sheet, range, and trace directory
- header matching and row filtering logic
- type coercions and rejected values
- unit conversions
- scenario mapping
- bus/region/subregion mapping
- date and financial-year logic
- output row counts
- duplicate IDs or duplicate time keys
- aggregate reconciliation against source totals
- whether pragmatic defaults are used and why

Pay special attention to existing pragmatic assumptions:

- VRE pmax currently aggregates existing capacity and scales average traces; it
  must be checked against final 2026 capacity outlook expectations.
- Generator reliability, slope, inertia, and cost defaults must be verified or
  reported as assumptions.
- Storage static values and pumped-storage classification must be reconciled
  against final 2026 workbook data.
- VIC and CSA alias handling must be checked across demand, trace, VRE,
  generator, storage, and transmission paths.

### Phase 6: Produce The Correctness Report

Create a tracked report at:

```text
docs/isp2026-parsing-correctness-report.md
```

The report must include:

- executive summary
- exact source artefact filenames and, where possible, checksums/file sizes
- build command and test command used
- generated output directory and row counts
- per-parser source-to-output mapping
- validation findings by source and severity
- type coercions applied, including examples
- label mappings and aliases applied
- aggregate reconciliation tables
- unresolved assumptions
- remaining blockers
- sign-off checklist

The report must explicitly state whether each output table is:

- verified against final ISP2026 source data
- populated but only partially verified
- populated using documented assumptions
- intentionally empty
- still incorrect/blocking

### Phase 7: Final Acceptance Criteria

Do not mark ISP2026 complete until all of these are true:

- `Pkg.test()` passes.
- The real-data ISP2026 build passes from a clean output directory.
- DER/DSP is implemented or documented as intentionally empty with source proof.
- EV is implemented or documented as intentionally empty with source proof.
- Hydro generation inflows are implemented or documented as intentionally empty
  with source proof.
- Pumped-storage/ESS inflows are implemented or documented as intentionally
  empty with source proof.
- Source validation reports blockers for malformed critical data.
- Fixture tests cover mixed source column types and label mismatches.
- The correctness report exists and covers every parser listed in Phase 5.
- Any remaining modelling assumptions are visible in the report and not hidden
  in parser defaults.

## Notes For The Next Agent

- Keep changes release-scoped. Do not reintroduce 2024 globals into the ISP2026
  path.
- Prefer explicit source schema declarations over positional assumptions.
- Preserve the existing output contract unless the user approves a breaking
  change.
- Use the writable Julia depot command above to avoid compiled-cache pidfile
  failures.
- Generated data, downloaded workbooks, CSVs, Arrow files, and ZIPs are ignored
  and should not be committed.
