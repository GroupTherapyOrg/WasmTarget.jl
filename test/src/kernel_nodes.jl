# dart2wasm's kernel_nodes.dart, ported (src/kernel_nodes.jl): the classes and procedures of dart's
# runtime library the compiler names. Each is a definition of the sdk at the pin, not ported, so each
# rejects Unported naming it, the target's patch where the target chooses one.

module KernelNodesTest

using Test
using WasmTarget

const W = WasmTarget
const D = WasmTarget.Dart2Wasm

f(x::Int) = x + 1

@testset "kernel_nodes.dart: the runtime's classes and procedures, Unported at the sdk" begin
    local world = W.build_nir(W.check_subset(f, (Int,), "kernel_nodes"), "kernel_nodes")
    local data() = D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options()))
    local js = D.Translator(world, data(), D.TranslatorOptions())
    local standalone = D.Translator(world, data(), D.TranslatorOptions(; standalone = true))
    local anchor(f, t) = (e = try; f(t); nothing; catch x; x; end; e isa W.RejectionError && e.rejection isa W.Unported ? e.rejection.anchor : e)
    @test anchor(D.list_base_class, js) == "sdk/lib/_internal/wasm/common/list.dart:15 WasmListBase"
    @test anchor(D.immutable_list_class, js) == "sdk/lib/_internal/wasm/common/list.dart:290 ImmutableList"
    @test anchor(D.throw_wasm_ref_error, js) == "sdk/lib/_internal/wasm/common/errors_patch.dart:87 _TypeError._throwWasmRefError"
    @test anchor(D.embedder_string_from_char_code_array, standalone) == "sdk/lib/_internal/wasm/standalone/embedder.dart:62 stringFromCharCodeArray"
    @test anchor(D.embedder_string_from_ascii_bytes, standalone) == "sdk/lib/_internal/wasm/standalone/embedder.dart:71 stringFromAsciiBytes"
    # the target's patch: standalone or JS
    @test anchor(D.stack_trace_current, js) == "sdk/lib/_internal/wasm/js_common/stack_trace_patch.dart:13 StackTrace.current"
    @test anchor(D.stack_trace_current, standalone) == "sdk/lib/_internal/wasm/standalone/stack_trace_patch.dart:15 StackTrace.current"
    @test anchor(D.print_to_console, js) == "sdk/lib/_internal/wasm/js_common/print_patch.dart:8 printToConsole"
    @test anchor(D.print_to_console, standalone) == "sdk/lib/_internal/wasm/standalone/print_patch.dart:9 printToConsole"
    @test D._string_impl_class_name(js) == "JSStringImpl" && D._string_impl_class_name(standalone) == "EmbedderStringImpl"
    # each anchor names a line of the pinned sdk that declares it
    local sdk = W._pin_sdk()
    if sdk !== nothing
        for (fn, t) in ((D.list_base_class, js), (D.immutable_list_class, js), (D.throw_wasm_ref_error, js), (D.embedder_string_from_char_code_array, standalone),
                        (D.embedder_string_from_ascii_bytes, standalone), (D.stack_trace_current, js), (D.stack_trace_current, standalone),
                        (D.print_to_console, js), (D.print_to_console, standalone))
            local a = anchor(fn, t)
            local (path, rest) = split(a, ':'; limit = 2)
            local (line, name) = split(rest, ' '; limit = 2)
            local text = readlines(joinpath(sdk, path))[parse(Int, line)]
            @test occursin(last(split(name, '.')), text)
        end
    end
end

end
