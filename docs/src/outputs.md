# Output tables

PISP writes static tables once per build and schedule tables once per requested planning year or date range. The same table names are used for CSV and Arrow output, with `.csv` or `.arrow` extensions.

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

The exported DER schedule filename is `DER_pred_sched`, as defined by the writing layer in `src/utils/writing/PISPutils-writing.jl`. The internal schema constant is named `MOD_DER_PRED_MAX`; use the exported filename when reading generated files.

## Static tables

| Table | Primary key | Main foreign keys | What it represents |
|---|---|---|---|
| `Bus` | `id_bus` | `id_area` | The 12 package-defined NEM sub-regional buses. |
| `Demand` | `id_dem` | `id_bus` | Demand nodes attached to buses, with static demand metadata and controllability flags. |
| `DER` | `id_der` | `id_dem` | Demand-side participation and EV-related rows linked to demand nodes. |
| `ESS` | `id_ess` | `id_bus` | Battery and pumped-storage assets with static power, energy, efficiency, outage, and service fields. |
| `Generator` | `id_gen` | `id_bus` | Generating units and buildout rows with technology, capacity, outage, cost, response, and unit-commitment fields. |
| `Line` | `id_lin` | `id_bus_from`, `id_bus_to` | Aggregated transmission corridors and augmentation options between PISP buses. |

## Schedule tables

Most schedule tables share the same shape: an integer `id`, an asset ID, a numeric `scenario`, a `date`, and a `value`. The asset ID column tells you which static table to join against.

| Schedule table | Join key | Static table/column being scheduled | Value meaning |
|---|---|---|---|
| `Demand_load_sched` | `id_dem` | `Demand.load_` | Demand load in MW. |
| `DER_pred_sched` | `id_der` | `DER.pred_max` | Predicted maximum DER/demand-response quantity in MW. |
| `ESS_emax_sched` | `id_ess` | `ESS.emax` | Maximum storage energy in MWh. |
| `ESS_inflow_sched` | `id_ess` | `ESS` hydro/storage asset | Approximate inflow energy in MWh. |
| `ESS_lmax_sched` | `id_ess` | `ESS.lmax` | Maximum charging load in MW. |
| `ESS_n_sched` | `id_ess` | `ESS.n` | Time-varying unit count/availability. |
| `ESS_pmax_sched` | `id_ess` | `ESS.pmax` | Maximum discharging power in MW. |
| `Generator_inflow_sched` | `id_gen` | `Generator` hydro unit | Approximate inflow energy in MWh. |
| `Generator_n_sched` | `id_gen` | `Generator.n` | Time-varying unit count/availability. |
| `Generator_pmax_sched` | `id_gen` | `Generator.pmax` | Maximum generation output in MW. |
| `Line_fwcap_sched` | `id_lin` | `Line.fwcap` | Forward transfer capacity in MW. |
| `Line_rvcap_sched` | `id_lin` | `Line.rvcap` | Reverse transfer capacity in MW. |

When `write_traces = false` or trace outputs are skipped through `check_exist_trace`, PISP still writes the lightweight `Generator_n_sched` and `ESS_n_sched` schedules. Heavier trace-dependent schedules are skipped in that mode.

## Common interpretation rules

- Join schedule rows to static rows by the relevant asset ID and `scenario`.
- Use `date` as the timestamp at which the scheduled `value` applies.
- Treat `value` units according to the scheduled column; the column name alone is not enough.
- Multiply static or scheduled `pmax`, `lmax`, `fwcap`, and `rvcap` by the corresponding `n` value when modelling available units/circuits.
- Do not infer forced-outage time series from the schedule tables. Outage quantities are static fields on `Generator`, `ESS`, or `Line` rows.
