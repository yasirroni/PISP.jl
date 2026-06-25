function _reject_nonfinal_isp2026_path(path::AbstractString)
    normalized = lowercase(replace(string(path), "_" => "-", " " => "-"))
    if occursin("dr" * "aft-2026", normalized)
        throw(ArgumentError("Preliminary 2026 ISP artefacts are not supported. Use the final 25 June 2026 ISP file instead: $(path)"))
    end
    return nothing
end

function read_isp2026_line_invoptions_raw(ispdata26::AbstractString;
        sheetname::AbstractString = "Flow Path Augmentation options",
        range::AbstractString = "B11:O94")
    _reject_nonfinal_isp2026_path(ispdata26)
    return ParseISP.read_xlsx_with_header(ispdata26, sheetname, range)
end

function read_isp2026_outlook_entries(zip_path::AbstractString)
    _reject_nonfinal_isp2026_path(zip_path)
    isfile(zip_path) || error("2026 ISP outlook archive not found: $(zip_path)")
    entries = split(chomp(read(`unzip -Z -1 $zip_path`, String)), '\n')
    return String.(filter(!isempty, entries))
end

function read_isp2026_outlook_workbook(zip_path::AbstractString, entry::AbstractString,
        sheetname::AbstractString, range::AbstractString)
    _reject_nonfinal_isp2026_path(zip_path)
    bytes = read(`unzip -p $zip_path $entry`)
    return ParseISP.read_xlsx_with_header(IOBuffer(bytes), sheetname, range)
end
