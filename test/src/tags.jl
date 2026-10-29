# tags.dart (src/tags.jl): the one tag every Julia exception is thrown and caught with, its payload the
# exception object (the top type without its null, the lead's ruling; dart's StackTrace a located gap),
# defined once in the main module; and the JS tag, imported from WebAssembly.JSTag by a JS host alone.

module TagsTest

using Test
using WasmTarget

const WT = WasmTarget
const D = WT.Dart2Wasm
const IR = WT.WasmBuilder.IR

module Cases
f(x::Int) = x + 1
end

translator(standalone) = D.Translator(WasmTarget.build_nir(WT.check_subset(Cases.f, (Int,), "tags"), "test"),
    D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions(; standalone))

@testset "ExceptionTags" begin
    local t = translator(false)
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    local tags = D.ExceptionTags(t)
    local main = D.main_module(t)
    local tag = D.get_dart_exception_tag(tags, main)
    @test tag.type.inputs == [t.top_type_non_nullable[]] && isempty(tag.type.outputs)
    @test D.get_dart_exception_tag(tags, main) === tag                  # defined once, on first read
    @test tag in main.tags[]._defined
    local js = D.get_js_exception_tag(tags, main)
    @test js isa IR.ImportedTag && js.module_ == "WebAssembly" && js.name == "JSTag"
    @test js.type.inputs == [IR.RefType_extern(nullable = true)] && isempty(js.type.outputs)

    local ts = translator(true)
    D._init_modules(ts, nothing)
    collect(D.ClassInfoCollector(ts))
    local e = try; D.get_js_exception_tag(D.ExceptionTags(ts), D.main_module(ts)); nothing; catch x; x; end
    @test e isa WT.RejectionError && e.rejection isa WT.Internal                # a standalone module imports no JS tag
end

end # module TagsTest
