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
        # the fast-math forms Julia's codegen gives the same LLVM operation with fast flags
        # (src/intrinsics.cpp:1527 llvm.minimum, :1536 llvm.maximum, :1754 llvm.sqrt): wasm's min, max, sqrt
        @test issubset((Core.Intrinsics.min_float_fast, Core.Intrinsics.max_float_fast), keys(B[w][w]))
        @test Core.Intrinsics.sqrt_llvm_fast in keys(U[w])
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
    @test emits(g, call(Core.:(===), x, lit(Int64(3)))) == ["i32.const 0"]   # disjoint types: never egal (emit_f_is)
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

# Base's muladd and fma, one rounding as natively on the FMA host (Base's emulated fma), the fused
# answer where two roundings lose it (1 + 2^-30 times 1 - 2^-30, less 1, is -2^-60); have_fma true, as
# that host answers; fpiseq, Float64's and Float32's isequal; bswap_int on every width Julia's bswap
# takes it, LLVM's expansion
module FloatBitCases
mad(x::Float64) = muladd(x, 2.0, 0.5) + 2.0^70 * muladd(1.0 + x * 2.0^-30, 1.0 - 2.0^-30, -1.0)
mad32(x::Float32) = muladd(x, 4.0f0, -1.25f0)
fma32(x::Float32) = fma(x, 0.1f0, -0.3f0)
iseq(x::Float64, y::Float64) = isequal(x, y)
iseq32(x::Float32, y::Float32) = isequal(x, y)
# the 16-bit operands made inside (the runner passes no 16-bit argument): z's low bits, w's wrapped
swap(x::UInt32, y::Int64, z::Int64, w::Int64) = (UInt64(bswap(x)) ⊻ reinterpret(UInt64, bswap(y))) +
    UInt64(bswap(z % UInt16)) + UInt64(reinterpret(UInt16, bswap(w % Int16))) + (bswap(w % Int16) < 0 ? UInt64(1) << 40 : UInt64(0))
end

@testset "intrinsics.cpp: muladd and fma in one rounding, have_fma, fpiseq and bswap_int against native" begin
    local C = FloatBitCases
    local f64s = [0.0, -0.0, 1.5, -2.5, 1e300, -Inf, NaN]
    local f32s = Float32[0, -0.0, 1.5, -2.5, 3.0f38, -Inf, NaN, 0.7f0, 1.0f-30]
    for (f, at, argsets) in ((C.mad, (Float64,), [(x,) for x in f64s]), (C.mad32, (Float32,), [(x,) for x in f32s]),
                             (C.fma32, (Float32,), [(x,) for x in f32s]),
                             (C.iseq, (Float64, Float64), [(x, y) for x in f64s for y in f64s]),
                             (C.iseq32, (Float32, Float32), [(x, y) for x in f32s for y in f32s]),
                             (C.swap, (UInt32, Int64, Int64, Int64), [(UInt32(0x12345678), Int64(0x0102030405060708), Int64(0xabcd), Int64(-2)),
                                                                     (typemax(UInt32), typemin(Int64), Int64(1), Int64(-32768)),
                                                                     (UInt32(0), Int64(-1), Int64(0xff00), Int64(0x7f01))]))
        local bytes = W.compile(f, at; optimize = false)
        queue_native!(string(nameof(f)), bytes, f, argsets)
    end
    # have_fma of a constant Float64 or Float32 is the native FMA host's answer, true
    local g = ready_codegen_of(C.mad, (Float64,), [IR.NumType_f64], [IR.NumType_f64])
    @test emitted_by(() -> D.generate_static_intrinsic(g.intrinsifier[], W.NirCall(W.NirValue[W.NirConst(Core.Const(Core.Intrinsics.have_fma)), W.NirConst(Core.Const(Float64))])), g) == ["i32.const 1"]
end

# Julia's donotdelete: its value the constant nothing, each argument with a run-time value consumed
# (julia/src/codegen.cpp:4988), a constant or ghost argument not
module DoNotDeleteCases
keep(x::Int64, y::Float64) = (Base.donotdelete(x, y, 3, nothing); x + 1)
keepnothing(x::Int64) = Base.donotdelete(x) === nothing ? x : -x
end

@testset "codegen.cpp: donotdelete consumes its run-time arguments and is nothing, against native" begin
    local C = DoNotDeleteCases
    for (f, at, argsets) in ((C.keep, (Int64, Float64), [(Int64(1), 2.5), (typemax(Int64), -0.0)]),
                             (C.keepnothing, (Int64,), [(Int64(7),), (Int64(-3),)]))
        local bytes = W.compile(f, at; optimize = false)
        queue_native!(string(nameof(f)), bytes, f, argsets)
    end
end

# a 128-bit integer, its class's struct of two i64 halves (LLVM's expansion of an i128): a constant's
# halves, sext_int and zext_int into it, trunc_int out of it, bitcast between Int128 and UInt128, and
# eq_int, ne_int and === over its halves
module Int128Cases
const BIG = Int128(1) << 100 + Int128(12345)
const UBIG = typemax(UInt128) - UInt128(7)
wide(n::Int64) = Int64(Int128(n) % Int64) + Int64(Int128(n) == BIG) * 10 + Int64(Int128(n) != Int128(n)) * 100 +
    Int64(BIG % Int64) + Int64((BIG >> 64) % Int64) * 3 + Int64(UBIG % UInt32) +
    Int64(reinterpret(UInt128, Int128(n)) == UInt128(n % UInt64)) * 1000 + Int64(UInt128(UInt32(n % UInt32)) % Int32) * 7 +
    Int64(Int128(n) === Int128(n % Int32)) * 100_000 + Int64(Int128(n % Int8) % Int16)
# add, sub, neg, the bitwise operations and the compares over the halves, the carries and borrows
# between them crossed (BIG's low half near its top, typemax's wrap), each high half observed by a
# compare against a constant
const NEARTOP = Int128(typemax(UInt64)) - Int128(2)
function arith(a::Int64, b::Int64)
    local x = NEARTOP + Int128(a)
    local y = BIG - Int128(b)
    local r = x + y
    local s = x - y
    local u = reinterpret(UInt128, x)
    local v = reinterpret(UInt128, -y)
    return Int64(r % Int64) + 3 * Int64(s % Int64) + 5 * Int64((-x) % Int64) + 7 * Int64(((x & y) | (x ⊻ ~y)) % Int64) +
        11 * Int64(x < y) + 13 * Int64(x <= y) + 17 * Int64(u < v) + 19 * Int64(u <= v) + 23 * Int64(r > BIG) +
        29 * Int64(s < -BIG) + 31 * Int64(typemax(Int128) + Int128(a) < Int128(0)) + 37 * Int64(x > Int128(typemax(UInt64)))
end
# mul_int (compiler-rt's __multi3) and the shifts (__ashlti3, __lshrti3, __ashrti3 within Julia's
# rule for an amount of the width or more), each result's halves both observed
halves(r::Int128) = Int64(r % Int64) ⊻ (Int64((r >> 64) % Int64) * 31)
uhalves(r::UInt128) = Int64(r % UInt64 % Int64) ⊻ (Int64((r >> 64) % UInt64 % Int64) * 37)
function mulshift(a::Int64, n::Int64)
    local x = NEARTOP * Int128(a) + Int128(n)
    local y = BIG - Int128(n)
    local u = reinterpret(UInt128, x) * reinterpret(UInt128, y)
    return halves(x * y) + 3 * uhalves(u) + 5 * halves(typemin(Int128) * Int128(a)) +
        7 * halves(x << n) + 11 * halves(x >> n) + 13 * uhalves(u >>> n) + 17 * uhalves(u << (n % UInt8)) +
        19 * halves(x >> (n % UInt128))
end
# the expansions' branches on a literal operand (LegalizeIntegerTypes.cpp): an add of 1, of all ones
# in the low half alone and in both halves, a literal on the left of an add and of a compare (moved
# right), equality with -1, the sign-bit tests x < 0 and x > -1, a compare of a value with itself, and
# shifts by literal amounts below, at and past a half's width and past the type's; and compares whose
# literal decides a half (TargetLowering.cpp's SimplifySetCC: x < 2^64's low compare false, so the high
# compare answers alone; x >= 2^64's low compare true; u <= MAX-5 rewritten u < MAX-4); and a
# zero-extended value compared, against a literal and against a value
function literals(a::Int64, b::Int64)
    local x = NEARTOP * Int128(a) + Int128(b)
    local u = reinterpret(UInt128, x)
    return halves(x + Int128(1)) + 3 * halves(x + Int128(typemax(UInt64))) + 5 * halves(x + Int128(-1)) +
        7 * halves(Int128(5) + x) + 11 * halves(x - Int128(1)) +
        13 * Int64(x == Int128(-1)) + 17 * Int64(x != Int128(-1)) + 19 * Int64(x < Int128(0)) + 23 * Int64(x > Int128(-1)) +
        29 * Int64(Int128(3) < x) + 31 * Int64(Int128(3) <= x) + 37 * Int64(UInt128(3) < u) + 41 * Int64(x >= Int128(0)) +
        43 * Int64(x < x) + 47 * Int64(u <= u) +
        53 * halves(x << 3) + 59 * halves(x << 64) + 61 * halves(x << 70) + 67 * halves(x >> 3) + 71 * halves(x >> 64) +
        73 * halves(x >> 100) + 79 * uhalves(u >>> 3) + 83 * uhalves(u >>> 64) + 89 * uhalves(u >>> 100) +
        97 * halves(x << 200) + 101 * halves(x >> 200) +
        103 * Int64(x < Int128(1) << 64) + 107 * Int64(x >= Int128(1) << 64) + 109 * Int64(u <= typemax(UInt128) - UInt128(5)) +
        113 * Int64(UInt128(reinterpret(UInt64, a)) < UInt128(1) << 64) + 127 * Int64(UInt128(reinterpret(UInt64, b)) >= u)
end
# division and remainder, signed and unsigned (compiler-rt's __divti3, __modti3, __udivti3, __umodti3
# in the runtime), a divisor of one half and of both, negative operands, literal divisors, Julia's
# DivideError at 0 and at typemin ÷ -1, and rem(typemin, -1), which Julia answers 0
function divmod(a::Int64, d::Int64)
    local x = BIG * Int128(a) + NEARTOP
    local y = d == 7 ? BIG + Int128(3) : d == 8 ? typemin(Int128) : Int128(d)
    local u = reinterpret(UInt128, x)
    local v = reinterpret(UInt128, y * Int128(d))
    return halves(div(x, y)) + 3 * halves(rem(x, y)) + 5 * uhalves(div(u, v | UInt128(1))) + 7 * uhalves(rem(u, v | UInt128(1))) +
        11 * halves(div(x, Int128(10))) + 13 * uhalves(rem(u, UInt128(1) << 70)) +
        17 * halves(rem(d == 9 ? typemin(Int128) : x, d == 9 ? Int128(-1) : y)) +
        19 * halves(div(d == 9 ? typemin(Int128) : x, d == 9 ? Int128(-1) : y))
end
# the bit counts, the byte swap, flipsign (by a value and by literals of either sign) and the float
# conversions Base writes over them, each against native
function bits(a::Int64, n::Int64)
    local x = (BIG * Int128(a)) >> (n % UInt8) + Int128(n)
    local u = reinterpret(UInt128, x)
    return Int64(leading_zeros(x)) + 3 * Int64(trailing_zeros(x)) + 5 * Int64(count_ones(u)) + 7 * halves(bswap(x)) +
        11 * halves(flipsign(x, Int128(n))) + 13 * Int64(reinterpret(UInt64, Float64(x)) % Int64) +
        17 * Int64(reinterpret(UInt64, Float64(u)) % Int64) + 19 * Int64(reinterpret(UInt32, Float32(x))) +
        23 * halves(unsafe_trunc(Int128, Float64(n) * 1.0e20)) +
        29 * halves(Core.Intrinsics.flipsign_int(x, Int128(-3))) + 31 * halves(Core.Intrinsics.flipsign_int(x, Int128(5)))
end
end

@testset "LegalizeIntegerTypes.cpp: a 128-bit integer is two i64 halves, its conversions, equality, arithmetic, compares, product, shifts, division and bit counts" begin
    local bytes = W.compile(Int128Cases.wide, (Int64,); optimize = false)
    queue_native!("wide", bytes, Int128Cases.wide, [(n,) for n in Int64[0, 5, -3, 300, typemax(Int64), typemin(Int64)]])
    local abytes = W.compile(Int128Cases.arith, (Int64, Int64); optimize = false)
    local edge = Int64[0, 1, 2, 3, -1, -3, typemax(Int64), typemin(Int64)]
    queue_native!("arith", abytes, Int128Cases.arith, [(a, b) for a in edge for b in edge])
    local mbytes = W.compile(Int128Cases.mulshift, (Int64, Int64); optimize = false)
    local amounts = Int64[0, 1, 31, 63, 64, 65, 100, 127, 128, 129, 200, -1, -64]
    queue_native!("mulshift", mbytes, Int128Cases.mulshift, [(a, n) for a in Int64[0, 1, -1, 3, typemax(Int64), typemin(Int64)] for n in amounts])
    local lbytes = W.compile(Int128Cases.literals, (Int64, Int64); optimize = false)
    queue_native!("literals", lbytes, Int128Cases.literals, [(a, b) for a in edge for b in edge])
    local dbytes = W.compile(Int128Cases.divmod, (Int64, Int64); optimize = false)
    local dcases = [(a, d) for a in Int64[0, 1, -1, 5, typemax(Int64), typemin(Int64)] for d in Int64[1, -1, 3, -10, 7, 8, typemax(Int64), 0, 9]]
    @test count(c -> WTRunner.native_answer(Int128Cases.divmod, c) == WTRunner.Throws(DivideError), dcases) >= 7
    append!(NATIVE_RUNS, [WTRunner.RunCase("divmod$c", dbytes, c, WTRunner.native_answer(Int128Cases.divmod, c)) for c in dcases])
    local bbytes = W.compile(Int128Cases.bits, (Int64, Int64); optimize = false)
    queue_native!("bits", bbytes, Int128Cases.bits, [(a, n) for a in Int64[0, 1, -1, 7, typemax(Int64), typemin(Int64)] for n in Int64[0, 1, 63, 64, 100, 127, -5]])
    # SimplifySetCC's fold of two constants, which no compile reaches (src/llvm/target_lowering.jl says
    # why), called on halves and on 128-bit pairs directly: two constants answer Julia's own compare of
    # them, signed or unsigned by the condition (ICmpInst::compare), and a constant left of a value
    # moves right under the swapped condition (getSetCCSwappedOperands), which the int128 arm's compare
    # of a literal and a value reaches (test/smoke_corpus.jl int128_limbs setcc_literal_left)
    local S = W.LLVM.simplify_set_cc
    local v = IR.Local(0, IR.NumType_i64)
    local halves64 = Int64[0, 1, -1, 3, typemax(Int64), typemin(Int64)]
    local ops = (:SETEQ => (==), :SETNE => (!=), :SETLT => (<), :SETLE => (<=), :SETGT => (>), :SETGE => (>=))
    for c0 in halves64, c1 in halves64
        for (cc, op) in ops
            @test S(c0, c1, cc) === op(c0, c1)
            local ucc = cc === :SETEQ || cc === :SETNE ? cc : Symbol(:SETU, String(cc)[4:end])
            @test S(c0, c1, ucc) === op(reinterpret(UInt64, c0), reinterpret(UInt64, c1))
        end
    end
    for (cc, swapped) in (:SETEQ => :SETEQ, :SETNE => :SETNE, :SETLT => :SETGT, :SETGT => :SETLT, :SETLE => :SETGE,
                          :SETGE => :SETLE, :SETULT => :SETUGT, :SETUGT => :SETULT, :SETULE => :SETUGE, :SETUGE => :SETULE)
        @test S(Int64(3), v, cc) === (v, Int64(3), swapped)
        @test S((Int64(3), Int64(1)), (v, v), cc) === ((v, v), (Int64(3), Int64(1)), swapped)
    end
    # a 128-bit pair is a constant where both halves are: its compare is Julia's of the Int128s, and
    # its bound rewrites are over 128 bits (x <= C as x < C+1, x >= typemin true)
    local halves128 = Int128[0, 1, -1, Int128(1) << 64, typemax(Int128), typemin(Int128), -(Int128(1) << 64)]
    local pair(c::Int128) = W.LLVM.expand_int_res_constant(c)
    for c0 in halves128, c1 in halves128
        for (cc, op) in ops
            @test S(pair(c0), pair(c1), cc) === op(c0, c1)
            local ucc = cc === :SETEQ || cc === :SETNE ? cc : Symbol(:SETU, String(cc)[4:end])
            @test S(pair(c0), pair(c1), ucc) === op(reinterpret(UInt128, c0), reinterpret(UInt128, c1))
        end
    end
    @test S((v, v), pair(Int128(5) << 64), :SETLE) === ((v, v), pair((Int128(5) << 64) + 1), :SETLT)
    @test S((v, v), pair(typemin(Int128)), :SETGE) === true
    @test S((v, v), pair(Int128(1)), :SETULT) === ((v, v), pair(Int128(0)), :SETEQ)
    @test S((v, v), pair(Int128(-1)), :SETULE) === true
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTRunner.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end

end
