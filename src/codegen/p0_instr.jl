# THROWAWAY (batch 116a Part 0 instrumentation; never landed)
const P0 = Dict{String,Int}()
const P0EX = Dict{String,Vector{String}}()
const P0_REG = Ref(false)
const P0_NOMETHOD = IdDict{Any,Set{Any}}()      # callee type -> args tuples the collector recorded
const P0_CLASSES = Ref{Any}(Any[])               # the candidates' class set of the last collection
function __init__()
    empty!(P0); empty!(P0EX)
    atexit(p0_dump)
end
function p0!(key::AbstractString, ex::AbstractString="")
    k = String(key)
    P0[k] = get(P0, k, 0) + 1
    if !isempty(ex)
        v = get!(() -> String[], P0EX, k)
        e = first(String(ex), 400)
        length(v) < 6 && !(e in v) && push!(v, e)
    end
    nothing
end
function p0_dump()
    io = stderr
    println(io, "P0BEGIN")
    for k in sort!(collect(keys(P0)))
        println(io, "P0\t", k, "\t", P0[k])
        for e in get(P0EX, k, String[])
            println(io, "P0EX\t", k, "\t", replace(e, '\n' => ' '))
        end
    end
    println(io, "P0END")
end
p0_table() = Core.Compiler.method_table(get_wasm_interpreter())
_p0_meths(ms) = ms === nothing ? "nothing" : string([ (m.method, m.spec_types) for m in ms ])
# a Base-table consult and the overlay table's answer, compared
function p0_hasmethod(site::String, g, T)
    sig = Base.signature_type(g, T)
    b = hasmethod(g, T)
    o = Core.Compiler.findsup(sig, p0_table())[1] !== nothing
    oe = begin ms = Core.Compiler.findall(sig, p0_table(); limit=-1); ms !== nothing && !isempty(ms) end
    p0!("P0D site=$site findsup=" * (b == o ? "agree" : "DIFFER"), b == o ? "" : "$sig base=$b overlay=$o")
    p0!("P0D site=$site nonempty=" * (b == oe ? "agree" : "DIFFER"), b == oe ? "" : "$sig base=$b overlay=$oe")
    return b
end
function p0_which(site::String, g, T)
    sig = Base.signature_type(g, T)
    b = which(g, T)
    om = Core.Compiler.findsup(sig, p0_table())[1]
    o = om === nothing ? nothing : om.method
    p0!("P0D site=$site which=" * (b === o ? "agree" : "DIFFER"), b === o ? "" : "$sig base=$b overlay=$o")
    return b
end
function p0_mbf(site::String, sig, mt, lim, world)
    b = Base._methods_by_ftype(sig, mt, lim, world)
    o = Core.Compiler.findall(sig, p0_table(); limit=lim)
    bs = b === nothing ? nothing : [(m.method, m.spec_types, m.sparams) for m in b]
    os = o === nothing ? nothing : [(m.method, m.spec_types, m.sparams) for m in o]
    p0!("P0D site=$site mbf=" * (isequal(bs, os) ? "agree" : "DIFFER"),
        isequal(bs, os) ? "" : "$sig base=$(_p0_meths(b)) overlay=$(_p0_meths(o))")
    return b
end
function p0_uwhich(site::String, sig)
    b = Base._which(sig; raise=false)
    o = Core.Compiler.findsup(sig, p0_table())[1]
    bm = b === nothing ? nothing : b.method
    om = o === nothing ? nothing : o.method
    p0!("P0D site=$site _which=" * (bm === om ? "agree" : "DIFFER"), bm === om ? "" : "$sig base=$bm overlay=$om")
    return b
end
function p0_isamb(site::String, ma, mb)
    b = Base.isambiguous(ma, mb)
    ti = typeintersect(ma.sig, mb.sig)
    ov = ti === Union{} ? 0 : length(Base._methods_by_ftype(ti, WASM_METHOD_TABLE, -1, Base.get_world_counter()))
    p0!("P0D site=$site isambiguous=$(b) overlay_methods_in_intersection=$(ov)", "$ma | $mb")
    return b
end
function p0_irget(site::String, cache, mi)
    h = get(cache, mi, nothing)
    p0!("P0B site=$site key=$(mi isa Core.MethodInstance ? "mi" : "OTHER") " * (h === nothing ? "miss" : "hit"),
        h === nothing ? string(mi) : "")
    return h
end
