# PURE-4121: Verify wasm_type_intersection matches native typeintersect for 100+ type pairs
# Includes simple, Union, and Tuple cases (non-UnionAll).
# Zero tolerance for divergence.

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
# Section 19: UnionAll fallback (delegated to native for now)
# ============================================================
check_intersection(Vector{Int64}, AbstractVector{Int64})
check_intersection(AbstractVector{Int64}, Vector{Int64})
check_intersection(Vector{Int64}, AbstractArray{Int64})
check_intersection(Matrix{Float64}, AbstractArray{Float64})
# 4 pairs

# ============================================================
# Section 20: Complex union+tuple combos
# ============================================================
check_intersection(Tuple{Union{Int64,Float64},String}, Tuple{Number,AbstractString})
check_intersection(Tuple{Union{Int64,Float64}}, Tuple{Union{Float64,String}})
check_intersection(Union{Tuple{Int64},Tuple{Float64}}, Tuple{Int64})
check_intersection(Union{Tuple{Int64},Tuple{Float64}}, Tuple{String})
check_intersection(Tuple{Union{Int64,Float64},Union{String,Symbol}}, Tuple{Number,Any})
# 5 pairs

# ============================================================
# Section 21: Commutativity spot-checks
# ============================================================
# Verify a ∩ b == b ∩ a for selected pairs
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
    r1 = wasm_type_intersection(a, b)
    r2 = wasm_type_intersection(b, a)
    expected1 = typeintersect(a, b)
    expected2 = typeintersect(b, a)
    # Both directions should match native
    check_intersection(a, b)
    check_intersection(b, a)
end
# 8*2 = 16 pairs

# ============================================================
# Section 22: IO/AbstractString hierarchy
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
# Section 23: Function types
# ============================================================
check_intersection(Function, typeof(+))
check_intersection(typeof(+), Function)
check_intersection(typeof(+), typeof(-))
check_intersection(typeof(+), typeof(+))
# 4 pairs

# ============================================================
# Print results
# ============================================================
total = passed + failed
println("=" ^ 60)
println("PURE-4121: Intersection test results")
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
    error("PURE-4121 FAILED: $failed/$total pairs diverge from native typeintersect")
else
    println("\nAll $total pairs match native typeintersect exactly.")
    println("PURE-4121 PASS ✓")
end
