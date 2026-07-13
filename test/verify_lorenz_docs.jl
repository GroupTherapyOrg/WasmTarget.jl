using Test
using Binaryen_jll

html_path = only(ARGS)
html = read(html_path, String)

@testset "Lorenz docs island calls Canvas2D imports" begin
    @test occursin("window.TherapyHydrate[\"examplelorenz\"]", html)

    hydrate_at = findfirst("function hydrate_examplelorenz()", html)
    @test hydrate_at !== nothing
    array_marker = "var _wb = new Uint8Array(["
    marker_at = findnext(array_marker, html, first(hydrate_at))
    @test marker_at !== nothing
    bytes_at = last(marker_at) + 1
    array_end = findnext("]);", html, bytes_at)
    @test array_end !== nothing
    wasm = UInt8[parse(UInt8, n) for n in
        split(SubString(html, bytes_at, first(array_end) - 1), ',')]

    mktemp() do wasm_path, wasm_io
        write(wasm_io, wasm)
        close(wasm_io)
        mktemp() do wat_path, wat_io
            close(wat_io)
            run(`$(Binaryen_jll.wasmdis_path) $wasm_path -o $wat_path`)
            wat = read(wat_path, String)
            @test occursin("(import \"canvas2d\" \"begin_path\"", wat)
            @test occursin("(call \$canvas2d.begin_path)", wat)
            # If this export exists, Therapy compiled WasmMakie's Julia-native
            # no-op stub instead of resolving calls to the browser import.
            @test !occursin("(export \"canvas_begin_path\"", wat)
        end
    end
end
