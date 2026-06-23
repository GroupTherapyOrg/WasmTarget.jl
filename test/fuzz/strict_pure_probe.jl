# Investigation: how much would "maximally pure" strict mode reject?
#
# "Pure" = make the native-throws stubs (Category B) fatal: any call whose INFERRED
# return type is `Union{}` (an always-throws helper — DomainError/BoundsError/kwerr arms
# Julia's IR couldn't prove dead) becomes a hard WasmCompileError instead of a silent
# `unreachable`. This script measures the blast radius WITHOUT changing WT behavior: for
# a corpus of ordinary functions, it collects the closed world and counts the throw-arms
# pure would choke on — i.e. exactly the functions pure would refuse to compile.
#
# Run: julia --project=. test/fuzz/strict_pure_probe.jl

using WasmTarget
const WT = WasmTarget
const CC = Core.Compiler

# ── corpus of ORDINARY code (the kind real notebooks/algorithms write) ──────────
sq(x::Float64)        = sqrt(x)
lg(x::Float64)        = log(x)
invx(x::Float64)      = 1.0 / x
divi(x::Int64)        = div(x, 3)
remi(x::Int64)        = x % 7
idx1(v::Vector{Int64})   = v[1]
idxn(v::Vector{Int64})   = v[end]
summ(v::Vector{Float64}) = sum(v)
maxx(v::Vector{Float64}) = maximum(v)
strcat(s::String)     = s * "x"
strlen(s::String)     = length(s)
powi(x::Int64)        = x ^ 3
absf(x::Float64)      = abs(x)
clamp01(x::Float64)   = clamp(x, 0.0, 1.0)
parsei(s::String)     = parse(Int, s)
floori(x::Float64)    = floor(Int, x)
muladdf(x::Float64)   = muladd(x, 2.0, 1.0)
sortv(v::Vector{Int64}) = sort(v)
pure_arith(x::Int64)  = x*x + 2x - 1           # should be CLEAN (no throw arms)
pure_float(x::Float64)= x*0.5 + 1.0            # should be CLEAN

const CORPUS = [
    ("sqrt", sq, (Float64,)), ("log", lg, (Float64,)), ("inv 1/x", invx, (Float64,)),
    ("div(x,3)", divi, (Int64,)), ("x % 7", remi, (Int64,)),
    ("v[1]", idx1, (Vector{Int64},)), ("v[end]", idxn, (Vector{Int64},)),
    ("sum(v)", summ, (Vector{Float64},)), ("maximum(v)", maxx, (Vector{Float64},)),
    ("s*\"x\"", strcat, (String,)), ("length(s)", strlen, (String,)),
    ("x^3", powi, (Int64,)), ("abs(x)", absf, (Float64,)), ("clamp", clamp01, (Float64,)),
    ("parse(Int,s)", parsei, (String,)), ("floor(Int,x)", floori, (Float64,)),
    ("muladd", muladdf, (Float64,)), ("sort(v)", sortv, (Vector{Int64},)),
    ("x*x+2x-1", pure_arith, (Int64,)), ("x*0.5+1", pure_float, (Float64,)),
]

# A call statement whose inferred type is Union{} = an always-throws helper (the
# Category-B trigger). Returns the throwing callees found in one function's IR.
function throw_arms(src::Core.CodeInfo)
    out = String[]
    ssat = src.ssavaluetypes
    ssat isa Vector || return out
    for (k, stmt) in enumerate(src.code)
        stmt isa Expr || continue
        (stmt.head === :call || stmt.head === :invoke) || continue
        t = k <= length(ssat) ? ssat[k] : Any
        t === Union{} || continue
        cref = stmt.head === :invoke ? (stmt.args[1] isa Core.MethodInstance ? stmt.args[1] :
                  (length(stmt.args) >= 2 ? stmt.args[2] : stmt.args[1])) :
                  (length(stmt.args) >= 1 ? stmt.args[1] : nothing)
        nm = cref isa GlobalRef ? string(cref.name) :
             cref isa Core.MethodInstance ? string(cref.def.name) : string(cref)
        push!(out, nm)
    end
    return out
end

function run_probe()
    println("="^78)
    println("PURE-STRICT BLAST-RADIUS PROBE — would 'maximally pure' reject ordinary code?")
    println("(rejected = ANY function in its closed world has an always-throws arm)")
    println("="^78)
    nrej = 0
    for (label, f, argt) in CORPUS
        rejected = false; allarms = String[]; npairs = 0
        try
            mi = WT.entry_method_instance(f, argt)
            ci = WT.collect_closed_world(Any[mi])
            npairs = length(ci) ÷ 2
            i = 1
            while i + 1 <= length(ci)
                c, src = ci[i], ci[i+1]; i += 2
                (c isa Core.CodeInstance && src isa Core.CodeInfo) || continue
                append!(allarms, throw_arms(src))
            end
            rejected = !isempty(allarms)
        catch e
            println(rpad(label, 16), "  COLLECT-ERROR: ", first(split(string(e), "\n")))
            continue
        end
        nrej += rejected ? 1 : 0
        mark = rejected ? "✗ REJECTED" : "✓ ok      "
        uarms = unique(allarms)
        arms = isempty(uarms) ? "" : "  ← throws: " * join(first(uarms, 6), ", ") * (length(uarms) > 6 ? " …" : "")
        println(rpad(label, 16), " ", mark, "  (", npairs, " fns, ", length(allarms), " arms)", arms)
    end
    println("="^78)
    println("PURE would REJECT $nrej / $(length(CORPUS)) ordinary functions.")
    println("="^78)
end

run_probe()
