# PURE-4111 + PURE-4113 + PURE-4115: Verify wasm_subtype matches native <: for 1000+ type pairs
# Includes Union, Tuple, Vararg, UnionAll, TypeVar, parametric, diagonal, and edge cases.
# Zero tolerance for divergence. This is the GATE for M_SUBTYPE_IMPL.

include(joinpath(@__DIR__, "..", "src", "typeinf", "subtype.jl"))

# Collect all type pairs and results
passed = 0
failed = 0
errors = Pair{String,String}[]

function check_subtype(@nospecialize(a), @nospecialize(b))
    global passed, failed
    expected = a <: b
    actual = wasm_subtype(a, b)
    if actual == expected
        passed += 1
    else
        failed += 1
        push!(errors, "$a <: $b" => "expected=$expected, got=$actual")
    end
end

# ============================================================
# Section 1: Concrete numeric types vs themselves and each other
# ============================================================
concrete_numerics = [
    Bool, Int8, Int16, Int32, Int64, Int128,
    UInt8, UInt16, UInt32, UInt64, UInt128,
    Float16, Float32, Float64,
]

for a in concrete_numerics
    for b in concrete_numerics
        check_subtype(a, b)  # a <: b is true only when a === b
    end
end
# 14*14 = 196 pairs

# ============================================================
# Section 2: Concrete numerics vs abstract hierarchy
# ============================================================
abstract_numerics = [Number, Real, Integer, AbstractFloat, Signed, Unsigned]

for a in concrete_numerics
    for b in abstract_numerics
        check_subtype(a, b)
    end
    for b in abstract_numerics
        check_subtype(b, a)  # abstract <: concrete is always false
    end
end
# 14*6*2 = 168 pairs

# ============================================================
# Section 3: Abstract hierarchy vs abstract hierarchy
# ============================================================
for a in abstract_numerics
    for b in abstract_numerics
        check_subtype(a, b)
    end
end
# 6*6 = 36 pairs

# ============================================================
# Section 4: Any, Union{}, Nothing, Missing
# ============================================================
special_types = [Any, Union{}, Nothing, Missing]
all_basic = vcat(concrete_numerics, abstract_numerics, special_types)

for a in special_types
    for b in all_basic
        check_subtype(a, b)
        check_subtype(b, a)
    end
end
# ~192 pairs (4 * 24 * 2, minus duplicates within special_types)

# ============================================================
# Section 5: String, Symbol, Char, AbstractString, AbstractChar
# ============================================================
text_types = [String, SubString{String}, Symbol, Char, AbstractString, AbstractChar]

for a in text_types
    for b in text_types
        check_subtype(a, b)
    end
    # vs Any and Union{}
    check_subtype(a, Any)
    check_subtype(Union{}, a)
    check_subtype(a, Union{})
end
# 6*6 + 6*3 = 54 pairs

# ============================================================
# Section 6: Union types (basic — already implemented in PURE-4110)
# ============================================================
check_subtype(Union{Int64,Float64}, Number)          # true
check_subtype(Union{Int64,Float64}, Real)             # true
check_subtype(Union{Int64,Float64}, Integer)          # false (Float64 !<: Integer)
check_subtype(Int64, Union{Int64,Float64})            # true
check_subtype(String, Union{Int64,Float64})           # false
check_subtype(Union{Int8,Int16}, Union{Int8,Int16,Int32}) # true
check_subtype(Union{Int8,Int16}, Signed)              # true
check_subtype(Union{Int8,UInt8}, Integer)             # true
check_subtype(Union{Int8,UInt8}, Signed)              # false (UInt8 !<: Signed)
check_subtype(Union{}, Union{Int64,Float64})          # true (Union{} <: anything)
check_subtype(Union{Int64,Float64}, Any)              # true
check_subtype(Union{Nothing,Int64}, Any)              # true
check_subtype(Nothing, Union{Nothing,Int64})          # true
check_subtype(Missing, Union{Nothing,Missing})        # true
check_subtype(Int64, Union{Nothing,Missing})          # false

# ============================================================
# Section 7: Common container types (parametric — these test UnionAll fallback)
# Note: Vector{Int64} etc. are DataTypes (fully parameterized), not UnionAll.
# The current wasm_subtype handles DataType <: DataType via supertype walk.
# ============================================================
check_subtype(Vector{Int64}, Vector{Int64})           # true (identity)
check_subtype(Dict{String,Int64}, Dict{String,Int64}) # true (identity)
check_subtype(Set{Float64}, Set{Float64})             # true (identity)
check_subtype(Vector{Int64}, Vector{Float64})         # false (invariant)
check_subtype(Vector{Int64}, Array{Int64,1})          # true (Vector = Array{T,1})
check_subtype(Matrix{Float64}, Array{Float64,2})      # true
check_subtype(Vector{Int64}, AbstractVector{Int64})   # true
check_subtype(Vector{Int64}, AbstractArray{Int64,1})  # true

# Tuple types — identity and negative cases (covariance tested in PURE-4113)
check_subtype(Tuple{Int64}, Tuple{Int64})             # true (identity)
check_subtype(Tuple{Int64,Float64}, Tuple{Int64,Float64}) # true (identity)
check_subtype(Tuple{}, Tuple{})                       # true
check_subtype(Tuple{Int64}, Tuple{Float64})           # false
check_subtype(Tuple{Int64}, Tuple{Int64,Int64})       # false (length mismatch)

# DataType itself
check_subtype(DataType, DataType)                     # true
check_subtype(DataType, Any)                          # true
check_subtype(Int64, DataType)                        # false (Int64 is a DataType instance, not a subtype of DataType)

# ============================================================
# Section 8 (PURE-4113): Tuple covariance
# ============================================================
# Basic covariance: Tuple{SubType} <: Tuple{SuperType}
check_subtype(Tuple{Int64}, Tuple{Number})                    # true
check_subtype(Tuple{Int64}, Tuple{Real})                      # true
check_subtype(Tuple{Int64}, Tuple{Integer})                   # true
check_subtype(Tuple{Int64}, Tuple{Signed})                    # true
check_subtype(Tuple{Int64}, Tuple{Any})                       # true
check_subtype(Tuple{Float64}, Tuple{Number})                  # true
check_subtype(Tuple{Float64}, Tuple{AbstractFloat})           # true
check_subtype(Tuple{Bool}, Tuple{Integer})                    # true
check_subtype(Tuple{UInt8}, Tuple{Unsigned})                  # true
check_subtype(Tuple{String}, Tuple{AbstractString})           # true

# Multi-element covariance
check_subtype(Tuple{Int64,Float64}, Tuple{Number,Number})     # true
check_subtype(Tuple{Int64,Float64}, Tuple{Real,Real})         # true
check_subtype(Tuple{Int64,Float64}, Tuple{Any,Any})           # true
check_subtype(Tuple{Int64,Float64}, Tuple{Integer,Number})    # false (Float64 !<: Integer)
check_subtype(Tuple{Int64,String}, Tuple{Number,AbstractString}) # true
check_subtype(Tuple{Int64,String}, Tuple{Any,Any})            # true
check_subtype(Tuple{Int64,String}, Tuple{String,Int64})       # false (swapped)

# Negative covariance (subtypes go wrong way)
check_subtype(Tuple{Number}, Tuple{Int64})                    # false
check_subtype(Tuple{Real}, Tuple{Float64})                    # false
check_subtype(Tuple{Any}, Tuple{Int64})                       # false
check_subtype(Tuple{Number,Number}, Tuple{Int64,Float64})     # false

# Empty tuple
check_subtype(Tuple{}, Tuple{})                               # true (identity, already tested but ensure)
check_subtype(Tuple{}, Tuple{Int64})                          # false (length mismatch)
check_subtype(Tuple{Int64}, Tuple{})                          # false (length mismatch)
check_subtype(Tuple{}, Tuple{Vararg{Any}})                    # true (0 elements match Vararg)
check_subtype(Tuple{}, Tuple{Vararg{Int64}})                  # true (0 elements)

# 29 pairs

# ============================================================
# Section 9 (PURE-4113): Tuple with Vararg — comprehensive
# ============================================================
# Unbounded Vararg on right: Tuple{A...} <: Tuple{Vararg{B}} iff each A <: B
check_subtype(Tuple{Int64}, Tuple{Vararg{Number}})            # true
check_subtype(Tuple{Int64,Int64}, Tuple{Vararg{Number}})      # true
check_subtype(Tuple{Int64,Int64,Int64}, Tuple{Vararg{Number}}) # true
check_subtype(Tuple{Int64,Float64}, Tuple{Vararg{Number}})    # true (both <: Number)
check_subtype(Tuple{Int64,String}, Tuple{Vararg{Number}})     # false (String !<: Number)
check_subtype(Tuple{Int64,Float64}, Tuple{Vararg{Real}})      # true
check_subtype(Tuple{Int64,Float64}, Tuple{Vararg{Integer}})   # false (Float64 !<: Integer)

# Unbounded Vararg with fixed prefix
check_subtype(Tuple{Int64,Float64}, Tuple{Number,Vararg{Number}})  # true
check_subtype(Tuple{Int64}, Tuple{Number,Vararg{Number}})          # true (1 fixed, 0 vararg)
check_subtype(Tuple{Int64,Float64,Bool}, Tuple{Number,Vararg{Number}}) # true
check_subtype(Tuple{String,Int64}, Tuple{Number,Vararg{Number}})   # false (String !<: Number)

# Bare Tuple = Tuple{Vararg{Any}}, everything is a subtype of bare Tuple
check_subtype(Tuple{Int64}, Tuple)                            # true
check_subtype(Tuple{Int64,Float64}, Tuple)                    # true
check_subtype(Tuple{String,Symbol,Bool}, Tuple)               # true
check_subtype(Tuple{}, Tuple)                                 # true

# Vararg{T,N} — bounded
check_subtype(Tuple{Int64,Int64}, Tuple{Vararg{Number,2}})    # true
check_subtype(Tuple{Int64,Float64}, Tuple{Vararg{Number,2}})  # true
check_subtype(Tuple{Int64}, Tuple{Vararg{Number,2}})          # false (length mismatch)
check_subtype(Tuple{Int64,Int64,Int64}, Tuple{Vararg{Number,2}}) # false (length mismatch)

# Vararg on left side — bounded only
check_subtype(Tuple{Vararg{Int64,2}}, Tuple{Number,Number})   # true
check_subtype(Tuple{Vararg{Int64,3}}, Tuple{Number,Number,Number}) # true
check_subtype(Tuple{Vararg{Int64,2}}, Tuple{Number,Number,Number}) # false (length mismatch)
check_subtype(Tuple{Vararg{Int64,2}}, Tuple{String,String})   # false (Int64 !<: String)

# Vararg vs Vararg
check_subtype(Tuple{Vararg{Int64}}, Tuple{Vararg{Number}})    # true (Int64 <: Number)
check_subtype(Tuple{Vararg{Number}}, Tuple{Vararg{Int64}})    # false (Number !<: Int64)
check_subtype(Tuple{Vararg{Int64}}, Tuple{Vararg{Any}})       # true
check_subtype(Tuple{Vararg{Any}}, Tuple{Vararg{Int64}})       # false

# Vararg edge: unbounded left vs fixed right
check_subtype(Tuple{Vararg{Int64}}, Tuple{Int64})             # false (unbounded left, fixed right)
check_subtype(Tuple{Vararg{Int64}}, Tuple{Int64,Int64})       # false

# 31 pairs

# ============================================================
# Section 10 (PURE-4113): Nested Unions
# ============================================================
# Julia flattens nested Unions, so Union{Union{A,B},C} === Union{A,B,C}
# But we test through wasm_subtype to ensure it handles them correctly

check_subtype(Union{Union{Int8,Int16},Int32}, Signed)                # true
check_subtype(Union{Union{Int8,Int16},Int32}, Integer)               # true
check_subtype(Union{Union{Int8,Int16},Int32}, Number)                # true
check_subtype(Union{Union{Int8,Int16},Int32}, Any)                   # true
check_subtype(Union{Union{Int8,Int16},Int32}, Unsigned)              # false
check_subtype(Union{Union{Int8,Int16},UInt8}, Signed)                # false (UInt8 !<: Signed)
check_subtype(Int8, Union{Union{Int8,Int16},Int32})                  # true
check_subtype(Int32, Union{Union{Int8,Int16},Int32})                 # true
check_subtype(Int64, Union{Union{Int8,Int16},Int32})                 # false

# Triple-nesting
check_subtype(Union{Union{Union{Int8,Int16},Int32},Int64}, Signed)   # true
check_subtype(Union{Union{Union{Int8,Int16},Int32},Int64}, Integer)  # true
check_subtype(Int64, Union{Union{Union{Int8,Int16},Int32},Int64})    # true

# Union with Nothing/Missing
check_subtype(Union{Nothing,Union{Int64,Float64}}, Any)              # true
check_subtype(Union{Nothing,Missing}, Union{Nothing,Missing,Int64})  # true
check_subtype(Nothing, Union{Nothing,Union{Int64,Float64}})          # true
check_subtype(Float64, Union{Nothing,Union{Int64,Float64}})          # true
check_subtype(String, Union{Nothing,Union{Int64,Float64}})           # false

# 17 pairs

# ============================================================
# Section 11 (PURE-4113): Single-element Union
# ============================================================
# Union{T} === T in Julia, so Union{Int64} === Int64
check_subtype(Union{Int64}, Int64)                 # true (Union{Int64} === Int64)
check_subtype(Int64, Union{Int64})                 # true
check_subtype(Union{Int64}, Number)                # true
check_subtype(Union{Int64}, String)                # false
check_subtype(Union{String}, AbstractString)       # true
check_subtype(Union{Nothing}, Nothing)             # true
check_subtype(Union{Nothing}, Any)                 # true
check_subtype(Union{Nothing}, Int64)               # false

# 8 pairs

# ============================================================
# Section 12 (PURE-4113): Mixed Union + Tuple
# ============================================================
# Tuple containing Unions in its parameters
check_subtype(Tuple{Union{Int64,Float64}}, Tuple{Number})               # true
check_subtype(Tuple{Union{Int64,Float64}}, Tuple{Real})                 # true
check_subtype(Tuple{Union{Int64,Float64}}, Tuple{Integer})              # false (Float64 !<: Integer)
check_subtype(Tuple{Union{Int64,Float64}}, Tuple{Any})                  # true
check_subtype(Tuple{Union{Int64,Float64}}, Tuple{String})               # false
check_subtype(Tuple{Int64,Union{String,Symbol}}, Tuple{Number,Any})     # true
check_subtype(Tuple{Int64,Union{String,Symbol}}, Tuple{Any,AbstractString}) # false (Symbol !<: AbstractString)

# Union of Tuples
check_subtype(Union{Tuple{Int64},Tuple{Float64}}, Tuple{Number})        # true
check_subtype(Union{Tuple{Int64},Tuple{String}}, Tuple{Any})            # true
check_subtype(Union{Tuple{Int64},Tuple{String}}, Tuple{Number})         # false (Tuple{String} !<: Tuple{Number})

# Tuple <: Union
check_subtype(Tuple{Int64}, Union{Tuple{Int64},Tuple{Float64}})         # true
check_subtype(Tuple{String}, Union{Tuple{Int64},Tuple{Float64}})        # false
check_subtype(Tuple{Int64,Int64}, Union{Tuple{Int64,Int64},Tuple{Float64,Float64}}) # true

# Union{} in Tuple — note: Tuple{Union{}} is INVALID in Julia ("Tuple field type cannot be Union{}")
# So we skip those pairs. Union{} as a standalone type is already tested in Section 4.

# Tuple with Vararg + Union
check_subtype(Tuple{Union{Int64,Float64},Union{Int64,Float64}}, Tuple{Vararg{Number}})  # true
check_subtype(Tuple{Union{Int64,String}}, Tuple{Vararg{Number}})        # false (String !<: Number)

# 18 pairs

# ============================================================
# Section 13 (PURE-4113): Tuple vs non-Tuple, special cases
# ============================================================
# Tuple types are not subtypes of non-Tuple types (except Any)
check_subtype(Tuple{Int64}, Any)                               # true
check_subtype(Tuple{Int64}, Int64)                             # false
check_subtype(Tuple{Int64}, Number)                            # false
check_subtype(Int64, Tuple{Int64})                             # false
check_subtype(Nothing, Tuple{})                                # false
check_subtype(Tuple{}, Nothing)                                # false
check_subtype(Union{}, Tuple{Int64})                           # true (Union{} <: anything)
check_subtype(Tuple{Int64}, Union{})                           # false

# Tuple{Any} vs various
check_subtype(Tuple{Any}, Tuple{Any})                          # true
check_subtype(Tuple{Int64}, Tuple{Any})                        # true
check_subtype(Tuple{Any}, Tuple{Int64})                        # false (Any !<: Int64)
check_subtype(Tuple{Any,Any}, Tuple{Any})                      # false (length mismatch)

# Longer Tuples
check_subtype(Tuple{Int8,Int16,Int32,Int64}, Tuple{Signed,Signed,Signed,Signed})  # true
check_subtype(Tuple{Int8,Int16,Int32,Int64}, Tuple{Number,Number,Number,Number})  # true
check_subtype(Tuple{Int8,Int16,Int32,Int64}, Tuple{Any,Any,Any,Any})              # true
check_subtype(Tuple{Int8,Int16,Int32,Int64}, Tuple{Int8,Int16,Int32,Float64})     # false (Int64 !<: Float64)
check_subtype(Tuple{Int8,Int16,Int32,Int64,Int128}, Tuple{Vararg{Signed}})        # true
check_subtype(Tuple{Int8,Int16,Int32,Int64,UInt8}, Tuple{Vararg{Signed}})         # false (UInt8 !<: Signed)

# 18 pairs

# ============================================================
# Section 14 (PURE-4113): Systematic Tuple covariance matrix
# ============================================================
# Cross all numeric types with abstract types through Tuples
tuple_concrete = [Int8, Int64, Float32, Float64, Bool, UInt16]
tuple_abstract = [Number, Real, Integer, AbstractFloat, Signed, Unsigned, Any]

for c in tuple_concrete
    for a in tuple_abstract
        check_subtype(Tuple{c}, Tuple{a})
    end
end
# 6 * 7 = 42 pairs

# ============================================================
# Section 15 (PURE-4115): Parametric types — invariant parameter checking
# ============================================================
# Vector{Int} vs Vector{Number} — INVARIANT (must be false)
check_subtype(Vector{Int64}, Vector{Number})                    # false
check_subtype(Vector{Int64}, Vector{Real})                      # false
check_subtype(Vector{Int64}, Vector{Any})                       # false
check_subtype(Vector{Number}, Vector{Int64})                    # false
check_subtype(Vector{Float64}, Vector{Number})                  # false
check_subtype(Vector{Float64}, Vector{AbstractFloat})           # false

# Dict invariant
check_subtype(Dict{String,Int64}, Dict{String,Number})          # false
check_subtype(Dict{String,Int64}, Dict{AbstractString,Int64})   # false
check_subtype(Dict{String,Int64}, Dict{Any,Any})                # false
check_subtype(Dict{String,Int64}, Dict{String,Int64})           # true (identity)

# Set invariant
check_subtype(Set{Int64}, Set{Number})                          # false
check_subtype(Set{Int64}, Set{Int64})                           # true
check_subtype(Set{Float64}, Set{Float64})                       # true

# Pair invariant
check_subtype(Pair{Int64,String}, Pair{Int64,String})           # true
check_subtype(Pair{Int64,String}, Pair{Number,String})          # false
check_subtype(Pair{Int64,String}, Pair{Int64,AbstractString})   # false
check_subtype(Pair{Int64,String}, Pair{Any,Any})                # false

# Array dimension invariant
check_subtype(Array{Int64,1}, Array{Int64,2})                   # false
check_subtype(Array{Int64,1}, Array{Int64,1})                   # true
check_subtype(Array{Float64,2}, Array{Float64,2})               # true
check_subtype(Array{Float64,2}, Array{Float64,1})               # false

# 21 pairs

# ============================================================
# Section 16 (PURE-4115): UnionAll on right — existential (Vector{Int} <: Vector{T} where T)
# ============================================================
check_subtype(Vector{Int64}, Vector)                             # true (Vector = Vector{T} where T)
check_subtype(Vector{Float64}, Vector)                           # true
check_subtype(Vector{String}, Vector)                            # true
check_subtype(Vector{Any}, Vector)                               # true
check_subtype(Dict{String,Int64}, Dict)                          # true
check_subtype(Dict{Any,Any}, Dict)                               # true
check_subtype(Set{Int64}, Set)                                   # true
check_subtype(Pair{Int64,String}, Pair)                          # true

# AbstractVector is UnionAll: AbstractVector{T} where T
check_subtype(Vector{Int64}, AbstractVector)                     # true
check_subtype(Vector{Float64}, AbstractVector)                   # true
check_subtype(Vector{String}, AbstractVector)                    # true

# AbstractArray is UnionAll: AbstractArray{T,N} where {T,N}
check_subtype(Vector{Int64}, AbstractArray)                      # true
check_subtype(Matrix{Float64}, AbstractArray)                    # true
check_subtype(Array{Int64,3}, AbstractArray)                     # true

# AbstractDict
check_subtype(Dict{String,Int64}, AbstractDict)                  # true
check_subtype(Dict{Any,Any}, AbstractDict)                       # true

# AbstractSet
check_subtype(Set{Int64}, AbstractSet)                           # true

# AbstractVector{T} where T<:Number — bounded
check_subtype(Vector{Int64}, AbstractVector{Int64})              # true (already in Sec 7)
check_subtype(Vector{Float64}, AbstractVector{Float64})          # true

# DenseArray/DenseVector
check_subtype(Vector{Int64}, DenseVector{Int64})                 # true
check_subtype(Vector{Int64}, DenseArray{Int64,1})                # true
check_subtype(Matrix{Float64}, DenseMatrix{Float64})             # true
check_subtype(Matrix{Float64}, DenseArray{Float64,2})            # true

# 23 pairs

# ============================================================
# Section 17 (PURE-4115): UnionAll on left — universal
# ============================================================
# These test "for all T, ..." patterns
check_subtype(Vector, AbstractVector)                            # true (for all T, Vector{T} <: AbstractVector{T})
check_subtype(Vector, AbstractArray)                             # true
check_subtype(Matrix, AbstractMatrix)                            # true
check_subtype(Matrix, AbstractArray)                             # true
check_subtype(Dict, AbstractDict)                                # true
check_subtype(Set, AbstractSet)                                  # true

# Negative: unrelated UnionAll
check_subtype(Vector, AbstractDict)                              # false
check_subtype(Dict, AbstractSet)                                 # false
check_subtype(Set, AbstractVector)                               # false
check_subtype(AbstractVector, Vector)                            # false (Vector is more specific)
check_subtype(AbstractDict, Dict)                                # false

# UnionAll vs concrete
check_subtype(Vector, Vector{Int64})                             # false (not all T match Int64)
check_subtype(Dict, Dict{String,Int64})                          # false
check_subtype(Set, Set{Float64})                                 # false

# 14 pairs

# ============================================================
# Section 18 (PURE-4115): Bounded TypeVars — where T<:Number etc.
# ============================================================
# Vector{T} where T<:Number
BoundedVecNum = Vector{T} where T<:Number
check_subtype(Vector{Int64}, BoundedVecNum)                      # true
check_subtype(Vector{Float64}, BoundedVecNum)                    # true
check_subtype(Vector{Bool}, BoundedVecNum)                       # true (Bool <: Number)
check_subtype(Vector{String}, BoundedVecNum)                     # false (String !<: Number)
check_subtype(Vector{Any}, BoundedVecNum)                        # false (Any !<: Number)

# Vector{T} where T<:Integer
BoundedVecInt = Vector{T} where T<:Integer
check_subtype(Vector{Int64}, BoundedVecInt)                      # true
check_subtype(Vector{Bool}, BoundedVecInt)                       # true
check_subtype(Vector{Float64}, BoundedVecInt)                    # false
check_subtype(Vector{UInt8}, BoundedVecInt)                      # true

# Vector{T} where T<:AbstractFloat
BoundedVecFloat = Vector{T} where T<:AbstractFloat
check_subtype(Vector{Float64}, BoundedVecFloat)                  # true
check_subtype(Vector{Float32}, BoundedVecFloat)                  # true
check_subtype(Vector{Int64}, BoundedVecFloat)                    # false

# Pair{T,T} where T — same-type pairs
SamePair = Pair{T,T} where T
check_subtype(Pair{Int64,Int64}, SamePair)                       # true
check_subtype(Pair{String,String}, SamePair)                     # true
check_subtype(Pair{Int64,String}, SamePair)                      # false (Int64 != String)

# Pair{T,T} where T<:Number
SameNumPair = Pair{T,T} where T<:Number
check_subtype(Pair{Int64,Int64}, SameNumPair)                    # true
check_subtype(Pair{Float64,Float64}, SameNumPair)                # true
check_subtype(Pair{Int64,Float64}, SameNumPair)                  # false
check_subtype(Pair{String,String}, SameNumPair)                  # false

# Lower-bounded TypeVar: T where T>:Int64
LowerBound = Ref{T} where T>:Int64
check_subtype(Ref{Int64}, LowerBound)                            # true
check_subtype(Ref{Number}, LowerBound)                           # true (Number >: Int64)
check_subtype(Ref{Any}, LowerBound)                              # true
check_subtype(Ref{Float64}, LowerBound)                          # false (Float64 !>: Int64)
check_subtype(Ref{String}, LowerBound)                           # false

# Double-bounded TypeVar: T where Int64<:T<:Number
DoubleBound = Ref{T} where Int64<:T<:Number
check_subtype(Ref{Int64}, DoubleBound)                           # true
check_subtype(Ref{Number}, DoubleBound)                          # true
check_subtype(Ref{Real}, DoubleBound)                            # true (Int64 <: Real <: Number)
check_subtype(Ref{Signed}, DoubleBound)                          # true (Int64 <: Signed <: Number)
check_subtype(Ref{Integer}, DoubleBound)                         # true
check_subtype(Ref{Float64}, DoubleBound)                         # false (Int64 !<: Float64)
check_subtype(Ref{Any}, DoubleBound)                             # false (Any !<: Number)
check_subtype(Ref{String}, DoubleBound)                          # false

# 33 pairs

# ============================================================
# Section 19 (PURE-4115): Type{T} — singleton type handling
# ============================================================
check_subtype(Type{Int64}, Type{Int64})                          # true
check_subtype(Type{Int64}, Type{Number})                         # false (invariant)
check_subtype(Type{Int64}, Type)                                 # true (Type = Type{T} where T)
check_subtype(Type{Float64}, Type)                               # true
check_subtype(Type{String}, Type)                                # true
check_subtype(Type{Any}, Type)                                   # true
check_subtype(DataType, Type)                                    # true
check_subtype(Type, Type)                                        # true (identity)
check_subtype(Type{Int64}, DataType)                             # true (typeof(Int64) is DataType)
check_subtype(Type{Int64}, Any)                                  # true
check_subtype(Int64, Type{Int64})                                # false (Int64 is not Type{Int64})
check_subtype(Int64, Type)                                       # false
check_subtype(Type{Int64}, Type{Float64})                        # false

# UnionAll types vs Type
check_subtype(Type{Vector{Int64}}, Type)                         # true
check_subtype(Type{Tuple{Int64}}, Type)                          # true

# 15 pairs

# ============================================================
# Section 20 (PURE-4115): Diagonal dispatch — Tuple{T,T} where T patterns
# ============================================================
# Diagonal: T appears 2+ times in covariant position → must be concrete
DiagTT = Tuple{T,T} where T
check_subtype(Tuple{Int64,Int64}, DiagTT)                        # true (concrete match)
check_subtype(Tuple{Float64,Float64}, DiagTT)                    # true
check_subtype(Tuple{String,String}, DiagTT)                      # true
check_subtype(Tuple{Int64,Float64}, DiagTT)                      # false (different types)
check_subtype(Tuple{Int64,String}, DiagTT)                       # false

# Diagonal with bound: Tuple{T,T} where T<:Number
DiagTTNum = Tuple{T,T} where T<:Number
check_subtype(Tuple{Int64,Int64}, DiagTTNum)                     # true
check_subtype(Tuple{Float64,Float64}, DiagTTNum)                 # true
check_subtype(Tuple{Int64,Float64}, DiagTTNum)                   # false (not same type)
check_subtype(Tuple{String,String}, DiagTTNum)                   # false (String !<: Number)

# Diagonal with 3 occurrences
DiagTTT = Tuple{T,T,T} where T
check_subtype(Tuple{Int64,Int64,Int64}, DiagTTT)                 # true
check_subtype(Tuple{Int64,Int64,Float64}, DiagTTT)               # false
check_subtype(Tuple{String,String,String}, DiagTTT)              # true

# Non-diagonal: T appears once → abstract is OK
SingleT = Tuple{T} where T
check_subtype(Tuple{Int64}, SingleT)                             # true
check_subtype(Tuple{Number}, SingleT)                            # true (abstract OK, only 1 occurrence)
check_subtype(Tuple{Any}, SingleT)                               # true
check_subtype(Tuple{String}, SingleT)                            # true

# T appears once covariant, once invariant → not diagonal
# Tuple{T, Vector{T}} where T — T is invariant in Vector, covariant in first pos
TVecT = Tuple{T, Vector{T}} where T
check_subtype(Tuple{Int64, Vector{Int64}}, TVecT)                # true
check_subtype(Tuple{Float64, Vector{Float64}}, TVecT)            # true
check_subtype(Tuple{Int64, Vector{Float64}}, TVecT)              # false
check_subtype(Tuple{Number, Vector{Int64}}, TVecT)               # false (T can't be both Number and Int64)

# 21 pairs

# ============================================================
# Section 21 (PURE-4115): Nested UnionAll — multi-parameter where clauses
# ============================================================
# Dict{K,V} where {K,V} = Dict
check_subtype(Dict{String,Int64}, Dict{K,V} where {K,V})        # true
check_subtype(Dict{Any,Any}, Dict{K,V} where {K,V})             # true

# Dict{K,V} where {K<:AbstractString,V<:Number}
BoundedDict = Dict{K,V} where {K<:AbstractString, V<:Number}
check_subtype(Dict{String,Int64}, BoundedDict)                   # true
check_subtype(Dict{String,Float64}, BoundedDict)                 # true
check_subtype(Dict{SubString{String},Int64}, BoundedDict)        # true
check_subtype(Dict{String,String}, BoundedDict)                  # false (String !<: Number)
check_subtype(Dict{Int64,Int64}, BoundedDict)                    # false (Int64 !<: AbstractString)

# Array{T,N} where {T,N}
check_subtype(Vector{Int64}, Array{T,N} where {T,N})             # true
check_subtype(Matrix{Float64}, Array{T,N} where {T,N})           # true
check_subtype(Array{Int64,3}, Array{T,N} where {T,N})            # true

# Array{T,N} where {T<:Number,N}
BoundedArr = Array{T,N} where {T<:Number, N}
check_subtype(Vector{Int64}, BoundedArr)                         # true
check_subtype(Matrix{Float64}, BoundedArr)                       # true
check_subtype(Vector{String}, BoundedArr)                        # false

# Nested Vector{Vector{T}} vs Vector{Vector{T} where T}
# These are different! Vector{Vector{T}} where T has all inner vectors same T
# Vector{Vector{T} where T} allows different T per inner vector
VVT = Vector{Vector{T}} where T   # all inner vecs must have same T
VVWT = Vector{Vector{T} where T}  # inner vecs can have different T
check_subtype(Vector{Vector{Int64}}, VVT)                        # true (T=Int64)
check_subtype(Vector{Vector{Int64}}, VVWT)                       # true
check_subtype(VVT, VVWT)                                         # true (more constrained <: less constrained)
check_subtype(VVWT, VVT)                                         # false (less constrained !<: more constrained)

# 18 pairs

# ============================================================
# Section 22 (PURE-4115): Covariant Tuple vs invariant parametric — contrast
# ============================================================
# Tuple is COVARIANT — Tuple{Int} <: Tuple{Number}
check_subtype(Tuple{Int64}, Tuple{Number})                       # true (covariant)
check_subtype(Tuple{Int64,Int64}, Tuple{Number,Number})          # true
check_subtype(Tuple{Int64,Float64,String}, Tuple{Number,Number,Any})  # true

# Vector is INVARIANT — Vector{Int} !<: Vector{Number}
check_subtype(Vector{Int64}, Vector{Number})                     # false (invariant)

# Ref is INVARIANT
check_subtype(Ref{Int64}, Ref{Number})                           # false
check_subtype(Ref{Int64}, Ref{Int64})                            # true
check_subtype(Ref{Number}, Ref{Int64})                           # false

# Mixed: Tuple of invariant containers
check_subtype(Tuple{Vector{Int64}}, Tuple{Vector{Int64}})        # true
check_subtype(Tuple{Vector{Int64}}, Tuple{Vector{Number}})       # false (inner Vector is invariant)
check_subtype(Tuple{Vector{Int64}}, Tuple{AbstractVector{Int64}})  # true (Tuple covariant, AbstractVector)
check_subtype(Tuple{Vector{Int64}}, Tuple{Vector})               # true (Tuple covariant, Vector=Vector{T} where T)
check_subtype(Tuple{Ref{Int64}}, Tuple{Ref{Int64}})              # true
check_subtype(Tuple{Ref{Int64}}, Tuple{Ref{Number}})             # false

# 13 pairs

# ============================================================
# Section 23 (PURE-4115): Union + UnionAll combinations
# ============================================================
check_subtype(Union{Vector{Int64},Vector{Float64}}, AbstractVector)  # true
check_subtype(Union{Vector{Int64},Set{Float64}}, AbstractVector)     # false (Set !<: AbstractVector)
check_subtype(Vector{Int64}, Union{Vector{Int64},Vector{Float64}})   # true
check_subtype(Vector{String}, Union{Vector{Int64},Vector{Float64}})  # false

# Union inside parametric
check_subtype(Vector{Union{Int64,Float64}}, Vector{Union{Int64,Float64}})  # true (identity)
check_subtype(Vector{Int64}, Vector{Union{Int64,Float64}})                  # false (invariant!)
check_subtype(Vector{Union{Int64,Float64}}, Vector{Number})                 # false (invariant!)

# Tuple with Union and UnionAll
check_subtype(Tuple{Vector{Int64},Int64}, Tuple{AbstractVector,Number})  # true
check_subtype(Tuple{Vector{Int64},String}, Tuple{AbstractVector,Number}) # false
check_subtype(Tuple{Union{Int64,Float64},Vector{Int64}}, Tuple{Number,Vector})  # true

# 10 pairs

# ============================================================
# Section 24 (PURE-4115): Value type parameters
# ============================================================
# Tuples with integer value parameters (Tuple{1,2} etc. from Julia)
check_subtype(Tuple{1,2}, Tuple{1,2})                            # true
check_subtype(Tuple{1,2}, Tuple{1,3})                            # false
check_subtype(Tuple{1}, Tuple{1})                                # true

# Val types
check_subtype(Val{1}, Val{1})                                    # true
check_subtype(Val{1}, Val{2})                                    # false
check_subtype(Val{1}, Val)                                       # true (Val = Val{T} where T)
check_subtype(Val{:foo}, Val)                                    # true
check_subtype(Val{:foo}, Val{:foo})                              # true
check_subtype(Val{:foo}, Val{:bar})                              # false

# 9 pairs

# ============================================================
# Section 25 (PURE-4115): NamedTuple types
# ============================================================
NT1 = NamedTuple{(:a,:b), Tuple{Int64,Float64}}
NT2 = NamedTuple{(:a,:b), Tuple{Int64,Float64}}
NT3 = NamedTuple{(:a,:b), Tuple{Number,Number}}
NT4 = NamedTuple{(:x,:y), Tuple{Int64,Float64}}

check_subtype(NT1, NT2)                                          # true (identical)
check_subtype(NT1, NT3)                                          # false (invariant on field types)
check_subtype(NT1, NT4)                                          # false (different field names)
check_subtype(NT1, NamedTuple)                                   # true (NamedTuple is UnionAll)
check_subtype(NT1, Any)                                          # true

# 5 pairs

# ============================================================
# Section 26 (PURE-4115): AbstractArray subtype hierarchy
# ============================================================
check_subtype(Vector{Int64}, AbstractVector{Int64})              # true
check_subtype(Vector{Int64}, AbstractVector{Number})             # false (invariant parameter)
check_subtype(Matrix{Float64}, AbstractMatrix{Float64})          # true
check_subtype(Matrix{Float64}, AbstractMatrix{Number})           # false
check_subtype(Array{Int64,3}, AbstractArray{Int64,3})            # true
check_subtype(Array{Int64,3}, AbstractArray{Int64,2})            # false (dimension mismatch)
check_subtype(Vector{Int64}, AbstractArray{Int64,1})             # true (already tested, confirm)
check_subtype(Vector{Int64}, AbstractArray{Int64,2})             # false

# Subtype chains
check_subtype(Vector{Int64}, DenseVector{Int64})                 # true
check_subtype(Vector{Int64}, DenseVector{Number})                # false (invariant)
check_subtype(DenseVector{Int64}, AbstractVector{Int64})         # true
check_subtype(DenseVector{Int64}, AbstractVector{Number})        # false

# 12 pairs

# ============================================================
# Section 27 (PURE-4115): Complex where clause patterns from Julia test suite
# ============================================================
# Ref{T} where T<:Ref — recursive-looking but valid
RefRef = Ref{T} where T<:Ref
check_subtype(Ref{Ref{Int64}}, RefRef)                           # true
check_subtype(Ref{Int64}, RefRef)                                # false (Int64 !<: Ref)

# Pair{T,S} where S<:T — dependent bounds
DepPair = Pair{T,S} where {T, S<:T}
check_subtype(Pair{Number,Int64}, DepPair)                       # true (Int64 <: Number)
check_subtype(Pair{Number,Float64}, DepPair)                     # true
check_subtype(Pair{Integer,Int64}, DepPair)                      # true
check_subtype(Pair{Int64,Number}, DepPair)                       # false (Number !<: Int64)
check_subtype(Pair{Int64,Float64}, DepPair)                      # false (Float64 !<: Int64)

# Tuple with UnionAll parameter
check_subtype(Tuple{Vector{Int64}}, Tuple{Vector{T} where T})        # true
check_subtype(Tuple{Vector{Int64}}, Tuple{Vector{T}} where T)        # true
check_subtype(Tuple{Vector{Int64}}, Tuple{Vector{T} where T<:Number}) # true
check_subtype(Tuple{Vector{String}}, Tuple{Vector{T} where T<:Number}) # false

# 11 pairs

# ============================================================
# Section 28 (PURE-4115): IO/abstract type hierarchy
# ============================================================
check_subtype(IOBuffer, IO)                                       # true
check_subtype(IO, IO)                                             # true
check_subtype(IO, Any)                                            # true
check_subtype(IOBuffer, Any)                                      # true

# 4 pairs

# ============================================================
# Section 29 (PURE-4115): Function/callable types
# ============================================================
check_subtype(Function, Function)                                 # true
check_subtype(Function, Any)                                      # true
check_subtype(typeof(sin), Function)                              # true
check_subtype(typeof(+), Function)                                # true
check_subtype(typeof(println), Function)                          # true
check_subtype(Int64, Function)                                    # false

# 6 pairs

# ============================================================
# Section 30 (PURE-4115): Vararg with UnionAll in Tuples
# ============================================================
# Tuple{T,Vararg{T}} where T — homogeneous tuples
HomTuple = Tuple{T,Vararg{T}} where T
check_subtype(Tuple{Int64}, HomTuple)                             # true (1 elem)
check_subtype(Tuple{Int64,Int64}, HomTuple)                       # true
check_subtype(Tuple{Int64,Int64,Int64}, HomTuple)                 # true
check_subtype(Tuple{Int64,Float64}, HomTuple)                     # false (different types)

# NTuple{N,T} is Tuple{Vararg{T,N}}
check_subtype(NTuple{3,Int64}, NTuple{3,Int64})                   # true
check_subtype(NTuple{3,Int64}, NTuple{3,Number})                  # false (Vararg covariant? — actually true, let native decide)
check_subtype(NTuple{3,Int64}, Tuple{Int64,Int64,Int64})          # true
check_subtype(Tuple{Int64,Int64,Int64}, NTuple{3,Int64})          # true
check_subtype(NTuple{2,Int64}, NTuple{3,Int64})                   # false (length mismatch)

# 9 pairs

# ============================================================
# Section 31 (PURE-4115): Systematic parametric matrix — Vector{T} where T<:X for various X
# ============================================================
parametric_bounds = [Number, Real, Integer, AbstractFloat, Signed, Unsigned, Any]
parametric_concrete = [Int64, Float64, Bool, UInt8, String]

for bound in parametric_bounds
    BV = Vector{T} where T<:bound
    for concrete in parametric_concrete
        check_subtype(Vector{concrete}, BV)
    end
end
# 7 * 5 = 35 pairs

# ============================================================
# Section 32 (PURE-4115): Supertype chain for parametric types
# ============================================================
check_subtype(Vector{Int64}, Array{Int64})                       # true (Vector = Array{T,1}, Array = Array{T,N} where N)
check_subtype(Matrix{Float64}, Array{Float64})                   # true
check_subtype(Vector{Int64}, Array)                              # true
check_subtype(Matrix{Float64}, Array)                            # true

# BitVector, BitMatrix (if available)
check_subtype(BitVector, AbstractVector{Bool})                   # true
check_subtype(BitVector, AbstractVector)                         # true
check_subtype(BitVector, AbstractArray)                          # true

# StepRange, UnitRange
check_subtype(UnitRange{Int64}, AbstractRange{Int64})            # true
check_subtype(UnitRange{Int64}, AbstractVector{Int64})           # true
check_subtype(UnitRange{Int64}, AbstractVector)                  # true
check_subtype(StepRange{Int64,Int64}, AbstractRange{Int64})      # true

# 11 pairs

# ============================================================
# Section 33 (PURE-4115): Miscellaneous edge cases
# ============================================================
# Union{} in various positions
check_subtype(Union{}, Vector{Int64})                             # true
check_subtype(Union{}, AbstractVector)                            # true
check_subtype(Union{}, Tuple{T} where T)                          # true
check_subtype(Union{}, Union{})                                   # true

# Any in various positions
check_subtype(Vector{Int64}, Any)                                 # true
check_subtype(AbstractVector, Any)                                # true
check_subtype(Tuple{T} where T, Any)                              # true

# Self-subtype
check_subtype(Vector, Vector)                                     # true
check_subtype(AbstractVector, AbstractVector)                     # true
check_subtype(Dict, Dict)                                         # true
check_subtype(Tuple{Vararg{Any}}, Tuple{Vararg{Any}})            # true

# Complex nested — Tuple{Vector{T}, T} where T — T appears in covariant and invariant
TVecAndT = Tuple{Vector{T}, T} where T
check_subtype(Tuple{Vector{Int64}, Int64}, TVecAndT)              # true
check_subtype(Tuple{Vector{Int64}, Float64}, TVecAndT)            # false (T can't be both)
check_subtype(Tuple{Vector{Int64}, Number}, TVecAndT)             # false

# 14 pairs

# ============================================================
# Report
# ============================================================
println("=" ^ 60)
println("PURE-4115: Full wasm_subtype verification (GATE for M_SUBTYPE_IMPL)")
println("=" ^ 60)
println("Passed: $passed")
println("Failed: $failed")
println("Total:  $(passed + failed)")
println()

if !isempty(errors)
    println("FAILURES:")
    for (pair, msg) in errors
        println("  $pair — $msg")
    end
end

new_pairs = passed + failed - 832  # 832 was the previous count from PURE-4111+4113+4114
println("New pairs in PURE-4115: $new_pairs")

@assert failed == 0 "PURE-4115 FAILED: $failed divergences from native <:"
@assert passed >= 1032 "PURE-4115 requires 200+ new pairs (got $new_pairs new, need >= 200)"
println("ALL $(passed) type pairs CORRECT — wasm_subtype matches native <:")
println("GATE PASSED: M_SUBTYPE_IMPL is complete.")
