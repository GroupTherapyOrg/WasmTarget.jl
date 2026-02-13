using WasmTarget
using JuliaSyntax

# Test: Does the parse! rule dispatch work correctly in the multi-function context?
# This function should return 2 for :statement (parse_stmts branch)
# If it returns 1, it means the :all branch (parse_toplevel) was taken incorrectly.
function test_rule_dispatch_in_parse(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    # This should call parse! with rule=:statement
    # parse! dispatches: :all → parse_toplevel (returns 1 if that path taken)
    #                    :statement → parse_stmts (returns 2)

    # Actually, we can't observe the dispatch directly. Instead, count output nodes:
    # rule=:statement for "1" → 2 output nodes (TOMBSTONE + Integer)
    # rule=:all for "1" → 3 output nodes (TOMBSTONE + Integer + toplevel)
    JuliaSyntax.parse!(stream; rule=:statement)
    return Int32(length(stream.output))
end

# This is the exact same function as parsestmt uses internally
# parsestmt(Expr, s) calls _parse(:statement, true, Expr, s)
# _parse calls parse!(stream; rule=:statement)
# If Wasm gets 3 instead of 2, it means the :all path was taken

println("=== Native Julia Ground Truth ===")
println("test_rule_dispatch_in_parse(\"1\") = ", test_rule_dispatch_in_parse("1"), " (expected 2)")
println("test_rule_dispatch_in_parse(\"hello\") = ", test_rule_dispatch_in_parse("hello"), " (expected 2)")

println("\n=== Compiling (this is the big multi-function context) ===")
try
    bytes = WasmTarget.compile(test_rule_dispatch_in_parse, (String,))
    write("WasmTarget.jl/browser/test_rule_dispatch.wasm", bytes)
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
    val = read(`wasm-tools validate $tmpf`, String)
    println("$(length(bytes)) bytes, $nfuncs funcs, validates=$(isempty(val) ? "YES" : val)")
catch e
    println("ERROR: ", sprint(showerror, e)[1:min(300, end)])
end
