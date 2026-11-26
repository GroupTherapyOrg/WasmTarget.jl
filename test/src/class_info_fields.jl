# dart2wasm's class_info.dart, ported (src/class_info.jl, dev/MARCH.md 1.C): each filled definition
# answers as dart's does on fixed inputs: a class's instance fields, the collector, ClassInfo and _upperBound. Split
# from test/src/class_info.jl, every testset verbatim; its other half is test/src/class_info_numbering.jl, whose
# ClassInfoCases module this half repeats verbatim, as both halves' testsets read it.
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm

module ClassInfoCases
# a slot of DataTypes tested against Type{Int64}: Float64 is a DataType too, so only the value's own
# test (jl_isa's jl_types_equal) answers, never its class
kind_isa(n::Int64) = (v = Any[Int64, Float64]; v[n] isa Type{Int64} ? 1 : 0)
abstract type Shape end
struct Circle <: Shape; r::Float64; end
struct Square <: Shape; s::Float64; end
f_shapes(n::Int) = n > 0 ? Circle(1.0) : Square(2.0)
f_vector(v::Vector{Int}) = sum(v)
struct Holder; t::Tuple{Any}; end
f_holder(h::Holder) = 1
f_int32(n::Int) = Int32(n)
f_cov(h::Holder, x::Tuple{Int}, n::Int) = Int32(n) + x[1]
end

module FieldCases
struct P; x::Float64; y::Int32; end
mutable struct M; a::Int; const b::Float64; end
abstract type A end
struct S end
end

@testset "class_info.dart: the class's instance fields and the collector" begin
    local W = WasmTarget
    local at = "class_info"
    local fields(c) = W.class_instance_fields(c, at)
    # a struct's fields are Julia's fieldnames and fieldtypes, mutable where Julia's isconst says not
    local p = fields(FieldCases.P)
    @test [f.name for f in p] == [string(n) for n in fieldnames(FieldCases.P)] && [f.type for f in p] == collect(fieldtypes(FieldCases.P))
    @test [f.index for f in p] == [1, 2] && !any(f -> f.mutable, p)
    local m = fields(FieldCases.M)
    @test [f.mutable for f in m] == [!isconst(FieldCases.M, i) for i in 1:fieldcount(FieldCases.M)] == [true, false]
    # an abstract class and a singleton have none; a primitive class its one value, the class itself
    @test isempty(fields(FieldCases.A)) && isempty(fields(FieldCases.S)) && isempty(fields(Any)) && isempty(fields(Nothing))
    @test [(f.name, f.type, f.index, f.mutable) for f in fields(Int64)] == [("value", Int64, 0, false)]
    @test isprimitivetype(Bool) && fields(Bool)[1].type === Bool
    # a kind takes dart's runtime type layout: isDeclaredNullable, and a DataType the class id
    @test [(f.name, f.type, f.index) for f in fields(DataType)] == [("isDeclaredNullable", Bool, 0), ("classId", Int32, 0), ("parameters", Core.SimpleVector, Base.fieldindex(DataType, :parameters))]
    @test [f.name for f in fields(Core.TypeofBottom)] == ["isDeclaredNullable"]
    @test [f.name for f in fields(Union)] == ["isDeclaredNullable", "a", "b"]
    # a String: its UTF-8 code units as one immutable array of dart:_wasm's WasmI8 (the String ruling)
    @test [(f.name, f.type, f.index) for f in fields(String)] == [("_data", W.WasmArray{W.WasmI8}, 0)]
    # a Symbol: Julia's jl_sym_t (julia.h:147), the symbol table's children, its hash, then its name, one String
    # (dart's Symbol._name)
    @test [(f.name, f.type, f.index) for f in fields(Symbol)] == [("left", Union{Nothing,Symbol}, 0), ("right", Union{Nothing,Symbol}, 0),
                                                                  ("hash", UInt64, 0), ("_name", String, 0)]
    # a Module: its name, one Symbol (jl_module_t's leading field); with it every concrete class of
    # Core and Base that holds its data outside its fields has its representation
    @test [(f.name, f.type, f.index) for f in fields(Module)] == [("name", Symbol, 0)]
    # the collector over a translator: no class masquerades in Julia; typeType, read only for a
    # class's type parameters, which Julia's classes do not have, stays unassigned
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(ClassInfoCases.f_shapes, (Int,), at, Base.get_world_counter()), "test"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions(optimization_level = 2))
    local c = D.ClassInfoCollector(t)
    @test c.translator === t && D.options(c) === t.options && isempty(c.masqueraded[])
    local e = try; c.type_type[]; nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Unported && occursin("ClassInfoCollector.typeType", e.rejection.anchor)
    # the top class requires the class id field
    @test D._requires_subclass_fields(c, nothing, IdDict{TypeVar,TypeVar}(), nothing)
    # the translator's class tables, filled by collect
    @test isempty(t.class_info) && isempty(t.class_for_heap_type) && isempty(t.field_index)
    local e2 = try; t.classes[]; nothing; catch x; x; end
    @test e2 isa W.RejectionError && e2.rejection isa W.Unported && occursin("Translator.classes", e2.rejection.anchor)
end

@testset "class_info.dart: ClassInfo, _upperBound and cyclicness on wasm structs" begin
    local W = WasmTarget
    local IR = W.WasmBuilder.IR
    local S = ClassInfoCases
    # a hand-built hierarchy as collect makes it: the top struct, Any below it, the abstract Shape
    # sharing Any's struct, Circle and Square below Shape
    local top = D.ClassInfo(nothing, 0, 0, IR.StructType("#Top"), nothing)
    local anyi = D.ClassInfo(Any, 4, 1, IR.StructType("Any"; super_type = top.struct_), top)
    local shape = D.ClassInfo(S.Shape, 3, 2, anyi.struct_, anyi)
    local circle = D.ClassInfo(S.Circle, 1, 3, IR.StructType("Circle"; super_type = anyi.struct_), shape)
    local square = D.ClassInfo(S.Square, 2, 3, IR.StructType("Square"; super_type = anyi.struct_), shape)
    # the two reference types to the class's struct
    @test D.type_with_nullability(circle, true) == IR.RefType_def(circle.struct_; nullable = true)
    @test D.type_with_nullability(circle, false) == circle.non_nullable_type && !circle.non_nullable_type.nullable
    @test D.class_id(square) == 2 && isempty(circle.type_parameter_match)
    # the nearest class info above both, by depth then by super info
    @test D._upper_bound(circle, square) === shape && D._upper_bound(square, circle) === shape
    @test D._upper_bound(circle, circle) === circle && D._upper_bound(circle, anyi) === anyi && D._upper_bound(top, square) === top
    # repr and cyclicness are filled by collect; read before, located rejections
    for f in (D.repr, D.is_cyclic)
        local e = try; f(circle); nothing; catch x; x; end
        @test e isa W.RejectionError && e.rejection isa W.Internal
    end
    local mixin = D.ClassInfo(S.Shape, D.anonymous_mixin_class_id(), 2, anyi.struct_, anyi)
    local e = try; D.class_id(mixin); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
    # the fields: the class id at 0, the identity hash at 1, the class's own from 2
    D._add_field(top, IR.FieldType(IR.NumType_i32; mutable = false); expected_index = D.FieldIndex_class_id())
    for (i, ft) in enumerate(top.struct_.fields)
        D._add_field(anyi, ft; field_name = get(top.struct_.field_names, i - 1, nothing))
    end
    D._add_field(anyi, IR.FieldType(IR.NumType_i32); expected_index = D.FieldIndex_identity_hash())
    for ft in anyi.struct_.fields
        D._add_field(circle, ft)
    end
    D._add_field(circle, IR.FieldType(IR.NumType_f64; mutable = false); field_name = "r")
    @test circle.struct_.field_names[2] == "r" && length(circle.struct_.fields) == 3
    @test D.get_class_field_types(circle) == [IR.NumType_f64]
    local seen = Tuple{Int,IR.FieldType}[]
    D.for_each_class_field_index(circle, (i, ft) -> push!(seen, (i, ft)))
    @test seen == [(2, circle.struct_.fields[3])]
    local e2 = try; D._add_field(circle, IR.FieldType(IR.NumType_i64); expected_index = 7); nothing; catch x; x; end
    @test e2 isa W.RejectionError && e2.rejection isa W.Internal
    # cyclicness: a struct holding a non-nullable reference to its own class's struct is cyclic; one
    # holding a nullable reference is not
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(S.f_shapes, (Int,), "class_info", Base.get_world_counter()), "test"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    for info in (circle, square)
        info._repr = info.non_nullable_type
        t.class_for_heap_type[info.struct_] = info
    end
    push!(circle.struct_.fields, IR.FieldType(circle.non_nullable_type; mutable = false))
    push!(square.struct_.fields, IR.FieldType(square.nullable_type; mutable = false))
    @test D._calculate_cyclicness(circle, t) && D.is_cyclic(circle)
    @test !D._calculate_cyclicness(square, t) && !D.is_cyclic(square)
end
