# dart2wasm's code_generator.dart and intrinsics.dart, ported (src/code_generator.jl,
# src/intrinsics.jl, dev/MARCH.md 1.D): the code generator of a body built over the closed world's
# NIR, its variables and static types Julia's, and Julia's intrinsics matched to the instructions
# Julia's codegen answers with. Until InstructionsBuilder lands (1.B), emitting is a located rejection.
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm
const W = WasmTarget
const IR = W.WasmBuilder.IR

module CodegenCases
f_add(x::Int32) = x + Int32(1)
f_poly(x::Float64, y::Float64) = x * y - 1.0
f_narrow(x::Int8) = x + Int8(1)
f_twice(x::Int64) = f_add(x % Int32) === Int32(3)
abstract type Shape end
struct Circle <: Shape; r::Float64; end
struct Square <: Shape; s::Float64; end
shapes(n::Int) = n > 0 ? Circle(Float64(n)) : Square(2.0)
loop(n::Int) = (s = 0; for i in 1:n; s += i; end; s)
end

# the translator of the closed world of `f` at `argtypes`, one main module
translator_of(f, argtypes) = D.Translator(W.check_subset(f, argtypes, "code_generator"),
    D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())

# the code generator of the entry body of `f` at `argtypes`, its wasm signature `ins -> outs`
function codegen_of(f, argtypes, ins, outs)
    local t = translator_of(f, argtypes)
    local mi = only(nb.ci.def for nb in t.component if nb.ci.def.def.name === nameof(f))
    return D.get_inlinable_member_code_generator(t, IR.FunctionType(IR.ValueType[ins...], IR.ValueType[outs...]), mi)
end

# the rejection `f()` raises, or nothing
rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e : rethrow(); end

@testset "code_generator.dart: a body's code generator over the NIR" begin
    local g = codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    @test g isa D.SynchronousProcedureCodeGenerator && g.member === g.reference === g.enclosing_member
    # the body is the CodeInstance Julia inferred for the method: `%1 = add_int(_2, 1)`, `return %1`
    @test g.body.ci.def === g.member && length(g.body.stmts) == 2
    @test g.body.stmts[1] isa W.NirCall && g.body.stmts[2] isa W.NirReturn
    # the used statements: %1, which the return reads; the return's own value is no variable
    @test g.used == BitSet([1])
    @test D.outputs(g) == IR.ValueType[IR.NumType_i32] && D.options(g) === g.translator.options
    # each operand's static type is Julia's: the statement's inferred type, the argument's
    # specialization, the literal's own type (Int32(1), not Int)
    local call = g.body.stmts[1]::W.NirCall
    @test D.dart_type_of(g, call.args[2]) === Int32 && D.dart_type_of(g, call.args[3]) === Int32
    @test D.dart_type_of(g, W.NirSSA(1)) === Int32 && D.dart_type_of(g, call.args[1]) === typeof(Core.Intrinsics.add_int)
    @test D.translate_type(g, Int32) == IR.NumType_i32
    # the intrinsifier is built on its first read, over the generator itself, as dart's late field
    @test D.translator(g.intrinsifier[]) === g.translator && g.intrinsifier[].code_gen === g
    @test D.type_of_exp(g.intrinsifier[], call.args[2]) == IR.NumType_i32
    # the used call declares its variable, typed by the translator's local-variable type, as a local
    # of the builder, which `generate` gives: before it, the late builder rejects, located
    local e = rejection(() -> D.translate_statement(g, g.body.stmts[1], W.NirSSA(1)))
    @test e.rejection isa W.Unported && occursin("AstCodeGenerator.b", e.rejection.anchor)
    # nothing is emitted before `generate` gives the builder: the late builder rejects, located
    @test occursin("AstCodeGenerator.b", rejection(() -> D.add_local(g, IR.NumType_i32)).rejection.anchor)
    # a Julia method has one entry: the multiple-entry paths are WasmTarget's own defect if reached
    @test rejection(() -> D._make_multiple_entry_point(g, true)).rejection isa W.Internal
    @test rejection(() -> D._make_multiple_entry_point_shared_body(g)).rejection isa W.Internal
    # a function's callee is a singleton: no `this` (dart's static member)
    @test g.this_local === nothing && rejection(() -> D.visit_this(g, IR.NumType_i32)).rejection isa W.Internal
    # the multi-function body: f_add inlined into f_twice, its statements read by SSA
    local h = codegen_of(CodegenCases.f_twice, (Int64,), [IR.NumType_i64], [IR.NumType_i32])
    @test h.used == BitSet([1, 2, 3])
end

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
    # Int32's add_int has its arm: it translates its operands, so it reads the argument's local, which
    # no parameter setup has made here
    local e = rejection(() -> D.generate_static_intrinsic(g.intrinsifier[], g.body.stmts[1]::W.NirCall))
    @test e.rejection isa W.Internal && occursin("undefined variable", e.rejection.site)
    # an 8-bit add wraps at 8 bits in Julia, at 32 in an i32: no arm, and the call rejects, located
    local n = codegen_of(CodegenCases.f_narrow, (Int8,), [IR.NumType_i32], [IR.NumType_i32])
    local ncall = n.body.stmts[findfirst(s -> s isa W.NirCall, n.body.stmts)]::W.NirCall
    # an 8-bit add has its arm now (the operand's form put back after the i32 add): it reaches the
    # argument's local, which no parameter setup has made here
    local e2 = rejection(() -> D.generate_static_intrinsic(n.intrinsifier[], ncall))
    @test e2.rejection isa W.Internal && occursin("undefined variable", e2.rejection.site)
end

@testset "code_generator.dart: translateStatement over the NIR" begin
    local t = translator_of(CodegenCases.shapes, (Int,))
    local t2 = translator_of(CodegenCases.loop, (Int,))
    # the class table an allocation's type reads, as translate fills it before any code
    for tt in (t, t2)
        D._init_modules(tt, nothing)
        collect(D.ClassInfoCollector(tt))
    end
    local gens = [D.SynchronousProcedureCodeGenerator(Val(:_), tt, IR.FunctionType(IR.ValueType[], IR.ValueType[]), b.ci.def, b)
                  for tt in (t, t2) for b in tt.component]
    local forms = Set(W.stmt_form(st) for g in gens for st in g.body.stmts)
    @test "return" in forms && "gotoifnot" in forms && "new" in forms
    for g in gens, (k, st) in enumerate(g.body.stmts)
        local r = rejection(() -> D.translate_statement(g, st, W.NirSSA(k)))
        if st isa W.NirReturn
            # the return translates its value at the return type, the translator's outputOrVoid, which
            # answers; what stops it is past the translator
            @test r isa W.RejectionError && !occursin("outputOrVoid", string(r.rejection))
        elseif st isa W.NirNothing
            @test r === nothing
        elseif st isa Union{W.NirCall, W.NirInvoke, W.NirNew, W.NirGlobalRead}
            # a used value is a local declared with its initializer; an unused one an expression statement
            @test r.rejection isa W.Unported && occursin("AstCodeGenerator.b", r.rejection.anchor)
            # the unused one is translated at the void marker: its expression's own visitor, which
            # stops at the first piece not yet given here (a constant, a parameter, an allocation)
            local r2 = rejection(() -> D.translate_statement(g, st, nothing))
            @test r2 isa W.RejectionError && !occursin("voidMarker", string(r2.rejection))
        elseif st isa Union{W.NirForeignCall, W.NirCFunction}
            @test r.rejection isa W.Unquarantined && occursin("1.F", r.rejection.row)
        elseif st isa Union{W.NirGoto, W.NirGotoIfNot, W.NirPhi}
            # a jump and a merge are the stackifier's (visit_block), never a statement of their own
            @test r.rejection isa W.Internal && occursin("visit_block", r.rejection.site)
        else
            # every Julia-only form rejects in its own arm, naming the stackifier's row
            @test r.rejection isa W.Unquarantined && occursin("1.D", r.rejection.row)
        end
    end
    # forms no program above holds, built directly
    @test rejection(() -> D.translate_statement(gens[1], W.NirGoto(1), nothing)).rejection isa W.Internal
    # Julia's unreachable is a trap, emitted into the builder `generate` gives
    @test occursin("AstCodeGenerator.b", rejection(() -> D.translate_statement(gens[1], W.NirUnreachable(), nothing)).rejection.anchor)
end

@testset "intrinsics.dart: Julia's identity, ifelse, conversions and shifts" begin
    local I = Core.Intrinsics
    local g = codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    local p = codegen_of(CodegenCases.f_poly, (Float64, Float64), [IR.NumType_f64, IR.NumType_f64], [IR.NumType_f64])
    local n = codegen_of(CodegenCases.f_narrow, (Int8,), [IR.NumType_i32], [IR.NumType_i32])
    local lit(v) = W.NirConst(Core.Const(v))
    local x = W.NirArgument(2)
    local call(f, args...) = W.NirCall(W.NirValue[lit(f), args...])
    # an arm found translates its operands first, reading the argument's local, which no parameter
    # setup has made here; no arm is nothing, the call then rejecting where it stands
    local found(gen, c) = (r = rejection(() -> D.generate_static_intrinsic(gen.intrinsifier[], c));
                           r !== nothing && r.rejection isa W.Internal && occursin("undefined variable", r.rejection.site))
    local absent(gen, c) = D.generate_static_intrinsic(gen.intrinsifier[], c) === nothing
    # Julia's === compares bits, so a float is compared as its bits' integer: native Julia's answers
    @test (NaN === NaN) && !(0.0 === -0.0) && reinterpret(Int64, NaN) == reinterpret(Int64, NaN)
    @test found(g, call(Core.:(===), x, lit(Int32(3)))) && found(p, call(Core.:(===), x, W.NirArgument(3)))
    @test absent(g, call(Core.:(===), x, lit(Int64(3))))   # different types: no value comparison
    @test found(g, call(Core.ifelse, lit(true), x, x)) && absent(g, call(Core.ifelse, lit(true), x, lit(1.0)))
    # conversions between full-width types; a narrow one has no arm
    @test found(g, call(I.sext_int, lit(Int64), x)) && found(g, call(I.zext_int, lit(UInt64), x))
    @test found(g, call(I.sitofp, lit(Float64), x)) && found(g, call(I.bitcast, lit(Float32), x)) && found(g, call(I.bitcast, lit(UInt32), x))
    @test found(p, call(I.fptosi, lit(Int64), x)) && found(p, call(I.fptrunc, lit(Float32), x)) && found(p, call(I.bitcast, lit(Int64), x))
    @test found(g, call(I.trunc_int, lit(Int8), x)) && found(n, call(I.sext_int, lit(Int32), x)) && absent(g, call(I.fpext, lit(Float64), x))
    # Julia's shifts saturate, the count unsigned: native Julia's answers, which the select ports
    @test I.shl_int(Int32(1), UInt64(40)) == 0 && I.lshr_int(Int32(-1), UInt8(32)) == 0
    @test I.ashr_int(Int32(-8), UInt64(100)) == -1 && I.ashr_int(Int32(8), UInt64(100)) == 0 && I.shl_int(Int64(3), Int32(-1)) == 0
    # a shift's arm takes a local for the count first, from the builder `generate` has not given yet
    local e = rejection(() -> D.generate_static_intrinsic(g.intrinsifier[], call(I.shl_int, x, lit(Int64(3)))))
    @test e.rejection isa W.Unported && occursin("AstCodeGenerator.b", e.rejection.anchor)
    # an 8-bit shift has its arm: its count's local comes first, from the builder not given here
    @test occursin("AstCodeGenerator.b", rejection(() -> D.generate_static_intrinsic(n.intrinsifier[], call(I.shl_int, x, lit(Int64(3))))).rejection.anchor)
end

module FieldGenCases
struct P; a::Int32; b::Float64; end
struct N; x::Int8; y::UInt8; end
getb(p::P) = p.b
mk(x::Int32) = P(x, 2.0)
mkn(x::Int8) = N(x, 0x01)
end

@testset "code_generator.dart: a field read and an allocation" begin
    local t = translator_of(FieldGenCases.getb, (FieldGenCases.P,))
    local body = only(t.component)
    local g = D.SynchronousProcedureCodeGenerator(Val(:_), t, IR.FunctionType(IR.ValueType[], IR.ValueType[]), body.ci.def, body)
    # getfield(p, :b) is the field read, routed to visitInstanceGet; it reaches the class table, which
    # no collect has filled here: a located rejection, the field found
    local gf = body.stmts[findfirst(s -> s isa W.NirCall, body.stmts)]::W.NirCall
    @test W.nir_callee(gf) === Core.getfield
    local e = rejection(() -> D.translate_expression(g, gf, IR.NumType_f64))
    @test e.rejection isa W.Internal && occursin("_directGet: no class info", e.rejection.site)
    # a field named at run time, or a receiver Julia leaves abstract, rejects before any class lookup
    local dyn = W.NirCall(W.NirValue[gf.args[1], gf.args[2], W.NirArgument(2)])
    @test rejection(() -> D.visit_instance_get(g, dyn, IR.NumType_f64)).rejection isa W.Unquarantined
    # Expr(:new): the allocation, its class the type operand's value
    local t2 = translator_of(FieldGenCases.mk, (Int32,))
    local b2 = only(t2.component)
    local g2 = D.SynchronousProcedureCodeGenerator(Val(:_), t2, IR.FunctionType(IR.ValueType[], IR.ValueType[]), b2.ci.def, b2)
    local nw = b2.stmts[findfirst(s -> s isa W.NirNew, b2.stmts)]::W.NirNew
    @test D.generate_constructor_intrinsic(g2.intrinsifier[], nw) === nothing
    local e2 = rejection(() -> D.translate_expression(g2, nw, IR.NumType_i32))
    @test e2.rejection isa W.Internal && occursin("no class info for $(FieldGenCases.P)", e2.rejection.site)
end

module SetGenCases
mutable struct M; a::Int32; const c::Int32; end
seta(m::M, v::Int32) = (m.a = v; nothing)
end

@testset "code_generator.dart: a field write" begin
    local t = translator_of(SetGenCases.seta, (SetGenCases.M, Int32))
    local body = only(t.component)
    local g = D.SynchronousProcedureCodeGenerator(Val(:_), t, IR.FunctionType(IR.ValueType[], IR.ValueType[]), body.ci.def, body)
    local sf = body.stmts[findfirst(s -> s isa W.NirCall && W.nir_callee(s) === Core.setfield!, body.stmts)]::W.NirCall
    # setfield! routes to visitInstanceSet, which reaches the class table no collect filled here
    local e = rejection(() -> D.translate_expression(g, sf, D.void_marker(g)))
    @test e.rejection isa W.Internal && occursin("_directSet: no class info", e.rejection.site)
    # a const field does not change in Julia: a located rejection before any lookup
    local sc = W.NirCall(W.NirValue[sf.args[1], sf.args[2], W.NirConst(Core.Const(:c)), sf.args[4]])
    @test rejection(() -> D.visit_instance_set(g, sc, D.void_marker(g))).rejection isa W.Unquarantined
end

@testset "symbols.dart: Symbols" begin
    local s = D.Symbols(false)
    @test D.method_symbol_from_name(s, :f) === :f && D.getter_symbol_from_name(s, :x) === :x
    @test D.setter_symbol_from_name(s, :x) === Symbol("x=") && D.symbol_for_named_parameter(s, "k") === :k
    @test D.get_mangled_symbol_name(s, :foo) == "foo" && isempty(s.symbol_ordinals)
    # minified, each symbol its ordinal in order of first use, in dart's base 64
    local m = D.Symbols(true)
    local names = [D.get_mangled_symbol_name(m, x) for x in (:a, :b, :a, :c)]
    @test names == [D.Util.int_to_base64(0), D.Util.int_to_base64(1), D.Util.int_to_base64(0), D.Util.int_to_base64(2)]
    @test m.symbol_ordinals == Dict(:a => 0, :b => 1, :c => 2)
end

@testset "code_generator.dart: the first compile, f(x::Int32) = x + Int32(1)" begin
    # WasmTarget.compile runs the whole pipeline (compile.dart's phases, translate): the module our
    # builder accepted instruction by instruction; run by node it answers as native Julia (1 42 0
    # -2147483648 -2147483647 for 0 41 -1 typemax typemin, the add wrapping)
    local bytes = W.compile(CodegenCases.f_add, (Int32,))
    @test bytes[1:8] == UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
    # the body: local.get 0, i32.const 1, i32.add
    @test any(i -> bytes[i:i+4] == UInt8[0x20, 0x00, 0x41, 0x01, 0x6a], 1:length(bytes)-4)
    # the entry exported under its function's name
    @test occursin("f_add", String(copy(bytes)))
    @test CodegenCases.f_add(typemax(Int32)) == typemin(Int32)
end

# the module of one function: translate()'s steps before code, the body generated, `f` exported
function compile_one(f, argtypes)
    local B = W.WasmBuilder
    local t = translator_of(f, argtypes)
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    local mb = D.main_module(t)
    local nb = only(t.component)
    local sig = B.define_function(mb.types[], IR.ValueType[D.translate_type(t, T) for T in argtypes], IR.ValueType[D.translate_return_type(t, nb.ci.rettype)])
    local fb = B.define(mb.functions[], sig, "f")
    D.generate(D.get_member_code_generator(t, fb, nb.ci.def), B.body(fb), B.locals(fb), nothing)
    B.var"export"(mb.exports, "f", fb)
    local s = B.Serializer(); B.serialize(s, B.build(mb))
    return B.data(s)
end

module IntrinsicCompileCases
mulshift(x::Int64, y::Int64) = x * y - (x >> 3)
floorabs(x::Float64) = floor(x) + abs(x)
scale(x::Int32) = Float64(x) * 2.5
absint(x::Int64) = abs(x)
bits(x::Int64) = leading_zeros(x) + trailing_zeros(x) + count_ones(x)
notand(a::Bool, b::Bool) = !a & b
minmax(x::Int32, y::Int32) = min(x, y) + max(x, y)
widen32(x::Int32) = UInt64(reinterpret(UInt32, x)) + 1
egal(x::Float64, y::Float64) = x === y
end

@testset "intrinsics.dart: whole functions of Julia's intrinsics compile" begin
    # each compiles to a module the builder accepted instruction by instruction (D10); run by node,
    # each answers as native Julia on its edge inputs (the commit records the differential)
    local C = IntrinsicCompileCases
    for (f, at) in ((C.mulshift, (Int64, Int64)), (C.floorabs, (Float64,)), (C.absint, (Int64,)), (C.notand, (Bool, Bool)),
                    (C.widen32, (Int32,)))
        local bytes = compile_one(f, at)
        @test bytes[1:8] == UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
    end
end

module CallTargetCases
@noinline h(x::Int64) = x * x + Int64(3)
g(x::Int64) = h(x) + h(x + Int64(1))
end

@testset "code_generator.dart: CallTarget and AstCallTarget" begin
    local t = translator_of(CallTargetCases.g, (Int64,))
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    local mi = only(nb.ci.def for nb in t.component if nb.ci.def.def.name === :h)
    local target = D.direct_call_target(t, mi)
    @test target isa D.AstCallTarget && target._reference === mi && target.signature === D.signature_for_direct_call(t, mi)
    # the target names and gives the member's function, made once in the main module
    @test D.name(target) == D.get_function_name(t.functions[], mi)
    @test D.var"function"(target) === D.get_function(t.functions[], mi)
    # the inlinable generator of the member, over the same signature
    local cg = D.inlining_code_gen(target)
    @test cg isa D.SynchronousProcedureCodeGenerator && cg.member === mi && cg.function_type === target.signature
    # the base class's answers, which a call target without its own takes
    @test !invoke(D.synthesize_null_return_value, Tuple{D.CallTarget}, target) && !invoke(D.synthesize_no_return, Tuple{D.CallTarget}, target)
    @test !invoke(D.supports_inlining, Tuple{D.CallTarget}, target) && !invoke(D.should_inline, Tuple{D.CallTarget}, target).should_inline
    @test rejection(() -> invoke(D.name, Tuple{D.CallTarget}, target)).rejection isa W.Internal
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

@testset "code_generator.dart: a PiNode is the unchecked as" begin
    local g = codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    # the narrowing translates its operand at the expected type: here the argument's local, which no
    # parameter setup has made, so the read rejects where it stands
    local e = rejection(() -> D.translate_expression(g, W.NirPi(W.NirArgument(2), Int32), IR.NumType_i32))
    @test e.rejection isa W.Internal && occursin("undefined variable", e.rejection.site)
    # an unused narrowing is an expression statement at the void marker, no longer a 1.D rejection
    local e2 = rejection(() -> D.translate_statement(g, W.NirPi(W.NirArgument(2), Int32), nothing))
    @test !(e2.rejection isa W.Unquarantined)
end

@testset "code_generator.dart: MacroAssembler's class-id search, loops and tables" begin
    local B = W.WasmBuilder
    # f(classId) = whether it lies in `ranges`, through emitClassIdRangeCheck: a linear search for three
    # ranges or fewer, a bisection beyond; each module accepted by the builder at every instruction
    local range_module(ranges) = begin
        local mb = B.ModuleBuilder("m", nothing)
        local fb = B.define(mb.functions[], B.define_function(mb.types[], IR.ValueType[IR.NumType_i32], IR.ValueType[IR.NumType_i32]), "f")
        local b = B.body(fb)
        B.local_get(b, B.locals(fb)[1])
        D.emit_class_id_range_check(b, ranges)
        B.var"end"(b)
        local s = B.Serializer(); B.serialize(s, B.build(mb)); B.data(s)
    end
    # run by node over class ids 0..45 each answers Julia's `any(r -> contains(r, id), ranges)` (the
    # commit records the differential)
    for ranges in ([D.Range(3, 3)], [D.Range(1, 2), D.Range(5, 9)],
                   [D.Range(0, 0), D.Range(2, 4), D.Range(7, 7), D.Range(10, 20), D.Range(30, 31)],
                   [D.Range(i, i + 1) for i in 0:4:40])
        @test range_module(ranges)[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    end
    # an empty search with no miss is WasmTarget's own defect
    local mb = B.ModuleBuilder("m", nothing)
    local fb = B.define(mb.functions[], B.define_function(mb.types[], IR.ValueType[IR.NumType_i32], IR.ValueType[IR.NumType_i32]), "f")
    @test rejection(() -> D._linear_class_id_search(B.body(fb), NamedTuple{(:range, :value), Tuple{D.Range, Nothing}}[], IR.ValueType[], _ -> nothing, nothing)).rejection isa W.Internal
    # incrementingLoop and emitDenseTableBranch build valid control: a sum of 0..n-1 and a three-way table
    local mb2 = B.ModuleBuilder("m", nothing)
    local fb2 = B.define(mb2.functions[], B.define_function(mb2.types[], IR.ValueType[IR.NumType_i32], IR.ValueType[IR.NumType_i32]), "g")
    local b2 = B.body(fb2)
    local acc = B.add_local(b2, IR.NumType_i32)
    D.incrementing_loop(b2; push_start = () -> B.i32_const(b2, 0), push_limit = () -> B.local_get(b2, B.locals(fb2)[1]),
        gen_body = v -> (B.local_get(b2, acc); B.local_get(b2, v); B.i32_add(b2); B.local_set(b2, acc)))
    D.emit_dense_table_branch(b2, IR.ValueType[IR.NumType_i32], 3, () -> B.local_get(b2, acc),
        i -> B.i32_const(b2, 10 * (i + 1)), () -> B.i32_const(b2, -1))
    B.var"end"(b2)
    local s2 = B.Serializer(); B.serialize(s2, B.build(mb2))
    @test B.data(s2)[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
end

module GlobalCases
const SCALE = Int32(7)
counter = 0
const BOX = Ref(0)
scaled(x::Int32) = x * SCALE
end

@testset "code_generator.dart: a constant binding's read is its value" begin
    # a GlobalRef of a constant binding is its value, instantiated as a constant: it reaches the
    # translator's constants, which no translate() has assigned here
    local g = codegen_of(GlobalCases.scaled, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    D._init_modules(g.translator, nothing)
    collect(D.ClassInfoCollector(g.translator))
    g.translator.dart_globals[] = D.DartGlobals(g.translator)
    local e = rejection(() -> D.translate_expression(g, W.NirGlobal(GlobalRef(GlobalCases, :SCALE)), IR.NumType_i32))
    @test e.rejection isa W.Unported && occursin("Translator.constants", e.rejection.anchor)
    # a binding a load can change (non-const, or const holding a mutable object, globals.dart's one
    # rule) reaches the getter, which rejects, located, as a statement or an operand
    for name in (:counter, :BOX)
        @test occursin("_generateGetter", rejection(() -> D.visit_static_get(g, W.NirGlobalRead(GlobalRef(GlobalCases, name)), IR.NumType_i32)).rejection.anchor)
    end
    @test rejection(() -> D.visit_static_get(g, W.NirGlobal(GlobalRef(GlobalCases, :counter)), IR.NumType_i32)).rejection isa W.Unported
end

module ControlCases
sumto(n::Int64) = (s = Int64(0); for i in Int64(1):n; s += i; end; s)
function fib(n::Int32)
    a, b = Int32(0), Int32(1)
    for _ in Int32(1):n
        a, b = b, a + b
    end
    a
end
sign3(x::Float64) = x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0)
absdiff(x::Int32, y::Int32) = x > y ? x - y : y - x
mergey(x::Int32) = (y = x > Int32(0) ? x * Int32(2) : x - Int32(5); y + Int32(1))
function early(x::Int64, y::Int64)
    x < 0 && return Int64(0)
    for i in Int64(1):y
        i > x && return i
    end
    y
end
end

@testset "code_generator.dart: control flow, structured by LLVM's stackifier" begin
    # loops, phis (fib's `a, b = b, a + b` a parallel move), nested branches, a merging diamond and
    # early returns from a loop: each body's machine code, sorted and stackified by LLVM's passes, is
    # lowered into a module the builder accepted at every instruction; run by node, each answers as
    # native Julia on its edge inputs (the commit records the differential)
    local C = ControlCases
    for (f, at) in ((C.fib, (Int32,)), (C.sign3, (Float64,)), (C.mergey, (Int32,)), (C.early, (Int64, Int64)))
        @test compile_one(f, at)[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    end
    # the loop's module holds a loop (0x03) and a conditional branch out of it
    local bytes = compile_one(C.sumto, (Int64,))
    @test 0x03 in bytes && 0x0d in bytes
end

@testset "types.dart's type tests read the code generator's late builder" begin
    # emitIsTest and emitAsCheck emit into AstCodeGenerator.b, dart's `late w.InstructionsBuilder b`,
    # a Late cell: read through it, a type test reaches its own rules (a located answer or rejection),
    # never a MethodError on the cell
    local B = W.WasmBuilder
    local t = translator_of(CodegenCases.f_add, (Int32,))
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    local mi = only(nb.ci.def for nb in t.component)
    local fb = B.define(D.main_module(t).functions[], B.define_function(D.main_module(t).types[], IR.ValueType[], IR.ValueType[]), "probe")
    local g = D.get_inlinable_member_code_generator(t, fb.type, mi)
    g.b[] = B.body(fb)
    for f in (() -> D.emit_is_test(t.types[], g, Int64, Any),
              () -> D.emit_as_check(t.types[], g, Int64, Any, t.top_type[]))
        local r = try; f(); nothing; catch e; e; end
        @test r === nothing || r isa W.RejectionError
    end
end

@testset "translator.dart: topTypeNonNullable" begin
    local t = translator_of(CodegenCases.f_add, (Int32,))
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    # dart's topType without null, read once from the top type
    @test t.top_type_non_nullable[] == W.WasmBuilder.with_nullability(t.top_type[], false) && !t.top_type_non_nullable[].nullable
end

@testset "code_generator.dart: an unresolved call and a field outside the layout reject at their rows" begin
    local g = codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    # a generic call Julia left unresolved (the trim verifier's must-throw warning) is dart's dynamic
    # invocation, rejected at that row, not at the intrinsifier's
    local e = rejection(() -> D.visit_static_invocation(g, W.NirCall(W.NirValue[W.NirConst(Core.Const(sin)), W.NirArgument(2)]), IR.NumType_f64))
    @test e.rejection isa W.Unported && occursin("visitDynamicInvocation", e.rejection.anchor)
    # a field the class layout does not hold is a valid program outside the representation (A44S1)
    local t = translator_of(FieldGenCases.getb, (FieldGenCases.P,))
    local body = only(t.component)
    local gb = D.SynchronousProcedureCodeGenerator(Val(:_), t, IR.FunctionType(IR.ValueType[], IR.ValueType[]), body.ci.def, body)
    local gf = body.stmts[findfirst(s -> s isa W.NirCall, body.stmts)]::W.NirCall
    local nofield = W.NirCall(W.NirValue[gf.args[1], gf.args[2], W.NirConst(Core.Const(:nope))])
    @test rejection(() -> D.visit_instance_get(gb, nofield, IR.NumType_f64)).rejection isa W.Unquarantined
end

module NarrowCases
add8(x::Int8, y::Int8) = x + y
lt8u(x::UInt8, y::UInt8) = x < y
neg8(x::Int8) = -x
widen8(x::Int8) = Int64(x) + Int64(1)
lshr8(x::Int8) = Core.Intrinsics.lshr_int(x, 0x03)
end

@testset "intrinsics.dart: 8- and 16-bit integers, in their type's form" begin
    # each compiles, our builder accepting every instruction; run by node over every pair of edge
    # values (-128, -1, 0, 1, 100, 127 and 0, 1, 100, 200, 255), each answers as native Julia (the
    # commit records the differential)
    local C = NarrowCases
    for (f, at) in ((C.add8, (Int8, Int8)), (C.lt8u, (UInt8, UInt8)), (C.neg8, (Int8,)), (C.widen8, (Int8,)), (C.lshr8, (Int8,)))
        @test compile_one(f, at)[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    end
    # the add of two Int8s puts its result back sign-extended (i32.extend8_s, 0xc0)
    @test 0xc0 in compile_one(C.add8, (Int8, Int8))
end

module TypeTestCases
# the entry's signature is concrete (Julia compiles no specialization for a Union signature); the
# operand under test is the field read, whose inferred type is the Union
maybe(r::Base.RefValue{Union{Nothing,Int64}}) = r[] isa Int64
end

@testset "code_generator.dart: isa and typeassert through types.dart's tests" begin
    local t = translator_of(TypeTestCases.maybe, (Base.RefValue{Union{Nothing,Int64}},))
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    local body = only(t.component)
    local g = D.SynchronousProcedureCodeGenerator(Val(:_), t, IR.FunctionType(IR.ValueType[], IR.ValueType[]), body.ci.def, body)
    local mb = D.main_module(t)
    g.b[] = W.WasmBuilder.body(W.WasmBuilder.define(mb.functions[], W.WasmBuilder.define_function(mb.types[], IR.ValueType[], IR.ValueType[]), "probe"))
    local x = W.NirSSA(findfirst(==(Union{Nothing,Int64}), body.types))
    local isa_call = W.NirCall(W.NirValue[W.NirConst(Core.Const(Core.isa)), x, W.NirConst(Core.Const(Int64))])
    local ta_call = W.NirCall(W.NirValue[W.NirConst(Core.Const(Core.typeassert)), x, W.NirConst(Core.Const(Int64))])
    # routed to visitIsExpression and visitAsExpression; each reaches its operand's local (the field
    # read is never visited here), a located rejection, past the routing and the tested type
    for c in (isa_call, ta_call)
        local e = rejection(() -> D.translate_expression(g, c, IR.NumType_i32))
        @test e.rejection isa W.Internal && occursin("undefined variable", e.rejection.site)
    end
    # a type computed at run time is no type test's constant
    local dyn = W.NirCall(W.NirValue[W.NirConst(Core.Const(Core.isa)), x, x])
    @test rejection(() -> D.visit_is_expression(g, dyn, IR.NumType_i32)).rejection isa W.Unquarantined
end
