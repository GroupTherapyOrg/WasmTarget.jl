using Test

mutable struct _WTUndefinedField
    value::Int64
    _WTUndefinedField() = new()
end

_wt_make_undefined_field() = _WTUndefinedField()
_wt_many_string_length()::Int64 = Int64(ncodeunits(Base._string("aa", "bbb", "cccc")))
function _wt_vector_mutation_semantics()::Int64
    v = Int64[]
    for i in 1:20
        push!(v, i)
    end
    resize!(v, 5)
    push!(v, 99)
    return sum(v) * 10 + length(v)
end

@testset "codegen never fabricates missing values" begin
    @test_throws WasmTarget.WasmCompileError WasmTarget.compile(_wt_make_undefined_field, ())
    @test compare_julia_wasm(_wt_many_string_length).pass
    @test compare_julia_wasm(_wt_vector_mutation_semantics).pass
end
