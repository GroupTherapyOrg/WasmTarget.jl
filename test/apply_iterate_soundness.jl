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

module _WTNamedPlus
    +(xs::Int64...) = Core.Intrinsics.add_int(Int64(100), Int64(length(xs)))
end
_wt_same_name_not_base(a::Vector{Int64}, b::Vector{Int64})::Int64 =
    _WTNamedPlus.:+(a..., b...)

function _wt_empty_splat_methoderror(a::Vector{Int64}, b::Vector{Int64})::Int32
    try
        +(a..., b...)
        return Int32(0)
    catch err
        return err isa MethodError ? Int32(1) : Int32(2)
    end
end

function _wt_empty_splat_methoderror_payload(a::Vector{Int64}, b::Vector{Int64})::Int32
    try
        +(a..., b...)
        return Int32(0)
    catch err
        err isa MethodError || return Int32(-1)
        score = err.f === (+) ? Int32(1) : Int32(0)
        score += err.args === () ? Int32(2) : Int32(0)
        score += err.world != typemax(UInt64) ? Int32(4) : Int32(0)
        return score
    end
end

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
    @test compare_julia_wasm_vec(_wt_empty_splat_methoderror, Int64[], Int64[]).pass
    @test compare_julia_wasm_vec(_wt_empty_splat_methoderror, Int64[1], Int64[]).pass
    @test compare_julia_wasm_vec(_wt_empty_splat_methoderror_payload, Int64[], Int64[]).pass

    err = try
        WasmTarget.compile(_wt_same_name_not_base, (Vector{Int64}, Vector{Int64}))
        nothing
    catch caught
        caught
    end
    @test err isa WasmTarget.WasmCompileError
    @test occursin("unsupported operator/target", sprint(showerror, err))
end
