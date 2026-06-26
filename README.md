# ParseISP.jl: Julia parser of the Integrated System Plan
[![Build Status](https://github.com/airampg/ParseISP.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/airampg/ParseISP.jl/actions/workflows/CI.yml?query=branch%3Amain)

**ParseISP** (short for *Julia Parser of the Integrated System Plan*) is an open-source toolkit for parsing and generating structured datasets of the East Coast Australian Power System for power system studies. 

The data parsing functionalities are built on publicly available information from the Integrated System Plan (ISP) released by the Australian Energy Market Operator (AEMO) for the Australian National Electricity Market (NEM).

> [!CAUTION]
> The current release is fully functional and has been extensively tested; however, bugs or other issues may still arise. We would greatly appreciate any feedback or bug reports submitted via https://github.com/airampg/ParseISP.jl/issues

## Core function
Dataset construction in ParseISP is performed through the release-dispatched high-level function `build_datasets(release; kwargs...)`. Supported release adapters are `ISP2024()` and `ISP2026()`.

Compatibility wrappers remain available:

- `build_ISP24_datasets(; kwargs...)` calls `build_datasets(ISP2024(); kwargs...)`.
- `build_ISP26_datasets(; kwargs...)` calls `build_datasets(ISP2026(); kwargs...)`.

## Release guides
For release-specific examples and setup notes, see:

- [ISP2026 tutorial](docs/isp2026.md)
- [ISP2024 examples](docs/isp2024.md)

## ISP2026 quick start
ISP2026 dataset construction is exposed through `ParseISP.build_datasets(ParseISP.ISP2026(); ...)`. The downloader, `ParseISP.download_isp26_source_files(downloadpath; kwargs...)`, obtains the 2026 ISP input artefacts and the AEMO 2025 IASR EV workbook referenced by the 2026 Inputs and Assumptions workbook.

For ISP2026, `years = [Y]` means the financial year from `Y-07-01` through `Y+1-06-30`. Supported values are `2026:2050`, mapping to FY2026-27 through FY2050-51.

```julia
using ParseISP

ParseISP.build_datasets(
    ParseISP.ISP2026(),
    downloadpath = joinpath(@__DIR__, "..", "data", "parseisp-downloads"),
    years        = [2026], # FY2026-27
    output_root  = joinpath(@__DIR__, "..", "data", "parseisp-datasets"),
    write_csv    = true,
    write_arrow  = false,
)
```

## Optional parameters for ParseISP.build_datasets
`build_datasets(release; kwargs...)` accepts the following keyword arguments. One of `years` or `drange` must be supplied.

| Parameter | Default | Available for | Description |
| --- | --- | --- | --- |
| `downloadpath` | `"../../data-download"` | ISP2024, ISP2026 | Path where AEMO source files are downloaded, extracted, and prepared. |
| `download_from_AEMO` | `true` | ISP2024, ISP2026 | Whether to download source files from AEMO before building. |
| `poe` | `10` | ISP2024, ISP2026 | Probability of exceedance for demand: `10` or `50`. |
| `reftrace` | `4006` | ISP2024, ISP2026 | Reference weather trace. ISP2024 supports `2011:2023` or `4006`; ISP2026 uses the trace ID when preparing the 2026 trace inputs. |
| `years` | `nothing` | ISP2024, ISP2026 | Full-period schedules to build. ISP2024 accepts calendar/planning years `2025:2050`; ISP2026 accepts financial-year start years `2026:2050`. Mutually exclusive with `drange`. |
| `drange` | `nothing` | ISP2024, ISP2026 | Alternative to `years`. Array of `(start, end)` tuples using `Date`, `DateTime`, or strings in `"DD-MM-YYYY"` format. Output folders are named `schedule-DDMMYYYY-DDMMYYYY`. Mutually exclusive with `years`. |
| `output_name` | `"out"` / `"out-isp2026"` | ISP2024, ISP2026 | Output folder name prefix. The default is `"out"` for ISP2024 and `"out-isp2026"` for ISP2026. |
| `output_root` | `nothing` | ISP2024, ISP2026 | Optional output folder root. |
| `write_csv` | `true` | ISP2024, ISP2026 | Whether to write CSV files. |
| `write_arrow` | `true` | ISP2024, ISP2026 | Whether to write Arrow files. |
| `scenarios` | `[1,2,3]` | ISP2024, ISP2026 | Scenario IDs to include. ISP2024: `1` Progressive Change, `2` Step Change, `3` Green Energy Exports. ISP2026: `1` Slower Growth, `2` Step Change, `3` Accelerated Transition. |
| `write_traces` | `true` | ISP2024 | Whether to compute and write time-varying trace outputs. |
| `check_exist_trace` | `false` | ISP2024 | When `true`, skip trace computation for a schedule whose key trace outputs already exist. |
| `buildout_filepath` | `nothing` | ISP2024 | Optional Excel workbook containing buildout schedules to apply after static tables are populated. |
| `sc_buildouts` | empty dictionary | ISP2024 | Optional scenario-to-sheet mapping for `buildout_filepath`. |
| `prepare_outlook` | `true` | ISP2026 | Whether to prepare generation, storage, and REZ outlook auxiliary workbooks from the 2026 ISP outlook ZIP. |
| `prepare_supporting_assets` | `download_from_AEMO` | ISP2026 | Whether to extract downloaded 2026 ISP archives and prepare local supporting files before parsing. |
| `build_traces` | `true` | ISP2026 | Whether to prepare demand, rooftop PV, VRE, hydro, and other trace inputs before parsing. |
| `scenario_map` | empty dictionary | ISP2026 | Optional scenario-name overrides used when preparing 2026 ISP outlook support assets. |


## Description of dataset formatting
Below, an overview of each of the databases the parser produces is given.
## Files description
> [!NOTE] 
> **NEM12**: Time-static information
> - Bus
> - Demand
> - DER
> - ESS
> - Generator
> - Line

## Time-varying parameters

> [!IMPORTANT] 
> **Schedule**: Time-varying parameters
> - Demand_load_sched: `value` load (MW) at a given `date`. Match with column `load_` from Demand
> - DER_pred_sched: `value` pred (MW) starting at a given `date`. Match with column `pred` from DER
>   - `pred`: Maximum load reduction capacity (MW)
> - ESS_emax_sched: `value` emax (MWh) starting at a given `date`. Match with column `emax` from ESS
>   - `emax`: Maximum storage energy (MWh).
> - ESS_inflow_sched: approximate energy inflow (MWh), for one unit `n` (ESS.n column) of each hydro storage at a given `date`. 
> - ESS_lmax_sched: `value` lmax (MW) starting at a given `date`. Match with column `lmax` from ESS
>   - `lmax`: Maximum storage charge input (MW) *[as a load]*.
> - ESS_n_sched: `value` n (p.u.) starting at a given `date`. Match with column `n` from Generator
>   - `n`: Maximum number of online units
> - ESS_pmax_sched: `value` pmax (MW) starting at a given `date`. Match with column `pmax` from ESS
>   - `pmax`: Maximum storage discharge output (MW).
> - Generator_inflow_sched: approximate energy inflow (MWh), for one unit `n` (Generators.n column) of each hydro generator at a given `date`. 
> - Generator_pmax_sched: `value` pmax (MW) at a given `date`. Match with column `pmax` from Generator
>   - `pmax`: Maximum generator output (MW).
> - Generator_n_sched: `value` n (p.u.) starting at a given `date`. Match with column `n` from Generator
>   - `n`: Maximum number of online units
> - Line_fwcap_sched: `value` fwcap (MW) starting at a given `date`. Match with column `fwcap` from Line
>   - `fwcap`: Maximum line forward rating (MW)
> - Line_rvcap_sched: `value` rvcap (MW) starting at a given `date`. Match with column `rvcap` from Line
>   - `rvcap`: Maximum line reverse rating (MW)


## Relevant calculations

> [!IMPORTANT] 
> *Calculations using parameters from the corresponding tables*
> - **Generator**: 
>   - Maximum generation output = `pmax` * `n`
>   - Minimum generation output = `pmin` * `n`
> - **ESS**: 
>   - Maximum discharging output = `pmax` * `n`
>   - Maximum charging input = `lmax` * `n`
>   - Minimum discharging output = `pmin` * `n`
>   - Minimum charging input = `lmin` * `n`
>   - Minimum state of charge = `emin` (%) * `emax` (MW)
>   - Initial state of charge in $t=1$ = `eini` (%) * `emax` (MW)
> - **Line**: 
>   - Maximum forward capacity output = `fwcap` * `n`
>   - Maximum reverse capacity output = `rvcap` * `n`

## Time-static parameters in each database

### Bus
| Parameter       | Description |  
|-----------------|-------------|
| `id_bus`            | id of the bus | 
| `active`        | Active flag (1: active; 0: inactive) | 
| `id_area`       | Area of the 5-bus NEM  market model (1: QLD; 2:NSW; 3:VIC; 4:TAS; 5:SA) | 

### Demand
| Parameter       | Description |  
|-----------------|-------------|
| `id_dem`            | id of the bus | 
| `load_`        | Load (MW) | 
| `id_bus`       | Bus the demand is connected to (match with `id_bus` from **Bus** table) | 
| `active`        | Active flag (1:active; 0:inactive) | 
| `controllable`      | Controllable flag (1:controllable; 0:non-controllable) | 
| `voll`       | Value of Lost Load ($/MWh) | 

### DER
| Parameter       | Description |  
|-----------------|-------------|
| `id_der`            | id of the DER | 
| `name`        | Name of the DER | 
| `tech`       | Technology (DSP: demand-side participation) | 
| `id_dem`       | Demand the DER is attached to (match with `id_dem` from **Demand** table) | 
| `active`        | Active flag (1:active; 0:inactive) | 
| `capacity`      | Capacity of the DER service (MW) | 
| `reduct`       | Reduction flag (1:yes, 0:no) | 
| `pred_max`       | Maximum capacity reduction (MW) | 
| `cost_red`       | Cost associated with the reduction ($/MWh) | 

### ESS
| Parameter       | Description |  
|-----------------|-------------|
| `id_ess`            | id of the ESS | 
| `tech`            | Technology (BESS: battery; PS: pumped hydro) | 
| `type`       | Type of storage (SHALLOW, MEDIUM, DEEP) | 
| `investment`      | Investment flag (1:investment; 0:non-investment) | 
| `active`        | Active flag (1:active; 0:inactive) | 
| `id_bus`       | Bus the ESS is connected to (match with `id_bus` from **Bus** table) | 
| `ch_eff`       | Charging efficiency (%) | 
| `dch_eff`       | Discharging efficiency (%) | 
| `eini`       | Initial energy capacity (% of `emax`) | 
| `emin`       | Minimum energy capacity (% of `emax`)| 
| `emax`       | Maximum energy capacity (MWh) | 
| `pmin`       | Minimum discharging power (MW) | 
| `pmax`       | Maximum discharging power (MW) | 
| `lmin`       | Minimum charging power (MW) | 
| `lmax`       | Maximum charging power (MW) | 
| `fullout`       | Forced outage rate - full outage (% of time in decimal form)| 
| `partialout`       |  Forced outage rate - partial outage (% of time in decimal form)| 
| `mttrfull`       | Mean time to repair - full outage (hr) | 
| `mttrpart`       | Mean time to repair - partial outage (hr) |
| `n`       | Maximum number of units online (p.u) | 

### Generator
| Parameter       | Description |  
|-----------------|-------------|
| `id`            | id of the generator | 
| `fuel`        | Fuel type | 
| `tech`            | Generator technology | 
| `type`       | Generator type | 
| `forate`       | Outage rate (%) `forate =` $\ \  1-(\mathcal{F}+\mathcal{P}(1-\alpha))$ ; $\mathcal{F}$, $\mathcal{P}$ full/partial outage rates, $\alpha$ derating factor| 
| `fullout`       | Forced outage rate - full outage (% of time in decimal form)| 
| `partialout`       |  Forced outage rate - partial outage (% of time in decimal form)| 
| `derate`      | Partial outage derating factor (% in decimal form)
| `mttrfull`       | Mean time to repair - full outage (hr) | 
| `mttrpart`       | Mean time to repair - partial outage (hr) |
| `bus_id`      | Bus the generator is connected to (match with `id_bus` from **Bus** table) | 
| `pmin`      | Minimum power output (MW)| 
| `pmax`      | Maximum power output (MW)| 
| `rup`      | Ramp-up capacity (MW/min)| 
| `rdw`      | Ramp-down capacity (MW/min)| 
| `investment`      | Investment flag (1:investment; 0:non-investment) | 
| `active`      | Active flag (1:active; 0:inactive) | 
| `cvar`      | Variable cost ($/MWh)| 
| `cfuel`      | Fuel cost ($/GJ)| 
| `cvom`      | Variable operation and maintenance cost ($/MWh)| 
| `cfom`      | Fixed operation and maintenance cost ($/MWh/yr)| 
| `co2`      | CO2 emmissions (kgC02/MWh)| 
| `hrate`      | Heat rate (MWh/GJ) | 
| `pfrmax`      | Maximum headroom (MW) | 
| `ffr` | Fast frequency response provision flag |
| `pfr` | Primary frequency response provision flag |
| `res2` | Secondary reserve provision flag |
| `res3` | Tertiary (Regulation) reserve provision flag | 
| `n`      | Maximum number of units online (p.u.)| 
| `down_time`       | Minimum down time after being shut-down (h) | 
| `up_time`       |  Minimum up time after being started (h)| 
| `start_up_cost`      | Start-up cost ($) | 
| `shut_down_cost`      | Shut-down cost ($)| 
| `start_up_time`      | Time to start-up units (h)| 
| `shut_down_time`      | Time to shut-down units (h)| 

- Forced Outage Rate (%) - The percentage of time per year that a generator is expected to be out of service due to forced outage.
- Mean time to repair (hrs) - The average time take to return a generating unit to service
- Partial Outage Derating Factor - The loss of capacity during a partial outage, relative to generator unit rating. If the outage factor is 20%, the generator will operate at 80% capacity during a partial outage.
### Line
| Parameter       | Description |  
|-----------------|-------------|
| `id`            | id of the line | 
| `tech`        | Technology | 
| `capacity`            | Maximum capacity | 
| `id_bus_from`       | Bus the line starts (match with `id_bus` from **Bus** table) | 
| `id_bus_to`       | Bus the line ends (match with `id_bus` from **Bus** table) | 
| `investment`      | Investment flag (1:investment; 0:non-investment) | 
| `active`      | Active flag (1:active; 0:inactive) | 
| `rvcap`     | Maximum reverse capacity bus_a $\rightarrow$ bus_b (MW)| 
| `fwcap`     | Maximum forward capacity bus_b $\rightarrow$ bus_a (MW)| 
| `fullout`       | Unplanned outage rate - single credible contingency (% of time in decimal form)| 
| `mttrfull`       | Mean time to repair - single credible contingency (hr) | 
| `n`      | Maximum number of units online (p.u.)| 


## Data sources of ParseISP
> [!IMPORTANT] 
> All the datasets that ParseISP generates are based on publicly available data from AEMO. 
>
> 2024 ISP files are obtained from: https://www.aemo.com.au/energy-systems/major-publications/integrated-system-plan-isp/2024-integrated-system-plan-isp
> - 2024 Integrated System Plan **Inputs and Assumptions workbook**
> - 2024 Integrated System Plan **generation and storage outlook**
> - 2024 Integrated System Plan **Model**
> - 2024 Integrated System Plan **Demand & Variable Renewable Energy trace data**
>
> Final 2026 ISP files are obtained from AEMO final 2026 ISP supporting material and model artefacts:
> - 2026 Integrated System Plan **Inputs and Assumptions workbook**
> - 2026 Integrated System Plan **generation and storage outlook**
> - 2026 Integrated System Plan **Model**
> - 2026 Integrated System Plan **solar trace archive**
> - 2026 Integrated System Plan **wind trace archive**
> - 2025 IASR **EV workbook**, required support data because it is referenced by the final 2026 ISP workbook
