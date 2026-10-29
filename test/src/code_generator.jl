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
translator_of(f, argtypes) = D.Translator(WasmTarget.build_nir(W.check_subset(f, argtypes, "code_generator"), "test"),
    D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())

# the code generator of the entry body of `f` at `argtypes`, its wasm signature `ins -> outs`
function codegen_of(f, argtypes, ins, outs)
    local t = translator_of(f, argtypes)
    local mi = only(nb.ci.def for nb in t.component if nb.ci.def.def.name === nameof(f))
    return D.get_inlinable_member_code_generator(t, IR.FunctionType(IR.ValueType[ins...], IR.ValueType[outs...]), mi)
end

# the code generator of `f` ready to emit, as `generate` leaves it before the body: translate()'s
# steps before code, its builder a function of signature `ins -> outs`, its parameters set up
function ready_codegen_of(f, argtypes, ins, outs)
    local B = W.WasmBuilder
    local t = translator_of(f, argtypes)
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    local mi = only(nb.ci.def for nb in t.component if nb.ci.def.def.name === nameof(f))
    local mb = D.main_module(t)
    local fb = B.define(mb.functions[], B.define_function(mb.types[], IR.ValueType[ins...], IR.ValueType[outs...]), "f")
    local g = D.get_inlinable_member_code_generator(t, fb.type, mi)
    g.b[] = B.body(fb)
    g.param_locals[] = B.locals(fb)
    g.return_label[] = nothing
    D.setup_parameters_for_normal_entry(g, g.member)
    return g
end

# the instructions `thunk` emits into the builder of `g`, by name
function emitted_by(thunk, g)
    local n0 = length(g.b[]._instructions)
    thunk()
    return String[W.WasmBuilder.name(i) for i in g.b[]._instructions[n0+1:end]]
end

# the rejection `f()` raises, or nothing
rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e : rethrow(); end

isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))

# the modules the file's cases compiled, each with its argument tuples and native Julia's answers,
# queued for one node process at the file's end (test/runner.jl, the third oracle): a node start per
# module would cost more than the cases
const NATIVE_RUNS = WTRunner.RunCase[]
queue_native!(label, bytes, f, argsets) =
    append!(NATIVE_RUNS, [WTRunner.RunCase("$label$a", bytes, a, f(a...)) for a in argsets])

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
    @test rejection(() -> D.setup_parameters_for_checked_entry(g, g.member)).rejection isa W.Internal
    @test rejection(() -> D.setup_parameters_for_unchecked_entry(g, g.member)).rejection isa W.Internal
    # a function's callee is a singleton: no `this` (dart's static member)
    @test g.this_local === nothing && rejection(() -> D.visit_this(g, IR.NumType_i32)).rejection isa W.Internal
    # the multi-function body: f_add inlined into f_twice, its statements read by SSA
    local h = codegen_of(CodegenCases.f_twice, (Int64,), [IR.NumType_i64], [IR.NumType_i32])
    @test h.used == BitSet([1, 2, 3])
end

@testset "code_generator.dart: the code generator holds every field dart declares" begin
    # dart's AstCodeGenerator declares 22 instance fields (code_generator.dart:67 to :160) and
    # SynchronousProcedureCodeGenerator 3 (:3606 to :3608); 5 are Julia's answers (typeContext,
    # breakFinalizers, switchLabels, switchBackwardJumpInfos, kind), and Julia's SSA form forces 2
    # (body, used): 22 + 3 - 5 + 2 = 22
    @test fieldcount(D.SynchronousProcedureCodeGenerator) == 22
    local g = codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    @test all(i -> isdefined(g, i), 1:fieldcount(D.SynchronousProcedureCodeGenerator))
    # dart's initial values: the maps and lists empty, no source yet
    @test isempty(g.type_locals) && isempty(g.try_block_locals) && g._source_map_source === nothing
    # the late closures, which generateInternal assigns from Translator.getClosures, reject when read
    # first: Unported, at the field's line
    local e = rejection(() -> g.closures[])
    @test e.rejection isa W.Unported && occursin("code_generator.dart:82 AstCodeGenerator.closures", e.rejection.anchor)
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

@testset "code_generator.dart: an allocation Julia's IR never produces is an Internal (A59S1)" begin
    local g = ready_codegen_of(FieldGenCases.mk, (Int32,), [IR.NumType_i32], IR.ValueType[])
    local nw = g.body.stmts[findfirst(s -> s isa W.NirNew, g.body.stmts)]::W.NirNew
    @test length(nw.args) == 3 && Core.Compiler.datatype_min_ninitialized(FieldGenCases.P) == 2
    # more values than fields, and fewer than the fields Julia's type requires initialized: neither is an
    # allocation Julia's IR produces, so each is WasmTarget's own defect, before the runtime's gap
    local over = rejection(() -> D.visit_constructor_invocation(g, W.NirNew(W.NirValue[nw.args..., nw.args[2]]), IR.NumType_i32))
    @test over.rejection isa W.Internal && occursin("passing 3 values to its 2 fields", over.rejection.site)
    local under = rejection(() -> D.visit_constructor_invocation(g, W.NirNew(nw.args[1:2]), IR.NumType_i32))
    @test under.rejection isa W.Internal && occursin("requires 2 initialized", under.rejection.site)
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

# the instructions `generate` emits for the body of `f` at `argtypes`, compile_one's steps, the
# bodies of the functions it calls not generated
function generated_instructions(f, argtypes)
    local B = W.WasmBuilder
    local t = translator_of(f, argtypes)
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    local mb = D.main_module(t)
    local nb = only(nb for nb in t.component if nb.ci.def.def.name === nameof(f))
    local sig = B.define_function(mb.types[], IR.ValueType[D.translate_type(t, T) for T in argtypes], IR.ValueType[D.translate_return_type(t, nb.ci.rettype)])
    local fb = B.define(mb.functions[], sig, "f")
    local b = B.body(fb)
    D.generate(D.get_member_code_generator(t, fb, nb.ci.def), b, B.locals(fb), nothing)
    return String[B.name(i) for i in b._instructions]
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

module InstanceCases
# `c(y)` inside callc: a call whose callee, the closure, carries its capture x, Kernel's
# InstanceInvocation, the closure the receiver
@noinline callc(c, y::Int64) = c(y)
mkc(x::Int64) = callc(z -> z + x, Int64(3))
end

@testset "code_generator.dart: a call of a callee that carries fields is an instance invocation" begin
    local bytes = W.compile(InstanceCases.mkc, (Int64,); optimize = false)
    @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    queue_native!("mkc", bytes, InstanceCases.mkc, [(x,) for x in Int64[0, 5, -7, typemax(Int64)]])
    # Julia has no super call (Core.invoke, which the trim verifier rejects): reaching a super visitor
    # is WasmTarget's own defect, naming why
    local g = codegen_of(InstanceCases.mkc, (Int64,), [IR.NumType_i64], [IR.NumType_i64])
    local inv = first(st for st in g.body.stmts if st isa W.NirInvoke)
    for v in (D.visit_super_method_invocation, D.visit_super_property_get, D.visit_super_property_set)
        local e = rejection(() -> v(g, inv, IR.NumType_i32))
        @test e.rejection isa W.Internal && occursin("unimplemented_invoke", e.rejection.site)
    end
    # a call of a function value is an invoke of its method: dart's closure calls name Julia's visitors
    for v in (D.visit_function_invocation, D.visit_local_function_invocation)
        local e = rejection(() -> v(g, inv, IR.NumType_i64))
        @test e.rejection isa W.Internal && occursin("visitInstanceInvocation", e.rejection.site)
    end
    # a closure is a struct of its captures: its allocation is visitConstructorInvocation's
    local f = rejection(() -> D._push_context(g, g.body))
    @test f.rejection isa W.Internal && occursin("visitConstructorInvocation", f.rejection.site)
end

module EqualsCases
struct P; x::Int64; end
@noinline Base.:(==)(a::P, b::P) = a.x == b.x
eqp(x::Int64, y::Int64) = P(x) == P(y)
end

@testset "code_generator.dart: a call of == is Kernel's EqualsCall" begin
    # == on two Int64s is the equality intrinsic; a method of == Julia resolved (P's) is called with
    # both operands: each run by node against native
    local bytes = W.compile(EqualsCases.eqp, (Int64,Int64); optimize = false)
    @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    queue_native!("eqp", bytes, EqualsCases.eqp, [(Int64(1), Int64(1)), (Int64(1), Int64(2)), (typemin(Int64), typemin(Int64))])
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

@testset "code_generator.dart: a literal is its value's constant, as dart's literal visitors" begin
    # translateExpression routes a NirConst by its value's type to dart's literal visitors, each the
    # same constant visitConstantExpression instantiates
    local g = ready_codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    for (v, w, visitor) in ((true, IR.NumType_i32, D.visit_bool_literal), (Int64(5), IR.NumType_i64, D.visit_int_literal),
                            (2.5, IR.NumType_f64, D.visit_double_literal))
        local c = W.NirConst(Core.Const(v))
        local routed = emitted_by(() -> D.translate_expression(g, c, w), g)
        @test !isempty(routed) && emitted_by(() -> visitor(g, c, w), g) == routed == emitted_by(() -> D.visit_constant_expression(g, c, w), g)
    end
end

@testset "code_generator.dart: makeArray over the translator's" begin
    # an array of expressions takes the translator's mutable array type of its element and its makeArray:
    # each item translated at the element type (here a boxed Int32's constant), in order, then the array
    local g = ready_codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    local items = W.NirValue[W.NirConst(Core.Const(Int32(1))), W.NirConst(Core.Const(Int32(2)))]
    local result = nothing
    local ins = emitted_by(() -> (result = D.make_array_from_expressions(g, items, Int32)), g)
    @test result isa IR.RefType && length(ins) == 3 && startswith(ins[end], "array.new_fixed")
end

@testset "code_generator.dart: the source map's source, types, and what a Julia method never needs" begin
    local g = ready_codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    @test D.types(g) === g.translator.types[]
    # the source swaps in and the old one comes back, with the file offset beside it
    @test D.set_source_map_source(g, :file) === nothing && D.set_source_map_source(g, nothing) === :file
    @test D.set_source_map_source_and_file_offset(g, :file, D.TreeNode_no_offset) == (nothing, D.TreeNode_no_offset)
    # a Julia method is never external, checks no covariant parameter and has no type argument at run
    # time; an abstract code generator has no instance: each an Internal, located
    @test rejection(() -> D.emit_unimplemented_external_error(g, g.member)).rejection isa W.Internal
    @test rejection(() -> D.AstCodeGenerator(g.translator, g.function_type, g.member)).rejection isa W.Internal
    local call = g.body.stmts[1]::W.NirCall
    @test occursin("visitAsExpression", rejection(() -> D.visit_null_check(g, call, IR.NumType_i32)).rejection.site)
    # no context: nothing to initialize, nothing emitted
    @test emitted_by(() -> D._initialize_context_locals(g, call), g) == String[]
    # a variable declared by its statement is visitVariable's, its local holding the value; a parameter
    # is no declaration; a variable initialized from a pushed value keeps it in a local of its own
    @test emitted_by(() -> D.translate_variable(g, W.NirSSA(1)), g) == ["local.get", "i32.const 1", "i32.add", "local.set"]
    @test rejection(() -> D.translate_variable(g, W.NirArgument(2))).rejection isa W.Internal
    @test emitted_by(() -> D.initialize_variable(g, W.NirSSA(1), () -> W.WasmBuilder.i32_const(g.b[], 7)), g) == ["i32.const 7", "local.set"]
    # the runtime's printToConsole is not ported: Unported at its definition
    @test occursin("printToConsole", rejection(() -> D.debug_runtime_print(g, "x")).rejection.anchor)
end

@testset "code_generator.dart: a PiNode is the unchecked as" begin
    local g = ready_codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    # the narrowing translates its operand at the expected type: the argument's local, read
    @test emitted_by(() -> D.translate_expression(g, W.NirPi(W.NirArgument(2), Int32), IR.NumType_i32), g) == ["local.get"]
    # an unused narrowing is an expression statement at the void marker: its operand read and dropped
    @test emitted_by(() -> D.translate_statement(g, W.NirPi(W.NirArgument(2), Int32), nothing), g) == ["local.get", "drop"]
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
        B.var"export"(mb.exports, "f", fb)
        local s = B.Serializer(); B.serialize(s, B.build(mb)); B.data(s)
    end
    # run by node over class ids 0..45 each answers Julia's `any(r -> contains(r, id), ranges)`
    for ranges in ([D.Range(3, 3)], [D.Range(1, 2), D.Range(5, 9)],
                   [D.Range(0, 0), D.Range(2, 4), D.Range(7, 7), D.Range(10, 20), D.Range(30, 31)],
                   [D.Range(i, i + 1) for i in 0:4:40])
        local bytes = range_module(ranges)
        @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
        queue_native!("ranges $(length(ranges)) ", bytes, id -> Int32(any(r -> contains(r, Int64(id)), ranges)), [(Int32(id),) for id in 0:45])
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
setcounter(x::Int) = (global counter = x; nothing)
@noinline callf(f, x) = f(x)
tear(x::Int32) = callf(abs, x)
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
    # its static type rejects at the same getter, one kind at both sites; a constant binding's type is
    # its value's, mutable or not
    @test occursin("_generateGetter", rejection(() -> D.dart_type_of(g, W.NirGlobal(GlobalRef(GlobalCases, :counter)))).rejection.anchor)
    @test D.dart_type_of(g, W.NirGlobal(GlobalRef(GlobalCases, :BOX))) === Base.RefValue{Int64}
    # a function's binding as an operand, `abs` passed to callf, is Kernel's StaticTearOff, the
    # function's singleton constant: run by node against native
    local tb = W.compile(GlobalCases.tear, (Int32,); optimize = false)
    queue_native!("tear", tb, GlobalCases.tear, [(x,) for x in Int32[-3, 0, 5, typemin(Int32)]])
    # a write of a binding, Kernel's StaticSet (the body's own setglobal!), calls its setter, not
    # ported: Unported there
    local sg = codegen_of(GlobalCases.setcounter, (Int,), [IR.NumType_i64], IR.ValueType[])
    local set = only(st for st in sg.body.stmts if st isa W.NirCall && W.nir_callee(st) === Core.setglobal!)
    local w = rejection(() -> D.translate_expression(sg, set, D.void_marker(sg)))
    @test w.rejection isa W.Unported && occursin("StaticFieldImplicitAccessorCodeGenerator._generateSetter", w.rejection.anchor)
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
    # native Julia on its edge inputs
    local C = ControlCases
    local i32s = Int32[0, 41, -1, typemax(Int32), typemin(Int32)]
    for (f, at, argsets) in ((C.fib, (Int32,), [(Int32(n),) for n in (0, 1, 2, 10, 46, 47)]),
                             (C.sign3, (Float64,), [(x,) for x in [0.0, -0.0, 1.5, -2.5, 1e300, -Inf, NaN]]),
                             (C.mergey, (Int32,), [(x,) for x in i32s]),
                             (C.early, (Int64, Int64), [(Int64(-1), Int64(5)), (Int64(2), Int64(9)), (Int64(9), Int64(3)), (Int64(0), Int64(0))]),
                             (C.sumto, (Int64,), [(Int64(n),) for n in (0, 1, 10, 1000)]))
        local bytes = compile_one(f, at)
        @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
        queue_native!(string(nameof(f)), bytes, f, argsets)
    end
    # the loop's module holds a loop (0x03) and a conditional branch out of it
    local bytes = compile_one(C.sumto, (Int64,))
    @test 0x03 in bytes && 0x0d in bytes
end

module TryGenCases
struct E; v::Int64; end
@noinline thr(x::Int64) = x < 0 ? throw(E(x)) : x
tc(x::Int64) = try; thr(x) + 1; catch e; e isa E ? e.v * 2 : 0; end
tn(x::Int64) = try; (try; thr(x); catch; -1; end) + thr(x + 1); catch; -2; end
end

@testset "code_generator.dart: a try/catch, the stackifier's try_table around the call that unwinds to the catch" begin
    # tc's body alone (thr's, whose throw is not ported, is not generated), each instruction accepted
    # by the builder (D10): a BLOCK typed by the exception tag's payload, the try_table catching the tag
    # into it around the call, an unreachable after the try_table's end; after the block's end the
    # caught exception stashed (dart's visitTryCatch) and Julia's the_exception, narrowed to E, cast
    local names = generated_instructions(TryGenCases.tc, (Int64,))
    local t = findfirst(==("try_table"), names)
    @test names[t-2:t] == ["block", "block", "try_table"] && names[t+1:t+2] == ["local.get", "call"]
    local u = findfirst(==("unreachable"), names)
    @test names[u-1:u+5] == ["end", "unreachable", "end", "local.set", "local.get", "ref.cast", "local.set"]
    # nested try regions: the value the inner catch receives, x, through its Upsilon into the PhiC's
    # register, which the catch block reads
    local nn = generated_instructions(TryGenCases.tn, (Int64,))
    @test count(==("try_table"), nn) == 2 && count(==("unreachable"), nn) == 2
    # a try region's entry, exit and pop are the stackifier's structure and emit nothing; its catch's
    # exception and exception-edge values are read where visit_block translates them, never as statements
    local g = ready_codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    for st in (W.NirEnter(2, nothing), W.NirLeave(W.NirValue[W.NirSSA(1)]), W.NirPopException(W.NirValue[W.NirSSA(1)]))
        @test isempty(emitted_by(() -> D.translate_statement(g, st, nothing), g))
    end
    for st in (W.NirTheException(W.NirValue[]), W.NirUpsilon(W.NirArgument(2)), W.NirPhiC(W.NirValue[W.NirSSA(1)]))
        local r = rejection(() -> D.translate_statement(g, st, W.NirSSA(3)))
        @test r.rejection isa W.Internal && occursin("visit_block", r.rejection.site)
    end
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

module ThrowCases
struct E; v::Int64; end
thr(x::Int64) = x < 0 ? throw(E(x)) : x
end

@testset "code_generator.dart: an unresolved call and a field outside the layout reject at their rows" begin
    local g = codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    # a generic call Julia left unresolved (the trim verifier's must-throw warning) is Julia's
    # MethodError throw, never dart's dynamic invocation: rejected at the throw's port, not at the
    # intrinsifier's
    local e = rejection(() -> D.visit_static_invocation(g, W.NirCall(W.NirValue[W.NirConst(Core.Const(sin)), W.NirArgument(2)]), IR.NumType_f64))
    @test e.rejection isa W.Unported && occursin("Error._throwWithCurrentStackTrace", e.rejection.anchor) && occursin("proved throws", e.at)
    # a definition only a node Julia has no counterpart for reaches rejects by its Kernel row: Internal at
    # the definition, naming the row and its reason, the one source of that text
    local k = rejection(() -> W.no_counterpart_rejection("Let", "dart2wasm/lib/code_generator.dart:1603 AstCodeGenerator.visitLet", "at"))
    @test k.rejection isa W.Internal && occursin("AstCodeGenerator.visitLet: the Kernel table's Let row, no counterpart", k.rejection.site) &&
          occursin("visit_block", k.rejection.site)
    @test rejection(() -> W.no_counterpart_rejection("ReturnStatement", "a", "b")).rejection isa W.Internal
    # Julia's throw(x), Kernel's Throw: the exception, then the runtime's throw, not ported: Unported there
    local t = rejection(() -> W.compile(ThrowCases.thr, (Int64,); optimize = false))
    @test t.rejection isa W.Unported && t.rejection.anchor == "sdk/lib/_internal/wasm/common/errors_patch.dart:19 Error._throwWithCurrentStackTrace" &&
          occursin("ThrowCases.E", t.at)
    # dart's dynamic invocation has no Julia input: the verifier resolves every call it admits but a
    # must-throw one, so reaching it is WasmTarget's own defect, naming Julia's replacement
    local d = rejection(() -> D._handle_dynamic_invocation(g, W.NirArgument(2), W.NirValue[], :f))
    @test d.rejection isa W.Internal && occursin("trim verifier", d.rejection.site) && occursin("visitStaticInvocation", d.rejection.site)
    # Julia's IR is a CFG, which visit_block structures by LLVM's CFGStackify port: each structured
    # statement's visitor takes the Kernel table's NoCounterpart, which no value inhabits, so no NIR
    # reaches one; a try region too, Julia's EnterNode, which visit_block structures as a try_table
    for v in (D.visit_labeled_statement, D.visit_break_statement, D.visit_if_statement, D.visit_do_statement, D.visit_while_statement,
              D.visit_for_statement, D.emit_for_statement_update, D.visit_switch_statement, D.visit_continue_switch_statement,
              D.visit_try_catch, D.visit_try_finally)
        @test only(m for m in methods(v) if m.sig.parameters[2] === D.AstCodeGenerator).sig.parameters[3] === W.NoCounterpart
    end
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

module TypeTestCases
# each entry's signature is concrete (Julia compiles no specialization for a Union signature); the
# operand under test is the field read, whose inferred type is the Union
maybe(r::Base.RefValue{Union{Nothing,Int64}}) = r[] isa Int64
# the same isa over a reference the runner can build from an Int64 (an Int64 in the Union needs its
# box, not ported): the Ref built inside, nothing for a negative argument
mutable struct Cell; x::Int64; end
maybe_cell(r::Base.RefValue{Union{Nothing,Cell}}) = r[] isa Cell
maybe_of(x::Int64) = maybe_cell(Ref{Union{Nothing,Cell}}(x < 0 ? nothing : Cell(x)))
# Julia's `x === nothing` over the same field read, Kernel's EqualsNull
null_of(x::Int64) = Ref{Union{Nothing,Cell}}(x < 0 ? nothing : Cell(x))[] === nothing
as_int(r::Base.RefValue{Union{Nothing,Int64}}) = r[]::Int64
dyn(r::Base.RefValue{Union{Nothing,Int64}}, T::DataType) = r[] isa T
end

@testset "code_generator.dart: isa and typeassert through types.dart's tests" begin
    local R = Base.RefValue{Union{Nothing,Int64}}
    # Julia's isa of the field read, visitIsExpression over the body's own statement (the Union of
    # Nothing and Int64 a nullable reference, emitIsTest's null check): run by node it answers as
    # native Julia, nothing and every Int64
    local bytes = W.compile(TypeTestCases.maybe_of, (Int64,); optimize = false)
    queue_native!("maybe_of", bytes, TypeTestCases.maybe_of, [(x,) for x in Int64[-1, 0, 1, typemax(Int64), typemin(Int64)]])
    # `x === nothing`, visitEqualsNull: the field read's null check, run by node against native
    local nbytes = W.compile(TypeTestCases.null_of, (Int64,); optimize = false)
    queue_native!("null_of", nbytes, TypeTestCases.null_of, [(x,) for x in Int64[-1, 0, 5]])
    # Julia's typeassert, the checked AsExpression: emitAsCheck needs the runtime's _asSubtype, not
    # ported, a located rejection at the runtime library's definition
    local e = rejection(() -> generated_instructions(TypeTestCases.as_int, (R,)))
    @test e.rejection isa W.Unported && e.rejection.anchor == "sdk/lib/_internal/wasm/common/type.dart:1561 _asSubtype" &&
          startswith(e.at, "dart2wasm/lib/types.dart:527 Types.emitAsCheck")
    # a type computed at run time is no type test's constant: a value, which only the runtime's
    # subtype check takes, not ported
    local d = rejection(() -> generated_instructions(TypeTestCases.dyn, (R, DataType)))
    @test d.rejection isa W.Unported && d.rejection.anchor == "sdk/lib/_internal/wasm/common/type.dart:1484 _isSubtype" &&
          occursin("TypeTestCases.dyn", d.at)
    # Julia's type parameter is a static parameter of the MethodInstance, never a type local, a
    # capture or a field: no NIR reaches instantiateTypeParameter, an Internal naming nir.jl's rejection
    local g = codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    local p = rejection(() -> D.instantiate_type_parameter(g, TypeVar(:T)))
    @test p.rejection isa W.Internal && occursin("Expr(:static_parameter)", p.rejection.site)
end

# a variable a closure captures before it is assigned: Julia's closure conversion allocates Core.Box() with
# its contents undefined; until the runtime's throw is ported, a located Unported rejection, never a null
module BoxCases
@noinline function counter(n::Int)
    local f
    f = () -> n + 1
    return f()
end
@noinline function recur(n::Int)
    local g
    g = k -> k <= 0 ? 0 : k + g(k - 1)
    return g(n)
end
end
@testset "an allocation leaving a field undefined: Core.Box of a variable captured before it is assigned" begin
    for f in (BoxCases.counter, BoxCases.recur)
        local bytes = try
            W.compile(f, (Int,); optimize = false)
        catch e
            e isa W.RejectionError || rethrow()
            # located; an allocation leaving a field undefined rejects at the runtime's throw of a local read
            # before its assignment, never compiling to a null a later read takes for `nothing` (D9)
            @test !isempty(e.at)
            occursin("left undefined", sprint(showerror, e)) &&
                @test e.rejection isa W.Unported && occursin("_throwLateErrorLocalNI", e.rejection.anchor)
            nothing
        end
        bytes === nothing || queue_native!("$(nameof(f)) ", bytes, f, [(3,), (0,)])
    end
end

@testset "code_generator.dart: the switch statement's info, whose constructors no NIR reaches" begin
    # dart's fields, each by the one rule's name: the backward jump's local and labels, the jump table's
    # range, value pusher and cases, and the switch's types, comparisons, special cases and table
    @test fieldnames(D.SwitchBackwardJumpInfo) == (:switch_value_local, :loop_label, :default_loop_label)
    @test fieldnames(D.BrTableInfo) == (:min_value, :max_value, :_br_table_expr, :case_map)
    @test fieldnames(D.SwitchInfo) == (:nullable_type, :non_nullable_type, :dynamic_type_guard, :compare, :default_case, :null_case, :br_table)
    # a late field read before dart's constructor assigns it names the field
    local si = D.SwitchInfo(Val(:_))
    @test si.br_table === nothing && si.dynamic_type_guard === nothing
    @test occursin("SwitchInfo.compare", rejection(() -> si.compare[]).rejection.anchor)
    # Julia's IR has no switch statement: SwitchInfo's constructor and its special cases take the Kernel
    # table's NoCounterpart, which no value inhabits, so no NIR reaches either
    @test only(m for m in methods(D.SwitchInfo) if length(m.sig.parameters) == 3).sig.parameters[3] === W.NoCounterpart
    @test only(methods(D._initialize_special_cases)).sig.parameters[3] === W.NoCounterpart
    @test rejection(() -> W.NoCounterpart()).rejection isa W.Internal
end

@testset "code_generator.dart: the code generators of members Julia never has are types of no value" begin
    # each holds AstCodeGenerator's fields and dart's own, and its one inner constructor rejects Internal,
    # as dart's constructor, its outer function, does
    for (G, own) in ((D.TearOffCodeGenerator, (:member,)), (D.DynamicForwarderCodeGenerator, (:reference, :call_shape)),
                     (D.ConstructorInitializerCodeGenerator, (:member, :field_locals)), (D.ConstructorAllocatorCodeGenerator, (:member,)),
                     (D.ConstructorBodyCodeGenerator, (:member,)), (D.ImplicitFieldAccessorCodeGenerator, (:field, :is_implicit_getter, :use_unchecked_entry)),
                     (D.SynchronousLambdaCodeGenerator, (:lambda,)), (D.UnreachableCodeGenerator, ()))
        @test G <: D.AstCodeGenerator
        @test fieldnames(G) == (fieldnames(D.SynchronousProcedureCodeGenerator)[1:18]..., own...)
        local e = rejection(() -> G(Val(:_)))
        @test e.rejection isa W.Internal && occursin("$(nameof(G)): no value", e.rejection.site)
    end
end

module TypeLiteralCases
struct Bx; t::DataType; n::Int; end
# Julia keeps the type literal Int64 as the allocation's operand, the field the callee does not read
@noinline getn(b::Bx) = b.n
mkb(x::Int) = getn(Bx(Int64, x)) + 1
end
@testset "code_generator.dart: a type as a value is makeType's, Kernel's TypeLiteral" begin
    local g = ready_codegen_of(TypeLiteralCases.mkb, (Int,), [IR.NumType_i64], [IR.NumType_i64])
    g.translator.globals[] = D.Globals(g.translator); g.translator.dart_globals[] = D.DartGlobals(g.translator)
    local tt = D.non_nullable_type_type(D.types(g))
    # a type with no free type variable is a constant: its global read, the type's wasm type
    @test emitted_by(() -> @test(D.translate_expression(g, W.NirConst(Core.Const(Int64)), tt) == tt), g) == ["global.get"]
    # the allocation's type operand compiles, and the module answers as native Julia
    queue_native!("mkb ", W.compile(TypeLiteralCases.mkb, (Int,); optimize = false), TypeLiteralCases.mkb, [(3,), (-1,)])
end

module StaticFieldCases
global counter::Int = 7
bump(x::Int) = counter + x
end
# the translator of StaticFieldCases.bump as translate() leaves it before code, its DartGlobals assigned
function static_field_translator()
    local t = translator_of(StaticFieldCases.bump, (Int,))
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    t.globals[] = D.Globals(t)
    t.dart_globals[] = D.DartGlobals(t)
    return t
end
# a code generator of the binding, `G(t, type, binding, extra...)`, its builder a function of `type`
function static_field_codegen(G, t, ftype, extra...)
    local B = W.WasmBuilder
    local fb = B.define(D.main_module(t).functions[], ftype, "f")
    local g = G(t, ftype, GlobalRef(StaticFieldCases, :counter), extra...)
    g.b[] = B.body(fb)
    g.param_locals[] = B.locals(fb)
    g.return_label[] = nothing
    return g
end

@testset "code_generator.dart: a static field's initializer function" begin
    local t = static_field_translator()
    local counter = GlobalRef(StaticFieldCases, :counter)
    local ftype = D.get_function_type(t.functions[], counter)
    # the binding's reference is its initializer's: getMemberCodeGenerator gives its generator
    local mb = D.main_module(t)
    local gm = D.get_member_code_generator(t, W.WasmBuilder.define(mb.functions[], ftype, "init"), counter)
    @test gm isa D.StaticFieldInitializerCodeGenerator && gm.field === counter && gm.enclosing_member === counter
    # the lazy arm's definition is made through FunctionCollector.getFunction, whose located rejection
    # (the modules' __init__ at load) the body lets through, never a value in its place
    local g = static_field_codegen(D.StaticFieldInitializerCodeGenerator, t, ftype)
    local e = rejection(() -> D.generate_internal(g))
    @test e.rejection isa W.Unquarantined && occursin("src/functions.jl getFunction", e.rejection.row)
    # with the definition the lazy arm makes after it (a mutable global and its flag), the body writes
    # the binding's image value, tees it, sets the flag and returns the value
    local dg = t.dart_globals[]
    local flag = D._define_initializer_flag(dg, counter, mb)
    dg._definitions[counter] = D._define_global_based_field(dg, counter, D.translate_type_of_field(t, counter), mb, true, nothing, flag)
    local g2 = static_field_codegen(D.StaticFieldInitializerCodeGenerator, t, ftype)
    @test emitted_by(() -> D.generate_internal(g2), g2) ==
          ["i64.const 7", "local.tee", "global.set", "local.get", "i32.const 1", "global.set", "end"]
end

@testset "code_generator.dart: a static field's eager initializer in the start function" begin
    local t = static_field_translator()
    local counter = GlobalRef(StaticFieldCases, :counter)
    local mb = D.main_module(t)
    local gl = W.WasmBuilder.define(mb.globals[], IR.GlobalType(D.translate_type_of_field(t, counter); mutable = true), "counter")
    # its function type takes and returns nothing, its enclosing member the binding
    local g0 = D.EagerStaticFieldInitializerCodeGenerator(t, counter, gl)
    @test isempty(g0.function_type.inputs) && isempty(g0.function_type.outputs) && g0.enclosing_member === counter
    # the binding's image value written to its global
    local g = static_field_codegen((t, ft, f) -> D.EagerStaticFieldInitializerCodeGenerator(t, f, gl), t, g0.function_type)
    @test emitted_by(() -> D.generate_internal(g), g) == ["i64.const 7", "global.set"]
end

# Base's fallback == is Julia's egal: identity for two mutable objects, content for immutable values (audit #56)
module EqualsCases
struct Q; x::Int; end
mutable struct M; x::Int; end
@noinline same_q(a::Int) = Q(a) == Q(a)
@noinline same_m(a::Int) = M(a) == M(a)
@noinline self_m(a::Int) = (m = M(a); m == m)
end
@testset "Base's fallback == over immutable and mutable operands, never a wrong answer" begin
    for f in (EqualsCases.same_q, EqualsCases.same_m, EqualsCases.self_m)
        local bytes = try
            W.compile(f, (Int,); optimize = false)
        catch e
            e isa W.RejectionError || rethrow()
            # a rejection is admitted, located; a compiled module must answer as native does
            @test !isempty(e.at)
            nothing
        end
        bytes === nothing || queue_native!("$(nameof(f)) ", bytes, f, [(3,), (-1,)])
    end
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTRunner.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end
