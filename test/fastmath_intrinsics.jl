# `@fastmath` float intrinsics (Base.FastMath.add_float_fast / sub / mul / div /
# neg / sqrt_llvm_fast / eq / ne / lt / le / min / max _fast).
#
# `@fastmath` rewrites `a / b` etc. to the `*_fast` aliases of the Core intrinsics.
# Only min/max/sqrt had `_fast` arms in calls.jl; every other fast form fell through
# to "unresolved dynamic call" (surfaced by SimpleDiffEq's SimpleATsit5 step-size
# controller: `@fastmath q = q11 / (qold^beta2)`). Wasm has no fast-math flags, so
# each fast form now lowers to the same opcode as its strict form (intrinsics
# table + legacy arms + the operand-typing name lists in context.jl/helpers.jl).
#
# Native `@fastmath` may legitimately differ in the last bits (LLVM reassociation /
# contraction), so the differential check is tolerance-based, NOT bit-exact.

# native-vs-wasm to a tolerance (compare_julia_wasm is exact-equality).
function _fm_check(f, args...; tol = 1e-12)
    expected = f(args...)
    bytes = WasmTarget.compile(f, Tuple(map(typeof, args)))
    actual = run_wasm_with_imports(bytes, string(nameof(f)), Dict("Math" => Dict("pow" => "Math.pow")), args...)
    actual === nothing && return true                # no Node → skip (matches compare_julia_wasm)
    T = typeof(expected)
    return isapprox(T(actual), expected; rtol = tol, atol = tol)
end

@testset "fastmath float intrinsics lower to plain ops" begin
    # table shape: every fast binop has an entry with the same result type as its strict form
    for (op, res) in ((:add_float_fast, WasmTarget.F64), (:sub_float_fast, WasmTarget.F64),
                      (:mul_float_fast, WasmTarget.F64), (:div_float_fast, WasmTarget.F64),
                      (:min_float_fast, WasmTarget.F64), (:max_float_fast, WasmTarget.F64),
                      (:eq_float_fast, WasmTarget.I32), (:ne_float_fast, WasmTarget.I32),
                      (:lt_float_fast, WasmTarget.I32), (:le_float_fast, WasmTarget.I32))
        b = WasmTarget.InstrBuilder(; func_name = "fm")
        WasmTarget.seed_input!(b, WasmTarget.WasmValType[WasmTarget.F64, WasmTarget.F64])
        @test WasmTarget.emit_intrinsic_binop!(b, WasmTarget.F64, WasmTarget.F64, op) === res
        b32 = WasmTarget.InstrBuilder(; func_name = "fm32")
        WasmTarget.seed_input!(b32, WasmTarget.WasmValType[WasmTarget.F32, WasmTarget.F32])
        @test WasmTarget.emit_intrinsic_binop!(b32, WasmTarget.F32, WasmTarget.F32, op) ===
              (res === WasmTarget.F64 ? WasmTarget.F32 : WasmTarget.I32)
    end

    # Float64: / * + - ^ inv sqrt under @fastmath, differential to 1e-12
    fm_arith64(a::Float64, b::Float64)::Float64 =
        @fastmath (a / b) * (a + b) - (a - b) + a^b + inv(b) + sqrt(a)
    @test _fm_check(fm_arith64, 2.5, 1.25)
    @test _fm_check(fm_arith64, 9.0, 0.5)
    @test _fm_check(fm_arith64, 1.0e-3, 3.0)

    # Float32 analogue
    fm_arith32(a::Float32, b::Float32)::Float32 =
        @fastmath (a / b) * (a + b) - (a - b) + a^b + inv(b) + sqrt(a)
    @test _fm_check(fm_arith32, 2.5f0, 1.25f0; tol = 1e-6)
    @test _fm_check(fm_arith32, 9.0f0, 0.5f0; tol = 1e-6)

    # unary negation
    fm_neg64(a::Float64)::Float64 = @fastmath -a + 0.0
    fm_neg32(a::Float32)::Float32 = @fastmath -a + 0.0f0
    @test _fm_check(fm_neg64, 3.75)
    @test _fm_check(fm_neg32, 3.75f0; tol = 1e-6)

    # comparisons: each fast compare feeds a branch, result packed into one Int64
    fm_cmp64(a::Float64, b::Float64)::Int64 =
        @fastmath (a < b ? 1 : 0) + (a <= b ? 10 : 0) + (a == b ? 100 : 0) + (a != b ? 1000 : 0)
    @test compare_julia_wasm(fm_cmp64, 1.0, 2.0).pass    # 1011
    @test compare_julia_wasm(fm_cmp64, 2.0, 2.0).pass    # 110
    @test compare_julia_wasm(fm_cmp64, 3.0, 2.0).pass    # 1000
    fm_cmp32(a::Float32, b::Float32)::Int64 =
        @fastmath (a < b ? 1 : 0) + (a <= b ? 10 : 0) + (a == b ? 100 : 0) + (a != b ? 1000 : 0)
    @test compare_julia_wasm(fm_cmp32, 1.0f0, 2.0f0).pass
    @test compare_julia_wasm(fm_cmp32, 2.0f0, 2.0f0).pass

    # the SimpleATsit5 PI-controller shape that surfaced the gap
    fm_pi(eest::Float64, qold::Float64)::Float64 = @fastmath begin
        q11 = eest^(0.7 / 5)
        q = q11 / (qold^(0.08))
        max(inv(5.0), min(inv(0.2), q / 0.9))
    end
    @test _fm_check(fm_pi, 0.5, 1.0)
    @test _fm_check(fm_pi, 1.0e-4, 0.3)
    @test _fm_check(fm_pi, 40.0, 2.0)
end
