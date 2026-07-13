using Test
using WasmTarget

const _WT_EXACT_GLOBAL_DICT =
    Dict{Union{Int64,Symbol},String}(Int64(7) => "seven", :answer => "forty-two")

_wt_exact_global_count()::Int64 = getfield(_WT_EXACT_GLOBAL_DICT, :count)
function _wt_mutate_then_read_global()::Int64
    setfield!(_WT_EXACT_GLOBAL_DICT, :count,
              getfield(_WT_EXACT_GLOBAL_DICT, :count) + 1)
    return _wt_exact_global_count()
end

@testset "exact mutable GlobalRef initialization" begin
    @test _wt_exact_global_count() == 2
    bytes = WasmTarget.compile(_wt_exact_global_count, (); validate=true)
    @test run_wasm(bytes, "_wt_exact_global_count") == 2

    mutation_bytes = WasmTarget.compile(_wt_mutate_then_read_global, (); validate=true)
    @test run_wasm(mutation_bytes, "_wt_mutate_then_read_global") == 3
end
