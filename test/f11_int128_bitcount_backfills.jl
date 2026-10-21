# Parity Loop 0 — F11 backfills (dev/HISTORY.md#parity-method): Int128 bit-counting intrinsics.
#
# cttz_int / ctpop_int / not_int ignored the is_128bit flag and emitted a single i64 op on a
# 128-bit (two-limb struct) value → wasm-tools rejected the module (invalid). Added
# emit_int128_cttz / emit_int128_ctpop / emit_int128_not in src/codegen/int128.jl (mirroring
# the existing emit_int128_ctlz). Verified native-vs-wasm; values build Int128 from an Int64
# argument and return Int64 (Int128 args/returns aren't Node-marshalable).

@testset "F11 Int128 bit-counting intrinsics" begin
    # trailing_zeros across the lo/hi limb boundary
    i128_tz_hi(a::Int64)::Int64 = Int64(trailing_zeros(Int128(a) << 64))  # 64 + tz(a)
    i128_tz_lo(a::Int64)::Int64 = Int64(trailing_zeros(Int128(a)))        # tz within lo limb
    @test compare_julia_wasm(i128_tz_hi, Int64(8)).pass    # 64+3 = 67
    @test compare_julia_wasm(i128_tz_hi, Int64(1)).pass    # 64+0 = 64
    @test compare_julia_wasm(i128_tz_lo, Int64(96)).pass   # tz(96)=5

    # count_ones spanning both limbs
    i128_co(a::Int64)::Int64 = Int64(count_ones((Int128(a) << 64) | Int128(a)))  # 2·popcnt(a), a≥0
    @test compare_julia_wasm(i128_co, Int64(7)).pass       # 6
    @test compare_julia_wasm(i128_co, Int64(255)).pass     # 16

    # count_zeros = count_ones(~x) → exercises ctpop AND not_int on Int128
    i128_cz(a::Int64)::Int64 = Int64(count_zeros(Int128(a)))
    @test compare_julia_wasm(i128_cz, Int64(7)).pass       # 125
    @test compare_julia_wasm(i128_cz, Int64(0)).pass       # 128
    @test compare_julia_wasm(i128_cz, Int64(-1)).pass      # 0 (all bits set)

    # bitwise NOT directly
    i128_not(a::Int64)::Int64 = Int64((~Int128(a)) & Int128(typemax(Int64)))
    @test compare_julia_wasm(i128_not, Int64(5)).pass
    @test compare_julia_wasm(i128_not, Int64(0)).pass
end

# top-level helpers: a function defined inside a @testset that calls another is a closure
_i128_wide(a::Int64) = Int128(a) << 70 + Int128(a) * 12345
_i128_wq(a::Int64, b::Int64)::Int64 = Int64(div(_i128_wide(a), Int128(b) << 65 + 3) % Int64)
_i128_wr(a::Int64, b::Int64)::Int64 = Int64(rem(_i128_wide(a), Int128(b) << 65 + 3) % Int64)
@noinline _i128_one(n::Int64) = Int128(n > -1000) + Int128(n) * 0   # 1, opaque to constant folding
_i128_shl(n::Int64) = (r = Core.Intrinsics.shl_int(_i128_one(n), n % UInt64); Int64((r >> 64) % Int64) * 1000 + Int64(r % Int64))
_i128_lshr(n::Int64) = (x = (_i128_one(n) << 127) | _i128_one(n); r = Core.Intrinsics.lshr_int(x, n % UInt64); Int64(r % Int64) + Int64((r >>> 64) % Int64) * 1000)
_i128_ashr(n::Int64) = (x = -(_i128_one(n) << 100); r = Core.Intrinsics.ashr_int(x, n % UInt64); Int64(r % Int64) + Int64((r >> 64) % Int64) * 1000)

@testset "F11b Int128 division and remainder are Julia's (dev/formal/Int128Limbs.tla)" begin
    # sdiv/udiv/srem/urem and their checked forms run over the two limbs: one-limb operands
    # take i64.div_u; the rest long division (the divrem helper), signed on magnitudes.
    mrem(a::Int64)::Int64   = rem(Int128(a) * Int128(1000), Int128(7)) % Int64
    mdiv(a::Int64)::Int64   = div(Int128(a) * Int128(1000), Int128(7)) % Int64
    murem(a::Int64)::Int64  = Int64(rem(UInt128(a) * UInt128(1000), UInt128(7)) % UInt128(7))
    for a in (Int64(13), Int64(-13), Int64(0), typemax(Int64), typemin(Int64))
        @test compare_julia_wasm(mrem, a).pass
        @test compare_julia_wasm(mdiv, a).pass
    end
    @test compare_julia_wasm(murem, Int64(13)).pass
    # both limbs: a wide dividend by a wide divisor, every sign combination
    for (a, b) in ((Int64(987654321), Int64(3)), (Int64(-987654321), Int64(3)),
                   (Int64(987654321), Int64(-3)), (Int64(-987654321), Int64(-3)))
        @test compare_julia_wasm(_i128_wq, a, b).pass
        @test compare_julia_wasm(_i128_wr, a, b).pass
    end
    # a divisor of 2^127 or more, unsigned
    mbig(a::Int64)::Int64 = Int64(div(typemax(UInt128) - UInt128(a), (UInt128(1) << 127) + UInt128(a)) % Int64) * 10 +
                            Int64(rem(typemax(UInt128) - UInt128(a), (UInt128(1) << 127) + UInt128(a)) >> 100)
    @test compare_julia_wasm(mbig, Int64(5)).pass
    # Julia's errors: a zero divisor, and typemin ÷ -1, throw DivideError; rem(typemin, -1) == 0
    mz(a::Int64)::Int64 = try; Int64(div(Int128(a) << 64, Int128(a) - Int128(a)) % Int64); catch e; e isa DivideError ? -1 : -2; end
    mo(a::Int64)::Int64 = try; Int64(div(typemin(Int128) + Int128(a), Int128(-1)) % Int64); catch e; e isa DivideError ? -1 : -2; end
    mr(a::Int64)::Int64 = Int64(rem(typemin(Int128) + Int128(a), Int128(-1)))
    @test compare_julia_wasm(mz, Int64(3)).pass
    @test compare_julia_wasm(mo, Int64(0)).pass
    @test compare_julia_wasm(mr, Int64(0)).pass
end

@testset "F11b Int128 shifts past the width are Julia's intrinsics (dev/formal/Int128Limbs.tla)" begin
    # Core.Intrinsics.shl_int/lshr_int/ashr_int select on `shift >= width` (intrinsics.cpp):
    # 0, or the sign in every bit. The limb shifts took the amount modulo 64 and answered
    # 2^66 for shl_int(Int128(1), 130).
    for f in (_i128_shl, _i128_lshr, _i128_ashr), n in (0, 1, 63, 64, 65, 127, 128, 130, 200)
        @test compare_julia_wasm(f, Int64(n)).pass
    end
end

@testset "F11b Int128 bswap is Julia's (dev/formal/Int128Limbs.tla)" begin
    # each limb's bytes reversed, the limbs exchanged; it once rejected (no 16-byte reverse)
    mbswap(a::Int64)::Int64 = Int64(bswap(Int128(a)) >> 120)
    mbswap_lo(a::Int64)::Int64 = bswap(UInt128(reinterpret(UInt64, a)) << 64 + UInt128(0x0102030405060708)) % Int64
    for a in (Int64(1), Int64(0x0102030405060708), Int64(-2), typemin(Int64))
        @test compare_julia_wasm(mbswap, a).pass
        @test compare_julia_wasm(mbswap_lo, a).pass
    end
end
