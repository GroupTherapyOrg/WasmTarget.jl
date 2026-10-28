# dart2wasm's class_info.dart, ported (src/class_info.jl, dev/MARCH.md 1.C): each filled definition
# answers as dart's does on fixed inputs.
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm

@testset "class_info.dart: Range and normalize" begin
    local R = D.Range
    # the factory: a range whose end precedes its start is the empty one
    @test D.is_empty(R(3, 1)) && R(3, 1) == D.Range_empty() && length(R(3, 1)) == 0
    @test length(R(2, 5)) == 4 && contains(R(2, 5), 5) && !contains(R(2, 5), 6)
    @test D.contains_range(R(1, 9), R(2, 5)) && !D.contains_range(R(2, 5), R(1, 9))
    @test D.shift_by(R(2, 5), 3) == R(5, 8) && D.is_empty(D.shift_by(R(3, 1), 3))
    @test R(1, 2) == R(1, 2) && R(1, 2) != R(1, 3) && hash(R(1, 2)) == hash(R(1, 2))
    @test sprint(show, R(1, 2)) == "[1, 2]" && sprint(show, R(3, 1)) == "[]"
    # the private constructor asserts start <= end: a located rejection, never a wrong range
    local e = try; D.Range__(3, 1); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Internal
    # normalize: sorted by start, overlapping and adjacent runs merged, empty ranges dropped
    local norm(v) = (D.normalize(v); v)
    @test norm(D.Range[]) == D.Range[]
    @test norm([R(5, 7), R(1, 2), R(3, 4), R(10, 9), R(12, 14), R(13, 13)]) == [R(1, 7), R(12, 14)]
    @test norm([R(1, 3), R(2, 5), R(7, 8), R(9, 9)]) == [R(1, 5), R(7, 9)]
    @test norm([R(4, 6), R(1, 2)]) == [R(1, 2), R(4, 6)]
    @test norm([R(3, 1), R(2, 2)]) == [R(2, 2)]
end

module ClassInfoCases
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

@testset "class_info.dart: ClassIdNumbering on the closed world" begin
    local W = WasmTarget
    local translator(f, at) = D.Translator(W.check_subset(f, at, "class_info"), D.TranslatorOptions())
    local number(f, at, masq = Base.IdSet{DataType}()) = D.ClassIdNumbering__number(translator(f, at), masq)
    for (f, at) in ((ClassInfoCases.f_shapes, (Int,)), (ClassInfoCases.f_vector, (Vector{Int},)))
        local t = translator(f, at)
        local n = D.ClassIdNumbering__number(t, Base.IdSet{DataType}())
        local world = W.closed_world_classes(t.component, "class_info")
        # the walk meets every class of the closed world once, Any first, each class after its supertype
        @test length(n.dfs_order) == length(world) && Base.IdSet{DataType}(n.dfs_order) == Base.IdSet{DataType}(world)
        @test n.dfs_order[1] === Any
        @test all(c -> c === Any || findfirst(x -> x === supertype(c), n.dfs_order) < findfirst(x -> x === c, n.dfs_order), n.dfs_order)
        # the concrete classes hold 1..C, the abstract ones the ids after, one each (the model's
        # ConcreteDense and AbstractAfter), Julia deciding which class is concrete
        local conc = filter(isconcretetype, n.dfs_order)
        local abst = filter(!isconcretetype, n.dfs_order)
        @test sort([n.class_ids[c] for c in conc]) == collect(1:length(conc)) == collect(1:n.max_concrete_class_id)
        @test sort([n.class_ids[a] for a in abst]) == collect(length(conc)+1:n.max_class_id)
        # a class's ranges hold a concrete class's id exactly when Julia's <: says it is a subtype
        # (the model's RangeIsa)
        @test all(((k, c),) -> (c <: k) == any(r -> contains(r, n.class_ids[c]), D.get_concrete_class_id_range(n, k)),
                  [(k, c) for k in n.dfs_order for c in conc])
        @test D.get_concrete_class_id_range(n, Any) == [D.Range(1, length(conc))]
        @test D.get_concrete_subclass_ranges(n, Any) == [D.Range(1, length(conc))]
        # no masquerades: the first interface class id is 1
        @test n.first_non_masqueraded_interface_class_cid[] == 1
    end
    # the abstract Shape's concrete subclasses, Circle and Square, are one range; with Shape
    # masqueraded the first interface class id follows it
    local n = number(ClassInfoCases.f_shapes, (Int,), Base.IdSet{DataType}([ClassInfoCases.Shape]))
    local ids = sort([n.class_ids[ClassInfoCases.Circle], n.class_ids[ClassInfoCases.Square]])
    @test ids[2] == ids[1] + 1 && D.get_concrete_class_id_range(n, ClassInfoCases.Shape) == [D.Range(ids[1], ids[2])]
    @test n.first_non_masqueraded_interface_class_cid[] == ids[2] + 1
    # Julia's TypeofBottom and Type{Union{}} are equal types and two classes, numbered apart
    # (Int32(n)'s throw_inexacterror takes a type as a value, which brings every kind)
    local v = number(ClassInfoCases.f_int32, (Int,))
    @test v.class_ids[Core.TypeofBottom] != v.class_ids[Type{Union{}}]
    @test D.get_concrete_class_id_range(v, Type{Union{}}) == [D.Range(v.class_ids[Core.TypeofBottom], v.class_ids[Core.TypeofBottom])]
    # a world with Tuple covariance (Tuple{Int64} <: Tuple{Any} off its supertype chain) and with
    # Type{Union{}} beside TypeofBottom: every class's ranges hold a concrete class's id exactly when
    # Julia's <: says it is a subtype, the implementors' ranges merged in
    local cov = number(ClassInfoCases.f_cov, (ClassInfoCases.Holder, Tuple{Int}, Int))
    local cconc = filter(isconcretetype, cov.dfs_order)
    @test Tuple{Any} in cov.dfs_order && Tuple{Int} in cov.dfs_order && Core.TypeofBottom in cov.dfs_order && Type{Union{}} in cov.dfs_order
    @test Tuple{Int} <: Tuple{Any} && supertype(Tuple{Int}) === Any
    @test cov._implementors[Tuple{Any}] == DataType[c for c in cconc if c <: Tuple{Any}]
    @test all(((k, c),) -> (c <: k) == any(r -> contains(r, cov.class_ids[c]), D.get_concrete_class_id_range(cov, k)),
              [(k, c) for k in cov.dfs_order for c in cconc])
    @test any(r -> contains(r, cov.class_ids[Tuple{Int}]), D.get_concrete_class_id_range(cov, Tuple{Any}))
    @test D.get_concrete_class_id_range(cov, Type{Union{}}) == [D.Range(cov.class_ids[Core.TypeofBottom], cov.class_ids[Core.TypeofBottom])]
    # a singleton type as a value: its member Int isa Type{Int}, yet no class is <: it, so the range
    # query rejects, located (audit A41S3)
    @test Int isa Type{Int} && !(DataType <: Type{Int})
    local e3 = try; D.get_concrete_class_id_range(cov, Type{Int}); nothing; catch x; x; end
    @test e3 isa W.RejectionError && e3.rejection isa W.Unquarantined
    # a covariant Tuple class is abstract: no value has it exactly
    @test W.class_is_abstract(Tuple{Any}) && !W.class_is_abstract(Tuple{Int})
    # the translator's late classIdNumbering, read before ClassInfoCollector.collect assigns it
    local e2 = try; translator(ClassInfoCases.f_shapes, (Int,)).class_id_numbering[]; nothing; catch x; x; end
    @test e2 isa W.RejectionError && e2.rejection isa W.Unported && occursin("Translator.classIdNumbering", e2.rejection.anchor)
end

@testset "class_info.dart: FieldIndex and the top-level constants" begin
    # the object header: the class id first, then the identity hash, then the class's own fields
    @test D.FieldIndex_class_id() == 0 && D.FieldIndex_identity_hash() == 1 && D.FieldIndex_object_field_base() == 2
    @test D.FieldIndex_box_value() == 1 && D.FieldIndex_record_field_base() == 2
    @test D.FieldIndex_closure_context() == 2 && D.FieldIndex_closure_vtable() == 3 && D.FieldIndex_closure_runtime_type() == 4
    @test D.FieldIndex_function_type_named_parameters() == 9 && D.FieldIndex_ffi_pointer_address() == 3
    @test D.initial_identity_hash() == 0 && D.anonymous_mixin_class_id() == -1
    @test D.FieldIndex() isa D.FieldIndex
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
    @test [(f.name, f.type, f.index) for f in fields(DataType)] == [("isDeclaredNullable", Bool, 0), ("classId", Int32, 0)]
    @test [f.name for f in fields(Core.TypeofBottom)] == ["isDeclaredNullable"]
    @test [f.name for f in fields(Union)] == ["isDeclaredNullable", "a", "b"]
    # a class whose data Julia holds outside its fields rejects, located
    for c in (String, Symbol)
        local e = try; fields(c); nothing; catch x; x; end
        @test e isa W.RejectionError && e.rejection isa W.Unquarantined
    end
    # the collector over a translator: no class masquerades in Julia; typeType, read only for a
    # class's type parameters, which Julia's classes do not have, stays unassigned
    local t = D.Translator(W.check_subset(ClassInfoCases.f_shapes, (Int,), at), D.TranslatorOptions(optimization_level = 2))
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
    local t = D.Translator(W.check_subset(S.f_shapes, (Int,), "class_info"), D.TranslatorOptions())
    for info in (circle, square)
        info._repr = info.non_nullable_type
        t.class_for_heap_type[info.struct_] = info
    end
    push!(circle.struct_.fields, IR.FieldType(circle.non_nullable_type; mutable = false))
    push!(square.struct_.fields, IR.FieldType(square.nullable_type; mutable = false))
    @test D._calculate_cyclicness(circle, t) && D.is_cyclic(circle)
    @test !D._calculate_cyclicness(square, t) && !D.is_cyclic(square)
end
