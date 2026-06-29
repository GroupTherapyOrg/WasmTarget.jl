# Parity probe — sort comparator-kwarg backfill.
#
# SILENT MISCOMPILE: the non-mutating `Base.sort` overlay (src/codegen/interpreter.jl) forwarded
# only `rev` to `sort!`, silently DROPPING `by`/`lt`/`order` — so `sort(v, by=f)` / `sort(v, lt=cmp)`
# returned the default-`isless` order (wrong, not a trap). The `sort!` overlay's body already honors
# lt/by/rev; the bug was purely the forwarding. Fixed to forward all comparator kwargs.
# Verified native-vs-wasm (Int64-in/out wrappers).

@testset "sort comparator kwargs (by / lt / rev)" begin
    sp(n::Int64)  = sort([3, 1, n, 2])[1]                  # plain → 1
    sr(n::Int64)  = sort([3, 1, n, 2]; rev=true)[1]        # rev → 5
    sbn(n::Int64) = sort([3, 1, n, 2]; by=x -> -x)[1]      # by negate (descending) → 5
    sba(n::Int64) = sort([-3, 1, -n, 2]; by=abs)[1]        # by abs → 1 (|1| smallest)
    slt(n::Int64) = sort([3, 1, n, 2]; lt=(a, b) -> a > b)[1]  # custom lt (descending) → 5
    sbr(n::Int64) = sort([3, 1, n, 2]; by=x -> x, rev=true)[1] # by + rev → 5
    @test compare_julia_wasm(sp,  Int64(5)).pass
    @test compare_julia_wasm(sr,  Int64(5)).pass
    @test compare_julia_wasm(sbn, Int64(5)).pass
    @test compare_julia_wasm(sba, Int64(5)).pass
    @test compare_julia_wasm(slt, Int64(5)).pass
    @test compare_julia_wasm(sbr, Int64(5)).pass
end

@testset "sortperm overlay (was identity permutation / silent-wrong)" begin
    # generic Base.sortperm mis-compiled to the IDENTITY permutation; new overlay does a stable
    # insertion sort on the index vector comparing by v[idx]. Verified native-vs-wasm.
    spmin(n::Int64)  = sortperm([3, 1, n, 2])[1]                 # min=1 at idx 2
    splast(n::Int64) = sortperm([3, 1, n, 2])[end]               # max=5 at idx 3
    spby(n::Int64)   = sortperm([3, 1, n, 2]; by=x -> -x)[1]     # descending → idx 3
    sprev(n::Int64)  = sortperm([3, 1, n, 2]; rev=true)[1]       # descending → idx 3
    spfull(n::Int64) = Int64(sum(sortperm([3, 1, n, 2]) .* [1, 2, 3, 4]))  # whole permutation
    @test compare_julia_wasm(spmin,  Int64(5)).pass
    @test compare_julia_wasm(splast, Int64(5)).pass
    @test compare_julia_wasm(spby,   Int64(5)).pass
    @test compare_julia_wasm(sprev,  Int64(5)).pass
    @test compare_julia_wasm(spfull, Int64(5)).pass
end
