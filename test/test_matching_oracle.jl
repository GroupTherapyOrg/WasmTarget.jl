# Test wasm_matching_methods against native findall for 77+ DictMethodTable oracle cases
include("../src/typeinf/subtype.jl")
include("../src/typeinf/matching.jl")

using Core.Compiler: InternalMethodTable, findall, MethodMatch

world = Base.get_world_counter()
native_mt = InternalMethodTable(world)

# Build test signatures (the 77 DictMethodTable cases + extras)
test_sigs = Any[]

# Arithmetic (6)
push!(test_sigs, ("+(I64,I64)", Tuple{typeof(+), Int64, Int64}))
push!(test_sigs, ("-(I64,I64)", Tuple{typeof(-), Int64, Int64}))
push!(test_sigs, ("*(I64,I64)", Tuple{typeof(*), Int64, Int64}))
push!(test_sigs, ("div(I64,I64)", Tuple{typeof(div), Int64, Int64}))
push!(test_sigs, ("rem(I64,I64)", Tuple{typeof(rem), Int64, Int64}))
push!(test_sigs, ("mod(I64,I64)", Tuple{typeof(mod), Int64, Int64}))

# Math (7)
push!(test_sigs, ("abs(I64)", Tuple{typeof(abs), Int64}))
push!(test_sigs, ("abs(F64)", Tuple{typeof(abs), Float64}))
push!(test_sigs, ("sqrt(F64)", Tuple{typeof(sqrt), Float64}))
push!(test_sigs, ("sin(F64)", Tuple{typeof(sin), Float64}))
push!(test_sigs, ("cos(F64)", Tuple{typeof(cos), Float64}))
push!(test_sigs, ("exp(F64)", Tuple{typeof(exp), Float64}))
push!(test_sigs, ("log(F64)", Tuple{typeof(log), Float64}))

# Float arithmetic (4)
push!(test_sigs, ("+(F64,F64)", Tuple{typeof(+), Float64, Float64}))
push!(test_sigs, ("-(F64,F64)", Tuple{typeof(-), Float64, Float64}))
push!(test_sigs, ("*(F64,F64)", Tuple{typeof(*), Float64, Float64}))
push!(test_sigs, ("/(F64,F64)", Tuple{typeof(/), Float64, Float64}))

# Comparison (7)
push!(test_sigs, ("<(I64,I64)", Tuple{typeof(<), Int64, Int64}))
push!(test_sigs, ("<=(I64,I64)", Tuple{typeof(<=), Int64, Int64}))
push!(test_sigs, (">(I64,I64)", Tuple{typeof(>), Int64, Int64}))
push!(test_sigs, (">=(I64,I64)", Tuple{typeof(>=), Int64, Int64}))
push!(test_sigs, ("==(I64,I64)", Tuple{typeof(==), Int64, Int64}))
push!(test_sigs, ("isless(I64,I64)", Tuple{typeof(isless), Int64, Int64}))
push!(test_sigs, ("isequal(I64,I64)", Tuple{typeof(isequal), Int64, Int64}))

# Boolean (4)
push!(test_sigs, ("&(Bool,Bool)", Tuple{typeof(&), Bool, Bool}))
push!(test_sigs, ("|(Bool,Bool)", Tuple{typeof(|), Bool, Bool}))
push!(test_sigs, ("xor(Bool,Bool)", Tuple{typeof(xor), Bool, Bool}))
not_fn = Base.:!
push!(test_sigs, ("not(Bool)", Tuple{typeof(not_fn), Bool}))

# Conversion (3)
push!(test_sigs, ("convert(TI64,F64)", Tuple{typeof(convert), Type{Int64}, Float64}))
push!(test_sigs, ("convert(TF64,I64)", Tuple{typeof(convert), Type{Float64}, Int64}))
push!(test_sigs, ("convert(TBool,I64)", Tuple{typeof(convert), Type{Bool}, Int64}))

# String (5)
push!(test_sigs, ("length(Str)", Tuple{typeof(length), String}))
push!(test_sigs, ("string(I64)", Tuple{typeof(string), Int64}))
push!(test_sigs, ("string(Str)", Tuple{typeof(string), String}))
push!(test_sigs, ("repr(I64)", Tuple{typeof(repr), Int64}))
push!(test_sigs, ("occursin(Str,Str)", Tuple{typeof(occursin), String, String}))

# IO (4)
push!(test_sigs, ("println(Str)", Tuple{typeof(println), String}))
push!(test_sigs, ("print(Str)", Tuple{typeof(print), String}))
push!(test_sigs, ("show(IO,I64)", Tuple{typeof(show), IO, Int64}))
push!(test_sigs, ("write(IO,I64)", Tuple{typeof(write), IO, Int64}))

# Collections (8)
push!(test_sigs, ("push!(V,I64)", Tuple{typeof(push!), Vector{Int64}, Int64}))
push!(test_sigs, ("getindex(V,I64)", Tuple{typeof(getindex), Vector{Int64}, Int64}))
push!(test_sigs, ("setindex!(V,I64,I64)", Tuple{typeof(setindex!), Vector{Int64}, Int64, Int64}))
push!(test_sigs, ("length(V)", Tuple{typeof(length), Vector{Int64}}))
push!(test_sigs, ("iterate(V)", Tuple{typeof(iterate), Vector{Int64}}))
push!(test_sigs, ("copy(V)", Tuple{typeof(copy), Vector{Int64}}))
push!(test_sigs, ("empty!(V)", Tuple{typeof(empty!), Vector{Int64}}))
push!(test_sigs, ("haskey(Dict,Sym)", Tuple{typeof(haskey), Dict{Symbol,Int64}, Symbol}))

# Type queries (6)
push!(test_sigs, ("sizeof(I64)", Tuple{typeof(sizeof), Int64}))
push!(test_sigs, ("sizeof(F64)", Tuple{typeof(sizeof), Float64}))
push!(test_sigs, ("zero(TI64)", Tuple{typeof(zero), Type{Int64}}))
push!(test_sigs, ("one(TI64)", Tuple{typeof(one), Type{Int64}}))
push!(test_sigs, ("typemin(TI64)", Tuple{typeof(typemin), Type{Int64}}))
push!(test_sigs, ("typemax(TI64)", Tuple{typeof(typemax), Type{Int64}}))

# Hash (2)
push!(test_sigs, ("hash(I64)", Tuple{typeof(hash), Int64}))
push!(test_sigs, ("hash(Str)", Tuple{typeof(hash), String}))

# Pair (1)
push!(test_sigs, ("Pair(Sym,I64)", Tuple{Type{Pair{Symbol,Int64}}, Symbol, Int64}))

# Min/Max (2)
push!(test_sigs, ("max(I64,I64)", Tuple{typeof(max), Int64, Int64}))
push!(test_sigs, ("min(I64,I64)", Tuple{typeof(min), Int64, Int64}))

# Higher-order (3)
push!(test_sigs, ("map(+,V,V)", Tuple{typeof(map), typeof(+), Vector{Int64}, Vector{Int64}}))
push!(test_sigs, ("filter(iseven,V)", Tuple{typeof(filter), typeof(iseven), Vector{Int64}}))
push!(test_sigs, ("map(abs,V)", Tuple{typeof(map), typeof(abs), Vector{Int64}}))

# Control flow (3)
push!(test_sigs, ("identity(I64)", Tuple{typeof(identity), Int64}))
push!(test_sigs, ("isnothing(Nothing)", Tuple{typeof(isnothing), Nothing}))
push!(test_sigs, ("isnothing(I64)", Tuple{typeof(isnothing), Int64}))

# Type constructors (2)
push!(test_sigs, ("Float64(I64)", Tuple{Type{Float64}, Int64}))
push!(test_sigs, ("Int64(F64)", Tuple{Type{Int64}, Float64}))

# Misc numeric (2)
push!(test_sigs, ("muladd(I64,I64,I64)", Tuple{typeof(muladd), Int64, Int64, Int64}))
push!(test_sigs, ("fma(F64,F64,F64)", Tuple{typeof(fma), Float64, Float64, Float64}))

# Range (1)
push!(test_sigs, (":(I64,I64)", Tuple{typeof(:), Int64, Int64}))

# String interpolation (1)
push!(test_sigs, ("string(I64,Str)", Tuple{typeof(string), Int64, String}))

# Bitwise (2)
push!(test_sigs, ("<<(I64,I64)", Tuple{typeof(<<), Int64, Int64}))
push!(test_sigs, (">>(I64,I64)", Tuple{typeof(>>), Int64, Int64}))

# Sign (2)
push!(test_sigs, ("sign(I64)", Tuple{typeof(sign), Int64}))
push!(test_sigs, ("signbit(F64)", Tuple{typeof(signbit), Float64}))

# Rounding (3)
push!(test_sigs, ("floor(TI64,F64)", Tuple{typeof(floor), Type{Int64}, Float64}))
push!(test_sigs, ("ceil(TI64,F64)", Tuple{typeof(ceil), Type{Int64}, Float64}))
push!(test_sigs, ("round(TI64,F64)", Tuple{typeof(round), Type{Int64}, Float64}))

# Additional edge cases
push!(test_sigs, ("parse(TI64,Str)", Tuple{typeof(parse), Type{Int64}, String}))
push!(test_sigs, ("read(IO,TI64)", Tuple{typeof(read), IO, Type{Int64}}))
push!(test_sigs, ("replace(Str,Pair)", Tuple{typeof(replace), String, Pair{String,String}}))
push!(test_sigs, ("getfield(Pair,I64)", Tuple{typeof(getfield), Pair{Symbol,Int64}, Int64}))

# Run tests
function run_oracle_tests()
    method_pass = 0
    sparams_pass = 0
    total = length(test_sigs)

    for (name, sig) in test_sigs
        native = findall(sig, native_mt; limit=3)
        wasm = wasm_matching_methods(sig; limit=3)

        native_n = native === nothing ? 0 : length(native.matches)
        wasm_n = wasm === nothing ? 0 : length(wasm.matches)

        # Both nothing = correct
        if native === nothing && wasm === nothing
            method_pass += 1
            sparams_pass += 1
            print("✓ ")
            continue
        end

        if native === nothing || wasm === nothing || native_n != wasm_n
            println("✗ $name — count: native=$native_n, wasm=$wasm_n")
            continue
        end

        m_ok = true
        s_ok = true
        for i in 1:native_n
            nm = native.matches[i]::MethodMatch
            wm = wasm.matches[i]::MethodMatch
            if !(nm.method === wm.method)
                m_ok = false
            end
            if nm.sparams != wm.sparams
                s_ok = false
            end
        end

        if m_ok
            method_pass += 1
            if s_ok
                sparams_pass += 1
                print("✓ ")
            else
                print("⚠ ")
            end
        else
            println("✗ $name — method mismatch")
        end
    end

    println("\n\n=== RESULTS ===")
    println("Method matching: $method_pass/$total CORRECT")
    println("Sparams matching: $sparams_pass/$total CORRECT")

    if method_pass == total
        println("\nALL METHODS CORRECT")
    end
    if sparams_pass == total
        println("ALL SPARAMS CORRECT")
    end
end

run_oracle_tests()
