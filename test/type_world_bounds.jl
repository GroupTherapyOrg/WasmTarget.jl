using Test
using WasmTarget

@testset "closed-world TypeName world bounds" begin
    # Int's binding is unbounded in the collection world. Exercise the semantic
    # operation directly so both compile-time metadata and target execution are
    # locked independently of Base's display stack.
    bounds_are_unbounded()::Bool =
        WasmTarget._closed_world_type_bounds(Int.name) === nothing

    @test bounds_are_unbounded()
    bytes = WasmTarget.compile(bounds_are_unbounded, (); validate=true)
    @test run_wasm(bytes, "bounds_are_unbounded") == 1

    # The overlay must preserve ordinary Julia behavior exactly.
    @test WasmTarget._closed_world_type_bounds(Int.name) ===
          Base.check_world_bounded(Int.name)
end
