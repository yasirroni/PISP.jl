# Domain concepts

This page defines the conventions that shape PISP's output tables. These conventions are visible in the data model: they determine table names, scenario IDs, time windows, bus assignments, and how schedule tables should be joined to static tables.

## Scenario model

PISP uses the three scenario IDs encoded in `src/parameters/general2024ISP.jl`:

| Scenario ID | Scenario name |
|---:|---|
| 1 | Progressive Change |
| 2 | Step Change |
| 3 | Green Energy Exports |

The `scenarios` keyword to `build_ISP24_datasets` selects which IDs are included. The default is all three scenarios.

Several source files use scenario-specific labels that differ from the display names. Hydro inflow files use `NetZero2050`, `StepChange`, and `HydrogenSuperpower`; demand traces use `PROGRESSIVE_CHANGE`, `STEP_CHANGE`, and `HYDROGEN_EXPORT`. PISP's public output tables retain numeric scenario IDs.

## Planning years, date ranges, and the 1 July split

PISP can build output by planning year or by explicit date range:

| Mode | Keyword | Output schedule tag | Split behaviour |
|---|---|---|---|
| Planning year | `years = [2030]` | `schedule-2030` | Always creates January-June and July-December problem blocks for each scenario. |
| Date range | `drange = [(start, end)]` | `schedule-DDMMYYYY-DDMMYYYY` | Splits only when the requested range crosses 1 July. |

The split matters because some ISP inputs are organised by Australian financial year. The split is an internal problem-table convention; static tables are still written once per build folder, while time-varying schedules are written under each schedule directory.

## Trace year and probability of exceedance

Two build arguments select the weather/demand traces used by time-varying tables:

| Argument | Meaning | Encoded options |
|---|---|---|
| `reftrace` | Reference weather trace year or trace ID. | Historical years 2011-2023, or `4006` for the ISP Optimal Development Path trace. |
| `poe` | Demand probability of exceedance. | `10` or `50`. |

For `reftrace = 4006`, PISP contains an explicit financial-year-to-weather-year map in `WEATHER_YEARS_ISP`. The map is documented in [Parameters and mappings](@ref).

## NEM bus and area model

PISP represents the East Coast Australian system as 12 named ISP sub-regional buses, mapped to five NEM market areas. The bus names, coordinates, and bus-to-area relationships are package constants rather than rows parsed from an AEMO workbook at build time.

Every static asset table uses the bus model directly or indirectly:

| Table | Bus relationship |
|---|---|
| `Bus` | One row per package-defined bus. |
| `Demand` | `id_bus` identifies the bus containing the demand node. |
| `Generator` | `id_bus` identifies the connected bus. |
| `ESS` | `id_bus` identifies the connected bus. |
| `Line` | `id_bus_from` and `id_bus_to` identify the aggregated corridor endpoints. |
| `DER` | `id_dem` links to a demand row, which links to a bus. |

See [Parameters and mappings](@ref) for the current bus list.

## Static values and schedule overlays

PISP writes a static row for every asset and schedule rows only for values that vary across scenario/time. A downstream model should treat a schedule table as an override or time-varying companion for one static column, not as a replacement for the static table.

Examples:

| Static table | Static column | Schedule table | Schedule value |
|---|---|---|---|
| `Demand` | `load_` | `Demand_load_sched` | Time-varying demand load. |
| `Generator` | `pmax` | `Generator_pmax_sched` | Time-varying maximum generator output. |
| `Generator` | `n` | `Generator_n_sched` | Time-varying unit availability/count. |
| `ESS` | `pmax`, `lmax`, `emax`, `n` | `ESS_*_sched` | Time-varying discharge, charge, energy, and unit values. |
| `Line` | `fwcap`, `rvcap` | `Line_fwcap_sched`, `Line_rvcap_sched` | Time-varying transfer limits. |
| `DER` | `pred_max` | `DER_pred_sched` | Time-varying demand-side response/EV prediction. |

A missing schedule row does not mean the asset is absent. It usually means the static value already carries the relevant value for the period being studied.

## Solar and wind classification

When aggregating variable renewable generation from PISP output, classify by `Generator.tech`, not by `Generator.fuel` alone. The tutorial uses a case-insensitive substring rule: `pv` or `solar` for solar, and `wind` for wind. This preserves distinctions such as rooftop PV versus utility-scale PV that can be collapsed by fuel-level grouping.
