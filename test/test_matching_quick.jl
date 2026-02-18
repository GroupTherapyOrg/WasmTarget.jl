# Quick test for wasm_matching_methods — check method + sparams correctness
include("../src/typeinf/subtype.jl")
include("../src/typeinf/matching.jl")

using Core.Compiler: InternalMethodTable, findall, MethodMatch

world = Base.get_world_counter()
native_mt = InternalMethodTable(world)

function test_one(name::String, @nospecialize(sig))
    native = findall(sig, native_mt; limit=3)
    wasm = wasm_matching_methods(sig; limit=3)

    native_n = native === nothing ? 0 : length(native.matches)
    wasm_n = wasm === nothing ? 0 : length(wasm.matches)

    # Both nothing = correct match
    if native === nothing && wasm === nothing
        return (true, true)  # (method_ok, sparams_ok)
    end
    if native === nothing || wasm === nothing
        println("✗ $name — null mismatch (native=$native_n, wasm=$wasm_n)")
        return (false, false)
    end
    if native_n != wasm_n
        println("✗ $name — count mismatch (native=$native_n, wasm=$wasm_n)")
        return (false, false)
    end

    method_ok = true
    sparams_ok = true
    for i in 1:native_n
        nm = native.matches[i]::MethodMatch
        wm = wasm.matches[i]::MethodMatch
        if !(nm.method === wm.method)
            println("✗ $name — method[$i] differs: native=$(nm.method.sig) wasm=$(wm.method.sig)")
            method_ok = false
        end
        if nm.sparams != wm.sparams
            println("⚠ $name — sparams[$i]: native=$(nm.sparams) wasm=$(wm.sparams)")
            sparams_ok = false
        end
    end
    return (method_ok, sparams_ok)
end

function run_all_tests()
    cases = [
        # Arithmetic
        ("+(Int64,Int64)", Tuple{typeof(+), Int64, Int64}),
        ("-(Int64,Int64)", Tuple{typeof(-), Int64, Int64}),
        ("*(Int64,Int64)", Tuple{typeof(*), Int64, Int64}),
        ("div(Int64,Int64)", Tuple{typeof(div), Int64, Int64}),

        # Comparison
        ("<(Int64,Int64)", Tuple{typeof(<), Int64, Int64}),
        ("==(Int64,Int64)", Tuple{typeof(==), Int64, Int64}),
        ("isless(Int64,Int64)", Tuple{typeof(isless), Int64, Int64}),
        ("isequal(Int64,Int64)", Tuple{typeof(isequal), Int64, Int64}),

        # Math
        ("abs(Int64)", Tuple{typeof(abs), Int64}),
        ("max(Int64,Int64)", Tuple{typeof(max), Int64, Int64}),
        ("min(Int64,Int64)", Tuple{typeof(min), Int64, Int64}),

        # Collections
        ("length(String)", Tuple{typeof(length), String}),
        ("push!(Vec,Int64)", Tuple{typeof(push!), Vector{Int64}, Int64}),
        ("getindex(Vec,Int64)", Tuple{typeof(getindex), Vector{Int64}, Int64}),
        ("iterate(Vec)", Tuple{typeof(iterate), Vector{Int64}}),
        ("copy(Vec)", Tuple{typeof(copy), Vector{Int64}}),
        ("haskey(Dict,Sym)", Tuple{typeof(haskey), Dict{Symbol,Int64}, Symbol}),

        # Type constructors
        ("Float64(Int64)", Tuple{Type{Float64}, Int64}),
        ("Bool(Int64)", Tuple{Type{Bool}, Int64}),
        ("convert(T{Int64},F64)", Tuple{typeof(convert), Type{Int64}, Float64}),
        ("zero(T{Int64})", Tuple{typeof(zero), Type{Int64}}),
        ("one(T{Int64})", Tuple{typeof(one), Type{Int64}}),

        # IO
        ("println(String)", Tuple{typeof(println), String}),
        ("string(Int64)", Tuple{typeof(string), Int64}),
        ("repr(Int64)", Tuple{typeof(repr), Int64}),
        ("show(IO,Int64)", Tuple{typeof(show), IO, Int64}),
        ("write(IO,Int64)", Tuple{typeof(write), IO, Int64}),
        ("read(IO,T{Int64})", Tuple{typeof(read), IO, Type{Int64}}),

        # Misc
        ("hash(Int64)", Tuple{typeof(hash), Int64}),
        ("sizeof(Int64)", Tuple{typeof(sizeof), Int64}),

        # Additional parametric types
        ("+(Float64,Float64)", Tuple{typeof(+), Float64, Float64}),
        ("*(Float64,Float64)", Tuple{typeof(*), Float64, Float64}),
        ("convert(T{F64},I64)", Tuple{typeof(convert), Type{Float64}, Int64}),
        ("parse(T{Int64},Str)", Tuple{typeof(parse), Type{Int64}, String}),
        ("getfield(Pair,Int64)", Tuple{typeof(getfield), Pair{Symbol,Int64}, Int64}),

        # Struct types
        ("Pair(Sym,Int64)", Tuple{Type{Pair{Symbol,Int64}}, Symbol, Int64}),

        # Higher-order
        ("map(typeof(+),Vec)", Tuple{typeof(map), typeof(+), Vector{Int64}}),
        ("filter(typeof(iseven),Vec)", Tuple{typeof(filter), typeof(iseven), Vector{Int64}}),

        # String ops
        ("occursin(Str,Str)", Tuple{typeof(occursin), String, String}),
        ("replace(Str,Pair)", Tuple{typeof(replace), String, Pair{String,String}}),
    ]

    method_pass = 0
    sparams_pass = 0
    total = length(cases)

    for (name, sig) in cases
        m_ok, s_ok = test_one(name, sig)
        if m_ok
            method_pass += 1
        end
        if s_ok
            sparams_pass += 1
        end
        if m_ok && s_ok
            print("✓ ")
        elseif m_ok
            print("⚠ ")  # method ok, sparams differ
        end
    end

    println("\nMethod matching: $method_pass/$total CORRECT")
    println("Sparams matching: $sparams_pass/$total CORRECT")
end

run_all_tests()
