using Test

_wt_bottom_throw(x::Int64) = throw(ArgumentError("bottom-$x"))
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

@testset "Union{} bodies preserve their real exception" begin
    @test compare_julia_wasm(_wt_bottom_catch, Int64(7)).pass
    @test compare_julia_wasm(_wt_typeassert_payload, Int64(7)).pass
end
