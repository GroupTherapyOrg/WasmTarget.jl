# PURE-4123: Full intersection verification — 200+ type pairs, ALL must match native
# Gate test for M_INTERSECTION_IMPL milestone.
# Includes: concrete, abstract, Union, Tuple, Vararg, UnionAll, TypeVar, parametric,
#           user-defined types, DictMethodTable-relevant cases.
# Zero tolerance for divergence. 100% match rate required.

include(joinpath(@__DIR__, "..", "src", "typeinf", "subtype.jl"))

# Collect all type pairs and results
passed = 0
failed = 0
errors = Pair{String,String}[]

function check_intersection(@nospecialize(a), @nospecialize(b))
    global passed, failed
    expected = typeintersect(a, b)
    actual = wasm_type_intersection(a, b)
    if actual == expected
        passed += 1
    else
        failed += 1
        push!(errors, "$a ∩ $b" => "expected=$expected, got=$actual")
    end
end

# ─── User-defined types for testing (NOT in any pre-computed Dict) ────────────

struct TestPoint
    x::Float64
    y::Float64
end

struct TestContainer{T}
    value::T
    label::String
end

abstract type TestShape end
struct TestCircle <: TestShape
    radius::Float64
end
struct TestSquare <: TestShape
    side::Float64
end

# ============================================================
# Section 1: Concrete numeric types — identity and disjoint
# ============================================================
concrete_numerics = [
    Bool, Int8, Int16, Int32, Int64, Int128,
    UInt8, UInt16, UInt32, UInt64, UInt128,
    Float16, Float32, Float64,
]

for a in concrete_numerics
    for b in concrete_numerics
        check_intersection(a, b)  # a ∩ b = a when a===b, else Union{}
    end
end
# 14*14 = 196 pairs

# ============================================================
# Section 2: Concrete vs abstract numerics
# ============================================================
abstract_numerics = [Number, Real, Integer, AbstractFloat, Signed, Unsigned]

for a in concrete_numerics
    for b in abstract_numerics
        check_intersection(a, b)  # a ∩ b = a if a <: b, else Union{}
        check_intersection(b, a)  # b ∩ a = a if a <: b, else Union{}
    end
end
# 14*6*2 = 168 pairs

# ============================================================
# Section 3: Abstract vs abstract numerics
# ============================================================
for a in abstract_numerics
    for b in abstract_numerics
        check_intersection(a, b)
    end
end
# 6*6 = 36 pairs

# ============================================================
# Section 4: Any and Union{} with everything
# ============================================================
basic_types = [Int64, Float64, String, Bool, Nothing, Missing, Any, Union{}]

for t in basic_types
    check_intersection(Any, t)     # Any ∩ T = T
    check_intersection(t, Any)     # T ∩ Any = T
    check_intersection(Union{}, t) # Union{} ∩ T = Union{}
    check_intersection(t, Union{}) # T ∩ Union{} = Union{}
end
# 8*4 = 32 pairs

# ============================================================
# Section 5: Non-numeric concrete types — disjoint
# ============================================================
other_concrete = [String, Symbol, Char, Nothing, Missing, Bool]

for a in other_concrete
    for b in other_concrete
        check_intersection(a, b)
    end
end
# 6*6 = 36 pairs

# ============================================================
# Section 6: String/Char with abstract hierarchy
# ============================================================
string_abstract = [AbstractString, AbstractChar]
for a in [String, SubString{String}]
    for b in string_abstract
        check_intersection(a, b)
        check_intersection(b, a)
    end
end
check_intersection(Char, AbstractChar)
check_intersection(AbstractChar, Char)
# ~10 pairs

# ============================================================
# Section 7: Simple Union intersections
# ============================================================
check_intersection(Union{Int64,Float64}, Int64)
check_intersection(Int64, Union{Int64,Float64})
check_intersection(Union{Int64,Float64}, Float64)
check_intersection(Union{Int64,Float64}, String)
check_intersection(Union{Int64,Float64}, Union{Float64,String})
check_intersection(Union{Int64,Float64,String}, Union{Float64,String,Bool})
check_intersection(Union{Int64,Float64}, Union{String,Symbol})
check_intersection(Union{Int64,Nothing}, Nothing)
check_intersection(Union{Int64,Nothing}, Int64)
check_intersection(Union{Int64,Nothing}, Union{Nothing,Float64})
# 10 pairs

# ============================================================
# Section 8: Union with abstract types
# ============================================================
check_intersection(Union{Int64,Float64}, Number)
check_intersection(Union{Int64,Float64}, Integer)
check_intersection(Union{Int64,Float64}, AbstractFloat)
check_intersection(Union{Int64,String}, Real)
check_intersection(Union{Int64,String}, AbstractString)
check_intersection(Number, Union{Int64,String})
check_intersection(Integer, Union{Int64,Float64})
check_intersection(AbstractFloat, Union{Int64,Float64})
# 8 pairs

# ============================================================
# Section 9: Nested Unions
# ============================================================
check_intersection(Union{Union{Int64,Float64},String}, Int64)
check_intersection(Union{Union{Int64,Float64},String}, Union{Float64,Symbol})
check_intersection(Union{Int64,Union{Float64,String}}, Union{String,Union{Bool,Char}})
check_intersection(Union{Int64,Float64,String}, Union{Float64,String,Bool})
# 4 pairs

# ============================================================
# Section 10: Basic Tuples — same length, no Vararg
# ============================================================
check_intersection(Tuple{Int64,Float64}, Tuple{Int64,Float64})
check_intersection(Tuple{Int64,Float64}, Tuple{Int64,String})
check_intersection(Tuple{Int64,Float64}, Tuple{String,Float64})
check_intersection(Tuple{Int64}, Tuple{Float64})
check_intersection(Tuple{Int64}, Tuple{Int64})
check_intersection(Tuple{}, Tuple{})
check_intersection(Tuple{Int64,Float64}, Tuple{Number,Real})
check_intersection(Tuple{Number,Real}, Tuple{Int64,Float64})
check_intersection(Tuple{Int64,Float64,String}, Tuple{Int64,Float64,String})
check_intersection(Tuple{Int64,Float64,String}, Tuple{Int64,Float64,Symbol})
# 10 pairs

# ============================================================
# Section 11: Tuple length mismatch
# ============================================================
check_intersection(Tuple{Int64}, Tuple{Int64,Float64})
check_intersection(Tuple{Int64,Float64}, Tuple{Int64})
check_intersection(Tuple{Int64,Float64,String}, Tuple{Int64,Float64})
check_intersection(Tuple{}, Tuple{Int64})
# 4 pairs

# ============================================================
# Section 12: Tuple with Union elements
# ============================================================
check_intersection(Tuple{Union{Int64,Float64},String}, Tuple{Int64,String})
check_intersection(Tuple{Union{Int64,Float64},String}, Tuple{Float64,String})
check_intersection(Tuple{Union{Int64,Float64},String}, Tuple{Bool,String})
check_intersection(Tuple{Int64,Union{String,Symbol}}, Tuple{Int64,String})
check_intersection(Tuple{Union{Int64,Float64}}, Tuple{Union{Float64,String}})
check_intersection(Tuple{Union{Int64,Float64},Union{String,Symbol}}, Tuple{Int64,String})
# 6 pairs

# ============================================================
# Section 13: Tuple with abstract elements
# ============================================================
check_intersection(Tuple{Number}, Tuple{Int64})
check_intersection(Tuple{Int64}, Tuple{Number})
check_intersection(Tuple{Number,AbstractString}, Tuple{Int64,String})
check_intersection(Tuple{Integer,Real}, Tuple{Int64,Float64})
check_intersection(Tuple{Any}, Tuple{Int64})
check_intersection(Tuple{Any,Any}, Tuple{Int64,String})
# 6 pairs

# ============================================================
# Section 14: Vararg tuples — one side
# ============================================================
check_intersection(Tuple{Int64,Vararg{Float64}}, Tuple{Int64,Float64,Float64})
check_intersection(Tuple{Vararg{Int64}}, Tuple{Int64,Int64})
check_intersection(Tuple{Vararg{Int64}}, Tuple{Int64})
check_intersection(Tuple{Vararg{Int64}}, Tuple{})
check_intersection(Tuple{Vararg{Number}}, Tuple{Int64,Float64})
check_intersection(Tuple{Int64,Vararg{Any}}, Tuple{Int64,String,Float64})
check_intersection(Tuple{Vararg{Int64}}, Tuple{String})
check_intersection(Tuple{Int64,Vararg{Float64}}, Tuple{Int64})
# 8 pairs

# ============================================================
# Section 15: Vararg tuples — both sides
# ============================================================
check_intersection(Tuple{Vararg{Int64}}, Tuple{Vararg{Int64}})
check_intersection(Tuple{Vararg{Int64}}, Tuple{Vararg{Number}})
check_intersection(Tuple{Vararg{Number}}, Tuple{Vararg{Int64}})
check_intersection(Tuple{Vararg{Int64}}, Tuple{Vararg{String}})
check_intersection(Tuple{Int64,Vararg{Float64}}, Tuple{Int64,Vararg{Number}})
# 5 pairs

# ============================================================
# Section 16: Bool/Nothing edge cases
# ============================================================
check_intersection(Bool, Integer)
check_intersection(Integer, Bool)
check_intersection(Bool, Signed)
check_intersection(Nothing, Union{Nothing,Int64})
check_intersection(Union{Nothing,Missing}, Nothing)
check_intersection(Union{Nothing,Missing}, Missing)
check_intersection(Union{Nothing,Missing}, Union{Missing,Int64})
# 7 pairs

# ============================================================
# Section 17: Type{T} (singleton types)
# ============================================================
check_intersection(Type{Int64}, Type{Int64})
check_intersection(Type{Int64}, Type{Float64})
check_intersection(Type{Int64}, DataType)
check_intersection(DataType, Type{Int64})
check_intersection(Type{Int64}, Any)
check_intersection(Any, Type{Int64})
# 6 pairs

# ============================================================
# Section 18: Parametric invariant — same wrapper
# ============================================================
check_intersection(Vector{Int64}, Vector{Int64})
check_intersection(Vector{Int64}, Vector{Float64})
check_intersection(Vector{Int64}, Vector{Number})
check_intersection(Dict{String,Int64}, Dict{String,Int64})
check_intersection(Dict{String,Int64}, Dict{String,Float64})
check_intersection(Dict{String,Int64}, Dict{Symbol,Int64})
check_intersection(Set{Int64}, Set{Int64})
check_intersection(Set{Int64}, Set{Float64})
check_intersection(Ref{Int64}, Ref{Int64})
check_intersection(Ref{Int64}, Ref{Float64})
check_intersection(Pair{Int64,String}, Pair{Int64,String})
check_intersection(Pair{Int64,String}, Pair{Float64,String})
check_intersection(Pair{Int64,String}, Pair{Int64,Symbol})
check_intersection(Array{Int64,2}, Array{Int64,2})
check_intersection(Array{Int64,2}, Array{Int64,3})
check_intersection(Array{Int64,2}, Array{Float64,2})
# 16 pairs

# ============================================================
# Section 19: UnionAll — basic (concrete meets UnionAll)
# ============================================================
check_intersection(Vector{Int64}, AbstractVector{Int64})
check_intersection(AbstractVector{Int64}, Vector{Int64})
check_intersection(Vector{Int64}, AbstractArray{Int64})
check_intersection(Matrix{Float64}, AbstractArray{Float64})
check_intersection(Vector{Int64}, AbstractVector{Float64})
check_intersection(Vector{String}, AbstractVector{String})
# 6 pairs

# ============================================================
# Section 20: UnionAll — bounded TypeVar
# ============================================================
check_intersection(Vector{Int64}, Vector{<:Number})
check_intersection(Vector{<:Number}, Vector{Int64})
check_intersection(Vector{<:Integer}, Vector{<:Number})
check_intersection(Vector{<:Number}, Vector{<:Integer})
check_intersection(Vector{<:AbstractFloat}, Vector{Float64})
check_intersection(Vector{Float64}, Vector{<:AbstractFloat})
check_intersection(Vector{<:Integer}, Vector{<:AbstractFloat})
check_intersection(Vector{<:Real}, Vector{<:Number})
check_intersection(Vector{<:Number}, Vector{<:Real})
# 9 pairs

# ============================================================
# Section 21: UnionAll — abstract meets concrete
# ============================================================
check_intersection(AbstractVector{Int64}, Array{Int64,1})
check_intersection(AbstractDict{String,Int64}, Dict{String,Int64})
check_intersection(AbstractSet{Int64}, Set{Int64})
check_intersection(AbstractVector{Float64}, Vector{Int64})
check_intersection(AbstractArray{Int64,2}, Matrix{Int64})
# 5 pairs

# ============================================================
# Section 22: Two UnionAlls — same name
# ============================================================
check_intersection(Vector{<:Number}, Vector{<:Real})
check_intersection(Vector{<:Real}, Vector{<:Number})
check_intersection(AbstractVector{<:Integer}, AbstractVector{<:Number})
check_intersection(AbstractVector{<:Number}, AbstractVector{<:Integer})
# 4 pairs

# ============================================================
# Section 23: Multi-param UnionAll
# ============================================================
check_intersection(Dict{<:AbstractString,<:Number}, Dict{String,Int64})
check_intersection(Dict{String,Int64}, Dict{<:AbstractString,<:Number})
check_intersection(Array{<:Number,2}, Array{Float64,2})
check_intersection(Array{Float64,2}, Array{<:Number,2})
check_intersection(Pair{<:Integer,<:AbstractFloat}, Pair{Int64,Float64})
check_intersection(Pair{Int64,Float64}, Pair{<:Integer,<:AbstractFloat})
# 6 pairs

# ============================================================
# Section 24: Diagonal dispatch patterns (where T ... ::T, ::T)
# ============================================================
# Tuple{T,T} where T — diagonal constraint
check_intersection(Tuple{Int64,Int64}, (@NamedTuple{a::T,b::T} where T).types[1].body)  # Can't directly make Tuple{T,T} where T easily
# Use a simpler approach — intersect with Tuple types that exercise diagonal
let T = TypeVar(:T)
    diag_tt = UnionAll(T, Tuple{T,T})
    check_intersection(Tuple{Int64,Int64}, diag_tt)
    check_intersection(Tuple{Int64,Float64}, diag_tt)
    check_intersection(diag_tt, Tuple{String,String})
    check_intersection(diag_tt, Tuple{Int64,String})
    check_intersection(Tuple{Number,Number}, diag_tt)
end
let T = TypeVar(:T, Number)
    bounded_diag = UnionAll(T, Tuple{T,T})
    check_intersection(Tuple{Int64,Int64}, bounded_diag)
    check_intersection(Tuple{Int64,Float64}, bounded_diag)
end
# 7 pairs

# ============================================================
# Section 25: Tuple + UnionAll
# ============================================================
let T = TypeVar(:T)
    check_intersection(UnionAll(T, Tuple{T,Vector{T}}), Tuple{Int64,Vector{Int64}})
    check_intersection(UnionAll(T, Tuple{T,Vector{T}}), Tuple{Int64,Vector{Float64}})
    check_intersection(Tuple{Int64,Vector{Int64}}, UnionAll(T, Tuple{T,Vector{T}}))
end
let T = TypeVar(:T, Number)
    check_intersection(UnionAll(T, Tuple{T,T}), Tuple{Int64,Int64})
    check_intersection(UnionAll(T, Tuple{T,T}), Tuple{String,String})
    check_intersection(UnionAll(T, Tuple{T,T}), Tuple{Int64,Float64})
end
# 6 pairs

# ============================================================
# Section 26: Nested UnionAll
# ============================================================
check_intersection(Array{<:Number}, Vector{Int64})
check_intersection(Vector{Int64}, Array{<:Number})
let T = TypeVar(:T), S = TypeVar(:S)
    nested = UnionAll(T, UnionAll(S, Tuple{T,S}))
    check_intersection(nested, Tuple{Int64,String})
    check_intersection(Tuple{Int64,String}, nested)
end
# 4 pairs

# ============================================================
# Section 27: Type{T} with UnionAll
# ============================================================
let T = TypeVar(:T)
    check_intersection(UnionAll(T, Type{T}), Type{Int64})
    check_intersection(Type{Int64}, UnionAll(T, Type{T}))
    check_intersection(UnionAll(T, Type{T}), DataType)
end
# 3 pairs

# ============================================================
# Section 28: Commutativity for UnionAll pairs
# ============================================================
check_intersection(Vector{<:Number}, Vector{Int64})
check_intersection(Vector{Int64}, Vector{<:Number})
check_intersection(AbstractVector{Int64}, Vector{Int64})
check_intersection(Vector{Int64}, AbstractVector{Int64})
check_intersection(Array{<:Number,2}, Matrix{Float64})
check_intersection(Matrix{Float64}, Array{<:Number,2})
# 6 pairs

# ============================================================
# Section 29: Complex combinations (UnionAll + Union + Tuple)
# ============================================================
check_intersection(Union{Vector{Int64},Vector{Float64}}, AbstractVector{Int64})
check_intersection(AbstractVector{Int64}, Union{Vector{Int64},Vector{Float64}})
check_intersection(Union{Vector{Int64},Vector{Float64}}, Vector{<:Number})
# 3 pairs

# ============================================================
# Section 30: UnionAll × Union
# ============================================================
check_intersection(Vector{<:Number}, Union{Vector{Int64},Vector{String}})
check_intersection(Union{Vector{Int64},Vector{String}}, Vector{<:Number})
check_intersection(AbstractVector{<:Integer}, Union{Vector{Int64},Vector{Float64}})
# 3 pairs

# ============================================================
# Section 31: UnionAll × Any/Union{}
# ============================================================
check_intersection(Vector{<:Number}, Any)
check_intersection(Any, Vector{<:Number})
check_intersection(Vector{<:Number}, Union{})
check_intersection(Union{}, Vector{<:Number})
# 4 pairs

# ============================================================
# Section 32: Identity (UnionAll with itself)
# ============================================================
check_intersection(Vector{<:Number}, Vector{<:Number})
check_intersection(AbstractVector{Int64}, AbstractVector{Int64})
# 2 pairs

# ============================================================
# Section 33: Array alias patterns
# ============================================================
check_intersection(Vector{Int64}, Array{Int64,1})
check_intersection(Array{Int64,1}, Vector{Int64})
check_intersection(Matrix{Float64}, Array{Float64,2})
# 3 pairs

# ============================================================
# Section 34: Concrete × abstract UnionAll
# ============================================================
check_intersection(Vector{Int64}, AbstractArray{Int64,1})
check_intersection(Matrix{Float64}, AbstractArray{Float64,2})
check_intersection(Dict{String,Int64}, AbstractDict{String,Int64})
# 3 pairs

# ============================================================
# Section 35: Lower-bounded TypeVar
# ============================================================
let T = TypeVar(:T, Integer, Any)
    check_intersection(UnionAll(T, Vector{T}), Vector{Int64})
    check_intersection(Vector{Int64}, UnionAll(T, Vector{T}))
end
# 2 pairs

# ============================================================
# Section 36: Val types
# ============================================================
check_intersection(Val{1}, Val{1})
check_intersection(Val{1}, Val{2})
# 2 pairs

# ============================================================
# Section 37: Vararg + UnionAll
# ============================================================
let T = TypeVar(:T)
    check_intersection(UnionAll(T, Tuple{T,Vararg{T}}), Tuple{Int64,Int64,Int64})
    check_intersection(Tuple{Int64,Int64,Int64}, UnionAll(T, Tuple{T,Vararg{T}}))
end
check_intersection(Tuple{Vararg{<:Number}}, Tuple{Int64,Float64})
# 3 pairs

# ============================================================
# Section 38: Deeply nested UnionAll
# ============================================================
let T = TypeVar(:T), S = TypeVar(:S)
    check_intersection(UnionAll(T, UnionAll(S, Dict{T,S})), Dict{String,Int64})
    check_intersection(Dict{String,Int64}, UnionAll(T, UnionAll(S, Dict{T,S})))
    check_intersection(UnionAll(T, UnionAll(S, Pair{T,S})), Pair{Int64,String})
end
# 3 pairs

# ============================================================
# Section 39: Complex union+tuple combos
# ============================================================
check_intersection(Tuple{Union{Int64,Float64},String}, Tuple{Number,AbstractString})
check_intersection(Tuple{Union{Int64,Float64}}, Tuple{Union{Float64,String}})
check_intersection(Union{Tuple{Int64},Tuple{Float64}}, Tuple{Int64})
check_intersection(Union{Tuple{Int64},Tuple{Float64}}, Tuple{String})
check_intersection(Tuple{Union{Int64,Float64},Union{String,Symbol}}, Tuple{Number,Any})
# 5 pairs

# ============================================================
# Section 40: General commutativity spot-checks
# ============================================================
comm_pairs = [
    (Int64, Float64),
    (Int64, Number),
    (Union{Int64,Float64}, String),
    (Union{Int64,Float64}, Union{Float64,String}),
    (Tuple{Int64,Float64}, Tuple{Number,Real}),
    (Tuple{Int64}, Tuple{Float64}),
    (Vector{Int64}, Vector{Float64}),
    (Bool, Integer),
]

for (a, b) in comm_pairs
    check_intersection(a, b)
    check_intersection(b, a)
end
# 8*2 = 16 pairs

# ============================================================
# Section 41: IO/AbstractString hierarchy
# ============================================================
check_intersection(IO, IOBuffer)
check_intersection(IOBuffer, IO)
check_intersection(IO, IOStream)
check_intersection(IOStream, IO)
check_intersection(AbstractString, String)
check_intersection(String, AbstractString)
check_intersection(AbstractString, SubString{String})
check_intersection(SubString{String}, AbstractString)
# 8 pairs

# ============================================================
# Section 42: Function types
# ============================================================
check_intersection(Function, typeof(+))
check_intersection(typeof(+), Function)
check_intersection(typeof(+), typeof(-))
check_intersection(typeof(+), typeof(+))
# 4 pairs

# ============================================================
# Section 43: User-defined types (NOT in any pre-computed Dict)
# ============================================================
check_intersection(TestPoint, TestPoint)
check_intersection(TestPoint, TestCircle)
check_intersection(TestCircle, TestSquare)
check_intersection(TestCircle, TestShape)
check_intersection(TestShape, TestCircle)
check_intersection(TestSquare, TestShape)
check_intersection(TestShape, TestSquare)
check_intersection(TestShape, TestShape)
check_intersection(TestPoint, Any)
check_intersection(Any, TestPoint)
check_intersection(TestPoint, Union{})
check_intersection(Union{}, TestPoint)
check_intersection(Union{TestCircle,TestSquare}, TestShape)
check_intersection(TestShape, Union{TestCircle,TestSquare})
check_intersection(Union{TestCircle,TestSquare}, TestCircle)
check_intersection(Union{TestCircle,TestPoint}, Union{TestSquare,TestPoint})
# 16 pairs

# ============================================================
# Section 44: User-defined parametric types
# ============================================================
check_intersection(TestContainer{Int64}, TestContainer{Int64})
check_intersection(TestContainer{Int64}, TestContainer{Float64})
check_intersection(TestContainer{Int64}, TestContainer{String})
check_intersection(TestContainer{<:Number}, TestContainer{Int64})
check_intersection(TestContainer{Int64}, TestContainer{<:Number})
check_intersection(TestContainer{<:Number}, TestContainer{<:Integer})
# 6 pairs

# ============================================================
# Section 45: DictMethodTable-relevant signature intersections
# These are the kinds of type intersections typeinf actually computes
# during method dispatch resolution.
# ============================================================

# Arithmetic dispatch signatures
check_intersection(Tuple{typeof(+),Int64,Int64}, Tuple{typeof(+),Number,Number})
check_intersection(Tuple{typeof(*),Float64,Float64}, Tuple{typeof(*),Number,Number})
check_intersection(Tuple{typeof(-),Int64,Int64}, Tuple{typeof(-),Number,Number})

# Comparison signatures
check_intersection(Tuple{typeof(<),Int64,Int64}, Tuple{typeof(<),Real,Real})
check_intersection(Tuple{typeof(==),Int64,Int64}, Tuple{typeof(==),Any,Any})
check_intersection(Tuple{typeof(<=),Float64,Float64}, Tuple{typeof(<=),Real,Real})

# Collection signatures
check_intersection(Tuple{typeof(push!),Vector{Int64},Int64}, Tuple{typeof(push!),Vector,Any})
check_intersection(Tuple{typeof(length),Vector{Int64}}, Tuple{typeof(length),AbstractArray})
check_intersection(Tuple{typeof(getindex),Vector{Int64},Int64}, Tuple{typeof(getindex),AbstractArray,Int64})

# String/IO signatures
check_intersection(Tuple{typeof(string),Int64}, Tuple{typeof(string),Any})
check_intersection(Tuple{typeof(print),IOBuffer,String}, Tuple{typeof(print),IO,AbstractString})

# Type conversion signatures
check_intersection(Tuple{typeof(convert),Type{Float64},Int64}, Tuple{typeof(convert),Type{Float64},Number})
check_intersection(Tuple{typeof(convert),Type{Int64},Float64}, Tuple{typeof(convert),Type{Int64},Number})

# Constructor signatures
check_intersection(Tuple{Type{Vector{Int64}},UndefInitializer,Int64}, Tuple{Type{Vector{Int64}},UndefInitializer,Int64})
# 14 pairs

# ============================================================
# Section 46: Method signature intersection patterns
# (Tuple types that arise during method table lookup)
# ============================================================
# Different arity
check_intersection(Tuple{typeof(+),Int64,Int64}, Tuple{typeof(+),Int64})
check_intersection(Tuple{typeof(+),Int64}, Tuple{typeof(+),Int64,Int64})

# Union-typed dispatch
check_intersection(Tuple{typeof(+),Union{Int64,Float64},Int64}, Tuple{typeof(+),Int64,Int64})
check_intersection(Tuple{typeof(+),Int64,Int64}, Tuple{typeof(+),Union{Int64,Float64},Int64})

# Abstract-typed dispatch
check_intersection(Tuple{typeof(+),Integer,Integer}, Tuple{typeof(+),Int64,Int64})
check_intersection(Tuple{typeof(+),Int64,Int64}, Tuple{typeof(+),Integer,Integer})

# Different function types (disjoint)
check_intersection(Tuple{typeof(+),Int64,Int64}, Tuple{typeof(*),Int64,Int64})
check_intersection(Tuple{typeof(sin),Float64}, Tuple{typeof(cos),Float64})
# 8 pairs

# ============================================================
# Section 47: Ref/Ptr types (invariant parametric)
# ============================================================
check_intersection(Ref{Int64}, Ref{Number})
check_intersection(Ref{Number}, Ref{Int64})
check_intersection(Ref{Int64}, Ref{<:Number})
check_intersection(Ref{<:Number}, Ref{Int64})
check_intersection(Ref{<:Integer}, Ref{<:Real})
check_intersection(Ref{<:Real}, Ref{<:Integer})
# 6 pairs

# ============================================================
# Section 48: NamedTuple intersection
# ============================================================
check_intersection(NamedTuple{(:a,:b),Tuple{Int64,Float64}}, NamedTuple{(:a,:b),Tuple{Int64,Float64}})
check_intersection(NamedTuple{(:a,:b),Tuple{Int64,Float64}}, NamedTuple{(:a,:b),Tuple{Float64,Float64}})
check_intersection(NamedTuple{(:a,),Tuple{Int64}}, NamedTuple{(:b,),Tuple{Int64}})
check_intersection(NamedTuple{(:a,:b),Tuple{Int64,Float64}}, NamedTuple{(:a,:b),Tuple{Number,Real}})
# 4 pairs

# ============================================================
# Section 49: AbstractArray hierarchy
# ============================================================
check_intersection(AbstractVector{Int64}, AbstractMatrix{Int64})
check_intersection(AbstractMatrix{Int64}, AbstractVector{Int64})
check_intersection(AbstractArray{Int64,1}, AbstractArray{Int64,2})
check_intersection(AbstractArray{Int64}, AbstractVector{Int64})
check_intersection(AbstractVector{Int64}, AbstractArray{Int64})
check_intersection(DenseArray{Int64,1}, Vector{Int64})
check_intersection(Vector{Int64}, DenseArray{Int64,1})
# 7 pairs

# ============================================================
# Section 50: Tuple with Vararg + UnionAll combined
# ============================================================
let T = TypeVar(:T)
    # Vararg{T} where T
    vt = UnionAll(T, Tuple{Vararg{T}})
    check_intersection(vt, Tuple{Int64,Int64})
    check_intersection(vt, Tuple{Int64,Float64})
    check_intersection(Tuple{Int64,Int64}, vt)
end
check_intersection(Tuple{Vararg{<:Integer}}, Tuple{Int64,Int64})
check_intersection(Tuple{Int64,Int64}, Tuple{Vararg{<:Integer}})
# 5 pairs

# ============================================================
# Print results
# ============================================================
total = passed + failed
println("=" ^ 60)
println("PURE-4123: Full intersection verification")
println("=" ^ 60)
println("Total pairs: $total")
println("CORRECT:     $passed")
println("DIVERGENT:   $failed")
println("=" ^ 60)

if failed > 0
    println("\nDivergent pairs:")
    for (pair, result) in errors
        println("  $pair → $result")
    end
    error("PURE-4123 FAILED: $failed/$total pairs diverge from native typeintersect")
else
    println("\nAll $total pairs match native typeintersect exactly.")
    println("PURE-4123 PASS — M_INTERSECTION_IMPL gate PASSED")
end
