# F3 sub-loop L0 (dev/HISTORY.md#closures-and-dynamic-dispatch) — unit tests for the PURE Core.Box contents-type inference.
#
# `box_contents_type` computes the captured variable's REAL type = the join of the enclosing init
# and every closure write's COMPUTED result type (closure bodies via the invoke CodeInstance; write
# types via Core.Compiler.return_type past the box's Any-erasure). Concrete join → that type (typed
# cell); Union/abstract/Any → `nothing` (anyref-boxed = dart2wasm's top-type field). This mirrors
# dart2wasm's `translateTypeOfLocalVariable` — reconstructing what Julia erased, not a heuristic.
# Pure analysis, not wired into codegen yet (byte-identical).

# The box-capture analysis takes every closure body of a callable type (closure_bodies) and asks
# each call's return type of `rettype`: a compilation passes its collected world's bodies and the
# collector's inference entry; a test outside any compilation takes every specialization Julia
# holds of the type's call methods, inferred by the WasmInterpreter, and that same entry.
_f3_bodies_l0(@nospecialize(T)) = Tuple{Core.MethodInstance,Core.CodeInfo}[
    (mi, r[1][1]) for m in Base._methods_by_ftype(Tuple{T, Vararg{Any}}, -1, Base.get_world_counter())
    for mi in Base.specializations(m.method)
    if mi isa Core.MethodInstance && mi.specTypes isa DataType && mi.specTypes.parameters[1] === T
    for r in (Base.code_typed_by_type(mi.specTypes; interp=WasmTarget.get_wasm_interpreter()),) if !isempty(r)]

@testset "F3 L0: pure box_contents_type inference (dart2wasm-aligned)" begin
    _btype(fn) = begin
        ci = code_typed(fn, (Int64,); optimize=true)[1].first
        nir = WasmTarget.build_nir(ci)
        bs = WasmTarget.find_box_news(nir)
        @assert length(bs) == 1
        WasmTarget.box_contents_type(nir, nir, bs[1]; closure_bodies=_f3_bodies_l0, rettype=WasmTarget.infer_return_type)
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
    @test WasmTarget.box_contents_type(WasmTarget.NirStmt[], Any[], 1; closure_bodies=_f3_bodies_l0, rettype=WasmTarget.infer_return_type) === nothing
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
    bodies = WasmTarget._f3_capturing_closure_bodies(nir, box_id; closure_bodies=_f3_bodies_l0)
    @test length(bodies) == 2

    # The join over ALL writes (Int64 init, Int64 `+=` in level2, Float64 literal in level2) must
    # widen to dynamic (`nothing`) — Int64 alone (the one-hop answer) is the documented soundness gap.
    @test WasmTarget.box_contents_type(nir, nir, box_id; closure_bodies=_f3_bodies_l0, rettype=WasmTarget.infer_return_type) === nothing

    # A captor body the scanned code invokes that the closed world does not hold is one whose
    # writes no one can see: the walk is loud, never a narrowing to the creator's Int64 init
    # (BoxJoin.tla EveryCaptorBody)
    local none = T -> Tuple{Core.MethodInstance,Core.CodeInfo}[]
    @test_throws WasmTarget.WasmInternalError WasmTarget._f3_capturing_closure_bodies(nir, box_id; closure_bodies=none)
    local err = try
        WasmTarget.box_contents_type(nir, nir, box_id; closure_bodies=none, rettype=WasmTarget.infer_return_type,
                                     spectypes=WasmTarget.nir_slot_types(ci))
        nothing
    catch e
        e
    end
    @test err isa WasmTarget.WasmInternalError
    # it names the creator body, the invoking statement and the captor body
    @test occursin("_f3_l0_outer_boxjoin", sprint(showerror, err))
    @test occursin("invokes the captor body", sprint(showerror, err)) && err.stmt_idx > 0
end

# formal(dev/formal/BoxJoin.tla) — a captor called elsewhere. The creator makes a closure that
# writes the box and does not call it: it returns it, and its caller calls it. A walk that read
# captor bodies through the creator's `:invoke`s never saw the Float64 write and narrowed the cell
# to the Int64 the creator writes (MCBoxJoinCaptorMissedBroken.cfg); the walk takes every body of
# each captor type, so the join is dynamic.
_f3_l0_mk_writer(n::Int64) = (x = n; w = () -> (x = x + 0.5; nothing); x += 1; (w, () -> x))
@testset "F3 L0: every body of a captor type, called here or not (BoxJoin.tla EveryCaptorBody)" begin
    local pair = _f3_l0_mk_writer(1)
    pair[1](); pair[2]()   # Julia specializes both bodies, as the closed world would hold them
    ci = code_typed(_f3_l0_mk_writer, (Int64,); optimize = true)[1].first
    nir = WasmTarget.build_nir(ci)
    box_id = only(WasmTarget.find_box_news(nir))
    @test !any(s -> s.node isa WasmTarget.NirInvoke, nir)   # the creator calls neither closure
    bodies = WasmTarget._f3_capturing_closure_bodies(nir, box_id; closure_bodies=_f3_bodies_l0)
    @test length(bodies) == 2
    @test WasmTarget.box_contents_type(nir, nir, box_id; spectypes=WasmTarget.nir_slot_types(ci),
                                       closure_bodies=_f3_bodies_l0, rettype=WasmTarget.infer_return_type) === nothing
end
