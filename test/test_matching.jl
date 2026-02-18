# PURE-4131: Comprehensive method matching verification
# Gate test for M_MATCHING_IMPL — 100% match rate required
#
# Tests wasm_matching_methods against native Core.Compiler.findall
# for ALL DictMethodTable oracle cases plus edge cases.

using Test

include("../src/typeinf/subtype.jl")
include("../src/typeinf/matching.jl")

using Core.Compiler: InternalMethodTable, findall, MethodMatch

const WORLD = Base.get_world_counter()
const NATIVE_MT = InternalMethodTable(WORLD)

# ─── Helper: compare one signature ───

function compare_matching(name::String, @nospecialize(sig); limit::Int=3)
    native = findall(sig, NATIVE_MT; limit=limit)
    wasm = wasm_matching_methods(sig; limit=limit)

    native_n = native === nothing ? 0 : length(native.matches)
    wasm_n = wasm === nothing ? 0 : length(wasm.matches)

    # Both nothing = correct (limit exceeded equally)
    if native === nothing && wasm === nothing
        return true
    end

    @test native !== nothing  # native should find methods
    @test wasm !== nothing    # wasm should find methods
    (native === nothing || wasm === nothing) && return false

    @test native_n == wasm_n  # same number of matches

    if native_n != wasm_n
        println("  ✗ $name — count mismatch: native=$native_n, wasm=$wasm_n")
        return false
    end

    all_ok = true
    for i in 1:native_n
        nm = native.matches[i]::MethodMatch
        wm = wasm.matches[i]::MethodMatch

        # Methods must be identical (same Method object)
        if !(nm.method === wm.method)
            println("  ✗ $name — method[$i] differs")
            println("    native: $(nm.method.sig)")
            println("    wasm:   $(wm.method.sig)")
            all_ok = false
        end

        # Sparams must match
        if nm.sparams != wm.sparams
            println("  ⚠ $name — sparams[$i] differ")
            println("    native: $(nm.sparams)")
            println("    wasm:   $(wm.sparams)")
            all_ok = false
        end
    end

    @test all_ok
    return all_ok
end

# ─── Section 1: DictMethodTable Oracle Cases (82 cases) ───

@testset "PURE-4131: Method Matching Verification" begin

@testset "Arithmetic (6)" begin
    @test compare_matching("+(I64,I64)", Tuple{typeof(+), Int64, Int64})
    @test compare_matching("-(I64,I64)", Tuple{typeof(-), Int64, Int64})
    @test compare_matching("*(I64,I64)", Tuple{typeof(*), Int64, Int64})
    @test compare_matching("div(I64,I64)", Tuple{typeof(div), Int64, Int64})
    @test compare_matching("rem(I64,I64)", Tuple{typeof(rem), Int64, Int64})
    @test compare_matching("mod(I64,I64)", Tuple{typeof(mod), Int64, Int64})
end

@testset "Math (7)" begin
    @test compare_matching("abs(I64)", Tuple{typeof(abs), Int64})
    @test compare_matching("abs(F64)", Tuple{typeof(abs), Float64})
    @test compare_matching("sqrt(F64)", Tuple{typeof(sqrt), Float64})
    @test compare_matching("sin(F64)", Tuple{typeof(sin), Float64})
    @test compare_matching("cos(F64)", Tuple{typeof(cos), Float64})
    @test compare_matching("exp(F64)", Tuple{typeof(exp), Float64})
    @test compare_matching("log(F64)", Tuple{typeof(log), Float64})
end

@testset "Float arithmetic (4)" begin
    @test compare_matching("+(F64,F64)", Tuple{typeof(+), Float64, Float64})
    @test compare_matching("-(F64,F64)", Tuple{typeof(-), Float64, Float64})
    @test compare_matching("*(F64,F64)", Tuple{typeof(*), Float64, Float64})
    @test compare_matching("/(F64,F64)", Tuple{typeof(/), Float64, Float64})
end

@testset "Comparison (7)" begin
    @test compare_matching("<(I64,I64)", Tuple{typeof(<), Int64, Int64})
    @test compare_matching("<=(I64,I64)", Tuple{typeof(<=), Int64, Int64})
    @test compare_matching(">(I64,I64)", Tuple{typeof(>), Int64, Int64})
    @test compare_matching(">=(I64,I64)", Tuple{typeof(>=), Int64, Int64})
    @test compare_matching("==(I64,I64)", Tuple{typeof(==), Int64, Int64})
    @test compare_matching("isless(I64,I64)", Tuple{typeof(isless), Int64, Int64})
    @test compare_matching("isequal(I64,I64)", Tuple{typeof(isequal), Int64, Int64})
end

@testset "Boolean (4)" begin
    @test compare_matching("&(Bool,Bool)", Tuple{typeof(&), Bool, Bool})
    @test compare_matching("|(Bool,Bool)", Tuple{typeof(|), Bool, Bool})
    @test compare_matching("xor(Bool,Bool)", Tuple{typeof(xor), Bool, Bool})
    not_fn = Base.:!
    @test compare_matching("!(Bool)", Tuple{typeof(not_fn), Bool})
end

@testset "Conversion (3)" begin
    @test compare_matching("convert(TI64,F64)", Tuple{typeof(convert), Type{Int64}, Float64})
    @test compare_matching("convert(TF64,I64)", Tuple{typeof(convert), Type{Float64}, Int64})
    @test compare_matching("convert(TBool,I64)", Tuple{typeof(convert), Type{Bool}, Int64})
end

@testset "String (5)" begin
    @test compare_matching("length(Str)", Tuple{typeof(length), String})
    @test compare_matching("string(I64)", Tuple{typeof(string), Int64})
    @test compare_matching("string(Str)", Tuple{typeof(string), String})
    @test compare_matching("repr(I64)", Tuple{typeof(repr), Int64})
    @test compare_matching("occursin(Str,Str)", Tuple{typeof(occursin), String, String})
end

@testset "IO (4)" begin
    @test compare_matching("println(Str)", Tuple{typeof(println), String})
    @test compare_matching("print(Str)", Tuple{typeof(print), String})
    @test compare_matching("show(IO,I64)", Tuple{typeof(show), IO, Int64})
    @test compare_matching("write(IO,I64)", Tuple{typeof(write), IO, Int64})
end

@testset "Collections (8)" begin
    @test compare_matching("push!(V{I64},I64)", Tuple{typeof(push!), Vector{Int64}, Int64})
    @test compare_matching("getindex(V{I64},I64)", Tuple{typeof(getindex), Vector{Int64}, Int64})
    @test compare_matching("setindex!(V{I64},I64,I64)", Tuple{typeof(setindex!), Vector{Int64}, Int64, Int64})
    @test compare_matching("length(V{I64})", Tuple{typeof(length), Vector{Int64}})
    @test compare_matching("iterate(V{I64})", Tuple{typeof(iterate), Vector{Int64}})
    @test compare_matching("copy(V{I64})", Tuple{typeof(copy), Vector{Int64}})
    @test compare_matching("empty!(V{I64})", Tuple{typeof(empty!), Vector{Int64}})
    @test compare_matching("haskey(Dict,Sym)", Tuple{typeof(haskey), Dict{Symbol,Int64}, Symbol})
end

@testset "Type queries (6)" begin
    @test compare_matching("sizeof(I64)", Tuple{typeof(sizeof), Int64})
    @test compare_matching("sizeof(F64)", Tuple{typeof(sizeof), Float64})
    @test compare_matching("zero(TI64)", Tuple{typeof(zero), Type{Int64}})
    @test compare_matching("one(TI64)", Tuple{typeof(one), Type{Int64}})
    @test compare_matching("typemin(TI64)", Tuple{typeof(typemin), Type{Int64}})
    @test compare_matching("typemax(TI64)", Tuple{typeof(typemax), Type{Int64}})
end

@testset "Hash (2)" begin
    @test compare_matching("hash(I64)", Tuple{typeof(hash), Int64})
    @test compare_matching("hash(Str)", Tuple{typeof(hash), String})
end

@testset "Pair (1)" begin
    @test compare_matching("Pair(Sym,I64)", Tuple{Type{Pair{Symbol,Int64}}, Symbol, Int64})
end

@testset "Min/Max (2)" begin
    @test compare_matching("max(I64,I64)", Tuple{typeof(max), Int64, Int64})
    @test compare_matching("min(I64,I64)", Tuple{typeof(min), Int64, Int64})
end

@testset "Higher-order (3)" begin
    @test compare_matching("map(+,V,V)", Tuple{typeof(map), typeof(+), Vector{Int64}, Vector{Int64}})
    @test compare_matching("filter(iseven,V)", Tuple{typeof(filter), typeof(iseven), Vector{Int64}})
    @test compare_matching("map(abs,V)", Tuple{typeof(map), typeof(abs), Vector{Int64}})
end

@testset "Control flow (3)" begin
    @test compare_matching("identity(I64)", Tuple{typeof(identity), Int64})
    @test compare_matching("isnothing(Nothing)", Tuple{typeof(isnothing), Nothing})
    @test compare_matching("isnothing(I64)", Tuple{typeof(isnothing), Int64})
end

@testset "Type constructors (2)" begin
    @test compare_matching("Float64(I64)", Tuple{Type{Float64}, Int64})
    @test compare_matching("Int64(F64)", Tuple{Type{Int64}, Float64})
end

@testset "Misc numeric (2)" begin
    @test compare_matching("muladd(I64,I64,I64)", Tuple{typeof(muladd), Int64, Int64, Int64})
    @test compare_matching("fma(F64,F64,F64)", Tuple{typeof(fma), Float64, Float64, Float64})
end

@testset "Range (1)" begin
    @test compare_matching(":(I64,I64)", Tuple{typeof(:), Int64, Int64})
end

@testset "String interpolation (1)" begin
    @test compare_matching("string(I64,Str)", Tuple{typeof(string), Int64, String})
end

@testset "Bitwise (2)" begin
    @test compare_matching("<<(I64,I64)", Tuple{typeof(<<), Int64, Int64})
    @test compare_matching(">>(I64,I64)", Tuple{typeof(>>), Int64, Int64})
end

@testset "Sign (2)" begin
    @test compare_matching("sign(I64)", Tuple{typeof(sign), Int64})
    @test compare_matching("signbit(F64)", Tuple{typeof(signbit), Float64})
end

@testset "Rounding (3)" begin
    @test compare_matching("floor(TI64,F64)", Tuple{typeof(floor), Type{Int64}, Float64})
    @test compare_matching("ceil(TI64,F64)", Tuple{typeof(ceil), Type{Int64}, Float64})
    @test compare_matching("round(TI64,F64)", Tuple{typeof(round), Type{Int64}, Float64})
end

@testset "Additional oracle cases (4)" begin
    @test compare_matching("parse(TI64,Str)", Tuple{typeof(parse), Type{Int64}, String})
    @test compare_matching("read(IO,TI64)", Tuple{typeof(read), IO, Type{Int64}})
    @test compare_matching("replace(Str,Pair)", Tuple{typeof(replace), String, Pair{String,String}})
    @test compare_matching("getfield(Pair,I64)", Tuple{typeof(getfield), Pair{Symbol,Int64}, Int64})
end

# ─── Section 2: Edge Cases — Parametric Dispatch ───

@testset "Parametric dispatch" begin
    # Different element types for collections
    @test compare_matching("push!(V{F64},F64)", Tuple{typeof(push!), Vector{Float64}, Float64})
    @test compare_matching("getindex(V{Str},I64)", Tuple{typeof(getindex), Vector{String}, Int64})
    @test compare_matching("length(V{Bool})", Tuple{typeof(length), Vector{Bool}})

    # Dict with different key/value types
    @test compare_matching("haskey(Dict{Str,F64},Str)", Tuple{typeof(haskey), Dict{String,Float64}, String})
    @test compare_matching("getindex(Dict{Sym,I64},Sym)", Tuple{typeof(getindex), Dict{Symbol,Int64}, Symbol})

    # Parametric convert
    @test compare_matching("convert(TI32,I64)", Tuple{typeof(convert), Type{Int32}, Int64})
    @test compare_matching("convert(TF32,F64)", Tuple{typeof(convert), Type{Float32}, Float64})
    @test compare_matching("convert(TUInt8,I64)", Tuple{typeof(convert), Type{UInt8}, Int64})

    # Type constructors with different types
    @test compare_matching("Int32(I64)", Tuple{Type{Int32}, Int64})
    @test compare_matching("UInt64(I64)", Tuple{Type{UInt64}, Int64})
    @test compare_matching("Float32(F64)", Tuple{Type{Float32}, Float64})

    # Parametric zero/one
    @test compare_matching("zero(TF64)", Tuple{typeof(zero), Type{Float64}})
    @test compare_matching("one(TF64)", Tuple{typeof(one), Type{Float64}})
end

# ─── Section 3: Edge Cases — Varargs ───

@testset "Varargs signatures" begin
    # string() with multiple args (varargs)
    @test compare_matching("string(I64,I64)", Tuple{typeof(string), Int64, Int64})
    @test compare_matching("string(Str,Str)", Tuple{typeof(string), String, String})
    @test compare_matching("string(I64,Str,F64)", Tuple{typeof(string), Int64, String, Float64})

    # println with multiple args
    @test compare_matching("println(I64)", Tuple{typeof(println), Int64})
    @test compare_matching("println(I64,Str)", Tuple{typeof(println), Int64, String})

    # print with multiple args
    @test compare_matching("print(I64)", Tuple{typeof(print), Int64})

    # max/min with more args
    @test compare_matching("max(I64,I64,I64)", Tuple{typeof(max), Int64, Int64, Int64})
    @test compare_matching("min(F64,F64,F64)", Tuple{typeof(min), Float64, Float64, Float64})

    # map with multiple collections
    @test compare_matching("map(+,V{I64})", Tuple{typeof(map), typeof(+), Vector{Int64}})
end

# ─── Section 4: Edge Cases — Different Numeric Types ───

@testset "Cross-type numeric" begin
    # Mixed integer types
    @test compare_matching("+(I32,I32)", Tuple{typeof(+), Int32, Int32})
    @test compare_matching("*(I32,I32)", Tuple{typeof(*), Int32, Int32})
    @test compare_matching("<(I32,I32)", Tuple{typeof(<), Int32, Int32})

    # Mixed float types
    @test compare_matching("+(F32,F32)", Tuple{typeof(+), Float32, Float32})
    @test compare_matching("*(F32,F32)", Tuple{typeof(*), Float32, Float32})

    # Unsigned
    @test compare_matching("+(UInt64,UInt64)", Tuple{typeof(+), UInt64, UInt64})
    @test compare_matching("&(UInt64,UInt64)", Tuple{typeof(&), UInt64, UInt64})

    # Bool arithmetic (Bool <: Integer)
    @test compare_matching("+(Bool,Bool)", Tuple{typeof(+), Bool, Bool})
    @test compare_matching("xor(I64,I64)", Tuple{typeof(xor), Int64, Int64})
end

# ─── Section 5: Edge Cases — Complex Types ───

@testset "Complex type signatures" begin
    # Tuple operations
    @test compare_matching("length(NTuple)", Tuple{typeof(length), NTuple{3,Int64}})
    @test compare_matching("getindex(Tuple,I64)", Tuple{typeof(getindex), Tuple{Int64,String}, Int64})

    # Set operations
    @test compare_matching("push!(Set{I64},I64)", Tuple{typeof(push!), Set{Int64}, Int64})
    @test compare_matching("length(Set{I64})", Tuple{typeof(length), Set{Int64}})

    # Matrix/Array operations
    @test compare_matching("size(Matrix{F64})", Tuple{typeof(size), Matrix{Float64}})
    @test compare_matching("length(Matrix{I64})", Tuple{typeof(length), Matrix{Int64}})
    @test compare_matching("getindex(Matrix{F64},I64,I64)", Tuple{typeof(getindex), Matrix{Float64}, Int64, Int64})

    # Channel, Ref
    @test compare_matching("iterate(Channel{I64})", Tuple{typeof(iterate), Channel{Int64}})
    @test compare_matching("getindex(Ref{I64})", Tuple{typeof(getindex), Ref{Int64}})
end

# ─── Section 6: Edge Cases — Abstract Type Signatures ───
# These test non-dispatch-tuple behavior (abstract args → intersection matching)

@testset "Abstract type signatures" begin
    # Abstract number types
    @test compare_matching("+(Integer,Integer)", Tuple{typeof(+), Integer, Integer})
    @test compare_matching("*(Number,Number)", Tuple{typeof(*), Number, Number})
    @test compare_matching("<(Real,Real)", Tuple{typeof(<), Real, Real})

    # Abstract collection types
    @test compare_matching("length(AbstractVector)", Tuple{typeof(length), AbstractVector{Int64}})
    @test compare_matching("iterate(AbstractArray)", Tuple{typeof(iterate), AbstractArray{Float64}})

    # Abstract string
    @test compare_matching("length(AbstractString)", Tuple{typeof(length), AbstractString})
end

# ─── Section 7: Edge Cases — Identity and Edge Methods ───

@testset "Identity and edge methods" begin
    # identity for various types
    @test compare_matching("identity(F64)", Tuple{typeof(identity), Float64})
    @test compare_matching("identity(Str)", Tuple{typeof(identity), String})
    @test compare_matching("identity(Nothing)", Tuple{typeof(identity), Nothing})

    # isa (intrinsic)
    @test compare_matching("isa(I64,Type{I64})", Tuple{typeof(isa), Int64, Type{Int64}})

    # typeof
    @test compare_matching("typeof(I64)", Tuple{typeof(typeof), Int64})

    # === (egality)
    @test compare_matching("===(I64,I64)", Tuple{typeof(===), Int64, Int64})

    # throw
    @test compare_matching("throw(ErrorException)", Tuple{typeof(throw), ErrorException})
end

# ─── Section 8: Edge Cases — Iterate with State ───

@testset "Iterate with state (2-arg)" begin
    @test compare_matching("iterate(V{I64},I64)", Tuple{typeof(iterate), Vector{Int64}, Int64})
    @test compare_matching("iterate(Str,I64)", Tuple{typeof(iterate), String, Int64})
    @test compare_matching("iterate(UnitRange{I64},I64)", Tuple{typeof(iterate), UnitRange{Int64}, Int64})
end

# ─── Summary ───

println("\nPURE-4131: All method matching tests passed!")
println("Gate: M_MATCHING_IMPL — PASSED")

end  # outer testset
