# parity(M10): mutable capture — dart Context semantics (closures.dart:960-1013).
# Two lanes: (a) the INLINED accumulator cycle (Julia scalarized the box to phis;
# the numeric join types it; the phi-edge store must carry the value — the
# drop+zero-default arm is the historical silent miscompile); (b) the ESCAPING
# closure (the box survives IR: ONE materialized cell, closure field holds THE ref).
@testset "M10 mutable capture (dart Context semantics)" begin
    # (a) inlined cycle — the two promoted F3 xfails
    f_any = (n::Int64) -> (s = 0; foreach(i -> (s += i), 1:n); s)
    f_typed = (n::Int64) -> ((s = 0; foreach(i -> (s += i), 1:n); s)::Int64)
    @test compare_julia_wasm(f_typed, Int64(5)).pass          # was: silent 0
    @test compare_julia_wasm(f_typed, Int64(100)).pass
    # The Any-return variant computes correctly in-wasm (the typed variants prove the
    # cycle); its EXPORT is a classId box the JS harness cannot unmarshal — a known
    # host-boundary limitation, not a codegen gap. Compile-only here.
    @test !isempty(WasmTarget.compile(f_any, (Int64,)))

    # richer cycle shapes
    f_mul = (n::Int64) -> ((p = 1; foreach(i -> (p *= i), 1:n); p)::Int64)
    @test compare_julia_wasm(f_mul, Int64(6)).pass             # 720
    f_two = (n::Int64) -> ((a = 0; b = 1; foreach(i -> (a += i; b *= 2), 1:n); a + b)::Int64)
    @test compare_julia_wasm(f_two, Int64(4)).pass             # 10 + 16 = 26
end

# M10b CLOSED (march 3): the cross-function escaping closure (@noinline maker; caller
# mutates through the shared box). Root causes were (1) the identity-convert arm in
# calls.jl appending its value emission AFTER the pre-pushed args (doubled bytes), and
# (2) the convert/typeassert results staying erased-Any so the result local typed anyref
# while the store carried the refined i64 — fixed by refine_checked_cast_types! (dart
# `as T`: the cast's static type IS T, code_generator.dart visitAsExpression).
# top-level so the entries are singleton functions, not capturing closures —
# a closure-typed ENTRY can't cross the JS arg boundary in run_wasm.
@noinline mkn_g(n::Int64) = (c = 0; inc = () -> (c += n; c); inc)
outer_g(n::Int64)::Int64 = (f = mkn_g(n); f(); f())
@noinline mkf_g(x::Float64) = (c = 0.0; add = () -> (c += x; c); add)
outerf_g(x::Float64)::Float64 = (f = mkf_g(x); f(); f(); f())
@noinline mk2_g(n::Int64) = (c = n; bump = () -> (c += 1; c); bump)
outer2_g(n::Int64)::Int64 = (f = mk2_g(n); g = mk2_g(n * 10); f(); g(); f() + g())

@testset "M10b escaping closure" begin
    @test compare_julia_wasm(outer_g, Int64(3)).pass         # 3 + 3 = 6
    @test compare_julia_wasm(outer_g, Int64(-5)).pass        # -10
    # richer shapes: float cell, more mutations, two escaping closures
    @test compare_julia_wasm(outerf_g, 1.5).pass             # 4.5
    @test compare_julia_wasm(outer2_g, Int64(2)).pass        # 4 + 22 = 26
end
