# The helper test/src/unicode.jl and test/src/unicode_case.jl share (each file includes this into its own
# module): a table of a pinned C file, read again entry for entry, the guard against a copied table regenerated or
# edited.
using Test

# the pinned file's table `decl` (its declaration line, utf8proc_data.c's or another C file's), its entries in order, each token as it stands
function pinned_entries(lines::Vector{String}, decl::String)::Vector{String}
    local i = findfirst(==(decl), lines)
    @test i !== nothing
    local out = String[]
    while true
        i += 1
        local l = lines[i]
        append!(out, filter(!isempty, strip.(split(replace(l, "};" => ""), ','))))
        endswith(rstrip(l), "};") && return out
    end
end
