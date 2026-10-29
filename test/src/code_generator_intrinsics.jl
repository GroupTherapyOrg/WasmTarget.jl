# dart2wasm's intrinsics.dart and code_generator.dart's first compiles, ported (src/intrinsics.jl,
# src/code_generator.jl): Julia's intrinsics matched to the instructions Julia's codegen answers with,
# whole functions of them compiled and run against native Julia, the narrow integers and Float32
# literals, and the first compile through WasmTarget.compile.
module CodeGeneratorIntrinsicsTest

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "codegen_helpers.jl"))

@testset "intrinsics.dart: Julia's intrinsics, by the instructions Julia's codegen answers" begin
    local B = D.Intrinsifier__binary_operator_map[]
    local U = D.Intrinsifier__unary_operator_map[]
    local i32, i64, f32, f64 = IR.NumType_i32, IR.NumType_i64, IR.NumType_f32, IR.NumType_f64
    # dart's static constants
    @test D.Intrinsifier_bool_type() == i32 && D.Intrinsifier_int_type() == i64 && D.Intrinsifier_double_type() == f64
    # integer arithmetic wraps in both widths, as Julia's; the sign is the intrinsic's own
    for w in (i32, i64)
        @test issubset((Core.Intrinsics.add_int, Core.Intrinsics.sub_int, Core.Intrinsics.mul_int, Core.Intrinsics.slt_int,
                        Core.Intrinsics.ult_int, Core.Intrinsics.sdiv_int, Core.Intrinsics.urem_int), keys(B[w][w]))
        @test !haskey(B[w][w], Core.Intrinsics.add_float) && issubset((Core.Intrinsics.neg_int, Core.Intrinsics.not_int), keys(U[w]))
    end
    for w in (f32, f64)
        @test issubset((Core.Intrinsics.add_float, Core.Intrinsics.div_float, Core.Intrinsics.lt_float), keys(B[w][w]))
        @test issubset((Core.Intrinsics.neg_float, Core.Intrinsics.sqrt_llvm, Core.Intrinsics.rint_llvm), keys(U[w]))
    end
    # no arm mixes operand types, which Julia's intrinsics never do
    @test !haskey(B[i32], i64) && !haskey(B[f64], f32)
    # dart's negation and complement are Julia's: -x == x * -1, ~x == x ⊻ -1 at every width
    for x in Int32[0, 1, -7, typemax(Int32), typemin(Int32)]
        @test Core.Intrinsics.neg_int(x) == x * Int32(-1) && Core.Intrinsics.not_int(x) == x ⊻ Int32(-1)
    end
    # comparisons give a Bool, an i32
    @test D.Intrinsifier_is_comparison(Core.Intrinsics.ule_int) && D.Intrinsifier_is_comparison(Core.Intrinsics.ne_float)
    @test !D.Intrinsifier_is_comparison(Core.Intrinsics.add_int)
    # no Julia method is an intrinsic of dart's: a call Julia resolved is the method's own body
    local g = codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    @test D.MemberIntrinsic_from_procedure(g.member) === nothing && D.StaticIntrinsic_from_procedure(g.member) === nothing
    # Int32's add_int has its arm: its operands, then the add
    local ga = ready_codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    @test emitted_by(() -> D.generate_static_intrinsic(ga.intrinsifier[], ga.body.stmts[1]::W.NirCall), ga) ==
          ["local.get", "i32.const 1", "i32.add"]
    # an 8-bit add wraps at 8 bits in Julia, at 32 in an i32: the i32 add, then the operand's form put
    # back (i32.extend8_s)
    local n = ready_codegen_of(CodegenCases.f_narrow, (Int8,), [IR.NumType_i32], [IR.NumType_i32])
    local ncall = n.body.stmts[findfirst(s -> s isa W.NirCall, n.body.stmts)]::W.NirCall
    @test emitted_by(() -> D.generate_static_intrinsic(n.intrinsifier[], ncall), n) ==
          ["local.get", "i32.const 1", "i32.add", "i32.extend8_s"]
end

@testset "intrinsics.dart: Julia's identity, ifelse, conversions and shifts" begin
    local I = Core.Intrinsics
    local g = ready_codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    local p = ready_codegen_of(CodegenCases.f_poly, (Float64, Float64), [IR.NumType_f64, IR.NumType_f64], [IR.NumType_f64])
    local n = ready_codegen_of(CodegenCases.f_narrow, (Int8,), [IR.NumType_i32], [IR.NumType_i32])
    local lit(v) = W.NirConst(Core.Const(v))
    local x = W.NirArgument(2)
    local call(f, args...) = W.NirCall(W.NirValue[lit(f), args...])
    # an arm found emits its operands, then its instructions; no arm is nothing, emitting nothing, the
    # call then rejecting where it stands
    local emits(gen, c) = emitted_by(() -> D.generate_static_intrinsic(gen.intrinsifier[], c), gen)
    local absent(gen, c) = D.generate_static_intrinsic(gen.intrinsifier[], c) === nothing
    # Julia's === compares bits, so a float is compared as its bits' integer: native Julia's answers
    @test (NaN === NaN) && !(0.0 === -0.0) && reinterpret(Int64, NaN) == reinterpret(Int64, NaN)
    @test emits(g, call(Core.:(===), x, lit(Int32(3)))) == ["local.get", "i32.const 3", "i32.eq"]
    @test emits(p, call(Core.:(===), x, W.NirArgument(3))) == ["local.get", "i64.reinterpret_f64", "local.get", "i64.reinterpret_f64", "i64.eq"]
    @test absent(g, call(Core.:(===), x, lit(Int64(3))))   # different types: no value comparison
    @test emits(g, call(Core.ifelse, lit(true), x, x)) == ["local.get", "local.get", "i32.const 1", "select"]
    @test absent(g, call(Core.ifelse, lit(true), x, lit(1.0)))
    # conversions between full-width types, each its one instruction (a bitcast between two integers of
    # one width none); a narrow one puts the operand's form back; fpext has no arm
    @test emits(g, call(I.sext_int, lit(Int64), x)) == ["local.get", "i64.extend_i32_s"]
    @test emits(g, call(I.zext_int, lit(UInt64), x)) == ["local.get", "i64.extend_i32_u"]
    @test emits(g, call(I.sitofp, lit(Float64), x)) == ["local.get", "f64.convert_i32_s"]
    @test emits(g, call(I.bitcast, lit(Float32), x)) == ["local.get", "f32.reinterpret_i32"]
    @test emits(g, call(I.bitcast, lit(UInt32), x)) == ["local.get"]
    @test emits(p, call(I.fptosi, lit(Int64), x)) == ["local.get", "i64.trunc_sat_f64_s"]
    @test emits(p, call(I.fptrunc, lit(Float32), x)) == ["local.get", "f32.demote_f64"]
    @test emits(p, call(I.bitcast, lit(Int64), x)) == ["local.get", "i64.reinterpret_f64"]
    @test emits(g, call(I.trunc_int, lit(Int8), x)) == ["local.get", "i32.extend8_s"]
    @test emits(n, call(I.sext_int, lit(Int32), x)) == ["local.get"]
    @test absent(g, call(I.fpext, lit(Float64), x))
    # Julia's shifts saturate, the count unsigned: native Julia's answers, which the select ports
    @test I.shl_int(Int32(1), UInt64(40)) == 0 && I.lshr_int(Int32(-1), UInt8(32)) == 0
    @test I.ashr_int(Int32(-8), UInt64(100)) == -1 && I.ashr_int(Int32(8), UInt64(100)) == 0 && I.shl_int(Int64(3), Int32(-1)) == 0
    # a shift's arm takes a local for the count first, from the builder `generate` gives: before it,
    # the late builder rejects, located
    local gu = codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    local nu = codegen_of(CodegenCases.f_narrow, (Int8,), [IR.NumType_i32], [IR.NumType_i32])
    local e = rejection(() -> D.generate_static_intrinsic(gu.intrinsifier[], call(I.shl_int, x, lit(Int64(3)))))
    @test e.rejection isa W.Unported && occursin("AstCodeGenerator.b", e.rejection.anchor)
    # an 8-bit shift has its arm: its count's local comes first, from the builder not given here
    @test occursin("AstCodeGenerator.b", rejection(() -> D.generate_static_intrinsic(nu.intrinsifier[], call(I.shl_int, x, lit(Int64(3))))).rejection.anchor)
end

@testset "code_generator.dart: the first compile, f(x::Int32) = x + Int32(1)" begin
    # WasmTarget.compile runs the whole pipeline (compile.dart's phases, translate): the module our
    # builder accepted instruction by instruction; run by node it answers as native Julia on 0, 41,
    # -1, typemax and typemin, the add wrapping
    local bytes = W.compile(CodegenCases.f_add, (Int32,); optimize = false)
    queue_native!("f_add", bytes, CodegenCases.f_add, [(x,) for x in Int32[0, 41, -1, typemax(Int32), typemin(Int32)]])
    @test bytes[1:8] == UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
    # the body: local.get 0, i32.const 1, i32.add
    @test any(i -> bytes[i:i+4] == UInt8[0x20, 0x00, 0x41, 0x01, 0x6a], 1:length(bytes)-4)
    # the entry exported under its function's name
    @test occursin("f_add", String(copy(bytes)))
end

module IntrinsicCompileCases
mulshift(x::Int64, y::Int64) = x * y - (x >> 3)
floorabs(x::Float64) = floor(x) + abs(x)
scale(x::Int32) = Float64(x) * 2.5
absint(x::Int64) = abs(x)
bits(x::Int64) = leading_zeros(x) + trailing_zeros(x) + count_ones(x)
notand(a::Bool, b::Bool) = !a & b
notb(a::Bool) = !a
minmax(x::Int32, y::Int32) = min(x, y) + max(x, y)
widen32(x::Int32) = Int64(reinterpret(UInt32, x)) + 1
egal(x::Float64, y::Float64) = x === y
end

@testset "intrinsics.dart: whole functions of Julia's intrinsics compile" begin
    # each compiles to a module the builder accepted instruction by instruction (D10); run by node,
    # each answers as native Julia on its edge inputs
    local C = IntrinsicCompileCases
    local i64s = Int64[0, 1, -1, 7, typemax(Int64), typemin(Int64)]
    local i32s = Int32[0, 41, -1, typemax(Int32), typemin(Int32)]
    local f64s = [0.0, -0.0, 1.5, -2.5, 1e300, -Inf, NaN]
    for (f, at, argsets) in ((C.mulshift, (Int64, Int64), [(a, b) for a in i64s for b in i64s]), (C.floorabs, (Float64,), [(x,) for x in f64s]),
                             (C.absint, (Int64,), [(x,) for x in i64s]), (C.notand, (Bool, Bool), [(a, b) for a in (false, true) for b in (false, true)]),
                             (C.notb, (Bool,), [(false,), (true,)]),
                             (C.widen32, (Int32,), [(x,) for x in i32s]))
        local bytes = compile_one(f, at)
        @test bytes[1:8] == UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
        queue_native!(string(nameof(f)), bytes, f, argsets)
    end
    # Bool's not_int is Kernel's Not, visitNot's alone: the intrinsifier has no arm for it
    local nb = ready_codegen_of(C.notb, (Bool,), [IR.NumType_i32], [IR.NumType_i32])
    @test D.generate_static_intrinsic(nb.intrinsifier[], W.NirCall(W.NirValue[W.NirConst(Core.Const(Core.Intrinsics.not_int)), W.NirArgument(2)])) === nothing
end

module TruncCases
tr64(x::Float64) = unsafe_trunc(Int64, x)
tru32(x::Float64) = unsafe_trunc(UInt32, x)
end

@testset "intrinsics.dart: fptosi and fptoui never trap" begin
    # Julia's unsafe_trunc is the bare intrinsic, its unrepresentable value arbitrary: natively it
    # saturates, NaN 0 (aarch64), which wasm's saturating truncation (0xfc prefix) gives; the trapping
    # truncation (0xb0, 0xab) is no Julia behavior
    local b64 = compile_one(TruncCases.tr64, (Float64,))
    local b32 = compile_one(TruncCases.tru32, (Float64,))
    local has(bytes, seq) = any(i -> bytes[i:i+length(seq)-1] == seq, 1:length(bytes)-length(seq)+1)
    @test has(b64, UInt8[0xfc, 0x06]) && !has(b64, UInt8[0xb0])      # i64.trunc_sat_f64_s, not i64.trunc_f64_s
    @test has(b32, UInt8[0xfc, 0x03]) && !has(b32, UInt8[0xab])      # i32.trunc_sat_f64_u, not i32.trunc_f64_u
    @test unsafe_trunc(Int64, 1e30) == typemax(Int64) || Sys.ARCH !== :aarch64
end

module NarrowCases
add8(x::Int8, y::Int8) = x + y
lt8u(x::UInt8, y::UInt8) = x < y
neg8(x::Int8) = -x
widen8(x::Int8) = Int64(x) + Int64(1)
lshr8(x::Int8) = Core.Intrinsics.lshr_int(x, 0x03)
end

# each narrow case behind Int32 arguments and answers, the types the runner marshals: the 8-bit
# operations run inside, the conversions at the edges
module NarrowWires
import ..NarrowCases as N
add8(x::Int32, y::Int32) = Int32(N.add8(x % Int8, y % Int8))
lt8u(x::Int32, y::Int32) = N.lt8u(x % UInt8, y % UInt8)
neg8(x::Int32) = Int32(N.neg8(x % Int8))
widen8(x::Int32) = N.widen8(x % Int8)
lshr8(x::Int32) = Int32(N.lshr8(x % Int8))
end

@testset "intrinsics.dart: 8- and 16-bit integers, in their type's form" begin
    # each compiles, our builder accepting every instruction; behind Int32 arguments, run by node over
    # every pair of edge values (-128, -1, 0, 1, 100, 127 and 0, 1, 100, 200, 255), each answers as
    # native Julia
    local C = NarrowCases
    for (f, at) in ((C.add8, (Int8, Int8)), (C.lt8u, (UInt8, UInt8)), (C.neg8, (Int8,)), (C.widen8, (Int8,)), (C.lshr8, (Int8,)))
        @test compile_one(f, at)[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    end
    local e8 = Int32[-128, -1, 0, 1, 100, 127]
    local u8 = Int32[0, 1, 100, 200, 255]
    local Wr = NarrowWires
    for (f, argsets) in ((Wr.add8, [(a, b) for a in e8 for b in e8]), (Wr.lt8u, [(a, b) for a in u8 for b in u8]),
                         (Wr.neg8, [(x,) for x in e8]), (Wr.widen8, [(x,) for x in e8]), (Wr.lshr8, [(x,) for x in e8]))
        queue_native!(string(nameof(f)), compile_one(f, map(typeof, first(argsets))), f, argsets)
    end
    # the add of two Int8s puts its result back sign-extended, i32.extend8_s right after the i32.add
    local ins = generated_instructions(C.add8, (Int8, Int8))
    local k = findfirst(==("i32.add"), ins)
    @test k !== nothing && ins[k + 1] == "i32.extend8_s"
end

module Float32Cases
addf(x::Float32) = x + 1.5f0
end

@testset "constants.dart: a Float32 literal is an f32.const of its value" begin
    # visitDoubleConstant pushes the literal through the builder's f32_const, dart's double narrowed
    # to the f32 the instruction holds: f32.const 1.5 (0x43, then 1.5f0's little-endian bytes)
    local bytes = compile_one(Float32Cases.addf, (Float32,))
    @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    local f32 = UInt8[0x43, reinterpret(UInt8, [1.5f0])...]
    @test any(i -> bytes[i:i+4] == f32, 1:length(bytes)-4)
    # run by node, it answers as native Julia, the f32 crossing as its bits
    queue_native!("addf", bytes, Float32Cases.addf, [(x,) for x in Float32[0, -0.0, 1, -1.5, 3.0f38, Inf, NaN]])
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTRunner.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end

end
