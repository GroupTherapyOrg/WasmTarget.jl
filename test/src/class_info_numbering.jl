# dart2wasm's class_info.dart, ported (src/class_info.jl, dev/MARCH.md 1.C): each filled definition
# answers as dart's does on fixed inputs: Range, ClassIdNumbering and FieldIndex. Split from test/src/class_info.jl,
# every testset verbatim; its other half is test/src/class_info_fields.jl.
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

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

@testset "class_info.dart: ClassIdNumbering on the closed world" begin
    local W = WasmTarget
    local translator(f, at) = D.Translator(WasmTarget.build_nir(W.check_subset(f, at, "class_info", Base.get_world_counter()), "test"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
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
        # (the model's RangeIsa), an open tuple type its arities' records, a concrete tuple boxed into one
        # (the record model, src/julia/classes.jl open_tuple_holds; the runtime's roots bring `Tuple`)
        # the arities the records cover are set once, with the class ids: the record classes of the
        # closed world's, each covered arity's record class among its concrete classes
        @test n.covered_arities == W.record_arities(conc) == W.record_arities(n.dfs_order)
        @test all(a -> any(c -> W.tuple_record_arity(c) == W.FixedArity(a), conc), n.covered_arities)
        local holds(k, c) = k <: Tuple && !isconcretetype(k) ? W.open_tuple_holds(k, c, n.covered_arities) : c <: k
        @test all(((k, c),) -> holds(k, c) == any(r -> contains(r, n.class_ids[c]), D.get_concrete_class_id_range(n, k)),
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
    # Julia's <: says it is a subtype, the implementors' ranges merged in; an open tuple type's ranges
    # hold the records of the arities it admits (TupleRecord), its values' classes, a concrete tuple
    # being boxed into its record where it flows into an open slot
    local cov = number(ClassInfoCases.f_cov, (ClassInfoCases.Holder, Tuple{Int}, Int))
    local cconc = filter(isconcretetype, cov.dfs_order)
    @test Tuple{Any} in cov.dfs_order && Tuple{Int} in cov.dfs_order && Core.TypeofBottom in cov.dfs_order && Type{Union{}} in cov.dfs_order
    @test W.tuple_record_class(1) in cov.dfs_order
    @test Tuple{Int} <: Tuple{Any} && supertype(Tuple{Int}) === Any
    @test cov._implementors[Tuple{Any}] == DataType[c for c in cconc if c <: Tuple{Any}]
    local holds(k, c) = k isa DataType && k <: Tuple && !isconcretetype(k) ?
        (local r = W.tuple_record_arity(c); r isa W.FixedArity && typeintersect(k, NTuple{r.n,Any}) !== Union{}) : c <: k
    @test all(((k, c),) -> holds(k, c) == any(r -> contains(r, cov.class_ids[c]), D.get_concrete_class_id_range(cov, k)),
              [(k, c) for k in cov.dfs_order for c in cconc])
    @test D.get_concrete_class_id_range(cov, Tuple{Any}) == [D.Range(cov.class_ids[W.tuple_record_class(1)], cov.class_ids[W.tuple_record_class(1)])]
    @test D.get_concrete_class_id_range(cov, Type{Union{}}) == [D.Range(cov.class_ids[Core.TypeofBottom], cov.class_ids[Core.TypeofBottom])]
    # a singleton type as a value: its one member Int isa Type{Int} (jl_isa's Type{T} arm), yet no class
    # is <: it; its classes are its member's class, Int's kind DataType (a class set, never a test)
    @test Int isa Type{Int} && !(DataType <: Type{Int})
    @test D.get_concrete_class_id_range(cov, Type{Int}) == D.get_concrete_class_id_range(cov, DataType)
    # that class set is never a membership test: an isa over a Type{Int64} slot holding a DataType of the
    # same kind (Float64) is the value's run-time test, jl_isa's jl_types_equal, never a class-id check
    # answering true for every DataType: Int64 is in it and Float64 is not, as natively
    local kb = W.compile(ClassInfoCases.kind_isa, (Int64,))
    for r in Main.WTChild.run_cases([Main.WTChild.RunCase("kind_isa$(a)", kb, a, ClassInfoCases.kind_isa(a...)) for a in [(1,), (2,)]])
        @test r.ok || (@info r.label r.why; false)
    end
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
