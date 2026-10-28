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
