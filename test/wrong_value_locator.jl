# A wrong value is located at the first statement whose value differs between Julia and
# wasm (test/trace_localize.jl `first_divergence`): a planted miscompile is named at its
# statement, source line and iteration, with both values (dev/CHARTER.md C6, C10).
using Test
using WasmTarget
isdefined(@__MODULE__, :WasmRunner) || include(joinpath(@__DIR__, "wasm_runner.jl"))
using .WasmRunner
isdefined(@__MODULE__, :TraceLocalize) || include(joinpath(@__DIR__, "trace_localize.jl"))
using .TraceLocalize

_wv_sum(n::Int64) = (s = Int64(0); for i in 1:n; s += i * 3; end; s)   # line 11: the multiply
@noinline _wv_inner(i::Int64) = i * 5 + 1                                # line 12: in a callee
_wv_outer(n::Int64) = (s = Int64(0); for i in 1:n; s += _wv_inner(i); end; s)

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
    finally
        WasmTarget.INTRINSIC_BINOPS[k] = saved
    end
    # no miscompile: every traced statement agrees
    d = TraceLocalize.first_divergence(_wv_sum, Int64(4); js_args="4n")
    @test !d.found && d.ir_matches_julia
    d2 = TraceLocalize.first_divergence(_wv_outer, Int64(3); js_args="3n")
    @test !d2.found && d2.ir_matches_julia
end
