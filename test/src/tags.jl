# tags.dart (src/tags.jl): the one tag every Julia exception is thrown and caught with, its payload the
# exception object (the top type without its null) and its stack trace (the standalone runtime's
# _EmbedderStackTrace), defined once in the main module; and the JS tag, imported from WebAssembly.JSTag
# by a JS host alone.

module TagsTest

using Test
using WasmTarget

const WT = WasmTarget
const D = WT.Dart2Wasm
const IR = WT.WasmBuilder.IR

module Cases
f(x::Int) = x + 1
g(x::Int) = x < 0 ? throw(DomainError(x)) : x
end

function translator(standalone, p = Cases.f)
    local t = D.Translator(WasmTarget.build_nir(WT.check_subset(p, (Int,), "tags"), "test"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions(; standalone))
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    return t
end

@testset "ExceptionTags" begin
    # a standalone module that throws: the tag takes the exception and its stack trace, the standalone
    # runtime's _EmbedderStackTrace
    local ts = translator(true, Cases.g)
    local tags = D.ExceptionTags(ts)
    local main = D.main_module(ts)
    local tag = D.get_dart_exception_tag(tags, main)
    @test ts.stack_trace_info[].cls === WT.Runtime._EmbedderStackTrace && !ts.stack_trace_type[].nullable
    @test tag.type.inputs == [ts.top_type_non_nullable[], ts.stack_trace_type[]] && isempty(tag.type.outputs)
    @test D.get_dart_exception_tag(tags, main) === tag                  # defined once, on first read
    @test tag in main.tags[]._defined
    # the main module exports it once, under its fixed name, for the host to match a Julia exception by
    local tag_exports = [x for x in main.exports._exports if x isa IR.TagExport]
    @test length(tag_exports) == 1 && only(tag_exports).name == WT.EXCEPTION_TAG_EXPORT && only(tag_exports).tag === tag
    local e = try; D.get_js_exception_tag(tags, main); nothing; catch x; x; end
    @test e isa WT.RejectionError && e.rejection isa WT.Internal                # a standalone module imports no JS tag

    # a JS host's module: the JS tag, imported; its stack trace class, the JS runtime's JavaScriptStack,
    # not ported, so the exception tag rejects there, located
    local t = translator(false)
    local js = D.get_js_exception_tag(D.ExceptionTags(t), D.main_module(t))
    @test js isa IR.ImportedTag && js.module_ == "WebAssembly" && js.name == "JSTag"
    @test js.type.inputs == [IR.RefType_extern(nullable = true)] && isempty(js.type.outputs)
    local r = try; D.get_dart_exception_tag(D.ExceptionTags(t), D.main_module(t)); nothing; catch x; x; end
    @test r isa WT.RejectionError && r.rejection isa WT.Unported && r.rejection.anchor == "sdk/lib/_internal/wasm/js_common/js_helper.dart:830 JavaScriptStack"
end

module Throwing
h(x::Int, y::Int) = div(x, y)
end

@testset "ExceptionTags: a module that throws exports its exception tag, once, under its fixed name" begin
    # a checked division raises DivideError, so its module defines the tag and names it once among its
    # bytes, its export's name; a module with no throw defines no tag and exports none
    local h = WT.compile(Throwing.h, (Int, Int))
    @test count(WT.EXCEPTION_TAG_EXPORT, String(copy(h))) == 1
    @test !occursin(WT.EXCEPTION_TAG_EXPORT, String(copy(WT.compile(Cases.f, (Int,)))))
end

end # module TagsTest
