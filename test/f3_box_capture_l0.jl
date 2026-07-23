# F3 sub-loop L0 (dev/HISTORY.md#closures-and-dynamic-dispatch) — unit tests for the PURE Core.Box contents-type inference.
#
# `box_contents_type` computes the captured variable's REAL type = the join of the enclosing init
# and every closure write's COMPUTED result type (closure bodies via the invoke CodeInstance; write
# types via Core.Compiler.return_type past the box's Any-erasure). Concrete join → that type (typed
# cell); Union/abstract/Any → `nothing` (anyref-boxed = dart2wasm's top-type field). This mirrors
# dart2wasm's `translateTypeOfLocalVariable` — reconstructing what Julia erased, not a heuristic.
# Pure analysis, not wired into codegen yet (byte-identical).

@testset "F3 L0: pure box_contents_type inference (dart2wasm-aligned)" begin
    _btype(fn) = begin
        ci = code_typed(fn, (Int64,); optimize=true)[1].first
        bs = WasmTarget.find_box_news(ci.code)
        @assert length(bs) == 1
        WasmTarget.box_contents_type(ci.code, ci.ssavaluetypes, bs[1])
    end

    # MONOMORPHIC captures → typed cell (the variable's real concrete type).
    @test _btype((n::Int64) -> (c = 0; f = () -> (c += 1); for _ in 1:n; f(); end; c)) === Int64
    # arg-taking closure (`s += i`, i::Int64) — body retrieved via the invoke CodeInstance.
    @test _btype((n::Int64) -> (s = 0; f = i -> (s += i); for i in 1:n; f(i); end; s)) === Int64
    @test _btype((n::Int64) -> (s = 0.0; f = x -> (s += x); for i in 1:n; f(1.5); end; s)) === Float64

    # GENUINELY-POLYMORPHIC captures → nothing (anyref-boxed; the pure join diverges to a Union).
    # widen: c starts Int, closure does c = c*1.5 → Float64 ≠ Int64 ⇒ Union ⇒ dynamic.
    @test _btype((n::Int64) -> (c = 0; f = () -> (c = c * 1.5); f(); c)) === nothing
    # hetero: a := Int | String — the cheap init-only inference WRONGLY returned Int64; pure → nothing.
    hetero(n::Int64) = (a = 0; f = () -> (a = a > 0 ? 1 : "x"); f(); a)
    @test _btype(hetero) === nothing

    # A box with no resolvable write in this IR → nothing (no false concrete type).
    @test WasmTarget.box_contents_type(Any[], Any[], 1) === nothing
end
