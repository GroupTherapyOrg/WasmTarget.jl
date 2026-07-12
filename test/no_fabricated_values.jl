using Test

mutable struct _WTUndefinedField
    value::Int64
    _WTUndefinedField() = new()
end

_wt_make_undefined_field() = _WTUndefinedField()

@testset "codegen never fabricates missing values" begin
    @test_throws WasmTarget.WasmCompileError WasmTarget.compile(_wt_make_undefined_field, ())
end
