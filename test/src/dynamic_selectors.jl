# dart2wasm's DynamicDispatchTable.dynamicSelectors (dynamic_dispatch_table.dart:42), mirrored as one
# late field build assigns, which the dynamic dispatchers read (dynamic_dispatchers.dart:251, :316),
# and the KernelNodes members those dispatchers call, each a located rejection while its runtime
# definition is not ported.
module DynamicSelectorsTest

using Test
using WasmTarget

const DD = WasmTarget.Dart2Wasm
const W = WasmTarget.WasmBuilder

module Cases
struct Holder; x::Int; end
k(h::Holder) = h.x + 1
end

caught(f) = try; f(); nothing; catch x; x; end
rejected(f, kind) = (e = caught(f); e isa WasmTarget.RejectionError && e.rejection isa kind)

@testset "dynamic_dispatch_table.dart: dynamicSelectors, assigned by build" begin
    local data = DD.build_module_output_data(DD.DefaultModuleStrategy(DD.WasmCompilerOptions_default_options()))
    local t = DD.Translator(WasmTarget.build_nir(WasmTarget.check_subset(Cases.k, (Cases.Holder,), "dynamic_selectors", Base.get_world_counter()), "test"), data, DD.TranslatorOptions())
    DD._init_modules(t, nothing)
    collect(DD.ClassInfoCollector(t))
    local ddt = t.dynamic_dispatch_table[]
    # dart's late field: read before build assigns it, a located rejection naming its line
    local e = caught(() -> ddt.dynamic_selectors[])
    @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Unported &&
          occursin("dynamic_dispatch_table.dart:42 DynamicDispatchTable.dynamicSelectors", e.rejection.anchor)
    # build assigns the empty map, then makes a selector per collected shape: none in a Julia program
    DD.build(ddt, DD.DynamicCallSiteCollector_collect(t.component))
    @test ddt.dynamic_selectors[] isa DD.LinkedHashMap{DD.CallShape,DD.DynamicSelector} && isempty(ddt.dynamic_selectors[])
    # late final: a second build assigns it twice, Internal
    @test rejected(() -> DD.build(ddt, Set{DD.CallShape}()), WasmTarget.Internal)
    # a shape is the collector's error: build assigns the map and rejects at dart's loop
    local ddt2 = DD.DynamicDispatchTable(t)
    @test rejected(() -> DD.build(ddt2, Set{DD.CallShape}([DD.GetterCallShape(:f)])), WasmTarget.Internal)
    @test isempty(ddt2.dynamic_selectors[])

    # the dispatchers read the map: no selector for a shape, so neither table call is emitted
    local m = DD.main_module(t)
    local fb = W.define(m.functions[], W.define_function(m.types[], W.IR.ValueType[], W.IR.ValueType[]), "dispatcher")
    local shape = DD.MethodCallShape(:f, 0, 1, Symbol[])
    local g = DD._DynamicDispatcherCodeGenerator(t, shape, fb)
    local b = W.body(fb)
    local nsm = W.block(b)
    local class_id = W.add_local(b, W.IR.NumType_i32)
    local receiver = W.add_local(b, W.IR.NumType_i32)
    @test DD._emit_dynamic_dispatch_table_call(g, b, shape, class_id, receiver, _ -> nothing, nsm) === nothing
    @test DD._emit_dynamic_dispatch_table_call_via_field(g, b, shape, class_id, receiver, receiver, nsm) === nothing
end

@testset "kernel_nodes.dart: the dynamic dispatchers' runtime members, unported" begin
    local data = DD.build_module_output_data(DD.DefaultModuleStrategy(DD.WasmCompilerOptions_default_options()))
    local t = DD.Translator(WasmTarget.build_nir(WasmTarget.check_subset(Cases.k, (Cases.Holder,), "dynamic_selectors", Base.get_world_counter()), "test"), data, DD.TranslatorOptions())
    for (f, anchor) in ((DD.function_type_class, "common/type.dart:413 _FunctionType"),
                        (DD.function_type_type_parameter_defaults_field, "common/type.dart:422 _FunctionType.typeParameterDefaults"),
                        (DD.invoke_no_such_method, "common/object_patch.dart:66 Object._invokeNoSuchMethod"),
                        (DD.invocation_getter_factory, "core/invocation.dart:49 Invocation.getter"),
                        (DD.invocation_setter_factory, "core/invocation.dart:60 Invocation.setter"),
                        (DD.check_closure_shape, "common/type.dart:1772 _checkClosureShape"),
                        (DD.check_closure_type, "common/type.dart:1855 _checkClosureType"))
        local e = caught(() -> f(t))
        @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Unported && endswith(e.rejection.anchor, anchor)
    end
    # the Symbols field is read as a field: dart's symbols.getterSymbolFromName
    @test DD.getter_symbol_from_name(t.symbols, :x) === :x && DD.setter_symbol_from_name(t.symbols, :x) === Symbol("x=")
end

end
