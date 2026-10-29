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

isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))
const WTRunner = Main.WTRunner

# the rejection `f()` raises, or nothing
rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e : rethrow(); end

# node runs each case's module on its arguments, in one run: whether every answer is native Julia's
function answers_native(cases::Vector{WTRunner.RunCase})
    local results = WTRunner.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    return all(r -> r.ok, results)
end

@testset "code_generator.dart: BrTableInfo" begin
    local none = Dict{Int64,D.NoCounterpart}()
    local push = _ -> nothing
    # a table is too sparse past 50 entries under half occupied; up to 50 it is always taken
    @test D.BrTableInfo_build(none, push; min_value = 0, max_value = 49) isa D.BrTableInfo
    @test D.BrTableInfo_build(none, push; min_value = -10, max_value = 40) === nothing
    @test D.range_size(D.BrTableInfo_build(none, push; min_value = -3, max_value = 4)) == 8
    # the private constructor's assert: a sparse table is WasmTarget's own defect, located
    local e = rejection(() -> D.BrTableInfo__(0, 100, none, push))
    @test e.rejection isa W.Internal && occursin("BrTableInfo._", e.rejection.site)
    # the table's index, the switched i64 normalized on min and wrapped to i32, selects the case by a
    # br_table (emitDenseTableBranch); a value outside min..max takes the default; one node run
    local cases = WTRunner.RunCase[]
    for (lo, hi) in ((0, 5), (-3, 4), (7, 12))
        local mb = B.ModuleBuilder("m", nothing)
        local fb = B.define(mb.functions[], B.define_function(mb.types[], IR.ValueType[IR.NumType_i64], IR.ValueType[IR.NumType_i32]), "f")
        local b = B.body(fb)
        local x = B.locals(fb)[1]
        local table = D.BrTableInfo_build(none, l -> B.local_get(b, l); min_value = lo, max_value = hi)
        D.emit_dense_table_branch(b, IR.ValueType[IR.NumType_i32], D.range_size(table),
            () -> D.emit_br_table_expr(table, b, x), i -> B.i32_const(b, i), () -> B.i32_const(b, -1))
        B.var"end"(b)
        B.var"export"(mb.exports, "f", fb)
        local s = B.Serializer(); B.serialize(s, B.build(mb))
        append!(cases, [WTRunner.RunCase("br_table $lo..$hi ($v)", B.data(s), (Int64(v),), lo <= v <= hi ? Int32(v - lo) : Int32(-1)) for v in -6:15])
    end
    @test answers_native(cases)
end


# a program whose closed world holds DataType, the class of a closure's runtime type
is_int(r::Base.RefValue{Any}) = r[] isa Int64

# its translator as translate() leaves it before code: modules, closures and classes collected, the
# globals and constants made; built once for the file's cases
const TRANSLATOR = Ref{Any}()
let t = D.Translator(W.check_subset(is_int, (Base.RefValue{Any},), "code_generator_sub"),
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


@testset "code_generator.dart: an invocation stub gathers its arguments, then rejects: Julia has no noSuchMethod" begin
    local t = TRANSLATOR[]
    local mb = D.main_module(t)
    # the stub of `f(x)` and of `f(x; k)`, each argument a top-type value
    local stub(shape) = begin
        local inputs = IR.ValueType[t.top_type[] for _ in 1:(shape.positional_count + length(shape.named))]
        local fb = B.define(mb.functions[], B.define_function(mb.types[], inputs, IR.ValueType[t.top_type[]]), "stub")
        (D.InvocationCreationStubGenerator(t, shape), fb)
    end
    local (g, fb) = stub(D.MethodCallShape(:f, 0, 1, Symbol[]))
    local e = rejection(() -> D.generate(g, B.body(fb), B.locals(fb), nothing))
    @test e.rejection isa W.Unquarantined && occursin("createInvocationObject", e.rejection.row)
    # a named argument's name is a Symbol constant, whose creation is not ported yet
    local (g2, fb2) = stub(D.MethodCallShape(:f, 0, 1, [:k]))
    local e2 = rejection(() -> D.generate(g2, B.body(fb2), B.locals(fb2), nothing))
    @test e2.rejection isa W.Unported && occursin("visitSymbolConstant", e2.rejection.anchor)
end


@testset "code_generator.dart: a generator of a construct Julia replaces rejects at its constructor, Unquarantined" begin
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
                        (() -> D.ImplicitFieldAccessorCodeGenerator(t, ft, field, true, false), "getfield"),
                        (() -> D.SynchronousLambdaCodeGenerator(t, lambda), "Closures makes no Lambda"),
                        (() -> D.get_lambda_code_generator(t, lambda), "Closures makes no Lambda"),
                        (() -> D.UnreachableCodeGenerator(t, ft, mi), "cyclic"))
        local e = rejection(ctor)
        @test e !== nothing && e.rejection isa W.Unquarantined && occursin(why, e.rejection.row)
    end
end


@testset "code_generator.dart: restoreThisAndContextChain reads `this` and the parents from the innermost context" begin
    local mi = only(nb for nb in TRANSLATOR[].component if nb.ci.def.def.name === :is_int).ci.def
    # an object holding an i32, the outer context holding it as `this`, the inner context its parent
    local mb = B.ModuleBuilder("m", nothing)
    local obj = B.define_struct(mb.types[], "obj"; fields = [IR.FieldType(IR.NumType_i32; mutable = false)], brand = false)
    local outer = D.Context(mi, nothing, true)
    local inner = D.Context(mi, outer, false)
    outer.struct_[] = B.define_struct(mb.types[], "outer"; fields = [IR.FieldType(IR.RefType_def(obj; nullable = true))], brand = false)
    inner.struct_[] = B.define_struct(mb.types[], "inner"; fields = [IR.FieldType(IR.RefType_def(outer.struct_[]; nullable = true))], brand = false)
    local fb = B.define(mb.functions[], B.define_function(mb.types[], IR.ValueType[IR.NumType_i32], IR.ValueType[IR.NumType_i32]), "f")
    local b = B.body(fb)
    inner.current_local = B.add_local(b, IR.RefType_def(inner.struct_[]; nullable = true))
    outer.current_local = B.add_local(b, IR.RefType_def(outer.struct_[]; nullable = true))
    local this = B.add_local(b, IR.RefType_def(obj; nullable = false))
    # inner = inner(outer(obj(x))), then the chain restored from inner alone, and this.x returned
    B.local_get(b, B.locals(fb)[1]); B.struct_new(b, obj); B.struct_new(b, outer.struct_[]); B.struct_new(b, inner.struct_[])
    B.local_set(b, inner.current_local)
    D.restore_this_and_context_chain(b, inner, this)
    B.local_get(b, this); B.struct_get(b, obj, 0)
    B.var"end"(b)
    B.var"export"(mb.exports, "f", fb)
    local s = B.Serializer(); B.serialize(s, B.build(mb))
    @test answers_native([WTRunner.RunCase("restore ($x)", B.data(s), (x,), x) for x in Int32[0, 7, -3]])
    # `this` in a context of a function with no `this` local is WasmTarget's own defect
    @test rejection(() -> D.restore_this_and_context_chain(b, outer, nothing)).rejection isa W.Internal
end


@testset "code_generator.dart: _VirtualCallKind" begin
    @test [sprint(show, k) for k in instances(D._VirtualCallKind)] == ["get", "set", "call"]
    @test D.is_getter(D._VirtualCallKind_Get) && !D.is_getter(D._VirtualCallKind_Call)
    @test D.is_setter(D._VirtualCallKind_Set) && !D.is_setter(D._VirtualCallKind_Get)
end

end
