# dart2wasm's namer.dart, ported (src/namer.jl, dev/MARCH.md 1.C): Namer on fixed inputs.
using Test
using WasmTarget

const DN = WasmTarget.Dart2Wasm

@testset "namer.dart: Namer" begin
    local n = DN.Namer()
    @test !n.minify
    # the name asked for, then suffixed until unused
    @test DN.get_name(n, "f") == "f" && DN.get_name(n, "f") == "f_0" && DN.get_name(n, "f") == "f_1"
    @test DN.get_name(n, "f_0") == "f_0_0"
    # a JS-safe name has every character outside [a-zA-Z0-9_$] replaced by _
    @test DN.get_name(n, "a.b-c\$d"; js_safe_name = true) == "a_b_c\$d"
    @test DN.Namer__js_sanitize_name("x y.z") == "x_y_z"
    DN.reserve_name(n, "g")                 # no namespace to protect unminified
    @test DN.get_name(n, "g") == "g"
    # minified: the shortest strings of a counter, skipping a reserved one
    local m = DN.Namer(; minify = true)
    DN.reserve_name(m, "\$")
    # the counter's id 0 is "\$", reserved, so the first name is id 1's
    @test DN.get_name(m, "anything") == "%"
    @test DN.get_name(m, "else") == "&"
    # one counter for both alphabets: the next id, 3, is the JS-safe "E" (A is 0)
    @test DN.get_name(m, "x"; js_safe_name = true) == "E"
    local e = try; DN.reserve_name(m, "\$"); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Internal
end

module NamerInterop
using Test, WasmTarget
const DN = WasmTarget.Dart2Wasm
entry(x::Int) = helper(x) + 1
@noinline helper(x::Int) = 2x
@testset "namer.dart: InteropMemberNamer, Julia's exports and no imports" begin
    local world = WasmTarget.build_nir(WasmTarget.check_subset(entry, (Int,), "namer"), "namer")
    local mi(f) = only(b.ci.def for b in world if b.ci.def.def.name === nameof(f))
    # the program's entry is its one export, strong, named by its function; no member is an import
    local exports = DN.Namer(; minify = true)
    local n = DN.InteropMemberNamer(world, exports, DN.TranslatorOptions())
    @test DN.get_export_name(n, mi(entry)) == "entry" && DN.get_export_name(n, mi(helper)) === nothing
    @test DN.get_import_name(n, mi(entry)) === nothing && DN.get_import_name(n, mi(helper)) === nothing
    @test DN.register_external_export_name(n, mi(entry)) && !DN.register_external_export_name(n, mi(helper))
    # the export's name is reserved in the export namer: registering it again collides
    local e = try; DN.register_external_export_name(n, mi(entry)); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Internal
    # the helpers' module: dart2wasm, or _ when minified
    @test DN.interop_helper_module_name(n) == "dart2wasm"
    @test DN.interop_helper_module_name(DN.InteropMemberNamer(world, DN.Namer(), DN.TranslatorOptions(; optimization_level = 2))) == "_"
end
end
