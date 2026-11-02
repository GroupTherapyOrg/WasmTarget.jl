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
# the site inlined twice into one caller: one site, one import
twice(x::Int64) = (W.Runtime.print_to_console("a"); W.Runtime.print_to_console("b"); x)
# a program naming the runtime's internal interop module itself, as no dart program may import dart:_js_helper
forged(x::Int64) = (ccall(("s => (", "dart2wasm"), Nothing, ()); x)
@testset "js_common/print_patch.dart: printToConsole hands its line to the JS runtime's inline JS" begin
    local world = W.build_nir(W.check_subset(said, (Int64,), "print_patch"), "print_patch")
    # the method whose body holds the inline JS: printToConsole's, or its caller's where Julia inlined it
    local mi = only(b.ci.def for b in world if !isempty(W.nir_js_sites(world, b.ci.def)))
    local (site, sname, code) = only(W.nir_js_sites(world, mi))
    # the site is where it was written, print_patch.jl's port, whatever caller Julia inlined it into
    @test startswith(site, "WasmTarget.Runtime.print_to_console") && occursin("String", site) && sname == "print_to_console" && code == "s => printToConsole(s)"
    # generateJsMethods writes the method under the name the code generator imports it by
    local namer = D.InteropMemberNamer(world, D.Namer(), D.TranslatorOptions())
    local body = only(b for b in world if b.ci.def === mi)
    local site = W.nir_foreign_import(body, only(st for st in body.stmts if st isa W.NirForeignCall && st.args[1].c.val[2] == "dart2wasm"))
    local name = D.get_import_name(namer._interop_helper_member_namer, site, mi)
    @test name.module_name == "dart2wasm"
    @test D.generate_js_methods(J.RuntimeFinalizer(namer), [mi, mi]) == "      $(name.item_name): s => printToConsole(s),\n"
    # compiled as dart2wasm compiles a program, the module beside the JS runtime the runtime generator
    # writes (its methods generateJsMethods'), and run under that runtime in node: the runtime's own
    # printToConsole prints the line as Julia's println prints it, then the export answers 7
    local opts = D.WasmCompilerOptions(; main_uri = "", output_file = "out/said.wasm"); opts.translator_options.generate_source_maps = false
    local r = D.compile(opts, W.check_subset(said, (Int64,), "print_patch"))
    @test occursin(": s => printToConsole(s),", r.js_files["out/said.mjs"])
    mktempdir() do dir
        write(joinpath(dir, "said.mjs"), r.js_files["out/said.mjs"])
        write(joinpath(dir, "said.wasm"), only(values(r.wasm_files)))
        local script = "import {compile} from '$(dir)/said.mjs'; import {readFileSync} from 'fs'; " *
            "const app = await compile(readFileSync('$(dir)/said.wasm')); const i = await app.instantiate({}); " *
            "console.log(String(i.instantiatedModule.exports.said(7n)));"
        local out = read(`perl -e 'alarm 60; exec @ARGV' node --input-type=module -e $script`, String)
        # (said itself cannot run natively: its JS string lives only in the module)
        @test out == sprint(println, "héllo") * sprint(println, 7)
    end
    # a site Julia inlined twice into one caller is one site: one import, one JS method
    local r2 = D.compile(opts, W.check_subset(twice, (Int64,), "print_patch"))
    @test count(": s => printToConsole(s),", r2.js_files["out/said.mjs"]) == 1
    # the interop module named outside the runtime is the program's error, located, never invalid JS
    local e = try; W.compile(forged, (Int64,)); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.ProgramError && occursin("dart:_js_helper", sprint(showerror, e))
    # two inline JS sites written on one line of a runtime port: Julia's debug info gives no column, so
    # one name would run the first's JS for both; refused at the site, located, never the first's code
    Core.eval(W.Runtime, :(two_on_one_line() = (ccall(("() => 1", "dart2wasm"), Nothing, ()); ccall(("() => 2", "dart2wasm"), Nothing, ()); nothing)))
    local tw = W.build_nir(W.check_subset(getglobal(W.Runtime, :two_on_one_line), (), "print_patch"), "print_patch")
    local twe = try; W.nir_js_sites(tw, tw.entry); nothing; catch x; x; end
    @test twe isa W.RejectionError && twe.rejection isa W.Internal && occursin("two inline JS sites", twe.rejection.site) &&
          occursin("() => 1", twe.rejection.site) && occursin("() => 2", twe.rejection.site)
    # the same line's two sites inlined into two callers, each keeping one (its branch pruned): each body
    # holds one site, so generateJsMethods, which writes one code per site across the world, refuses the
    # second code, located, never the first's JS for both
    Core.eval(W.Runtime, :(@inline one_line_of_two(b::Bool) = b ? ccall(("() => 3", "dart2wasm"), Nothing, ()) : ccall(("() => 4", "dart2wasm"), Nothing, ())))
    Core.eval(W.Runtime, :(@noinline keeps_first() = (one_line_of_two(true); nothing)))
    Core.eval(W.Runtime, :(@noinline keeps_second() = (one_line_of_two(false); nothing)))
    local both = (x::Int64) -> (W.Runtime.keeps_first(); W.Runtime.keeps_second(); x)
    local bw = W.build_nir(W.check_subset(both, (Int64,), "print_patch"), "print_patch")
    local keepers = [b.ci.def for b in bw if b.ci.def.def.name in (:keeps_first, :keeps_second)]
    @test length(keepers) == 2 && all(mi -> length(W.nir_js_sites(bw, mi)) == 1, keepers)
    local bnamer = D.InteropMemberNamer(bw, D.Namer(), D.TranslatorOptions())
    # each keeper's import named, as the code generator names it at the call (both sites one key, one name)
    for mi in keepers
        local kb = only(b for b in bw if b.ci.def === mi)
        D.get_import_name(bnamer._interop_helper_member_namer, W.nir_foreign_import(kb, only(st for st in kb.stmts if st isa W.NirForeignCall)), mi)
    end
    local ge = try; D.generate_js_methods(J.RuntimeFinalizer(bnamer), keepers); nothing; catch x; x; end
    @test ge isa W.RejectionError && ge.rejection isa W.Internal && occursin("kept by different callers", ge.rejection.site) &&
          occursin("() => 3", ge.rejection.site) && occursin("() => 4", ge.rejection.site)
end
end
