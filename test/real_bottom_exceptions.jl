using Test

_wt_bottom_throw(x::Int64) = throw(ArgumentError("bottom-$x"))
_wt_interpolation_length(x::Int64)::Int64 = length("value=$x")
function _wt_bottom_catch(x::Int64)::Int64
    try
        _wt_bottom_throw(x)
        return 0
    catch err
        return err isa ArgumentError ? 1 : 2
    end
end

function _wt_typeassert_payload(x::Int64)::Int64
    try
        typeassert(x, String)
        return 0
    catch err
        return err isa TypeError && err.expected === String && err.got isa Int64 ? 1 : 2
    end
end

_wt_bottom_invoke_catch(x::Int32)::Int32 = try
    div(Int32(0), Int32(typemax(Int64)))
catch
    x
end

_wt_bounds_helper_catch(x::Int64)::Int64 = try
    [x][0]
    0
catch err
    err isa BoundsError ? 1 : 2
end

_wt_inexact_helper_catch(x::Int64)::Int64 = try
    Int32(typemax(Int64))
    0
catch err
    err isa InexactError ? 1 : 2
end

_wt_domain_helper_catch(x::Int64)::Int64 = try
    sin(Inf)
    0
catch err
    err isa DomainError ? 1 : 2
end

_wt_overflow_helper_catch(x::Int64)::Int64 = try
    Base.checked_add(typemax(Int64), x)
    0
catch err
    err isa OverflowError ? 1 : 2
end

@testset "Union{} bodies preserve their real exception" begin
    @test compare_julia_wasm(_wt_bottom_catch, Int64(7)).pass
    @test compare_julia_wasm(_wt_typeassert_payload, Int64(7)).pass
    @test compare_julia_wasm(_wt_bottom_invoke_catch, Int32(7)).pass
    @test compare_julia_wasm(_wt_bounds_helper_catch, Int64(1)).pass
    @test compare_julia_wasm(_wt_inexact_helper_catch, Int64(1)).pass
    @test compare_julia_wasm(_wt_domain_helper_catch, Int64(1)).pass
    @test compare_julia_wasm(_wt_overflow_helper_catch, Int64(1)).pass
    @test compare_julia_wasm(_wt_interpolation_length, typemax(Int64)).pass
    @test compare_julia_wasm(_wt_interpolation_length, typemin(Int64)).pass
end
