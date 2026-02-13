using WasmTarget
using JuliaSyntax

# Test: How many output nodes does bump_trivia add?
function test_bump_trivia_count(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    before = length(stream.output)
    JuliaSyntax.bump_trivia(stream; skip_newlines=true)
    after = length(stream.output)
    return Int32(after - before)
end

# Test: How many output nodes does a single bump add?
function test_bump_count(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.bump_trivia(stream; skip_newlines=true)
    before = length(stream.output)
    JuliaSyntax.bump(stream)
    after = length(stream.output)
    return Int32(after - before)
end

# Test: What is lookahead_index before and after bump_trivia?
function test_lookahead_idx_before(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    return Int32(stream.lookahead_index)
end

function test_lookahead_idx_after_trivia(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.bump_trivia(stream; skip_newlines=true)
    return Int32(stream.lookahead_index)
end

println("=== Native Julia Ground Truth ===")
for s in ["1", " 1", "  1"]
    bt = test_bump_trivia_count(s)
    bc = test_bump_count(s)
    lb = test_lookahead_idx_before(s)
    la = test_lookahead_idx_after_trivia(s)
    println("\"$s\": bump_trivia_added=$bt bump_added=$bc la_before=$lb la_after_trivia=$la")
end

println("\n=== Compiling ===")
for (name, fn) in [
    ("test_bump_trivia_count", test_bump_trivia_count),
    ("test_bump_count", test_bump_count),
    ("test_lookahead_idx_before", test_lookahead_idx_before),
    ("test_lookahead_idx_after_trivia", test_lookahead_idx_after_trivia),
]
    print("$name: ")
    try
        bytes = WasmTarget.compile(fn, (String,))
        write("WasmTarget.jl/browser/$(name).wasm", bytes)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        val = read(`wasm-tools validate $tmpf`, String)
        nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
        println("$(length(bytes)) bytes, $nfuncs funcs, validates=$(isempty(val) ? "YES" : val)")
    catch e
        println("ERROR: ", sprint(showerror, e)[1:min(200, end)])
    end
end
