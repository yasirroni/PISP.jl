# PISP.jl

PISP.jl parses public AEMO Integrated System Plan material into structured power-system datasets for the National Electricity Market (NEM). It is a dataset builder, not a dispatch or optimisation model: it prepares static network and asset tables, hourly schedules, and scenario/time metadata that can be consumed by downstream modelling tools.

The current build path targets the 2024 Integrated System Plan. Its high-level entry point is `PISP.build_ISP24_datasets(; kwargs...)`, which can build either whole planning years (`years`) or explicit date windows (`drange`). PISP splits each requested time span at the 1 July Australian financial-year boundary where the underlying ISP inputs require that convention.

## What the package produces

A normal build writes two groups of output tables, in CSV and/or Arrow format:

| Output group | Location pattern | Contents |
|---|---|---|
| Static tables | `<output_name>-ref<reftrace>-poe<poe>/csv/` or `/arrow/` | `Bus`, `Demand`, `DER`, `ESS`, `Generator`, and `Line` tables. |
| Schedule tables | `<output_name>-ref<reftrace>-poe<poe>/csv/schedule-<tag>/` or `/arrow/schedule-<tag>/` | Hourly or dated schedules such as demand load, generator PMax, unit counts, line transfer limits, storage limits, inflows, and DER prediction. |

See [Output tables](@ref) for the exported schemas and schedule naming conventions.

## Core concepts

PISP organises each build by scenario, time window, and trace year. The package uses the three 2024 ISP scenarios, a 12-bus NEM sub-regional representation, and trace inputs selected by `reftrace` and `poe`. See [Domain concepts](@ref) for the conventions that determine how tables and schedules should be interpreted.

## Data and caveats

The package combines downloaded AEMO workbooks/archives with a small set of package constants and hard-coded mappings. Those constants are part of the dataset definition, not incidental implementation details. See:

- [Data sources](@ref) for the encoded AEMO inputs and local input layout.
- [Parameters and mappings](@ref) for scenario IDs, bus/area mappings, trace-year mappings, and selected hard-coded assumptions.
- [Assumptions and scope](@ref) for modelling boundaries before using PISP output in a study.

## Tutorials

[Building a `PISPtimeConfig` problem table](@ref) explains the scenario/time table that PISP builds before reading AEMO files. It runs entirely in memory.

[Validating PISP-produced outputs against demand](@ref) inspects a local PISP output build and compares daily aggregate solar PMax, wind PMax, and demand. This page requires the example output data described in [Data sources](@ref).

## API reference

See [API Reference](@ref) for the public entry point and the problem-table helpers used by the tutorials.
