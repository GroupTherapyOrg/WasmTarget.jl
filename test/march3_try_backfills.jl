# march 3 backfills: the try/catch driver battery that surfaced the
# throw-arm-past-the-leave silent miscompile.
#
# Shape: `y = try; x > 5 ? x : throw(...); catch; 0; end; y + 1` — Julia lowers
# the try body with the normal exit (leave + goto merge) FIRST and the throw arm
# LAST, between leave_idx and catch_dest. The linear PURE-9031 walker's range is
# bounded by leave_idx, so the throw arm compiled to an EMPTY if/else and the
# try-exit phi store ran unconditionally: the catch never fired and the wrong
# value flowed out (f_phi(2) returned 3, not 1) — validated, silent, wrong.
# Fix: the shape dispatches to the stackified try driver (ONE lowering).

_m3_try_basic(x::Int64)::Int64 = try; x == 0 ? throw(DivideError()) : 100 ÷ x; catch; -1; end
_m3_try_nested(x::Int64)::Int64 = try; try; x < 0 ? error("neg") : x * 2; catch; -10; end; catch; -20; end
_m3_try_guard(x::Int64)::Int64 = Int64(try; gcd(Int32(0), Int32(x)); catch; Int32(0); end)
_m3_try_phi(x::Int64)::Int64 = (y = try; x > 5 ? x : throw(ArgumentError("small")); catch; 0; end; y + 1)
_m3_try_rethrow(x::Int64)::Int64 = try; x == 3 ? error("boom") : x; catch e; x + 100; end

@testset "march3: try/catch driver battery (throw-arm-past-leave)" begin
    @test compare_julia_wasm(_m3_try_basic, Int64(5)).pass
    @test compare_julia_wasm(_m3_try_basic, Int64(0)).pass
    @test compare_julia_wasm(_m3_try_nested, Int64(4)).pass
    @test compare_julia_wasm(_m3_try_nested, Int64(-2)).pass
    @test compare_julia_wasm(_m3_try_guard, Int64(12)).pass
    @test compare_julia_wasm(_m3_try_phi, Int64(9)).pass
    @test compare_julia_wasm(_m3_try_phi, Int64(2)).pass    # was: silent 3 (≠ 1)
    @test compare_julia_wasm(_m3_try_rethrow, Int64(3)).pass
    @test compare_julia_wasm(_m3_try_rethrow, Int64(7)).pass
end
