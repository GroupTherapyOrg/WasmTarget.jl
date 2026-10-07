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
using Random, SHA   # seeded streams, as the full suite loads them
using LinearAlgebra: Diagonal, Symmetric   # struct_by_structure: array-interface structs
include(joinpath(@__DIR__, "utils.jl"))
include(joinpath(@__DIR__, "trace_localize.jl"))   # a WRONG answer's first divergent statement

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

# ---- KNOWN-PENDING (xfail) — gaps with an open loop; reported, do NOT fail the gate.
# When one flips to passing, the smoke says so loudly (the loop that closes it is done).
const XFAIL = Vector{Pair{String,Vector{Any}}}()
_xf(name, cases) = push!(XFAIL, name => cases)
# The xfails that compile and then fail when they run, each with what it does: `:wrong`
# returns a value native does not (a module that runs and answers wrong, the worst outcome),
# `:trap` traps where native returns, and `:unreadable` returns a GC reference for an
# abstract return type that the harness cannot read back, so its value is unverified. Every
# other xfail rejects at compile time. The xfail lane measures each case against this table
# exactly, so a loud reject cannot turn into a wrong answer unseen; R39 counts the table
# (dev/CHARTER.md C6), terminal state 0.
const XFAIL_RUNTIME = Dict{String,Symbol}(
)
# What an xfail case does now: :pass, one of XFAIL_RUNTIME's outcomes, :loud (the compile
# rejects it at a statement it names, dev/CHARTER.md C6), or :crash (the compile raises
# anything else: a codegen bug, a rejection that names no statement), which no xfail may do.
function xfail_outcome(f, args)::Symbol
    expected = f(args...)
    bytes = try
        WasmTarget.compile(f, Tuple(map(typeof, args)); optimize=false)
    catch err
        return err isa WasmTarget.WasmCompileError && err.diag.stmt_idx > 0 ? :loud : :crash
    end
    status, val = WasmRunner.run_wasm_single(bytes, string(nameof(f)),
                                             join(map(format_js_arg, args), ", "))
    status === :ok && return unmarshal_result(val) == expected ? :pass : :wrong
    if status === :trap && startswith(val, "unserializable result")
        # read inside the module, through a typeassert to the native result's type
        w = typed_result_wrapper(f, typeof(expected))
        w === nothing && return :unreadable
        wb = try WasmTarget.compile(w, Tuple(map(typeof, args)); optimize=false) catch; return :unreadable end
        status, val = WasmRunner.run_wasm_single(wb, string(nameof(w)), join(map(format_js_arg, args), ", "))
        status === :ok && return unmarshal_result(val) == expected ? :pass : :wrong
    end
    status === :trap && return startswith(val, "unserializable result") ? :unreadable : :trap
    error("xfail lane: the runner answered $status: $val")
end
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
# Ten methods pass Julia's max_methods cutoff, so inference types each call below `::Any`;
# the result type is Julia's answer with the cutoff lifted (every applicable method's
# inferred result, joined). _smm: all Int64. _smw: nine Int64 methods and one WIDER
# `_smw(::Any, ::Int64)::Float64` that the tenth class reaches. _smx: five Int64, five Float64.
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
    ("megamorphic_all_int64", (n::Int64) -> ((t = 0; for x in _smm_xs(); t += _smm(x, n); end; t)::Int64), Int64(3)),
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

# BUILTIN_LOWERINGS reached from an :invoke: the closed-world metadata operations Julia
# leaves as an :invoke of their @noinline overlay; compile_invoke! selects the entry by the
# invoked function's identity.
@noinline _sm_visible_from_main(tn::Core.TypeName)::Bool =
    WasmTarget._closed_world_isvisible(tn.name, tn.module, Main)
_g("builtins_invoked", Any[
    ("closed_world_type_bounds", (x::Int64) -> WasmTarget._closed_world_type_bounds(Int.name) === nothing ? x : -x, Int64(3)),  # _closed_world_type_bounds
    ("closed_world_isvisible", (x::Int64) -> _sm_visible_from_main(Int.name) ? x : -x, Int64(3)),                            # _closed_world_isvisible
])
# Arithmetic whose operands are results of an erased (Vector{Any}) closure call: Julia
# types each result `::Any`, so `+`/`-`/`*` runs on two Any values and rejects located at
# `dynamic (%a + %b)::Any`.
# These passed only while the call result was guessed as its first argument's type. Gap:
# the typed value channel — each boxed operand unboxed by its classId and the operator
# dispatched on the classes, the result boxed with the class the chosen method returns.
_xf("erased_arithmetic", Any[
    ("erased_call", (n::Int64) -> (h = x -> x + n; fs = Any[h]; (fs[1](1) + fs[1](2))::Int64), Int64(3)),
    ("erased_two_closures", (n::Int64) -> (fs = Any[x -> x + n, x -> x * n]; (fs[1](1) + fs[2](2))::Int64), Int64(3)),
    ("erased_results_sub", (n::Int64) -> (h = x -> x + n; fs = Any[h]; (fs[1](5) - fs[1](2))::Int64), Int64(3)),
    ("erased_results_mul", (n::Int64) -> (h = x -> x + n; fs = Any[h]; (fs[1](5) * fs[1](2))::Int64), Int64(3)),
    ("erased_results_sub_f", (n::Float64) -> (h = x -> x + n; fs = Any[h]; (fs[1](5.0) - fs[1](2.0))::Float64), 1.5),
    ("erased_results_mul_f", (n::Float64) -> (h = x -> x + n; fs = Any[h]; (fs[1](5.0) * fs[1](2.0))::Float64), 1.5),
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
# BoxValueTypes.tla); native 1, 2, 1 on 1.12/1.13. propagate_numeric_value_types and
# f3_box_value_types now pass their models (VERIFY rechecks each phi's join and restarts;
# literal operands join). What each case does now:
# - numeric_join_seeded_phi: rejects located, "`+` on operands typed (Any, Float64) has no
#   single opcode" at `+(%16, 0.5)` (the phi is Any once VERIFY bans its Int64 seed).
# - numeric_join_dropped_phi: rejects located at `+(%26, 1)` (was a runtime "illegal cast"
#   trap).
# - box_value_literal_phi: rejects located at the closure's `s += 1`.
_xf("box_type_recovery", Any[
    ("numeric_join_seeded_phi", (n::Int64) -> (s = 0; foreach(i -> (s += 0.5), 1:n); s isa Float64 ? 1 : 2), Int64(4)),
    ("numeric_join_dropped_phi", (n::Int64) -> (v = Any[1.5]; p = n > 0 ? v[1] : 0; q = p + 1; q isa Int64 ? 1 : 2), Int64(1)),
    ("box_value_literal_phi", _sm_boxlit, Int64(0)),
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
])
# isa against a kind (DataType, UnionAll, …): Julia folds S <: T only where its subtyping of
# kinds is sound (jl_is_not_broken_subtype), and tests the type object's kind elsewhere
@noinline _sm_kv(x::Int64) = x > 0 ? Vector : Int64
@noinline _sm_ki(x::Int64)::Type{Int64} = Int64
_g("kind_isa", Any[
    ("type_of_type_isa_datatype", (x::Int64) -> (t = _sm_ki(x); t isa DataType ? 1 : 2), Int64(3)),
    ("unionall_isa_datatype", (x::Int64) -> (T = _sm_kv(x); T isa DataType ? 1 : 2), Int64(3)),
    ("unionall_isa_unionall", (x::Int64) -> (T = _sm_kv(x); T isa UnionAll ? 1 : 2), Int64(3)),
])
# A runtime-length tuple (`Core.tuple(v...)`) is an NTuple{n,E} for its run-time n
# (jl_f_tuple); its representation's header names Tuple{Vararg{E}}, which no value has, so
# typeof, `===` and an erased slot answered for that class (dev/AUDIT.md A5E3: native 1, wasm
# 2). isa tests its size; the rest reject at their statement
@noinline _sm_mk(v::Vector{Int64}) = Core.tuple(v...)
@noinline _sm_mk8(v::Vector{Int8}) = Core.tuple(v...)
@noinline _sm_mkbool(v::Vector{Bool}) = Core.tuple(v...)
struct _SmMT; m::Memory{Int64}; t::Tuple{Int64}; end
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
    # a packed element is read with its sign: -3 read unsigned is 253 (A9B3, A10P6)
    ("isa_narrowed_int8_fields", (n::Int64) -> (t = _sm_mk8(Int8[-n, 2, 3]); t isa NTuple{3,Int8} ? Int64(t[1]) + Int64(t[3]) : 0), Int64(3)),
    ("isa_narrowed_fields", (n::Int64) -> (t = _sm_mk([n, 2, 3]); t isa NTuple{3,Int64} ? t[1] + t[3] : 0), Int64(3)),
    # a Bool element is unpacked, read plainly (A10E5: a signed read of it was refused)
    ("isa_narrowed_bool_fields", (n::Int64) -> (t = _sm_mkbool([true, false, n > 2]); t isa NTuple{3,Bool} ? (t[3] ? 2 : 1) : 0), Int64(3)),
    # a fixed tuple held as any value and asserted a runtime-length tuple is built into it
    # (A10E4: a cast of its struct trapped where native answers 3)
    ("erased_asserted_runtime_length", (n::Int64) -> (v = Any[(n,)]; t = v[1]::Tuple{Vararg{Int64}}; t[1]), Int64(3)),
    # a struct whose layout is the representation's widens to Any as any struct does
    ("same_layout_struct_erased", (n::Int64) -> (m = Memory{Int64}(undef, 1); m[1] = n; v = Any[_SmMT(m, (n,))]; (v[1]::_SmMT).t[1]), Int64(3)),
])
_xf("runtime_length_tuple_class", Any[
    ("typeof_ntuple", (n::Int64) -> typeof(_sm_mk([n, 2, 3])) === Tuple{Int64,Int64,Int64} ? 1 : 2, Int64(3)),
    ("egal_ntuple", (n::Int64) -> _sm_mk([n, 2, 3]) === (3, 2, 3) ? 1 : 2, Int64(3)),
    ("erased_isa_ntuple", (n::Int64) -> Any[_sm_mk([n, 2, 3])][1] isa NTuple{3,Int64} ? 1 : 2, Int64(3)),
    # a failed typeassert's TypeError carries the value as `got`, a slot of any class (A6E2)
    ("typeassert_got", (n::Int64) -> (try; _sm_mk([n, 2, 3])::NTuple{2,Int64}; 0; catch e; e isa TypeError && e.got isa NTuple{3,Int64} ? 1 : 2; end), Int64(3)),
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
    ("union_split_fields", (n::Int64) -> (v = Any[n, 1.5]; try; _sm_me_q(v[n])::Int64; catch e; (e isa MethodError && e.f === _sm_me_q && e.args isa Tuple{Float64} && e.args[1] == 1.5) ? 1 : 2; end), Int64(2)),
    ("union_split_string_args", (n::Int64) -> (v = Any[n, "s"]; try; _sm_me_q(v[n])::Int64; catch e; (e isa MethodError && typeof(e.args) === Tuple{String} && e.args[1] == "s") ? 1 : 2; end), Int64(2)),
    ("union_split_two_args", (n::Int64) -> (v = Any[n, 1.5]; try; _sm_me_r(n, v[n])::Int64; catch e; (e isa MethodError && e.args === (n, 1.5)) ? 1 : 2; end), Int64(2)),
    ("closure_entry_caught", (n::Int64) -> (k = n; f = _sm_dh(x::Int64 -> x + k)[]; f(1); try; f(_sm_dh(1.5)[])::Int64; catch e; e isa MethodError ? -1 : -2; end), Int64(3)),
    ("closure_entry_fields", (n::Int64) -> (k = n; g = x::Int64 -> x + k; f = _sm_dh(g)[]; f(1); try; f(_sm_dh(1.5)[])::Int64; catch e; (e isa MethodError && e.f === g && e.args === (1.5,)) ? 1 : 2; end), Int64(3)),
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

# ============================================================================

# A WRONG answer located at its first divergent statement (TraceLocalize.first_divergence);
# the locator's own failure is reported in its place, never hidden.
function _smoke_locate(f, args)::String
    try
        return TraceLocalize.first_divergence(f, args...; js_args=join(map(format_js_arg, args), ", ")).summary
    catch e
        return "(the wrong value could not be located: $(first(sprint(showerror, e), 200)))"
    end
end

# An error's located lines — the headline (for a codegen bug, the compiler source line it was
# raised at), the statement, its innermost inline frame, and the cause — so a failing case
# names where to look without rerunning it; the full trace prints when the case runs alone.
function _smoke_error_text(e)::String
    local lines = split(sprint(showerror, e), '\n')
    local keep = [strip(l) for l in lines if !isempty(strip(l)) &&
                  !startswith(strip(l), "←") && !startswith(strip(l), "raised through")]
    local text = join(first(keep, 4), " | ")
    return length(text) > 600 ? first(text, 600) * "…" : text
end

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
                    nfail += 1
                    push!(failures, "WRONG $tag  exp=$(r.expected) act=$(r.actual)\n    " *
                                    replace(_smoke_locate(f, args), "\n" => "\n    "))
                end
            catch e
                nerr += 1; push!(failures, "ERROR $tag  $(_smoke_error_text(e))")
            end
        end
    end
    # xfail lane: known-pending gaps. A NEWLY-PASSING one is great news (its loop landed) and
    # never fails the gate; a still-failing one must fail the way XFAIL_RUNTIME says it does.
    xf_now_pass = String[]; xf_still = 0; xf_mismatch = String[]; xf_seen = Set{String}()
    for (group, cases) in XFAIL
        _want(group) || continue
        for case in cases
            name = case[1]; f = case[2]; args = case[3:end]
            tag = "$group/$name"; push!(xf_seen, tag)
            got = xfail_outcome(f, args)
            if got === :pass
                push!(xf_now_pass, tag)
            else
                xf_still += 1
                want = get(XFAIL_RUNTIME, tag, :loud)
                got === want || push!(xf_mismatch, "$tag: XFAIL_RUNTIME says $want, measured $got")
            end
        end
    end
    for tag in keys(XFAIL_RUNTIME)
        _want(String(first(split(tag, '/')))) && !(tag in xf_seen) &&
            push!(xf_mismatch, "$tag: listed in XFAIL_RUNTIME, but no xfail case has that name")
    end
    dt = round(time() - t0; digits = 1)
    println("\n" * "="^60)
    for fl in failures; println("  ", fl); end
    println("="^60)
    if !isempty(xf_now_pass)
        println("xfail NOW PASSING (a gap closed — promote it out of XFAIL): ", join(xf_now_pass, ", "))
    end
    for m in xf_mismatch; println("  XFAIL OUTCOME ", m); end
    println("xfail: $(length(xf_now_pass)) now-passing, $xf_still still-pending (expected), " *
            "$(length(xf_mismatch)) outcome mismatch(es)")
    println("smoke: $npass passed, $nfail wrong, $nerr errored  ($(dt)s)")
    exit((nfail + nerr + length(xf_mismatch)) == 0 ? 0 : 1)
end
# main() runs when smoke.jl is the program; test/registry_coverage.jl includes it for GROUPS only
abspath(PROGRAM_FILE) == (@__FILE__) && main()
