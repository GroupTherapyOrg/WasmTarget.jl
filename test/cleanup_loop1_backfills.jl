# Loop-1 cleanup backfill regressions.
#
# Each of the 7 fix_* post-emission byte-rewrite passes is being DELETED (proven dead by the
# WT_NEUTRALIZE=all probe + full-suite run — see dev/cleanup_ledger.md). These tests PIN the
# migrated typed-InstrBuilder emitters that now produce correct bytes up front, so the case
# each pass used to compensate for can never silently regress after the pass is gone.
#
# Differential (compile + wasm-tools validate + Node run == native) via compare_julia_wasm, plus
# raw-byte structural assertions where the ledger named a specific pattern. Functions are top-level
# + named (compare_julia_wasm keys off nameof). Designed to pass WITH the passes active (no-ops) AND
# after their deletion. Standalone:
#   julia --project=. -e 'using WasmTarget; include("test/utils.jl"); include("test/cleanup_loop1_backfills.jl")'

const _WT = WasmTarget

# NOTE: the Node differential harness can't marshal Vector ARGUMENTS, String RETURNS, or Bool
# args — so these fns build arrays internally from scalars, drive branches with Int flags, and
# return primitives. They still exercise the SAME codegen trigger each pass compensated for.
# (The multivar if/else phi-merge case is a SEPARATE confirmed bug — see
# test/fuzz/repro_multivar_phi_merge.jl — NOT something fix_consecutive_local_sets addressed.)

# ── L1.a fix_consecutive_local_sets: consecutive local.set of the same/related values ──
function bf_swap(x::Int64, y::Int64)          # historical consecutive-local-set shape
    t = x; x = y; y = t
    return x - y
end
function bf_dualassign(n::Int64)              # one value → two locals (no branch; the pass's case)
    a = n; b = n
    return a * 1000 + b
end

# ── L1.b/L1.c fix_i32_wrap_after_i32_ops + fix_i64_local_in_i32_ops: mixed int-width ──
bf_i32chain(x::Int32, y::Int32) = (x + y) * Int32(3) - x
bf_i64mix(a::Int64, b::Int32)   = a + Int64(b)
bf_widemul(a::Int32)            = Int64(a) * 2
function bf_idxi32(n::Int64, i::Int32)        # build internally; index with an i32 widened to i64
    v = Int64[]
    for k in 1:n; push!(v, k * 10); end
    return v[Int64(i)]
end
bf_bitsi32(x::UInt32)           = (x << 2) ⊻ (x >> 1) & 0xff

# ── L1.d fix_local_get_set_type_mismatch: i32 edge merged into an i64 phi local ──
function bf_i32edge_i64phi(n::Int64, k::Int32)
    a = Int64(0)
    for i in 1:n
        a = i == 1 ? Int64(k) : a + i
    end
    return a
end

# ── L1.e fix_broken_select_instructions: ref-string select + gcd phi loop ──
bf_selref_len(x::Int64)       = length(x > 0 ? "positive" : "no")   # ref-producing select, Int return
function bf_gcd(a::Int64, b::Int64)   # phi-condition loop (the 0xfb-LEB select gap family)
    while b != 0
        a, b = b, a % b
    end
    return a
end

# ── L1.f fix_array_len_wrap: length()/end on arrays (array.len i32 vs length()::Int64) ──
function bf_len(n::Int64)
    v = Int64[]; for i in 1:n; push!(v, i); end
    return length(v)
end
function bf_lenarith(n::Int64)
    v = Int64[]; for i in 1:n; push!(v, i); end
    return length(v) * 2 + 1
end
function bf_lastidx(n::Int64)
    v = Int64[]; for i in 1:n; push!(v, i * 7); end
    return v[length(v)]
end

# ── L1.g fix_numeric_to_ref_local_stores: numeric → ref-typed phi local (union/boxing) ──
bf_union(x::Int64) = x > 0 ? 1 : 2.5     # Union{Int,Float} phi return (a WORKING corpus case)

# ── raw-byte structural guards (no Node needed) ──────────────────────────────────────────
# array.len is [0xFB 0x0F]; a spurious wrap after it would be the trailing 0xA7. The migrated
# emitter widens via I64_EXTEND_I32_S (0xAC), never i32.wrap_i64 (0xA7), after array.len.
function _no_wrap_after_array_len(bytes::Vector{UInt8})
    i = 1
    while i <= length(bytes) - 2
        if bytes[i] == 0xFB && bytes[i+1] == 0x0F && bytes[i+2] == 0xA7
            return false
        end
        i += 1
    end
    return true
end
# i32-producing opcodes (comparisons 0x45-0x78, ref.eq 0xD1) must not be followed by i32.wrap_i64.
function _no_wrap_after_i32_op(bytes::Vector{UInt8})
    i = 1
    while i <= length(bytes) - 1
        op = bytes[i]
        if ((0x45 <= op <= 0x78) || op == 0xD1) && bytes[i+1] == 0xA7
            return false
        end
        i += 1
    end
    return true
end

@testset "Loop-1 cleanup backfills (migrated emitters, post-fix_* deletion guards)" begin
    @testset "L1.a consecutive local.set (emit_phi_local_set!)" begin
        @test compare_julia_wasm(bf_swap, Int64(5), Int64(9)).pass
        @test compare_julia_wasm(bf_dualassign, Int64(7)).pass
    end
    @testset "L1.b/c mixed int-width (front-line type-directed wrap)" begin
        @test compare_julia_wasm(bf_i32chain, Int32(4), Int32(6)).pass
        @test compare_julia_wasm(bf_i64mix, Int64(10), Int32(3)).pass
        @test compare_julia_wasm(bf_widemul, Int32(21)).pass
        @test compare_julia_wasm(bf_idxi32, Int64(3), Int32(2)).pass
        @test compare_julia_wasm(bf_bitsi32, UInt32(0xABCD)).pass
        # no spurious i32.wrap_i64 after an i32-producing op (the deleted pass's job, now emit-time)
        for (f, a) in ((bf_i32chain, (Int32(4), Int32(6))), (bf_bitsi32, (UInt32(9),)))
            @test _no_wrap_after_i32_op(_WT.compile(f, map(typeof, a)))
        end
    end
    @testset "L1.d i32 edge into i64 phi (structural I64_EXTEND widening)" begin
        @test compare_julia_wasm(bf_i32edge_i64phi, Int64(5), Int32(3)).pass
        @test compare_julia_wasm(bf_i32edge_i64phi, Int64(1), Int32(99)).pass
    end
    @testset "L1.e ref-string select + gcd phi loop (typed select_t!)" begin
        @test compare_julia_wasm(bf_selref_len, Int64(3)).pass
        @test compare_julia_wasm(bf_selref_len, Int64(-1)).pass
        @test compare_julia_wasm(bf_gcd, Int64(48), Int64(36)).pass
    end
    @testset "L1.f length()/array.len (I64_EXTEND, never wrap)" begin
        @test compare_julia_wasm(bf_len, Int64(3)).pass
        @test compare_julia_wasm(bf_lenarith, Int64(3)).pass
        @test compare_julia_wasm(bf_lastidx, Int64(3)).pass
        for (f, a) in ((bf_len, (Int64(2),)), (bf_lenarith, (Int64(3),)), (bf_lastidx, (Int64(1),)))
            @test _no_wrap_after_array_len(_WT.compile(f, map(typeof, a)))
        end
    end
    @testset "L1.g numeric → ref phi local (union return validates)" begin
        @test compare_julia_wasm(bf_union, Int64(5)).pass
        @test compare_julia_wasm(bf_union, Int64(-5)).pass
    end
end
