# Wide corpus for the cleanup-loop DYNAMIC blast-radius probe.
#
# Each fix_* post-emission pass rewrites a specific byte pattern; this corpus is chosen to
# EXERCISE those patterns so neutralizing a pass (WT_NEUTRALIZE=<pass>) reveals which
# functions it actually compensates for. Deterministic; values not the point — VALIDITY +
# byte-identity-vs-baseline are. Reuses the frozen migration corpus + targeted additions.
include(joinpath(@__DIR__, "migration_corpus.jl"))   # brings WT, MIGRATION_CORPUS

struct _PPt; x::Float64; y::Float64; end
abstract type _PAnimal end
struct _PCat <: _PAnimal; lives::Int; end
struct _PDog <: _PAnimal; bark::Float64; end
_psound(c::_PCat) = c.lives * 2
_psound(d::_PDog) = d.bark + 1.0

const PROBE_EXTRA = Any[
  # ── array_len_wrap: length()/end on arrays (array_len returns i32, length()::Int64) ──
  ("p_len",      (v::Vector{Int64})-> length(v), (Vector{Int64},)),
  ("p_end",      (v::Vector{Float64})-> v[end], (Vector{Float64},)),
  ("p_lenarith", (v::Vector{Int64})-> length(v) * 2 + 1, (Vector{Int64},)),
  ("p_lastidx",  (v::Vector{Int64})-> v[length(v)], (Vector{Int64},)),
  ("p_sizeloop", function(v::Vector{Float64}); s=0.0; for i in 1:length(v); s+=v[i]; end; s; end, (Vector{Float64},)),
  # ── i32_wrap_after_i32_ops + i64_local_in_i32_ops: mixed int-width arithmetic ──
  ("p_i32chain", (x::Int32,y::Int32)-> (x + y) * Int32(3) - x, (Int32,Int32)),
  ("p_i64mix",   (a::Int64,b::Int32)-> a + Int64(b), (Int64,Int32)),
  ("p_widemul",  (a::Int32)-> Int64(a) * 2, (Int32,)),
  ("p_idxi32",   (v::Vector{Int64},i::Int32)-> v[Int64(i)], (Vector{Int64},Int32)),
  ("p_bitsi32",  (x::UInt32)-> (x << 2) ⊻ (x >> 1) & 0xff, (UInt32,)),
  # ── consecutive_local_sets + local_get_set_type_mismatch: reassign, type-changing locals ──
  ("p_reassign", function(x::Int64); a=x; a=a+1; a=a*2; a; end, (Int64,)),
  ("p_swap",     function(x::Int64,y::Int64); t=x; x=y; y=t; x-y; end, (Int64,Int64)),
  ("p_accumf",   function(n::Int64); s=0.0; t=0; for i in 1:n; s+=i; t+=1; end; s/t; end, (Int64,)),
  ("p_multiloc", function(x::Float64); a=x; b=a*2; c=b+a; d=c-b; a+b+c+d; end, (Float64,)),
  # ── broken_select_instructions: ternaries / ifelse, incl ref-producing ──
  ("p_selnum",   (x::Int64)-> x > 0 ? 10 : 20, (Int64,)),
  ("p_selref",   (x::Int64)-> x > 0 ? "pos" : "neg", (Int64,)),
  ("p_ifelse",   (x::Float64)-> ifelse(x > 0.0, x, -x), (Float64,)),
  ("p_selstruct",(b::Bool)-> b ? _PPt(1.0,2.0) : _PPt(3.0,4.0), (Bool,)),
  ("p_nestsel",  (x::Int64)-> x==0 ? 0 : (x<0 ? -1 : (x>10 ? 2 : 1)), (Int64,)),
  # ── numeric_to_ref_local_stores: union/boxing — number stored to a ref local ──
  ("p_union",    (x::Int64)-> (x>0 ? 1 : 2.5), (Int64,)),
  ("p_unionvec", function(x::Int64); a = x>0 ? 1 : 2.5; b = a; b; end, (Int64,)),
  ("p_anyret",   (x::Int64)-> x > 0 ? x : "neg", (Int64,)),
  ("p_dispatch", (a::_PAnimal)-> _psound(a), (_PAnimal,)),
  ("p_isa",      (a::_PAnimal)-> a isa _PCat ? 1 : 0, (_PAnimal,)),
  # ── broader real-shape code (string/dict/comprehension/struct/closure) ──
  ("p_strcat",   (n::Int64)-> string(n) * "!", (Int64,)),
  ("p_strjoin",  (v::Vector{Int64})-> join([string(x) for x in v], ","), (Vector{Int64},)),
  ("p_comp",     (n::Int64)-> sum([i*i for i in 1:n]), (Int64,)),
  ("p_filter",   (v::Vector{Int64})-> sum(filter(iseven, v)), (Vector{Int64},)),
  ("p_map",      (v::Vector{Float64})-> sum(map(sqrt, v)), (Vector{Float64},)),
  ("p_dictget",  function(); d=Dict(1=>2.0, 3=>4.0); d[1]+d[3]; end, ()),
  ("p_pushloop", function(n::Int64); a=Int64[]; for i in 1:n; push!(a,i*i); end; sum(a); end, (Int64,)),
  ("p_struct",   (x::Float64,y::Float64)-> sqrt(_PPt(x,y).x^2 + _PPt(x,y).y^2), (Float64,Float64)),
  ("p_closure",  function(n::Int64); f=x->x+n; f(10)+f(20); end, (Int64,)),
  ("p_tryc",     function(x::Int64); try; x ÷ 0; catch; -1; end; end, (Int64,)),
  ("p_float",    (x::Float64)-> x^2 - 3.0*x + 1.0, (Float64,)),
  ("p_i128",     (a::Int128,b::Int128)-> a*b + a - b, (Int128,Int128)),
]

const PROBE_CORPUS = vcat(MIGRATION_CORPUS, PROBE_EXTRA)

function probe_digest(io=stdout)
  for (nm, f, ts) in PROBE_CORPUS
    try
      w = WT.compile(f, ts)
      println(io, nm, " ", length(w), " ", bytes2hex(sha256(w)))
    catch e
      println(io, nm, " ERR ", first(replace(sprint(showerror, e), "\n"=>" "), 90))
    end
  end
end

if abspath(PROGRAM_FILE) == @__FILE__
  probe_digest(stdout)
end
