using Test
using WasmTarget

# Inside a collected closed world the collection's IR is the only IR: a query it cannot
# answer is an error, never a second inference (a fresh WasmInterpreter at the current
# world, in another cache partition, possibly unoptimized).
_wt_oip_a(x::Int) = x + 1
_wt_oip_b(x::Int) = x * 2

@testset "one inference path inside a collected world" begin
    ci, rt = WasmTarget.get_typed_ir(_wt_oip_a, (Int,))
    cache = IdDict{Any, Tuple{Core.CodeInfo, Any}}((_wt_oip_a, (Int,)) => (ci, rt))
    previous = WasmTarget.TRIM_IR_CACHE[]
    WasmTarget.TRIM_IR_CACHE[] = cache
    try
        @test WasmTarget.get_typed_ir(_wt_oip_a, (Int,))[1] === ci          # served, not re-inferred
        @test_throws ErrorException WasmTarget.get_typed_ir(_wt_oip_b, (Int,))   # outside the world
        @test_throws ErrorException WasmTarget.get_typed_ir(_wt_oip_a, (Int,); optimize=false)
        @test_throws ErrorException WasmTarget.get_typed_ir(Tuple{typeof(_wt_oip_a), Int})
    finally
        WasmTarget.TRIM_IR_CACHE[] = previous
    end
    # outside a collection both queries infer as before
    @test WasmTarget.get_typed_ir(_wt_oip_b, (Int,))[2] === Int
    @test length(WasmTarget.get_typed_ir(Tuple{typeof(_wt_oip_a), Int})) == 1
end
