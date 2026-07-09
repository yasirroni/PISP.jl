# PISP documentation maintenance

The human-facing documentation lives under `docs/src/` and is built with Documenter.jl. Literate tutorial sources live under `docs/literate/` and render into committed Markdown under `docs/src/generated/`.

## Build the site

From the repository root:

```sh
julia --project=docs docs/make.jl
```

Open `docs/build/index.html` after the build completes.

`docs/make.jl` does not regenerate Literate pages and does not require local AEMO/PISP output data. It publishes the committed Markdown already present in `docs/src/generated/`.

## Regenerate Literate tutorials

From the repository root:

```sh
julia --project=docs docs/render_literate.jl
```

`docs/literate/problem_table.jl` is data-free. `docs/literate/pisp_outputs_validation.jl` requires a local example output build at:

```text
data/pisp-datasets/out-ref4006-poe10/csv/
```

including:

```text
data/pisp-datasets/out-ref4006-poe10/csv/schedule-2030/
```

When that data is absent, regenerate only after producing the local PISP output build or expect `docs/render_literate.jl` to fail with a named precondition error.

## Page ownership

| Path | Purpose |
|---|---|
| `docs/src/index.md` | Human overview and navigation. |
| `docs/src/data-sources.md` | Encoded source inputs and local input layout. |
| `docs/src/concepts.md` | Scenario, trace, bus, and schedule concepts. |
| `docs/src/outputs.md` | Exported table names and schema interpretation. |
| `docs/src/parameters.md` | Package constants, mappings, and hard-coded assumptions. |
| `docs/src/assumptions.md` | Modelling scope and caveats. |
| `docs/src/api.md` | Documenter `@docs` references. |
| `docs/literate/*.jl` | Executable tutorial sources. |
| `docs/src/generated/*.md` | Committed rendered tutorial pages. |

Keep build mechanics, regeneration commands, and local-data preconditions in this file or in source comments. Avoid putting them at the top of rendered tutorial pages unless the reader needs the precondition to run the tutorial.
