# The String data operations (src/julia/wasm_array.jl), dart:_wasm's WasmArray operations on a String's
# code units: natively each answers as Julia does, which an overlay written with them relies on.
module WasmArrayStringTest

using Test
using WasmTarget

const W = WasmTarget

@testset "wasm_array.jl: a String's data, natively" begin
    for s in ("", "ab", "héllo", "日本語", repeat("é", 300))
        @test W.wasm_string_length(s) == ncodeunits(s) == sizeof(s)
        @test [W.wasm_string_codeunit(s, i) for i in 0:ncodeunits(s) - 1] == collect(codeunits(s))
    end
    # concatenation as Base's _string makes it: a fresh String, the bytes copied in
    local a, b = "héllo", " 世界"
    local t = W.wasm_string_alloc(ncodeunits(a) + ncodeunits(b))
    W.wasm_string_copy!(t, 0, a, 0, ncodeunits(a))
    W.wasm_string_copy!(t, ncodeunits(a), b, 0, ncodeunits(b))
    @test t == a * b && ncodeunits(t) == ncodeunits(a) + ncodeunits(b)
end

end
