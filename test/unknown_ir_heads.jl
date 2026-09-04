using Test
using WasmTarget

# dev/MARCH.md Phase 6.4: :splatnew and :copyast had zero handling anywhere in
# src. `compile_statement!`'s `stmt.head` dispatch (statements.jl) previously
# had no final `else` branch, so an unmodeled head fell all the way through
# with `stmt_bytes` left empty — no diagnostic, no trap, and (for a statement
# whose SSA value is consumed later) a silently WRONG compiled module. The
# dispatch now rejects any unmodeled head through `record_unsupported!(ctx,
# :ir_node, ...)`, matching dart's structured DiagnosticReporter shape.

# :copyast is genuinely reachable: any function body containing a quoted
# expression literal (`:(a + b)`) lowers to `Expr(:copyast, QuoteNode(...))`,
# and — unlike :splatnew below — Julia's optimizer does NOT eliminate it.
_wt_quoted_expr_probe() = :(a + b)

@testset "unknown IR heads reject loudly" begin
    err = @test_throws WasmTarget.WasmCompileError WasmTarget.compile(
        _wt_quoted_expr_probe, (); validate=false)
    @test occursin("copyast", sprint(showerror, err.value))
end

# :splatnew is dart2wasm-absent in a different way: it exists at the Julia IR
# level (e.g. Base's `@eval function _new_NamedTuple(T, args::Tuple)
# $(Expr(:splatnew, :T, :args)) end`, namedtuple.jl) but Julia's own SSA
# optimizer resolves it to a concrete `:new` whenever the tuple type is fully
# concrete — which it always is by the time WT's closed-world compiler (which
# calls `code_typed(...; optimize=true)`, ir.jl:17) can compile a function at
# all. A dynamic-length splat that could keep :splatnew alive under inference
# would fail earlier, at the Vararg/`_apply_iterate` boundary, not here.
# This is the differential proof the march calls for in lieu of an end-to-end
# :splatnew regression case: prove the elimination holds for WT's actual
# optimize=true IR retrieval, not just that a handler exists.
@testset "splatnew is eliminated before WT's typed IR (differential proof)" begin
    T = NamedTuple{(:a, :b), Tuple{Int64,Int64}}
    ci, _ = WasmTarget.get_typed_ir(Base._new_NamedTuple, (Type{T}, Tuple{Int64,Int64}); optimize=true)
    @test !any(stmt -> stmt isa Expr && stmt.head === :splatnew, ci.code)
    @test any(stmt -> stmt isa Expr && stmt.head === :new, ci.code)
    # And the handler still exists and would reject it if this ever changes:
    # a direct :splatnew Expr reaching compile_statement! is rejected the same
    # way :copyast is (same `else` branch — proven above).
end
