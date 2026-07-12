using Test

# Julia 1.13 shares bounds-error tails between the outer and inner loops of the
# inlined insertion sort. Those shared terminal blocks cross the natural-loop
# regions. The structurizer must tail-duplicate the non-returning tails; treating
# their labels as ordinarily nested silently skipped the final key store.
_wt_crossing_sort_sum(x::Float64)::Float64 = sum(sort([0.0, x, x]))

@testset "crossing terminal CFG tails" begin
    @test _wt_crossing_sort_sum(-1.0) == -2.0
    @test compare_julia_wasm(_wt_crossing_sort_sum, -1.0; optimize=false).pass
    @test compare_julia_wasm(_wt_crossing_sort_sum, -1.0; optimize=true).pass
end
