# dart2wasm's target.dart and wasm_annotations.dart, ported (src/target.jl, src/wasm_annotations.jl):
# the target's configuration on fixed inputs, each expected value dart's own literal.
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm

@testset "target.dart" begin
    local t = D.WasmTarget()
    @test t.mode == D.Mode_regular && t.enable_experimental_ffi && t.enable_experimental_wasm_interop && !t.remove_asserts
    @test t._growable_list === nothing && t._native_classes === nothing
    @test D.name(t) == "wasm" && D.platform_file(t) == "dart2wasm_platform.dill"
    local s = D.WasmTarget(mode = D.Mode_standalone, remove_asserts = true)
    @test D.name(s) == "wasm_standalone" && D.platform_file(s) == "dart2wasm_standalone_platform.dill" && s.remove_asserts
    local j = D.WasmTarget(mode = D.Mode_jsCompatibility)
    @test D.name(j) == "wasm_js_compatibility" && D.platform_file(j) == "dart2wasm_js_compatibility_platform.dill"
    # the libraries: the shared list, then the embedder's or the JS interop's
    @test D.extra_required_libraries(s)[end] == "dart:_embedder" && length(D.extra_required_libraries(s)) == 16
    @test D.extra_required_libraries(t)[end - 3:end] == ["dart:_js_helper", "dart:_js_types", "dart:js_interop", "dart:js_interop_unsafe"]
    @test D.extra_indexed_libraries(t)[1] == "dart:_boxed_bool" && length(D.extra_indexed_libraries(t)) == 14
    @test D.is_supported_pragma(t, "wasm:import") && D.is_supported_pragma(t, "dyn-module:callable") && !D.is_supported_pragma(t, "vm:entry-point")
    @test D.enable_no_such_method_forwarders(t) && D.supports_set_literals(t) && D.supports_file_uri_expression(t)
    @test D.supports_explicit_getter_calls(t) && !D.supports_late_lowering_sentinel(t) && !D.use_static_field_lowering(t)
    @test D.supports_unevaluated_constants(D.constants_backend(t)) && !D.constants_backend(t).keep_locals
    @test D.verification(t) isa D.WasmVerification
    @test D._dart_ffi_and_pragma_allowlist() == ["flutter", "engine", "ui", "package_info_plus", "test", "url_launcher_web"]
    # the record classes are assigned once, by the compile
    local e = try; t.record_classes[]; nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Unported
end

@testset "wasm_annotations.dart" begin
    local m = D.MemoryLimits(min_size = 1)
    @test m.min_size == 1 && m.max_size === nothing
    @test D.MemoryLimits(min_size = 2, max_size = 5).max_size == 5
end
