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

intr_translator_of(f, argtypes) = DI.Translator(WI.check_subset(f, argtypes, "intrinsics"),
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
    # no Julia method is one of dart's library members: the lookups are empty, a triple names none
    @test isempty(DI.MemberIntrinsic__lookup[]) && isempty(DI.StaticIntrinsic__lookup[])
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
    # _svec_ref has no arm: its BoundsError waits for throwing
    @test DI.generate_static_intrinsic(ii, WI.NirCall(WI.NirValue[lit(Core._svec_ref), body.stmts[k].args[2], lit(1)])) === nothing
end
