# dev/climb/spans.jl — the lines a definition spans, read by Julia's parser (Meta.parseall), for dev/climb/climb.py's
# judge of a move (council round 3, architect 14): "the diff works on the definition" is a hunk that overlaps the
# definition's lines, never its name somewhere in the diff's text.
#
#   julia --startup-file=no dev/climb/spans.jl < queries
#
# Each query is a line `<id>\t<file>\t<name>` (the top-level forms of <file> that define <name>) or
# `<id>\t<file>\t:<line>` (the top-level form holding <line>); each answer a line `<id>\t<first line>\t<last line>`,
# one per form found, none when no form matches. A top-level form spans from its own line to the line before the
# next form (the file's last line for the last), its docstring and its macro calls (@parity, @quarantine) with it.

defined(x::Symbol) = [x]
defined(x::Expr) =
    x.head in (:call, :where, :(::), :curly, :<:) ? defined(x.args[1]) :
    x.head === :. ? [x.args[2] isa QuoteNode ? x.args[2].value : x.args[2]] : Symbol[]
defined(x) = Symbol[]

# the names a top-level form defines: a function (long or short form), a struct, an abstract or primitive type, a
# const or global, through any macro call or docstring that wraps it
function defs_of(ex)::Vector{Symbol}
    ex isa Expr || return Symbol[]
    h = ex.head
    h === :macrocall && return reduce(vcat, (defs_of(a) for a in ex.args[2:end] if a isa Expr); init = Symbol[])
    h === :block && return reduce(vcat, (defs_of(a) for a in ex.args); init = Symbol[])
    (h === :function || h === :macro) && return defined(ex.args[1])
    h === :(=) && ex.args[1] isa Expr && ex.args[1].head in (:call, :where, :(::)) && return defined(ex.args[1])
    (h === :const || h === :global) && return defs_of(ex.args[1])
    h === :(=) && return defined(ex.args[1])
    h === :struct && return defined(ex.args[2])
    (h === :abstract || h === :primitive) && return defined(ex.args[1])
    return Symbol[]
end

# each top-level form of a file with its first and last line
function forms(path)
    text = read(path, String)
    top = Meta.parseall(text; filename = path)
    nlines = count(==('\n'), text) + 1
    out, line = Tuple{Any,Int}[], 0
    for a in top.args
        a isa LineNumberNode ? (line = a.line) : push!(out, (a, line))
    end
    return [(ex, l, i < length(out) ? out[i+1][2] - 1 : nlines) for (i, (ex, l)) in enumerate(out)]
end

cache = Dict{String,Any}()
for q in eachline(stdin)
    isempty(q) && continue
    id, file, what = split(q, '\t'; limit = 3)
    fs = get!(() -> isfile(file) ? forms(file) : [], cache, file)
    for (ex, a, b) in fs
        hit = startswith(what, ':') ? a <= parse(Int, what[2:end]) <= b : Symbol(what) in defs_of(ex)
        hit && println(id, '\t', a, '\t', b)
    end
end
