# ============================================================================
# FAST differential smoke — the INNER-LOOP gate for the dart2wasm-parity march.
#
# Why: the full `Pkg.test()` is 18-30 min and gets OOM-killed (jetsam) under
# memory pressure. This runs a curated breadth of native-vs-wasm differential
# cases in ONE low-memory Julia session (~2-3 min after precompile), covering
# every dimension a codegen change is likely to touch. GREEN here = safe to run
# the full commit-gate; it is NOT a substitute for it (rule #0 still stands).
#
# Run:   julia --project=. test/smoke.jl
# Exit:  0 = all pass, 1 = any fail/error (so it is gate-able + CI-able).
# Filter: julia --project=. test/smoke.jl boxing phi   # only matching groups
# ============================================================================
using WasmTarget
using Random, SHA   # seeded streams, as the full suite loads them (WasmTargetRandomExt active)
include(joinpath(@__DIR__, "utils.jl"))

const FILTER = lowercase.(ARGS)
_want(group) = isempty(FILTER) || any(f -> occursin(f, lowercase(group)), FILTER)

# Each case: (name, f, args...). Compared native-vs-wasm via compare_julia_wasm.
const GROUPS = Vector{Pair{String,Vector{Any}}}()
_g(name, cases) = push!(GROUPS, name => cases)

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
    ("erased_call", (n::Int64) -> (h = x -> x + n; fs = Any[h]; (fs[1](1) + fs[1](2))::Int64), Int64(3)),
    ("erased_two_closures", (n::Int64) -> (fs = Any[x -> x + n, x -> x * n]; (fs[1](1) + fs[2](2))::Int64), Int64(3)),
    ("erased_two_specializations", (n::Int64) -> (h = x -> x + n; fs = Any[h]; (fs[1](1)::Int64) + Int64((fs[1](2.5)::Float64) * 2)), Int64(3)),
])

# ---- KNOWN-PENDING (xfail) — gaps with an open loop; reported, do NOT fail the gate.
# When one flips to passing, the smoke says so loudly (the loop that closes it is done).
const XFAIL = Vector{Pair{String,Vector{Any}}}()
_xf(name, cases) = push!(XFAIL, name => cases)
# M6 progress (2026-07-02): the closure body now compiles VALID wasm (the self-box numeric
# join types the capture cycle — f3_self_box_joins, dart Capture.type). The remaining gap is
# SHARED-CONTEXT semantics: the parent scalar-replaces the escaping Box while the closure
# mutates the real one (two copies). Fix = dart Context structs (closures.dart:970): the
# parent materializes ONE shared cell; no scalar replacement across an escaping closure.
# parity(M10a) PROMOTED: the scalar-replaced accumulator cycle computes correctly — the
# numeric join is the variable's REAL type for EVERY consumer (dart
# translateTypeOfLocalVariable), so the dynamic-+ default-zero arm never fires.
_g("mutable_capture", Any[
    ("mutate_capture_typed", (n::Int64) -> ((s = 0; foreach(i -> (s += i), 1:n); s)::Int64), Int64(5)),
])
# The un-annotated variant returns Any (a classId box) — computes correctly in-wasm; the
# JS harness can't unmarshal the boxed export (host-boundary limitation, not codegen).
_xf("any_return_boundary", Any[
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
_g("dispatch", Any[
    ("dispatch_int", (x::Int64) -> _disp(x), Int64(5)),
    ("dispatch_float", (x::Float64) -> _disp(x), 4.0),
    # a dynamic call whose abstract position holds boxed numerics and a classed string:
    # the discovery builds a row per observed class (Int64, String, Float64 — dart's rows
    # for every class of the component) and the switch unboxes/casts per row; it used to
    # skip non-struct classes and trap at runtime with no row
    ("eq_any_mixed", (n::Int64) -> (v = Any[1, "x", 2.5]; (v[1] == 1 ? 1 : 0) + (v[2] == "x" ? 10 : 0) + (v[3] == 2.5 ? 100 : 0) + n), Int64(1)),
    ("selector_table_span", (n::Int64) -> (v = Any[_SmA(Int32(n)), _SmB(Int32(n)), _SmC(Int32(n)), _SmD(Int32(n))]; s = Int32(0); for e in v; s += _smd_fwd(e); end; Int64(s) + n), Int64(3)),
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

# ---- lowering-registry coverage (charter C5, test/registry_coverage.jl) ----
# Each case below is the smallest ordinary program that reaches the registry entry named
# in its comment; the coverage lane confirms the entry fires while it compiles.

# FOREIGN_LOWERINGS. The seeded stream reaches `jl_type_intersection` through
# Random.hash_seed's dispatch guards: a total break of that lowering on 2026-09-08 failed
# every seeded Random differential in the full suite while smoke and probes stayed green.
# On Julia 1.13 the seeded stream does not compile (measured 2026-09-22): the closed world
# registers `Pair{Symbol, Union{}}`, and structs.jl `is_self_referential_type` calls
# `eltype(Union{})` on its bottom-typed field (`Union{} <: AbstractVector`), escaping as a
# raw ArgumentError ("Union{} does not have elements"); past that, the compile rejects
# "closure typeof(getproperty): arity-2 specializations disagree on returning a value".
(VERSION >= v"1.13-" ? _xf : _g)("seeded_random", Any[
    ("seeded_rand_range", (s::Int64) -> rand(Xoshiro(s), 1:1000), Int64(42)),       # jl_type_intersection
    ("seeded_rand_float", (s::Int64) -> rand(Xoshiro(s)), Int64(7)),                # jl_type_intersection
])
@noinline _sm_opsym(x::Int64) = x > 0 ? :+ : :foo
_g("foreign_calls", Any[
    ("typeintersect_runtime", (x::Int64) -> typeintersect(x > 0 ? Int64 : String, Integer) === Int64 ? 1 : 0, Int64(1)),  # jl_type_intersection
    ("is_operator", (x::Int64) -> Base._isoperator(_sm_opsym(x)) ? 1 : 0, Int64(1)),                                      # jl_is_operator
    ("is_syntactic_operator", (x::Int64) -> Base.is_syntactic_operator(x > 0 ? :(=) : :foo) ? 1 : 0, Int64(1)),         # jl_is_syntactic_operator
    ("id_chars", (x::Int64) -> (Base.is_id_start_char(Char(x)) ? 1 : 0) + (Base.is_id_char(Char(x)) ? 2 : 0), Int64(97)), # jl_id_start_char, jl_id_char
    ("isidentifier", (x::Int64) -> Base.isidentifier(x > 0 ? "abc" : "1x") ? 1 : 0, Int64(1)),                           # jl_id_start_char, jl_id_char
    ("module_name", (x::Int64) -> x + length(String(nameof(Base.Math))), Int64(1)),                                      # jl_module_name
    ("module_parent", (x::Int64) -> x + length(String(nameof(parentmodule(Base.Math)))), Int64(1)),                      # jl_module_parent
    ("write_symbol", (x::Int64) -> (io = IOBuffer(); write(io, x > 0 ? :abc : :de); position(io)), Int64(1)),            # strlen
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
    ("expr_new", (x::Int64) -> (e = Expr(:call, :+, 1, x); length(e.args)), Int64(1)),                              # Core._expr
    ("donotdelete", (x::Int64) -> (Base.donotdelete(x); x + 1), Int64(1)),                                           # Core.donotdelete
    ("isassigned_ref_elements", (x::Int64) -> (v = Vector{String}(undef, 3); v[1] = "a"; isassigned(v, x) ? 1 : 0), Int64(2)),  # memoryref_isassigned
    ("typeof_any", (x::Int64) -> (v = Any[1, 2.0]; typeof(v[x]) === Float64 ? 1 : 0), Int64(2)),                   # Core.typeof
    ("length_any", (x::Int64) -> (v = Any["abcé", [1, 2]]; length(v[x])::Int64), Int64(1)),                        # Base.length
    ("ifelse", (x::Int64) -> ifelse(x > 0, x, -x), Int64(-3)),                                                       # Core.ifelse
    ("sizeof_string", (x::Int64) -> sizeof(x > 0 ? "abcé" : "de"), Int64(1)),                                        # Core.sizeof
])

# Wrong values found while writing the registry-coverage cases (measured 2026-09-22).
# `===` on floats is Julia's egal — bit identity — but the `===` lowering compares with
# f64.eq / f32.eq (calls.jl `_compile_call_egaleq`): 0.0 === -0.0 answers true (native
# false) and NaN === NaN answers false (native true).
_xf("float_egal", Any[
    ("f64_egal_signed_zero", (x::Float64) -> (x === -0.0 ? 1 : 0) + (x !== -0.0 ? 2 : 0), 0.0),       # exp 2, act 1
    ("f64_egal_nan", (x::Float64) -> (x === NaN ? 1 : 0) + (x !== NaN ? 2 : 0), NaN),                 # exp 1, act 2
    ("f32_egal_signed_zero", (x::Float32) -> (x === -0.0f0 ? 1 : 0) + (x !== -0.0f0 ? 2 : 0), 0.0f0), # exp 2, act 1
])
# BUILTIN_LOWERINGS apply_type: a runtime `Union{T, Nothing}` is a fresh $JlUnion
# (builtins.jl `_lower_apply_type!`), and `===` against the same Union constant answers
# false; Julia's Union is an immutable value, so the two are egal (native 1, wasm 0).
_xf("apply_type_union", Any[
    ("runtime_union_egal", (x::Int64) -> (T = x > 0 ? Int64 : Float64; U = Union{T, Nothing}; U === Union{Int64, Nothing} ? 1 : 0), Int64(1)),
])
# BUILTIN_LOWERINGS memorynew: every Memory is allocated with at least 16 slots
# (builtins.jl `_lower_memorynew!`, min_capacity = 16) and `length(::Memory)` reads the
# array length: length(Memory{Int64}(undef, 3)) answers 16 (native 3).
_xf("memory_length", Any[
    ("memory_undef_length", (n::Int64) -> length(Memory{Int64}(undef, n)), Int64(3)),
])

# ============================================================================
function main()
    t0 = time()
    npass = 0; nfail = 0; nerr = 0
    failures = String[]
    for (group, cases) in GROUPS
        _want(group) || continue
        for case in cases
            name = case[1]; f = case[2]; args = case[3:end]
            tag = "$group/$name"
            try
                r = isempty(args) ? compare_julia_wasm(f) : compare_julia_wasm(f, args...)
                if r.pass
                    npass += 1
                else
                    nfail += 1; push!(failures, "WRONG $tag  exp=$(r.expected) act=$(r.actual)")
                end
            catch e
                nerr += 1; push!(failures, "ERROR $tag  $(first(sprint(showerror, e), 90))")
            end
        end
    end
    # xfail lane: known-pending gaps. Report status; a NEWLY-PASSING one is great news
    # (its loop landed) but never fails the gate; a still-failing one is expected.
    xf_now_pass = String[]; xf_still = 0
    for (group, cases) in XFAIL
        _want(group) || continue
        for case in cases
            name = case[1]; f = case[2]; args = case[3:end]
            ok = try
                r = isempty(args) ? compare_julia_wasm(f) : compare_julia_wasm(f, args...)
                r.pass
            catch
                false
            end
            ok ? push!(xf_now_pass, "$group/$name") : (xf_still += 1)
        end
    end
    dt = round(time() - t0; digits = 1)
    println("\n" * "="^60)
    for fl in failures; println("  ", fl); end
    println("="^60)
    if !isempty(xf_now_pass)
        println("xfail NOW PASSING (a gap closed — promote it out of XFAIL): ", join(xf_now_pass, ", "))
    end
    println("xfail: $(length(xf_now_pass)) now-passing, $xf_still still-pending (expected)")
    println("smoke: $npass passed, $nfail wrong, $nerr errored  ($(dt)s)")
    exit((nfail + nerr) == 0 ? 0 : 1)
end
# main() runs when smoke.jl is the program; test/registry_coverage.jl includes it for GROUPS only
abspath(PROGRAM_FILE) == (@__FILE__) && main()
