# Caveats

PISP outputs are structured planning datasets, not a validated power-system case for every downstream purpose.
Before using them in an optimisation, simulation, or reliability study, review the following boundaries:

- The network is an aggregated 12-bus ISP representation rather than a detailed nodal AC model.
- Source files span the 2024 ISP, a 2023 EV workbook, and a targeted 2019 thermal-unit input.
- Package mappings and placeholders can materially affect technology classification, asset identity, capacity interpretation, and trace selection.
- Forced-outage quantities are static inputs; PISP does not generate chronological outage events.
- Static generator capacity is not a valid capacity-factor denominator for rooftop PV or future-year utility-scale solar and wind schedules.

See [Assumptions and scope](@ref) for the full modelling boundary, [Parameters and mappings](@ref) for the encoded assumptions, and [Data sources](@ref) for provenance and source-vintage details.
