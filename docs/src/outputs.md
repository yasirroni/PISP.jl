# Output tables

PISP separates **asset definition** from **time-varying behaviour**.
Static tables identify the system components and store parameters that are intended to remain stable within a build.
Schedule tables record values that depend on scenario, planning period, trace, or timestamp.

```text
static asset table + applicable schedule tables = system state for a scenario and time
```

!!! note "Why are schedules not embedded in the static tables?"
    The same generator, storage asset, demand node, or corridor can appear across many scenarios and thousands of timestamps.
    Storing identity and stable parameters once avoids duplication, while schedule overlays make each changing quantity explicit and independently joinable.

## Output directory pattern

For a call such as:

```julia
PISP.build_ISP24_datasets(
    output_name = "out",
    output_root = "data/pisp-datasets",
    reftrace = 4006,
    poe = 10,
    years = [2030],
    write_csv = true,
    write_arrow = true,
)
```

PISP writes paths with this structure:

```text
data/pisp-datasets/
└── out-ref4006-poe10/
    ├── csv/
    │   ├── Bus.csv
    │   ├── Demand.csv
    │   ├── DER.csv
    │   ├── ESS.csv
    │   ├── Generator.csv
    │   ├── Line.csv
    │   └── schedule-2030/
    │       ├── Demand_load_sched.csv
    │       ├── DER_pred_sched.csv
    │       ├── ESS_emax_sched.csv
    │       ├── ESS_inflow_sched.csv
    │       ├── ESS_lmax_sched.csv
    │       ├── ESS_n_sched.csv
    │       ├── ESS_pmax_sched.csv
    │       ├── Generator_inflow_sched.csv
    │       ├── Generator_n_sched.csv
    │       ├── Generator_pmax_sched.csv
    │       ├── Line_fwcap_sched.csv
    │       └── Line_rvcap_sched.csv
    └── arrow/
        └── ... same table names with .arrow extensions
```

Static tables are written once per build and schedule directories are written once per requested planning year or date range.
CSV and Arrow outputs use the same logical table names.

## Static asset tables

| Table | Primary key | Main foreign keys | Modelling role |
|---|---|---|---|
| `Bus` | `id_bus` | `id_area` | Defines the 12 aggregated ISP sub-regions used as the common spatial index. |
| `Demand` | `id_dem` | `id_bus` | Defines demand nodes and their static metadata; hourly load is supplied separately. |
| `DER` | `id_der` | `id_dem` | Defines demand-side participation and EV-related rows linked to demand nodes. |
| `ESS` | `id_ess` | `id_bus` | Defines storage assets, including power, energy, efficiency, reliability, and service fields. |
| `Generator` | `id_gen` | `id_bus` | Defines existing, aggregated, and future generation assets with technology, capacity, cost, outage, and commitment fields. |
| `Line` | `id_lin` | `id_bus_from`, `id_bus_to` | Defines aggregated transfer corridors and augmentation options between PISP buses. |

These tables are not interchangeable inventories.
`Bus` provides the spatial backbone, `Demand` and `DER` describe consumption-side entities, `Generator` and `ESS` describe supply and flexibility, and `Line` describes interconnection between regions.
See [Domain concepts](@ref) for the modelling interpretation of each table.

## Schedule tables

Most schedules contain an integer row ID, an asset ID, a numeric `scenario`, a `date`, and a `value`.
The asset ID identifies the static table that gives the scheduled value its physical meaning and units.

| Schedule table | Join key | Static quantity being scheduled | Value meaning |
|---|---|---|---|
| `Demand_load_sched` | `id_dem` | `Demand.load_` | Demand load in MW. |
| `DER_pred_sched` | `id_der` | `DER.pred_max` | Predicted maximum demand-side or EV quantity in MW. |
| `ESS_emax_sched` | `id_ess` | `ESS.emax` | Maximum storage energy in MWh. |
| `ESS_inflow_sched` | `id_ess` | Storage or hydro inflow | Approximate inflow energy in MWh. |
| `ESS_lmax_sched` | `id_ess` | `ESS.lmax` | Maximum charging load in MW. |
| `ESS_n_sched` | `id_ess` | `ESS.n` | Time-varying unit count or availability. |
| `ESS_pmax_sched` | `id_ess` | `ESS.pmax` | Maximum discharging power in MW. |
| `Generator_inflow_sched` | `id_gen` | Hydro inflow | Approximate inflow energy in MWh. |
| `Generator_n_sched` | `id_gen` | `Generator.n` | Time-varying unit count or availability. |
| `Generator_pmax_sched` | `id_gen` | `Generator.pmax` | Maximum generation output in MW. |
| `Line_fwcap_sched` | `id_lin` | `Line.fwcap` | Forward transfer capacity in MW. |
| `Line_rvcap_sched` | `id_lin` | `Line.rvcap` | Reverse transfer capacity in MW. |

When `write_traces = false`, or when trace writing is skipped through `check_exist_trace`, PISP still writes the lightweight `Generator_n_sched` and `ESS_n_sched` tables.
The heavier trace-dependent schedules are omitted in that mode.

## Reconstructing a system state

For a selected scenario and timestamp:

1. Start from the relevant static asset row.
2. Select schedule rows with the same asset identifier and scenario.
3. Apply the schedule value at the required timestamp to the corresponding static quantity.
4. Retain static values for quantities that have no applicable schedule override.

For example, `Generator.csv` identifies a generator and its technology, bus, outage parameters, and static capacity-related fields.
`Generator_pmax_sched.csv` supplies the scenario- and time-dependent maximum output, while `Generator_n_sched.csv` can change the available unit count.
The complete generator state therefore depends on all three tables rather than on any one file alone.

## Common interpretation rules

- Join schedule rows to the matching static table by asset ID and retain `scenario` when comparing or filtering schedules.
- Interpret `date` as the timestamp at which the scheduled `value` applies.
- Interpret `value` using the scheduled quantity and its units; the generic column name does not supply enough context by itself.
- Apply the relevant `n` value when a downstream model interprets `pmax`, `lmax`, `fwcap`, or `rvcap` as a per-unit or per-circuit quantity.
- Do not infer forced-outage time series from schedule tables; outage quantities are static fields on `Generator`, `ESS`, or `Line` rows.
- Do not treat a missing schedule as proof that an asset is absent; first check whether the static value applies or trace writing was disabled.

## See also

- [Domain concepts](@ref) explains why the dataset uses static assets plus schedule overlays.
- [Parameters and mappings](@ref) records technology-specific exceptions and hard-coded values that affect interpretation.
- [Assumptions and scope](@ref) identifies quantities that require study-specific validation before downstream modelling.
