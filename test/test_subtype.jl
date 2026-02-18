# PURE-4111 + PURE-4113: Verify wasm_subtype matches native <: for 700+ type pairs
# Includes Union, Tuple, Vararg, and mixed combinations.
# Zero tolerance for divergence.

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
# Known gaps: These require PURE-4114 (UnionAll)
# Documented here for completeness, tested in PURE-4115
# ============================================================
# UnionAll (PURE-4114/4115):
#   DataType <: Type                           — Type is UnionAll (Type{T} where T)
#   Vector{Int64} <: AbstractVector             — AbstractVector is UnionAll

# ============================================================
# Report
# ============================================================
println("=" ^ 60)
println("PURE-4111 + PURE-4113: wasm_subtype verification")
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

@assert failed == 0 "PURE-4113 FAILED: $failed divergences from native <:"
println("ALL $(passed) type pairs CORRECT — wasm_subtype matches native <:")
