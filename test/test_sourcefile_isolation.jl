using WasmTarget
include("utils.jl")

using JuliaSyntax: SourceFile

# Test 1: Can we construct a SourceFile from a String?
println("=== Test 1: SourceFile from String ===")
try
    # SourceFile(code::AbstractString; ...) eventually calls #SourceFile#8
    # which takes (filename, first_line, first_index, ::Type{SourceFile}, code::SubString{String})
    # Let's try just the inner constructor path

    # First, test SubString creation
    test_substr(s::String) = SubString(s, 1, length(s))
    r = compare_julia_wasm(test_substr, "hello")
    println("SubString: pass=$(r.pass), expected=$(r.expected), actual=$(r.actual)")
catch e
    println("Test 1 error: $e")
end

# Test 2: Can we iterate over codeunits in a loop (SourceFile#8 pattern)?
println("\n=== Test 2: Count newlines (SourceFile#8 core loop) ===")
try
    function count_newlines_simple(s::String)
        n = Int64(0)
        for i in 1:length(s)
            if codeunit(s, i) == UInt8('\n')
                n += Int64(1)
            end
        end
        return n
    end

    for input in ["hello", "a\nb", "a\nb\nc\n"]
        r = compare_julia_wasm(count_newlines_simple, input)
        println("count_newlines_simple($(repr(input))): pass=$(r.pass), expected=$(r.expected), actual=$(r.actual)")
    end
catch e
    println("Test 2 error: $e")
end

# Test 3: Can we create a Vector{Int64} with push! (SourceFile#8 stores line offsets)?
println("\n=== Test 3: Vector creation with push! ===")
try
    function make_line_starts(s::String)
        starts = Int64[0]
        for i in 1:length(s)
            if codeunit(s, i) == UInt8('\n')
                push!(starts, Int64(i))
            end
        end
        return length(starts)
    end

    for input in ["hello", "a\nb", "a\nb\nc\n"]
        r = compare_julia_wasm(make_line_starts, input)
        println("make_line_starts($(repr(input))): pass=$(r.pass), expected=$(r.expected), actual=$(r.actual)")
    end
catch e
    println("Test 3 error: $e")
end

# Test 4: What about SubString + codeunit iteration?
println("\n=== Test 4: SubString + codeunit iteration ===")
try
    function count_newlines_substr(s::String)
        ss = SubString(s, 1, length(s))
        n = Int64(0)
        for i in 1:ncodeunits(ss)
            if codeunit(ss, i) == UInt8('\n')
                n += Int64(1)
            end
        end
        return n
    end

    for input in ["hello", "a\nb"]
        r = compare_julia_wasm(count_newlines_substr, input)
        println("count_newlines_substr($(repr(input))): pass=$(r.pass), expected=$(r.expected), actual=$(r.actual)")
    end
catch e
    println("Test 4 error: $e")
end

println("\nDone!")
