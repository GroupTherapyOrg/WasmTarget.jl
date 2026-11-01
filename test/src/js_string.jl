# dart's js_string.dart (src/runtime/js_common/js_string.jl): a String's code units made a JS string, its
# UTF-8 widened to UTF-16 as Base.transcode widens it, through the JS string builtin fromCharCodeArray,
# a host import. The oracle is Julia's own transcode(UInt16, ...) of the same bytes.

module JSStringTest

using Test
using WasmTarget

const W = WasmTarget

module Cases
import WasmTarget
const R = WasmTarget.Runtime
# ASCII, two-, three- and four-byte characters, and invalid UTF-8 (a lone continuation byte, a
# truncated sequence)
const TEXT = "héllo, 世界 😀"
const BROKEN = String(UInt8[0x61, 0x80, 0xe4, 0xb8, 0x62, 0xf0, 0x9f])
text() = R.JSStringImpl_from_ascii_bytes(TEXT, 0, ncodeunits(TEXT))
tail() = R.JSStringImpl_from_ascii_bytes(TEXT, 3, ncodeunits(TEXT))
broken() = R.JSStringImpl_from_ascii_bytes(BROKEN, 0, ncodeunits(BROKEN))
empty() = R.JSStringImpl_from_ascii_bytes(TEXT, 2, 2)
end

# the JS string an export returns, as its UTF-16 code units, run with the engine's JS string builtins and
# its imported string constants, as the JS runtime compiles a module (src/js/runtime_blob.jl)
function js_code_units(f)
    local path = tempname() * ".wasm"
    write(path, W.compile(f, ()))
    local name = string(nameof(f))
    local script = "(async () => { const m = await WebAssembly.compile(require('fs').readFileSync(process.argv[1]), {builtins: ['js-string'], importedStringConstants: ''}); " *
        "const i = await WebAssembly.instantiate(m, {}); const s = i.exports.$name(); " *
        "console.log(Array.from({length: s.length}, (_, k) => s.charCodeAt(k)).join(',')); })()"
    local out = readchomp(`node -e $script $path`)
    rm(path)
    return out
end
units(bytes) = join(Int.(transcode(UInt16, collect(bytes))), ",")

@testset "js_string.dart: a String's code units made a JS string, widened as Base.transcode widens them" begin
    @test js_code_units(Cases.text) == units(codeunits(Cases.TEXT))
    @test js_code_units(Cases.tail) == units(codeunits(Cases.TEXT)[4:end])
    @test js_code_units(Cases.broken) == units(codeunits(Cases.BROKEN))
    @test js_code_units(Cases.empty) == ""
end

end

module PrintPatchTest
using Test, WasmTarget
const W = WasmTarget
const D = WasmTarget.Dart2Wasm
const J = WasmTarget.Dart2Wasm.JS
# a program that prints through the JS patch's printToConsole, then answers its argument
said(x::Int64) = (W.Runtime.print_to_console("héllo"); x)
@testset "js_common/print_patch.dart: printToConsole hands its line to the JS runtime's inline JS" begin
    local world = W.build_nir(W.check_subset(said, (Int64,), "print_patch"), "print_patch")
    # the method whose body holds the inline JS: printToConsole's, or its caller's where Julia inlined it
    local mi = only(b.ci.def for b in world if W.nir_js_code(world, b.ci.def) !== nothing)
    @test W.nir_js_code(world, mi) == "s => printToConsole(s)"
    # generateJsMethods writes the method under the name the code generator imports it by
    local namer = D.InteropMemberNamer(world, D.Namer(), D.TranslatorOptions())
    local body = only(b for b in world if b.ci.def === mi)
    local site = W.nir_foreign_import(body, only(st for st in body.stmts if st isa W.NirForeignCall && st.args[1].c.val[2] == "dart2wasm"))
    local name = D.get_import_name(namer._interop_helper_member_namer, site, mi)
    @test name.module_name == "dart2wasm"
    @test D.generate_js_methods(J.RuntimeFinalizer(namer), [mi, mi]) == "      $(name.item_name): s => printToConsole(s),\n"
    # the module imports the inline JS from the interop module, and run with JS's console for the
    # runtime's printToConsole it prints the line and answers 7
    local path = tempname() * ".wasm"
    write(path, W.compile(said, (Int64,)))
    local script = "(async () => { const m = await WebAssembly.compile(require('fs').readFileSync(process.argv[1]), {builtins: ['js-string'], importedStringConstants: ''}); " *
        "const imps = WebAssembly.Module.imports(m).filter(i => i.module === 'dart2wasm'); " *
        "const dart2wasm = Object.fromEntries(imps.map(i => [i.name, s => console.log(s)])); " *
        "const i = await WebAssembly.instantiate(m, {dart2wasm}); console.log(imps.length + ' ' + i.exports.said(7n)); })()"
    local out = readchomp(`node -e $script $path`)
    rm(path)
    @test out == "héllo\n1 7"
end
end
