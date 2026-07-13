using Test

mutable struct _WTUndefinedField
    value::Int64
    _WTUndefinedField() = new()
end

_wt_make_undefined_field() = _WTUndefinedField()
mutable struct _WTDefinitelyInitializedFields
    x::Int64
    y::Int64
    function _WTDefinitelyInitializedFields(x::Int64)
        value = new()
        value.x = x
        value.y = x + 1
        return value
    end
end
_wt_use_definitely_initialized_fields(x::Int64)::Int64 = begin
    value = _WTDefinitelyInitializedFields(x)
    value.x * 10 + value.y
end
_wt_exact_kwerr_exception()::Int64 = try
    Base.kwerr((; unsupported_keyword=true), identity)
    0
catch err
    err isa MethodError && err.f === Core.kwcall ? 1 : 2
end
_wt_exact_inexact_exception()::Int64 = try
    Core.throw_inexacterror(:convert, UInt8, UInt64(300))
    0
catch err
    err isa InexactError && err.func === :convert ? 1 : 2
end
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
function _wt_resize_broadcast_fill(a::Int32, b::Int32)::Int32
    values = zeros(10)
    resize!(values, 100)
    values .= 1
    return sum(values)
end
_wt_pure_power_semantics(x::Int64)::Int64 = x^3 + Int64(floor(Float64(x)^2.0))
struct _WTUnsupportedShow
    x::Int64
end
_wt_unsupported_show() = (show(_WTUnsupportedShow(1)); Int64(1))

@testset "codegen never fabricates missing values" begin
    @test_throws WasmTarget.WasmCompileError WasmTarget.compile(_wt_make_undefined_field, ())
    @test compare_julia_wasm(_wt_use_definitely_initialized_fields, Int64(4)).pass
    @test compare_julia_wasm(_wt_exact_kwerr_exception).pass
    @test compare_julia_wasm(_wt_exact_inexact_exception).pass
    @test compare_julia_wasm(_wt_many_string_length).pass
    @test compare_julia_wasm(_wt_vector_mutation_semantics).pass
    @test compare_julia_wasm(_wt_resize_broadcast_fill, Int32(5), Int32(3)).pass
    @test compare_julia_wasm(_wt_resize_broadcast_fill, Int32(5), Int32(3); optimize=true).pass
    @test compare_julia_wasm(_wt_pure_power_semantics, Int64(3)).pass
    @test_throws WasmTarget.WasmCompileError WasmTarget.compile(_wt_unsupported_show, ())
end
