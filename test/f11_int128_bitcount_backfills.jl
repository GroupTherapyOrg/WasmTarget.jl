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

@testset "F11b Int128 div/rem/bswap loud-reject (no invalid wasm)" begin
    # div/rem/bswap on Int128 have no 128-bit emitter (long division needs a loop primitive WT
    # lacks; bswap needs a 16-byte reverse). They must LOUD-REJECT (WasmCompileError), never
    # emit invalid wasm. `rem`→checked_srem_int and bswap_int previously fell through to a
    # single i64 op on a 128-bit struct → wasm-tools rejected the module. Now guarded.
    mrem(a::Int64)::Int64   = Int64(rem(Int128(a) * Int128(1000), Int128(7)))
    mdiv(a::Int64)::Int64   = Int64(div(Int128(a) * Int128(1000), Int128(7)))
    mbswap(a::Int64)::Int64 = Int64(bswap(Int128(a)) >> 120)
    murem(a::Int64)::Int64  = Int64(rem(UInt128(a) * UInt128(1000), UInt128(7)) % UInt128(7))
    @test_throws WasmTarget.WasmCompileError WasmTarget.compile(mrem, (Int64,))
    @test_throws WasmTarget.WasmCompileError WasmTarget.compile(mdiv, (Int64,))
    @test_throws WasmTarget.WasmCompileError WasmTarget.compile(mbswap, (Int64,))
    @test_throws WasmTarget.WasmCompileError WasmTarget.compile(murem, (Int64,))
end
