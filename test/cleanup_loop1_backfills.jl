# Loop-1 cleanup backfill regressions.
#
# Each of the 7 fix_* post-emission byte-rewrite passes is being DELETED (proven dead by the
# WT_NEUTRALIZE=all probe + full-suite run — see dev/HISTORY.md#typed-builder-and-cleanup-campaigns. These tests PIN the
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
# F1 (Loop B): a numeric Union spanning int+float (Union{Int64,Float64}) is now BOXED as a
# classId-tagged {typeId,value} struct (anyref), NOT collapsed to a lossy f64. So the bare
# union RETURN below compiles+validates but its anyref result can't be Node-marshaled (the
# return JSON is `undefined`) — assert COMPILE+VALIDATE only. The faithful round-trip is proven
# by the union-INTERNAL companions (bfu_*), which create+consume the box internally and return
# a primitive Node CAN marshal (value preserved, tag preserved, numeric content exact).
bf_union(x::Int64) = x > 0 ? 1 : 2.5     # Union{Int,Float} phi return (now boxed → anyref)
bfu_use(x::Int64)   = (a = x>0 ? 1 : 2.5; a > 1.5 ? 100 : 200)       # value preserved
bfu_isa(x::Int64)   = (a = x>0 ? 1 : 2.5; a isa Float64 ? 1 : 0)     # TAG preserved (not lossy)
bfu_arith(x::Int64) = (a = x>0 ? 1 : 2.5; Int(floor(Float64(a)*10))) # numeric content exact

# ── structural guards over the disassembled instruction stream ──────────────────────────
# These scan instruction boundaries, not raw bytes: a raw scan cannot tell an opcode from
# an operand, and `local.get 69` / `i64.const 100` followed by a legitimate i32.wrap_i64
# both start with a byte in the i32-producer opcode range (a Windows/1.12-only false
# positive from local-numbering differences in collected Base bodies, 2026-09-01).
function _instr_mnemonics(bytes::Vector{UInt8})
    wasm_tools = Sys.which("wasm-tools")
    wasm_tools === nothing && error("wasm-tools is required for the Loop-1 structural guards")
    path = tempname() * ".wasm"
    write(path, bytes)
    text = try
        read(pipeline(`$(wasm_tools) print $(path)`, stderr=devnull), String)
    finally
        rm(path; force=true)
    end
    mnemonics = String[]
    for line in eachline(IOBuffer(text))
        s = strip(line)
        (isempty(s) || s[1] in ('(', ')', ';')) && continue
        push!(mnemonics, first(split(s)))
    end
    return mnemonics
end
# The migrated emitter widens via i64.extend_i32_s after array.len, never i32.wrap_i64.
function _no_wrap_after_array_len(bytes::Vector{UInt8})
    m = _instr_mnemonics(bytes)
    return !any(i -> m[i-1] == "array.len" && m[i] == "i32.wrap_i64", 2:length(m))
end
# i32-producing instructions (the 0x45-0x78 comparison/i32-arithmetic family and ref.eq)
# must never be followed by i32.wrap_i64 — the value is already i32.
const _I32_PRODUCER = r"^(?:ref\.eq|(?:i32|i64|f32|f64)\.(?:eqz|eq|ne|lt_s|lt_u|gt_s|gt_u|le_s|le_u|ge_s|ge_u|lt|gt|le|ge)|i32\.(?:clz|ctz|popcnt|add|sub|mul|div_s|div_u|rem_s|rem_u|and|or|xor|shl|shr_s|shr_u|rotl|rotr))$"
function _no_wrap_after_i32_op(bytes::Vector{UInt8})
    m = _instr_mnemonics(bytes)
    return !any(i -> occursin(_I32_PRODUCER, m[i-1]) && m[i] == "i32.wrap_i64", 2:length(m))
end

@testset "Loop-1 cleanup backfills (migrated emitters, post-fix_* deletion guards)" begin
    @testset "L1.a consecutive local.set of the same or related values" begin
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
        # the guard must be able to fire: a hand-built module whose body is
        # `i32.const 0; i32.eqz; i32.wrap_i64; drop` (invalid wasm, printable)
        let bad = UInt8[0x00,0x61,0x73,0x6D, 0x01,0x00,0x00,0x00,
                        0x01,0x04,0x01,0x60,0x00,0x00,
                        0x03,0x02,0x01,0x00,
                        0x0A,0x09,0x01,0x07,0x00, 0x41,0x00, 0x45, 0xA7, 0x1A, 0x0B]
            @test !_no_wrap_after_i32_op(bad)
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
    @testset "L1.g numeric → ref phi local (F1: numeric union BOXED, faithful)" begin
        # Bare boxed-union return: compiles + validates (wasm-tools gate inside compile),
        # but the anyref result is not Node-marshalable → assert compile-validates only.
        @test (_WT.compile(bf_union, (Int64,)); true)
        # Union-INTERNAL → primitive: the faithful-boxing proof (Node-marshalable).
        @test compare_julia_wasm(bfu_use, Int64(5)).pass    # value preserved (200)
        @test compare_julia_wasm(bfu_use, Int64(-5)).pass   # value preserved (100)
        @test compare_julia_wasm(bfu_isa, Int64(5)).pass    # TAG preserved (0 = Int, not Float)
        @test compare_julia_wasm(bfu_isa, Int64(-5)).pass   # TAG preserved (1 = Float64)
        @test compare_julia_wasm(bfu_arith, Int64(5)).pass  # numeric content exact (10)
        @test compare_julia_wasm(bfu_arith, Int64(-5)).pass # numeric content exact (25)
    end
end
