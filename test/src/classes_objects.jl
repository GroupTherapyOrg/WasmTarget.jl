# The closed world's classes (src/julia/classes.jl, dev/MARCH.md 1.C), the objects a module builds: an empty
# mutable struct, a constant's object graph, egal by identity, a Memory and a MemoryRef, #undef slots, a constant
# DAG and a type value's parameters, each module run against native Julia. Split from test/src/classes.jl, every
# testset verbatim; its other half is test/src/classes_world.jl.
using Test
using WasmTarget

const W = WasmTarget
_classes(f, at) = W.closed_world_classes(W.build_nir(W.check_subset(f, at, "classes", Base.get_world_counter()), "classes"), "classes")

isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module EmptyMutableCases
mutable struct Token end
@noinline make(x::Int) = x > 0 ? Token() : nothing
made(x::Int) = make(x) isa Token
end

@testset "a mutable struct with no fields holds nothing, each instance its own object" begin
    # Julia's layout: no field and nothing outside one; identity is the object's (=== tells two apart)
    @test fieldcount(EmptyMutableCases.Token) == 0 && !Base.issingletontype(EmptyMutableCases.Token)
    @test W.class_instance_fields(EmptyMutableCases.Token, "classes") == W.ClassField[]
    @test EmptyMutableCases.Token in _classes(EmptyMutableCases.made, (Int,))
    local f = EmptyMutableCases.made
    local bytes = W.compile(f, (Int,))
    for r in WTChild.run_cases([WTChild.RunCase("made$(a)", bytes, a, f(a...)) for a in [(1,), (0,), (-2,)]])
        @test r.ok || (@info r.label r.why; false)
    end
end

module ConstantGraphCases
# a constant whose field, declared Any, holds a Float64: the Float64 only the value tells
mutable struct Box; v::Any; end
const B = Box(2.5)
boxed(x::Int) = x > 0 ? B : nothing
# a type as a value, its parameters' classes held by its layout
params() = Tuple{Int8,String}
# a binding no const holds, read as a statement of its own (a GlobalRef statement, Kernel's StaticGet):
# its starting value, the constant its lazy initializer instantiates, holds a Held only the value tells
struct Held; x::Int64; end
held::Vector{Any} = Any[Held(7)]
read_held(n::Int64) = (v = held[1]; v === nothing ? 0 : n + 1)
end

@testset "a constant's object graph brings its values' classes (dev/formal/ValueClasses.tla)" begin
    # Julia's answer: each value a constant holds has its own class, typeof, which its declared field
    # type (Any) does not tell; constants.jl instantiates each, so the closed world numbers each
    local cs = _classes(ConstantGraphCases.boxed, (Int,))
    @test ConstantGraphCases.Box in cs && Float64 in cs
    @test W.compile(ConstantGraphCases.boxed, (Int,))[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    # a type value's own fields: DataType's parameters, an svec of the classes the type names
    local ps = _classes(ConstantGraphCases.params, ())
    @test DataType in ps && Core.SimpleVector in ps && Int8 in ps && String in ps
    # a binding read as a statement brings its value's graph, as an operand's does
    local hs = _classes(ConstantGraphCases.read_held, (Int64,))
    @test ConstantGraphCases.Held in hs && Vector{Any} in hs
    local held_bytes = W.compile(ConstantGraphCases.read_held, (Int64,))
    for r in WTChild.run_cases([WTChild.RunCase("held$(a)", held_bytes, a, ConstantGraphCases.read_held(a...)) for a in [(1,), (-3,)]])
        @test r.ok || (@info r.label r.why; false)
    end
end

module EgalCases
mutable struct Box; x::Int; end
struct Pair2; a::Int; end
# a field of a type as a value: the receiver Julia types Type{X}, its class X's kind (DataType)
nparams(n::Int64) = Core._svec_len(Tuple{Int64,Float64,Bool}.parameters) + n
end

@testset "egal_by_identity: Julia's egal by identity for a mutable class, by content for String, SimpleVector and DataType" begin
    # Julia's own answer: two equal-content Strings are distinct objects yet egal, so String is compared
    # by content though mutable; so are a SimpleVector and a DataType (builtins.c jl_egal__unboxed_)
    local a = string(1, 2); local b = string(1, 2)
    @test a === b && pointer(a) != pointer(b)
    @test !W.egal_by_identity(String) && !W.egal_by_identity(Core.SimpleVector) && !W.egal_by_identity(DataType)
    @test W.egal_by_identity(EgalCases.Box) && !W.egal_by_identity(EgalCases.Pair2) && !W.egal_by_identity(Int)
    @test EgalCases.Box(1) !== EgalCases.Box(1) && EgalCases.Pair2(1) === EgalCases.Pair2(1)
end

@testset "a binding's value at compile time is nir_binding_value's, a tear-off's too; a type as a value reads its kind's layout" begin
    local D = W.Dart2Wasm
    local IR = W.WasmBuilder.IR
    local t = D.Translator(W.build_nir(W.check_subset(EmptyMutableCases.made, (Int,), "classes", Base.get_world_counter()), "classes"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local mi = only(nb.ci.def for nb in t.component if nb.ci.def.def.name === :made)
    local g = D.get_inlinable_member_code_generator(t, IR.FunctionType(IR.ValueType[], IR.ValueType[]), mi)
    # Base's stdout is host state Base.__init__ set: the tear-off's read of it rejects there, located
    local e = try; D.visit_static_tear_off(g, W.NirGlobal(W.nir_binding!(W.NirBindings(t.component.world), GlobalRef(Base, :stdout))), IR.NumType_i32); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Unquarantined && occursin("Base.__init__", e.rejection.row)
    # Tuple{...}.parameters: a getfield of a type constant, its class DataType, run against native
    local f = EgalCases.nparams
    local bytes = W.compile(f, (Int64,); optimize = false)
    for r in WTChild.run_cases([WTChild.RunCase("nparams$(a)", bytes, a, f(a...)) for a in [(0,), (4,), (-3,)]])
        @test r.ok || (@info r.label r.why; false)
    end
end

module MemoryCases
alloc(n::Int) = Vector{Int}(undef, n)
names(n::Int) = Vector{String}(undef, n)
end

@testset "a Memory is its elements in one wasm array and Julia's length; a MemoryRef its index and memory" begin
    local M, R = Memory{Int}, Core.MemoryRef{Int}
    # Julia's layout: length and ptr, the elements inline after them; ptr_or_offset and mem
    @test fieldnames(M) == (:length, :ptr) && fieldnames(R) == (:ptr_or_offset, :mem)
    # the elements one array of their storage class (an Int64 unboxed, a String a nullable reference),
    # Julia's own length beside it, ptr left out; the reference's offset an index, then its memory
    @test W.class_instance_fields(M, "classes") == [W.ClassField(M, 0, "data", W.WasmArray{W.WasmI64}, false), W.ClassField(M, 1, "length", Int, false)]
    @test W.class_instance_fields(Memory{String}, "classes")[1].type === W.WasmArray{Union{String,Nothing}}
    @test W.class_instance_fields(Memory{Float64}, "classes")[1].type === W.WasmArray{W.WasmF64}
    @test W.class_instance_fields(Memory{Bool}, "classes")[1].type === W.WasmArray{W.WasmI8}
    # elements that may hold nothing keep a set flag each (dart's late lowering, useIsSetField), one i8
    # array beside the data; a reference excluding nothing, or an inline bits union, none
    @test [f.name for f in W.class_instance_fields(Memory{Any}, "classes")] == ["data", "data#isSet", "length"]
    @test W.class_instance_fields(Memory{Union{Nothing,String}}, "classes")[2] == W.ClassField(Memory{Union{Nothing,String}}, 0, "data#isSet", W.WasmArray{W.WasmI8}, false)
    @test [f.name for f in W.class_instance_fields(Memory{String}, "classes")] == ["data", "length"]
    @test [f.name for f in W.class_instance_fields(Memory{Union{Nothing,Int}}, "classes")] == ["data", "length"]
    @test W.class_instance_fields(R, "classes") == [W.ClassField(R, 1, "ptr_or_offset", Int, false), W.ClassField(R, 2, "mem", M, false)]
    # the index is Julia's own value of ptr_or_offset only for a memory of union or zero-size elements
    # (base/pointer.jl unsafe_convert); a read of it for any other memory, Julia's address, rejects
    local ru = W.memoryref_address_unread(W.class_instance_fields(R, "classes")[1])
    @test ru isa W.Unquarantined && occursin("ptr_or_offset of a MemoryRef{$Int}, Julia's element address", ru.row)
    @test W.memoryref_address_unread(W.class_instance_fields(R, "classes")[2]) === nothing
    for T in (Union{Nothing,Int}, Nothing)
        local RT = Core.MemoryRef{T}
        @test W.memoryref_address_unread(W.class_instance_fields(RT, "classes")[1]) === nothing
    end
    # an atomic memory, a primitive with no storage class: located rejections
    local e = try; W.class_instance_fields(AtomicMemory{Int}, "classes"); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Unquarantined
    local e2 = try; W.class_instance_fields(Memory{Int128}, "classes"); nothing; catch x; x; end
    @test e2 isa W.RejectionError && e2.rejection isa W.Unquarantined
    # a Vector's own fields, its MemoryRef and its size, bring the memory and the reference
    local cs = _classes(MemoryCases.alloc, (Int,))
    @test Vector{Int} in cs && R in cs && M in cs && !(Ptr{Nothing} in cs)
    @test String in _classes(MemoryCases.names, (Int,))
    # class_info.dart's collector lays each out: the memory's struct, the header, then data and length
    local D = W.Dart2Wasm
    local t = D.Translator(W.build_nir(W.check_subset(MemoryCases.alloc, (Int,), "classes", Base.get_world_counter()), "classes"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    @test haskey(t.class_info, M) && haskey(t.class_info, R) && haskey(t.class_info, Vector{Int})
end

module IsSetCases
# fields an inner constructor may leave undefined: a bits one (unspecified bits), one that cannot be
# nothing (null for unset), two that may (each its set flag) and an inline bits union (never #undef)
mutable struct Part
    a::Int
    b::Int
    s::String
    c::Any
    d::Union{Nothing,String}
    u::Union{Nothing,Int}
    Part(a) = new(a)
end
struct Frozen
    x::Any
    Frozen() = new()
end
end

@testset "#undef is dart's late lowering: a potentially nullable slot keeps an isSet flag, any other null" begin
    local P, F = IsSetCases.Part, IsSetCases.Frozen
    # Julia's answer for which fields an inner constructor may leave out
    @test P.name.n_uninitialized == 5 && F.name.n_uninitialized == 1
    @test [W.field_may_be_null(P, i) for i in 1:6] == [false, false, true, true, true, false]
    local fs = W.class_instance_fields(P, "classes")
    # Julia's fields, then a flag for each field that may be unset and may hold nothing, index 0
    @test [f.name for f in fs] == ["a", "b", "s", "c", "d", "u", "c#isSet", "d#isSet"]
    @test fs[7] == W.ClassField(P, 0, "c#isSet", Bool, true) && W.class_is_set_field(fs[5]) == fs[8]
    @test W.class_is_set_field(fs[3]) === nothing && W.class_is_set_field(fs[6]) === nothing
    @test W.class_instance_fields(F, "classes")[2] == W.ClassField(F, 0, "x#isSet", Bool, false)
end

# A constant whose immutable fields share heap objects: a 41-node DAG, each node's two children the same
# node, has 2^40 paths. The walk meets each object once (dev/formal/ValueClasses.tla's seenObj), an
# immutable one by ===, so it ends in linear time; walking every path never ended (dart_const/constant_dag)
module ClassesDagCases
struct Node
    a::Union{Nothing,Node}
    b::Union{Nothing,Node}
end
depth(n::Node)::Int64 = (local a = n.a; a === nothing ? Int64(0) : 1 + depth(a))
const DAG = let n = Node(nothing, nothing)
    for _ in 1:40
        n = Node(n, n)
    end
    n
end
f(x::Int64) = depth(DAG) * x
end

@testset "a constant DAG's walk meets each object once" begin
    local t = @elapsed (local cs = _classes(ClassesDagCases.f, (Int64,)))
    @test ClassesDagCases.Node in cs
    @test t < 60
end

# A type value's layout holds the id of the class it denotes (constants.dart:430 _makeInterfaceTypeConstant,
# dart's classIds[type.classNode]): a UnionAll's body, a DataType with a free type variable, denotes itself, a
# class no value has; and every class's type value (the typeof table) holds its parameters, each a type value
# whose class the closed world numbers
module ClassesTypeParamCases
struct Inner{T} end
struct Outer{T<:Inner} end
body(x::Int64) = (v = Any[Vector, Int64]; u = v[x]; u isa UnionAll ? (u.body isa DataType ? 1 : 2) : 0)
same(n::Int64) = typeof(n == 1 ? Outer{Inner{Int64}}() : Outer{Inner{String}}()) === Outer{Inner{Int64}}
end

@testset "a type value's classes: a UnionAll's body, and each class's type parameters" begin
    local cs = _classes(ClassesTypeParamCases.body, (Int64,))
    @test Vector.body in cs && W.class_is_abstract(Vector.body) && TypeVar in cs
    local ps = _classes(ClassesTypeParamCases.same, (Int64,))
    @test ClassesTypeParamCases.Inner{String} in ps && ClassesTypeParamCases.Inner{Int64} in ps
    for f in (ClassesTypeParamCases.body, ClassesTypeParamCases.same)
        local bytes = W.compile(f, (Int64,))
        for r in WTChild.run_cases([WTChild.RunCase("$(nameof(f))$(a)", bytes, a, f(a...)) for a in [(1,), (2,)]])
            @test r.ok || (@info r.label r.why; false)
        end
    end
end
