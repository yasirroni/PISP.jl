function build_line_invoptions_from_canonical!(ts::ParseISPtimeStatic, canonical::DataFrame)
    maxidlin = isempty(ts.line) ? 0 : maximum(ts.line.id_lin)
    idx = 0
    for row in eachrow(canonical)
        maxidlin += 1
        idx += 1
        invname = "NL_$(row.idbusA)$(row.idbusB)_INV$(idx)"
        vline = [maxidlin, row.name, invname, "DC", max(row.fwd, row.rev), row.idbusA, row.idbusB, row.active, row.active, 0.01, 0.1, row.rev, row.fwd, 0, 1, 220, 1, "", "", 1, 1, 0]
        push!(ts.line, vline)
    end
    return ts
end
