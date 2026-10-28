# The smoke corpus: every differential case, grouped (`_g` a group, `_xf` a known-pending one,
# `_lazy_g`/`_lazy_xf` one built from a generator file), as test/smoke.jl runs them; the driver
# defines the group tables and the harness, this file only the cases and the helpers they call.
using Random, SHA   # seeded streams, as the full suite loads them
using LinearAlgebra: Diagonal, Symmetric   # struct_by_structure: array-interface structs

# ---- the strict subset (dev/MARCH.md 1.A7): Julia's trim verifier decides --------------------------
# a call whose target inference cannot resolve is outside the subset: the compile rejects it with
# OutsideSubset, Julia's own CallMissing text, and the ladder reads LOUD-OUTSIDE
_g("subset", Any[
    ("dynamic_dispatch", (x::Int64) -> Base.inferencebarrier(x) + 1, Int64(5)),
])

# ---- numerics -------------------------------------------------------------
_g("numerics", Any[
    ("add_i", (x::Int64) -> x + 3, Int64(5)),
    ("mul_f", (x::Float64) -> x * 2.5, 4.0),
    ("mixed_promote", (x::Int64) -> x + 1.5, Int64(2)),
    ("idiv", (x::Int64) -> div(x, 3) + x % 3, Int64(20)),
    ("cmp_chain", (x::Int64) -> (0 < x < 10), Int64(5)),
    ("float_trunc", (x::Float64) -> Int64(floor(x)), 7.9),
    ("bitops", (x::Int64) -> (x << 2) | (x >> 1) & 0xff, Int64(13)),
    ("abs_sign", (x::Int64) -> abs(x) + sign(x), Int64(-7)),
    ("pow_int", (x::Int64) -> x^3, Int64(4)),
    # Int128 mul/sub (div is deferred F10); return Int64 (harness can't marshal an Int128 result).
    ("int128", (x::Int64) -> Int64(Int128(x) * Int128(x) - Int128(x)), Int64(1000)),
])

# ---- control flow ---------------------------------------------------------
_g("controlflow", Any[
    ("ternary", (x::Int64) -> x > 0 ? x * 2 : -x, Int64(-5)),
    ("ifelse_chain", (x::Int64) -> x < 0 ? -1 : (x == 0 ? 0 : 1), Int64(0)),
    ("while_sum", (n::Int64) -> (s = 0; i = 1; while i <= n; s += i; i += 1; end; s), Int64(10)),
    ("for_break", (n::Int64) -> (s = 0; for i in 1:n; i > 5 && break; s += i; end; s), Int64(10)),
    ("for_continue", (n::Int64) -> (s = 0; for i in 1:n; i % 2 == 0 && continue; s += i; end; s), Int64(10)),
    ("nested_loop", (n::Int64) -> (s = 0; for i in 1:n, j in 1:n; s += i * j; end; s), Int64(4)),
    # multi-back-edge loop (2+ continues → 2+ back edges to ONE header): the loop
    # label must close at the LAST back-edge source only — firing at every source
    # emitted a spurious End per extra edge (1.13 Base `print` shape, fixed 2026-07-04)
    ("multi_continue", (n::Int64) -> (s = 0; i = 0; while i < n; i += 1; i % 2 == 0 && continue; i % 3 == 0 && continue; s += i; end; s), Int64(100)),
    ("multi_continue_nested", (n::Int64) -> (t = 0; for i in 1:n, j in 1:n; j % 2 == 0 && continue; i % 3 == 0 && continue; t += i * j; end; t), Int64(7)),
])

# ---- phi / union (the boxing channel) -------------------------------------
# P4-types (get_concrete_wasm_type / julia_to_wasm_type_concrete fold): protect the
# Union{Nothing,T}-for-locals EqRef seam (CG-003d) before the two duplicate chains merge.
struct _PU
    v::Int64
end
struct _PUWrap
    inner::Union{Nothing,_PU}
end
_g("phi_union", Any[
    ("loop_phi", (n::Int64) -> (s = 0; for i in 1:n; s += i % 2 == 0 ? i : -i; end; s), Int64(6)),
    ("union_add", (b::Bool) -> (b ? 10 : 20) + 1, true),
    ("ternary_widen", (x::Int64) -> x > 5 ? 1.5 : 2.5, Int64(2)),
    ("acc_float", (n::Int64) -> (s = 0.0; for i in 1:n; s += i; end; s), Int64(5)),
    # (1) two-edge if/else phi: one Nothing edge, one concrete-struct edge, stored in a
    # local then used. Exercises the EqRef-for-locals path when the local is re-read.
    ("phi_nothing_struct",
     (x::Int64) -> (r = x > 0 ? _PU(x) : nothing; y = r; y === nothing ? Int64(-1) : y.v),
     Int64(3)),
    # (2) >=3-predecessor phi (if/elseif/elseif/else) merging Union{Nothing,_PU}.
    ("phi_3way_nothing_struct",
     (x::Int64) -> (r = if x == 1
         _PU(10)
     elseif x == 2
         _PU(20)
     elseif x == 3
         nothing
     else
         _PU(30)
     end; r === nothing ? Int64(-1) : r.v),
     Int64(2)),
    # (3) a Union{Nothing,_PU} value widened through an Any-typed intermediate, then
    # merged again at a second phi (one edge sourced from the Any local, one Nothing).
    ("phi_any_intermediate",
     (x::Int64) -> (pre = x > 0 ? _PU(x) : nothing; dyn::Any = pre; post = x > 3 ? dyn : nothing;
                    (post isa _PU) ? post.v : Int64(-1)),
     Int64(6)),
    # (4) a struct field of type Union{Nothing,T} read straight into a local, then used.
    ("struct_field_nothing_to_local",
     (x::Int64) -> (w = _PUWrap(x > 0 ? _PU(x) : nothing); f = w.inner; f === nothing ? Int64(-1) : f.v),
     Int64(8)),
])

# ---- arrays ---------------------------------------------------------------
_g("arrays", Any[
    ("vec_sum_loop", (n::Int64) -> (a = collect(1:n); s = 0; for x in a; s += x; end; s), Int64(6)),
    ("vec_index", (n::Int64) -> (a = zeros(Int64, 5); a[2] = n; a[2] + a[1]), Int64(7)),
    ("vec_push", (n::Int64) -> (v = Int64[]; for i in 1:n; push!(v, i * i); end; sum(v)), Int64(4)),
    ("comprehension", (n::Int64) -> sum([i * 2 for i in 1:n]), Int64(5)),
    ("comprehension_if", (n::Int64) -> sum([i for i in 1:n if i % 2 == 0]), Int64(8)),
    ("float_arr", (n::Int64) -> (a = zeros(Float64, 3); a[1] = Float64(n); a[1] * 2), Int64(3)),
    ("matrix_2d", (n::Int64) -> (m = zeros(Int64, 2, 2); m[1, 1] = n; m[2, 2] = n; m[1, 1] + m[2, 2]), Int64(4)),
])

# ---- Any-arrays (recent phi-edge unbox fix; the box round-trip) -----------
_g("anyarray_boxing", Any[
    ("any_idx_i", (x::Int64) -> (v = Any[1, 2, 3]; v[x]::Int64), Int64(2)),
    ("any_idx_f", (x::Int64) -> (v = Any[1.5, 2.5, 3.5]; v[x]::Float64), Int64(3)),
    ("any_loop", () -> (v = Any[1, 2, 3]; s = 0; for e in v; s += e::Int64; end; s)),
    ("any_mixed", (x::Int64) -> (v = Any[1, "two", 3]; v[x]::Int64), Int64(1)),
    ("any_sum_idx", (n::Int64) -> (v = Any[10, 20, 30, 40]; t = 0; for i in 1:n; t += v[i]::Int64; end; t), Int64(3)),
    # Loop B′: Vector{Any} elements ride the UNIFORM classId box — push!-built + dynamic (isa) read-back.
    ("any_push_mixed_dyn", (n::Int64) -> (v = Any[]; for i in 1:n; push!(v, i % 2 == 0 ? i : Float64(i)); end; s = 0.0; for e in v; s += e isa Int64 ? Float64(e) : e::Float64; end; s), Int64(4)),
    ("any_typeof_disc", (x::Int64) -> (v = Any[1, "two", 3.0]; e = v[x]; e isa Int64 ? 1 : (e isa Float64 ? 2 : 3)), Int64(3)),
])

# ---- dicts ----------------------------------------------------------------
# Native-built Dict{String,Int} CONSTANT: slots/keys/vals are embedded verbatim
# (compile_memory_elements!, values.jl) at their NATIVE hash-placed positions,
# so this only resolves in wasm when hash(::String) is bit-exact with native
# (ground-truth string hashing; see string_hash_ground_truth.jl).
const _SMOKE_HASH_DS = Dict("a" => 1, "bb" => 2, "ccc" => 3)
_g("dicts", Any[
    ("dict_get", (x::Int64) -> (d = Dict(1 => 10, 2 => 20, 3 => 30); get(d, x, 0)), Int64(2)),
    ("dict_build", (n::Int64) -> (d = Dict{Int64,Int64}(); for i in 1:n; d[i] = i * i; end; sum(values(d))), Int64(4)),
    ("dict_haskey", (x::Int64) -> (d = Dict(1 => 1, 2 => 2); haskey(d, x) ? 1 : 0), Int64(2)),
    # native-built constants: only occupied slots are serialized (unoccupied isbits
    # slots held host heap garbage — process-varying bytes), and a constant Vector
    # read only through .size registers its struct on demand
    ("dict_const_get", (x::Int64) -> _SMOKE_DICT[x] + get(_SMOKE_DICT, x + 100, -1), Int64(2)),
    ("dict_const_grow", (x::Int64) -> (d = copy(_SMOKE_DICT); d[x + 50] = 7; length(d) + d[x + 50]), Int64(3)),
    ("vec_const_len", (x::Int64) -> length(_SMOKE_VEC) + length(_SMOKE_VEC2) + x, Int64(1)),
    # Set{Int} = Dict{Int,Nothing}: the unoccupied vals slots take the physical default
    ("set_const_in", (x::Int64) -> (x in _SMOKE_SET ? 1 : 0) + length(_SMOKE_SET), Int64(2)),
    # copy of a String-keyed Dict: isbitstype(String) folds (no sizeof(String) branch)
    # and the non-isbits Memory copy divides byte offsets by the reference stride
    ("dict_str_copy_grow", (x::Int64) -> (d = copy(_SMOKE_DS); d["cc"] = x; length(d) * 10 + d["bb"]), Int64(3)),
    # reference-element copies at offset 0 and above (stride 8 both sides)
    ("vec_str_copy_push", (x::Int64) -> (w = copy(_SMOKE_VS); push!(w, "e"); length(w) * 10 + length(w[2]) + x), Int64(0)),
    ("vec_str_slice", (x::Int64) -> (w = _SMOKE_VS[2:3]; length(w) * 10 + length(w[1]) + length(w[2]) + x), Int64(0)),
    ("vec_str_copy_set", (x::Int64) -> (w = copy(_SMOKE_VS); w[2] = "zz"; length(_SMOKE_VS[2]) * 10 + length(w[2]) + x), Int64(0)),
])

# ---- isa / typeassert against parametric abstracts on Any-typed values ---
# AbstractVector = AbstractArray{T,1}: a DFS range keyed by the base could not answer
# it (constant false), and its wasm type reached the matrix registrar (illegal cast).
@noinline _smoke_anyvec(n::Int64) = n > 0 ? Any[1.0, 2.0] : Any[Float64[1.0, 2.0], "s", Int64[3]]
_g("abstract_isa", Any[
    ("isa_abstractvector", (n::Int64) -> (c = 0; for x in _smoke_anyvec(n); x isa AbstractVector && (c += 1); end; c), Int64(0)),
    ("isa_abstractarray", (n::Int64) -> (c = 0; for x in _smoke_anyvec(n); x isa AbstractArray && (c += 1); end; c), Int64(0)),
    ("isa_abstractvector_none", (n::Int64) -> (c = 0; for x in _smoke_anyvec(n); x isa AbstractVector && (c += 1); end; c), Int64(1)),
    ("typeassert_abstractvector", (n::Int64) -> (v = _smoke_anyvec(n)[1]::AbstractVector; v isa Vector{Float64} ? length(v)::Int : -1), Int64(0)),
    ("dict_str_const_lookup", () -> _SMOKE_HASH_DS["bb"]),
])
const _SMOKE_DICT = Dict{Int64,Int64}(i => i * 10 for i in 1:5)
const _SMOKE_VEC = Int64[1, 2, 3]
const _SMOKE_VEC2 = Int64[4, 5, 6]
const _SMOKE_SET = Set([1, 2, 3, 40])
const _SMOKE_DS = Dict{String,Int64}("a" => 1, "bb" => 2)
const _SMOKE_VS = ["a", "bb", "ccc", "dddd"]

# ---- structs / tuples -----------------------------------------------------
struct _Pt; x::Int64; y::Int64; end
mutable struct _Box; v::Int64; end
mutable struct _RegTarget; v::Float64; end
mutable struct _Holder; slot::Union{Nothing,_RegTarget}; end
# @noinline so the struct genuinely escapes and setfield!/getfield compile for
# real (inlined into a single closure body, Julia's SROA scalar-replaces the
# field down to pure dataflow and never exercises the setfield! codegen path
# this regresses).
@noinline function _wt_clear_slot!(h::_Holder)
    h.slot = nothing
    return h.slot === nothing
end
_g("structs_tuples", Any[
    ("struct_field", (n::Int64) -> (p = _Pt(n, n + 1); p.x + p.y), Int64(3)),
    ("mutable_struct", (n::Int64) -> (b = _Box(n); b.v += 10; b.v), Int64(5)),
    ("tuple_idx", (x::Int64) -> (t = (x, x + 1, x + 2); t[1] + t[3]), Int64(4)),
    ("namedtuple", (x::Int64) -> (nt = (a = x, b = x * 2); nt.a + nt.b), Int64(3)),
    ("het_tuple", (x::Int64) -> (t = (x, 1.5); t[1] + Int64(t[2] > 1 ? 1 : 0)), Int64(7)),
    # Loop B′: heterogeneous tuple at a RUNTIME index → Union element via the uniform box (both arms).
    ("het_tuple_rtidx", (x::Int64) -> (t = (10, 2.5); s = t[x]; s isa Int64 ? s : Int64(round(s))), Int64(1)),
    ("const_het_tuple_rtidx", (x::Int64) -> (t = (100, 3.5, 200); v = t[x]; v isa Int64 ? v : Int64(round(v))), Int64(1)),
    # Phase 6.1 regression: `h.slot = nothing` lowers `nothing` as GlobalRef(Mod,:nothing),
    # NOT a literal — setfield! into a Union{Nothing,ConcreteStruct} field must null the
    # field with ITS OWN concrete type, not the generic bottom ref (MOI.Utilities.Model
    # crash trigger). Round-trips nothing → back to a real struct value.
    ("setfield_nothing_regression", (x::Float64) -> (h = _Holder(_RegTarget(x)); r1 = _wt_clear_slot!(h) ? 1 : 0; h.slot = _RegTarget(x * 2); r2 = h.slot === nothing ? 0.0 : h.slot.v; Float64(r1) + r2), 3.0),
])

# ---- closures (capture; mutate-capture = F3) ------------------------------
# Function values called through an ERASED binding ride the closure vtable
# (closures.jl: one vtable per closure type; entry[arity] = the trampoline). A closure
# type with several same-arity specializations in the closed world gets a DISPATCHING
# entry that tests the erased arguments' classIds (_closure_dispatch_trampoline!; the
# first specialization used to win silently — Int64 vs Float64 below), and the vtable
# structs chain by arity (dart's parentVtableStruct).
_g("closures", Any[
    ("capture", (x::Int64) -> (f = y -> y + x; f(10)), Int64(5)),
    ("map_closure", (n::Int64) -> (k = 3; sum(map(i -> i * k, 1:n))), Int64(4)),
    ("erased_two_specializations", (n::Int64) -> (h = x -> x + n; fs = Any[h]; (fs[1](1)::Int64) + Int64((fs[1](2.5)::Float64) * 2)), Int64(3)),
    # a function value called inside nested branches whose result feeds a multiply: through
    # the erased vtable call (one and two result classes) and a union of capturing closures
    ("erased_nested_mul", (n::Int64) -> (m = n + 1; fs = Any[x -> x * m, x -> x + m, x -> x - m]; r = 0; for k in 1:3; g = fs[k]; if n > 0; if k != 2 || n > 3; r += (g(n)::Int64) * n; end; end; end; r), Int64(4)),
    ("erased_nested_mul_mixed", (n::Int64) -> (fs = Any[x -> x * 2, x -> x * 0.5]; r = 0.0; for k in 1:2; g = fs[k]; if n > 0; if k == 1; r += Float64(g(n)::Int64) * n; else; r += (g(n)::Float64) * n; end; end; end; r), Int64(4)),
    ("union_closure_nested_mul", (n::Int64) -> (m = n + 1; f = n == 1 ? (x -> x * m) : n == 2 ? (x -> x * 3m) : n == 3 ? (x -> x + m) : (x -> x - m); r = 0; if n > 0; if n < 10; r = f(n) * n; end; end; r), Int64(4)),
    # every vtable entry returns anyref (dart closures.dart:648): a Nothing-returning body's
    # entry yields null (it used to return no value, and the caller's cast to the uniform
    # signature trapped), and one arity may mix Nothing- and value-returning specializations
    # (it used to be refused at compile time)
    ("erased_nothing_body", (n::Int64) -> (v = Int64[]; h = s -> (push!(v, length(s) * n); nothing); fs = Any[h]; fs[1]("ab"); fs[1]("abc"); sum(v)), Int64(3)),
    ("erased_nothing_specialization", (n::Int64) -> (v = Int64[]; h = x -> (x isa String ? (push!(v, length(x)); nothing) : x * n); fs = Any[h]; fs[1]("abcd"); Int64((fs[1](2.5)::Float64) * 2) + sum(v)), Int64(3)),
    # an erased call's result is Julia's `::Any`, never its first argument's type: the value
    # keeps its own class (native 2, 1, 1; typed as the Int64 argument it answered 1, and
    # trapped an illegal cast for the Bool and Float64 results)
    ("erased_result_uint64", (n::Int64) -> (fs = Any[x -> UInt64(x)]; r = fs[1](n); r isa Int64 ? 1 : 2), Int64(3)),
    ("erased_result_bool", (n::Int64) -> (fs = Any[x -> x > 0]; r = fs[1](n); r isa Bool ? 1 : 2), Int64(3)),
    ("erased_result_float64", (n::Int64) -> (fs = Any[x -> x * 0.5]; r = fs[1](n); r isa Float64 ? 1 : 2), Int64(3)),
])

# a captured variable's reads carry the join of every write into its box across the closed
# world (record_capture_contents, dev/formal/CaptureType.tla; dart Capture.type).
# parity(M10a) PROMOTED: the scalar-replaced accumulator cycle computes correctly — the
# numeric join is the variable's REAL type for EVERY consumer (dart
# translateTypeOfLocalVariable), so the dynamic-+ default-zero arm never fires.
_g("mutable_capture", Any[
    ("mutate_capture_typed", (n::Int64) -> ((s = 0; foreach(i -> (s += i), 1:n); s)::Int64), Int64(5)),
])
# The un-annotated variant returns Any (a classId box), which the host cannot read; the harness
# reads it inside the module, through a typeassert to the native result's type
# (typed_result_wrapper, test/utils.jl).
_g("any_return_boundary", Any[
    ("mutate_capture", (n::Int64) -> (s = 0; foreach(i -> (s += i), 1:n); s), Int64(5)),
])
# Strings lack the $JlBase classId header (bare array<i32> refs), so abstract isa on a
# heterogeneous element can't range-check them — pre-existing rep gap (strings dimension),
# found while installing dart's dense-range isa (M3). Fix = class the string rep (M6/strings).
# parity(M9) PROMOTED: strings are CLASSED ({classId, data} <: $JlBase, in the DFS
# hierarchy) — `isa AbstractString` is the same dense-range check as everything else.
_g("strings_classed", Any[
    ("isa_abstractstring_anyvec", (n::Int64) -> (v = Any[1, "a", 2]; c = 0; for e in v; e isa AbstractString && (c += 1); end; c + n), Int64(10)),
])

# ---- dispatch (multiple methods / types) ----------------------------------
_disp(x::Int64) = x * 2
_disp(x::Float64) = x + 0.5
# formal(dev/formal/ClassIdDispatch.tla) DispatchExact: four classed receivers through the ONE
# selector table — rows packed with the whole span reserved, the classId span guard in front of
# call_indirect (the MethodError-trap fix; test/dispatch_method_error.jl has the trap side).
struct _SmA x::Int32 end; struct _SmB x::Int32 end; struct _SmC x::Int32 end; struct _SmD x::Int32 end
_smd(a::_SmA) = Int32(1); _smd(a::_SmB) = Int32(2); _smd(a::_SmC) = Int32(3); _smd(a::_SmD) = Int32(4)
@noinline _smd_fwd(x::Any)::Int32 = _smd(x)
# Ten methods pass Julia's max_methods cutoff, so inference types each call below `::Any`, and
# the call is the dynamic dispatch Julia's IR asks for: its result is the method's, read at run
# time (codegen re-infers nothing). _smm: all Int64 (summed: two Any operands, erased_arithmetic).
# _smw: nine Int64 methods and one WIDER `_smw(::Any, ::Int64)::Float64` that the tenth class
# reaches. _smx: five Int64, five Float64.
abstract type _SmM end
abstract type _SmW end
abstract type _SmX end
for i in 1:10
    @eval struct $(Symbol("_SmM", i)) <: _SmM; v::Int64; end
    @eval _smm(x::$(Symbol("_SmM", i)), k::Int64)::Int64 = x.v * $i + k
    @eval struct $(Symbol("_SmW", i)) <: _SmW; v::Int64; end
    i < 10 && @eval _smw(x::$(Symbol("_SmW", i)), k::Int64)::Int64 = x.v * $i + k
    @eval struct $(Symbol("_SmX", i)) <: _SmX; v::Int64; end
    @eval _smx(x::$(Symbol("_SmX", i)), k::Int64) = $(i <= 5 ? :(x.v + k) : :(Float64(x.v) * 0.5))
end
_smw(x, k::Int64)::Float64 = Float64(k) + 0.5
for (A, T) in ((:_smm_xs, :_SmM), (:_smw_xs, :_SmW), (:_smx_xs, :_SmX))
    @eval @noinline $A() = $T[$([:($(Symbol(T, i))($i)) for i in 1:10]...)]
end
_g("dispatch", Any[
    ("dispatch_int", (x::Int64) -> _disp(x), Int64(5)),
    ("dispatch_float", (x::Float64) -> _disp(x), 4.0),
    # a dynamic call whose abstract position holds boxed numerics and a classed string:
    # the discovery builds a row per observed class (Int64, String, Float64 — dart's rows
    # for every class of the component) and the switch unboxes/casts per row; it used to
    # skip non-struct classes and trap at runtime with no row
    ("eq_any_mixed", (n::Int64) -> (v = Any[1, "x", 2.5]; (v[1] == 1 ? 1 : 0) + (v[2] == "x" ? 10 : 0) + (v[3] == 2.5 ? 100 : 0) + n), Int64(1)),
    ("selector_table_span", (n::Int64) -> (v = Any[_SmA(Int32(n)), _SmB(Int32(n)), _SmC(Int32(n)), _SmD(Int32(n))]; s = Int32(0); for e in v; s += _smd_fwd(e); end; Int64(s) + n), Int64(3)),
    ("megamorphic_wider_method", (n::Int64) -> (c = 0; for x in _smw_xs(); c += _smw(x, n) isa Float64 ? 100 : 1; end; c), Int64(3)),
    ("megamorphic_disagree", (n::Int64) -> (c = 0; for x in _smx_xs(); c += _smx(x, n) isa Int64 ? 1 : 100; end; c), Int64(3)),
])

# ---- filtered folds (was the #1 SILENT MISCOMPILE: _InitialValue sentinel through
# _foldl_impl + FilteringRF returned 0; healed by the M1-M4 structural work, certified
# 2026-07-01 — these cases lock it fixed forever) ------------------------------
_g("filtered_fold", Any[
    ("range_filter_sum", (n::Int64) -> sum(x for x in 1:n if x % 2 == 0), Int64(10)),
    ("vec_filter_sum", (n::Int64) -> (v = collect(1:n); sum(x for x in v if x % 2 == 0)), Int64(10)),
    ("init_filter_sum", (n::Int64) -> sum(x for x in 1:n if x > 3; init=0), Int64(6)),
])

# ---- higher-order / reduce ------------------------------------------------
_g("higherorder", Any[
    # a generic function held as a value, called on an Int64 (A11P3: iterate(::Int64))
    ("iterate_held", (n::Int64) -> (f = Any[iterate][1]; t = f(n); t === nothing ? 0 : t[1]), Int64(3)),
    ("reduce_max", (n::Int64) -> reduce(max, 1:n), Int64(7)),
    ("foldl_sum", (n::Int64) -> foldl(+, 1:n; init = 0), Int64(6)),
    ("filter_count", (n::Int64) -> count(iseven, 1:n), Int64(10)),
    ("mapreduce", (n::Int64) -> mapreduce(x -> x^2, +, 1:n), Int64(4)),
])

# ---- runtime-length varargs (Phase 12 H) ----------------------------------
# `f(t...)` where `t` is a runtime-length Vararg tuple: the callee's own trailing
# `Vararg{E}` parameter IS that value's {Object, data, size} representation, so the
# splat compiles to a direct call. Nothing in dart2wasm answers to this
# (parity(quarantine: Julia varargs)); before Phase 12 H it was a loud reject.
@noinline _sm_vsum(xs::Int64...) = (s = 0; for x in xs; s += x; end; s)
@noinline _sm_vmaxf(xs::Float64...) = (m = -Inf; for x in xs; x > m && (m = x); end; m)
@noinline _sm_mktup(v::Vector{Int64}) = Core.tuple(v...)      # the builtin VALUE spelling
@noinline _sm_mktupf(v::Vector{Float64}) = tuple(v...)        # GlobalRef(Main, :tuple)
@noinline _sm_mktup_ne(v::Vector{Int64}) = (t = Core.tuple(v...); isempty(t) ? (0,) : t)
_g("varargs", Any[
    ("splat_vararg_sum", (n::Int64) -> _sm_vsum(_sm_mktup(collect(1:n))...), Int64(5)),
    ("splat_vararg_sum_empty", (n::Int64) -> _sm_vsum(_sm_mktup(collect(1:n))...), Int64(0)),
    ("splat_vararg_sum_one", (n::Int64) -> _sm_vsum(_sm_mktup(collect(1:n))...), Int64(1)),
    ("splat_vararg_maxf", (n::Int64) -> _sm_vmaxf(_sm_mktupf(Float64[i * 1.5 for i in 1:n])...), Int64(4)),
    # the non-empty narrowing Tuple{T, Vararg{T}} shares the canonical layout
    ("splat_vararg_nonempty", (n::Int64) -> _sm_vsum(_sm_mktup_ne(collect(1:n))...), Int64(3)),
])

# ---- identity: `===` / `!==` is Julia's jl_egal ----------------------------
# Bit identity for primitives (never IEEE `==`), fieldwise egal for immutable structs and
# tuples, content for String, object identity for mutable objects. Results are Int64 so a
# sign of zero or a Bool/Int mixup cannot hide behind `==`.
@noinline _id_any(v::Vector{Any}, i::Int64) = v[i]
@noinline _id_maybe(x::Int64) = x > 0 ? x : nothing
_id_anyval(x::Int64) = (v = Any[x]; x > 0 || (v[1] = nothing); _id_any(v, 1))
const _ID_SV = Any["a", :a, Int64(1), "x", :a]
_id_f64(x::Float64, y::Float64) = Int64(x === y)
_id_f32(x::Float32, y::Float32) = Int64(x === y)
_id_f64_ne(x::Float64, y::Float64) = Int64(x !== y)
_id_any_pair(i::Int64, j::Int64) = Int64(_id_any(_ID_SV, i) === _id_any(_ID_SV, j))
_id_any_pair_ne(i::Int64, j::Int64) = Int64(_id_any(_ID_SV, i) !== _id_any(_ID_SV, j))
_g("identity", Any[
    ("f64_nan", _id_f64, NaN, NaN),
    ("f64_zero_negzero", _id_f64, 0.0, -0.0),
    ("f64_equal", _id_f64, 2.5, 2.5),
    ("f64_nan_ne", _id_f64_ne, NaN, NaN),
    ("f64_zero_negzero_ne", _id_f64_ne, 0.0, -0.0),
    ("f32_nan", _id_f32, NaN32, NaN32),
    ("f32_zero_negzero", _id_f32, 0.0f0, -0.0f0),
    ("f64_egal_signed_zero", (x::Float64) -> (x === -0.0 ? 1 : 0) + (x !== -0.0 ? 2 : 0), 0.0),
    ("f64_egal_nan", (x::Float64) -> (x === NaN ? 1 : 0) + (x !== NaN ? 2 : 0), NaN),
    ("f32_egal_signed_zero", (x::Float32) -> (x === -0.0f0 ? 1 : 0) + (x !== -0.0f0 ? 2 : 0), 0.0f0),
    ("f64_nan_payload", (x::Float64) -> Int64(x === reinterpret(Float64, reinterpret(UInt64, x) | 0x1)), NaN),
    ("any_nan_nan", (i::Int64) -> (v = Any[NaN, NaN, 0.0, -0.0]; Int64(_id_any(v, i) === _id_any(v, i + 1))), Int64(1)),
    ("any_zero_negzero", (i::Int64) -> (v = Any[NaN, NaN, 0.0, -0.0]; Int64(_id_any(v, i) === _id_any(v, i + 1))), Int64(3)),
    ("any_two_boxes", (x::Int64) -> (v = Any[x, x + 0]; Int64(_id_any(v, 1) === _id_any(v, 2))), Int64(7)),
    ("any_box_vs_num", (x::Int64) -> Int64(_id_any(Any[x], 1) === x), Int64(7)),
    ("any_box_vs_num_ne", (x::Int64) -> Int64(_id_any(Any[x], 1) !== x), Int64(7)),
    ("any_i32_vs_i64", (i::Int64) -> (v = Any[Int32(1), Int64(1)]; Int64(_id_any(v, i) === _id_any(v, i + 1))), Int64(1)),
    ("any_bool_vs_i64", (i::Int64) -> (v = Any[true, Int64(1)]; Int64(_id_any(v, i) === _id_any(v, i + 1))), Int64(1)),
    ("any_nothing_egal", (x::Int64) -> Int64(_id_anyval(x) === nothing), Int64(-3)),
    ("any_int_not_nothing", (x::Int64) -> Int64(_id_anyval(x) === nothing), Int64(3)),
    ("any_nothing_vs_any", (x::Int64) -> Int64(_id_anyval(x) === _id_anyval(x - 1)), Int64(-3)),
    ("str_content", (x::Int64) -> (v = Any["ab", string('a', Char(x))]; Int64(_id_any(v, 1) === _id_any(v, 2))), Int64(98)),
    ("str_static_content", (x::Int64) -> Int64("ab" === string('a', Char(x))), Int64(98)),
    ("sym_vs_sym", _id_any_pair, Int64(2), Int64(5)),
    ("num_ne_str", _id_any_pair_ne, Int64(3), Int64(4)),
    ("tuple_type_int", (x::Int64) -> (t = (UInt8, x); t === (UInt8, 3) ? 1 : 2), Int64(3)),
    ("tuple_type_int_barrier", (x::Int64) -> (t = Base.inferencebarrier((UInt8, x)); t === (UInt8, 3) ? 1 : 2), Int64(3)),
    ("tuple_sym_int_barrier", () -> (t = Base.inferencebarrier((:a, 3)); t === (:a, 3) ? 1 : 2)),
    ("tuple_type_only_barrier", () -> (t = Base.inferencebarrier((UInt8,)); t === (UInt8,) ? 1 : 2)),
    ("tuple_float_fields", (x::Float64) -> Int64((x, 1) === (NaN, 1)), NaN),
    ("struct_fields", (x::Int64) -> Int64(_id_any(Any[_Pt(x, 2), _Pt(3, 2)], 1) === _id_any(Any[_Pt(x, 2), _Pt(3, 2)], 2)), Int64(3)),
    ("mutable_identity", (x::Int64) -> (a = _Box(x); b = _Box(x); Int64(a === b) + 2 * Int64(a === a)), Int64(3)),
    ("type_barrier", () -> (t = Base.inferencebarrier(UInt8); t === UInt8 ? 1 : 2)),
    ("empty_tuple_any", (i::Int64) -> Int64(_id_any(Any[(), 1], i) === ()), Int64(1)),
    ("empty_tuple_any_ne", (i::Int64) -> Int64(_id_any(Any[(), 1], i) === ()), Int64(2)),
    ("bswap_u16", (x::Int64) -> Int64(bswap(x % UInt16)), Int64(0x1234)),
    ("bswap_i16", (x::Int64) -> Int64(bswap(x % Int16)), Int64(0x12f4)),
])

# `===` / `!==` on a Union{Nothing,Int64} value: once a wrong constant, then a located
# rejection while the value lived in an i64; now the value is its nullable box, so egal
# answers exactly.
_g("union_register", Any[
    ("union_num_ne", (x::Int64) -> Int64(_id_maybe(x) !== 3), Int64(3)),
    ("union_nothing_egal", (x::Int64) -> Int64(_id_maybe(x) === nothing), Int64(-3)),
])

# ---- symbol_class: a Symbol is its own class, sharing the classed string layout ----
# Egal, isa, typeof and dispatch tell `"a"` from `:a`; a runtime Symbol (`jl_symbol_n`) is built
# under Symbol's class and hashes as Julia's interned symbol does.
@noinline _sym_of(x::Int64) = x > 0 ? :abc : :d
@noinline _sym_dispatch(x::Symbol) = 1
@noinline _sym_dispatch(x::String) = 2
@noinline _sym_dispatch(x) = 3
mutable struct _SymBytes
    m::Memory{UInt8}
end
_sym_bytes_values(i::Int64) = Any[string('a', Char(i + 96)), _SymBytes(Memory{UInt8}(undef, 2)), Symbol(string('a', Char(i + 96)))]
_g("symbol_class", Any[
    ("str_vs_sym", _id_any_pair, Int64(1), Int64(2)),
    ("str_ne_sym", _id_any_pair_ne, Int64(1), Int64(2)),
    ("typeof_sym_is_Symbol", (i::Int64) -> Int64(typeof(_id_any(_ID_SV, i)) === Symbol), Int64(2)),
    ("typeof_sym_is_String", (i::Int64) -> Int64(typeof(_id_any(_ID_SV, i)) === String), Int64(2)),
    ("typeof_str_is_String", (i::Int64) -> Int64(typeof(_id_any(_ID_SV, i)) === String), Int64(1)),
    ("str_isa_Symbol", (i::Int64) -> Int64(_id_any(_ID_SV, i) isa Symbol), Int64(1)),
    ("sym_isa_String", (i::Int64) -> Int64(_id_any(_ID_SV, i) isa String), Int64(2)),
    ("str_isa_AbstractString", (i::Int64) -> Int64(_id_any(_ID_SV, i) isa AbstractString), Int64(1)),
    ("sym_isa_AbstractString", (i::Int64) -> Int64(_id_any(_ID_SV, i) isa AbstractString), Int64(2)),
    ("dispatch_sym", (i::Int64) -> _sym_dispatch(_id_any(_ID_SV, i)), Int64(2)),
    ("dispatch_str", (i::Int64) -> _sym_dispatch(_id_any(_ID_SV, i)), Int64(1)),
    ("symbol_ctor_egal", (x::Int64) -> Int64(Symbol(string('a', Char(x))) === :ab), Int64(98)),     # jl_symbol_n
    ("symbol_ctor_vs_str", (x::Int64) -> (v = Any[Symbol(string('a', Char(x))), "ab"]; Int64(_id_any(v, 1) === _id_any(v, 2))), Int64(98)),
    ("symbol_from_bytes", (x::Int64) -> Int64(Symbol(UInt8[0x61, UInt8(x)]) === :ab), Int64(98)),  # jl_symbol_n
    ("symbol_from_substring", (x::Int64) -> Int64(Symbol(SubString(string('x', 'a', Char(x), 'y'), 2, 3)) === :ab), Int64(98)),  # jl_symbol_n
    ("string_of_sym", (x::Int64) -> Int64(string(_sym_of(x)) == "abc"), Int64(1)),
    ("String_of_sym_is_String", (x::Int64) -> (v = Any[String(_sym_of(x))]; Int64(typeof(_id_any(v, 1)) === String)), Int64(1)),
    ("symbol_hash", (x::Int64) -> Int64(hash(Symbol(string('a', Char(x)))) == hash(:ab)), Int64(98)),
    ("dict_symbol_roundtrip", (x::Int64) -> (d = Dict{Symbol,Int64}(:a => x, :b => 2); d[:a] * 10 + d[Symbol(string('b'))]), Int64(7)),
    # a mutable struct whose one field is a byte Memory has the classed string's exact layout,
    # so add_type! gives both one type index: isa must read the classId, not the layout alone
    ("str_isa_bytes_struct", (i::Int64) -> Int64(_id_any(_sym_bytes_values(i), i) isa _SymBytes), Int64(1)),
    ("sym_isa_bytes_struct", (i::Int64) -> Int64(_id_any(_sym_bytes_values(i), i) isa _SymBytes), Int64(3)),
    ("bytes_struct_isa_bytes_struct", (i::Int64) -> Int64(_id_any(_sym_bytes_values(i), i) isa _SymBytes), Int64(2)),
    ("bytes_struct_isa_String", (i::Int64) -> Int64(_id_any(_sym_bytes_values(i), i) isa String), Int64(2)),
])

# ---- symbol_syntax: Julia's parser answers jl_is_operator / jl_is_syntactic_operator for
# any Symbol, including one built at runtime from bytes (test/symbol_syntax_metadata.jl) ----
@noinline _ss_isop(s::Symbol) = Int64(Base._isoperator(s))
@noinline _ss_issyn(s::Symbol) = Int64(Base.is_syntactic_operator(s))
_g("symbol_syntax", Any[
    ("plus_is_operator", () -> _ss_isop(Symbol("+"))),
    ("Int_is_operator", () -> _ss_isop(:Int)),
    ("equal_is_syntactic", () -> _ss_issyn(Symbol("="))),
    ("plus_is_syntactic", () -> _ss_issyn(Symbol("+"))),
    ("bytes_symbol_is_operator", (x::Int64) -> _ss_isop(Symbol(String(UInt8[UInt8(x)]))), Int64(0x2b)),
    ("bytes_symbol_is_syntactic", (x::Int64) -> _ss_issyn(Symbol(String(UInt8[UInt8(x)]))), Int64(0x3d)),
    ("substring_symbol_is_operator", (x::Int64) -> _ss_isop(Symbol(SubString(string('a', Char(x), 'b'), 2, 2))), Int64(0x2b)),
    ("substring_symbol_is_syntactic", (x::Int64) -> _ss_issyn(Symbol(SubString(string('a', Char(x), 'b'), 2, 2))), Int64(0x3d)),
    ("suffixed_operator", (x::Int64) -> _ss_isop(Symbol(string('+', Char(x)))), Int64(0x2032)),
    ("no_suffix_operator", (x::Int64) -> _ss_isop(Symbol(string('=', Char(x)))), Int64(0x2032)),
    ("dotted_operator", (x::Int64) -> _ss_isop(Symbol(string('.', Char(x)))), Int64(0x2b)),
    ("word_not_operator", (x::Int64) -> _ss_isop(Symbol(string('i', Char(x)))), Int64(0x6e)),
    ("dotted_syntactic", (x::Int64) -> _ss_issyn(Symbol(string('.', Char(x)))), Int64(0x3d)),
    ("string_is_operator", (x::Int64) -> Int64(Base._isoperator(string(Char(x), Char(x)))), Int64(0x2b)),
    ("literal_is_operator", (x::Int64) -> Int64(Base._isoperator(x > 0 ? :+ : :foo)), Int64(1)),
    ("literal_is_syntactic", (x::Int64) -> Int64(Base.is_syntactic_operator(x > 0 ? :(=) : :foo)), Int64(1)),
])

# A primitive word reinterpreted as its byte tuple and back (the `_reinterpret` overlays,
# interpreter.jl). Julia 1.13's Random.rehash! reinterprets its Int64 counter this way; the
# generic path walks the host layout at runtime and its dynamic calls grew the closed world
# to ~10,000 functions (measured 2026-09-23), so these compiled for hours instead of seconds.
_g("byte_reinterpret", Any[
    ("i64_to_bytes", (x::Int64) -> (b = reinterpret(NTuple{8, UInt8}, x); Int64(b[1]) + 256 * Int64(b[3]) + 65536 * Int64(b[8])), Int64(0x0123456789abcdef)),  # 109551
    ("u64_to_bytes", (x::Int64) -> (b = reinterpret(NTuple{8, UInt8}, x % UInt64); Int64(b[2]) - Int64(b[7])), Int64(-12345678901)),                            # -28
    ("f64_to_bytes", (x::Float64) -> Int64(reinterpret(NTuple{8, UInt8}, x)[8]), 1.5),                                                                          # 63
    ("bytes_to_u32", (x::Int64) -> Int64(reinterpret(UInt32, (x % UInt8, 0x02, 0x03, 0x84))), Int64(0x1ff)),                                                   # 2214789887
    ("bytes_to_i16", (x::Int64) -> Int64(reinterpret(Int16, (x % UInt8, 0x80))), Int64(7)),                                                                    # -32761
])

# ---- string_identity: a String's identity is its content (jl_object_id memhashes the bytes),
# a C string starts at its pointer, and a boxed byte Memory keeps its own class ----
@noinline _si_any(v::Vector{Any}, i::Int64) = v[i]
_g("string_identity", Any[
    ("objectid_equal_strings", (x::Int64) -> Int64(objectid("ab") == objectid(string('a', Char(x)))), Int64(98)),
    ("objectid_string_value", (x::Int64) -> reinterpret(Int64, objectid(string('a', Char(x)))), Int64(98)),
    ("cstring_mid_pointer", (x::Int64) -> (s = string('a', 'b', 'c', Char(x)); GC.@preserve s length(unsafe_string(pointer(s, 3)))), Int64(100)),
    ("cstring_mid_pointer_bytes", (x::Int64) -> (s = string('a', 'b', 'c', Char(x)); GC.@preserve s Int64(codeunit(unsafe_string(pointer(s, 2)), 1))), Int64(100)),
    ("cstring_substring_pointer", (x::Int64) -> (s = string('x', 'y', Char(x), 'z'); ss = SubString(s, 3); GC.@preserve s length(unsafe_string(pointer(ss)))), Int64(0x77)),
    ("boxed_memory_isa_String", (x::Int64) -> (v = Any[Memory{UInt8}(undef, x)]; Int64(_si_any(v, 1) isa String)), Int64(3)),
    ("boundserror_memory_isa_String", (x::Int64) -> (e = BoundsError(Memory{UInt8}(undef, 2), x); Int64(_si_any(Any[e.a], 1) isa String)), Int64(5)),
    ("boundserror_memory_isa_Memory", (x::Int64) -> (e = BoundsError(Memory{UInt8}(undef, 2), x); Int64(_si_any(Any[e.a], 1) isa Memory{UInt8})), Int64(5)),
    ("sprint_print_string", (x::Int64) -> length(sprint(print, string('a', Char(x)))), Int64(98)),
    ("sprint_print_symbol", (x::Int64) -> length(sprint(print, Symbol(string('a', Char(x))))), Int64(98)),
])
# IdDict's table is C (jl_eqtable_get/put, iddict.c); no lowering exists, so its methods reject
# at compile time ("unsupported method: foreigncall").
_xf("string_identity_gaps", Any[
    ("iddict_string_key", (x::Int64) -> (d = IdDict{String,Int64}(); d["ab"] = 7; get(d, string('a', Char(x)), -1)), Int64(98)),
])

# ---- lowering-registry coverage (charter C5, test/registry_coverage.jl) ----
# Each case below is the smallest ordinary program that reaches the registry entry named
# in its comment; the coverage lane confirms the entry fires while it compiles.

# FOREIGN_LOWERINGS. The seeded stream reaches `jl_type_intersection` through
# Random.hash_seed's dispatch guards: a total break of that lowering on 2026-09-08 failed
# every seeded Random differential in the full suite while smoke and probes stayed green.
# On 1.13 the stream seeds through Random.SeedHasher and SHA2_512 (128-bit division, byte swap
# and store; writes into a fresh String through its pointer).
_g("seeded_random", Any[
    ("seeded_rand_range", (s::Int64) -> rand(Xoshiro(s), 1:1000), Int64(42)),       # jl_type_intersection
    ("seeded_rand_float", (s::Int64) -> rand(Xoshiro(s)), Int64(7)),                # jl_type_intersection
    # a negative seed hashes one more constant, `(0x01,)`: it once read randperm's `(1,)` global
    ("seeded_randperm_negative", (s::Int64) -> (p = randperm(Xoshiro(s), 9); sum(p[i] * i for i in 1:9)), Int64(-7)),
])
_g("foreign_calls", Any[
    ("typeintersect_runtime", (x::Int64) -> typeintersect(x > 0 ? Int64 : String, Integer) === Int64 ? 1 : 0, Int64(1)),  # jl_type_intersection
    ("id_chars", (x::Int64) -> (Base.is_id_start_char(Char(x)) ? 1 : 0) + (Base.is_id_char(Char(x)) ? 2 : 0), Int64(97)), # jl_id_start_char, jl_id_char
    ("isidentifier", (x::Int64) -> Base.isidentifier(x > 0 ? "abc" : "1x") ? 1 : 0, Int64(1)),                           # jl_id_start_char, jl_id_char
    ("module_name", (x::Int64) -> x + length(String(nameof(Base.Math))), Int64(1)),                                      # jl_module_name
    ("module_parent", (x::Int64) -> x + length(String(nameof(parentmodule(Base.Math)))), Int64(1)),                      # jl_module_parent
    ("write_symbol", (x::Int64) -> (io = IOBuffer(); write(io, x > 0 ? :abc : :de); position(io)), Int64(1)),            # strlen
    # No Base method of Julia 1.12 or 1.13 calls jl_alloc_genericmemory (Memory{T}(undef, n)
    # is the `memorynew` builtin); an explicit ccall is the only spelling that reaches it.
    ("memcpy", (x::Int64) -> (a = zeros(UInt8, 4); b = UInt8[1, 2, 3, x]; GC.@preserve a b Base.memcpy(pointer(a), pointer(b), 4); Int64(a[4])), Int64(9)),  # memcpy
    ("alloc_genericmemory_ccall", (n::Int64) -> (m = ccall(:jl_alloc_genericmemory, Ref{Memory{Int64}}, (Any, Csize_t), Memory{Int64}, n); m[1] = 4; m[1] + length(m)), Int64(3)),
])

# INTRINSIC_BINOPS: the unchecked integer intrinsics have no Base spelling (`div`/`rem`/`!=`
# lower to checked_*/not_int(eq_int)), so these call them directly.
_g("intrinsics_int", Any[
    ("i32_ne", (x::Int32, y::Int32) -> Core.Intrinsics.ne_int(x, y) ? 1 : 0, Int32(3), Int32(4)),
    ("i64_ne", (x::Int64, y::Int64) -> Core.Intrinsics.ne_int(x, y) ? 1 : 0, Int64(3), Int64(3)),
    ("i32_sdiv_srem", (x::Int32, y::Int32) -> Int64(Core.Intrinsics.sdiv_int(x, y)) * 1000 + Int64(Core.Intrinsics.srem_int(x, y)), Int32(-17), Int32(5)),
    ("u32_udiv_urem", (x::UInt32, y::UInt32) -> Int64(Core.Intrinsics.udiv_int(x, y)) * 1000 + Int64(Core.Intrinsics.urem_int(x, y)), UInt32(17), UInt32(5)),
    ("i64_sdiv_srem", (x::Int64, y::Int64) -> Core.Intrinsics.sdiv_int(x, y) * 1000 + Core.Intrinsics.srem_int(x, y), Int64(-17), Int64(5)),
    ("u64_udiv_urem", (x::UInt64, y::UInt64) -> Int64(Core.Intrinsics.udiv_int(x, y)) * 1000 + Int64(Core.Intrinsics.urem_int(x, y)), UInt64(17), UInt64(5)),
    ("i32_count_ones", (x::Int32) -> count_ones(x), Int32(-3)),                     # INTRINSIC_UNOPS ctpop_int
])

# INTRINSIC_UNOPS / INTRINSIC_BINOPS on Float32, and the @fastmath forms.
_g("float32_fastmath", Any[
    ("f32_rounding", (x::Float32) -> ceil(x) * 1000f0 + floor(x) * 100f0 + round(x) * 10f0 + trunc(x), 2.5f0),  # ceil/floor/rint/trunc_llvm
    ("f32_neg", (x::Float32) -> -x, 2.5f0),                                          # neg_float
    ("f32_sqrt", (x::Float32) -> sqrt(x), 2.25f0),                                   # sqrt_llvm
    ("fast_sqrt", (x::Float64, y::Float32) -> @fastmath(sqrt(x)) + Float64(@fastmath(sqrt(y))), 6.25, 2.25f0),  # sqrt_llvm_fast
    ("f32_fast_minmax", (x::Float32, y::Float32) -> @fastmath(max(x, y)) * 10f0 + @fastmath(min(x, y)), 2.5f0, 1.5f0),  # max/min_float_fast
    ("f64_fast_minmax", (x::Float64, y::Float64) -> @fastmath(max(x, y)) * 10.0 + @fastmath(min(x, y)), -2.5, 1.5),     # max/min_float_fast
])

# INTRINSIC_CONVERSIONS.
_g("conversions", Any[
    ("f32_to_u32", (x::Float32) -> Int64(trunc(UInt32, x)) + Int64(unsafe_trunc(UInt32, x)), 7.75f0),  # fptoui F32→I32
    ("f32_to_i64", (x::Float32) -> trunc(Int64, x) + unsafe_trunc(Int64, x), -7.75f0),                 # fptosi F32→I64
    ("f32_to_u64", (x::Float32) -> Int64(trunc(UInt64, x)), 7.75f0),                                    # fptoui F32→I64
    ("f64_to_i32", (x::Float64) -> Int64(trunc(Int32, x)), -7.75),                                      # fptosi F64→I32
    ("f64_to_u32", (x::Float64) -> Int64(trunc(UInt32, x)), 7.75),                                      # fptoui F64→I32
    ("i32_bits_to_f32", (x::Int32) -> reinterpret(Float32, x), Int32(1069547520)),                     # bitcast I32→F32
    ("i32_to_f32", (x::Int32) -> Float32(x) / 4f0, Int32(-7)),                                          # sitofp I32→F32
    ("u32_to_f32", (x::UInt32) -> Float32(x) / 4f0, UInt32(7)),                                         # uitofp I32→F32
    ("i64_to_f32", (x::Int64) -> Float32(x) / 4f0, Int64(-7)),                                          # sitofp I64→F32
    ("u64_to_f32", (x::UInt64) -> Float32(x) / 4f0, UInt64(7)),                                         # uitofp I64→F32
])

# STANDALONE_INTRINSIC_BODIES: try/finally inside a catch lowers to an implicit
# `rethrow()` whose MethodInstance the closed world compiles as its own body.
_g("exceptions", Any[
    ("finally_in_catch", (x::Int64) -> (r = 0; try; try; x > 0 && error("a"); finally; r += 1; end; catch; r += 10; end; r), Int64(1)),
])

# BUILTIN_LOWERINGS reached from ordinary code: a call the optimizer leaves as a :call.
_g("builtins", Any[
    # sizeof of an Any element: Base.aligned_sizeof's `Core.sizeof` reaches its lowering
    ("sizeof_any", (x::Int64) -> (v = Any["abcd", 1]; sizeof(v[x])), Int64(1)),
    # compilerbarrier(kind, x) is x, its type hidden: boxed with its own class into the
    # statement's Any
    ("inferencebarrier_int", (x::Int64) -> Base.inferencebarrier(x)::Int64 + 1, Int64(1)),
    ("expr_new", (x::Int64) -> (e = Expr(:call, :+, 1, x); length(e.args)), Int64(1)),                              # Core._expr
    ("donotdelete", (x::Int64) -> (Base.donotdelete(x); x + 1), Int64(1)),                                           # Core.donotdelete
    ("isassigned_ref_elements", (x::Int64) -> (v = Vector{String}(undef, 3); v[1] = "a"; isassigned(v, x) ? 1 : 0), Int64(2)),  # memoryref_isassigned
    ("typeof_any", (x::Int64) -> (v = Any[1, 2.0]; typeof(v[x]) === Float64 ? 1 : 0), Int64(2)),                   # Core.typeof
    ("length_any", (x::Int64) -> (v = Any["abcé", [1, 2]]; length(v[x])::Int64), Int64(1)),                        # Base.length
    ("ifelse", (x::Int64) -> ifelse(x > 0, x, -x), Int64(-3)),                                                       # Core.ifelse
    ("sizeof_string", (x::Int64) -> sizeof(x > 0 ? "abcé" : "de"), Int64(1)),                                        # Core.sizeof
    ("ifelse_any_condition", (x::Int64) -> (v = Any[true, false]; ifelse(v[x], 1, 2)), Int64(2)),                  # Base.ifelse
    # Symbol(::Int64) is Julia's `Symbol(string(x...))`: no builtin; Julia's methods answer it
    ("symbol_int", (x::Int64) -> (Symbol(x) === Symbol("12") ? 1 : 0), Int64(12)),
    ("compilerbarrier_const", (x::Int64) -> Base.compilerbarrier(:const, x) + 1, Int64(1)),                         # Core.compilerbarrier
    ("inferencebarrier_ref", (x::Int64) -> (Base.inferencebarrier(Any[x])::Vector{Any})[1]::Int64, Int64(1)),     # Core.compilerbarrier
    ("getglobal_const_vector", (x::Int64) -> getglobal(Main, :_SMOKE_GLOBAL_VEC)[x], Int64(2)),                    # Core.getglobal
    # `-`/`*` on a captured, mutated accumulator: the dynamic operator whose operands carry
    # the variable's joined type (translateTypeOfLocalVariable)
    ("mutate_capture_sub", (n::Int64) -> ((s = 100; foreach(i -> (s -= i), 1:n); s)::Int64), Int64(5)),   # Base.:-
    ("mutate_capture_mul", (n::Int64) -> ((s = 1; foreach(i -> (s *= i), 1:n); s)::Int64), Int64(5)),     # Base.:*
    # one concrete operand type per machine width: the opcode and the unbox width are the
    # type the operands' nodes state (native 2.0, 1, 2.25, 55)
    ("mutate_capture_add_f64", (n::Int64) -> ((s = 0.0; foreach(i -> (s += 0.5), 1:n); s)::Float64), Int64(4)),                              # Base.:+
    ("mutate_capture_add_u64", (n::Int64) -> (((s = typemax(UInt64); foreach(i -> (s += UInt64(2)), 1:n); s)::UInt64) % Int64), Int64(1)),   # Base.:+
    ("mutate_capture_mul_f32", (n::Int64) -> Float64((s = 1.0f0; foreach(i -> (s *= 1.5f0), 1:n); s)::Float32), Int64(2)),                  # Base.:*
    ("mutate_capture_add_i64", (n::Int64) -> ((s = 0; foreach(i -> (s += i), 1:n); s)::Int64), Int64(10)),                                  # Base.:+
])
const _SMOKE_GLOBAL_VEC = [10, 20, 30]

# Arithmetic whose operands are results of an erased (Vector{Any}) closure call: Julia
# types each result `::Any`, so `+`/`-`/`*` runs on two Any values and rejects located at
# `dynamic (%a + %b)::Any`.
# These passed only while the call result was guessed as its first argument's type, and the
# megamorphic sum only while codegen re-inferred the call with Julia's max_methods cutoff lifted
# (Julia's own answer at the cutoff is the IR's `Any`). Gap:
# the typed value channel — each boxed operand unboxed by its classId and the operator
# dispatched on the classes, the result boxed with the class the chosen method returns.
_xf("erased_arithmetic", Any[
    ("erased_call", (n::Int64) -> (h = x -> x + n; fs = Any[h]; (fs[1](1) + fs[1](2))::Int64), Int64(3)),
    ("erased_two_closures", (n::Int64) -> (fs = Any[x -> x + n, x -> x * n]; (fs[1](1) + fs[2](2))::Int64), Int64(3)),
    ("erased_results_sub", (n::Int64) -> (h = x -> x + n; fs = Any[h]; (fs[1](5) - fs[1](2))::Int64), Int64(3)),
    ("erased_results_mul", (n::Int64) -> (h = x -> x + n; fs = Any[h]; (fs[1](5) * fs[1](2))::Int64), Int64(3)),
    ("erased_results_sub_f", (n::Float64) -> (h = x -> x + n; fs = Any[h]; (fs[1](5.0) - fs[1](2.0))::Float64), 1.5),
    ("erased_results_mul_f", (n::Float64) -> (h = x -> x + n; fs = Any[h]; (fs[1](5.0) * fs[1](2.0))::Float64), 1.5),
    ("megamorphic_all_int64", (n::Int64) -> ((t = 0; for x in _smm_xs(); t += _smm(x, n); end; t)::Int64), Int64(3)),
])

@noinline _sm_bump!(f) = f()
function _sm_boxlit(n::Int64)
    s = 0
    g = () -> (s += 1)
    _sm_bump!(g); _sm_bump!(g)
    x = n > 0 ? s : 0.5
    return x isa Float64 ? 1 : 2
end
# TLC findings against box_capture.jl's type recovery (dev/formal/NumericJoin.tla,
# BoxValueTypes.tla); native 1, 2 on 1.12/1.13. propagate_numeric_value_types and
# f3_box_value_types now pass their models (VERIFY rechecks each phi's join and restarts;
# literal operands join); the third TLC finding, box_value_literal_phi, answers as native
# (group inlined_captor). What each case does now:
# - numeric_join_seeded_phi: rejects located, "`+` on operands typed (Any, Float64) has no
#   single opcode" at `+(%16, 0.5)` (the phi is Any once VERIFY bans its Int64 seed).
# - numeric_join_dropped_phi: rejects located at `+(%26, 1)` (was a runtime "illegal cast"
#   trap).
_xf("box_type_recovery", Any[
    ("numeric_join_seeded_phi", (n::Int64) -> (s = 0; foreach(i -> (s += 0.5), 1:n); s isa Float64 ? 1 : 2), Int64(4)),
    ("numeric_join_dropped_phi", (n::Int64) -> (v = Any[1.5]; p = n > 0 ? v[1] : 0; q = p + 1; q isa Int64 ? 1 : 2), Int64(1)),
])

# BUILTIN_LOWERINGS apply_type: a `Union{T, Nothing}` built at run time is Julia's
# jl_type_union, which flattens, deduplicates and orders the members; that is not ported, so
# the construction rejects (builtins.jl `_lower_apply_type!`). It used to build a bare $JlUnion
# of the operands, which was not === the constant Union{Int64, Nothing} (native 1, wasm 0).
_xf("apply_type_union", Any[
    ("runtime_union_egal", (x::Int64) -> (T = x > 0 ? Int64 : Float64; U = Union{T, Nothing}; U === Union{Int64, Nothing} ? 1 : 0), Int64(1)),
])
# BUILTIN_LOWERINGS memorynew: a Memory is allocated with exactly n elements (it used to be
# padded to 16, so length(Memory{Int64}(undef, 3)) answered 16).
_g("memory_length", Any[
    ("memory_undef_length", (n::Int64) -> length(Memory{Int64}(undef, n)), Int64(3)),
])
# FOREIGN_LOWERINGS jl_type_unionall: `UnionAll(v, t)` constructs a type (jltypes.c
# jl_type_unionall, statements.jl `_fc_jl_type_unionall!`): a body without v is the body,
# `T where T<:S` is S, a non-type body is Julia's TypeError, anything else a new UnionAll —
# the mention test is jl_has_typevar, ported (get_has_typevar_function!). It used to emit
# `ref.test $JlUnionAll` on the TypeVar, a predicate in the constructed type's place.
const _SMOKE_TV = TypeVar(:T)
const _SMOKE_TV_S = TypeVar(:S, Integer)
@noinline _sm_unionall(t::TypeVar, @nospecialize(b)) = UnionAll(t, b)
_g("unionall_constructor", Any[
    ("unionall_body_without_var", (x::Int64) -> (b = Any[Int64, Vector{_SMOKE_TV}][x]; _sm_unionall(_SMOKE_TV, b) === Int64 ? 1 : 0), Int64(1)),
    ("unionall_body_with_var", (x::Int64) -> (b = Any[Int64, Vector{_SMOKE_TV}][x]; _sm_unionall(_SMOKE_TV, b) isa UnionAll ? 1 : 0), Int64(2)),
    ("unionall_body_is_var", (x::Int64) -> (b = Any[_SMOKE_TV_S, Int64][x]; _sm_unionall(_SMOKE_TV_S, b) === Integer ? 1 : 0), Int64(1)),
    ("unionall_new_node_parts", (x::Int64) -> (b = Any[Int64, Vector{_SMOKE_TV}][x]; u = _sm_unionall(_SMOKE_TV, b); u isa UnionAll ? ((u.var === _SMOKE_TV ? 10 : 20) + (u.body === Vector{_SMOKE_TV} ? 1 : 2)) : 0), Int64(2)),
    ("unionall_union_body", (x::Int64) -> (b = Any[Int64, Union{_SMOKE_TV, Nothing}][x]; _sm_unionall(_SMOKE_TV, b) isa UnionAll ? 1 : 0), Int64(2)),
    ("unionall_type_error", (x::Int64) -> (b = Any[Int64, 5][x]; try; _sm_unionall(_SMOKE_TV, b); 0; catch e; e isa TypeError ? 1 : 2; end), Int64(2)),
    ("supertype_of_unionall", (x::Int64) -> (v = Any[Vector, Int64]; t = v[x]; t isa UnionAll ? (s = supertype(t); s isa UnionAll ? ((s.var === t.var ? 10 : 20) + (s.body isa DataType ? 1 : 2)) : 0) : 5), Int64(1)),
])
# A type object is an instance of its kind, typeof(X) (constants.dart:361 _lowerTypeToConstant):
# a Union constant is a $JlUnion holding its members, a UnionAll a $JlUnionAll holding its
# body, and isa/typeof answer by the kind. Every type constant used to be a $JlDataType, so
# `isa Union`/`isa UnionAll` answered 0 and `isa DataType` 1 for them, and `typeof` of any
# type object trapped; the constants were keyed by isequal, so `Vector` and its body
# `Array{T,1}` (equal under mutual subtyping) shared one object.
_g("type_object_kinds", Any[
    ("isa_unionall_any", (x::Int64) -> (v = Any[Vector, Int64]; v[x] isa UnionAll ? 1 : 0), Int64(1)),
    ("isa_union_const", (x::Int64) -> (v = Any[Union{Int64,Nothing}, Int64]; v[x] isa Union ? 1 : 0), Int64(1)),
    ("isa_union_not_datatype", (x::Int64) -> (v = Any[Union{Int64,Nothing}, Int64]; v[x] isa DataType ? 1 : 0), Int64(1)),
    ("isa_unionall_not_datatype", (x::Int64) -> (v = Any[Vector, Int64]; v[x] isa DataType ? 1 : 0), Int64(1)),
    ("isa_datatype_const", (x::Int64) -> (v = Any[Int64, 5]; v[x] isa DataType ? 1 : 0), Int64(1)),
    ("isa_type_union", (x::Int64) -> (v = Any[Union{Int64,Nothing}, 1]; v[x] isa Type ? 1 : 0), Int64(1)),
    ("isa_type_int", (x::Int64) -> (v = Any[Int64, 5]; v[x] isa Type ? 1 : 0), Int64(2)),
    ("typeof_union_const", (x::Int64) -> (v = Any[Union{Int64,Nothing}, Int64]; typeof(v[x]) === Union ? 1 : 0), Int64(1)),
    ("typeof_unionall_const", (x::Int64) -> (v = Any[Vector, Int64]; typeof(v[x]) === UnionAll ? 1 : 0), Int64(1)),
    ("typeof_datatype_const", (x::Int64) -> (v = Any[Vector, Int64]; typeof(v[x]) === DataType ? 1 : 0), Int64(2)),
    ("typeof_int_value", (x::Int64) -> (v = Any[Int64, 5]; typeof(v[x]) === Int64 ? 1 : 0), Int64(2)),
    ("union_const_egal", (x::Int64) -> (v = Any[Union{Int64,Nothing}, Int64]; v[x] === Union{Nothing,Int64} ? 1 : 0), Int64(1)),
    ("union_member_a", (x::Int64) -> (v = Any[Union{Int64,Nothing}, Int64]; u = v[x]; u isa Union ? (u.a === Nothing ? 1 : 2) : 0), Int64(1)),
    ("union_member_b", (x::Int64) -> (v = Any[Union{Int64,Nothing}, Int64]; u = v[x]; u isa Union ? (u.b === Int64 ? 1 : 2) : 0), Int64(1)),
    ("unionall_body", (x::Int64) -> (v = Any[Vector, Int64]; u = v[x]; u isa UnionAll ? (u.body isa DataType ? 1 : 2) : 0), Int64(1)),
    ("datatype_param", (x::Int64) -> (v = Any[Vector{Int64}, Int64]; t = v[x]; t isa DataType ? (t.parameters[1] === Int64 ? 1 : 2) : 0), Int64(1)),
    ("datatype_param_union", (x::Int64) -> (v = Any[Vector{Union{Int64,Nothing}}, Int64]; t = v[x]; t isa DataType ? (t.parameters[1] isa Union ? 1 : 2) : 0), Int64(1)),
    # a TypeVar is a constant object holding its name and bounds; a UnionAll holds its var
    ("typevar_isa", (x::Int64) -> (v = Any[_SMOKE_TV, 1]; v[x] isa TypeVar ? 1 : 0), Int64(1)),
    ("typeof_typevar", (x::Int64) -> (v = Any[_SMOKE_TV, 1]; typeof(v[x]) === TypeVar ? 1 : 0), Int64(1)),
    ("typevar_ub_name", (x::Int64) -> (v = Any[_SMOKE_TV, 1]; t = v[x]; t isa TypeVar ? (t.ub === Any ? 10 : 20) + (t.name === :T ? 1 : 2) : 0), Int64(1)),
    ("unionall_var_name", (x::Int64) -> (v = Any[Vector, Int64]; u = v[x]; u isa UnionAll ? (u.var.name === :T ? 1 : 2) : 0), Int64(1)),
    ("unionall_var_lb", (x::Int64) -> (v = Any[Vector, Int64]; u = v[x]; u isa UnionAll ? (u.var.lb === Union{} ? 1 : 2) : 0), Int64(1)),
    # Union{} is the one instance of Core.TypeofBottom: a Type, not a DataType
    ("bottom_egal", (x::Int64) -> (v = Any[Union{}, Int64]; v[x] === Union{} ? 1 : 0), Int64(1)),
    ("bottom_isa_type", (x::Int64) -> (v = Any[Union{}, 5]; v[x] isa Type ? 1 : 0), Int64(1)),
    ("bottom_not_datatype", (x::Int64) -> (v = Any[Union{}, Int64]; v[x] isa DataType ? 1 : 0), Int64(1)),
    ("typeof_bottom", (x::Int64) -> (v = Any[Union{}, Int64]; typeof(v[x]) === Core.TypeofBottom ? 1 : 0), Int64(1)),
])
# isa is a test or Julia's own answer, never a constant (calls.jl `_compile_call_isa`): an
# unboxed numeric answers by its exact Julia type (a captured Int64 is not a Float64; a UInt64
# in an I64 local is not Signed), and a type object answers by its kind.
_g("isa_exact", Any[
    ("isa_captured_int_float", (x::Int64) -> (c = x; g = () -> (c += 1); g(); isa(c, Float64) ? 1 : 0), Int64(3)),
    ("isa_captured_uint_signed", (x::Int64) -> (c = UInt64(x); g = () -> (c += UInt64(1)); g(); isa(c, Signed) ? 1 : 0), Int64(3)),
    ("isa_type_object", (i::Int64) -> (v = Any[i, Int64, :a][i]; isa(v, Type) ? 1 : 0), Int64(2)),
])
# `isa(x, T)` with a runtime `T` has no runtime subtype test: it rejects at its statement
# ("isa(x, T) with a runtime type T"); it answered 0 where native answers 1.
_xf("isa_runtime_type", Any[
    ("isa_runtime_type", (i::Int64) -> (ts = Any[Int64, Float64]; isa(i, ts[i]) ? 1 : 0), Int64(1)),
])
# A value held abstractly: `ncodeunits` of an AbstractString element dispatches to the element's
# own method (the builtin lowered every AbstractString as a String's byte array, which read a
# SubString's parent or trapped at the cast), and `typeof` of a Memory held in Any is read off
# its array type (a bare array carries no classId; the classId read trapped).
# Int128/UInt128 over two i64 limbs (dev/formal/Int128Limbs.tla): the shift intrinsics past the
# width (they took the amount modulo 64: shl_int(Int128(1), 130) answered 2^66), division and
# remainder (once rejected), and the byte swap (once rejected).
@noinline _sm_one128(n::Int64) = Int128(n > -1000) + Int128(n) * 0
_g("int128_limbs", Any[
    ("shl_past_width", (n::Int64) -> (r = Core.Intrinsics.shl_int(_sm_one128(n), n % UInt64); Int64((r >> 64) % Int64) * 1000 + Int64(r % Int64)), Int64(130)),
    ("ashr_past_width", (n::Int64) -> (r = Core.Intrinsics.ashr_int(-(_sm_one128(n) << 100), n % UInt64); Int64(r % Int64)), Int64(128)),
    ("sdiv_wide", (n::Int64) -> Int64(div(Int128(n) << 70 + 12345, -(Int128(n) << 65 + 3)) % Int64), Int64(987654321)),
    ("urem_big_divisor", (n::Int64) -> Int64(rem(typemax(UInt128) - UInt128(n), (UInt128(1) << 127) + UInt128(n)) >> 100), Int64(5)),
    ("sdiv_typemin_by_minus1", (n::Int64) -> (try; Int64(div(typemin(Int128) + Int128(n), Int128(-1)) % Int64); catch e; e isa DivideError ? -1 : -2; end), Int64(0)),
    ("bswap_u128", (n::Int64) -> Int64(bswap(UInt128(n) << 64 + UInt128(0x0102030405060708)) % Int64), Int64(7)),
])
# Julia's own math kernels, bit-exact against native: each case hashes the exact result bits
# of f over n evenly spaced inputs in (-20, 20], so one == compares n answers. A NaN result
# counts as one canonical NaN (its sign bit is the host's). muladd_float and fma_float round
# once (Julia's fma_emulated) and have_fma is true, as natively on an FMA host: with two
# roundings exp, expm1 and acos differed in the last bit, and hypot took its fallback branch.
# The Float32 exp/exp2/exp10/sinh/cosh/tanh and Float64 sinh/cosh/tanh/asin/hypot overlays
# they replace answered differently from Julia (exp(-2.4282868f0) was 0.088187784f0, Julia's
# is 0.08818779f0). x^n is not here: muladd lets the compiler round once or twice, and native
# Julia 1.12 fuses the muladds in pow_body where native 1.13 does not (measured on all 4001
# inputs), so no one lowering is both versions' answer.
@noinline function _sm_bits(f::F, ::Type{T}, n::Int64)::Int64 where {F,T}
    acc = UInt64(14695981039346656037)
    for i in 1:n
        r = f(T(-20.0 + 40.0 * i / n))
        b = isnan(r) ? UInt64(0x7ff8000000000000) : UInt64(reinterpret(Base.uinttype(T), r))
        acc = (acc ⊻ b) * 0x00000100000001b3
    end
    return reinterpret(Int64, acc)
end
# fma over its own branches: subnormal operands and results, a product below 2^-969,
# overflow, infinities, NaN, signed zeros, and an exact cancellation two roundings lose.
const _SM_FMA_TABLE = NTuple{3,Float64}[
    (1.0 + 2.0^-30, 1.0 - 2.0^-30, -1.0), (1e-310, 2.0, 0.0), (1e-310, 1e-310, 1e-320),
    (1e-200, 1e-200, 1e-310), (3.0e-160, 7.0e-160, -2.0e-318), (1e300, 1e10, -1e308),
    (1e300, 1e300, -Inf), (Inf, 0.0, 1.0), (Inf, 1.0, -Inf), (-0.0, 1.0, 0.0),
    (-0.0, 1.0, -0.0), (0.1, 10.0, -1.0), (nextfloat(1.0), prevfloat(1.0), -1.0),
    (-1.7976931348623157e308, 2.0, 1.7976931348623157e308), (5e-324, 0.5, 0.0)]
@noinline function _sm_fma_bits(k::Int64)::Int64
    acc = UInt64(14695981039346656037)
    for (a, b, c) in _SM_FMA_TABLE
        r = k == 1 ? fma(a, b, c) : muladd(a, b, c)
        acc = (acc ⊻ (isnan(r) ? UInt64(0x7ff8000000000000) : reinterpret(UInt64, r))) * 0x00000100000001b3
    end
    return reinterpret(Int64, acc)
end
_g("bit_exact_math", Any[
    ("exp_f64", (n::Int64) -> _sm_bits(exp, Float64, n), Int64(4001)),
    ("expm1_f64", (n::Int64) -> _sm_bits(expm1, Float64, n), Int64(4001)),
    ("acos_f64", (n::Int64) -> _sm_bits(x -> acos(x / 21), Float64, n), Int64(4001)),
    ("asin_f64", (n::Int64) -> _sm_bits(x -> asin(x / 21), Float64, n), Int64(4001)),
    ("sinh_f64", (n::Int64) -> _sm_bits(sinh, Float64, n), Int64(4001)),
    ("cosh_f64", (n::Int64) -> _sm_bits(cosh, Float64, n), Int64(4001)),
    ("tanh_f64", (n::Int64) -> _sm_bits(tanh, Float64, n), Int64(4001)),
    ("hypot_f64", (n::Int64) -> _sm_bits(x -> hypot(x, 1.5), Float64, n), Int64(4001)),
    ("pow_f64", (n::Int64) -> _sm_bits(x -> abs(x)^1.7, Float64, n), Int64(4001)),
    ("log_sin_atan_f64", (n::Int64) -> _sm_bits(x -> log(abs(x) + 1e-3) + sin(x) + atan(x), Float64, n), Int64(4001)),
    ("exp_f32", (n::Int64) -> _sm_bits(exp, Float32, n), Int64(4001)),
    ("exp2_f32", (n::Int64) -> _sm_bits(exp2, Float32, n), Int64(4001)),
    ("exp10_f32", (n::Int64) -> _sm_bits(x -> exp10(x / 3), Float32, n), Int64(4001)),
    ("sinh_f32", (n::Int64) -> _sm_bits(sinh, Float32, n), Int64(4001)),
    ("cosh_f32", (n::Int64) -> _sm_bits(cosh, Float32, n), Int64(4001)),
    ("tanh_f32", (n::Int64) -> _sm_bits(tanh, Float32, n), Int64(4001)),
    ("fma_branches", _sm_fma_bits, Int64(1)),
    ("muladd_fused", _sm_fma_bits, Int64(2)),
])
# Julia's own bit-level bodies, which replaced overlays: shifts by a negative or oversized
# Int amount (the overlays existed because `0x01 << typemin(Int64)` once answered 1; Julia's
# is 0), isless over NaN and signed zeros, unsigned of negatives, primitive reinterpret.
_g("julia_bit_bodies", Any[
    ("shl_typemin", (n::Int64) -> Int64(0x01 << (typemin(Int64) + n)), Int64(0)),
    ("shl_negative", (n::Int64) -> Int64(UInt32(40) << -n), Int64(3)),
    ("ashr_oversized", (n::Int64) -> Int64(Int8(-100) >> n), Int64(200)),
    ("lshr_negative", (n::Int64) -> Int64(UInt16(5) >>> -n), Int64(4)),
    ("shl_width", (n::Int64) -> (typemax(Int64) << n) + (Int32(7) << (n - 32)), Int64(64)),
    ("isless_nan_zero", (x::Float64) -> Int64(isless(x, NaN)) + 2Int64(isless(NaN, x)) +
                                         4Int64(isless(-0.0, x)) + 8Int64(isless(x, -0.0)) +
                                         16Int64(isless(NaN, NaN)), 0.0),
    ("isless_f32", (x::Float32) -> Int64(isless(x, NaN32)) + 2Int64(isless(-0.0f0, x)) +
                                   4Int64(isless(x, -1.0f0)), 0.0f0),
    ("sort_nan_zeros", (x::Float64) -> (v = sort([NaN, 1.0, -0.0, x, -1.0]);
                                        Int64(isnan(v[5])) + 2Int64(signbit(v[2])) + 4Int64(v[4] == 1.0)), 0.0),
    ("unsigned_neg", (n::Int64) -> Int64(unsigned(Int8(-n))) + Int64(unsigned(Int16(-n)) % 1000) +
                                   Int64(unsigned(Int32(-n)) % 1000) + Int64(unsigned(-n) % 1000), Int64(3)),
    ("reinterpret_prims", (x::Float64) -> Int64(reinterpret(UInt64, x) % 1000) +
                                          Int64(reinterpret(UInt32, Float32(x)) % 1000) +
                                          Int64(reinterpret(Int64, -x) % 1000) +
                                          Int64(reinterpret(Float64, reinterpret(UInt64, x) + 1) > x), -0.1),
])
# A MemoryRef or Memory held erased. Each dispatch reads the callee's declared signature, where
# a MemoryRef crosses as its single-value struct (the closure layouter and the inline typeId
# dispatch each re-derived it as the bare Memory: a StackImbalanceError, a codegen error), and
# the collector counts memoryrefnew and jl_alloc_genericmemory as instantiations (without them
# the dispatch had no MemoryRef row and trapped where Julia answers). A Memory carries no class
# header, so both dispatches tell it by its array type (emit_class_id!); they read the header and
# trapped.
_g("memoryref_erased", Any[
    ("erased_closure_memoryref", (n::Int64) -> (v = [n, 2n]; h = r -> (r[]::Int64) + n; fs = Any[h];
                                                (fs[1](v.ref)::Int64) + (fs[1](Ref(5n))::Int64)), Int64(3)),
    ("any_memoryref_dispatch", (n::Int64) -> (v = [n, 2n]; xs = Any[v.ref, Ref(5n)];
                                              (xs[1][]::Int64) + (xs[2][]::Int64)), Int64(3)),
    ("any_memory_dispatch", (n::Int64) -> (xs = Any[Memory{Int64}(undef, n), [1, 2]];
                                           (length(xs[1])::Int64) * 10 + (length(xs[2])::Int64)), Int64(3)),
    ("erased_closure_memory", (n::Int64) -> (h = m -> (length(m)::Int64) + n; fs = Any[h];
                                             (fs[1](Memory{Int64}(undef, n))::Int64) * 10 + (fs[1]([1, 2])::Int64)), Int64(3)),
])
# A captured variable's type is the join of every write into its Core.Box across the closed world,
# the creator's included (record_capture_contents; dev/formal/CaptureType.tla). A closure body once
# guessed it alone from its own arithmetic: `c = c + 1` over a box its creator filled with 0.25
# guessed Int64, and the read unboxed a Float64 box as an Int64 one (a trap; Julia answers 2.25).
@noinline _sm_cap_int(x::Int64) = (c = x; () -> (c = c + 1; c))
@noinline _sm_cap_float(x::Float64) = (c = x; () -> (c = c + 0.5; c))
@noinline _sm_cap_undef() = (local r; () -> (r = Int64[]; push!(r, 1); r))
_g("captured_variables", Any[
    # a closure capturing a type: the frontend's Core._typeof_captured_variable asks
    # jl_has_free_typevars of the constant type
    ("captured_type", (n::Int64) -> (T = Int64; g = x -> T(x) + one(T); g(n)), Int64(4)),
    ("int_counter", (x::Int64) -> (f = _sm_cap_int(x); f(); f()), Int64(3)),
    ("float_counter", (x::Float64) -> (f = _sm_cap_float(x); f(); f()), 0.25),
    ("undefined_then_written", (n::Int64) -> (f = _sm_cap_undef(); length(f()) + n), Int64(3)),
])
# The same shape with a Float64 creator and an Int64 step reads its Float64 correctly, and then
# `+(::Float64, ::Int64)` rejects: arithmetic on two concrete types that differ (MARCH 13.10).
@noinline _sm_cap_mixed(x::Float64) = (c = x; () -> (c = c + 1; c))
_xf("captured_mixed_step", Any[
    ("float_counter_int_step", (x::Float64) -> (f = _sm_cap_mixed(x); f(); f()), 0.25),
])
# Loads and stores through a storage pointer: one offset for every arm, `ptr - base + (i - 1) *
# sizeof(T)`, with a String's or Symbol's pointer carrying base 1 and a Memory's base 0
# (_emit_storage_pointer_offset!, calls.jl). The byte store ignored `i` (every store landed on
# byte 0 of a Vector{UInt8}), a String store was off by one, and a String load read one add_ptr
# step as the index and ignored `i` and sub_ptr.
_g("storage_pointers", Any[
    ("string_load_offset_index", (n::Int64) -> (s = "abcdefgh"; GC.@preserve s Int64(unsafe_load(pointer(s) + n ÷ 10, n % 10))), Int64(23)),
    ("vector_load_offset_index", (n::Int64) -> (v = UInt8[0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68]; GC.@preserve v Int64(unsafe_load(pointer(v) + n ÷ 10, n % 10))), Int64(23)),
    ("string_store_index", (n::Int64) -> (s = Base._string_n(8); GC.@preserve s (for k in 1:8; unsafe_store!(pointer(s), UInt8(0x40 + k), k); end; unsafe_store!(pointer(s) + n ÷ 10, UInt8(0x7a), n % 10)); sum(Int64(codeunit(s, k)) * k for k in 1:8)), Int64(23)),
    ("vector_store_index", (n::Int64) -> (v = zeros(UInt8, 8); GC.@preserve v (for k in 1:8; unsafe_store!(pointer(v), UInt8(0x40 + k), k); end; unsafe_store!(pointer(v) + n ÷ 10, UInt8(0x7a), n % 10)); sum(Int64(v[k]) * k for k in 1:8)), Int64(23)),
    ("string_store_first_byte", (n::Int64) -> (s = Base._string_n(3); GC.@preserve s unsafe_store!(pointer(s), UInt8(65 + n)); Int64(codeunit(s, 1))), Int64(1)),
])
# A long string constant codegen itself emits (Julia's `_new_genericmemory_` message, 107
# bytes) and a long Symbol name are eager constant globals; they were bytes in a passive data
# segment, the one constant path outside the constant funnel (R15).
_g("long_constants", Any[
    ("memory_size_message", (n::Int64) -> (try; length(Memory{UInt8}(undef, n)); catch e; m = (e::ArgumentError).msg::String; ncodeunits(m) * 1000 + Int64(codeunit(m, 9)); end), Int64(-1)),
    ("long_symbol_name", (n::Int64) -> ncodeunits(String(:a_symbol_whose_name_is_well_past_the_sixty_four_byte_eager_threshold)) + n, Int64(1)),
])
_g("abstract_receivers", Any[
    ("ncodeunits_abstract_string", (x::Int64) -> (v = AbstractString["abc", SubString("hello", 2, 3)]; ncodeunits(v[x])), Int64(1)),
    ("ncodeunits_abstract_substring", (x::Int64) -> (v = AbstractString["abc", SubString("hello", 2, 3)]; ncodeunits(v[x])), Int64(2)),
    ("ncodeunits_substring", (x::Int64) -> ncodeunits(SubString("hello", 2, 1 + x)), Int64(3)),
    ("ncodeunits_error_message", (x::Int64) -> (try; throw(ArgumentError(x > 0 ? "bad" : "no")); catch e; ncodeunits((e::ArgumentError).msg); end), Int64(1)),
    ("boxed_memory_typeof", (x::Int64) -> (v = Any[Memory{UInt8}(undef, x)]; Int64(typeof(_si_any(v, 1)) === Memory{UInt8})), Int64(3)),
])
# A dynamic ==/!= over two erased operands is Julia's dispatch on both operands' classes, which
# WT does not lower yet (two-position dispatch, MARCH 13.10): each rejects at its statement, and
# an answer, right or wrong, is reported here.
_xf("dynamic_eq_erased", Any[
    ("float_pair", (x::Int64) -> (v = Any[1.0, 1.0]; v[1] == v[2] ? 1 : 0), Int64(1)),
    ("int_pair", (x::Int64) -> (v = Any[x, x]; v[1] == v[2] ? 1 : 0), Int64(3)),
    ("mixed_pair", (x::Int64) -> (v = Any[x, 1.0]; v[1] == v[2] ? 1 : 0), Int64(1)),
])
# BUILTIN_LOWERINGS crashes: each compiles or runs to a failure where native returns a value.
_xf("builtin_crashes", Any[
    # getfield by a runtime name where WT's layout does not hold Julia's fields in Julia's
    # order (DataType, TypeName are projections) or the read is not a field (a Module's is a
    # global binding): the read rejects at its statement, with why. Until 2026-09-29 the
    # DataType read raised a codegen bug and the Module read threw FieldError where Julia
    # returns (dev/AUDIT.md E1); answering, wrong or right, is an outcome mismatch here.
    ("datatype_runtime_name", (x::Int64) -> (v = _sm_dt_getfield(x > 0 ? Int64 : Float64, x > 2 ? :hash : :flags); v isa Int32 ? Int64(v::Int32) : -1), Int64(3)),
    ("module_runtime_name", (x::Int64) -> (getfield(x > 0 ? Base : Core, x > 2 ? :pi : :nothing) === nothing ? 1 : 2), Int64(3)),
    # Symbol of an Any element: `Symbol(::Any)` is Julia's dynamic dispatch, and a constructor
    # callee enrolls no dispatch candidates, so it rejects at its statement. A `Symbol` builtin
    # once cast the value to the classed string (a trap for an Int64), and get_function's
    # reverse-subtype pass then bound it to a compiled `Symbol(::String)`.
    ("symbol_any_int", (x::Int64) -> (v = Any[12, "cde"]; Symbol(v[x]) === Symbol("12") ? 1 : 0), Int64(1)),
    ("symbol_any_string", (x::Int64) -> (v = Any[12, "cde"]; Symbol(v[x]) === :cde ? 1 : 0), Int64(2)),
    # Base.getproperty/setproperty! on an Any element: the struct and primitive dispatch
    # candidates compile (getfield_runtime_name); the Memory{Any} candidate rejects — its
    # getfield by a runtime name could read `ptr`, which escapes the storage-pointer algebra,
    # and setproperty! asks fieldtype(Memory{Any}, name) (MARCH 13.10)
    ("getproperty_any", (x::Int64) -> (v = Any[_Pt(x, 2)]; v[1].x::Int64), Int64(5)),
    ("setproperty_any", (x::Int64) -> (v = Any[_Box(1)]; v[1].v = x; (v[1]::_Box).v), Int64(5)),
])
# A dynamic call binds to no specialization compiled for other argument types. `_RW(::Any)`
# holding a Symbol once ran the compiled `_RW(::String)` (get_function matched the Any
# argument by reverse subtyping; String and Symbol share one wasm struct, so the cast passed)
# and answered 1001 for 1100. A constructor callee enrolls no dispatch candidates, so the call
# rejects at its statement; answering wrong again is an outcome mismatch here.
struct _RW; v::Int64; end
@noinline _RW(x::String) = _RW(ncodeunits(x))
@noinline _RW(x::Symbol) = _RW(100)
_xf("dynamic_constructor", Any[
    ("ctor_any_symbol", (x::Int64) -> (vs = Any["abc", :b]; _RW("z").v * 1000 + (_RW(vs[x])::_RW).v), Int64(2)),
    ("ctor_any_string", (x::Int64) -> (vs = Any["abc", :b]; _RW("z").v * 1000 + (_RW(vs[x])::_RW).v), Int64(1)),
])
# `ncodeunits(e.msg)` of a caught ArgumentError: `msg` is an AbstractString, so the call is
# dynamic dispatch over the closed world's AbstractString classes; with one class observed the
# inline switch has one row, and a one-row switch traps wherever discovery missed a class (the
# constructor cases above), so the call rejects until dispatch is dart's table (MARCH 13.4).
# The builtin once read every AbstractString as a String, which was wrong for a SubString.
_xf("dynamic_single_class", Any[
    ("pop_empty_message", (n::Int64) -> (v = collect(1:n); try; pop!(v); 0; catch e; e isa ArgumentError ? (ncodeunits(e.msg)::Int) : -1; end), Int64(0)),
])
# objectid of an immutable is its content's hash (jl_object_id_, builtins.c: the type's hash mixed
# with each field's id; the objectid overlay, interpreter.jl). Base.dataids -> mightalias ->
# unalias reaches it when 1.12's `Vector{UInt8}(s)` copies from `codeunits(s)`; the lowered
# jl_object_id once gave an immutable a per-object counter (and trapped at a cast for CodeUnits).
_g("immutable_objectid", Any[
    ("objectid_equal_immutables", (n::Int64) -> objectid(Base.CodeUnits(string(n))) == objectid(Base.CodeUnits(string(n))) ? 1 : 0, Int64(7)),
    ("vector_from_string", (n::Int64) -> length(Vector{UInt8}(n > 0 ? "hello" : "ab")), Int64(1)),
])
# FOREIGN_LOWERINGS rejects: every program measured to reach these stops at a loud reject.
_xf("pointer_foreigncalls", Any[
    # jl_value_ptr: pointer_from_objref of a Ref rejects "jl_value_ptr escapes
    # storage-relative WasmGC operations"
    ("ref_pointer_load", (x::Int64) -> (r = Ref(x); GC.@preserve r unsafe_load(Base.unsafe_convert(Ptr{Int64}, r))), Int64(5)),
    # jl_ptr_to_array_1d: the lowering cannot trace pointer(v) and declines ("no lowering")
    ("unsafe_wrap_pointer", (n::Int64) -> (v = collect(1:n); GC.@preserve v (w = unsafe_wrap(Array, pointer(v), n); w[2])), Int64(3)),
])
# `repr` of a runtime type (native "Int64")
_g("show_type", Any[
    ("repr_runtime_type", (x::Int64) -> length(repr(x > 0 ? Int64 : Float64)), Int64(1)),
])
# ---- Union{Nothing,<numeric>} storage (dart's `int?` = a nullable boxed ref) ----
# A Union{Nothing,Int64} field / return / element must hold `nothing` distinctly from 0;
# @noinline keeps the struct, the call and the vector from being scalar-replaced away.
struct _UFImm; f::Union{Nothing,Int64}; end
mutable struct _UFMut; f::Union{Nothing,Int64}; end
struct _UFF64; f::Union{Nothing,Float64}; end
struct _UFBool; f::Union{Nothing,Bool}; end
@noinline _uf_imm(x::Int64) = _UFImm(x > 0 ? x : nothing)
@noinline _uf_immv(x::Int64) = _UFImm(x)
@noinline _uf_f64(x::Int64) = _UFF64(x > 0 ? Float64(x) / 2 : nothing)
@noinline _uf_bool(x::Int64) = _UFBool(x > 0 ? isodd(x) : nothing)
@noinline _uf_clear!(m::_UFMut) = (m.f = nothing; nothing)
@noinline _uf_set!(m::_UFMut, x::Int64) = (m.f = x; nothing)
@noinline _uf_ret(x::Int64) = x > 0 ? x : nothing
@noinline _uf_vec(x::Int64) = Union{Nothing,Int64}[x, nothing, 0]
_g("union_fields", Any[
    ("imm_nothing_is", (x::Int64) -> Int64(_uf_imm(x).f === nothing), Int64(-3)),
    ("imm_int_is", (x::Int64) -> Int64(_uf_imm(x).f === nothing), Int64(3)),
    ("imm_nothing_isnot", (x::Int64) -> Int64(_uf_imm(x).f !== nothing), Int64(-3)),
    ("imm_int_isnot", (x::Int64) -> Int64(_uf_imm(x).f !== nothing), Int64(3)),
    ("imm_something_nothing", (x::Int64) -> something(_uf_imm(x).f, Int64(77)), Int64(-3)),
    ("imm_something_int", (x::Int64) -> something(_uf_imm(x).f, Int64(77)), Int64(3)),
    ("imm_isa_nothing", (x::Int64) -> Int64(_uf_imm(x).f isa Nothing), Int64(-3)),
    ("imm_zero_is_not_nothing", (x::Int64) -> Int64(_uf_immv(x).f === nothing), Int64(0)),
    ("mut_set_nothing", (x::Int64) -> (m = _UFMut(x); _uf_clear!(m); Int64(m.f === nothing)), Int64(4)),
    ("mut_roundtrip", (x::Int64) -> (m = _UFMut(nothing); _uf_set!(m, x);
        a = m.f === nothing ? -1 : m.f::Int64; _uf_clear!(m); b = m.f === nothing ? 1 : 0; a * 10 + b), Int64(4)),
    ("mut_roundtrip_zero", (x::Int64) -> (m = _UFMut(nothing); _uf_set!(m, x);
        a = m.f === nothing ? -1 : m.f::Int64; a * 10 + (m.f === nothing ? 1 : 0)), Int64(0)),
    ("f64_nothing", (x::Int64) -> (f = _uf_f64(x).f; f === nothing ? -1.0 : f::Float64), Int64(-3)),
    ("f64_value", (x::Int64) -> (f = _uf_f64(x).f; f === nothing ? -1.0 : f::Float64), Int64(5)),
    ("bool_nothing", (x::Int64) -> (f = _uf_bool(x).f; f === nothing ? Int64(-1) : Int64(f::Bool)), Int64(-3)),
    ("bool_value", (x::Int64) -> (f = _uf_bool(x).f; f === nothing ? Int64(-1) : Int64(f::Bool)), Int64(5)),
    ("ret_nothing", (x::Int64) -> (r = _uf_ret(x); r === nothing ? Int64(-1) : r::Int64), Int64(-3)),
    ("ret_value", (x::Int64) -> (r = _uf_ret(x); r === nothing ? Int64(-1) : r::Int64), Int64(3)),
    ("vec_elements", (x::Int64) -> (v = _uf_vec(x); c = 0; for e in v; c = 10c + (e === nothing ? 9 : e::Int64); end; c), Int64(4)),
    # Base's own Union{Nothing,Int64} returns: a miss is `nothing`, never index 0
    ("findfirst_vec_miss", (x::Int64) -> (r = findfirst(==(x), Int64[1, 2, 3]); r === nothing ? Int64(-1) : r), Int64(9)),
    ("findfirst_vec_hit", (x::Int64) -> (r = findfirst(==(x), Int64[1, 2, 3]); r === nothing ? Int64(-1) : r), Int64(2)),
    ("findfirst_char_miss", (x::Int64) -> Int64(findfirst(==(Char(x)), "abc") === nothing), Int64(122)),
])
# ---- a loop whose back edge is a goto-if-not (1.13 lays the String search loop of
# findfirst that way): the one CFG's loop bounds see it (L181; on 1.12 its back edge is a goto)
_g("loop_backward_branch", Any[
    ("findfirst_char_miss", (x::Int64) -> Int64(findfirst(==(Char(x)), "abc") === nothing), Int64(122)),
    ("findfirst_char_hit", (x::Int64) -> (r = findfirst(==(Char(x)), "abcabc"); r === nothing ? Int64(-1) : Int64(r)), Int64(99)),
    ("findnext_char_hit", (x::Int64) -> (r = findnext(==(Char(x)), "abcabc", 4); r === nothing ? Int64(-1) : Int64(r)), Int64(98)),
])
# ---- Union{Nothing,<numeric>} values: returns, phis, typeof, union-split calls ----
# Each shape runs at a `nothing` input, a 0 input and a nonzero input, so a nothing-vs-0
# confusion shows. A phi typed Int64 by inference can receive `nothing` on a path that
# never reads it (Julia gives the phi an undefined value there); `typeof` of `nothing`
# held in a Union is Nothing; a union-split call returns its branch's concrete type.
@noinline _un_i64(x::Int64) = x > 0 ? nothing : x
@noinline _un_bool(x::Int64) = x > 0 ? nothing : iseven(x)
@noinline _un_f64(x::Int64) = x > 0 ? nothing : Float64(x) / 2
@noinline _un_char(x::Int64) = x > 0 ? nothing : Char(64 - x)
@noinline _un_missing(x::Int64) = x > 0 ? missing : x
@noinline _un_pass(r::Union{Nothing,Int64}) = r
@noinline _un_passb(r::Union{Nothing,Bool}) = r
struct _UNMiss; f::Union{Missing,Int64}; end
@noinline _un_miss_field(x::Int64) = _UNMiss(x > 0 ? missing : x)
_un_phi_loop(n::Int64) = (r = nothing; for i in 1:n; i == 2 && (r = i - 2); end; r === nothing ? -1 : r)
_un_phi_loop_bool(n::Int64) = (r = nothing; for i in 1:n; i == 2 && (r = isodd(n)); end; r === nothing ? -1 : Int64(r))
_un_phi_loop_f64(n::Int64) = (r = nothing; for i in 1:n; i == 2 && (r = n / 4); end; r === nothing ? -1.0 : r)
_un_ret(x::Int64) = (r = _un_i64(x); r === nothing ? 7 : r)
_un_typeof(x::Int64) = (r = _un_i64(x); typeof(r) === Nothing ? 1 : (typeof(r) === Int64 ? 2 : 3))
_un_split(x::Int64) = (r = _un_pass(_un_i64(x)); r === nothing ? -1 : r)
_un_split_bool(x::Int64) = (r = _un_passb(_un_bool(x)); r === nothing ? -1 : Int64(r))
_g("union_nothing", Any[
    ("ret_nothing", _un_ret, Int64(1)),
    ("ret_zero", _un_ret, Int64(0)),
    ("ret_value", _un_ret, Int64(-4)),
    ("bool_nothing", (x::Int64) -> (r = _un_bool(x); r === nothing ? Int64(7) : Int64(r)), Int64(1)),
    ("bool_false", (x::Int64) -> (r = _un_bool(x); r === nothing ? Int64(7) : Int64(r)), Int64(-3)),
    ("f64_nothing", (x::Int64) -> (r = _un_f64(x); r === nothing ? 7.0 : r), Int64(1)),
    ("f64_zero", (x::Int64) -> (r = _un_f64(x); r === nothing ? 7.0 : r), Int64(0)),
    ("char_nothing", (x::Int64) -> (r = _un_char(x); r === nothing ? Int64(7) : Int64(r)), Int64(1)),
    ("char_value", (x::Int64) -> (r = _un_char(x); r === nothing ? Int64(7) : Int64(r)), Int64(0)),
    ("missing_ret", (x::Int64) -> (r = _un_missing(x); r === missing ? 7 : r), Int64(1)),
    ("missing_ret_zero", (x::Int64) -> (r = _un_missing(x); r === missing ? 7 : r), Int64(0)),
    ("missing_field", (x::Int64) -> (s = _un_miss_field(x); ismissing(s.f) ? -1 : s.f::Int64), Int64(1)),
    ("missing_field_zero", (x::Int64) -> (s = _un_miss_field(x); ismissing(s.f) ? -1 : s.f::Int64), Int64(0)),
    ("isnothing", (x::Int64) -> Int64(isnothing(_un_i64(x))), Int64(1)),
    ("isnothing_zero", (x::Int64) -> Int64(isnothing(_un_i64(x))), Int64(0)),
    ("something_f64", (x::Int64) -> something(_un_f64(x), 7.5), Int64(1)),
    ("egal_zero", (x::Int64) -> Int64(_un_i64(x) === 0), Int64(1)),
    ("phi_loop_nothing", _un_phi_loop, Int64(1)),
    ("phi_loop_zero", _un_phi_loop, Int64(3)),
    ("phi_loop_bool_nothing", _un_phi_loop_bool, Int64(1)),
    ("phi_loop_bool", _un_phi_loop_bool, Int64(3)),
    ("phi_loop_f64_nothing", _un_phi_loop_f64, Int64(1)),
    ("phi_loop_f64", _un_phi_loop_f64, Int64(2)),
    ("typeof_nothing", _un_typeof, Int64(1)),
    ("typeof_zero", _un_typeof, Int64(0)),
    ("typeof_any_nothing", (x::Int64) -> Int64(typeof(_id_anyval(x)) === Nothing), Int64(-3)),
    ("split_call_nothing", _un_split, Int64(1)),
    ("split_call_zero", _un_split, Int64(0)),
    ("split_call_value", _un_split, Int64(-4)),
    ("split_call_bool_nothing", _un_split_bool, Int64(1)),
    ("split_call_bool", _un_split_bool, Int64(-4)),
    ("vec_bool", (x::Int64) -> (v = Union{Nothing,Bool}[x > 0 ? nothing : true, false, nothing];
        c = 0; for e in v; c = 10c + (e === nothing ? 9 : Int64(e)); end; c), Int64(1)),
    ("ref_cell", (x::Int64) -> (r = Ref{Union{Nothing,Int64}}(nothing); x <= 0 && (r[] = x);
        v = r[]; v === nothing ? -1 : v), Int64(0)),
    ("dict_value", (x::Int64) -> (d = Dict{Int64,Union{Nothing,Int64}}(1 => nothing, 0 => 0);
        v = d[x]; v === nothing ? -1 : v), Int64(1)),
])
# A tuple or NamedTuple with a Union{Nothing,T} element is an abstract type in Julia (its
# values are Tuple{Nothing,Int64} or Tuple{Int64,Int64}); WT gives it no class, and a
# closure capturing such a value is typed by a runtime `apply_type`. Each rejects at its
# statement: the `tuple` (its type is its elements' runtime types), `getproperty` on the
# NamedTuple ("getfield call shape not lowerable"), the capture ("unresolved dynamic call
# `Core.apply_type`").
@noinline _un_tup(x::Int64) = (x > 0 ? nothing : x, x)
@noinline _un_nt(x::Int64) = (a = x > 0 ? nothing : iseven(x), b = x)
_xf("union_nothing_containers", Any[
    ("tuple_element", (x::Int64) -> (t = _un_tup(x); t[1] === nothing ? -1 : t[1]::Int64), Int64(1)),
    ("namedtuple_field", (x::Int64) -> (t = _un_nt(x); t.a === nothing ? -1 : Int64(t.a::Bool)), Int64(1)),
    ("closure_capture", (x::Int64) -> (r = _un_i64(x); g = () -> r === nothing ? -1 : r::Int64; g()), Int64(1)),
])
# ---- Memory: fill, allocation length, storage identity (C6 suspects 12, 14, 15, 27) ----
_sm_enc(v) = (r = 0; for x in v; r = r * 10 + x; end; r)
_g("memory", Any[
    # memset with a runtime byte, and a zero memset over live data (Dict/Set empty!)
    ("fill_u8_runtime", (x::Int64) -> (v = zeros(UInt8, 5); fill!(v, UInt8(x)); Int64(sum(Int64, v)) * 1000 + Int64(v[3])), Int64(7)),
    ("fill_u8_wrapped", (x::Int64) -> (v = zeros(UInt8, 5); fill!(v, x % UInt8); Int64(sum(Int64, v))), Int64(0x1ff)),
    ("fill_i8_negative", (x::Int64) -> (v = zeros(Int8, 4); fill!(v, Int8(x)); Int64(sum(Int64, v)) * 1000 + Int64(v[2])), Int64(-3)),
    ("fill_constructor_u8", (x::Int64) -> Int64(sum(Int64, fill(UInt8(x), 5))), Int64(4)),
    ("fill_u8_zero_live", (x::Int64) -> (v = zeros(UInt8, 5); for i in 1:5; v[i] = UInt8(x + i); end; fill!(v, 0x00); Int64(sum(Int64, v))), Int64(7)),
    ("dict_empty_reuse", (x::Int64) -> (d = Dict{Int64,Int64}(x => 1, 2 => 3); empty!(d); d[5] = 9; Int64(haskey(d, x)) * 100 + length(d) * 10 + d[5]), Int64(7)),
    ("set_empty_reuse", (x::Int64) -> (s = Set{Int64}([x, 2]); empty!(s); push!(s, 3); Int64(x in s) * 10 + length(s)), Int64(7)),
    # Core.memorynew allocates exactly n elements and throws Base's ArgumentError for n < 0
    ("memory_new_len", (n::Int64) -> length(Memory{Int64}(undef, n)), Int64(4)),
    ("memory_new_fill", (n::Int64) -> (m = Memory{Int64}(undef, n); fill!(m, 3); length(m) * 100 + sum(m)), Int64(4)),
    ("memory_new_negative", (n::Int64) -> try; length(Memory{Int64}(undef, n)); catch e; e isa ArgumentError ? -1 : -2; end, Int64(-1)),
    ("growbeg_mem_length", (n::Int64) -> (v = collect(1:n); popfirst!(v); popfirst!(v); pushfirst!(v, 100); pushfirst!(v, 200); _sm_enc(v) + length(v.ref.mem) * 1_000_000_000), Int64(5)),
    # a Memory's ptr identifies its storage: distinct arrays never alias, overlapping views do
    ("mightalias_distinct", (n::Int64) -> (a = collect(1:n); b = collect(1:n); Int64(Base.mightalias(a, b))), Int64(3)),
    ("mightalias_view", (n::Int64) -> (a = collect(1:n); Int64(Base.mightalias(a, view(a, 1:2)))), Int64(3)),
    ("copyto_view_overlap", (n::Int64) -> (v = collect(1:n); copyto!(view(v, 2:n), view(v, 1:n-1)); _sm_enc(v)), Int64(5)),
    ("bcast_reverse_view", (n::Int64) -> (v = collect(1:n); v .= @view v[end:-1:1]; _sm_enc(v)), Int64(5)),
    ("pointer_eq_distinct", (n::Int64) -> (a = collect(1:n); b = collect(1:n); Int64(pointer(a) == pointer(b))), Int64(3)),
    ("pointer_eq_empty_memory", (n::Int64) -> (a = Memory{Int64}(undef, n); b = Memory{Int64}(undef, n); Int64(pointer(a) == pointer(b))), Int64(0)),
    ("mightalias_views_distinct", (n::Int64) -> (a = collect(1:n); b = collect(1:n); Int64(Base.mightalias(view(a, 1:2), view(b, 1:2)))), Int64(3)),
    ("copyto_views_distinct", (n::Int64) -> (a = collect(1:n); b = collect(10:10+n-1); copyto!(view(a, 2:n), view(b, 1:n-1)); _sm_enc(a)), Int64(5)),
    ("bcast_view_into_vector", (n::Int64) -> (a = collect(1:n); b = collect(1:n); a .= view(b, n:-1:1); _sm_enc(a)), Int64(4)),
])

# A struct field of MemoryRef type holds the ref's single-value struct {mem, off0}; reading the
# field unpacks it into the pair channel, so a ref stored at an element offset reads back the
# element and the offset Julia gives it (it used to reject: "not unpacked into the pair channel").
struct _SmMRHolder; r::MemoryRef{Int64}; end
@noinline _sm_mr_read(h::_SmMRHolder)::Int64 = h.r[] * 10 + Base.memoryrefoffset(h.r)
@noinline _sm_mr_value(h::_SmMRHolder)::Int64 = h.r[]
# A MemoryRef crossing a call — an argument or a result — is its single-value struct too
# (boundary_wasm_type): its element offset crosses with it (it rejected unless provably 0).
@noinline _sm_mr_arg(r::MemoryRef{Int64})::Int64 = r[] * 10 + Base.memoryrefoffset(r)
@noinline _sm_mr_next(r::MemoryRef{Int64})::MemoryRef{Int64} = memoryref(r, 2)
@noinline _sm_mr_same(r::MemoryRef{Int64})::MemoryRef{Int64} = r
_g("memoryref_field", Any[
    ("arg_at_offset", (n::Int64) -> (v = collect(1:n); _sm_mr_arg(memoryref(v.ref, 3))), Int64(5)),
    ("result_at_offset", (n::Int64) -> (v = collect(1:n); r = _sm_mr_next(memoryref(v.ref, 2)); r[] * 10 + Base.memoryrefoffset(r)), Int64(5)),
    ("result_is_argument", (n::Int64) -> (v = collect(1:n); r = _sm_mr_same(memoryref(v.ref, 4)); r[] * 10 + Base.memoryrefoffset(r)), Int64(5)),
    ("field_fresh", (n::Int64) -> (v = collect(10:10+n); _sm_mr_read(_SmMRHolder(v.ref))), Int64(3)),
    ("field_at_offset", (n::Int64) -> (v = collect(1:n); _sm_mr_read(_SmMRHolder(memoryref(v.ref, 3)))), Int64(5)),
    ("field_value_after_popfirst", (n::Int64) -> (v = collect(1:n); popfirst!(v); _sm_mr_value(_SmMRHolder(v.ref))), Int64(5)),
])
# Vector growth and deletion run Julia's own bodies — _growend!, _growbeg!, _growat!,
# _deletebeg! and their reallocating closures, which the collector enrolls as statically
# invoked closures — so the Vector's MemoryRef offset and its Memory's length are Julia's.
# The reallocating WASM_METHOD_TABLE overlays these replace put the ref back at offset 1
# (popfirst! twice: Julia 3, WT 1), and the name-keyed stand-in for _growbeg!'s closure
# answered wrong values (pushfirst!(v, 7, 8): 7816 vs 7836).
_g("vector_growth_offsets", Any[
    ("offset_after_popfirst", (n::Int64) -> (v = collect(1:n); popfirst!(v); popfirst!(v); Base.memoryrefoffset(v.ref)), Int64(5)),
    ("pushfirst_len_offset", (n::Int64) -> (v = collect(1:n); pushfirst!(v, 0); length(v) * 10 + Base.memoryrefoffset(v.ref)), Int64(5)),
    ("queue_push_popfirst", (n::Int64) -> (v = collect(1:n); s = 0; for i in 1:40; push!(v, i); s += popfirst!(v); end; (Base.memoryrefoffset(v.ref) * 100 + length(v.ref.mem)) * 1000 + s), Int64(5)),
    ("pushfirst_multi", (n::Int64) -> (v = collect(1:n); pushfirst!(v, 7, 8); v[1] * 1000 + v[2] * 100 + v[3] * 10 + length(v)), Int64(4)),
    ("splice_insert", (n::Int64) -> (v = collect(1:n); splice!(v, 2:1, [5, 6]); v[2] * 100 + v[3] * 10 + length(v)), Int64(4)),
    ("deque_mix", (n::Int64) -> (v = Int64[]; s = 0; for i in 1:n; pushfirst!(v, i); push!(v, -i); end; while !isempty(v); s = s * 3 + popfirst!(v); end; s), Int64(6)),
])
# The same Vectors observed through their elements, under Julia's own growth bodies. Native
# values are identical on 1.12 and 1.13. The last case is the freed slot Julia's `_deleteend!`
# nulls (`_unsetindex!`), which a later grow finds unassigned.
_g("memoryref_offset", Any[
    ("resize_grow_write", (n::Int64) -> (v = collect(1:n); resize!(v, 3n); v[3n] = 7; v[3n] + length(v)), Int64(5)),
    ("push_view_sum", (n::Int64) -> (v = Int64[]; for i in 1:n; push!(v, i); end; sum(view(v, 3:n))), Int64(12)),
    ("string_after_popfirst", (n::Int64) -> (v = UInt8[0x61, 0x62, 0x63, 0x64]; popfirst!(v); s = String(v); ncodeunits(s) * 1000 + Int64(codeunit(s, n))), Int64(1)),
    ("reshape_after_popfirst", (n::Int64) -> (v = collect(1:n); popfirst!(v); popfirst!(v); m = reshape(v, 2, 2); Int64(pointer(m) == pointer(v)) * 100 + m[2, 2]), Int64(6)),
    ("any_resize_isassigned", (n::Int64) -> (v = Any[1, 2, n]; resize!(v, 2); resize!(v, 3); Int64(isassigned(v, 3))), Int64(3)),
])
# The MemoryRef pair channel (builtins.jl): an indexed ref carries its element offset
# through a phi (loop-carried and branch), a chain of indexed refs, a store, and the bounds
# check memoryrefnew runs when `bc` is true — BoundsError's `i` is the relative index, and
# an unused check still runs.
_g("memoryref_pair", Any[
    ("loop_phi_offset", (n::Int64) -> (v = collect(1:10); r = v.ref; for k in 1:n; r = Core.memoryrefnew(r, 2, true); end; Core.memoryrefget(r, :not_atomic, true) * 100 + Base.memoryrefoffset(r)), Int64(3)),
    ("branch_phi_offset", (n::Int64) -> (v = collect(1:10); r = n > 3 ? Core.memoryrefnew(v.ref, 5, true) : Core.memoryrefnew(v.ref, 2, true); Core.memoryrefget(r, :not_atomic, true) * 100 + Base.memoryrefoffset(r)), Int64(4)),
    ("chained_get", (n::Int64) -> (v = collect(10:10:100); r = Core.memoryrefnew(Core.memoryrefnew(v.ref, 3, true), n, true); Core.memoryrefget(r, :not_atomic, true) * 100 + Base.memoryrefoffset(r)), Int64(4)),
    ("chained_set", (n::Int64) -> (v = collect(10:10:100); r = Core.memoryrefnew(Core.memoryrefnew(v.ref, 3, true), n, true); Core.memoryrefset!(r, 7, :not_atomic, true); v[n + 2]), Int64(4)),
    ("bc_throw_past_end", (n::Int64) -> (m = Memory{Int64}(undef, 3); r = Core.memoryrefnew(m); try; Core.memoryrefnew(r, n, true); 0; catch e; e isa BoundsError ? 1 : 2; end), Int64(5)),
    ("bc_throw_index_zero", (n::Int64) -> (m = Memory{Int64}(undef, 3); r = Core.memoryrefnew(m); try; Core.memoryrefnew(r, n, true); 0; catch e; e isa BoundsError ? (e.i::Int) : -1; end), Int64(0)),
    ("bc_throw_chained", (n::Int64) -> (v = collect(1:10); try; Core.memoryrefnew(Core.memoryrefnew(v.ref, 3, true), n, true); 0; catch e; e isa BoundsError ? (e.i::Int) : -1; end), Int64(9)),
    ("bc_unused_check", (n::Int64) -> (v = collect(1:10); try; Core.memoryrefnew(v.ref, n, true); 0; catch e; e isa BoundsError ? 1 : -1; end), Int64(11)),
])
# A MemoryRef is a snapshot: a ref taken before its Array is grown, resized or given a new
# :ref still reads the old Memory at its old offset; two MemoryRef phis swapping on one edge
# read each other's old values. A MemoryRef in a slot that holds any value (BoundsError's
# `a`, a Vector{Any} element) is classed MemoryRef{T}.
_g("memoryref_snapshot", Any[
    ("ref_snapshot_push", (n::Int64) -> (v = collect(1:3); r = v.ref; for k in 1:n; push!(v, k); end; v[1] = 99; Core.memoryrefget(r, :not_atomic, true)), Int64(10)),
    ("indexed_snapshot_resize", (n::Int64) -> (v = collect(1:3); r = Core.memoryrefnew(v.ref, 2, true); resize!(v, n); v[2] = 77; Core.memoryrefget(r, :not_atomic, true)), Int64(100)),
    ("indexed_snapshot_setfield", (n::Int64) -> (v = collect(1:5); r = Core.memoryrefnew(v.ref, n, true); w = collect(10:10:50); setfield!(v, :ref, w.ref); Core.memoryrefget(r, :not_atomic, true) * 100 + Base.memoryrefoffset(r)), Int64(2)),
    ("phi_swap_offsets", (n::Int64) -> (v = collect(1:20); r = v.ref; s = Core.memoryrefnew(v.ref, 5, true); for k in 1:n; r, s = s, Core.memoryrefnew(r, 2, true); end; Core.memoryrefget(r, :not_atomic, true) * 100 + Core.memoryrefget(s, :not_atomic, true)), Int64(3)),
    ("bc_payload_isa", (n::Int64) -> (m = Memory{Int64}(undef, 3); r = Core.memoryrefnew(Core.memoryrefnew(m), 2, true); try; Core.memoryrefnew(r, n, true); 0; catch e; a = (e::BoundsError).a; (a isa MemoryRef{Int64} ? 10 : 0) + (typeof(a) === MemoryRef{Int64} ? 1 : 0); end), Int64(5)),
    ("bc_payload_zero_isa", (n::Int64) -> (m = Memory{Int64}(undef, 3); r = Core.memoryrefnew(m); try; Core.memoryrefnew(r, n, true); 0; catch e; a = (e::BoundsError).a; (a isa MemoryRef{Int64} ? 10 : 0) + (typeof(a) === MemoryRef{Int64} ? 1 : 0); end), Int64(5)),
    ("any_slot_isa", (n::Int64) -> (v = collect(1:n); x = Any[v.ref, 1]; (x[1] isa MemoryRef{Int64} ? 1 : 0) + (x[2] isa MemoryRef{Int64} ? 10 : 0)), Int64(3)),
])
# Reading a MemoryRef back out of a slot that holds any value needs its single-value struct
# unpacked into the pair channel; until then it rejects, located (native 1).
_xf("memoryref_unbox", Any[
    ("any_slot_unbox", (n::Int64) -> (v = collect(1:n); x = Any[v.ref, 1]; Core.memoryrefget(x[1]::MemoryRef{Int64}, :not_atomic, true)), Int64(3)),
])
# An Array keeps its :ref's element offset (the Array struct's off0 field): Julia's own
# `_deletebeg!` (not an overlay) and `Base.wrap` store an offset ref, and every reader —
# indexing, reshape, push!, copy, splatting, `take!` — honours it.
# A self-referential struct's Vector field registers with its recursion group through the one
# Vector layout builder, which carries the offset field.
mutable struct _SmMRRec
    value::Int64
    children::Vector{_SmMRRec}
end
_g("memoryref_array_offset", Any[
    ("recursive_vector_field", (n::Int64) -> (r = _SmMRRec(n, _SmMRRec[]); push!(r.children, _SmMRRec(n + 1, _SmMRRec[])); r.value * 10 + length(r.children) + r.children[1].value * 100), Int64(4)),
    ("wrap_offset", (n::Int64) -> (m = Memory{Int64}(undef, 10); for i in 1:10; m[i] = i * 10; end; v = Base.wrap(Array, memoryref(m, n), 3); v[1] + v[3] * 1000 + Base.memoryrefoffset(v.ref) * 1000000), Int64(4)),
    ("wrap_offset_matrix", (n::Int64) -> (m = Memory{Int64}(undef, 10); for i in 1:10; m[i] = i; end; a = Base.wrap(Array, memoryref(m, n), (2, 3)); a[2, 3] * 100 + Base.memoryrefoffset(a.ref)), Int64(3)),
    ("setfield_ref_offset", (n::Int64) -> (v = collect(1:10); setfield!(v, :ref, Core.memoryrefnew(v.ref, n, true)); setfield!(v, :size, (10 - n + 1,)); v[1] * 100 + length(v) + sum(v)), Int64(3)),
    ("deletebeg_offset", (n::Int64) -> (v = collect(1:n); Base._deletebeg!(v, 2); v[1] * 100 + Base.memoryrefoffset(v.ref)), Int64(5)),
    ("deletebeg_reshape", (n::Int64) -> (v = collect(1:n); Base._deletebeg!(v, 2); m = reshape(v, 2, 2); m[2, 2] * 100 + Base.memoryrefoffset(m.ref)), Int64(6)),
    ("deletebeg_sum_push", (n::Int64) -> (v = collect(1:n); Base._deletebeg!(v, 2); push!(v, 100); sum(v) * 100 + length(v)), Int64(5)),
    ("deletebeg_copy", (n::Int64) -> (v = collect(1:n); Base._deletebeg!(v, 2); w = copy(v); w[1] * 100 + Base.memoryrefoffset(w.ref)), Int64(5)),
    ("deletebeg_vect_prefix", (n::Int64) -> (v = collect(1:n); Base._deletebeg!(v, 2); w = [0, v...]; sum(w) * 100 + length(w)), Int64(5)),
    ("deletebeg_vect_copy", (n::Int64) -> (v = collect(1:n); Base._deletebeg!(v, 2); w = Base.vect(v...)::Vector{Int64}; w[1] * 100 + length(w)), Int64(5)),
    ("deletebeg_splat_sum", (n::Int64) -> (v = collect(1:n); Base._deletebeg!(v, 2); +(v...)), Int64(5)),
    ("iobuffer_grow_take", (n::Int64) -> (io = IOBuffer(); for i in 1:n; write(io, UInt8(i % 256)); end; b = take!(io); length(b) * 1000 + Int64(b[end])), Int64(2000)),
])
# Julia's own collection bodies, compiled instead of bespoke overlays (dev/CHARTER.md C3), at
# the inputs where a re-implementation drifts: signed zeros, NaN, ties, negative integers, an
# empty generator's element type.
# a constant whose contents are values too: the classes of the function singletons inside
# a Dict constant are numbered before its snapshot is built
const _SM_FNDICT = Dict(1 => isodd, 2 => iseven)
struct _SmPair; a::Float64; b::Float64; end
struct _SmTrip; a::Float64; b::Float64; c::Float64; end   # a 24-byte stride
_g("julia_collection_bodies", Any[
    ("constant_dict_of_functions", (n::Int64) -> length(_SM_FNDICT) * 10 + (haskey(_SM_FNDICT, n) ? 1 : 0), Int64(2)),
    # Julia's copy of an isbits-struct vector is a memmove of its inline storage
    ("copy_isbits_struct_vector", (n::Int64) -> (v = [_SmPair(1.0, 2.0), _SmPair(3.0, n)]; w = copy(v); w[2].b * 10 + w[1].a + length(w)), Int64(4)),
    ("copy_isbits_struct_stride24", (n::Int64) -> (v = [_SmTrip(1.0, 2.0, 3.0), _SmTrip(4.0, 5.0, n), _SmTrip(7.0, 8.0, 9.0)]; w = copy(v); w[2].c * 100 + w[3].a * 10 + length(w)), Int64(6)),
    ("splice_index", (n::Int64) -> (v = collect(1:n); x = splice!(v, 2); x * 100 + length(v)), Int64(5)),
    ("unique_int", (n::Int64) -> (u = unique([3, 1, 3, n, 1]); sum(u) * 10 + length(u)), Int64(7)),
    ("unique_f64_zero_nan", (n::Int64) -> (u = unique([0.0, -0.0, NaN, NaN, Float64(n)]); length(u) * 10 + (signbit(u[2]) ? 1 : 0)), Int64(2)),
    ("unique_f32_zero_nan", (n::Int64) -> (u = unique(Float32[0.0, -0.0, NaN, NaN, n]); length(u) * 10 + (signbit(u[2]) ? 1 : 0)), Int64(2)),
    ("unique_string", (n::Int64) -> length(unique(["a", "b", "a", string(n)])), Int64(3)),
    ("copy_vector", (n::Int64) -> (v = collect(1:n); w = copy(v); w[1] = 99; v[1] * 1000 + w[1] + length(w)), Int64(4)),
    ("copy_matrix", (n::Int64) -> (m = reshape(collect(1.0:6.0), 2, 3); c = copy(m); c[2, 3] * 10 + m[1, 2] + n), Int64(3)),
    ("copyto_matrix", (n::Int64) -> (d = zeros(2, 2); copyto!(d, [1.0 2.0; 3.0 Float64(n)]); d[2, 2] * 10 + d[1, 2]), Int64(5)),
    ("matrix_add", (n::Int64) -> (c = [1.0 2.0; 3.0 4.0] + fill(Float64(n), 2, 2); c[2, 1] * 10 + c[1, 2]), Int64(2)),
    ("filter_odd", (n::Int64) -> (f = filter(isodd, collect(1:n)); sum(f) * 100 + length(f)), Int64(9)),
    ("generator_collect", (n::Int64) -> sum([x * 0.5 for x in 1:n]), Int64(9)),
    ("generator_empty_eltype", (n::Int64) -> (eltype([x * 0.5 for x in 1:n]) === Float64 ? 1 : 0), Int64(0)),
    ("dict_delete", (n::Int64) -> (d = Dict(1 => 2, 3 => 4, n => 6); delete!(d, 3); length(d) * 100 + get(d, 3, 0) * 10 + get(d, n, 0)), Int64(8)),
    ("count_even", (n::Int64) -> count(iseven, collect(1:n)), Int64(9)),
    ("maximum_signed_zero", (n::Int64) -> (signbit(maximum([-0.0, 0.0, -Float64(n)])) ? 1 : 0), Int64(1)),
    ("minimum_signed_zero", (n::Int64) -> (signbit(minimum([0.0, -0.0, Float64(n)])) ? 1 : 0), Int64(1)),
    ("maximum_negative_ints", (n::Int64) -> maximum([-3, -1, -n]) * 10 + minimum([-3, -1, -n]), Int64(5)),
    ("maximum_nan", (n::Int64) -> (isnan(maximum([1.0, NaN, Float64(n)])) ? 1 : 0), Int64(2)),
    ("argmax_ties", (n::Int64) -> argmax([1, n, 3, n]) * 10 + argmin([n, 1, 1, n]), Int64(5)),
    ("argmin_nan", (n::Int64) -> argmin([2.0, NaN, -Float64(n)]) * 10 + argmax([2.0, NaN, Float64(n)]), Int64(3)),
    ("foreach_sum", (n::Int64) -> (s = Ref(0); foreach(x -> (s[] += x), collect(1:n)); s[]), Int64(6)),
    ("repeat_string", (n::Int64) -> length(repeat("ab", n)) * 100 + ncodeunits(repeat('é', n)), Int64(3)),
    ("string_int", (n::Int64) -> length(string(-n * 1000)) * 100 + length(string(typemin(Int64))), Int64(7)),
    ("first_last", (n::Int64) -> (v = collect(10:10+n); first(v) * 100 + last(v)), Int64(4)),
    ("union_set", (n::Int64) -> (s = Set([1, 2]); union!(s, [2, 3, n]); length(s)), Int64(9)),
    ("collect_vector", (n::Int64) -> (w = collect(collect(1:n)); w[end] * 10 + length(w)), Int64(5)),
    # isequal of two floats is Julia's fpiseq: bits equal, or both NaN
    ("isequal_f64", (n::Int64) -> (isequal(0.0, -0.0) ? 1 : 0) + (isequal(NaN, -NaN) ? 10 : 0) + (isequal(Float64(n), Float64(n)) ? 100 : 0), Int64(3)),
    ("isequal_f32", (n::Int64) -> (isequal(0.0f0, -0.0f0) ? 1 : 0) + (isequal(NaN32, -NaN32) ? 10 : 0) + (isequal(Float32(n), Float32(n)) ? 100 : 0), Int64(3)),
    ("set_f64", (n::Int64) -> length(Set([0.0, -0.0, NaN, NaN, Float64(n)])), Int64(2)),
    ("lpad_rpad", (n::Int64) -> ncodeunits(lpad(string(n), 6, "ab")) * 100 + ncodeunits(rpad("x", n, 'é')), Int64(4)),
    ("lpad_negative_int", (n::Int64) -> length(lpad(-n * 7, 5)) + (lpad(-n, 4)[1] == ' ' ? 10 : 0), Int64(3)),
])
# Julia's own string and ordering bodies (dev/CHARTER.md C3), at the inputs a re-implementation
# drifts on: multibyte characters, empty pieces, limits, kwargs, stability, signed zeros.
# the bytes of a String, packed with its length: any byte out of place changes the value
_sm_pack(u::String)::Int64 = (x = Int64(0); for c in codeunits(u); x = x * 256 + Int64(c); end; x * 16 + ncodeunits(u))
function _sm_sub_bytes(n::Int64)::Int64
    s = SubString("hello world", n, n + 4)
    bytes = UInt8[]
    for i in 1:ncodeunits(s)
        push!(bytes, codeunit(s, i))
    end
    t = String(bytes)
    return Int64(sum(codeunits(t))) * 100 + ncodeunits(t)
end
_g("julia_string_bodies", Any[
    # a SubString's code units, read in a loop into a fresh String, and Julia's own
    # uppercase/lowercase of a SubString (once noted as reading zeros)
    ("substring_codeunit_loop", _sm_sub_bytes, Int64(2)),
    # String(::SubString{String}) copies from the parent's pointer (unsafe_string(pointer(parent,
    # offset + 1), n)); a String pointer's value is 1 + its byte offset, which the copy once read
    # as the offset itself, answering "de" for "cd"
    ("substring_to_string", (n::Int64) -> _sm_pack(string(SubString("cde", 1, n))), Int64(2)),
    ("substring_string_interpolated", (n::Int64) -> _sm_pack(string(SubString("cdef", 2, n + 1), 7)), Int64(2)),
    # titlecase is Julia's rule (words split at non-letters, Unicode casing) over utf8proc's
    # grapheme breaks; an ASCII stand-in answered "Hello-world" and "élan"
    ("titlecase_dash", (n::Int64) -> Int64(codepoint(titlecase("hello-world" * string(n))[7])), Int64(2)),
    ("titlecase_accent", (n::Int64) -> Int64(codepoint(first(titlecase("élan vital" * string(n))))), Int64(2)),
    ("titlecase_combining", (n::Int64) -> (t = titlecase("e\u0301cole ÉLAN" * string(n)); Int64(codepoint(t[1])) * 1000 + Int64(codepoint(t[end-1]))), Int64(2)),
    ("grapheme_count", (n::Int64) -> length(Base.Unicode.graphemes("e\u0301a🇺🇸x" * string(n))), Int64(2)),
    ("grapheme_break_stateful", (x::Int64) -> Base.Unicode.isgraphemebreak!(Ref{Int32}(0), 'a', Char(x)) ? 1 : 0, Int64(98)),
    ("uppercase_substring", (n::Int64) -> (u = uppercase(SubString("hello world", n, n + 4)); Int64(sum(codeunits(u))) * 100 + ncodeunits(u)), Int64(2)),
    ("lowercase_substring", (n::Int64) -> (u = lowercase(SubString("HELLO WORLD", n, n + 4)); Int64(sum(codeunits(u))) * 100 + ncodeunits(u)), Int64(2)),
    ("reverse_unicode", (n::Int64) -> ncodeunits(reverse("aé" * string(n) * "∀")) * 10 + Int64(codepoint(first(reverse("xé")))), Int64(3)),
    ("titlecase_words", (n::Int64) -> Int64(codepoint(titlecase("hello wörld " * string(n))[7])), Int64(2)),
    ("replace_pair", (n::Int64) -> ncodeunits(replace("abcabc" * string(n), "b" => "xyz")), Int64(4)),
    ("split_keepempty", (n::Int64) -> length(split("a,,b," * string(n), ",")) * 10 + length(split("a,,b", ","; keepempty=false)), Int64(5)),
    ("split_limit", (n::Int64) -> length(split("a b c d", " "; limit=n)), Int64(2)),
    ("join_delim", (n::Int64) -> ncodeunits(join(["ab", "c", string(n)], ", ")) * 10 + ncodeunits(join(["x", "yz"])), Int64(7)),
    ("join_ints", (n::Int64) -> ncodeunits(join([1, n, -3], "-")), Int64(12)),
    ("repr_vector", (n::Int64) -> ncodeunits(repr([1, n, 3])), Int64(20)),
    ("string_nothing", (n::Int64) -> ncodeunits(string(nothing)) + n, Int64(1)),
    ("strvec_range", (n::Int64) -> (v = ["a", "bb", "ccc", "d"]; w = v[2:n]; length(w) * 10 + ncodeunits(w[end])), Int64(3)),
    ("string_substring", (n::Int64) -> (s = "hello, world"; ncodeunits(String(SubString(s, 1, n)))), Int64(5)),
    ("concat_mixed", (n::Int64) -> ncodeunits("a" * string(n) * 'é' * SubString("xyz", 2)), Int64(4)),
    ("string_of_type", (n::Int64) -> ncodeunits(string(n > 0 ? Vector{Int64} : Dict{String,Int64})), Int64(1)),
    ("byte_in_codeunits", (n::Int64) -> (UInt8(n) in codeunits("abc") ? 1 : 0) + (Int8(98) in Int8[97, 98] ? 10 : 0), Int64(99)),
    ("dict_from_tuple", (n::Int64) -> (d = Dict((1 => 2, n => 4)); length(d) * 10 + d[n]), Int64(3)),
    ("sort_by_rev", (n::Int64) -> (v = sort([3, -1, n, 2]; by=abs, rev=true); v[1] * 10 + v[end]), Int64(5)),
    ("sort_signed_zero", (n::Int64) -> (v = sort([0.0, -0.0, Float64(n), -1.0]); (signbit(v[2]) ? 1 : 0) + (signbit(v[3]) ? 10 : 0)), Int64(2)),
    ("sortperm_rev", (n::Int64) -> (p = sortperm([3, 1, n, 2]; rev=true); p[1] * 10 + p[end]), Int64(4)),
    ("partialsort_k", (n::Int64) -> partialsort([5, 3, n, 1, 4], 2), Int64(2)),
    # ScratchQuickSort's scratch copy of a tuple vector is a memmove of isbits-struct storage
    ("sort_stable_lt", (n::Int64) -> (v = sort([(2, 1), (1, 2), (2, 3), (1, n)]; lt=(a, b) -> a[1] < b[1]); v[2][2] * 10 + v[4][2]), Int64(4)),
    # two String literals compared in a function no String type names (the scratch locals
    # are allocated at the comparison)
    ("string_literal_eq", (n::Int64) -> (repeat("hello", 1) == "hello" ? 1 : 0) + n, Int64(2)),
])
# Julia's own printing bodies (dev/CHARTER.md C3). A string compares by a positional digest of
# its code units, so every byte and its place counts.
_sm_digest(s::AbstractString)::Int64 = (d = Int64(0); for (i, c) in enumerate(codeunits(s)); d += Int64(c) * i; end; d * 1000 + ncodeunits(s))
_g("julia_print_bodies", Any[
    ("concat2", (n::Int64) -> _sm_digest("ab" * string(n)), Int64(7)),
    ("concat3", (n::Int64) -> _sm_digest("ab" * "c" * string(n)), Int64(7)),
    ("interp_mixed", (n::Int64) -> _sm_digest("x=$(n) y=$(n * 0.5) z=$(n > 0)"), Int64(3)),
    ("string_float", (n::Int64) -> _sm_digest(string(0.1 + 0.2 * n)) + _sm_digest(string(-0.0)) + _sm_digest(string(1.0e-7 * n)), Int64(1)),
    ("string_float32", (n::Int64) -> _sm_digest(string(Float32(0.1) * n)), Int64(3)),
    ("string_complex", (n::Int64) -> _sm_digest(string(1.0 + n * 1.0im)), Int64(2)),
    ("string_vec_int", (n::Int64) -> _sm_digest(string([1, n, -3])), Int64(5)),
    ("string_vec_float", (n::Int64) -> _sm_digest(string([1.5, n * 0.25])), Int64(3)),
    ("string_vec_string", (n::Int64) -> _sm_digest(string(["a", string(n)])), Int64(4)),
    ("ryu_writefixed", (n::Int64) -> _sm_digest(Base.Ryu.writefixed(1.23456 * n, 2)), Int64(3)),
    ("ryu_writeexp", (n::Int64) -> _sm_digest(Base.Ryu.writeexp(1.23456e10 * n, 3)), Int64(3)),
    ("ryu_writeshortest", (n::Int64) -> _sm_digest(Base.Ryu.writeshortest(0.3 * n)), Int64(3)),
    ("hvcat_tuples", (n::Int64) -> (m = [(1, 2) (3, n); (5, 6) (7, 8)]; m[1, 2][2] * 100 + m[2, 1][1] * 10 + size(m, 2)), Int64(4)),
])
# Types whose fields reach back to themselves register with their strongly connected component
# (finish_pending!, dev/formal/RecGroup.tla): a two-type cycle through a type parameter, a
# three-type cycle, a cycle through a tuple and through an abstract field — each field keeps its
# exact type (placeholder-and-patch erased one field of a two-type cycle to structref).
mutable struct _SmRA{T}; b::Union{Nothing,T}; x::Int64; end
mutable struct _SmRB; a::_SmRA{_SmRB}; y::Int64; end
mutable struct _SmR3A{T}; next::Union{Nothing,T}; v::Int64; end
mutable struct _SmR3B{T}; next::Union{Nothing,T}; v::Int64; end
mutable struct _SmR3C; next::_SmR3A{_SmR3B{_SmR3C}}; v::Int64; end
mutable struct _SmRT; t::Union{Nothing,Tuple{_SmRT,Int64}}; v::Int64; end
abstract type _SmRAbs end
mutable struct _SmRN1 <: _SmRAbs; next::Union{Nothing,_SmRAbs}; v::Int64; end
mutable struct _SmRN2 <: _SmRAbs; other::_SmRN1; w::Int64; end
function _sm_rec3(n::Int64)::Int64
    c = _SmR3C(_SmR3A{_SmR3B{_SmR3C}}(nothing, n), 1)
    b = _SmR3B{_SmR3C}(c, n + 1)
    c.next.next = b
    return c.next.next.next.v * 100 + c.next.v * 10 + b.v
end
_g("recursive_types", Any[
    ("mutual_pair", (n::Int64) -> (a = _SmRA{_SmRB}(nothing, n); b = _SmRB(a, n + 1); a.b = b; a.b.a.x * 10 + a.b.y), Int64(5)),
    ("three_cycle", _sm_rec3, Int64(4)),
    ("tuple_cycle", (n::Int64) -> (l = _SmRT(nothing, n); r = _SmRT((l, 2n), 1); t = r.t::Tuple{_SmRT,Int64}; r.v + t[1].v * 10 + t[2] * 100), Int64(3)),
    ("abstract_cycle", (n::Int64) -> (a = _SmRN1(nothing, n); b = _SmRN2(a, 3); a.next = b; (a.next::_SmRN2).other.v * 10 + (a.next::_SmRN2).w), Int64(7)),
    ("vector_tree", (n::Int64) -> (t = _SmMRRec(1, [_SmMRRec(n, _SmMRRec[]), _SmMRRec(2n, _SmMRRec[])]); s = t.value; for k in t.children; s += k.value; end; s), Int64(4)),
])
# A constant is interned by `===` (dev/formal/Constants.tla SharedOnlyIfEgal): `(1,)` and
# `(0x01,)` are `isequal` but two constants of two types, and a map keyed by `isequal` gave the
# `Tuple{UInt8}` site the `Tuple{Int64}` global (Random's hash_seed trapped on the cast);
# `(true,)` and `(0x01,)` share a layout, so the same conflation passed the cast and carried
# the wrong type; `1.0` and `1`, `0.0` and `-0.0` likewise.
@noinline _sm_ce_push(v::Vector{Any}, t) = (push!(v, t); length(v))
function _sm_ce_tuples(n::Int64)::Int64
    v = Any[]
    _sm_ce_push(v, (1,))
    n < 0 && _sm_ce_push(v, (0x01,))
    _sm_ce_push(v, (true,))
    _sm_ce_push(v, (0x01,))
    s = 0
    for x in v
        s = s * 10 + (x isa Tuple{Int64} ? 1 : x isa Tuple{UInt8} ? 2 : x isa Tuple{Bool} ? 3 : 9)
    end
    return s
end
function _sm_ce_floats(n::Int64)::Int64
    v = Any[]
    _sm_ce_push(v, (1,))
    _sm_ce_push(v, (1.0,))
    _sm_ce_push(v, (0.0,))
    _sm_ce_push(v, (-0.0,))
    s = 0
    for x in v
        s = s * 10 + (x isa Tuple{Int64} ? 1 : x isa Tuple{Float64} ? (signbit(x[1]) ? 3 : 2) : 9)
    end
    return s + n
end
_g("constant_identity", Any[
    ("tuple_int_byte", _sm_ce_tuples, Int64(-1)),
    ("tuple_int_byte_pos", _sm_ce_tuples, Int64(1)),
    ("tuple_int_float_zero", _sm_ce_floats, Int64(0)),
])
# A concrete struct is laid out by its fields whatever it subtypes (dev/MARCH.md 13.4): a
# Diagonal, a Symmetric, a UnitRange and a Complex are ordinary structs; only the types with a
# dedicated representation (Array, Memory, MemoryRef, String, Symbol, Tuple, CodeUnits) are
# not. Until 13.4 an AbstractArray other than a Vector took the Matrix layout
# ([:ref, :size]) at whichever route registered it first, so `D.diag` was not lowerable, and a
# Number struct was an erased structref in locals. A constructor call never becomes a bare
# struct.new that skips a normalizing body (UnitRange's last, a user constructor's abs).
@noinline _sm_sb_dg(D::Diagonal{Float64,Vector{Float64}})::Float64 = D.diag[end]
@noinline _sm_sb_sd(S::Symmetric{Float64,Matrix{Float64}})::Float64 = S.data[1, 2] + (S.uplo == 'U' ? 100.0 : 0.0)
@noinline _sm_sb_cx(n::Int64)::ComplexF64 = ifelse(n > 0, ComplexF64(1, 2), ComplexF64(3, 4))
@noinline _sm_sb_ceq(a::ComplexF64, b::ComplexF64)::Bool = a === b
struct _SmSbNorm
    x::Int64
    _SmSbNorm(x::Int64) = new(abs(x))
end
@noinline _sm_sb_norm(n::Int64)::_SmSbNorm = _SmSbNorm(n)
_g("struct_by_structure", Any[
    ("diagonal_field", (n::Int64) -> _sm_sb_dg(Diagonal([1.0, 2.0, Float64(n)])) * 10, Int64(3)),
    ("symmetric_fields", (n::Int64) -> _sm_sb_sd(Symmetric([1.0 Float64(n); 5.0 4.0])), Int64(7)),
    ("matrix_of_diagonal", (n::Int64) -> (M = Matrix(Diagonal([1.0, Float64(n)])); M[2, 2] * 10 + M[1, 2] + M[1, 1]), Int64(4)),
    ("diagonal_size_then_field", (n::Int64) -> (D = Diagonal([1.0, Float64(n)]); size(D, 1) * 100 + Int(_sm_sb_dg(D))), Int64(6)),
    ("complex_ifelse", (n::Int64) -> (z = _sm_sb_cx(n); Int(real(z)) * 10 + Int(imag(z))), Int64(-1)),
    ("complex_egal", (n::Int64) -> Int(_sm_sb_ceq(ComplexF64(n, 1), ComplexF64(2, 1))) * 10 + Int(_sm_sb_ceq(ComplexF64(n, 1), ComplexF64(n, 1))), Int64(3)),
    ("vector_complex", (n::Int64) -> (v = [ComplexF64(i, -2i) for i in 1:n]; s = sum(v); Int(real(s)) * 100 - Int(imag(s))), Int64(4)),
    ("unitrange_capture", (n::Int64) -> (r = 2:n; f = () -> sum(r) + length(r); f()), Int64(5)),
    ("diagonal_capture", (n::Int64) -> (D = Diagonal([1.0, Float64(n)]); f = () -> D.diag[2]; Int(f())), Int64(9)),
    ("unitrange_normalizes", (n::Int64) -> length(UnitRange{Int64}(5, n)) * 10 + last(UnitRange{Int64}(5, n)), Int64(2)),
    ("constructor_normalizes", (n::Int64) -> _sm_sb_norm(n).x, Int64(-3)),
])
# The storage algebra (dev/formal/StorageRef.tla): a MemoryRef's ptr_or_offset counts in
# Julia's stride — an element index for an isbits-union element, the inline struct's size
# for an inline element — so Base's own pointer arithmetic lands on the same slot; an
# unsafe_copyto! between offset refs; `atomic_pointerset(p, C_NULL)` unsets a reference
# slot (Julia's `_unsetindex!`); a reshape shares its Vector's Memory. Then a const Vector
# global is one object at every read (`===`, and a mutation seen by the next read), and
# `sizeof`/`Core.sizeof` of a Vector.
function _sm_ptr_stride(v, n::Int64, elsz::Int64)::Int64
    GC.@preserve v begin
        a = Base.unsafe_convert(Ptr{Nothing}, memoryref(v.ref, n))
        b = Base.unsafe_convert(Ptr{Nothing}, memoryref(v.ref, 1))
        return Int64(a == b + (n - 1) * elsz)
    end
end
const _SM_CONST_VEC = [1, 2]
# Core.sizeof is Julia's answer (jl_f_sizeof): a String's bytes; a Memory's length × its element
# size, plus a selector byte per element for an isbits union. The lowering once cast every
# AbstractVector or Any operand to the String byte array: a Memory{Int64} trapped at the cast
# where Julia answers 24.
# Julia's reflection over a runtime type's TypeName — check_world_bounded, isvisible,
# isdefinedglobal, isdeprecated, isconst — answered from the closed world's TypeName metadata. The
# two types live in different modules, so the module stays the TypeName's own field (a type pair
# from one module folds it to a constant, and the lowerings decline); the second argument is the
# spelling show_function uses (name, or singletonname).
_sm_rt_type(x::Int64) = x > 0 ? Int64 : Float64
_sm_rt_type2(x::Int64) = x > 0 ? Int64 : Base.RefValue{Int64}
_g("closed_world_reflection", Any[
    ("check_world_bounded_runtime", (x::Int64) -> (r = Base.check_world_bounded(_sm_rt_type(x).name); r === nothing ? -1 : Int64(first(r) >= 0)), Int64(1)),
    ("isvisible_runtime", (x::Int64) -> (tn = _sm_rt_type2(x).name; Int64(Base.isvisible(tn.name, tn.module, Main))), Int64(1)),
    ("isvisible_runtime_not", (x::Int64) -> (tn = _sm_rt_type2(x).name; Int64(Base.isvisible(tn.name, tn.module, Main))), Int64(-1)),
    ("isdefinedglobal_runtime", (x::Int64) -> (tn = _sm_rt_type2(x).name; Int64(isdefinedglobal(tn.module, tn.singletonname))), Int64(-1)),
    ("isdeprecated_runtime", (x::Int64) -> (tn = _sm_rt_type2(x).name; Int64(Base.isdeprecated(tn.module, tn.name))), Int64(1)),
    ("isconst_runtime", (x::Int64) -> (tn = _sm_rt_type2(x).name; Int64(isconst(tn.module, tn.singletonname))), Int64(-1)),
])
# invoke_in_world(world, f, args...) calls f(args...): the closed world has one world, so the
# collector's edge is that call's dispatch, with each operand typed as the call site types it.
# Until 2026-09-29 an argument operand went untyped and no edge was added ("unresolved dynamic
# call Main.abs (Int64,)").
_g("invoke_in_world", Any[
    ("argument_operand", (x::Int64) -> Base.invoke_in_world(Base.tls_world_age(), abs, x)::Int64, Int64(-3)),
    ("ssa_operand", (x::Int64) -> Base.invoke_in_world(Base.tls_world_age(), +, x * 2, 1)::Int64, Int64(4)),
    ("float_result", (x::Int64) -> Base.invoke_in_world(Base.tls_world_age(), sqrt, Float64(x))::Float64 > 2.0 ? 1 : 0, Int64(5)),
    # a callee returning `nothing` pushes no value: what is below it on the stack is not its
    # result (dev/AUDIT.md E7)
    ("nothing_result", (x::Int64) -> (r = Ref(x); y = x * 3 + (Base.invoke_in_world(Base.tls_world_age(), _sm_iiw_set!, r, x + 1); r[]); y), Int64(4)),
    # a call no one method covers is the dynamic call it makes, f(args...), as Julia's run-time
    # invoke_in_world dispatches it: two methods over an erased argument, and one method that does
    # not cover it (dev/AUDIT.md P3: no edge and no dynamic site, rejected; native 21 and 34)
    ("two_methods_erased", (x::Int64) -> (v = Any[x, "ab"]; w = Base.tls_world_age(); Base.invoke_in_world(w, _sm_iiw2, v[1])::Int64 + 10 * Base.invoke_in_world(w, _sm_iiw2, v[2])::Int64), Int64(3)),
    ("one_method_not_covering", (x::Int64) -> (v = Any[x, Int32(2)]; w = Base.tls_world_age(); Base.invoke_in_world(w, _sm_iiw3, v[1])::Int64 + 10 * Base.invoke_in_world(w, _sm_iiw3, v[2])::Int64), Int64(3)),
])
# Julia's exception stack (dev/formal/ExceptionStack.tla): a throw pushes its exception, an
# enter records the depth and its pop_exception restores it, `catch e` reads the top, rethrow()
# throws the top again and rethrow(e) overwrites it, and either at depth 0 throws Julia's
# ErrorException (dev/AUDIT.md A2E1–A2E3, A3E1, A3E2).
@noinline function _sm_xs_nested_rethrow(x::Int64)::Int64
    try; throw(ArgumentError("outer")); catch
        try; x > 0 && throw(DomainError(x)); catch; end
        rethrow()
    end
    return 0
end
@noinline _sm_xs_rethrow_other(x::Int64)::Int64 =
    (try; error("orig"); catch; rethrow(ArgumentError("replaced")); end; Int64(0))
_sm_xs_kind(e)::Int64 = e isa ArgumentError ? 1 : e isa DomainError ? 2 :
    e isa ErrorException ? _sm_xs_msg((e::ErrorException).msg::String) : 3
_sm_xs_msg(m::String)::Int64 = m == "rethrow() not allowed outside a catch block" ? 4 :
    m == "rethrow(exc) not allowed outside a catch block" ? 5 : 6
@noinline function _sm_xs_other_nested(x::Int64)::Int64
    try; throw(ArgumentError("outer")); catch
        try; x > 0 && rethrow(DomainError(x)); catch; end
        rethrow()
    end
    return 0
end
@noinline function _sm_xs_other_finally(x::Int64)::Int64
    try; throw(ArgumentError("outer")); catch
        try; x > 0 && rethrow(DomainError(x)); finally; end
    end
    return 0
end
@noinline _sm_xs_after_handled(x::Int64)::Int64 = (try; throw(DomainError(x)); catch; end; x > 0 && rethrow(); 0)
_g("exception_stack", Any[
    ("rethrow_other_in_nested_region", (x::Int64) -> (try; _sm_xs_other_nested(x); catch e; _sm_xs_kind(e); end), Int64(3)),
    ("rethrow_other_through_finally", (x::Int64) -> (try; _sm_xs_other_finally(x); catch e; _sm_xs_kind(e); end), Int64(3)),
    ("rethrow_outside_catch", (x::Int64) -> (try; x > 0 && rethrow(); 0; catch e; _sm_xs_kind(e); end), Int64(3)),
    ("rethrow_other_outside_catch", (x::Int64) -> (try; x > 0 && rethrow(ArgumentError("a")); 0; catch e; _sm_xs_kind(e); end), Int64(3)),
    ("rethrow_after_a_handled_exception", (x::Int64) -> (try; _sm_xs_after_handled(x); catch e; _sm_xs_kind(e); end), Int64(3)),
    ("nested_catch_then_rethrow", (x::Int64) -> (try; _sm_xs_nested_rethrow(x); catch e; _sm_xs_kind(e); end), Int64(1)),
    ("rethrow_other_exception", (x::Int64) -> (try; _sm_xs_rethrow_other(x); catch e; _sm_xs_kind(e); end), Int64(1)),
    ("catch_after_nested_region", (x::Int64) -> (try; (try; throw(DomainError(x)); catch; end); throw(ArgumentError("o")); catch e; _sm_xs_kind(e); end), Int64(1)),
    ("nested_in_one_function", (x::Int64) -> (try; (try; throw(ArgumentError("o")); catch; (try; x > 0 && throw(DomainError(x)); catch; end); rethrow(); end); Int64(0); catch e; _sm_xs_kind(e); end), Int64(1)),
])
# Core.throw_methoderror(f, args...), where Julia's IR throws for a call with no method: it
# throws MethodError(f, (args...,), world), never the exception last handled. Each case reads
# the caught value: Julia folds `e isa MethodError` here, since it knows what the call throws.
@noinline _sm_nm(x::Int64) = 1
@noinline _sm_nm(x::String) = 2
_g("method_error_value", Any[
    ("function_and_args", (x::Int64) -> (try; _sm_nm(Float64(x)); catch e; e isa MethodError && e.f === _sm_nm && e.args isa Tuple{Float64} ? 1 : 2; end), Int64(3)),
    ("args_value", (x::Int64) -> (try; _sm_nm(Float64(x)); catch e; Int64(((e::MethodError).args::Tuple{Float64})[1]); end), Int64(3)),
    ("after_a_handled_exception", (x::Int64) -> (try; throw(ArgumentError("a")); catch; end; try; _sm_nm(Float64(x)); catch e; (e::MethodError).f === _sm_nm ? 1 : 2; end), Int64(3)),
])
# typeassert(x, T) is Julia's checked cast: a value that is not a T throws TypeError, whatever
# T is (abstract, a struct) and whatever the value is (a number, a struct, nothing)
struct _SmTa; a::Int64; end
@noinline _sm_ta_num(x::Int64) = x > 0 ? Ref{Any}(1.5) : Ref{Any}(x)
@noinline _sm_ta_obj(x::Int64) = x > 0 ? Ref{Any}(_SmTa(x)) : Ref{Any}("s")
@noinline _sm_ta_nothing(x::Int64) = x > 0 ? Ref{Any}(nothing) : Ref{Any}(_SmTa(x))
_sm_ta_kind(e)::Int64 = e isa TypeError ? -7 : -8
_g("typeassert_checks", Any[
    ("abstract_number_target", (x::Int64) -> (try; y = _sm_ta_num(x)[]::Integer; 5; catch e; _sm_ta_kind(e); end), Int64(3)),
    ("abstract_string_target", (x::Int64) -> (try; y = _sm_ta_obj(x)[]::AbstractString; 5; catch e; _sm_ta_kind(e); end), Int64(3)),
    ("abstract_target_holds", (x::Int64) -> (try; y = _sm_ta_num(x)[]::Real; 5; catch e; _sm_ta_kind(e); end), Int64(3)),
    ("nothing_to_struct", (x::Int64) -> (try; y = _sm_ta_nothing(x)[]::_SmTa; 5; catch e; _sm_ta_kind(e); end), Int64(3)),
    ("nothing_to_struct_field", (x::Int64) -> (try; (_sm_ta_nothing(x)[]::_SmTa).a; catch e; _sm_ta_kind(e); end), Int64(3)),
    ("struct_to_struct_holds", (x::Int64) -> (try; (_sm_ta_nothing(x)[]::_SmTa).a; catch e; _sm_ta_kind(e); end), Int64(-2)),
    ("concrete_number_target", (x::Int64) -> (try; y = _sm_ta_num(x)[]::Int64; 5; catch e; _sm_ta_kind(e); end), Int64(3)),
    # a value of static type S is a T exactly when it is an S ∩ T (Julia's emit_isa): here the
    # one concrete Tuple{Int64,Int64}, tested where Tuple{Any,Any} has no test of its own
    ("static_intersection_target", (x::Int64) -> (t = _sm_ta_pair(x); (t::Tuple{Any,Any})[1]::Int64), Int64(3)),
    ("static_intersection_throws", (x::Int64) -> (try; t = _sm_ta_pair(x); (t::Tuple{Any,Any})[1]::Int64; catch e; _sm_ta_kind(e); end), Int64(-3)),
])
@noinline _sm_ta_pair(x::Int64) = x > 0 ? (x, 2) : nothing
# One as-checker per (target, operand type) (types.dart:763 generateAsChecker): the same check
# from two statements and from two functions calls one function; its rejection or TypeError is
# each caller's
@noinline _sm_ac_int(x::Int64) = (r = _sm_ta_num(x); (r[]::Int64) + (r[]::Int64))
@noinline _sm_ac_int2(x::Int64) = _sm_ta_num(x)[]::Int64
_g("as_checkers", Any[
    ("same_check_twice", (x::Int64) -> _sm_ac_int(x), Int64(-2)),
    ("same_check_twice_throws", (x::Int64) -> (try; _sm_ac_int(x); catch e; _sm_ta_kind(e); end), Int64(3)),
    ("same_check_two_functions", (x::Int64) -> _sm_ac_int(x) + _sm_ac_int2(x), Int64(-2)),
    ("throws_in_second_caller", (x::Int64) -> (try; _sm_ac_int(-x) + _sm_ac_int2(x); catch e; _sm_ta_kind(e); end), Int64(3)),
    # a static type that meets no value of the target (S ∩ T empty): the checker always throws
    ("empty_intersection_throws", (x::Int64) -> (try; y = (x > 0 ? x : Float64(x))::String; 5; catch e; _sm_ta_kind(e); end), Int64(3)),
    ("empty_intersection_throws_float", (x::Int64) -> (try; y = (x > 0 ? x : Float64(x))::String; 5; catch e; _sm_ta_kind(e); end), Int64(-3)),
])
# A call's constant callee, one representation (A4C5): an intrinsic the IR embeds as the object
# (have_fma in expm1, ctlz_int in _growend!), a type object an :invoke embeds (Dict's
# constructor), a function a specialized argument names (a singleton-typed parameter), and a
# constant callee holding captures, whose self the :invoke passes (a closure's; a callable
# struct's is xfail functor_invoke)
struct _SmCC; a::Int64; end
@noinline (c::_SmCC)(x::Int64) = x + c.a
const _SM_CCI = _SmCC(5)
const _SM_CLO = let a = 3; @noinline (x::Int64) -> x * a; end
@noinline _sm_apply(f, x) = f(x)
_g("constant_callees", Any[
    ("embedded_intrinsic_fma", (x::Float64) -> expm1(x), 0.5),
    ("embedded_intrinsic_ctlz", (x::Int64) -> (v = String[]; for i in 1:x; push!(v, "a"); end; length(v)), Int64(5)),
    ("embedded_type_object", (x::Int64) -> (d = Dict{Int64,Int64}(); d[x] = 2; d[x] + length(d)), Int64(3)),
    ("singleton_argument", (x::Int64) -> _sm_apply(abs, x), Int64(-4)),
    ("closure_constant", (x::Int64) -> _SM_CLO(x) + 1, Int64(4)),
])
# a callable struct's :invoke: the closed world holds no function for the functor's
# MethodInstance, a located rejection (dev/MARCH.md 13.10)
_xf("functor_invoke", Any[
    ("functor_constant", (x::Int64) -> _SM_CCI(x), Int64(4)),
])
# A SimpleVector is dart's immutable array of its elements, a wasm type of its own; a
# Memory{Any} is a mutable one, so a value of either is told apart (Core.svec as the IR embeds
# it is the builtin it names)
@noinline _sm_sv(x::Int64) = Core.svec(x, 2)
@noinline _sm_sv_mem(x::Int64) = Memory{Any}(undef, x)
_g("simplevector_values", Any[
    ("svec_length", (x::Int64) -> length(_sm_sv(x)), Int64(3)),
    ("memory_any_typeof", (x::Int64) -> (v = Any[_sm_sv_mem(x), _sm_sv(x)]; typeof(v[x > 0 ? 1 : 2]) === Memory{Any} ? 1 : 2), Int64(3)),
    ("svec_typeof", (x::Int64) -> (v = Any[_sm_sv_mem(x), _sm_sv(x)]; typeof(v[x > 0 ? 2 : 1]) === Core.SimpleVector ? 1 : 2), Int64(3)),
    ("svec_isa", (x::Int64) -> (v = Any[_sm_sv_mem(x), _sm_sv(x)]; v[2] isa Core.SimpleVector ? 1 : 2), Int64(3)),
])
# A Memory{Int64} and a Memory{UInt64} are one wasm array type, so no test tells a value of one
# from the other: a class read over both rejects at its statement, where it would trap on one
# (MARCH 13.17 A3S2; the root is a Memory as a classed object, as dart's `_List` is)
@noinline _sm_mi(x::Int64) = Memory{Int64}(undef, x)
@noinline _sm_mu(x::Int64) = Memory{UInt64}(undef, x)
@noinline _sm_mx(x::Int64) = x > 2 ? Memory{UInt64}(undef, 1) : x > 1 ? Memory{Int64}(undef, 1) : x
_xf("shared_bare_arrays", Any[
    ("typeof_either", (x::Int64) -> (v = Vector{Any}(undef, 2); v[1] = _sm_mi(x); v[2] = _sm_mu(x); typeof(v[x > 0 ? 2 : 1]) === Memory{UInt64} ? 1 : 2), Int64(3)),
    # isa and typeassert are class reads too: both answered true for the other class
    # (dev/AUDIT.md A4C2, A4E1)
    ("isa_either", (x::Int64) -> (v = Vector{Any}(undef, 2); v[1] = _sm_mi(x); v[2] = _sm_mu(x); v[2] isa Memory{Int64} ? 1 : 2), Int64(3)),
    ("typeassert_either", (x::Int64) -> (v = Vector{Any}(undef, 2); v[1] = _sm_mi(x); v[2] = _sm_mu(x); try; Int64((v[2]::Memory{Int64})[1]); catch e; e isa TypeError ? -7 : -8; end), Int64(3)),
    # isa over an abstract type narrowed to its one concrete member (Julia's emit_isa) is the
    # same read (A4E1 c)
    ("narrowed_isa_either", (x::Int64) -> _sm_mx(x) isa AbstractVector{Int64} ? 1 : 2, Int64(3)),
    # a String's CodeUnits is the String's byte array, Memory{UInt8}'s array type (dev/AUDIT.md
    # A5B2: both trapped, illegal cast, where native answers 2)
    ("codeunits_isa_memory", (n::Int64) -> (v = Any[codeunits("ab"), Memory{UInt8}(undef, 2)]; v[n - 2] isa Memory{UInt8} ? 1 : 2), Int64(3)),
    ("codeunits_isa_codeunits", (n::Int64) -> (v = Any[codeunits("ab"), Memory{UInt8}(undef, 2)]; v[n - 1] isa Base.CodeUnits{UInt8,String} ? 1 : 2), Int64(3)),
    ("codeunits_typeof", (n::Int64) -> (v = Any[codeunits("ab"), Memory{UInt8}(undef, 2)]; typeof(v[n - 2]) === Memory{UInt8} ? 1 : 2), Int64(3)),
])
# A tuple is typed by its elements' runtime types (jl_f_tuple): a type element is its kind, so
# `(Int64, x)` is a Tuple{DataType,Int64}, never a Tuple{Type{Int64},Int64}, which no value has
# (dev/AUDIT.md A4E2)
@noinline _sm_tt(x::Int64) = (Int64, x)
@noinline _sm_tv(x::Int64) = (Vector, x)
@noinline _sm_tu(x::Int64) = (Union{Int64,Nothing}, x)
_g("tuple_runtime_types", Any[
    ("datatype_element_typeof", (x::Int64) -> (v = Any[_sm_tt(x)]; typeof(v[1]) === Tuple{DataType,Int64} ? 1 : 2), Int64(3)),
    ("datatype_element_egal", (x::Int64) -> (v = Any[_sm_tt(x)]; v[1] === (Int64, 3) ? 1 : 2), Int64(3)),
    ("unionall_element_typeof", (x::Int64) -> (v = Any[_sm_tv(x)]; typeof(v[1]) === Tuple{UnionAll,Int64} ? 1 : 2), Int64(3)),
    ("union_element_typeof", (x::Int64) -> (v = Any[_sm_tu(x)]; typeof(v[1]) === Tuple{Union,Int64} ? 1 : 2), Int64(3)),
    ("type_element_read", (x::Int64) -> (t = _sm_tt(x); t[2] + (t[1] === Int64 ? 10 : 20)), Int64(3)),
])
# A dynamic call reaches every class that may be its argument: a tuple, which Core.tuple
# allocates without a %new, is a candidate class like any struct (dev/AUDIT.md A3S3), and a
# closure called with an erased argument has its body enrolled for it (A4S2); each trapped
@noinline _sm_dh(@nospecialize(x)) = Ref{Any}(x)
struct _SmEA; x::Int64; end
struct _SmEB; x::Int64; end
_sm_wf(x::T) where {T<:Integer} = (T === Int64 ? 1 : 3)
_sm_wf(x) = 2
abstract type _SmQAB end
struct _SmQB1 <: _SmQAB; x::Int64; end
struct _SmQB2 <: _SmQAB; x::Int64; end
struct _SmQH; q::Union{Nothing,_SmQB2}; end
const _SM_KT = Any[(3, true), "abc"]
# a non-constant global's value: values.jl bakes it as its global's initializer
struct _SmNQ1; x::Int64; end
struct _SmNQ2; x::Int64; end
_sm_nq_g::Vector{Any} = Any[_SmNQ2(7)]
_sm_nq_g2::Vector{Any} = Any[_SmNQ2(7), "s"]
_sm_nq(x::_SmNQ1) = 1
_sm_nq(x::_SmNQ2) = 2
_sm_nq(x) = 3
_sm_kd(::DataType) = 1
_sm_kd(::Int64) = 2
# Arithmetic on a value narrowed out of a Union (its class stated by Julia's IR) answers, and
# an erased operand whose class only the run time knows rejects at its statement: the arm that
# unboxed it at the operator's width with no class test is gone (dev/AUDIT.md A3E6)
_g("narrowed_union_arithmetic", Any[
    ("narrowed_uint64_rem", (n::Int64) -> (x = n > 0 ? UInt64(n) : nothing; x === nothing ? 0 : Int64(x % UInt64(3))), Int64(7)),
    ("narrowed_int32_mul", (n::Int64) -> (x = n > 0 ? Int32(n) : nothing; x === nothing ? 0 : Int64(x * Int32(5))), Int64(3)),
])
_xf("erased_operand_arithmetic", Any[
    ("erased_div_any", (n::Int64) -> (v = Any[n, UInt64(7)]; div(v[1], 2) + Int64(div(v[2], UInt64(2)))), Int64(9)),
])
_g("dynamic_enrollment", Any[
    ("closure_erased_argument", (n::Int64) -> (k = n; f = _sm_dh(s -> (s isa _SmEA ? 10 : 20) + k)[]; f(_SmEA(n)); f(_sm_dh(_SmEB(n))[])::Int64), Int64(3)),
    ("tuple_getindex_erased", (n::Int64) -> (v = Any[(Float64(n),)]; Int64(v[1][1]::Float64)), Int64(3)),
    ("tuple_length_erased", (n::Int64) -> (v = Any[(n, 2), "ab"]; length(v[1])::Int64), Int64(3)),
    # a closure with two methods called with an erased Int64 runs the more specific one, and one
    # whose only method is narrower than the erased argument still gets its body (Julia's
    # matching, Base._methods_by_ftype, and rows most specific first; dev/AUDIT.md A5P2 A5P3)
    ("closure_two_methods_erased", (n::Int64) -> (k = n; h(x::Int64) = 1 + k; h(x) = 2 + k; f = _sm_dh(h)[]; f(_sm_dh(n)[])::Int64), Int64(3)),
    ("closure_narrow_method_erased", (n::Int64) -> (k = n; f = _sm_dh(x::Int64 -> x + k)[]; f(_sm_dh(n)[])::Int64), Int64(3)),
    # a closure whose two methods are also called directly: the dispatching entry's rows are
    # tried most specific first (A4S1), and an erased Int64 among an Any vector runs
    # inner(::Int64) (A5C1)
    ("closure_overlapping_rows", (n::Int64) -> (k = n; h(x) = 2 + 0k; h(x::Int64) = 1 + 0k; a = h(n); g = _sm_dh(h)[]; a + 10 * g(_sm_dh(n)[])::Int64), Int64(3)),
    ("closure_overlapping_any_vector", (n::Int64) -> (inner(x::Int64) = x + n; inner(x) = -1; f = _sm_dh(inner)[]; v = Any[n, "s"]; f(v[1])::Int64), Int64(3)),
    # a method with static parameters is enrolled at each observed class it admits (its
    # intersection with an erased argument is a UnionAll; A6C1: native 1, wasm 2), and a body
    # reached only by `invoke` is no row (A6C2: it tied with the dispatch target, native 12,
    # wasm 22)
    ("closure_parametric_method", (n::Int64) -> (k = n; h(x::T) where {T<:Integer} = 1 + 0k; h(x) = 2 + 0k; f = _sm_dh(h)[]; f(_sm_dh(n)[])::Int64), Int64(3)),
    # a method whose static parameters two erased arguments fix is enrolled at each tuple of
    # observed classes (A7C1: rowed one position at a time it had no row, native 1, wasm 2), and
    # it covers the ambiguity of two less specific methods (native 3, wasm 1)
    ("closure_two_position_parametric", (n::Int64) -> (k = n; h(x::T, y::S) where {T<:Integer,S<:Integer} = 1 + 0k; h(x, y) = 2 + 0k; f = _sm_dh(h)[]; f(_sm_dh(n)[], _sm_dh(n)[])::Int64), Int64(3)),
    ("closure_parametric_covers_ambiguity", (n::Int64) -> (k = n; h(x::Integer, y) = 1 + 0k; h(x, y::Integer) = 2 + 0k; h(x::T, y::S) where {T<:Integer,S<:Integer} = 3 + 0k; f = _sm_dh(h)[]; f(_sm_dh(n)[], _sm_dh(n)[])::Int64), Int64(3)),
    # a generic function's method with a static parameter, a dispatch candidate for an erased
    # Int64, specialized with Julia's static parameter values (A7C6)
    ("generic_parametric_candidate", (n::Int64) -> (v = Any[n, "s"]; _sm_wf(v[1]) + 10 * _sm_wf(v[2])), Int64(3)),
    # a static parameter fixed by a Type{X} argument (A8C2: no candidate class, no row, native
    # 1, wasm 2), and one a match leaves a TypeVar (A8C6: it rejected the static_parameter node)
    ("closure_parametric_type_position", (n::Int64) -> (k = n; h(x::T, ::Type{S}) where {T<:Integer,S} = 1 + 0k; h(x, y) = 2 + 0k; f = _sm_dh(h)[]; f(_sm_dh(n)[], Int64)::Int64), Int64(3)),
    ("closure_unbounded_parameter", (n::Int64) -> (k = n; h(x::T) where {T} = (T === Int64 ? 1 : 3) + 0k; f = _sm_dh(h)[]; f(_sm_dh(n)[])::Int64), Int64(3)),
    # an ambiguity only at a class no value has (QB2) rejected under the rule that asked
    # Base.isambiguous over every type; Julia's dispatch at the classes that reach runs h(::QB1,
    # ::QB1) (dev/AUDIT.md A7C4, A9P3: native 3)
    ("closure_ambiguity_unreached_class", (n::Int64) -> (k = n; h(x::_SmQAB, y) = 1 + 0k; h(x, y::_SmQAB) = 2 + 0k; h(x::_SmQB1, y::_SmQB1) = 3 + 0k; f = _sm_dh(h)[]; f(_sm_dh(_SmQB1(n))[], _sm_dh(_SmQB1(n))[])::Int64), Int64(3)),
    # a type object reaching an erased argument fixes a Type{S} method's static parameter
    # (A9C1: it had no row, native 1, wasm 2)
    ("closure_type_object_erased", (n::Int64) -> (k = n; h(::Type{S}) where {S<:Integer} = 1 + 0k; h(x) = 2 + 0k; g = _sm_dh(h)[]; g(_sm_dh(Int64)[])::Int64), Int64(3)),
    ("closure_invoke_only_body", (n::Int64) -> (k = n; @noinline h(x::Int64) = 1 + 0k; @noinline h(x::Integer) = 2 + 0k; a = invoke(h, Tuple{Integer}, n); f = _sm_dh(h)[]; a + 10 * f(_sm_dh(n)[])::Int64), Int64(3)),
    # a function with a DataType method and an Int64 method, called on an erased type object
    # and an erased Int64 (A5E10, A5B4: measured 21)
    ("kind_and_class_rows", (n::Int64) -> (v = Any[Int64, n]; _sm_kd(v[1]) + 10 * _sm_kd(v[2])), Int64(3)),
    # the same with a tuple of a type built in the program, whose DataType element the
    # collector observes (A5C3: measured 1)
    ("kind_row_beside_type_tuple", (n::Int64) -> (v = Any[Int64, n]; _sm_kd(v[1]) + _sm_tt(n)[2] - n), Int64(3)),
    # one class set (closed_world_classes): the ambiguity search asks about the classes a value may
    # have, not every numbered one; QB2 is numbered (a field's type names it) and no value has it
    # (dev/AUDIT.md A7C4: rejected over the numbered classes, native 3)
    ("closure_ambiguity_numbered_unreached_class", (n::Int64) -> (k = n; h(x::_SmQAB, y) = 1 + 0k; h(x, y::_SmQAB) = 2 + 0k; h(x::_SmQB1, y::_SmQB1) = 3 + 0k; f = _sm_dh(h)[]; q = _sm_dh(_SmQH(nothing))[]::_SmQH; f(_sm_dh(_SmQB1(n))[], _sm_dh(_SmQB1(n))[])::Int64 + (q.q === nothing ? 0 : 5)), Int64(3)),
    # the constant `nothing` a statement passes is a value of class Nothing, as a literal is (it was
    # no candidate: no row for it, a trap where native answers 1), and Julia's match at Nothing
    # leaves T a TypeVar, the MethodInstance Julia runs
    ("closure_union_nothing_erased", (n::Int64) -> (k = n; h(x::Union{T,Nothing}) where {T} = (x === nothing ? 1 : 3) + 0k; g = _sm_dh(h)[]; g(_sm_dh(nothing)[])::Int64), Int64(3)),
    # a kind is no value's dispatch type at a Type{S} parameter: the match at DataType leaves S a
    # TypeVar and is no signature; the type object's own Type{Int64} is (dev/AUDIT.md A9C6: the
    # body built at DataType rejected its static parameter, native 8)
    ("closure_type_parameter_at_kind", (n::Int64) -> (k = n; h(::Type{S}) where {S} = (S === Int64 ? 1 : 3) + 0k; h(x) = 7 + 0k; g = _sm_dh(h)[]; v = Any[Int64, DataType, n]; g(v[1])::Int64 + g(v[3])::Int64), Int64(3)),
    # the classes a constant holds are candidates: the tuple inside `_SM_KT` has a row for the
    # dynamic `length` (it was numbered and no candidate: a trap where native answers 32)
    ("constant_contents_dynamic_call", (n::Int64) -> length(_SM_KT[n])::Int64 + 10 * length(_SM_KT[n + 1])::Int64, Int64(1)),
    # what a non-constant global holds is a value as a constant's contents are: its class (named
    # nowhere else) is numbered for the initializer baked from it (the first walk of a constant
    # alone left it unnumbered, a codegen bug at ensure_type_id!), and a dynamic call over it
    # has its rows
    ("nonconst_global_contents", (n::Int64) -> (v = _sm_nq_g[1]; v === nothing ? 0 : n + 1), Int64(3)),
    ("nonconst_global_dynamic_call", (n::Int64) -> _sm_nq(_sm_nq_g2[1]) + 10 * _sm_nq(_sm_nq_g2[2]) + n, Int64(3)),
    # a tuple held as Any, read by a dynamic getindex (dev/AUDIT.md A3S3)
    ("tuple_getindex_held_any", (n::Int64) -> (t = _sm_dh((n, 2n))[]; t[1]::Int64), Int64(3)),
    # a callee is no evidence of a class: the Dict a constructor builds is a candidate by the %new
    # in the constructor's body (dev/AUDIT.md A4C4)
    ("constructor_callee_class", (n::Int64) -> (d = Dict{Int64,Int64}(n => 1); v = Any[d, "ab"]; length(v[1])::Int64), Int64(3)),
])
# isa against a kind (DataType, UnionAll, …): Julia folds S <: T only where its subtyping of
# kinds is sound (jl_is_not_broken_subtype), and tests the type object's kind elsewhere
@noinline _sm_kv(x::Int64) = x > 0 ? Vector : Int64
@noinline _sm_ki(x::Int64)::Type{Int64} = Int64
_g("kind_isa", Any[
    ("type_of_type_isa_datatype", (x::Int64) -> (t = _sm_ki(x); t isa DataType ? 1 : 2), Int64(3)),
    ("unionall_isa_datatype", (x::Int64) -> (T = _sm_kv(x); T isa DataType ? 1 : 2), Int64(3)),
    ("unionall_isa_unionall", (x::Int64) -> (T = _sm_kv(x); T isa UnionAll ? 1 : 2), Int64(3)),
    # a value whose static type admits one kind is tested for that kind only (dev/AUDIT.md
    # A5E8: the partition was over every kind under the type tested)
    ("kind_partition_static_type", (n::Int64) -> (v = n > 2 ? typeof(_sm_dh(n)[]) : (n > 1 ? :a : n); v isa Type ? 1 : 2), Int64(3)),
])
# A runtime-length tuple (`Core.tuple(v...)`) is an NTuple{n,E} for its run-time n
# (jl_f_tuple); its representation's header names Tuple{Vararg{E}}, which no value has, so
# typeof, `===` and an erased slot answered for that class (dev/AUDIT.md A5E3: native 1, wasm
# 2). isa tests its size; the rest reject at their statement
@noinline _sm_mk(v::Vector{Int64}) = Core.tuple(v...)
@noinline _sm_mk8(v::Vector{Int8}) = Core.tuple(v...)
@noinline _sm_mkbool(v::Vector{Bool}) = Core.tuple(v...)
struct _SmMT; m::Memory{Int64}; t::Tuple{Int64}; end
struct _SmWA; x::Any; end
@noinline _sm_wa(x) = _SmWA(x)
struct _SmWU; x::Union{Nothing,Tuple{Vararg{Int64}}}; end
_g("runtime_length_tuple", Any[
    ("isa_ntuple_length", (n::Int64) -> _sm_mk([n, 2, 3]) isa NTuple{3,Int64} ? 1 : 2, Int64(3)),
    ("isa_ntuple_other_length", (n::Int64) -> _sm_mk([n, 2, 3]) isa NTuple{2,Int64} ? 1 : 2, Int64(3)),
    ("isa_empty", (n::Int64) -> _sm_mk(Int64[]) isa Tuple{} ? n : 2, Int64(3)),
    # against an abstract tuple type or a union, the lengths it admits (A6E1: the header's
    # class answered 2 where native answers 1)
    ("isa_least_length", (n::Int64) -> _sm_mk([n, 2, 3]) isa Tuple{Int64,Vararg{Int64}} ? 1 : 2, Int64(3)),
    ("isa_least_length_fails", (n::Int64) -> _sm_mk([n, 2, 3]) isa Tuple{Int64,Int64,Int64,Int64,Vararg{Int64}} ? 1 : 2, Int64(3)),
    ("isa_union_of_lengths", (n::Int64) -> _sm_mk([n, 2, 3]) isa Union{Tuple{Int64},NTuple{3,Int64}} ? 1 : 2, Int64(3)),
    # a fixed tuple joining a runtime-length one at a phi is that runtime-length tuple (A9E4:
    # a cast between the two structs trapped where native answers 7), whether the edge is a
    # literal or a value (A10P7)
    ("fixed_joins_runtime_length", (n::Int64) -> (u = n == 3 ? (7,) : _sm_mk([n, 2]); u[1]), Int64(3)),
    ("runtime_length_joins_fixed", (n::Int64) -> (u = n == 3 ? (7,) : _sm_mk([n, 2]); u[1]), Int64(4)),
    ("value_joins_runtime_length", (n::Int64) -> (u = n == 3 ? (n,) : _sm_mk([n, 2]); u[1]), Int64(3)),
    # narrowed to the NTuple it was tested to be, it is that NTuple (A6E3: a cast between the
    # two structs trapped where native answers 6)
    # a packed element is read with its sign: -3 read unsigned is 253 (A9B3, A10P6); the
    # answer, 2, is not the else branch's 0 (A11P4)
    ("isa_narrowed_int8_fields", (n::Int64) -> (t = _sm_mk8(Int8[-n, 2, 5]); t isa NTuple{3,Int8} ? Int64(t[1]) + Int64(t[3]) : 0), Int64(3)),
    ("isa_narrowed_fields", (n::Int64) -> (t = _sm_mk([n, 2, 3]); t isa NTuple{3,Int64} ? t[1] + t[3] : 0), Int64(3)),
    # a Bool element is unpacked, read plainly (A10E5: a signed read of it was refused)
    ("isa_narrowed_bool_fields", (n::Int64) -> (t = _sm_mkbool([true, false, n > 2]); t isa NTuple{3,Bool} ? (t[3] ? 2 : 1) : 0), Int64(3)),
    # a fixed tuple held as any value and asserted a runtime-length tuple is built into it
    # (A10E4: a cast of its struct trapped where native answers 3)
    ("erased_asserted_runtime_length", (n::Int64) -> (v = Any[(n,)]; t = v[1]::Tuple{Vararg{Int64}}; t[1]), Int64(3)),
    # a struct whose layout is the representation's widens to Any as any struct does
    ("same_layout_struct_erased", (n::Int64) -> (m = Memory{Int64}(undef, 1); m[1] = n; v = Any[_SmMT(m, (n,))]; (v[1]::_SmMT).t[1]), Int64(3)),
    # held in a field typed by a union of Nothing and itself, read under that type
    ("into_union_field", (n::Int64) -> (w = _SmWU(_sm_mk([n, 2])); w.x isa NTuple{2,Int64} ? 1 : 2), Int64(3)),
    ("into_union_field_length", (n::Int64) -> (w = _SmWU(_sm_mk([n, 2])); x = w.x; x === nothing ? 0 : length(x)), Int64(3)),
])
_xf("runtime_length_tuple_class", Any[
    ("typeof_ntuple", (n::Int64) -> typeof(_sm_mk([n, 2, 3])) === Tuple{Int64,Int64,Int64} ? 1 : 2, Int64(3)),
    ("egal_ntuple", (n::Int64) -> _sm_mk([n, 2, 3]) === (3, 2, 3) ? 1 : 2, Int64(3)),
    ("erased_isa_ntuple", (n::Int64) -> Any[_sm_mk([n, 2, 3])][1] isa NTuple{3,Int64} ? 1 : 2, Int64(3)),
    # a failed typeassert's TypeError carries the value as `got`, a slot of any class (A6E2)
    ("typeassert_got", (n::Int64) -> (try; _sm_mk([n, 2, 3])::NTuple{2,Int64}; 0; catch e; e isa TypeError && e.got isa NTuple{3,Int64} ? 1 : 2; end), Int64(3)),
    # into a field of any class through a constructor call: the one widening check, the
    # funnel's, rejects it at the call (dev/AUDIT.md A7E4: the check trusted a sink's type)
    ("into_any_field", (n::Int64) -> (w = _sm_wa(_sm_mk([n, 2])); w.x isa NTuple{2,Int64} ? 1 : 2), Int64(3)),
])
# A heterogeneous tuple read by a runtime index: each field converts to the union's
# representation through the one conversion, a box, a string, a closure's object, and
# `nothing` a nullable representation's null (dev/AUDIT.md A11E7: its own ladder)
_g("heterogeneous_tuple_read", Any[
    ("box", (n::Int64) -> (t = (n, 2.5, "ab"); v = t[n - 2]; v isa Int64 ? 1 : v isa Float64 ? 2 : 3), Int64(3)),
    ("float", (n::Int64) -> (t = (n, 2.5, "ab"); v = t[n - 1]; v isa Int64 ? 1 : v isa Float64 ? 2 : 3), Int64(3)),
    ("string", (n::Int64) -> (t = (n, 2.5, "ab"); v = t[n]; v isa String ? length(v) : 0), Int64(3)),
    ("closure", (n::Int64) -> (k = n; t = (n, x -> x + k); v = t[n - 1]; v isa Int64 ? v : (v(1))::Int64), Int64(3)),
    ("nothing", (n::Int64) -> (t = (n, nothing); v = t[n - 1]; v === nothing ? 1 : 2), Int64(3)),
    # `nothing` read as a three-member union is its null, which isa reads (A16E2: native 1, wasm 2)
    ("nothing_isa", (n::Int64) -> (t = (n, nothing, 2.5); t[(n % 3) + 1] isa Nothing ? 1 : 2), Int64(1)),
])
# A constant Memory{Any}'s elements are typed by their own classes, never the Memory's element
# type: a numeric is boxed under its classId (dev/AUDIT.md A12C6: a WasmInternalError where
# native answers, the element converted as an `Any`)
const _SM_CM = let m = Memory{Any}(undef, 3); m[1] = Int64; m[2] = 7; m[3] = 2.5; m; end
_g("constant_memory_elements", Any[
    ("numeric", (n::Int64) -> (x = _SM_CM[n - 2]; x isa Int64 ? x : 2), Int64(4)),
    ("type_object", (n::Int64) -> (x = _SM_CM[n - 2]; x === Int64 ? 1 : 2), Int64(3)),
    ("float", (n::Int64) -> (x = _SM_CM[n]; x isa Float64 ? x : 0.0), Int64(3)),
])
# A tuple with a type object element is typed by its kind, one rule (type_element_kind)
# for the tuple's runtime type and its registration (dev/AUDIT.md A5E5)
_g("tuple_type_element", Any[
    ("typeof", (n::Int64) -> (t = (Int64, n); typeof(t) === Tuple{DataType,Int64} ? 1 : 2), Int64(3)),
    ("erased", (n::Int64) -> (v = Any[(Int64, n)]; v[1] isa Tuple{DataType,Int64} ? 1 : 2), Int64(3)),
])
# A narrow source's register is normalised before it widens into Int128 (13.1: sext of a UInt8
# with its high bit set is -128; a dirty Int8 or UInt8 register holds junk above its width)
@noinline _sm_dirty8(n::Int64) = Int8(n) + Int8(100)
@noinline _sm_dirtyu8(n::Int64) = UInt8(n) + UInt8(100)
_g("int128_extends", Any[
    ("sext_uint8_high_bit", (n::Int64) -> Int64(Core.Intrinsics.sext_int(Int128, UInt8(n))), Int64(128)),
    ("sext_int8_high_bit", (n::Int64) -> Int64(Int128(n % Int8)), Int64(200)),
    ("sext_dirty_int8", (n::Int64) -> Int64(Int128(_sm_dirty8(n))), Int64(100)),
    ("zext_dirty_uint8", (n::Int64) -> Int64(Int128(_sm_dirtyu8(n))), Int64(200)),
])
# A narrow source widens by its op, into a target of any register: sext_int and sitofp read its
# sign at its own width, zext_int and uitofp its bits, whatever its type (dev/AUDIT.md A16B1 =
# A16E1: a dirty Int8 widened to Int32 answered 200, native -56)
_g("narrow_widening", Any[
    ("sext_dirty_int8_to_int32", (n::Int64) -> Int64(Int32(_sm_dirty8(n))), Int64(100)),
    ("sext_dirty_int8_to_int16", (n::Int64) -> Int64(Int16(_sm_dirty8(n))), Int64(100)),
    ("zext_dirty_uint8_to_uint16", (n::Int64) -> Int64(UInt16(_sm_dirtyu8(n))), Int64(200)),
    ("sext_rem_int8_to_int32", (n::Int64) -> Int64(Int32((n % Int8) + Int8(100))), Int64(100)),
    ("zext_rem_uint8_to_uint16", (n::Int64) -> Int64(UInt16((n % UInt8) + 0x64)), Int64(200)),
    ("sext_uint8_to_int64", (n::Int64) -> Core.Intrinsics.sext_int(Int64, n % UInt8), Int64(128)),
    ("sitofp_uint8", (n::Int64) -> Core.Intrinsics.sitofp(Float64, n % UInt8), Int64(255)),
    ("uitofp_dirty_uint8", (n::Int64) -> Float64(_sm_dirtyu8(n)), Int64(200)),
])
# A conversion's target is the type its operand names, resolved once (a GlobalRef `Float32`):
# sitofp to Float32 rounds once (dev/AUDIT.md A16E3: it converted to Float64 and demoted, rounding
# twice, native 2^60+2^37, wasm 2^60)
_g("conversion_target", Any[
    # its bits, read exactly (a Float32 this large reaches the host as a decimal)
    ("sitofp_float32", (n::Int64) -> Int64(reinterpret(Int32, Core.Intrinsics.sitofp(Float32, n))), Int64(1152921573326323713)),
])
# An intrinsic splatted over a vector runs at its own arity: two elements, or Julia's
# ArgumentError (dev/AUDIT.md A16E4: three elements answered their sum, native throws)
_g("reduce_intrinsic_arity", Any[
    ("two_elements", (n::Int64) -> (v = [1, n]; Core.Intrinsics.add_int(v...)), Int64(3)),
    ("three_elements", (n::Int64) -> (v = [1, n, 3]; try; Core.Intrinsics.add_int(v...); catch e; e isa ArgumentError ? -1 : -2; end), Int64(3)),
    ("one_element", (n::Int64) -> (v = [n]; try; Core.Intrinsics.add_int(v...); catch e; e isa ArgumentError ? -1 : -2; end), Int64(3)),
    ("no_element", (n::Int64) -> (v = Int64[]; try; Core.Intrinsics.add_int(v...); catch e; e isa ArgumentError ? -1 : -2; end), Int64(3)),
])
# An :invoke retargeted by its operand's capture typing is retargeted by the final world's: a
# captor collected after the first round widens the variable, and the call keeps Julia's method
# (dev/AUDIT.md A16C1: the first round's g(::Int64) stayed, a trap where native answers 19)
@noinline _sm_gn(@nospecialize(x)) = x isa Int ? x + 1 : -1
_g("capture_typed_invoke", Any[
    ("captor_collected_later", (n::Int64) -> (c = n; w = y -> (c = y; nothing); fs = Any[w]; fs[1](2.5); _sm_gn(c) + 10 * _sm_gn(Base.inferencebarrier(n))), Int64(1)),
])
# A closure built inside a captor from its box field writes into the creator's box: the
# creator's read joins its writes (dev/AUDIT.md A16C3: the read kept Int64, a trap where native
# answers 1)
_g("nested_captor", Any[
    ("nested_write_read_by_creator", (n::Int64) -> (c = n; o = @noinline () -> (i = @noinline () -> (c = 2.5; nothing); i(); nothing); o(); c isa Float64 ? 1 : 2), Int64(1)),
])
# A captor's body inlined into a function taking the closure as an argument writes through that
# argument: the write joins the box, so the creator's read is not its own Int64 alone (dev/AUDIT.md
# A17C1: the read unboxed a Float64 box as an Int64 one, an illegal cast on 1.12, native 1)
@noinline _sm_callit(g) = (g(); nothing)
# (box_value_literal_phi: _sm_bump! inlines its argument's `s += 1` and returns its Int64 sum
# under its `Any` result, boxed by the value's own class; it rejected located at that write until
# the write through the argument joined the box)
# A closure held in a constant global, its call inlined, writes through the constant
# (`getfield(Main._SmCC, :s)`): the write joins the box of its closure type, so a read of that type
# through an argument is not the world's Int64 join alone (dev/AUDIT.md A18C3: an illegal cast on
# 0bc84e05, native 14)
_sm_mkc(v) = (s = v; (y...) -> (isempty(y) || (s = y[1]); s))
const _SmCC = _sm_mkc(1)
@noinline _sm_mkn(n::Int64) = _sm_mkc(n)
@noinline _sm_crd(c) = c()
@noinline _sm_cwr(c, y) = c(y)
function _sm_constcarrier(n::Int64)
    h = _sm_mkn(n)
    _sm_cwr(h, n + 1)
    a = _sm_crd(h)::Int64
    _SmCC(2.5)
    return _sm_crd(_SmCC) isa Float64 ? a + 10 : a + 20
end
_g("inlined_captor", Any[
    ("write_through_argument", (n::Int64) -> (c = n; w = () -> (c = 2.5; nothing); _sm_callit(w); c isa Float64 ? 1 : 2), Int64(1)),
    ("box_value_literal_phi", _sm_boxlit, Int64(0)),
    ("write_through_constant", _sm_constcarrier, Int64(3)),
])
# A user primitive narrower than its i32 register keeps junk above its width until it is read:
# its width is its own bits, 8*sizeof, for every primitive (dev/AUDIT.md A17E2: zext of an 8-bit
# primitive answered 300, native 44)
primitive type _SmP8 8 end
primitive type _SmP24 24 end
primitive type _SmP40 40 end
_sm_p8(n::Int64) = Core.Intrinsics.bitcast(_SmP8, (n % UInt8) + 0xc8)
_g("narrow_primitive", Any[
    ("zext_dirty_p8", (n::Int64) -> Core.Intrinsics.zext_int(Int64, _sm_p8(n)), Int64(100)),
    ("sext_dirty_p8", (n::Int64) -> Core.Intrinsics.sext_int(Int64, _sm_p8(n)), Int64(200)),
    ("ult_dirty_p8", (n::Int64) -> Core.Intrinsics.ult_int(_sm_p8(n), Core.Intrinsics.bitcast(_SmP8, 0x50)) ? 1 : 2, Int64(100)),
    ("egal_dirty_p8", (n::Int64) -> _sm_p8(n) === Core.Intrinsics.bitcast(_SmP8, 0x2c) ? 1 : 2, Int64(100)),
    # a 24-bit primitive in an i32 and a 40-bit one in an i64 (dev/AUDIT.md A17E2: sext
    # of a dirty 24-bit value answered 32754, native -32782; of a 40-bit one 1099511627762,
    # native -14; zext of a dirty 40-bit one -1099511627774, native 2)
    ("zext_dirty_p24", (n::Int64) -> Core.Intrinsics.zext_int(Int64, Core.Intrinsics.trunc_int(_SmP24, (n % UInt32) + 0xffffff00)), Int64(2)),
    ("sext_dirty_p24", (n::Int64) -> Core.Intrinsics.sext_int(Int64, Core.Intrinsics.trunc_int(_SmP24, (n % UInt32) + 0x00ff7ff0)), Int64(2)),
    ("slt_dirty_p24", (n::Int64) -> Core.Intrinsics.slt_int(Core.Intrinsics.trunc_int(_SmP24, (n % UInt32) + 0x00800000), Core.Intrinsics.trunc_int(_SmP24, (n % UInt32) + 0x00ffffff)) ? 1 : 2, Int64(2)),
    ("ashr_dirty_p24", (n::Int64) -> Core.Intrinsics.sext_int(Int64, Core.Intrinsics.ashr_int(Core.Intrinsics.trunc_int(_SmP24, (n % UInt32) + 0x00ff7ff0), 1)), Int64(2)),
    ("egal_dirty_p24", (n::Int64) -> Core.Intrinsics.trunc_int(_SmP24, (n % UInt32) + 0x01000000) === Core.Intrinsics.trunc_int(_SmP24, n % UInt32) ? 1 : 2, Int64(2)),
    ("zext_dirty_p40", (n::Int64) -> Core.Intrinsics.zext_int(Int64, Core.Intrinsics.trunc_int(_SmP40, (n % UInt64) + 0xffffff0000000000)), Int64(2)),
    ("sext_dirty_p40", (n::Int64) -> Core.Intrinsics.sext_int(Int64, Core.Intrinsics.trunc_int(_SmP40, (n % UInt64) + 0x000000fffffffff0)), Int64(2)),
    ("ashr_dirty_p40", (n::Int64) -> Core.Intrinsics.sext_int(Int64, Core.Intrinsics.ashr_int(Core.Intrinsics.trunc_int(_SmP40, (n % UInt64) + 0x000000fffffffff0), 1)), Int64(2)),
    ("ult_dirty_p40", (n::Int64) -> Core.Intrinsics.ult_int(Core.Intrinsics.trunc_int(_SmP40, (n % UInt64) + 0xffffff0000000000), Core.Intrinsics.trunc_int(_SmP40, UInt64(3))) ? 1 : 2, Int64(2)),
    ("egal_dirty_p40", (n::Int64) -> Core.Intrinsics.trunc_int(_SmP40, (n % UInt64) + 0x0000010000000000) === Core.Intrinsics.trunc_int(_SmP40, n % UInt64) ? 1 : 2, Int64(2)),
    # its bits counted and its sign read at its own width, in an i64 as in an i32 (measured with
    # 117a's W2 and W7 normalising an i32-held operand alone: ctlz answered 62, native 38; cttz of
    # 0 64, native 40; ctpop of a dirty value 2, native 1; flipsign 5, native -5)
    ("ctlz_p40", (n::Int64) -> Core.Intrinsics.zext_int(Int64, Core.Intrinsics.ctlz_int(Core.Intrinsics.trunc_int(_SmP40, n % UInt64))), Int64(2)),
    ("cttz_zero_p40", (n::Int64) -> Core.Intrinsics.zext_int(Int64, Core.Intrinsics.cttz_int(Core.Intrinsics.trunc_int(_SmP40, (n % UInt64) << 41))), Int64(3)),
    ("ctpop_dirty_p40", (n::Int64) -> (p = Core.Intrinsics.trunc_int(_SmP40, n); Core.Intrinsics.zext_int(Int64, Core.Intrinsics.ctpop_int(Core.Intrinsics.add_int(p, p)))), Int64(2)^39 + 1),
    ("flipsign_p40", (n::Int64) -> Core.Intrinsics.sext_int(Int64, Core.Intrinsics.flipsign_int(Core.Intrinsics.trunc_int(_SmP40, UInt64(5)), Core.Intrinsics.trunc_int(_SmP40, (n % UInt64) + 0x000000fffffffff0))), Int64(2)),
    # into a 128-bit integer from a 40-bit one in an i64, by the one width rule (dev/AUDIT.md
    # A18E2 (c), measured on 25e6a5b7: the sext answered 2, native 1; the zext of a dirty value
    # 1099511627778, native 2)
    ("sext128_p40", (n::Int64) -> Core.Intrinsics.slt_int(Core.Intrinsics.sext_int(Int128, Core.Intrinsics.trunc_int(_SmP40, n)), Int128(0)) ? 1 : 2, Int64(2)^40 - 2),
    ("zext128_dirty_p40", (n::Int64) -> (p = Core.Intrinsics.trunc_int(_SmP40, n); Core.Intrinsics.trunc_int(Int64, Core.Intrinsics.zext_int(Int128, Core.Intrinsics.add_int(p, p)))), Int64(2)^39 + 1),
])
# An erased nothing reaching a selector-dispatched `::Nothing` method, through the selector
# caller's class read and the dispatch wrapper's argument (dev/AUDIT.md A17E3: the base trapped
# reading a null's header, native 4)
_sm_gq(x::Int64) = 1; _sm_gq(x::Float64) = 2; _sm_gq(x::String) = 3; _sm_gq(x::Nothing) = 4; _sm_gq(x::Char) = 5
_sm_gq(x::Int32) = 6; _sm_gq(x::UInt8) = 7; _sm_gq(x::Bool) = 8; _sm_gq(x::Symbol) = 9; _sm_gq(x::Int16) = 10
@noinline _sm_callgq(@nospecialize(x)) = _sm_gq(x)
@noinline _sm_gs(x::Nothing) = 4; @noinline _sm_gs(x::Int64) = 1; @noinline _sm_gs(x::Float64) = 2
_g("selector_nothing", Any[
    ("erased_nothing_many_methods", (n::Int64) -> (v = Any[n, 2.5, "a", nothing, 'c', Int32(1), 0x01, true, :s, Int16(2)]; _sm_gq(v[n])::Int64), Int64(4)),
    ("erased_nothing_dispatch_caller", (n::Int64) -> (v = Any[n, 2.5, "a", nothing, 'c', Int32(1), 0x01, true, :s, Int16(2)]; _sm_callgq(v[n])::Int64), Int64(4)),
    ("erased_nothing_three_methods", (n::Int64) -> (v = Any[n, 2.5, nothing]; _sm_gs(v[n])::Int64), Int64(3)),
])
# Julia's `#undef` is NULL and `nothing` an object; WT's `nothing` is the null, so a slot that
# holds both marks `#undef` with its undefined value: a stored `nothing` is assigned, an unset slot
# is not, and its read throws UndefRefError (dev/AUDIT.md A17E1: isassigned and isdefined of a
# stored `nothing` answered 2, native 1, and the read of an unset slot answered 0, native
# UndefRefError; dev/formal/Undef.tla)
mutable struct _SmUA; x; _SmUA() = new(); end
mutable struct _SmUS; a::Int64; x::String; _SmUS() = new(1); end
# the String's length out of line: an inlined `length` in a try body is 13.17's 1.13 stackifier gap
@noinline _sm_ulen(s::String) = ncodeunits(s)
mutable struct _SmUU; a::Int64; x::Union{Nothing,String}; _SmUU() = new(1); end
mutable struct _SmUR; a::Int64; b; _SmUR() = new(1); end
mutable struct _SmUD; x::Union{Nothing,String}; _SmUD(x) = new(x); end
@noinline _sm_ua_h(x) = x === nothing ? 1 : 2
# `Core.tuple(v...)` out of line, a throw beside it: Julia infers the splat nothrow, so a try around a
# call of a callee doing only that is dropped and the native UndefRefError escapes it
@noinline _sm_utup(v::Vector{String}, n::Int64) = (n > 100 && throw(ArgumentError("n")); ncodeunits(Core.tuple(v...)[n - 2]))
# An immutable struct with a pointer field is stored inline by Julia (jl_datatype_isinlinealloc),
# its `#undef` a NULL first pointer (typed_load's null_pointer_check of first_ptr, cgutils.cpp:2270;
# jl_field_isdefined, datatype.c:2293); WT holds it in its own nullable reference, whose null is
# `#undef`
struct _SmUP; s::String; end
mutable struct _SmUF; a::Int64; p::Some{String}; _SmUF() = new(1); end
# constants holding unset slots: a Dict's unoccupied reference slot, a Vector's and a Memory's
# unset element are `#undef`, emitted by one rule (emit_constant_slots!)
const _SmUDict = Dict{Int,Any}(1 => 2)
const _SmUDictU = Dict{Int,Union{Nothing,String}}(1 => nothing)
const _SmUVecA = let v = Vector{Any}(undef, 3); v[1] = 7; v[3] = nothing; v; end
const _SmUVecS = let v = Vector{String}(undef, 2); v[2] = "ab"; v; end
const _SmUMemA = let m = Memory{Any}(undef, 2); m[2] = 5; m; end
_g("undef_slots", Any[
    ("isassigned_stored_nothing", (n::Int64) -> (v = Vector{Any}(undef, 2); v[1] = nothing; v[2] = n; isassigned(v, 1) ? 1 : 2), Int64(3)),
    ("isassigned_unset", (n::Int64) -> (v = Vector{Any}(undef, 2); v[2] = n; isassigned(v, 1) ? 1 : 2), Int64(3)),
    ("read_unset_throws", (n::Int64) -> (v = Vector{Any}(undef, 2); v[1] = n; try; _sm_ua_h(v[n - 1]); catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("isdefined_field_nothing", (n::Int64) -> (m = _SmUA(); m.x = (n > 0 ? nothing : n); isdefined(m, :x) ? 1 : 2), Int64(3)),
    ("isdefined_field_unset", (n::Int64) -> (m = _SmUA(); isdefined(m, :x) ? 1 : 2 + 0n), Int64(3)),
    ("read_unset_field_throws", (n::Int64) -> (m = _SmUA(); try; _sm_ua_h(m.x); catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("captured_local_nothing", (n::Int64) -> (local x; g = () -> x; x = n > 0 ? nothing : 1; g() === nothing ? 1 : 2), Int64(3)),
    ("grown_slot_unset", (n::Int64) -> (v = Any[nothing, n]; resize!(v, 1); resize!(v, 2); (isassigned(v, 1) ? 10 : 20) + (isassigned(v, 2) ? 1 : 2)), Int64(3)),
    ("copied_unset", (n::Int64) -> (v = Vector{Any}(undef, 3); v[1] = nothing; v[3] = n; w = copy(v); (isassigned(w, 1) ? 10 : 20) + (isassigned(w, 2) ? 1 : 2)), Int64(3)),
    # a slot whose type admits no `nothing` keeps its null as `#undef`, read checked; a
    # Union{Nothing,S} slot is held in the any hierarchy, so `#undef` and `nothing` are two values
    # (dev/AUDIT.md A17E1, measured on 52c0a9bd: a Vector{String} slot's unset read answered 1 or
    # trapped, native 2 or UndefRefError; isassigned of a stored nothing in a
    # Vector{Union{Nothing,String}} 2, native 1, and its unset read `nothing`, native
    # UndefRefError; the same for a field `new` leaves unset; a read by a run-time name of an unset
    # field 1, native UndefRefError; a splat `[v...]` of an unset slot read as assigned, 2, and its
    # length 2, native UndefRefError)
    ("ref_unset_read_throws", (n::Int64) -> (v = Vector{String}(undef, n); try; v[1]; 1; catch; 2; end), Int64(2)),
    ("ref_unset_length_throws", (n::Int64) -> (v = Vector{String}(undef, 2); v[2] = "a"; try; _sm_ulen(v[n - 2]); catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("ref_field_unset_throws", (n::Int64) -> (m = _SmUS(); try; _sm_ulen(m.x) + n; catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("union_isassigned_nothing", (n::Int64) -> (v = Vector{Union{Nothing,String}}(undef, 2); v[1] = nothing; isassigned(v, 1) ? 1 : 2), Int64(3)),
    ("union_unset_read_throws", (n::Int64) -> (v = Vector{Union{Nothing,String}}(undef, 2); try; v[n - 2] === nothing ? 1 : 2; catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("union_values", (n::Int64) -> (v = Vector{Union{Nothing,String}}(undef, 2); v[1] = "ab"; v[2] = nothing; (v[1] === nothing ? 10 : length(v[1]::String)) + (v[2] === nothing ? 100 : 0)), Int64(3)),
    ("union_field_isdefined_nothing", (n::Int64) -> (m = _SmUU(); m.x = (n > 0 ? nothing : "s"); isdefined(m, :x) ? 1 : 2), Int64(3)),
    ("union_field_unset_throws", (n::Int64) -> (m = _SmUU(); try; m.x === nothing ? 1 : 2; catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("union_field_value", (n::Int64) -> (m = _SmUU(); m.x = (n > 0 ? "abc" : nothing); m.x === nothing ? 0 : length(m.x::String)), Int64(3)),
    # an isbits union is inline in Julia, never `#undef`: its box's null is `nothing`, read as it is
    ("inline_union_isassigned", (n::Int64) -> (v = Union{Nothing,Int64}[nothing, n]; (isassigned(v, 1) ? 10 : 20) + (v[1] === nothing ? 1 : 2)), Int64(3)),
    ("splat_any_unset_throws", (n::Int64) -> (v = Vector{Any}(undef, 2); v[2] = n; try; isassigned([v...], 1) ? 1 : 2; catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("splat_union_unset_throws", (n::Int64) -> (v = Vector{Union{Nothing,String}}(undef, 2); v[2] = "a"; try; isassigned([v...], 1) ? 1 : 2; catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("splat_ref_unset_throws", (n::Int64) -> (v = Vector{String}(undef, 2); v[2] = "a"; try; length([v...]); catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("splat_assigned", (n::Int64) -> (v = Any[nothing, n]; w = [v...]; (isassigned(w, 1) ? 10 : 20) + (w[2] === n ? 1 : 2)), Int64(3)),
    # a splat behind a prefix, `[x, v...]`, and `Core.tuple(v...)` read each copied slot alike (on
    # 0ebf6352 the prefixed splat of an unset slot answered isassigned 2 and length 3, native UndefRefError)
    ("splat_prefix_any_unset_throws", (n::Int64) -> (v = Vector{Any}(undef, 2); v[2] = n; try; isassigned([nothing, v...], 2) ? 1 : 2; catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("splat_prefix_ref_unset_throws", (n::Int64) -> (v = Vector{String}(undef, 2); v[2] = "a"; try; length(["x", v...]); catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("splat_prefix_assigned", (n::Int64) -> (v = ["ab", "c"]; w = ["x", v...]; ncodeunits(w[n - 1]) + length(w)), Int64(3)),
    ("tuple_splat_ref_unset_throws", (n::Int64) -> (v = Vector{String}(undef, 2); v[2] = "a"; try; _sm_utup(v, n); catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("tuple_splat_ref_assigned", (n::Int64) -> (v = ["ab", "c"]; _sm_utup(v, n)), Int64(3)),
    # a field `new` always sets is defined, its null `nothing` (isdefined_tfunc, jl_f_isdefined)
    ("union_field_set_isdefined", (n::Int64) -> (m = _SmUD(n > 0 ? nothing : "a"); isdefined(m, :x) ? 1 : 2), Int64(3)),
    ("runtime_name_unset_throws", (n::Int64) -> (m = _SmUR(); s = n > 0 ? :b : :a; try; getfield(m, s); 1; catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    # an inline struct with a pointer field (Some{String}, a struct holding a String,
    # Tuple{Int64,String}) is `#undef` until stored: isassigned is false and a read throws
    # UndefRefError (dev/AUDIT.md A18B1, measured on 0bc84e05: isassigned of an unset slot answered
    # 11, native 21, isdefined of an unset field 1, native 2, a grown slot 11, native 12, a splat's
    # length 5, native -1, and every read of an unset slot or field trapped on the null, native -1;
    # on 52c0a9bd isassigned answered as native, the reads trapped too)
    ("inline_ptr_some_isassigned", (n::Int64) -> (v = Vector{Some{String}}(undef, 2); v[2] = Some("a"); (isassigned(v, n - 2) ? 10 : 20) + (isassigned(v, 2) ? 1 : 2)), Int64(3)),
    ("inline_ptr_some_unset_read_throws", (n::Int64) -> (v = Vector{Some{String}}(undef, 2); v[2] = Some("ab"); try; _sm_ulen(v[n - 2].value); catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("inline_ptr_some_set_read", (n::Int64) -> (v = Vector{Some{String}}(undef, 2); v[2] = Some("ab"); try; _sm_ulen(v[n - 1].value); catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("inline_ptr_struct_isassigned", (n::Int64) -> (v = Vector{_SmUP}(undef, 2); v[2] = _SmUP("a"); (isassigned(v, n - 2) ? 10 : 20) + (isassigned(v, 2) ? 1 : 2)), Int64(3)),
    ("inline_ptr_struct_unset_read_throws", (n::Int64) -> (v = Vector{_SmUP}(undef, 2); v[2] = _SmUP("ab"); try; _sm_ulen(v[n - 2].s); catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("inline_ptr_tuple_isassigned", (n::Int64) -> (v = Vector{Tuple{Int64,String}}(undef, 2); v[2] = (n, "a"); (isassigned(v, n - 2) ? 10 : 20) + (isassigned(v, 2) ? 1 : 2)), Int64(3)),
    ("inline_ptr_tuple_unset_read_throws", (n::Int64) -> (v = Vector{Tuple{Int64,String}}(undef, 2); v[2] = (n, "ab"); try; _sm_ulen(v[n - 2][2]); catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("inline_ptr_union_nothing_unset", (n::Int64) -> (v = Vector{Union{Nothing,Some{String}}}(undef, 2); v[2] = nothing; (isassigned(v, n - 2) ? 10 : 20) + (isassigned(v, 2) ? 1 : 2) + (v[n - 1] === nothing ? 100 : 200)), Int64(3)),
    ("inline_ptr_union_unset_read_throws", (n::Int64) -> (v = Vector{Union{Nothing,Some{String}}}(undef, 2); v[2] = nothing; try; v[n - 2] === nothing ? 1 : 2; catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("inline_ptr_field_isdefined", (n::Int64) -> (m = _SmUF(); isdefined(m, :p) ? 1 : 2 + 0n), Int64(3)),
    ("inline_ptr_field_unset_read_throws", (n::Int64) -> (m = _SmUF(); try; _sm_ulen(m.p.value) + n; catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("inline_ptr_field_set", (n::Int64) -> (m = _SmUF(); m.p = Some("abc"); (isdefined(m, :p) ? 10 : 20) + _sm_ulen(m.p.value)), Int64(3)),
    ("inline_ptr_grown_unset", (n::Int64) -> (v = [Some("a"), Some("b")]; resize!(v, 1); resize!(v, 2); (isassigned(v, n - 2) ? 10 : 20) + (isassigned(v, 2) ? 1 : 2)), Int64(3)),
    ("inline_ptr_splat_unset_throws", (n::Int64) -> (v = Vector{Some{String}}(undef, 2); v[2] = Some("a"); try; length([v...]) + n; catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    # a slot whose abstract type admits no `nothing` (Number) keeps its null as `#undef`
    ("number_unset_read_throws", (n::Int64) -> (v = Vector{Number}(undef, 2); v[2] = n; try; _sm_ua_h(v[n - 2]); catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("number_isassigned", (n::Int64) -> (v = Vector{Number}(undef, 2); v[2] = n; (isassigned(v, 1) ? 10 : 20) + (isassigned(v, 2) ? 1 : 2)), Int64(3)),
    # a constant's unset slot (dev/AUDIT.md A18B3, measured on 0bc84e05: a Dict{Int,Any}'s unoccupied
    # vals slot answered isassigned 1 and read `nothing`, native 2 and UndefRefError; a Vector
    # constant with an unset slot raised an internal error and a Memory one rejected)
    ("const_dict_vals_isassigned", (n::Int64) -> (isassigned(_SmUDict.vals, n) ? 1 : 2), Int64(findfirst(==(0x00), _SmUDict.slots))),
    ("const_dict_vals_read_throws", (n::Int64) -> (try; _sm_ua_h(_SmUDict.vals[n]); catch e; e isa UndefRefError ? -1 : -2; end), Int64(findfirst(==(0x00), _SmUDict.slots))),
    ("const_dict_union_vals_isassigned", (n::Int64) -> (isassigned(_SmUDictU.vals, n) ? 1 : 2), Int64(findfirst(==(0x00), _SmUDictU.slots))),
    ("const_dict_get", (n::Int64) -> (get(_SmUDict, n - 2, 0)::Int64), Int64(3)),
    # (dev/AUDIT.md A18E3: 16 on 0bc84e05, native 1)
    ("const_dict_vals_count_assigned", (n::Int64) -> count(i -> isassigned(_SmUDict.vals, i), eachindex(_SmUDict.vals)) + 0n, Int64(3)),
    ("const_vector_isassigned", (n::Int64) -> ((isassigned(_SmUVecA, n - 1) ? 10 : 20) + (isassigned(_SmUVecA, n) ? 1 : 2)), Int64(3)),
    ("const_vector_read_throws", (n::Int64) -> (try; _sm_ua_h(_SmUVecA[n - 1]); catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("const_vector_values", (n::Int64) -> ((_SmUVecA[n - 2]::Int64) + (_SmUVecA[n] === nothing ? 100 : 0)), Int64(3)),
    ("const_vector_ref_read_throws", (n::Int64) -> (try; ncodeunits(_SmUVecS[n - 2]); catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
    ("const_memory_unset", (n::Int64) -> ((isassigned(_SmUMemA, n - 2) ? 10 : 20) + (_SmUMemA[n - 1]::Int64)), Int64(3)),
])
# A MemoryRef passed through `inferencebarrier`: memoryrefget and memoryrefset! read the element
# type from the reference's own type (memoryref_eltype, never a guessed Int32 element, A17E1), and
# an Int64 element read into a statement typed Any is boxed under its own class (measured on
# 52c0a9bd: a WasmInternalError, the box with no source type; native 1)
_g("memoryref_barrier", Any[
    ("memoryrefget_erased_any", (n::Int64) -> (v = Any[n, 2]; r = Base.inferencebarrier(Core.memoryrefnew(v.ref.mem)); Core.memoryrefget(r, :not_atomic, true) === n ? 1 : 2), Int64(3)),
    ("memoryrefget_erased_int", (n::Int64) -> (v = [n, 2]; r = Base.inferencebarrier(Core.memoryrefnew(v.ref.mem)); Core.memoryrefget(r, :not_atomic, true) === n ? 1 : 2), Int64(3)),
    ("memoryrefset_erased_any", (n::Int64) -> (v = Any[1, 2]; r = Base.inferencebarrier(Core.memoryrefnew(v.ref.mem)); Core.memoryrefset!(r, n, :not_atomic, true); v[1] === n ? 1 : 2), Int64(3)),
])
# A pointer slot whose type admits `nothing` held in a host reference (a Union{Nothing,Function},
# an externref) has no undefined value to tell `#undef` from `nothing`: its allocation rejects at
# its statement (dev/AUDIT.md A18E4: an unlocated internal error at type registration on 0bc84e05;
# the representation, anyref with the extern bridges, is on dev/MARCH.md 13.17)
@noinline _sm_uh(x) = x === nothing ? 1 : 2
_xf("undef_host_reference", Any[
    ("function_union_isassigned", (n::Int64) -> (v = Vector{Union{Nothing,Function}}(undef, 2); v[1] = nothing; (isassigned(v, 1) ? 10 : 20) + (isassigned(v, 2) ? 1 : 2)), Int64(3)),
    ("function_union_unset_read_throws", (n::Int64) -> (v = Vector{Union{Nothing,Function}}(undef, 2); v[1] = nothing; try; _sm_uh(v[n - 1]); catch e; e isa UndefRefError ? -1 : -2; end), Int64(3)),
])
# A primitive type wider than any register (a 128-bit one that is no Int128) has no
# representation: it rejects at its statement (dev/AUDIT.md A16B5: an unlocated error)
primitive type _SmP128 128 end
_xf("wide_primitive", Any[
    ("bitcast_p128", (n::Int64) -> (x = Core.bitcast(_SmP128, Int128(n)); Int64(Core.bitcast(Int128, x))), Int64(3)),
])
# A Float32 stored byte-wise through a pointer into a byte vector and read back: its bits cut
# from an integer register (emit_bitcast!)
_g("pointer_float_bytes", Any[
    ("float32_store_load", (n::Int64) -> (v = zeros(UInt8, 8); GC.@preserve v unsafe_store!(Ptr{Float32}(pointer(v)), Float32(n) + 0.5f0); GC.@preserve v Float64(unsafe_load(Ptr{Float32}(pointer(v))))), Int64(3)),
])
# A dynamic call whose every method takes one number class at a slot: the dispatch slot carries
# its register (the one width rule), a narrow integer, an enum; a Float16 is no faithful value
@noinline _sm_s8(x::Int8, y::Int64) = Int64(x) + y
@noinline _sm_s8(x::Int8, y::Float64) = Int64(x) + 2 * Int64(round(y))
@enum _SmCol _sm_red = 1 _sm_green = 2
@noinline _sm_se(c::_SmCol, y::Int64) = Int64(Int(c)) + y
@noinline _sm_se(c::_SmCol, y::Float64) = Int64(Int(c)) * 10 + Int64(round(y))
@noinline _sm_sf(x::Float16, y::Int64) = Float64(x) + y
@noinline _sm_sf(x::Float16, y::Float64) = Float64(x) * y
_g("dispatch_slot_registers", Any[
    ("int8_slot", (n::Int64) -> (v = Any[n, 2.5]; _sm_s8(Int8(n), v[1]) + _sm_s8(Int8(n), v[2])), Int64(3)),
    ("enum_slot", (n::Int64) -> (v = Any[n, 2.5]; _sm_se(_sm_green, v[1]) + _sm_se(_sm_red, v[2])), Int64(3)),
])
# a Float16 is no faithful value (its fpext rejects at its statement), at a dispatch slot too
_xf("dispatch_slot_float16", Any[
    ("float16_slot", (n::Int64) -> (v = Any[n, 2.5]; _sm_sf(Float16(1.5), v[1]) + _sm_sf(Float16(2.0), v[2])), Int64(3)),
])
# An intrinsic splatted over a vector runs as itself: `add_int` over Float64 elements adds their
# bits, never their values, which no float opcode does: it rejects at its statement (native NaN)
_xf("reduce_intrinsic_kind", Any[
    ("add_int_over_floats", (n::Int64) -> (v = [1.0, Float64(n)]; Core.Intrinsics.add_int(v...)), Int64(3)),
])
# A partially initialized object a handler may read before its fields are stored: it reaches the
# handler through an upsilon, a use before the stores, and the definite-initialization proof
# (which follows the body's CFG, an Enter's catch edge included) fails, so the %new rejects at its
# statement (a field read on that path has no defined value natively)
mutable struct _SmPN; a::Int64; b::Int64; _SmPN() = new(); end
@noinline _sm_pn_throw(n::Int64) = n > 5 ? error("big") : n
_xf("partial_new_handler_read", Any[
    ("handler_reads_unstored_field", (n::Int64) -> (o = _SmPN(); try; o.a = _sm_pn_throw(n); o.b = 2; catch; return o.b; end; o.a + o.b), Int64(3)),
])
# Two structurally equal self-referential structs are one wasm type (iso-recursive
# canonicalization): the builder gives them one index, so an isa tells them by classId
# (dev/AUDIT.md A5E4 = A5B3: two indices for one type, and `ref.test` answered 1 where native
# answers 2)
mutable struct _SmLA; next::Union{Nothing,_SmLA}; v::Int64; end
mutable struct _SmLB; next::Union{Nothing,_SmLB}; v::Int64; end
_g("isomorphic_recursive_classes", Any[
    ("isa_other_class", (n::Int64) -> (xs = Any[_SmLA(nothing, n), _SmLB(nothing, n)]; xs[n - 1] isa _SmLA ? 1 : 2), Int64(3)),
    ("isa_own_class", (n::Int64) -> (xs = Any[_SmLA(nothing, n), _SmLB(nothing, n)]; xs[n - 2] isa _SmLA ? 1 : 2), Int64(3)),
    ("field_through_other", (n::Int64) -> (b = _SmLB(_SmLB(nothing, n), 7); a = _SmLA(nothing, 1); b.next.v + a.v), Int64(3)),
])
# A class test reads the classId, as dart's emitIsTest does: a struct's wasm type index is a
# runtime type other classes may share, and which of them are registered when an isa compiles
# depends on the order bodies compile (dev/AUDIT.md A6B1 = A6P2: a bare ref.test answered 1
# where native answers 2, for one-field structs and for recursive ones, in either order)
struct _SmPA; x::Int64; end
struct _SmPB; x::Int64; end
@noinline _sm_mkpb(n::Int64) = Any[_SmPB(n)]
@noinline _sm_mkpa(n::Int64) = Any[_SmPA(n)]
@noinline _sm_isla(@nospecialize(x)) = x isa _SmLA ? 1 : 2
@noinline _sm_mklb(n::Int64) = (v = Any[nothing]; v[1] = _SmLB(nothing, n); v[1])
_g("class_test_any_order", Any[
    # a closure value is not its captured-fields struct: its header's classId is its class
    # (dev/AUDIT.md A7E2: native 16, wasm 26)
    ("closure_isa_own_type", (n::Int64) -> (k = n; c = x -> x + k; g = _sm_dh(c)[]; (g isa typeof(c) ? 10 : 20) + g(n)::Int64), Int64(3)),
    # a closure row taking a String's CodeUnits, a bare array (A7C2: it never matched, native 1, wasm 2)
    ("closure_codeunits_row", (n::Int64) -> (k = n; h(x::Base.CodeUnits{UInt8,String}) = 1 + 0k; h(x) = 2 + 0k; f = _sm_dh(h)[]; f(_sm_dh(codeunits("ab"))[])::Int64), Int64(3)),
    ("isa_before_sharer", (n::Int64) -> _sm_mkpb(n)[1] isa _SmPA ? 1 : 2, Int64(3)),
    ("isa_both_orders", (n::Int64) -> (a = _sm_mkpa(n)[1] isa _SmPB ? 10 : 20; a + (_sm_mkpb(n)[1] isa _SmPA ? 1 : 2)), Int64(3)),
    ("recursive_isa_in_callee", (n::Int64) -> _sm_isla(_sm_mklb(n)), Int64(3)),
])
# isa against `Type{X}` of an erased value, as Julia's emit_isa tests it: X's one type object
# by identity where its values are pointer-unique (jl_pointer_egal); any other test that meets
# `Type{…}` is type equality at run time (jl_isa), which rejects at its statement (dev/AUDIT.md
# A5E2: the type-object arm kept a kind only when the kind is under T, so it answered 2 and -7)
_g("type_isa", Any[
    ("type_identity_isa", (n::Int64) -> (v = Any[Int64, 2.5]; v[n] isa Type{Int64} ? 1 : 2), Int64(1)),
    ("type_identity_isa_other_value", (n::Int64) -> (v = Any[Int64, 2.5]; v[n] isa Type{Int64} ? 1 : 2), Int64(2)),
    ("type_identity_isa_other_type", (n::Int64) -> (v = Any[Float64, Int64]; v[n] isa Type{Int64} ? 1 : 2), Int64(1)),
    ("type_identity_typeassert", (n::Int64) -> (v = Any[Int64, 2.5]; try; (v[n]::Type{Int64}) === Int64 ? 1 : 3; catch; -7; end), Int64(1)),
    # Type{Union{}} is tested as typeof(Union{}), as emit_isa swaps it first (A6B8)
    ("type_bottom_isa", (n::Int64) -> (v = Any[Union{}, Int64]; v[n - 2] isa Type{Union{}} ? 1 : 2), Int64(3)),
    ("type_bottom_isa_other", (n::Int64) -> (v = Any[Union{}, Int64]; v[n - 1] isa Type{Union{}} ? 1 : 2), Int64(3)),
    ("type_identity_typeassert_throws", (n::Int64) -> (v = Any[Int64, 2.5]; try; (v[n]::Type{Int64}) === Int64 ? 1 : 3; catch e; e isa TypeError ? -7 : -8; end), Int64(2)),
])
_xf("type_isa_equality", Any[
    ("type_or_nothing_isa", (n::Int64) -> (v = Any[Int64, 2.5]; v[n] isa Union{Nothing,Type{Int64}} ? 1 : 2), Int64(1)),
])
# A closure entry tests a type-object argument as isa does (emit_type_object_test!): a
# TypeVar first, whose `$kind` is never written and read as DataType's (dev/AUDIT.md A5B1: a
# TypeVar passed the DataType row, and a TypeVar row read a class header it lacks, native 22,
# wasm trap)
const _SM_TV = TypeVar(:T)
const _SM_CT = (Int64, UInt8)
struct _SmHb; v::Int64; end
const _SM_HV = Any[_SmHb, 1]
# a type object a constant mutable struct's field holds (A12C3; the Memory and cycle arms are
# pinned on the plan in test/dispatch_method_error.jl: neither constant compiles yet)
struct _SmHr; v::Int64; end
const _SM_HR = Ref{Any}(_SmHr)
_g("type_object_rows", Any[
    ("typevar_row", (n::Int64) -> (k = n; g = _sm_dh(x -> (x isa TypeVar ? 20 : 10) + k)[]; n == 1 ? g(DataType[Int64][1])::Int64 : g(TypeVar[_SM_TV][1])::Int64), Int64(2)),
    # a closure row taking Type{Int64}: Int64's identity (A6B4 = A6C6)
    ("type_identity_row", (n::Int64) -> (k = n; h(::Type{Int64}) = 1 + 0k; h(x) = 2 + 0k; f = _sm_dh(h)[]; f(_sm_dh(Int64)[])::Int64 + 10 * f(_sm_dh(n)[])::Int64), Int64(3)),
    ("datatype_row", (n::Int64) -> (k = n; g = _sm_dh(x -> (x isa TypeVar ? 20 : 10) + k)[]; n == 1 ? g(DataType[Int64][1])::Int64 : g(TypeVar[_SM_TV][1])::Int64), Int64(1)),
    # a type object a `typeof` makes is a candidate of an erased position: the method on
    # `Type{S}` has its row (A10C1, A10P2: native 1, wasm 2 or a trap)
    ("typeof_made_type_row", (n::Int64) -> (k = n; h(::Type{S}) where {S} = 1 + 0k; h(x) = 2 + 0k; g = _sm_dh(h)[]; g(typeof(_sm_dh(_Pt(n, 2))[]))::Int64), Int64(3)),
    ("typeof_made_unsigned_row", (n::Int64) -> (k = n; h(::Type{S}) where {S<:Unsigned} = 1 + 0k; h(x) = 2 + 0k; g = _sm_dh(h)[]; g(typeof(_sm_dh(0x03)[]))::Int64), Int64(3)),
    # a type object a constant tuple holds, read out at run time (A10C1)
    ("constant_tuple_type_row", (n::Int64) -> (k = n; h(::Type{S}) where {S<:Unsigned} = 1 + 0k; h(x) = 2 + 0k; g = _sm_dh(h)[]; g(_SM_CT[n - 1])::Int64), Int64(3)),
    # a type object a mutable constant holds, and the kind a `typeof` of a type object returns
    # (A11C1: native 1, wasm 2 or a trap)
    ("mutable_constant_type_row", (n::Int64) -> (k = n; h(::Type{S}) where {S} = 1 + 0k; h(x) = 2 + 0k; g = _sm_dh(h)[]; g(_SM_HV[n - 2])::Int64), Int64(3)),
    ("typeof_kind_row", (n::Int64) -> (k = n; h(::Type{S}) where {S} = 1 + 0k; h(x) = 2 + 0k; g = _sm_dh(h)[]; g(typeof(_sm_dh(Int64)[]))::Int64), Int64(3)),
    ("ref_field_type_row", (n::Int64) -> (k = n; h(::Type{S}) where {S} = 1 + 0k; h(x) = 2 + 0k; g = _sm_dh(h)[]; g(_SM_HR[])::Int64), Int64(3)),
])
# `===` on closures compares their type and captures, as jl_egal compares an immutable struct,
# whichever of WT's two representations each operand is (its captured-fields context, or the
# closure object holding it once erased; dev/AUDIT.md A7S1: two equal closures answered 2, and
# two erasures of one closure trapped)
_g("closure_egal", Any[
    ("equal_captures_erased", (n::Int64) -> (mk = k -> (y -> y + k); a = _sm_dh(mk(n))[]; b = _sm_dh(mk(n))[]; a === b ? 1 : 2), Int64(3)),
    ("one_closure_erased_twice", (n::Int64) -> (c = x -> x + n; a = _sm_dh(c)[]; b = _sm_dh(c)[]; a(1); a === b ? 1 : 2), Int64(3)),
    ("other_captures_erased", (n::Int64) -> (mk = k -> (y -> y + k); a = _sm_dh(mk(n))[]; b = _sm_dh(mk(n + 1))[]; a === b ? 1 : 2), Int64(3)),
    ("equal_captures_static", (n::Int64) -> (mk = k -> (y -> y + k); mk(n) === mk(n) ? 1 : 2), Int64(3)),
])
# `===`, typeof and isa over closures erased in either representation (dev/AUDIT.md A10B1: two
# functions used as values share the dummy context and answered equal, native 18, wasm 118;
# A10E2: a closure whose context registered after the egal function was built, native 1,
# wasm 2; A10C2: typeof of an erased Base.Fix2 trapped; isa(x, Base.Fix2) of its context
# answered 0, native 1)
_sm_cv_a(x::Int64) = x + 3
_sm_cv_m(x::Int64) = x * 4
@noinline _sm_cv_mk(n::Int64) = Ref{Any}(y -> y + n)[]
mutable struct _SmMC <: Function; n::Int64; end
(m::_SmMC)(x::Int64) = x + m.n
@noinline _sm_idmc(m::_SmMC) = m
@noinline _sm_mkmc(m::_SmMC) = () -> m.n
@noinline _sm_newmc(n::Int64) = _SmMC(n)
@noinline _sm_holdmc(m::_SmMC) = () -> m
struct _SmHF; f::Base.Fix2{typeof(+),Int64}; end
_sm_cv_k(::Base.Fix2) = 1
_sm_cv_k(x) = 2
_g("closure_values", Any[
    ("two_functions_egal", (n::Int64) -> (fs = Any[_sm_cv_a, _sm_cv_m]; s = (fs[1](n))::Int64 + (fs[2](n))::Int64; fs[1] === fs[2] ? s + 100 : s), Int64(3)),
    ("one_function_egal", (n::Int64) -> (fs = Any[_sm_cv_a, _sm_cv_a]; s = (fs[1](n))::Int64; fs[1] === fs[2] ? s + 100 : s), Int64(3)),
    ("closures_built_apart_egal", (n::Int64) -> (a = _sm_cv_mk(n); b = _sm_cv_mk(n); a === b ? 1 : 2), Int64(3)),
    ("closures_other_captures_egal", (n::Int64) -> (a = _sm_cv_mk(n); b = _sm_cv_mk(n + 1); a === b ? 1 : 2), Int64(3)),
    ("typeof_erased_fix2", (n::Int64) -> (v = Any[Base.Fix2(+, n), n]; typeof(v[1]) === Base.Fix2{typeof(+),Int64} ? 1 : 2), Int64(3)),
    ("isa_erased_fix2", (n::Int64) -> _sm_cv_k(_sm_dh(Base.Fix2(+, n))[]), Int64(3)),
    ("typeof_erased_fix2_held", (n::Int64) -> typeof(_sm_dh(Base.Fix2(+, n))[]) === Base.Fix2{typeof(+),Int64} ? 1 : 2, Int64(3)),
    # a mutable callable is compared by identity (A10B2: its fields were compared, native 2, wasm 1)
    ("mutable_callables_egal", (n::Int64) -> (a = _sm_dh(_SmMC(n))[]; b = _sm_dh(_SmMC(n))[]; a === b ? 1 : 2), Int64(3)),
    ("mutable_callable_self_egal", (n::Int64) -> (a = _sm_dh(_SmMC(n))[]; b = Any[a]; a === b[1] ? 1 : 2), Int64(3)),
    # a closure type a struct field registers before its own value is built (A10P5, A10E8)
    ("closure_in_field", (n::Int64) -> (h = _SmHF(Base.Fix2(+, n)); v = Any[h.f]; (v[1])(1)::Int64), Int64(3)),
    # a closure captured by another, compared with `===`: the capture is held as its object
    # (A10E3: a cast of the object to its context trapped where native answers 1)
    ("captured_closure_egal", (n::Int64) -> (c = x -> x + n; f = _sm_dh(c)[]; f(1); mk = () -> (y -> c(y)); a = _sm_dh(mk())[]; b = _sm_dh(mk())[]; a === b ? 1 : 2), Int64(3)),
    # a closure passed to an erased closure call: the callee, a capture-less closure the
    # program passes on as a literal, has its row, and the argument arrives as its object,
    # whose context the body takes (MARCH 13.17 A7S1 stage 4: native 4, wasm trap)
    ("closure_argument_erased_call", (n::Int64) -> (k = n; c = x -> x + k; f = _sm_dh(y -> y(1))[]; f(c)::Int64), Int64(3)),
    ("fix2_argument_erased_call", (n::Int64) -> (f = _sm_dh(y -> y(1))[]; f(Base.Fix2(+, n))::Int64), Int64(3)),
    # a closure an erased closure returns is its object at the entry's result (A11E1: the bare
    # context answered `isa Function` 2 where native answers 1)
    ("closure_returned_erased", (n::Int64) -> (h = Any[y -> (z -> z + y)][1]; g = h(n); g isa Function ? 1 : 2), Int64(3)),
    # a mutable callable is one object with identity, whichever form it is held in (A11B1,
    # A11E3: native 1, wasm 2), and its fields are its own (A11C5: an invalid module)
    ("mutable_callable_identity", (n::Int64) -> (m = _SmMC(n); _sm_idmc(m) === m ? 1 : 2), Int64(3)),
    ("mutable_callable_captured", (n::Int64) -> (m = _SmMC(n); _sm_mkmc(m) === _sm_mkmc(m) ? 1 : 2), Int64(3)),
    ("mutable_callable_field_write", (n::Int64) -> (m = _sm_newmc(n); m.n += 1; m(1)), Int64(3)),
    ("mutable_callable_held_in_closure", (n::Int64) -> (m = _SmMC(n); h = _sm_holdmc(m); h() === m ? 1 : 2), Int64(3)),
])
# a dynamic call with no method for its argument's class throws Julia's MethodError, `f` the
# callee and `args` the tuple of the arguments' classes, which the program can catch: through
# Julia's own union split (Core.throw_methoderror), a closure's vtable entry, and WT's class
# switch (MARCH 13.17 A3S1, formal(dev/formal/ClassIdSwitch.tla): each trapped, native -1)
_sm_me_q(x::Int64) = 1
_sm_me_r(x::Int64, y::Int64) = 1
_sm_me_5(x::Int64) = 1
_sm_me_5(x::String) = 2
_sm_me_5(x::Int32) = 3
_sm_me_5(x::UInt8) = 4
_sm_me_5(x::Char) = 5
_g("method_error", Any[
    ("union_split_caught", (n::Int64) -> (v = Any[n, 1.5]; try; _sm_me_q(v[n])::Int64; catch e; e isa MethodError ? -1 : -2; end), Int64(2)),
    # an erased closure called with `nothing`, which no method takes: its MethodError carries the
    # nothing, taken as the args tuple holds it, never unboxed (the null trapped)
    ("closure_nothing_no_method", (n::Int64) -> (k = n; h(x::Int64) = x + k; g = _sm_dh(h)[]; try; g(_sm_dh(nothing)[])::Int64; catch e; (e isa MethodError && e.args === (nothing,)) ? -1 : -2; end), Int64(3)),
    ("union_split_fields", (n::Int64) -> (v = Any[n, 1.5]; try; _sm_me_q(v[n])::Int64; catch e; (e isa MethodError && e.f === _sm_me_q && e.args isa Tuple{Float64} && e.args[1] == 1.5) ? 1 : 2; end), Int64(2)),
    ("union_split_string_args", (n::Int64) -> (v = Any[n, "s"]; try; _sm_me_q(v[n])::Int64; catch e; (e isa MethodError && typeof(e.args) === Tuple{String} && e.args[1] == "s") ? 1 : 2; end), Int64(2)),
    ("union_split_two_args", (n::Int64) -> (v = Any[n, 1.5]; try; _sm_me_r(n, v[n])::Int64; catch e; (e isa MethodError && e.args === (n, 1.5)) ? 1 : 2; end), Int64(2)),
    ("closure_entry_caught", (n::Int64) -> (k = n; f = _sm_dh(x::Int64 -> x + k)[]; f(1); try; f(_sm_dh(1.5)[])::Int64; catch e; e isa MethodError ? -1 : -2; end), Int64(3)),
    ("closure_entry_fields", (n::Int64) -> (k = n; g = x::Int64 -> x + k; f = _sm_dh(g)[]; f(1); try; f(_sm_dh(1.5)[])::Int64; catch e; (e isa MethodError && e.f === g && e.args === (1.5,)) ? 1 : 2; end), Int64(3)),
    # `nothing` reaching a call with no method: its class is Nothing's (A11E2, A11C4: the class
    # read trapped on the null; a tuple holding `nothing` raised a WasmInternalError)
    ("nothing_union_split", (n::Int64) -> (x = n > 0 ? n : nothing; try; _sm_me_q(x)::Int64; catch e; e isa MethodError ? -1 : -2; end), Int64(-1)),
    ("nothing_in_any_vector", (n::Int64) -> (v = Any[n, nothing]; try; _sm_me_q(v[n])::Int64; catch e; e isa MethodError ? -1 : -2; end), Int64(2)),
    # an exception a Base body raises, caught and passed to a call with no method for it
    ("caught_exception_no_method", (n::Int64) -> (e = try; div(n, n - 3); catch err; err; end; try; _sm_me_q(e)::Int64; catch e2; e2 isa MethodError ? -1 : -2; end), Int64(3)),
    # an exception WT's lowering instantiates (a MethodError arm's, an Int32 division's
    # DivideError), caught, reaching a union-split call with no method for it: the class is in the
    # one set (LOWERING_INSTANTIATED_CLASSES), so its MethodError tuple is numbered (it was not:
    # unreachable, where native answers -1)
    ("caught_methoderror_union_split", (n::Int64) -> (y = n > 0 ? n : (try; _sm_me_q(Base.inferencebarrier("s")); catch e; e::Exception; end); try; _sm_me_q(y)::Int64; catch e2; e2 isa MethodError ? -1 : -2; end), Int64(-1)),
    ("caught_divideerror_union_split", (n::Int64) -> (y = n > 0 ? n : (try; Int64(div(Int32(n), Int32(n + 1))); catch e; e::Exception; end); try; _sm_me_q(y)::Int64; catch e2; e2 isa MethodError ? -1 : -2; end), Int64(-1)),
    # a Bool a comparison makes, reaching a union-split call with no method for it: its class is
    # in the one class set where it is made (an intrinsic's result), as the numbered set's fixed
    # primitives held it before
    ("bool_union_split", (n::Int64) -> (x = n > 0 ? n : (n < -5); try; _sm_me_q(x)::Int64; catch e; (e isa MethodError && e.args === (false,)) ? -1 : -2; end), Int64(-1)),
    ("class_switch_caught", (n::Int64) -> (v = Any[n, "s", Int32(2), 0x01, 'c', 1.5]; s = _sm_me_5(v[1])::Int64 + _sm_me_5(v[2])::Int64 + _sm_me_5(v[3])::Int64 + _sm_me_5(v[4])::Int64 + _sm_me_5(v[5])::Int64; try; _sm_me_5(v[n])::Int64; catch e; (e isa MethodError && e.args === (1.5,)) ? s + 100 : s; end), Int64(6)),
])
# a String's CodeUnits is the String's byte array wherever it is held: a tuple field, a struct
# field, any value narrowed to a method's parameter (A8C4: a tuple field laid out as a class
# struct trapped, and the narrowing read it as a String; native 100, wasm trap)
_sm_cu_q(::Base.CodeUnits{UInt8,String}) = 100
_sm_cu_q(::Vector{Int64}) = 1
_sm_cu_q(::Int64) = 2
_sm_cu_q(::Float64) = 3
struct _SmCU; c::Base.CodeUnits{UInt8,String}; n::Int64; end
_g("codeunits_values", Any[
    ("selector_codeunits", (n::Int64) -> (v = Any[codeunits("ab"), [n], n, 1.0]; _sm_cu_q(v[1])::Int64), Int64(3)),
    ("selector_each_class", (n::Int64) -> (v = Any[codeunits("ab"), [n], n, 1.0]; _sm_cu_q(v[n - 1])::Int64 + 10 * _sm_cu_q(v[n])::Int64 + 100 * _sm_cu_q(v[n + 1])::Int64), Int64(2)),
    ("struct_field_codeunits", (n::Int64) -> (v = Any[_SmCU(codeunits("abc"), n)]; length((v[1]::_SmCU).c) + n), Int64(3)),
])
# a tuple built at run time from a value of any class: its type is known only at run time, so
# it rejects at its statement (it raised a WasmInternalError registering the abstract `Tuple`)
_xf("abstract_tuple_values", Any[
    ("splat_any_joins_fixed", (n::Int64) -> (u = n == 3 ? (n,) : Core.tuple(_sm_dh([n, 2])[][]...); u[1]), Int64(3)),
])
# getfield(x::T, f) with a Symbol known only at run time (a dispatch candidate of
# getproperty(x, f::Symbol)): jl_f_getfield compares f with each field name in order and reads
# that field, else throws FieldError(T, f); a type with no fields, or a Tuple (integer field
# names), always throws. Until 2026-09-29 it rejected "getfield call shape not lowerable".
struct _SmMix; a::Int64; b::Float64; s::String; end
_sm_rn_name(x) = x > 2 ? :x : x > 0 ? :y : :z
_g("getfield_runtime_name", Any[
    ("struct_first_field", (x::Int64) -> getfield(_Pt(x, 20), _sm_rn_name(x))::Int64, Int64(3)),
    ("struct_second_field", (x::Int64) -> getfield(_Pt(x, 20), _sm_rn_name(x))::Int64, Int64(1)),
    ("struct_no_such_field", (x::Int64) -> (try; getfield(_Pt(x, 20), _sm_rn_name(x)); 0; catch e; e isa FieldError && e.field === :z && e.type === _Pt ? 1 : 2; end), Int64(0)),
    ("mixed_fields_boxed", (x::Int64) -> (v = getfield(_SmMix(x, 1.5, "q"), x > 0 ? :b : :a); v isa Float64 ? 1 : 2), Int64(1)),
    ("mixed_fields_boxed_int", (x::Int64) -> (v = getfield(_SmMix(x, 1.5, "q"), x > 0 ? :b : :a); v isa Int64 ? (v::Int64) : -1), Int64(-4)),
    ("string_field", (x::Int64) -> (v = getfield(_SmMix(x, 1.5, "qq"), x > 0 ? :s : :a); v isa String ? ncodeunits(v) : -1), Int64(1)),
    ("primitive_has_no_fields", (x::Int64) -> (try; getfield(UInt64(x), _sm_rn_name(x)); 0; catch e; e isa FieldError && e.type === UInt64 ? 7 : 8; end), Int64(1)),
    ("tuple_names_are_integers", (x::Int64) -> (try; getfield((x, 2), _sm_rn_name(x)); 0; catch e; e isa FieldError ? 1 : 2; end), Int64(3)),
    # a vararg pack indexed by a Symbol is a Tuple read by name: FieldError, not an integer
    # cast of the Symbol (the vararg arm once emitted it as I64 and trapped)
    ("vararg_names_are_integers", (x::Int64) -> (try; _sm_va_getfield(_sm_rn_name(x), x, 2); 0; catch e; e isa FieldError ? 1 : 2; end), Int64(3)),
])
@noinline _sm_va_getfield(s::Symbol, xs...) = getfield(xs, s)
@noinline _sm_iiw_set!(r::Base.RefValue{Int64}, v::Int64) = (r[] = v; nothing)
@noinline _sm_iiw2(x::Int64) = 1
@noinline _sm_iiw2(x::String) = 2
@noinline _sm_iiw3(x::Integer) = Int64(x) + 1
@noinline _sm_dt_getfield(@nospecialize(T::DataType), s::Symbol) = getfield(T, s)
_g("sizeof_values", Any[
    ("sizeof_memory_int64", (n::Int64) -> Core.sizeof(Memory{Int64}(undef, n)), Int64(3)),
    ("sizeof_memory_float32", (n::Int64) -> sizeof(Memory{Float32}(undef, n)), Int64(3)),
    ("sizeof_memory_uint8", (n::Int64) -> Core.sizeof(Memory{UInt8}(undef, n)), Int64(3)),
    ("sizeof_memory_union", (n::Int64) -> Core.sizeof(Memory{Union{Int64,Nothing}}(undef, n)), Int64(3)),
    ("sizeof_memory_any", (n::Int64) -> Core.sizeof(Memory{Any}(undef, n)), Int64(3)),
    ("sizeof_string", (n::Int64) -> sizeof("hé" * string(n)), Int64(3)),
])
_g("memoryref_storage", Any[
    ("union_ref_ptr_stride", (n::Int64) -> _sm_ptr_stride(Union{Int64,Nothing}[1, nothing, 3, 4, 5], n, 8), Int64(3)),
    ("tuple_ref_ptr_stride", (n::Int64) -> _sm_ptr_stride(Tuple{Int64,String}[(1, "a"), (2, "b"), (3, "c"), (4, "d")], n, 16), Int64(3)),
    ("any_ref_ptr_stride", (n::Int64) -> _sm_ptr_stride(Any[1, 2, 3, 4, 5], n, 8), Int64(3)),
    ("i64_ref_ptr_stride", (n::Int64) -> _sm_ptr_stride(collect(1:5), n, 8), Int64(3)),
    ("union_memcopy_offset", (n::Int64) -> (v = Union{Int64,Nothing}[1, nothing, 3, 4, 5]; w = Union{Int64,Nothing}[0, 0, 0, 0, 0, 0]; unsafe_copyto!(memoryref(w.ref, n), memoryref(v.ref, 2), 3); s = 0; for x in w; s = s * 10 + (x === nothing ? 9 : x); end; s), Int64(3)),
    ("any_memcopy_offset", (n::Int64) -> (v = Any[1, "a", 3, 4, 5]; w = Any[0, 0, 0, 0, 0, 0]; unsafe_copyto!(memoryref(w.ref, n), memoryref(v.ref, 2), 3); (w[n] == "a" ? 100 : 0) + (w[n + 1]::Int) * 10 + (w[n + 2]::Int)), Int64(3)),
    ("unset_any_slot", (n::Int64) -> (v = Any[1, 2, 3]; GC.@preserve v Core.Intrinsics.atomic_pointerset(Ptr{Ptr{Cvoid}}(pointer(v)) + (n - 1) * 8, C_NULL, :monotonic); (isassigned(v, n) ? 10 : 0) + (isassigned(v, 1) ? 1 : 0)), Int64(2)),
    ("reshape_mightalias", (n::Int64) -> (v = collect(1:n); m = reshape(v, 2, 2); Int64(Base.mightalias(v, m)) * 10 + Int64(Base.mightalias(v, collect(1:n)))), Int64(4)),
    ("const_vector_identity", (n::Int64) -> (a = _SM_CONST_VEC; b = _SM_CONST_VEC; Int64(a === b)), Int64(0)),
    ("const_vector_mutation", (n::Int64) -> (push!(_SM_CONST_VEC, n); r = _SM_CONST_VEC[end] * 10 + length(_SM_CONST_VEC); pop!(_SM_CONST_VEC); r), Int64(7)),
    ("sizeof_vec_i64", (n::Int64) -> (v = collect(1:n); sizeof(v)), Int64(5)),
    ("sizeof_vec_f32", (n::Int64) -> (v = Float32[1, 2, 3]; sizeof(v) * 10 + n), Int64(1)),
    ("core_sizeof_vec_i64", (n::Int64) -> (v = collect(1:n); Core.sizeof(v)), Int64(5)),
    ("core_sizeof_vec_f32", (n::Int64) -> (v = Float32[1, 2, 3]; Core.sizeof(v) * 10 + n), Int64(1)),
])
# ---- overlays retired for Julia's own bodies (dev/CHARTER.md C3, C6) -------
# Each case is a value a bespoke overlay computed wrong (test/soundness_suspects.jl rows 10,
# 11, 18, 22); Base's own method now compiles in its place.
@noinline _sm_ovstr(x::Int64) = x > 0 ? "héllo" : "abc"
_g("overlays", Any[
    # first/last(::String, n) count characters, not bytes
    ("first_nonascii_ncodeunits", (n::Int64) -> ncodeunits(first(_sm_ovstr(Int64(1)), n)), Int64(2)),
    ("first_nonascii_eq", (n::Int64) -> Int64(first(_sm_ovstr(Int64(1)), n) == "hé"), Int64(2)),
    ("first_past_end", (n::Int64) -> ncodeunits(first(_sm_ovstr(Int64(1)), n)), Int64(10)),
    ("last_nonascii_ncodeunits", (n::Int64) -> ncodeunits(last(_sm_ovstr(Int64(1)), n)), Int64(4)),
    ("last_nonascii_eq", (n::Int64) -> Int64(last(_sm_ovstr(Int64(1)), n) == "éllo"), Int64(4)),
    # mod/rem(::Float64): a zero result takes the divisor's sign (bits compared, not ==)
    ("mod_zero_sign_pos_divisor", (x::Float64) -> reinterpret(Int64, mod(x, 3.0)), -3.0),
    ("mod_zero_sign_neg_divisor", (x::Float64) -> reinterpret(Int64, mod(x, -3.0)), 3.0),
    ("mod_negzero_dividend", (x::Float64) -> reinterpret(Int64, mod(x, 3.0)), -0.0),
    ("mod_large_quotient", (x::Float64) -> reinterpret(Int64, mod(x, 1.41)), 5.4e7),
    ("mod_neg_infinite_divisor", (x::Float64) -> reinterpret(Int64, mod(x, -Inf)), 1.0),
    ("rem_negzero_dividend", (x::Float64) -> reinterpret(Int64, rem(x, 3.0)), -0.0),
    ("rem_large_quotient", (x::Float64) -> reinterpret(Int64, rem(x, 1.41)), -5.4e7),
    # pop!/resize!(::Vector): Base's argument checks throw ArgumentError
    ("pop_empty_argumenterror", (n::Int64) -> (v = collect(1:n); try; pop!(v); 0; catch e; e isa ArgumentError ? 1 : 2; end), Int64(0)),
    ("pop_sequence", (n::Int64) -> (v = collect(1:n); a = pop!(v); b = pop!(v); push!(v, 9); a * 100 + b * 10 + length(v) + sum(v)), Int64(5)),
    ("resize_negative_argumenterror", (n::Int64) -> (v = collect(1:3); try; resize!(v, n); 0; catch e; e isa ArgumentError ? 1 : 2; end), Int64(-1)),
    ("resize_grow", (n::Int64) -> (v = collect(1:3); resize!(v, n); v[n] = 7; length(v) * 100 + v[3] + v[n]), Int64(6)),
    ("resize_shrink", (n::Int64) -> (v = collect(1:6); resize!(v, n); push!(v, 1); length(v) * 100 + sum(v)), Int64(2)),
    ("resize_grow_past_capacity", (n::Int64) -> (v = zeros(10); resize!(v, n); v .= 1; Int64(sum(v))), Int64(100)),
    # Char case mapping and classes beyond Latin-1 read utf8proc's own answers
    ("isletter_greek", (c::Char) -> Int64(isletter(c)), 'λ'),
    ("isletter_cjk", (c::Char) -> Int64(isletter(c)), '中'),
    ("isspace_em_space", (c::Char) -> Int64(isspace(c)), '\u2003'),
    ("textwidth_wide", (c::Char) -> Int64(textwidth(c)), '中'),
    ("isletter_astral", (c::Char) -> Int64(isletter(c)) * 10 + Int64(isspace(c)), '𐐨'),
    ("uppercase_greek", (c::Char) -> Int64(UInt32(uppercase(c))), 'λ'),
    ("lowercase_greek", (c::Char) -> Int64(UInt32(lowercase(c))), 'Σ'),
    ("titlecase_digraph", (c::Char) -> Int64(UInt32(titlecase(c))), 'ǆ'),
    ("isuppercase_greek", (c::Char) -> Int64(isuppercase(c)), 'Σ'),
    ("islowercase_greek", (c::Char) -> Int64(islowercase(c)), 'σ'),
    ("isascii_latin1", (c::Char) -> Int64(isascii(c)), 'é'),
    ("uppercasefirst_nonascii", (n::Int64) -> Int64(uppercasefirst(n > 0 ? "élan" : "x") == "Élan"), Int64(1)),
    ("lowercasefirst_nonascii", (n::Int64) -> Int64(lowercasefirst(n > 0 ? "ÉLAN" : "x") == "éLAN"), Int64(1)),
    ("uppercase_string_sharp_s", (n::Int64) -> ncodeunits(uppercase(n > 0 ? "straße λ" : "x")), Int64(1)),
    # an always-taken `@inbounds` boundscheck branch carries its target's phi values
    ("inbounds_isvalid_substring", (i::Int64) -> Int64(@inbounds isvalid(SubString(i > 0 ? " ab,c " : "xyz", 2, 5), i)), Int64(1)),
    # strip/lstrip/rstrip/chomp return Base's SubString; ==/cmp/startswith compare through memcmp
    ("strip_is_substring", (n::Int64) -> Int64(typeof(strip(n > 0 ? "  héllo \n" : "x")) === SubString{String}), Int64(1)),
    ("strip_offset", (n::Int64) -> strip(n > 0 ? "  héllo \n" : "x").offset, Int64(1)),
    ("strip_eq_string", (n::Int64) -> Int64(strip(n > 0 ? "  héllo \n" : "x") == "héllo"), Int64(1)),
    ("strip_unicode_space", (n::Int64) -> ncodeunits(strip(n > 0 ? "\u00a0x y\u2003" : "x")), Int64(1)),
    ("lstrip_ncodeunits", (n::Int64) -> ncodeunits(lstrip(n > 0 ? "\t héllo " : "x")), Int64(1)),
    ("rstrip_ncodeunits", (n::Int64) -> ncodeunits(rstrip(n > 0 ? "\t héllo \r\n" : "x")), Int64(1)),
    ("chomp_crlf_offset", (n::Int64) -> (c = chomp(n > 0 ? "abc\r\n" : "x"); c.offset * 10 + ncodeunits(c)), Int64(1)),
    ("chop_nonascii", (n::Int64) -> Int64(chop(n > 0 ? "hé" : "x") == "h"), Int64(1)),
    ("chop_head_tail", (n::Int64) -> ncodeunits(chop(n > 0 ? "élan vital" : "x"; head = 1, tail = 1)), Int64(1)),
    ("cmp_strings", (n::Int64) -> cmp(n > 0 ? "abc" : "x", "abd") * 10 + cmp("abd", n > 0 ? "abc" : "x"), Int64(1)),
    ("startswith_substring", (n::Int64) -> Int64(startswith(strip(n > 0 ? " héllo" : "x"), "hé")), Int64(1)),
    ("endswith_nonascii", (n::Int64) -> Int64(endswith(n > 0 ? "vital é" : "x", " é")), Int64(1)),
    # a SubString's codeunits are a window, not the parent's byte array; memchr reads through it
    ("substring_codeunits_findfirst", (n::Int64) -> something(findfirst(==(UInt8(',')), codeunits(strip(n > 0 ? " ab,c " : "x"))), 0), Int64(1)),
    ("substring_occursin", (n::Int64) -> Int64(occursin(",", strip(n > 0 ? " a,b " : "x"))), Int64(1)),
    ("strip_split_join", (n::Int64) -> length(join(split(strip(n > 0 ? "  hello,world,test  " : "x"), ","), "-")), Int64(1)),
])

# The closed world's edges (_closed_world_edge): each edge CC.collectinvokes! follows besides
# :invoke (Compiler typeinfer.jl:1336 on 1.12, :1477 on 1.13), one case per kind. A closure
# built by a `:new` in a separately compiled body and called through an `Any` slot: on 1.13
# Julia's queue collects its body through the `:new` (new_function, :1523), and the dynamic
# call names the same body.
@noinline _sm_mknew(n::Int64) = (x::Int64) -> x + n
@noinline _sm_mknew2(n::Int64) = (x::Int64) -> x * n
# A method called statically and through an abstract slot: the dynamic step makes it a dispatch
# candidate though a static :invoke collected it first, and the :invoke still names it.
abstract type _SmSh end
for k in 1:6
    local S = Symbol(:_SmSh, k)
    @eval struct $S <: _SmSh; v::Int64; end
    @eval @noinline _sm_shar(s::$S) = s.v + $k
end
_g("closed_world_edges", Any[
    ("static_and_dynamic_call_one_method", (n::Int64) -> (xs = _SmSh[_SmSh1(n), _SmSh2(n), _SmSh3(n), _SmSh4(n), _SmSh5(n), _SmSh6(n)]; s = _sm_shar(_SmSh1(n)); for x in xs; s += _sm_shar(x)::Int64; end; s), Int64(3)),
    ("new_closure_called_dynamically", (n::Int64) -> (fs = Any[_sm_mknew(n)]; fs[1](2)::Int64), Int64(3)),
    ("new_closures_two_classes", (n::Int64) -> (fs = Any[_sm_mknew(n), _sm_mknew2(n)]; (fs[1](2)::Int64) * 100 + (fs[2](2)::Int64)), Int64(3)),
])
# The plan is the one consult: an :invoke calls the function of the MethodInstance it names (two
# methods share one specialization's argument types: `invoke` names the less specific one); a
# closure body that is a dispatch candidate is also the target of the :invoke that names it; each
# callable's MethodError comes from its own no-method record (an answer cannot tell a flat record
# apart, the rows coming first: test/dispatch_method_error.jl reads the module).
@noinline _sm_oc(x::Integer) = x + 100
@noinline _sm_oc(x::Int64) = x + 1
@noinline _sm_ncf(x::String) = Int64(1)
@noinline _sm_ncg(x::Int64) = x + 1
@noinline _sm_ncg(x::String) = Int64(2)
# A callable whose methods are overlays, called as a value: the vtable pre-pass asks whether two of
# its rows are ambiguous over the overlay table (wt_methods_ambiguous), and the compile then
# rejects, located, where Julia answers 3: the generic overlay objectid(x::T) enrolled for a type
# object reaches its jl_object_id foreigncall, which has no lowering.
_xf("overlaid_callable_value", Any[
    ("objectid_as_value", (n::Int64) -> (v = Any[n, :a]; fs = Any[objectid]; fs[1](v[2]) == objectid(:a) ? n : -n), Int64(3)),
])
_g("one_consult", Any[
    ("invoke_names_its_method", (n::Int64) -> invoke(_sm_oc, Tuple{Integer}, n) * 1000 + _sm_oc(n), Int64(3)),
    ("closure_candidate_and_invoked", (n::Int64) -> (k = n; g = @noinline((x::Int64) -> x + k); a = g(1); fs = Any[g]; a * 100 + (fs[1](2)::Int64)), Int64(3)),
    ("no_method_record_per_callee", (n::Int64) -> (v = Any[n, "s"]; a = try; _sm_ncf(v[1]); catch e; e isa MethodError ? Int64(-1) : Int64(-2); end; a * 100 + (_sm_ncg(v[1])::Int64)), Int64(3)),
])
# One reader of what a node is (value_type, Julia's argextype): an operand's type is the same for
# every consumer — a literal or constant global edge into a phi, a non-constant global's declared
# type, a field read Julia types narrower than the field (BoundsError's `a::Any` read as the
# Memory{UInt8} it holds), a dynamic call Julia leaves `::Any` (its result is the dispatched
# method's, read at run time, never re-inferred in codegen), and a captured variable a closure the
# creator does not call writes (every body of each captor type joins, BoxJoin.tla).
const _OTR_VEC = [1, 2, 3]
global _otr_typed::Int64 = 5
_otr_mk(n::Int64) = (x = n; w = @noinline(() -> (x = 2.5; nothing)); (w, @noinline(() -> x)))
# a closure writing its own argument into the box (the write typed by the argument's slot type,
# argextype's answer): of the creator's type, so the box stays that type; of another, so it widens
_otr_arg_same(n::Int64) = (x = n; w = @noinline(y -> (x = y; nothing)); w(n + 1); x)
_otr_arg_other(n::Int64) = (x = n; w = @noinline(y -> (x = y; nothing)); w(2.5); v = x; v isa Float64 ? Int64(2 * v) : -1)
# a box write whose value is a call with a type-literal operand (the literal argues as Type{T})
_otr_lit_write(n::Int64) = (x = n; w = @noinline(y -> (x = convert(Int64, y); nothing)); w(Int32(n + 4)); x)
_g("one_type_reader", Any[
    ("literal_phi_edge", (n::Int64) -> (x = n > 0 ? "a" : n; x isa String ? ncodeunits(x) + n : -1), Int64(3)),
    ("constant_global_phi_edge", (n::Int64) -> (v = n > 0 ? _OTR_VEC : Int64[]; length(v) + n), Int64(3)),
    ("typed_global_read", (n::Int64) -> n + _otr_typed, Int64(3)),
    ("field_read_narrower_than_field", (x::Int64) -> (e = BoundsError(Memory{UInt8}(undef, 2), x); length(e.a) + x), Int64(5)),
    ("dynamic_call_result_any", (n::Int64) -> (v = Any[codeunits("ab"), [n], n, 1.0]; _sm_cu_q(v[n])), Int64(3)),
    ("captor_called_elsewhere", (n::Int64) -> (p = _otr_mk(n); p[1](); p[2]() isa Float64 ? 1 : 0), Int64(3)),
    ("box_write_argument_same_type", (n::Int64) -> _otr_arg_same(n), Int64(3)),
    ("box_write_argument_other_type", (n::Int64) -> _otr_arg_other(n), Int64(3)),
    ("box_write_type_literal_operand", (n::Int64) -> _otr_lit_write(n), Int64(3)),
    ("captor_called_elsewhere_value", (n::Int64) -> (p = _otr_mk(n); a = p[2]()::Int64; p[1](); a * 10 + Int64(2 * (p[2]()::Float64))), Int64(3)),
])
# A finalizer, a `:cfunction` and an `:invoke_modify` have no lowering: the collector enrolls
# the edge's target, and the statement rejects where it stands (record_unsupported!), never
# compiled to a plausible value. A finalizer survives Julia's elision only with an object that
# escapes and a callback with an effect. diagnostic_attribution.jl pins each kind's enrollment.
@noinline _sm_cf_add(x::Cint) = x + Cint(1)
const _SM_FIN_SINK = Ref{Any}(nothing)
const _SM_FIN_LOG = Int64[]
mutable struct _SmFin; v::Int64; end
@noinline _sm_fin_cb(o::_SmFin) = (push!(_SM_FIN_LOG, o.v); nothing)
mutable struct _SmAtom; @atomic v::Int64; end
@noinline _sm_atom_op(x::Int64, y::Int64) = x * 10 + y
_xf("closed_world_edge_rejects", Any[
    # a finalizer: the edge enrolls the callback at the object's type
    ("finalizer_registered", (n::Int64) -> (o = _SmFin(n); finalizer(_sm_fin_cb, o); _SM_FIN_SINK[] = o; n), Int64(3)),
    # :cfunction: the edge enrolls the function at its declared argument types
    ("cfunction_pointer", (n::Int64) -> (p = @cfunction(_sm_cf_add, Cint, (Cint,)); p == C_NULL ? Int64(0) : n), Int64(3)),
    # an atomic modify of a field with a function: the :invoke_modify head names the
    # operator, which the edge enrolls
    ("atomic_modify_operator", (n::Int64) -> (a = _SmAtom(n); @atomic a.v _sm_atom_op n; @atomic a.v), Int64(3)),
])

# Base paths the short cases compile but never run: a Float64 sort long enough for its quick sort
# (keys spread) and its radix sort (two passes over keys 4000 ulps apart), and the errors a zero-textwidth pad and
# an embedded NUL raise (their messages' escape_string), each caught (native -1)
_g("entered_paths", Any[
    ("sort_quick", (x::Float64) -> (v = sort([x, 355.5, 202.5, 49.5, -103.5, -256.5, -409.5, 446.5, 293.5, 140.5, -12.5, -165.5, -318.5, -471.5, 384.5, 231.5, 78.5, -74.5, -227.5, -380.5, 475.5, 322.5, 169.5, 16.5, -136.5, -289.5, -442.5, 413.5, 260.5, 107.5, -45.5, -198.5, -351.5, 504.5, 351.5, 198.5, 45.5, -107.5, -260.5, -413.5, 442.5, 289.5, 136.5, -16.5, -169.5, -322.5, -475.5, 380.5, 227.5, 74.5, -78.5, -231.5, -384.5, 471.5, 318.5, 165.5, 12.5, -140.5, -293.5, -446.5, 409.5, 256.5, 103.5, -49.5, -202.5, -355.5, 500.5, 347.5, 194.5, 41.5, -111.5, -264.5, -417.5, 438.5, 285.5, 132.5, -20.5, -173.5, -326.5, -479.5, 376.5, 223.5, 70.5, -82.5, -235.5, -388.5, 467.5, 314.5, 161.5, 8.5, -144.5, -297.5, -450.5, 405.5, 252.5, 99.5, -53.5, -206.5, -359.5, 496.5, 343.5, 190.5, 37.5, -115.5, -268.5, -421.5, 434.5, 281.5, 128.5, -24.5, -177.5, -330.5, -483.5, 372.5, 219.5, 66.5, -86.5, -239.5, -392.5, 463.5, 310.5, 157.5, 4.5, -148.5, -301.5, -454.5, 401.5, 248.5, 95.5, -57.5, -210.5, -363.5, 492.5, 339.5, 186.5, 33.5, -119.5, -272.5, -425.5, 430.5, 277.5, 124.5, -28.5, -181.5, -334.5, -487.5, 368.5, 215.5, 62.5, -90.5, -243.5, -396.5, 459.5, 306.5, 153.5, 0.5, -152.5, -305.5, -458.5, 397.5, 244.5, 91.5, -61.5, -214.5, -367.5, 488.5, 335.5, 182.5, 29.5, -123.5, -276.5, -429.5, 426.5, 273.5, 120.5, -32.5, -185.5, -338.5, -491.5, 364.5, 211.5, 58.5, -94.5, -247.5, -400.5, 455.5, 302.5, 149.5, -3.5, -156.5, -309.5, -462.5, 393.5, 240.5, 87.5, -65.5, -218.5, -371.5, 484.5, 331.5, 178.5, 25.5, -127.5, -280.5, -433.5, 422.5, 269.5, 116.5, -36.5, -189.5, -342.5, -495.5, 360.5, 207.5, 54.5, -98.5, -251.5, -404.5, 451.5, 298.5, 145.5, -7.5, -160.5, -313.5, -466.5, 389.5, 236.5, 83.5, -69.5, -222.5, -375.5, 480.5, 327.5, 174.5, 21.5, -131.5, -284.5, -437.5, 418.5, 265.5, 112.5, -40.5, -193.5, -346.5, -499.5, 356.5, 203.5, 50.5, -102.5, -255.5, -408.5, 447.5, 294.5, 141.5, -11.5, -164.5, -317.5, -470.5, 385.5, 232.5, 79.5, -73.5, -226.5, -379.5, 476.5, 323.5, 170.5, 17.5, -135.5, -288.5, -441.5, 414.5, 261.5, 108.5, -44.5, -197.5, -350.5, 505.5, 352.5, 199.5, 46.5, -106.5, -259.5, -412.5, 443.5, 290.5, 137.5, -15.5, -168.5, -321.5, -474.5, 381.5, 228.5, 75.5, -77.5, -230.5, -383.5, 472.5, 319.5, 166.5, 13.5]); v[1] + 2 * v[end] + v[150]), 0.25),
    ("sort_radix_two_passes", (x::Float64) -> (v = sort([x, 1.0, 1.0000000000002747, 1.0000000000005493, 1.000000000000824, 1.0000000000002103, 1.000000000000485, 1.0000000000007596, 1.0000000000001459, 1.0000000000004206, 1.0000000000006952, 1.0000000000000815, 1.0000000000003562, 1.0000000000006308, 1.000000000000017, 1.0000000000002918, 1.0000000000005664, 1.000000000000841, 1.0000000000002274, 1.000000000000502, 1.0000000000007767, 1.000000000000163, 1.0000000000004376, 1.0000000000007123, 1.0000000000000986, 1.0000000000003733, 1.000000000000648, 1.0000000000000342, 1.0000000000003089, 1.0000000000005835, 1.0000000000008582, 1.0000000000002445, 1.0000000000005191, 1.0000000000007938, 1.00000000000018, 1.0000000000004547, 1.0000000000007294, 1.0000000000001157, 1.0000000000003904, 1.000000000000665, 1.0000000000000513, 1.000000000000326, 1.0000000000006006, 1.0000000000008753, 1.0000000000002616, 1.0000000000005362, 1.000000000000811, 1.0000000000001972, 1.0000000000004718, 1.0000000000007465, 1.0000000000001328, 1.0000000000004075, 1.0000000000006821, 1.0000000000000684, 1.000000000000343, 1.0000000000006177, 1.000000000000004, 1.0000000000002787, 1.0000000000005533, 1.000000000000828, 1.0000000000002143]); (v[end] - v[1]) / eps(1.0) + 10000 * (v[2] - v[1]) / eps(1.0)), 1.0000000000000004),
    ("lpad_zero_width_string", (n::Int64) -> (try; ncodeunits(lpad(string(n), 6, "\u0301")); catch; -1; end), Int64(4)),
    ("lpad_rpad_zero_width", (n::Int64) -> (try; ncodeunits(lpad(string(n), 6, "\u0301")) * 100 + ncodeunits(rpad("x", n, '\u0301')); catch; -1; end), Int64(4)),
    ("operator_embedded_nul", (x::Int64) -> (try; Int64(Base._isoperator(string(Char(x), Char(0)))); catch; -1; end), Int64(0x2b)),
])

# ---- dart2wasm's tests at the pin, tests/web/wasm (test/dart_tests.toml, dev/LEDGER.md D41) -------
# Each case is the dart test's construct written in Julia, named by the dart file less `_test`; the
# expected value is what native Julia computes, never dart's (D3). A case whose dart test asserts
# several facts returns them as bits, the first fact the highest, so a wrong one names itself.
_dw_bits(bs::Bool...) = foldl((a, b) -> 2a + Int64(b), bs; init = Int64(0))
# boxed_value_tearoff: a method bound to a boxed receiver, then called
_dw_tearoff(x::Int64) = () -> abs(x)
# closure_hash_code: closures, a function value and a closure over a mutable receiver compared by
# ==, hash and ===
_dw_static() = nothing
mutable struct _DwC
    x::Int64
end
_dw_member(o::_DwC) = () -> o.x
_dw_same(a, b) = _dw_bits(a == b, hash(a) == hash(b), a === b)
# constructor_tearoff: a parametric struct with a keyword default, its constructor, a redirecting
# outer constructor, a factory and a constructor that forwards, each called and passed as a value
struct _DwFoo{T}
    pos::T
    named::String
    _DwFoo{T}(pos::T; named::String = "Foo named") where {T} = new{T}(pos, named)
end
_DwFoo(pos::T; named::String = "Foo named") where {T} = _DwFoo{T}(pos; named = named)
_dw_foo_redirect(pos; named::String = "Foo.redirect named") = _DwFoo(pos; named = named)
_dw_foo_factory(pos; named::String = "Foo.factory named") = _DwFoo(pos; named = named)
_dw_foo_forward(pos; kw...) = _DwFoo(pos; kw...)
_dw_foo_is(f::_DwFoo, pos, named::String) = f.pos == pos && f.named == named
# constructor_test: constructors whose arguments are captured, modified and stored
struct _DwBase{T,U}
    t::T
    u::U
end
struct _DwDerived{V}
    base::_DwBase{V,Int64}
    v::V
    _DwDerived{V}(v_in::V, i::Int64) where {V} = new{V}(_DwBase{V,Int64}(v_in, i), v_in)
end
_dw_init_capture(p::Int64) = (g = () -> p; (g, p))
function _dw_init_capture_modify(p0::Int64)
    local p::Int64 = p0
    local getP = () -> (p = p + 1; p)
    local pAfter = (p = p + 2)
    return (getP, pAfter)
end
function _dw_body_capture_modify(p0::Int64)
    local p::Int64 = p0
    p = p + 10
    local pInBody = p
    local getP = () -> (p = p + 1; p)
    return (getP, pInBody)
end
function _dw_double_capture(p0::Int64)
    local p::Int64 = p0
    local initClosure = () -> p
    p = p + 5
    local bodyClosure = () -> p
    p = p + 5
    return (initClosure, bodyClosure)
end
struct _DwMixed
    a::Int64
    b::Int64
    c::Int64
    _DwMixed(a::Int64, b::Int64 = Int64(2), c::Int64 = Int64(3)) = new(a, b, c)
end
struct _DwNamed
    a::Int64
    b::Int64
end
_DwNamed(; a::Int64, b::Int64 = 20) = _DwNamed(a, b)
struct _DwFactory
    x::Int64
    _DwFactory(x::Int64) = new(x + 100)
end
# flutter_regress_152029: a parametric struct's nullable field written through a receiver read
# from a mixed list
mutable struct _DwA{T}
    value::Union{Nothing,T}
end
# inlining: a recursive constructor and a recursive function
struct _DwWidget
    children::Vector{_DwWidget}
end
_DwWidget(n::Int64) = _DwWidget([_DwWidget(Int64(0)) for _ in 1:n])
_dw_fib(n::Int64)::Int64 = n == 0 ? 0 : n == 1 ? 1 : _dw_fib(n - 1) + _dw_fib(n - 2)
# issue_54926: two values of one method bound to one receiver
struct _DwC2 end
_dw_f(::_DwC2, t) = t
# issue_56234: a Float64 asserted to be an Int64 at run time
struct _DwX
    x::Float64
end
_dw_getx(c::_DwX) = c.x
# lazy_const_record: a constant tuple holding a constant list of 10,001 integers
const _DW_LIST = collect(Int64(0):Int64(10000))
const _DW_RECORD = (_DW_LIST, Int64(10))
# lazy_static_number_initializer_regression: a constant chosen by a type test, used by a function
# rounding either number
const _DW_MAXINT = 1 isa Float64 ? 2.0^52 : floor(1.0e300)
_dw_round(n::Union{Int64,Float64}) = n isa Float64 && isinf(n) ? _DW_MAXINT : round(n)
# no_omit_error_details: an index past a list's end
const _DW_L = Int64[0, 1, 2, 3, 4]
# regress_54794: isa against a supertype parameterized by a tuple type
abstract type _DwBaseT{T} end
struct _DwSub{A,B} <: _DwBaseT{Tuple{A,B}} end
# regress_59782: a value of a union compared with string cases
_dw_switch(x::Union{Int64,String}) = x == "a" ? "a" : x == "b" ? "b" : "default"
_dw_switch_none(x::Union{Int64,String}) = x == "a" ? "a" : x == "b" ? "b" : nothing
# regress_59840: two optional nullable keyword Float64s, an assertion relating them and a check
function _dw_opt(; something::Union{Nothing,Float64} = nothing, other::Union{Nothing,Float64} = nothing)
    @assert (something === nothing && other === nothing) || (something !== nothing && other !== nothing)
    something === nothing && return 0.0
    return something + Base.something(other)
end
# regress_62273: a method with its own keyword default, reached through a function returning the
# abstract type
abstract type _DwA62 end
struct _DwB62 <: _DwA62 end
_dw_foo(::_DwA62; s::String = "hi") = s
_dw_foo(::_DwB62; s::String = "there") = s
_dw_geta(x::Int64)::_DwA62 = x < 10 ? _DwB62() : throw(ArgumentError("here"))
# regress_63454: a loop over an empty Dict's pairs whose body writes a field of the key
mutable struct _DwUnused
    foo::Any
end
# regress_63747: a constructor argument rebound before copyto! copies it
struct _DwBytes
    field::Vector{UInt8}
end
function _dw_bytes_foo(arg::Vector{Int64})
    local field = zeros(UInt8, 64)
    local a::Union{Vector{Int64},Vector{UInt8}} = arg
    length(a) > 64 && (a = zeros(UInt8, 16))
    copyto!(field, 1, a, 1, length(a))
    return _DwBytes(field)
end
function _dw_bytes_bar(arg::Vector{Int64})
    local field = zeros(UInt8, 64)
    local a = zeros(UInt8, 16)
    local initialLength = length(a)
    copyto!(field, 1, a, 1, length(a))
    return (_DwBytes(field), initialLength)
end
# static_dispatch_pragma: a call over a list of two subtypes of one abstract type
abstract type _DwDoit end
struct _DwA1 <: _DwDoit end
struct _DwA2 <: _DwDoit end
_dw_doit(::_DwA1) = Int64(1)
_dw_doit(::_DwA2) = Int64(2)
# unreachable_selector_implementation: a call over two subtypes while a third, never made, has a
# method with a keyword default
abstract type _DwSel end
struct _DwSub1 <: _DwSel end
struct _DwSub2 <: _DwSel end
struct _DwSub3 <: _DwSel end
_dw_sel(::_DwSub1) = "Sub1.foo()"
_dw_sel(::_DwSub2) = "Sub2.foo()"
_dw_sel(::_DwSub3; a::Int64 = 4) = "Sub3.foo($a)"
# closures/function_apply: functions with an optional positional default applied to one and two
# arguments, and to one argument too many
_dw_static1(a, b = "missing-b") = "static1: $a $b"
_dw_static2(a, b = "missing-b") = "static2: $a $b"
_dw_apply(f, args::Tuple) = f(args...)
_g("dart_web_wasm", Any[
    ("assertion_failure_message", (x::Bool) -> (try; @assert x "failure message"; 0; catch e; e isa AssertionError && occursin("failure message", e.msg) ? 1 : 2; end), false),
    ("boxed_value_tearoff", (x::Int64) -> (t = _dw_tearoff(x); t()), Int64(-4)),
    ("closure_hash_code", (n::Int64) -> (f = () -> n; o1 = _DwC(n); o2 = _DwC(n);
        _dw_bits(_dw_same(f, f) == 7, _dw_same(() -> nothing, () -> nothing) == 0, _dw_same(_dw_static, _dw_static) == 7,
                 _dw_same(_dw_member(o1), _dw_member(o1)) == 7, _dw_same(_dw_member(o1), _dw_member(o2)) == 0)), Int64(1)),
    ("constructor_tearoff", (x::Float64) -> (n = Int64(round(x));
        cs = (_DwFoo, _dw_foo_redirect, _dw_foo_factory, _dw_foo_forward);
        _dw_bits(_dw_foo_is(_DwFoo(n), n, "Foo named"), _dw_foo_is(_dw_foo_redirect(n), n, "Foo.redirect named"),
                 _dw_foo_is(_dw_foo_factory(n), n, "Foo.factory named"), _dw_foo_is(_dw_foo_forward(n), n, "Foo named"),
                 _dw_foo_is(cs[1](x), x, "Foo named"), _dw_foo_is(cs[2](x; named = "2"), x, "2"),
                 _dw_foo_is(cs[3](x), x, "Foo.factory named"), _dw_foo_is(cs[4](x; named = "4"), x, "4"))), 1.0),
    ("constructor", (one::Int64) -> (d = _DwDerived{String}("hello", 42 * one);
        (gi, vi) = _dw_init_capture(10 * one); (gm, pa) = _dw_init_capture_modify(30 * one); (gb, pb) = _dw_body_capture_modify(40 * one);
        (ci, cb) = _dw_double_capture(300 * one); m1 = _DwMixed(one); m2 = _DwMixed(one, 10 * one); k1 = _DwNamed(a = 5 * one);
        k2 = _DwNamed(b = 30 * one, a = 7 * one);
        _dw_bits(d.base.t == "hello" && d.base.u == 42 && d.v == "hello", gi() == 10 && vi == 10, pa == 32 && gm() == 33 && gm() == 34,
                 pb == 50 && gb() == 51 && gb() == 52, ci() == 310 && cb() == 310, (m1.a, m1.b, m1.c) == (1, 2, 3) && (m2.a, m2.b, m2.c) == (1, 10, 3),
                 (k1.a, k1.b) == (5, 20) && (k2.a, k2.b) == (7, 30), _DwFactory(50 * one).x == 150)), Int64(1)),
    ("flutter_regress_152029", (i::Int64) -> (list = Union{_DwA{String},Int64}[_DwA{String}(nothing), Int64(1)]; a = list[i];
        a isa _DwA && i == 1 && (a.value = "42"); a isa _DwA && a.value == "42" ? 1 : 0), Int64(1)),
    ("inlining", (n::Int64) -> length(_DwWidget(n).children) * 100 + _dw_fib(Int64(5)), Int64(10)),
    ("issue_54926", (n::Int64) -> (c = _DwC2(); f1 = Base.Fix1(_dw_f, c); f2 = Base.Fix1(_dw_f, c); _dw_bits(f1 === f2, f1 == f2, f1(n) == n)), Int64(3)),
    ("issue_56234", (x::Float64) -> (try; v = _dw_getx(_DwX(x))::Int64; v; catch e; e isa TypeError ? Int64(-1) : Int64(-2); end), 0.0),
    ("lazy_const_record", (i::Int64) -> _DW_RECORD[1][i] + _DW_RECORD[2] + length(_DW_RECORD[1]), Int64(10001)),
    ("lazy_static_number_initializer_regression", (x::Float64) -> _dw_bits(_dw_round(x) == 1, _dw_round(Int64(1)) == 1, _dw_round(Inf) == _DW_MAXINT), 1.0),
    ("no_omit_error_details", (i::Int64) -> (try; _DW_L[i]; catch e; e isa BoundsError ? Int64(-1) : Int64(-2); end), Int64(6)),
    ("regress_54794", (i::Int64) -> (o = i == 1 ? _DwSub{Int64,String}() : i;
        _dw_bits(o isa _DwBaseT, o isa _DwBaseT{<:Tuple}, o isa _DwBaseT{<:Tuple{Any,Any}}, o isa _DwBaseT{<:Tuple{Int64,Any}},
                 o isa _DwBaseT{<:Tuple{Any,String}}, o isa _DwBaseT{Tuple{Int64,String}}, o isa _DwBaseT{<:Tuple{String,Any}},
                 o isa _DwBaseT{<:Tuple{Any,Int64}}, o isa _DwBaseT{Tuple{Any,Any}})), Int64(1)),
    ("regress_59782", (n::Int64) -> _dw_bits(_dw_switch(n) == "default", _dw_switch_none(n) === nothing), Int64(42)),
    ("regress_59840", (x::Float64) -> _dw_opt(something = x, other = x) + _dw_opt(), 1.0),
    ("regress_62273", (x::Int64) -> _dw_bits(_dw_foo(_dw_geta(x)) == "there", _dw_foo(_dw_geta(x - 1); s = "wow") == "wow"), Int64(9)),
    ("regress_63454", (n::Int64) -> (value = Ref(n); d = Dict{_DwUnused,Int64}(); k = 0; for (key, _) in d; key.foo = value; k += 1; end; k + n), Int64(3)),
    ("regress_63747", (n::Int64) -> (f = _dw_bytes_foo(fill(n, 80)); (b, l) = _dw_bytes_bar(fill(n, 80)); Int64(sum(f.field)) + Int64(sum(b.field)) + l), Int64(0)),
    ("static_dispatch_pragma", (n::Int64) -> (list = Union{_DwA1,_DwA2}[_DwA1(), _DwA2()]; s = Int64(0); for e in list; s = 10s + _dw_doit(e); end; s + n), Int64(0)),
    ("unreachable_selector_implementation", (n::Int64) -> (l = Union{_DwSub1,_DwSub2}[_DwSub1(), _DwSub2()]; s = Int64(0); for x in l; s += ncodeunits(_dw_sel(x)); end; s + n), Int64(0)),
    ("function_apply", (n::Int64) -> (fs = (_dw_static1, _dw_static2);
        _dw_bits(_dw_apply(fs[1], (n,)) == "static1: $n missing-b", _dw_apply(fs[1], (n, 2)) == "static1: $n 2",
                 _dw_apply(fs[2], (n,)) == "static2: $n missing-b", _dw_apply(fs[2], (n, 2)) == "static2: $n 2",
                 (try; _dw_apply(fs[1], (n, 2, "extra2")); false; catch e; e isa MethodError; end))), Int64(1)),
])

# ---- dart2wasm's tests at the pin, tests/language (test/dart_tests.toml, dev/LEDGER.md D41) -------
# Each case is named by the dart file's path under tests/language, `/` written `_`, less `_test`.
# flutter_regession_151473: methods calling their supertype's method (Julia's invoke), through a
# list of two subtypes
abstract type _DlI end
abstract type _DlRes end
struct _DlSub1 <: _DlRes end
struct _DlSub2 <: _DlRes end
struct _DlSub3 <: _DlRes end
abstract type _DlA <: _DlI end
struct _DlB1 <: _DlA end
struct _DlB2 <: _DlA end
_dl_foo(::_DlA)::_DlRes = _DlSub1()
_dl_foo(b::_DlB1)::_DlRes = (invoke(_dl_foo, Tuple{_DlA}, b) isa _DlSub1 ? _DlSub2() : _DlSub1())
_dl_foo(b::_DlB2)::_DlRes = (invoke(_dl_foo, Tuple{_DlA}, b) isa _DlSub1 ? _DlSub3() : _DlSub1())
_dl_bar(::_DlA)::_DlRes = _DlSub1()
_dl_bar(b::_DlB1)::_DlRes = (invoke(_dl_bar, Tuple{_DlA}, b) isa _DlSub1 ? _DlSub2() : _DlSub1())
_dl_bar(b::_DlB2)::_DlRes = (invoke(_dl_bar, Tuple{_DlA}, b) isa _DlSub1 ? _DlSub3() : _DlSub1())
# local_null_initialization: a variable of a loop's body, assigned in some iterations, is fresh in
# each (read with @isdefined, Julia's unassigned local)
function _dl_convert(text::String)
    local result = Union{Nothing,Int64}[]
    for ch in text
        if ch == '<'
            replacement = Int64(1)
        elseif ch == '>'
            replacement = Int64(2)
        end
        push!(result, @isdefined(replacement) ? replacement : nothing)
    end
    return result
end
# record_literal / record_type: tuples and named tuples, nested, holding a function, of one
# element, declared by type, passed and returned
_dl_rec_foo(input::Tuple{Int64,@NamedTuple{b::Bool}}, x::Int64)::Tuple{Int64,Int64} = input[2].b ? (42, 42) : (1, 1)
_dl_rec_f1(t::T) where {T} = (Int64(42), t)
struct _DlBar end
_dl_rec_bar(::_DlBar, x::Int64)::Tuple{Int64,Int64} = (42, 42)
# regress_54994: isa against parametric subtypes after a value is held at a supertype
abstract type _DlG0{T} end
abstract type _DlG1{T,H} <: _DlG0{Int64} end
struct _DlG1c{T,H} <: _DlG1{T,H} end
struct _DlG2{T} <: _DlG1{T,T} end
_dl_b0(k::Bool)::_DlG0{Int64} = k ? _DlG2{String}() : _DlG1c{Bool,Bool}()
_dl_b1(k::Bool)::_DlG1 = k ? _DlG2{Int64}() : _DlG1c{Number,Number}()
function _dl_x_test(::Type{T}, k::Bool) where {T<:Number}
    local a = k ? _DlG2{T}() : _DlG1c{T,T}()
    return _dw_bits(a isa _DlG2{T}, a isa _DlG2{Int64}, a isa _DlG2{Float64})
end
# regression_55741: isa against a parametric type whose subtype instantiates it at a nullable type
abstract type _DlBaseA{T} end
struct _DlBase{T} <: _DlBaseA{T}
    data::T
end
struct _DlSubN{T} <: _DlBaseA{Union{Nothing,T}}
    data::Union{Nothing,T}
end
# if/and: a bit set after a shift of a value read in a loop
_dl_opshr(n::Int64, a2::Int64) = (negative = a2 == 496; res2 = a2; negative && (res2 |= 3); res2)
# if/dangling_else: nested ifs whose else belongs to the outer if, and a labeled block left early
function _dl_nested_if1(notTrue::Bool)
    notTrue && return "bad input"
    if notTrue
        notTrue && return "bad"
    else
        return "good"
    end
    return "bug"
end
function _dl_nested_while(notTrue::Bool)
    notTrue && return "bad input"
    if notTrue
        while notTrue
            notTrue && return "bad"
        end
    else
        return "good"
    end
    return "bug"
end
function _dl_nested_for(notTrue::Bool)
    notTrue && return "bad input"
    if notTrue
        for i in 0:2
            i == 0 && return "bad"
        end
    else
        return "good"
    end
    return "bug"
end
function _dl_nested_labeled(notTrue::Bool)
    notTrue && return "bad input"
    if notTrue
        notTrue && @goto label
        @label label
    else
        return "good"
    end
    return "bug"
end
# if/if_test: if statements with empty branches, else, negation, || and &&
_dl_f0(b::Bool) = (if b; end; if b; else; end; Int64(0))
_dl_f1(b::Bool) = b ? Int64(1) : Int64(2)
_dl_f3(b::Bool) = (b && return Int64(1); Int64(2))
_dl_f5(b::Bool) = (!b && return Int64(1); Int64(2))
_dl_f6(a::Bool, b::Bool) = (a || b) ? Int64(1) : Int64(2)
_dl_f7(a::Bool, b::Bool) = (a && b) ? Int64(1) : Int64(2)
# if/nested_if: a list rebound in a branch never taken, then appended to in a loop
function _dl_nested_if(x::Bool, a::Vector{Int64})
    for _ in 1:10
        if x
            !x && (a = Int64[])
            push!(a, 3)
        end
    end
    return a
end
# return/in_loop: a return inside an infinite loop
_dl_in_loop() = (x = 0; while true; true && return Int64(42); x = 1; end)
# return/skip_expression: a parametric struct's method returning a new instance of its type
struct _DlOneArg{A} end
struct _DlTwoArgs{A,B} end
_dl_next(::_DlOneArg{A}) where {A} = _DlOneArg{A}()
_dl_next(::_DlTwoArgs{A,B}) where {A,B} = _DlTwoArgs{A,B}()
# return/this_type: a method of the supertype returning its receiver
abstract type _DlRA end
struct _DlRB <: _DlRA end
_dl_this(a::_DlRA) = a
# bool/bool_test: Bool equality and identity, string, negation, && and || over operands of a union
# (a non-Bool condition raises TypeError) and their short circuit counted
_dl_and(a::Union{Bool,Int64}, b::Union{Bool,Int64}) = (try; a && b; catch e; e isa TypeError ? Int64(-1) : Int64(-2); end)
_dl_or(a::Union{Bool,Int64}, b::Union{Bool,Int64}) = (try; a || b; catch e; e isa TypeError ? Int64(-1) : Int64(-2); end)
function _dl_short_circuit()
    local t = Ref(Int64(0))
    local f = Ref(Int64(0))
    local tf = () -> (t[] += 1; true)
    local ff = () -> (f[] += 1; false)
    local s = Int64(0)
    tf() && tf(); s = 100s + 10t[] + f[]; t[] = f[] = 0
    ff() && tf(); s = 100s + 10t[] + f[]; t[] = f[] = 0
    tf() && ff(); s = 100s + 10t[] + f[]; t[] = f[] = 0
    ff() || ff(); s = 100s + 10t[] + f[]
    return s
end
# bool/check_strong, bool/condition_check_strong: a condition that is nothing or a String
_dl_cond(x::Union{Nothing,String,Bool}) = (try; x ? Int64(1) : Int64(0); catch e; e isa TypeError ? Int64(-1) : Int64(-2); end)
_dl_check(; a::Union{Nothing,Bool} = false, b::Union{Nothing,Bool} = true) = string(a ? "a" : "", b ? "b" : "")
# identity: === passed as a value, over integers, floats, strings, mutable structs and NaNs
mutable struct _DlPoint
    x::Int64
    y::Int64
end
_dl_f() = nothing
const _DL_G = Int64(1)
const _DL_IDENTICAL_FF = _dl_f === _dl_f
const _DL_IDENTICAL_FG = _dl_f === _DL_G
_dl_ident_ho(a::String) = (!("ho" === a) ? Int64(2) : Int64(1))
_dl_strict(a::Int64) = _dw_bits(a === 3, !(a === 3), !(3 === a), (a === 3 ? 1 : 2) == 1, (a === 0), (0 === a), nothing != nothing)
# double_literals: integer literals in a Float64 context convert to the Float64 of the same value
mutable struct _DlSetter
    x::Float64
end
_dl_expect_double(e::Float64, a::Float64) = e === a
_g("dart_language", Any[
    ("flutter_regession_151473", (i::Int64) -> (l = Union{_DlB1,_DlB2}[_DlB1(), _DlB2()];
        _dw_bits(_dl_foo(l[i]) isa _DlSub2, _dl_bar(l[i]) isa _DlSub2, _dl_foo(l[i + 1]) isa _DlSub3, _dl_bar(l[i + 1]) isa _DlSub3)), Int64(1)),
    ("local_null_initialization", (s::String) -> (s2 = Int64(0); for x in _dl_convert(s); s2 = 10s2 + (x === nothing ? 9 : x); end; s2), "<A>"),
    ("record_literal", (n::Int64) -> (r1 = ((n, 2), (a = 3, b = 4)); r2 = (42, 42, 42); r3 = ((42,), (foo = 42, bar = 42, baz = 42)); r4 = ((42, 42), 42);
        r5 = ((foo, bar) -> 42, 42); r6 = (42,); r8 = ((42,), (foo = "bar",));
        r1[1][1] + r1[1][2] + r1[2].a + r1[2].b + sum(r2) + r3[1][1] + r3[2].bar + r4[1][2] + r5[1](1, 2) + r5[2] + r6[1] + ncodeunits(r8[2].foo)), Int64(1)),
    ("record_type", (n::Int64) -> (r1::Tuple{Int64,Int64} = (n, 2); r3::Tuple{Int64,Int64,@NamedTuple{a::Int64,b::Int64}} = (1, 2, (a = 3, b = 4));
        l = Tuple{Int64,Int64}[]; push!(l, r1); one::Tuple{Int64} = (1,); ok::@NamedTuple{ok::Int64} = (ok = 1,);
        f = _dl_rec_foo((42, (b = true,)), 42); g = _dl_rec_bar(_DlBar(), 42); h = _dl_rec_f1("x");
        r1[1] + r3[3].b + l[1][2] + one[1] + ok.ok + f[1] + g[2] + h[1] + ncodeunits(h[2])), Int64(1)),
    ("regress_54994", (k::Bool) -> (a = _dl_b0(k); b = _dl_b1(k);
        _dw_bits(a isa _DlG2{Int64}, a isa _DlG2{String}, b isa _DlG2{Number}, b isa _DlG2{Int64}, b isa _DlG2{Float64},
                 b isa _DlG2{<:Number}) * 64 + _dl_x_test(Int64, k) * 8 + _dl_x_test(Float64, k)), true),
    ("regression_55741", (k::Bool) -> (base = k ? _DlBase{String}("a") : 1; baseN = k ? _DlBase{Union{Nothing,String}}("a") : 1;
        sub = k ? _DlSubN{String}("a") : 1;
        _dw_bits(base isa _DlBaseA{String}, base isa _DlBaseA{Union{Nothing,String}}, baseN isa _DlBaseA{String}, baseN isa _DlBaseA{Union{Nothing,String}},
                 sub isa _DlSubN{String}, sub isa _DlBaseA{String}, sub isa _DlBaseA{Union{Nothing,String}}, base isa _DlBaseA{<:Union{Nothing,String}})), true),
    ("if_and", (n::Int64) -> (t = 0; for _ in 1:3; t = _dl_opshr(n, Int64(496)); end; t), Int64(99)),
    ("if_dangling_else", (b::Bool) -> _dw_bits(_dl_nested_if1(b) == "good", _dl_nested_while(b) == "good", _dl_nested_for(b) == "good", _dl_nested_labeled(b) == "good"), false),
    ("if_if", (b::Bool) -> (r = [_dl_f0(b), _dl_f1(b), _dl_f1(!b), _dl_f3(b), _dl_f3(!b), _dl_f5(b), _dl_f5(!b), _dl_f6(b, b), _dl_f6(b, !b), _dl_f6(!b, b), _dl_f6(!b, !b),
        _dl_f7(b, b), _dl_f7(b, !b), _dl_f7(!b, b), _dl_f7(!b, !b)]; s = Int64(0); for x in r; s = 3s + x; end; s), true),
    ("if_nested_if", (x::Bool) -> (a = _dl_nested_if(x, Int64[]); length(a) * 10 + a[1]), true),
    ("return_in_loop", (n::Int64) -> _dl_in_loop() + n, Int64(0)),
    ("return_skip_expression", (n::Int64) -> _dw_bits(_dl_next(_DlOneArg{String}()) isa _DlOneArg, _dl_next(_DlTwoArgs{String,Int64}()) isa _DlTwoArgs,
        _dl_next(_DlOneArg{String}()) isa _DlOneArg{String}, _dl_next(_DlTwoArgs{String,Int64}()) isa _DlTwoArgs{String,Int64}) + n, Int64(0)),
    ("return_this_type", (n::Int64) -> (_dl_this(_DlRB()) isa _DlRB ? 1 : 0) + n, Int64(0)),
    ("bool_bool", (t::Bool) -> (f = !t;
        _dw_bits(t === true, t === f, t == (t == t), f === (t == f), t != f, string(t) == "true", string(f) == "false", !f == t) * 10^12 +
        (_dl_and(t, t) === true) * 10^11 + (_dl_and(t, Int64(0)) === Int64(0)) * 10^10 + (_dl_and(Int64(0), t) === Int64(-1)) * 10^9 +
        (_dl_or(f, t) === true) * 10^8 + (_dl_or(t, Int64(0)) === true) * 10^7 + (_dl_or(f, Int64(1)) === Int64(1)) * 10^6 +
        (_dl_or(Int64(1), f) === Int64(-1)) * 10^5 + _dl_short_circuit() % 10^5), true),
    ("bool_check_strong", (s::String) -> _dl_cond(nothing) * 10 + _dl_cond(s), "true"),
    ("bool_condition_check_strong", (n::Int64) -> (try; ncodeunits(_dl_check(a = nothing, b = nothing)); catch e; e isa TypeError ? Int64(-1) : Int64(-2); end) * 10 +
        ncodeunits(_dl_check()) + n, Int64(0)),
    ("identity_closure2", (n::Int64) -> (myid = (===); _dw_bits(myid(typemin(Int64), typemin(Int64)), myid(typemin(Int64), typemin(Int64) + n), myid(42, 42.0), myid(NaN, NaN))), Int64(1)),
    ("identity_closure", (n::Int64) -> (myid = (===); p = _DlPoint(n, n); q = _DlPoint(n, n); a = "hello"; b = string("hel", "lo");
        _dw_bits(myid(42, 42), myid(42, 41), myid(42.0, 42.0), myid(42.0, 41.0), myid(35184372088832, 35184372088832), myid(35184372088832, 35184372088831),
                 myid("hello", 41), myid(p, q), myid(p, p), myid(a, b), myid(42, nothing), myid(nothing, nothing))), Int64(1)),
    ("identity_const", (n::Int64) -> _dw_bits(_DL_IDENTICAL_FF, _DL_G === _DL_G, _DL_IDENTICAL_FG, _DL_G === _dl_f) + n, Int64(0)),
    ("identity_identical", (s::String) -> (r = Int64(0); for _ in 1:20; r += _dl_ident_ho(s) + (("ho" === s) ? 10 : 20) + (!("ho" === s) ? 100 : 200); end; r), "ho"),
    ("identity_mint_identical", (n::Int64) -> _dw_bits(2305843009213693952 + n === 2305843009213693952, 4611686018427387903 + n === 4611686018427387903,
        4611686018427387904 + n === 4611686018427387904, 2305843009213693953 + n === 2305843009213693954), Int64(0)),
    ("identity_nan_identical", (x::Float64) -> (other = reinterpret(Float64, typemax(UInt64) - UInt64(1)); a = other; b = x;
        _dw_bits(NaN === -NaN, NaN === NaN, -NaN === -NaN, other === -other, other === other, -other === -other, a === b, -a === -b, -a === b, a === -b,
                 -(-a) === a, -(-b) === b)), NaN),
    ("identity_strict_equal", (n::Int64) -> _dl_strict(n) * 1000 + _dl_strict(n - 2) * 10 + _dl_strict(Int64(0)) % 10, Int64(5)),
    ("double_literals_double_literal_coercion", (n::Int64) -> (v1::Float64 = 255 + n; v2::Float64 = 9007199254740992 + n; v3::Float64 = -0 + n; v4::Float64 = 4611686018427387904 + n;
        _dw_bits(_dl_expect_double(255.0, v1), _dl_expect_double(9007199254740992.0, v2), _dl_expect_double(0.0, v3), _dl_expect_double(-0.0, v3),
                 _dl_expect_double(4.611686018427387904e18, v4), _dl_expect_double(-1.0, Float64(-1 + n)))), Int64(0)),
    ("double_literals_implicit_double_context", (n::Int64) -> (v::Float64 = 0; v = v + n; o = _DlSetter(0); o.x = 2 + n; w::Float64 = 0x02;
        l = Float64[1, 2]; push!(l, 3); _dw_bits(v === 0.0, o.x === 2.0, w === 2.0, l[3] === 3.0, sum(l) === 6.0)), Int64(0)),
])

# ---- dart2wasm's structural tests at the pin (test/dart_tests.toml, dev/LEDGER.md D41) -------------
# Each case writes the construct a golden of pkg/dart2wasm/test/ir_tests or a structural test of
# tests/web/wasm compiles, named by the dart file less `_test`; the golden's property is checked on
# WT's module once the compiler emits (dev/MARCH.md 1.T), native Julia's answer meanwhile.
# hello: one print of a constant string (to devnull, so the suite's output stays its own)
# always_throws: a call of a function whose return type is Union{} (dart's Never)
@noinline _ds_always_throws(x::Int64)::Union{} = throw(ArgumentError("fooAlwaysThrows"))
@noinline _ds_foo(x::Int64) = x > 0 ? _ds_always_throws(x) : x
# math_min_max: min and max of Int64, Float64 and mixed operands, each in a function of its own
@noinline _ds_min_ii(a::Int64, b::Int64) = min(a, b)
@noinline _ds_max_ii(a::Int64, b::Int64) = max(a, b)
@noinline _ds_min_dd(a::Float64, b::Float64) = min(a, b)
@noinline _ds_max_dd(a::Float64, b::Float64) = max(a, b)
@noinline _ds_min_id(a::Int64, b::Float64) = min(a, b)
@noinline _ds_max_id(a::Int64, b::Float64) = max(a, b)
@noinline _ds_min_nn(a::Union{Int64,Float64}, b::Union{Int64,Float64}) = min(a, b)
@noinline _ds_max_nn(a::Union{Int64,Float64}, b::Union{Int64,Float64}) = max(a, b)
# globals: globals with constant and computed initializers, typed and nullable, read and written
struct _DsFoo
    s::String
end
const _DS_FOO0 = _DsFoo("foo0")
const _DS_FOO1 = Ref(_DsFoo("foo1"))
const _DS_BAR1 = Ref{Union{Nothing,_DsFoo}}(_DsFoo("bar1"))
const _DS_BAR3 = Ref{Union{Nothing,_DsFoo}}(nothing)
global _ds_baz::Union{Nothing,_DsFoo} = _DsFoo("baz1")
function _ds_globals(n::Int64)
    local r = ncodeunits(_DS_FOO0.s) + ncodeunits(_DS_FOO1[].s) + (_DS_BAR3[] === nothing ? 1 : 0)
    _DS_FOO1[] = _DsFoo("")
    _DS_BAR1[] = nothing
    _DS_BAR3[] = _DsFoo("x")
    global _ds_baz = nothing
    r += ncodeunits(_DS_FOO1[].s) + (_DS_BAR1[] === nothing ? 10 : 0) + ncodeunits(something(_DS_BAR3[]).s) + (_ds_baz === nothing ? 100 : 0)
    _DS_FOO1[] = _DsFoo("foo1"); _DS_BAR1[] = _DsFoo("bar1"); _DS_BAR3[] = nothing; global _ds_baz = _DsFoo("baz1")
    return r + n
end
# try_blocks: catch clauses selecting by the caught exception's type
@noinline _ds_f(n::Int64) = n == 0 ? throw(ErrorException("Hi")) : n
_ds_try1(n::Int64) = (try; _ds_f(n); catch e; e isa ErrorException ? -1 : rethrow(); end)
_ds_try2(n::Int64) = (try; _ds_f(n); catch; -2; end)
_ds_try3(n::Int64) = (try; _ds_f(n); catch e; e isa ArgumentError ? -3 : -4; end)
# type_brand: structs of one layout, each its own type
struct _DsFoo1; s1::String; a1::Int64; end
struct _DsFoo2; s2::String; a2::Int64; end
struct _DsFoo3; s3::String; a3::Int64; end
struct _DsBar1; s1::String; d1::Float64; end
_ds_brand(x::_DsFoo1) = 1
_ds_brand(x::_DsFoo2) = 2
_ds_brand(x::_DsFoo3) = 3
_ds_brand(x::_DsBar1) = 4
# large_const_set: a constant set of 10,001 integers
const _DS_SET = Set{Int64}(0:10000)
# long_string_import: a string literal of 100,001 bytes
const _DS_LONG = repeat("x", 100000) * "y"
# source_map_simple: an error thrown two calls deep and caught where it is thrown from
@noinline _ds_g(n::Int64) = n > 0 ? throw(ErrorException("g")) : n
@noinline _ds_sf(n::Int64) = _ds_g(n) + 1
_g("dart_structural", Any[
    ("hello", (n::Int64) -> (print(devnull, "hello world"); n), Int64(0)),
    ("always_throws", (n::Int64) -> (try; _ds_foo(n); catch e; e isa ArgumentError ? Int64(-1) : Int64(-2); end), Int64(1)),
    ("constant_string_ops", (n::Int64) -> (a = "hello"; b = "world"; ncodeunits("foo") * 1000 + Int64(codeunit("foo", 1)) + ncodeunits(a * " " * b) * 10^6 + n), Int64(0)),
    ("math_min_max", (k::Bool) -> (ia = k ? Int64(1) : Int64(2); ib = k ? Int64(2) : Int64(1); da = k ? 1.5 : 2.5; db = k ? 2.5 : 1.5;
        na = k ? ia : 1.2; nb = k ? ib : 1.2;
        Float64(_ds_min_ii(ia, ib) + 10 * _ds_max_ii(ia, ib)) + 100 * _ds_min_dd(da, db) + 1000 * _ds_max_dd(da, db) + 10^4 * _ds_min_id(ia, da) +
        10^5 * _ds_max_id(ia, da) + 10^6 * _ds_min_nn(na, nb) + 10^7 * _ds_max_nn(na, nb)), true),
    ("globals", (n::Int64) -> _ds_globals(n), Int64(0)),
    ("try_blocks", (n::Int64) -> _ds_try1(n) * 100 + _ds_try2(n) * 10 + _ds_try3(n) + _ds_try1(n + 1) * 1000, Int64(0)),
    ("type_brand", (n::Int64) -> (l = Union{_DsFoo1,_DsFoo2,_DsFoo3,_DsBar1}[_DsFoo1("1", n), _DsFoo2("1", n), _DsFoo3("1", n), _DsBar1("1", 1.1)];
        s = Int64(0); for e in vcat(l, l); s = 10s + _ds_brand(e); end; s), Int64(1)),
    ("large_const_set", (n::Int64) -> (n in _DS_SET ? 1 : 0) + length(_DS_SET) * 10, Int64(10000)),
    ("long_string_import", (n::Int64) -> ncodeunits(_DS_LONG) + Int64(codeunit(_DS_LONG, ncodeunits(_DS_LONG))) + n, Int64(0)),
    ("source_map_simple", (n::Int64) -> (try; _ds_sf(n); catch e; e isa ErrorException ? Int64(-1) : Int64(-2); end), Int64(1)),
])

# ---- dart2wasm's tests at the pin, tests/language/nnbd/{flow_analysis,type_promotion,static_errors} ----
# Each case is named by the dart file's path under tests/language/nnbd, `/` written `_`, less `_test`.
# dart's nullable `T?` is Julia's Union{Nothing,T}; a point where dart promotes is a runtime isa (or a
# typeassert that cannot fail); dart's Never is Julia's Union{}.
const _NaI = Union{Nothing,Int64}
const _NaO = Union{Int64,String}
_na_pack(xs::Int64...) = foldl((a, b) -> 16a + b, xs; init = Int64(0))

# flow_analysis/boolean_parameter: a parameter of type Bool or a union reassigned to a null test, then
# branched on, in a function, a method, a local function and a closure
struct _NaBpC end
function _na_bp_bool(x::_NaI, b::Bool)
    b = x !== nothing
    return b ? x isa Int64 : false
end
function _na_bp_obj(x::_NaI, b::Union{Nothing,Bool,String})
    b = x !== nothing
    return (b::Bool) ? x isa Int64 : false
end
_na_bp_method(::_NaBpC, x::_NaI, b::Bool) = (b = x !== nothing; b ? x isa Int64 : false)
function _na_bp_local(x::_NaI)
    local f = (b::Bool) -> (b = x !== nothing; b ? x isa Int64 : false)
    local g = (b::Union{Nothing,Bool,String}) -> (b = x !== nothing; (b::Bool) ? x isa Int64 : false)
    return _dw_bits(f(false), g(nothing), g("foo"))
end
# flow_analysis/demotion_and_type_of_interest_promotion: a variable narrowed twice, then assigned values
# of a narrower, a wider and an unrelated type
function _na_demote(n::Int64)
    local x::Union{Int64,Float64,String,Vector{Int64}} = n
    x::Real
    x::Int64
    local a = x isa Int64
    x = 1.0
    local b = x isa Real && !(x isa Int64)
    x = n
    x = ""
    local c = !(x isa Real)
    x = Int64[]
    local d = x isa AbstractVector{<:Real}
    x = n
    local e = x isa Int64
    return _dw_bits(a, b, c, d, e)
end
# flow_analysis/expr_property_not_promoted: a field of a struct returned by a function value, tested
# and read again through a second call
struct _NaEpC
    f::_NaI
end
_na_ep_eq(c) = c().f === nothing ? c().f === nothing : c().f isa Int64
_na_ep_is(c) = c().f isa Int64 ? c().f isa Int64 : c().f === nothing
# flow_analysis/identical: === against nothing, either operand order, unprefixed and through Core
function _na_ident(i::_NaI)
    local a = !(i === nothing) ? i isa Int64 : true
    local b = !(nothing === i) ? i isa Int64 : true
    local c = !Core.:(===)(i, nothing) ? i isa Int64 : true
    local d = !Core.:(===)(nothing, i) ? i isa Int64 : true
    return _dw_bits(a, b, c, d, i === nothing)
end
# flow_analysis/issue43093: a null-aware field read followed by a non-null assertion, in one branch
struct _NaI43C
    x::_NaI
end
_na_i43(b::Bool, c::Union{Nothing,_NaI43C})::_NaI = b ? (c === nothing ? nothing : something(c.x)) : nothing
# flow_analysis/late_var_assigned_in_try: a variable assigned in try, read in catch and in finally
function _na_late_try(n::Int64)
    local x::Int64
    local r1 = false
    try
        x = 10n
        throw(ErrorException("foo"))
    catch
        r1 = x == 10n
    end
    local y::Int64
    local r2 = false
    try
        y = 10n
    finally
        r2 = y == 10n
    end
    return _dw_bits(r1, r2)
end
# flow_analysis/late_var_used_before_assignment_in_local_function_ok: a variable written inside a local
# function or closure and read after the call, or written outside and read inside
function _na_late_localfn(n::Int64)
    local x::Int64
    function wf()
        x = 10n
        return nothing
    end
    wf()
    local a = x == 10n
    local y::Int64
    local wc = () -> (y = 10n; nothing)
    wc()
    local b = y == 10n
    local z::Int64
    function rf()
        return z == 10n
    end
    z = 10n
    local w::Int64
    local rc = () -> w == 10n
    w = 10n
    return _dw_bits(a, b, rf(), rc())
end
# flow_analysis/late_var_used_before_assignment_in_loop: a variable written in one loop iteration and
# read in the next (for, for-each, while, do-while)
function _na_late_loop(n::Int64)
    local r = Int64(0)
    local x::Int64
    for i in 0:1
        i == 1 && (r += x)
        i == 0 && (x = 10n)
    end
    local y::Int64
    for b in (false, true)
        b && (r += 2y)
        !b && (y = 10n)
    end
    local z::Int64
    local i = 0
    while i < 2
        i == 1 && (r += 3z)
        i == 0 && (z = 10n)
        i += 1
    end
    local w::Int64
    local j = 0
    while true
        j == 1 && (r += 4w)
        j == 0 && (w = 10n)
        j += 1
        j < 2 || break
    end
    return r
end
# flow_analysis/late_var_used_before_assignment_in_switch: a labelled case reached by `continue L`
# from the case that assigns the variable (@goto)
function _na_late_switch(one::Int64)
    local x::Int64
    if one == 1
        x = 10
        @goto L
    elseif one == 0
        @goto L
    end
    return Int64(-1)
    @label L
    return x
end
# flow_analysis/local_boolean_defeated_by_assignment: a Bool holding a null test, defeated by a write
# to it or to the tested variable on a path reaching the use (an if, a later iteration, a catch)
function _na_dba_cond(x::_NaI, b2::Bool)
    local b = x !== nothing
    local r1 = b && x isa Int64
    b2 && (b = true)
    local r2 = b && x isa Int64
    return _dw_bits(r1, r2, b)
end
function _na_dba_prom(x::_NaI, b2::Bool, y::_NaI)
    local b = x !== nothing
    local r1 = b && x isa Int64
    b2 && (x = y)
    return _dw_bits(r1, b && x isa Int64)
end
function _na_dba_loop(x::_NaI, y::_NaI)
    local b = x !== nothing
    local r = Int64(0)
    local i = 0
    while i < 2
        r = 2r + (b && x isa Int64)
        x = y
        i += 1
    end
    return r
end
function _na_dba_catch(x::_NaI, y::_NaI)
    local b = x !== nothing
    try
        throw(ErrorException("e"))
    catch
        x = y
    end
    return b && x isa Int64
end
# flow_analysis/local_boolean_defeated_by_capture: a Bool or the tested variable written by a closure
function _na_dbc(x0::_NaI)
    local x::_NaI = x0
    local b::Bool
    local f = (b2::Bool) -> (b = b2)
    b = x !== nothing
    local r1 = b && x isa Int64
    local c::Bool = x !== nothing
    local r2 = c && x isa Int64
    local g = (z::_NaI) -> (x = z)
    local r3 = c && x isa Int64
    g(nothing)
    local r4 = c && x isa Int64
    f(false)
    return _dw_bits(r1, r2, r3, r4, b)
end
# flow_analysis/local_boolean_does_not_detect_aliases: a copy of the tested variable, and a copy of
# the condition Bool
function _na_alias(x::_NaI)
    local y::_NaI = x
    local b = x !== nothing
    local r1 = b ? (x isa Int64 && y isa Int64) : y === nothing
    local b1 = x !== nothing
    local b2 = b1
    local r2 = b1 ? x isa Int64 : x === nothing
    local r3 = b2 ? x isa Int64 : x === nothing
    return _dw_bits(r1, r2, r3, b2)
end
# flow_analysis/local_boolean_expression_types: a Bool from is, !is, ==/!= nothing, &&, ||, ?:, and an
# assignment, used by if, !, &&, ||, while and do-while
_na_et_true(x) = true
_na_et_false(x) = false
function _na_et(x::_NaO, y::_NaO, z::_NaI)
    local s = Int64(0)
    local b = x isa Int64
    if (b)
        s += x::Int64
    end
    if !b
        s += 10
    else
        s += x::Int64
    end
    (b && _na_et_true(x::Int64)) && (s += x::Int64)
    (_na_et_true(x) && b) && (s += x::Int64)
    (b || _na_et_false(x)) && (s += 100)
    while b
        s += x::Int64
        _na_et_true(nothing) && break
    end
    while true
        s += 1000
        _na_et_true(nothing) && break
        b || break
    end
    local c = !(x isa Int64)
    !c && (s += x::Int64)
    local d = z === nothing
    !d && (s += z::Int64)
    local e = nothing !== z
    e && (s += z::Int64)
    local f = x isa String && y isa String
    f && (s += ncodeunits(x::String) + ncodeunits(y::String))
    local o = x isa Int64 || y isa Int64
    o || (s += 10000)
    local g = x isa Int64 ? true : false
    g && (s += x::Int64)
    local h
    local k = (h = x isa Int64)
    (k && h) && (s += x::Int64)
    return s
end
# flow_analysis/local_boolean_implicitly_typed_new: untyped Bool locals initialized or assigned with a
# null test, of a parameter, a reassigned parameter and a local
function _na_itn(x::_NaI, y::_NaI)
    local s = Int64(0)
    local b1 = x !== nothing
    b1 && (s += (x::Int64) + 1)
    local b2
    b2 = x !== nothing
    b2 && (s += 2(x::Int64) + 2)
    x = y
    local b3 = x !== nothing
    b3 && (s += 4(x::Int64) + 4)
    local w::_NaI = y
    local b4 = w !== nothing
    b4 && (s += 8(w::Int64) + 8)
    return s
end
# flow_analysis/local_boolean_join_equivalent: the same null test assigned to a Bool on both paths of
# an if, a loop's break, an enum switch, a try/catch and a labelled block, then used after the join
@enum _NaJeE _na_je_E1 _na_je_E2
function _na_je(x::_NaI, b1::Bool, e::_NaJeE)
    local s = Int64(0)
    local b2::Bool
    if b1
        b2 = x !== nothing
    else
        b2 = x !== nothing
    end
    b2 && (s += 1)
    local b3::Bool = false
    for i in 0:0
        if b1
            b3 = x !== nothing
            break
        end
        b3 = x !== nothing
    end
    b3 && (s += 2)
    local b4::Bool
    if e == _na_je_E1
        b4 = x !== nothing
    elseif e == _na_je_E2
        b4 = x !== nothing
    end
    b4 && (s += 4)
    local b5::Bool
    try
        b1 && throw(ErrorException("foo"))
        b5 = x !== nothing
    catch
        b5 = x !== nothing
    end
    b5 && (s += 8)
    local b6::Bool
    if b1
        b6 = x !== nothing
        @goto label
    end
    b6 = x !== nothing
    @label label
    b6 && (s += 16)
    return s + (x === nothing ? Int64(0) : 32 * (x::Int64))
end
# flow_analysis/local_boolean_logical_op: two condition Bools combined by && and ||, invalidated by
# writes to the tested variables or to a condition
function _na_lo_and(x::_NaI, y::_NaI, z::_NaI, b::Bool)
    local s = Int64(0)
    local b1 = x isa Int64
    local b2 = y isa Int64
    (b1 && b2) && (s += 1)
    b1 = x isa Int64
    x = z
    b2 = y isa Int64
    (b1 && b2) && (s += 2 * (x isa Int64))
    b1 = x isa Int64
    b1 = b
    b2 = y isa Int64
    (b1 && b2) && (s += 4)
    b1 = x isa Int64
    b2 = y isa Int64
    y = z
    (b1 && b2) && (s += 8 * (y isa Int64))
    return s
end
function _na_lo_or(x::_NaI, y::_NaI, z::_NaI, b::Bool)
    local s = Int64(0)
    local b1 = x === nothing
    local b2 = y === nothing
    (b1 || b2) || (s += (x::Int64) + (y::Int64))
    b1 = x === nothing
    x = z
    (b1 || b2) || (s += 100 * (x isa Int64))
    b1 = b
    (b1 || b2) || (s += 1000)
    return s
end
# flow_analysis/local_boolean_null: a comparison against a local holding nothing
function _na_lbnull(x::_NaI)
    local a = x === nothing ? x === nothing : x isa Int64
    local y::_NaI = nothing
    local c = x === y
    return _dw_bits(a, c)
end
# flow_analysis/local_boolean_promoted_on_assignment: a nullable Bool, and a union narrowed to Bool by
# being assigned a null test, then used as the condition
function _na_lbpoa(x::_NaI)
    local s = Int64(0)
    local b::Union{Nothing,Bool} = nothing
    b = x !== nothing
    (b::Bool) && (s += (x::Int64) + 1)
    local o::Union{Bool,Vector{Int64}} = Int64[]
    if !(o isa Bool)
        o = x !== nothing
        (o::Bool) && (s += 2(x::Int64) + 2)
    end
    local c::Union{Nothing,Bool} = x !== nothing
    (c::Bool) && (s += 4)
    return s
end
# flow_analysis/local_boolean_promoted: a union-typed local holding a null test, narrowed to Bool
function _na_lbprom(x::_NaI)
    local b::Union{Bool,Int64} = x !== nothing
    return (b isa Bool && b) ? (x::Int64) + 1 : Int64(0)
end
# flow_analysis/local_boolean: condition locals typed Bool, nullable Bool or untyped, initialized or
# assigned later, over a parameter, a reassigned parameter and locals
function _na_lb(x::_NaI, y::_NaI)
    local s = Int64(0)
    local b1::Bool = x !== nothing
    b1 && (s += 1 + (x::Int64))
    local b2::Bool
    b2 = x !== nothing
    b2 && (s += 2)
    local b3::Union{Nothing,Bool} = x !== nothing
    (b3::Bool) && (s += 4)
    local b4 = x !== nothing
    b4 && (s += 8)
    x = y
    local b5::Bool = x !== nothing
    b5 && (s += 16 + (x::Int64))
    local w::_NaI = y
    local b6::Bool = w !== nothing
    b6 && (s += 32)
    local v::_NaI
    v = y
    local b7::Bool
    b7 = v !== nothing
    b7 && (s += 64)
    return s
end
# flow_analysis/local_boolean_try_finally: a condition Bool assigned in try or in finally, used in the
# other block and after
function _na_lbtf(x::_NaI, b2::Bool)
    local s = Int64(0)
    local b::Bool = b2
    try
        b = x !== nothing
        b && (s += (x::Int64) + 1)
    finally
        b && (s += 2)
    end
    b && (s += 4)
    local c::Bool
    try
        c = x !== nothing
    finally
        nothing
    end
    c && (s += 8)
    local d::Bool = b2
    try
        d && (s += 16)
    finally
        d = x !== nothing
    end
    d && (s += 32)
    local e::Bool
    try
        nothing
    finally
        e = x !== nothing
    end
    e && (s += 64)
    return s
end
# flow_analysis/local_boolean_undefeated_by_assignment: a write followed by a throw on the same path,
# so it cannot reach the later use of the condition
function _na_lbu(x::_NaI, b2::Bool, y::_NaI)
    local s = Int64(0)
    try
        local b = x !== nothing
        b && (s += 1)
        b2 && (b = true; throw("foo"))
        b && (s += 2)
    catch err
        err isa String || rethrow()
    end
    try
        local c = x !== nothing
        b2 && (x = y; throw("foo"))
        c && (s += 4 * (x isa Int64))
    catch err
        err isa String || rethrow()
    end
    return s
end
# flow_analysis/null_shorting_in_cascade: null-aware calls, property and index reads in one cascade
# section, and `??=` through a getter and an index operator
struct _NaNsD end
struct _NaNsE end
struct _NaNsC{T}
    t::T
end
_na_ns_f(::_NaNsD, cnt::Base.RefValue{Int64}, v::_NaI) = (cnt[] += v === nothing ? 1 : 10; nothing)
_na_ns_d(d::_NaNsD) = d
_na_ns_index(d::_NaNsD, ::Int64) = d
_na_ns_eindex(::_NaNsE, ::Int64) = nothing
_na_ns_eset(::_NaNsE, ::Int64, ::Int64, cnt::Base.RefValue{Int64}) = (cnt[] += 100; nothing)
function _na_ns(i::_NaI)
    local cnt = Ref(Int64(0))
    local c = _NaNsC{Union{Nothing,_NaNsD}}(_NaNsD())
    local t = c.t
    t === nothing || _na_ns_f(t, cnt, nothing)
    t === nothing || _na_ns_f(t, cnt, something(i))
    t === nothing || _na_ns_f(t, cnt, i)
    t === nothing || _na_ns_f(_na_ns_d(t), cnt, nothing)
    t === nothing || _na_ns_f(_na_ns_index(t, 0), cnt, nothing)
    c.t === nothing && something(i)
    local e = _NaNsC{_NaNsE}(_NaNsE())
    _na_ns_eindex(e.t, 0) === nothing && _na_ns_eset(e.t, 0, something(i), cnt)
    return cnt[] + 1000 * (c.t isa _NaNsD)
end
# flow_analysis/null_shorting_in_conditional: a null-aware field chain as one arm of ?:
struct _NaNcD
    i::Int64
end
struct _NaNcC
    d::_NaNcD
end
function _na_nc(b::Bool, c::Union{Nothing,_NaNcC}, d::_NaNcD)
    local v1 = b ? (c === nothing ? nothing : c.d) : d
    local v2 = b ? d : (c === nothing ? nothing : c.d)
    local v3 = b ? (c === nothing ? nothing : c.d.i) : d.i
    local v4 = b ? d.i : (c === nothing ? nothing : c.d.i)
    return _dw_bits(v1 === nothing, v2 === nothing, v3 === nothing, v4 === nothing) + 16 * (something(v3, Int64(-1)) + 1)
end
# flow_analysis/postfix_increment_decrement: x += 1 / x -= 1 on a narrowed Int64, and on a struct whose
# + returns its abstract supertype
abstract type _NaPiB end
abstract type _NaPiC <: _NaPiB end
struct _NaPiD <: _NaPiC end
Base.:+(d::_NaPiD, ::Int64)::_NaPiC = d
Base.:-(d::_NaPiD, ::Int64)::_NaPiC = d
function _na_pi_int(x::Union{Int64,Float64})
    local r = false
    if x isa Int64
        x += 1
        r = x isa Int64
        x -= 1
        r = r && x isa Int64
    end
    return r
end
function _na_pi_inc(x::_NaPiB)
    if x isa _NaPiC
        if x isa _NaPiD
            x += 1
            return x isa _NaPiC
        end
    end
    return false
end
function _na_pi_dec(x::_NaPiB)
    if x isa _NaPiC
        if x isa _NaPiD
            x -= 1
            return x isa _NaPiC
        end
    end
    return false
end
# flow_analysis/this_not_promoted: === nothing and isa tests on a method's receiver, and on a nullable
# receiver
abstract type _NaTnBase end
struct _NaTnC <: _NaTnBase end
struct _NaTnD <: _NaTnBase end
struct _NaTnG end
_na_tn_methods(this::_NaTnBase) = _dw_bits(this === nothing, this isa _NaTnBase, this isa _NaTnD)
_na_tn_ext(this::Union{Nothing,_NaTnG}) = _dw_bits(this === nothing, this isa Union{Nothing,_NaTnG}, this isa _NaTnG)
# flow_analysis/this_property_not_promoted: a receiver's nullable field tested with ===, !== and isa,
# then read again
struct _NaTpnpC
    f::_NaI
end
_na_tpnp_eq(this::_NaTpnpC) = this.f === nothing ? this.f === nothing : this.f isa Int64
_na_tpnp_ne(this::_NaTpnpC) = this.f !== nothing ? this.f isa Int64 : this.f === nothing
_na_tpnp_is(this::_NaTpnpC) = this.f isa Int64 ? this.f isa Int64 : this.f === nothing
# flow_analysis/unreachable_via_expr_property: branches on a property of a function's result whose
# type is Nothing, tested with === nothing and isa Union{}
struct _NaUeC end
_na_ue_null(::_NaUeC) = nothing
_na_ue_objq(::_NaUeC)::_NaI = nothing
function _na_ue_eqs(x::_NaI, y::_NaI, f)
    (x === nothing || y === nothing) && return Int64(-1)
    if _na_ue_null(f()) === nothing
        x = nothing
    else
        y = nothing
    end
    return _dw_bits(x === nothing, y === nothing)
end
function _na_ue_eqb(x::_NaI, y::_NaI, f)
    (x === nothing || y === nothing) && return Int64(-1)
    if _na_ue_objq(f()) isa Nothing
        if _na_ue_objq(f()) === nothing
            x = nothing
        else
            y = nothing
        end
    end
    return _dw_bits(x === nothing, y === nothing)
end
function _na_ue_iss(x::_NaI, y::_NaI, f)
    (x === nothing || y === nothing) && return Int64(-1)
    if _na_ue_null(f()) isa Union{}
        x = nothing
    else
        y = nothing
    end
    return _dw_bits(x === nothing, y === nothing)
end
function _na_ue_isb(x::_NaI, y::_NaI, f)
    (x === nothing || y === nothing) && return Int64(-1)
    if _na_ue_objq(f()) isa Nothing
        if _na_ue_objq(f()) isa Union{}
            x = nothing
        else
            y = nothing
        end
    end
    return _dw_bits(x === nothing, y === nothing)
end
# flow_analysis/unreachable_via_getter_get: a getter whose inferred type is Union{} (it always throws)
# on the only path that skips the isa narrowing
_na_ugg_never() = throw(ErrorException("x"))
struct _NaUggT{T} end
_na_ugg_tget(::_NaUggT{T}) where {T} = throw(ErrorException("x"))
function _na_ugg(x::_NaO, b::Bool)
    if !(x isa Int64)
        if b
            _na_ugg_never()
        else
            return false
        end
    end
    return iseven(x::Int64)
end
function _na_ugg_t(t::_NaUggT, x::_NaO, b::Bool)
    if !(x isa Int64)
        if b
            _na_ugg_tget(t)
        else
            return false
        end
    end
    return iseven(x::Int64)
end
# flow_analysis/unreachable_via_invocation: a call returning Union{} on the only path that skips the
# isa narrowing
_na_uvi_never() = throw(ErrorException("x"))
struct _NaUviT{T} end
_na_uvi_tmethod(::_NaUviT{T}) where {T} = throw(ErrorException("x"))
function _na_uvi(x::_NaO, b::Bool)
    if !(x isa Int64)
        if b
            _na_uvi_never()
        else
            return false
        end
    end
    return iseven(x::Int64)
end
function _na_uvi_t(t::_NaUviT, x::_NaO, b::Bool)
    if !(x isa Int64)
        if b
            _na_uvi_tmethod(t)
        else
            return false
        end
    end
    return iseven(x::Int64)
end
# flow_analysis/unreachable_via_never: a cast to Union{}, `?? throw`, `??= throw`, isa Union{}, a
# non-null assertion of nothing and a null-aware call on nothing
_na_uvn_ext(o) = nothing
function _na_uvn_as(x::_NaI, i::Int64)
    x === nothing && (i::Union{})
    return x::Int64
end
function _na_uvn_ifnull(x::_NaI, f)
    x === nothing && (v = f(); v === nothing ? throw(ErrorException("")) : v)
    return x::Int64
end
function _na_uvn_ifnullassign(x::_NaI, n::Nothing)
    x === nothing && n === nothing && throw(ErrorException(""))
    return x::Int64
end
function _na_uvn_ifexpr(x::_NaI, y::_NaI, f)
    (x === nothing || y === nothing) && return Int64(-1)
    if f() isa Union{}
        x = nothing
    else
        y = nothing
    end
    return _dw_bits(x === nothing, y === nothing)
end
function _na_uvn_nonnull(x::_NaI, f)
    x === nothing && something(f())
    return x::Int64
end
function _na_uvn_nullaware(x::_NaI, y::_NaI, f, g)
    (x === nothing || y === nothing) && return Int64(-1)
    f() === nothing || (x = nothing; _na_uvn_ext(x))
    g() === nothing || (y = nothing; _na_uvn_ext(y))
    return _dw_bits(x === nothing, y === nothing)
end
# flow_analysis/unreachable_via_promotion: isa Union{} (directly and through a type parameter) and
# !== nothing on a Nothing, on the only path that skips the isa narrowing
function _na_uvp_is(x::_NaO, y::Union{Nothing,Int64,String})
    if !(x isa Int64)
        if y isa Union{}
        else
            return false
        end
    end
    return iseven(x::Int64)
end
function _na_uvp_tv(::Type{T}, x::_NaO, y::Union{Nothing,Int64,String}) where {T}
    if !(x isa Int64)
        if y isa T
        else
            return false
        end
    end
    return iseven(x::Int64)
end
function _na_uvp_null(x::_NaO, y::Nothing)
    if !(x isa Int64)
        if y !== nothing
        else
            return false
        end
    end
    return iseven(x::Int64)
end
# flow_analysis/unreachable_via_this_property: branches on a receiver's Nothing-typed property, from
# methods of two subtypes
abstract type _NaUtpB end
struct _NaUtpC <: _NaUtpB end
struct _NaUtpD <: _NaUtpB end
_na_utp_null(::_NaUtpB) = nothing
_na_utp_objq(::_NaUtpB)::_NaI = nothing
function _na_utp_eqs(this::_NaUtpB, x::_NaI, y::_NaI)
    (x === nothing || y === nothing) && return Int64(-1)
    if _na_utp_null(this) === nothing
        x = nothing
    else
        y = nothing
    end
    return _dw_bits(x === nothing, y === nothing)
end
function _na_utp_eqb(this::_NaUtpB, x::_NaI, y::_NaI)
    (x === nothing || y === nothing) && return Int64(-1)
    if _na_utp_objq(this) isa Nothing
        if _na_utp_objq(this) === nothing
            x = nothing
        else
            y = nothing
        end
    end
    return _dw_bits(x === nothing, y === nothing)
end
function _na_utp_iss(this::_NaUtpB, x::_NaI, y::_NaI)
    (x === nothing || y === nothing) && return Int64(-1)
    if _na_utp_null(this) isa Union{}
        x = nothing
    else
        y = nothing
    end
    return _dw_bits(x === nothing, y === nothing)
end
function _na_utp_isb(this::_NaUtpB, x::_NaI, y::_NaI)
    (x === nothing || y === nothing) && return Int64(-1)
    if _na_utp_objq(this) isa Nothing
        if _na_utp_objq(this) isa Union{}
            x = nothing
        else
            y = nothing
        end
    end
    return _dw_bits(x === nothing, y === nothing)
end
_na_utp_all(this::_NaUtpB, x::Int64) = _na_pack(_na_utp_eqs(this, x, x), _na_utp_eqb(this, x, x), _na_utp_iss(this, x, x), _na_utp_isb(this, x, x))
# flow_analysis/unreachable_via_this: === nothing, isa Nothing and isa Union{} on a receiver, non-null
# or nullable and nothing
struct _NaUvtC end
struct _NaUvtE end
const _NaUvtR = Union{Nothing,_NaUvtC,_NaUvtE}
function _na_uvt_eqs(this::_NaUvtR, x::_NaI, y::_NaI)
    (x === nothing || y === nothing) && return Int64(-1)
    if this === nothing
        x = nothing
    else
        y = nothing
    end
    return _dw_bits(x === nothing, y === nothing)
end
function _na_uvt_eqb(this::_NaUvtR, x::_NaI, y::_NaI)
    (x === nothing || y === nothing) && return Int64(-1)
    if this isa Nothing
        if this === nothing
            x = nothing
        else
            y = nothing
        end
    end
    return _dw_bits(x === nothing, y === nothing)
end
function _na_uvt_iss(this::_NaUvtR, x::_NaI, y::_NaI)
    (x === nothing || y === nothing) && return Int64(-1)
    if this isa Union{}
        x = nothing
    else
        y = nothing
    end
    return _dw_bits(x === nothing, y === nothing)
end
function _na_uvt_isb(this::_NaUvtR, x::_NaI, y::_NaI)
    (x === nothing || y === nothing) && return Int64(-1)
    if this isa Nothing
        if this isa Union{}
            x = nothing
        else
            y = nothing
        end
    end
    return _dw_bits(x === nothing, y === nothing)
end
_na_uvt_all(this::_NaUvtR, x::Int64) = _na_pack(_na_uvt_eqs(this, x, x), _na_uvt_eqb(this, x, x), _na_uvt_iss(this, x, x), _na_uvt_isb(this, x, x))
# flow_analysis/unreachable_via_variable_get: a never-assigned local read on the only path that skips
# the isa narrowing, inside a loop whose later write calls a function that always throws
function _na_uvvg(f, x::_NaO, b1::Bool, b2::Bool)
    local y
    while true
        if !(x isa Int64)
            if b1
                y
            else
                return false
            end
        end
        local r = iseven(x::Int64)
        b2 && return r
        y = f()
    end
end
# flow_analysis/unreachable_via_variable_property: branches on a variable's Nothing-typed property
struct _NaUvvpC end
_na_uvvp_pnull(::_NaUvvpC) = nothing
_na_uvvp_pobjq(::_NaUvvpC)::_NaI = nothing
function _na_uvvp_eqs(x::_NaI, y::_NaI, c::_NaUvvpC)
    (x === nothing || y === nothing) && return Int64(-1)
    if _na_uvvp_pnull(c) === nothing
        x = nothing
    else
        y = nothing
    end
    return _dw_bits(x === nothing, y === nothing)
end
function _na_uvvp_eqb(x::_NaI, y::_NaI, c::_NaUvvpC)
    (x === nothing || y === nothing) && return Int64(-1)
    if _na_uvvp_pobjq(c) isa Nothing
        if _na_uvvp_pobjq(c) === nothing
            x = nothing
        else
            y = nothing
        end
    end
    return _dw_bits(x === nothing, y === nothing)
end
function _na_uvvp_iss(x::_NaI, y::_NaI, c::_NaUvvpC)
    (x === nothing || y === nothing) && return Int64(-1)
    if _na_uvvp_pnull(c) isa Union{}
        x = nothing
    else
        y = nothing
    end
    return _dw_bits(x === nothing, y === nothing)
end
function _na_uvvp_isb(x::_NaI, y::_NaI, c::_NaUvvpC)
    (x === nothing || y === nothing) && return Int64(-1)
    if _na_uvvp_pobjq(c) isa Nothing
        if _na_uvvp_pobjq(c) isa Union{}
            x = nothing
        else
            y = nothing
        end
    end
    return _dw_bits(x === nothing, y === nothing)
end
# flow_analysis/variable_property_not_promoted: a variable's nullable field tested with ===, !== and
# isa, then read again
struct _NaVpnpC
    f::_NaI
end
_na_vpnp_eq(c::_NaVpnpC) = c.f === nothing ? c.f === nothing : c.f isa Int64
_na_vpnp_ne(c::_NaVpnpC) = c.f !== nothing ? c.f isa Int64 : c.f === nothing
_na_vpnp_is(c::_NaVpnpC) = c.f isa Int64 ? c.f isa Int64 : c.f === nothing
# flow_analysis/write_promoted_value_in_loop: a narrowed variable assigned an Int64 in a loop's
# initializer and in a for-each's iterable, read in the body
function _na_wpl(x::_NaO)
    local s = Int64(0)
    if x isa Int64
        x = Int64(0)
        while true
            s += iseven(x::Int64)
            break
        end
        local y = (x = Int64(0))
        while true
            s += 2iseven(x::Int64)
            break
        end
        for y2 in [begin x = Int64(0) end]
            s += 4iseven(x::Int64)
            break
        end
    end
    return s
end
# flow_analysis/write_promoted_value_in_switch: a narrowed variable assigned in a switch's scrutinee or
# in a case body, read in cases with and without a label reached by `continue L` (@goto)
function _na_wps(x::_NaO)
    local s = Int64(0)
    if x isa Int64
        local v = (x = Int64(0))
        if v == 1
        else
            s += iseven(x::Int64)
        end
        local v2 = (x = Int64(0))
        if v2 == 1
        elseif v2 == 0
            s += 2iseven(x::Int64)
        end
        s += 4iseven(x::Int64)
        x = Int64(0)
        local v3 = (x = Int64(0))
        if v3 == 1
            @goto L
        end
        @label L
        s += 8iseven(x::Int64)
    end
    return s
end
# flow_analysis/write_promoted_value_in_try: a narrowed variable read then assigned in catch and in
# finally
function _na_wpt(x::_NaO)
    local s = Int64(0)
    if x isa Int64
        try
            nothing
        catch
            s += iseven(x::Int64)
            x = ""
        end
        try
            nothing
        finally
            s += 2iseven(x::Int64)
            x = Int64(0)
        end
    end
    return s
end

# type_promotion/assignment_inference_after_null_check: a nullable vector parameter assigned a fresh
# vector when nothing, then appended to
function _na_t_aianc(x::Union{Nothing,Vector{Int64}})
    if x === nothing
        x = Int64[]
    end
    push!(x, 0)
    return length(x)
end
# type_promotion/conditional_both: `x isa String || throw` in both arms of ?:, then a String use
function _na_t_condboth(b::Bool, x::_NaO)
    b ? (x isa String || throw(Int64(1))) : (x isa String || throw(Int64(2)))
    return ncodeunits(x::String)
end
# type_promotion/do_condition_is_not_type: a do-while looping while !(x isa String), then a String use
function _na_t_docnt(x::_NaO)
    local k = Int64(0)
    while true
        k += 1
        x isa String && break
    end
    return ncodeunits(x::String) + 100k
end
# type_promotion/do_outer_is_type: a String use inside and after a do-while within an isa branch
function _na_t_doouter(b::Bool, x::_NaO)
    local s = Int64(0)
    if x isa String
        while true
            s += ncodeunits(x::String)
            b || break
        end
        s += ncodeunits(x::String)
    end
    return s
end
# type_promotion/for_outer_is_type: a String use inside and after a for(;b;) within an isa branch
function _na_t_forouter(b::Bool, x::_NaO)
    local s = Int64(0)
    if x isa String
        while b
            s += 10ncodeunits(x::String)
            break
        end
        s += ncodeunits(x::String)
    end
    return s
end
# type_promotion/function_expression_is_type_mutated_in_closure: a local function's parameter narrowed
# by isa while a nested closure writes it
function _na_t_femut(x0::_NaO)
    local x::_NaO = x0
    local a = x isa String ? ncodeunits(x::String) : Int64(-1)
    local h = () -> (x = Int64(42); nothing)
    local b = x isa String
    h()
    return _dw_bits(a == ncodeunits(string(x0)), b, x === Int64(42))
end
# type_promotion/function_expression_is_type: a closure's parameter narrowed by isa, then reassigned
function _na_t_feis(x0::_NaO)
    local g = (x::_NaO) -> (r = x isa String ? ncodeunits(x::String) : Int64(-1); x = Int64(42); r + x)
    return g(x0)
end
# type_promotion/function_expression_outer_is_type_assigned_outside: a closure assigned only in an isa
# branch, called after the narrowed variable is reassigned (unassigned when the branch did not run)
function _na_t_feouter(x0::_NaO)
    local x::_NaO = x0
    local g
    local r = Int64(0)
    if x isa String
        r = ncodeunits(x::String)
        g = () -> Int64(7)
    end
    x = Int64(42)
    return r + g()
end
# type_promotion/if_is_not_type: a String use in the else of `if !(x isa String)`
_na_t_ifnot(x::_NaO) = !(x isa String) ? Int64(-1) : ncodeunits(x::String)
# type_promotion/if_is_type: a String use in the then of `if x isa String`
_na_t_ifis(x::_NaO) = x isa String ? ncodeunits(x::String) : Int64(-1)
# type_promotion/logical_or_throw: `x isa String || throw(42)` then a String use
function _na_t_orthrow(x::_NaO)
    x isa String || throw(Int64(42))
    return ncodeunits(x::String)
end
# type_promotion/promoted_lhs_used_as_assignment_context: a Float64-narrowed variable assigned 1 (left
# untyped, and through a Float64-typed local), then a String
_na_t_g(x::Float64) = x
function _na_t_plhs(x0::Union{Float64,Int64,String})
    local x = x0
    local a = false
    local b = false
    local c = false
    if x isa Float64
        local y::Float64 = x
        y = 1
        _na_t_g(y)
        b = y isa Float64
        x = 1
        a = x isa Float64
        x = "foo"
        c = x isa String
    end
    return _dw_bits(a, b, c)
end
# type_promotion/try_catch_assigned_body: a narrowed variable reassigned in try, re-narrowed or returned
_na_t_noop() = nothing
function _na_t_tcab(x0::_NaO)
    local x::_NaO = x0
    x isa String || return Int64(-1)
    local r = ncodeunits(x::String)
    try
        x = Int64(42)
        _na_t_noop()
        x isa String || return r
        r += ncodeunits(x::String)
    catch
    end
    return r + 100
end
# type_promotion/try_catch_catch_finally_outer_is_type: a String use in try, catch, finally and after,
# within an isa branch
function _na_t_tccf(x::_NaO)
    local s = Int64(0)
    if x isa String
        try
            s += ncodeunits(x::String)
        catch
            s += 10ncodeunits(x::String)
        finally
            s += 100ncodeunits(x::String)
        end
        s += 1000ncodeunits(x::String)
    end
    return s
end
# type_promotion/try_catch_is_not_type_exit_body_catch: `isa String || return` in both try and catch,
# then a String use after
function _na_t_tcnebc(x::_NaO)
    local s = Int64(0)
    try
        x isa String || return Int64(-1)
        s += ncodeunits(x::String)
    catch
        x isa String || return Int64(-2)
        s += ncodeunits(x::String)
    end
    return s + ncodeunits(x::String)
end
# type_promotion/try_catch_is_not_type_exit_body: `isa String || return` in try, an empty catch
function _na_t_tcneb(x::_NaO)
    local s = Int64(0)
    try
        x isa String || return Int64(-1)
        s += ncodeunits(x::String)
    catch
    end
    return s
end
# type_promotion/try_finally_outer_is_type_assigned_body: a narrowed variable reassigned in try, read in
# finally
function _na_t_tfab(x0::_NaO)
    local x::_NaO = x0
    local s = Int64(0)
    if x isa String
        try
            s += ncodeunits(x::String)
            x = Int64(42)
        finally
            s += x isa Int64 ? Int64(100) : Int64(0)
        end
    end
    return s
end
# type_promotion/try_finally_outer_is_type_assigned_finally: a narrowed variable read in try and in
# finally, then reassigned in finally
function _na_t_tfaf(x0::_NaO)
    local x::_NaO = x0
    local s = Int64(0)
    if x isa String
        try
            s += ncodeunits(x::String)
        finally
            s += 10ncodeunits(x::String)
            x = Int64(42)
        end
        s += x isa Int64 ? Int64(100) : Int64(0)
    end
    return s
end
# type_promotion/while_condition_false: a String use after `while !(x isa String)`
function _na_t_wcf(x::_NaO)
    while !(x isa String)
    end
    return ncodeunits(x::String)
end
# type_promotion/while_condition_true: a String use inside `while x isa String`
function _na_t_wct(x::_NaO)
    local s = Int64(0)
    while x isa String
        s += ncodeunits(x::String)
        break
    end
    return s
end

# static_errors/equals_parameter_made_nullable_at_invoke: == between a value and nothing, and a
# struct's identity == compared with nothing
mutable struct _NaSEqC end
Base.:(==)(a::_NaSEqC, other::_NaSEqC) = a === other
function _na_s_eqnull(n::Int64)
    local o = n
    local foInt::_NaI = nothing
    local c = _NaSEqC()
    return _dw_bits(o == nothing, o == foInt, c == c, c == _NaSEqC(), c == nothing)
end
# static_errors/implicit_downcasts: an explicit downcast of a union-typed value to Int64, succeeding
# and failing
function _na_s_downcast(n::Int64)
    local asDynamic::Union{Int64,Float64,String} = n
    local asInt3::Int64 = asDynamic::Int64
    local d2::Union{Int64,Float64,String} = 1.5
    local t = try
        d2::Int64
        false
    catch e
        e isa TypeError
    end
    return _dw_bits(asInt3 == n, t)
end
# static_errors/non_null_assertion: a non-null assertion (something) of nothing
_na_s_nna(n::Int64) = (iq::_NaI = n == 1 ? nothing : n; something(iq))
# static_errors/not_assigned_local_if_then_else: a local assigned on both arms of an if, then read
function _na_s_naite(b::Bool)
    local v::Int64
    if b
        v = 0
    else
        v = 1
    end
    return v
end
# static_errors/not_assigned_local_try_catch_body_catch: a local assigned at the end of try and in catch
_na_s_g(n::Int64) = n < 0 ? throw(ErrorException("g")) : nothing
function _na_s_natcbc(n::Int64)
    local v::Int64
    try
        _na_s_g(n)
        v = 0
    catch
        v = 1
    end
    return v
end
# static_errors/not_assigned_local_while_true_break_after: a local assigned before a while(true)'s break
function _na_s_nawtba(b::Bool)
    local v::Int64
    while true
        v = 0
        b && break
    end
    return v
end
# static_errors/nullable_function_types: a callable struct called, and a null-aware tear-off of a
# nullable one
struct _NaSNfC end
(c::_NaSNfC)() = Int64(7)
function _na_s_nft(n::Int64)
    local c1 = _NaSNfC()
    local nc1::Union{Nothing,_NaSNfC} = nothing
    local nf3 = nc1 === nothing ? nothing : nc1
    return c1() + n + (nf3 === nothing ? Int64(0) : Int64(100))
end
# static_errors/super_equals_allows_null: `super == x` as invoke of the supertype's ==, skipped when x
# is nothing; a covariant Real parameter given a String throws
abstract type _NaSSeBaseObject end
mutable struct _NaSSeDerivedObject <: _NaSSeBaseObject
    calls::Int64
    last::_NaI
end
function _na_s_se_eq(this::_NaSSeBaseObject, other)
    this.calls += 1
    this.last = other
    return false
end
_na_s_se_super(this::_NaSSeDerivedObject, o::_NaI) = o === nothing ? false : invoke(_na_s_se_eq, Tuple{_NaSSeBaseObject,Any}, this, o)
abstract type _NaSSeBaseNum end
mutable struct _NaSSeDerivedNum <: _NaSSeBaseNum
    calls::Int64
    last::_NaI
end
function _na_s_se_eqnum(this::_NaSSeBaseNum, other)
    local o = other::Real
    this.calls += 1
    this.last = o
    return false
end
_na_s_se_supernum(this::_NaSSeDerivedNum, o::Union{Nothing,Int64,String}) = o === nothing ? false : invoke(_na_s_se_eqnum, Tuple{_NaSSeBaseNum,Any}, this, o)
function _na_s_se(n::Int64)
    local d = _NaSSeDerivedObject(0, nothing)
    local a1 = !_na_s_se_super(d, nothing) && d.calls == 0
    local a2 = !_na_s_se_super(d, n) && d.calls == 1 && d.last === n
    local m = _NaSSeDerivedNum(0, nothing)
    local a3 = !_na_s_se_supernum(m, nothing) && m.calls == 0
    local a4 = !_na_s_se_supernum(m, n + 1) && m.calls == 1 && m.last === n + 1
    local a5 = try
        _na_s_se_supernum(m, "foo")
        false
    catch e
        e isa TypeError
    end
    return _dw_bits(a1, a2, a3, a4, a5, m.calls == 1)
end
# static_errors/this_reference_in_late_field: a field initialized lazily to its own receiver
mutable struct _NaSTrC
    x::Union{Nothing,_NaSTrC}
    _NaSTrC() = new(nothing)
end
_na_s_tr_x(c::_NaSTrC) = (c.x === nothing && (c.x = c); c.x)
# static_errors/throw_of_invalid_type: an Int64 thrown and caught
_na_s_f1(a::Int64) = try
    throw(a)
catch e
    e isa Int64 ? (e::Int64) : Int64(-1)
end
# static_errors/unchecked_use_of_nullable: the operations allowed on nothing (string, hash, typeof,
# ??=, === nothing, null-aware calls, a null-aware spread) and a non-null assertion of nothing
function _na_s_unn(n::Int64)
    local x::_NaI = nothing
    local cond::Union{Nothing,Bool} = nothing
    local list::Union{Nothing,Vector{Int64}} = nothing
    local a = string(x) == "nothing"
    local b = hash(x) == hash(nothing) && typeof(x) === Nothing
    local q = x === nothing ? nothing : iseven(x)
    x === nothing && (x = n)
    local c = x === n
    local d = try
        something(cond)
        false
    catch e
        e isa ArgumentError
    end
    local e1 = (cond === nothing ? nothing : cond) === nothing
    local f = cond === nothing && !(cond !== nothing)
    local g = (x === nothing ? nothing : iseven(x)) === iseven(n)
    local spread = list === nothing ? Int64[] : copy(list)
    return _dw_bits(a, b, q === nothing, c, d, e1, f, g, isempty(spread))
end
# static_errors/unchecked_use_of_nullable_cascaded: null-aware cascade sections on nothing (skipped)
# and toString/typeof on it
function _na_s_unc(n::Int64)
    local list::Union{Nothing,Vector{Int64}} = nothing
    list === nothing || push!(list, n)
    local s = string(list)
    list === nothing || (list[end] = n)
    list === nothing || (list[1] = n)
    local t = typeof(list)
    local list2::Union{Nothing,Vector{Int64}} = [n]
    list2 === nothing || push!(list2, n)
    return _dw_bits(list === nothing, s == "nothing", t === Nothing, length(something(list2)) == 2)
end

_g("dart_nnbd", Any[
    ("flow_analysis_boolean_parameter", (n::Int64) -> _dw_bits(_na_bp_bool(nothing, false), _na_bp_bool(n, false),
        _na_bp_obj(nothing, nothing), _na_bp_obj(n, "foo"), _na_bp_method(_NaBpC(), nothing, false), _na_bp_method(_NaBpC(), n, false),
        _na_bp_local(nothing) == 0, _na_bp_local(n) == 7), Int64(0)),
    ("flow_analysis_demotion_and_type_of_interest_promotion", (n::Int64) -> _na_demote(n), Int64(0)),
    ("flow_analysis_expr_property_not_promoted", (n::Int64) -> _dw_bits(_na_ep_eq(() -> _NaEpC(n)), _na_ep_is(() -> _NaEpC(n)),
        _na_ep_eq(() -> _NaEpC(nothing)), _na_ep_is(() -> _NaEpC(nothing))), Int64(1)),
    ("flow_analysis_identical", (n::Int64) -> 100 * _na_ident(nothing) + _na_ident(n), Int64(0)),
    ("flow_analysis_issue43093", (n::Int64) -> _dw_bits((try; _na_i43(true, _NaI43C(nothing)); false; catch e; e isa ArgumentError; end),
        _na_i43(true, _NaI43C(n)) === n, _na_i43(false, _NaI43C(n)) === nothing, _na_i43(true, nothing) === nothing), Int64(1)),
    ("flow_analysis_late_var_assigned_in_try", (n::Int64) -> _na_late_try(n), Int64(1)),
    ("flow_analysis_late_var_used_before_assignment_in_local_function_ok", (n::Int64) -> _na_late_localfn(n), Int64(1)),
    ("flow_analysis_late_var_used_before_assignment_in_loop", (n::Int64) -> _na_late_loop(n), Int64(1)),
    ("flow_analysis_late_var_used_before_assignment_in_switch", (n::Int64) -> _na_late_switch(n) + 100 * _na_late_switch(n + 1), Int64(1)),
    ("flow_analysis_local_boolean_defeated_by_assignment", (n::Int64) -> _na_pack(_na_dba_cond(n, true), _na_dba_cond(nothing, true),
        _na_dba_cond(nothing, false), _na_dba_prom(n, true, nothing), _na_dba_prom(n, false, nothing), _na_dba_loop(n, nothing),
        _na_dba_loop(nothing, n), Int64(_na_dba_catch(n, nothing)), Int64(_na_dba_catch(n, n))), Int64(0)),
    ("flow_analysis_local_boolean_defeated_by_capture", (n::Int64) -> 100 * _na_dbc(n) + _na_dbc(nothing), Int64(0)),
    ("flow_analysis_local_boolean_does_not_detect_aliases", (n::Int64) -> 100 * _na_alias(n) + _na_alias(nothing), Int64(0)),
    ("flow_analysis_local_boolean_expression_types", (n::Int64) -> _na_et("foo", "bar", nothing) + 3 * _na_et(n, "bar", n) +
        7 * _na_et(n, n + 1, nothing) + 11 * _na_et("foo", n, n), Int64(2)),
    ("flow_analysis_local_boolean_implicitly_typed_new", (n::Int64) -> _na_itn(nothing, nothing) + 3 * _na_itn(n, nothing) +
        5 * _na_itn(nothing, n) + 7 * _na_itn(n, n), Int64(1)),
    ("flow_analysis_local_boolean_join_equivalent", (n::Int64) -> _na_je(nothing, false, _na_je_E1) + 3 * _na_je(nothing, true, _na_je_E2) +
        5 * _na_je(n, false, _na_je_E1) + 7 * _na_je(n, true, _na_je_E2), Int64(1)),
    ("flow_analysis_local_boolean_logical_op", (n::Int64) -> (vs = _NaI[n, nothing]; s = Int64(0);
        for x in vs, y in vs, z in vs, b in (true, false); s = 3s + _na_lo_and(x, y, z, b) + _na_lo_or(x, y, z, b); end; s), Int64(1)),
    ("flow_analysis_local_boolean_null", (n::Int64) -> 10 * _na_lbnull(n) + _na_lbnull(nothing), Int64(0)),
    ("flow_analysis_local_boolean_promoted_on_assignment", (n::Int64) -> 100 * _na_lbpoa(n) + _na_lbpoa(nothing), Int64(1)),
    ("flow_analysis_local_boolean_promoted", (n::Int64) -> 100 * _na_lbprom(n) + _na_lbprom(nothing), Int64(1)),
    ("flow_analysis_local_boolean", (n::Int64) -> _na_lb(nothing, nothing) + 3 * _na_lb(nothing, n) + 5 * _na_lb(n, nothing) + 7 * _na_lb(n, n), Int64(1)),
    ("flow_analysis_local_boolean_try_finally", (n::Int64) -> _na_lbtf(nothing, false) + 3 * _na_lbtf(nothing, true) +
        5 * _na_lbtf(n, false) + 7 * _na_lbtf(n, true), Int64(1)),
    ("flow_analysis_local_boolean_undefeated_by_assignment", (n::Int64) -> _na_pack(_na_lbu(n, true, nothing), _na_lbu(nothing, true, nothing),
        _na_lbu(n, false, nothing), _na_lbu(nothing, false, n)), Int64(0)),
    ("flow_analysis_null_shorting_in_cascade", (n::Int64) -> _na_ns(n), Int64(0)),
    ("flow_analysis_null_shorting_in_conditional", (n::Int64) -> (cs = Union{Nothing,_NaNcC}[nothing, _NaNcC(_NaNcD(n))]; s = Int64(0);
        for b in (false, true), c in cs; s = 100s + _na_nc(b, c, _NaNcD(n + 1)); end; s), Int64(0)),
    ("flow_analysis_postfix_increment_decrement", (n::Int64) -> _dw_bits(_na_pi_int(n), _na_pi_int(1.0), _na_pi_inc(_NaPiD()), _na_pi_dec(_NaPiD())), Int64(0)),
    ("flow_analysis_this_not_promoted", (n::Int64) -> _na_pack(_na_tn_methods(_NaTnC()), _na_tn_methods(_NaTnD()), _na_tn_ext(_NaTnG()),
        _na_tn_ext(nothing)) + n, Int64(0)),
    ("flow_analysis_this_property_not_promoted", (n::Int64) -> _dw_bits(_na_tpnp_eq(_NaTpnpC(n)), _na_tpnp_ne(_NaTpnpC(n)), _na_tpnp_is(_NaTpnpC(n)),
        _na_tpnp_eq(_NaTpnpC(nothing)), _na_tpnp_ne(_NaTpnpC(nothing)), _na_tpnp_is(_NaTpnpC(nothing))), Int64(1)),
    ("flow_analysis_unreachable_via_expr_property", (n::Int64) -> (f = () -> _NaUeC(); _na_pack(_na_ue_eqs(n, n, f), _na_ue_eqb(n, n, f),
        _na_ue_iss(n, n, f), _na_ue_isb(n, n, f), _na_ue_eqs(nothing, n, f) + 2)), Int64(1)),
    ("flow_analysis_unreachable_via_getter_get", (n::Int64) -> _dw_bits(_na_ugg(n, false), _na_ugg_t(_NaUggT{Union{}}(), n, false),
        _na_ugg("x", false), (try; _na_ugg("x", true); false; catch e; e isa ErrorException; end)), Int64(0)),
    ("flow_analysis_unreachable_via_invocation", (n::Int64) -> _dw_bits(_na_uvi(n, false), _na_uvi_t(_NaUviT{Union{}}(), n, false),
        _na_uvi("x", false), (try; _na_uvi_t(_NaUviT{Union{}}(), "x", true); false; catch e; e isa ErrorException; end)), Int64(0)),
    ("flow_analysis_unreachable_via_never", (n::Int64) -> _na_pack(_na_uvn_as(n, n), _na_uvn_ifnull(n, () -> nothing), _na_uvn_ifnullassign(n, nothing),
        _na_uvn_ifexpr(n, n, () -> n), _na_uvn_nonnull(n, () -> nothing), _na_uvn_nullaware(n, n, () -> nothing, () -> n),
        (try; _na_uvn_as(nothing, n); Int64(0); catch e; e isa TypeError ? Int64(1) : Int64(2); end)), Int64(1)),
    ("flow_analysis_unreachable_via_promotion", (n::Int64) -> _dw_bits(_na_uvp_is(n, "foo"), _na_uvp_tv(Union{}, n, "foo"),
        _na_uvp_tv(Any, n, "foo"), _na_uvp_null(n, nothing), _na_uvp_is("x", "foo"), _na_uvp_null("x", nothing)), Int64(0)),
    ("flow_analysis_unreachable_via_this_property", (n::Int64) -> 65536 * _na_utp_all(_NaUtpC(), n) + _na_utp_all(_NaUtpD(), n), Int64(1)),
    ("flow_analysis_unreachable_via_this", (n::Int64) -> _na_uvt_all(_NaUvtC(), n) * 4294967296 + _na_uvt_all(_NaUvtE(), n) * 65536 + _na_uvt_all(nothing, n), Int64(1)),
    ("flow_analysis_unreachable_via_variable_get", (n::Int64) -> _dw_bits(_na_uvvg(() -> throw(ErrorException("x")), n, false, true),
        _na_uvvg(() -> throw(ErrorException("x")), "x", false, true),
        (try; _na_uvvg(() -> throw(ErrorException("x")), n, false, false); false; catch e; e isa ErrorException; end)), Int64(0)),
    ("flow_analysis_unreachable_via_variable_property", (n::Int64) -> (c = _NaUvvpC(); _na_pack(_na_uvvp_eqs(n, n, c), _na_uvvp_eqb(n, n, c),
        _na_uvvp_iss(n, n, c), _na_uvvp_isb(n, n, c))), Int64(1)),
    ("flow_analysis_variable_property_not_promoted", (n::Int64) -> _dw_bits(_na_vpnp_eq(_NaVpnpC(n)), _na_vpnp_ne(_NaVpnpC(n)), _na_vpnp_is(_NaVpnpC(n)),
        _na_vpnp_eq(_NaVpnpC(nothing)), _na_vpnp_ne(_NaVpnpC(nothing)), _na_vpnp_is(_NaVpnpC(nothing))), Int64(1)),
    ("flow_analysis_write_promoted_value_in_loop", (n::Int64) -> 10 * _na_wpl(n) + _na_wpl("x"), Int64(1)),
    ("flow_analysis_write_promoted_value_in_switch", (n::Int64) -> 100 * _na_wps(n) + _na_wps("x"), Int64(1)),
    ("flow_analysis_write_promoted_value_in_try", (n::Int64) -> 10 * _na_wpt(n) + _na_wpt("x"), Int64(1)),
    ("type_promotion_assignment_inference_after_null_check", (n::Int64) -> _na_t_aianc(nothing) + 10 * _na_t_aianc([n]), Int64(1)),
    ("type_promotion_conditional_both", (n::Int64) -> _dw_bits(_na_t_condboth(true, "ab") == 2, _na_t_condboth(false, "abc") == 3,
        (try; _na_t_condboth(true, n); false; catch e; e === Int64(1); end), (try; _na_t_condboth(false, n); false; catch e; e === Int64(2); end)), Int64(0)),
    ("type_promotion_do_condition_is_not_type", (x::String) -> _na_t_docnt(x), "abc"),
    ("type_promotion_do_outer_is_type", (n::Int64) -> 100 * _na_t_doouter(false, "ab") + _na_t_doouter(false, n), Int64(0)),
    ("type_promotion_for_outer_is_type", (n::Int64) -> 1000 * _na_t_forouter(true, "ab") + 10 * _na_t_forouter(false, "abc") + _na_t_forouter(true, n), Int64(0)),
    ("type_promotion_function_expression_is_type_mutated_in_closure", (n::Int64) -> 10 * _na_t_femut("ab") + _na_t_femut(n), Int64(0)),
    ("type_promotion_function_expression_is_type", (n::Int64) -> 100 * _na_t_feis("ab") + _na_t_feis(n), Int64(1)),
    ("type_promotion_function_expression_outer_is_type_assigned_outside", (n::Int64) -> 100 * _na_t_feouter("ab") +
        (try; _na_t_feouter(n); catch e; e isa UndefVarError ? Int64(-1) : Int64(-2); end), Int64(1)),
    ("type_promotion_if_is_not_type", (n::Int64) -> 100 * _na_t_ifnot("ab") + _na_t_ifnot(n), Int64(1)),
    ("type_promotion_if_is_type", (n::Int64) -> 100 * _na_t_ifis("ab") + _na_t_ifis(n), Int64(1)),
    ("type_promotion_logical_or_throw", (n::Int64) -> 100 * _na_t_orthrow("abc") + (try; _na_t_orthrow(n); catch e; e === Int64(42) ? Int64(-1) : Int64(-2); end), Int64(1)),
    ("type_promotion_promoted_lhs_used_as_assignment_context", (x::Float64) -> 10 * _na_t_plhs(x) + _na_t_plhs(Int64(1)), 1.0),
    ("type_promotion_try_catch_assigned_body", (n::Int64) -> 100 * _na_t_tcab("ab") + _na_t_tcab(n), Int64(1)),
    ("type_promotion_try_catch_catch_finally_outer_is_type", (n::Int64) -> _na_t_tccf("ab") + _na_t_tccf(n), Int64(1)),
    ("type_promotion_try_catch_is_not_type_exit_body_catch", (n::Int64) -> 100 * _na_t_tcnebc("ab") + _na_t_tcnebc(n), Int64(1)),
    ("type_promotion_try_catch_is_not_type_exit_body", (n::Int64) -> 100 * _na_t_tcneb("ab") + _na_t_tcneb(n), Int64(1)),
    ("type_promotion_try_finally_outer_is_type_assigned_body", (n::Int64) -> 1000 * _na_t_tfab("ab") + _na_t_tfab(n), Int64(1)),
    ("type_promotion_try_finally_outer_is_type_assigned_finally", (n::Int64) -> 1000 * _na_t_tfaf("ab") + _na_t_tfaf(n), Int64(1)),
    ("type_promotion_while_condition_false", (x::String) -> _na_t_wcf(x), "abcd"),
    ("type_promotion_while_condition_true", (n::Int64) -> 100 * _na_t_wct("ab") + _na_t_wct(n), Int64(1)),
    ("static_errors_equals_parameter_made_nullable_at_invoke", (n::Int64) -> _na_s_eqnull(n), Int64(0)),
    ("static_errors_implicit_downcasts", (n::Int64) -> _na_s_downcast(n), Int64(1)),
    ("static_errors_non_null_assertion", (n::Int64) -> (try; _na_s_nna(n); catch e; e isa ArgumentError ? Int64(-1) : Int64(-2); end) * 100 + _na_s_nna(n + 1), Int64(1)),
    ("static_errors_not_assigned_local_if_then_else", (b::Bool) -> 10 * _na_s_naite(b) + _na_s_naite(!b), true),
    ("static_errors_not_assigned_local_try_catch_body_catch", (n::Int64) -> 10 * _na_s_natcbc(n) + _na_s_natcbc(-n), Int64(1)),
    ("static_errors_not_assigned_local_while_true_break_after", (b::Bool) -> _na_s_nawtba(b) + 1, true),
    ("static_errors_nullable_function_types", (n::Int64) -> _na_s_nft(n), Int64(1)),
    ("static_errors_super_equals_allows_null", (n::Int64) -> _na_s_se(n), Int64(0)),
    ("static_errors_this_reference_in_late_field", (n::Int64) -> (c = _NaSTrC(); a = c.x === nothing; _dw_bits(c === c, a, _na_s_tr_x(c) === c, c.x === c, n == 1)), Int64(1)),
    ("static_errors_throw_of_invalid_type", (n::Int64) -> _na_s_f1(n), Int64(5)),
    ("static_errors_unchecked_use_of_nullable", (n::Int64) -> _na_s_unn(n), Int64(1)),
    ("static_errors_unchecked_use_of_nullable_cascaded", (n::Int64) -> _na_s_unc(n), Int64(0)),
])

# ---- dart2wasm's tests at the pin, tests/language/nnbd (all but flow_analysis, type_promotion, static_errors) ----
# nnbd: a call's outcome as a code (0 returned; 1 TypeError, 2 MethodError, 3 ErrorException, 4 AssertionError,
# 5 UndefVarError, 6 UndefKeywordError, 7 UndefRefError, 8 ArgumentError, 9 InexactError), packed four bits each
_nb_code(f::F) where {F} = (try; f(); Int64(0); catch e; e isa TypeError ? Int64(1) : e isa MethodError ? Int64(2) :
    e isa ErrorException ? Int64(3) : e isa AssertionError ? Int64(4) : e isa UndefVarError ? Int64(5) :
    e isa UndefKeywordError ? Int64(6) : e isa UndefRefError ? Int64(7) : e isa ArgumentError ? Int64(8) :
    e isa InexactError ? Int64(9) : Int64(15); end)
_nb_pack(cs::Int64...) = foldl((a, b) -> 16a + b, cs; init = Int64(0))
const _NbNum = Union{Int64,Float64}
# nnbd late: a cell assigned before use; a read before raises UndefRefError, a final one's second write (or a write
# during its initializer) raises ErrorException, an initializer runs on the first read
mutable struct _NbLate{T}
    v::T
    set::Bool
    final::Bool
    _NbLate{T}(final::Bool) where {T} = (c = new{T}(); c.set = false; c.final = final; c)
    _NbLate{T}(final::Bool, v) where {T} = new{T}(v, true, final)
end
_nb_get(c::_NbLate) = c.set ? c.v : throw(UndefRefError())
function _nb_get(c::_NbLate{T}, init::F) where {T,F}
    c.set && return c.v
    local v::T = init()
    c.set && c.final && error("assigned during initialization")
    c.v = v
    c.set = true
    return v
end
_nb_set!(c::_NbLate{T}, v) where {T} = (c.final && c.set && error("already initialized"); c.v = v; c.set = true; c.v)
_nb_unset!(c::_NbLate) = (c.set = false; nothing)
# boolean_conversion/boolean_conversion_strong: a value of a union as the condition of eleven constructs
const _NbBcV = Union{Nothing,Bool,String,Int64,Vector{Bool}}
function _nb_bc_dyn(value::_NbBcV, index::Int64)
    if index == 0
        if value; end
    elseif index == 1
        [3 for _ in 1:1 if value]
    elseif index == 2
        value ? 3 : 4
    elseif index == 3
        while value; break; end
    elseif index == 4
        local done = false
        while true
            done && break
            done = true
            value || break
        end
    elseif index == 5
        value || true
    elseif index == 6
        value && true
    elseif index == 7
        false || value
    elseif index == 8
        true && value
    elseif index == 9
        while value; break; end
    elseif index == 10
        local v::_NbBcV = value
        local r = Int64[]
        while v; push!(r, 3); v = false; end
    else
        throw(ArgumentError("Invalid index"))
    end
    return nothing
end
_nb_bc_mask(v::_NbBcV) = (m = Int64(0); for i in 0:10; m = 4m + min(_nb_code(() -> _nb_bc_dyn(v, i)), Int64(3)); end; m)
# const/potentially_constant_types: a parametric struct built from isa and typeasserts against its parameter
struct _NbPc{T}
    isT::Bool
    isListT::Bool
    t::Union{Nothing,T}
    l::Union{Nothing,Vector{T}}
end
_nb_pc1(::Type{T}, x) where {T} = _NbPc{T}(x isa T, x isa Vector{T}, nothing, nothing)
_nb_pc2(::Type{T}, x) where {T} = _NbPc{T}(true, false, x::T, nothing)
_nb_pc3(::Type{T}, x) where {T} = _NbPc{T}(false, true, nothing, x::Vector{T})
_nb_pc4(::Type{T}, x) where {T} = _NbPc{T}(x isa T, x isa Vector{T}, x isa T ? x : nothing, x isa Vector{T} ? x : nothing)
const _NB_PC_I0 = Int64[0]
const _NB_PC_N0 = _NbNum[0]
const _NB_PC_S0 = String["hello"]
# inference/variables_initialized_to_null: a global, a field and a local holding nothing, then an Int64
const _NB_VN_G0 = Ref{Union{Nothing,Int64}}(nothing)
const _NB_VN_S0 = Ref{Union{Nothing,Int64}}(nothing)
mutable struct _NbVnTest
    instance0::Union{Nothing,Int64}
end
# late/chained_assignment: chained assignments through locals, fields, a setter function and a Ref
mutable struct _NbCaFoo
    x::Int64
    _y::Int64
    w::Int64
    _NbCaFoo() = (o = new(); o.x = 0; o._y = 0; o)
end
_nb_ca_y(o::_NbCaFoo) = o._y
_nb_ca_sety!(o::_NbCaFoo, y::Int64) = (o._y = y)
const _NB_CA_Z = Ref(Int64(0))
function _nb_ca_run(one::Int64)
    foo = _NbCaFoo()
    local a::Int64 = 0
    local b::Int64
    local c::Int64
    local d::Int64
    b = a = one
    f1 = a == 1 && b == 1
    a = b = 2one
    f2 = a == 2 && b == 2
    b = foo.x = 3one
    f3 = foo.x == 3 && b == 3
    foo.x = b = 4one
    f4 = foo.x == 4 && b == 4
    b = _nb_ca_sety!(foo, 5one)
    f5 = _nb_ca_y(foo) == 5 && b == 5
    _nb_ca_sety!(foo, begin; b = 6one; end)
    f6 = _nb_ca_y(foo) == 6 && b == 6
    b = c = 7one
    f7 = b == 7 && c == 7
    d = b = 8one
    f8 = b == 8 && d == 8
    _NB_CA_Z[] = a = 9one
    f9 = a == 9 && _NB_CA_Z[] == 9
    a = _NB_CA_Z[] = 10one
    f10 = a == 10 && _NB_CA_Z[] == 10
    _NB_CA_Z[] = foo.x = 11one
    f11 = foo.x == 11 && _NB_CA_Z[] == 11
    foo.x = _NB_CA_Z[] = 12one
    f12 = foo.x == 12 && _NB_CA_Z[] == 12
    _NB_CA_Z[] = _nb_ca_sety!(foo, 13one)
    f13 = _nb_ca_y(foo) == 13 && _NB_CA_Z[] == 13
    _nb_ca_sety!(foo, begin; _NB_CA_Z[] = 14one; end)
    f14 = _nb_ca_y(foo) == 14 && _NB_CA_Z[] == 14
    foo.w = a = 15one
    f15 = a == 15 && foo.w == 15
    a = foo.w = 16one
    f16 = a == 16 && foo.w == 16
    foo.w = foo.x = 17one
    f17 = foo.x == 17 && foo.w == 17
    foo.x = foo.w = 18one
    f18 = foo.x == 18 && foo.w == 18
    foo.w = _nb_ca_sety!(foo, 19one)
    f19 = _nb_ca_y(foo) == 19 && foo.w == 19
    _nb_ca_sety!(foo, begin; foo.w = 20one; end)
    f20 = _nb_ca_y(foo) == 20 && foo.w == 20
    _NB_CA_Z[] = 0
    return _dw_bits(f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20)
end
# late/covariant_instance_field: a subtype narrowing a field to Int64; a Float64 written to it
mutable struct _NbCvFoo
    a::_NbNum
    b::_NbNum
    _NbCvFoo() = new()
end
mutable struct _NbCvBar
    a::Int64
    b::Int64
    _NbCvBar() = new()
end
# late/dynamic_instance_field: fields read and written through a receiver of a union of two structs
mutable struct _NbDiFoo
    a::Int64
    b::Int64
    c::Int64
    d::Int64
    _NbDiFoo() = (o = new(); o.c = -1; o.d = -2; o)
end
struct _NbDiBar
    a::String
    b::String
    c::String
    d::String
end
@noinline _nb_di_fetch(getFoo::Bool, foo::_NbDiFoo, bar::_NbDiBar)::Union{_NbDiFoo,_NbDiBar} = getFoo ? foo : bar
# late/generic_covariant_instance_field: a parametric struct's field written through the wider instance's type
mutable struct _NbGcFoo{T}
    a::T
    b::T
    _NbGcFoo{T}() where {T} = new{T}()
end
# late/instance_field_initializers: a field set by the constructor, a const field, lazily initialized fields
const _NB_IF_HISTORY = Int64[]
_nb_if_log(n::Int64) = (push!(_NB_IF_HISTORY, n); n)
mutable struct _NbIfFoo
    a::Int64
    const b::Int64
    c::_NbLate{Int64}
    d::_NbLate{Int64}
end
_nb_if_with_c(a::Int64, b::Int64, c::Int64) = _NbIfFoo(a, b, _NbLate{Int64}(false, c), _NbLate{Int64}(true))
_nb_if_without_c(a::Int64, b::Int64) = _NbIfFoo(a, b, _NbLate{Int64}(false), _NbLate{Int64}(true))
_nb_if_c(o::_NbIfFoo) = _nb_get(o.c, () -> _nb_if_log(-1))
_nb_if_d(o::_NbIfFoo) = _nb_get(o.d, () -> _nb_if_log(-2))
function _nb_if_check(foo::_NbIfFoo, c0::Int64, hist::Vector{Int64})
    r = _dw_bits(foo.a == 1, foo.b == 2, _nb_if_c(foo) == c0, _nb_if_d(foo) == -2)
    foo.a = _nb_if_log(100)
    t = _nb_code(() -> (foo.b = _nb_if_log(101)))
    _nb_set!(foo.c, _nb_if_log(102))
    r2 = _dw_bits(foo.a == 100, foo.b == 2, _nb_get(foo.c) == 102, _NB_IF_HISTORY == hist)
    empty!(_NB_IF_HISTORY)
    return (r * 16 + t) * 16 + r2
end
# never/never_null_assignability_strong: functions taking nothing, an Int64, a non-nothing value, anything, and one
# with no method (dart's Never parameter), called directly, after a typeassert and as values
_nb_never()::Union{} = error("Never")
_nb_takes_any(n) = nothing
_nb_takes_object(n::Union{Int64,String}) = nothing
_nb_takes_int(n::Int64) = nothing
_nb_takes_null(n::Nothing) = nothing
function _nb_takes_never end
_nb_apply_null(fn::F, arg) where {F} = fn(arg::Nothing)
_nb_apply_never(fn::F, arg) where {F} = fn(arg::Union{})
_nb_apply_dyn(fn::F, arg) where {F} = fn(arg)
# normalization/type_object_normalization: Union{Nothing,T} built at run time normalizes like dart's T?
_nb_orq(::Type{T}) where {T} = Union{Nothing,T}
_nb_list(::Type{T}) where {T} = Vector{T}
struct _NbRep{T} end
_nb_rep(::Type{T}) where {T} = _NbRep{T}
_nb_rep_rt(::Type{T}) where {T} = typeof(_NbRep{T}())
# required_named_parameters/missing_required_argument_dynamic: keyword arguments without defaults, mixed with
# defaulted ones, a required one past 32 optional ones, missing at the call
struct _NbMrA end
_nb_mr_m1(::_NbMrA; a::Int64) = Int64(1)
_nb_mr_m2(::_NbMrA) = (; x::String) -> "m2: $x"
_nb_mr_m3(::_NbMrA; p1::Int64, p2::Int64 = 2, p3::Int64 = 3, p4::Int64 = 4, p5::Int64 = 5, p6::Int64, p7::Int64 = 7, p8::Int64,
    p9::Int64 = 9, p10::Int64 = 10) = p1 + p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9 + p10
_nb_mr_m4(::_NbMrA; p1::Int64 = 1, p2::Int64 = 2, p3::Int64 = 3, p4::Int64 = 4, p5::Int64 = 5, p6::Int64 = 6, p7::Int64 = 7,
    p8::Int64 = 8, p9::Int64 = 9, p10::Int64 = 10, p11::Int64 = 11, p12::Int64 = 12, p13::Int64 = 13, p14::Int64 = 14,
    p15::Int64 = 15, p16::Int64 = 16, p17::Int64 = 17, p18::Int64 = 18, p19::Int64 = 19, p20::Int64 = 20, p21::Int64 = 21,
    p22::Int64 = 22, p23::Int64 = 23, p24::Int64 = 24, p25::Int64 = 25, p26::Int64 = 26, p27::Int64 = 27, p28::Int64 = 28,
    p29::Int64 = 29, p30::Int64 = 30, p31::Int64 = 31, p32::Int64 = 32, p33::Int64 = 33, p34::Int64 = 34, p35::Int64 = 35,
    p36::Int64) = p1 + p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9 + p10 + p11 + p12 + p13 + p14 + p15 + p16 + p17 + p18 + p19 +
    p20 + p21 + p22 + p23 + p24 + p25 + p26 + p27 + p28 + p29 + p30 + p31 + p32 + p33 + p34 + p35 + p36
_nb_mr_f(; a::Int64) = Int64(2)
_nb_mr_g() = (; a::Int64) -> "g"
_nb_mr_h(; p1::Int64, p2::Int64 = 2, p3::Int64 = 3, p4::Int64 = 4, p5::Int64 = 5, p6::Int64 = 6, p7::Int64 = 7, p8::Int64,
    p9::Int64 = 9, p10::Int64) = p1 + p2 - p3 + p4 - p5 + p6 - p7 + p8 - p9 + p10
_nb_mr_i(; p1::Int64 = 1, p2::Int64 = 2, p3::Int64 = 3, p4::Int64 = 4, p5::Int64 = 5, p6::Int64 = 6, p7::Int64 = 7,
    p8::Int64 = 8, p9::Int64 = 9, p10::Int64 = 10, p11::Int64 = 11, p12::Int64 = 12, p13::Int64 = 13, p14::Int64 = 14,
    p15::Int64 = 15, p16::Int64 = 16, p17::Int64 = 17, p18::Int64 = 18, p19::Int64 = 19, p20::Int64 = 20, p21::Int64 = 21,
    p22::Int64 = 22, p23::Int64 = 23, p24::Int64 = 24, p25::Int64 = 25, p26::Int64 = 26, p27::Int64 = 27, p28::Int64 = 28,
    p29::Int64 = 29, p30::Int64 = 30, p31::Int64 = 31, p32::Int64 = 32, p33::Int64 = 33, p34::Int64, p35::Int64 = 35,
    p36::Int64 = 36) = p1 + p2 - p3 + p4 - p5 + p6 - p7 + p8 - p9 + p10 - p11 + p12 - p13 + p14 - p15 + p16 - p17 + p18 -
    p19 + p20 - p21 + p22 - p23 + p24 - p25 + p26 - p27 + p28 - p29 + p30 - p31 + p32 - p33 + p34 - p35 + p36
# required_named_parameters/required_named_args(_strong): a function with a defaulted and two required keywords,
# called directly and with a splatted NamedTuple (dart's Function.apply)
_nb_rn_func(q0::String; p3::Bool = false, p1::Int64, p2::String) = string(q0, p1, p2, p3)
# resolution/issue41479: a getter returning Union{Nothing,Int64}, used null-aware
struct _NbR41A end
_nb_r41_foo(::_NbR41A)::Union{Nothing,Int64} = Int64(0)
# resolution/null_assertion_null_type: something(nothing) passed where an Int64 is expected
_nb_nt_f(i::Int64) = nothing
_nb_nt_g(n::Nothing) = _nb_nt_f(something(n))
# subtyping/function_type_required_params: a required and a defaulted keyword argument, compared and called
_nb_ft_f(; i::Int64) = i + 1
_nb_ft_g(; i::Int64 = 1) = i + 1
# subtyping/regress41272: nothing asserted to be of the root type and of Int64, twenty times
@noinline _nb_r412_x(n::Int64)::Union{Nothing,Int64} = n == 0 ? nothing : n
# subtyping/type_casts_strong: typeasserts against a struct's parameter T, Union{Nothing,T}, X{T}, X{Union{Nothing,T}}
struct _NbTcC end
abstract type _NbTcY end
struct _NbTcY0 <: _NbTcY end
struct _NbTcZ <: _NbTcY end
struct _NbTcX{T} end
struct _NbTcW{T} end
@noinline _nb_tc_as_t(::_NbTcW{T}, arg) where {T} = arg::T
@noinline _nb_tc_as_nt(::_NbTcW{T}, arg) where {T} = arg::Union{Nothing,T}
@noinline _nb_tc_as_xt(::_NbTcW{T}, arg) where {T} = arg::_NbTcX{T}
@noinline _nb_tc_as_nxt(::_NbTcW{T}, arg) where {T} = arg::Union{Nothing,_NbTcX{T}}
@noinline _nb_tc_as_xnt(::_NbTcW{T}, arg) where {T} = arg::_NbTcX{Union{Nothing,T}}
_nb_ok(f::F) where {F} = _nb_code(f) == 0
function _nb_tc_tests()
    wy = _NbTcW{_NbTcY}()
    wny = _NbTcW{Union{Nothing,_NbTcY}}()
    return _dw_bits(
        _nb_ok(() -> _nb_tc_as_t(wy, _NbTcY0())), _nb_ok(() -> _nb_tc_as_t(wy, _NbTcZ())), _nb_ok(() -> _nb_tc_as_t(wy, nothing)),
        _nb_ok(() -> _nb_tc_as_t(wy, _NbTcC())),
        _nb_ok(() -> _nb_tc_as_nt(wy, _NbTcY0())), _nb_ok(() -> _nb_tc_as_nt(wy, _NbTcZ())), _nb_ok(() -> _nb_tc_as_nt(wy, nothing)),
        _nb_ok(() -> _nb_tc_as_nt(wy, _NbTcC())),
        _nb_ok(() -> _nb_tc_as_xt(wy, _NbTcX{_NbTcY}())), _nb_ok(() -> _nb_tc_as_xt(wy, _NbTcX{_NbTcZ}())), _nb_ok(() -> _nb_tc_as_xt(wy, nothing)),
        _nb_ok(() -> _nb_tc_as_xt(wy, _NbTcX{Any}())), _nb_ok(() -> _nb_tc_as_xt(wy, _NbTcX{Union{Nothing,_NbTcY}}())),
        _nb_ok(() -> _nb_tc_as_nxt(wy, _NbTcX{_NbTcY}())), _nb_ok(() -> _nb_tc_as_nxt(wy, _NbTcX{_NbTcZ}())), _nb_ok(() -> _nb_tc_as_nxt(wy, nothing)),
        _nb_ok(() -> _nb_tc_as_nxt(wy, _NbTcX{Any}())), _nb_ok(() -> _nb_tc_as_nxt(wy, _NbTcX{Union{Nothing,_NbTcY}}())),
        _nb_ok(() -> _nb_tc_as_xnt(wy, _NbTcX{_NbTcY}())), _nb_ok(() -> _nb_tc_as_xnt(wy, _NbTcX{_NbTcZ}())),
        _nb_ok(() -> _nb_tc_as_xnt(wy, _NbTcX{Union{Nothing,_NbTcY}}())), _nb_ok(() -> _nb_tc_as_xnt(wy, nothing)),
        _nb_ok(() -> _nb_tc_as_xnt(wy, _NbTcX{Any}())),
        _nb_ok(() -> _nb_tc_as_xt(wny, _NbTcX{_NbTcY}())), _nb_ok(() -> _nb_tc_as_xt(wny, _NbTcX{_NbTcZ}())),
        _nb_ok(() -> _nb_tc_as_xt(wny, _NbTcX{Union{Nothing,_NbTcY}}())), _nb_ok(() -> _nb_tc_as_xt(wny, nothing)),
        _nb_ok(() -> _nb_tc_as_xt(wny, _NbTcX{Any}())))
end
# syntax/cascade_nullcheck: something() applied to nullable results in a chain, then a nullable field written
mutable struct _NbCnC
    y::Union{Nothing,Int64}
end
struct _NbCnD end
@noinline _nb_cn_f(::_NbCnC)::Union{Nothing,_NbCnD} = _NbCnD()
@noinline _nb_cn_h(c::_NbCnC)::Union{Nothing,_NbCnC} = c
_nb_cn_g(d::_NbCnD) = d
@noinline _nb_cn_index(::_NbCnD, s::String)::Union{Nothing,Bool} = true
function _nb_cn_test(x::_NbCnC)
    something(_nb_cn_index(_nb_cn_g(something(_nb_cn_f(x))), "Hi!"))
    something(_nb_cn_h(x)).y = 2
    return x
end
# syntax/class_member_declarations: a nullable receiver whose member calls are skipped when it is nothing
mutable struct _NbCmA
    x27::Int64
end
_nb_cm_foo(::_NbCmA) = Int64[]
# syntax/late_modifier_bug_39658: fields with a lazy initializer, a trivial one, a nothing one and none
const _NB_LB_CALLS = Ref(Int64(0))
_nb_lb_init() = (_NB_LB_CALLS[] += 1; 1.23)
struct _NbLbA
    fieldWithInit::_NbLate{Union{Nothing,Float64}}
    fieldWithTrivialInit::_NbLate{Float64}
    fieldWithNullInit::_NbLate{Union{Nothing,Float64}}
    fieldWithNoInit::_NbLate{Float64}
end
_NbLbA() = _NbLbA(_NbLate{Union{Nothing,Float64}}(false), _NbLate{Float64}(false), _NbLate{Union{Nothing,Float64}}(false), _NbLate{Float64}(false))
_nb_lb_wi(a::_NbLbA) = _nb_get(a.fieldWithInit, _nb_lb_init)
_nb_lb_wt(a::_NbLbA) = _nb_get(a.fieldWithTrivialInit, () -> 1.23)
_nb_lb_wn(a::_NbLbA) = _nb_get(a.fieldWithNullInit, () -> nothing)
function _nb_lb_run(x::Float64)
    _NB_LB_CALLS[] = 0
    a = _NbLbA()
    r1 = _dw_bits(_NB_LB_CALLS[] == 0, _nb_lb_wi(a) == 1.23, _nb_lb_wt(a) == 1.23, _nb_lb_wn(a) === nothing,
        _nb_code(() -> _nb_get(a.fieldWithNoInit)) == 7, _NB_LB_CALLS[] == 1, _nb_lb_wi(a) == 1.23, _nb_lb_wt(a) == 1.23,
        _nb_lb_wn(a) === nothing, _nb_code(() -> _nb_get(a.fieldWithNoInit)) == 7, _NB_LB_CALLS[] == 1)
    _nb_set!(a.fieldWithInit, x); _nb_set!(a.fieldWithTrivialInit, x); _nb_set!(a.fieldWithNullInit, x); _nb_set!(a.fieldWithNoInit, x)
    r2 = _dw_bits(_NB_LB_CALLS[] == 1, _nb_lb_wi(a) == 4.56, _nb_lb_wt(a) == 4.56, _nb_lb_wn(a) == 4.56, _nb_get(a.fieldWithNoInit) == 4.56,
        _NB_LB_CALLS[] == 1)
    _NB_LB_CALLS[] = 0
    b = _NbLbA()
    _nb_set!(b.fieldWithInit, x)
    r3 = _dw_bits(_NB_LB_CALLS[] == 0, _nb_lb_wi(b) == 4.56, _NB_LB_CALLS[] == 0)
    c = _NbLbA()
    _nb_set!(c.fieldWithInit, nothing)
    r4 = _dw_bits(_NB_LB_CALLS[] == 0, _nb_lb_wi(c) === nothing, _NB_LB_CALLS[] == 0)
    return ((r1 * 64 + r2) * 8 + r3) * 8 + r4
end
# syntax/late_modifier_edge_cases: lazy initializers writing their own field, recursing into it, nested in closures,
# and throwing before and after a write
mutable struct _NbLeA
    lateField::_NbLate{Int64}
    lateFinalField::_NbLate{Int64}
    count::Int64
end
_NbLeA() = _NbLeA(_NbLate{Int64}(false), _NbLate{Int64}(true), Int64(0))
_nb_le_late(a::_NbLeA) = _nb_get(a.lateField, () -> (_nb_set!(a.lateField, Int64(456)); _nb_get(a.lateField) == 456 ? Int64(123) : Int64(-1)))
_nb_le_late_final(a::_NbLeA)::Int64 = _nb_get(a.lateFinalField, () -> a.count == 5 ? a.count : (a.count += 1) + _nb_le_late_final(a))
const _NB_LE_S_LATE = _NbLate{Int64}(false)
const _NB_LE_S_FINAL = _NbLate{Int64}(true)
const _NB_LE_S_COUNT = Ref(Int64(0))
_nb_le_s_late() = _nb_get(_NB_LE_S_LATE, () -> (_nb_set!(_NB_LE_S_LATE, Int64(456)); _nb_get(_NB_LE_S_LATE) == 456 ? Int64(123) : Int64(-1)))
_nb_le_s_final()::Int64 = _nb_get(_NB_LE_S_FINAL, () -> _NB_LE_S_COUNT[] == 5 ? _NB_LE_S_COUNT[] : (_NB_LE_S_COUNT[] += 1) + _nb_le_s_final())
function _nb_le_intermediate()
    _nb_unset!(_NB_LE_S_LATE); _nb_unset!(_NB_LE_S_FINAL); _NB_LE_S_COUNT[] = 0
    a = _NbLeA()
    return _dw_bits(_nb_le_late(a) == 123, _nb_code(() -> _nb_le_late_final(a)) == 3, _nb_le_late_final(a) == 5,
        _nb_le_s_late() == 123, _nb_code(() -> _nb_le_s_final()) == 3, _nb_le_s_final() == 5)
end
function _nb_le_complicated()
    count = Ref(Int64(0))
    closure = () -> (count[] += 1; Int64(5))
    nested = _NbLate{Int64}(false)
    lateVar = _NbLate{Vector{Int64}}(false)
    lv = () -> _nb_get(lateVar, () -> [i * i for i in 0:(_nb_get(nested, closure) - 1)])
    r1 = _dw_bits(count[] == 0, lv() == [0, 1, 4, 9, 16], count[] == 1, lv() == [0, 1, 4, 9, 16], count[] == 1)
    count[] = 0
    inIf = _NbLate{Vector{Int64}}(false)
    mk = () -> vcat([(count[] += 1)], [i * i for i in 0:2])
    r2 = _dw_bits(count[] == 0, _nb_get(inIf, mk) == [1, 0, 1, 4], count[] == 1, _nb_get(inIf, mk) == [1, 0, 1, 4], count[] == 1)
    count[] = 0
    inClosure = _NbLate{Vector{Int64}}(false)
    another = () -> _nb_get(inClosure, mk) == [1, 0, 1, 4]
    r3 = _dw_bits(count[] == 0, another(), another(), another(), count[] == 1)
    count[] = 0
    outer = _NbLate{Int64}(false)
    outerInit = () -> (ok = count[] == 0; count[] += 1; inner = _NbLate{Int64}(false); ok = ok && count[] == 1;
        v = _nb_get(inner, closure); ok = ok && v == 5 && count[] == 2; ok ? v : Int64(-1))
    r4 = _dw_bits(count[] == 0, _nb_get(outer, outerInit) == 5, count[] == 2)
    return ((r1 * 32 + r2) * 32 + r3) * 8 + r4
end
mutable struct _NbLeB
    throwBeforeWrite::_NbLate{Int64}
    throwAfterWrite::_NbLate{Int64}
end
_nb_le_tbw(b::_NbLeB) = _nb_get(b.throwBeforeWrite, () -> throw(AssertionError("before write")))
_nb_le_taw(b::_NbLeB) = _nb_get(b.throwAfterWrite, () -> (_nb_set!(b.throwAfterWrite, Int64(456)); throw(AssertionError("after write"))))
function _nb_le_throwing()
    local tbw = _NbLate{Int64}(false)
    local rd = () -> _nb_get(tbw, () -> throw(AssertionError("local")))
    b = _NbLeB(_NbLate{Int64}(false), _NbLate{Int64}(false))
    return _nb_pack(_nb_code(rd), _nb_code(rd), _nb_code(rd), _nb_code(() -> _nb_le_tbw(b)), _nb_code(() -> _nb_le_tbw(b)),
        _nb_code(() -> _nb_le_tbw(b)), _nb_code(() -> _nb_le_taw(b)), Int64(_nb_le_taw(b) == 456), Int64(_nb_le_taw(b) == 456))
end
# syntax/late_modifier_final_field: a final field with a lazy initializer over the supertype's final field of one
# name (written through the supertype's setter), and a final field with no initializer
const _NB_LF_CALLS = Ref(Int64(0))
_nb_lf_init() = (_NB_LF_CALLS[] += 1; Int64(123))
struct _NbLfA
    base_fieldWithInit::_NbLate{Int64}
    fieldWithInit::_NbLate{Int64}
end
_NbLfA() = _NbLfA(_NbLate{Int64}(true), _NbLate{Int64}(true))
_nb_lf_get(a::_NbLfA) = _nb_get(a.fieldWithInit, _nb_lf_init)
_nb_lf_set!(a::_NbLfA, v::Int64) = _nb_set!(a.base_fieldWithInit, v)
_nb_lf_super(a::_NbLfA) = _nb_get(a.base_fieldWithInit)
function _nb_lf_run()
    _NB_LF_CALLS[] = 0
    a = _NbLfA()
    r1 = _dw_bits(_NB_LF_CALLS[] == 0, _nb_lf_get(a) == 123, _NB_LF_CALLS[] == 1, _nb_lf_get(a) == 123, _NB_LF_CALLS[] == 1)
    _nb_lf_set!(a, Int64(456))
    r2 = _dw_bits(_nb_lf_super(a) == 456, _nb_lf_get(a) == 123, _NB_LF_CALLS[] == 1, _nb_code(() -> _nb_lf_set!(a, Int64(789))) == 3,
        _NB_LF_CALLS[] == 1, _nb_lf_get(a) == 123, _NB_LF_CALLS[] == 1)
    _NB_LF_CALLS[] = 0
    a2 = _NbLfA()
    r3 = _NB_LF_CALLS[] == 0
    _nb_lf_set!(a2, Int64(456))
    r4 = _dw_bits(_nb_lf_super(a) == 456, _NB_LF_CALLS[] == 0, _nb_code(() -> _nb_lf_set!(a2, Int64(789))) == 3, _NB_LF_CALLS[] == 0,
        _nb_lf_get(a2) == 123, _nb_lf_super(a) == 456, _NB_LF_CALLS[] == 1)
    b = _NbLate{Int64}(true)
    r5 = _nb_code(() -> _nb_get(b)) == 7
    _nb_set!(b, Int64(123))
    r6 = _dw_bits(_nb_get(b) == 123, _nb_code(() -> _nb_set!(b, Int64(456))) == 3, _nb_get(b) == 123)
    _NB_LF_CALLS[] = 0
    return _dw_bits(r1 == 31, r2 == 127, r3, r4 == 127, r5, r6 == 7)
end
# syntax/late_modifier_final_local_var: a final local with a lazy initializer, and one with none written once
const _NB_LFL_CALLS = Ref(Int64(0))
_nb_lfl_init() = (_NB_LFL_CALLS[] += 1; Int64(123))
function _nb_lfl_run()
    _NB_LFL_CALLS[] = 0
    fieldWithInit = _NbLate{Int64}(true)
    r1 = _dw_bits(_NB_LFL_CALLS[] == 0, _nb_get(fieldWithInit, _nb_lfl_init) == 123, _NB_LFL_CALLS[] == 1,
        _nb_get(fieldWithInit, _nb_lfl_init) == 123, _NB_LFL_CALLS[] == 1)
    fieldWithNoInit = _NbLate{Int64}(true)
    r2 = _nb_code(() -> _nb_get(fieldWithNoInit)) == 7
    1 > 0 && _nb_set!(fieldWithNoInit, Int64(123))
    r3 = _dw_bits(_nb_get(fieldWithNoInit) == 123, _nb_code(() -> _nb_set!(fieldWithNoInit, Int64(456))) == 3, _nb_get(fieldWithNoInit) == 123)
    _NB_LFL_CALLS[] = 0
    return (r1 * 2 + r2) * 8 + r3
end
# syntax/late_modifier_global_var: global cells with lazy, trivial, nothing and no initializers, final and not
const _NB_LG_CALLS = Ref(Int64(0))
_nb_lg_init() = (_NB_LG_CALLS[] += 1; Int64(123))
const _NB_LG_VAR_WITH_INIT = _NbLate{Int64}(false)
const _NB_LG_VAR_WITH_INIT2 = _NbLate{Int64}(false)
const _NB_LG_VAR_WITH_INIT3 = _NbLate{Union{Nothing,Int64}}(false)
const _NB_LG_VAR_TRIVIAL = _NbLate{Int64}(false)
const _NB_LG_VAR_NULL = _NbLate{Union{Nothing,Int64}}(false)
const _NB_LG_VAR_NO_INIT = _NbLate{Int64}(false)
const _NB_LG_FINAL_WITH_INIT = _NbLate{Int64}(true)
const _NB_LG_FINAL_TRIVIAL = _NbLate{Int64}(true)
const _NB_LG_FINAL_NULL = _NbLate{Union{Nothing,Int64}}(true)
const _NB_LG_FINAL_NO_INIT = _NbLate{Int64}(true)
_nb_lg_vwi() = _nb_get(_NB_LG_VAR_WITH_INIT, _nb_lg_init)
_nb_lg_vt() = _nb_get(_NB_LG_VAR_TRIVIAL, () -> Int64(123))
_nb_lg_vn() = _nb_get(_NB_LG_VAR_NULL, () -> nothing)
_nb_lg_fwi() = _nb_get(_NB_LG_FINAL_WITH_INIT, _nb_lg_init)
_nb_lg_ft() = _nb_get(_NB_LG_FINAL_TRIVIAL, () -> Int64(123))
_nb_lg_fn() = _nb_get(_NB_LG_FINAL_NULL, () -> nothing)
function _nb_lg_run(v::Int64)
    _NB_LG_CALLS[] = 0
    _nb_unset!(_NB_LG_VAR_WITH_INIT); _nb_unset!(_NB_LG_VAR_WITH_INIT2); _nb_unset!(_NB_LG_VAR_WITH_INIT3); _nb_unset!(_NB_LG_VAR_TRIVIAL)
    _nb_unset!(_NB_LG_VAR_NULL); _nb_unset!(_NB_LG_VAR_NO_INIT); _nb_unset!(_NB_LG_FINAL_WITH_INIT); _nb_unset!(_NB_LG_FINAL_TRIVIAL)
    _nb_unset!(_NB_LG_FINAL_NULL); _nb_unset!(_NB_LG_FINAL_NO_INIT)
    r1 = _dw_bits(_NB_LG_CALLS[] == 0, _nb_lg_vwi() == 123, _nb_lg_vt() == 123, _nb_lg_vn() === nothing, _nb_code(() -> _nb_get(_NB_LG_VAR_NO_INIT)) == 7,
        _NB_LG_CALLS[] == 1, _nb_lg_vwi() == 123, _nb_lg_vt() == 123, _nb_lg_vn() === nothing, _nb_code(() -> _nb_get(_NB_LG_VAR_NO_INIT)) == 7,
        _NB_LG_CALLS[] == 1)
    _nb_set!(_NB_LG_VAR_WITH_INIT, v); _nb_set!(_NB_LG_VAR_TRIVIAL, v); _nb_set!(_NB_LG_VAR_NULL, v); _nb_set!(_NB_LG_VAR_NO_INIT, v)
    r2 = _dw_bits(_NB_LG_CALLS[] == 1, _nb_lg_vwi() == 456, _nb_lg_vt() == 456, _nb_lg_vn() == 456, _nb_get(_NB_LG_VAR_NO_INIT) == 456,
        _NB_LG_CALLS[] == 1)
    _NB_LG_CALLS[] = 0
    _nb_set!(_NB_LG_VAR_WITH_INIT2, v)
    r3 = _dw_bits(_NB_LG_CALLS[] == 0, _nb_get(_NB_LG_VAR_WITH_INIT2, _nb_lg_init) == 456, _NB_LG_CALLS[] == 0)
    _nb_set!(_NB_LG_VAR_WITH_INIT3, nothing)
    r4 = _dw_bits(_NB_LG_CALLS[] == 0, _nb_get(_NB_LG_VAR_WITH_INIT3, _nb_lg_init) === nothing, _NB_LG_CALLS[] == 0)
    r5 = _dw_bits(_nb_lg_fwi() == 123, _nb_lg_ft() == 123, _nb_lg_fn() === nothing, _NB_LG_CALLS[] == 1, _nb_lg_fwi() == 123,
        _nb_lg_ft() == 123, _nb_lg_fn() === nothing, _NB_LG_CALLS[] == 1)
    r6 = _nb_code(() -> _nb_get(_NB_LG_FINAL_NO_INIT)) == 7
    _nb_set!(_NB_LG_FINAL_NO_INIT, Int64(123))
    r7 = _dw_bits(_nb_get(_NB_LG_FINAL_NO_INIT) == 123, _nb_code(() -> _nb_set!(_NB_LG_FINAL_NO_INIT, Int64(456))) == 3,
        _nb_get(_NB_LG_FINAL_NO_INIT) == 123)
    return _dw_bits(r1 == 2047, r2 == 63, r3 == 7, r4 == 7, r5 == 255, r6, r7 == 7)
end
# syntax/late_modifier_local_var: locals with lazy initializers (cells) and an unassigned Julia local read in a closure
const _NB_LLV_CALLS = Ref(Int64(0))
_nb_llv_init() = (_NB_LLV_CALLS[] += 1; Int64(123))
function _nb_llv_run(v::Int64)
    _NB_LLV_CALLS[] = 0
    varWithInit = _NbLate{Int64}(false)
    varWithTrivialInit = _NbLate{Int64}(false)
    varWithNullInit = _NbLate{Union{Nothing,Int64}}(false)
    local varWithNoInit::Int64
    rd = () -> varWithNoInit
    vwi = () -> _nb_get(varWithInit, _nb_llv_init)
    vt = () -> _nb_get(varWithTrivialInit, () -> Int64(123))
    vn = () -> _nb_get(varWithNullInit, () -> nothing)
    r1 = _dw_bits(_NB_LLV_CALLS[] == 0, vwi() == 123, vt() == 123, vn() === nothing, _nb_code(rd) == 5, _NB_LLV_CALLS[] == 1,
        vwi() == 123, vt() == 123, vn() === nothing, _nb_code(rd) == 5, _NB_LLV_CALLS[] == 1)
    _nb_set!(varWithInit, v); _nb_set!(varWithTrivialInit, v); _nb_set!(varWithNullInit, v)
    varWithNoInit = v
    r2 = _dw_bits(_NB_LLV_CALLS[] == 1, vwi() == 456, vt() == 456, vn() == 456, rd() == 456, _NB_LLV_CALLS[] == 1)
    _NB_LLV_CALLS[] = 0
    varWithInit2 = _NbLate{Int64}(false)
    r3 = _NB_LLV_CALLS[] == 0
    _nb_set!(varWithInit2, v)
    r4 = _dw_bits(_NB_LLV_CALLS[] == 0, _nb_get(varWithInit2, _nb_llv_init) == 456, _NB_LLV_CALLS[] == 0)
    varWithInit3 = _NbLate{Union{Nothing,Int64}}(false)
    _nb_set!(varWithInit3, nothing)
    r5 = _dw_bits(_NB_LLV_CALLS[] == 0, _nb_get(varWithInit3, _nb_llv_init) === nothing, _NB_LLV_CALLS[] == 0)
    varWithCondInit = _NbLate{Int64}(false)
    lambda = () -> _nb_get(varWithCondInit, () -> something(nothing, _nb_llv_init())) == 123 && _NB_LLV_CALLS[] == 1
    r6 = _dw_bits(lambda(), lambda(), lambda())
    _NB_LLV_CALLS[] = 0
    true && (varNotInBlock = _NbLate{Int64}(false))
    r7 = _NB_LLV_CALLS[] == 0
    _NB_LLV_CALLS[] = 0
    return _dw_bits(r1 == 2047, r2 == 63, r3, r4 == 7, r5 == 7, r6 == 7, r7)
end
# syntax/late_modifier_non_final_field: fields with lazy, trivial, nothing, constructor-set and no initializers
const _NB_LN_CALLS = Ref(Int64(0))
_nb_ln_init() = (_NB_LN_CALLS[] += 1; Int64(123))
struct _NbLnA
    fieldWithInit::_NbLate{Union{Nothing,Int64}}
    fieldWithTrivialInit::_NbLate{Int64}
    fieldWithNullInit::_NbLate{Union{Nothing,Int64}}
    fieldWithNoInit::_NbLate{Int64}
    nullableFieldWithNoInit::_NbLate{Union{Nothing,Int64}}
    fieldWithOnlyCtorInit::_NbLate{Union{Nothing,Int64}}
    fieldWithOnlyBothInitAndCtorInit::_NbLate{Union{Nothing,Int64}}
end
_NbLnA() = _NbLnA(_NbLate{Union{Nothing,Int64}}(false), _NbLate{Int64}(false), _NbLate{Union{Nothing,Int64}}(false), _NbLate{Int64}(false),
    _NbLate{Union{Nothing,Int64}}(false), _NbLate{Union{Nothing,Int64}}(false, nothing), _NbLate{Union{Nothing,Int64}}(false, nothing))
_nb_ln_wi(a::_NbLnA) = _nb_get(a.fieldWithInit, _nb_ln_init)
_nb_ln_wt(a::_NbLnA) = _nb_get(a.fieldWithTrivialInit, () -> Int64(123))
_nb_ln_wn(a::_NbLnA) = _nb_get(a.fieldWithNullInit, () -> nothing)
_nb_ln_both(a::_NbLnA) = _nb_get(a.fieldWithOnlyBothInitAndCtorInit, () -> Int64(123))
function _nb_ln_run(v::Int64)
    _NB_LN_CALLS[] = 0
    a = _NbLnA()
    r1 = _dw_bits(_NB_LN_CALLS[] == 0, _nb_ln_wi(a) == 123, _nb_ln_wt(a) == 123, _nb_ln_wn(a) === nothing, _nb_code(() -> _nb_get(a.fieldWithNoInit)) == 7,
        _nb_code(() -> _nb_get(a.nullableFieldWithNoInit)) == 7, _nb_get(a.fieldWithOnlyCtorInit) === nothing, _nb_ln_both(a) === nothing,
        _NB_LN_CALLS[] == 1, _nb_ln_wi(a) == 123, _nb_ln_wt(a) == 123, _nb_ln_wn(a) === nothing, _nb_code(() -> _nb_get(a.fieldWithNoInit)) == 7,
        _nb_code(() -> _nb_get(a.nullableFieldWithNoInit)) == 7, _NB_LN_CALLS[] == 1)
    _nb_set!(a.fieldWithInit, v); _nb_set!(a.fieldWithTrivialInit, v); _nb_set!(a.fieldWithNullInit, v); _nb_set!(a.fieldWithNoInit, v)
    _nb_set!(a.nullableFieldWithNoInit, nothing); _nb_set!(a.fieldWithOnlyCtorInit, v); _nb_set!(a.fieldWithOnlyBothInitAndCtorInit, v)
    r2 = _dw_bits(_NB_LN_CALLS[] == 1, _nb_ln_wi(a) == 456, _nb_ln_wt(a) == 456, _nb_ln_wn(a) == 456, _nb_get(a.fieldWithNoInit) == 456,
        _nb_get(a.nullableFieldWithNoInit) === nothing, _nb_get(a.fieldWithOnlyCtorInit) == 456, _nb_ln_both(a) == 456, _NB_LN_CALLS[] == 1)
    _NB_LN_CALLS[] = 0
    b = _NbLnA()
    _nb_set!(b.fieldWithInit, v)
    r3 = _dw_bits(_NB_LN_CALLS[] == 0, _nb_ln_wi(b) == 456, _NB_LN_CALLS[] == 0)
    c = _NbLnA()
    _nb_set!(c.fieldWithInit, nothing)
    r4 = _dw_bits(_NB_LN_CALLS[] == 0, _nb_ln_wi(c) === nothing, _NB_LN_CALLS[] == 0)
    _NB_LN_CALLS[] = 0
    return _dw_bits(r1 == 32767, r2 == 511, r3 == 7, r4 == 7)
end
# syntax/late_modifier_runtime_error: reads before a write, second writes of final cells and recursive initializers,
# for globals, fields and locals (an unassigned Julia local raises UndefVarError)
const _NB_LR_SF1 = _NbLate{Int64}(false)
const _NB_LR_SF2 = _NbLate{Int64}(true)
const _NB_LR_SF3 = _NbLate{Int64}(true)
const _NB_LR_DO_SF3 = Ref(true)
_nb_lr_sf3()::Int64 = _nb_get(_NB_LR_SF3, () -> _NB_LR_DO_SF3[] ? (_NB_LR_DO_SF3[] = false; _nb_lr_sf3()) : Int64(3))
mutable struct _NbLrA
    f1::_NbLate{Int64}
    f2::_NbLate{Int64}
    f3::_NbLate{Int64}
    doRecursiveInitF3::Bool
end
_NbLrA() = _NbLrA(_NbLate{Int64}(false), _NbLate{Int64}(true), _NbLate{Int64}(true), true)
_nb_lr_f3(o::_NbLrA)::Int64 = _nb_get(o.f3, () -> o.doRecursiveInitF3 ? (o.doRecursiveInitF3 = false; _nb_lr_f3(o)) : Int64(3))
_nb_lr_local3(c::_NbLate{Int64}, flag::Base.RefValue{Bool})::Int64 = _nb_get(c, () -> flag[] ? (flag[] = false; _nb_lr_local3(c, flag)) : Int64(3))
function _nb_lr_run(s::String)
    _nb_unset!(_NB_LR_SF1); _nb_unset!(_NB_LR_SF2); _nb_unset!(_NB_LR_SF3); _NB_LR_DO_SF3[] = true
    c1 = _nb_code(() -> _nb_get(_NB_LR_SF1))
    c2 = _nb_code(() -> _nb_get(_NB_LR_SF2))
    _nb_set!(_NB_LR_SF2, Int64(42))
    c3 = _nb_code(() -> _nb_set!(_NB_LR_SF2, Int64(2)))
    c4 = _nb_code(_nb_lr_sf3)
    obj = _NbLrA()
    c5 = _nb_code(() -> _nb_get(obj.f1))
    c6 = _nb_code(() -> _nb_get(obj.f2))
    _nb_set!(obj.f2, Int64(42))
    c7 = _nb_code(() -> _nb_set!(obj.f2, Int64(2)))
    c8 = _nb_code(() -> _nb_lr_f3(obj))
    local local1::Int64
    parse(Int64, s) == 2 && (local1 = -1)
    c9 = _nb_code(() -> local1)
    local2 = _NbLate{Int64}(true)
    c10 = _nb_code(() -> _nb_get(local2))
    parse(Int64, s) == 1 && _nb_set!(local2, Int64(42))
    c11 = _nb_code(() -> _nb_set!(local2, Int64(2)))
    local3 = _NbLate{Int64}(true)
    doRecursiveInitLocal3 = Ref(true)
    c12 = _nb_code(() -> _nb_lr_local3(local3, doRecursiveInitLocal3))
    return _nb_pack(c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12)
end
# syntax/late_modifier_static_field: global cells with lazy, trivial, nothing and no initializers, pre-empted by writes
const _NB_LS_CALLS = Ref(Int64(0))
_nb_ls_init() = (_NB_LS_CALLS[] += 1; Int64(123))
const _NB_LS_A_INIT = _NbLate{Int64}(false)
const _NB_LS_A_TRIVIAL = _NbLate{Int64}(false)
const _NB_LS_A_NULL = _NbLate{Union{Nothing,Int64}}(false)
const _NB_LS_A_NO_INIT = _NbLate{Int64}(false)
const _NB_LS_B_INIT = _NbLate{Int64}(false)
const _NB_LS_C_INIT = _NbLate{Union{Nothing,Int64}}(false)
_nb_ls_ai() = _nb_get(_NB_LS_A_INIT, _nb_ls_init)
_nb_ls_at() = _nb_get(_NB_LS_A_TRIVIAL, () -> Int64(123))
_nb_ls_an() = _nb_get(_NB_LS_A_NULL, () -> nothing)
function _nb_ls_run(v::Int64)
    _NB_LS_CALLS[] = 0
    _nb_unset!(_NB_LS_A_INIT); _nb_unset!(_NB_LS_A_TRIVIAL); _nb_unset!(_NB_LS_A_NULL); _nb_unset!(_NB_LS_A_NO_INIT)
    _nb_unset!(_NB_LS_B_INIT); _nb_unset!(_NB_LS_C_INIT)
    r1 = _dw_bits(_NB_LS_CALLS[] == 0, _nb_ls_ai() == 123, _nb_ls_at() == 123, _nb_ls_an() === nothing, _nb_code(() -> _nb_get(_NB_LS_A_NO_INIT)) == 7,
        _NB_LS_CALLS[] == 1, _nb_ls_ai() == 123, _nb_ls_at() == 123, _nb_ls_an() === nothing, _nb_code(() -> _nb_get(_NB_LS_A_NO_INIT)) == 7,
        _NB_LS_CALLS[] == 1)
    _nb_set!(_NB_LS_A_INIT, v); _nb_set!(_NB_LS_A_TRIVIAL, v); _nb_set!(_NB_LS_A_NULL, v); _nb_set!(_NB_LS_A_NO_INIT, v)
    r2 = _dw_bits(_NB_LS_CALLS[] == 1, _nb_ls_ai() == 456, _nb_ls_at() == 456, _nb_ls_an() == 456, _nb_get(_NB_LS_A_NO_INIT) == 456, _NB_LS_CALLS[] == 1)
    _NB_LS_CALLS[] = 0
    _nb_set!(_NB_LS_B_INIT, v)
    r3 = _dw_bits(_NB_LS_CALLS[] == 0, _nb_get(_NB_LS_B_INIT, _nb_ls_init) == 456, _NB_LS_CALLS[] == 0)
    _nb_set!(_NB_LS_C_INIT, nothing)
    r4 = _dw_bits(_NB_LS_CALLS[] == 0, _nb_get(_NB_LS_C_INIT, _nb_ls_init) === nothing, _NB_LS_CALLS[] == 0)
    return _dw_bits(r1 == 2047, r2 == 63, r3 == 7, r4 == 7)
end
# syntax/late_modifier_static_final_field: final global cells with lazy, trivial, nothing and no initializers
const _NB_LSF_CALLS = Ref(Int64(0))
_nb_lsf_init() = (_NB_LSF_CALLS[] += 1; Int64(123))
const _NB_LSF_INIT = _NbLate{Int64}(true)
const _NB_LSF_TRIVIAL = _NbLate{Int64}(true)
const _NB_LSF_NULL = _NbLate{Union{Nothing,Int64}}(true)
const _NB_LSF_NO_INIT = _NbLate{Int64}(true)
function _nb_lsf_run(v::Int64)
    _NB_LSF_CALLS[] = 0
    _nb_unset!(_NB_LSF_INIT); _nb_unset!(_NB_LSF_TRIVIAL); _nb_unset!(_NB_LSF_NULL); _nb_unset!(_NB_LSF_NO_INIT)
    fi = () -> _nb_get(_NB_LSF_INIT, _nb_lsf_init)
    ft = () -> _nb_get(_NB_LSF_TRIVIAL, () -> Int64(123))
    fnl = () -> _nb_get(_NB_LSF_NULL, () -> nothing)
    r1 = _dw_bits(_NB_LSF_CALLS[] == 0, fi() == 123, ft() == 123, fnl() === nothing, _NB_LSF_CALLS[] == 1, fi() == 123, ft() == 123,
        fnl() === nothing, _NB_LSF_CALLS[] == 1)
    r2 = _nb_code(() -> _nb_get(_NB_LSF_NO_INIT))
    _nb_set!(_NB_LSF_NO_INIT, v)
    r3 = _dw_bits(_nb_get(_NB_LSF_NO_INIT) == 123, _nb_code(() -> _nb_set!(_NB_LSF_NO_INIT, Int64(456))) == 3, _nb_get(_NB_LSF_NO_INIT) == 123)
    return (r1 * 16 + r2) * 8 + r3
end
# syntax/late_modifier: a final global with a lazy initializer, a const field set by the constructor, a local
# assigned before use
const _NB_LM_D = _NbLate{Int64}(true)
_nb_lm_d() = _nb_get(_NB_LM_D, () -> Int64(5))
const _NB_LM_E = _NbLate{Int64}(true)
_nb_lm_e() = _nb_get(_NB_LM_E, () -> Int64(6))
mutable struct _NbLmC
    const f::Int64
end
_NbLmC() = _NbLmC(Int64(7))
_nb_lm_g(::_NbLmC) = (local x::Int64; x = 8; x)
# syntax/non_null_assertion: something() over values of many kinds, and over nothing from a function, a getter and
# a function value
struct _NbNnC end
@noinline _nb_nn_x(::_NbNnC)::Union{Nothing,Int64} = nothing
@noinline _nb_nn_f()::Union{Nothing,Int64} = nothing
# syntax/null_assertion_ambiguous: something() binding tighter than throw, closures, assignment, ?:, * and unary -
struct _NbAmC end
_nb_am_mul(c::_NbAmC, other::Union{Nothing,Int64}) = c
_nb_am_neg(c::_NbAmC)::Union{Nothing,Int64} = nothing
@noinline _nb_am_null(n::Int64)::Union{Nothing,Int64} = n == 0 ? nothing : n
# syntax/nullable_type_ambiguous: a conditional on a typeassert, an isa and an operator, inside Set and Dict literals
struct _NbTaC end
_nb_ta_mul(::_NbTaC, ::Type) = true
# syntax/required_modifier: required keyword arguments on a function and a method
struct _NbRmC end
_nb_rm_f(; i::Int64) = i + 1
_nb_rm_m(::_NbRmC, a::Int64; i::Int64) = a + i
# syntax/required_modifier_dynamic_error: a missing required keyword raises before the body reads it
struct _NbRdFoo end
_nb_rd_foo(::_NbRdFoo; a::String, b::String, c::String, d::String) = ncodeunits(a) + ncodeunits(b) + ncodeunits(c) + ncodeunits(d)
_nb_rd_baz(; a::String, b::String, c::String, d::String) = ncodeunits(a) + ncodeunits(b) + ncodeunits(c) + ncodeunits(d)
# type_equality/function_type_equality: functions of one signature under two names, compared by type and by the
# argument lists they accept; a required keyword against a defaulted one
_nb_fe_fn() = nothing
_nb_fe_fn2() = nothing
_nb_fe_void_to_int() = Int64(42)
_nb_fe_void_to_int2() = Int64(42)
_nb_fe_pos_nullable(i::Union{Nothing,Int64}) = nothing
_nb_fe_pos_nullable2(i::Union{Nothing,Int64}) = nothing
_nb_fe_opt(i::Int64 = 0) = nothing
_nb_fe_opt2(i::Int64 = 0) = nothing
_nb_fe_opt_nullable(i::Union{Nothing,Int64} = nothing) = nothing
_nb_fe_opt_nullable2(i::Union{Nothing,Int64} = nothing) = nothing
_nb_fe_named(; i::Int64 = 0) = nothing
_nb_fe_named2(; i::Int64 = 0) = nothing
_nb_fe_required(; i::Int64) = nothing
_nb_fe_required2(; i::Int64) = nothing
_nb_fe_sig(f::F) where {F} = _dw_bits(applicable(f), applicable(f, Int64(0)), applicable(f, nothing), hasmethod(f, Tuple{}, (:i,)))
_nb_fe_same(f::F, g::G) where {F,G} = _dw_bits(typeof(f) == typeof(g), _nb_fe_sig(f) == _nb_fe_sig(g))
# type_equality/generic_function_type_equality: methods with a type parameter under two names, compared by type and
# by the arguments they accept; a required keyword against a defaulted one
_nb_ge_fn(::Type{T}) where {T} = nothing
_nb_ge_fn2(::Type{R}) where {R} = nothing
_nb_ge_pos_t(i::T) where {T} = nothing
_nb_ge_pos_s(i::S) where {S} = nothing
_nb_ge_pos_nullable_t(i::Union{Nothing,T}) where {T} = nothing
_nb_ge_pos_nullable_s(i::Union{Nothing,S}) where {S} = nothing
_nb_ge_opt_t(i::Vector{T} = Int64[]) where {T} = nothing
_nb_ge_opt_s(i::Vector{S} = Int64[]) where {S} = nothing
_nb_ge_named_t(; i::Vector{<:Any} = Int64[]) = nothing
_nb_ge_named_s(; i::Vector{<:Any} = Int64[]) = nothing
_nb_ge_required_t(; i::Vector{<:Any}) = nothing
_nb_ge_required_s(; i::Vector{<:Any}) = nothing
_nb_ge_sig(f::F) where {F} = _dw_bits(applicable(f), applicable(f, Int64(0)), applicable(f, nothing), applicable(f, Int64),
    applicable(f, Int64[0]), hasmethod(f, Tuple{}, (:i,)))
_nb_ge_same(f::F, g::G) where {F,G} = _dw_bits(typeof(f) == typeof(g), _nb_ge_sig(f) == _nb_ge_sig(g))
# type_equality/regress42246: methods of a parametric struct returning and taking Union{Nothing,T} and Union{Nothing,S}
struct _NbRgA{T} end
_nb_rg_fn(::_NbRgA{T}) where {T} = nothing::Union{Nothing,T}
_nb_rg_gn(::_NbRgA{T}, ::Type{S}, param::Union{Nothing,S}) where {T,S} = nothing
_nb_rg_hn(::_NbRgA{T}, ::Type{S}) where {T,S} = nothing::Union{Nothing,S}
# type_object/equality: type objects compared with ==, from names, typeof and a function returning its parameter
struct _NbToA end
struct _NbToB end
_nb_to_type(::Type{T}) where {T} = T
_g("dart_nnbd", Any[
    ("boolean_conversion_boolean_conversion_strong", (t::Bool) -> (vs = _NbBcV[t, !t, t, !t, nothing, "", "true", "null", "undefined", Int64(0), Int64(1), Bool[true]];
        s = Int64(0); for v in vs; s = s * 1000003 + _nb_bc_mask(v); end; s), true),
    ("const_potentially_constant_types", (n::Int64) -> (c1 = _nb_pc1(Int64, n); c2 = _nb_pc1(Int64, n); c3 = _nb_pc1(Int64, n + 1); c4 = _nb_pc1(Int64, "hello");
        c5 = _nb_pc1(Int64, nothing); l1 = _nb_pc1(Int64, _NB_PC_I0); l4 = _nb_pc1(Int64, _NB_PC_N0); l5 = _nb_pc1(_NbNum, _NB_PC_I0);
        d1 = _nb_pc2(Int64, n); d2 = _nb_pc2(Int64, n); d3 = _nb_pc2(_NbNum, n); e1 = _nb_pc3(Int64, _NB_PC_I0); e2 = _nb_pc3(Int64, _NB_PC_I0);
        f1 = _nb_pc4(_NbNum, n); f2 = _nb_pc4(_NbNum, "hello"); f3 = _nb_pc4(_NbNum, _NB_PC_I0); f4 = _nb_pc4(_NbNum, _NB_PC_S0); f5 = _nb_pc4(Int64, _NB_PC_N0);
        _dw_bits(c1 === c2, c1 === c3, c1 === c4, c1 === c5, c1.isT, c4.isT, c5.isT, c1.isListT, l1.isListT, l4.isListT, l5.isListT, l1 === l5,
                 d1 === d2, d1 === d3, e1 === e2, _nb_code(() -> _nb_pc3(_NbNum, _NB_PC_I0)) == 1,
                 f1.isT && !f1.isListT && f1.t == 0 && f1.l === nothing, !f2.isT && !f2.isListT && f2.t === nothing && f2.l === nothing,
                 f3.isListT, f3.l === nothing, !f4.isT && !f4.isListT && f4.l === nothing, !f5.isT && !f5.isListT && f5.l === nothing)), Int64(0)),
    ("const_regress43281", (n::Int64) -> (s = Set([n, 2, 3, nothing]); _dw_bits(length(s) == 4, s isa Set{Union{Nothing,Int64}}, s isa Set{Int64})), Int64(1)),
    ("constant_null_safety_mode", (n::Int64) -> (l = String[]; _dw_bits(Nothing[] isa Vector{Int64}) * 16 + _nb_code(() -> push!(l, nothing)) + length(l) * 256 + n), Int64(0)),
    ("inference_variables_initialized_to_null", (three::Int64) -> (_NB_VN_G0[] = three; g0 = iseven(something(_NB_VN_G0[])); _NB_VN_G0[] = nothing;
        _NB_VN_S0[] = three; s0 = iseven(something(_NB_VN_S0[])); _NB_VN_S0[] = nothing;
        o = _NbVnTest(nothing); o.instance0 = three; local0::Union{Nothing,Int64} = nothing; local0 = three;
        _dw_bits(!g0, !s0, !iseven(something(o.instance0)), !iseven(something(local0)))), Int64(3)),
    ("is_type_test_null_is", (n::Int64) -> (x = _nb_am_null(n);
        _dw_bits(x isa Union{}, x isa Union{Nothing,Union{}}, x isa Nothing, x isa Any, x isa Bool, x isa Union{Nothing,Bool}, x isa Real, x isa Union{Nothing,Real},
                 x isa Int64, x isa Union{Nothing,Int64}, x isa Float64, x isa Union{Nothing,Float64}, x isa String, x isa Union{Nothing,String},
                 x isa AbstractVector, x isa Union{Nothing,AbstractVector}, x isa AbstractSet, x isa Union{Nothing,AbstractSet}, x isa AbstractDict,
                 x isa Union{Nothing,AbstractDict}, x isa Symbol, x isa Union{Nothing,Symbol})), Int64(0)),
    ("late_chained_assignment", (one::Int64) -> _nb_ca_run(one), Int64(1)),
    ("late_covariant_instance_field", (x::Float64) -> (foo = _NbCvFoo(); foo.a = 0; foo.b = 1; f1 = foo.a == 0 && foo.b == 1; foo.a = x; f2 = foo.a == 1.618;
        bars = Union{_NbCvFoo,_NbCvBar}[_NbCvFoo(), _NbCvBar()]; bar = bars[2]; bar.a = 2; bar.b = 3;
        _dw_bits(f1, f2, bar.a == 2 && bar.b == 3) * 16 + _nb_code(() -> (bar.a = 3.14))), 1.618),
    ("late_dynamic_instance_field", (k::Bool) -> (foo = _NbDiFoo(); bar = _NbDiBar("a", "b", "c", "d"); x = _nb_di_fetch(!k, foo, bar);
        f1 = x.a == "a" && x.b == "b" && x.c == "c" && x.d == "d"; x = _nb_di_fetch(k, foo, bar); f2 = x.c == -1 && x.d == -2;
        x isa _NbDiFoo && (x.a = 1; x.b = 2; x.c = 3); x = _nb_di_fetch(!k, foo, bar); f3 = x.a == "a" && x.b == "b" && x.c == "c" && x.d == "d";
        x = _nb_di_fetch(k, foo, bar); _dw_bits(f1, f2, f3, x.a == 1 && x.b == 2 && x.c == 3 && x.d == -2)), true),
    ("late_generic_covariant_instance_field", (x::Float64) -> (foo = _NbGcFoo{_NbNum}(); foo.a = 0; foo.b = 1; f1 = foo.a == 0 && foo.b == 1; foo.a = x;
        f2 = foo.a == 1.618; bars = Union{_NbGcFoo{_NbNum},_NbGcFoo{Int64}}[_NbGcFoo{_NbNum}(), _NbGcFoo{Int64}()]; bar = bars[2]; bar.a = 2; bar.b = 3;
        _dw_bits(f1, f2, bar.a == 2 && bar.b == 3) * 16 + _nb_code(() -> (bar.a = 3.14))), 1.618),
    ("late_instance_field_initializers", (one::Int64) -> (empty!(_NB_IF_HISTORY);
        r1 = _nb_if_check(_nb_if_with_c(_nb_if_log(one), _nb_if_log(2one), _nb_if_log(3one)), Int64(3), Int64[1, 2, 3, -2, 100, 101, 102]);
        r2 = _nb_if_check((a = _nb_if_log(one); b = _nb_if_log(2one); _nb_if_without_c(a, b)), Int64(-1), Int64[1, 2, -1, -2, 100, 101, 102]);
        r1 * 4096 + r2), Int64(1)),
    ("never_never_null_assignability_strong", (n::Int64) -> (vals = Union{Nothing,Int64,String}[nothing, n, "hello"]; dn = vals[1]; d3 = vals[2]; ds = vals[3];
        p1 = _nb_pack(_nb_code(() -> _nb_takes_null(nothing)), _nb_code(() -> _nb_takes_null(_nb_never())), _nb_code(() -> _nb_takes_null(d3)),
            _nb_code(() -> _nb_takes_never(_nb_never())), _nb_code(() -> _nb_takes_never(d3)), _nb_code(() -> _nb_takes_int(n)),
            _nb_code(() -> _nb_takes_int(dn)), _nb_code(() -> _nb_takes_int(ds)), _nb_code(() -> _nb_takes_object(n)),
            _nb_code(() -> _nb_takes_object(dn)), _nb_code(() -> _nb_takes_any(n)), _nb_code(() -> _nb_takes_any(nothing)));
        p2 = _nb_pack(_nb_code(() -> _nb_apply_null(_nb_takes_null, dn)), _nb_code(() -> _nb_apply_null(_nb_takes_any, dn)),
            _nb_code(() -> _nb_apply_null(_nb_takes_null, d3)), _nb_code(() -> _nb_apply_null(_nb_takes_any, d3)),
            _nb_code(() -> _nb_apply_never(_nb_takes_null, dn)), _nb_code(() -> _nb_apply_never(_nb_takes_never, dn)),
            _nb_code(() -> _nb_apply_never(_nb_takes_int, dn)), _nb_code(() -> _nb_apply_never(_nb_takes_object, dn)),
            _nb_code(() -> _nb_apply_never(_nb_takes_any, dn)), _nb_code(() -> _nb_apply_never(_nb_takes_int, d3)),
            _nb_code(() -> _nb_apply_never(_nb_takes_any, d3)));
        p3 = _nb_pack(_nb_code(() -> _nb_apply_dyn(_nb_takes_null, dn)), _nb_code(() -> _nb_apply_dyn(_nb_takes_any, dn)),
            _nb_code(() -> _nb_apply_dyn(_nb_takes_null, d3)), _nb_code(() -> _nb_apply_dyn(_nb_takes_any, d3)),
            _nb_code(() -> _nb_apply_dyn(_nb_takes_never, dn)), _nb_code(() -> _nb_apply_dyn(_nb_takes_int, dn)),
            _nb_code(() -> _nb_apply_dyn(_nb_takes_object, dn)), _nb_code(() -> _nb_apply_dyn(_nb_takes_null, d3)),
            _nb_code(() -> _nb_apply_dyn(_nb_takes_never, d3)), _nb_code(() -> _nb_apply_dyn(_nb_takes_int, d3)),
            _nb_code(() -> _nb_apply_dyn(_nb_takes_int, ds)), _nb_code(() -> _nb_apply_dyn(_nb_takes_object, d3)));
        (p1 * 1000003 + p2) * 1000003 + p3), Int64(3)),
    ("normalization_type_object_normalization", (n::Int64) -> (T = typeof(n);
        _dw_bits(_nb_orq(Any) == Any, _nb_orq(_nb_orq(Any)) == Any, Union{} != Nothing, Union{Nothing,Union{}} == Nothing, _nb_orq(Nothing) == Nothing,
                 _nb_orq(T) != T, _nb_orq(_nb_orq(_nb_orq(T))) == _nb_orq(T), Vector{Union{Nothing,Union{}}} == _nb_list(Nothing),
                 _nb_list(_nb_orq(_nb_orq(T))) == Vector{Union{Nothing,Int64}}, _NbRep{Union{Nothing,Union{}}} == _nb_rep(Nothing),
                 _nb_rep_rt(_nb_orq(_nb_orq(T))) == _NbRep{Union{Nothing,Int64}}, typeof(_NbRep{Union{}}()) != _nb_rep_rt(Nothing),
                 _nb_rep_rt(_nb_orq(T)) != _nb_rep_rt(T))), Int64(0)),
    ("required_named_parameters_missing_required_argument_dynamic", (n::Int64) -> (a = _NbMrA();
        codes = _nb_pack(_nb_code(() -> _nb_mr_m1(a)), _nb_code(() -> _nb_mr_f()), _nb_code(() -> _nb_mr_g()()), _nb_code(() -> _nb_mr_m2(a)()),
            _nb_code(() -> _nb_mr_h(p1 = 1, p6 = 6, p10 = 10)), _nb_code(() -> _nb_mr_m3(a, p1 = 1, p8 = 8, p10 = 10)),
            _nb_code(() -> _nb_mr_i(p36 = 36)), _nb_code(() -> _nb_mr_m4(a, p34 = 34)));
        codes * 1024 + _dw_bits(_nb_mr_m1(a, a = 5n) == 1, _nb_mr_f(a = 3n) == 2, _nb_mr_g()(a = 4n) == "g", _nb_mr_m2(a)(x = "check") == "m2: check",
            _nb_mr_h(p1 = n, p8 = 8, p10 = 10) == 7, _nb_mr_m3(a, p1 = n, p6 = 6, p8 = 8) == 55, _nb_mr_i(p34 = 34n) == 20,
            _nb_mr_m4(a, p36 = 36n) == 666)), Int64(1)),
    ("required_named_parameters_required_named_args_strong", (n::Int64) -> _nb_pack(_nb_code(() -> _nb_rn_func(""; p1 = nothing, p2 = nothing)),
        _nb_code(() -> _nb_rn_func(""; (p1 = nothing, p2 = nothing)...)), _nb_code(() -> _nb_rn_func(""; p1 = 100n)),
        _nb_code(() -> _nb_rn_func(""; (p1 = 100n,)...))), Int64(1)),
    ("required_named_parameters_required_named_args", (n::Int64) -> ncodeunits(_nb_rn_func(""; p1 = 100n, p2 = "", p3 = true)) * 1000 +
        ncodeunits(_nb_rn_func(""; (p1 = 100n, p2 = "", p3 = true)...)) * 100 + ncodeunits(_nb_rn_func(""; p1 = 100n, p2 = "")) * 10 +
        ncodeunits(_nb_rn_func(""; (p1 = 100n, p2 = "")...)), Int64(1)),
    ("resolution_issue41479", (n::Int64) -> (a = _NbR41A(); v = _nb_r41_foo(a); r = v === nothing ? nothing : iseven(v); (r === true ? 1 : 0) + n), Int64(0)),
    ("resolution_null_assertion_null_type", (n::Int64) -> _nb_code(() -> _nb_nt_g(nothing)) + n, Int64(0)),
    ("subtyping_function_type_required_params", (n::Int64) -> _dw_bits(typeof(_nb_ft_f) == typeof(_nb_ft_f), typeof(_nb_ft_f) == typeof(_nb_ft_g),
        typeof(_nb_ft_g) == typeof(_nb_ft_g)) * 2^24 + _nb_pack(_nb_code(() -> _nb_ft_f(i = n)), _nb_code(() -> _nb_ft_f()), _nb_code(() -> _nb_ft_g(i = n)),
        _nb_code(() -> _nb_ft_g()), _nb_code(() -> _nb_ft_f(i1 = n, i2 = n))) + _nb_ft_f(i = n) * 2^20, Int64(1)),
    ("subtyping_regress41272", (n::Int64) -> (s = Int64(0); for _ in 1:20; x = _nb_r412_x(n); s += 100 * _nb_code(() -> x::Any) + _nb_code(() -> x::Int64); end; s), Int64(0)),
    ("subtyping_type_casts_strong", (n::Int64) -> (r = _nb_tc_tests(); for _ in 2:20; r == _nb_tc_tests() || return Int64(-1); end; r + n), Int64(0)),
    ("syntax_cascade_nullcheck", (n::Int64) -> (c = _nb_cn_test(_NbCnC(nothing)); something(c.y) + n), Int64(0)),
    ("syntax_class_member_declarations", (n::Int64) -> (a::Union{Nothing,_NbCmA} = n == 0 ? nothing : _NbCmA(0); s::Union{Nothing,String} = "";
        a === nothing || (length(_nb_cm_foo(a)); a.x27 = ncodeunits(something(s))); a === nothing ? Int64(-1) : a.x27), Int64(0)),
    ("syntax_late_modifier_bug_39658", (x::Float64) -> _nb_lb_run(x), 4.56),
    ("syntax_late_modifier_edge_cases", (n::Int64) -> (_nb_le_intermediate() * 2^20 + _nb_le_complicated()) * 2^36 + _nb_le_throwing() + n, Int64(0)),
    ("syntax_late_modifier_final_field", (n::Int64) -> (r = _nb_lf_run(); for _ in 2:20; r == _nb_lf_run() || return Int64(-1); end; r + n), Int64(0)),
    ("syntax_late_modifier_final_local_var", (n::Int64) -> (r = _nb_lfl_run(); for _ in 2:20; r == _nb_lfl_run() || return Int64(-1); end; r + n), Int64(0)),
    ("syntax_late_modifier_global_var", (v::Int64) -> _nb_lg_run(v), Int64(456)),
    ("syntax_late_modifier_local_var", (v::Int64) -> (r = _nb_llv_run(v); for _ in 2:20; r == _nb_llv_run(v) || return Int64(-1); end; r), Int64(456)),
    ("syntax_late_modifier_non_final_field", (v::Int64) -> (r = _nb_ln_run(v); for _ in 2:20; r == _nb_ln_run(v) || return Int64(-1); end; r), Int64(456)),
    ("syntax_late_modifier_runtime_error", (s::String) -> _nb_lr_run(s), "1"),
    ("syntax_late_modifier_static_field", (v::Int64) -> _nb_ls_run(v), Int64(456)),
    ("syntax_late_modifier_static_final_field", (v::Int64) -> _nb_lsf_run(v), Int64(123)),
    ("syntax_late_modifier", (n::Int64) -> _dw_bits(_nb_lm_d() == 5, _nb_lm_e() == 6, _NbLmC().f == 7, _nb_lm_g(_NbLmC()) == 8) + n, Int64(0)),
    ("syntax_non_null_assertion", (n::Int64) -> (c = _NbNnC(); g = _nb_nn_f; i = n; x13 = [something((t = i; i += 1; t))];
        _dw_bits([something(n)] isa Vector{Int64}, something(true) === true, something("foo") == "foo", something(:foo) === :foo,
                 something([1]) == [1], something(Dict(1 => 2)) == Dict(1 => 2), something(Set([1])) == Set([1]), something(_NbNnC()) === c,
                 _nb_code(() -> [something(_nb_nn_f())]) == 8, _nb_code(() -> [something(_nb_nn_x(c))]) == 8, _nb_code(() -> [something(g())]) == 8,
                 x13 == [0] && i == 1)), Int64(0)),
    ("syntax_null_assertion_ambiguous", (n::Int64) -> (a = _nb_am_null(n); c1 = _nb_code(() -> throw(something(a))); x1 = () -> something(a);
        c2 = _nb_code(x1); x3::Int64 = Int64(0); c3 = _nb_code(() -> (x3 = something(a))); x4::Union{Nothing,Int64} = Int64(0);
        c4 = _nb_code(() -> (x4 = something(a))); x5 = true ? nothing : something(a); x6 = 2; i1 = _nb_am_null(Int64(2)); p6 = x6 * something(i1);
        x7 = _NbAmC(); i2 = _nb_am_null(n); c7 = _nb_code(() -> _nb_am_mul(x7, something(i2))); x8 = _nb_am_null(Int64(2)); p8 = -something(x8);
        x10 = _nb_am_neg(something(_NbAmC()));
        _nb_pack(c1, c2, c3, c4, c7) * 64 + _dw_bits(x3 == 0, x4 == 0, x5 === nothing, p6 == 4, p8 == -2, x10 === nothing)), Int64(0)),
    ("syntax_nullable_type_ambiguous", (k::Bool) -> (a1 = k; x1 = Set([(a1::Bool) ? -3 : 3]); a2 = Int64(0); x2 = Set([a2 isa Int64 ? -3 : 3]);
        a3 = _NbTaC(); x3 = Set([_nb_ta_mul(a3, Int64) ? -3 : 3]); x4 = Set([a1 isa Union{Nothing,Bool} ? -3 : 3]); x5 = Dict(something(a1 isa Bool, true) => 3);
        _dw_bits(x1 isa AbstractSet, -3 in x1, x2 isa AbstractSet, -3 in x2, x3 isa AbstractSet, -3 in x3, x4 isa AbstractSet, -3 in x4,
                 x5 isa AbstractDict, x5[true] == 3)), true),
    ("syntax_nullable_type", (n::Int64) -> (x1 = Union{Nothing,Int64}[nothing]; x2 = Union{Nothing,Core.Int64}[nothing]; x3 = Union{Nothing,Vector{Int64}}[nothing];
        x4 = Union{Nothing,Function}[nothing];
        _dw_bits(x1 isa Vector{Union{Nothing,Int64}}, x1 isa Vector{Int64}, x2 isa Vector{Union{Nothing,Int64}}, x2 isa Vector{Int64},
                 x3 isa Vector{Union{Nothing,Vector{Int64}}}, x3 isa Vector{Vector{Int64}}, x4 isa Vector{Union{Nothing,Function}}, x4 isa Vector{Function}) + n), Int64(0)),
    ("syntax_required_modifier", (n::Int64) -> _nb_rm_f(i = 2n) * 100 + _nb_rm_m(_NbRmC(), 4n, i = 5n), Int64(1)),
    ("syntax_required_modifier_dynamic_error", (s::String) -> (f = _NbRdFoo(); closure = (; a::String, b::String, c::String, d::String) -> ncodeunits(a) + ncodeunits(b) + ncodeunits(c) + ncodeunits(d);
        _nb_rd_foo(f, a = s, b = s, c = s, d = s) * 4096 + _nb_pack(_nb_code(() -> _nb_rd_foo(f, a = s, b = s, d = s)), _nb_code(() -> _nb_rd_baz(a = s, c = s, d = s)),
            _nb_code(() -> closure(a = s, c = s, d = s)))), "aa"),
    ("type_equality_function_type_equality", (n::Int64) -> _dw_bits(_nb_fe_same(_nb_fe_fn, _nb_fe_fn) == 3, _nb_fe_same(_nb_fe_fn, _nb_fe_fn2) == 1,
        _nb_fe_same(_nb_fe_void_to_int, _nb_fe_void_to_int2) == 1, _nb_fe_same(_nb_fe_pos_nullable, _nb_fe_pos_nullable2) == 1,
        _nb_fe_same(_nb_fe_opt, _nb_fe_opt2) == 1, _nb_fe_same(_nb_fe_opt_nullable, _nb_fe_opt_nullable2) == 1, _nb_fe_same(_nb_fe_named, _nb_fe_named2) == 1,
        _nb_fe_same(_nb_fe_required, _nb_fe_required2) == 1, _nb_fe_same(_nb_fe_opt, _nb_fe_opt_nullable) == 1,
        _nb_code(() -> _nb_fe_required()) == _nb_code(() -> _nb_fe_named())) * 64 + _nb_fe_sig(_nb_fe_opt) * 4 + n, Int64(0)),
    ("type_equality_generic_function_type_equality", (n::Int64) -> _dw_bits(_nb_ge_same(_nb_ge_fn, _nb_ge_fn2) == 1, _nb_ge_same(_nb_ge_pos_t, _nb_ge_pos_s) == 1,
        _nb_ge_same(_nb_ge_pos_nullable_t, _nb_ge_pos_nullable_s) == 1, _nb_ge_same(_nb_ge_opt_t, _nb_ge_opt_s) == 1,
        _nb_ge_same(_nb_ge_named_t, _nb_ge_named_s) == 1, _nb_ge_same(_nb_ge_required_t, _nb_ge_required_s) == 1,
        _nb_code(() -> _nb_ge_named_t()) == _nb_code(() -> _nb_ge_required_t())) * 64 + _nb_ge_sig(_nb_ge_pos_nullable_t) + n, Int64(0)),
    ("type_equality_regress42246", (n::Int64) -> (a = _NbRgA{Int64}();
        _dw_bits(_nb_rg_fn(a) === nothing, _nb_rg_fn(a) isa Union{Nothing,Int64}, applicable(_nb_rg_gn, a, String, nothing), applicable(_nb_rg_gn, a, String, "s"),
                 applicable(_nb_rg_gn, a, String, n), _nb_rg_hn(a, String) isa Union{Nothing,String})), Int64(0)),
    ("type_object_equality", (n::Int64) -> (a = _NbToA(); b = _NbToB();
        _dw_bits(_NbToA == _NbToA, _NbToB == _NbToB, _NbToA == _NbToB, _NbToA == typeof(a), _NbToB == typeof(b), typeof(a) == typeof(b), _NbToA == Int64,
                 _NbToA == 123, Int64 == Int64, Int64 == typeof(n), Int64 == typeof(0x8000000000000000), String == typeof("x"), String == typeof("\U1D11E"),
                 _nb_to_type(Union{Nothing,Int64}) == _nb_to_type(Union{Nothing,Int64}), _nb_to_type(Union{Nothing,Int64}) == _nb_to_type(Int64),
                 _nb_to_type(Int64) == _nb_to_type(Union{Nothing,Int64}), _nb_to_type(Int64) == _nb_to_type(Int64))), Int64(0)),
])

# ---- dart2wasm's tests at the pin, tests/language/patterns (test/dart_tests.toml, dev/LEDGER.md D41) ----
# Each case is named by the dart file's path under tests/language/patterns, `/` written `_`, less
# `_test`. A pattern is written as Julia destructuring and if/elseif chains of isa tests, comparisons
# and length checks; a switch no case matches throws ErrorException; a throw is coded by _pt_ecode.
_pt_nomatch()::Union{} = throw(ErrorException("no case matched"))
_pt_ecode(e) = e isa TypeError ? Int64(1) : e isa ErrorException ? Int64(2) : e isa MethodError ? Int64(3) :
    e isa ArgumentError ? Int64(4) : e isa KeyError ? Int64(5) : e isa BoundsError ? Int64(6) : Int64(9)
_pt_throws(f) = (try; f(); Int64(0); catch e; _pt_ecode(e); end)
# call_tear_off: a callable struct torn off to a closure where a function is expected, kept as itself
# when destructured (so a function test refutes it)
struct _PtCallC end
(c::_PtCallC)(x::Int64) = x
struct _PtBox{T}
    value::T
end
_pt_tear(c::_PtCallC) = (x::Int64) -> c(x)
# cast_from_dynamic: values of a union (dart's dynamic) matched by typed, list, map and object patterns;
# a failed cast throws where the pattern is irrefutable and refutes where it is refutable
struct _PtCfdC end
_pt_cfd_known(::_PtCfdC) = Int64(123)
_pt_cfd_dynint(::_PtCfdC)::Union{Int64,String} = Int64(123)
_pt_cfd_dynstr(::_PtCfdC)::Union{Int64,String} = "wrong type"
function _pt_cfd(n::Int64, s::String)
    local big::Union{Int64,String} = n + 111
    local di::Union{Int64,String} = n
    local ds::Union{Int64,String} = s
    local dl::Union{Vector{Int64},String} = [n]
    local dls::Union{Vector{Int64},String} = s
    local dm::Union{Dict{String,Int64},String} = Dict("x" => n)
    local dms::Union{Dict{String,Int64},String} = s
    local dc::Union{_PtCfdC,String} = _PtCfdC()
    local dcs::Union{_PtCfdC,String} = s
    local l = Union{Int64,String}[n]
    local ls = Union{Int64,String}[s]
    local m = Dict{String,Union{Int64,String}}("x" => n)
    local ms = Dict{String,Union{Int64,String}}("x" => s)
    local c = _PtCfdC()
    (x1,) = dl::Vector{Int64}
    (x2,) = l
    return _dw_bits(n < big::Int64,
        di::Int64 == 123, _pt_throws(() -> ds::Int64) == 1, di isa Int64, !(ds isa Int64),
        x1 == 123, _pt_throws(() -> ((y,) = dls::Vector{Int64}; y)) == 1, dl isa Vector{Int64} && length(dl) == 1, !(dls isa Vector{Int64}),
        (dm::Dict{String,Int64})["x"] == 123, _pt_throws(() -> (dms::Dict{String,Int64})["x"]) == 1, dm isa Dict{String,Int64} && haskey(dm, "x"),
        !(dms isa Dict{String,Int64}),
        _pt_cfd_known(dc::_PtCfdC) == 123, _pt_throws(() -> _pt_cfd_known(dcs::_PtCfdC)) == 1, dc isa _PtCfdC, !(dcs isa _PtCfdC),
        x2::Int64 == 123, _pt_throws(() -> ((y,) = ls; y::Int64)) == 1, l[1] isa Int64, !(ls[1] isa Int64),
        m["x"]::Int64 == 123, _pt_throws(() -> ms["x"]::Int64) == 1, m["x"] isa Int64, !(ms["x"] isa Int64),
        _pt_cfd_dynint(c)::Int64 == 123, _pt_throws(() -> _pt_cfd_dynstr(c)::Int64) == 1, _pt_cfd_dynint(c) isa Int64, !(_pt_cfd_dynstr(c) isa Int64))
end
# exhaustiveness/cast: switches whose last case casts (a failed cast throws) over a union, a sealed
# hierarchy and lists
abstract type _PtCtM end
struct _PtCtA <: _PtCtM end
struct _PtCtB <: _PtCtM end
struct _PtCtC <: _PtCtM end
_pt_ct_si(o) = o isa String ? o : string(o::Int64)
_pt_ct_si_and(o) = o isa String ? o : (v = o::Int64; v2 = v; string(v, v2))
_pt_ct_sn(o) = o isa String ? o : (v = o::Int64; v isa Number ? string(v) : _pt_nomatch())
_pt_ct_su(o) = o isa String ? o : string(iseven(o::Int64))
_pt_ct_mm(m::_PtCtM) = (m::_PtCtM) isa Union{_PtCtA,_PtCtB,_PtCtC} ? Int64(0) : _pt_nomatch()
_pt_ct_dm(m) = (m::_PtCtM) isa Union{_PtCtA,_PtCtB,_PtCtC} ? Int64(0) : _pt_nomatch()
_pt_ct_dmu(m) = (x = m::_PtCtM; x isa _PtCtA || x isa _PtCtB || (x isa _PtCtC && hash(x) isa UInt64)) ? Int64(0) : _pt_nomatch()
_pt_ct_dms(m) = (x = m::_PtCtA; x isa _PtCtA || x isa _PtCtB || (x isa _PtCtC && hash(x) == 5)) ? Int64(0) : _pt_nomatch()
_pt_ct_list(o) = o isa Vector{Int64} && length(o) == 1 ? Int64(1) : (o::Vector{Int64}; Int64(0))
# exhaustiveness/extension_type: switches over extension types, which are their representation type at
# run time (a type alias here)
abstract type _PtEtS end
struct _PtEtA <: _PtEtS end
struct _PtEtB <: _PtEtS end
const _PtEtNullable = Union{Nothing,String}
const _PtEtNum = Union{Int64,Float64}
const _PtEtBool = Bool
const _PtEtSealed = _PtEtS
_pt_et_null1(o::_PtEtNullable) = o === nothing ? Int64(0) : o isa String ? Int64(1) : _pt_nomatch()
_pt_et_null2(o::_PtEtNullable) = o isa _PtEtNullable ? Int64(2) : _pt_nomatch()
_pt_et_null3(o::Union{Nothing,String}) = o isa _PtEtNullable ? Int64(3) : _pt_nomatch()
_pt_et_num1(o::_PtEtNum) = o isa Int64 ? Int64(0) : o isa Float64 ? Int64(1) : _pt_nomatch()
_pt_et_num2(o::_PtEtNum) = o isa _PtEtNum ? Int64(2) : _pt_nomatch()
_pt_et_num3(o::Union{Int64,Float64}) = o isa _PtEtNum ? Int64(3) : _pt_nomatch()
_pt_et_bool1(o::_PtEtBool) = o == true ? Int64(0) : o == false ? Int64(1) : _pt_nomatch()
_pt_et_bool2(o::_PtEtBool) = o isa _PtEtBool ? Int64(2) : _pt_nomatch()
_pt_et_bool3(o::Bool) = o isa _PtEtBool ? Int64(3) : _pt_nomatch()
_pt_et_sealed1(o::_PtEtSealed) = o isa _PtEtA ? Int64(0) : o isa _PtEtB ? Int64(1) : _pt_nomatch()
_pt_et_sealed2(o::_PtEtSealed) = o isa _PtEtSealed ? Int64(2) : _pt_nomatch()
_pt_et_sealed3(o::_PtEtS) = o isa _PtEtSealed ? Int64(3) : _pt_nomatch()
# exhaustiveness/fallback: switches made exhaustive by a wildcard, a variable, a type, an object
# pattern, ||, &&, a cast, a null assert (something), null, parentheses, a tuple, nullable and enum factoring
@enum _PtFbE _pt_fb_e1 _pt_fb_e2
_pt_fb_nullable(b::Union{Nothing,Bool}) = b === nothing ? Int64(0) : b isa Bool ? Int64(1) : _pt_nomatch()
_pt_fb_enum(e::Union{Nothing,_PtFbE}) = e === _pt_fb_e1 ? Int64(0) : e === _pt_fb_e2 ? Int64(1) : e === nothing ? Int64(2) : _pt_nomatch()
function _pt_fb(b::Bool, e::_PtFbE)
    local nb::Union{Nothing,Bool} = b
    local rs = (b === true ? 0 : 1, b === true ? 0 : (x = b; 1), b === true ? 0 : b isa Bool ? 1 : _pt_nomatch(),
        b === true ? 0 : b isa Any ? 1 : _pt_nomatch(), (b === true || b isa Bool) ? 0 : _pt_nomatch(),
        (b isa Bool || b === true) ? 0 : _pt_nomatch(), (b isa Bool && b isa Any) ? 0 : _pt_nomatch(),
        (nb::Bool) isa Bool ? 0 : _pt_nomatch(), something(nb) isa Bool ? 0 : _pt_nomatch(), (b isa Bool) ? 0 : _pt_nomatch(),
        e === _pt_fb_e1 ? 0 : e === _pt_fb_e2 ? 1 : _pt_nomatch(), (b, e) isa Tuple{Bool,_PtFbE} ? 0 : _pt_nomatch(),
        _pt_fb_nullable(nothing), _pt_fb_enum(e), _pt_fb_enum(nothing))
    local s = Int64(0)
    for r in rs
        s = 3s + r
    end
    return s
end
# exhaustiveness/issue52048: a switch over an abstract type with one subtype that mixes in a trait
abstract type _PtI52048A end
struct _PtI52048B <: _PtI52048A end
_pt_i52048_f(a::_PtI52048A) = a isa _PtI52048B ? Int64(1) : Int64(0)
# exhaustiveness/list_constant: a list matched against an empty constant list, then a non-empty list pattern
const _PT_LC_EMPTY = Int64[]
_pt_lc(v::Vector{Int64}) = v == _PT_LC_EMPTY ? "empty constant" : length(v) >= 1 ? "non-empty" : _pt_nomatch()
# exhaustiveness/nullable_cast: a nullable Int64 cast to a non-nullable type (a type parameter, Int64,
# Number) before an object pattern; nothing fails the cast
_pt_nc_tv(::Type{T}, o::Union{Nothing,Int64}) where {T} = (o::T) isa Int64 ? Int64(0) : _pt_nomatch()
_pt_nc_int(o::Union{Nothing,Int64}) = (o::Int64) isa Int64 ? Int64(0) : _pt_nomatch()
_pt_nc_num(o::Union{Nothing,Int64}) = (o::Number) isa Int64 ? Int64(0) : _pt_nomatch()
# exhaustiveness/restrictive_cast_pattern_3_2, restrictive_cast_pattern_error: cases that cast then
# match a field; a value implementing both cast types (a Union per interface) matches neither
abstract type _PtRcS end
struct _PtRcA <: _PtRcS
    b::Bool
end
struct _PtRcB <: _PtRcS
    b::Bool
end
struct _PtRcC <: _PtRcS end
const _PtRcIsA = Union{_PtRcA,_PtRcC}
const _PtRcIsB = Union{_PtRcB,_PtRcC}
_pt_rc_b(x::Union{_PtRcA,_PtRcB}) = x.b
_pt_rc_b(::_PtRcC) = false
const _PT_RC_VALUE = Ref{Union{Nothing,Int64}}(Int64(1))
function _pt_rc_method(s::_PtRcS)::Union{Nothing,Int64}
    _pt_rc_b(s::_PtRcIsA) && return Int64(0)
    _pt_rc_b(s::_PtRcIsB) && return _PT_RC_VALUE[]
    return _pt_nomatch()
end
# exhaustiveness/sealed_cast_3_2, sealed_cast_error: a case `A() as B` over a sealed type; a value
# implementing A and B (a Union per interface) passes the cast
abstract type _PtScM end
struct _PtScA <: _PtScM end
struct _PtScB <: _PtScM end
struct _PtScC <: _PtScM end
struct _PtScD <: _PtScM end
const _PtScIsA = Union{_PtScA,_PtScD}
const _PtScIsB = Union{_PtScB,_PtScD}
_pt_sc_method(m::_PtScM) = m isa _PtScIsA ? (m::_PtScIsB; Int64(0)) : m isa _PtScIsB ? Int64(1) : _pt_nomatch()
# exhaustiveness/unsound_cast_3_2: cases `X() as A`, `Y() as B`; a value implementing A and B passes
# both casts and matches neither
abstract type _PtUcS end
abstract type _PtUcA <: _PtUcS end
abstract type _PtUcB <: _PtUcS end
struct _PtUcX <: _PtUcA end
struct _PtUcY <: _PtUcB end
struct _PtUcZ <: _PtUcS end
const _PtUcIsA = Union{_PtUcA,_PtUcZ}
const _PtUcIsB = Union{_PtUcB,_PtUcZ}
_pt_uc_unsound(s::_PtUcS) = (s::_PtUcIsA) isa _PtUcX ? Int64(0) : (s::_PtUcIsB) isa _PtUcY ? Int64(1) : _pt_nomatch()
_pt_uc_sound(s::_PtUcS) = (s::_PtUcIsA) isa _PtUcX ? Int64(0) : (s::_PtUcIsB) isa _PtUcY ? Int64(1) : nothing
# flow_analysis/boolean_condition: a null test stored by an assignment and by a declaration, then
# guarding a read of the value as Int64
function _pt_bc_assign(x::Union{Nothing,Int64})
    local b::Bool
    b = x !== nothing
    return b ? (x::Int64) + 1 : Int64(0)
end
_pt_bc_declare(x::Union{Nothing,Int64}) = (b = x !== nothing; b ? (x::Int64) + 1 : Int64(0))
# flow_analysis/list_pattern_with_nullable_list_scrutinee: an empty-list pattern over a nullable list
_pt_lpn(x::Union{Nothing,Vector{Union{Nothing,Int64}}}) = x isa Vector && isempty(x) ? Int64(1) : Int64(2)
# flow_analysis/null_check_in_guard: `int? y when y != null` in a switch statement and expression, an
# if-case and list, map and set elements
function _pt_ncg_stmt(x)
    if x isa Union{Nothing,Int64} && x !== nothing
        return (x::Int64) isa Int64
    else
        return false
    end
end
_pt_ncg_expr(x) = (x isa Union{Nothing,Int64} && x !== nothing) ? true : false
_pt_ncg_if(x) = (if x isa Union{Nothing,Int64} && x !== nothing; true; else; false; end)
_pt_ncg_list(x) = (l = Int64[]; (x isa Union{Nothing,Int64} && x !== nothing) && push!(l, x); !isempty(l))
_pt_ncg_map(x) = (d = Dict{String,Int64}(); (x isa Union{Nothing,Int64} && x !== nothing) && (d[""] = x); !isempty(d))
_pt_ncg_set(x) = (s = Set{Int64}(); (x isa Union{Nothing,Int64} && x !== nothing) && push!(s, x); !isempty(s))
# flow_analysis/pattern_assignment_lookahead: a local assigned by a pattern assignment inside a closure,
# read after the closure runs
function _pt_pal(v::String)
    local s::String
    (() -> ((s,) = (v,); nothing))()
    return s
end
# guard_capture: closures made in a guard capture the pattern variables the body then assigns; cases
# sharing a body each have their own variable
function _pt_gc_single(v::Vector{String})
    length(v) == 2 || return Int64(0)
    local a::String = v[1]
    local b::String = v[2]
    local ca = () -> a
    local cb = () -> b
    local r1 = string(ca(), " ", cb()) == "one two"
    local r2 = a == "one" && b == "two"
    a = "after"
    b = "then"
    return _dw_bits(r1, r2, a == "after" && b == "then", string(ca(), " ", cb()) == "after then")
end
function _pt_gc_shared(v::Vector{String})
    length(v) == 3 || return Int64(0)
    local a1::String = v[1]
    local c1 = () -> a1
    local a2::String = v[2]
    local c2 = () -> a2
    local a3::String = v[3]
    local c3 = () -> a3
    local a::String = a3
    local r1 = a == "three"
    local r2 = string(c1(), " ", c2(), " ", c3()) == "one two three"
    a = "after"
    return _dw_bits(r1, r2, a == "after", string(c1(), " ", c2(), " ", c3()) == "one two three")
end
# guard_scope: a pattern variable read in the guard of a switch statement, a switch expression, an
# if-case and a collection element
const _PT_GS_ARG = Ref("")
_pt_gs_guard(arg::String) = (_PT_GS_ARG[] = arg; true)
_pt_gs_expect(e::String) = (r = _PT_GS_ARG[] == e; _PT_GS_ARG[] = ""; r)
function _pt_gs(v::String)
    let a = v
        if _pt_gs_guard(a)
        end
    end
    local r1 = _pt_gs_expect("value")
    local body = let a = v
        _pt_gs_guard(a) ? "body" : "other"
    end
    local r2 = _pt_gs_expect("value") && body == "body"
    let a = v
        _pt_gs_guard(a) && nothing
    end
    local r3 = _pt_gs_expect("value")
    local list = String[]
    let a = v
        _pt_gs_guard(a) && push!(list, "element")
    end
    local r4 = _pt_gs_expect("value") && length(list) == 1
    return _dw_bits(r1, r2, r3, r4)
end
# identifier_when_not: a constant, a module-qualified constant and a named tuple's constant matched
# with a negated guard in switches, if-cases and list, map and set elements
const _PT_IWN_ONE = 1
const _PT_IWN_VALUES = (one = 1,)
function _pt_iwn(x::Int64)
    local ks = (_PT_IWN_ONE, (@__MODULE__)._PT_IWN_ONE, _PT_IWN_VALUES.one, (@__MODULE__)._PT_IWN_VALUES.one)
    local s = Int64(0)
    for k in ks
        local sw = (x == k && !false) ? 1 : 0
        local ex = (x == k && !false) ? 0 : _pt_nomatch()
        local ic = if x == k && !false; 1; else; 0; end
        local li = [(x == k && !false) ? "" : "Should have matched"] == [""]
        local mp = Dict((x == k && !false) ? ("" => "") : ("" => "Should have matched")) == Dict("" => "")
        local st = Set([(x == k && !false) ? "" : "Should have matched"]) == Set([""])
        s = 64s + _dw_bits(sw == 1, ex == 0, ic == 1, li, mp, st)
    end
    return s
end
# implicit_instantiation: a generic function instantiated at Int64 (a closure accepting only Int64)
# where a function of Int64 is expected, kept generic when destructured; told apart by applicable
_pt_ii_id(t) = t
_pt_ii_inst() = (x::Int64) -> _pt_ii_id(x)
_pt_ii_is_intfn(f) = applicable(f, Int64(1)) && !applicable(f, "s")
_pt_ii_is_tfn(f) = applicable(f, Int64(1)) && applicable(f, "s")
struct _PtIiCompare end
_pt_ii_lt(::_PtIiCompare, f) = _pt_ii_is_tfn(f)
# int_to_double: an Int64 converted to Float64 by a typed declaration, an assignment and a comparison
# with a Float64; a list of Int64 is no list of Float64
struct _PtDoubleComparer
    value::Float64
end
_pt_dc_gt(c::_PtDoubleComparer, d::Real) = c.value > Float64(d)
function _pt_itd(n::Int64)
    local d::Float64 = n
    local r1 = d isa Float64 && d == 123.0
    d = n + 111
    local r2 = d isa Float64 && d == 234.0
    local c = _PtDoubleComparer(12.34)
    local v = [n]
    local result = v isa Vector{Float64} ? "wrong" : "ok"
    return _dw_bits(r1, r2, !_pt_dc_gt(c, 345), _pt_dc_gt(c, 3), !(v isa Vector{Float64}), result == "ok")
end
# invalid_inside_unary_pattern_parentheses: casts, null asserts (something) and null checks nested in
# one another, and relational patterns under a null check
_pt_iup_cc(x) = ((x::Number)::Int64; true)
_pt_iup_cna(x) = (something(x)::Int64; true)
_pt_iup_cnc(x) = x !== nothing && (x::Union{Nothing,Int64}; true)
_pt_iup_nac(x) = (something(x::Union{Nothing,Number}); true)
_pt_iup_nana(x) = (something(something(x)); true)
_pt_iup_nanc(x) = x !== nothing && (something(x); true)
_pt_iup_ncc(x) = (x::Union{Nothing,Number}) !== nothing
_pt_iup_ncna(x) = something(x) !== nothing
_pt_iup_ncnc(x) = x !== nothing && x !== nothing
_pt_iup_eq(x) = x !== nothing && x == 1
_pt_iup_gt(x) = x !== nothing && x > 1
# issue_52439: a declaration destructuring a switch expression's tuple into an Int64 and a nullable tuple
_pt_i52439_sw(foo::Int64)::Tuple{Int64,Union{Nothing,Tuple{Int64}}} = (Int64(42), nothing)
# issue52409: an object pattern on a field function that never returns, over a value not of its type
struct _PtI52409A end
_pt_i52409_never(::_PtI52409A)::Union{} = throw(ErrorException("0"))
function _pt_i52409_f(x::Union{Int64,_PtI52409A})
    local y::Union{Nothing,Int64} = Int64(0)
    if x isa _PtI52409A
        _pt_i52409_never(x)
        y = nothing
    end
    return y === nothing ? Int64(-1) : y
end
# issue54559: an if-case binding a String from a nullable String under the same name
function _pt_i54559(s::String)
    local fooValue::Union{Nothing,String} = s
    if fooValue isa String
        let fooValue = fooValue
            return fooValue == "hello world"
        end
    end
    return false
end
# non_interface_object_pattern: function values told apart by the argument types they accept
# (hasmethod for dart's function types), then nothing and Int64
_pt_nio_function() = nothing
_pt_nio_int(i::Int64) = i
_pt_nio_string(s::String) = s
_pt_nio_bool(b::Bool) = b
_pt_nio_dynamic(d) = d
_pt_nio_multi(i::Int64, s::String) = nothing
function _pt_nio(::Type{T}, o) where {T}
    hasmethod(o, Tuple{}) && return Int64(1)
    hasmethod(o, Tuple{Int64}) && !hasmethod(o, Tuple{String}) && return Int64(2)
    hasmethod(o, Tuple{String}) && !hasmethod(o, Tuple{Int64}) && return Int64(3)
    hasmethod(o, Tuple{T}) && return Int64(4)
    hasmethod(o, Tuple{Any}) && return Int64(5)
    o === nothing && return Int64(6)
    o isa Int64 && return Int64(7)
    return Int64(0)
end
# nullable_object_pattern: an object pattern of a nullable type, of a type parameter (nullable Int64,
# Int64, Union{}) and with fields every value has (typeof, hash)
const _PtNopA = Union{Nothing,Int64}
_pt_nop_without(x) = x isa _PtNopA
_pt_nop_potential(::Type{T}, x) where {T} = x isa T
_pt_nop_nonnull(::Type{T}, x) where {T} = x isa T && iseven(x)
_pt_nop_fields(x) = x isa _PtNopA ? (typeof(x) == typeof(x) && hash(x) == hash(x)) : false
# object_pattern_inference: object patterns over parametric types: a covariant (<:) parameter, a bound,
# an f-bounded type, a subtype adding a parameter, a parametric alias and a function type (hasmethod)
abstract type _PtOpiB{T} end
struct _PtOpiC{T} <: _PtOpiB{T}
    t::T
end
_pt_opi_listoft(c::_PtOpiC{T}) where {T} = T[c.t]
_pt_opi_explicit(b::_PtOpiB{Int64}) = b isa _PtOpiC{<:Number} ? true : _pt_nomatch()
_pt_opi_simple(b::_PtOpiB{<:Number}) = b isa _PtOpiC ? true : _pt_nomatch()
_pt_opi_dynamic(o) = o isa _PtOpiC ? (iseven(o.t); length(_pt_opi_listoft(o)) == 1) : false
struct _PtOpiD{T<:Number}
    t::T
end
_pt_opi_bound(o) = o isa _PtOpiD
struct _PtOpiE{T,U}
    t::T
    u::U
end
_pt_opi_enclosing(::_PtOpiE{T,U}, e::_PtOpiE{Set{U},Set{T}}) where {T,U} = e isa _PtOpiE
abstract type _PtOpiF1{T} end
mutable struct _PtOpiF2 <: _PtOpiF1{_PtOpiF2}
    t::_PtOpiF2
    _PtOpiF2() = (x = new(); x.t = x; x)
end
_pt_opi_fbounded(o) = o isa _PtOpiF1
abstract type _PtOpiG{T} end
struct _PtOpiG1{T} <: _PtOpiG{T}
    t::T
end
struct _PtOpiG2{T,U<:AbstractSet{T}} <: _PtOpiG{T}
    t::T
    u::U
end
_pt_opi_partial(g::_PtOpiG{Int64}) = g isa _PtOpiG2
struct _PtOpiH1{T,U}
    t::T
    u::U
end
const _PtOpiH2 = _PtOpiH1{<:Number,String}
_pt_opi_alias(o) = o isa _PtOpiH2
_pt_opi_fntype(o) = hasmethod(o, Tuple{Number})
# primitive_switch: switch statements and expressions over two enums, separately and over their union
@enum _PtPsA _pt_ps_aa _pt_ps_ab _pt_ps_ac
@enum _PtPsB _pt_ps_ba _pt_ps_bb _pt_ps_bc
const _PtPsI = Union{_PtPsA,_PtPsB}
_pt_ps_expr_a(a::_PtPsA) = a === _pt_ps_aa ? Int64(0) : a === _pt_ps_ab ? Int64(1) : a === _pt_ps_ac ? Int64(2) : _pt_nomatch()
function _pt_ps_stmt_a(a::_PtPsA)
    if a === _pt_ps_aa
        return Int64(0)
    elseif a === _pt_ps_ab
        return Int64(1)
    elseif a === _pt_ps_ac
        return Int64(2)
    end
    return _pt_nomatch()
end
_pt_ps_expr_b(b::_PtPsB) = b === _pt_ps_ba ? Int64(3) : b === _pt_ps_bb ? Int64(4) : b === _pt_ps_bc ? Int64(5) : _pt_nomatch()
function _pt_ps_stmt_b(b::_PtPsB)
    if b === _pt_ps_ba
        return Int64(3)
    elseif b === _pt_ps_bb
        return Int64(4)
    elseif b === _pt_ps_bc
        return Int64(5)
    end
    return _pt_nomatch()
end
_pt_ps_expr_i(i::_PtPsI) = i === _pt_ps_aa ? Int64(0) : i === _pt_ps_ab ? Int64(1) : i === _pt_ps_ac ? Int64(2) :
    i === _pt_ps_ba ? Int64(3) : i === _pt_ps_bb ? Int64(4) : i === _pt_ps_bc ? Int64(5) : Int64(-1)
function _pt_ps_stmt_i(i::_PtPsI)
    if i === _pt_ps_aa
        return Int64(0)
    elseif i === _pt_ps_ab
        return Int64(1)
    elseif i === _pt_ps_ac
        return Int64(2)
    elseif i === _pt_ps_ba
        return Int64(3)
    elseif i === _pt_ps_bb
        return Int64(4)
    elseif i === _pt_ps_bc
        return Int64(5)
    else
        return Int64(-1)
    end
end
# record_type_object_pattern: a tuple with a named part matched by a tuple pattern, by a parametric
# alias with its fields, and with functions standing for extension getters
const _PtRtoR3{A,B,C} = Tuple{A,B,NamedTuple{(:s5,),Tuple{C}}}
_pt_rto_ext3(::_PtRtoR3) = "3"
_pt_rto_ext2p64p1(::_PtRtoR3) = "2p64+1"
function _pt_rto(n::Int64)
    local rec = (n, "a", (s5 = true,))
    local r1 = if rec isa Tuple{Int64,String,@NamedTuple{s5::Bool}}
        (a, b, nt) = rec
        (; s5) = nt
        a == 1 && b == "a" && s5 == true
    else
        false
    end
    local r2 = rec isa _PtRtoR3{Int64,String,Bool} && rec[1] == 1 && rec[2] == "a" && rec[3].s5 == true
    local r3 = rec isa _PtRtoR3{Int64,String,Bool} && rec[1] == 1 && rec[3].s5 == true
    local r4 = rec isa _PtRtoR3{Int64,String,Bool} && rec[1] == 1 && _pt_rto_ext3(rec) == "3" && rec[3].s5 == true &&
        _pt_rto_ext2p64p1(rec) == "2p64+1"
    return _dw_bits(r1, r2, r3, r4)
end
# regress_59613: if-cases binding the loop variable's name again, in nested scopes, at three types
struct _PtR59613Obj end
function _pt_r59613(x::Float64)
    local s = Int64(0)
    for thing in Union{Float64,String,_PtR59613Obj}[x, "foo", _PtR59613Obj()]
        if thing isa Float64
            let thing = thing::Float64
                s = 10s + (thing == x ? 1 : 0)
            end
        elseif thing isa String
            let thing = thing::String
                s = 10s + ncodeunits(thing)
            end
        elseif thing isa Any
            let thing = thing
                s = 10s + (thing isa _PtR59613Obj ? 5 : 0)
            end
        else
            throw(ErrorException("unknown"))
        end
    end
    return s
end
# relational_pattern_expression_precedence: relational patterns (==, !=, <=, <, >=, >) whose operand is
# a bitwise, shift, additive, multiplicative, unary, member or primary expression
_pt_rpe(op::F, n::Int64) where {F} = _dw_bits(op(7 + n, 5 | 6), op(3 + n, xor(5, 6)), op(4 + n, 5 & 6), op(4 + n, 1 << 2), op(1 + n, 4 >> 2),
    op(4 + n, 3 + 1), op(2 + n, 3 - 1), op(10 + n, 5 * 2), op(2.5 + n, 5 / 2), op(1 + n, 5 % 2), op(2 + n, div(5, 2)), op(-3 + n, -3),
    op(~3 + n, ~3), op(3 + n, ncodeunits("foo")))
_pt_rpe_eq(op::F, n::Int64) where {F} = _pt_rpe(op, n) * 4 + _dw_bits(op(n == 0, !false), op(string("xy", 'z'), "xyz"))
_pt_rpe_ord(op::F, n::Int64) where {F} = _pt_rpe(op, n) * 2 + _dw_bits(op(3 + n, 3))
# schema: declarations and assignments destructuring by logical-and, a null assert (something), typed
# and untyped variables, lists (empty, with rest), maps, tuples and object patterns
function _pt_schema(n::Int64)
    local f = (m::Number) -> m
    local x1 = f
    local y1 = f
    local v::Union{Nothing,Int64} = n
    local i1 = something(v)
    local i2::Int64 = n
    local i3::Int64
    i3 = n
    (x2,) = [n]
    (_,) = [n]
    (x3,) = [n]
    local e1 = Int64[]
    isempty(e1) || _pt_nomatch()
    local e2 = [n]
    pop!(e2)
    isempty(e2) || _pt_nomatch()
    local x4 = Int64[][begin:end]
    (x5,) = Int64[0]
    local x6 = [n][begin:end]
    (f1, f2) = [f, f]
    local d = Dict{Int64,String}(0 => "x")
    local dm = Dict(1 => f, 2 => f)
    (i4, nt) = (n, (y = "y",))
    (; y) = nt
    local l = Int64[]
    local x7 = first([n])
    return _dw_bits(x1(n) == n, y1(1.5) == 1.5, i1 == n, i2 == n, i3 == n, x2 == n, x3 isa Any, isempty(e1), isempty(e2), isempty(x4),
        x5 == 0, x6 == [n], f1(n) == n && f2(1.5) == 1.5, haskey(d, 0), dm[1](n) == n && dm[2](n) == n, i4 == n && y == "y",
        l isa Vector{Int64}, x7 == n)
end
# shared_case_variable: cases sharing a body whose variables differ in finality, type and name (unused
# in the body), or agree where the body reads them, at list, map, tuple and nested positions
const _PT_SCV_LAST = Ref("none")
_pt_scv_guard(v, label::String) = (_PT_SCV_LAST[] = string(v, ": ", label); true)
_pt_scv_matched() = (r = _PT_SCV_LAST[]; _PT_SCV_LAST[] = "none"; r)
function _pt_scv_finality(k::Int64, v)
    if (k == 0 && v isa Int64 && _pt_scv_guard(v, "int")) || (k == 1 && v isa Int64 && _pt_scv_guard(v, "final int")) ||
       (k == 2 && _pt_scv_guard(v, "var")) || (k == 3 && _pt_scv_guard(v, "final"))
        return _pt_scv_matched()
    end
    return _pt_nomatch()
end
function _pt_scv_type(k::Int64, v)
    if (k == 0 && v isa Int64 && _pt_scv_guard(v, "int")) || (k == 1 && v isa Bool && _pt_scv_guard(v, "bool")) ||
       (k == 2 && _pt_scv_guard(v, "var"))
        return _pt_scv_matched()
    end
    return _pt_nomatch()
end
function _pt_scv_variable(k::Int64, v)
    if (k == 0 && _pt_scv_guard(v, "unique")) || (k == 1 && _pt_scv_guard(v, "inTwo")) || (k == 2 && _pt_scv_guard(v, "inTwo"))
        return _pt_scv_matched()
    end
    return _pt_nomatch()
end
function _pt_scv_annotated(k::Int64, v)
    local a
    if (k == 0 && (a = v; _pt_scv_guard(a, "var"))) || (k == 1 && v isa Any && (a = v; _pt_scv_guard(a, "Object")))
        return v == a ? _pt_scv_matched() : "mismatch"
    end
    return _pt_nomatch()
end
function _pt_scv_promoted(k::Int64, v)
    if v isa String
        local a::String
        if (k == 0 && (a = v; _pt_scv_guard(a, "var"))) || (k == 1 && (a = v; _pt_scv_guard(a, "String")))
            return v == a ? _pt_scv_matched() : "mismatch"
        end
        return _pt_nomatch()
    end
    return "null"
end
function _pt_scv_context(v)
    local a::Int64
    if (v isa AbstractVector && length(v) == 2 && v[1] isa Int64 && v[2] isa Bool && (a = v[1]; _pt_scv_guard(a, "list"))) ||
       (v isa AbstractDict && haskey(v, "b") && haskey(v, "a") && v["b"] isa Bool && v["a"] isa Int64 && (a = v["a"]; _pt_scv_guard(a, "map"))) ||
       (v isa NamedTuple{(:a, :b)} && v.a isa Int64 && v.b isa Bool && (a = v.a; _pt_scv_guard(a, "record"))) ||
       (v isa NamedTuple{(:a, :b)} && v.a isa Int64 && v.b isa AbstractVector && length(v.b) == 1 && v.b[1] isa Bool &&
        (a = v.a; _pt_scv_guard(a, "nested")))
        return string(a, ": ", _pt_scv_matched())
    end
    return _pt_nomatch()
end
# switch_case_scope: pattern variables in a scope around the case body, shadowing outer locals, in
# unshared and shared cases
function _pt_scs_body(v::String)
    let x = v
        let x = "local"
            return x == "local"
        end
    end
end
function _pt_scs_unshared(t::Tuple{String,String})
    local loc = "local"
    local r = false
    let topLevel = t[1], loc = t[2]
        r = string(topLevel, " ", loc) == "pat tern"
        loc = "assigned"
    end
    return r && loc == "local"
end
function _pt_scs_shared(t::Tuple{String,String}, value::Int64)
    local loc = "local"
    local r = false
    if value == 0 || value == 1
        let topLevel = t[1], loc = t[2]
            r = string(topLevel, " ", loc) == "pat tern"
            loc = "assigned"
        end
    else
        _pt_nomatch()
    end
    return r && loc == "local"
end
# type_question_before_when: a guarded cast to a nullable type, and conditionals over a cast and a type test
_pt_tqw_matched(x, b::Bool) = (y = x::Union{Nothing,Int64}; b ? true : false)
_pt_tqw_as(condition, when, otherwise) = (condition::Bool) ? when : otherwise
_pt_tqw_is(obj, when, otherwise) = obj isa Int64 ? when : otherwise
# version_2_29_changes: a map pattern never reads length (a dict whose length throws) and matches a map
# with extra keys
struct _PtNoLengthMap <: AbstractDict{String,Int64}
    inner::Dict{String,Int64}
end
Base.length(::_PtNoLengthMap) = throw(ErrorException("No length!"))
Base.haskey(m::_PtNoLengthMap, k::String) = haskey(m.inner, k)
Base.getindex(m::_PtNoLengthMap, k::String) = m.inner[k]
Base.iterate(m::_PtNoLengthMap) = iterate(m.inner)
Base.iterate(m::_PtNoLengthMap, i) = iterate(m.inner, i)
_pt_v229_has_a(m::AbstractDict{String,Int64}) = haskey(m, "a") ? true : false
_pt_v229_ab(m::AbstractDict{String,Int64}) = haskey(m, "a") && haskey(m, "b") ? "a b" : haskey(m, "a") ? "a" : haskey(m, "b") ? "b" : "???"
_g("dart_patterns", Any[
    ("call_tear_off", (n::Int64) -> (c = _PtCallC(); a = _pt_tear(c); (b,) = (_pt_tear(c),); (d,) = [_pt_tear(c)];
        e = Dict("x" => _pt_tear(c))["x"]; f = _PtBox(_pt_tear(c)).value;
        _dw_bits(a isa Function, a isa _PtCallC, b isa Function, d isa Function, e isa Function, f isa Function, a(n) + b(n) + d(n) + e(n) + f(n) == 5n,
                 (c,)[1] isa Function, [c][1] isa Function, Dict("x" => c)["x"] isa Function, _PtBox(c).value isa Function, c(n) == n)), Int64(3)),
    ("cast_from_dynamic", (s::String) -> _pt_cfd(Int64(123), s), "wrong type"),
    ("exhaustiveness_cast", (s::String) -> _dw_bits(
        _pt_ct_si(s) == "foo", _pt_ct_si(Int64(42)) == "42", _pt_throws(() -> _pt_ct_si(true)) == 1,
        _pt_ct_si_and(s) == "foo", _pt_ct_si_and(Int64(42)) == "4242", _pt_throws(() -> _pt_ct_si_and(true)) == 1,
        _pt_ct_sn(s) == "foo", _pt_ct_sn(Int64(42)) == "42", _pt_throws(() -> _pt_ct_sn(3.14)) == 1,
        _pt_ct_su(s) == "foo", _pt_ct_su(Int64(42)) == "true", _pt_ct_su(Int64(87)) == "false", _pt_throws(() -> _pt_ct_su(true)) == 1,
        _pt_ct_mm(_PtCtA()) + _pt_ct_mm(_PtCtB()) + _pt_ct_mm(_PtCtC()) == 0,
        _pt_ct_dm(_PtCtA()) + _pt_ct_dm(_PtCtB()) + _pt_ct_dm(_PtCtC()) == 0, _pt_throws(() -> _pt_ct_dm(true)) == 1,
        _pt_ct_dmu(_PtCtA()) + _pt_ct_dmu(_PtCtB()) + _pt_ct_dmu(_PtCtC()) == 0, _pt_throws(() -> _pt_ct_dmu(true)) == 1,
        _pt_ct_dms(_PtCtA()) == 0, _pt_throws(() -> _pt_ct_dms(_PtCtB())) == 1, _pt_throws(() -> _pt_ct_dms(_PtCtC())) == 1,
        _pt_throws(() -> _pt_ct_dms(true)) == 1,
        _pt_ct_list(Int64[]) == 0, _pt_ct_list(Int64[0]) == 1, _pt_ct_list(Int64[0, 1]) == 0, _pt_throws(() -> _pt_ct_list(true)) == 1), "foo"),
    ("exhaustiveness_extension_type", (s::String) -> (s4 = Int64(0);
        for r in (_pt_et_null1(nothing), _pt_et_null1(s), _pt_et_null2(nothing), _pt_et_null2(s), _pt_et_null3(nothing), _pt_et_null3(s),
                  _pt_et_num1(Int64(42)), _pt_et_num1(3.14), _pt_et_num2(Int64(42)), _pt_et_num2(3.14), _pt_et_num3(Int64(42)), _pt_et_num3(3.14),
                  _pt_et_bool1(true), _pt_et_bool1(false), _pt_et_bool2(true), _pt_et_bool2(false), _pt_et_bool3(true), _pt_et_bool3(false),
                  _pt_et_sealed1(_PtEtA()), _pt_et_sealed1(_PtEtB()), _pt_et_sealed2(_PtEtA()), _pt_et_sealed2(_PtEtB()),
                  _pt_et_sealed3(_PtEtA()), _pt_et_sealed3(_PtEtB()));
            s4 = 4s4 + r;
        end; s4), "foo"),
    ("exhaustiveness_fallback", (b::Bool) -> _pt_fb(b, _pt_fb_e1), false),
    ("exhaustiveness_issue52048", (n::Int64) -> _pt_i52048_f(_PtI52048B()) + n, Int64(0)),
    ("exhaustiveness_list_constant", (n::Int64) -> ncodeunits(_pt_lc([n, 2, 3])), Int64(1)),
    ("exhaustiveness_nullable_cast", (n::Int64) -> _dw_bits(_pt_nc_tv(Integer, n) == 0, _pt_nc_tv(Int64, n) == 0, _pt_throws(() -> _pt_nc_tv(Int64, nothing)) == 1,
        _pt_nc_int(n) == 0, _pt_throws(() -> _pt_nc_int(nothing)) == 1, _pt_nc_num(n) == 0, _pt_throws(() -> _pt_nc_num(nothing)) == 1), Int64(42)),
    ("exhaustiveness_restrictive_cast_pattern_3_2", (n::Int64) -> _pt_throws(() -> _pt_rc_method(_PtRcC())) * 100 +
        _pt_throws(() -> _pt_rc_method(_PtRcB(true))) * 10 + something(_pt_rc_method(_PtRcA(true))) + n, Int64(0)),
    ("exhaustiveness_restrictive_cast_pattern_error", (n::Int64) -> _pt_throws(() -> _pt_rc_method(_PtRcC())) + n, Int64(0)),
    ("exhaustiveness_sealed_cast_3_2", (n::Int64) -> _pt_throws(() -> _pt_sc_method(_PtScA())) * 1000 + _pt_sc_method(_PtScB()) * 100 +
        _pt_throws(() -> _pt_sc_method(_PtScC())) * 10 + _pt_sc_method(_PtScD()) + n, Int64(0)),
    ("exhaustiveness_sealed_cast_error", (n::Int64) -> _pt_throws(() -> _pt_sc_method(_PtScA())) * 1000 + _pt_sc_method(_PtScB()) * 100 +
        _pt_throws(() -> _pt_sc_method(_PtScC())) * 10 + _pt_sc_method(_PtScD()) + n, Int64(0)),
    ("exhaustiveness_unsound_cast_3_2", (n::Int64) -> _dw_bits(_pt_uc_sound(_PtUcX()) == _pt_uc_unsound(_PtUcX()),
        _pt_throws(() -> _pt_uc_unsound(_PtUcZ())) == 2) + n, Int64(0)),
    ("flow_analysis_boolean_condition", (n::Int64) -> _pt_bc_assign(n) * 100 + _pt_bc_declare(n) * 10 + _pt_bc_assign(nothing) + _pt_bc_declare(nothing), Int64(0)),
    ("flow_analysis_list_pattern_with_nullable_list_scrutinee", (n::Int64) -> _pt_lpn(nothing) * 10 + _pt_lpn(Union{Nothing,Int64}[]) + n, Int64(0)),
    ("flow_analysis_null_check_in_guard", (n::Int64) -> _dw_bits(
        _pt_ncg_stmt(n), !_pt_ncg_stmt(nothing), !_pt_ncg_stmt(""), _pt_ncg_expr(n), !_pt_ncg_expr(nothing), !_pt_ncg_expr(""),
        _pt_ncg_if(n), !_pt_ncg_if(nothing), !_pt_ncg_if(""), _pt_ncg_list(n), !_pt_ncg_list(nothing), !_pt_ncg_list(""),
        _pt_ncg_map(n), !_pt_ncg_map(nothing), !_pt_ncg_map(""), _pt_ncg_set(n), !_pt_ncg_set(nothing), !_pt_ncg_set("")), Int64(0)),
    ("flow_analysis_pattern_assignment_lookahead", (t::String) -> ncodeunits(_pt_pal(t)) + 1, ""),
    ("guard_capture", (s::String) -> _pt_gc_single([s, "two"]) * 256 + _pt_gc_single(String[s, "two"]) * 16 + _pt_gc_shared([s, "two", "three"]), "one"),
    ("guard_scope", (s::String) -> _pt_gs(s), "value"),
    ("identifier_when_not", (n::Int64) -> _pt_iwn(n), Int64(1)),
    ("implicit_instantiation", (n::Int64) -> (a = _pt_ii_inst(); (b,) = (_pt_ii_inst(),); (c,) = [_pt_ii_inst()]; d = Dict("x" => _pt_ii_inst())["x"];
        e = _PtBox(_pt_ii_inst()).value;
        _dw_bits(!_pt_ii_lt(_PtIiCompare(), _pt_ii_inst()), _pt_ii_is_intfn(a), !_pt_ii_is_tfn(a), _pt_ii_is_intfn(b), !_pt_ii_is_tfn(b),
                 _pt_ii_is_intfn(c), !_pt_ii_is_tfn(c), _pt_ii_is_intfn(d), !_pt_ii_is_tfn(d), _pt_ii_is_intfn(e), !_pt_ii_is_tfn(e), a(n) == n,
                 !_pt_ii_is_intfn((_pt_ii_id,)[1]), !_pt_ii_is_intfn([_pt_ii_id][1]), !_pt_ii_is_intfn(Dict("x" => _pt_ii_id)["x"]),
                 !_pt_ii_is_intfn(_PtBox(_pt_ii_id).value))), Int64(1)),
    ("int_to_double", (n::Int64) -> _pt_itd(n), Int64(123)),
    ("invalid_inside_unary_pattern_parentheses", (n::Int64) -> _dw_bits(_pt_iup_cc(n), _pt_iup_cna(n), _pt_iup_cnc(n), _pt_iup_nac(n), _pt_iup_nana(n),
        _pt_iup_nanc(n), _pt_iup_ncc(n), _pt_iup_ncna(n), _pt_iup_ncnc(n), _pt_iup_eq(n + 1), _pt_iup_gt(n + 2),
        _pt_throws(() -> _pt_iup_nana(nothing)) == 4), Int64(0)),
    ("issue_52439", (n::Int64) -> ((x, y) = _pt_i52439_sw(n); _dw_bits(x == 42, y === nothing)), Int64(84)),
    ("issue52409", (n::Int64) -> _pt_i52409_f(n) + n, Int64(0)),
    ("issue54559", (s::String) -> _dw_bits(_pt_i54559(s)), "hello world"),
    ("non_interface_object_pattern", (n::Int64) -> (s = Int64(0);
        for r in (_pt_nio(Any, _pt_nio_function), _pt_nio(Any, _pt_nio_int), _pt_nio(Any, _pt_nio_string), _pt_nio(Bool, _pt_nio_bool),
                  _pt_nio(Any, _pt_nio_bool), _pt_nio(Number, _pt_nio_bool), _pt_nio(Any, _pt_nio_dynamic), _pt_nio(Any, _pt_nio_dynamic),
                  _pt_nio(Bool, _pt_nio_dynamic), _pt_nio(Any, _pt_nio_multi), _pt_nio(Any, nothing), _pt_nio(Any, n));
            s = 8s + r;
        end; s), Int64(0)),
    ("nullable_object_pattern", (n::Int64) -> _dw_bits(
        _pt_nop_without(nothing), _pt_nop_without(n), !_pt_nop_without(""),
        _pt_nop_potential(_PtNopA, nothing), _pt_nop_potential(_PtNopA, n), !_pt_nop_potential(_PtNopA, ""),
        !_pt_nop_potential(Int64, nothing), _pt_nop_potential(Int64, n), !_pt_nop_potential(Int64, ""),
        !_pt_nop_potential(Union{}, nothing), !_pt_nop_potential(Union{}, n), !_pt_nop_potential(Union{}, ""),
        !_pt_nop_nonnull(Int64, nothing), _pt_nop_nonnull(Int64, n), !_pt_nop_nonnull(Int64, n + 1), !_pt_nop_nonnull(Int64, ""),
        !_pt_nop_nonnull(Union{}, nothing), !_pt_nop_nonnull(Union{}, n), !_pt_nop_nonnull(Union{}, n + 1), !_pt_nop_nonnull(Union{}, ""),
        _pt_nop_fields(nothing), _pt_nop_fields(n), !_pt_nop_fields("")), Int64(0)),
    ("object_pattern_inference", (n::Int64) -> _dw_bits(_pt_opi_explicit(_PtOpiC(n)), _pt_opi_simple(_PtOpiC(n)), _pt_opi_dynamic(_PtOpiC(n)),
        !_pt_opi_dynamic(n), _pt_opi_bound(_PtOpiD(n)), !_pt_opi_bound(n), _pt_opi_enclosing(_PtOpiE{Int64,String}(n, ""), _PtOpiE(Set([""]), Set([n]))),
        _pt_opi_fbounded(_PtOpiF2()), !_pt_opi_fbounded(n), _pt_opi_partial(_PtOpiG2(n, Set([n]))), !_pt_opi_partial(_PtOpiG1(n)),
        _pt_opi_alias(_PtOpiH1{Int64,String}(n, "")), _pt_opi_alias(_PtOpiH1{Number,String}(n, "")), !_pt_opi_alias(_PtOpiH1{Any,String}(n, "")),
        _pt_opi_fntype((o::Any) -> string(o)), _pt_opi_fntype((m::Number) -> string(m)), !_pt_opi_fntype((i::Int64) -> string(i))), Int64(0)),
    ("primitive_switch", (n::Int64) -> (s = Int64(n);
        for a in instances(_PtPsA); s = 6s + _pt_ps_expr_a(a); end;
        for a in instances(_PtPsA); s = 6s + _pt_ps_stmt_a(a); end;
        for b in instances(_PtPsB); s = 6s + _pt_ps_expr_b(b); end;
        for b in instances(_PtPsB); s = 6s + _pt_ps_stmt_b(b); end;
        for i in (instances(_PtPsA)..., instances(_PtPsB)...); s = 6s + _pt_ps_expr_i(i); end;
        for i in (instances(_PtPsA)..., instances(_PtPsB)...); s = 6s + _pt_ps_stmt_i(i); end; s), Int64(0)),
    ("record_type_object_pattern", (n::Int64) -> _pt_rto(n), Int64(1)),
    ("regress_59613", (x::Float64) -> _pt_r59613(x), 42.42),
    ("relational_pattern_expression_precedence", (n::Int64) -> (s = Int64(0);
        for b in (_pt_rpe_eq(==, n), _pt_rpe_eq(!=, n), _pt_rpe_ord(<=, n), _pt_rpe_ord(<, n), _pt_rpe_ord(>=, n), _pt_rpe_ord(>, n));
            s = s * 65537 + b;
        end; s), Int64(0)),
    ("schema", (n::Int64) -> _pt_schema(n), Int64(1)),
    ("shared_case_variable", (n::Int64) -> _dw_bits(
        _pt_scv_finality(n, n) == "0: int", _pt_scv_finality(n + 1, n + 1) == "1: final int", _pt_scv_finality(n + 2, n + 2) == "2: var",
        _pt_scv_finality(n + 3, n + 3) == "3: final",
        _pt_scv_type(n, n) == "0: int", _pt_scv_type(n + 1, true) == "true: bool", _pt_scv_type(n + 2, "s") == "s: var",
        _pt_scv_variable(n, "unique") == "unique: unique", _pt_scv_variable(n + 1, "in") == "in: inTwo", _pt_scv_variable(n + 2, "two") == "two: inTwo",
        _pt_scv_annotated(n, "one") == "one: var", _pt_scv_annotated(n + 1, "two") == "two: Object",
        _pt_scv_promoted(n, "one") == "one: var", _pt_scv_promoted(n + 1, "two") == "two: String",
        _pt_scv_context(Union{Int64,Bool}[n, true]) == "0: 0: list", _pt_scv_context(Dict{String,Union{Int64,Bool}}("a" => n + 1, "b" => true)) == "1: 1: map",
        _pt_scv_context((a = n + 2, b = true)) == "2: 2: record", _pt_scv_context((a = n + 3, b = [true])) == "3: 3: nested"), Int64(0)),
    ("switch_case_scope", (s::String) -> _dw_bits(_pt_scs_body(s), _pt_scs_unshared(("pat", "tern")), _pt_scs_shared(("pat", "tern"), Int64(0)),
        _pt_scs_shared(("pat", "tern"), Int64(1))), "pattern"),
    ("type_question_before_when", (n::Int64) -> _dw_bits(_pt_tqw_matched(nothing, true), _pt_tqw_matched(n, true), !_pt_tqw_matched(n, false),
        _pt_throws(() -> _pt_tqw_matched("", true)) == 1, _pt_tqw_as(true, "a", "b") == "a", _pt_tqw_as(false, "a", "b") == "b",
        _pt_tqw_is(n, "a", "b") == "a", _pt_tqw_is("x", "a", "b") == "b"), Int64(0)),
    ("version_2_29_changes", (n::Int64) -> (m = Dict("a" => n, "b" => n + 1);
        _dw_bits(_pt_v229_has_a(_PtNoLengthMap(m)), _pt_v229_ab(m) == "a b", _pt_throws(() -> length(_PtNoLengthMap(m))) == 2)), Int64(1)),
    ("wildcard_in_matching_context", (n::Int64) -> (v = [n];
        _dw_bits(length(v) == 1, length(v) == 1, length(v) == 1 && v[1] isa Int64, length(v) == 1 && v[1] isa Int64, length(v) == 1)), Int64(0)),
    ("wildcard_in_pattern_assignment", (n::Int64) -> (x = Int64(-1); (x, _) = [n, n + 1]; x), Int64(0)),
    ("wildcard_in_pattern_variable_declaration", (n::Int64) -> ((x, _) = [n, n + 1]; (y, w) = [n, n + 1]; _dw_bits(x == 0, y == 0, w isa Int64)), Int64(0)),
])

# ---- tests/language/function_type: the generated function_type<N> tests, function types as values ----
# Each case takes 5 of the file's typedefs covering its distinct shapes: [x] -> a default, {x} -> a keyword,
# <A>/<B extends int> -> a Type argument, a function-typed return -> a closure; each is called, and
# applicable/hasmethod answer dart's `is F_i`; a typedef taking List<T> also gets a method on _FtU{T}.
struct _FtU{T} end
_ft_id(x) = x
_ft_w(x::Int64) = x
_ft_w(x::Vector{Int64}) = sum(x)
_ft_w(x::Vector{Function}) = Int64(length(x))
_ft_w(x::Vector{Bool}) = Int64(length(x))
_ft_w(x::Function) = Int64(7)
_ft_mix(hs::Int64...) = foldl((a, b) -> 1000003 * a + b, hs; init = Int64(0))

# function_type0: F1 = Function Function(List<T> x); F2 = core.List<core.int> Function(int y, {List<Function> x}); F3 = Function(int, {Function x}); F11 = List<Function> Function(int y, [List<T> x]) Function(); F23 = void Function<A>(core.List<core.int> x) Function()
function _ft_f0_1(p1_1::Vector{Int64})
    s1 = Int64(0) + _ft_w(p1_1)
    return () -> s1
end
_ft_m0_1(u::_FtU{T}, p1_1::Vector{T}) where {T} = Int64(0) + _ft_w(p1_1)
function _ft_t0_1(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f0_1(Int64[n, 1])
    h = 31h + Int64(v2 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f0_1, Int64[n, 1]), !applicable(_ft_f0_1, Int64[n, 1], n), hasmethod(_ft_f0_1, Tuple{Vector{Int64}}), !applicable(_ft_f0_1, Bool[true]))
    h = 31h + _ft_m0_1(_FtU{Int64}(), Int64[n, 201]) + _ft_m0_1(_FtU{Bool}(), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m0_1, _FtU{Bool}(), Bool[true]), !applicable(_ft_m0_1, _FtU{Int64}(), Bool[true]))
    return h
end
function _ft_f0_2(p1_1::Int64; x::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return Int64[s1]
end
function _ft_t0_2(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f0_2((n + 1))
    h = 31h + sum(v3)
    local v4 = _ft_f0_2((n + 1); x = Function[_ft_id])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(_ft_f0_2, (n + 1)), !applicable(_ft_f0_2, (n + 1), n), hasmethod(_ft_f0_2, Tuple{Int64}))
    return h
end
function _ft_f0_3(p1_1::Int64; x::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return s1
end
function _ft_t0_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f0_3((n + 1))
    h = 31h + v3
    local v4 = _ft_f0_3((n + 1); x = _ft_id)
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f0_3, (n + 1)), !applicable(_ft_f0_3, (n + 1), n), hasmethod(_ft_f0_3, Tuple{Int64}))
    return h
end
function _ft_f0_11()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t0_11(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f0_11()
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2), Int64[n, 3])
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Int64[n, 3], n), !applicable(v1, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f0_11), !applicable(_ft_f0_11, n), hasmethod(_ft_f0_11, Tuple{}))
    return h
end
function _ft_f0_23()
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t0_23(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f0_23()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f0_23), !applicable(_ft_f0_23, n), hasmethod(_ft_f0_23, Tuple{}))
    return h
end

# function_type1: F3 = Function(int y, {Function x}); F4 = Function Function<A>(Function x); F11 = List<Function> Function(int y, [List<T> x]) Function(int x); F19 = void Function([List<Function> x]) Function(int x); F22 = Function<A>(List<Function> x) Function(int x)
function _ft_f1_3(p1_1::Int64; x::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return s1
end
function _ft_t1_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f1_3((n + 1))
    h = 31h + v3
    local v4 = _ft_f1_3((n + 1); x = _ft_id)
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f1_3, (n + 1)), !applicable(_ft_f1_3, (n + 1), n), hasmethod(_ft_f1_3, Tuple{Int64}))
    return h
end
function _ft_f1_4(::Type{A}, p1_1::Function) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return () -> s1
end
function _ft_t1_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f1_4(Int64, _ft_id)
    h = 31h + Int64(v2 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f1_4, Int64, _ft_id), !applicable(_ft_f1_4, Int64, _ft_id, n), hasmethod(_ft_f1_4, Tuple{Type{Int64}, typeof(_ft_id)}))
    return h
end
function _ft_f1_11(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t1_11(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f1_11((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3), Int64[n, 4])
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Int64[n, 4], n), !applicable(v2, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f1_11, (n + 1)), !applicable(_ft_f1_11, (n + 1), n), hasmethod(_ft_f1_11, Tuple{Int64}))
    return h
end
function _ft_f1_19(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t1_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f1_19((n + 1))
    local v4 = v2()
    h = 31h + Int64(v4 === nothing)
    local v5 = v2(Function[_ft_id])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f1_19, (n + 1)), !applicable(_ft_f1_19, (n + 1), n), hasmethod(_ft_f1_19, Tuple{Int64}))
    return h
end
function _ft_f1_22(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t1_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f1_22((n + 1))
    local v4 = v2(Int64, Function[_ft_id])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, Function[_ft_id]), !applicable(v2, Int64, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f1_22, (n + 1)), !applicable(_ft_f1_22, (n + 1), n), hasmethod(_ft_f1_22, Tuple{Int64}))
    return h
end

# function_type2: F0 = int Function(int, [int x]); F5 = int Function(int, {int x}) Function<B extends core.int>(); F11 = List<Function> Function(int y, [List<T> x]) Function<B extends core.int>(); F19 = void Function([List<Function> x]) Function<B extends core.int>(); F22 = Function<A>(List<Function> x) Function<B extends core.int>()
function _ft_f2_0(p1_1::Int64, p1_2::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
function _ft_t2_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f2_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f2_0((n + 1), (n + 2))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f2_0, (n + 1)), !applicable(_ft_f2_0, (n + 1), (n + 2), n), hasmethod(_ft_f2_0, Tuple{Int64}))
    return h
end
function _ft_f2_5(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t2_5(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f2_5(Int64)
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2); x = (n + 3))
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f2_5, Int64), !applicable(_ft_f2_5, Int64, n), hasmethod(_ft_f2_5, Tuple{Type{Int64}}))
    return h
end
function _ft_f2_11(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t2_11(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f2_11(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2), Int64[n, 3])
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Int64[n, 3], n), !applicable(v1, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f2_11, Int64), !applicable(_ft_f2_11, Int64, n), hasmethod(_ft_f2_11, Tuple{Type{Int64}}))
    return h
end
function _ft_f2_19(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t2_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f2_19(Int64)
    local v3 = v1()
    h = 31h + Int64(v3 === nothing)
    local v4 = v1(Function[_ft_id])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f2_19, Int64), !applicable(_ft_f2_19, Int64, n), hasmethod(_ft_f2_19, Tuple{Type{Int64}}))
    return h
end
function _ft_f2_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t2_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f2_22(Int64)
    local v3 = v1(Int64, Function[_ft_id])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, Function[_ft_id]), !applicable(v1, Int64, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f2_22, Int64), !applicable(_ft_f2_22, Int64, n), hasmethod(_ft_f2_22, Tuple{Type{Int64}}))
    return h
end

# function_type3: F0 = int Function(int y, [int x]); F5 = int Function(int, {int x}) Function<B extends core.int>(int x); F11 = List<Function> Function(int y, [List<T> x]) Function<B extends core.int>( int x, ); F19 = void Function([List<Function> x]) Function<B extends core.int>( int x, ); F22 = Function<A>(List<Function> x) Function<B extends core.int>( int x, )
function _ft_f3_0(p1_1::Int64, p1_2::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
function _ft_t3_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f3_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f3_0((n + 1), (n + 2))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f3_0, (n + 1)), !applicable(_ft_f3_0, (n + 1), (n + 2), n), hasmethod(_ft_f3_0, Tuple{Int64}))
    return h
end
function _ft_f3_5(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t3_5(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f3_5(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + v5
    local v6 = v2((n + 3); x = (n + 4))
    h = 31h + v6
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f3_5, Int64, (n + 1)), !applicable(_ft_f3_5, Int64, (n + 1), n), hasmethod(_ft_f3_5, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f3_11(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t3_11(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f3_11(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3), Int64[n, 4])
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Int64[n, 4], n), !applicable(v2, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f3_11, Int64, (n + 1)), !applicable(_ft_f3_11, Int64, (n + 1), n), hasmethod(_ft_f3_11, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f3_19(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t3_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f3_19(Int64, (n + 1))
    local v4 = v2()
    h = 31h + Int64(v4 === nothing)
    local v5 = v2(Function[_ft_id])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f3_19, Int64, (n + 1)), !applicable(_ft_f3_19, Int64, (n + 1), n), hasmethod(_ft_f3_19, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f3_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t3_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f3_22(Int64, (n + 1))
    local v4 = v2(Int64, Function[_ft_id])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, Function[_ft_id]), !applicable(v2, Int64, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f3_22, Int64, (n + 1)), !applicable(_ft_f3_22, Int64, (n + 1), n), hasmethod(_ft_f3_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type4: F2 = core.List<core.int> Function(int y, [core.List<core.int> x]); F4 = Function Function<A>(List<T> x); F17 = Function({List<Function> x}) Function(); F19 = void Function(int, [List<Function> x]) Function(); F21 = List<Function> Function<A>(List<Function> x) Function()
function _ft_f4_2(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return Int64[s1]
end
function _ft_t4_2(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f4_2((n + 1))
    h = 31h + sum(v3)
    local v4 = _ft_f4_2((n + 1), Int64[n, 2])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(_ft_f4_2, (n + 1)), !applicable(_ft_f4_2, (n + 1), Int64[n, 2], n), hasmethod(_ft_f4_2, Tuple{Int64}))
    return h
end
function _ft_f4_4(::Type{A}, p1_1::Vector{Int64}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return () -> s1
end
_ft_m4_4(u::_FtU{T}, ::Type{A}, p1_1::Vector{T}) where {T, A} = Int64(0) + _ft_w(p1_1)
function _ft_t4_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f4_4(Int64, Int64[n, 1])
    h = 31h + Int64(v2 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f4_4, Int64, Int64[n, 1]), !applicable(_ft_f4_4, Int64, Int64[n, 1], n), hasmethod(_ft_f4_4, Tuple{Type{Int64}, Vector{Int64}}), !applicable(_ft_f4_4, Int64, Bool[true]))
    h = 31h + _ft_m4_4(_FtU{Int64}(), Int64, Int64[n, 201]) + _ft_m4_4(_FtU{Bool}(), Int64, Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m4_4, _FtU{Bool}(), Int64, Bool[true]), !applicable(_ft_m4_4, _FtU{Int64}(), Int64, Bool[true]))
    return h
end
function _ft_f4_17()
    s1 = Int64(0)
    return function (; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(x)
        s2
    end
end
function _ft_t4_17(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f4_17()
    local v3 = v1()
    h = 31h + v3
    local v4 = v1(; x = Function[_ft_id])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, n))
    h = 31h + _dw_bits(applicable(_ft_f4_17), !applicable(_ft_f4_17, n), hasmethod(_ft_f4_17, Tuple{}))
    return h
end
function _ft_f4_19()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t4_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f4_19()
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f4_19), !applicable(_ft_f4_19, n), hasmethod(_ft_f4_19, Tuple{}))
    return h
end
function _ft_f4_21()
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        Function[_ft_id]
    end
end
function _ft_t4_21(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f4_21()
    local v3 = v1(Int64, Function[_ft_id])
    h = 31h + Int64(length(v3))
    h = 31h + _dw_bits(applicable(v1, Int64, Function[_ft_id]), !applicable(v1, Int64, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f4_21), !applicable(_ft_f4_21, n), hasmethod(_ft_f4_21, Tuple{}))
    return h
end

# function_type5: F0 = int Function([int]); F4 = Function Function<A>(); F9 = Function Function(int y, {List<T> x}) Function(int x); F19 = void Function(int, [List<Function> x]) Function(int x); F22 = Function<A>(core.List<core.int> x) Function(int x)
function _ft_f5_0(p1_1::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t5_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f5_0()
    h = 31h + v2
    local v3 = _ft_f5_0((n + 1))
    h = 31h + v3
    h = 31h + _dw_bits(applicable(_ft_f5_0), !applicable(_ft_f5_0, (n + 1), n), hasmethod(_ft_f5_0, Tuple{}))
    return h
end
function _ft_f5_4(::Type{A}) where {A}
    s1 = Int64(0)
    return () -> s1
end
function _ft_t5_4(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f5_4(Int64)
    h = 31h + Int64(v1 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f5_4, Int64), !applicable(_ft_f5_4, Int64, n), hasmethod(_ft_f5_4, Tuple{Type{Int64}}))
    return h
end
function _ft_f5_9(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        () -> s2
    end
end
function _ft_t5_9(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f5_9((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 isa Function)
    local v6 = v2((n + 3); x = Int64[n, 4])
    h = 31h + Int64(v6 isa Function)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f5_9, (n + 1)), !applicable(_ft_f5_9, (n + 1), n), hasmethod(_ft_f5_9, Tuple{Int64}))
    return h
end
function _ft_f5_19(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t5_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f5_19((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f5_19, (n + 1)), !applicable(_ft_f5_19, (n + 1), n), hasmethod(_ft_f5_19, Tuple{Int64}))
    return h
end
function _ft_f5_22(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t5_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f5_22((n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f5_22, (n + 1)), !applicable(_ft_f5_22, (n + 1), n), hasmethod(_ft_f5_22, Tuple{Int64}))
    return h
end

# function_type6: F0 = int Function(int, [int]); F4 = Function Function<A>(A x); F9 = Function Function(int y, {List<T> x}) Function<B extends core.int>(); F19 = void Function(int, [List<Function> x]) Function<B extends core.int>(); F22 = Function<A>(core.List<core.int> x) Function<B extends core.int>()
function _ft_f6_0(p1_1::Int64, p1_2::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
function _ft_t6_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f6_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f6_0((n + 1), (n + 2))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f6_0, (n + 1)), !applicable(_ft_f6_0, (n + 1), (n + 2), n), hasmethod(_ft_f6_0, Tuple{Int64}))
    return h
end
function _ft_f6_4(::Type{A}, p1_1::A) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return () -> s1
end
function _ft_t6_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f6_4(Int64, (n + 1))
    h = 31h + Int64(v2 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f6_4, Int64, (n + 1)), !applicable(_ft_f6_4, Int64, (n + 1), n), hasmethod(_ft_f6_4, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f6_9(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        () -> s2
    end
end
function _ft_t6_9(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f6_9(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 isa Function)
    local v5 = v1((n + 2); x = Int64[n, 3])
    h = 31h + Int64(v5 isa Function)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f6_9, Int64), !applicable(_ft_f6_9, Int64, n), hasmethod(_ft_f6_9, Tuple{Type{Int64}}))
    return h
end
function _ft_f6_19(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t6_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f6_19(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f6_19, Int64), !applicable(_ft_f6_19, Int64, n), hasmethod(_ft_f6_19, Tuple{Type{Int64}}))
    return h
end
function _ft_f6_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t6_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f6_22(Int64)
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f6_22, Int64), !applicable(_ft_f6_22, Int64, n), hasmethod(_ft_f6_22, Tuple{Type{Int64}}))
    return h
end

# function_type7: F0 = int Function(int x, [int]); F4 = Function Function<A>(List<A> x); F9 = Function Function(int y, {List<T> x}) Function<B extends core.int>(int x); F18 = Function() Function<B extends core.int>(int x); F19 = void Function(int, [List<Function> x]) Function<B extends core.int>(int x)
function _ft_f7_0(p1_1::Int64, p1_2::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
function _ft_t7_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f7_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f7_0((n + 1), (n + 2))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f7_0, (n + 1)), !applicable(_ft_f7_0, (n + 1), (n + 2), n), hasmethod(_ft_f7_0, Tuple{Int64}))
    return h
end
function _ft_f7_4(::Type{A}, p1_1::Vector{A}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return () -> s1
end
function _ft_t7_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f7_4(Int64, Int64[n, 1])
    h = 31h + Int64(v2 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f7_4, Int64, Int64[n, 1]), !applicable(_ft_f7_4, Int64, Int64[n, 1], n), hasmethod(_ft_f7_4, Tuple{Type{Int64}, Vector{Int64}}))
    return h
end
function _ft_f7_9(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        () -> s2
    end
end
function _ft_t7_9(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f7_9(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 isa Function)
    local v6 = v2((n + 3); x = Int64[n, 4])
    h = 31h + Int64(v6 isa Function)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f7_9, Int64, (n + 1)), !applicable(_ft_f7_9, Int64, (n + 1), n), hasmethod(_ft_f7_9, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f7_18(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function ()
        s2 = s1
        s2
    end
end
function _ft_t7_18(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f7_18(Int64, (n + 1))
    local v3 = v2()
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f7_18, Int64, (n + 1)), !applicable(_ft_f7_18, Int64, (n + 1), n), hasmethod(_ft_f7_18, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f7_19(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t7_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f7_19(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f7_19, Int64, (n + 1)), !applicable(_ft_f7_19, Int64, (n + 1), n), hasmethod(_ft_f7_19, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type8: F0 = int Function({int x}); F4 = List<Function> Function<A>(int x); F17 = Function(int, {List<Function> x}) Function(); F20 = void Function(int, [List<T>]) Function(); F21 = List<Function> Function<A>(core.List<core.int> x) Function()
function _ft_f8_0(; x::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(x)
    return s1
end
function _ft_t8_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f8_0()
    h = 31h + v2
    local v3 = _ft_f8_0(; x = (n + 1))
    h = 31h + v3
    h = 31h + _dw_bits(applicable(_ft_f8_0), !applicable(_ft_f8_0, n), hasmethod(_ft_f8_0, Tuple{}))
    return h
end
function _ft_f8_4(::Type{A}, p1_1::Int64) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return Function[_ft_id]
end
function _ft_t8_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f8_4(Int64, (n + 1))
    h = 31h + Int64(length(v2))
    h = 31h + _dw_bits(applicable(_ft_f8_4, Int64, (n + 1)), !applicable(_ft_f8_4, Int64, (n + 1), n), hasmethod(_ft_f8_4, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f8_17()
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t8_17(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f8_17()
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2); x = Function[_ft_id])
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f8_17), !applicable(_ft_f8_17, n), hasmethod(_ft_f8_17, Tuple{}))
    return h
end
function _ft_f8_20()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t8_20(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f8_20()
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2), Int64[n, 3])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Int64[n, 3], n), !applicable(v1, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f8_20), !applicable(_ft_f8_20, n), hasmethod(_ft_f8_20, Tuple{}))
    return h
end
function _ft_f8_21()
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        Function[_ft_id]
    end
end
function _ft_t8_21(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f8_21()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + Int64(length(v3))
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f8_21), !applicable(_ft_f8_21, n), hasmethod(_ft_f8_21, Tuple{}))
    return h
end

# function_type9: F0 = int Function(int, {int x}); F4 = List<Function> Function<A>(Function x); F17 = Function(int, {List<Function> x}) Function(int x); F20 = void Function(int, [List<T>]) Function(int x); F23 = void Function<A>() Function(int x)
function _ft_f9_0(p1_1::Int64; x::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return s1
end
function _ft_t9_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f9_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f9_0((n + 1); x = (n + 2))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f9_0, (n + 1)), !applicable(_ft_f9_0, (n + 1), n), hasmethod(_ft_f9_0, Tuple{Int64}))
    return h
end
function _ft_f9_4(::Type{A}, p1_1::Function) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return Function[_ft_id]
end
function _ft_t9_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f9_4(Int64, _ft_id)
    h = 31h + Int64(length(v2))
    h = 31h + _dw_bits(applicable(_ft_f9_4, Int64, _ft_id), !applicable(_ft_f9_4, Int64, _ft_id, n), hasmethod(_ft_f9_4, Tuple{Type{Int64}, typeof(_ft_id)}))
    return h
end
function _ft_f9_17(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t9_17(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f9_17((n + 1))
    local v5 = v2((n + 3))
    h = 31h + v5
    local v6 = v2((n + 3); x = Function[_ft_id])
    h = 31h + v6
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f9_17, (n + 1)), !applicable(_ft_f9_17, (n + 1), n), hasmethod(_ft_f9_17, Tuple{Int64}))
    return h
end
function _ft_f9_20(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t9_20(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f9_20((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3), Int64[n, 4])
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Int64[n, 4], n), !applicable(v2, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f9_20, (n + 1)), !applicable(_ft_f9_20, (n + 1), n), hasmethod(_ft_f9_20, Tuple{Int64}))
    return h
end
function _ft_f9_23(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type)
        s2 = s1
        nothing
    end
end
function _ft_t9_23(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f9_23((n + 1))
    local v3 = v2(Int64)
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(v2, Int64), !applicable(v2, Int64, n))
    h = 31h + _dw_bits(applicable(_ft_f9_23, (n + 1)), !applicable(_ft_f9_23, (n + 1), n), hasmethod(_ft_f9_23, Tuple{Int64}))
    return h
end

# function_type10: F0 = int Function(int y, {int x}); F4 = List<Function> Function<A>(List<Function> x); F17 = Function(int, {List<Function> x}) Function<B extends core.int>(); F20 = void Function(int, [List<T>]) Function<B extends core.int>(); F21 = List<Function> Function<A>(core.List<core.int> x) Function<B extends core.int>()
function _ft_f10_0(p1_1::Int64; x::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return s1
end
function _ft_t10_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f10_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f10_0((n + 1); x = (n + 2))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f10_0, (n + 1)), !applicable(_ft_f10_0, (n + 1), n), hasmethod(_ft_f10_0, Tuple{Int64}))
    return h
end
function _ft_f10_4(::Type{A}, p1_1::Vector{Function}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return Function[_ft_id]
end
function _ft_t10_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f10_4(Int64, Function[_ft_id])
    h = 31h + Int64(length(v2))
    h = 31h + _dw_bits(applicable(_ft_f10_4, Int64, Function[_ft_id]), !applicable(_ft_f10_4, Int64, Function[_ft_id], n), hasmethod(_ft_f10_4, Tuple{Type{Int64}, Vector{Function}}))
    return h
end
function _ft_f10_17(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t10_17(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f10_17(Int64)
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2); x = Function[_ft_id])
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f10_17, Int64), !applicable(_ft_f10_17, Int64, n), hasmethod(_ft_f10_17, Tuple{Type{Int64}}))
    return h
end
function _ft_f10_20(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t10_20(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f10_20(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2), Int64[n, 3])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Int64[n, 3], n), !applicable(v1, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f10_20, Int64), !applicable(_ft_f10_20, Int64, n), hasmethod(_ft_f10_20, Tuple{Type{Int64}}))
    return h
end
function _ft_f10_21(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        Function[_ft_id]
    end
end
function _ft_t10_21(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f10_21(Int64)
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + Int64(length(v3))
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f10_21, Int64), !applicable(_ft_f10_21, Int64, n), hasmethod(_ft_f10_21, Tuple{Type{Int64}}))
    return h
end

# function_type11: F0 = int Function(Function x); F4 = List<Function> Function<A>(core.List<core.int> x); F17 = Function(int, {List<Function> x}) Function<B extends core.int>( int x, ); F20 = void Function(int, [List<T>]) Function<B extends core.int>( int x, ); F23 = void Function<A>() Function<B extends core.int>(int x)
function _ft_f11_0(p1_1::Function)
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t11_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f11_0(_ft_id)
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f11_0, _ft_id), !applicable(_ft_f11_0, _ft_id, n), hasmethod(_ft_f11_0, Tuple{typeof(_ft_id)}))
    return h
end
function _ft_f11_4(::Type{A}, p1_1::Vector{Int64}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return Function[_ft_id]
end
function _ft_t11_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f11_4(Int64, Int64[n, 1])
    h = 31h + Int64(length(v2))
    h = 31h + _dw_bits(applicable(_ft_f11_4, Int64, Int64[n, 1]), !applicable(_ft_f11_4, Int64, Int64[n, 1], n), hasmethod(_ft_f11_4, Tuple{Type{Int64}, Vector{Int64}}))
    return h
end
function _ft_f11_17(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t11_17(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f11_17(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + v5
    local v6 = v2((n + 3); x = Function[_ft_id])
    h = 31h + v6
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f11_17, Int64, (n + 1)), !applicable(_ft_f11_17, Int64, (n + 1), n), hasmethod(_ft_f11_17, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f11_20(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t11_20(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f11_20(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3), Int64[n, 4])
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Int64[n, 4], n), !applicable(v2, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f11_20, Int64, (n + 1)), !applicable(_ft_f11_20, Int64, (n + 1), n), hasmethod(_ft_f11_20, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f11_23(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type)
        s2 = s1
        nothing
    end
end
function _ft_t11_23(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f11_23(Int64, (n + 1))
    local v3 = v2(Int64)
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(v2, Int64), !applicable(v2, Int64, n))
    h = 31h + _dw_bits(applicable(_ft_f11_23, Int64, (n + 1)), !applicable(_ft_f11_23, Int64, (n + 1), n), hasmethod(_ft_f11_23, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type12: F0 = int Function([Function x]); F3 = Function(int y, {List<Function> x}); F4 = List<Function> Function<A>(List<T> x); F11 = List<Function> Function(int, [List<T>]) Function(); F23 = void Function<A>(A x) Function()
function _ft_f12_0(p1_1::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t12_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f12_0()
    h = 31h + v2
    local v3 = _ft_f12_0(_ft_id)
    h = 31h + v3
    h = 31h + _dw_bits(applicable(_ft_f12_0), !applicable(_ft_f12_0, _ft_id, n), hasmethod(_ft_f12_0, Tuple{}))
    return h
end
function _ft_f12_3(p1_1::Int64; x::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return s1
end
function _ft_t12_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f12_3((n + 1))
    h = 31h + v3
    local v4 = _ft_f12_3((n + 1); x = Function[_ft_id])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f12_3, (n + 1)), !applicable(_ft_f12_3, (n + 1), n), hasmethod(_ft_f12_3, Tuple{Int64}))
    return h
end
function _ft_f12_4(::Type{A}, p1_1::Vector{Int64}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return Function[_ft_id]
end
_ft_m12_4(u::_FtU{T}, ::Type{A}, p1_1::Vector{T}) where {T, A} = Int64(0) + _ft_w(p1_1)
function _ft_t12_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f12_4(Int64, Int64[n, 1])
    h = 31h + Int64(length(v2))
    h = 31h + _dw_bits(applicable(_ft_f12_4, Int64, Int64[n, 1]), !applicable(_ft_f12_4, Int64, Int64[n, 1], n), hasmethod(_ft_f12_4, Tuple{Type{Int64}, Vector{Int64}}), !applicable(_ft_f12_4, Int64, Bool[true]))
    h = 31h + _ft_m12_4(_FtU{Int64}(), Int64, Int64[n, 201]) + _ft_m12_4(_FtU{Bool}(), Int64, Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m12_4, _FtU{Bool}(), Int64, Bool[true]), !applicable(_ft_m12_4, _FtU{Int64}(), Int64, Bool[true]))
    return h
end
function _ft_f12_11()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t12_11(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f12_11()
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2), Int64[n, 3])
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Int64[n, 3], n), !applicable(v1, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f12_11), !applicable(_ft_f12_11, n), hasmethod(_ft_f12_11, Tuple{}))
    return h
end
function _ft_f12_23()
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t12_23(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f12_23()
    local v3 = v1(Int64, (n + 2))
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(v1, Int64, (n + 2)), !applicable(v1, Int64, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f12_23), !applicable(_ft_f12_23, n), hasmethod(_ft_f12_23, Tuple{}))
    return h
end

# function_type13: F0 = int Function(int, [Function x]); F8 = Function Function(int, {List<Function> x}) Function(int x); F11 = List<Function> Function(int, [List<T>]) Function(int x); F18 = void Function([int x]) Function(int x); F22 = Function<A>() Function(int x)
function _ft_f13_0(p1_1::Int64, p1_2::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
function _ft_t13_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f13_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f13_0((n + 1), _ft_id)
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f13_0, (n + 1)), !applicable(_ft_f13_0, (n + 1), _ft_id, n), hasmethod(_ft_f13_0, Tuple{Int64}))
    return h
end
function _ft_f13_8(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        () -> s2
    end
end
function _ft_t13_8(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f13_8((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 isa Function)
    local v6 = v2((n + 3); x = Function[_ft_id])
    h = 31h + Int64(v6 isa Function)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f13_8, (n + 1)), !applicable(_ft_f13_8, (n + 1), n), hasmethod(_ft_f13_8, Tuple{Int64}))
    return h
end
function _ft_f13_11(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t13_11(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f13_11((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3), Int64[n, 4])
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Int64[n, 4], n), !applicable(v2, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f13_11, (n + 1)), !applicable(_ft_f13_11, (n + 1), n), hasmethod(_ft_f13_11, Tuple{Int64}))
    return h
end
function _ft_f13_18(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t13_18(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f13_18((n + 1))
    local v4 = v2()
    h = 31h + Int64(v4 === nothing)
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f13_18, (n + 1)), !applicable(_ft_f13_18, (n + 1), n), hasmethod(_ft_f13_18, Tuple{Int64}))
    return h
end
function _ft_f13_22(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type)
        s2 = s1
        s2
    end
end
function _ft_t13_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f13_22((n + 1))
    local v3 = v2(Int64)
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v2, Int64), !applicable(v2, Int64, n))
    h = 31h + _dw_bits(applicable(_ft_f13_22, (n + 1)), !applicable(_ft_f13_22, (n + 1), n), hasmethod(_ft_f13_22, Tuple{Int64}))
    return h
end

# function_type14: F0 = int Function(int y, [Function x]); F4 = List<Function> Function<A>(A x); F11 = List<Function> Function(int, [List<T>]) Function<B extends core.int>(); F17 = Function(int y, {List<Function> x}) Function<B extends core.int>(); F23 = void Function<A>(A x) Function<B extends core.int>()
function _ft_f14_0(p1_1::Int64, p1_2::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
function _ft_t14_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f14_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f14_0((n + 1), _ft_id)
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f14_0, (n + 1)), !applicable(_ft_f14_0, (n + 1), _ft_id, n), hasmethod(_ft_f14_0, Tuple{Int64}))
    return h
end
function _ft_f14_4(::Type{A}, p1_1::A) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return Function[_ft_id]
end
function _ft_t14_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f14_4(Int64, (n + 1))
    h = 31h + Int64(length(v2))
    h = 31h + _dw_bits(applicable(_ft_f14_4, Int64, (n + 1)), !applicable(_ft_f14_4, Int64, (n + 1), n), hasmethod(_ft_f14_4, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f14_11(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t14_11(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f14_11(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2), Int64[n, 3])
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Int64[n, 3], n), !applicable(v1, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f14_11, Int64), !applicable(_ft_f14_11, Int64, n), hasmethod(_ft_f14_11, Tuple{Type{Int64}}))
    return h
end
function _ft_f14_17(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t14_17(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f14_17(Int64)
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2); x = Function[_ft_id])
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f14_17, Int64), !applicable(_ft_f14_17, Int64, n), hasmethod(_ft_f14_17, Tuple{Type{Int64}}))
    return h
end
function _ft_f14_23(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t14_23(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f14_23(Int64)
    local v3 = v1(Int64, (n + 2))
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(v1, Int64, (n + 2)), !applicable(v1, Int64, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f14_23, Int64), !applicable(_ft_f14_23, Int64, n), hasmethod(_ft_f14_23, Tuple{Type{Int64}}))
    return h
end

# function_type15: F4 = List<Function> Function<A>(List<A> x); F8 = Function Function(int, {List<Function> x}) Function<B extends core.int>( int x, ); F11 = List<Function> Function(int, [List<T>]) Function<B extends core.int>(int x); F18 = void Function([int x]) Function<B extends core.int>(int x); F22 = Function<A>() Function<B extends core.int>(int x)
function _ft_f15_4(::Type{A}, p1_1::Vector{A}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return Function[_ft_id]
end
function _ft_t15_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f15_4(Int64, Int64[n, 1])
    h = 31h + Int64(length(v2))
    h = 31h + _dw_bits(applicable(_ft_f15_4, Int64, Int64[n, 1]), !applicable(_ft_f15_4, Int64, Int64[n, 1], n), hasmethod(_ft_f15_4, Tuple{Type{Int64}, Vector{Int64}}))
    return h
end
function _ft_f15_8(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        () -> s2
    end
end
function _ft_t15_8(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f15_8(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 isa Function)
    local v6 = v2((n + 3); x = Function[_ft_id])
    h = 31h + Int64(v6 isa Function)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f15_8, Int64, (n + 1)), !applicable(_ft_f15_8, Int64, (n + 1), n), hasmethod(_ft_f15_8, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f15_11(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t15_11(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f15_11(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3), Int64[n, 4])
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Int64[n, 4], n), !applicable(v2, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f15_11, Int64, (n + 1)), !applicable(_ft_f15_11, Int64, (n + 1), n), hasmethod(_ft_f15_11, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f15_18(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t15_18(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f15_18(Int64, (n + 1))
    local v4 = v2()
    h = 31h + Int64(v4 === nothing)
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f15_18, Int64, (n + 1)), !applicable(_ft_f15_18, Int64, (n + 1), n), hasmethod(_ft_f15_18, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f15_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type)
        s2 = s1
        s2
    end
end
function _ft_t15_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f15_22(Int64, (n + 1))
    local v3 = v2(Int64)
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v2, Int64), !applicable(v2, Int64, n))
    h = 31h + _dw_bits(applicable(_ft_f15_22, Int64, (n + 1)), !applicable(_ft_f15_22, Int64, (n + 1), n), hasmethod(_ft_f15_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type16: F0 = int Function([Function]); F3 = Function(int y, [core.List<core.int> x]); F11 = List<Function> Function(int x, [List<T>]) Function(); F16 = Function({int x}) Function(); F23 = void Function<A>(List<A> x) Function()
function _ft_f16_0(p1_1::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t16_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f16_0()
    h = 31h + v2
    local v3 = _ft_f16_0(_ft_id)
    h = 31h + v3
    h = 31h + _dw_bits(applicable(_ft_f16_0), !applicable(_ft_f16_0, _ft_id, n), hasmethod(_ft_f16_0, Tuple{}))
    return h
end
function _ft_f16_3(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
function _ft_t16_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f16_3((n + 1))
    h = 31h + v3
    local v4 = _ft_f16_3((n + 1), Int64[n, 2])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f16_3, (n + 1)), !applicable(_ft_f16_3, (n + 1), Int64[n, 2], n), hasmethod(_ft_f16_3, Tuple{Int64}))
    return h
end
function _ft_f16_11()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t16_11(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f16_11()
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2), Int64[n, 3])
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Int64[n, 3], n), !applicable(v1, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f16_11), !applicable(_ft_f16_11, n), hasmethod(_ft_f16_11, Tuple{}))
    return h
end
function _ft_f16_16()
    s1 = Int64(0)
    return function (; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(x)
        s2
    end
end
function _ft_t16_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f16_16()
    local v3 = v1()
    h = 31h + v3
    local v4 = v1(; x = (n + 2))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, n))
    h = 31h + _dw_bits(applicable(_ft_f16_16), !applicable(_ft_f16_16, n), hasmethod(_ft_f16_16, Tuple{}))
    return h
end
function _ft_f16_23()
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t16_23(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f16_23()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f16_23), !applicable(_ft_f16_23, n), hasmethod(_ft_f16_23, Tuple{}))
    return h
end

# function_type17: F4 = core.List<core.int> Function<A>(Function x); F11 = List<Function> Function(int x, [List<T>]) Function(int x); F16 = Function({int x}) Function(int x); F21 = List<Function> Function<A>() Function(int x); F23 = void Function<A>(List<A> x) Function(int x)
function _ft_f17_4(::Type{A}, p1_1::Function) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return Int64[s1]
end
function _ft_t17_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f17_4(Int64, _ft_id)
    h = 31h + sum(v2)
    h = 31h + _dw_bits(applicable(_ft_f17_4, Int64, _ft_id), !applicable(_ft_f17_4, Int64, _ft_id, n), hasmethod(_ft_f17_4, Tuple{Type{Int64}, typeof(_ft_id)}))
    return h
end
function _ft_f17_11(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t17_11(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f17_11((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3), Int64[n, 4])
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Int64[n, 4], n), !applicable(v2, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f17_11, (n + 1)), !applicable(_ft_f17_11, (n + 1), n), hasmethod(_ft_f17_11, Tuple{Int64}))
    return h
end
function _ft_f17_16(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(x)
        s2
    end
end
function _ft_t17_16(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f17_16((n + 1))
    local v4 = v2()
    h = 31h + v4
    local v5 = v2(; x = (n + 3))
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f17_16, (n + 1)), !applicable(_ft_f17_16, (n + 1), n), hasmethod(_ft_f17_16, Tuple{Int64}))
    return h
end
function _ft_f17_21(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type)
        s2 = s1
        Function[_ft_id]
    end
end
function _ft_t17_21(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f17_21((n + 1))
    local v3 = v2(Int64)
    h = 31h + Int64(length(v3))
    h = 31h + _dw_bits(applicable(v2, Int64), !applicable(v2, Int64, n))
    h = 31h + _dw_bits(applicable(_ft_f17_21, (n + 1)), !applicable(_ft_f17_21, (n + 1), n), hasmethod(_ft_f17_21, Tuple{Int64}))
    return h
end
function _ft_f17_23(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t17_23(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f17_23((n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f17_23, (n + 1)), !applicable(_ft_f17_23, (n + 1), n), hasmethod(_ft_f17_23, Tuple{Int64}))
    return h
end

# function_type18: F0 = int Function(int x, [Function]); F4 = core.List<core.int> Function<A>(List<Function> x); F11 = List<Function> Function(int x, [List<T>]) Function<B extends core.int>(); F16 = Function({int x}) Function<B extends core.int>(); F23 = void Function<A>(List<A> x) Function<B extends core.int>()
function _ft_f18_0(p1_1::Int64, p1_2::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
function _ft_t18_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f18_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f18_0((n + 1), _ft_id)
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f18_0, (n + 1)), !applicable(_ft_f18_0, (n + 1), _ft_id, n), hasmethod(_ft_f18_0, Tuple{Int64}))
    return h
end
function _ft_f18_4(::Type{A}, p1_1::Vector{Function}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return Int64[s1]
end
function _ft_t18_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f18_4(Int64, Function[_ft_id])
    h = 31h + sum(v2)
    h = 31h + _dw_bits(applicable(_ft_f18_4, Int64, Function[_ft_id]), !applicable(_ft_f18_4, Int64, Function[_ft_id], n), hasmethod(_ft_f18_4, Tuple{Type{Int64}, Vector{Function}}))
    return h
end
function _ft_f18_11(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t18_11(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f18_11(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2), Int64[n, 3])
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Int64[n, 3], n), !applicable(v1, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f18_11, Int64), !applicable(_ft_f18_11, Int64, n), hasmethod(_ft_f18_11, Tuple{Type{Int64}}))
    return h
end
function _ft_f18_16(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(x)
        s2
    end
end
function _ft_t18_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f18_16(Int64)
    local v3 = v1()
    h = 31h + v3
    local v4 = v1(; x = (n + 2))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, n))
    h = 31h + _dw_bits(applicable(_ft_f18_16, Int64), !applicable(_ft_f18_16, Int64, n), hasmethod(_ft_f18_16, Tuple{Type{Int64}}))
    return h
end
function _ft_f18_23(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t18_23(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f18_23(Int64)
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f18_23, Int64), !applicable(_ft_f18_23, Int64, n), hasmethod(_ft_f18_23, Tuple{Type{Int64}}))
    return h
end

# function_type19: F0 = int Function({Function x}); F11 = List<Function> Function(int x, [List<T>]) Function<B extends core.int>( int x, ); F16 = Function({int x}) Function<B extends core.int>(int x); F21 = List<Function> Function<A>() Function<B extends core.int>( int x, ); F23 = void Function<A>(List<A> x) Function<B extends core.int>( int x, )
function _ft_f19_0(; x::Function = _ft_id)
    s1 = Int64(0) + _ft_w(x)
    return s1
end
function _ft_t19_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f19_0()
    h = 31h + v2
    local v3 = _ft_f19_0(; x = _ft_id)
    h = 31h + v3
    h = 31h + _dw_bits(applicable(_ft_f19_0), !applicable(_ft_f19_0, n), hasmethod(_ft_f19_0, Tuple{}))
    return h
end
function _ft_f19_11(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t19_11(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f19_11(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3), Int64[n, 4])
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Int64[n, 4], n), !applicable(v2, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f19_11, Int64, (n + 1)), !applicable(_ft_f19_11, Int64, (n + 1), n), hasmethod(_ft_f19_11, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f19_16(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(x)
        s2
    end
end
function _ft_t19_16(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f19_16(Int64, (n + 1))
    local v4 = v2()
    h = 31h + v4
    local v5 = v2(; x = (n + 3))
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f19_16, Int64, (n + 1)), !applicable(_ft_f19_16, Int64, (n + 1), n), hasmethod(_ft_f19_16, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f19_21(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type)
        s2 = s1
        Function[_ft_id]
    end
end
function _ft_t19_21(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f19_21(Int64, (n + 1))
    local v3 = v2(Int64)
    h = 31h + Int64(length(v3))
    h = 31h + _dw_bits(applicable(v2, Int64), !applicable(v2, Int64, n))
    h = 31h + _dw_bits(applicable(_ft_f19_21, Int64, (n + 1)), !applicable(_ft_f19_21, Int64, (n + 1), n), hasmethod(_ft_f19_21, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f19_23(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t19_23(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f19_23(Int64, (n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f19_23, Int64, (n + 1)), !applicable(_ft_f19_23, Int64, (n + 1), n), hasmethod(_ft_f19_23, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type20: F0 = int Function(int, {Function x}); F2 = core.List<core.int> Function({List<T> x}); F19 = void Function(int, [List<Function>]) Function(); F22 = Function<A>(List<A> x) Function(); F23 = int Function(B x) Function<B extends core.int>()
function _ft_f20_0(p1_1::Int64; x::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return s1
end
function _ft_t20_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f20_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f20_0((n + 1); x = _ft_id)
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f20_0, (n + 1)), !applicable(_ft_f20_0, (n + 1), n), hasmethod(_ft_f20_0, Tuple{Int64}))
    return h
end
function _ft_f20_2(; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(x)
    return Int64[s1]
end
_ft_m20_2(u::_FtU{T}; x::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(x)
function _ft_t20_2(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f20_2()
    h = 31h + sum(v2)
    local v3 = _ft_f20_2(; x = Int64[n, 1])
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(_ft_f20_2), !applicable(_ft_f20_2, n), hasmethod(_ft_f20_2, Tuple{}))
    h = 31h + _ft_m20_2(_FtU{Int64}()) + _ft_m20_2(_FtU{Bool}(); x = Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m20_2, _FtU{Bool}()))
    return h
end
function _ft_f20_19()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t20_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f20_19()
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f20_19), !applicable(_ft_f20_19, n), hasmethod(_ft_f20_19, Tuple{}))
    return h
end
function _ft_f20_22()
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t20_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f20_22()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f20_22), !applicable(_ft_f20_22, n), hasmethod(_ft_f20_22, Tuple{}))
    return h
end
function _ft_f20_23(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t20_23(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f20_23(Int64)
    local v3 = v1((n + 2))
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f20_23, Int64), !applicable(_ft_f20_23, Int64, n), hasmethod(_ft_f20_23, Tuple{Type{Int64}}))
    return h
end

# function_type21: F2 = core.List<core.int> Function(int, {List<T> x}); F4 = core.List<core.int> Function<A>(); F19 = void Function(int, [List<Function>]) Function(int x); F22 = Function<A>(List<A> x) Function(int x); F23 = int Function(B x) Function<B extends core.int>(int x)
function _ft_f21_2(p1_1::Int64; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return Int64[s1]
end
_ft_m21_2(u::_FtU{T}, p1_1::Int64; x::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1) + _ft_w(x)
function _ft_t21_2(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f21_2((n + 1))
    h = 31h + sum(v3)
    local v4 = _ft_f21_2((n + 1); x = Int64[n, 2])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(_ft_f21_2, (n + 1)), !applicable(_ft_f21_2, (n + 1), n), hasmethod(_ft_f21_2, Tuple{Int64}))
    h = 31h + _ft_m21_2(_FtU{Int64}(), (n + 201)) + _ft_m21_2(_FtU{Bool}(), (n + 202); x = Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m21_2, _FtU{Bool}(), (n + 202)))
    return h
end
function _ft_f21_4(::Type{A}) where {A}
    s1 = Int64(0)
    return Int64[s1]
end
function _ft_t21_4(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f21_4(Int64)
    h = 31h + sum(v1)
    h = 31h + _dw_bits(applicable(_ft_f21_4, Int64), !applicable(_ft_f21_4, Int64, n), hasmethod(_ft_f21_4, Tuple{Type{Int64}}))
    return h
end
function _ft_f21_19(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t21_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f21_19((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f21_19, (n + 1)), !applicable(_ft_f21_19, (n + 1), n), hasmethod(_ft_f21_19, Tuple{Int64}))
    return h
end
function _ft_f21_22(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t21_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f21_22((n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f21_22, (n + 1)), !applicable(_ft_f21_22, (n + 1), n), hasmethod(_ft_f21_22, Tuple{Int64}))
    return h
end
function _ft_f21_23(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t21_23(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f21_23(Int64, (n + 1))
    local v4 = v2((n + 3))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f21_23, Int64, (n + 1)), !applicable(_ft_f21_23, Int64, (n + 1), n), hasmethod(_ft_f21_23, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type22: F0 = int Function(List<Function> x); F1 = List<Function> Function(int y, {int x}); F2 = core.List<core.int> Function(int y, {List<T> x}); F19 = void Function(int, [List<Function>]) Function<B extends core.int>(); F22 = Function<A>(List<A> x) Function<B extends core.int>()
function _ft_f22_0(p1_1::Vector{Function})
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t22_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f22_0(Function[_ft_id])
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f22_0, Function[_ft_id]), !applicable(_ft_f22_0, Function[_ft_id], n), hasmethod(_ft_f22_0, Tuple{Vector{Function}}))
    return h
end
function _ft_f22_1(p1_1::Int64; x::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return Function[_ft_id]
end
function _ft_t22_1(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f22_1((n + 1))
    h = 31h + Int64(length(v3))
    local v4 = _ft_f22_1((n + 1); x = (n + 2))
    h = 31h + Int64(length(v4))
    h = 31h + _dw_bits(applicable(_ft_f22_1, (n + 1)), !applicable(_ft_f22_1, (n + 1), n), hasmethod(_ft_f22_1, Tuple{Int64}))
    return h
end
function _ft_f22_2(p1_1::Int64; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return Int64[s1]
end
_ft_m22_2(u::_FtU{T}, p1_1::Int64; x::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1) + _ft_w(x)
function _ft_t22_2(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f22_2((n + 1))
    h = 31h + sum(v3)
    local v4 = _ft_f22_2((n + 1); x = Int64[n, 2])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(_ft_f22_2, (n + 1)), !applicable(_ft_f22_2, (n + 1), n), hasmethod(_ft_f22_2, Tuple{Int64}))
    h = 31h + _ft_m22_2(_FtU{Int64}(), (n + 201)) + _ft_m22_2(_FtU{Bool}(), (n + 202); x = Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m22_2, _FtU{Bool}(), (n + 202)))
    return h
end
function _ft_f22_19(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t22_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f22_19(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f22_19, Int64), !applicable(_ft_f22_19, Int64, n), hasmethod(_ft_f22_19, Tuple{Type{Int64}}))
    return h
end
function _ft_f22_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t22_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f22_22(Int64)
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f22_22, Int64), !applicable(_ft_f22_22, Int64, n), hasmethod(_ft_f22_22, Tuple{Type{Int64}}))
    return h
end

# function_type23: F0 = int Function([List<Function> x]); F2 = core.List<core.int> Function(); F11 = List<Function> Function({List<T> x}) Function<B extends core.int>(int x); F19 = void Function(int, [List<Function>]) Function<B extends core.int>(int x); F22 = Function<A>(List<A> x) Function<B extends core.int>(int x)
function _ft_f23_0(p1_1::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t23_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f23_0()
    h = 31h + v2
    local v3 = _ft_f23_0(Function[_ft_id])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(_ft_f23_0), !applicable(_ft_f23_0, Function[_ft_id], n), hasmethod(_ft_f23_0, Tuple{}))
    return h
end
function _ft_f23_2()
    s1 = Int64(0)
    return Int64[s1]
end
function _ft_t23_2(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f23_2()
    h = 31h + sum(v1)
    h = 31h + _dw_bits(applicable(_ft_f23_2), !applicable(_ft_f23_2, n), hasmethod(_ft_f23_2, Tuple{}))
    return h
end
function _ft_f23_11(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(x)
        Function[_ft_id]
    end
end
function _ft_t23_11(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f23_11(Int64, (n + 1))
    local v4 = v2()
    h = 31h + Int64(length(v4))
    local v5 = v2(; x = Int64[n, 3])
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f23_11, Int64, (n + 1)), !applicable(_ft_f23_11, Int64, (n + 1), n), hasmethod(_ft_f23_11, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f23_19(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t23_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f23_19(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f23_19, Int64, (n + 1)), !applicable(_ft_f23_19, Int64, (n + 1), n), hasmethod(_ft_f23_19, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f23_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t23_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f23_22(Int64, (n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f23_22, Int64, (n + 1)), !applicable(_ft_f23_22, Int64, (n + 1), n), hasmethod(_ft_f23_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type24: F11 = List<Function> Function(int, {List<T> x}) Function(); F17 = Function(int, [core.List<core.int> x]) Function(); F19 = void Function(int x, [List<Function>]) Function(); F21 = List<Function> Function<A>(List<A> x) Function(); F23 = List<Function> Function(B x) Function<B extends core.int>()
function _ft_f24_11()
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Function[_ft_id]
    end
end
function _ft_t24_11(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f24_11()
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2); x = Int64[n, 3])
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f24_11), !applicable(_ft_f24_11, n), hasmethod(_ft_f24_11, Tuple{}))
    return h
end
function _ft_f24_17()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t24_17(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f24_17()
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2), Int64[n, 3])
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f24_17), !applicable(_ft_f24_17, n), hasmethod(_ft_f24_17, Tuple{}))
    return h
end
function _ft_f24_19()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t24_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f24_19()
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f24_19), !applicable(_ft_f24_19, n), hasmethod(_ft_f24_19, Tuple{}))
    return h
end
function _ft_f24_21()
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        Function[_ft_id]
    end
end
function _ft_t24_21(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f24_21()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + Int64(length(v3))
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f24_21), !applicable(_ft_f24_21, n), hasmethod(_ft_f24_21, Tuple{}))
    return h
end
function _ft_f24_23(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64)
        s2 = s1 + _ft_w(p2_1)
        Function[_ft_id]
    end
end
function _ft_t24_23(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f24_23(Int64)
    local v3 = v1((n + 2))
    h = 31h + Int64(length(v3))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f24_23, Int64), !applicable(_ft_f24_23, Int64, n), hasmethod(_ft_f24_23, Tuple{Type{Int64}}))
    return h
end

# function_type25: F3 = Function([List<T> x]); F11 = List<Function> Function(int, {List<T> x}) Function(int x); F19 = void Function(int x, [List<Function>]) Function(int x); F21 = List<Function> Function<A>(List<A> x) Function(int x); F23 = List<Function> Function(B x) Function<B extends core.int>( int x, )
function _ft_f25_3(p1_1::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
_ft_m25_3(u::_FtU{T}, p1_1::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1)
function _ft_t25_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f25_3()
    h = 31h + v2
    local v3 = _ft_f25_3(Int64[n, 1])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(_ft_f25_3), !applicable(_ft_f25_3, Int64[n, 1], n), hasmethod(_ft_f25_3, Tuple{}), !applicable(_ft_f25_3, Bool[true]))
    h = 31h + _ft_m25_3(_FtU{Int64}(), Int64[n, 201]) + _ft_m25_3(_FtU{Bool}(), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m25_3, _FtU{Bool}(), Bool[true]), !applicable(_ft_m25_3, _FtU{Int64}(), Bool[true]))
    return h
end
function _ft_f25_11(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Function[_ft_id]
    end
end
function _ft_t25_11(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f25_11((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3); x = Int64[n, 4])
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f25_11, (n + 1)), !applicable(_ft_f25_11, (n + 1), n), hasmethod(_ft_f25_11, Tuple{Int64}))
    return h
end
function _ft_f25_19(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t25_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f25_19((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f25_19, (n + 1)), !applicable(_ft_f25_19, (n + 1), n), hasmethod(_ft_f25_19, Tuple{Int64}))
    return h
end
function _ft_f25_21(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        Function[_ft_id]
    end
end
function _ft_t25_21(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f25_21((n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + Int64(length(v4))
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f25_21, (n + 1)), !applicable(_ft_f25_21, (n + 1), n), hasmethod(_ft_f25_21, Tuple{Int64}))
    return h
end
function _ft_f25_23(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64)
        s2 = s1 + _ft_w(p2_1)
        Function[_ft_id]
    end
end
function _ft_t25_23(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f25_23(Int64, (n + 1))
    local v4 = v2((n + 3))
    h = 31h + Int64(length(v4))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f25_23, Int64, (n + 1)), !applicable(_ft_f25_23, Int64, (n + 1), n), hasmethod(_ft_f25_23, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type26: F3 = Function(int, [List<T> x]); F11 = List<Function> Function(int, {List<T> x}) Function<B extends core.int>(); F19 = void Function(int x, [List<Function>]) Function<B extends core.int>(); F21 = List<Function> Function<A>(List<A> x) Function<B extends core.int>(); F22 = A Function<A>(int x) Function<B extends core.int>()
function _ft_f26_3(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
_ft_m26_3(u::_FtU{T}, p1_1::Int64, p1_2::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
function _ft_t26_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f26_3((n + 1))
    h = 31h + v3
    local v4 = _ft_f26_3((n + 1), Int64[n, 2])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f26_3, (n + 1)), !applicable(_ft_f26_3, (n + 1), Int64[n, 2], n), hasmethod(_ft_f26_3, Tuple{Int64}), !applicable(_ft_f26_3, (n + 101), Bool[true]))
    h = 31h + _ft_m26_3(_FtU{Int64}(), (n + 201), Int64[n, 202]) + _ft_m26_3(_FtU{Bool}(), (n + 203), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m26_3, _FtU{Bool}(), (n + 203), Bool[true]), !applicable(_ft_m26_3, _FtU{Int64}(), (n + 203), Bool[true]))
    return h
end
function _ft_f26_11(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Function[_ft_id]
    end
end
function _ft_t26_11(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f26_11(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2); x = Int64[n, 3])
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f26_11, Int64), !applicable(_ft_f26_11, Int64, n), hasmethod(_ft_f26_11, Tuple{Type{Int64}}))
    return h
end
function _ft_f26_19(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t26_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f26_19(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f26_19, Int64), !applicable(_ft_f26_19, Int64, n), hasmethod(_ft_f26_19, Tuple{Type{Int64}}))
    return h
end
function _ft_f26_21(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        Function[_ft_id]
    end
end
function _ft_t26_21(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f26_21(Int64)
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + Int64(length(v3))
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f26_21, Int64), !applicable(_ft_f26_21, Int64, n), hasmethod(_ft_f26_21, Tuple{Type{Int64}}))
    return h
end
function _ft_f26_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Int64)
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t26_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f26_22(Int64)
    local v3 = v1(Int64, (n + 2))
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, (n + 2)), !applicable(v1, Int64, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f26_22, Int64), !applicable(_ft_f26_22, Int64, n), hasmethod(_ft_f26_22, Tuple{Type{Int64}}))
    return h
end

# function_type27: F3 = Function(int y, [List<T> x]); F11 = List<Function> Function(int, {List<T> x}) Function<B extends core.int>( int x, ); F19 = void Function(int x, [List<Function>]) Function<B extends core.int>(int x); F21 = List<Function> Function<A>(List<A> x) Function<B extends core.int>(int x); F22 = A Function<A>(int x) Function<B extends core.int>(int x)
function _ft_f27_3(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
_ft_m27_3(u::_FtU{T}, p1_1::Int64, p1_2::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
function _ft_t27_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f27_3((n + 1))
    h = 31h + v3
    local v4 = _ft_f27_3((n + 1), Int64[n, 2])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f27_3, (n + 1)), !applicable(_ft_f27_3, (n + 1), Int64[n, 2], n), hasmethod(_ft_f27_3, Tuple{Int64}), !applicable(_ft_f27_3, (n + 101), Bool[true]))
    h = 31h + _ft_m27_3(_FtU{Int64}(), (n + 201), Int64[n, 202]) + _ft_m27_3(_FtU{Bool}(), (n + 203), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m27_3, _FtU{Bool}(), (n + 203), Bool[true]), !applicable(_ft_m27_3, _FtU{Int64}(), (n + 203), Bool[true]))
    return h
end
function _ft_f27_11(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Function[_ft_id]
    end
end
function _ft_t27_11(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f27_11(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3); x = Int64[n, 4])
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f27_11, Int64, (n + 1)), !applicable(_ft_f27_11, Int64, (n + 1), n), hasmethod(_ft_f27_11, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f27_19(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t27_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f27_19(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f27_19, Int64, (n + 1)), !applicable(_ft_f27_19, Int64, (n + 1), n), hasmethod(_ft_f27_19, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f27_21(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        Function[_ft_id]
    end
end
function _ft_t27_21(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f27_21(Int64, (n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + Int64(length(v4))
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f27_21, Int64, (n + 1)), !applicable(_ft_f27_21, Int64, (n + 1), n), hasmethod(_ft_f27_21, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f27_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Int64)
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t27_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f27_22(Int64, (n + 1))
    local v4 = v2(Int64, (n + 3))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, (n + 3)), !applicable(v2, Int64, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f27_22, Int64, (n + 1)), !applicable(_ft_f27_22, Int64, (n + 1), n), hasmethod(_ft_f27_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type28: F11 = List<Function> Function(int y, {List<T> x}) Function(); F17 = Function(int y, [core.List<core.int> x]) Function(); F18 = void Function([int]) Function(); F22 = A Function<A>(Function x) Function(); F23 = List<T> Function(B x) Function<B extends core.int>()
function _ft_f28_11()
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Function[_ft_id]
    end
end
function _ft_t28_11(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f28_11()
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2); x = Int64[n, 3])
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f28_11), !applicable(_ft_f28_11, n), hasmethod(_ft_f28_11, Tuple{}))
    return h
end
function _ft_f28_17()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t28_17(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f28_17()
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2), Int64[n, 3])
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f28_17), !applicable(_ft_f28_17, n), hasmethod(_ft_f28_17, Tuple{}))
    return h
end
function _ft_f28_18()
    s1 = Int64(0)
    return function (p2_1::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t28_18(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f28_18()
    local v3 = v1()
    h = 31h + Int64(v3 === nothing)
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f28_18), !applicable(_ft_f28_18, n), hasmethod(_ft_f28_18, Tuple{}))
    return h
end
function _ft_f28_22()
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Function)
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t28_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f28_22()
    local v3 = v1(Int64, _ft_id)
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, _ft_id), !applicable(v1, Int64, _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f28_22), !applicable(_ft_f28_22, n), hasmethod(_ft_f28_22, Tuple{}))
    return h
end
function _ft_f28_23(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64)
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t28_23(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f28_23(Int64)
    local v3 = v1((n + 2))
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f28_23, Int64), !applicable(_ft_f28_23, Int64, n), hasmethod(_ft_f28_23, Tuple{Type{Int64}}))
    return h
end

# function_type29: F3 = Function([List<T>]); F11 = List<Function> Function(int y, {List<T> x}) Function(int x); F20 = void Function() Function(int x); F22 = A Function<A>(Function x) Function(int x); F23 = List<T> Function(B x) Function<B extends core.int>(int x)
function _ft_f29_3(p1_1::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
_ft_m29_3(u::_FtU{T}, p1_1::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1)
function _ft_t29_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f29_3()
    h = 31h + v2
    local v3 = _ft_f29_3(Int64[n, 1])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(_ft_f29_3), !applicable(_ft_f29_3, Int64[n, 1], n), hasmethod(_ft_f29_3, Tuple{}), !applicable(_ft_f29_3, Bool[true]))
    h = 31h + _ft_m29_3(_FtU{Int64}(), Int64[n, 201]) + _ft_m29_3(_FtU{Bool}(), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m29_3, _FtU{Bool}(), Bool[true]), !applicable(_ft_m29_3, _FtU{Int64}(), Bool[true]))
    return h
end
function _ft_f29_11(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Function[_ft_id]
    end
end
function _ft_t29_11(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f29_11((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3); x = Int64[n, 4])
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f29_11, (n + 1)), !applicable(_ft_f29_11, (n + 1), n), hasmethod(_ft_f29_11, Tuple{Int64}))
    return h
end
function _ft_f29_20(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function ()
        s2 = s1
        nothing
    end
end
function _ft_t29_20(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f29_20((n + 1))
    local v3 = v2()
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f29_20, (n + 1)), !applicable(_ft_f29_20, (n + 1), n), hasmethod(_ft_f29_20, Tuple{Int64}))
    return h
end
function _ft_f29_22(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Function)
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t29_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f29_22((n + 1))
    local v4 = v2(Int64, _ft_id)
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, _ft_id), !applicable(v2, Int64, _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f29_22, (n + 1)), !applicable(_ft_f29_22, (n + 1), n), hasmethod(_ft_f29_22, Tuple{Int64}))
    return h
end
function _ft_f29_23(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64)
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t29_23(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f29_23(Int64, (n + 1))
    local v4 = v2((n + 3))
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f29_23, Int64, (n + 1)), !applicable(_ft_f29_23, Int64, (n + 1), n), hasmethod(_ft_f29_23, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type30: F3 = Function(int, [List<T>]); F4 = List<T> Function<A>(A x); F11 = List<Function> Function(int y, {List<T> x}) Function<B extends core.int>(); F18 = void Function([int]) Function<B extends core.int>(); F22 = A Function<A>(Function x) Function<B extends core.int>()
function _ft_f30_3(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
_ft_m30_3(u::_FtU{T}, p1_1::Int64, p1_2::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
function _ft_t30_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f30_3((n + 1))
    h = 31h + v3
    local v4 = _ft_f30_3((n + 1), Int64[n, 2])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f30_3, (n + 1)), !applicable(_ft_f30_3, (n + 1), Int64[n, 2], n), hasmethod(_ft_f30_3, Tuple{Int64}), !applicable(_ft_f30_3, (n + 101), Bool[true]))
    h = 31h + _ft_m30_3(_FtU{Int64}(), (n + 201), Int64[n, 202]) + _ft_m30_3(_FtU{Bool}(), (n + 203), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m30_3, _FtU{Bool}(), (n + 203), Bool[true]), !applicable(_ft_m30_3, _FtU{Int64}(), (n + 203), Bool[true]))
    return h
end
function _ft_f30_4(::Type{A}, p1_1::A) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return Int64[s1]
end
function _ft_t30_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f30_4(Int64, (n + 1))
    h = 31h + sum(v2)
    h = 31h + _dw_bits(applicable(_ft_f30_4, Int64, (n + 1)), !applicable(_ft_f30_4, Int64, (n + 1), n), hasmethod(_ft_f30_4, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f30_11(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Function[_ft_id]
    end
end
function _ft_t30_11(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f30_11(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2); x = Int64[n, 3])
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f30_11, Int64), !applicable(_ft_f30_11, Int64, n), hasmethod(_ft_f30_11, Tuple{Type{Int64}}))
    return h
end
function _ft_f30_18(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t30_18(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f30_18(Int64)
    local v3 = v1()
    h = 31h + Int64(v3 === nothing)
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f30_18, Int64), !applicable(_ft_f30_18, Int64, n), hasmethod(_ft_f30_18, Tuple{Type{Int64}}))
    return h
end
function _ft_f30_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Function)
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t30_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f30_22(Int64)
    local v3 = v1(Int64, _ft_id)
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, _ft_id), !applicable(v1, Int64, _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f30_22, Int64), !applicable(_ft_f30_22, Int64, n), hasmethod(_ft_f30_22, Tuple{Type{Int64}}))
    return h
end

# function_type31: F3 = Function(int x, [List<T>]); F4 = List<T> Function<A>(List<A> x); F11 = List<Function> Function(int y, {List<T> x}) Function<B extends core.int>( int x, ); F20 = void Function() Function<B extends core.int>(int x); F22 = A Function<A>(Function x) Function<B extends core.int>(int x)
function _ft_f31_3(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
_ft_m31_3(u::_FtU{T}, p1_1::Int64, p1_2::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
function _ft_t31_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f31_3((n + 1))
    h = 31h + v3
    local v4 = _ft_f31_3((n + 1), Int64[n, 2])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f31_3, (n + 1)), !applicable(_ft_f31_3, (n + 1), Int64[n, 2], n), hasmethod(_ft_f31_3, Tuple{Int64}), !applicable(_ft_f31_3, (n + 101), Bool[true]))
    h = 31h + _ft_m31_3(_FtU{Int64}(), (n + 201), Int64[n, 202]) + _ft_m31_3(_FtU{Bool}(), (n + 203), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m31_3, _FtU{Bool}(), (n + 203), Bool[true]), !applicable(_ft_m31_3, _FtU{Int64}(), (n + 203), Bool[true]))
    return h
end
function _ft_f31_4(::Type{A}, p1_1::Vector{A}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return Int64[s1]
end
function _ft_t31_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f31_4(Int64, Int64[n, 1])
    h = 31h + sum(v2)
    h = 31h + _dw_bits(applicable(_ft_f31_4, Int64, Int64[n, 1]), !applicable(_ft_f31_4, Int64, Int64[n, 1], n), hasmethod(_ft_f31_4, Tuple{Type{Int64}, Vector{Int64}}))
    return h
end
function _ft_f31_11(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Function[_ft_id]
    end
end
function _ft_t31_11(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f31_11(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3); x = Int64[n, 4])
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f31_11, Int64, (n + 1)), !applicable(_ft_f31_11, Int64, (n + 1), n), hasmethod(_ft_f31_11, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f31_20(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function ()
        s2 = s1
        nothing
    end
end
function _ft_t31_20(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f31_20(Int64, (n + 1))
    local v3 = v2()
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f31_20, Int64, (n + 1)), !applicable(_ft_f31_20, Int64, (n + 1), n), hasmethod(_ft_f31_20, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f31_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Function)
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t31_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f31_22(Int64, (n + 1))
    local v4 = v2(Int64, _ft_id)
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, _ft_id), !applicable(v2, Int64, _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f31_22, Int64, (n + 1)), !applicable(_ft_f31_22, Int64, (n + 1), n), hasmethod(_ft_f31_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type32: F4 = Function<A>(int x); F13 = core.List<core.int> Function([List<T>]) Function(); F19 = void Function(int, {List<Function> x}) Function(); F22 = A Function<A>(List<Function> x) Function(); F23 = B Function(B x) Function<B extends core.int>()
function _ft_f32_4(::Type{A}, p1_1::Int64) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t32_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f32_4(Int64, (n + 1))
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f32_4, Int64, (n + 1)), !applicable(_ft_f32_4, Int64, (n + 1), n), hasmethod(_ft_f32_4, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f32_13()
    s1 = Int64(0)
    return function (p2_1::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t32_13(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f32_13()
    local v3 = v1()
    h = 31h + sum(v3)
    local v4 = v1(Int64[n, 2])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, Int64[n, 2], n), !applicable(v1, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f32_13), !applicable(_ft_f32_13, n), hasmethod(_ft_f32_13, Tuple{}))
    return h
end
function _ft_f32_19()
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        nothing
    end
end
function _ft_t32_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f32_19()
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2); x = Function[_ft_id])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f32_19), !applicable(_ft_f32_19, n), hasmethod(_ft_f32_19, Tuple{}))
    return h
end
function _ft_f32_22()
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t32_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f32_22()
    local v3 = v1(Int64, Function[_ft_id])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, Function[_ft_id]), !applicable(v1, Int64, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f32_22), !applicable(_ft_f32_22, n), hasmethod(_ft_f32_22, Tuple{}))
    return h
end
function _ft_f32_23(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t32_23(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f32_23(Int64)
    local v3 = v1((n + 2))
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f32_23, Int64), !applicable(_ft_f32_23, Int64, n), hasmethod(_ft_f32_23, Tuple{Type{Int64}}))
    return h
end

# function_type33: F4 = Function<A>(Function x); F11 = List<Function> Function() Function(int x); F13 = core.List<core.int> Function([List<T>]) Function(int x); F19 = void Function(int, {List<Function> x}) Function(int x); F23 = B Function(B x) Function<B extends core.int>(int x)
function _ft_f33_4(::Type{A}, p1_1::Function) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t33_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f33_4(Int64, _ft_id)
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f33_4, Int64, _ft_id), !applicable(_ft_f33_4, Int64, _ft_id, n), hasmethod(_ft_f33_4, Tuple{Type{Int64}, typeof(_ft_id)}))
    return h
end
function _ft_f33_11(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function ()
        s2 = s1
        Function[_ft_id]
    end
end
function _ft_t33_11(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f33_11((n + 1))
    local v3 = v2()
    h = 31h + Int64(length(v3))
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f33_11, (n + 1)), !applicable(_ft_f33_11, (n + 1), n), hasmethod(_ft_f33_11, Tuple{Int64}))
    return h
end
function _ft_f33_13(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t33_13(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f33_13((n + 1))
    local v4 = v2()
    h = 31h + sum(v4)
    local v5 = v2(Int64[n, 3])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, Int64[n, 3], n), !applicable(v2, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f33_13, (n + 1)), !applicable(_ft_f33_13, (n + 1), n), hasmethod(_ft_f33_13, Tuple{Int64}))
    return h
end
function _ft_f33_19(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        nothing
    end
end
function _ft_t33_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f33_19((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3); x = Function[_ft_id])
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f33_19, (n + 1)), !applicable(_ft_f33_19, (n + 1), n), hasmethod(_ft_f33_19, Tuple{Int64}))
    return h
end
function _ft_f33_23(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t33_23(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f33_23(Int64, (n + 1))
    local v4 = v2((n + 3))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f33_23, Int64, (n + 1)), !applicable(_ft_f33_23, Int64, (n + 1), n), hasmethod(_ft_f33_23, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type34: F0 = int Function([core.List<core.int> x]); F1 = List<Function> Function(List<Function> x); F3 = Function(int y, {List<T> x}); F19 = void Function(int, {List<Function> x}) Function<B extends core.int>(); F22 = A Function<A>(List<Function> x) Function<B extends core.int>()
function _ft_f34_0(p1_1::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t34_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f34_0()
    h = 31h + v2
    local v3 = _ft_f34_0(Int64[n, 1])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(_ft_f34_0), !applicable(_ft_f34_0, Int64[n, 1], n), hasmethod(_ft_f34_0, Tuple{}))
    return h
end
function _ft_f34_1(p1_1::Vector{Function})
    s1 = Int64(0) + _ft_w(p1_1)
    return Function[_ft_id]
end
function _ft_t34_1(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f34_1(Function[_ft_id])
    h = 31h + Int64(length(v2))
    h = 31h + _dw_bits(applicable(_ft_f34_1, Function[_ft_id]), !applicable(_ft_f34_1, Function[_ft_id], n), hasmethod(_ft_f34_1, Tuple{Vector{Function}}))
    return h
end
function _ft_f34_3(p1_1::Int64; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return s1
end
_ft_m34_3(u::_FtU{T}, p1_1::Int64; x::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1) + _ft_w(x)
function _ft_t34_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f34_3((n + 1))
    h = 31h + v3
    local v4 = _ft_f34_3((n + 1); x = Int64[n, 2])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f34_3, (n + 1)), !applicable(_ft_f34_3, (n + 1), n), hasmethod(_ft_f34_3, Tuple{Int64}))
    h = 31h + _ft_m34_3(_FtU{Int64}(), (n + 201)) + _ft_m34_3(_FtU{Bool}(), (n + 202); x = Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m34_3, _FtU{Bool}(), (n + 202)))
    return h
end
function _ft_f34_19(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        nothing
    end
end
function _ft_t34_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f34_19(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2); x = Function[_ft_id])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f34_19, Int64), !applicable(_ft_f34_19, Int64, n), hasmethod(_ft_f34_19, Tuple{Type{Int64}}))
    return h
end
function _ft_f34_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t34_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f34_22(Int64)
    local v3 = v1(Int64, Function[_ft_id])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, Function[_ft_id]), !applicable(v1, Int64, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f34_22, Int64), !applicable(_ft_f34_22, Int64, n), hasmethod(_ft_f34_22, Tuple{Type{Int64}}))
    return h
end

# function_type35: F3 = Function(); F4 = Function<A>(core.List<core.int> x); F13 = core.List<core.int> Function([List<T>]) Function<B extends core.int>(int x); F19 = void Function(int, {List<Function> x}) Function<B extends core.int>(int x); F22 = A Function<A>(List<Function> x) Function<B extends core.int>( int x, )
function _ft_f35_3()
    s1 = Int64(0)
    return s1
end
function _ft_t35_3(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f35_3()
    h = 31h + v1
    h = 31h + _dw_bits(applicable(_ft_f35_3), !applicable(_ft_f35_3, n), hasmethod(_ft_f35_3, Tuple{}))
    return h
end
function _ft_f35_4(::Type{A}, p1_1::Vector{Int64}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t35_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f35_4(Int64, Int64[n, 1])
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f35_4, Int64, Int64[n, 1]), !applicable(_ft_f35_4, Int64, Int64[n, 1], n), hasmethod(_ft_f35_4, Tuple{Type{Int64}, Vector{Int64}}))
    return h
end
function _ft_f35_13(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t35_13(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f35_13(Int64, (n + 1))
    local v4 = v2()
    h = 31h + sum(v4)
    local v5 = v2(Int64[n, 3])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, Int64[n, 3], n), !applicable(v2, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f35_13, Int64, (n + 1)), !applicable(_ft_f35_13, Int64, (n + 1), n), hasmethod(_ft_f35_13, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f35_19(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        nothing
    end
end
function _ft_t35_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f35_19(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3); x = Function[_ft_id])
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f35_19, Int64, (n + 1)), !applicable(_ft_f35_19, Int64, (n + 1), n), hasmethod(_ft_f35_19, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f35_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t35_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f35_22(Int64, (n + 1))
    local v4 = v2(Int64, Function[_ft_id])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, Function[_ft_id]), !applicable(v2, Int64, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f35_22, Int64, (n + 1)), !applicable(_ft_f35_22, Int64, (n + 1), n), hasmethod(_ft_f35_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type36: F0 = int Function(int y, [core.List<core.int> x]); F4 = Function<A>(List<T> x); F19 = void Function(int y, {List<Function> x}) Function(); F22 = A Function<A>(core.List<core.int> x) Function(); F23 = void Function(B x) Function<B extends core.int>()
function _ft_f36_0(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
function _ft_t36_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f36_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f36_0((n + 1), Int64[n, 2])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f36_0, (n + 1)), !applicable(_ft_f36_0, (n + 1), Int64[n, 2], n), hasmethod(_ft_f36_0, Tuple{Int64}))
    return h
end
function _ft_f36_4(::Type{A}, p1_1::Vector{Int64}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
_ft_m36_4(u::_FtU{T}, ::Type{A}, p1_1::Vector{T}) where {T, A} = Int64(0) + _ft_w(p1_1)
function _ft_t36_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f36_4(Int64, Int64[n, 1])
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f36_4, Int64, Int64[n, 1]), !applicable(_ft_f36_4, Int64, Int64[n, 1], n), hasmethod(_ft_f36_4, Tuple{Type{Int64}, Vector{Int64}}), !applicable(_ft_f36_4, Int64, Bool[true]))
    h = 31h + _ft_m36_4(_FtU{Int64}(), Int64, Int64[n, 201]) + _ft_m36_4(_FtU{Bool}(), Int64, Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m36_4, _FtU{Bool}(), Int64, Bool[true]), !applicable(_ft_m36_4, _FtU{Int64}(), Int64, Bool[true]))
    return h
end
function _ft_f36_19()
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        nothing
    end
end
function _ft_t36_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f36_19()
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2); x = Function[_ft_id])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f36_19), !applicable(_ft_f36_19, n), hasmethod(_ft_f36_19, Tuple{}))
    return h
end
function _ft_f36_22()
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t36_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f36_22()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f36_22), !applicable(_ft_f36_22, n), hasmethod(_ft_f36_22, Tuple{}))
    return h
end
function _ft_f36_23(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64)
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t36_23(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f36_23(Int64)
    local v3 = v1((n + 2))
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f36_23, Int64), !applicable(_ft_f36_23, Int64, n), hasmethod(_ft_f36_23, Tuple{Type{Int64}}))
    return h
end

# function_type37: F2 = List<T> Function(int, [Function x]); F4 = Function<A>(); F19 = void Function(int y, {List<Function> x}) Function(int x); F22 = A Function<A>(core.List<core.int> x) Function(int x); F23 = void Function(B x) Function<B extends core.int>(int x)
function _ft_f37_2(p1_1::Int64, p1_2::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return Int64[s1]
end
function _ft_t37_2(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f37_2((n + 1))
    h = 31h + sum(v3)
    local v4 = _ft_f37_2((n + 1), _ft_id)
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(_ft_f37_2, (n + 1)), !applicable(_ft_f37_2, (n + 1), _ft_id, n), hasmethod(_ft_f37_2, Tuple{Int64}))
    return h
end
function _ft_f37_4(::Type{A}) where {A}
    s1 = Int64(0)
    return s1
end
function _ft_t37_4(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f37_4(Int64)
    h = 31h + v1
    h = 31h + _dw_bits(applicable(_ft_f37_4, Int64), !applicable(_ft_f37_4, Int64, n), hasmethod(_ft_f37_4, Tuple{Type{Int64}}))
    return h
end
function _ft_f37_19(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        nothing
    end
end
function _ft_t37_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f37_19((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3); x = Function[_ft_id])
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f37_19, (n + 1)), !applicable(_ft_f37_19, (n + 1), n), hasmethod(_ft_f37_19, Tuple{Int64}))
    return h
end
function _ft_f37_22(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t37_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f37_22((n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f37_22, (n + 1)), !applicable(_ft_f37_22, (n + 1), n), hasmethod(_ft_f37_22, Tuple{Int64}))
    return h
end
function _ft_f37_23(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64)
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t37_23(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f37_23(Int64, (n + 1))
    local v4 = v2((n + 3))
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f37_23, Int64, (n + 1)), !applicable(_ft_f37_23, Int64, (n + 1), n), hasmethod(_ft_f37_23, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type38: F0 = int Function([core.List<core.int>]); F2 = List<T> Function(int y, [Function x]); F4 = Function<A>(A x); F19 = void Function(int y, {List<Function> x}) Function<B extends core.int>(); F22 = A Function<A>(core.List<core.int> x) Function<B extends core.int>()
function _ft_f38_0(p1_1::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t38_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f38_0()
    h = 31h + v2
    local v3 = _ft_f38_0(Int64[n, 1])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(_ft_f38_0), !applicable(_ft_f38_0, Int64[n, 1], n), hasmethod(_ft_f38_0, Tuple{}))
    return h
end
function _ft_f38_2(p1_1::Int64, p1_2::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return Int64[s1]
end
function _ft_t38_2(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f38_2((n + 1))
    h = 31h + sum(v3)
    local v4 = _ft_f38_2((n + 1), _ft_id)
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(_ft_f38_2, (n + 1)), !applicable(_ft_f38_2, (n + 1), _ft_id, n), hasmethod(_ft_f38_2, Tuple{Int64}))
    return h
end
function _ft_f38_4(::Type{A}, p1_1::A) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t38_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f38_4(Int64, (n + 1))
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f38_4, Int64, (n + 1)), !applicable(_ft_f38_4, Int64, (n + 1), n), hasmethod(_ft_f38_4, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f38_19(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        nothing
    end
end
function _ft_t38_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f38_19(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2); x = Function[_ft_id])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f38_19, Int64), !applicable(_ft_f38_19, Int64, n), hasmethod(_ft_f38_19, Tuple{Type{Int64}}))
    return h
end
function _ft_f38_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t38_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f38_22(Int64)
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f38_22, Int64), !applicable(_ft_f38_22, Int64, n), hasmethod(_ft_f38_22, Tuple{Type{Int64}}))
    return h
end

# function_type39: F0 = int Function(int, [core.List<core.int>]); F4 = Function<A>(List<A> x); F13 = core.List<core.int> Function(int, [List<T>]) Function<B extends core.int>( int x, ); F19 = void Function(int y, {List<Function> x}) Function<B extends core.int>( int x, ); F22 = A Function<A>(core.List<core.int> x) Function<B extends core.int>(int x)
function _ft_f39_0(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
function _ft_t39_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f39_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f39_0((n + 1), Int64[n, 2])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f39_0, (n + 1)), !applicable(_ft_f39_0, (n + 1), Int64[n, 2], n), hasmethod(_ft_f39_0, Tuple{Int64}))
    return h
end
function _ft_f39_4(::Type{A}, p1_1::Vector{A}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t39_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f39_4(Int64, Int64[n, 1])
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f39_4, Int64, Int64[n, 1]), !applicable(_ft_f39_4, Int64, Int64[n, 1], n), hasmethod(_ft_f39_4, Tuple{Type{Int64}, Vector{Int64}}))
    return h
end
function _ft_f39_13(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t39_13(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f39_13(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3), Int64[n, 4])
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Int64[n, 4], n), !applicable(v2, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f39_13, Int64, (n + 1)), !applicable(_ft_f39_13, Int64, (n + 1), n), hasmethod(_ft_f39_13, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f39_19(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        nothing
    end
end
function _ft_t39_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f39_19(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3); x = Function[_ft_id])
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f39_19, Int64, (n + 1)), !applicable(_ft_f39_19, Int64, (n + 1), n), hasmethod(_ft_f39_19, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f39_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t39_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f39_22(Int64, (n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f39_22, Int64, (n + 1)), !applicable(_ft_f39_22, Int64, (n + 1), n), hasmethod(_ft_f39_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type40: F9 = List<Function> Function(int x, [int]) Function(); F16 = Function(int y, [Function x]) Function(); F18 = void Function({int x}) Function(); F22 = A Function<A>(List<T> x) Function(); F23 = B Function(Function x) Function<B extends core.int>()
function _ft_f40_9()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t40_9(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f40_9()
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2), (n + 3))
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f40_9), !applicable(_ft_f40_9, n), hasmethod(_ft_f40_9, Tuple{}))
    return h
end
function _ft_f40_16()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t40_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f40_16()
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2), _ft_id)
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f40_16), !applicable(_ft_f40_16, n), hasmethod(_ft_f40_16, Tuple{}))
    return h
end
function _ft_f40_18()
    s1 = Int64(0)
    return function (; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(x)
        nothing
    end
end
function _ft_t40_18(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f40_18()
    local v3 = v1()
    h = 31h + Int64(v3 === nothing)
    local v4 = v1(; x = (n + 2))
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, n))
    h = 31h + _dw_bits(applicable(_ft_f40_18), !applicable(_ft_f40_18, n), hasmethod(_ft_f40_18, Tuple{}))
    return h
end
function _ft_f40_22()
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t40_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f40_22()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n), !applicable(v1, Int64, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f40_22), !applicable(_ft_f40_22, n), hasmethod(_ft_f40_22, Tuple{}))
    return h
end
function _ft_f40_23(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Function)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t40_23(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f40_23(Int64)
    local v3 = v1(_ft_id)
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, _ft_id), !applicable(v1, _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f40_23, Int64), !applicable(_ft_f40_23, Int64, n), hasmethod(_ft_f40_23, Tuple{Type{Int64}}))
    return h
end

# function_type41: F9 = List<Function> Function(int x, [int]) Function(int x); F16 = Function(int y, [Function x]) Function(int x); F18 = void Function({int x}) Function(int x); F22 = A Function<A>(List<T> x) Function(int x); F23 = B Function(Function x) Function<B extends core.int>(int x)
function _ft_f41_9(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t41_9(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f41_9((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3), (n + 4))
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), (n + 4), n))
    h = 31h + _dw_bits(applicable(_ft_f41_9, (n + 1)), !applicable(_ft_f41_9, (n + 1), n), hasmethod(_ft_f41_9, Tuple{Int64}))
    return h
end
function _ft_f41_16(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t41_16(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f41_16((n + 1))
    local v5 = v2((n + 3))
    h = 31h + v5
    local v6 = v2((n + 3), _ft_id)
    h = 31h + v6
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f41_16, (n + 1)), !applicable(_ft_f41_16, (n + 1), n), hasmethod(_ft_f41_16, Tuple{Int64}))
    return h
end
function _ft_f41_18(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(x)
        nothing
    end
end
function _ft_t41_18(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f41_18((n + 1))
    local v4 = v2()
    h = 31h + Int64(v4 === nothing)
    local v5 = v2(; x = (n + 3))
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f41_18, (n + 1)), !applicable(_ft_f41_18, (n + 1), n), hasmethod(_ft_f41_18, Tuple{Int64}))
    return h
end
function _ft_f41_22(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t41_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f41_22((n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n), !applicable(v2, Int64, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f41_22, (n + 1)), !applicable(_ft_f41_22, (n + 1), n), hasmethod(_ft_f41_22, Tuple{Int64}))
    return h
end
function _ft_f41_23(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Function)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t41_23(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f41_23(Int64, (n + 1))
    local v4 = v2(_ft_id)
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, _ft_id), !applicable(v2, _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f41_23, Int64, (n + 1)), !applicable(_ft_f41_23, Int64, (n + 1), n), hasmethod(_ft_f41_23, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type42: F0 = int Function(int, {core.List<core.int> x}); F9 = List<Function> Function(int x, [int]) Function<B extends core.int>(); F16 = Function(int y, [Function x]) Function<B extends core.int>(); F18 = void Function({int x}) Function<B extends core.int>(); F22 = A Function<A>(List<T> x) Function<B extends core.int>()
function _ft_f42_0(p1_1::Int64; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return s1
end
function _ft_t42_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f42_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f42_0((n + 1); x = Int64[n, 2])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f42_0, (n + 1)), !applicable(_ft_f42_0, (n + 1), n), hasmethod(_ft_f42_0, Tuple{Int64}))
    return h
end
function _ft_f42_9(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t42_9(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f42_9(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2), (n + 3))
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f42_9, Int64), !applicable(_ft_f42_9, Int64, n), hasmethod(_ft_f42_9, Tuple{Type{Int64}}))
    return h
end
function _ft_f42_16(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t42_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f42_16(Int64)
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2), _ft_id)
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f42_16, Int64), !applicable(_ft_f42_16, Int64, n), hasmethod(_ft_f42_16, Tuple{Type{Int64}}))
    return h
end
function _ft_f42_18(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(x)
        nothing
    end
end
function _ft_t42_18(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f42_18(Int64)
    local v3 = v1()
    h = 31h + Int64(v3 === nothing)
    local v4 = v1(; x = (n + 2))
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, n))
    h = 31h + _dw_bits(applicable(_ft_f42_18, Int64), !applicable(_ft_f42_18, Int64, n), hasmethod(_ft_f42_18, Tuple{Type{Int64}}))
    return h
end
function _ft_f42_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t42_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f42_22(Int64)
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n), !applicable(v1, Int64, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f42_22, Int64), !applicable(_ft_f42_22, Int64, n), hasmethod(_ft_f42_22, Tuple{Type{Int64}}))
    return h
end

# function_type43: F0 = int Function(int y, {core.List<core.int> x}); F9 = List<Function> Function(int x, [int]) Function<B extends core.int>(int x); F16 = Function(int y, [Function x]) Function<B extends core.int>( int x, ); F18 = void Function({int x}) Function<B extends core.int>(int x); F22 = A Function<A>(List<T> x) Function<B extends core.int>(int x)
function _ft_f43_0(p1_1::Int64; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return s1
end
function _ft_t43_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f43_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f43_0((n + 1); x = Int64[n, 2])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f43_0, (n + 1)), !applicable(_ft_f43_0, (n + 1), n), hasmethod(_ft_f43_0, Tuple{Int64}))
    return h
end
function _ft_f43_9(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t43_9(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f43_9(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3), (n + 4))
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), (n + 4), n))
    h = 31h + _dw_bits(applicable(_ft_f43_9, Int64, (n + 1)), !applicable(_ft_f43_9, Int64, (n + 1), n), hasmethod(_ft_f43_9, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f43_16(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t43_16(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f43_16(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + v5
    local v6 = v2((n + 3), _ft_id)
    h = 31h + v6
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f43_16, Int64, (n + 1)), !applicable(_ft_f43_16, Int64, (n + 1), n), hasmethod(_ft_f43_16, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f43_18(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(x)
        nothing
    end
end
function _ft_t43_18(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f43_18(Int64, (n + 1))
    local v4 = v2()
    h = 31h + Int64(v4 === nothing)
    local v5 = v2(; x = (n + 3))
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f43_18, Int64, (n + 1)), !applicable(_ft_f43_18, Int64, (n + 1), n), hasmethod(_ft_f43_18, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f43_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t43_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f43_22(Int64, (n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n), !applicable(v2, Int64, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f43_22, Int64, (n + 1)), !applicable(_ft_f43_22, Int64, (n + 1), n), hasmethod(_ft_f43_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type44: F3 = void Function({int x}); F4 = A Function<A>(List<T> x); F12 = core.List<core.int> Function([List<Function>]) Function(); F14 = List<T> Function(int y, {Function x}) Function(); F23 = B Function(core.List<core.int> x) Function<B extends core.int>()
function _ft_f44_3(; x::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(x)
    return nothing
end
function _ft_t44_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f44_3()
    h = 31h + Int64(v2 === nothing)
    local v3 = _ft_f44_3(; x = (n + 1))
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f44_3), !applicable(_ft_f44_3, n), hasmethod(_ft_f44_3, Tuple{}))
    return h
end
function _ft_f44_4(::Type{A}, p1_1::Vector{Int64}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return A(s1)
end
_ft_m44_4(u::_FtU{T}, ::Type{A}, p1_1::Vector{T}) where {T, A} = Int64(0) + _ft_w(p1_1)
function _ft_t44_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f44_4(Int64, Int64[n, 1])
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f44_4, Int64, Int64[n, 1]), !applicable(_ft_f44_4, Int64, Int64[n, 1], n), hasmethod(_ft_f44_4, Tuple{Type{Int64}, Vector{Int64}}), !applicable(_ft_f44_4, Int64, Bool[true]))
    h = 31h + _ft_m44_4(_FtU{Int64}(), Int64, Int64[n, 201]) + _ft_m44_4(_FtU{Bool}(), Int64, Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m44_4, _FtU{Bool}(), Int64, Bool[true]), !applicable(_ft_m44_4, _FtU{Int64}(), Int64, Bool[true]))
    return h
end
function _ft_f44_12()
    s1 = Int64(0)
    return function (p2_1::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t44_12(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f44_12()
    local v3 = v1()
    h = 31h + sum(v3)
    local v4 = v1(Function[_ft_id])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f44_12), !applicable(_ft_f44_12, n), hasmethod(_ft_f44_12, Tuple{}))
    return h
end
function _ft_f44_14()
    s1 = Int64(0)
    return function (p2_1::Int64; x::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Int64[s2]
    end
end
function _ft_t44_14(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f44_14()
    local v4 = v1((n + 2))
    h = 31h + sum(v4)
    local v5 = v1((n + 2); x = _ft_id)
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f44_14), !applicable(_ft_f44_14, n), hasmethod(_ft_f44_14, Tuple{}))
    return h
end
function _ft_f44_23(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t44_23(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f44_23(Int64)
    local v3 = v1(Int64[n, 2])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64[n, 2]), !applicable(v1, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f44_23, Int64), !applicable(_ft_f44_23, Int64, n), hasmethod(_ft_f44_23, Tuple{Type{Int64}}))
    return h
end

# function_type45: F3 = void Function(int, {int x}); F4 = A Function<A>(); F12 = core.List<core.int> Function([List<Function>]) Function(int x); F14 = List<T> Function(int y, {Function x}) Function(int x); F23 = B Function(core.List<core.int> x) Function<B extends core.int>( int x, )
function _ft_f45_3(p1_1::Int64; x::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return nothing
end
function _ft_t45_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f45_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f45_3((n + 1); x = (n + 2))
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f45_3, (n + 1)), !applicable(_ft_f45_3, (n + 1), n), hasmethod(_ft_f45_3, Tuple{Int64}))
    return h
end
function _ft_f45_4(::Type{A}) where {A}
    s1 = Int64(0)
    return A(s1)
end
function _ft_t45_4(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f45_4(Int64)
    h = 31h + v1
    h = 31h + _dw_bits(applicable(_ft_f45_4, Int64), !applicable(_ft_f45_4, Int64, n), hasmethod(_ft_f45_4, Tuple{Type{Int64}}))
    return h
end
function _ft_f45_12(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t45_12(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f45_12((n + 1))
    local v4 = v2()
    h = 31h + sum(v4)
    local v5 = v2(Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f45_12, (n + 1)), !applicable(_ft_f45_12, (n + 1), n), hasmethod(_ft_f45_12, Tuple{Int64}))
    return h
end
function _ft_f45_14(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Int64[s2]
    end
end
function _ft_t45_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f45_14((n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3); x = _ft_id)
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f45_14, (n + 1)), !applicable(_ft_f45_14, (n + 1), n), hasmethod(_ft_f45_14, Tuple{Int64}))
    return h
end
function _ft_f45_23(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t45_23(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f45_23(Int64, (n + 1))
    local v4 = v2(Int64[n, 3])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64[n, 3]), !applicable(v2, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f45_23, Int64, (n + 1)), !applicable(_ft_f45_23, Int64, (n + 1), n), hasmethod(_ft_f45_23, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type46: F1 = List<Function> Function([core.List<core.int> x]); F3 = void Function(int y, {int x}); F4 = A Function<A>(A x); F14 = List<T> Function(int y, {Function x}) Function<B extends core.int>(); F16 = Function(Function) Function<B extends core.int>()
function _ft_f46_1(p1_1::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1)
    return Function[_ft_id]
end
function _ft_t46_1(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f46_1()
    h = 31h + Int64(length(v2))
    local v3 = _ft_f46_1(Int64[n, 1])
    h = 31h + Int64(length(v3))
    h = 31h + _dw_bits(applicable(_ft_f46_1), !applicable(_ft_f46_1, Int64[n, 1], n), hasmethod(_ft_f46_1, Tuple{}))
    return h
end
function _ft_f46_3(p1_1::Int64; x::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return nothing
end
function _ft_t46_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f46_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f46_3((n + 1); x = (n + 2))
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f46_3, (n + 1)), !applicable(_ft_f46_3, (n + 1), n), hasmethod(_ft_f46_3, Tuple{Int64}))
    return h
end
function _ft_f46_4(::Type{A}, p1_1::A) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return A(s1)
end
function _ft_t46_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f46_4(Int64, (n + 1))
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f46_4, Int64, (n + 1)), !applicable(_ft_f46_4, Int64, (n + 1), n), hasmethod(_ft_f46_4, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f46_14(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Int64[s2]
    end
end
function _ft_t46_14(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f46_14(Int64)
    local v4 = v1((n + 2))
    h = 31h + sum(v4)
    local v5 = v1((n + 2); x = _ft_id)
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f46_14, Int64), !applicable(_ft_f46_14, Int64, n), hasmethod(_ft_f46_14, Tuple{Type{Int64}}))
    return h
end
function _ft_f46_16(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Function)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t46_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f46_16(Int64)
    local v3 = v1(_ft_id)
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, _ft_id), !applicable(v1, _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f46_16, Int64), !applicable(_ft_f46_16, Int64, n), hasmethod(_ft_f46_16, Tuple{Type{Int64}}))
    return h
end

# function_type47: F1 = List<Function> Function(int, [core.List<core.int> x]); F3 = void Function(Function x); F4 = A Function<A>(List<A> x); F14 = List<T> Function(int y, {Function x}) Function<B extends core.int>(int x); F16 = Function(Function) Function<B extends core.int>(int x)
function _ft_f47_1(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return Function[_ft_id]
end
function _ft_t47_1(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f47_1((n + 1))
    h = 31h + Int64(length(v3))
    local v4 = _ft_f47_1((n + 1), Int64[n, 2])
    h = 31h + Int64(length(v4))
    h = 31h + _dw_bits(applicable(_ft_f47_1, (n + 1)), !applicable(_ft_f47_1, (n + 1), Int64[n, 2], n), hasmethod(_ft_f47_1, Tuple{Int64}))
    return h
end
function _ft_f47_3(p1_1::Function)
    s1 = Int64(0) + _ft_w(p1_1)
    return nothing
end
function _ft_t47_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f47_3(_ft_id)
    h = 31h + Int64(v2 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f47_3, _ft_id), !applicable(_ft_f47_3, _ft_id, n), hasmethod(_ft_f47_3, Tuple{typeof(_ft_id)}))
    return h
end
function _ft_f47_4(::Type{A}, p1_1::Vector{A}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return A(s1)
end
function _ft_t47_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f47_4(Int64, Int64[n, 1])
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f47_4, Int64, Int64[n, 1]), !applicable(_ft_f47_4, Int64, Int64[n, 1], n), hasmethod(_ft_f47_4, Tuple{Type{Int64}, Vector{Int64}}))
    return h
end
function _ft_f47_14(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Int64[s2]
    end
end
function _ft_t47_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f47_14(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3); x = _ft_id)
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f47_14, Int64, (n + 1)), !applicable(_ft_f47_14, Int64, (n + 1), n), hasmethod(_ft_f47_14, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f47_16(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Function)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t47_16(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f47_16(Int64, (n + 1))
    local v4 = v2(_ft_id)
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, _ft_id), !applicable(v2, _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f47_16, Int64, (n + 1)), !applicable(_ft_f47_16, Int64, (n + 1), n), hasmethod(_ft_f47_16, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type48: F2 = List<T> Function(int, [List<Function> x]); F3 = void Function([Function x]); F4 = List<A> Function<A>(int x); F9 = List<Function> Function(int, {int x}) Function(); F22 = A Function<A>(A x) Function()
function _ft_f48_2(p1_1::Int64, p1_2::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return Int64[s1]
end
function _ft_t48_2(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f48_2((n + 1))
    h = 31h + sum(v3)
    local v4 = _ft_f48_2((n + 1), Function[_ft_id])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(_ft_f48_2, (n + 1)), !applicable(_ft_f48_2, (n + 1), Function[_ft_id], n), hasmethod(_ft_f48_2, Tuple{Int64}))
    return h
end
function _ft_f48_3(p1_1::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1)
    return nothing
end
function _ft_t48_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f48_3()
    h = 31h + Int64(v2 === nothing)
    local v3 = _ft_f48_3(_ft_id)
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f48_3), !applicable(_ft_f48_3, _ft_id, n), hasmethod(_ft_f48_3, Tuple{}))
    return h
end
function _ft_f48_4(::Type{A}, p1_1::Int64) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return A[A(s1)]
end
function _ft_t48_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f48_4(Int64, (n + 1))
    h = 31h + sum(v2)
    h = 31h + _dw_bits(applicable(_ft_f48_4, Int64, (n + 1)), !applicable(_ft_f48_4, Int64, (n + 1), n), hasmethod(_ft_f48_4, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f48_9()
    s1 = Int64(0)
    return function (p2_1::Int64; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Function[_ft_id]
    end
end
function _ft_t48_9(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f48_9()
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2); x = (n + 3))
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f48_9), !applicable(_ft_f48_9, n), hasmethod(_ft_f48_9, Tuple{}))
    return h
end
function _ft_f48_22()
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t48_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f48_22()
    local v3 = v1(Int64, (n + 2))
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, (n + 2)), !applicable(v1, Int64, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f48_22), !applicable(_ft_f48_22, n), hasmethod(_ft_f48_22, Tuple{}))
    return h
end

# function_type49: F0 = int Function([List<T>]); F3 = void Function(int, [Function x]); F4 = List<A> Function<A>(Function x); F9 = List<Function> Function(int, {int x}) Function(int x); F23 = B Function() Function<B extends core.int>(int x)
function _ft_f49_0(p1_1::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
_ft_m49_0(u::_FtU{T}, p1_1::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1)
function _ft_t49_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f49_0()
    h = 31h + v2
    local v3 = _ft_f49_0(Int64[n, 1])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(_ft_f49_0), !applicable(_ft_f49_0, Int64[n, 1], n), hasmethod(_ft_f49_0, Tuple{}), !applicable(_ft_f49_0, Bool[true]))
    h = 31h + _ft_m49_0(_FtU{Int64}(), Int64[n, 201]) + _ft_m49_0(_FtU{Bool}(), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m49_0, _FtU{Bool}(), Bool[true]), !applicable(_ft_m49_0, _FtU{Int64}(), Bool[true]))
    return h
end
function _ft_f49_3(p1_1::Int64, p1_2::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return nothing
end
function _ft_t49_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f49_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f49_3((n + 1), _ft_id)
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f49_3, (n + 1)), !applicable(_ft_f49_3, (n + 1), _ft_id, n), hasmethod(_ft_f49_3, Tuple{Int64}))
    return h
end
function _ft_f49_4(::Type{A}, p1_1::Function) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return A[A(s1)]
end
function _ft_t49_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f49_4(Int64, _ft_id)
    h = 31h + sum(v2)
    h = 31h + _dw_bits(applicable(_ft_f49_4, Int64, _ft_id), !applicable(_ft_f49_4, Int64, _ft_id, n), hasmethod(_ft_f49_4, Tuple{Type{Int64}, typeof(_ft_id)}))
    return h
end
function _ft_f49_9(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Function[_ft_id]
    end
end
function _ft_t49_9(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f49_9((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3); x = (n + 4))
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f49_9, (n + 1)), !applicable(_ft_f49_9, (n + 1), n), hasmethod(_ft_f49_9, Tuple{Int64}))
    return h
end
function _ft_f49_23(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function ()
        s2 = s1
        s2
    end
end
function _ft_t49_23(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f49_23(Int64, (n + 1))
    local v3 = v2()
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f49_23, Int64, (n + 1)), !applicable(_ft_f49_23, Int64, (n + 1), n), hasmethod(_ft_f49_23, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type50: F0 = int Function(int, [List<T>]); F3 = void Function(int y, [Function x]); F4 = List<A> Function<A>(List<Function> x); F9 = List<Function> Function(int, {int x}) Function<B extends core.int>(); F22 = A Function<A>(A x) Function<B extends core.int>()
function _ft_f50_0(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
_ft_m50_0(u::_FtU{T}, p1_1::Int64, p1_2::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
function _ft_t50_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f50_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f50_0((n + 1), Int64[n, 2])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f50_0, (n + 1)), !applicable(_ft_f50_0, (n + 1), Int64[n, 2], n), hasmethod(_ft_f50_0, Tuple{Int64}), !applicable(_ft_f50_0, (n + 101), Bool[true]))
    h = 31h + _ft_m50_0(_FtU{Int64}(), (n + 201), Int64[n, 202]) + _ft_m50_0(_FtU{Bool}(), (n + 203), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m50_0, _FtU{Bool}(), (n + 203), Bool[true]), !applicable(_ft_m50_0, _FtU{Int64}(), (n + 203), Bool[true]))
    return h
end
function _ft_f50_3(p1_1::Int64, p1_2::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return nothing
end
function _ft_t50_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f50_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f50_3((n + 1), _ft_id)
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f50_3, (n + 1)), !applicable(_ft_f50_3, (n + 1), _ft_id, n), hasmethod(_ft_f50_3, Tuple{Int64}))
    return h
end
function _ft_f50_4(::Type{A}, p1_1::Vector{Function}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return A[A(s1)]
end
function _ft_t50_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f50_4(Int64, Function[_ft_id])
    h = 31h + sum(v2)
    h = 31h + _dw_bits(applicable(_ft_f50_4, Int64, Function[_ft_id]), !applicable(_ft_f50_4, Int64, Function[_ft_id], n), hasmethod(_ft_f50_4, Tuple{Type{Int64}, Vector{Function}}))
    return h
end
function _ft_f50_9(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Function[_ft_id]
    end
end
function _ft_t50_9(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f50_9(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2); x = (n + 3))
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f50_9, Int64), !applicable(_ft_f50_9, Int64, n), hasmethod(_ft_f50_9, Tuple{Type{Int64}}))
    return h
end
function _ft_f50_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t50_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f50_22(Int64)
    local v3 = v1(Int64, (n + 2))
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, (n + 2)), !applicable(v1, Int64, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f50_22, Int64), !applicable(_ft_f50_22, Int64, n), hasmethod(_ft_f50_22, Tuple{Type{Int64}}))
    return h
end

# function_type51: F0 = int Function(int x, [List<T>]); F3 = void Function(Function); F4 = List<A> Function<A>(core.List<core.int> x); F9 = List<Function> Function(int, {int x}) Function<B extends core.int>(int x); F22 = A Function<A>(A x) Function<B extends core.int>(int x)
function _ft_f51_0(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
_ft_m51_0(u::_FtU{T}, p1_1::Int64, p1_2::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
function _ft_t51_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f51_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f51_0((n + 1), Int64[n, 2])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f51_0, (n + 1)), !applicable(_ft_f51_0, (n + 1), Int64[n, 2], n), hasmethod(_ft_f51_0, Tuple{Int64}), !applicable(_ft_f51_0, (n + 101), Bool[true]))
    h = 31h + _ft_m51_0(_FtU{Int64}(), (n + 201), Int64[n, 202]) + _ft_m51_0(_FtU{Bool}(), (n + 203), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m51_0, _FtU{Bool}(), (n + 203), Bool[true]), !applicable(_ft_m51_0, _FtU{Int64}(), (n + 203), Bool[true]))
    return h
end
function _ft_f51_3(p1_1::Function)
    s1 = Int64(0) + _ft_w(p1_1)
    return nothing
end
function _ft_t51_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f51_3(_ft_id)
    h = 31h + Int64(v2 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f51_3, _ft_id), !applicable(_ft_f51_3, _ft_id, n), hasmethod(_ft_f51_3, Tuple{typeof(_ft_id)}))
    return h
end
function _ft_f51_4(::Type{A}, p1_1::Vector{Int64}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return A[A(s1)]
end
function _ft_t51_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f51_4(Int64, Int64[n, 1])
    h = 31h + sum(v2)
    h = 31h + _dw_bits(applicable(_ft_f51_4, Int64, Int64[n, 1]), !applicable(_ft_f51_4, Int64, Int64[n, 1], n), hasmethod(_ft_f51_4, Tuple{Type{Int64}, Vector{Int64}}))
    return h
end
function _ft_f51_9(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Function[_ft_id]
    end
end
function _ft_t51_9(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f51_9(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3); x = (n + 4))
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f51_9, Int64, (n + 1)), !applicable(_ft_f51_9, Int64, (n + 1), n), hasmethod(_ft_f51_9, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f51_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t51_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f51_22(Int64, (n + 1))
    local v4 = v2(Int64, (n + 3))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, (n + 3)), !applicable(v2, Int64, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f51_22, Int64, (n + 1)), !applicable(_ft_f51_22, Int64, (n + 1), n), hasmethod(_ft_f51_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type52: F3 = void Function([Function]); F4 = List<A> Function<A>(List<T> x); F9 = List<Function> Function(int y, {int x}) Function(); F16 = Function(int, [Function]) Function(); F22 = A Function<A>(List<A> x) Function()
function _ft_f52_3(p1_1::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1)
    return nothing
end
function _ft_t52_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f52_3()
    h = 31h + Int64(v2 === nothing)
    local v3 = _ft_f52_3(_ft_id)
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f52_3), !applicable(_ft_f52_3, _ft_id, n), hasmethod(_ft_f52_3, Tuple{}))
    return h
end
function _ft_f52_4(::Type{A}, p1_1::Vector{Int64}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return A[A(s1)]
end
_ft_m52_4(u::_FtU{T}, ::Type{A}, p1_1::Vector{T}) where {T, A} = Int64(0) + _ft_w(p1_1)
function _ft_t52_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f52_4(Int64, Int64[n, 1])
    h = 31h + sum(v2)
    h = 31h + _dw_bits(applicable(_ft_f52_4, Int64, Int64[n, 1]), !applicable(_ft_f52_4, Int64, Int64[n, 1], n), hasmethod(_ft_f52_4, Tuple{Type{Int64}, Vector{Int64}}), !applicable(_ft_f52_4, Int64, Bool[true]))
    h = 31h + _ft_m52_4(_FtU{Int64}(), Int64, Int64[n, 201]) + _ft_m52_4(_FtU{Bool}(), Int64, Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m52_4, _FtU{Bool}(), Int64, Bool[true]), !applicable(_ft_m52_4, _FtU{Int64}(), Int64, Bool[true]))
    return h
end
function _ft_f52_9()
    s1 = Int64(0)
    return function (p2_1::Int64; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Function[_ft_id]
    end
end
function _ft_t52_9(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f52_9()
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2); x = (n + 3))
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f52_9), !applicable(_ft_f52_9, n), hasmethod(_ft_f52_9, Tuple{}))
    return h
end
function _ft_f52_16()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t52_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f52_16()
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2), _ft_id)
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f52_16), !applicable(_ft_f52_16, n), hasmethod(_ft_f52_16, Tuple{}))
    return h
end
function _ft_f52_22()
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t52_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f52_22()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f52_22), !applicable(_ft_f52_22, n), hasmethod(_ft_f52_22, Tuple{}))
    return h
end

# function_type53: F3 = void Function(int, [Function]); F4 = List<A> Function<A>(); F14 = List<T> Function([List<Function> x]) Function(int x); F17 = Function(int, {core.List<core.int> x}) Function(int x); F22 = A Function<A>(List<A> x) Function(int x)
function _ft_f53_3(p1_1::Int64, p1_2::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return nothing
end
function _ft_t53_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f53_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f53_3((n + 1), _ft_id)
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f53_3, (n + 1)), !applicable(_ft_f53_3, (n + 1), _ft_id, n), hasmethod(_ft_f53_3, Tuple{Int64}))
    return h
end
function _ft_f53_4(::Type{A}) where {A}
    s1 = Int64(0)
    return A[A(s1)]
end
function _ft_t53_4(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f53_4(Int64)
    h = 31h + sum(v1)
    h = 31h + _dw_bits(applicable(_ft_f53_4, Int64), !applicable(_ft_f53_4, Int64, n), hasmethod(_ft_f53_4, Tuple{Type{Int64}}))
    return h
end
function _ft_f53_14(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t53_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f53_14((n + 1))
    local v4 = v2()
    h = 31h + sum(v4)
    local v5 = v2(Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f53_14, (n + 1)), !applicable(_ft_f53_14, (n + 1), n), hasmethod(_ft_f53_14, Tuple{Int64}))
    return h
end
function _ft_f53_17(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t53_17(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f53_17((n + 1))
    local v5 = v2((n + 3))
    h = 31h + v5
    local v6 = v2((n + 3); x = Int64[n, 4])
    h = 31h + v6
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f53_17, (n + 1)), !applicable(_ft_f53_17, (n + 1), n), hasmethod(_ft_f53_17, Tuple{Int64}))
    return h
end
function _ft_f53_22(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t53_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f53_22((n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f53_22, (n + 1)), !applicable(_ft_f53_22, (n + 1), n), hasmethod(_ft_f53_22, Tuple{Int64}))
    return h
end

# function_type54: F0 = int Function(int y, {List<T> x}); F3 = void Function(int x, [Function]); F9 = List<Function> Function(int y, {int x}) Function<B extends core.int>(); F16 = Function(int, [Function]) Function<B extends core.int>(); F22 = A Function<A>(List<A> x) Function<B extends core.int>()
function _ft_f54_0(p1_1::Int64; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return s1
end
_ft_m54_0(u::_FtU{T}, p1_1::Int64; x::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1) + _ft_w(x)
function _ft_t54_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f54_0((n + 1))
    h = 31h + v3
    local v4 = _ft_f54_0((n + 1); x = Int64[n, 2])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f54_0, (n + 1)), !applicable(_ft_f54_0, (n + 1), n), hasmethod(_ft_f54_0, Tuple{Int64}))
    h = 31h + _ft_m54_0(_FtU{Int64}(), (n + 201)) + _ft_m54_0(_FtU{Bool}(), (n + 202); x = Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m54_0, _FtU{Bool}(), (n + 202)))
    return h
end
function _ft_f54_3(p1_1::Int64, p1_2::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return nothing
end
function _ft_t54_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f54_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f54_3((n + 1), _ft_id)
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f54_3, (n + 1)), !applicable(_ft_f54_3, (n + 1), _ft_id, n), hasmethod(_ft_f54_3, Tuple{Int64}))
    return h
end
function _ft_f54_9(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Function[_ft_id]
    end
end
function _ft_t54_9(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f54_9(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2); x = (n + 3))
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f54_9, Int64), !applicable(_ft_f54_9, Int64, n), hasmethod(_ft_f54_9, Tuple{Type{Int64}}))
    return h
end
function _ft_f54_16(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t54_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f54_16(Int64)
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2), _ft_id)
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f54_16, Int64), !applicable(_ft_f54_16, Int64, n), hasmethod(_ft_f54_16, Tuple{Type{Int64}}))
    return h
end
function _ft_f54_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t54_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f54_22(Int64)
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f54_22, Int64), !applicable(_ft_f54_22, Int64, n), hasmethod(_ft_f54_22, Tuple{Type{Int64}}))
    return h
end

# function_type55: F0 = int Function(); F3 = void Function({Function x}); F14 = List<T> Function([List<Function> x]) Function<B extends core.int>(int x); F16 = Function(int, [Function]) Function<B extends core.int>(int x); F22 = A Function<A>(List<A> x) Function<B extends core.int>(int x)
function _ft_f55_0()
    s1 = Int64(0)
    return s1
end
function _ft_t55_0(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f55_0()
    h = 31h + v1
    h = 31h + _dw_bits(applicable(_ft_f55_0), !applicable(_ft_f55_0, n), hasmethod(_ft_f55_0, Tuple{}))
    return h
end
function _ft_f55_3(; x::Function = _ft_id)
    s1 = Int64(0) + _ft_w(x)
    return nothing
end
function _ft_t55_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f55_3()
    h = 31h + Int64(v2 === nothing)
    local v3 = _ft_f55_3(; x = _ft_id)
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f55_3), !applicable(_ft_f55_3, n), hasmethod(_ft_f55_3, Tuple{}))
    return h
end
function _ft_f55_14(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t55_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f55_14(Int64, (n + 1))
    local v4 = v2()
    h = 31h + sum(v4)
    local v5 = v2(Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f55_14, Int64, (n + 1)), !applicable(_ft_f55_14, Int64, (n + 1), n), hasmethod(_ft_f55_14, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f55_16(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t55_16(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f55_16(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + v5
    local v6 = v2((n + 3), _ft_id)
    h = 31h + v6
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f55_16, Int64, (n + 1)), !applicable(_ft_f55_16, Int64, (n + 1), n), hasmethod(_ft_f55_16, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f55_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        ta2(s2)
    end
end
function _ft_t55_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f55_22(Int64, (n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f55_22, Int64, (n + 1)), !applicable(_ft_f55_22, Int64, (n + 1), n), hasmethod(_ft_f55_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type56: F1 = List<Function> Function(List<T> x); F3 = void Function(int, {Function x}); F14 = List<T> Function(int, [List<Function> x]) Function(); F16 = Function(int x, [Function]) Function(); F21 = core.List<core.int> Function<A>(List<A> x) Function()
function _ft_f56_1(p1_1::Vector{Int64})
    s1 = Int64(0) + _ft_w(p1_1)
    return Function[_ft_id]
end
_ft_m56_1(u::_FtU{T}, p1_1::Vector{T}) where {T} = Int64(0) + _ft_w(p1_1)
function _ft_t56_1(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f56_1(Int64[n, 1])
    h = 31h + Int64(length(v2))
    h = 31h + _dw_bits(applicable(_ft_f56_1, Int64[n, 1]), !applicable(_ft_f56_1, Int64[n, 1], n), hasmethod(_ft_f56_1, Tuple{Vector{Int64}}), !applicable(_ft_f56_1, Bool[true]))
    h = 31h + _ft_m56_1(_FtU{Int64}(), Int64[n, 201]) + _ft_m56_1(_FtU{Bool}(), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m56_1, _FtU{Bool}(), Bool[true]), !applicable(_ft_m56_1, _FtU{Int64}(), Bool[true]))
    return h
end
function _ft_f56_3(p1_1::Int64; x::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return nothing
end
function _ft_t56_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f56_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f56_3((n + 1); x = _ft_id)
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f56_3, (n + 1)), !applicable(_ft_f56_3, (n + 1), n), hasmethod(_ft_f56_3, Tuple{Int64}))
    return h
end
function _ft_f56_14()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t56_14(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f56_14()
    local v4 = v1((n + 2))
    h = 31h + sum(v4)
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f56_14), !applicable(_ft_f56_14, n), hasmethod(_ft_f56_14, Tuple{}))
    return h
end
function _ft_f56_16()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t56_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f56_16()
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2), _ft_id)
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f56_16), !applicable(_ft_f56_16, n), hasmethod(_ft_f56_16, Tuple{}))
    return h
end
function _ft_f56_21()
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t56_21(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f56_21()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f56_21), !applicable(_ft_f56_21, n), hasmethod(_ft_f56_21, Tuple{}))
    return h
end

# function_type57: F4 = void Function<A>(Function x); F13 = core.List<core.int> Function() Function(int x); F14 = List<T> Function(int, [List<Function> x]) Function(int x); F17 = Function(int y, {core.List<core.int> x}) Function(int x); F21 = core.List<core.int> Function<A>(List<A> x) Function(int x)
function _ft_f57_4(::Type{A}, p1_1::Function) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return nothing
end
function _ft_t57_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f57_4(Int64, _ft_id)
    h = 31h + Int64(v2 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f57_4, Int64, _ft_id), !applicable(_ft_f57_4, Int64, _ft_id, n), hasmethod(_ft_f57_4, Tuple{Type{Int64}, typeof(_ft_id)}))
    return h
end
function _ft_f57_13(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function ()
        s2 = s1
        Int64[s2]
    end
end
function _ft_t57_13(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f57_13((n + 1))
    local v3 = v2()
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f57_13, (n + 1)), !applicable(_ft_f57_13, (n + 1), n), hasmethod(_ft_f57_13, Tuple{Int64}))
    return h
end
function _ft_f57_14(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t57_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f57_14((n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f57_14, (n + 1)), !applicable(_ft_f57_14, (n + 1), n), hasmethod(_ft_f57_14, Tuple{Int64}))
    return h
end
function _ft_f57_17(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t57_17(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f57_17((n + 1))
    local v5 = v2((n + 3))
    h = 31h + v5
    local v6 = v2((n + 3); x = Int64[n, 4])
    h = 31h + v6
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f57_17, (n + 1)), !applicable(_ft_f57_17, (n + 1), n), hasmethod(_ft_f57_17, Tuple{Int64}))
    return h
end
function _ft_f57_21(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t57_21(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f57_21((n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f57_21, (n + 1)), !applicable(_ft_f57_21, (n + 1), n), hasmethod(_ft_f57_21, Tuple{Int64}))
    return h
end

# function_type58: F0 = Function Function(int, [int x]); F4 = void Function<A>(List<Function> x); F14 = List<T> Function(int, [List<Function> x]) Function<B extends core.int>(); F17 = Function(int y, {core.List<core.int> x}) Function<B extends core.int>(); F21 = core.List<core.int> Function<A>(List<A> x) Function<B extends core.int>()
function _ft_f58_0(p1_1::Int64, p1_2::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return () -> s1
end
function _ft_t58_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f58_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f58_0((n + 1), (n + 2))
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f58_0, (n + 1)), !applicable(_ft_f58_0, (n + 1), (n + 2), n), hasmethod(_ft_f58_0, Tuple{Int64}))
    return h
end
function _ft_f58_4(::Type{A}, p1_1::Vector{Function}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return nothing
end
function _ft_t58_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f58_4(Int64, Function[_ft_id])
    h = 31h + Int64(v2 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f58_4, Int64, Function[_ft_id]), !applicable(_ft_f58_4, Int64, Function[_ft_id], n), hasmethod(_ft_f58_4, Tuple{Type{Int64}, Vector{Function}}))
    return h
end
function _ft_f58_14(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t58_14(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f58_14(Int64)
    local v4 = v1((n + 2))
    h = 31h + sum(v4)
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f58_14, Int64), !applicable(_ft_f58_14, Int64, n), hasmethod(_ft_f58_14, Tuple{Type{Int64}}))
    return h
end
function _ft_f58_17(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t58_17(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f58_17(Int64)
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2); x = Int64[n, 3])
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f58_17, Int64), !applicable(_ft_f58_17, Int64, n), hasmethod(_ft_f58_17, Tuple{Type{Int64}}))
    return h
end
function _ft_f58_21(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t58_21(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f58_21(Int64)
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f58_21, Int64), !applicable(_ft_f58_21, Int64, n), hasmethod(_ft_f58_21, Tuple{Type{Int64}}))
    return h
end

# function_type59: F4 = void Function<A>(core.List<core.int> x); F13 = core.List<core.int> Function() Function<B extends core.int>( int x, ); F14 = List<T> Function(int, [List<Function> x]) Function<B extends core.int>( int x, ); F17 = Function(int y, {core.List<core.int> x}) Function<B extends core.int>( int x, ); F21 = core.List<core.int> Function<A>(List<A> x) Function<B extends core.int>( int x, )
function _ft_f59_4(::Type{A}, p1_1::Vector{Int64}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return nothing
end
function _ft_t59_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f59_4(Int64, Int64[n, 1])
    h = 31h + Int64(v2 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f59_4, Int64, Int64[n, 1]), !applicable(_ft_f59_4, Int64, Int64[n, 1], n), hasmethod(_ft_f59_4, Tuple{Type{Int64}, Vector{Int64}}))
    return h
end
function _ft_f59_13(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function ()
        s2 = s1
        Int64[s2]
    end
end
function _ft_t59_13(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f59_13(Int64, (n + 1))
    local v3 = v2()
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f59_13, Int64, (n + 1)), !applicable(_ft_f59_13, Int64, (n + 1), n), hasmethod(_ft_f59_13, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f59_14(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t59_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f59_14(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f59_14, Int64, (n + 1)), !applicable(_ft_f59_14, Int64, (n + 1), n), hasmethod(_ft_f59_14, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f59_17(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t59_17(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f59_17(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + v5
    local v6 = v2((n + 3); x = Int64[n, 4])
    h = 31h + v6
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f59_17, Int64, (n + 1)), !applicable(_ft_f59_17, Int64, (n + 1), n), hasmethod(_ft_f59_17, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f59_21(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t59_21(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f59_21(Int64, (n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f59_21, Int64, (n + 1)), !applicable(_ft_f59_21, Int64, (n + 1), n), hasmethod(_ft_f59_21, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type60: F2 = List<T> Function(int y, [core.List<core.int> x]); F4 = void Function<A>(List<T> x); F14 = List<T> Function(int y, [List<Function> x]) Function(); F16 = Function({Function x}) Function(); F20 = int Function<A>(List<A> x) Function()
function _ft_f60_2(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return Int64[s1]
end
function _ft_t60_2(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f60_2((n + 1))
    h = 31h + sum(v3)
    local v4 = _ft_f60_2((n + 1), Int64[n, 2])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(_ft_f60_2, (n + 1)), !applicable(_ft_f60_2, (n + 1), Int64[n, 2], n), hasmethod(_ft_f60_2, Tuple{Int64}))
    return h
end
function _ft_f60_4(::Type{A}, p1_1::Vector{Int64}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return nothing
end
_ft_m60_4(u::_FtU{T}, ::Type{A}, p1_1::Vector{T}) where {T, A} = Int64(0) + _ft_w(p1_1)
function _ft_t60_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f60_4(Int64, Int64[n, 1])
    h = 31h + Int64(v2 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f60_4, Int64, Int64[n, 1]), !applicable(_ft_f60_4, Int64, Int64[n, 1], n), hasmethod(_ft_f60_4, Tuple{Type{Int64}, Vector{Int64}}), !applicable(_ft_f60_4, Int64, Bool[true]))
    h = 31h + _ft_m60_4(_FtU{Int64}(), Int64, Int64[n, 201]) + _ft_m60_4(_FtU{Bool}(), Int64, Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m60_4, _FtU{Bool}(), Int64, Bool[true]), !applicable(_ft_m60_4, _FtU{Int64}(), Int64, Bool[true]))
    return h
end
function _ft_f60_14()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t60_14(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f60_14()
    local v4 = v1((n + 2))
    h = 31h + sum(v4)
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f60_14), !applicable(_ft_f60_14, n), hasmethod(_ft_f60_14, Tuple{}))
    return h
end
function _ft_f60_16()
    s1 = Int64(0)
    return function (; x::Function = _ft_id)
        s2 = s1 + _ft_w(x)
        s2
    end
end
function _ft_t60_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f60_16()
    local v3 = v1()
    h = 31h + v3
    local v4 = v1(; x = _ft_id)
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, n))
    h = 31h + _dw_bits(applicable(_ft_f60_16), !applicable(_ft_f60_16, n), hasmethod(_ft_f60_16, Tuple{}))
    return h
end
function _ft_f60_20()
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t60_20(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f60_20()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f60_20), !applicable(_ft_f60_20, n), hasmethod(_ft_f60_20, Tuple{}))
    return h
end

# function_type61: F0 = Function Function([int]); F4 = void Function<A>(); F14 = List<T> Function(int y, [List<Function> x]) Function(int x); F16 = Function({Function x}) Function(int x); F20 = int Function<A>(List<A> x) Function(int x)
function _ft_f61_0(p1_1::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1)
    return () -> s1
end
function _ft_t61_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f61_0()
    h = 31h + Int64(v2 isa Function)
    local v3 = _ft_f61_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f61_0), !applicable(_ft_f61_0, (n + 1), n), hasmethod(_ft_f61_0, Tuple{}))
    return h
end
function _ft_f61_4(::Type{A}) where {A}
    s1 = Int64(0)
    return nothing
end
function _ft_t61_4(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f61_4(Int64)
    h = 31h + Int64(v1 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f61_4, Int64), !applicable(_ft_f61_4, Int64, n), hasmethod(_ft_f61_4, Tuple{Type{Int64}}))
    return h
end
function _ft_f61_14(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t61_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f61_14((n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f61_14, (n + 1)), !applicable(_ft_f61_14, (n + 1), n), hasmethod(_ft_f61_14, Tuple{Int64}))
    return h
end
function _ft_f61_16(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (; x::Function = _ft_id)
        s2 = s1 + _ft_w(x)
        s2
    end
end
function _ft_t61_16(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f61_16((n + 1))
    local v4 = v2()
    h = 31h + v4
    local v5 = v2(; x = _ft_id)
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f61_16, (n + 1)), !applicable(_ft_f61_16, (n + 1), n), hasmethod(_ft_f61_16, Tuple{Int64}))
    return h
end
function _ft_f61_20(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t61_20(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f61_20((n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f61_20, (n + 1)), !applicable(_ft_f61_20, (n + 1), n), hasmethod(_ft_f61_20, Tuple{Int64}))
    return h
end

# function_type62: F0 = Function Function(int, [int]); F4 = void Function<A>(A x); F14 = List<T> Function(int y, [List<Function> x]) Function<B extends core.int>(); F16 = Function({Function x}) Function<B extends core.int>(); F20 = int Function<A>(List<A> x) Function<B extends core.int>()
function _ft_f62_0(p1_1::Int64, p1_2::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return () -> s1
end
function _ft_t62_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f62_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f62_0((n + 1), (n + 2))
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f62_0, (n + 1)), !applicable(_ft_f62_0, (n + 1), (n + 2), n), hasmethod(_ft_f62_0, Tuple{Int64}))
    return h
end
function _ft_f62_4(::Type{A}, p1_1::A) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return nothing
end
function _ft_t62_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f62_4(Int64, (n + 1))
    h = 31h + Int64(v2 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f62_4, Int64, (n + 1)), !applicable(_ft_f62_4, Int64, (n + 1), n), hasmethod(_ft_f62_4, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f62_14(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t62_14(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f62_14(Int64)
    local v4 = v1((n + 2))
    h = 31h + sum(v4)
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f62_14, Int64), !applicable(_ft_f62_14, Int64, n), hasmethod(_ft_f62_14, Tuple{Type{Int64}}))
    return h
end
function _ft_f62_16(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (; x::Function = _ft_id)
        s2 = s1 + _ft_w(x)
        s2
    end
end
function _ft_t62_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f62_16(Int64)
    local v3 = v1()
    h = 31h + v3
    local v4 = v1(; x = _ft_id)
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, n))
    h = 31h + _dw_bits(applicable(_ft_f62_16, Int64), !applicable(_ft_f62_16, Int64, n), hasmethod(_ft_f62_16, Tuple{Type{Int64}}))
    return h
end
function _ft_f62_20(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t62_20(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f62_20(Int64)
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f62_20, Int64), !applicable(_ft_f62_20, Int64, n), hasmethod(_ft_f62_20, Tuple{Type{Int64}}))
    return h
end

# function_type63: F0 = Function Function(int x, [int]); F4 = void Function<A>(List<A> x); F14 = List<T> Function(int y, [List<Function> x]) Function<B extends core.int>( int x, ); F16 = Function({Function x}) Function<B extends core.int>(int x); F20 = int Function<A>(List<A> x) Function<B extends core.int>(int x)
function _ft_f63_0(p1_1::Int64, p1_2::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return () -> s1
end
function _ft_t63_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f63_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f63_0((n + 1), (n + 2))
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f63_0, (n + 1)), !applicable(_ft_f63_0, (n + 1), (n + 2), n), hasmethod(_ft_f63_0, Tuple{Int64}))
    return h
end
function _ft_f63_4(::Type{A}, p1_1::Vector{A}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return nothing
end
function _ft_t63_4(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f63_4(Int64, Int64[n, 1])
    h = 31h + Int64(v2 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f63_4, Int64, Int64[n, 1]), !applicable(_ft_f63_4, Int64, Int64[n, 1], n), hasmethod(_ft_f63_4, Tuple{Type{Int64}, Vector{Int64}}))
    return h
end
function _ft_f63_14(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t63_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f63_14(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f63_14, Int64, (n + 1)), !applicable(_ft_f63_14, Int64, (n + 1), n), hasmethod(_ft_f63_14, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f63_16(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (; x::Function = _ft_id)
        s2 = s1 + _ft_w(x)
        s2
    end
end
function _ft_t63_16(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f63_16(Int64, (n + 1))
    local v4 = v2()
    h = 31h + v4
    local v5 = v2(; x = _ft_id)
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f63_16, Int64, (n + 1)), !applicable(_ft_f63_16, Int64, (n + 1), n), hasmethod(_ft_f63_16, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f63_20(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t63_20(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f63_20(Int64, (n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f63_20, Int64, (n + 1)), !applicable(_ft_f63_20, Int64, (n + 1), n), hasmethod(_ft_f63_20, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type64: F0 = Function Function({int x}); F3 = void Function(int, [List<Function>]); F12 = core.List<core.int> Function(int y, {List<Function> x}) Function(); F17 = Function([List<T> x]) Function(); F22 = List<A> Function<A>(List<Function> x) Function()
function _ft_f64_0(; x::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(x)
    return () -> s1
end
function _ft_t64_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f64_0()
    h = 31h + Int64(v2 isa Function)
    local v3 = _ft_f64_0(; x = (n + 1))
    h = 31h + Int64(v3 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f64_0), !applicable(_ft_f64_0, n), hasmethod(_ft_f64_0, Tuple{}))
    return h
end
function _ft_f64_3(p1_1::Int64, p1_2::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return nothing
end
function _ft_t64_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f64_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f64_3((n + 1), Function[_ft_id])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f64_3, (n + 1)), !applicable(_ft_f64_3, (n + 1), Function[_ft_id], n), hasmethod(_ft_f64_3, Tuple{Int64}))
    return h
end
function _ft_f64_12()
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Int64[s2]
    end
end
function _ft_t64_12(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f64_12()
    local v4 = v1((n + 2))
    h = 31h + sum(v4)
    local v5 = v1((n + 2); x = Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f64_12), !applicable(_ft_f64_12, n), hasmethod(_ft_f64_12, Tuple{}))
    return h
end
function _ft_f64_17()
    s1 = Int64(0)
    return function (p2_1::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t64_17(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f64_17()
    local v3 = v1()
    h = 31h + v3
    local v4 = v1(Int64[n, 2])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, Int64[n, 2], n), !applicable(v1, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f64_17), !applicable(_ft_f64_17, n), hasmethod(_ft_f64_17, Tuple{}))
    return h
end
function _ft_f64_22()
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t64_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f64_22()
    local v3 = v1(Int64, Function[_ft_id])
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, Function[_ft_id]), !applicable(v1, Int64, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f64_22), !applicable(_ft_f64_22, n), hasmethod(_ft_f64_22, Tuple{}))
    return h
end

# function_type65: F0 = Function Function(int, {int x}); F3 = void Function(int x, [List<Function>]); F12 = core.List<core.int> Function(int y, {List<Function> x}) Function(int x); F17 = Function([List<T> x]) Function(int x); F22 = List<A> Function<A>(List<Function> x) Function(int x)
function _ft_f65_0(p1_1::Int64; x::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return () -> s1
end
function _ft_t65_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f65_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f65_0((n + 1); x = (n + 2))
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f65_0, (n + 1)), !applicable(_ft_f65_0, (n + 1), n), hasmethod(_ft_f65_0, Tuple{Int64}))
    return h
end
function _ft_f65_3(p1_1::Int64, p1_2::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return nothing
end
function _ft_t65_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f65_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f65_3((n + 1), Function[_ft_id])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f65_3, (n + 1)), !applicable(_ft_f65_3, (n + 1), Function[_ft_id], n), hasmethod(_ft_f65_3, Tuple{Int64}))
    return h
end
function _ft_f65_12(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Int64[s2]
    end
end
function _ft_t65_12(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f65_12((n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3); x = Function[_ft_id])
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f65_12, (n + 1)), !applicable(_ft_f65_12, (n + 1), n), hasmethod(_ft_f65_12, Tuple{Int64}))
    return h
end
function _ft_f65_17(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t65_17(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f65_17((n + 1))
    local v4 = v2()
    h = 31h + v4
    local v5 = v2(Int64[n, 3])
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, Int64[n, 3], n), !applicable(v2, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f65_17, (n + 1)), !applicable(_ft_f65_17, (n + 1), n), hasmethod(_ft_f65_17, Tuple{Int64}))
    return h
end
function _ft_f65_22(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t65_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f65_22((n + 1))
    local v4 = v2(Int64, Function[_ft_id])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v2, Int64, Function[_ft_id]), !applicable(v2, Int64, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f65_22, (n + 1)), !applicable(_ft_f65_22, (n + 1), n), hasmethod(_ft_f65_22, Tuple{Int64}))
    return h
end

# function_type66: F0 = Function Function(int y, {int x}); F3 = void Function({List<Function> x}); F5 = int Function(int y, [List<Function> x]) Function<B extends core.int>(); F17 = Function([List<T> x]) Function<B extends core.int>(); F22 = List<A> Function<A>(List<Function> x) Function<B extends core.int>()
function _ft_f66_0(p1_1::Int64; x::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return () -> s1
end
function _ft_t66_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f66_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f66_0((n + 1); x = (n + 2))
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f66_0, (n + 1)), !applicable(_ft_f66_0, (n + 1), n), hasmethod(_ft_f66_0, Tuple{Int64}))
    return h
end
function _ft_f66_3(; x::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(x)
    return nothing
end
function _ft_t66_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f66_3()
    h = 31h + Int64(v2 === nothing)
    local v3 = _ft_f66_3(; x = Function[_ft_id])
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f66_3), !applicable(_ft_f66_3, n), hasmethod(_ft_f66_3, Tuple{}))
    return h
end
function _ft_f66_5(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t66_5(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f66_5(Int64)
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f66_5, Int64), !applicable(_ft_f66_5, Int64, n), hasmethod(_ft_f66_5, Tuple{Type{Int64}}))
    return h
end
function _ft_f66_17(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t66_17(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f66_17(Int64)
    local v3 = v1()
    h = 31h + v3
    local v4 = v1(Int64[n, 2])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, Int64[n, 2], n), !applicable(v1, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f66_17, Int64), !applicable(_ft_f66_17, Int64, n), hasmethod(_ft_f66_17, Tuple{Type{Int64}}))
    return h
end
function _ft_f66_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t66_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f66_22(Int64)
    local v3 = v1(Int64, Function[_ft_id])
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, Function[_ft_id]), !applicable(v1, Int64, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f66_22, Int64), !applicable(_ft_f66_22, Int64, n), hasmethod(_ft_f66_22, Tuple{Type{Int64}}))
    return h
end

# function_type67: F1 = List<Function> Function(); F3 = void Function(int, {List<Function> x}); F5 = int Function(int y, [List<Function> x]) Function<B extends core.int>(int x); F17 = Function([List<T> x]) Function<B extends core.int>(int x); F22 = List<A> Function<A>(List<Function> x) Function<B extends core.int>(int x)
function _ft_f67_1()
    s1 = Int64(0)
    return Function[_ft_id]
end
function _ft_t67_1(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f67_1()
    h = 31h + Int64(length(v1))
    h = 31h + _dw_bits(applicable(_ft_f67_1), !applicable(_ft_f67_1, n), hasmethod(_ft_f67_1, Tuple{}))
    return h
end
function _ft_f67_3(p1_1::Int64; x::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return nothing
end
function _ft_t67_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f67_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f67_3((n + 1); x = Function[_ft_id])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f67_3, (n + 1)), !applicable(_ft_f67_3, (n + 1), n), hasmethod(_ft_f67_3, Tuple{Int64}))
    return h
end
function _ft_f67_5(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t67_5(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f67_5(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + v5
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + v6
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f67_5, Int64, (n + 1)), !applicable(_ft_f67_5, Int64, (n + 1), n), hasmethod(_ft_f67_5, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f67_17(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t67_17(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f67_17(Int64, (n + 1))
    local v4 = v2()
    h = 31h + v4
    local v5 = v2(Int64[n, 3])
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, Int64[n, 3], n), !applicable(v2, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f67_17, Int64, (n + 1)), !applicable(_ft_f67_17, Int64, (n + 1), n), hasmethod(_ft_f67_17, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f67_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t67_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f67_22(Int64, (n + 1))
    local v4 = v2(Int64, Function[_ft_id])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v2, Int64, Function[_ft_id]), !applicable(v2, Int64, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f67_22, Int64, (n + 1)), !applicable(_ft_f67_22, Int64, (n + 1), n), hasmethod(_ft_f67_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type68: F3 = void Function(int y, {List<Function> x}); F16 = Function(int y, {Function x}) Function(); F19 = void Function(int x, [core.List<core.int>]) Function(); F21 = List<T> Function<A>(List<Function> x) Function(); F22 = List<A> Function<A>(core.List<core.int> x) Function()
function _ft_f68_3(p1_1::Int64; x::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return nothing
end
function _ft_t68_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f68_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f68_3((n + 1); x = Function[_ft_id])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f68_3, (n + 1)), !applicable(_ft_f68_3, (n + 1), n), hasmethod(_ft_f68_3, Tuple{Int64}))
    return h
end
function _ft_f68_16()
    s1 = Int64(0)
    return function (p2_1::Int64; x::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t68_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f68_16()
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2); x = _ft_id)
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f68_16), !applicable(_ft_f68_16, n), hasmethod(_ft_f68_16, Tuple{}))
    return h
end
function _ft_f68_19()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t68_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f68_19()
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2), Int64[n, 3])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f68_19), !applicable(_ft_f68_19, n), hasmethod(_ft_f68_19, Tuple{}))
    return h
end
function _ft_f68_21()
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t68_21(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f68_21()
    local v3 = v1(Int64, Function[_ft_id])
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, Function[_ft_id]), !applicable(v1, Int64, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f68_21), !applicable(_ft_f68_21, n), hasmethod(_ft_f68_21, Tuple{}))
    return h
end
function _ft_f68_22()
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t68_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f68_22()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f68_22), !applicable(_ft_f68_22, n), hasmethod(_ft_f68_22, Tuple{}))
    return h
end

# function_type69: F0 = Function Function(int, [Function x]); F3 = void Function(core.List<core.int> x); F14 = List<T> Function([List<Function>]) Function(int x); F16 = Function(int y, {Function x}) Function(int x); F22 = List<A> Function<A>(core.List<core.int> x) Function(int x)
function _ft_f69_0(p1_1::Int64, p1_2::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return () -> s1
end
function _ft_t69_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f69_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f69_0((n + 1), _ft_id)
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f69_0, (n + 1)), !applicable(_ft_f69_0, (n + 1), _ft_id, n), hasmethod(_ft_f69_0, Tuple{Int64}))
    return h
end
function _ft_f69_3(p1_1::Vector{Int64})
    s1 = Int64(0) + _ft_w(p1_1)
    return nothing
end
function _ft_t69_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f69_3(Int64[n, 1])
    h = 31h + Int64(v2 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f69_3, Int64[n, 1]), !applicable(_ft_f69_3, Int64[n, 1], n), hasmethod(_ft_f69_3, Tuple{Vector{Int64}}))
    return h
end
function _ft_f69_14(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t69_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f69_14((n + 1))
    local v4 = v2()
    h = 31h + sum(v4)
    local v5 = v2(Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f69_14, (n + 1)), !applicable(_ft_f69_14, (n + 1), n), hasmethod(_ft_f69_14, Tuple{Int64}))
    return h
end
function _ft_f69_16(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t69_16(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f69_16((n + 1))
    local v5 = v2((n + 3))
    h = 31h + v5
    local v6 = v2((n + 3); x = _ft_id)
    h = 31h + v6
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f69_16, (n + 1)), !applicable(_ft_f69_16, (n + 1), n), hasmethod(_ft_f69_16, Tuple{Int64}))
    return h
end
function _ft_f69_22(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t69_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f69_22((n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f69_22, (n + 1)), !applicable(_ft_f69_22, (n + 1), n), hasmethod(_ft_f69_22, Tuple{Int64}))
    return h
end

# function_type70: F0 = Function Function(int y, [Function x]); F3 = void Function([core.List<core.int> x]); F16 = Function(int y, {Function x}) Function<B extends core.int>(); F21 = List<T> Function<A>(List<Function> x) Function<B extends core.int>(); F22 = List<A> Function<A>(core.List<core.int> x) Function<B extends core.int>()
function _ft_f70_0(p1_1::Int64, p1_2::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return () -> s1
end
function _ft_t70_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f70_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f70_0((n + 1), _ft_id)
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f70_0, (n + 1)), !applicable(_ft_f70_0, (n + 1), _ft_id, n), hasmethod(_ft_f70_0, Tuple{Int64}))
    return h
end
function _ft_f70_3(p1_1::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1)
    return nothing
end
function _ft_t70_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f70_3()
    h = 31h + Int64(v2 === nothing)
    local v3 = _ft_f70_3(Int64[n, 1])
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f70_3), !applicable(_ft_f70_3, Int64[n, 1], n), hasmethod(_ft_f70_3, Tuple{}))
    return h
end
function _ft_f70_16(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t70_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f70_16(Int64)
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2); x = _ft_id)
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f70_16, Int64), !applicable(_ft_f70_16, Int64, n), hasmethod(_ft_f70_16, Tuple{Type{Int64}}))
    return h
end
function _ft_f70_21(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t70_21(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f70_21(Int64)
    local v3 = v1(Int64, Function[_ft_id])
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, Function[_ft_id]), !applicable(v1, Int64, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f70_21, Int64), !applicable(_ft_f70_21, Int64, n), hasmethod(_ft_f70_21, Tuple{Type{Int64}}))
    return h
end
function _ft_f70_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t70_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f70_22(Int64)
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f70_22, Int64), !applicable(_ft_f70_22, Int64, n), hasmethod(_ft_f70_22, Tuple{Type{Int64}}))
    return h
end

# function_type71: F0 = Function Function(Function); F3 = void Function(int, [core.List<core.int> x]); F14 = List<T> Function([List<Function>]) Function<B extends core.int>(int x); F16 = Function(int y, {Function x}) Function<B extends core.int>( int x, ); F22 = List<A> Function<A>(core.List<core.int> x) Function<B extends core.int>( int x, )
function _ft_f71_0(p1_1::Function)
    s1 = Int64(0) + _ft_w(p1_1)
    return () -> s1
end
function _ft_t71_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f71_0(_ft_id)
    h = 31h + Int64(v2 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f71_0, _ft_id), !applicable(_ft_f71_0, _ft_id, n), hasmethod(_ft_f71_0, Tuple{typeof(_ft_id)}))
    return h
end
function _ft_f71_3(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return nothing
end
function _ft_t71_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f71_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f71_3((n + 1), Int64[n, 2])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f71_3, (n + 1)), !applicable(_ft_f71_3, (n + 1), Int64[n, 2], n), hasmethod(_ft_f71_3, Tuple{Int64}))
    return h
end
function _ft_f71_14(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t71_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f71_14(Int64, (n + 1))
    local v4 = v2()
    h = 31h + sum(v4)
    local v5 = v2(Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f71_14, Int64, (n + 1)), !applicable(_ft_f71_14, Int64, (n + 1), n), hasmethod(_ft_f71_14, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f71_16(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t71_16(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f71_16(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + v5
    local v6 = v2((n + 3); x = _ft_id)
    h = 31h + v6
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f71_16, Int64, (n + 1)), !applicable(_ft_f71_16, Int64, (n + 1), n), hasmethod(_ft_f71_16, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f71_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t71_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f71_22(Int64, (n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f71_22, Int64, (n + 1)), !applicable(_ft_f71_22, Int64, (n + 1), n), hasmethod(_ft_f71_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type72: F3 = void Function(int y, [core.List<core.int> x]); F14 = List<T> Function(int, [List<Function>]) Function(); F16 = Function(List<Function> x) Function(); F19 = void Function({core.List<core.int> x}) Function(); F22 = List<A> Function<A>(List<T> x) Function()
function _ft_f72_3(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return nothing
end
function _ft_t72_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f72_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f72_3((n + 1), Int64[n, 2])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f72_3, (n + 1)), !applicable(_ft_f72_3, (n + 1), Int64[n, 2], n), hasmethod(_ft_f72_3, Tuple{Int64}))
    return h
end
function _ft_f72_14()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t72_14(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f72_14()
    local v4 = v1((n + 2))
    h = 31h + sum(v4)
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f72_14), !applicable(_ft_f72_14, n), hasmethod(_ft_f72_14, Tuple{}))
    return h
end
function _ft_f72_16()
    s1 = Int64(0)
    return function (p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t72_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f72_16()
    local v3 = v1(Function[_ft_id])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Function[_ft_id]), !applicable(v1, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f72_16), !applicable(_ft_f72_16, n), hasmethod(_ft_f72_16, Tuple{}))
    return h
end
function _ft_f72_19()
    s1 = Int64(0)
    return function (; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(x)
        nothing
    end
end
function _ft_t72_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f72_19()
    local v3 = v1()
    h = 31h + Int64(v3 === nothing)
    local v4 = v1(; x = Int64[n, 2])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, n))
    h = 31h + _dw_bits(applicable(_ft_f72_19), !applicable(_ft_f72_19, n), hasmethod(_ft_f72_19, Tuple{}))
    return h
end
function _ft_f72_22()
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t72_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f72_22()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n), !applicable(v1, Int64, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f72_22), !applicable(_ft_f72_22, n), hasmethod(_ft_f72_22, Tuple{}))
    return h
end

# function_type73: F0 = Function Function(int, [Function]); F14 = List<T> Function(int, [List<Function>]) Function(int x); F16 = Function(List<Function> x) Function(int x); F19 = void Function({core.List<core.int> x}) Function(int x); F22 = List<A> Function<A>(List<T> x) Function(int x)
function _ft_f73_0(p1_1::Int64, p1_2::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return () -> s1
end
function _ft_t73_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f73_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f73_0((n + 1), _ft_id)
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f73_0, (n + 1)), !applicable(_ft_f73_0, (n + 1), _ft_id, n), hasmethod(_ft_f73_0, Tuple{Int64}))
    return h
end
function _ft_f73_14(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t73_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f73_14((n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f73_14, (n + 1)), !applicable(_ft_f73_14, (n + 1), n), hasmethod(_ft_f73_14, Tuple{Int64}))
    return h
end
function _ft_f73_16(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t73_16(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f73_16((n + 1))
    local v4 = v2(Function[_ft_id])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Function[_ft_id]), !applicable(v2, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f73_16, (n + 1)), !applicable(_ft_f73_16, (n + 1), n), hasmethod(_ft_f73_16, Tuple{Int64}))
    return h
end
function _ft_f73_19(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(x)
        nothing
    end
end
function _ft_t73_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f73_19((n + 1))
    local v4 = v2()
    h = 31h + Int64(v4 === nothing)
    local v5 = v2(; x = Int64[n, 3])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f73_19, (n + 1)), !applicable(_ft_f73_19, (n + 1), n), hasmethod(_ft_f73_19, Tuple{Int64}))
    return h
end
function _ft_f73_22(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t73_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f73_22((n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n), !applicable(v2, Int64, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f73_22, (n + 1)), !applicable(_ft_f73_22, (n + 1), n), hasmethod(_ft_f73_22, Tuple{Int64}))
    return h
end

# function_type74: F0 = Function Function(int x, [Function]); F14 = List<T> Function(int, [List<Function>]) Function<B extends core.int>(); F16 = Function(List<Function> x) Function<B extends core.int>(); F19 = void Function({core.List<core.int> x}) Function<B extends core.int>(); F22 = List<A> Function<A>(List<T> x) Function<B extends core.int>()
function _ft_f74_0(p1_1::Int64, p1_2::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return () -> s1
end
function _ft_t74_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f74_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f74_0((n + 1), _ft_id)
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f74_0, (n + 1)), !applicable(_ft_f74_0, (n + 1), _ft_id, n), hasmethod(_ft_f74_0, Tuple{Int64}))
    return h
end
function _ft_f74_14(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t74_14(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f74_14(Int64)
    local v4 = v1((n + 2))
    h = 31h + sum(v4)
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f74_14, Int64), !applicable(_ft_f74_14, Int64, n), hasmethod(_ft_f74_14, Tuple{Type{Int64}}))
    return h
end
function _ft_f74_16(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t74_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f74_16(Int64)
    local v3 = v1(Function[_ft_id])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Function[_ft_id]), !applicable(v1, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f74_16, Int64), !applicable(_ft_f74_16, Int64, n), hasmethod(_ft_f74_16, Tuple{Type{Int64}}))
    return h
end
function _ft_f74_19(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(x)
        nothing
    end
end
function _ft_t74_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f74_19(Int64)
    local v3 = v1()
    h = 31h + Int64(v3 === nothing)
    local v4 = v1(; x = Int64[n, 2])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, n))
    h = 31h + _dw_bits(applicable(_ft_f74_19, Int64), !applicable(_ft_f74_19, Int64, n), hasmethod(_ft_f74_19, Tuple{Type{Int64}}))
    return h
end
function _ft_f74_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t74_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f74_22(Int64)
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n), !applicable(v1, Int64, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f74_22, Int64), !applicable(_ft_f74_22, Int64, n), hasmethod(_ft_f74_22, Tuple{Type{Int64}}))
    return h
end

# function_type75: F0 = Function Function({Function x}); F14 = List<T> Function(int, [List<Function>]) Function<B extends core.int>(int x); F16 = Function(List<Function> x) Function<B extends core.int>(int x); F19 = void Function({core.List<core.int> x}) Function<B extends core.int>(int x); F22 = List<A> Function<A>(List<T> x) Function<B extends core.int>( int x, )
function _ft_f75_0(; x::Function = _ft_id)
    s1 = Int64(0) + _ft_w(x)
    return () -> s1
end
function _ft_t75_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f75_0()
    h = 31h + Int64(v2 isa Function)
    local v3 = _ft_f75_0(; x = _ft_id)
    h = 31h + Int64(v3 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f75_0), !applicable(_ft_f75_0, n), hasmethod(_ft_f75_0, Tuple{}))
    return h
end
function _ft_f75_14(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t75_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f75_14(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f75_14, Int64, (n + 1)), !applicable(_ft_f75_14, Int64, (n + 1), n), hasmethod(_ft_f75_14, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f75_16(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t75_16(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f75_16(Int64, (n + 1))
    local v4 = v2(Function[_ft_id])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Function[_ft_id]), !applicable(v2, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f75_16, Int64, (n + 1)), !applicable(_ft_f75_16, Int64, (n + 1), n), hasmethod(_ft_f75_16, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f75_19(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(x)
        nothing
    end
end
function _ft_t75_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f75_19(Int64, (n + 1))
    local v4 = v2()
    h = 31h + Int64(v4 === nothing)
    local v5 = v2(; x = Int64[n, 3])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f75_19, Int64, (n + 1)), !applicable(_ft_f75_19, Int64, (n + 1), n), hasmethod(_ft_f75_19, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f75_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t75_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f75_22(Int64, (n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n), !applicable(v2, Int64, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f75_22, Int64, (n + 1)), !applicable(_ft_f75_22, Int64, (n + 1), n), hasmethod(_ft_f75_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type76: F0 = Function Function(int, {Function x}); F14 = List<T> Function(int x, [List<Function>]) Function(); F17 = Function(List<T>) Function(); F19 = void Function(int, {core.List<core.int> x}) Function(); F22 = List<A> Function<A>() Function()
function _ft_f76_0(p1_1::Int64; x::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return () -> s1
end
function _ft_t76_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f76_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f76_0((n + 1); x = _ft_id)
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f76_0, (n + 1)), !applicable(_ft_f76_0, (n + 1), n), hasmethod(_ft_f76_0, Tuple{Int64}))
    return h
end
function _ft_f76_14()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t76_14(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f76_14()
    local v4 = v1((n + 2))
    h = 31h + sum(v4)
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f76_14), !applicable(_ft_f76_14, n), hasmethod(_ft_f76_14, Tuple{}))
    return h
end
function _ft_f76_17()
    s1 = Int64(0)
    return function (p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t76_17(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f76_17()
    local v3 = v1(Int64[n, 2])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64[n, 2]), !applicable(v1, Int64[n, 2], n), !applicable(v1, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f76_17), !applicable(_ft_f76_17, n), hasmethod(_ft_f76_17, Tuple{}))
    return h
end
function _ft_f76_19()
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        nothing
    end
end
function _ft_t76_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f76_19()
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2); x = Int64[n, 3])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f76_19), !applicable(_ft_f76_19, n), hasmethod(_ft_f76_19, Tuple{}))
    return h
end
function _ft_f76_22()
    s1 = Int64(0)
    return function (ta2::Type)
        s2 = s1
        [ta2(s2)]
    end
end
function _ft_t76_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f76_22()
    local v2 = v1(Int64)
    h = 31h + sum(v2)
    h = 31h + _dw_bits(applicable(v1, Int64), !applicable(v1, Int64, n))
    h = 31h + _dw_bits(applicable(_ft_f76_22), !applicable(_ft_f76_22, n), hasmethod(_ft_f76_22, Tuple{}))
    return h
end

# function_type77: F0 = Function Function(int y, {Function x}); F3 = void Function({core.List<core.int> x}); F14 = List<T> Function(int x, [List<Function>]) Function(int x); F17 = Function(List<T>) Function(int x); F22 = List<A> Function<A>() Function(int x)
function _ft_f77_0(p1_1::Int64; x::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return () -> s1
end
function _ft_t77_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f77_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f77_0((n + 1); x = _ft_id)
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f77_0, (n + 1)), !applicable(_ft_f77_0, (n + 1), n), hasmethod(_ft_f77_0, Tuple{Int64}))
    return h
end
function _ft_f77_3(; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(x)
    return nothing
end
function _ft_t77_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f77_3()
    h = 31h + Int64(v2 === nothing)
    local v3 = _ft_f77_3(; x = Int64[n, 1])
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f77_3), !applicable(_ft_f77_3, n), hasmethod(_ft_f77_3, Tuple{}))
    return h
end
function _ft_f77_14(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t77_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f77_14((n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f77_14, (n + 1)), !applicable(_ft_f77_14, (n + 1), n), hasmethod(_ft_f77_14, Tuple{Int64}))
    return h
end
function _ft_f77_17(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t77_17(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f77_17((n + 1))
    local v4 = v2(Int64[n, 3])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64[n, 3]), !applicable(v2, Int64[n, 3], n), !applicable(v2, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f77_17, (n + 1)), !applicable(_ft_f77_17, (n + 1), n), hasmethod(_ft_f77_17, Tuple{Int64}))
    return h
end
function _ft_f77_22(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type)
        s2 = s1
        [ta2(s2)]
    end
end
function _ft_t77_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f77_22((n + 1))
    local v3 = v2(Int64)
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v2, Int64), !applicable(v2, Int64, n))
    h = 31h + _dw_bits(applicable(_ft_f77_22, (n + 1)), !applicable(_ft_f77_22, (n + 1), n), hasmethod(_ft_f77_22, Tuple{Int64}))
    return h
end

# function_type78: F0 = Function Function(List<Function> x); F3 = void Function(int, {core.List<core.int> x}); F14 = List<T> Function(int x, [List<Function>]) Function<B extends core.int>(); F17 = Function(List<T>) Function<B extends core.int>(); F22 = List<A> Function<A>() Function<B extends core.int>()
function _ft_f78_0(p1_1::Vector{Function})
    s1 = Int64(0) + _ft_w(p1_1)
    return () -> s1
end
function _ft_t78_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f78_0(Function[_ft_id])
    h = 31h + Int64(v2 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f78_0, Function[_ft_id]), !applicable(_ft_f78_0, Function[_ft_id], n), hasmethod(_ft_f78_0, Tuple{Vector{Function}}))
    return h
end
function _ft_f78_3(p1_1::Int64; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return nothing
end
function _ft_t78_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f78_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f78_3((n + 1); x = Int64[n, 2])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f78_3, (n + 1)), !applicable(_ft_f78_3, (n + 1), n), hasmethod(_ft_f78_3, Tuple{Int64}))
    return h
end
function _ft_f78_14(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t78_14(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f78_14(Int64)
    local v4 = v1((n + 2))
    h = 31h + sum(v4)
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f78_14, Int64), !applicable(_ft_f78_14, Int64, n), hasmethod(_ft_f78_14, Tuple{Type{Int64}}))
    return h
end
function _ft_f78_17(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t78_17(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f78_17(Int64)
    local v3 = v1(Int64[n, 2])
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64[n, 2]), !applicable(v1, Int64[n, 2], n), !applicable(v1, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f78_17, Int64), !applicable(_ft_f78_17, Int64, n), hasmethod(_ft_f78_17, Tuple{Type{Int64}}))
    return h
end
function _ft_f78_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type)
        s2 = s1
        [ta2(s2)]
    end
end
function _ft_t78_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f78_22(Int64)
    local v2 = v1(Int64)
    h = 31h + sum(v2)
    h = 31h + _dw_bits(applicable(v1, Int64), !applicable(v1, Int64, n))
    h = 31h + _dw_bits(applicable(_ft_f78_22, Int64), !applicable(_ft_f78_22, Int64, n), hasmethod(_ft_f78_22, Tuple{Type{Int64}}))
    return h
end

# function_type79: F0 = Function Function([List<Function> x]); F3 = void Function(int y, {core.List<core.int> x}); F14 = List<T> Function(int x, [List<Function>]) Function<B extends core.int>( int x, ); F17 = Function(List<T>) Function<B extends core.int>(int x); F22 = List<A> Function<A>() Function<B extends core.int>(int x)
function _ft_f79_0(p1_1::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(p1_1)
    return () -> s1
end
function _ft_t79_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f79_0()
    h = 31h + Int64(v2 isa Function)
    local v3 = _ft_f79_0(Function[_ft_id])
    h = 31h + Int64(v3 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f79_0), !applicable(_ft_f79_0, Function[_ft_id], n), hasmethod(_ft_f79_0, Tuple{}))
    return h
end
function _ft_f79_3(p1_1::Int64; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return nothing
end
function _ft_t79_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f79_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f79_3((n + 1); x = Int64[n, 2])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f79_3, (n + 1)), !applicable(_ft_f79_3, (n + 1), n), hasmethod(_ft_f79_3, Tuple{Int64}))
    return h
end
function _ft_f79_14(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Int64[s2]
    end
end
function _ft_t79_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f79_14(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f79_14, Int64, (n + 1)), !applicable(_ft_f79_14, Int64, (n + 1), n), hasmethod(_ft_f79_14, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f79_17(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t79_17(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f79_17(Int64, (n + 1))
    local v4 = v2(Int64[n, 3])
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64[n, 3]), !applicable(v2, Int64[n, 3], n), !applicable(v2, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f79_17, Int64, (n + 1)), !applicable(_ft_f79_17, Int64, (n + 1), n), hasmethod(_ft_f79_17, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f79_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type)
        s2 = s1
        [ta2(s2)]
    end
end
function _ft_t79_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f79_22(Int64, (n + 1))
    local v3 = v2(Int64)
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v2, Int64), !applicable(v2, Int64, n))
    h = 31h + _dw_bits(applicable(_ft_f79_22, Int64, (n + 1)), !applicable(_ft_f79_22, Int64, (n + 1), n), hasmethod(_ft_f79_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type80: F0 = Function Function(int, [List<Function> x]); F16 = Function(int, [List<Function> x]) Function(); F19 = void Function(int y, {core.List<core.int> x}) Function(); F20 = Function Function<A>(List<T> x) Function(); F22 = List<A> Function<A>(A x) Function()
function _ft_f80_0(p1_1::Int64, p1_2::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return () -> s1
end
function _ft_t80_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f80_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f80_0((n + 1), Function[_ft_id])
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f80_0, (n + 1)), !applicable(_ft_f80_0, (n + 1), Function[_ft_id], n), hasmethod(_ft_f80_0, Tuple{Int64}))
    return h
end
function _ft_f80_16()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t80_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f80_16()
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f80_16), !applicable(_ft_f80_16, n), hasmethod(_ft_f80_16, Tuple{}))
    return h
end
function _ft_f80_19()
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        nothing
    end
end
function _ft_t80_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f80_19()
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2); x = Int64[n, 3])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f80_19), !applicable(_ft_f80_19, n), hasmethod(_ft_f80_19, Tuple{}))
    return h
end
function _ft_f80_20()
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Vector{Int64})
        s2 = s1 + _ft_w(p2_1)
        () -> s2
    end
end
function _ft_t80_20(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f80_20()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + Int64(v3 isa Function)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n), !applicable(v1, Int64, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f80_20), !applicable(_ft_f80_20, n), hasmethod(_ft_f80_20, Tuple{}))
    return h
end
function _ft_f80_22()
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t80_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f80_22()
    local v3 = v1(Int64, (n + 2))
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, (n + 2)), !applicable(v1, Int64, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f80_22), !applicable(_ft_f80_22, n), hasmethod(_ft_f80_22, Tuple{}))
    return h
end

# function_type81: F0 = Function Function(int y, [List<Function> x]); F16 = Function(int, [List<Function> x]) Function(int x); F19 = void Function(int y, {core.List<core.int> x}) Function(int x); F21 = List<T> Function<A>() Function(int x); F22 = List<A> Function<A>(A x) Function(int x)
function _ft_f81_0(p1_1::Int64, p1_2::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return () -> s1
end
function _ft_t81_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f81_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f81_0((n + 1), Function[_ft_id])
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f81_0, (n + 1)), !applicable(_ft_f81_0, (n + 1), Function[_ft_id], n), hasmethod(_ft_f81_0, Tuple{Int64}))
    return h
end
function _ft_f81_16(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t81_16(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f81_16((n + 1))
    local v5 = v2((n + 3))
    h = 31h + v5
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + v6
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f81_16, (n + 1)), !applicable(_ft_f81_16, (n + 1), n), hasmethod(_ft_f81_16, Tuple{Int64}))
    return h
end
function _ft_f81_19(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        nothing
    end
end
function _ft_t81_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f81_19((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3); x = Int64[n, 4])
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f81_19, (n + 1)), !applicable(_ft_f81_19, (n + 1), n), hasmethod(_ft_f81_19, Tuple{Int64}))
    return h
end
function _ft_f81_21(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type)
        s2 = s1
        Int64[s2]
    end
end
function _ft_t81_21(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f81_21((n + 1))
    local v3 = v2(Int64)
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v2, Int64), !applicable(v2, Int64, n))
    h = 31h + _dw_bits(applicable(_ft_f81_21, (n + 1)), !applicable(_ft_f81_21, (n + 1), n), hasmethod(_ft_f81_21, Tuple{Int64}))
    return h
end
function _ft_f81_22(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t81_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f81_22((n + 1))
    local v4 = v2(Int64, (n + 3))
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v2, Int64, (n + 3)), !applicable(v2, Int64, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f81_22, (n + 1)), !applicable(_ft_f81_22, (n + 1), n), hasmethod(_ft_f81_22, Tuple{Int64}))
    return h
end

# function_type82: F0 = Function Function(List<Function>); F3 = void Function(int, [List<T> x]); F6 = int Function(int y, {List<T> x}) Function<B extends core.int>(); F16 = Function(int, [List<Function> x]) Function<B extends core.int>(); F22 = List<A> Function<A>(A x) Function<B extends core.int>()
function _ft_f82_0(p1_1::Vector{Function})
    s1 = Int64(0) + _ft_w(p1_1)
    return () -> s1
end
function _ft_t82_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f82_0(Function[_ft_id])
    h = 31h + Int64(v2 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f82_0, Function[_ft_id]), !applicable(_ft_f82_0, Function[_ft_id], n), hasmethod(_ft_f82_0, Tuple{Vector{Function}}))
    return h
end
function _ft_f82_3(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return nothing
end
_ft_m82_3(u::_FtU{T}, p1_1::Int64, p1_2::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
function _ft_t82_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f82_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f82_3((n + 1), Int64[n, 2])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f82_3, (n + 1)), !applicable(_ft_f82_3, (n + 1), Int64[n, 2], n), hasmethod(_ft_f82_3, Tuple{Int64}), !applicable(_ft_f82_3, (n + 101), Bool[true]))
    h = 31h + _ft_m82_3(_FtU{Int64}(), (n + 201), Int64[n, 202]) + _ft_m82_3(_FtU{Bool}(), (n + 203), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m82_3, _FtU{Bool}(), (n + 203), Bool[true]), !applicable(_ft_m82_3, _FtU{Int64}(), (n + 203), Bool[true]))
    return h
end
function _ft_f82_6(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t82_6(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f82_6(Int64)
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2); x = Int64[n, 3])
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f82_6, Int64), !applicable(_ft_f82_6, Int64, n), hasmethod(_ft_f82_6, Tuple{Type{Int64}}))
    return h
end
function _ft_f82_16(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t82_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f82_16(Int64)
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f82_16, Int64), !applicable(_ft_f82_16, Int64, n), hasmethod(_ft_f82_16, Tuple{Type{Int64}}))
    return h
end
function _ft_f82_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t82_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f82_22(Int64)
    local v3 = v1(Int64, (n + 2))
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, (n + 2)), !applicable(v1, Int64, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f82_22, Int64), !applicable(_ft_f82_22, Int64, n), hasmethod(_ft_f82_22, Tuple{Type{Int64}}))
    return h
end

# function_type83: F0 = Function Function([List<Function>]); F16 = Function(int, [List<Function> x]) Function<B extends core.int>( int x, ); F19 = void Function(int y, {core.List<core.int> x}) Function<B extends core.int>( int x, ); F21 = List<T> Function<A>() Function<B extends core.int>(int x); F22 = List<A> Function<A>(A x) Function<B extends core.int>(int x)
function _ft_f83_0(p1_1::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(p1_1)
    return () -> s1
end
function _ft_t83_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f83_0()
    h = 31h + Int64(v2 isa Function)
    local v3 = _ft_f83_0(Function[_ft_id])
    h = 31h + Int64(v3 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f83_0), !applicable(_ft_f83_0, Function[_ft_id], n), hasmethod(_ft_f83_0, Tuple{}))
    return h
end
function _ft_f83_16(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t83_16(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f83_16(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + v5
    local v6 = v2((n + 3), Function[_ft_id])
    h = 31h + v6
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f83_16, Int64, (n + 1)), !applicable(_ft_f83_16, Int64, (n + 1), n), hasmethod(_ft_f83_16, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f83_19(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        nothing
    end
end
function _ft_t83_19(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f83_19(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3); x = Int64[n, 4])
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f83_19, Int64, (n + 1)), !applicable(_ft_f83_19, Int64, (n + 1), n), hasmethod(_ft_f83_19, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f83_21(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type)
        s2 = s1
        Int64[s2]
    end
end
function _ft_t83_21(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f83_21(Int64, (n + 1))
    local v3 = v2(Int64)
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v2, Int64), !applicable(v2, Int64, n))
    h = 31h + _dw_bits(applicable(_ft_f83_21, Int64, (n + 1)), !applicable(_ft_f83_21, Int64, (n + 1), n), hasmethod(_ft_f83_21, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f83_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t83_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f83_22(Int64, (n + 1))
    local v4 = v2(Int64, (n + 3))
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v2, Int64, (n + 3)), !applicable(v2, Int64, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f83_22, Int64, (n + 1)), !applicable(_ft_f83_22, Int64, (n + 1), n), hasmethod(_ft_f83_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type84: F0 = Function Function(int, [List<Function>]); F3 = void Function(List<T>); F14 = List<T> Function(int, {List<Function> x}) Function(); F16 = Function(int y, [List<Function> x]) Function(); F22 = List<A> Function<A>(List<A> x) Function()
function _ft_f84_0(p1_1::Int64, p1_2::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return () -> s1
end
function _ft_t84_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f84_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f84_0((n + 1), Function[_ft_id])
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f84_0, (n + 1)), !applicable(_ft_f84_0, (n + 1), Function[_ft_id], n), hasmethod(_ft_f84_0, Tuple{Int64}))
    return h
end
function _ft_f84_3(p1_1::Vector{Int64})
    s1 = Int64(0) + _ft_w(p1_1)
    return nothing
end
_ft_m84_3(u::_FtU{T}, p1_1::Vector{T}) where {T} = Int64(0) + _ft_w(p1_1)
function _ft_t84_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f84_3(Int64[n, 1])
    h = 31h + Int64(v2 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f84_3, Int64[n, 1]), !applicable(_ft_f84_3, Int64[n, 1], n), hasmethod(_ft_f84_3, Tuple{Vector{Int64}}), !applicable(_ft_f84_3, Bool[true]))
    h = 31h + _ft_m84_3(_FtU{Int64}(), Int64[n, 201]) + _ft_m84_3(_FtU{Bool}(), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m84_3, _FtU{Bool}(), Bool[true]), !applicable(_ft_m84_3, _FtU{Int64}(), Bool[true]))
    return h
end
function _ft_f84_14()
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Int64[s2]
    end
end
function _ft_t84_14(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f84_14()
    local v4 = v1((n + 2))
    h = 31h + sum(v4)
    local v5 = v1((n + 2); x = Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f84_14), !applicable(_ft_f84_14, n), hasmethod(_ft_f84_14, Tuple{}))
    return h
end
function _ft_f84_16()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        s2
    end
end
function _ft_t84_16(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f84_16()
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2), Function[_ft_id])
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f84_16), !applicable(_ft_f84_16, n), hasmethod(_ft_f84_16, Tuple{}))
    return h
end
function _ft_f84_22()
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t84_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f84_22()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f84_22), !applicable(_ft_f84_22, n), hasmethod(_ft_f84_22, Tuple{}))
    return h
end

# function_type85: F2 = Function([int]); F3 = void Function([List<T>]); F6 = int Function() Function(int x); F14 = List<T> Function(int, {List<Function> x}) Function(int x); F22 = List<A> Function<A>(List<A> x) Function(int x)
function _ft_f85_2(p1_1::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t85_2(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f85_2()
    h = 31h + v2
    local v3 = _ft_f85_2((n + 1))
    h = 31h + v3
    h = 31h + _dw_bits(applicable(_ft_f85_2), !applicable(_ft_f85_2, (n + 1), n), hasmethod(_ft_f85_2, Tuple{}))
    return h
end
function _ft_f85_3(p1_1::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1)
    return nothing
end
_ft_m85_3(u::_FtU{T}, p1_1::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1)
function _ft_t85_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f85_3()
    h = 31h + Int64(v2 === nothing)
    local v3 = _ft_f85_3(Int64[n, 1])
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f85_3), !applicable(_ft_f85_3, Int64[n, 1], n), hasmethod(_ft_f85_3, Tuple{}), !applicable(_ft_f85_3, Bool[true]))
    h = 31h + _ft_m85_3(_FtU{Int64}(), Int64[n, 201]) + _ft_m85_3(_FtU{Bool}(), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m85_3, _FtU{Bool}(), Bool[true]), !applicable(_ft_m85_3, _FtU{Int64}(), Bool[true]))
    return h
end
function _ft_f85_6(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function ()
        s2 = s1
        s2
    end
end
function _ft_t85_6(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f85_6((n + 1))
    local v3 = v2()
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f85_6, (n + 1)), !applicable(_ft_f85_6, (n + 1), n), hasmethod(_ft_f85_6, Tuple{Int64}))
    return h
end
function _ft_f85_14(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Int64[s2]
    end
end
function _ft_t85_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f85_14((n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3); x = Function[_ft_id])
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f85_14, (n + 1)), !applicable(_ft_f85_14, (n + 1), n), hasmethod(_ft_f85_14, Tuple{Int64}))
    return h
end
function _ft_f85_22(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t85_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f85_22((n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f85_22, (n + 1)), !applicable(_ft_f85_22, (n + 1), n), hasmethod(_ft_f85_22, Tuple{Int64}))
    return h
end

# function_type86: F0 = Function Function({List<Function> x}); F2 = Function(int, [int]); F3 = void Function(int, [List<T>]); F14 = List<T> Function(int, {List<Function> x}) Function<B extends core.int>(); F22 = List<A> Function<A>(List<A> x) Function<B extends core.int>()
function _ft_f86_0(; x::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(x)
    return () -> s1
end
function _ft_t86_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f86_0()
    h = 31h + Int64(v2 isa Function)
    local v3 = _ft_f86_0(; x = Function[_ft_id])
    h = 31h + Int64(v3 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f86_0), !applicable(_ft_f86_0, n), hasmethod(_ft_f86_0, Tuple{}))
    return h
end
function _ft_f86_2(p1_1::Int64, p1_2::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
function _ft_t86_2(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f86_2((n + 1))
    h = 31h + v3
    local v4 = _ft_f86_2((n + 1), (n + 2))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f86_2, (n + 1)), !applicable(_ft_f86_2, (n + 1), (n + 2), n), hasmethod(_ft_f86_2, Tuple{Int64}))
    return h
end
function _ft_f86_3(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return nothing
end
_ft_m86_3(u::_FtU{T}, p1_1::Int64, p1_2::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
function _ft_t86_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f86_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f86_3((n + 1), Int64[n, 2])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f86_3, (n + 1)), !applicable(_ft_f86_3, (n + 1), Int64[n, 2], n), hasmethod(_ft_f86_3, Tuple{Int64}), !applicable(_ft_f86_3, (n + 101), Bool[true]))
    h = 31h + _ft_m86_3(_FtU{Int64}(), (n + 201), Int64[n, 202]) + _ft_m86_3(_FtU{Bool}(), (n + 203), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m86_3, _FtU{Bool}(), (n + 203), Bool[true]), !applicable(_ft_m86_3, _FtU{Int64}(), (n + 203), Bool[true]))
    return h
end
function _ft_f86_14(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Int64[s2]
    end
end
function _ft_t86_14(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f86_14(Int64)
    local v4 = v1((n + 2))
    h = 31h + sum(v4)
    local v5 = v1((n + 2); x = Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f86_14, Int64), !applicable(_ft_f86_14, Int64, n), hasmethod(_ft_f86_14, Tuple{Type{Int64}}))
    return h
end
function _ft_f86_22(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t86_22(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f86_22(Int64)
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f86_22, Int64), !applicable(_ft_f86_22, Int64, n), hasmethod(_ft_f86_22, Tuple{Type{Int64}}))
    return h
end

# function_type87: F2 = Function(int x, [int]); F3 = void Function(int x, [List<T>]); F6 = int Function() Function<B extends core.int>(int x); F14 = List<T> Function(int, {List<Function> x}) Function<B extends core.int>( int x, ); F22 = List<A> Function<A>(List<A> x) Function<B extends core.int>( int x, )
function _ft_f87_2(p1_1::Int64, p1_2::Int64 = Int64(0))
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
function _ft_t87_2(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f87_2((n + 1))
    h = 31h + v3
    local v4 = _ft_f87_2((n + 1), (n + 2))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f87_2, (n + 1)), !applicable(_ft_f87_2, (n + 1), (n + 2), n), hasmethod(_ft_f87_2, Tuple{Int64}))
    return h
end
function _ft_f87_3(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return nothing
end
_ft_m87_3(u::_FtU{T}, p1_1::Int64, p1_2::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
function _ft_t87_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f87_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f87_3((n + 1), Int64[n, 2])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f87_3, (n + 1)), !applicable(_ft_f87_3, (n + 1), Int64[n, 2], n), hasmethod(_ft_f87_3, Tuple{Int64}), !applicable(_ft_f87_3, (n + 101), Bool[true]))
    h = 31h + _ft_m87_3(_FtU{Int64}(), (n + 201), Int64[n, 202]) + _ft_m87_3(_FtU{Bool}(), (n + 203), Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m87_3, _FtU{Bool}(), (n + 203), Bool[true]), !applicable(_ft_m87_3, _FtU{Int64}(), (n + 203), Bool[true]))
    return h
end
function _ft_f87_6(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function ()
        s2 = s1
        s2
    end
end
function _ft_t87_6(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f87_6(Int64, (n + 1))
    local v3 = v2()
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, n))
    h = 31h + _dw_bits(applicable(_ft_f87_6, Int64, (n + 1)), !applicable(_ft_f87_6, Int64, (n + 1), n), hasmethod(_ft_f87_6, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f87_14(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Int64[s2]
    end
end
function _ft_t87_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f87_14(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3); x = Function[_ft_id])
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f87_14, Int64, (n + 1)), !applicable(_ft_f87_14, Int64, (n + 1), n), hasmethod(_ft_f87_14, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f87_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        [ta2(s2)]
    end
end
function _ft_t87_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f87_22(Int64, (n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f87_22, Int64, (n + 1)), !applicable(_ft_f87_22, Int64, (n + 1), n), hasmethod(_ft_f87_22, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type88: F0 = Function Function(int y, {List<Function> x}); F3 = void Function({List<T> x}); F14 = List<T> Function(int y, {List<Function> x}) Function(); F15 = Function([int x]) Function(); F21 = List<T> Function<A>(List<A> x) Function()
function _ft_f88_0(p1_1::Int64; x::Vector{Function} = Function[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return () -> s1
end
function _ft_t88_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f88_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f88_0((n + 1); x = Function[_ft_id])
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f88_0, (n + 1)), !applicable(_ft_f88_0, (n + 1), n), hasmethod(_ft_f88_0, Tuple{Int64}))
    return h
end
function _ft_f88_3(; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(x)
    return nothing
end
_ft_m88_3(u::_FtU{T}; x::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(x)
function _ft_t88_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f88_3()
    h = 31h + Int64(v2 === nothing)
    local v3 = _ft_f88_3(; x = Int64[n, 1])
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f88_3), !applicable(_ft_f88_3, n), hasmethod(_ft_f88_3, Tuple{}))
    h = 31h + _ft_m88_3(_FtU{Int64}()) + _ft_m88_3(_FtU{Bool}(); x = Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m88_3, _FtU{Bool}()))
    return h
end
function _ft_f88_14()
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Int64[s2]
    end
end
function _ft_t88_14(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f88_14()
    local v4 = v1((n + 2))
    h = 31h + sum(v4)
    local v5 = v1((n + 2); x = Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f88_14), !applicable(_ft_f88_14, n), hasmethod(_ft_f88_14, Tuple{}))
    return h
end
function _ft_f88_15()
    s1 = Int64(0)
    return function (p2_1::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t88_15(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f88_15()
    local v3 = v1()
    h = 31h + v3
    local v4 = v1((n + 2))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f88_15), !applicable(_ft_f88_15, n), hasmethod(_ft_f88_15, Tuple{}))
    return h
end
function _ft_f88_21()
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t88_21(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f88_21()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f88_21), !applicable(_ft_f88_21, n), hasmethod(_ft_f88_21, Tuple{}))
    return h
end

# function_type89: F0 = Function Function(core.List<core.int> x); F3 = void Function(int, {List<T> x}); F14 = List<T> Function(int y, {List<Function> x}) Function(int x); F15 = Function([int x]) Function(int x); F21 = List<T> Function<A>(List<A> x) Function(int x)
function _ft_f89_0(p1_1::Vector{Int64})
    s1 = Int64(0) + _ft_w(p1_1)
    return () -> s1
end
function _ft_t89_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f89_0(Int64[n, 1])
    h = 31h + Int64(v2 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f89_0, Int64[n, 1]), !applicable(_ft_f89_0, Int64[n, 1], n), hasmethod(_ft_f89_0, Tuple{Vector{Int64}}))
    return h
end
function _ft_f89_3(p1_1::Int64; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return nothing
end
_ft_m89_3(u::_FtU{T}, p1_1::Int64; x::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1) + _ft_w(x)
function _ft_t89_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f89_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f89_3((n + 1); x = Int64[n, 2])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f89_3, (n + 1)), !applicable(_ft_f89_3, (n + 1), n), hasmethod(_ft_f89_3, Tuple{Int64}))
    h = 31h + _ft_m89_3(_FtU{Int64}(), (n + 201)) + _ft_m89_3(_FtU{Bool}(), (n + 202); x = Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m89_3, _FtU{Bool}(), (n + 202)))
    return h
end
function _ft_f89_14(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Int64[s2]
    end
end
function _ft_t89_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f89_14((n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3); x = Function[_ft_id])
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f89_14, (n + 1)), !applicable(_ft_f89_14, (n + 1), n), hasmethod(_ft_f89_14, Tuple{Int64}))
    return h
end
function _ft_f89_15(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t89_15(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f89_15((n + 1))
    local v4 = v2()
    h = 31h + v4
    local v5 = v2((n + 3))
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f89_15, (n + 1)), !applicable(_ft_f89_15, (n + 1), n), hasmethod(_ft_f89_15, Tuple{Int64}))
    return h
end
function _ft_f89_21(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t89_21(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f89_21((n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f89_21, (n + 1)), !applicable(_ft_f89_21, (n + 1), n), hasmethod(_ft_f89_21, Tuple{Int64}))
    return h
end

# function_type90: F0 = Function Function([core.List<core.int> x]); F3 = void Function(int y, {List<T> x}); F14 = List<T> Function(int y, {List<Function> x}) Function<B extends core.int>(); F15 = Function([int x]) Function<B extends core.int>(); F21 = List<T> Function<A>(List<A> x) Function<B extends core.int>()
function _ft_f90_0(p1_1::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1)
    return () -> s1
end
function _ft_t90_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f90_0()
    h = 31h + Int64(v2 isa Function)
    local v3 = _ft_f90_0(Int64[n, 1])
    h = 31h + Int64(v3 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f90_0), !applicable(_ft_f90_0, Int64[n, 1], n), hasmethod(_ft_f90_0, Tuple{}))
    return h
end
function _ft_f90_3(p1_1::Int64; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return nothing
end
_ft_m90_3(u::_FtU{T}, p1_1::Int64; x::Vector{T} = T[]) where {T} = Int64(0) + _ft_w(p1_1) + _ft_w(x)
function _ft_t90_3(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f90_3((n + 1))
    h = 31h + Int64(v3 === nothing)
    local v4 = _ft_f90_3((n + 1); x = Int64[n, 2])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f90_3, (n + 1)), !applicable(_ft_f90_3, (n + 1), n), hasmethod(_ft_f90_3, Tuple{Int64}))
    h = 31h + _ft_m90_3(_FtU{Int64}(), (n + 201)) + _ft_m90_3(_FtU{Bool}(), (n + 202); x = Bool[true])
    h = 31h + _dw_bits(applicable(_ft_m90_3, _FtU{Bool}(), (n + 202)))
    return h
end
function _ft_f90_14(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Int64[s2]
    end
end
function _ft_t90_14(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f90_14(Int64)
    local v4 = v1((n + 2))
    h = 31h + sum(v4)
    local v5 = v1((n + 2); x = Function[_ft_id])
    h = 31h + sum(v5)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f90_14, Int64), !applicable(_ft_f90_14, Int64, n), hasmethod(_ft_f90_14, Tuple{Type{Int64}}))
    return h
end
function _ft_f90_15(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t90_15(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f90_15(Int64)
    local v3 = v1()
    h = 31h + v3
    local v4 = v1((n + 2))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f90_15, Int64), !applicable(_ft_f90_15, Int64, n), hasmethod(_ft_f90_15, Tuple{Type{Int64}}))
    return h
end
function _ft_f90_21(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t90_21(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f90_21(Int64)
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + sum(v3)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f90_21, Int64), !applicable(_ft_f90_21, Int64, n), hasmethod(_ft_f90_21, Tuple{Type{Int64}}))
    return h
end

# function_type91: F0 = Function Function(int, [core.List<core.int> x]); F3 = void Function(); F14 = List<T> Function(int y, {List<Function> x}) Function<B extends core.int>( int x, ); F15 = Function([int x]) Function<B extends core.int>(int x); F21 = List<T> Function<A>(List<A> x) Function<B extends core.int>( int x, )
function _ft_f91_0(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return () -> s1
end
function _ft_t91_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f91_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f91_0((n + 1), Int64[n, 2])
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f91_0, (n + 1)), !applicable(_ft_f91_0, (n + 1), Int64[n, 2], n), hasmethod(_ft_f91_0, Tuple{Int64}))
    return h
end
function _ft_f91_3()
    s1 = Int64(0)
    return nothing
end
function _ft_t91_3(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f91_3()
    h = 31h + Int64(v1 === nothing)
    h = 31h + _dw_bits(applicable(_ft_f91_3), !applicable(_ft_f91_3, n), hasmethod(_ft_f91_3, Tuple{}))
    return h
end
function _ft_f91_14(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        Int64[s2]
    end
end
function _ft_t91_14(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f91_14(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + sum(v5)
    local v6 = v2((n + 3); x = Function[_ft_id])
    h = 31h + sum(v6)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f91_14, Int64, (n + 1)), !applicable(_ft_f91_14, Int64, (n + 1), n), hasmethod(_ft_f91_14, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f91_15(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64 = Int64(0))
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t91_15(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f91_15(Int64, (n + 1))
    local v4 = v2()
    h = 31h + v4
    local v5 = v2((n + 3))
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f91_15, Int64, (n + 1)), !applicable(_ft_f91_15, Int64, (n + 1), n), hasmethod(_ft_f91_15, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f91_21(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        Int64[s2]
    end
end
function _ft_t91_21(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f91_21(Int64, (n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + sum(v4)
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f91_21, Int64, (n + 1)), !applicable(_ft_f91_21, Int64, (n + 1), n), hasmethod(_ft_f91_21, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type92: F0 = Function Function(int y, [core.List<core.int> x]); F2 = Function([Function x]); F5 = int Function(int y, {List<Function> x}) Function(); F19 = void Function(int, [List<T> x]) Function(); F20 = Function Function<A>(List<A> x) Function()
function _ft_f92_0(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return () -> s1
end
function _ft_t92_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f92_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f92_0((n + 1), Int64[n, 2])
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f92_0, (n + 1)), !applicable(_ft_f92_0, (n + 1), Int64[n, 2], n), hasmethod(_ft_f92_0, Tuple{Int64}))
    return h
end
function _ft_f92_2(p1_1::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t92_2(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f92_2()
    h = 31h + v2
    local v3 = _ft_f92_2(_ft_id)
    h = 31h + v3
    h = 31h + _dw_bits(applicable(_ft_f92_2), !applicable(_ft_f92_2, _ft_id, n), hasmethod(_ft_f92_2, Tuple{}))
    return h
end
function _ft_f92_5()
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t92_5(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f92_5()
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2); x = Function[_ft_id])
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f92_5), !applicable(_ft_f92_5, n), hasmethod(_ft_f92_5, Tuple{}))
    return h
end
function _ft_f92_19()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t92_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f92_19()
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2), Int64[n, 3])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Int64[n, 3], n), !applicable(v1, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f92_19), !applicable(_ft_f92_19, n), hasmethod(_ft_f92_19, Tuple{}))
    return h
end
function _ft_f92_20()
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        () -> s2
    end
end
function _ft_t92_20(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f92_20()
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + Int64(v3 isa Function)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f92_20), !applicable(_ft_f92_20, n), hasmethod(_ft_f92_20, Tuple{}))
    return h
end

# function_type93: F2 = Function(int, [Function x]); F3 = int Function<A>(Function x); F10 = List<Function> Function([List<T> x]) Function(int x); F18 = void Function(int y, {Function x}) Function(int x); F20 = Function Function<A>(List<A> x) Function(int x)
function _ft_f93_2(p1_1::Int64, p1_2::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
function _ft_t93_2(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f93_2((n + 1))
    h = 31h + v3
    local v4 = _ft_f93_2((n + 1), _ft_id)
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f93_2, (n + 1)), !applicable(_ft_f93_2, (n + 1), _ft_id, n), hasmethod(_ft_f93_2, Tuple{Int64}))
    return h
end
function _ft_f93_3(::Type{A}, p1_1::Function) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t93_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f93_3(Int64, _ft_id)
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f93_3, Int64, _ft_id), !applicable(_ft_f93_3, Int64, _ft_id, n), hasmethod(_ft_f93_3, Tuple{Type{Int64}, typeof(_ft_id)}))
    return h
end
function _ft_f93_10(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1)
        Function[_ft_id]
    end
end
function _ft_t93_10(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f93_10((n + 1))
    local v4 = v2()
    h = 31h + Int64(length(v4))
    local v5 = v2(Int64[n, 3])
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, Int64[n, 3], n), !applicable(v2, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f93_10, (n + 1)), !applicable(_ft_f93_10, (n + 1), n), hasmethod(_ft_f93_10, Tuple{Int64}))
    return h
end
function _ft_f93_18(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        nothing
    end
end
function _ft_t93_18(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f93_18((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3); x = _ft_id)
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f93_18, (n + 1)), !applicable(_ft_f93_18, (n + 1), n), hasmethod(_ft_f93_18, Tuple{Int64}))
    return h
end
function _ft_f93_20(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        () -> s2
    end
end
function _ft_t93_20(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f93_20((n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f93_20, (n + 1)), !applicable(_ft_f93_20, (n + 1), n), hasmethod(_ft_f93_20, Tuple{Int64}))
    return h
end

# function_type94: F2 = Function(int y, [Function x]); F3 = int Function<A>(List<Function> x); F5 = int Function(int y, {List<Function> x}) Function<B extends core.int>(); F19 = void Function(int, [List<T> x]) Function<B extends core.int>(); F20 = Function Function<A>(List<A> x) Function<B extends core.int>()
function _ft_f94_2(p1_1::Int64, p1_2::Function = _ft_id)
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return s1
end
function _ft_t94_2(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f94_2((n + 1))
    h = 31h + v3
    local v4 = _ft_f94_2((n + 1), _ft_id)
    h = 31h + v4
    h = 31h + _dw_bits(applicable(_ft_f94_2, (n + 1)), !applicable(_ft_f94_2, (n + 1), _ft_id, n), hasmethod(_ft_f94_2, Tuple{Int64}))
    return h
end
function _ft_f94_3(::Type{A}, p1_1::Vector{Function}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t94_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f94_3(Int64, Function[_ft_id])
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f94_3, Int64, Function[_ft_id]), !applicable(_ft_f94_3, Int64, Function[_ft_id], n), hasmethod(_ft_f94_3, Tuple{Type{Int64}, Vector{Function}}))
    return h
end
function _ft_f94_5(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64; x::Vector{Function} = Function[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        s2
    end
end
function _ft_t94_5(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f94_5(Int64)
    local v4 = v1((n + 2))
    h = 31h + v4
    local v5 = v1((n + 2); x = Function[_ft_id])
    h = 31h + v5
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), n))
    h = 31h + _dw_bits(applicable(_ft_f94_5, Int64), !applicable(_ft_f94_5, Int64, n), hasmethod(_ft_f94_5, Tuple{Type{Int64}}))
    return h
end
function _ft_f94_19(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        nothing
    end
end
function _ft_t94_19(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f94_19(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(v4 === nothing)
    local v5 = v1((n + 2), Int64[n, 3])
    h = 31h + Int64(v5 === nothing)
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Int64[n, 3], n), !applicable(v1, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f94_19, Int64), !applicable(_ft_f94_19, Int64, n), hasmethod(_ft_f94_19, Tuple{Type{Int64}}))
    return h
end
function _ft_f94_20(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        () -> s2
    end
end
function _ft_t94_20(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f94_20(Int64)
    local v3 = v1(Int64, Int64[n, 2])
    h = 31h + Int64(v3 isa Function)
    h = 31h + _dw_bits(applicable(v1, Int64, Int64[n, 2]), !applicable(v1, Int64, Int64[n, 2], n))
    h = 31h + _dw_bits(applicable(_ft_f94_20, Int64), !applicable(_ft_f94_20, Int64, n), hasmethod(_ft_f94_20, Tuple{Type{Int64}}))
    return h
end

# function_type95: F2 = Function(Function); F3 = int Function<A>(core.List<core.int> x); F10 = List<Function> Function([List<T> x]) Function<B extends core.int>(int x); F18 = void Function(int y, {Function x}) Function<B extends core.int>(int x); F20 = Function Function<A>(List<A> x) Function<B extends core.int>( int x, )
function _ft_f95_2(p1_1::Function)
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t95_2(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f95_2(_ft_id)
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f95_2, _ft_id), !applicable(_ft_f95_2, _ft_id, n), hasmethod(_ft_f95_2, Tuple{typeof(_ft_id)}))
    return h
end
function _ft_f95_3(::Type{A}, p1_1::Vector{Int64}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t95_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f95_3(Int64, Int64[n, 1])
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f95_3, Int64, Int64[n, 1]), !applicable(_ft_f95_3, Int64, Int64[n, 1], n), hasmethod(_ft_f95_3, Tuple{Type{Int64}, Vector{Int64}}))
    return h
end
function _ft_f95_10(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1)
        Function[_ft_id]
    end
end
function _ft_t95_10(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f95_10(Int64, (n + 1))
    local v4 = v2()
    h = 31h + Int64(length(v4))
    local v5 = v2(Int64[n, 3])
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v2), !applicable(v2, Int64[n, 3], n), !applicable(v2, Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f95_10, Int64, (n + 1)), !applicable(_ft_f95_10, Int64, (n + 1), n), hasmethod(_ft_f95_10, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f95_18(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64; x::Function = _ft_id)
        s2 = s1 + _ft_w(p2_1) + _ft_w(x)
        nothing
    end
end
function _ft_t95_18(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f95_18(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(v5 === nothing)
    local v6 = v2((n + 3); x = _ft_id)
    h = 31h + Int64(v6 === nothing)
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), n))
    h = 31h + _dw_bits(applicable(_ft_f95_18, Int64, (n + 1)), !applicable(_ft_f95_18, Int64, (n + 1), n), hasmethod(_ft_f95_18, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f95_20(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1)
        s2 = s1 + _ft_w(p2_1)
        () -> s2
    end
end
function _ft_t95_20(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f95_20(Int64, (n + 1))
    local v4 = v2(Int64, Int64[n, 3])
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(v2, Int64, Int64[n, 3]), !applicable(v2, Int64, Int64[n, 3], n))
    h = 31h + _dw_bits(applicable(_ft_f95_20, Int64, (n + 1)), !applicable(_ft_f95_20, Int64, (n + 1), n), hasmethod(_ft_f95_20, Tuple{Type{Int64}, Int64}))
    return h
end

# function_type96: F0 = Function Function(int x, [core.List<core.int>]); F4 = int Function({int x}) Function(); F10 = List<Function> Function(int, [List<T> x]) Function(); F18 = void Function(List<Function> x) Function(); F21 = Function<A>(Function x) Function()
function _ft_f96_0(p1_1::Int64, p1_2::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(p1_2)
    return () -> s1
end
function _ft_t96_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f96_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f96_0((n + 1), Int64[n, 2])
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f96_0, (n + 1)), !applicable(_ft_f96_0, (n + 1), Int64[n, 2], n), hasmethod(_ft_f96_0, Tuple{Int64}))
    return h
end
function _ft_f96_4()
    s1 = Int64(0)
    return function (; x::Int64 = Int64(0))
        s2 = s1 + _ft_w(x)
        s2
    end
end
function _ft_t96_4(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f96_4()
    local v3 = v1()
    h = 31h + v3
    local v4 = v1(; x = (n + 2))
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v1), !applicable(v1, n))
    h = 31h + _dw_bits(applicable(_ft_f96_4), !applicable(_ft_f96_4, n), hasmethod(_ft_f96_4, Tuple{}))
    return h
end
function _ft_f96_10()
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t96_10(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f96_10()
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2), Int64[n, 3])
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Int64[n, 3], n), !applicable(v1, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f96_10), !applicable(_ft_f96_10, n), hasmethod(_ft_f96_10, Tuple{}))
    return h
end
function _ft_f96_18()
    s1 = Int64(0)
    return function (p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t96_18(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f96_18()
    local v3 = v1(Function[_ft_id])
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(v1, Function[_ft_id]), !applicable(v1, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f96_18), !applicable(_ft_f96_18, n), hasmethod(_ft_f96_18, Tuple{}))
    return h
end
function _ft_f96_21()
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Function)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t96_21(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f96_21()
    local v3 = v1(Int64, _ft_id)
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, _ft_id), !applicable(v1, Int64, _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f96_21), !applicable(_ft_f96_21, n), hasmethod(_ft_f96_21, Tuple{}))
    return h
end

# function_type97: F0 = Function Function({core.List<core.int> x}); F3 = int Function<A>(); F10 = List<Function> Function(int, [List<T> x]) Function(int x); F18 = void Function(List<Function> x) Function(int x); F21 = Function<A>(Function x) Function(int x)
function _ft_f97_0(; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(x)
    return () -> s1
end
function _ft_t97_0(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f97_0()
    h = 31h + Int64(v2 isa Function)
    local v3 = _ft_f97_0(; x = Int64[n, 1])
    h = 31h + Int64(v3 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f97_0), !applicable(_ft_f97_0, n), hasmethod(_ft_f97_0, Tuple{}))
    return h
end
function _ft_f97_3(::Type{A}) where {A}
    s1 = Int64(0)
    return s1
end
function _ft_t97_3(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f97_3(Int64)
    h = 31h + v1
    h = 31h + _dw_bits(applicable(_ft_f97_3, Int64), !applicable(_ft_f97_3, Int64, n), hasmethod(_ft_f97_3, Tuple{Type{Int64}}))
    return h
end
function _ft_f97_10(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t97_10(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f97_10((n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3), Int64[n, 4])
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Int64[n, 4], n), !applicable(v2, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f97_10, (n + 1)), !applicable(_ft_f97_10, (n + 1), n), hasmethod(_ft_f97_10, Tuple{Int64}))
    return h
end
function _ft_f97_18(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t97_18(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f97_18((n + 1))
    local v4 = v2(Function[_ft_id])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(v2, Function[_ft_id]), !applicable(v2, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f97_18, (n + 1)), !applicable(_ft_f97_18, (n + 1), n), hasmethod(_ft_f97_18, Tuple{Int64}))
    return h
end
function _ft_f97_21(p1_1::Int64)
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Function)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t97_21(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f97_21((n + 1))
    local v4 = v2(Int64, _ft_id)
    h = 31h + v4
    h = 31h + _dw_bits(applicable(v2, Int64, _ft_id), !applicable(v2, Int64, _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f97_21, (n + 1)), !applicable(_ft_f97_21, (n + 1), n), hasmethod(_ft_f97_21, Tuple{Int64}))
    return h
end

# function_type98: F0 = Function Function(int, {core.List<core.int> x}); F3 = int Function<A>(A x); F10 = List<Function> Function(int, [List<T> x]) Function<B extends core.int>(); F18 = void Function(List<Function> x) Function<B extends core.int>(); F21 = Function<A>(Function x) Function<B extends core.int>()
function _ft_f98_0(p1_1::Int64; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return () -> s1
end
function _ft_t98_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f98_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f98_0((n + 1); x = Int64[n, 2])
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f98_0, (n + 1)), !applicable(_ft_f98_0, (n + 1), n), hasmethod(_ft_f98_0, Tuple{Int64}))
    return h
end
function _ft_f98_3(::Type{A}, p1_1::A) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t98_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f98_3(Int64, (n + 1))
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f98_3, Int64, (n + 1)), !applicable(_ft_f98_3, Int64, (n + 1), n), hasmethod(_ft_f98_3, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f98_10(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t98_10(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f98_10(Int64)
    local v4 = v1((n + 2))
    h = 31h + Int64(length(v4))
    local v5 = v1((n + 2), Int64[n, 3])
    h = 31h + Int64(length(v5))
    h = 31h + _dw_bits(applicable(v1, (n + 2)), !applicable(v1, (n + 2), Int64[n, 3], n), !applicable(v1, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f98_10, Int64), !applicable(_ft_f98_10, Int64, n), hasmethod(_ft_f98_10, Tuple{Type{Int64}}))
    return h
end
function _ft_f98_18(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t98_18(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f98_18(Int64)
    local v3 = v1(Function[_ft_id])
    h = 31h + Int64(v3 === nothing)
    h = 31h + _dw_bits(applicable(v1, Function[_ft_id]), !applicable(v1, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f98_18, Int64), !applicable(_ft_f98_18, Int64, n), hasmethod(_ft_f98_18, Tuple{Type{Int64}}))
    return h
end
function _ft_f98_21(::Type{B}) where {B<:Integer}
    s1 = Int64(0)
    return function (ta2::Type, p2_1::Function)
        s2 = s1 + _ft_w(p2_1)
        s2
    end
end
function _ft_t98_21(n::Int64)
    local h = Int64(0)
    local v1 = _ft_f98_21(Int64)
    local v3 = v1(Int64, _ft_id)
    h = 31h + v3
    h = 31h + _dw_bits(applicable(v1, Int64, _ft_id), !applicable(v1, Int64, _ft_id, n))
    h = 31h + _dw_bits(applicable(_ft_f98_21, Int64), !applicable(_ft_f98_21, Int64, n), hasmethod(_ft_f98_21, Tuple{Type{Int64}}))
    return h
end

# function_type99: F0 = Function Function(int y, {core.List<core.int> x}); F2 = Function({Function x}); F3 = int Function<A>(List<A> x); F10 = List<Function> Function(int, [List<T> x]) Function<B extends core.int>( int x, ); F22 = void Function<A>(List<Function> x) Function<B extends core.int>(int x)
function _ft_f99_0(p1_1::Int64; x::Vector{Int64} = Int64[])
    s1 = Int64(0) + _ft_w(p1_1) + _ft_w(x)
    return () -> s1
end
function _ft_t99_0(n::Int64)
    local h = Int64(0)
    local v3 = _ft_f99_0((n + 1))
    h = 31h + Int64(v3 isa Function)
    local v4 = _ft_f99_0((n + 1); x = Int64[n, 2])
    h = 31h + Int64(v4 isa Function)
    h = 31h + _dw_bits(applicable(_ft_f99_0, (n + 1)), !applicable(_ft_f99_0, (n + 1), n), hasmethod(_ft_f99_0, Tuple{Int64}))
    return h
end
function _ft_f99_2(; x::Function = _ft_id)
    s1 = Int64(0) + _ft_w(x)
    return s1
end
function _ft_t99_2(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f99_2()
    h = 31h + v2
    local v3 = _ft_f99_2(; x = _ft_id)
    h = 31h + v3
    h = 31h + _dw_bits(applicable(_ft_f99_2), !applicable(_ft_f99_2, n), hasmethod(_ft_f99_2, Tuple{}))
    return h
end
function _ft_f99_3(::Type{A}, p1_1::Vector{A}) where {A}
    s1 = Int64(0) + _ft_w(p1_1)
    return s1
end
function _ft_t99_3(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f99_3(Int64, Int64[n, 1])
    h = 31h + v2
    h = 31h + _dw_bits(applicable(_ft_f99_3, Int64, Int64[n, 1]), !applicable(_ft_f99_3, Int64, Int64[n, 1], n), hasmethod(_ft_f99_3, Tuple{Type{Int64}, Vector{Int64}}))
    return h
end
function _ft_f99_10(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (p2_1::Int64, p2_2::Vector{Int64} = Int64[])
        s2 = s1 + _ft_w(p2_1) + _ft_w(p2_2)
        Function[_ft_id]
    end
end
function _ft_t99_10(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f99_10(Int64, (n + 1))
    local v5 = v2((n + 3))
    h = 31h + Int64(length(v5))
    local v6 = v2((n + 3), Int64[n, 4])
    h = 31h + Int64(length(v6))
    h = 31h + _dw_bits(applicable(v2, (n + 3)), !applicable(v2, (n + 3), Int64[n, 4], n), !applicable(v2, (n + 101), Bool[true]))
    h = 31h + _dw_bits(applicable(_ft_f99_10, Int64, (n + 1)), !applicable(_ft_f99_10, Int64, (n + 1), n), hasmethod(_ft_f99_10, Tuple{Type{Int64}, Int64}))
    return h
end
function _ft_f99_22(::Type{B}, p1_1::Int64) where {B<:Integer}
    s1 = Int64(0) + _ft_w(p1_1)
    return function (ta2::Type, p2_1::Vector{Function})
        s2 = s1 + _ft_w(p2_1)
        nothing
    end
end
function _ft_t99_22(n::Int64)
    local h = Int64(0)
    local v2 = _ft_f99_22(Int64, (n + 1))
    local v4 = v2(Int64, Function[_ft_id])
    h = 31h + Int64(v4 === nothing)
    h = 31h + _dw_bits(applicable(v2, Int64, Function[_ft_id]), !applicable(v2, Int64, Function[_ft_id], n))
    h = 31h + _dw_bits(applicable(_ft_f99_22, Int64, (n + 1)), !applicable(_ft_f99_22, Int64, (n + 1), n), hasmethod(_ft_f99_22, Tuple{Type{Int64}, Int64}))
    return h
end

_g("dart_function_type", Any[
    ("function_type0", (n::Int64) -> _ft_mix(_ft_t0_1(n), _ft_t0_2(n), _ft_t0_3(n), _ft_t0_11(n), _ft_t0_23(n)), Int64(1)),
    ("function_type1", (n::Int64) -> _ft_mix(_ft_t1_3(n), _ft_t1_4(n), _ft_t1_11(n), _ft_t1_19(n), _ft_t1_22(n)), Int64(1)),
    ("function_type2", (n::Int64) -> _ft_mix(_ft_t2_0(n), _ft_t2_5(n), _ft_t2_11(n), _ft_t2_19(n), _ft_t2_22(n)), Int64(1)),
    ("function_type3", (n::Int64) -> _ft_mix(_ft_t3_0(n), _ft_t3_5(n), _ft_t3_11(n), _ft_t3_19(n), _ft_t3_22(n)), Int64(1)),
    ("function_type4", (n::Int64) -> _ft_mix(_ft_t4_2(n), _ft_t4_4(n), _ft_t4_17(n), _ft_t4_19(n), _ft_t4_21(n)), Int64(1)),
    ("function_type5", (n::Int64) -> _ft_mix(_ft_t5_0(n), _ft_t5_4(n), _ft_t5_9(n), _ft_t5_19(n), _ft_t5_22(n)), Int64(1)),
    ("function_type6", (n::Int64) -> _ft_mix(_ft_t6_0(n), _ft_t6_4(n), _ft_t6_9(n), _ft_t6_19(n), _ft_t6_22(n)), Int64(1)),
    ("function_type7", (n::Int64) -> _ft_mix(_ft_t7_0(n), _ft_t7_4(n), _ft_t7_9(n), _ft_t7_18(n), _ft_t7_19(n)), Int64(1)),
    ("function_type8", (n::Int64) -> _ft_mix(_ft_t8_0(n), _ft_t8_4(n), _ft_t8_17(n), _ft_t8_20(n), _ft_t8_21(n)), Int64(1)),
    ("function_type9", (n::Int64) -> _ft_mix(_ft_t9_0(n), _ft_t9_4(n), _ft_t9_17(n), _ft_t9_20(n), _ft_t9_23(n)), Int64(1)),
    ("function_type10", (n::Int64) -> _ft_mix(_ft_t10_0(n), _ft_t10_4(n), _ft_t10_17(n), _ft_t10_20(n), _ft_t10_21(n)), Int64(1)),
    ("function_type11", (n::Int64) -> _ft_mix(_ft_t11_0(n), _ft_t11_4(n), _ft_t11_17(n), _ft_t11_20(n), _ft_t11_23(n)), Int64(1)),
    ("function_type12", (n::Int64) -> _ft_mix(_ft_t12_0(n), _ft_t12_3(n), _ft_t12_4(n), _ft_t12_11(n), _ft_t12_23(n)), Int64(1)),
    ("function_type13", (n::Int64) -> _ft_mix(_ft_t13_0(n), _ft_t13_8(n), _ft_t13_11(n), _ft_t13_18(n), _ft_t13_22(n)), Int64(1)),
    ("function_type14", (n::Int64) -> _ft_mix(_ft_t14_0(n), _ft_t14_4(n), _ft_t14_11(n), _ft_t14_17(n), _ft_t14_23(n)), Int64(1)),
    ("function_type15", (n::Int64) -> _ft_mix(_ft_t15_4(n), _ft_t15_8(n), _ft_t15_11(n), _ft_t15_18(n), _ft_t15_22(n)), Int64(1)),
    ("function_type16", (n::Int64) -> _ft_mix(_ft_t16_0(n), _ft_t16_3(n), _ft_t16_11(n), _ft_t16_16(n), _ft_t16_23(n)), Int64(1)),
    ("function_type17", (n::Int64) -> _ft_mix(_ft_t17_4(n), _ft_t17_11(n), _ft_t17_16(n), _ft_t17_21(n), _ft_t17_23(n)), Int64(1)),
    ("function_type18", (n::Int64) -> _ft_mix(_ft_t18_0(n), _ft_t18_4(n), _ft_t18_11(n), _ft_t18_16(n), _ft_t18_23(n)), Int64(1)),
    ("function_type19", (n::Int64) -> _ft_mix(_ft_t19_0(n), _ft_t19_11(n), _ft_t19_16(n), _ft_t19_21(n), _ft_t19_23(n)), Int64(1)),
    ("function_type20", (n::Int64) -> _ft_mix(_ft_t20_0(n), _ft_t20_2(n), _ft_t20_19(n), _ft_t20_22(n), _ft_t20_23(n)), Int64(1)),
    ("function_type21", (n::Int64) -> _ft_mix(_ft_t21_2(n), _ft_t21_4(n), _ft_t21_19(n), _ft_t21_22(n), _ft_t21_23(n)), Int64(1)),
    ("function_type22", (n::Int64) -> _ft_mix(_ft_t22_0(n), _ft_t22_1(n), _ft_t22_2(n), _ft_t22_19(n), _ft_t22_22(n)), Int64(1)),
    ("function_type23", (n::Int64) -> _ft_mix(_ft_t23_0(n), _ft_t23_2(n), _ft_t23_11(n), _ft_t23_19(n), _ft_t23_22(n)), Int64(1)),
    ("function_type24", (n::Int64) -> _ft_mix(_ft_t24_11(n), _ft_t24_17(n), _ft_t24_19(n), _ft_t24_21(n), _ft_t24_23(n)), Int64(1)),
    ("function_type25", (n::Int64) -> _ft_mix(_ft_t25_3(n), _ft_t25_11(n), _ft_t25_19(n), _ft_t25_21(n), _ft_t25_23(n)), Int64(1)),
    ("function_type26", (n::Int64) -> _ft_mix(_ft_t26_3(n), _ft_t26_11(n), _ft_t26_19(n), _ft_t26_21(n), _ft_t26_22(n)), Int64(1)),
    ("function_type27", (n::Int64) -> _ft_mix(_ft_t27_3(n), _ft_t27_11(n), _ft_t27_19(n), _ft_t27_21(n), _ft_t27_22(n)), Int64(1)),
    ("function_type28", (n::Int64) -> _ft_mix(_ft_t28_11(n), _ft_t28_17(n), _ft_t28_18(n), _ft_t28_22(n), _ft_t28_23(n)), Int64(1)),
    ("function_type29", (n::Int64) -> _ft_mix(_ft_t29_3(n), _ft_t29_11(n), _ft_t29_20(n), _ft_t29_22(n), _ft_t29_23(n)), Int64(1)),
    ("function_type30", (n::Int64) -> _ft_mix(_ft_t30_3(n), _ft_t30_4(n), _ft_t30_11(n), _ft_t30_18(n), _ft_t30_22(n)), Int64(1)),
    ("function_type31", (n::Int64) -> _ft_mix(_ft_t31_3(n), _ft_t31_4(n), _ft_t31_11(n), _ft_t31_20(n), _ft_t31_22(n)), Int64(1)),
    ("function_type32", (n::Int64) -> _ft_mix(_ft_t32_4(n), _ft_t32_13(n), _ft_t32_19(n), _ft_t32_22(n), _ft_t32_23(n)), Int64(1)),
    ("function_type33", (n::Int64) -> _ft_mix(_ft_t33_4(n), _ft_t33_11(n), _ft_t33_13(n), _ft_t33_19(n), _ft_t33_23(n)), Int64(1)),
    ("function_type34", (n::Int64) -> _ft_mix(_ft_t34_0(n), _ft_t34_1(n), _ft_t34_3(n), _ft_t34_19(n), _ft_t34_22(n)), Int64(1)),
    ("function_type35", (n::Int64) -> _ft_mix(_ft_t35_3(n), _ft_t35_4(n), _ft_t35_13(n), _ft_t35_19(n), _ft_t35_22(n)), Int64(1)),
    ("function_type36", (n::Int64) -> _ft_mix(_ft_t36_0(n), _ft_t36_4(n), _ft_t36_19(n), _ft_t36_22(n), _ft_t36_23(n)), Int64(1)),
    ("function_type37", (n::Int64) -> _ft_mix(_ft_t37_2(n), _ft_t37_4(n), _ft_t37_19(n), _ft_t37_22(n), _ft_t37_23(n)), Int64(1)),
    ("function_type38", (n::Int64) -> _ft_mix(_ft_t38_0(n), _ft_t38_2(n), _ft_t38_4(n), _ft_t38_19(n), _ft_t38_22(n)), Int64(1)),
    ("function_type39", (n::Int64) -> _ft_mix(_ft_t39_0(n), _ft_t39_4(n), _ft_t39_13(n), _ft_t39_19(n), _ft_t39_22(n)), Int64(1)),
    ("function_type40", (n::Int64) -> _ft_mix(_ft_t40_9(n), _ft_t40_16(n), _ft_t40_18(n), _ft_t40_22(n), _ft_t40_23(n)), Int64(1)),
    ("function_type41", (n::Int64) -> _ft_mix(_ft_t41_9(n), _ft_t41_16(n), _ft_t41_18(n), _ft_t41_22(n), _ft_t41_23(n)), Int64(1)),
    ("function_type42", (n::Int64) -> _ft_mix(_ft_t42_0(n), _ft_t42_9(n), _ft_t42_16(n), _ft_t42_18(n), _ft_t42_22(n)), Int64(1)),
    ("function_type43", (n::Int64) -> _ft_mix(_ft_t43_0(n), _ft_t43_9(n), _ft_t43_16(n), _ft_t43_18(n), _ft_t43_22(n)), Int64(1)),
    ("function_type44", (n::Int64) -> _ft_mix(_ft_t44_3(n), _ft_t44_4(n), _ft_t44_12(n), _ft_t44_14(n), _ft_t44_23(n)), Int64(1)),
    ("function_type45", (n::Int64) -> _ft_mix(_ft_t45_3(n), _ft_t45_4(n), _ft_t45_12(n), _ft_t45_14(n), _ft_t45_23(n)), Int64(1)),
    ("function_type46", (n::Int64) -> _ft_mix(_ft_t46_1(n), _ft_t46_3(n), _ft_t46_4(n), _ft_t46_14(n), _ft_t46_16(n)), Int64(1)),
    ("function_type47", (n::Int64) -> _ft_mix(_ft_t47_1(n), _ft_t47_3(n), _ft_t47_4(n), _ft_t47_14(n), _ft_t47_16(n)), Int64(1)),
    ("function_type48", (n::Int64) -> _ft_mix(_ft_t48_2(n), _ft_t48_3(n), _ft_t48_4(n), _ft_t48_9(n), _ft_t48_22(n)), Int64(1)),
    ("function_type49", (n::Int64) -> _ft_mix(_ft_t49_0(n), _ft_t49_3(n), _ft_t49_4(n), _ft_t49_9(n), _ft_t49_23(n)), Int64(1)),
    ("function_type50", (n::Int64) -> _ft_mix(_ft_t50_0(n), _ft_t50_3(n), _ft_t50_4(n), _ft_t50_9(n), _ft_t50_22(n)), Int64(1)),
    ("function_type51", (n::Int64) -> _ft_mix(_ft_t51_0(n), _ft_t51_3(n), _ft_t51_4(n), _ft_t51_9(n), _ft_t51_22(n)), Int64(1)),
    ("function_type52", (n::Int64) -> _ft_mix(_ft_t52_3(n), _ft_t52_4(n), _ft_t52_9(n), _ft_t52_16(n), _ft_t52_22(n)), Int64(1)),
    ("function_type53", (n::Int64) -> _ft_mix(_ft_t53_3(n), _ft_t53_4(n), _ft_t53_14(n), _ft_t53_17(n), _ft_t53_22(n)), Int64(1)),
    ("function_type54", (n::Int64) -> _ft_mix(_ft_t54_0(n), _ft_t54_3(n), _ft_t54_9(n), _ft_t54_16(n), _ft_t54_22(n)), Int64(1)),
    ("function_type55", (n::Int64) -> _ft_mix(_ft_t55_0(n), _ft_t55_3(n), _ft_t55_14(n), _ft_t55_16(n), _ft_t55_22(n)), Int64(1)),
    ("function_type56", (n::Int64) -> _ft_mix(_ft_t56_1(n), _ft_t56_3(n), _ft_t56_14(n), _ft_t56_16(n), _ft_t56_21(n)), Int64(1)),
    ("function_type57", (n::Int64) -> _ft_mix(_ft_t57_4(n), _ft_t57_13(n), _ft_t57_14(n), _ft_t57_17(n), _ft_t57_21(n)), Int64(1)),
    ("function_type58", (n::Int64) -> _ft_mix(_ft_t58_0(n), _ft_t58_4(n), _ft_t58_14(n), _ft_t58_17(n), _ft_t58_21(n)), Int64(1)),
    ("function_type59", (n::Int64) -> _ft_mix(_ft_t59_4(n), _ft_t59_13(n), _ft_t59_14(n), _ft_t59_17(n), _ft_t59_21(n)), Int64(1)),
    ("function_type60", (n::Int64) -> _ft_mix(_ft_t60_2(n), _ft_t60_4(n), _ft_t60_14(n), _ft_t60_16(n), _ft_t60_20(n)), Int64(1)),
    ("function_type61", (n::Int64) -> _ft_mix(_ft_t61_0(n), _ft_t61_4(n), _ft_t61_14(n), _ft_t61_16(n), _ft_t61_20(n)), Int64(1)),
    ("function_type62", (n::Int64) -> _ft_mix(_ft_t62_0(n), _ft_t62_4(n), _ft_t62_14(n), _ft_t62_16(n), _ft_t62_20(n)), Int64(1)),
    ("function_type63", (n::Int64) -> _ft_mix(_ft_t63_0(n), _ft_t63_4(n), _ft_t63_14(n), _ft_t63_16(n), _ft_t63_20(n)), Int64(1)),
    ("function_type64", (n::Int64) -> _ft_mix(_ft_t64_0(n), _ft_t64_3(n), _ft_t64_12(n), _ft_t64_17(n), _ft_t64_22(n)), Int64(1)),
    ("function_type65", (n::Int64) -> _ft_mix(_ft_t65_0(n), _ft_t65_3(n), _ft_t65_12(n), _ft_t65_17(n), _ft_t65_22(n)), Int64(1)),
    ("function_type66", (n::Int64) -> _ft_mix(_ft_t66_0(n), _ft_t66_3(n), _ft_t66_5(n), _ft_t66_17(n), _ft_t66_22(n)), Int64(1)),
    ("function_type67", (n::Int64) -> _ft_mix(_ft_t67_1(n), _ft_t67_3(n), _ft_t67_5(n), _ft_t67_17(n), _ft_t67_22(n)), Int64(1)),
    ("function_type68", (n::Int64) -> _ft_mix(_ft_t68_3(n), _ft_t68_16(n), _ft_t68_19(n), _ft_t68_21(n), _ft_t68_22(n)), Int64(1)),
    ("function_type69", (n::Int64) -> _ft_mix(_ft_t69_0(n), _ft_t69_3(n), _ft_t69_14(n), _ft_t69_16(n), _ft_t69_22(n)), Int64(1)),
    ("function_type70", (n::Int64) -> _ft_mix(_ft_t70_0(n), _ft_t70_3(n), _ft_t70_16(n), _ft_t70_21(n), _ft_t70_22(n)), Int64(1)),
    ("function_type71", (n::Int64) -> _ft_mix(_ft_t71_0(n), _ft_t71_3(n), _ft_t71_14(n), _ft_t71_16(n), _ft_t71_22(n)), Int64(1)),
    ("function_type72", (n::Int64) -> _ft_mix(_ft_t72_3(n), _ft_t72_14(n), _ft_t72_16(n), _ft_t72_19(n), _ft_t72_22(n)), Int64(1)),
    ("function_type73", (n::Int64) -> _ft_mix(_ft_t73_0(n), _ft_t73_14(n), _ft_t73_16(n), _ft_t73_19(n), _ft_t73_22(n)), Int64(1)),
    ("function_type74", (n::Int64) -> _ft_mix(_ft_t74_0(n), _ft_t74_14(n), _ft_t74_16(n), _ft_t74_19(n), _ft_t74_22(n)), Int64(1)),
    ("function_type75", (n::Int64) -> _ft_mix(_ft_t75_0(n), _ft_t75_14(n), _ft_t75_16(n), _ft_t75_19(n), _ft_t75_22(n)), Int64(1)),
    ("function_type76", (n::Int64) -> _ft_mix(_ft_t76_0(n), _ft_t76_14(n), _ft_t76_17(n), _ft_t76_19(n), _ft_t76_22(n)), Int64(1)),
    ("function_type77", (n::Int64) -> _ft_mix(_ft_t77_0(n), _ft_t77_3(n), _ft_t77_14(n), _ft_t77_17(n), _ft_t77_22(n)), Int64(1)),
    ("function_type78", (n::Int64) -> _ft_mix(_ft_t78_0(n), _ft_t78_3(n), _ft_t78_14(n), _ft_t78_17(n), _ft_t78_22(n)), Int64(1)),
    ("function_type79", (n::Int64) -> _ft_mix(_ft_t79_0(n), _ft_t79_3(n), _ft_t79_14(n), _ft_t79_17(n), _ft_t79_22(n)), Int64(1)),
    ("function_type80", (n::Int64) -> _ft_mix(_ft_t80_0(n), _ft_t80_16(n), _ft_t80_19(n), _ft_t80_20(n), _ft_t80_22(n)), Int64(1)),
    ("function_type81", (n::Int64) -> _ft_mix(_ft_t81_0(n), _ft_t81_16(n), _ft_t81_19(n), _ft_t81_21(n), _ft_t81_22(n)), Int64(1)),
    ("function_type82", (n::Int64) -> _ft_mix(_ft_t82_0(n), _ft_t82_3(n), _ft_t82_6(n), _ft_t82_16(n), _ft_t82_22(n)), Int64(1)),
    ("function_type83", (n::Int64) -> _ft_mix(_ft_t83_0(n), _ft_t83_16(n), _ft_t83_19(n), _ft_t83_21(n), _ft_t83_22(n)), Int64(1)),
    ("function_type84", (n::Int64) -> _ft_mix(_ft_t84_0(n), _ft_t84_3(n), _ft_t84_14(n), _ft_t84_16(n), _ft_t84_22(n)), Int64(1)),
    ("function_type85", (n::Int64) -> _ft_mix(_ft_t85_2(n), _ft_t85_3(n), _ft_t85_6(n), _ft_t85_14(n), _ft_t85_22(n)), Int64(1)),
    ("function_type86", (n::Int64) -> _ft_mix(_ft_t86_0(n), _ft_t86_2(n), _ft_t86_3(n), _ft_t86_14(n), _ft_t86_22(n)), Int64(1)),
    ("function_type87", (n::Int64) -> _ft_mix(_ft_t87_2(n), _ft_t87_3(n), _ft_t87_6(n), _ft_t87_14(n), _ft_t87_22(n)), Int64(1)),
    ("function_type88", (n::Int64) -> _ft_mix(_ft_t88_0(n), _ft_t88_3(n), _ft_t88_14(n), _ft_t88_15(n), _ft_t88_21(n)), Int64(1)),
    ("function_type89", (n::Int64) -> _ft_mix(_ft_t89_0(n), _ft_t89_3(n), _ft_t89_14(n), _ft_t89_15(n), _ft_t89_21(n)), Int64(1)),
    ("function_type90", (n::Int64) -> _ft_mix(_ft_t90_0(n), _ft_t90_3(n), _ft_t90_14(n), _ft_t90_15(n), _ft_t90_21(n)), Int64(1)),
    ("function_type91", (n::Int64) -> _ft_mix(_ft_t91_0(n), _ft_t91_3(n), _ft_t91_14(n), _ft_t91_15(n), _ft_t91_21(n)), Int64(1)),
    ("function_type92", (n::Int64) -> _ft_mix(_ft_t92_0(n), _ft_t92_2(n), _ft_t92_5(n), _ft_t92_19(n), _ft_t92_20(n)), Int64(1)),
    ("function_type93", (n::Int64) -> _ft_mix(_ft_t93_2(n), _ft_t93_3(n), _ft_t93_10(n), _ft_t93_18(n), _ft_t93_20(n)), Int64(1)),
    ("function_type94", (n::Int64) -> _ft_mix(_ft_t94_2(n), _ft_t94_3(n), _ft_t94_5(n), _ft_t94_19(n), _ft_t94_20(n)), Int64(1)),
    ("function_type95", (n::Int64) -> _ft_mix(_ft_t95_2(n), _ft_t95_3(n), _ft_t95_10(n), _ft_t95_18(n), _ft_t95_20(n)), Int64(1)),
    ("function_type96", (n::Int64) -> _ft_mix(_ft_t96_0(n), _ft_t96_4(n), _ft_t96_10(n), _ft_t96_18(n), _ft_t96_21(n)), Int64(1)),
    ("function_type97", (n::Int64) -> _ft_mix(_ft_t97_0(n), _ft_t97_3(n), _ft_t97_10(n), _ft_t97_18(n), _ft_t97_21(n)), Int64(1)),
    ("function_type98", (n::Int64) -> _ft_mix(_ft_t98_0(n), _ft_t98_3(n), _ft_t98_10(n), _ft_t98_18(n), _ft_t98_21(n)), Int64(1)),
    ("function_type99", (n::Int64) -> _ft_mix(_ft_t99_0(n), _ft_t99_2(n), _ft_t99_3(n), _ft_t99_10(n), _ft_t99_22(n)), Int64(1)),
])

# ---- dart2wasm's tests at the pin, tests/language/super -------------------------------------------
# Each case is named by the dart file's path under tests/language/super, less `_test`. A dart class
# is an abstract type (its subclasses' supertype) and a struct; `super.m(...)` is Julia's
# `invoke(m, Tuple{Super,...}, this, ...)`; an inherited field is a field of the subclass's struct.
# shared: super[i], super[i] = v, super[i] += d and super[i]++ through invoke of Base's index methods
_su_sget(::Type{S}, o, i::Int64) where {S} = invoke(getindex, Tuple{S,Int64}, o, i)
_su_sset(::Type{S}, o, i::Int64, v::Int64) where {S} = (invoke(setindex!, Tuple{S,Int64,Int64}, o, v, i); v)
_su_sadd(::Type{S}, o, i::Int64, d::Int64) where {S} = _su_sset(S, o, i, (_su_sget(S, o, i)::Int64) + d)
_su_spostinc(::Type{S}, o, i::Int64) where {S} = (old = _su_sget(S, o, i)::Int64; _su_sset(S, o, i, old + 1); old)
_su_index_seq(::Type{S}, o) where {S} = _dw_bits(
    _su_sset(S, o, 0, 42) == 42, _su_sget(S, o, 0) == 42, _su_sadd(S, o, 0, 1) == 43, _su_sget(S, o, 0) == 43,
    _su_spostinc(S, o, 0) == 43, _su_sget(S, o, 0) == 44, _su_sset(S, o, 0, 2) == 2, _su_sget(S, o, 0) == 2,
    _su_sadd(S, o, 0, 1) == 3, _su_sget(S, o, 0) == 3, _su_spostinc(S, o, 0) == 3, _su_sget(S, o, 0) == 4)
const _SU_NSM_SET = Symbol("[]=")
const _SU_NSM_GET = Symbol("[]")
# abstract_method: a super call through an abstract redeclaration reaches the grandparent's method
abstract type _SuAmBase end
abstract type _SuAmA <: _SuAmBase end
struct _SuAmB <: _SuAmA end
_su_am_foo(::_SuAmBase) = Int64(42)
_su_am_foo(::_SuAmB) = Int64(42)
_su_am_test_super_call(b::_SuAmB) = invoke(_su_am_foo, Tuple{_SuAmA}, b)
# all_named_constructor: a constructor with an optional default calls its supertype's, also defaulted
const _SU_ANC_RES = Ref(Int64(0))
abstract type _SuAncA end
_su_anc_a_init(v::Int64 = Int64(1)) = (_SU_ANC_RES[] += v; nothing)
struct _SuAncB <: _SuAncA
    _SuAncB(v::Int64 = Int64(2)) = (_su_anc_a_init(); _SU_ANC_RES[] += v; new())
end
# assign_runtime: a supertype's field written through the subtype and through a super setter
abstract type _SuAsA end
mutable struct _SuAsC <: _SuAsA
    x::Int64
end
_SuAsC() = _SuAsC(Int64(-1))
_su_as_set_x!(o::_SuAsA, v::Int64) = (o.x = v; nothing)
_su_as_setx!(c::_SuAsC, v::Int64) = invoke(_su_as_set_x!, Tuple{_SuAsA,Int64}, c, v)
# bound_closure: super methods with optional positional and keyword defaults taken as values
abstract type _SuBcA end
struct _SuBcB <: _SuBcA end
@noinline _su_bc_confuse(f) = f
_su_bc_bar(::_SuBcA, optional = 1) = 498 + optional
_su_bc_bar2(::_SuBcA; namedOptional = 2) = 40 + namedOptional
_su_bc_bar3(::_SuBcA, x, optional = 3) = x + 498 + optional
_su_bc_bar4(::_SuBcA, x; namedOptional = 4) = 422 + x + namedOptional
_su_bc_add(::_SuBcA, optional = 33) = 1234 + optional
_su_bc_trim(::_SuBcA; namedOptional = 22) = 1313 + namedOptional
_su_bc_sublist(::_SuBcA, x, optional = 44) = 4321 + optional + x
_su_bc_split(::_SuBcA, x; onMatch = 55, onNonMatch = 66) = 111 + x + onMatch + onNonMatch
_su_bc_bar(::_SuBcB, optional = nothing) = -1
_su_bc_bar2(::_SuBcB; namedOptional = nothing) = -1
_su_bc_bar3(::_SuBcB, x, optional = nothing) = -1
_su_bc_bar4(::_SuBcB, x; namedOptional = nothing) = -1
_su_bc_add(::_SuBcB, optional = 33) = -1
_su_bc_trim(::_SuBcB; namedOptional = 22) = -1
_su_bc_sublist(::_SuBcB, x, optional = 44) = -1
_su_bc_split(::_SuBcB, x; onMatch = 55, onNonMatch = 66) = -1
function _su_bc_super_bar(b::_SuBcB)
    f() = invoke(_su_bc_bar, Tuple{_SuBcA}, b)
    f(o) = invoke(_su_bc_bar, Tuple{_SuBcA,Any}, b, o)
    return f
end
_su_bc_super_bar2(b::_SuBcB) = (; kw...) -> invoke(_su_bc_bar2, Tuple{_SuBcA}, b; kw...)
function _su_bc_super_bar3(b::_SuBcB)
    f(x) = invoke(_su_bc_bar3, Tuple{_SuBcA,Any}, b, x)
    f(x, o) = invoke(_su_bc_bar3, Tuple{_SuBcA,Any,Any}, b, x, o)
    return f
end
_su_bc_super_bar4(b::_SuBcB) = (x; kw...) -> invoke(_su_bc_bar4, Tuple{_SuBcA,Any}, b, x; kw...)
function _su_bc_super_add(b::_SuBcB)
    f() = invoke(_su_bc_add, Tuple{_SuBcA}, b)
    f(o) = invoke(_su_bc_add, Tuple{_SuBcA,Any}, b, o)
    return f
end
_su_bc_super_trim(b::_SuBcB) = (; kw...) -> invoke(_su_bc_trim, Tuple{_SuBcA}, b; kw...)
function _su_bc_super_sublist(b::_SuBcB)
    f(x) = invoke(_su_bc_sublist, Tuple{_SuBcA,Any}, b, x)
    f(x, o) = invoke(_su_bc_sublist, Tuple{_SuBcA,Any,Any}, b, x, o)
    return f
end
_su_bc_super_split(b::_SuBcB) = (x; kw...) -> invoke(_su_bc_split, Tuple{_SuBcA,Any}, b, x; kw...)
# call: an overriding method calls the supertype's, mutating an inherited field
abstract type _SuCaA end
mutable struct _SuCaB <: _SuCaA
    field::Int64
end
_SuCaB() = _SuCaB(Int64(0))
_su_ca_incr!(a::_SuCaA) = (a.field += 1; nothing)
_su_ca_incr!(b::_SuCaB) = (b.field += 1; invoke(_su_ca_incr!, Tuple{_SuCaA}, b))
_su_ca_timesx(::_SuCaA, v) = v * 2
_su_ca_timesx(b::_SuCaB, v) = invoke(_su_ca_timesx, Tuple{_SuCaA,Any}, b, v) * 3
# call2: a super call in a generic subtype, and a super field holding a closure called through super
abstract type _SuC2C{T} end
struct _SuC2D{T} <: _SuC2C{T} end
_su_c2_foo(::_SuC2C{T}, a) where {T} = nothing
_su_c2_foo(d::_SuC2D{T}, a) where {T} = invoke(_su_c2_foo, Tuple{_SuC2C{T},Any}, d, a)
const _SU_C2_VALUE = Ref(Int64(-1))
abstract type _SuC2A end
struct _SuC2B{F} <: _SuC2A
    foo::F
end
_SuC2B() = _SuC2B((x::Int64) -> (_SU_C2_VALUE[] = x + 1))
_su_c2_getfoo(a::_SuC2A) = a.foo
_su_c2_m(b::_SuC2B, x::Int64) = (invoke(_su_c2_getfoo, Tuple{_SuC2A}, b)(x); nothing)
# call3_runtime: a final field with an initializer inherited by subtypes with default and named
# constructors
abstract type _SuC3A end
struct _SuC3B <: _SuC3A
    foo::Int64
end
_SuC3B() = _SuC3B(Int64(499))
struct _SuC3B2 <: _SuC3A
    foo::Int64
    x::Union{Nothing,Int64}
end
_SuC3B2() = _SuC3B2(Int64(499), nothing)
_su_c3_b2_named() = _SuC3B2(Int64(499), Int64(499))
abstract type _SuC3C end
struct _SuC3D <: _SuC3C
    foo::Int64
end
_SuC3D() = _SuC3D(Int64(499))
struct _SuC3D2 <: _SuC3C
    foo::Int64
    x::Union{Nothing,Int64}
end
_SuC3D2() = _SuC3D2(Int64(499), nothing)
_su_c3_d2_named() = _SuC3D2(Int64(499), Int64(499))
# call4: super calls of members the supertype only declares reach its noSuchMethod forwarder, which
# calls the subtype's noSuchMethod
abstract type _SuC4C end
struct _SuC4D <: _SuC4C end
_su_c4_nsm(::_SuC4C, im::Symbol) = true
_su_c4_nsm(::_SuC4D, im::Symbol) = false
_su_c4_foo(o::_SuC4C) = _su_c4_nsm(o, :foo)
_su_c4_bar(o::_SuC4C, a::Int64) = _su_c4_nsm(o, :bar)
_su_c4_baz(o::_SuC4C; b::Union{Nothing,Int64} = nothing) = _su_c4_nsm(o, :baz)
_su_c4_boz(o::_SuC4C, a::Int64; c::Union{Nothing,Int64} = nothing) = _su_c4_nsm(o, :boz)
_su_c4_test1(d::_SuC4D) = invoke(_su_c4_foo, Tuple{_SuC4C}, d)
_su_c4_test2(d::_SuC4D) = invoke(_su_c4_bar, Tuple{_SuC4C,Int64}, d, Int64(1))
_su_c4_test3(d::_SuC4D) = invoke(_su_c4_baz, Tuple{_SuC4C}, d; b = Int64(2))
_su_c4_test4(d::_SuC4D) = invoke(_su_c4_boz, Tuple{_SuC4C,Int64}, d, Int64(1); c = Int64(2))
# closure: closures over an overridden getter, through the receiver and through super
abstract type _SuClSuper end
struct _SuClSub <: _SuClSuper
    superX::String
    subX::String
end
_su_cl_x(o::_SuClSuper) = o.superX
_su_cl_x(o::_SuClSub) = o.subX
_su_cl_build(o::_SuClSub) = (() -> _su_cl_x(o), () -> _su_cl_x(o), () -> invoke(_su_cl_x, Tuple{_SuClSuper}, o))
# conditional_operator_runtime: a subtype instance with an inherited field and method
abstract type _SuCoB end
struct _SuCoC <: _SuCoB
    field::Int64
end
_SuCoC() = _SuCoC(Int64(1))
_su_co_method(::_SuCoB) = Int64(1)
_su_co_test(::_SuCoC) = nothing
# field_2: a field redeclared in a subtype; super.foo reads the nearest supertype's field
abstract type _SuF2A end
abstract type _SuF2AbsB <: _SuF2A end
abstract type _SuF2AbsC <: _SuF2AbsB end
abstract type _SuF2AbsD <: _SuF2AbsC end
struct _SuF2B <: _SuF2AbsB
    afoo::String
end
struct _SuF2C <: _SuF2AbsC
    afoo::String
    cfoo::String
end
struct _SuF2D <: _SuF2AbsD
    afoo::String
    cfoo::String
end
_su_f2_foo(o::_SuF2A) = o.afoo
_su_f2_foo(o::_SuF2AbsC) = o.cfoo
_su_f2_b_sfoo(::_SuF2A) = "A.B_Sfoo()"
_su_f2_b_sfoo(o::_SuF2AbsB) = invoke(_su_f2_foo, Tuple{_SuF2A}, o)
_su_f2_bc_sfoo(o::_SuF2AbsB) = invoke(_su_f2_foo, Tuple{_SuF2A}, o)
_su_f2_bc_sfoo(o::_SuF2AbsC) = invoke(_su_f2_foo, Tuple{_SuF2AbsB}, o)
_su_f2_bcd_sfoo(o::_SuF2AbsB) = invoke(_su_f2_foo, Tuple{_SuF2A}, o)
_su_f2_bcd_sfoo(o::_SuF2AbsC) = invoke(_su_f2_foo, Tuple{_SuF2AbsB}, o)
_su_f2_bcd_sfoo(o::_SuF2AbsD) = invoke(_su_f2_foo, Tuple{_SuF2AbsC}, o)
# field_access: a subtype's field shadowing the supertype's, read plainly, through this and super
abstract type _SuFaA end
struct _SuFaB <: _SuFaA
    afoo::Int64
    foo::Int64
end
_su_fa_b2(x::Int64, y::Int64) = _SuFaB(x, y)
_su_fa_foo(o::_SuFaA) = o.afoo
_su_fa_foo(o::_SuFaB) = o.foo
_su_fa_raw(o::_SuFaA) = _su_fa_foo(o)
_su_fa_this(o::_SuFaA) = _su_fa_foo(o)
_su_fa_super(o::_SuFaB) = invoke(_su_fa_foo, Tuple{_SuFaA}, o)
_su_fa_sum(o::_SuFaB) = _su_fa_foo(o) + invoke(_su_fa_foo, Tuple{_SuFaA}, o)
_su_fa_test(b::_SuFaB) = _dw_bits(_su_fa_foo(b) == 10, _su_fa_raw(b) == 10, _su_fa_this(b) == 10, _su_fa_super(b) == 100, _su_fa_sum(b) == 110)
# field: a chain of super calls and a getter overriding a field, reading it through super
abstract type _SuFiA end
abstract type _SuFiAbsB <: _SuFiA end
abstract type _SuFiAbsC <: _SuFiAbsB end
mutable struct _SuFiAc <: _SuFiA
    city::String
end
mutable struct _SuFiB <: _SuFiAbsB
    city::String
end
mutable struct _SuFiC <: _SuFiAbsC
    city::String
end
_su_fi_greeting(::_SuFiA) = "Gruezi"
_su_fi_greeting(o::_SuFiAbsB) = "Hola " * invoke(_su_fi_greeting, Tuple{_SuFiA}, o)
_su_fi_greeting(o::_SuFiAbsC) = "Servus " * invoke(_su_fi_greeting, Tuple{_SuFiAbsB}, o)
_su_fi_city(o::_SuFiA) = o.city
_su_fi_city(o::_SuFiAbsC) = "Basel " * invoke(_su_fi_city, Tuple{_SuFiA}, o)
# from_constructor: super calls inside a constructor, one inside a closure, one a method value
const _SU_FC_RESULTS = Int64[]
_su_fc_invoke(f) = f()::Int64
abstract type _SuFcBase end
_su_fc_m(::_SuFcBase, x) = push!(_SU_FC_RESULTS, x)
_su_fc_g(::_SuFcBase) = Int64(42)
mutable struct _SuFcC <: _SuFcBase
    f::Union{Nothing,Vector{Int64}}
    z::Union{Nothing,Int64}
    iter::Vector{Int64}
    function _SuFcC(iter::Vector{Int64})
        o = new(nothing, nothing, iter)
        map(x -> invoke(_su_fc_m, Tuple{_SuFcBase,Any}, o, x), iter)
        o.f = iter
        o.z = _su_fc_invoke(() -> invoke(_su_fc_g, Tuple{_SuFcBase}, o))
        return o
    end
end
_su_fc_g(::_SuFcC) = Int64(-1)
# implicit_closure: a super method taken as a value
abstract type _SuIcBase end
struct _SuIcDerived <: _SuIcBase
    i::Int64
    y::Int64
end
_su_ic_new(y::Int64, j::Int64) = _SuIcDerived(j, y)
_su_ic_foo(o::_SuIcBase) = o.i
_su_ic_foo(o::_SuIcDerived) = o.y
_su_ic_get_super(o::_SuIcDerived) = () -> invoke(_su_ic_foo, Tuple{_SuIcBase}, o)
# in_constructor: a super setter and a super field read inside a constructor
abstract type _SuInFoo end
_su_in_set_foo!(o::_SuInFoo, b::Bool) = (o.myBoolean = b; nothing)
_su_in_my_boolean(o::_SuInFoo) = o.myBoolean
mutable struct _SuInBaz <: _SuInFoo
    myBoolean::Bool
    checked::Bool
    function _SuInBaz()
        o = new(false, false)
        invoke(_su_in_set_foo!, Tuple{_SuInFoo,Bool}, o, true)
        o.checked = invoke(_su_in_my_boolean, Tuple{_SuInFoo}, o) == true
        return o
    end
end
# in_finally: a generic super call with a required keyword inside a finally run by a throw
abstract type _SuIfA end
struct _SuIfB <: _SuIfA end
_su_if_foo(::_SuIfA; x::T) where {T} = x
function _su_if_bar(b::_SuIfB)
    local r = Int64(0)
    try
        try
            throw(ErrorException("bar"))
        finally
            local x = invoke(_su_if_foo, Tuple{_SuIfA}, b; x = Int64(41))
            r = x + 1
        end
    catch
    end
    return r
end
# inferrer: a method called directly and through super with nothing, which raises MethodError
abstract type _SuInfA end
struct _SuInfAc <: _SuInfA end
struct _SuInfB <: _SuInfA end
_su_inf_foo(::_SuInfA, a) = a + 42
_su_inf_bar(b::_SuInfB) = (invoke(_su_inf_foo, Tuple{_SuInfA,Any}, b, nothing); nothing)
const _SU_INF_A = [_SuInfAc()]
# mixin_legacy: a super getter supplied by a class used as a mixin (the application is an
# intermediate supertype)
abstract type _SuMxlSuperclass end
abstract type _SuMxlMixin <: _SuMxlSuperclass end
struct _SuMxlSubclass <: _SuMxlMixin end
_su_mxl_getter(::_SuMxlMixin) = Int64(42)
_su_mxl_method(o::_SuMxlSubclass) = invoke(_su_mxl_getter, Tuple{_SuMxlMixin}, o)
# mixin: a super getter supplied by a mixin declaration
abstract type _SuMxSuperclass end
abstract type _SuMxMixin <: _SuMxSuperclass end
struct _SuMxSubclass <: _SuMxMixin end
_su_mx_getter(::_SuMxMixin) = Int64(42)
_su_mx_method(o::_SuMxSubclass) = invoke(_su_mx_getter, Tuple{_SuMxMixin}, o)
# no_such_method1: a super call of a declared-only method reaches the subtype's noSuchMethod
abstract type _SuNs1A end
struct _SuNs1B <: _SuNs1A end
_su_ns1_nsm(::_SuNs1A, im::Symbol) = Int64(42)
_su_ns1_nsm(::_SuNs1B, im::Symbol) = Int64(87)
_su_ns1_foo(a::_SuNs1A)::Int64 = _su_ns1_nsm(a, :foo)
_su_ns1_foo(b::_SuNs1B) = invoke(_su_ns1_foo, Tuple{_SuNs1A}, b)
# no_such_method2: the same through a declared-only getter
abstract type _SuNs2A end
struct _SuNs2B <: _SuNs2A end
_su_ns2_nsm(::_SuNs2A, im::Symbol) = Int64(42)
_su_ns2_nsm(::_SuNs2B, im::Symbol) = Int64(87)
_su_ns2_foo(a::_SuNs2A)::Int64 = _su_ns2_nsm(a, :foo)
_su_ns2_foo(b::_SuNs2B) = invoke(_su_ns2_foo, Tuple{_SuNs2A}, b)
# no_such_method3: the same through a declared-only setter, recording into a global
const _SU_NS3_RESULT = Ref(Int64(0))
abstract type _SuNs3A end
struct _SuNs3B <: _SuNs3A end
_su_ns3_nsm(::_SuNs3A, im::Symbol) = (_SU_NS3_RESULT[] = 42; nothing)
_su_ns3_nsm(::_SuNs3B, im::Symbol) = (_SU_NS3_RESULT[] = 87; nothing)
_su_ns3_set_foo!(a::_SuNs3A, v::Int64) = _su_ns3_nsm(a, :foo!)
_su_ns3_set_foo!(b::_SuNs3B, v::Int64) = invoke(_su_ns3_set_foo!, Tuple{_SuNs3A,Int64}, b, v)
# no_such_method4_runtime_legacy: a mixed-in declared-only method forwards to the class's
# noSuchMethod
abstract type _SuNs4lA end
struct _SuNs4lB <: _SuNs4lA end
_su_ns4l_nsm(::_SuNs4lA, im::Symbol) = Int64(42)
_su_ns4l_nsm(::_SuNs4lB, im::Symbol) = Int64(87)
_su_ns4l_foo(a::_SuNs4lA)::Int64 = _su_ns4l_nsm(a, :foo)
# no_such_method4_runtime: a mixin class used alone and mixed into a class with its own noSuchMethod
abstract type _SuNs4A end
struct _SuNs4Ac <: _SuNs4A end
struct _SuNs4B <: _SuNs4A end
_su_ns4_nsm(::_SuNs4A, im::Symbol) = Int64(42)
_su_ns4_nsm(::_SuNs4B, im::Symbol) = Int64(87)
_su_ns4_foo(a::_SuNs4A)::Int64 = _su_ns4_nsm(a, :foo)
# no_such_method5_runtime_legacy: a mixed-in declared-only method reaches the mixin's noSuchMethod
abstract type _SuNs5lA end
struct _SuNs5lB <: _SuNs5lA end
_su_ns5l_nsm(::_SuNs5lA, im::Symbol) = Int64(42)
_su_ns5l_foo(a::_SuNs5lA)::Int64 = _su_ns5l_nsm(a, :foo)
# no_such_method5_runtime: a mixin class used alone and mixed in, one noSuchMethod
abstract type _SuNs5A end
struct _SuNs5Ac <: _SuNs5A end
struct _SuNs5B <: _SuNs5A end
_su_ns5_nsm(::_SuNs5A, im::Symbol) = Int64(42)
_su_ns5_foo(a::_SuNs5A)::Int64 = _su_ns5_nsm(a, :foo)
# operator_index: super[i] = v and super[i] reaching the supertypes' index methods
abstract type _SuOiA end
struct _SuOiB <: _SuOiA end
abstract type _SuOiC end
struct _SuOiD <: _SuOiC end
struct _SuOiE end
Base.setindex!(::_SuOiA, b, a) = nothing
Base.getindex(::_SuOiC, a) = nothing
_su_oi_bfoo(o::_SuOiB) = (invoke(setindex!, Tuple{_SuOiA,Int64,Int64}, o, Int64(42), Int64(4)); nothing)
_su_oi_dfoo(o::_SuOiD) = invoke(getindex, Tuple{_SuOiC,Int64}, o, Int64(2))
_su_oi_efoo(::_SuOiE) = nothing
# operator_index2: super index methods backed by a Dict, including a compound assignment
abstract type _SuOi2A end
struct _SuOi2B <: _SuOi2A
    map::Dict{Int64,Int64}
end
_SuOi2B() = _SuOi2B(Dict{Int64,Int64}())
Base.setindex!(o::_SuOi2A, b, a) = (o.map[a] = b)
Base.getindex(o::_SuOi2A, a) = o.map[a]
_su_oi2_foo(o::_SuOi2B) = (_su_sset(_SuOi2A, o, 4, 42); r1 = _su_sget(_SuOi2A, o, 4) == 42;
    _su_sadd(_SuOi2A, o, 4, 5); _dw_bits(r1, _su_sget(_SuOi2A, o, 4) == 47))
# operator_index3: super[] from the parent and super[]= from the grandparent
abstract type _SuOi3A end
abstract type _SuOi3B <: _SuOi3A end
struct _SuOi3C <: _SuOi3B
    indexField::Vector{Union{Nothing,Int64}}
end
_SuOi3C() = _SuOi3C(Union{Nothing,Int64}[nothing, nothing])
Base.setindex!(o::_SuOi3A, value, index) = (o.indexField[index + 1] = value)
Base.getindex(o::_SuOi3B, index) = o.indexField[index + 1]
# operator_index4: super[]= from the parent and super[] from the grandparent
abstract type _SuOi4A end
abstract type _SuOi4B <: _SuOi4A end
struct _SuOi4C <: _SuOi4B
    indexField::Vector{Union{Nothing,Int64}}
end
_SuOi4C() = _SuOi4C(Union{Nothing,Int64}[nothing, nothing])
Base.getindex(o::_SuOi4A, index) = o.indexField[index + 1]
Base.setindex!(o::_SuOi4B, value, index) = (o.indexField[index + 1] = value)
# operator_index5: super[]= declared only, forwarded to noSuchMethod
abstract type _SuOi5A end
struct _SuOi5B <: _SuOi5A
    indexField::Vector{Union{Nothing,Int64}}
end
_SuOi5B() = _SuOi5B(Union{Nothing,Int64}[nothing, nothing])
function _su_oi5_nsm(o::_SuOi5A, name::Symbol, args::Tuple)
    if name === _SU_NSM_SET
        @assert length(args) == 2
        o.indexField[args[1] + 1] = args[2]
        return nothing
    end
    error("Should not reach here")
end
Base.getindex(o::_SuOi5A, index) = o.indexField[index + 1]
Base.setindex!(o::_SuOi5A, value, index) = _su_oi5_nsm(o, _SU_NSM_SET, (index, value))
# operator_index6: super[] declared only, forwarded to noSuchMethod
abstract type _SuOi6A end
struct _SuOi6B <: _SuOi6A
    indexField::Vector{Union{Nothing,Int64}}
end
_SuOi6B() = _SuOi6B(Union{Nothing,Int64}[nothing, nothing])
function _su_oi6_nsm(o::_SuOi6A, name::Symbol, args::Tuple)
    if name === _SU_NSM_GET
        @assert length(args) == 1
        return o.indexField[args[1] + 1]
    end
    error("Should not reach here")
end
Base.setindex!(o::_SuOi6A, value, index) = (o.indexField[index + 1] = value)
Base.getindex(o::_SuOi6A, index) = _su_oi6_nsm(o, _SU_NSM_GET, (index,))
# operator_index7: both super index operators declared only, forwarded to noSuchMethod
abstract type _SuOi7A end
struct _SuOi7B <: _SuOi7A
    indexField::Vector{Union{Nothing,Int64}}
end
_SuOi7B() = _SuOi7B(Union{Nothing,Int64}[nothing, nothing])
function _su_oi7_nsm(o::_SuOi7A, name::Symbol, args::Tuple)
    if name === _SU_NSM_SET
        @assert length(args) == 2
        o.indexField[args[1] + 1] = args[2]
        return nothing
    elseif name === _SU_NSM_GET
        @assert length(args) == 1
        return o.indexField[args[1] + 1]
    end
    error("Should not reach here")
end
Base.setindex!(o::_SuOi7A, value, index) = _su_oi7_nsm(o, _SU_NSM_SET, (index, value))
Base.getindex(o::_SuOi7A, index) = _su_oi7_nsm(o, _SU_NSM_GET, (index,))
# operator_index8: super[f()] = g() through noSuchMethod evaluates the index before the value
abstract type _SuOi8A end
struct _SuOi8B <: _SuOi8A
    indexField::Vector{Union{Nothing,Int64}}
end
_SuOi8B() = _SuOi8B(Union{Nothing,Int64}[nothing, nothing])
function _su_oi8_nsm(o::_SuOi8A, name::Symbol, args::Tuple)
    if name === _SU_NSM_SET
        @assert length(args) == 2
        o.indexField[args[1] + 1] = args[2]
        return nothing
    elseif name === _SU_NSM_GET
        @assert length(args) == 1
        return o.indexField[args[1] + 1]
    end
    error("Should not reach here")
end
Base.setindex!(o::_SuOi8A, value, index) = _su_oi8_nsm(o, _SU_NSM_SET, (index, value))
Base.getindex(o::_SuOi8A, index) = _su_oi8_nsm(o, _SU_NSM_GET, (index,))
const _SU_OI8_GLOBAL = Ref(Int64(0))
_su_oi8_f() = (@assert _SU_OI8_GLOBAL[] == 0; _SU_OI8_GLOBAL[] += 1; Int64(0))
_su_oi8_g() = (@assert _SU_OI8_GLOBAL[] == 1; _SU_OI8_GLOBAL[] += 1; Int64(42))
_su_oi8_test(o::_SuOi8B) = _dw_bits(_su_sset(_SuOi8A, o, _su_oi8_f(), _su_oi8_g()) == 42, _SU_OI8_GLOBAL[] == 2)
# operator: super +, [] and []= operators, the compound super[i++] += v evaluating its index once
abstract type _SuOpA end
mutable struct _SuOpAc <: _SuOpA
    val::String
    things::Vector{Union{String,Int64}}
end
_SuOpAc() = _SuOpAc("", Union{String,Int64}["D", "a", "r", "t", 42])
mutable struct _SuOpB <: _SuOpA
    val::String
    things::Vector{Union{String,Int64}}
end
_SuOpB() = _SuOpB("", Union{String,Int64}["D", "a", "r", "t", 42])
Base.:+(o::_SuOpA, s::String) = (o.val = string(o.val, s); o)
Base.getindex(o::_SuOpA, i::Int64) = o.things[i + 1]
Base.setindex!(o::_SuOpA, val, i::Int64) = (o.things[i + 1] = val)
Base.:+(o::_SuOpB, s::String) = (invoke(+, Tuple{_SuOpA,String}, o, string(s, s)); o)
function Base.getindex(o::_SuOpB, i::Int64)
    temp = invoke(getindex, Tuple{_SuOpA,Int64}, o, i)
    return temp isa String ? string(temp, temp) : temp + temp
end
function Base.setindex!(o::_SuOpB, val, i::Int64)
    local j = i
    i += 1
    local t = (invoke(getindex, Tuple{_SuOpA,Int64}, o, j)::Int64) + val
    invoke(setindex!, Tuple{_SuOpA,Any,Int64}, o, t, j)
    return t
end
# regress47698: a super field's getter used before its setter and the reverse, in constructors
abstract type _SuRgA end
_su_rg_i(o::_SuRgA) = o.i
_su_rg_set_i!(o::_SuRgA, v::Int64) = (o.i = v; nothing)
abstract type _SuRgB end
_su_rg_j(o::_SuRgB) = o._j
_su_rg_set_j!(o::_SuRgB, x::Int64) = (o._j = x; nothing)
mutable struct _SuRgC <: _SuRgA
    i::Int64
    function _SuRgC(val::Int64)
        o = new(val)
        x = invoke(_su_rg_i, Tuple{_SuRgA}, o) + 10
        invoke(_su_rg_set_i!, Tuple{_SuRgA,Int64}, o, x + 100)
        return o
    end
end
mutable struct _SuRgD <: _SuRgA
    i::Int64
    function _SuRgD(val::Int64)
        o = new(val)
        invoke(_su_rg_set_i!, Tuple{_SuRgA,Int64}, o, Int64(100))
        invoke(_su_rg_set_i!, Tuple{_SuRgA,Int64}, o, invoke(_su_rg_i, Tuple{_SuRgA}, o) + 10 + val)
        return o
    end
end
mutable struct _SuRgE <: _SuRgB
    _j::Int64
    function _SuRgE(val::Int64)
        o = new(val)
        x = invoke(_su_rg_j, Tuple{_SuRgB}, o) + 10
        invoke(_su_rg_set_j!, Tuple{_SuRgB,Int64}, o, x + 100)
        return o
    end
end
mutable struct _SuRgF <: _SuRgB
    _j::Int64
    function _SuRgF(val::Int64)
        o = new(val)
        invoke(_su_rg_set_j!, Tuple{_SuRgB,Int64}, o, Int64(100))
        invoke(_su_rg_set_j!, Tuple{_SuRgB,Int64}, o, invoke(_su_rg_j, Tuple{_SuRgB}, o) + 10 + val)
        return o
    end
end
# setter_interceptor: super setter and getter in =, +=, prefix and postfix ++ and --, the setter
# checking the value it receives
const _SU_SI_EXPECTED = Ref(Int64(0))
const _SU_SI_OK = Ref(true)
abstract type _SuSiA end
struct _SuSiB <: _SuSiA end
_su_si_set_length!(::_SuSiA, a::Int64) = (_SU_SI_OK[] &= (a == _SU_SI_EXPECTED[]); nothing)
_su_si_length(::_SuSiA) = Int64(41)
_su_si_sget(o::_SuSiB) = invoke(_su_si_length, Tuple{_SuSiA}, o)
_su_si_sset(o::_SuSiB, v::Int64) = (invoke(_su_si_set_length!, Tuple{_SuSiA,Int64}, o, v); v)
function _su_si_test(o::_SuSiB)
    _SU_SI_OK[] = true
    _SU_SI_EXPECTED[] = 42; r1 = _su_si_sset(o, Int64(42)) == 42
    _SU_SI_EXPECTED[] = 42; r2 = _su_si_sset(o, _su_si_sget(o) + 1) == 42
    _SU_SI_EXPECTED[] = 42; r3 = _su_si_sset(o, _su_si_sget(o) + 1) == 42
    _SU_SI_EXPECTED[] = 40; r4 = _su_si_sset(o, _su_si_sget(o) - 1) == 40
    _SU_SI_EXPECTED[] = 42; r5 = (old = _su_si_sget(o); _su_si_sset(o, old + 1); old) == 41
    _SU_SI_EXPECTED[] = 40; r6 = (old = _su_si_sget(o); _su_si_sset(o, old - 1); old) == 41
    r7 = _su_si_sget(o) == 41
    return _dw_bits(r1, r2, r3, r4, r5, r6, r7, _SU_SI_OK[])
end
# setter: an overriding setter and getter calling the supertype's through super
abstract type _SuStBase end
mutable struct _SuStDerived <: _SuStBase
    value_::String
end
_SuStDerived() = _SuStDerived("")
_su_st_value(o::_SuStBase) = o.value_
_su_st_set_value!(o::_SuStBase, v::String) = (o.value_ = "Base:$v"; nothing)
_su_st_set_value!(o::_SuStDerived, v::String) = invoke(_su_st_set_value!, Tuple{_SuStBase,String}, o, "Derived:$v")
_su_st_value(o::_SuStDerived) = invoke(_su_st_value, Tuple{_SuStBase}, o)
# super: constructor initializer lists run the subtype's initializers, then the supertype's
# initializers and body, then the subtype's body
const _SU_SU_I = Ref(Int64(0))
_su_su_inc() = (r = _SU_SU_I[]; _SU_SU_I[] += 1; r)
abstract type _SuSuSup end
_su_su_sup!(o::_SuSuSup, a::Int64, b::Int64) = (o.x = a; o.y = b; o.z = a + b; nothing)
_su_su_sup_stat!(o::_SuSuSup) = (o.x = _su_su_inc(); o.y = _su_su_inc(); o.z = _su_su_inc(); nothing)
mutable struct _SuSuSub <: _SuSuSup
    x::Int64
    y::Int64
    z::Int64
    u::Int64
    v::Int64
    w::Int64
    function _SuSuSub(a::Int64, b::Int64)
        o = new()
        o.v = a
        o.w = b
        _su_su_sup!(o, a, b)
        o.u = a + b
        return o
    end
    function _SuSuSub()
        o = new()
        o.v = _su_su_inc()
        o.w = _su_su_inc()
        _su_su_sup_stat!(o)
        o.u = _su_su_inc()
        return o
    end
end
_g("dart_super", Any[
    ("abstract_method", (n::Int64) -> _dw_bits(_su_am_foo(_SuAmB()) == 42, _su_am_test_super_call(_SuAmB()) == 42) + n, Int64(0)),
    ("all_named_constructor", (n::Int64) -> (_SU_ANC_RES[] = 0; _SuAncB(); _SU_ANC_RES[] + n), Int64(0)),
    ("assign_runtime", (n::Int64) -> (a = _SuAsC(); a.x = 37 * n; r1 = a.x; _su_as_setx!(a, 42 * n); r1 * 100 + a.x), Int64(1)),
    ("bound_closure", (n::Int64) -> (b = _SuBcB(); c = _su_bc_confuse;
        t = _su_bc_bar(b) + _su_bc_bar2(b) + _su_bc_bar3(b, 9n) + _su_bc_bar4(b, 19n);
        _dw_bits(t == -4,
            c(_su_bc_super_bar(b))() == 499, c(_su_bc_super_bar(b))(2n) == 500, c(_su_bc_super_bar2(b))() == 42,
            c(_su_bc_super_bar2(b))(namedOptional = 77n) == 117, c(_su_bc_super_bar3(b))(-3n) == 498, c(_su_bc_super_bar3(b))(-11n, -19n) == 468,
            c(_su_bc_super_bar4(b))(0n) == 426, c(_su_bc_super_bar4(b))(3n, namedOptional = 77n) == 502,
            c(_su_bc_super_add(b))() == 1267, c(_su_bc_super_add(b))(2n) == 1236, c(_su_bc_super_trim(b))() == 1335,
            c(_su_bc_super_trim(b))(namedOptional = 77n) == 1390, c(_su_bc_super_sublist(b))(-3n) == 4362, c(_su_bc_super_sublist(b))(-11n, -19n) == 4291,
            c(_su_bc_super_split(b))(0n) == 232, c(_su_bc_super_split(b))(3n, onMatch = 77n, onNonMatch = 8n) == 199)), Int64(1)),
    ("call", (n::Int64) -> (b = _SuCaB(); _su_ca_incr!(b); _dw_bits(b.field == 2, _su_ca_timesx(b, 2n) == 12)), Int64(1)),
    ("call2", (n::Int64) -> (_SU_C2_VALUE[] = -1; d = _SuC2D{Union{Nothing,Int64}}(); _su_c2_foo(d, nothing); b = _SuC2B(); _su_c2_m(b, 41n); _SU_C2_VALUE[]), Int64(1)),
    ("call3_runtime", (n::Int64) -> _dw_bits(_SuC3B().foo == 499, _SuC3B2().foo == 499, _su_c3_b2_named().foo == 499,
        _SuC3D().foo == 499, _SuC3D2().foo == 499, _su_c3_d2_named().foo == 499) + n, Int64(0)),
    ("call4", (n::Int64) -> (d = _SuC4D(); _dw_bits(_su_c4_test1(d) == false, _su_c4_test2(d) == false, _su_c4_test3(d) == false, _su_c4_test4(d) == false) + n), Int64(0)),
    ("closure", (s::String) -> (c = _su_cl_build(_SuClSub("super", s)); _dw_bits(length(c) == 3, c[1]() == "sub", c[2]() == "sub", c[3]() == "super")), "sub"),
    ("conditional_operator_runtime", (n::Int64) -> (c = _SuCoC(); _su_co_test(c) === nothing ? c.field + _su_co_method(c) + n : Int64(-1)), Int64(0)),
    ("field_2", (n::Int64) -> (b = _SuF2B("Ba"); c = _SuF2C("Ca", "Cc"); d = _SuF2D("Da", "Dc"); insc = x -> x;
        b_bc = insc(n == 1) ? b : c; c_bc = insc(n == 1) ? c : b;
        _dw_bits(_su_f2_foo(b) == "Ba", _su_f2_foo(c) == "Cc", _su_f2_foo(d) == "Dc", _su_f2_foo(b_bc) == "Ba", _su_f2_foo(c_bc) == "Cc",
                 _su_f2_b_sfoo(b) == "Ba", _su_f2_b_sfoo(c) == "Ca", _su_f2_b_sfoo(d) == "Da",
                 _su_f2_bc_sfoo(b) == "Ba", _su_f2_bc_sfoo(c) == "Ca", _su_f2_bc_sfoo(d) == "Da",
                 _su_f2_bcd_sfoo(b) == "Ba", _su_f2_bcd_sfoo(c) == "Ca", _su_f2_bcd_sfoo(d) == "Dc",
                 _su_f2_b_sfoo(insc(b_bc)) == "Ba", _su_f2_bcd_sfoo(insc(c_bc)) == "Ca")), Int64(1)),
    ("field_access", (n::Int64) -> _su_fa_test(_SuFaB(100n, 10n)) * 1024 + _su_fa_test(_su_fa_b2(100n, 10n)) * 32 + _su_fa_test(_su_fa_b2(100n, 10n)), Int64(1)),
    ("field", (s::String) -> (a = _SuFiAc("Bern"); b = _SuFiB("Bern"); c = _SuFiC("Bern");
        r = _dw_bits(_su_fi_greeting(a) == "Gruezi", _su_fi_greeting(b) == "Hola Gruezi", _su_fi_greeting(c) == "Servus Hola Gruezi",
                     _su_fi_city(a) == "Bern", _su_fi_city(b) == "Bern", _su_fi_city(c) == "Basel Bern");
        c.city = s; r * 2 + (_su_fi_city(c) == "Basel Zurich")), "Zurich"),
    ("from_constructor", (n::Int64) -> (empty!(_SU_FC_RESULTS); c = _SuFcC(Int64[1, 2, 3] .* n);
        _dw_bits(_SU_FC_RESULTS == [1, 2, 3], c.f == [1, 2, 3], c.z == 42)), Int64(1)),
    ("implicit_closure", (n::Int64) -> (obj = _su_ic_new(20n, 10n); ib = () -> _su_ic_foo(obj); r1 = ib() == obj.y; ib2 = _su_ic_get_super(obj);
        _dw_bits(r1, ib2() == obj.i)), Int64(1)),
    ("in_constructor", (b::Bool) -> (o = _SuInBaz(); _dw_bits(o.checked, o.myBoolean == b)), true),
    ("in_finally", (n::Int64) -> _su_if_bar(_SuIfB()) + n, Int64(0)),
    ("inferrer", (n::Int64) -> _dw_bits(_su_inf_foo(_SU_INF_A[1], 42n) == 84, (try; _su_inf_bar(_SuInfB()); false; catch e; e isa MethodError; end)), Int64(1)),
    ("mixin_legacy", (n::Int64) -> _su_mxl_method(_SuMxlSubclass()) + n, Int64(0)),
    ("mixin", (n::Int64) -> _su_mx_method(_SuMxSubclass()) + n, Int64(0)),
    ("no_such_method1", (n::Int64) -> _su_ns1_foo(_SuNs1B()) + n, Int64(0)),
    ("no_such_method2", (n::Int64) -> _su_ns2_foo(_SuNs2B()) + n, Int64(0)),
    ("no_such_method3", (n::Int64) -> (_SU_NS3_RESULT[] = 0; _su_ns3_set_foo!(_SuNs3B(), n); _SU_NS3_RESULT[]), Int64(0)),
    ("no_such_method4_runtime_legacy", (n::Int64) -> _su_ns4l_foo(_SuNs4lB()) + n, Int64(0)),
    ("no_such_method4_runtime", (n::Int64) -> _dw_bits(_su_ns4_foo(_SuNs4Ac()) == 42, _su_ns4_foo(_SuNs4B()) == 87) + n, Int64(0)),
    ("no_such_method5_runtime_legacy", (n::Int64) -> _su_ns5l_foo(_SuNs5lB()) + n, Int64(0)),
    ("no_such_method5_runtime", (n::Int64) -> _dw_bits(_su_ns5_foo(_SuNs5Ac()) == 42, _su_ns5_foo(_SuNs5B()) == 42) + n, Int64(0)),
    ("operator_index", (n::Int64) -> _dw_bits(_su_oi_bfoo(_SuOiB()) === nothing, _su_oi_dfoo(_SuOiD()) === nothing, _su_oi_efoo(_SuOiE()) === nothing) + n, Int64(0)),
    ("operator_index2", (n::Int64) -> _su_oi2_foo(_SuOi2B()) + n, Int64(0)),
    ("operator_index3", (n::Int64) -> _su_index_seq(_SuOi3B, _SuOi3C()) + n, Int64(0)),
    ("operator_index4", (n::Int64) -> _su_index_seq(_SuOi4B, _SuOi4C()) + n, Int64(0)),
    ("operator_index5", (n::Int64) -> _su_index_seq(_SuOi5A, _SuOi5B()) + n, Int64(0)),
    ("operator_index6", (n::Int64) -> _su_index_seq(_SuOi6A, _SuOi6B()) + n, Int64(0)),
    ("operator_index7", (n::Int64) -> _su_index_seq(_SuOi7A, _SuOi7B()) + n, Int64(0)),
    ("operator_index8", (n::Int64) -> (_SU_OI8_GLOBAL[] = 0; _su_oi8_test(_SuOi8B()) + n), Int64(0)),
    ("operator", (s::String) -> (a1 = _SuOpAc(); a1 = a1 + s; r1 = a1.val == "William"; r2 = a1[2] == "r";
        a2 = _SuOpB(); a2 += "Tell"; r3 = a2.val == "TellTell"; r4 = a2[2] == "rr"; a2[4] = 1;
        _dw_bits(r1, r2, r3, r4, a2.things[5] == 43, a2[4] == 86)), "William"),
    ("regress47698", (n::Int64) -> _dw_bits(_SuRgC(n).i == 111, _SuRgD(n).i == 111, _SuRgE(n)._j == 111, _SuRgF(n)._j == 111), Int64(1)),
    ("setter_interceptor", (n::Int64) -> _su_si_test(_SuSiB()) + n, Int64(0)),
    ("setter", (s::String) -> (b = _SuStDerived(); _su_st_set_value!(b, s); _su_st_value(b) == "Base:Derived:foo"), "foo"),
    ("super", (n::Int64) -> (_SU_SU_I[] = 0; s = _SuSuSub(1n, 2n);
        b1 = _dw_bits(s.x == 1, s.y == 2, s.z == 3, s.v == 1, s.w == 2, s.u == 3); s = _SuSuSub();
        b1 * 64 + _dw_bits(s.x == 2, s.y == 3, s.v == 0, s.w == 1, s.z == 4, s.u == 5)), Int64(1)),
])

# ---- dart2wasm's tests at the pin, tests/language/switch ------------------------------------------
# Each case is named by the dart file's path under tests/language/switch, less `_test`. A switch is an
# if/elseif chain on `==` (the case constant on the left where a custom == is the subject); a case
# does not fall through; `continue label` jumps with @goto to the labeled case's body.
# aborting_switch_case: a case whose body throws, caught outside the switch
_sw_ab_foo() = throw(Int64(42))
# backward_jump: continue to a labeled case earlier in the switch, to itself and to default
function _sw_bj_test(i::Int64)::String
    i == 5 && @goto a
    @goto b
    @label a
    i == 10 && return "a through b"
    i == 0 && return "a"
    i -= 1
    @goto a
    @label b
    i == 10 && @goto a
    i == 0 && return "b"
    i -= 1
    @goto b
end
# bad_case_runtime: a switch with no match returns nothing
function _sw_bc_caesar(n::Int64)
    if n == 1
        return "I"
    elseif n == 4
        return "IV"
    end
    return nothing
end
_sw_bc_archimedes(n::Float64) = nothing
# case_expression_with_assignment_runtime: cases on constants and a default
const _SW_CEA_ERROR_A = Int64(0)
const _SW_CEA_ERROR_B = Int64(1)
function _sw_cea_to_string(error::Int64)
    if error == _SW_CEA_ERROR_A
        return "ERROR_A"
    elseif error == _SW_CEA_ERROR_B
        return "ERROR_B"
    else
        return "Unknown error"
    end
end
# case_fallthrough: cases leaving by break, break and continue of an enclosing loop, continue to a
# label, return, throw, rethrow, loops that complete and calls that never return
_sw_cf_nop(x) = nothing
_sw_cf_not_ever(x::Int64)::Union{} = x < 0 ? _sw_cf_not_ever(x + 1) : throw(AssertionError("Never"))
function _sw_cf_switch(x::Int64)::Int64
    local path = Int64(-1)
    try
        try
            throw(x)
        catch
            for _ in 1:1
                if x == 0 || x == 1 || x == 10 || x == 11 || x == 20
                    _sw_cf_nop(x); path = 1
                elseif x == 2 || x == 12 || x == 21
                    _sw_cf_nop(x); path = 2; break
                elseif x == 3 || x == 13 || x == 22
                    _sw_cf_nop(x); path = 3; continue
                elseif x == 4 || x == 14 || x == 23
                    _sw_cf_nop(x); path = 4; continue
                elseif x == 5 || x == 15 || x == 24
                    _sw_cf_nop(x); path = 5
                elseif x == 6 || x == 16 || x == 25
                    _sw_cf_nop(x); return Int64(6)
                elseif x == 7 || x == 17 || x == 26
                    _sw_cf_nop(x); return x
                elseif x == 8 || x == 18 || x == 27
                    _sw_cf_nop(x); throw(x)
                elseif x == 9 || x == 19 || x == 28
                    _sw_cf_nop(x); rethrow()
                elseif x == 29 || x == 30 || x == 31
                    while true; break; end; path = 29
                elseif x == 32
                    for _ in Int64[]; @goto loop_done; end; path = 32
                elseif x == 33
                    if iseven(x); path = 33; else; path = 330; break; end
                elseif x == 34
                    throw(Int64(0))
                elseif x == 35
                    _sw_cf_nop(x); path = 35
                elseif x == 36
                    path = 36
                elseif x == 37
                    path = 37
                elseif x == 38
                    if isodd(x); path = 38; else; path = 380; break; end
                elseif x == 39 || x == 40 || x == 41
                    _sw_cf_not_ever(x)
                elseif x == 42
                    while true; _sw_cf_not_ever(x); end
                elseif x == 43
                    iseven(x) ? _sw_cf_not_ever(x) : _sw_cf_not_ever(-x)
                elseif x == 44
                    _sw_cf_nop(iseven(x) ? _sw_cf_not_ever(x) : _sw_cf_not_ever(-x))
                elseif x == 99
                    path = 99
                end
            end
            @label loop_done
        end
    catch e
        path = e isa Int64 ? 1000 + e : Int64(2000)
    end
    return path
end
# case_runtime: a fresh instance never matches a canonical constant of its class (identity)
abstract type _SwCrAbsA end
mutable struct _SwCrA <: _SwCrAbsA end
mutable struct _SwCrB <: _SwCrAbsA end
abstract type _SwCrAbsD <: _SwCrAbsA end
mutable struct _SwCrC <: _SwCrAbsD
    x::Int64
end
const _SW_CR_C = _SwCrC(0)
const _SW_CR_C2 = _SwCrC(1)
const _SW_CR_A = _SwCrA()
# case_static_const: cases on a top-level constant, a class constant and a literal string
const _SW_CSC_S = "S"
const _SW_CSC_A_S = "A.S"
function _sw_csc_foo(p::String)
    if p == _SW_CSC_S
        return Int64(1)
    elseif p == _SW_CSC_A_S
        return Int64(2)
    elseif p == "abc"
        return Int64(3)
    end
    return Int64(0)
end
# enum_compare: switches over enums (one of 52 values with a default), strings, ints and Bools
@enum _SwEcAnimal _sw_ec_cat _sw_ec_dog _sw_ec_mouse _sw_ec_lion _sw_ec_duck
@enum _SwEcLong begin
    _sw_ecl_a; _sw_ecl_b; _sw_ecl_c; _sw_ecl_d; _sw_ecl_e; _sw_ecl_f; _sw_ecl_g; _sw_ecl_h; _sw_ecl_i; _sw_ecl_j; _sw_ecl_k; _sw_ecl_l; _sw_ecl_m
    _sw_ecl_n; _sw_ecl_o; _sw_ecl_p; _sw_ecl_q; _sw_ecl_r; _sw_ecl_s; _sw_ecl_t; _sw_ecl_u; _sw_ecl_v; _sw_ecl_w; _sw_ecl_x; _sw_ecl_y; _sw_ecl_z
    _sw_ecl_aa; _sw_ecl_ab; _sw_ecl_ac; _sw_ecl_ad; _sw_ecl_ae; _sw_ecl_af; _sw_ecl_ag; _sw_ecl_ah; _sw_ecl_ai; _sw_ecl_aj; _sw_ecl_ak; _sw_ecl_al; _sw_ecl_am
    _sw_ecl_an; _sw_ecl_ao; _sw_ecl_ap; _sw_ecl_aq; _sw_ecl_ar; _sw_ecl_as; _sw_ecl_at; _sw_ecl_au; _sw_ecl_av; _sw_ecl_aw; _sw_ecl_ax; _sw_ecl_ay; _sw_ecl_az
end
const _SW_EC_STRINGS = String["cat", "dog", "mouse", "lion", "duck"]
const _SW_EC_INTS = Int64[1, 2, 3, 4, 5]
const _SW_EC_BOOLS = Bool[true, false]
function _sw_ec_switches(longEnum::_SwEcLong)
    local ok = Int64(0)
    for animal in instances(_SwEcAnimal)
        if animal == _sw_ec_cat
            ok += animal == _sw_ec_cat
        elseif animal == _sw_ec_dog
            ok += animal == _sw_ec_dog
        elseif animal == _sw_ec_mouse
            ok += animal == _sw_ec_mouse
        elseif animal == _sw_ec_lion
            ok += animal == _sw_ec_lion
        elseif animal == _sw_ec_duck
            ok += animal == _sw_ec_duck
        end
    end
    if longEnum == _sw_ecl_a
        ok += _sw_ecl_a == _sw_ecl_a
    elseif longEnum == _sw_ecl_b
        ok += _sw_ecl_b == _sw_ecl_b
    else
        ok += longEnum == _sw_ecl_ad
    end
    for string in _SW_EC_STRINGS
        if string == "cat"
            ok += string == "cat"
        elseif string == "dog"
            ok += string == "dog"
        elseif string == "mouse"
            ok += string == "mouse"
        elseif string == "lion"
            ok += string == "lion"
        elseif string == "duck"
            ok += string == "duck"
        else
            ok -= 100
        end
    end
    for i in _SW_EC_INTS
        if i == 1
            ok += i == 1
        elseif i == 2
            ok += i == 2
        elseif i == 3
            ok += i == 3
        elseif i == 4
            ok += i == 4
        elseif i == 5
            ok += i == 5
        else
            ok -= 100
        end
    end
    for b in _SW_EC_BOOLS
        if b == true
            ok += b
        elseif b == false
            ok += !b
        end
    end
    return ok
end
# equality_side_effect: each case constant's custom == is called, in order, until one matches
const _SW_ES_EFFECTS = String[]
struct _SwEsSideEffect
    value::Int64
end
_sw_es_str(s::_SwEsSideEffect) = "S($(s.value))"
Base.:(==)(a::_SwEsSideEffect, other::_SwEsSideEffect) = (push!(_SW_ES_EFFECTS, string(_sw_es_str(a), " == ", _sw_es_str(other))); a.value == other.value)
const _SW_ES_ONE = _SwEsSideEffect(1)
const _SW_ES_TWO = _SwEsSideEffect(2)
function _sw_es_test(value::Int64)::String
    empty!(_SW_ES_EFFECTS)
    local v = _SwEsSideEffect(value)
    if _SW_ES_ONE == v
        push!(_SW_ES_EFFECTS, "match one")
    elseif _SW_ES_TWO == v
        push!(_SW_ES_EFFECTS, "match two")
    else
        push!(_SW_ES_EFFECTS, "no match")
    end
    return join(_SW_ES_EFFECTS, ", ")
end
# infinite_switch_label: cases continuing to each other until a list grows past 10, then thrown
function _sw_isl_do(target::Int64)
    local list = Int64[]
    target == 0 && @goto l0
    target == 1 && @goto l1
    @goto default
    @label l0
    length(list) > 10 && throw(list)
    push!(list, 0)
    @goto l1
    @label l1
    length(list) > 10 && throw(list)
    push!(list, 1)
    @goto l0
    @label default
    push!(list, 2)
    @goto l1
end
_sw_isl_throws(t::Int64, expect::Vector{Int64}) = (try; _sw_isl_do(t); false; catch e; e isa Vector{Int64} && e == expect; end)
# issue_60375: switches on a value's runtime type, and on a nullable runtime type
struct _SwRtC{T}
    v::T
end
const _SW_RT_RETURN_NULL = Ref(false)
_sw_rt_nullable_type(c::_SwRtC) = _SW_RT_RETURN_NULL[] ? nothing : typeof(c)
function _sw_rt_test1(v::Union{_SwRtC{Int64},_SwRtC{String}})
    local t = typeof(v)
    if t == _SwRtC{Int64}
        return "int"
    elseif t == _SwRtC{String}
        return "String"
    else
        return "unknown"
    end
end
function _sw_rt_test2(v::Union{_SwRtC{Int64},_SwRtC{String}})
    local t = _sw_rt_nullable_type(v)
    if t == _SwRtC{Int64}
        return "int"
    elseif t == _SwRtC{String}
        return "String"
    elseif t === nothing
        return "null"
    else
        return "unknown"
    end
end
# label: string cases continuing to a labeled case, forward and backward, and from a nested switch
function _sw_lb_say1(sound::String)
    local x = 0
    sound == "moo" && @goto moo
    sound == "woof" && @goto woof
    @goto default
    @label moo
    x = 100
    @goto done
    @label woof
    x = 200
    @goto moo
    @label default
    x = 300
    @label done
    return x
end
function _sw_lb_say2(sound::String)
    local x = 0
    sound == "woof" && @goto woof
    sound == "moo" && @goto moo
    @goto default
    @label woof
    x = 200
    @goto done
    @label moo
    x = 100
    @goto woof
    @label default
    x = 300
    @label done
    return x
end
function _sw_lb_say3(animal::String, sound::String)
    local x = 0
    animal == "cow" && @goto cow
    animal == "dog" && @goto dog
    animal == "unicorn" && @goto nix
    @goto default
    @label cow
    if sound == "moo"
        x = 100
    elseif sound == "muh"
        x = 200
    else
        @goto nix
    end
    @goto done
    @label dog
    if sound == "woof"
        x = 300
    else
        @goto nix
    end
    @goto done
    @label nix
    x = 400
    @goto done
    @label default
    x = 500
    @label done
    return x
end
# label2: int cases continuing to labeled cases after and before them
function _sw_l2_do(target::Int64)
    local list = Int64[]
    target == 0 && @goto c0
    target == 1 && @goto case1
    target == 2 && @goto case2
    target == 3 && @goto c3
    @goto done
    @label c0
    push!(list, 0)
    @goto case2
    @label case1
    push!(list, 1)
    @goto done
    @label case2
    push!(list, 2)
    @goto done
    @label c3
    push!(list, 3)
    @goto case1
    @label done
    return list
end
# label3: enum cases sharing a body, and a nested switch continuing to the outer switch's label
@enum _SwL3Color _sw_l3_red _sw_l3_green _sw_l3_blue
@enum _SwL3Taste _sw_l3_sweet _sw_l3_sour _sw_l3_salty _sw_l3_bitter _sw_l3_umami
function _sw_l3_get_value(taste::_SwL3Taste, color::_SwL3Color)::Int64
    (taste == _sw_l3_sweet || taste == _sw_l3_sour || taste == _sw_l3_bitter) && return 1
    taste == _sw_l3_salty && @goto salty
    taste == _sw_l3_umami && @goto label
    throw(ErrorException("no case"))
    @label salty
    color == _sw_l3_red && return 2
    color == _sw_l3_blue && @goto label
    color == _sw_l3_green && return 3
    throw(ErrorException("Invalid state."))
    @label label
    return 4
end
# nested_switch_label: an inner switch continuing to its own labels and to the outer switch's
function _sw_ns_do(target::Int64)
    local list = String[]
    target == 0 && @goto outer0
    target == 1 && @goto outer1
    target == 2 && @goto outer2
    @goto outerDefault
    @label outer0
    push!(list, "0")
    @goto outer2
    @label outer1
    push!(list, "1")
    @goto outerDefault
    @label outer2
    target == 0 && @goto inner0
    target == 2 && @goto inner2
    target == 1 && @goto inner1
    @goto inner_end
    @label inner0
    push!(list, "2:0")
    @goto outer1
    @label inner2
    push!(list, "2:2")
    @goto inner1
    @label inner1
    push!(list, "2:1")
    @label inner_end
    push!(list, "2")
    @goto outer1
    @label outerDefault
    push!(list, "default")
    return list
end
# non_primitive_equality: case constants with a custom ==, one equal to Strings, and Float64 cases
struct _SwNpValueType
    value::Int64
end
Base.:(==)(a::_SwNpValueType, other) = other isa _SwNpValueType && a.value == other.value
struct _SwNpEts
    value::String
end
Base.:(==)(a::_SwNpEts, other) = other isa String && a.value == other
const _SW_NP_ONE = _SwNpValueType(1)
const _SW_NP_TWO = _SwNpValueType(2)
const _SW_NP_APE = _SwNpEts("ape")
const _SW_NP_BAT = _SwNpEts("bat")
function _sw_np_value_test(value::Int64)
    local v = _SwNpValueType(value)
    if _SW_NP_ONE == v
        return "one"
    elseif _SW_NP_TWO == v
        return "two"
    else
        return "other"
    end
end
function _sw_np_ets_test(value::String)
    if _SW_NP_APE == value
        return "primate"
    elseif _SW_NP_BAT == value
        return "chiroptera"
    else
        return "other"
    end
end
function _sw_np_double(value::Float64)
    if 0.0 == value
        return "nothing"
    elseif 1.1 == value
        return "one-ish"
    elseif 2.2 == value
        return "two-ish"
    else
        return "other"
    end
end
# null_int_case: a nullable Int64 switched with int cases and a nothing case, shared and constant
const _SW_NI_NULL_CONSTANT = nothing
function _sw_ni_test1(value::Union{Nothing,Int64})
    if value == 55
        return "55"
    elseif value == 352
        return "352"
    elseif value === nothing
        return "null"
    end
    return "no match"
end
_sw_ni_test2(value::Union{Nothing,Int64}) = value === nothing ? "null" : "no match"
function _sw_ni_test3(value::Union{Nothing,Int64})
    if value == 10 || value === nothing
        return "null or 10"
    elseif value == 20
        return "20"
    end
    return "no match"
end
_sw_ni_test4(value::Union{Nothing,Int64}) = value === _SW_NI_NULL_CONSTANT ? "null" : "no match"
# scope: each case declares its own local of one name
function _sw_sc_test(x::Int64)
    if x == 1
        let v = 1
            return v
        end
    elseif x == 2
        let v = 2
            v == 2 || return -1
            return v
        end
    else
        let v = 3
            return v
        end
    end
end
# switch_comparisons_1: a nullable String from UTF-8 bytes matched by switch statements with and
# without a nothing case, a switch expression, an if-case and an if
const _SW_SC1_KTYPE = "PhotographicBox"
const _SW_SC1_OPTION = Ref{Union{Nothing,String}}(nothing)
_sw_sc1_type() = _SW_SC1_OPTION[]
function _sw_sc1_with_null()::Bool
    local t = _sw_sc1_type()
    if _SW_SC1_KTYPE == t
        return true
    elseif t === nothing
        throw(ErrorException("Type is null on SWITCH CASE WITH NULL"))
    else
        throw(ErrorException("Unexpected type on SWITCH CASE WITH NULL: $(_sw_sc1_type())"))
    end
end
function _sw_sc1_without_null()::Bool
    if _SW_SC1_KTYPE == _sw_sc1_type()
        return true
    else
        throw(ErrorException("Unexpected type on SWITCH CASE WITHOUT NULL: $(_sw_sc1_type())"))
    end
end
_sw_sc1_expression()::Bool = (t = _sw_sc1_type(); _SW_SC1_KTYPE == t ? true :
    t === nothing ? throw(ErrorException("Type is null with SWITCH EXPRESSION")) :
    throw(ErrorException("Unexpected type with SWITCH EXPRESSION: $(_sw_sc1_type())")))
function _sw_sc1_if_case()::Bool
    if _SW_SC1_KTYPE == _sw_sc1_type()
        return true
    elseif _sw_sc1_type() === nothing
        throw(ErrorException("Type is null with IF CASE"))
    else
        throw(ErrorException("Unexpected type with IF CASE: $(_sw_sc1_type())"))
    end
end
function _sw_sc1_if_equals()::Bool
    if _sw_sc1_type() == _SW_SC1_KTYPE
        return true
    elseif _sw_sc1_type() === nothing
        throw(ErrorException("Type is null with IF"))
    else
        throw(ErrorException("Unexpected type with IF: $(_sw_sc1_type())"))
    end
end
const _SW_SC_BYTES = UInt8[80, 104, 111, 116, 111, 103, 114, 97, 112, 104, 105, 99, 66, 111, 120]
# switch_comparisons_2: a value of a small union matched against int, String and nothing cases
const _SW_SC2_KTYPE = "PhotographicBox"
function _sw_sc2_test1(v::Union{Nothing,Int64,String})::Bool
    if 1 == v
        throw(ErrorException("int case in switch without null"))
    elseif _SW_SC2_KTYPE == v
        return true
    else
        throw(ErrorException("default case in switch without null"))
    end
end
function _sw_sc2_test2(v::Union{Nothing,Int64,String})::Bool
    if 1 == v
        throw(ErrorException("int case in switch with null"))
    elseif v === nothing
        throw(ErrorException("null case"))
    elseif _SW_SC2_KTYPE == v
        return true
    else
        throw(ErrorException("default case in switch with null"))
    end
end
function _sw_sc2_test3(v::Union{Nothing,Int64,String})::Bool
    if "blah" == v
        throw(ErrorException("string case"))
    elseif _SW_SC2_KTYPE == v
        return true
    else
        throw(ErrorException("default case in string switch"))
    end
end
function _sw_sc2_test4(v::Union{Nothing,Int64,String})::Bool
    if "blah" == v
        throw(ErrorException("string case"))
    elseif v === nothing
        throw(ErrorException("null case"))
    elseif _SW_SC2_KTYPE == v
        return true
    else
        throw(ErrorException("default case in string switch"))
    end
end
function _sw_sc2_test5(v::Union{Nothing,Int64,String})::Bool
    if _SW_SC2_KTYPE == v
        throw(ErrorException("string case"))
    elseif 123 == v
        return true
    else
        throw(ErrorException("default case in switch without null"))
    end
end
function _sw_sc2_test6(v::Union{Nothing,Int64,String})::Bool
    if _SW_SC2_KTYPE == v
        throw(ErrorException("string case"))
    elseif v === nothing
        throw(ErrorException("null case"))
    elseif 123 == v
        return true
    else
        throw(ErrorException("default case in switch with null"))
    end
end
function _sw_sc2_test7(v::Union{Nothing,Int64,String})::Bool
    if 0 == v
        throw(ErrorException("wrong int"))
    elseif 123 == v
        return true
    else
        throw(ErrorException("default case in string switch"))
    end
end
function _sw_sc2_test8(v::Union{Nothing,Int64,String})::Bool
    if 0 == v
        throw(ErrorException("wrong int"))
    elseif v === nothing
        throw(ErrorException("null case"))
    elseif 123 == v
        return true
    else
        throw(ErrorException("default case in string switch"))
    end
end
# switch_dynamic: a Float64 matched against int cases by ==
function _sw_sd_test(x::Union{Int64,Float64})::Int64
    if x == 0
        throw(ErrorException("Test failed"))
    elseif x == 1
        throw(ErrorException("Test failed"))
    elseif x == 2
        throw(ErrorException("Test failed"))
    elseif x == 3
        return Int64(3)
    end
    throw(ErrorException("Test failed"))
end
# switch_legacy: cases on constant integer expressions, several sharing a body
const _SW_SL_IC1 = Int64(1)
const _SW_SL_IC2 = Int64(2)
function _sw_sl_test(input::Int64)::Union{Nothing,Int64}
    local result::Union{Nothing,Int64} = nothing
    if input == 1 + 1 || input == _SW_SL_IC1 + 2
        result = 11
    elseif input == _SW_SL_IC2 * 2 || input == 1 * 5
        result = 21
    elseif input == _SW_SL_IC1 % _SW_SL_IC2 + 5
        result = 31
    end
    return result
end
# switch: int cases sharing bodies and a default, constant-instance cases, Bool, nullable String and
# a constant scrutinee
function _sw_st_test1(val::Int64)
    local x = 0
    if val == 1
        x = 100
    elseif val == 2 || val == 3
        x = 200
    else
        x = 400
    end
    return x
end
_sw_st_test2(val::Int64) = (if val == 1; return 200; else; return 400; end)
struct _SwStEnum
    id::Int64
end
const _SW_ST_E1 = _SwStEnum(1)
const _SW_ST_E2 = _SwStEnum(2)
const _SW_ST_E3 = _SwStEnum(3)
function _sw_st_enum(input::Union{Nothing,_SwStEnum})
    local result::Union{Nothing,Int64} = nothing
    if input == _SW_ST_E1
        result = 10
    elseif input == _SW_ST_E2
        result = 20
    elseif input == _SW_ST_E3
        result = 30
    else
        result = 40
    end
    return result
end
function _sw_st_bool(input::Bool)
    local result::Union{Nothing,Int64} = nothing
    if input == true
        result = 12
    elseif input == false
        result = 22
    end
    return result
end
function _sw_st_string(input::Union{Nothing,String})
    local result::Union{Nothing,Int64} = nothing
    if input == "one"
        result = 1
    elseif input == "two"
        result = 2
    end
    return result
end
function _sw_st_const_string()
    local c = "a"
    if c == "a"
        return "aa"
    elseif c == "b"
        return "bb"
    elseif c == "c"
        return "cc"
    elseif c == "d"
        return "dd"
    elseif c == "e"
        return "ee"
    elseif c == "f"
        return "ff"
    end
    return nothing
end
# switch6: a case whose body is a block ending in break
function _sw_s6_test(a::Int64)
    local x = -1
    if a == 0
        x = 0
    elseif a == 1
        x = 1
    end
    return x
end
# switch8: nothing matched against a constant instance case
struct _SwS8A end
const _SW_S8_A = _SwS8A()
# try_catch: continue to labeled cases, one continue leaving a try block, the last case throwing
function _sw_tc_test(x::Int64, log::Vector{String})
    x == 0 && @goto c0
    x == 1 && @goto c1
    x == 5 && @goto c5
    x == 6 && @goto c6
    @goto done
    @label c0
    push!(log, "_0")
    @goto c5
    @label c1
    try
        push!(log, "bunny")
        @goto c6
    catch e
    end
    @goto done
    @label c5
    push!(log, "_5")
    @goto c6
    @label c6
    push!(log, "_6")
    throw(Int64(555))
    @label done
    return nothing
end
# type_compare: Type values matched against Type cases; a scrutinee's custom == is never used
struct _SwTcFoo end
struct _SwTcBar end
Base.:(==)(::_SwTcFoo, other) = true
Base.:(==)(::_SwTcBar, other) = true
_g("dart_switch", Any[
    ("aborting_switch_case", (x::Int64) -> (exception = Int64(0); try; if x == 42; _sw_ab_foo(); _sw_ab_foo(); end; catch e; exception = e isa Int64 ? e : Int64(-1); end; exception), Int64(42)),
    ("backward_jump", (n::Int64) -> _dw_bits(_sw_bj_test(5n) == "a", _sw_bj_test(10n) == "a through b", _sw_bj_test(7n) == "b"), Int64(1)),
    ("bad_case_runtime", (n::Int64) -> _dw_bits(_sw_bc_caesar(4n) == "IV", _sw_bc_caesar(2n) === nothing, _sw_bc_archimedes(3.14 * n) === nothing), Int64(1)),
    ("case_expression_with_assignment_runtime", (n::Int64) -> _dw_bits(_sw_cea_to_string(_SW_CEA_ERROR_A * n) == "ERROR_A",
        _sw_cea_to_string(_SW_CEA_ERROR_B * n) == "ERROR_B", _sw_cea_to_string(55n) == "Unknown error"), Int64(1)),
    ("case_fallthrough", (n::Int64) -> (s = Int64(0); for i in 0:100; s += _sw_cf_switch(i + n) * (i + 1); end; s), Int64(0)),
    ("case_runtime", (n::Int64) -> (c1 = _SwCrC(n); c2 = _SwCrC(n); c3 = _SwCrC(n); a = _SwCrA();
        _dw_bits(_SW_CR_C != c1, (_SW_CR_C::_SwCrC) != c2, (_SW_CR_C2::_SwCrC) != c3, _SW_CR_A != a)), Int64(0)),
    ("case_static_const", (s::String) -> _sw_csc_foo(s) * 1000 + _sw_csc_foo("S") * 100 + _sw_csc_foo("A.S") * 10 + _sw_csc_foo("abc"), "p"),
    ("enum_compare", (n::Int64) -> _sw_ec_switches(_SwEcLong(29 + n)), Int64(0)),
    ("equality_side_effect", (n::Int64) -> _dw_bits(_sw_es_test(1n) == "S(1) == S(1), match one", _sw_es_test(2n) == "S(1) == S(2), S(2) == S(2), match two",
        _sw_es_test(3n) == "S(1) == S(3), S(2) == S(3), no match"), Int64(1)),
    ("infinite_switch_label", (n::Int64) -> _dw_bits(_sw_isl_throws(0n, Int64[0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0]), _sw_isl_throws(2n, Int64[2, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0])), Int64(1)),
    ("issue_60375", (n::Int64) -> (c1 = _SwRtC(n); c2 = _SwRtC(""); _SW_RT_RETURN_NULL[] = false;
        b = _dw_bits(_sw_rt_test1(c1) == "int", _sw_rt_test1(c2) == "String", _sw_rt_test2(c1) == "int", _sw_rt_test2(c2) == "String");
        _SW_RT_RETURN_NULL[] = true; b2 = _dw_bits(_sw_rt_test2(c1) == "null", _sw_rt_test2(c2) == "null"); _SW_RT_RETURN_NULL[] = false; b * 4 + b2), Int64(1)),
    ("label", (s::String) -> _dw_bits(_sw_lb_say1(s) == 100, _sw_lb_say1("woof") == 100, _sw_lb_say1("cockadoodledoo") == 300,
        _sw_lb_say2(s) == 200, _sw_lb_say2("woof") == 200, _sw_lb_say2("") == 300,
        _sw_lb_say3("cow", s) == 100, _sw_lb_say3("cow", "muh") == 200, _sw_lb_say3("cow", "boeh") == 400, _sw_lb_say3("dog", "woof") == 300,
        _sw_lb_say3("dog", "boj") == 400, _sw_lb_say3("unicorn", "") == 400, _sw_lb_say3("angry bird", "whoooo") == 500), "moo"),
    ("label2", (n::Int64) -> _dw_bits(_sw_l2_do(0n) == [0, 2], _sw_l2_do(1n) == [1], _sw_l2_do(2n) == [2], _sw_l2_do(3n) == [3, 1]), Int64(1)),
    ("label3", (n::Int64) -> _dw_bits(_sw_l3_get_value(_sw_l3_sweet, _sw_l3_blue) == 1, _sw_l3_get_value(_sw_l3_bitter, _sw_l3_blue) == 1,
        _sw_l3_get_value(_sw_l3_salty, _sw_l3_red) == 2, _sw_l3_get_value(_sw_l3_salty, _sw_l3_blue) == 4,
        _sw_l3_get_value(_sw_l3_salty, _sw_l3_green) == 3, _sw_l3_get_value(_sw_l3_umami, _sw_l3_red) == 4) + n, Int64(0)),
    ("nested_switch_label", (n::Int64) -> _dw_bits(_sw_ns_do(0n) == ["0", "2:0", "1", "default"], _sw_ns_do(2n) == ["2:2", "2:1", "2", "1", "default"]), Int64(1)),
    ("non_primitive_equality", (n::Int64) -> _dw_bits(_sw_np_value_test(1n) == "one", _sw_np_value_test(2n) == "two", _sw_np_value_test(3n) == "other",
        _sw_np_ets_test("ape") == "primate", _sw_np_ets_test("bat") == "chiroptera", _sw_np_ets_test("cat") == "other",
        _sw_np_double(0.0 * n) == "nothing", _sw_np_double(-0.0 * n) == "nothing", _sw_np_double(1.1 * n) == "one-ish",
        _sw_np_double(2.2 * n) == "two-ish", _sw_np_double(3.3 * n) == "other"), Int64(1)),
    ("null_int_case", (n::Int64) -> (nn = n == 1 ? nothing : n;
        _dw_bits(_sw_ni_test1(55n) == "55", _sw_ni_test1(352n) == "352", _sw_ni_test1(nn) == "null", _sw_ni_test1(38792n) == "no match",
                 _sw_ni_test2(0n) == "no match", _sw_ni_test2(nn) == "null", _sw_ni_test3(10n) == "null or 10", _sw_ni_test3(nn) == "null or 10",
                 _sw_ni_test3(20n) == "20", _sw_ni_test3(28132n) == "no match", _sw_ni_test4(_SW_NI_NULL_CONSTANT) == "null", _sw_ni_test4(2189n) == "no match")), Int64(1)),
    ("scope", (n::Int64) -> _sw_sc_test(n) * 100 + _sw_sc_test(Int64(2)) * 10 + _sw_sc_test(Int64(7)), Int64(1)),
    ("switch_comparisons_1", (n::Int64) -> (_SW_SC1_OPTION[] = String(copy(_SW_SC_BYTES));
        _dw_bits(_sw_sc1_with_null(), _sw_sc1_without_null(), _sw_sc1_expression(), _sw_sc1_if_case(), _sw_sc1_if_equals()) + n), Int64(0)),
    ("switch_comparisons_2", (n::Int64) -> (s = String(copy(_SW_SC_BYTES)); i = parse(Int64, "123") + n;
        _dw_bits(_sw_sc2_test1(s), _sw_sc2_test2(s), _sw_sc2_test3(s), _sw_sc2_test4(s), _sw_sc2_test5(i), _sw_sc2_test6(i), _sw_sc2_test7(i), _sw_sc2_test8(i))), Int64(0)),
    ("switch_dynamic", (x::Float64) -> (try; _sw_sd_test(x); catch e; e isa ErrorException ? Int64(-1) : Int64(-2); end), 3.0),
    ("switch_legacy", (n::Int64) -> _dw_bits(_sw_sl_test(2n) == 11, _sw_sl_test(3n) == 11, _sw_sl_test(4n) == 21, _sw_sl_test(5n) == 21,
        _sw_sl_test(6n) == 31, _sw_sl_test(7n) === nothing), Int64(1)),
    ("switch", (n::Int64) -> _dw_bits(_sw_st_test1(1n) == 100, _sw_st_test1(2n) == 200, _sw_st_test1(3n) == 200, _sw_st_test1(4n) == 400,
        _sw_st_test1(5n) == 400, _sw_st_test2(1n) == 200, _sw_st_test2(2n) == 400,
        _sw_st_enum(_SW_ST_E1) == 10, _sw_st_enum(_SW_ST_E2) == 20, _sw_st_enum(_SW_ST_E3) == 30, _sw_st_enum(nothing) == 40,
        _sw_st_bool(n == 1) == 12, _sw_st_bool(n != 1) == 22,
        _sw_st_string(nothing) === nothing, _sw_st_string("one") == 1, _sw_st_string("two") == 2, _sw_st_string("three") === nothing,
        _sw_st_const_string() == "aa"), Int64(1)),
    ("switch6", (n::Int64) -> _sw_s6_test(n), Int64(0)),
    ("switch8", (n::Int64) -> (v = Union{Nothing,_SwS8A}[nothing][n]; _SW_S8_A == v ? Int64(-1) : Int64(0)), Int64(1)),
    ("try_catch", (x::Int64) -> (log = String[]; r = (try; _sw_tc_test(x, log); Int64(0); catch e; e isa Int64 && e == 555 ? Int64(1) : Int64(2); end);
        r * 10 + length(log)), Int64(0)),
    ("type_compare", (s::String) -> (c = parse(Int64, s) == 1; se1 = c ? _SwTcFoo() : _SwTcBar(); se2 = c ? Vector{Int64} : _SwTcBar();
        se4 = c ? Vector{String} : _SwTcFoo(); se5 = c ? Vector{Any} : Int64;
        _dw_bits(!(Any == se1), Vector{Int64} == se2, !(Any == se2), Vector{String} == se4, Vector{Any} == se5)), "1"),
])

# ---- dart2wasm's tests at the pin, tests/language/const ------------------------------------------
# dart const values become Julia const globals, immutable structs (equal instances are ===, Julia's
# canonical identity), tuples and named tuples; the expected value is what native Julia computes.
# shared: an identity function the compiler may not see through (dart's getValueNonOptimized)
@noinline _co_gv(x) = x
@noinline _co_gv_t(x::DataType)::DataType = x
# cast1: a struct's Int64 field initialized from an untyped constructor argument
struct _CoCast1A
    n::Int64
end
_co_cast1(input) = _CoCast1A(input)
# cast2: the same field initialized through an explicit cast of the argument
struct _CoCast2A
    n::Int64
end
_co_cast2(input::Union{Int64,String}) = _CoCast2A(input::Int64)
# cast3: a parametric struct bounded by an abstract type, its field cast to the parameter
abstract type _CoCast3A end
struct _CoCast3B <: _CoCast3A end
struct _CoCast3M{T<:_CoCast3A}
    a::T
end
_co_cast3_m(::Type{T}, t) where {T} = _CoCast3M{T}(t)
# cast4: a subclass constructor forwarding the cast argument to the parametric superclass
struct _CoCast4N{S<:_CoCast3A}
    m::_CoCast3M{S}
    _CoCast4N{S}(t) where {S} = new{S}(_CoCast3M{S}(t))
end
# conditional: constant conditionals choosing between two constant instances
struct _CoMarker
    field::Int64
end
const _co_cond_const0 = _CoMarker(0)
const _co_cond_const1 = _CoMarker(1)
const _co_cond_true = true
const _co_cond_false = false
const _co_cond1 = _co_cond_true ? _co_cond_const0 : _co_cond_const1
const _co_cond2 = _co_cond_false ? _co_cond_const0 : _co_cond_const1
# const: a const instance's field, a getter and an index operator read then written back (x++)
struct _CoAConst
    b_::Int64
    _CoAConst() = new(3)
end
struct _CoBConst end
_co_bconst_foo(::_CoBConst) = Int64(5)
_co_bconst_set_foo!(::_CoBConst, v) = nothing
Base.getindex(::_CoBConst, ix::Int64) = ix
Base.setindex!(::_CoBConst, v, ix::Int64) = nothing
# const2: constants of every literal kind and constant arithmetic, comparison, logic and bit
# operations over them (dart's hex int literals written decimal: Julia's 0x.. literals are unsigned)
const _co_c2_b = true
const _co_c2_s = "apple"
const _co_c2_i = 1
const _co_c2_d = 3.3
const _co_c2_h = 15
const _co_c2_n = nothing
const _co_c2_alist = (1, 2, 3)
const _co_c2_amap = Dict("1" => "one", "2" => "banana")
const _co_c2_int_lit = 5
const _co_c2_int_lit_ref = _co_c2_int_lit
const _co_c2_double_lit = 1.5
const _co_c2_bool_lit = true
const _co_c2_string_lit = "Hello"
const _co_c2_ints = let L = _co_c2_int_lit
    (L + 1, 1 + L, L - 1, 1 - L, L * 1, 1 * L, 5 % L, L % 5, 128 & 4, 128 | 4, 128 << 4, 128 >> 4, div(128, 4), 128 ⊻ 4,
     (1 * 2) + 3, 3 + (1 * 2), ~240, ~L, ~L & 123, ~(L | 255), -240, -L, -L + 123, -(L * 255))
end
const _co_c2_floats = let L = _co_c2_int_lit, D = _co_c2_double_lit
    (L / 1, 1 / L, D + 1.5, 1.5 + D, D - 1.5, 1.5 - D, D * 1.5, 1.5 * D, D / 1.5, 1.5 / D, 5.0 % D, D % 5.0,
     1 * L / 3 + L + 9, -D, -D + 123, -(D * 255))
end
const _co_c2_bools = let L = _co_c2_int_lit, D = _co_c2_double_lit, B = _co_c2_bool_lit, S = _co_c2_string_lit
    (2 < L, L < 2, 2 > L, L > 2, 2 < D, D < 2, 2 > D, D > 2, 2 <= L, L <= 2, 2 >= L, L >= 2, 2.0 <= D, D <= 2.0, 2.0 >= D, D >= 2,
     B && true, false || B, S == "World!", "Hello" != S, L == _co_c2_int_lit_ref, B != true, (1 > 2), !B, B || !true, !B || true, !(B && true))
end
# const3: a constant computed from other constants (Julia needs them defined first)
const _co_const3_n = 1
const _co_const3_o = 1 + 3
const _co_const3_p = 2 * (_co_const3_o - _co_const3_n)
# const4: a constant initialized from a constant of another module
module _CoConst4Lib
const _co_const4_b = 1
end
const _co_const4_a = _CoConst4Lib._co_const4_b
# constant_dag: a constant DAG of 41 nodes, each node's two children the same node
struct _CoNode
    a::Union{Nothing,_CoNode}
    b::Union{Nothing,_CoNode}
end
function _co_node_length_a(n::_CoNode)::Int64
    local a = n.a
    return a === nothing ? Int64(0) : 1 + _co_node_length_a(a)
end
function _co_node_length_b(n::_CoNode)::Int64
    local b = n.b
    return n.a === nothing ? Int64(0) : 1 + _co_node_length_b(b::_CoNode)
end
const _co_dag_n40 = let n = _CoNode(nothing, nothing)
    for _ in 1:40
        n = _CoNode(n, n)
    end
    n
end
# constant_type_variable: a constructor whose fields are its type parameter, a type built from it,
# an isa test against it and an empty list cast to a list of it
struct _CoCtvA{X}
    t1::DataType
    t2::DataType
    x1::Bool
    x2::Vector{<:X}
    _CoCtvA{X}() where {X} = new{X}(X, Vector{X}, 1 isa X, Union{}[]::Vector{<:X})
end
# constructor_mixin: a constructor of a type with an empty mixin forwarding an ignored argument
abstract type _CoMixin end
struct _CoMixB <: _CoMixin end
_CoMixB(foo) = _CoMixB()
# constructor_mixin3: a zero-argument constructor of a type with an empty mixin
struct _CoMix3B <: _CoMixin end
# constructor_super2: a subclass constructor storing its own field and forwarding one to its super
struct _CoCs2B
    a::Int64
    b::Int64
end
@noinline _co_cs2_foo() = _CoCs2B(1, 2)
@noinline _co_cs2_bar() = _CoCs2B(2, 2)
# constructor: a named constructor of a parametric type alongside a non-const unnamed one
struct _CoCtA{T}
    x::Int64
end
_co_ct_named(::Type{T}) where {T} = _CoCtA{T}(42)
_CoCtA{T}() where {T} = _CoCtA{T}(-1)
# constructor2: a parametric type's constructors (typed, optional, named, untyped) inferring the
# parameter, and redirecting factories through a chain of parametric types
abstract type _CoC2AbsA{T} end
struct _CoC2A{T} <: _CoC2AbsA{T} end
struct _CoC2B{S} <: _CoC2AbsA{S} end
struct _CoC2C{U}
    a::_CoC2AbsA{U}
end
_co_c2_c(a::_CoC2AbsA{U}) where {U} = _CoC2C{U}(a)
_co_c2_optional(a::_CoC2AbsA = _CoC2A{Any}()) = _co_c2_c(a)
_co_c2_named(; a) = _co_c2_c(a)
_co_c2_untyped(a) = _co_c2_c(a)
abstract type _CoC2E end
abstract type _CoC2AbsF{V} <: _CoC2E end
struct _CoC2F{V} <: _CoC2AbsF{V}
    field::V
end
struct _CoC2G{W} <: _CoC2AbsF{W}
    field::W
end
_co_c2_f_redirecting(::Type{V}, field) where {V} = _CoC2G{V}(field)
_co_c2_e_redirecting1(a::Int64) = _CoC2F{Int64}(a)
_co_c2_e_redirecting2(a::Int64) = _co_c2_f_redirecting(Int64, a)
_co_c2_e_redirecting3(a::Float64) = _co_c2_f_redirecting(Float64, a)
# constructor3: constant instances of a Float64-field type and of its subclass
abstract type _CoCtor3Abs end
struct _CoCtor3C <: _CoCtor3Abs
    d::Float64
end
struct _CoCtor3D <: _CoCtor3Abs
    d::Float64
end
const _co_ctor3_c = _CoCtor3C(0.0)
const _co_ctor3_e = _CoCtor3D(0.0)
# ct_const: canonical constant instances, a user ==, constant lists and string-keyed maps compared by
# identity, and a constant map that cannot be modified
const _co_ct_ii = 2
const _co_ct_iv = 4
const _co_ct_v = 5
const _co_ct_viva_italia = (green = 1, red = 3, white = 2)
struct _CoCtPoint
    x_::Int64
    y_::Int64
end
Base.:(==)(a::_CoCtPoint, b::_CoCtPoint) = (a.x_ == b.x_) && (a.y_ == b.y_)
const _co_ct_zero = 0
const _co_ct_origin = _CoCtPoint(0, 0)
const _co_ct_origin2 = _CoCtPoint(_co_ct_zero, _co_ct_iv - 4)
_co_ct_point_x(x::Int64) = _CoCtPoint(x, _co_ct_v - _co_ct_ii - 3)
struct _CoCtLine
    beg_::_CoCtPoint
    end_::_CoCtPoint
end
@noinline _co_ct_get_zero() = Int64(0)
const _co_ct_naught = nothing
_co_ct_set_green(m) = (try; setfield!(m, :green, 0); false; catch e; e isa ErrorException; end)
# double_in_int_op: constant bitwise and shift operators on two Int64 constants
const _co_diio_i1 = 3
const _co_diio_i2 = 2
const _co_diio_sum = 0 + (_co_diio_i1 | _co_diio_i2) + (_co_diio_i1 & _co_diio_i2) + (_co_diio_i1 ⊻ _co_diio_i2) +
    (_co_diio_i1 << _co_diio_i2) + (_co_diio_i1 >> _co_diio_i2) + (_co_diio_i1 >>> _co_diio_i2) + 0
# dynamic_type_literal: type literals as constants, identical to themselves and distinct map keys
const _co_dtl_d = Any
const _co_dtl_i = Int64
# escape_frog: a field initialized to a constant instance of a type parameterized by its owner
struct _CoFrogBar{T} end
struct _CoFrogFoo
    bar::_CoFrogBar{_CoFrogFoo}
end
_CoFrogFoo() = _CoFrogFoo(_CoFrogBar{_CoFrogFoo}())
# evaluation: identical(-0.0, 0) evaluated as a constant, a global, a field and a local agree
const _co_ev_top_const = -0.0 === 0
const _co_ev_top_final = -0.0 === 0
global _co_ev_top_var::Bool = -0.0 === 0
const _co_ev_static_const = -0.0 === 0
const _co_ev_static_final = -0.0 === 0
global _co_ev_static_var::Bool = -0.0 === 0
mutable struct _CoEvC
    instance_final::Bool
    instance_var::Bool
    _CoEvC() = new(-0.0 === 0, -0.0 === 0)
end
function _co_ev_test(c::_CoEvC, z::Int64)
    local local_const = -0.0 === 0
    local local_final = -0.0 === 0
    local local_var = -0.0 === z
    return _dw_bits((-0.0 === z) == _co_ev_top_const, _co_ev_top_const == _co_ev_top_final, _co_ev_top_final == _co_ev_top_var,
        _co_ev_top_var == _co_ev_static_const, _co_ev_static_const == _co_ev_static_final, _co_ev_static_final == _co_ev_static_var,
        _co_ev_static_var == c.instance_final, c.instance_final == c.instance_var, c.instance_var == local_const,
        local_const == local_final, local_final == local_var, _co_ev_top_const)
end
# factory_member: an abstract type whose constructor is a factory of a concrete subtype with an
# optional field default; the factory's instance is identical to the subtype's
abstract type _CoFmA end
struct _CoFmB <: _CoFmA
    x1::Tuple{}
    x5::Union{Nothing,Float64}
end
_CoFmB(x5::Float64 = 0.57721566490153286) = _CoFmB((), x5)
_CoFmA() = _CoFmB()
_co_fm_x2(::_CoFmB) = "B.x2"
_co_fm_x3(::_CoFmB) = Int64(42)
_co_fm_x4(::_CoFmB) = Int64(-42)
# factory_redirection: an abstract type's constructor redirecting to a concrete subtype, cast back
abstract type _CoFrC end
struct _CoFrD <: _CoFrC
    i::Int64
end
_CoFrC(x::Int64) = _CoFrD(x)
_co_fr_m(::_CoFrD) = "called m"
# global: a global constant passed to a constructor and stored in a constant list
const _co_gl_a = 1
struct _CoGlA{T}
    a::T
end
# inference: a generic function returning one constant whatever its type parameters, the constant's
# element type the least closure (Never, Julia's Union{})
_co_inf_const_function(_) = throw(ErrorException("uncalled"))
struct _CoInfC{T,F}
    fn::F
end
const _co_inf_c = _CoInfC{Union{},typeof(_co_inf_const_function)}(_co_inf_const_function)
_co_inf_get_c(::Type{T}) where {T} = _co_inf_c
const _co_inf_list = Union{}[]
_co_inf_get_list(::Type{T}) where {T} = _co_inf_list
const _co_inf_implicit = (Union{}[],)
_co_inf_get_implicit_list(::Type{T}) where {T} = _co_inf_implicit[1]
const _co_inf_set = Set{Union{}}()
_co_inf_get_set(::Type{T}) where {T} = _co_inf_set
const _co_inf_map = Dict{Union{},Union{}}()
_co_inf_get_map(::Type{K}, ::Type{V}) where {K,V} = _co_inf_map
_co_inf_get_function(::Type{T}, ::Type{R}) where {T,R} = (_co_inf_const_function,)[1]
# init: static constants computed from one another and a constant instance
struct _CoInitPoint
    x_::Int64
    y_::Int64
end
const _co_init_n = 1
const _co_init_o = 1 + 3
const _co_init_p = 2 * (_co_init_o - _co_init_n)
const _co_init_q = _CoInitPoint(0, 0)
const _co_init_q2 = _CoInitPoint(0, 0)
# init2: a Float64 constant
const _co_init2_c = 0.0
# instantiated_function_constant: generic functions held as constants, chosen by constant
# conditionals and ?? and stored in a parametric struct's fields
_co_ifc_f1(x::X, n::Number = 0, xList::Tuple = ()) where {X<:Number} = nothing
_co_ifc_f2(y::Y, i::Int64 = 1, yMap::Tuple = ()) where {Y<:Number} = nothing
const _co_ifc_c01 = _co_ifc_f1
const _co_ifc_c02 = _co_ifc_f2
struct _CoIfcA{U<:Number}
    x1::Function
    x2::Function
    x5::Function
    x7::Function
    x9::Function
    _CoIfcA{U}(b::Bool) where {U<:Number} = new{U}(b ? (b ? _co_ifc_f1 : _co_ifc_f2) : (b ? _co_ifc_f1 : _co_ifc_f2),
        b ? (b ? _co_ifc_c01 : _co_ifc_c02) : (b ? _co_ifc_c01 : _co_ifc_c02), Base.something(nothing, _co_ifc_f1),
        b ? _co_ifc_f1 : _co_ifc_f2, Base.something(nothing, _co_ifc_c02))
end
# locals: local constants computed from a global, interpolated into a string and stored in
# constant instances compared by identity
const _co_lo_n = 8
struct _CoLoFoo{T}
    x::T
end
function _co_lo_check(mn::Int64, mx::Int64, mask::Int64)
    local s = "MIN = $mn  MAX = $mx  MASK = $mask"
    local cf1 = _CoLoFoo(mask)
    local cf2 = _CoLoFoo(s)
    local cf3 = _CoLoFoo("MIN = $mn  MAX = $mx  MASK = $mask")
    return _dw_bits(mn == 1, mx == 16, mask == 65535, s === "MIN = $mn  MAX = $mx  MASK = $mask", s == "MIN = 1  MAX = 16  MASK = 65535",
        cf2 === cf3, !(cf2 === cf1))
end
# nested: the same local constants captured by a closure returned from their function
function _co_nested_closure(x::Int64)
    local mn = 2 - x
    local mx = _co_lo_n * 2
    local mask = (1 << (mx - mn + 1)) - 1
    return () -> _co_lo_check(mn, mx, mask)
end
# map_hashcode_override, map_hashcode_override_legacy: a constant map keyed by identity, one key's
# type defining a hash that throws, never called
struct _CoNasty
    n::Int64
end
Base.hash(::_CoNasty, ::UInt) = throw(ErrorException("Evil hashCode"))
const _co_nasty_map = IdDict{Union{Int64,String,_CoNasty},Union{Int64,String}}((1 => 42, "foo" => 499, 2 => "bar", _CoNasty(1) => "baz"))
function _co_nasty_check(x::Int64)
    local m = _co_nasty_map
    return _dw_bits(get(m, _co_gv(1.0), nothing) == 42, get(m, _co_gv(String(['f', 'o', 'o'])), nothing) == 499,
        get(m, _co_gv(2x), nothing) == "bar", get(m, _co_gv(_CoNasty(x)), nothing) === nothing, get(m, _co_gv(_CoNasty(1)), nothing) == "baz")
end
# map_hashcode_override2(_legacy), set_hashcode_override2(_legacy): keys of a mutable type (identity
# equality) with a user hash, the constant map and set built from the one canonical constant instance
mutable struct _CoMyClass
    n::Int64
end
Base.hash(x::_CoMyClass, h::UInt) = hash(x.n, h) + UInt(1)
const _co_mc_const = _CoMyClass(1)
const _co_mc_const_map = Dict{_CoMyClass,Int64}(_co_mc_const => 11)
const _co_mc_const_set = Set{_CoMyClass}((_co_mc_const,))
function _co_mc_map_check(x::Int64)
    local ci = _co_mc_const
    local nci = _CoMyClass(x)
    local cm = _co_mc_const_map
    local m2 = Dict{_CoMyClass,Int64}(ci => 11)
    local m3 = Dict{_CoMyClass,Int64}(nci => 11)
    return _dw_bits(ci != nci, haskey(cm, _co_gv(ci)), haskey(cm, _co_gv(nci)), haskey(m2, _co_gv(ci)), haskey(m2, _co_gv(nci)),
        haskey(m3, _co_gv(ci)), haskey(m3, _co_gv(nci)), get(cm, _co_gv(ci), nothing) == 11, get(cm, _co_gv(nci), nothing) === nothing,
        get(m2, _co_gv(ci), nothing) == 11, get(m2, _co_gv(nci), nothing) === nothing, get(m3, _co_gv(ci), nothing) === nothing,
        get(m3, _co_gv(nci), nothing) == 11)
end
function _co_mc_set_check(x::Int64)
    local ci = _co_mc_const
    local nci = _CoMyClass(x)
    local s2 = Set{_CoMyClass}((ci,))
    local s3 = Set{_CoMyClass}((nci,))
    return _dw_bits(ci != nci, _co_gv(ci) in _co_mc_const_set, _co_gv(nci) in _co_mc_const_set, _co_gv(ci) in s2, _co_gv(nci) in s2,
        _co_gv(ci) in s3, _co_gv(nci) in s3)
end
# map_null_lookup: constant maps with and without a nothing key, looked up with nothing
const _co_mnl_map1 = Dict{Union{Nothing,Int64,String},Union{Int64,String}}(1 => 42, nothing => 2, "asdf" => "fdsa")
const _co_mnl_map2 = Dict{Union{Nothing,Int64,String},Union{Int64,String}}(1 => 42, 2 => 2, "asdf" => "fdsa")
# map: a constant map looked up by ==-equal keys, every attempt to modify it throwing and leaving it
# unchanged (Julia's immutable map, Base.ImmutableDict)
const _co_mt_map = let d = Base.ImmutableDict{Union{Int64,String},Union{Int64,String}}()
    d = Base.ImmutableDict(d, 1 => 42)
    d = Base.ImmutableDict(d, "foo" => 499)
    Base.ImmutableDict(d, 2 => "bar")
end
_co_mt_lookups(m) = _dw_bits(get(m, _co_gv(1.0), nothing) == 42, get(m, _co_gv(String(['f', 'o', 'o'])), nothing) == 499,
    get(m, _co_gv(2), nothing) == "bar", get(m, 1024, nothing) === nothing)
_co_mt_modify(m, f::Symbol) = (try; setfield!(m, f, 1024); false; catch e; e isa ErrorException; end)
# map4: maps compared by ==, fresh ones and constants of differing key and value types
const _co_map4_ca = Dict(1 => "a", 2 => "b", 3 => "c")
const _co_map4_cb = Dict(1 => "a", 2 => "b", 3 => "c")
const _co_map4_ctyped = Dict{Int64,String}(1 => "a", 2 => "b", 3 => "c")
const _co_map4_cnum = Dict{Union{Int64,Float64},String}(1 => "a", 2 => "b", 3 => "c")
const _co_map4_cdyn = Dict{Union{Int64,String},Union{Int64,String}}(1 => "a", 2 => "b", 3 => "c")
# map5: a constant map keyed by type literals (a struct, a type alias, a function type), looked up
struct _CoM5A end
struct _CoM5C{T} end
const _CoM5Cint = _CoM5C{Int64}
const _CoM5F = Function
const _co_m5_a_type = _CoM5A
const _co_m5_f_type = _CoM5F
const _co_m5_cint_type = _CoM5Cint
const _co_m5_map = Dict{Union{DataType,String},Union{Int64,String}}(_CoM5A => 42, _CoM5F => 2, "asdf" => "fdsa", _CoM5Cint => "foo")
# set5: a constant set holding the same type literals, looked up
const _co_s5_set = Set{Union{DataType,String,Int64}}((_CoM5A, 1, "asdf", _CoM5F, _CoM5Cint))
# named: a constant built by a keyword constructor, read through a derived accessor
struct _CoDuration
    microseconds::Int64
end
_CoDuration(; milliseconds::Int64 = 0) = _CoDuration(milliseconds * 1000)
_co_in_milliseconds(d::_CoDuration) = div(d.microseconds, 1000)
# objects_are_immutable: a constant list, map and instance whose writes throw and leave them unchanged
struct _CoOaiA
    x::Int64
    y::Int64
end
_co_oai_set_list(l::Tuple{Int64,Int64}) = (try; setfield!(l, 1, 3); false; catch e; e isa ErrorException; end)
_co_oai_set_map(m::@NamedTuple{foo::Int64}) = (try; setfield!(m, :foo, 42); false; catch e; e isa ErrorException; end)
_co_oai_set_a(a::_CoOaiA) = (try; a.x = 499; false; catch e; e isa ErrorException; end)
# primitive_equality: a constant set of values with primitive equality (nothing, Bools, Int64s,
# Strings, Symbols, instances, an enum value); Julia's isequal makes false and 0 one element
@enum _CoPeE _co_pe_one
struct _CoPeA
    o::Bool
end
struct _CoPeB1 end
const _co_pe_set = Set{Union{Nothing,Bool,Int64,String,Symbol,_CoPeA,_CoPeB1,_CoPeE}}((nothing, true, false, 0, -100000, "Hello!",
    :symbol, :+, Symbol(" "), _CoPeA(true), _CoPeB1(), _co_pe_one))
# qq: ?? (Julia: a === nothing ? b : a) in constants, a constructor's defaults and initializers and
# local constant lists
struct _CoQqObj end
const _CoQqV = Union{Nothing,_CoQqObj,Int64}
const _co_qq_the_null = nothing
const _co_qq_not_null = _CoQqObj()
_co_qq(a, b) = a === nothing ? b : a
const _co_qq_test1 = _co_qq(_co_qq_the_null, _co_qq_not_null)
const _co_qq_test2 = _co_qq(_co_qq_not_null, _co_qq_the_null)
const _co_qq_test3 = _co_qq(_co_qq_the_null, _co_qq(_co_qq_the_null, _co_qq_not_null))
const _co_qq_test4 = _co_qq(_co_qq_the_null, _co_qq(_co_qq_the_null, _co_qq_the_null))
const _co_qq_static = (_co_qq(_co_qq_the_null, _co_qq_not_null), _co_qq(_co_qq_not_null, _co_qq_the_null),
    _co_qq(_co_qq_the_null, _co_qq(_co_qq_the_null, _co_qq_not_null)), _co_qq(_co_qq_the_null, _co_qq(_co_qq_the_null, _co_qq_the_null)))
struct _CoQqC
    test9::_CoQqV
    test10::_CoQqV
    test11::_CoQqV
    test12::_CoQqV
    test13::_CoQqV
    test14::_CoQqV
    test15::_CoQqV
    test16::_CoQqV
    test17::_CoQqV
end
function _co_qq_c(x::Union{Nothing,Int64}, t9::_CoQqV = _co_qq(_co_qq_the_null, _co_qq_not_null),
                  t10::_CoQqV = _co_qq(_co_qq_not_null, _co_qq_the_null),
                  t11::_CoQqV = _co_qq(_co_qq_the_null, _co_qq(_co_qq_the_null, _co_qq_not_null)),
                  t12::_CoQqV = _co_qq(_co_qq_the_null, _co_qq(_co_qq_the_null, _co_qq_the_null)))
    local tn = _co_qq_the_null
    local nn = _co_qq_not_null
    return _CoQqC(t9, t10, t11, t12, _co_qq(tn, x), _co_qq(nn, x), _co_qq(x, nn), _co_qq(tn, _co_qq(tn, x)), _co_qq(tn, _co_qq(x, nn)))
end
function _co_qq_method_local(::_CoQqC)
    local test18 = _co_qq(_co_qq_the_null, _co_qq_not_null)
    local test19 = _co_qq(_co_qq_not_null, _co_qq_the_null)
    local test20 = _co_qq(_co_qq_the_null, _co_qq(_co_qq_the_null, _co_qq_not_null))
    local test21 = _co_qq(_co_qq_the_null, _co_qq(_co_qq_the_null, _co_qq_the_null))
    return (test18, test19, test20, test21)
end
_co_qq_expression_local(::_CoQqC) = (_co_qq(_co_qq_the_null, _co_qq_not_null), _co_qq(_co_qq_not_null, _co_qq_the_null),
    _co_qq(_co_qq_the_null, _co_qq(_co_qq_the_null, _co_qq_not_null)), _co_qq(_co_qq_the_null, _co_qq(_co_qq_the_null, _co_qq_the_null)))
# redirect_skips_supertype: a constructor redirecting to a named one that leaves the field nothing
struct _CoRssC
    x::Nothing
end
_co_rss_c_named() = _CoRssC(nothing)
_CoRssC() = _co_rss_c_named()
const _co_rss_y = _CoRssC()
# redirecting_factory: factories redirecting to a keyword constructor with defaults, in either order
struct _CoRfK
    field1::Int64
    field2::Bool
end
_CoRfK(; field1::Int64 = 42, field2::Bool = true) = _CoRfK(field1, field2)
_co_rf_l() = _CoRfK()
_co_rf_l_named1(; kw...) = _CoRfK(; kw...)
_co_rf_l_named2(; kw...) = _CoRfK(; kw...)
const _co_rf_l1 = _co_rf_l()::_CoRfK
const _co_rf_l2a = _co_rf_l_named1()::_CoRfK
const _co_rf_l2b = _co_rf_l_named1(field1 = 87)::_CoRfK
const _co_rf_l2c = _co_rf_l_named1(field2 = false)::_CoRfK
const _co_rf_l2d = _co_rf_l_named1(field1 = 87, field2 = false)::_CoRfK
const _co_rf_l2e = _co_rf_l_named1(field2 = false, field1 = 87)::_CoRfK
const _co_rf_l3a = _co_rf_l_named2()::_CoRfK
const _co_rf_l3b = _co_rf_l_named2(field1 = 87)::_CoRfK
const _co_rf_l3c = _co_rf_l_named2(field2 = false)::_CoRfK
const _co_rf_l3d = _co_rf_l_named2(field1 = 87, field2 = false)::_CoRfK
const _co_rf_l3e = _co_rf_l_named2(field2 = false, field1 = 87)::_CoRfK
_co_rf_is(k::_CoRfK, f1::Int64, f2::Bool) = k.field1 == f1 && k.field2 == f2
# string: string constants identical whatever their quotes, concatenation or interpolation
const _co_str_yz = "y" * "z"
# switch: constant instances matched by identity, an Int64 field never identical to a Float64 one
struct _CoSwC
    field::Union{Int64,Float64}
end
const _co_sw_c1 = _CoSwC(0.0)
const _co_sw_c2 = _CoSwC(0)
const _co_sw_c3 = _CoSwC(0.5 + 0.5)
const _co_sw_c4 = _CoSwC(1)
_co_sw_test(c::_CoSwC) = c === _CoSwC(0.0) ? Int64(1) : c === _CoSwC(0) ? Int64(2) : c === _CoSwC(1.0) ? Int64(3) :
    c === _CoSwC(1) ? Int64(4) : Int64(0)
# syntax: local and global constants, a constant instance, constants from constants, an
# interpolated constant string and identical over constant instances
struct _CoSyPoint
    x::Int64
    y::Int64
end
const _co_sy_f0 = 42
const _co_sy_f2 = 87
const _co_sy_p0 = _CoSyPoint(0, 0)
const _co_sy_a0 = 42
const _co_sy_a1 = _co_sy_a0 + 1
const _co_sy_b0 = 42
const _co_sy_b1 = "Hello"
const _co_sy_b2 = "$_co_sy_b1 $_co_sy_b0"
const _co_sy_b5 = 1 === _CoSyPoint(1, 2)
# tree: a constant whose keyword default is a constant empty list, nested in another constant
struct _CoTreeA
    children::Vector{_CoTreeA}
end
const _co_tree_empty = _CoTreeA[]
_CoTreeA(; children::Vector{_CoTreeA} = _co_tree_empty) = _CoTreeA(children)
const _co_tree_a = _CoTreeA()
const _co_tree_b = _CoTreeA(children = [_co_tree_a])
# types: constant empty containers of a parametric type, its instances, and factories redirecting
# to it from a supertype
abstract type _CoTySupertype end
struct _CoTyClass{T} <: _CoTySupertype end
_CoTySupertype() = _CoTyClass{Any}()
_co_ty_class_named(::Type{T}) where {T} = _CoTyClass{T}()
_co_ty_generic_supertype(::Type{T}) where {T} = _CoTyClass{T}()
# var: untyped, typed and generic constants, global and local, and a parametric type's constant
# instances from this module and from a helper module
module _CoVarHelper
struct _CoVarHelperFoo{E} end
end
const _co_var_untyped_top = 1
const _co_var_typed_top = Int64(2)
const _co_var_generic_top = Dict{String,String}()
struct _CoVarFoo{E} end
_g("dart_const", Any[
    ("cast1", (x::Int64) -> _co_cast1(x + 1).n, Int64(1)),
    ("cast2", (x::Int64) -> _co_cast2(x + 1).n, Int64(1)),
    ("cast3", (x::Int64) -> (m = _co_cast3_m(_CoCast3B, _CoCast3B()); _dw_bits(m isa _CoCast3M{_CoCast3B}, m.a === _CoCast3B()) * x), Int64(1)),
    ("cast4", (x::Int64) -> (n = _CoCast4N{_CoCast3B}(_CoCast3B()); _dw_bits(n isa _CoCast4N{_CoCast3B}, n.m isa _CoCast3M{_CoCast3B}, n.m.a === _CoCast3B()) * x), Int64(1)),
    ("conditional", (x::Int64) -> (var0 = _CoMarker(x - 1); var1 = _CoMarker(x); cond3 = x > 0 ? _co_cond_const0 : _co_cond_const1;
        _dw_bits(var0 === _co_cond1, var1 === _co_cond2, var0 === cond3)), Int64(1)),
    ("const", (x::Int64) -> (r = Int64(0); for _ in 1:20; o = _CoAConst(); b = _CoBConst(); t = _co_bconst_foo(b); _co_bconst_set_foo!(b, t + x);
        y = b[5]; b[5] = y + x; r = o.b_ * 100 + t * 10 + y; end; r), Int64(1)),
    ("const2", (x::Int64) -> Float64(sum(_co_c2_ints) * x + _dw_bits(_co_c2_bools...) + length(_co_c2_amap) + sum(_co_c2_alist) + _co_c2_h + _co_c2_i +
        ncodeunits(_co_c2_s) + (_co_c2_b ? 1 : 0) + (_co_c2_n === nothing ? 1 : 0)) + sum(_co_c2_floats) * x + _co_c2_d, Int64(1)),
    ("const3", (x::Int64) -> _dw_bits(_co_const3_n == 1, _co_const3_o == 4, _co_const3_p == 6) * x, Int64(1)),
    ("const4", (x::Int64) -> _co_const4_a * x, Int64(1)),
    ("constant_dag", (x::Int64) -> _co_node_length_a(_co_dag_n40) * 100 + _co_node_length_b(_co_dag_n40) * x, Int64(1)),
    ("constant_type_variable", (x::Int64) -> (a = _CoCtvA{Int64}(); _dw_bits(a.t1 === Int64, a.t2 === Vector{Int64}, a.x1, a.x2 isa Vector{Union{}}) * x), Int64(1)),
    ("constructor_mixin", (x::Int64) -> _dw_bits(_CoMixB(x) isa _CoMixin, _CoMixB(x) === _CoMixB(42)), Int64(42)),
    ("constructor_mixin3", (x::Int64) -> _dw_bits(_CoMix3B() isa _CoMixin, _CoMix3B() === _CoMix3B()) * x, Int64(1)),
    ("constructor_super2", (x::Int64) -> _dw_bits(_co_cs2_foo() != _co_cs2_bar(), _co_cs2_foo().a != _co_cs2_bar().a, _co_cs2_foo().b == _co_cs2_bar().b) * x, Int64(1)),
    ("constructor", (x::Int64) -> _co_ct_named(Int64).x * 10 * x + _CoCtA{Int64}().x, Int64(1)),
    ("constructor2", (x::Int64) -> (a = _CoC2B{Int64}();
        _dw_bits(_co_c2_c(a) isa _CoC2C{Int64}, _co_c2_optional(a) isa _CoC2C{Int64}, _co_c2_optional() isa _CoC2C{Any}, _co_c2_named(a = a) isa _CoC2C{Int64},
                 _co_c2_untyped(a) isa _CoC2C{Int64}, _CoC2C{Int64}(a).a === a, _co_c2_e_redirecting1(x) isa _CoC2F{Int64},
                 _co_c2_e_redirecting2(x) isa _CoC2G{Int64}, _co_c2_e_redirecting3(Float64(x)) isa _CoC2G{Float64}, _co_c2_e_redirecting2(x).field == x)), Int64(1)),
    ("constructor3", (x::Float64) -> (_co_ctor3_e isa _CoCtor3Abs ? 1.0 : 0.0) + _co_ctor3_c.d + _co_ctor3_e.d + x, 1.0),
    ("ct_const", (x::Int64) -> (p2 = _CoCtPoint(0, _co_ct_get_zero() * x); l1 = _CoCtLine(_co_ct_origin, _CoCtPoint(1, 1)); l2 = _CoCtLine(_CoCtPoint(0, 0), _CoCtPoint(x, 1));
        evens = (2, 2 * 2, 2 * 3, 2 * 4, 2 * 5); germany1 = (black = 1, red = 2, yellow = 3); germany2 = (black = 1, red = 2, yellow = 3);
        belgium = (black = 1, yellow = 2, red = 3); italy = (green = x, red = 3, white = 2);
        _dw_bits(_co_ct_zero == 0, _co_ct_origin.x_ == 0, _co_ct_origin === _co_ct_origin2, _co_ct_origin === _CoCtPoint(0, 0), !(_co_ct_origin == _CoCtPoint(1, 1)),
                 !(_co_ct_origin === _CoCtPoint(1, 1)), _co_ct_origin == p2, _co_ct_point_x(5) === _CoCtPoint(5, 0), l1 === l2, evens === (2, 4, 6, 8, 10),
                 germany1 === (black = 1, red = 2, yellow = 3), germany1 === germany2, !(germany1 == belgium), !(germany1 === belgium),
                 italy === (green = 1, red = 3, white = 2), italy === _co_ct_viva_italia, length(italy) == 3, length(keys(italy)) == 3,
                 haskey(italy, :white), !haskey(italy, :black), _co_ct_set_green(italy), italy.green == 1, nothing == _co_ct_naught)), Int64(1)),
    ("double_in_int_op", (x::Int64) -> _co_diio_sum + ((3x | 2x) + (3x & 2x) + (3x ⊻ 2x) + (3x << 2x) + (3x >> 2x) + (3x >>> 2x)), Int64(1)),
    ("dynamic_type_literal", (x::Int64) -> _dw_bits(_co_dtl_d === Any, length(Dict{DataType,Int64}(_co_dtl_d => 1, _co_dtl_i => x)) == 2), Int64(2)),
    ("escape_frog", (x::Int64) -> (_CoFrogFoo().bar == _CoFrogBar{_CoFrogFoo}() ? x : Int64(0)), Int64(1)),
    ("evaluation", (x::Int64) -> _co_ev_test(_CoEvC(), x - 1), Int64(1)),
    ("factory_member", (x::Int64) -> _dw_bits(_CoFmB(0.57721566490153286) === _CoFmA(), _CoFmB(2.1).x5 == 2.1, _co_fm_x3(_CoFmA()) == 42,
        _co_fm_x4(_CoFmB()) == -42, _co_fm_x2(_CoFmB()) == "B.x2", isempty(_CoFmB().x1)) * x, Int64(1)),
    ("factory_redirection", (x::Int64) -> (c = _CoFrC(x); d = c::_CoFrD; d2 = _CoFrC(x)::_CoFrD;
        _dw_bits(d.i == 42, _co_fr_m(d) == "called m", d2.i == 42, _co_fr_m(d2) == "called m", d === d2)), Int64(42)),
    ("for_in_variable", (x::Int64) -> (r = Int64(0); for v in (1, 2, 3); r = v + x; break; end; r), Int64(1)),
    ("global", (x::Int64) -> _dw_bits(_co_gl_a == 1, _CoGlA(_co_gl_a * x).a == 1, (_CoGlA(_co_gl_a),)[x].a == 1), Int64(1)),
    ("inference", (x::Int64) -> _dw_bits(_co_inf_get_c(Int64) isa _CoInfC{Union{}}, _co_inf_get_c(String) isa _CoInfC{Union{}},
        _co_inf_get_c(Int64).fn === _co_inf_const_function, _co_inf_get_list(Int64) isa Vector{Union{}}, _co_inf_get_list(Int64) isa AbstractVector{<:Int64},
        _co_inf_get_list(String) isa AbstractVector{<:String}, _co_inf_get_implicit_list(Int64) isa Vector{Union{}}, _co_inf_get_set(Int64) isa AbstractSet{<:Int64},
        _co_inf_get_map(Int64, String) isa AbstractDict{<:Int64,<:String}, _co_inf_get_function(Int64, Int64) === _co_inf_const_function) * x, Int64(1)),
    ("init", (x::Int64) -> _dw_bits(_co_init_n == 1, _co_init_o == 4, _co_init_p == 6, _co_init_q.x_ == 0, _co_init_q.y_ == 0, _co_init_q === _co_init_q2) * x, Int64(1)),
    ("init2", (x::Float64) -> _co_init2_c + x, 1.0),
    ("instantiated_function_constant", (b::Bool) -> (a = _CoIfcA{Float64}(b); a2 = _CoIfcA{Number}(!b);
        _dw_bits(a.x1 === _co_ifc_f1, a2.x1 === _co_ifc_f2, a.x2 === _co_ifc_c01, a2.x2 === _co_ifc_f2, a.x5 === _co_ifc_f1, a.x7 === _co_ifc_f1,
                 a2.x7 === _co_ifc_f2, a.x9 === _co_ifc_f2, _co_ifc_c01 === _co_ifc_f1, _co_ifc_f1(1.0) === nothing, _co_ifc_f2(1, 2) === nothing)), true),
    ("list", (x::Int64) -> (fixed = fill(-x, 4); fixed2 = fill(-x, 4); gl = Int64[]; gl2 = Int64[];
        for i in 0:3; fixed[i + 1] = i; fixed2[i + 1] = i; push!(gl, i); push!(gl2, i); end;
        b1 = (gl == gl, gl != gl2, fixed == fixed, fixed != fixed2, fixed != gl);
        push!(gl, 4); b2 = fixed != gl; b3 = pop!(gl) == 4; b4 = fixed != gl; fixed[4] = 0; b5 = fixed != gl;
        a = [1, 2, 3.1]; b = [1, 2, 3.1];
        _dw_bits(b1..., b2, b3, b4, b5, a != b, (1, 2, 3.1) === (x, 2, 3.1), Union{Int64,Float64}[1, 2, 3.1] != [1, 2, 3.1])), Int64(1)),
    ("local", (x::Int64) -> (a = 1; _dw_bits(a == 1, _CoGlA(a * x).a == 1, (_CoGlA(a),)[x].a == 1)), Int64(1)),
    ("locals", (x::Int64) -> (mn = 2 - x; mx = _co_lo_n * 2; mask = (1 << (mx - mn + 1)) - 1; _co_lo_check(mn, mx, mask)), Int64(1)),
    ("map_hashcode_override_legacy", (x::Int64) -> _co_nasty_check(x), Int64(1)),
    ("map_hashcode_override", (x::Int64) -> _co_nasty_check(x), Int64(1)),
    ("map_hashcode_override2_legacy", (x::Int64) -> _co_mc_map_check(x), Int64(1)),
    ("map_hashcode_override2", (x::Int64) -> _co_mc_map_check(x), Int64(1)),
    ("map_null_lookup", (x::Int64) -> _dw_bits(get(_co_mnl_map1, _co_gv(nothing), nothing) == 2, haskey(_co_mnl_map1, nothing),
        get(_co_mnl_map2, _co_gv(nothing), nothing) === nothing, !haskey(_co_mnl_map2, nothing)) * x, Int64(1)),
    ("map", (x::Int64) -> (before = _co_mt_lookups(_co_mt_map) * x; mods = _dw_bits(_co_mt_modify(_co_mt_map, :value), _co_mt_modify(_co_mt_map, :key));
        after = _co_mt_lookups(_co_mt_map); (before * 4 + mods) * 16 + after), Int64(1)),
    ("map4", (x::Int64) -> (a = Dict(x => "a", 2 => "b", 3 => "c"); b = Dict(1 => "a", 2 => "b", 3 => "c");
        _dw_bits(a == b, _co_map4_ca == _co_map4_cb, _co_map4_ctyped == _co_map4_cb, _co_map4_cnum == _co_map4_cb, _co_map4_cdyn == _co_map4_cb,
                 _co_map4_ca === _co_map4_cb)), Int64(1)),
    ("map5", (x::Int64) -> (m = _co_m5_map; _dw_bits(m[_co_gv_t(_CoM5A)] == 42, m[_co_gv_t(_co_m5_a_type)] == 42, m[_co_gv_t(_CoM5F)] == 2, m[_co_gv_t(_co_m5_f_type)] == 2,
        m[_co_gv_t(_CoM5Cint)] == "foo", m[_co_gv_t(_co_m5_cint_type)] == "foo", haskey(m, _co_gv_t(_CoM5A)), haskey(m, _co_gv_t(_co_m5_a_type)), haskey(m, _co_gv_t(_CoM5F)),
        haskey(m, _co_gv_t(_co_m5_f_type)), haskey(m, _co_gv_t(_CoM5Cint)), haskey(m, _co_gv_t(_co_m5_cint_type)), haskey(m, _co_gv_t(_CoM5C{Float64}))) * x), Int64(1)),
    ("named", (x::Int64) -> _co_in_milliseconds(_CoDuration(milliseconds = 499 + x)), Int64(0)),
    ("nested", (x::Int64) -> _co_nested_closure(x)(), Int64(1)),
    ("objects_are_immutable", (x::Int64) -> (list = (x, 2); m = (foo = 499,); a1 = _CoOaiA(x, 2); a2 = _CoOaiA(1, 2);
        _dw_bits(_co_oai_set_list(list), list[1] == 1, _co_oai_set_map(m), m.foo == 499, _co_oai_set_a(a1), a1.x == 1, _co_oai_set_a(a2), a2.x == 1, a1 === a2)), Int64(1)),
    ("primitive_equality", (x::Int64) -> length(_co_pe_set) * x + (_co_pe_one in _co_pe_set ? 100 : 0) + (0 in _co_pe_set ? 1000 : 0) +
        (Symbol(" ") in _co_pe_set ? 10000 : 0), Int64(1)),
    ("qq", (x::Int64) -> (nn = _co_qq_not_null; c1 = _co_qq_c(nothing); c2 = _co_qq_c(42x); l1 = _co_qq_method_local(c1); e1 = _co_qq_expression_local(c1);
        l2 = _co_qq_method_local(c2); e2 = _co_qq_expression_local(c2);
        _dw_bits(nn === _co_qq_test1, nn === _co_qq_test2, nn === _co_qq_test3, nothing === _co_qq_test4,
                 nn === _co_qq_static[1], nn === _co_qq_static[2], nn === _co_qq_static[3], nothing === _co_qq_static[4],
                 nn === c1.test9, nn === c1.test10, nn === c1.test11, nothing === c1.test12, nothing === c1.test13, nn === c1.test14, nn === c1.test15,
                 nothing === c1.test16, nn === c1.test17,
                 nn === l1[1], nn === l1[2], nn === l1[3], nothing === l1[4], nn === e1[1], nn === e1[2], nn === e1[3], nothing === e1[4],
                 nn === c2.test9, nn === c2.test10, nn === c2.test11, nothing === c2.test12, 42 === c2.test13, nn === c2.test14, 42 === c2.test15,
                 42 === c2.test16, 42 === c2.test17,
                 nn === l2[1], nn === l2[2], nn === l2[3], nothing === l2[4], nn === e2[1], nn === e2[2], nn === e2[3], nothing === e2[4])), Int64(1)),
    ("redirect_skips_supertype", (x::Int64) -> (_co_rss_y.x === nothing ? x : Int64(0)) + (_co_rss_y === _CoRssC() ? 10 : 0), Int64(1)),
    ("redirecting_factory", (x::Int64) -> _dw_bits(_co_rf_is(_co_rf_l1, 42, true), _co_rf_is(_co_rf_l2a, 42, true), _co_rf_is(_co_rf_l2b, 87, true),
        _co_rf_is(_co_rf_l2c, 42, false), _co_rf_is(_co_rf_l2d, 87, false), _co_rf_is(_co_rf_l2e, 87, false), _co_rf_is(_co_rf_l3a, 42, true),
        _co_rf_is(_co_rf_l3b, 87, true), _co_rf_is(_co_rf_l3c, 42, false), _co_rf_is(_co_rf_l3d, 87, false), _co_rf_is(_co_rf_l3e, 87, false),
        _co_rf_is(_co_rf_l_named2(field1 = 87x), 87, true)), Int64(1)),
    ("set_hashcode_override2_legacy", (x::Int64) -> _co_mc_set_check(x), Int64(1)),
    ("set_hashcode_override2", (x::Int64) -> _co_mc_set_check(x), Int64(1)),
    ("set_null_lookup", (x::Int64) -> (s1 = Set{Union{Nothing,Int64,String}}((nothing, x, "asdf")); s2 = Set{Union{Nothing,Int64,String}}((42, x, "asdf"));
        _dw_bits(_co_gv(nothing) in s1, _co_gv(nothing) in s2)), Int64(1)),
    ("set5", (x::Int64) -> (s = _co_s5_set; _dw_bits(_co_gv_t(_CoM5A) in s, _co_gv_t(_co_m5_a_type) in s, _co_gv_t(_CoM5F) in s, _co_gv_t(_co_m5_f_type) in s,
        _co_gv_t(_CoM5Cint) in s, _co_gv_t(_co_m5_cint_type) in s, _co_gv(x) in s, _co_gv_t(_CoM5C{Float64}) in s)), Int64(1)),
    ("string", (s::String) -> (yz = _co_str_yz; _dw_bits("abcd" === "abcd", "ab\"cd" === "ab\"cd", "ab'cd" === "ab'cd", "abcd" === "ab" * "cd",
        "abcd" === s * "b" * "cd", "abcd" === s * "b" * "c" * "d", "a'b'cd" === s * "'b'" * "c" * "d", "a\"b\"cd" === s * "\"b\"" * "c" * "d",
        "ab" === s * "b", "xyz" === "x" * yz, "12" === "1" * "2", "zyz" === "z$yz")), "a"),
    ("switch", (x::Int64) -> (l = (_co_sw_c1, _co_sw_c2, _co_sw_c3, _co_sw_c4); s = Int64(0); for i in x:4; s = 10s + _co_sw_test(l[i]); end; s), Int64(1)),
    ("syntax", (x::Int64) -> (f0 = 42x; f2 = 87x; _dw_bits(f0 == 42, f2 == 87, _co_sy_f0 == 42, _co_sy_f2 == 87, _co_sy_p0 isa _CoSyPoint, _co_sy_a0 isa Int64,
        _co_sy_a1 isa Int64, _co_sy_b2 == "Hello 42", _CoSyPoint(1, 2) === _CoSyPoint(x, 2), !_co_sy_b5)), Int64(1)),
    ("tree", (x::Int64) -> length(_co_tree_b.children) * 10 + length(_co_tree_b.children[x].children) + (_co_tree_a.children === _co_tree_empty ? 100 : 0), Int64(1)),
    ("types", (x::Int64) -> _dw_bits(_CoTyClass{Any}() isa _CoTySupertype, isempty(()), isempty(_CoTyClass[]), isempty(_CoTyClass{Int64}[]),
        isempty(Dict{String,_CoTyClass}()), isempty(Dict{String,_CoTyClass{Int64}}()), _CoTyClass{Int64}() === _CoTyClass{Int64}(),
        _co_ty_class_named(Int64) === _CoTyClass{Int64}(), _CoTySupertype() isa _CoTyClass{Any}, _co_ty_generic_supertype(Int64) isa _CoTyClass{Int64}) * x, Int64(1)),
    ("var", (x::Int64) -> (untyped_local = 3x; typed_local::Int64 = 4x; generic_local = Dict{String,String}();
        _dw_bits(_co_var_untyped_top == 1, _co_var_typed_top == 2, isempty(_co_var_generic_top), untyped_local == 3, typed_local == 4, isempty(generic_local),
                 isempty(()), isempty(Int64[]), isempty(Dict{String,Int64}()), _CoVarFoo{Any}() === _CoVarFoo{Any}(), _CoVarFoo{Int64}() isa _CoVarFoo,
                 _CoVarHelper._CoVarHelperFoo{Int64}() isa _CoVarHelper._CoVarHelperFoo, !(_CoVarFoo{Int64}() isa _CoVarHelper._CoVarHelperFoo))), Int64(1)),
])
