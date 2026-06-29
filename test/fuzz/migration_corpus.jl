# Frozen corpus for byte-identity verification of the InstrBuilder migration.
# Diverse functions exercising value/call/invoke/statement/new/dispatch/flow/string/
# array/struct/int128/union/closure paths. DETERMINISTIC only (no UInt128-max).
using WasmTarget, SHA
const WT = WasmTarget
struct _MPt; x::Float64; y::Float64; end
_mdist(p::_MPt) = sqrt(p.x*p.x + p.y*p.y)
abstract type _MShape end
struct _MCirc <: _MShape; r::Float64; end
struct _MSq <: _MShape; s::Float64; end
_marea(c::_MCirc) = 3.14159 * c.r * c.r
_marea(s::_MSq) = s.s * s.s
const MIGRATION_CORPUS = Any[
  ("v_cond",   (x::Int)-> x>3 ? x*2 : x+1, (Int,)),
  ("v_char",   (c::Char)-> c == 'x', (Char,)),
  ("v_strcat", (n::Int)-> string(n) * "!", (Int,)),
  ("v_streq",  ()-> repeat("ab", Int64(3)) == "ababab", ()),
  ("v_tuple",  ()-> (1, 2.5, 'a'), ()),
  ("v_union",  (x::Int)-> (x>0 ? 1 : 2.5), (Int,)),
  ("a_sumloop",function(n::Int); s=0.0; for i in 1:n; s+=sqrt(Float64(i)); end; s; end, (Int,)),
  ("a_vecpush",function(n::Int); a=Int[]; for i in 1:n; push!(a,i*i); end; sum(a); end, (Int,)),
  ("s_struct",  (x::Float64,y::Float64)-> _mdist(_MPt(x,y)), (Float64,Float64)),
  ("s_getfield",(p::_MPt)-> p.x + p.y, (_MPt,)),
  ("d_dispatch",(s::_MShape)-> _marea(s), (_MShape,)),
  ("d_isa",     (s::_MShape)-> s isa _MCirc ? 1 : 0, (_MShape,)),
  ("m_intarith",(a::Int,b::Int)-> (a*b + a - b) ÷ 2, (Int,Int)),
  ("m_float",   (x::Float64)-> x^2 - 3.0*x + 1.0, (Float64,)),
  ("m_i128",    (a::Int128,b::Int128)-> a*b + a - b, (Int128,Int128)),
  ("m_u128sh",  (a::UInt128,n::Int64)-> (a << n) | (a >> n), (UInt128,Int64)),
  ("c_closure", function(n::Int); f = x -> x + n; f(10); end, (Int,)),
  ("f_excep",   function(x::Int); try; x ÷ 0; catch; -1; end; end, (Int,)),
  ("f_nested",  (x::Int)-> x==0 ? 100 : (x<0 ? -1 : (x>10 ? 2 : 1)), (Int,)),
  ("b_bitops",  (x::UInt32)-> (x << 2) ⊻ (x >> 1) & 0xff, (UInt32,)),
]
function migration_digest(io=stdout)
  for (nm, f, ts) in MIGRATION_CORPUS
    try; w = WT.compile(f, ts); println(io, nm, " ", length(w), " ", bytes2hex(sha256(w)))
    catch e; println(io, nm, " ERR ", first(sprint(showerror, e), 70)); end
  end
end
