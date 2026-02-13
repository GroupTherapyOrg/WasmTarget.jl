using WasmTarget
using JuliaSyntax

# Simple parse: just call parse! and return output length
# This will pull in the full parser tree, but let's see how many funcs
function test_parse_only(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream; rule=:statement)
    return Int32(length(stream.output))
end

# Even simpler: just create a stream and return a field
function test_parse_stream_only(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    return Int32(stream.next_byte)
end

# Medium: create stream, bump one token, return output count
function test_bump_one(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.bump(stream)
    return Int32(length(stream.output))
end

println("=== Native Julia Ground Truth ===")
for s in ["1", "hello"]
    println("\"$s\": parse_only=$(test_parse_only(s)) stream_only=$(test_parse_stream_only(s)) bump_one=$(test_bump_one(s))")
end

println("\n=== Function count comparison ===")
for (name, fn) in [
    ("test_parse_stream_only", test_parse_stream_only),
    ("test_bump_one", test_bump_one),
    ("test_parse_only", test_parse_only),
]
    entry = [(fn, (String,), name)]
    deps = WasmTarget.discover_dependencies(entry)
    println("$name: $(length(deps)) functions")
end
