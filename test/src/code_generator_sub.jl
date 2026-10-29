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
let t = D.Translator(WasmTarget.build_nir(W.check_subset(is_int, (Base.RefValue{Any},), "code_generator_sub"), "test"),
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


@testset "code_generator.dart: _VirtualCallKind" begin
    @test [sprint(show, k) for k in instances(D._VirtualCallKind)] == ["get", "set", "call"]
    @test D.is_getter(D._VirtualCallKind_Get) && !D.is_getter(D._VirtualCallKind_Call)
    @test D.is_setter(D._VirtualCallKind_Set) && !D.is_setter(D._VirtualCallKind_Get)
end

end
