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
        nir = WasmTarget.build_nir(ci)
        bs = WasmTarget.find_box_news(nir)
        @assert length(bs) == 1
        WasmTarget.box_contents_type(nir, nir, bs[1])
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
    @test WasmTarget.box_contents_type(WasmTarget.NirStmt[], Any[], 1) === nothing
end

# formal(dev/formal/BoxJoin.tla) — TRANSITIVE closure-write discovery. `_f3_capturing_closure_bodies`
# must recurse into a discovered closure's OWN body to find a FURTHER-nested closure that captures
# the SAME box (through a getfield of the outer closure's captured field) and writes it there —
# not just the box's own function's directly-created closures (one hop). A grandchild-only write
# reached the model's real typed IR (via `WasmTarget.get_typed_ir`, the one inference path) BEFORE
# this fix returned `Int64` (WRONG — should widen to `nothing`/anyref, since the write two hops down
# is Float64, divergent from the Int64 init). This test fails on the pre-fix (one-hop) code:
# verified by temporarily reverting box_capture.jl to its pre-fix content and re-running.
@testset "F3 L0: transitive closure-write discovery (BoxJoin.tla gap)" begin
    @eval const _F3_L0_BIG = 1_000_000
    @eval function _f3_l0_outer_boxjoin(n::Int64)
        x = 0
        @noinline function level1(m)
            @noinline function level2(k)
                k > _F3_L0_BIG ? (x = 3.5) : (x += k)
            end
            for i in 1:m
                level2(i)
            end
        end
        level1(n)
        x
    end
    ci, _ = WasmTarget.get_typed_ir(_f3_l0_outer_boxjoin, (Int64,))
    nir = WasmTarget.build_nir(ci)
    bs = WasmTarget.find_box_news(nir)
    @assert length(bs) == 1
    box_id = bs[1]

    # The root's own one-hop scan finds `level1` only; `level1` never writes the box directly (it
    # only creates+invokes `level2`, which does). Transitive discovery must surface BOTH bodies.
    bodies = WasmTarget._f3_capturing_closure_bodies(nir, box_id)
    @test length(bodies) == 2

    # The join over ALL writes (Int64 init, Int64 `+=` in level2, Float64 literal in level2) must
    # widen to dynamic (`nothing`) — Int64 alone (the one-hop answer) is the documented soundness gap.
    @test WasmTarget.box_contents_type(nir, nir, box_id) === nothing
end
