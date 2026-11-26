# dart2wasm's FieldIndex.validate (class_info.dart:58), ported (src/class_info.jl): each field WasmTarget reads by a
# FieldIndex constant was laid out at that index by ClassInfoCollector.collect, which runs the check last
# (class_info.dart:773); a drifted index is refused, located, naming the class, the field and both indices.

module FieldIndexValidateTest

using Test
using WasmTarget

const W = WasmTarget
const D = WasmTarget.Dart2Wasm

module Cases
# a program holding a record of two fields (Tuple{Int64,Float64}, boxed into TupleRecord{2}) and a 128-bit integer
@noinline pair_of(n::Int)::Any = (n, Float64(n))
@noinline wide_of(n::Int)::Any = Int128(n)
held(n::Int) = (pair_of(n) isa Tuple ? 1 : 0) + (wide_of(n) isa Int128 ? 2 : 0)
end

# the translator of the program, its classes collected (FieldIndex.validate run by collect)
function collected()
    local t = D.Translator(W.build_nir(W.check_subset(Cases.held, (Int,), "field_index_validate", Base.get_world_counter()), "test"),
                           D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(t.closure_layouter[])
    collect(t.class_info_collector[])
    return t
end

rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e.rejection : rethrow(); end

# the field of `cls` named `name`, as the check finds it (the Kernel's cls.fields)
field_of(cls, name) = only(filter(f -> f.name == name, W.class_instance_fields(cls, "field_index_validate")))

@testset "class_info.dart: FieldIndex.validate on a collected translator" begin
    local t = collected()
    # collect ran it; run again, every checked field is where its constant says
    @test D.FieldIndex_validate(t) === nothing
    # the classes the check reads are in the program's world
    @test haskey(t.class_info, Int64) && haskey(t.class_info, W.TupleRecord{2})
    @test t.field_index[field_of(Int64, "value")] == D.FieldIndex_box_value()
    @test t.field_index[field_of(W.TupleRecord{2}, "\$1")] == D.FieldIndex_record_field_base()
    @test t.field_index[field_of(W.TupleRecord{2}, "\$2")] == D.FieldIndex_record_field_base() + 1
    @test length(t.object_info[].struct_.fields) == D.FieldIndex_object_field_base()
end

@testset "class_info.dart: FieldIndex.validate refuses a drifted index, located" begin
    local t = collected()
    # a primitive class's box value laid out elsewhere than boxValue
    local value = field_of(Int64, "value")
    t.field_index[value] = D.FieldIndex_box_value() + 1
    local r = rejection(() -> D.FieldIndex_validate(t))
    @test r isa W.Internal && occursin("FieldIndex.validate", r.site) &&
          occursin("Int64 field value expected index = $(D.FieldIndex_box_value()), actual index = $(D.FieldIndex_box_value() + 1)", r.site)
    t.field_index[value] = D.FieldIndex_box_value()
    # a field the check reads with no index assigned
    delete!(t.field_index, value)
    r = rejection(() -> D.FieldIndex_validate(t))
    @test r isa W.Internal && occursin("Int64 field value doesn't have an index assigned", r.site)
    t.field_index[value] = D.FieldIndex_box_value()
    @test D.FieldIndex_validate(t) === nothing
    # a record's second positional field off getPositionalIndex
    local second = field_of(W.TupleRecord{2}, "\$2")
    t.field_index[second] = D.FieldIndex_record_field_base()
    r = rejection(() -> D.FieldIndex_validate(t))
    @test r isa W.Internal && occursin("field \$2 expected index = $(D.FieldIndex_record_field_base() + 1), actual index = $(D.FieldIndex_record_field_base())", r.site)
    t.field_index[second] = D.FieldIndex_record_field_base() + 1
    @test D.FieldIndex_validate(t) === nothing
    # an object header one field longer than objectFieldBase
    push!(t.object_info[].struct_.fields, W.WasmBuilder.IR.FieldType(W.WasmBuilder.IR.NumType_i32))
    r = rejection(() -> D.FieldIndex_validate(t))
    @test r isa W.Internal && occursin("object header, has $(D.FieldIndex_object_field_base() + 1) fields", r.site)
end

end
