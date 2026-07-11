function _wt_runtime_tuple_empty(v::Vector{Int64})::Int32
    t = (v...,)
    return t isa Tuple{} ? Int32(1) : Int32(0)
end


function _wt_runtime_tuple_index(v::Vector{Int64}, i::Int64)::Int64
    t = (v...,)
    return t[i] + length(t)
end

_wt_multi_splat_add(a::Vector{Int64}, b::Vector{Int64})::Int64 = +(a..., b...)
_wt_multi_splat_mul(a::Vector{Float64}, b::Vector{Float64})::Float64 = *(a..., b...)

@testset "_apply_iterate runtime Vararg tuple" begin
    @test WasmTarget.is_runtime_vararg_tuple_type(Tuple{Vararg{Int64}})
    @test !WasmTarget.is_runtime_vararg_tuple_type(Tuple)
    @test !WasmTarget.is_runtime_vararg_tuple_type(Tuple{Int64,Vararg{Int64}})
    @test compare_julia_wasm_vec(_wt_runtime_tuple_empty, Int64[]).pass
    @test compare_julia_wasm_vec(_wt_runtime_tuple_empty, Int64[1]).pass
    @test compare_julia_wasm_vec(_wt_runtime_tuple_empty, Int64[1, 2, 3]).pass
    @test compare_julia_wasm_vec(_wt_runtime_tuple_index, Int64[10, 20, 30], Int64(2)).pass
    @test compare_julia_wasm_vec(_wt_multi_splat_add, Int64[1, 2], Int64[3, 4]).pass
    @test compare_julia_wasm_vec(_wt_multi_splat_mul, Float64[2, 3], Float64[4]).pass
end
