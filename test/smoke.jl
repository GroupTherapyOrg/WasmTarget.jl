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
])

# ---- phi / union (the boxing channel) -------------------------------------
_g("phi_union", Any[
    ("loop_phi", (n::Int64) -> (s = 0; for i in 1:n; s += i % 2 == 0 ? i : -i; end; s), Int64(6)),
    ("union_add", (b::Bool) -> (b ? 10 : 20) + 1, true),
    ("ternary_widen", (x::Int64) -> x > 5 ? 1.5 : 2.5, Int64(2)),
    ("acc_float", (n::Int64) -> (s = 0.0; for i in 1:n; s += i; end; s), Int64(5)),
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
_g("dicts", Any[
    ("dict_get", (x::Int64) -> (d = Dict(1 => 10, 2 => 20, 3 => 30); get(d, x, 0)), Int64(2)),
    ("dict_build", (n::Int64) -> (d = Dict{Int64,Int64}(); for i in 1:n; d[i] = i * i; end; sum(values(d))), Int64(4)),
    ("dict_haskey", (x::Int64) -> (d = Dict(1 => 1, 2 => 2); haskey(d, x) ? 1 : 0), Int64(2)),
])

# ---- structs / tuples -----------------------------------------------------
struct _Pt; x::Int64; y::Int64; end
mutable struct _Box; v::Int64; end
_g("structs_tuples", Any[
    ("struct_field", (n::Int64) -> (p = _Pt(n, n + 1); p.x + p.y), Int64(3)),
    ("mutable_struct", (n::Int64) -> (b = _Box(n); b.v += 10; b.v), Int64(5)),
    ("tuple_idx", (x::Int64) -> (t = (x, x + 1, x + 2); t[1] + t[3]), Int64(4)),
    ("namedtuple", (x::Int64) -> (nt = (a = x, b = x * 2); nt.a + nt.b), Int64(3)),
    ("het_tuple", (x::Int64) -> (t = (x, 1.5); t[1] + Int64(t[2] > 1 ? 1 : 0)), Int64(7)),
    # Loop B′: heterogeneous tuple at a RUNTIME index → Union element via the uniform box (both arms).
    ("het_tuple_rtidx", (x::Int64) -> (t = (10, 2.5); s = t[x]; s isa Int64 ? s : Int64(round(s))), Int64(1)),
    ("const_het_tuple_rtidx", (x::Int64) -> (t = (100, 3.5, 200); v = t[x]; v isa Int64 ? v : Int64(round(v))), Int64(1)),
])

# ---- closures (capture; mutate-capture = F3) ------------------------------
_g("closures", Any[
    ("capture", (x::Int64) -> (f = y -> y + x; f(10)), Int64(5)),
    ("map_closure", (n::Int64) -> (k = 3; sum(map(i -> i * k, 1:n))), Int64(4)),
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
_xf("F3_mutable_capture", Any[
    ("mutate_capture", (n::Int64) -> (s = 0; foreach(i -> (s += i), 1:n); s), Int64(5)),
    ("mutate_capture_typed", (n::Int64) -> (s = 0; foreach(i -> (s += i), 1:n); s)::Int64, Int64(5)),
])
# Strings lack the $JlBase classId header (bare array<i32> refs), so abstract isa on a
# heterogeneous element can't range-check them — pre-existing rep gap (strings dimension),
# found while installing dart's dense-range isa (M3). Fix = class the string rep (M6/strings).
_xf("strings_lack_classid", Any[
    ("isa_abstractstring_anyvec", (n::Int64) -> (v = Any[1, "a", 2]; c = 0; for e in v; e isa AbstractString && (c += 1); end; c + n), Int64(10)),
])

# ---- dispatch (multiple methods / types) ----------------------------------
_disp(x::Int64) = x * 2
_disp(x::Float64) = x + 0.5
_g("dispatch", Any[
    ("dispatch_int", (x::Int64) -> _disp(x), Int64(5)),
    ("dispatch_float", (x::Float64) -> _disp(x), 4.0),
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
main()
