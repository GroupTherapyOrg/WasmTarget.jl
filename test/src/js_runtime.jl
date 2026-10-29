# dart2wasm's js/runtime_blob.dart and js/runtime_generator.dart, ported (src/js/): the template
# engine, the blob's text against the pinned dart source, and the string helpers, each expected value
# Julia's own (Julia's parser reads dart's JSON string escapes as its own string literals).
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm
const J = WasmTarget.Dart2Wasm.JS

_rejection(f) = try; f(); nothing; catch x; x isa WasmTarget.RejectionError ? x.rejection : rethrow(); end

@testset "js/runtime_blob.dart" begin
    local t = D.Template("a<<X>>b<<Y_Z>><<X>>")
    @test D.instantiate(t, Dict("X" => "1", "Y_Z" => "2")) == "a1b21"
    @test length(t._parts) == 7   # a string part around every variable, empty ones included
    @test D.instantiate(D.Template("no variables <<lower>>"), Dict{String,String}()) == "no variables <<lower>>"
    @test _rejection(() -> D.instantiate(t, Dict("X" => "1"))) isa WasmTarget.Internal
    # the blob's three texts are dart's byte for byte: each instantiates, its variables named, to the
    # pinned file's string with the variables left in place
    local sdk = WasmTarget._pin_sdk()
    if sdk !== nothing
        local src = read(joinpath(sdk, "pkg", "dart2wasm", "lib", "js", "runtime_blob.dart"), String)
        local grab(start, stop) = (i = findfirst(start, src)[end] + 1; src[i:findnext(stop, src, i)[1] - 1])
        local keep(tpl) = Dict(String(m[:varname]) => "<<$(m[:varname])>>" for m in eachmatch(D.Template__template_variable_reg_exp[], grab(tpl...)))
        for (f, tpl) in ((D.js_runtime_blob_template, ("final jsRuntimeBlobTemplate = Template(r'''\n", "''');")),
                         (D.module_loading_helper_template, ("final moduleLoadingHelperTemplate = Template(r'''\n", "''');")))
            @test D.instantiate(f[], keep(tpl)) == grab(tpl...)
        end
        @test D.js_poly_fill_methods() == grab("const String jsPolyFillMethods = r'''\n", "''';")
    end
end

@testset "js/runtime_generator.dart" begin
    for s in ["", "plain", "quote \" and backslash \\", "\b\t\n\f\r", "\x00\x01\x1f", "é ü 中 🎉", "\x7f"]
        local e = J.RuntimeFinalizer_escape(s)
        @test Meta.parse(e) == s
        @test startswith(e, '"') && endswith(e, '"')
    end
    @test J.RuntimeFinalizer_escape("a\x01\x1fb") == "\"a\\u0001\\u001fb\""   # lowercase hex, as dart's hexDigit
    @test J.RuntimeFinalizer_escape("🎉") == "\"🎉\""                          # a surrogate pair kept
    @test J.RuntimeFinalizer_escape(String(['x', Char(0xd800), 'y'])) == "\"x\\ud800y\""   # a lone surrogate escaped
    @test _rejection(() -> J.RuntimeFinalizer_escape(String(UInt8[0x61, 0xff]))) isa WasmTarget.Internal
    @test J._count_leading_spaces("   x ") == 3 && J._count_leading_spaces("") == 0 && J._count_leading_spaces("\tx") == 0
    @test J._unindent_js_code("  (a) => {\n      f(a);\n\n    }  ") == ["(a) => {", "  f(a);", "", "}"]
    @test J._unindent_js_code(" one line ") == ["one line"]
    @test J._unindent_js_code("x\n  \n    y") == ["x", "", "y"]
end

module JSRuntimeGenerate
using Test, WasmTarget
const D = WasmTarget.Dart2Wasm
const J = WasmTarget.Dart2Wasm.JS
isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))
entry(x::Int) = x + 1
@testset "js/runtime_generator.dart: RuntimeFinalizer.generate writes a JS module node parses" begin
    local world = WasmTarget.build_nir(WasmTarget.check_subset(entry, (Int,), "js_runtime"), "js_runtime")
    local f = J.RuntimeFinalizer(D.InteropMemberNamer(world, D.Namer(), D.TranslatorOptions()))
    local node = Main.WTRunner.node_binary()
    @test node !== nothing
    mktempdir() do dir
        # each combination of the string builtin and additional module loading fills every variable of
        # the blob (instantiate rejects one with no value), and node parses the runtime as an ES module
        for (builtin, loading) in ((false, false), (true, false), (false, true), (true, true))
            local js = D.generate(f, "main", Core.MethodInstance[], ["a", "b\"c"], builtin, loading)
            @test occursin("dart2wasm", js) && occursin("builtins: ['js-string']", js)
            local path = joinpath(dir, "runtime_$(builtin)_$(loading).mjs")
            write(path, js)
            @test success(pipeline(`perl -e 'alarm 30; exec @ARGV' $node --check $path`; stderr = devnull))
        end
    end
end
end
