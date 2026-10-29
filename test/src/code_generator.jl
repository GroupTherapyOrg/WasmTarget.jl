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
        elseif st isa Union{W.NirCall, W.NirInvoke, W.NirNew, W.NirGlobalRead}
            # a used value is a local declared with its initializer; an unused one an expression statement
            @test r.rejection isa W.Unported && occursin("AstCodeGenerator.b", r.rejection.anchor)
            # the unused one is translated at the void marker: its expression's own visitor, which
            # stops at the first piece not yet given here (a constant, a parameter, an allocation)
            local r2 = rejection(() -> D.translate_statement(g, st, nothing))
            @test r2 isa W.RejectionError && !occursin("voidMarker", string(r2.rejection))
        elseif st isa Union{W.NirForeignCall, W.NirCFunction}
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
    local e = rejection(() -> D.translate_expression(g, W.NirGlobal(GlobalRef(GlobalCases, :SCALE)), IR.NumType_i32))
    @test e.rejection isa W.Unported && occursin("Translator.constants", e.rejection.anchor)
    # a binding's operand whose value an assignment can change has a static type only its getter knows,
    # located at the getter; a constant binding's type is its value's, mutable or not
    @test occursin("_generateGetter", rejection(() -> D.dart_type_of(g, W.NirGlobal(GlobalRef(GlobalCases, :counter)))).rejection.anchor)
    @test D.dart_type_of(g, W.NirGlobal(GlobalRef(GlobalCases, :BOX))) === Base.RefValue{Int64}
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

module ThrowCases
struct E; v::Int64; end
thr(x::Int64) = x < 0 ? throw(E(x)) : x
# Julia throws any value, an Int too
thr_int(x::Int64) = x < 0 ? throw(x) : x
# Base's conversion throws InexactError through Base's own throw_inexacterror, a Core.throw
to_u8(x::Int64) = Int64(UInt8(x))
end

@testset "code_generator.dart: an unresolved call and a field outside the layout reject at their rows" begin
    local g = codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    # a generic call Julia left unresolved (the trim verifier's must-throw warning) is Julia's
    # MethodError throw, never dart's dynamic invocation: rejected at the throw's port, not at the
    # intrinsifier's
    local e = rejection(() -> D.visit_static_invocation(g, W.NirCall(W.NirValue[W.NirConst(Core.Const(sin)), W.NirArgument(2)]), IR.NumType_f64))
    @test e.rejection isa W.Unquarantined && occursin("src/julia/runtime/rtutils.jl", e.rejection.row) && occursin("proved throws", e.at)
    # a definition only a node Julia has no counterpart for reaches rejects by its Kernel row: Internal at
    # the definition, naming the row and its reason, the one source of that text
    local k = rejection(() -> W.no_counterpart_rejection("Let", "dart2wasm/lib/code_generator.dart:1603 AstCodeGenerator.visitLet", "at"))
    @test k.rejection isa W.Internal && occursin("AstCodeGenerator.visitLet: the Kernel table's Let row, no counterpart", k.rejection.site) &&
          occursin("visit_block", k.rejection.site)
    @test rejection(() -> W.no_counterpart_rejection("ReturnStatement", "a", "b")).rejection isa W.Internal
    # Julia's throw(x), Kernel's Throw: the exception, then the runtime's thrower, which throws it with
    # the program's tag: a wasm exception, never a trap, and native's answer where nothing is thrown
    for (f, x, T) in ((ThrowCases.thr, -1, ThrowCases.E), (ThrowCases.thr_int, -2, Int))
        @test (try; f(x); nothing; catch err; err; end) isa T
        local bytes = W.compile(f, (Int64,); optimize = false)
        push!(NATIVE_RUNS, WTRunner.RunCase("$(nameof(f))($x) throws ", bytes, (x,), WTRunner.Throws(T)))
        queue_native!("$(nameof(f)) ", bytes, f, [(7,)])
    end
    # Base's InexactError is built by its varargs constructor, InexactError(f, args...), whose trailing
    # Vararg has no argument count yet: a located rejection at the function type, never a MethodError
    @test (try; ThrowCases.to_u8(300); nothing; catch err; err; end) isa InexactError
    local iv = rejection(() -> W.compile(ThrowCases.to_u8, (Int64,); optimize = false))
    @test iv.rejection isa W.Unquarantined && occursin("Vararg signature", iv.rejection.row)
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
            # located; a Core.Box's contents::Any admits `nothing`, so its undefined state would share the
            # null: the allocation rejects, never a null a later read takes for `nothing` (D9)
            @test !isempty(e.at)
            occursin("left undefined", sprint(showerror, e)) &&
                @test e.rejection isa W.Unquarantined && occursin("share the null", e.rejection.row)
            nothing
        end
        bytes === nothing || queue_native!("$(nameof(f)) ", bytes, f, [(3,), (0,)])
    end
end

# a struct whose constructor leaves a reference field undefined: Julia's NULL, read as UndefRefError
module UndefFieldCases
mutable struct Node
    v::Int
    next::Node
    Node(v::Int) = new(v)
end
linked(x::Int) = (n = Node(x); n.next = Node(x + 1); n.next.v)
unlinked(x::Int) = Node(x).next.v
end
@testset "code_generator.dart: a field an allocation leaves undefined, null until set, its read Julia's UndefRefError" begin
    @test Core.Compiler.datatype_min_ninitialized(UndefFieldCases.Node) == 1
    # set before it is read: the value; read while undefined: UndefRefError, a wasm exception, never a trap
    queue_native!("linked ", W.compile(UndefFieldCases.linked, (Int,); optimize = false), UndefFieldCases.linked, [(4,), (-1,)])
    @test (try; UndefFieldCases.unlinked(4); nothing; catch err; err; end) isa UndefRefError
    push!(NATIVE_RUNS, WTRunner.RunCase("unlinked(4) throws ", W.compile(UndefFieldCases.unlinked, (Int,); optimize = false), (4,), WTRunner.Throws(UndefRefError)))
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
                     (D.ConstructorBodyCodeGenerator, (:member,)),
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
struct BoxCell; x::Int; end
global counter::Int = 7
global box::Base.RefValue{Int} = Ref(1)
bump(x::Int) = counter + box[] + x
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

@testset "code_generator.dart: unimplemented is never reached, every NIR form has its visitor" begin
    local t = static_field_translator()
    local counter = GlobalRef(StaticFieldCases, :counter)
    local g = static_field_codegen(D.StaticFieldInitializerCodeGenerator, t, D.get_function_type(t.functions[], D.FieldReference(counter, D.FieldReferenceKind_initializer)))
    # the closed NIR sums are matched @exhaustive by the code generator, so no form falls to a default
    @test any(m -> m[1] === D && m[2] === :NirValue, WasmTarget.MATCHES) && any(m -> m[1] === D && m[2] === :NirStmt, WasmTarget.MATCHES)
    # reaching dart's default is WasmTarget's defect, Internal and located, never a trap in the module
    local e = rejection(() -> D.default_expression(g, WasmTarget.NirConst(Core.Const(1)), W.WasmBuilder.IR.NumType_i64))
    @test e.rejection isa W.Internal && occursin("AstCodeGenerator.unimplemented", e.rejection.site) && occursin("@exhaustive", e.rejection.site)
end

@testset "code_generator.dart: a static field's initializer function" begin
    local t = static_field_translator()
    local counter = GlobalRef(StaticFieldCases, :counter)
    local init_ref = D.FieldReference(counter, D.FieldReferenceKind_initializer)
    local ftype = D.get_function_type(t.functions[], init_ref)
    # the field's initializer reference: getMemberCodeGenerator gives its generator
    local mb = D.main_module(t)
    local gm = D.get_member_code_generator(t, W.WasmBuilder.define(mb.functions[], ftype, "init"), init_ref)
    @test gm isa D.StaticFieldInitializerCodeGenerator && gm.field === counter && gm.enclosing_member === init_ref
    # the lazy arm's definition (a mutable global and its flag, made through FunctionCollector.getFunction):
    # the body writes the binding's session value, tees it, sets the flag and returns the value
    local g = static_field_codegen(D.StaticFieldInitializerCodeGenerator, t, ftype)
    @test emitted_by(() -> D.generate_internal(g), g) ==
          ["i64.const 7", "local.tee", "global.set", "local.get", "i32.const 1", "global.set", "end"]
    @test D.get_existing_function(t.functions[], init_ref) !== nothing
end

@testset "code_generator.dart: a static field's eager initializer, a type of no value" begin
    # dart makes it only for a field the startup pragma marks, which no Julia binding carries
    # (DartGlobals._initializeAtStartup answers no): the constructor and the struct reject Internal
    local t = static_field_translator()
    local counter = GlobalRef(StaticFieldCases, :counter)
    local gl = W.WasmBuilder.define(D.main_module(t).globals[], IR.GlobalType(D.translate_type_of_field(t, counter); mutable = true), "counter")
    @test !D._initialize_at_startup(t.dart_globals[], counter)
    local e = rejection(() -> D.EagerStaticFieldInitializerCodeGenerator(t, counter, gl))
    @test e.rejection isa W.Internal && occursin("startup pragma", e.rejection.site)
    @test rejection(() -> D.EagerStaticFieldInitializerCodeGenerator(Val(:_))).rejection isa W.Internal
end

@testset "code_generator.dart: a static field's implicit getter and setter" begin
    local B = W.WasmBuilder
    local t = static_field_translator()
    local mb = D.main_module(t)
    local dg = t.dart_globals[]
    local fc = t.functions[]
    local counter = GlobalRef(StaticFieldCases, :counter)
    local box = GlobalRef(StaticFieldCases, :box)
    local ty = D.translate_type_of_field(t, counter)
    local getter = IR.FunctionType(IR.ValueType[], IR.ValueType[ty])
    local acc(f, ftype, is_getter) = begin
        local fb = B.define(mb.functions[], ftype, "acc")
        local g = D.StaticFieldImplicitAccessorCodeGenerator(t, ftype, f, is_getter)
        g.b[] = B.body(fb); g.param_locals[] = B.locals(fb); g.return_label[] = nothing
        g
    end
    local g0 = acc(counter, getter, true)
    @test g0.enclosing_member === D.FieldReference(counter, D.FieldReferenceKind_getter) && g0.is_implicit_getter
    # the lazy arm's definition, made through getFunction in a translator of its own: an explicit flag
    # picks the global or the initializer's call
    let t0 = static_field_translator(), fb = B.define(D.main_module(t0).functions[], getter, "acc0"),
        g = D.StaticFieldImplicitAccessorCodeGenerator(t0, getter, counter, true)
        g.b[] = B.body(fb); g.param_locals[] = B.locals(fb); g.return_label[] = nothing
        @test emitted_by(() -> D.generate_internal(g), g) == ["global.get", "if", "global.get", "else", "call", "end", "end"]
        @test D.get_existing_function(t0.functions[], D.FieldReference(counter, D.FieldReferenceKind_initializer)) !== nothing
    end
    # a field with no initializer function is read and returned
    dg._definitions[counter] = D._define_global_based_field(dg, counter, ty, mb, true, nothing, nothing)
    local g1 = acc(counter, getter, true)
    @test emitted_by(() -> D.generate_internal(g1), g1) == ["global.get", "end"]
    # with its initializer function and an explicit flag: the flag picks the global or the initializer
    local flag = D._define_initializer_flag(dg, counter, mb)
    dg._definitions[counter] = D._define_global_based_field(dg, counter, ty, mb, true, nothing, flag)
    fc._functions[D.FieldReference(counter, D.FieldReferenceKind_initializer)] = B.define(mb.functions[], getter, "counter field initializer")
    local g2 = acc(counter, getter, true)
    @test emitted_by(() -> D.generate_internal(g2), g2) == ["global.get", "if", "global.get", "else", "call", "end", "end"]
    # the setter writes its parameter and sets the flag
    local g3 = acc(counter, IR.FunctionType(IR.ValueType[ty], IR.ValueType[]), false)
    @test emitted_by(() -> D.generate_internal(g3), g3) == ["local.get", "global.set", "i32.const 1", "global.set", "end"]
    # a reference field null when uninitialized: the read, branched past the initializer's call when
    # non-null
    local rty = D.translate_type_of_field(t, box)
    @test rty isa IR.RefType && !rty.nullable
    dg._definitions[box] = D._define_global_based_field(dg, box, B.with_nullability(rty, true), mb, true, nothing, nothing)
    local rgetter = IR.FunctionType(IR.ValueType[], IR.ValueType[rty])
    fc._functions[D.FieldReference(box, D.FieldReferenceKind_initializer)] = B.define(mb.functions[], rgetter, "box field initializer")
    local g4 = acc(box, rgetter, true)
    @test emitted_by(() -> D.generate_internal(g4), g4) == ["block", "global.get", "br_on_non_null", "call", "end", "end"]
end

@testset "the Kernel table's Reference: a member's MethodInstance or a field's accessor" begin
    local B = W.WasmBuilder
    local t = static_field_translator()
    local fc = t.functions[]
    local counter = GlobalRef(StaticFieldCases, :counter)
    local ty = D.translate_type_of_field(t, counter)
    local getter = D.FieldReference(counter, D.FieldReferenceKind_getter)
    local setter = D.FieldReference(counter, D.FieldReferenceKind_setter)
    # a field's reference compares by its field and kind, as dart's Reference by identity
    @test getter == D.FieldReference(counter, D.FieldReferenceKind_getter) && getter != setter
    # an instance field has no initializer reference: the pair cannot be made
    local cf = W.ClassField(StaticFieldCases.BoxCell, 0, "x", Int, false)
    @test rejection(() -> D.FieldReference(cf, D.FieldReferenceKind_initializer)).rejection isa W.Internal
    # a static field's getter takes nothing and returns the field; its setter takes it and returns nothing
    local fg = D.get_function_type(fc, getter); local fs = D.get_function_type(fc, setter)
    @test isempty(fg.inputs) && fg.outputs == [ty] && fs.inputs == [ty] && isempty(fs.outputs)
    @test D.get_function_name(fc, getter) == "$counter implicit getter" && D.get_function_name(fc, setter) == "$counter= implicit setter"
    @test D.synthesize_null_return_value(fc, setter) && !D.synthesize_null_return_value(fc, getter) && !D.synthesize_no_return(fc, getter)
    # getMemberCodeGenerator gives each accessor its generator
    local mb = D.main_module(t)
    local gg = D.get_member_code_generator(t, B.define(mb.functions[], D.get_function_type(fc, getter), "g"), getter)
    @test gg isa D.StaticFieldImplicitAccessorCodeGenerator && gg.is_implicit_getter
    local gs = D.get_member_code_generator(t, B.define(mb.functions[], D.get_function_type(fc, setter), "s"), setter)
    @test gs isa D.StaticFieldImplicitAccessorCodeGenerator && !gs.is_implicit_getter
end

@testset "code_generator.dart: an instance field's implicit getter and setter, a field selector's target" begin
    local B = W.WasmBuilder
    local t = translator_of(SetGenCases.seta, (SetGenCases.M, Int32))
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    local fc = t.functions[]
    local mb = D.main_module(t)
    local cf = W.class_instance_fields(SetGenCases.M, "test")[1]
    @test cf.name == "a" && cf.type === Int32
    local getter = D.FieldReference(cf, D.FieldReferenceKind_getter)
    local setter = D.FieldReference(cf, D.FieldReferenceKind_setter)
    local this_type = D.translate_type(t, SetGenCases.M)
    # the getter takes its class's reference and returns the field; the setter takes the value too
    local fg = D.get_function_type(fc, getter); local fs = D.get_function_type(fc, setter)
    @test fg.inputs == [this_type] && fg.outputs == [IR.NumType_i32]
    @test fs.inputs == [this_type, IR.NumType_i32] && isempty(fs.outputs)
    @test D.get_function_name(fc, getter) == "$(SetGenCases.M).a implicit getter"
    local acc(r, ftype) = begin
        local fb = B.define(mb.functions[], ftype, "acc")
        local g = D.get_member_code_generator(t, fb, r)
        g.b[] = B.body(fb); g.param_locals[] = B.locals(fb); g.return_label[] = nothing
        g
    end
    local gg = acc(getter, fg)
    @test gg isa D.ImplicitFieldAccessorCodeGenerator && gg.is_implicit_getter && !gg.use_unchecked_entry && gg.enclosing_member === getter
    @test emitted_by(() -> D.generate_internal(gg), gg) == ["local.get", "struct.get", "end"]
    local gs = acc(setter, fs)
    @test emitted_by(() -> D.generate_internal(gs), gs) == ["local.get", "local.get", "struct.set", "end"]
    @test gs.this_local === gs.param_locals[][1]
end

@testset "code_generator.dart: guardCanMatchJSException" begin
    # outside standalone mode a guard catches JS exceptions only when every value passes it, Julia's Any
    local t = translator_of(CodegenCases.f_add, (Int32,))
    @test !t.options.standalone
    @test D.guard_can_match_js_exception(t, Any)
    @test !D.guard_can_match_js_exception(t, Exception) && !D.guard_can_match_js_exception(t, TypeVar(:T))
    # standalone mode has no JS exceptions: no guard catches one
    local ts = D.Translator(WasmTarget.build_nir(W.check_subset(CodegenCases.f_add, (Int32,), "code_generator"), "test"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions(; standalone = true))
    @test !D.guard_can_match_js_exception(ts, Any)
end

# Base's fallback == is Julia's egal: identity for two mutable objects, content for immutable values (audit #56)
module FallbackEqualsCases
struct Q; x::Int; end
mutable struct M; x::Int; end
@noinline same_q(a::Int) = Q(a) == Q(a)
@noinline same_m(a::Int) = M(a) == M(a)
@noinline self_m(a::Int) = (m = M(a); m == m)
end
@testset "Base's fallback == over immutable and mutable operands, never a wrong answer" begin
    for f in (FallbackEqualsCases.same_q, FallbackEqualsCases.same_m, FallbackEqualsCases.self_m)
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

# a constructor's callee is a type object, Type{C}: Julia passes it as a constant (isconstType), so it is no
# parameter and no `this` (src/julia/nir.jl nir_carries_data), as a function's singleton callee is none
module CtorThisCases
struct Plain; x::Int; end
struct Para{T}; x::Int; end
end
@testset "a constructor's Type{C} callee carries no data" begin
    @test !WasmTarget.nir_carries_data(Type{CtorThisCases.Plain})
    @test !WasmTarget.nir_carries_data(Type{CtorThisCases.Para{String}})
    @test !WasmTarget.nir_carries_data(typeof(sin))
    @test WasmTarget.nir_carries_data(CtorThisCases.Plain)
    @test WasmTarget.nir_carries_data(Type)   # an unknown type object is a value at run time
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTRunner.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end

end
