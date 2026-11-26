# a TypeName's fields as Julia's runtime holds them (src/julia/classes.jl class_field_type): Julia 1.12's jl_init_types
# declares `linearcache` a Core.MethodCache (julia/src/jltypes.c:3023) while its storage is a jl_svec_t* (julia/src/julia.h:534); the
# class's layout takes the storage's type, and a program's access of the field, which Julia's inference types by the
# declaration, rejects, located (declared_type_unheld)
module TypenameFieldsTest
using Test, WasmTarget
_rt(x::Int64) = x > 0 ? Int64 : Float64
lc_len(x::Int64) = length(_rt(x).name.linearcache)
@testset "classes.jl class_field_type: TypeName's linearcache is the SimpleVector Julia holds (julia/src/julia.h:534)" begin
    local i = Base.fieldindex(Core.TypeName, :linearcache)
    @test WasmTarget.class_field_type(Core.TypeName, i) === typeof(Int64.name.linearcache) === Core.SimpleVector
    # every other field of TypeName, and any other struct's, is Julia's fieldtype
    @test all(WasmTarget.class_field_type(Core.TypeName, k) === fieldtype(Core.TypeName, k) for k in 1:fieldcount(Core.TypeName) if k != i)
    @test all(WasmTarget.class_field_type(Base.RefValue{Int}, k) === fieldtype(Base.RefValue{Int}, k) for k in 1:fieldcount(Base.RefValue{Int}))
    # an access is refused exactly where the running Julia still declares the slip
    local declared = fieldtype(Core.TypeName, i)
    @test WasmTarget.declared_type_unheld(Core.TypeName, i) isa (declared === Core.SimpleVector ? Nothing : WasmTarget.Unquarantined)
    @test WasmTarget.declared_type_unheld(Core.TypeName, 0) === nothing
    if declared !== Core.SimpleVector
        local e = try; WasmTarget.compile(lc_len, (Int64,)); nothing; catch x; x; end
        @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Unquarantined &&
              occursin("class_field_type: an access of the field linearcache of Core.TypeName", e.rejection.row)
    end
end
end
