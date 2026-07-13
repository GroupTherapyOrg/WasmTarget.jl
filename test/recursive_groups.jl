mutable struct _WTDirectRecursive
    value::Int64
    next::_WTDirectRecursive
    _WTDirectRecursive(value::Int64) = new(value)
end

mutable struct _WTVectorRecursive
    value::Int64
    children::Vector{_WTVectorRecursive}
end

@noinline _wt_make_direct_recursive(value::Int64) = _WTDirectRecursive(value)
@noinline _wt_make_vector_recursive(value::Int64) =
    _WTVectorRecursive(value, _WTVectorRecursive[])
_wt_direct_recursive(value::Int64)::Int64 = _wt_make_direct_recursive(value).value
_wt_vector_recursive(value::Int64)::Int64 = _wt_make_vector_recursive(value).value

@testset "Wasm recursive type groups" begin
    @test compare_julia_wasm(_wt_direct_recursive, Int64(41)).pass
    @test compare_julia_wasm(_wt_vector_recursive, Int64(42)).pass

    mod, _, _, _ = WasmTarget.compile_module(
        Any[(_wt_make_vector_recursive, (Int64,), "_wt_make_vector_recursive")];
        return_registries=true)
    @test !isempty(mod.rec_groups)
    @test all(g -> issorted(g) &&
                   all(g[i] + UInt32(1) == g[i + 1] for i in 1:length(g)-1),
              mod.rec_groups)
    @test validate_wasm(WasmTarget.to_bytes(mod))
end
