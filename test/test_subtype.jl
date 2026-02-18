# PURE-4111: Verify wasm_subtype matches native <: for 100+ type pairs
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

# Tuple types — these are DataTypes too
check_subtype(Tuple{Int64}, Tuple{Int64})             # true
check_subtype(Tuple{Int64,Float64}, Tuple{Int64,Float64}) # true (identity)
check_subtype(Tuple{Int64}, Tuple{Number})            # true (covariant)
check_subtype(Tuple{Int64,Float64}, Tuple{Number,Number}) # true
check_subtype(Tuple{}, Tuple{})                       # true
check_subtype(Tuple{Int64}, Tuple{Float64})           # false
check_subtype(Tuple{Int64}, Tuple{Int64,Int64})       # false (length mismatch)

# DataType itself
check_subtype(DataType, DataType)                     # true
check_subtype(DataType, Type)                         # true
check_subtype(DataType, Any)                          # true
check_subtype(Int64, DataType)                        # false (Int64 is a DataType instance, not a subtype of DataType)

# ============================================================
# Report
# ============================================================
println("=" ^ 60)
println("PURE-4111: wasm_subtype verification")
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

@assert failed == 0 "PURE-4111 FAILED: $failed divergences from native <:"
println("ALL $(passed) type pairs CORRECT — wasm_subtype matches native <:")
