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

# the code generator of the entry body of `f` at `argtypes`, its wasm signature `ins -> outs`
function codegen_of(f, argtypes, ins, outs)
    local t = D.Translator(W.check_subset(f, argtypes, "code_generator"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
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
    # the used call declares its variable, typed by the translator's local-variable type
    local e = rejection(() -> D.translate_statement(g, g.body.stmts[1], W.NirSSA(1)))
    @test e.rejection isa W.Unported && occursin("translateTypeOfLocalVariable", e.rejection.anchor)
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
    @test D.generate_static_intrinsic(n.intrinsifier[], ncall) === nothing
    local e2 = rejection(() -> D.visit_static_invocation(n, ncall, IR.NumType_i32))
    @test e2.rejection isa W.Unported && occursin("generateStaticIntrinsic", e2.rejection.anchor) && occursin("Int8", e2.at)
end

@testset "code_generator.dart: translateStatement over the NIR" begin
    local t = D.Translator(W.check_subset(CodegenCases.shapes, (Int,), "code_generator"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local t2 = D.Translator(W.check_subset(CodegenCases.loop, (Int,), "code_generator"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local gens = [D.SynchronousProcedureCodeGenerator(Val(:_), tt, IR.FunctionType(IR.ValueType[], IR.ValueType[]), b.ci.def, b)
                  for tt in (t, t2) for b in tt.component]
    local forms = Set(W.stmt_form(st) for g in gens for st in g.body.stmts)
    @test "return" in forms && "gotoifnot" in forms && "new" in forms
    for g in gens, (k, st) in enumerate(g.body.stmts)
        local r = rejection(() -> D.translate_statement(g, st, W.NirSSA(k)))
        if st isa W.NirReturn
            # the return translates its value at the return type, the translator's outputOrVoid
            @test r.rejection isa W.Unported && occursin("outputOrVoid", r.rejection.anchor)
        elseif st isa W.NirNothing
            @test r === nothing
        elseif st isa Union{W.NirCall, W.NirInvoke, W.NirNew, W.NirGlobalRead}
            # a used value is a local declared with its initializer; an unused one an expression statement
            @test r.rejection isa W.Unported && occursin("translateTypeOfLocalVariable", r.rejection.anchor)
            # the unused one is translated at the void marker: its expression's own visitor, which
            # stops at the first piece not yet given here (a constant, a parameter, an allocation)
            local r2 = rejection(() -> D.translate_statement(g, st, nothing))
            @test r2 isa W.RejectionError && !occursin("voidMarker", string(r2.rejection))
        elseif st isa Union{W.NirForeignCall, W.NirCFunction}
            @test r.rejection isa W.Unquarantined && occursin("1.F", r.rejection.row)
        else
            # every Julia-only form rejects in its own arm, naming the stackifier's row
            @test r.rejection isa W.Unquarantined && occursin("1.D", r.rejection.row)
        end
    end
    # forms no program above holds, built directly
    @test rejection(() -> D.translate_statement(gens[1], W.NirGoto(1), nothing)).rejection isa W.Unquarantined
    @test rejection(() -> D.translate_statement(gens[1], W.NirUnreachable(), nothing)).rejection isa W.Unquarantined
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
    @test absent(g, call(I.trunc_int, lit(Int8), x)) && absent(n, call(I.sext_int, lit(Int32), x)) && absent(g, call(I.fpext, lit(Float64), x))
    # Julia's shifts saturate, the count unsigned: native Julia's answers, which the select ports
    @test I.shl_int(Int32(1), UInt64(40)) == 0 && I.lshr_int(Int32(-1), UInt8(32)) == 0
    @test I.ashr_int(Int32(-8), UInt64(100)) == -1 && I.ashr_int(Int32(8), UInt64(100)) == 0 && I.shl_int(Int64(3), Int32(-1)) == 0
    # a shift's arm takes a local for the count first, from the builder `generate` has not given yet
    local e = rejection(() -> D.generate_static_intrinsic(g.intrinsifier[], call(I.shl_int, x, lit(Int64(3)))))
    @test e.rejection isa W.Unported && occursin("AstCodeGenerator.b", e.rejection.anchor)
    @test absent(n, call(I.shl_int, x, lit(Int64(3))))
end

module FieldGenCases
struct P; a::Int32; b::Float64; end
struct N; x::Int8; y::UInt8; end
getb(p::P) = p.b
mk(x::Int32) = P(x, 2.0)
mkn(x::Int8) = N(x, 0x01)
end

@testset "code_generator.dart: a field read and an allocation" begin
    local t = D.Translator(W.check_subset(FieldGenCases.getb, (FieldGenCases.P,), "code_generator"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
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
    local t2 = D.Translator(W.check_subset(FieldGenCases.mk, (Int32,), "code_generator"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local b2 = only(t2.component)
    local g2 = D.SynchronousProcedureCodeGenerator(Val(:_), t2, IR.FunctionType(IR.ValueType[], IR.ValueType[]), b2.ci.def, b2)
    local nw = b2.stmts[findfirst(s -> s isa W.NirNew, b2.stmts)]::W.NirNew
    @test D.generate_constructor_intrinsic(g2.intrinsifier[], nw) === nothing
    local e2 = rejection(() -> D.translate_expression(g2, nw, IR.NumType_i32))
    @test e2.rejection isa W.Internal && occursin("no class info for $(FieldGenCases.P)", e2.rejection.site)
end
