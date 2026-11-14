# dart2wasm's code_generator.dart from getLambdaCodeGenerator (:3502) on, ported (src/code_generator.jl):
# the code generators of tear-offs, forwarders, constructors, fields and lambdas, and the helpers of
# the switch, try and call statements. Each case is a located rejection of its kind, or a module run
# against native Julia (test/runner.jl).

module CodeGeneratorSubTest

using Test
using WasmTarget

const W = WasmTarget
const D = WasmTarget.Dart2Wasm
const B = WasmTarget.WasmBuilder
const IR = WasmTarget.WasmBuilder.IR

isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild

# the rejection `f()` raises, or nothing
rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e : rethrow(); end

# node runs each case's module on its arguments, in one run: whether every answer is native Julia's
function answers_native(cases::Vector{WTChild.RunCase})
    local results = WTChild.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    return all(r -> r.ok, results)
end

@testset "code_generator.dart: the switch family rejects: Julia's IR has no switch statement" begin
    # the one br_table WasmTarget emits is the stackifier's; each definition rejects, naming it
    local none = Dict{Int64,D.NoCounterpart}()
    local mb = B.ModuleBuilder("m", nothing)
    local fb = B.define(mb.functions[], B.define_function(mb.types[], IR.ValueType[IR.NumType_i64], IR.ValueType[]), "f")
    for f in (() -> D.BrTableInfo_build(none, _ -> nothing; min_value = 0, max_value = 4),
              () -> D.BrTableInfo__(0, 4, none, _ -> nothing),
              () -> D.BrTableInfo__is_too_sparse(0, 4, none),
              () -> D.BrTableInfo__range_size(0, 4),
              () -> D.BrTableInfo__minimum_table_occupancy(),
              () -> D.BrTableInfo__max_sparse_size(),
              () -> D.SwitchBackwardJumpInfo(B.locals(fb)[1], B.block(B.body(fb))))
        local e = rejection(f)
        @test e !== nothing && e.rejection isa W.Internal && occursin("stackifier", e.rejection.site)
    end
end


# a program whose closed world holds DataType, the class of a closure's runtime type
is_int(r::Base.RefValue{Any}) = r[] isa Int64

# its translator as translate() leaves it before code: modules, closures and classes collected, the
# globals and constants made; built once for the file's cases
const TRANSLATOR = Ref{Any}()
let t = D.Translator(WasmTarget.build_nir(W.check_subset(is_int, (Base.RefValue{Any},), "code_generator_sub", Base.get_world_counter()), "test"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(t.closure_layouter[]); collect(t.class_info_collector[])
    t.globals[] = D.Globals(t); t.dart_globals[] = D.DartGlobals(t); t.constants[] = D.Constants(t)
    TRANSLATOR[] = t
end

@testset "code_generator.dart: MacroAssembler's closure accessors type as dart documents them" begin
    local t = TRANSLATOR[]
    local layouter = t.closure_layouter[]
    local closure = IR.RefType(layouter.closure_base_struct[]; nullable = false)
    # each accessor's documented signature `[ref _Closure] -> [output]`: the builder, which refuses
    # invalid wasm at the emitting instruction (D10), takes its result as the function's output
    local mb = D.main_module(t)
    for (emit, output) in ((D.emit_instantiation_closure_check, IR.NumType_i32),
                           (D.emit_get_instantiated_closure, layouter.instantiation_context_base_struct[].fields[D.FieldIndex_instantiation_context_inner() + 1].type),
                           (D.emit_tear_off_check, IR.NumType_i32),
                           (D.emit_get_tear_off_receiver, t.top_type_non_nullable[]),
                           (D.emit_get_closure_vtable, layouter.closure_base_struct[].fields[D.FieldIndex_closure_vtable() + 1].type))
        local fb = B.define(mb.functions[], B.define_function(mb.types[], IR.ValueType[closure], IR.ValueType[B.unpacked(output)]), string(emit))
        local b = B.body(fb)
        B.local_get(b, B.locals(fb)[1])
        emit(b, t)
        @test B.var"end"(b) === nothing
    end
end


@testset "code_generator.dart: an invocation stub rejects, Internal: Julia has no noSuchMethod" begin
    local t = TRANSLATOR[]
    local mb = D.main_module(t)
    local shape = D.MethodCallShape(:f, 0, 1, Symbol[])
    local fb = B.define(mb.functions[], B.define_function(mb.types[], IR.ValueType[t.top_type[]], IR.ValueType[t.top_type[]]), "stub")
    local e = rejection(() -> D.generate(D.InvocationCreationStubGenerator(t, shape), B.body(fb), B.locals(fb), nothing))
    @test e.rejection isa W.Internal && occursin("noSuchMethod", e.rejection.site) && occursin("DynamicInvocation row", e.rejection.site)
    local e2 = rejection(() -> D.create_invocation_object(t, B.body(fb), :f, B.locals(fb)[1], B.locals(fb)[1], B.locals(fb)[1]))
    @test e2.rejection isa W.Internal && occursin("createInvocationObject", e2.rejection.site)
end


@testset "code_generator.dart: a generator of a construct Julia replaces rejects at its constructor, Internal" begin
    local t = TRANSLATOR[]
    local mb = D.main_module(t)
    local ft = B.define_function(mb.types[], IR.ValueType[], IR.ValueType[])
    local body = only(nb for nb in t.component if nb.ci.def.def.name === :is_int)
    local mi = body.ci.def
    local field = W.ClassField(Base.RefValue{Any}, 1, "x", Any, true)
    local lambda = D.Lambda__(body, :code_generator_sub, mi, D.Closures(t, mi; find_captures = false), 0)
    for (ctor, why) in ((() -> D.TearOffCodeGenerator(t, ft, mi), "singleton instance"),
                        (() -> D.DynamicForwarderCodeGenerator(t, ft, mi, D.GetterCallShape(:x)), "trim verifier"),
                        (() -> D.ConstructorCodeGeneratorBase(t, ft, mi), "%new"),
                        (() -> D.ConstructorInitializerCodeGenerator(t, ft, mi), "%new"),
                        (() -> D.ConstructorAllocatorCodeGenerator(t, ft, mi), "%new"),
                        (() -> D.ConstructorBodyCodeGenerator(t, ft, mi), "%new"),
                        (() -> D.SynchronousLambdaCodeGenerator(t, lambda), "Closures makes no Lambda"),
                        (() -> D.get_lambda_code_generator(t, lambda), "Closures makes no Lambda"),
                        (() -> D.UnreachableCodeGenerator(t, ft, mi), "cyclic"))
        local e = rejection(ctor)
        @test e !== nothing && e.rejection isa W.Internal && occursin(why, e.rejection.site)
    end
    # an instance field's accessor is a field selector's target (_virtualCall), a generator of its own
    @test D.ImplicitFieldAccessorCodeGenerator(t, ft, field, true, false) isa D.ImplicitFieldAccessorCodeGenerator
end


@testset "code_generator.dart: the suspend-state helpers reject, Internal: tasks are out of scope" begin
    local mi = only(nb for nb in TRANSLATOR[].component if nb.ci.def.def.name === :is_int).ci.def
    local mb = B.ModuleBuilder("m", nothing)
    local fb = B.define(mb.functions[], B.define_function(mb.types[], IR.ValueType[], IR.ValueType[]), "f")
    local e = rejection(() -> D.restore_this_and_context_chain(B.body(fb), D.Context(mi, nothing, true), nothing))
    @test e.rejection isa W.Internal && occursin("AsyncMarker row", e.rejection.site)
end


@testset "code_generator.dart: throwWasmRefError rejects Internal, naming its two unreached callers (A80S5)" begin
    local t = TRANSLATOR[]
    local mi = only(nb for nb in t.component if nb.ci.def.def.name === :is_int).ci.def
    local mb = D.main_module(t)
    local g = D.get_inlinable_member_code_generator(t, B.define_function(mb.types[], IR.ValueType[], IR.ValueType[]), mi)
    local e = rejection(() -> D.throw_wasm_ref_error(g, "a Dart object"))
    @test e.rejection isa W.Internal && occursin("WasmAnyRef.toObject", e.rejection.site) && occursin("WasmFunction.fromFuncRef", e.rejection.site)
end

module UndefBitsCases
# `new` leaving isbits fields undefined: a number and an inline struct, each written before any read
struct P; x::Int; y::Int; end
mutable struct Late; set::Bool; v::Int; p::P; Late() = new(false); end
late(n::Int) = (l = Late(); l.v = n; l.p = P(n, 2n); l.set = true; l.set ? l.v + l.p.y : -1)
end

@testset "code_generator.dart: visitConstructorInvocation, an isbits field `new` leaves undefined is its type's zero bits" begin
    # Julia's frozen undef (emit_new_struct), which any one value refines; the case reads only fields it
    # set, so run by node it answers as native Julia
    local bytes = W.compile(UndefBitsCases.late, (Int,); optimize = false)
    @test answers_native([WTChild.RunCase("late($n)", bytes, (n,), UndefBitsCases.late(n)) for n in (3, -4)])
end

module RunTimeClassCases
# a closure capturing a variable of two types: Julia types the closure by the captured value's type
# (Core._typeof_captured_variable, apply_type), so its `new` names a class only run time knows,
# Union{Type{F{Nothing}}, Type{F{Int64}}}, and the captured value is wider than either case's field
@noinline maybe(x::Int) = x > 0 ? nothing : x
capture(x::Int) = (r = maybe(x); g = () -> r === nothing ? -1 : r::Int; g())
# two captures, one of two classes, the other one: F{A, Int64} or F{B, Int64}
struct A; v::Int; end
struct B; v::Int; end
@noinline pick(x::Int) = x > 0 ? A(x) : B(-x)
two(x::Int) = (p = pick(x); k = 2x; g = () -> p.v + k; g())
# a value of no field type of its class: Julia's `new` written as it is (Expr(:new), the form an inner
# constructor's `new{T}(x)` lowers to after its convert), the class P{Int} or P{Cell} and the value an
# Int, a Cell or nothing, so on a non-positive input jl_new_structv's jl_isa refuses nothing for P{Cell}'s
# field, TypeError(:new, "", Cell, nothing)
struct Cell; v::Int; end
struct P{T}; v::T; end
@eval made(x::Int) = (T = x > 10 ? P{Int} : P{Cell};
                      v = x > 10 ? x : x > 0 ? Cell(x) : nothing;
                      p = $(Expr(:new, :T, :v));
                      p isa P{Int} ? (p::P{Int}).v : (p::P{Cell}).v.v + 100)
raised(x::Int) = try
        made(x)
    catch e
        e isa TypeError || return -1
        local ctx = e.context
        (e.func === :new) + 2 * (ctx isa String && isempty(ctx)) + 4 * (e.expected === Cell) + 8 * (e.got === nothing)
    end
end

@testset "codegen.cpp: a `new` of a class only run time knows is jl_new_structv, split over its classes (visitConstructorInvocation)" begin
    local R = RunTimeClassCases
    # the IR's own `new` takes a type value Julia's inference types as a union of two classes
    local ir = only(Base.code_ircode(R.capture, (Int,)))[1]
    local news = [st for st in ir.stmts.stmt if Meta.isexpr(st, :new)]
    @test length(news) == 1 && length(Base.uniontypes(ir.stmts.type[findfirst(st -> Meta.isexpr(st, :new), ir.stmts.stmt)])) == 2
    # each case's class found by its type value, its values tested against its fields and narrowed; run
    # by node, each path answers as native Julia
    local cases = WTChild.RunCase[]
    # jl_new_structv's raise: native Julia raises TypeError(:new, "", Cell, nothing) on a non-positive input
    local nir = only(Base.code_ircode(R.made, (Int,)))[1]
    local inew = findfirst(i -> Meta.isexpr(nir.stmts.stmt[i], :new) && nir.stmts.type[i] isa Union, eachindex(nir.stmts.stmt))
    @test inew !== nothing && nir.stmts.type[inew] == Union{R.P{Int}, R.P{R.Cell}}
    @test R.raised(-3) == 15 && R.raised(5) == 105 && R.raised(20) == 20
    for (f, xs) in ((R.capture, [3, -4]), (R.two, [5, -6]), (R.raised, [20, 5, -3]))
        local bytes = W.compile(f, (Int,); optimize = false)
        append!(cases, [WTChild.RunCase("$(nameof(f))($x)", bytes, (x,), f(x)) for x in xs])
    end
    @test answers_native(cases)
    # a union member that is no Type{C} of a concrete class rejects at the statement, located
    local t = TRANSLATOR[]
    local e = rejection(() -> D.new_struct_classes(t, Union{Type{R.A}, DataType}, "here"))
    @test e.rejection isa W.Unquarantined && startswith(e.rejection.row, "src/julia: an allocation of a class given as")
    # the classes in the union's own order, the order Julia's union split tests its cases
    local U = Union{Type{R.A}, Type{R.B}}
    @test D.new_struct_classes(t, U, "here") == DataType[m.parameters[1] for m in Base.uniontypes(U)]
end

@testset "code_generator.dart: an instance invocation and an == are never virtual calls: every invoke has its single target" begin
    # visitInstanceInvocation and visitEqualsCall reject Internal where singleTarget is nothing; Julia's
    # invoke names its MethodInstance, so over a closed world every invoke's single target is one
    local t = TRANSLATOR[]
    local invokes = [st for nb in t.component for st in nb.stmts if st isa W.NirInvoke]
    @test !isempty(invokes) && all(st -> D.single_target(t, st) isa Core.MethodInstance, invokes)
end

@testset "code_generator.dart: _VirtualCallKind" begin
    @test [sprint(show, k) for k in instances(D._VirtualCallKind)] == ["get", "set", "call"]
    @test D.is_getter(D._VirtualCallKind_Get) && !D.is_getter(D._VirtualCallKind_Call)
    @test D.is_setter(D._VirtualCallKind_Set) && !D.is_setter(D._VirtualCallKind_Get)
end

module VirtualCases
abstract type S end
struct A <: S; side::Int; tag::Int; end
struct B <: S; tag::Int; side::Int; end
struct Holder; s::S; end
# a field read on a receiver Julia left abstract: the getter selector of `side`, two classes holding it
# at different positions, a call through the dispatch table; its value narrowed back to Int
@noinline read_side(h::Holder) = h.s.side
reads(n::Int) = (r = read_side(Holder(n > 0 ? A(n, 1) : B(2, -n))); r isa Int ? r : -1)
# one class under its abstract type: one range, a direct call of that class's getter
abstract type T end
struct D1 <: T; v::Int; end
struct HolderT; t::T; end
@noinline read_v(h::HolderT) = h.t.v
direct(n::Int) = (r = read_v(HolderT(D1(n))); r isa Int ? r : -1)
# a field write on a receiver Julia left abstract: the setter selector, its value used
abstract type U end
mutable struct M1 <: U; v::Int; end
mutable struct M2 <: U; w::Int; v::Int; end
struct HolderU; u::U; end
@noinline write_v!(h::HolderU, x::Int) = setfield!(h.u, :v, x)
writes(n::Int) = (m = n > 0 ? M1(0) : M2(5, 0); r = write_v!(HolderU(m), 3n); s = m isa M1 ? m.v : (m::M2).v; r isa Int ? r + s : -1)
# a class the receiver admits without the field: Julia's FieldError
struct C <: S; tag::Int; end
missing_side(n::Int) = (r = read_side(Holder(n > 0 ? A(n, 1) : C(n))); r isa Int ? r : -1)
end

@testset "code_generator.dart: _virtualCall, a field access on a receiver Julia left abstract through its selector" begin
    local V = VirtualCases
    # reads: the getter selector's two ranges, the receiver kept in a local and the table called
    # indirectly; writes: the setter selector's, its synthesized null dropped and the value kept;
    # direct: one range, a direct call of D1's getter. Run by node each answers as native Julia
    local cases = WTChild.RunCase[]
    for (f, xs) in ((V.reads, [5, -7]), (V.direct, [4]), (V.writes, [2, -3]))
        local bytes = W.compile(f, (Int,); optimize = false)
        append!(cases, [WTChild.RunCase("$(nameof(f))($x)", bytes, (x,), f(x)) for x in xs])
    end
    @test answers_native(cases)
    # MissingFieldTraps: a class the receiver admits without the field reaches Julia's FieldError, a
    # located rejection at the dispatch table's build
    local e = rejection(() -> W.compile(V.missing_side, (Int,); optimize = false))
    @test e !== nothing && e.rejection isa W.Unquarantined && occursin("FieldError", e.rejection.row)
end

module TypeofCases
# typeof of a value only run time knows: a Union slot holding either member, its type compared by ===
struct ToA end
struct ToB end
struct Slot; x::Union{ToA,ToB}; end
@noinline code_of(s::Slot) = (t = typeof(s.x); (t === ToA ? 1 : 0) + (t === ToB ? 2 : 0))
pick(n::Int) = code_of(Slot(n > 0 ? ToA() : ToB()))
# a slot admitting `nothing`, the null reference: its typeof is Nothing's type, past the table
struct NSlot; x::Union{Nothing,ToA}; end
@noinline code_of_n(s::NSlot) = (t = typeof(s.x); (t === ToA ? 1 : 0) + (t === Nothing ? 2 : 0))
pick_n(n::Int) = code_of_n(NSlot(n > 0 ? ToA() : nothing))
end

@testset "intrinsics.dart: typeof of a value run time knows is Julia's jl_typeof, its class id's entry in jl_to_typeof's table" begin
    # Julia leaves `typeof(s.x)` a builtin call on the Union; each member's type value is its canonical
    # constant, so === answers as native Julia for either member, `nothing` among them
    local cases = WTChild.RunCase[]
    for f in (TypeofCases.pick, TypeofCases.pick_n)
        local bytes = W.compile(f, (Int,); optimize = false)
        append!(cases, [WTChild.RunCase("$(nameof(f))($n)", bytes, (n,), f(n)) for n in (1, -1)])
    end
    @test answers_native(cases)
end

end
