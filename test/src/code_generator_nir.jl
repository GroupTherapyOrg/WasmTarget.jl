# test/src/code_generator.jl, split three ways (code_generator_nir.jl, code_generator_rows.jl,
# code_generator_static.jl), each testset moved verbatim; this third: the body's generator over the NIR, field
# reads, writes and allocations, calls, literals and constant and lazy bindings.
# dart2wasm's code_generator.dart, ported (src/code_generator.jl, dev/MARCH.md 1.D): the code generator
# of a body built over the closed world's NIR, its variables and static types Julia's: its fields, its
# statements, field reads, writes and allocations, calls, literals, constants, the definitions Julia
# never reaches, and the static-field generators. Its intrinsics and control flow are
# code_generator_intrinsics.jl's and code_generator_control.jl's, each a file the shards balance apart.
# a binding an __init__ set: this session ran the module's __init__ once, when its definition finished
# (a top-level module: a module nested in the test's own runs its __init__ only when the test's
# finishes), so the binding starts at that value and no __init__ is compiled (dev/MODULE_INIT.md;
# audit A61S1)
module CodegenInitOnceCases
const seen = Ref(0)
__init__() = (seen[] += 1; nothing)
read_seen(x::Int) = seen[] + x
end

module CodeGeneratorTest

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "codegen_helpers.jl"))

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
        elseif st isa Union{W.NirCall, W.NirInvoke, W.NirNew, W.NirGlobalRead, W.NirForeignCall, W.NirBoundscheck}
            # a used value is a local declared with its initializer; an unused one an expression statement
            # (Julia's bounds-check flag too, a Bool constant translateExpression gives: the runtime's
            # 128-bit division routines hold one)
            @test r.rejection isa W.Unported && occursin("AstCodeGenerator.b", r.rejection.anchor)
            # the unused one is translated at the void marker: its expression's own visitor, which
            # stops at the first piece not yet given here (a constant, a parameter, an allocation)
            local r2 = rejection(() -> D.translate_statement(g, st, nothing))
            @test r2 isa W.RejectionError && !occursin("voidMarker", string(r2.rejection))
        elseif st isa Union{W.NirUnreachable, W.NirPi}
            # a trap and a narrowing are emitted into the builder `generate` gives (the runtime's roots,
            # in every world, hold both)
            @test r.rejection isa W.Unported && occursin("AstCodeGenerator.b", r.rejection.anchor)
        elseif st isa W.NirCFunction
            @test r.rejection isa W.Unquarantined && startswith(r.rejection.row, "src/functions.jl getFunction") && occursin("1.F", r.rejection.row)
        elseif st isa Union{W.NirGoto, W.NirGotoIfNot, W.NirPhi}
            # a jump and a merge are the stackifier's (visit_block), never a statement of their own
            @test r.rejection isa W.Internal && occursin("visit_block", r.rejection.site)
        else
            # every Julia-only form rejects in its own arm, its row opening with the src file whose
            # definition it waits for
            local file = match(r"^([\w./-]+?)(?::\d+)?(?::|\s|$)", r.rejection.row)
            @test r.rejection isa W.Unquarantined && file !== nothing && isfile(joinpath(pkgdir(WasmTarget), file[1]))
        end
    end
    # forms no program above holds, built directly
    @test rejection(() -> D.translate_statement(gens[1], W.NirGoto(1), nothing)).rejection isa W.Internal
    # Julia's unreachable is a trap, emitted into the builder `generate` gives
    @test occursin("AstCodeGenerator.b", rejection(() -> D.translate_statement(gens[1], W.NirUnreachable(), nothing)).rejection.anchor)
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
    local body = entry_body(t.component)
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
    local b2 = entry_body(t2.component)
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
    local body = entry_body(t.component)
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
    # the runtime's printToConsole (the JS patch's) is called where the closed world holds it; this one
    # holds none, WasmTarget's own defect, located
    local dp = rejection(() -> D.debug_runtime_print(g, "x")).rejection
    @test dp isa W.Internal && occursin("print_to_console", sprint(show, dp))
end

@testset "code_generator.dart: a PiNode is the unchecked as" begin
    local g = ready_codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    # the narrowing translates its operand at the expected type: the argument's local, read
    @test emitted_by(() -> D.translate_expression(g, W.NirPi(W.NirArgument(2), Int32), IR.NumType_i32), g) == ["local.get"]
    # an unused narrowing is an expression statement at the void marker: its operand read and dropped
    @test emitted_by(() -> D.translate_statement(g, W.NirPi(W.NirArgument(2), Int32), nothing), g) == ["local.get", "drop"]
end

@testset "code_generator.dart: Julia's compilerbarrier is the unchecked as" begin
    local g = ready_codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    local lit(v) = W.NirConst(Core.Const(v))
    local barrier(setting) = W.NirCall(W.NirValue[lit(Core.compilerbarrier), lit(setting), W.NirArgument(2)])
    # Julia's answer: the value itself, under every setting
    @test Base.compilerbarrier(:const, Int32(3)) === Int32(3) && Base.compilerbarrier(:type, Int32(3)) === Int32(3)
    # the operand translated at the expected type: the argument's local, read
    @test emitted_by(() -> D.translate_expression(g, barrier(:type), IR.NumType_i32), g) == ["local.get"]
    # a setting of no Symbol type is emit_typecheck's run-time TypeError, not written: located
    @test rejection(() -> D.translate_expression(g, barrier(1), IR.NumType_i32)).rejection isa W.Unquarantined
end

module GlobalCases
const SCALE = Int32(7)
counter = 0
const BOX = Ref(0)
scaled(x::Int32) = x * SCALE
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
    # each binding as the closed world's world holds it (NirBinding)
    local node(name) = W.NirGlobal(W.nir_binding!(W.NirBindings(g.translator.component.world), GlobalRef(GlobalCases, name)))
    local e = rejection(() -> D.translate_expression(g, node(:SCALE), IR.NumType_i32))
    @test e.rejection isa W.Unported && occursin("Translator.constants", e.rejection.anchor)
    # a binding's operand whose value an assignment can change has a static type only its getter knows,
    # located at the getter; a constant binding's type is its value's, mutable or not
    @test occursin("_generateGetter", rejection(() -> D.dart_type_of(g, node(:counter))).rejection.anchor)
    @test D.dart_type_of(g, node(:BOX)) === Base.RefValue{Int64}
    # a function's binding as an operand, `abs` passed to callf, is Kernel's StaticTearOff, the
    # function's singleton constant: run by node against native
    local tb = W.compile(GlobalCases.tear, (Int32,); optimize = false)
    queue_native!("tear", tb, GlobalCases.tear, [(x,) for x in Int32[-3, 0, 5, typemin(Int32)]])
end

# a binding a load can change (globals.dart's lazy arm): a read calls its implicit getter, which runs
# its initializer, the binding's session value, on the first read; a write calls its implicit setter.
# Each module starts from the value compiled in, so every native answer is computed from that value
module LazyGlobalCases
global total::Int = 5
peek(x::Int) = total + x
@noinline put!(x::Int) = (global total = x; nothing)
setpeek(x::Int) = (put!(x * 3); total + 1)
end
@testset "code_generator.dart: a lazy static field, read through its getter and written through its setter" begin
    local pb = W.compile(LazyGlobalCases.peek, (Int,); optimize = false)
    local sb = W.compile(LazyGlobalCases.setpeek, (Int,); optimize = false)
    # the session value, before any native write below changes it
    queue_native!("peek ", pb, LazyGlobalCases.peek, [(1,), (-7,)])
    queue_native!("setpeek ", sb, LazyGlobalCases.setpeek, [(2,), (-4,)])
    # a const binding of a mutable Ref is read through its getter, its value the session's
    @test Main.CodegenInitOnceCases.seen[] == 1
    queue_native!("read_seen ", W.compile(Main.CodegenInitOnceCases.read_seen, (Int,); optimize = false), Main.CodegenInitOnceCases.read_seen, [(1,), (-3,)])
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTChild.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end

end
