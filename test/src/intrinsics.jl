# dart2wasm's intrinsics.dart, the remainder ported (src/intrinsics.jl, dev/MARCH.md 1.D): the literal
# extractors, the lane index, the lookups and the call-site intrinsics, Julia's operations the answer.
using Test
using WasmTarget

const DI = WasmTarget.Dart2Wasm
const WI = WasmTarget
const IRI = WI.WasmBuilder.IR

module IntrinsicCases
eq64(x::Int64) = x + 1
eqf(x::Float64) = x * 2.0
end

intr_translator_of(f, argtypes) = DI.Translator(WasmTarget.build_nir(WI.check_subset(f, argtypes, "intrinsics"), "test"),
    DI.build_module_output_data(DI.DefaultModuleStrategy(DI.WasmCompilerOptions_default_options())), DI.TranslatorOptions())
function intr_codegen_of(f, argtypes, ins, outs)
    local t = intr_translator_of(f, argtypes)
    local mi = only(nb.ci.def for nb in t.component if nb.ci.def.def.name === nameof(f))
    return DI.get_inlinable_member_code_generator(t, IRI.FunctionType(IRI.ValueType[ins...], IRI.ValueType[outs...]), mi)
end
intr_rejection(f) = try; f(); nothing; catch e; e isa WI.RejectionError ? e : rethrow(); end

# the code generator of `f` ready to emit, as `generate` leaves it before the body: translate()'s
# steps before code, its builder a function of `f`'s parameter types and the results `outs`, its
# parameters set up
function intr_ready_codegen_of(f, argtypes, outs)
    local B = WI.WasmBuilder
    local t = intr_translator_of(f, argtypes)
    DI._init_modules(t, nothing)
    collect(DI.ClassInfoCollector(t))
    t.constants[] = DI.Constants(t)
    local mi = only(nb.ci.def for nb in t.component if nb.ci.def.def.name === nameof(f))
    local mb = DI.main_module(t)
    local fb = B.define(mb.functions[], B.define_function(mb.types[], IRI.ValueType[DI.translate_type(t, T) for T in argtypes], IRI.ValueType[outs...]), "f")
    local g = DI.get_inlinable_member_code_generator(t, fb.type, mi)
    g.b[] = B.body(fb)
    g.param_locals[] = B.locals(fb)
    g.return_label[] = nothing
    DI.setup_parameters_for_normal_entry(g, g.member)
    return g
end

# the instructions `thunk` emits into the builder of `g`, by name
function intr_emitted_by(thunk, g)
    local n0 = length(g.b[]._instructions)
    thunk()
    return String[WI.WasmBuilder.name(i) for i in g.b[]._instructions[n0+1:end]]
end

@testset "intrinsics.dart: literals, lanes and lookups" begin
    local lit(v) = WI.NirConst(Core.Const(v))
    # an integer literal is dart's int, Julia's Int64; a float literal Float64; anything else none
    @test DI.extract_int_value(lit(3)) == 3 && DI.extract_int_value(lit(Int32(3))) === nothing && DI.extract_int_value(WI.NirSSA(1)) === nothing
    @test DI._extract_double_value(lit(2.5)) == 2.5 && DI._extract_double_value(lit(2.5f0)) === nothing
    @test DI._extract_lane_indices(lit((1, 2, 3))) == [1, 2, 3] && DI._extract_lane_indices(lit((1, 2.0))) === nothing
    @test DI._extract_lane_indices(lit(1)) === nothing
    # the Julia methods that are dart library members are the runtime's ports: Runtime.Error__throw is
    # dart:core's Error._throw, the errorThrow intrinsic, filed under it; no method is a dart:_wasm member
    @test DI.MemberIntrinsic__lookup[] == Dict("dart:core" => Dict("Error" => Dict("_throw" => DI.MemberIntrinsic_errorThrow))) &&
          isempty(DI.StaticIntrinsic__lookup[])
    local throw_mi = Core.Compiler.specialize_method(only(methods(WI.Runtime.Error__throw)), Tuple{typeof(WI.Runtime.Error__throw),Exception}, Core.svec())
    @test DI.MemberIntrinsic_from_procedure(throw_mi) === DI.MemberIntrinsic_errorThrow
    local other_mi = Core.Compiler.specialize_method(only(methods(WI.Runtime.Error__throw_with_current_stack_trace)),
                                                     Tuple{typeof(WI.Runtime.Error__throw_with_current_stack_trace),Exception}, Core.svec())
    @test DI.MemberIntrinsic_from_procedure(other_mi) === nothing
    local e = intr_rejection(() -> DI.MemberIntrinsic("dart:core", "Object", "=="))
    @test e.rejection isa WI.Internal
    local g = intr_codegen_of(IntrinsicCases.eq64, (Int64,), [IRI.NumType_i64], [IRI.NumType_i64])
    local ii = g.intrinsifier[]
    # a lane index: a literal within the lanes; another, a located rejection
    local st = WI.NirNothing()
    @test DI._get_simd_lane_index(ii, lit(1), 4, st) == 1
    for bad in (lit(4), lit(-1), WI.NirSSA(1))
        @test intr_rejection(() -> DI._get_simd_lane_index(ii, bad, 4, st)).rejection isa WI.Internal
    end
    # the folded unary operators are Julia's intrinsics, rounding a float to its own type
    @test haskey(DI.Intrinsifier__inline_unary_operator_map[][IRI.NumType_i64], Core.Intrinsics.neg_int)
    @test Set(keys(DI.Intrinsifier__inline_unary_operator_map[][IRI.NumType_f64])) ==
          Set([Core.Intrinsics.neg_float, Core.Intrinsics.floor_llvm, Core.Intrinsics.ceil_llvm, Core.Intrinsics.trunc_llvm])
    @test DI.Intrinsifier__unary_result_map[][Core.Intrinsics.floor_llvm] == IRI.NumType_f64
    @test DI.types(ii) === DI.translator(ii).types[]
end

@testset "intrinsics.dart: the call-site intrinsics over Julia's calls" begin
    local lit(v) = WI.NirConst(Core.Const(v))
    local g = intr_codegen_of(IntrinsicCases.eq64, (Int64,), [IRI.NumType_i64], [IRI.NumType_i64])
    local ii = g.intrinsifier[]
    local x = WI.NirArgument(2)
    local mi(f, T) = Core.Compiler.specialize_method(Base._which(Base.signature_type(f, T)))
    local inv(m, args...) = WI.NirInvoke(m, WI.NirValue[lit(m.def.name === :(==) ? (==) : (+)), args...])
    # Base's == on two Int64s is their bit equality, which i64.eq computes: the operands, then i64.eq;
    # Julia's own answer stands beside it
    @test (typemin(Int64) == typemin(Int64)) && !(1 == 2) && !(NaN == NaN) && (0.0 == -0.0)
    local r = intr_ready_codegen_of(IntrinsicCases.eq64, (Int64,), [IRI.NumType_i64])
    @test intr_emitted_by(() -> DI.generate_equals_intrinsic(r.intrinsifier[], inv(mi(==, (Int64, Int64)), x, lit(3))), r) ==
          ["local.get", "i64.const 3", "i64.eq"]
    # two types, or another method, is no equality intrinsic
    @test DI.generate_equals_intrinsic(ii, inv(mi(==, (Int64, Float64)), x, lit(3.0))) === nothing
    @test DI.generate_equals_intrinsic(ii, inv(mi(+, (Int64, Int64)), x, lit(3))) === nothing
    # a resolved call, a field read, a global read and a function value's call are no intrinsics
    @test DI.generate_instance_intrinsic(ii, inv(mi(+, (Int64, Int64)), x, lit(3))) === nothing
    @test DI.generate_instance_getter_intrinsic(ii, WI.NirCall(WI.NirValue[lit(getfield), x, lit(:a)])) === nothing
    @test DI.generate_static_getter_intrinsic(ii, WI.NirGlobalRead(GlobalRef(Base, :pi))) === nothing
    @test DI.generate_function_call_intrinsic(ii, inv(mi(+, (Int64, Int64)), x, lit(3))) === nothing
    # dart:_wasm's typed array and memory intrinsics, which no Julia call is: located rejections
    @test intr_rejection(() -> DI.read_int_array(ii, inv(mi(+, (Int64, Int64)), x, lit(3)); unsigned = true)).rejection isa WI.Internal
end

module SvecLenCases
nparams(T::DataType, n::Int) = Core._svec_len(T.parameters) + n
end

@testset "intrinsics.dart: a SimpleVector's length, its wasm array's" begin
    local lit(v) = WI.NirConst(Core.Const(v))
    local t = intr_translator_of(SvecLenCases.nparams, (DataType, Int))
    DI._init_modules(t, nothing)
    collect(DI.ClassInfoCollector(t))
    local mi = only(nb.ci.def for nb in t.component if nb.ci.def.def.name === :nparams)
    local g = DI.get_inlinable_member_code_generator(t, IRI.FunctionType(IRI.ValueType[DI.translate_type(t, DataType), IRI.NumType_i64], IRI.ValueType[IRI.NumType_i64]), mi)
    local ii = g.intrinsifier[]
    # Julia's answer the arm computes: the parameters' count
    @test Core._svec_len(Tuple{Int,Float64,Bool}.parameters) == 3
    # the NIR's statement: the arm takes it, its operand the field read before it (translated first,
    # its local set), then the vector's array and its length, widened to Int
    local body = only(nb for nb in t.component if nb.ci.def === mi)
    local k = findfirst(st -> st isa WI.NirCall && WI.nir_callee(st) === Core._svec_len, body.stmts)
    @test k !== nothing
    local r = intr_ready_codegen_of(SvecLenCases.nparams, (DataType, Int), [IRI.NumType_i64])
    for j in 1:k-1
        DI.translate_statement(r, r.body.stmts[j], j in r.used ? WI.NirSSA(j) : nothing)
    end
    @test intr_emitted_by(() -> DI.generate_static_intrinsic(r.intrinsifier[], r.body.stmts[k]), r) ==
          ["local.get", "struct.get", "array.len", "i64.extend_i32_u"]
end

isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))

module DivCases
# each checked division at each width, by `k`: one module per signedness
sops(a::Int64, b::Int64, k::Int64) = k == 0 ? div(a, b) : k == 1 ? rem(a, b) :
                                     k == 2 ? Int64(div(a % Int32, b % Int32)) : Int64(div(a % Int8, b % Int8))
uops(a::UInt64, b::UInt64, k::Int64) = k == 0 ? div(a, b) : k == 1 ? rem(a, b) :
                                       k == 2 ? UInt64(div(a % UInt32, b % UInt32)) : UInt64(rem(a % UInt16, b % UInt16))
end

@testset "intrinsics.cpp: a checked division raises DivideError through the runtime's thrower, as Julia's does" begin
    # Julia's checked_sdiv_int and kin raise DivideError at a zero divisor, and checked_sdiv_int at
    # typemin ÷ -1 too, its type's own typemin for a 32- or 8-bit operand: the module raises a wasm
    # exception where native Julia throws (Error._throw's tag), never a trap, and answers as native
    # elsewhere
    local C = DivCases
    local s(a, b, k) = (Int64(a), Int64(b), Int64(k))
    local u(a, b, k) = (UInt64(a), UInt64(b), Int64(k))
    local cases = WTRunner.RunCase[]
    for (f, argsets) in ((C.sops, [s(7, 2, 0), s(7, 0, 0), (typemin(Int64), Int64(-1), Int64(0)), s(-7, 2, 0),
                                   s(7, 2, 1), s(7, 0, 1), (typemin(Int64), Int64(-1), Int64(1)),
                                   s(typemin(Int32), -1, 2), s(9, -2, 2), s(9, 0, 2),
                                   s(-128, -1, 3), s(5, 0, 3), s(-7, 2, 3), s(200, 3, 3)]),
                         (C.uops, [u(7, 2, 0), u(7, 0, 0), u(typemax(UInt64), 3, 0), u(7, 2, 1), u(7, 0, 1),
                                   u(typemax(UInt32), 3, 2), u(7, 0, 2), u(65535, 7, 3), u(70000, 0, 3), u(9, 65540, 3)]))
        local bytes = WI.compile(f, map(typeof, first(argsets)))
        append!(cases, [WTRunner.RunCase("$(nameof(f))$(a)", bytes, a, WTRunner.native_answer(f, a)) for a in argsets])
    end
    @test count(c -> c.native isa WTRunner.Throws, cases) == 11
    for r in WTRunner.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

module StringDataCases
using WasmTarget: wasm_string_length, wasm_string_alloc, wasm_string_codeunit, wasm_string_copy!
# a String's length and a fresh String's (src/julia/wasm_array.jl), === on two Strings, a code unit,
# and a code unit of two Strings copied into a fresh one, by `k`
function strops(k::Int64, b::Bool)
    k == 0 && return wasm_string_length(b ? "héllo" : "日本")
    k == 1 && return Int64((b ? "abc" : "abd") === "abc")
    k == 2 && return Int64((b ? "abc" : "abcd") === "abc")
    k == 3 && return wasm_string_length(wasm_string_alloc(b ? 7 : 0))
    k == 4 && return Int64(wasm_string_codeunit("héllo", b ? 2 : 0))
    local x = b ? "hé" : "x"
    local y = "llo"
    local s = wasm_string_alloc(wasm_string_length(x) + wasm_string_length(y))
    wasm_string_copy!(s, 0, x, 0, wasm_string_length(x))
    wasm_string_copy!(s, wasm_string_length(x), y, 0, wasm_string_length(y))
    return Int64(wasm_string_codeunit(s, 3))
end
end

@testset "intrinsics.dart: a String's data operations and Julia's egal on two Strings, against native" begin
    # wasm_string_length is `struct.get _data; array.len`, wasm_string_alloc a String struct over a
    # fresh array (WasmArrayRef.length, the WasmArray constructor); === compares lengths, then bytes,
    # as jl_egal does: non-ASCII text's bytes, equal and unequal contents of equal and unequal lengths
    local args = [(Int64(k), b) for k in 0:5 for b in (true, false)]
    local bytes = WI.compile(StringDataCases.strops, (Int64, Bool))
    for r in WTRunner.run_cases([WTRunner.RunCase("strops$a", bytes, a, StringDataCases.strops(a...)) for a in args])
        @test r.ok || (@info r.label r.why; false)
    end    # each data operation is dart's external member: the closed world records its call and never
    # collects its body (Julia's native evaluation through pointers); a call the intrinsifier declines
    # (here, the body asked for directly) finds none and rejects, located
    local t = intr_translator_of(StringDataCases.strops, (Int64, Bool))
    local cu = Core.Compiler.specialize_method(only(methods(WI.wasm_string_codeunit)), Tuple{typeof(WI.wasm_string_codeunit),String,Int}, Core.svec())
    @test WI.nir_intrinsified(cu) && !any(nb -> nb.ci.def === cu, t.component)
    local r = intr_rejection(() -> WI.nir_body_of(t.component, cu))
    @test r.rejection isa WI.Internal && occursin("a call it did not lower", r.rejection.site)
end

module SvecRefCases
const ELEMENTS = Core.svec(Int64(7), "x", Int64(9))
# a SimpleVector's element by its index from 1, read by its class
sref(i::Int64) = (x = ELEMENTS[i]; x isa Int64 ? Int64(1) : x isa String ? Int64(2) : Int64(3))
end

@testset "intrinsics.dart: a SimpleVector's element, Julia's bounds check raising BoundsError" begin
    # _svec_ref reads the data array at i - 1 behind Julia's check: an index outside 1..length
    # raises BoundsError through the runtime's thrower, a wasm exception, never a trap
    local args = [(Int64(k),) for k in (-1, 0, 1, 2, 3, 4)]
    local bytes = WI.compile(SvecRefCases.sref, (Int64,))
    local cases = [WTRunner.RunCase("sref$a", bytes, a, WTRunner.native_answer(SvecRefCases.sref, a)) for a in args]
    @test count(c -> c.native isa WTRunner.Throws, cases) == 3
    for r in WTRunner.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

module SvecNewCases
# a SimpleVector made at run time of an Int, a String and an Int, its element by index; its length
made(i::Int64, k::Int64) = (v = Core.svec(i, "x", i + 1); x = v[k]; x isa Int64 ? Int64(1) : x isa String ? Int64(2) : Int64(3))
made_len(b::Bool) = Core._svec_len(b ? Core.svec("a", "b", "c") : Core.svec("z"))
end

@testset "intrinsics.dart: a SimpleVector made at run time, WasmArray.literal's array.new_fixed in its struct" begin
    # Core.svec builds its data array from its operands, each boxed to the element type, as dart's
    # WasmArray.literal does, under the SimpleVector's header; read back by index and by length, and
    # past its length raising BoundsError
    local native(f, a) = try; f(a...); catch e; WTRunner.Throws(typeof(e)); end
    local cases = WTRunner.RunCase[]
    for (f, argsets) in ((SvecNewCases.made, [(Int64(5), Int64(k)) for k in 0:4]), (SvecNewCases.made_len, [(true,), (false,)]))
        local bytes = WI.compile(f, map(typeof, first(argsets)))
        append!(cases, [WTRunner.RunCase("$(nameof(f))$(a)", bytes, a, native(f, a)) for a in argsets])
    end
    @test count(c -> c.native isa WTRunner.Throws, cases) == 2
    for r in WTRunner.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end
