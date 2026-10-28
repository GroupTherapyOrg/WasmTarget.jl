# The closed world's classes (src/julia/classes.jl, dev/MARCH.md 1.C): the types the NIR carries, in
# the order the walk first meets them, each with its supertype chain to Any, a type as a value by
# its kind, a UnionAll value a located rejection. The class-id numbering reads this list
# (class_info.dart:864, its model dev/formal/ClassIdNumbering.tla).
using Test
using WasmTarget

module ClassesCases
struct Pt; x::Float64; y::Int32; end
f_arith(a::Int, b::Int) = a < b ? a + b : a * b
f_struct(n::Int) = n > 0 ? Pt(1.0, Int32(n)) : nothing
f_vector(v::Vector{Int}) = sum(v)
# a field of the UnionAll type Vector: the entry is concrete (an entry typed Vector has no compileable
# specialization, so Julia's subset check rejects it first), the value the walk meets is not
struct Open; v::Vector; end
f_open(o::Open) = length(o.v)
@enum Hue red blue
f_enum(c::Hue) = c == red ? 1 : 2
end

const W = WasmTarget
_classes(f, at) = W.closed_world_classes(W.build_nir(W.check_subset(f, at, "classes"), "classes"), "classes")

@testset "the closed world's classes (1.C)" begin
    # the kinds are Julia's own
    @test all(k -> Base.iskindtype(k) && isconcretetype(k), W._KINDS)
    for (f, at) in ((ClassesCases.f_arith, (Int, Int)), (ClassesCases.f_struct, (Int,)),
                    (ClassesCases.f_vector, (Vector{Int},)), (ClassesCases.f_enum, (ClassesCases.Hue,)))
        local cs = _classes(f, at)
        # each class once by identity (Julia's TypeofBottom and its supertype Type{Union{}} are
        # distinct objects Julia calls equal types, two classes), Any among them, every class's
        # supertype a class: one tree rooted at Any
        @test length(Base.IdSet{DataType}(cs)) == length(cs)
        @test Any in cs
        @test all(c -> supertype(c) in cs, cs)
        # the program's first argument, the callable, is met first
        @test first(cs) === typeof(f)
    end
    # program order: the arguments before the statements' types, a struct's fields after it
    local cs = _classes(ClassesCases.f_struct, (Int,))
    @test cs[1:4] == [typeof(ClassesCases.f_struct), Function, Any, Int64]
    @test findfirst(==(ClassesCases.Pt), cs) < findfirst(==(Float64), cs)
    @test ClassesCases.Pt in cs && Int32 in cs && Nothing in cs
    # a type as a value is met by its kind: throw_inexacterror's `Type` argument brings every kind
    @test all(k -> k in cs, W._KINDS)
    @test Type{Union{}} in cs              # TypeofBottom's supertype, as Julia gives it
    # a parametric instance is a class of its own, its supertype chain Julia's
    local vs = _classes(ClassesCases.f_vector, (Vector{Int},))
    @test Vector{Int} in vs && DenseVector{Int} in vs && AbstractVector{Int} in vs && Memory{Int} in vs
    @test !(Vector in vs)
    # an @enum is a class under its Enum supertype
    @test ClassesCases.Hue in _classes(ClassesCases.f_enum, (ClassesCases.Hue,))
    # a value of a UnionAll type not under Type rejects, located at the walk
    local e = try; _classes(ClassesCases.f_open, (ClassesCases.Open,)); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Unquarantined && occursin("src/julia/classes.jl", e.rejection.row)
end

module ClassesTypeValueCases
f_type(::Type{T}) where {T} = T
f_vec_eltype(n::Int) = n > 0 ? Vector{Int} : Vector{Float64}
end

@testset "classes: a type value brings the classes it denotes" begin
    local W = WasmTarget
    local cs(f, at) = W.closed_world_classes(W.build_nir(W.check_subset(f, at, "classes"), "classes"), "classes")
    # Type{Int8}: its kind, DataType, and Int8 itself, whose class id a type value's layout holds
    local c = cs(ClassesTypeValueCases.f_type, (Type{Int8},))
    @test DataType in c && Int8 in c
    # a Union of type values: each member it can denote
    local c2 = cs(ClassesTypeValueCases.f_vec_eltype, (Int,))
    @test Vector{Int} in c2 && Vector{Float64} in c2
end
