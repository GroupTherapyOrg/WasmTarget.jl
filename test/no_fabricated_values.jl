using Test

mutable struct _WTUndefinedField
    value::Int64
    _WTUndefinedField() = new()
end

_wt_make_undefined_field() = _WTUndefinedField()
_wt_many_string_length()::Int64 = Int64(ncodeunits(Base._string("aa", "bbb", "cccc")))

@testset "codegen never fabricates missing values" begin
    @test_throws WasmTarget.WasmCompileError WasmTarget.compile(_wt_make_undefined_field, ())
    @test compare_julia_wasm(_wt_many_string_length).pass
end
