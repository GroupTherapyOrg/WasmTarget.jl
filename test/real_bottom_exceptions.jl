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

# An exception that escapes an export to the host leaves Julia's exception stack as the call
# found it: the host is the catching frame (jl_restore_excstack). The next call's `rethrow()`
# outside a catch raises Julia's ErrorException, never the escaped exception (it did: 1, not 2).
_wt_export_escape(x::Int64) = x > 0 ? throw(ArgumentError("escaped")) : x
_wt_export_rethrow(x::Int64) = try; rethrow(); catch e; e isa ArgumentError ? 1 : (e isa ErrorException ? 2 : 3); end + x
_wt_export_nested(x::Int64) = try; throw(DomainError(1)); catch; try; rethrow(); catch e2; e2 isa DomainError ? 1 : (e2 isa ArgumentError ? 2 : 3); end; end + x

@testset "an exception escaping an export leaves the stack as the call found it" begin
    native_rethrow = (try; _wt_export_escape(1); catch; end; _wt_export_rethrow(0))
    native_nested = (try; _wt_export_escape(1); catch; end; _wt_export_nested(0))
    @test (native_rethrow, native_nested) == (2, 1)
    bytes = WasmTarget.compile_multi([(_wt_export_escape, (Int64,)), (_wt_export_rethrow, (Int64,)),
                                      (_wt_export_nested, (Int64,))])
    driver = """
    const importObject = {};
    $(WasmRunner.HOST_RUNTIME_MERGE_JS)
    const { instance } = await WebAssembly.instantiate(bytes, importObject, { builtins: ['js-string'] });
    const ex = instance.exports;
    const call = (f, a) => { try { return Number(f(a)); } catch (e) { return -1; } };
    const out = [call(ex['_wt_export_escape'], 1n), call(ex['_wt_export_rethrow'], 0n),
                 call(ex['_wt_export_escape'], 1n), call(ex['_wt_export_nested'], 0n)];
    return [{ ok: out }];
    """
    status, results = WasmRunner.run_driver_batch(bytes, driver; ninputs=1)
    @test status === :ok
    @test results[1]["ok"] == [-1, native_rethrow, -1, native_nested]
end
