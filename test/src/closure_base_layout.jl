# dart2wasm's ClosureLayouter.closureBaseStruct (closures.dart:350-375), ported (src/closures.jl): #ClosureBase holds
# _Closure's context at FieldIndex.closureContext, its vtable at closureVtable and its function type at
# closureRuntimeType, the indices every reader of the struct uses; Julia's Function declares no field, so the
# context is laid out on #ClosureBase itself, below Any's two-field header. A drifted layout is refused, located,
# where the struct is defined.

module ClosureBaseLayoutTest

using Test
using WasmTarget

const W = WasmTarget
const D = WasmTarget.Dart2Wasm
const IR = WasmTarget.WasmBuilder.IR

module Cases
# a program whose closed world holds DataType, the class of a closure's runtime type (ClosureLayouter.functionTypeType)
is_int(r::Base.RefValue{Any}) = r[] isa Int64
end

# the translator of the program, its closures and classes collected, as translate() leaves it before code
function collected()
    local t = D.Translator(W.build_nir(W.check_subset(Cases.is_int, (Base.RefValue{Any},), "closure_base_layout", Base.get_world_counter()), "test"),
                           D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(t.closure_layouter[])
    collect(t.class_info_collector[])
    return t
end

rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e.rejection : rethrow(); end

@testset "closures.dart: #ClosureBase holds the context, the vtable and the function type at their FieldIndex constants" begin
    local t = collected()
    local layouter = t.closure_layouter[]
    local base = layouter.closure_base_struct[]
    # below _Closure's struct (Julia's Function's, Any's two-field header): the header, then the three fields
    @test base.super_type === t.closure_info[].struct_
    @test length(t.closure_info[].struct_.fields) == D.FieldIndex_object_field_base() == D.FieldIndex_closure_context()
    @test length(base.fields) == D.FieldIndex_closure_runtime_type() + 1
    @test base.field_names[D.FieldIndex_closure_context()] == "context"
    @test base.field_names[D.FieldIndex_closure_vtable()] == "vtable"
    @test base.field_names[D.FieldIndex_closure_runtime_type()] == "functionType"
    # dart's field types: the context closureContextFieldType (closures.dart:19, `final WasmStructRef context`), the
    # vtable a non-null #VtableBase, the function type functionTypeType; each immutable
    local context = base.fields[D.FieldIndex_closure_context() + 1]
    @test context.type == D.closure_context_field_type() == IR.RefType_struct(; nullable = false) && !context.mutable
    local vtable = base.fields[D.FieldIndex_closure_vtable() + 1]
    @test vtable.type == IR.RefType(layouter._vtable_base_struct_uninitialized[]; nullable = false) && !vtable.mutable
    local function_type = base.fields[D.FieldIndex_closure_runtime_type() + 1]
    @test function_type.type == layouter.function_type_type[] && !function_type.mutable
    # an instantiation context's closure is a #ClosureBase (closures.dart:273, the genericClosure field)
    @test layouter.instantiation_context_base_struct[].fields[D.FieldIndex_instantiation_context_inner() + 1].type == IR.RefType(base; nullable = false)
end

@testset "closures.dart: a representation's closure struct extends #ClosureBase, its vtable at FieldIndex.closureVtable" begin
    local t = collected()
    local layouter = t.closure_layouter[]
    # _createRepresentation (closures.dart:562) replaces field 3, the vtable (:591), by the representation's own
    local representation = D._create_representation(layouter, 0, 1, String[], nothing, nothing, Int[1])
    local closure_struct = representation.closure_struct
    @test closure_struct.super_type === layouter.closure_base_struct[]
    @test closure_struct.field_names[D.FieldIndex_closure_vtable()] == "vtable"
    @test closure_struct.fields[D.FieldIndex_closure_vtable() + 1].type == IR.RefType(representation.vtable_struct; nullable = false)
    @test closure_struct.field_names[D.FieldIndex_closure_context()] == "context"
    @test closure_struct.fields[D.FieldIndex_closure_runtime_type() + 1].type == layouter.function_type_type[]
end

@testset "closures.dart: #ClosureBase over a header of another length is refused, located" begin
    local t = collected()
    # _Closure's struct (Any's, shared with Function) one field longer: the context would land at 3
    push!(t.closure_info[].struct_.fields, IR.FieldType(IR.NumType_i32))
    local r = rejection(() -> t.closure_layouter[].closure_base_struct[])
    @test r isa W.Internal && occursin("ClosureLayouter.closureBaseStruct", r.site) &&
          occursin("#ClosureBase field $(D.FieldIndex_closure_context()) expected = context, actual = none", r.site) &&
          occursin("struct holds $(D.FieldIndex_closure_context() + 1) fields", r.site)
end

end
