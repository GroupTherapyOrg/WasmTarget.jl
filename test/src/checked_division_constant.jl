# Julia's checked integer division by a constant divisor (src/intrinsics.jl generateStaticIntrinsic,
# Val(:checked_division)): Julia's codegen emits the DivideError test and raise for every divisor
# (julia/src/intrinsics.cpp:1594-1620, raise_exception_unless at julia/src/cgutils.cpp:1586), and Julia's LLVM
# pipeline deletes the raise where a constant divisor makes it unreachable (the IRBuilder's ConstantFolder,
# InstCombine's or/and folds, SimplifyCFG's ConstantFoldTerminator and removeUnreachableBlocks): a nonzero
# constant, and for checked_sdiv_int one that is not -1. Each body emits the raise exactly where that pipeline
# keeps it; compiled and run, each answers as native Julia, a DivideError where native throws one. Outside
# standalone mode a body whose raise is deleted translates, and one that keeps it stops at the stack trace
# class the JS runtime's thrower needs (js_helper.dart's JavaScriptStack, not ported), located.
module CheckedDivisionConstantTest

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "codegen_helpers.jl"))

module Cases
udiv16(x::UInt64) = div(x, UInt64(16))
urem10(x::UInt32) = rem(x, UInt32(10))
sdiv7(x::Int64) = div(x, Int64(7))
srem7(x::Int64) = rem(x, Int64(7))
srem_m1(x::Int64) = rem(x, Int64(-1))      # emit_checked_srem_int: only y != 0 raises; typemin rem -1 answers 0
sdiv8(x::Int64) = Int64(div(x % Int8, Int8(3)))      # an 8-bit division, its operand in its view
sdiv_m1(x::Int64) = div(x, Int64(-1))      # typemin ÷ -1 raises: the test stays
sdiv0(x::Int64) = div(x, Int64(0))         # y == 0: the raise stays
sdivv(x::Int64, y::Int64) = div(x, y)      # no constant: the test stays
end

const FOLDED = ((Cases.udiv16, (UInt64,)), (Cases.urem10, (UInt32,)), (Cases.sdiv7, (Int64,)), (Cases.srem7, (Int64,)),
                (Cases.srem_m1, (Int64,)), (Cases.sdiv8, (Int64,)))
const KEPT = ((Cases.sdiv_m1, (Int64,)), (Cases.sdiv0, (Int64,)), (Cases.sdivv, (Int64, Int64)))

@testset "intrinsics.cpp: each body divides by Julia's checked intrinsic, its constant divisor a literal" begin
    for (f, at) in (FOLDED..., KEPT...)
        local src = only(Base.code_typed(f, at; optimize = true))[1]
        local calls = [st for st in src.code if Meta.isexpr(st, :call) && st.args[1] isa GlobalRef &&
                       st.args[1].name in (:checked_sdiv_int, :checked_udiv_int, :checked_srem_int, :checked_urem_int)]
        @test length(calls) == 1
        @test (length(at) == 1) == (only(calls).args[3] isa Integer)
    end
end

@testset "intrinsics.cpp + LLVM's pipeline: the raise is emitted exactly where a constant divisor leaves it reachable" begin
    for (f, at) in FOLDED
        local names = generated_instructions(f, at; standalone = true)
        @test !("unreachable" in names) && !("if" in names)
    end
    for (f, at) in KEPT
        local names = generated_instructions(f, at; standalone = true)
        @test "if" in names && "unreachable" in names && "call" in names
    end
end

@testset "a checked division by a constant answers as native Julia, a DivideError where native throws" begin
    local runs = WTChild.RunCase[]
    for (f, at, xs) in ((Cases.udiv16, (UInt64,), UInt64[0, 15, 16, 17, typemax(UInt64)]),
                        (Cases.urem10, (UInt32,), UInt32[0, 9, 10, 12345, typemax(UInt32)]),
                        (Cases.sdiv7, (Int64,), Int64[typemin(Int64), -15, -7, 0, 6, 7, typemax(Int64)]),
                        (Cases.srem7, (Int64,), Int64[typemin(Int64), -15, 0, 13, typemax(Int64)]),
                        (Cases.srem_m1, (Int64,), Int64[typemin(Int64), -5, 0, 5]),
                        (Cases.sdiv8, (Int64,), Int64[-128, -7, 0, 7, 127, 300]),
                        (Cases.sdiv_m1, (Int64,), Int64[typemin(Int64), -5, 0, typemax(Int64)]),
                        (Cases.sdiv0, (Int64,), Int64[0, 3]))
        local bytes = W.compile(f, at)
        append!(runs, [WTChild.RunCase("$(nameof(f))($x)", bytes, (x,), WTChild.native_answer(f, (x,))) for x in xs])
    end
    local bytes = W.compile(Cases.sdivv, (Int64, Int64))
    append!(runs, [WTChild.RunCase("sdivv$a", bytes, a, WTChild.native_answer(Cases.sdivv, a))
                   for a in ((Int64(7), Int64(2)), (Int64(7), Int64(0)), (typemin(Int64), Int64(-1)), (typemin(Int64), Int64(1)))])
    @test count(r -> r.native isa WTChild.Throws, runs) == 5
    local results = WTChild.run_cases(runs)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == length(runs) && all(r -> r.ok, results)
end

@testset "outside standalone mode: a deleted raise reaches no thrower, a kept one stops at the JS stack trace class" begin
    for (f, at) in FOLDED
        @test rejection(() -> D.translate(translator_of(f, at), nothing)) === nothing
    end
    for (f, at) in KEPT
        local r = rejection(() -> D.translate(translator_of(f, at), nothing))
        @test r isa W.RejectionError && r.rejection isa W.Unported &&
              r.rejection.anchor == "sdk/lib/_internal/wasm/js_common/js_helper.dart:830 JavaScriptStack"
    end
end

end
