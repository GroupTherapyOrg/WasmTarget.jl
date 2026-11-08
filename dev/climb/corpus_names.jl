# dev/climb/corpus_names.jl — the names a corpus file binds at top level, read by Julia's own parser
# (Meta.parseall), for dev/climb/climb.py's G5: an added corpus line may define a new name, never rebind one the
# corpus already binds (audit 97, A97E2: a regex missed @noinline, typed-return, dotted, const and struct forms).
#
#   julia --startup-file=no dev/climb/corpus_names.jl <base.jl> <new.jl>
#
# prints `rebind\t<name>\t<count in base>\t<count in new>` for each name the new file binds more often than the base,
# and `form\t<kind>\t<text>` for each top-level form the new file adds that is no definition or registration: a
# rebind inside let, if, for, module or @eval would pass a walk of the definitions (audit 98, A98E3), so an added
# top-level form is one of the kinds the corpus is made of, or it is refused.

bound_name(x::Symbol) = string(x)
bound_name(x::Expr) =
    x.head in (:call, :where, :(::), :curly, :<:) ? bound_name(x.args[1]) :
    x.head === :. ? string(bound_name(x.args[1]), ".", x.args[2] isa QuoteNode ? x.args[2].value : x.args[2]) :
    ""
bound_name(x) = ""

function names!(out, ex)
    ex isa Expr || return out
    h = ex.head
    if h === :toplevel || h === :block
        foreach(a -> names!(out, a), ex.args)
    elseif h === :macrocall   # @noinline f(x) = …, @inline function …, @kwdef struct …
        foreach(a -> names!(out, a), ex.args[2:end])
    elseif h === :function || h === :macro || (h === :(=) && ex.args[1] isa Expr && ex.args[1].head in (:call, :where, :(::)))
        n = bound_name(ex.args[1]); isempty(n) || (out[n] = get(out, n, 0) + 1)
    elseif h === :const || h === :global
        names!(out, ex.args[1])
    elseif h === :(=)
        n = bound_name(ex.args[1]); isempty(n) || (out[n] = get(out, n, 0) + 1)
    elseif h === :struct
        n = bound_name(ex.args[2]); isempty(n) || (out[n] = get(out, n, 0) + 1)
    elseif h === :abstract || h === :primitive
        n = bound_name(ex.args[1]); isempty(n) || (out[n] = get(out, n, 0) + 1)
    end
    return out
end

counts(path) = names!(Dict{String,Int}(), Meta.parseall(read(path, String); filename=path))

const ADDABLE = (:function, :(=), :struct, :const, :abstract, :primitive, :global)
const ADDABLE_MACROS = (Symbol("@noinline"), Symbol("@inline"), Symbol("@enum"))
const REGISTRATIONS = (:_g, :_xf, :_lazy_g, :_lazy_xf)
kind(ex) = ex isa Expr ? (ex.head === :call ? (ex.args[1] isa Symbol ? ex.args[1] : :call) :
                          ex.head === :macrocall ? ex.args[1] : ex.head) : :literal
addable(ex) = !(ex isa Expr) || ex.head in ADDABLE || (ex.head === :call && ex.args[1] in REGISTRATIONS) ||
              (ex.head === :macrocall && ex.args[1] in ADDABLE_MACROS)
# a form compared without its line numbers, a macro call's among them (they name the file and the line, which an
# insertion above the form shifts)
nolines(x) = x isa Expr ? Expr(x.head, (a isa LineNumberNode ? nothing : nolines(a) for a in x.args)...) : x
forms(path) = [nolines(a) for a in Meta.parseall(read(path, String); filename=path).args if !(a isa LineNumberNode)]

base, new = counts(ARGS[1]), counts(ARGS[2])
for (n, c) in sort!(collect(new))
    b = get(base, n, 0)
    b > 0 && c > b && println("rebind\t", n, "\t", b, "\t", c)
end
old = Set(string.(forms(ARGS[1])))
for ex in forms(ARGS[2])
    string(ex) in old || addable(ex) || println("form\t", kind(ex), "\t", replace(first(string(ex), 80), "\n" => " "))
end
