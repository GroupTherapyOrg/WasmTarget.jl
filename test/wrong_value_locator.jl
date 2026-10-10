# A wrong value is located at the first statement whose value differs between Julia and
# wasm (test/trace_localize.jl `first_divergence`): a planted miscompile is named at its
# statement, source line and iteration, with both values, in callees and closures (C6, C10).
using Test
using WasmTarget
isdefined(@__MODULE__, :WasmRunner) || include(joinpath(@__DIR__, "wasm_runner.jl"))
using .WasmRunner
isdefined(@__MODULE__, :TraceLocalize) || include(joinpath(@__DIR__, "trace_localize.jl"))
using .TraceLocalize

_wv_sum(n::Int64) = (s = Int64(0); for i in 1:n; s += i * 3; end; s)   # line 11: the multiply
@noinline _wv_inner(i::Int64) = i * 5 + 1                                # line 12: in a callee
_wv_outer(n::Int64) = (s = Int64(0); for i in 1:n; s += _wv_inner(i); end; s)
@noinline _wv_apply(g, i) = g(i)
_wv_clo(n::Int64) = (k = n + 2; g = @noinline i -> i * k; s = 0; for i in 1:n; s += _wv_apply(g, i); end; s)   # line 15: in a closure
_wv_inst(n::Int64) = (s = 0; for j in 1:n; g = @noinline i -> i * j + 1; s += _wv_apply(g, j); end; s)

@testset "a wrong value is located at its first divergent statement" begin
    # a planted miscompile: the intrinsics table's mul_int row emits a subtract (restored after)
    k = (WasmTarget.I64, WasmTarget.I64, :mul_int)
    saved = WasmTarget.INTRINSIC_BINOPS[k]
    WasmTarget.INTRINSIC_BINOPS[k] = WasmTarget.BinOpEmit((b, ctx, jw) -> WasmTarget.num!(b, WasmTarget.Opcode.I64_SUB), saved.result)
    try
        d = TraceLocalize.first_divergence(_wv_sum, Int64(4); js_args="4n")
        @test d.found
        @test occursin("mul_int", d.text)
        @test d.iteration == 1
        @test d.native == "3" && d.wasm == "-2"      # i * 3 at i = 1: 3 natively, 1 - 3 in wasm
        @test d.ir_matches_julia                     # WT's IR run natively is Julia's answer: codegen
        @test any(f -> occursin("wrong_value_locator.jl:11", f), d.frames)
        println(d.summary)
        # the same miscompile inside a callee WT compiled separately: the run is followed into it
        d2 = TraceLocalize.first_divergence(_wv_outer, Int64(3); js_args="3n")
        @test d2.found && occursin("_wv_inner", d2.func) && occursin("mul_int", d2.text)
        @test d2.native == "5" && d2.wasm == "-4"    # i * 5 at i = 1: 5 natively, 1 - 5 in wasm
        @test any(f -> occursin("wrong_value_locator.jl:12", f), d2.frames)
        println(d2.summary)
        # inside a closure that reads its own capture (`k`), called through another function:
        # the run is followed into the closure's body, its `#self#` the instance the call passed
        d3 = TraceLocalize.first_divergence(_wv_clo, Int64(3); js_args="3n")
        @test d3.found && occursin("#", d3.func) && occursin("_wv_clo", d3.func) && occursin("mul_int", d3.text)
        @test d3.iteration == 1
        @test d3.native == "5" && d3.wasm == "-4"    # i * k at i = 1, k = 5: 5 natively, 1 - 5 in wasm
        @test any(f -> occursin("wrong_value_locator.jl:15", f), d3.frames)
        println(d3.summary)
    finally
        WasmTarget.INTRINSIC_BINOPS[k] = saved
    end
    # no miscompile: every traced statement agrees
    d = TraceLocalize.first_divergence(_wv_sum, Int64(4); js_args="4n")
    @test !d.found && d.ir_matches_julia
    d2 = TraceLocalize.first_divergence(_wv_outer, Int64(3); js_args="3n")
    @test !d2.found && d2.ir_matches_julia
    d3 = TraceLocalize.first_divergence(_wv_clo, Int64(3); js_args="3n")
    @test !d3.found && d3.ir_matches_julia
    # a closure built in the loop, a new capture each iteration: each call runs with its own
    # instance, never a fixed environment
    d4 = TraceLocalize.first_divergence(_wv_inst, Int64(4); js_args="4n")
    @test !d4.found && d4.ir_matches_julia
    println(d4.summary)
end
