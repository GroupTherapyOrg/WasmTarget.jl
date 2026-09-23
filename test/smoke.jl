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
    # every vtable entry returns anyref (dart closures.dart:648): a Nothing-returning body's
    # entry yields null (it used to return no value, and the caller's cast to the uniform
    # signature trapped), and one arity may mix Nothing- and value-returning specializations
    # (it used to be refused at compile time)
    ("erased_nothing_body", (n::Int64) -> (v = Int64[]; h = s -> (push!(v, length(s) * n); nothing); fs = Any[h]; fs[1]("ab"); fs[1]("abc"); sum(v)), Int64(3)),
    ("erased_nothing_specialization", (n::Int64) -> (v = Int64[]; h = x -> (x isa String ? (push!(v, length(x)); nothing) : x * n); fs = Any[h]; fs[1]("abcd"); Int64((fs[1](2.5)::Float64) * 2) + sum(v)), Int64(3)),
])

# ---- KNOWN-PENDING (xfail) — gaps with an open loop; reported, do NOT fail the gate.
# When one flips to passing, the smoke says so loudly (the loop that closes it is done).
const XFAIL = Vector{Pair{String,Vector{Any}}}()
_xf(name, cases) = push!(XFAIL, name => cases)
# An erased call's result is Julia's `::Any`, never its first argument's type: the value
# keeps its own class (native 2, 1, 1; typed as the Int64 argument it answers 1, and traps
# an illegal cast for the Bool and Float64 results).
_xf("erased_call_result", Any[
    ("erased_result_uint64", (n::Int64) -> (fs = Any[x -> UInt64(x)]; r = fs[1](n); r isa Int64 ? 1 : 2), Int64(3)),
    ("erased_result_bool", (n::Int64) -> (fs = Any[x -> x > 0]; r = fs[1](n); r isa Bool ? 1 : 2), Int64(3)),
    ("erased_result_float64", (n::Int64) -> (fs = Any[x -> x * 0.5]; r = fs[1](n); r isa Float64 ? 1 : 2), Int64(3)),
])
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
# Egal, isa, typeof and dispatch tell `"a"` from `:a`; a runtime Symbol (`jl_symbol_n`, the
# `Symbol` builtin) is built under Symbol's class and hashes as Julia's interned symbol does.
@noinline _sym_of(x::Int64) = x > 0 ? :abc : :d
@noinline _sym_dispatch(x::Symbol) = 1
@noinline _sym_dispatch(x::String) = 2
@noinline _sym_dispatch(x) = 3
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
    ("expr_new", (x::Int64) -> (e = Expr(:call, :+, 1, x); length(e.args)), Int64(1)),                              # Core._expr
    ("donotdelete", (x::Int64) -> (Base.donotdelete(x); x + 1), Int64(1)),                                           # Core.donotdelete
    ("isassigned_ref_elements", (x::Int64) -> (v = Vector{String}(undef, 3); v[1] = "a"; isassigned(v, x) ? 1 : 0), Int64(2)),  # memoryref_isassigned
    ("typeof_any", (x::Int64) -> (v = Any[1, 2.0]; typeof(v[x]) === Float64 ? 1 : 0), Int64(2)),                   # Core.typeof
    ("length_any", (x::Int64) -> (v = Any["abcé", [1, 2]]; length(v[x])::Int64), Int64(1)),                        # Base.length
    ("ifelse", (x::Int64) -> ifelse(x > 0, x, -x), Int64(-3)),                                                       # Core.ifelse
    ("sizeof_string", (x::Int64) -> sizeof(x > 0 ? "abcé" : "de"), Int64(1)),                                        # Core.sizeof
    ("ifelse_any_condition", (x::Int64) -> (v = Any[true, false]; ifelse(v[x], 1, 2)), Int64(2)),                  # Base.ifelse
    ("symbol_any_string", (x::Int64) -> (v = Any[12, "cde"]; Symbol(v[x]) === :cde ? 1 : 0), Int64(2)),            # Symbol
    ("compilerbarrier_const", (x::Int64) -> Base.compilerbarrier(:const, x) + 1, Int64(1)),                         # Core.compilerbarrier
    ("inferencebarrier_ref", (x::Int64) -> (Base.inferencebarrier(Any[x])::Vector{Any})[1]::Int64, Int64(1)),     # Core.compilerbarrier
    ("getglobal_const_vector", (x::Int64) -> getglobal(Main, :_SMOKE_GLOBAL_VEC)[x], Int64(2)),                    # Core.getglobal
    # `+`/`-`/`*` whose operands are results of an erased (Vector{Any}) closure call
    ("erased_results_sub", (n::Int64) -> (h = x -> x + n; fs = Any[h]; (fs[1](5) - fs[1](2))::Int64), Int64(3)),     # Base.:-
    ("erased_results_mul", (n::Int64) -> (h = x -> x + n; fs = Any[h]; (fs[1](5) * fs[1](2))::Int64), Int64(3)),     # Base.:*
    ("erased_results_sub_f", (n::Float64) -> (h = x -> x + n; fs = Any[h]; (fs[1](5.0) - fs[1](2.0))::Float64), 1.5),  # Base.:-
    ("erased_results_mul_f", (n::Float64) -> (h = x -> x + n; fs = Any[h]; (fs[1](5.0) * fs[1](2.0))::Float64), 1.5),  # Base.:*
    # `-`/`*` on a captured, mutated accumulator: the dynamic operator whose operands carry
    # the variable's joined type (translateTypeOfLocalVariable)
    ("mutate_capture_sub", (n::Int64) -> ((s = 100; foreach(i -> (s -= i), 1:n); s)::Int64), Int64(5)),   # Base.:-
    ("mutate_capture_mul", (n::Int64) -> ((s = 1; foreach(i -> (s *= i), 1:n); s)::Int64), Int64(5)),     # Base.:*
])
const _SMOKE_GLOBAL_VEC = [10, 20, 30]

# BUILTIN_LOWERINGS reached from an :invoke: the closed-world metadata operations Julia
# leaves as an :invoke of their @noinline overlay; compile_invoke! selects the entry by the
# invoked function's identity.
@noinline _sm_visible_from_main(tn::Core.TypeName)::Bool =
    WasmTarget._closed_world_isvisible(tn.name, tn.module, Main)
_g("builtins_invoked", Any[
    ("closed_world_type_bounds", (x::Int64) -> WasmTarget._closed_world_type_bounds(Int.name) === nothing ? x : -x, Int64(3)),  # _closed_world_type_bounds
    ("closed_world_isvisible", (x::Int64) -> _sm_visible_from_main(Int.name) ? x : -x, Int64(3)),                            # _closed_world_isvisible
])
# BUILTIN_LOWERINGS apply_type: a runtime `Union{T, Nothing}` is a fresh $JlUnion
# (builtins.jl `_lower_apply_type!`), and `===` against the same Union constant answers
# false; Julia's Union is an immutable value, so the two are egal (native 1, wasm 0).
_xf("apply_type_union", Any[
    ("runtime_union_egal", (x::Int64) -> (T = x > 0 ? Int64 : Float64; U = Union{T, Nothing}; U === Union{Int64, Nothing} ? 1 : 0), Int64(1)),
])
# BUILTIN_LOWERINGS memorynew: a Memory is allocated with exactly n elements (it used to be
# padded to 16, so length(Memory{Int64}(undef, 3)) answered 16).
_g("memory_length", Any[
    ("memory_undef_length", (n::Int64) -> length(Memory{Int64}(undef, n)), Int64(3)),
])
# FOREIGN_LOWERINGS jl_type_unionall: `UnionAll(v, t)` constructs a type, but the lowering
# (statements.jl `_fc_jl_type_unionall!`) emits `ref.test $JlUnionAll` on the TypeVar
# operand — a predicate in place of the constructed type (native 1, wasm 0 for both).
const _SMOKE_TV = TypeVar(:T)
@noinline _sm_unionall(t::TypeVar, @nospecialize(b)) = UnionAll(t, b)
_xf("unionall_constructor", Any[
    ("unionall_body_without_var", (x::Int64) -> (b = Any[Int64, Vector{_SMOKE_TV}][x]; _sm_unionall(_SMOKE_TV, b) === Int64 ? 1 : 0), Int64(1)),
    ("unionall_body_with_var", (x::Int64) -> (b = Any[Int64, Vector{_SMOKE_TV}][x]; _sm_unionall(_SMOKE_TV, b) isa UnionAll ? 1 : 0), Int64(2)),
])
# `isa UnionAll` on an Any-typed value answers 0 for `Vector` (native 1).
_xf("isa_unionall", Any[
    ("isa_unionall_any", (x::Int64) -> (v = Any[Vector, Int64]; v[x] isa UnionAll ? 1 : 0), Int64(1)),
])
# BUILTIN_LOWERINGS crashes: each compiles or runs to a failure where native returns a value.
_xf("builtin_crashes", Any[
    # Core.compilerbarrier on an Int64: WasmInternalError "numeric-to-reference conversion
    # lacks a concrete Julia source type"
    ("inferencebarrier_int", (x::Int64) -> Base.inferencebarrier(x)::Int64 + 1, Int64(1)),
    # Base.ncodeunits on a Vector{AbstractString} element: the String element returns no
    # value to the host ("undefined"), the SubString element traps "illegal cast"
    ("ncodeunits_abstract_string", (x::Int64) -> (v = AbstractString["abc", SubString("hello", 2, 3)]; ncodeunits(v[x])), Int64(1)),
    ("ncodeunits_abstract_substring", (x::Int64) -> (v = AbstractString["abc", SubString("hello", 2, 3)]; ncodeunits(v[x])), Int64(2)),
    # Base.sizeof on an Any element: WasmInternalError at `getfield(Any, :layout)`
    ("sizeof_any", (x::Int64) -> (v = Any["abcd", 1]; sizeof(v[x])), Int64(1)),
    # Symbol of an Any element holding an Int64: traps "illegal cast" (native Symbol("12"))
    ("symbol_any_int", (x::Int64) -> (v = Any[12, "cde"]; Symbol(v[x]) === Symbol("12") ? 1 : 0), Int64(1)),
    # Base.getproperty on an Any element: the dispatch candidate getproperty(::UInt64,
    # ::Symbol) rejects "getfield call shape not lowerable"
    ("getproperty_any", (x::Int64) -> (v = Any[_Pt(x, 2)]; v[1].x::Int64), Int64(5)),
    ("setproperty_any", (x::Int64) -> (v = Any[_Box(1)]; v[1].v = x; (v[1]::_Box).v), Int64(5)),
    # Core.invoke_in_world: the re-dispatched `abs` is not in the closed world
    # ("unresolved dynamic call Main.abs (Int64,)")
    ("invoke_in_world", (x::Int64) -> Base.invoke_in_world(Base.tls_world_age(), abs, x)::Int64, Int64(-3)),
])
# FOREIGN_LOWERINGS rejects: every program measured to reach these stops at a loud reject.
_xf("pointer_foreigncalls", Any[
    # jl_value_ptr: pointer_from_objref of a Ref rejects "jl_value_ptr escapes
    # storage-relative WasmGC operations" (also the first reject in isgraphemebreak!,
    # whose Ref{Int32} state argument goes through it; its utf8proc foreigncall has no
    # lowering and would reject next)
    ("ref_pointer_load", (x::Int64) -> (r = Ref(x); GC.@preserve r unsafe_load(Base.unsafe_convert(Ptr{Int64}, r))), Int64(5)),
    ("grapheme_break_stateful", (x::Int64) -> Base.Unicode.isgraphemebreak!(Ref{Int32}(0), 'a', Char(x)) ? 1 : 0, Int64(98)),
    # jl_ptr_to_array_1d: the lowering cannot trace pointer(v) and declines ("no lowering")
    ("unsafe_wrap_pointer", (n::Int64) -> (v = collect(1:n); GC.@preserve v (w = unsafe_wrap(Array, pointer(v), n); w[2])), Int64(3)),
])
# `repr` of a runtime type traps "dereferencing a null pointer" on Julia 1.12 (native
# "Int64"); on Julia 1.13 it passes (measured 2026-09-22).
(VERSION >= v"1.13-" ? _g : _xf)("show_type", Any[
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

# popfirst!/pushfirst! are WASM_METHOD_TABLE overlays (codegen/interpreter.jl) that copy
# into a fresh allocation, so the Vector's MemoryRef is back at offset 1 where Julia's
# _deletebeg! advanced it to 3. The lowering reads the offset WT's MemoryRef carries — a
# ref with an offset cannot be stored (it rejects loudly) — so the gap is the overlay:
# Julia's own _deletebeg!/_growbeg! compile only once a stored MemoryRef keeps its offset.
# pushfirst! (Julia's offset 6, WT's 1) and a push!/popfirst! queue (5, WT's 1) are the
# same gap.
_xf("memoryref_offset", Any[
    ("offset_after_popfirst", (n::Int64) -> (v = collect(1:n); popfirst!(v); popfirst!(v); Base.memoryrefoffset(v.ref)), Int64(5)),
    ("pushfirst_len_offset", (n::Int64) -> (v = collect(1:n); pushfirst!(v, 0); length(v) * 10 + Base.memoryrefoffset(v.ref)), Int64(5)),
    ("queue_push_popfirst", (n::Int64) -> (v = collect(1:n); s = 0; for i in 1:40; push!(v, i); s += popfirst!(v); end; (Base.memoryrefoffset(v.ref) * 100 + length(v.ref.mem)) * 1000 + s), Int64(5)),
])
# The same Vectors observed through their elements: the overlays already compute these, and
# they must keep computing them once Julia's own growth bodies (which move the ref's offset)
# replace the overlays. Native values are identical on 1.12 and 1.13. The last case is the
# freed slot Julia's `_deleteend!` nulls.
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
# An Array keeps its :ref's element offset (the Array struct's off0 field): Julia's own
# `_deletebeg!` (not an overlay) and `Base.wrap` store an offset ref, and every reader —
# indexing, reshape, push!, copy, splatting, `take!` — honours it.
_g("memoryref_array_offset", Any[
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
    ("pop_empty_message", (n::Int64) -> (v = collect(1:n); try; pop!(v); 0; catch e; e isa ArgumentError ? (ncodeunits(e.msg)::Int) : -1; end), Int64(0)),
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
