#!/usr/bin/env julia
# PURE-4151: Isolation tests to find root cause of runtime traps
using WasmTarget
include(joinpath(@__DIR__, "..", "test", "utils.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "subtype.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "matching.jl"))

if NODE_CMD === nothing
    println("Node.js not available — aborting")
    exit(1)
end

# ─── Test 1: _datatype_subtype alone ───
println("=" ^ 60)
println("Test 1: _datatype_subtype(Int64, Number) via compile_multi")

test_dsub() = Int32(_datatype_subtype(Int64, Number))

funcs1 = [
    (_datatype_subtype, (DataType, DataType)),
    (test_dsub, ()),
]

bytes1 = compile_multi(funcs1)
println("  Compiled: $(length(bytes1)) bytes")
tmpf = tempname() * ".wasm"
write(tmpf, bytes1)
try
    run(`wasm-tools validate --features=gc $tmpf`)
    println("  VALIDATES ✓")
catch
    valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`) catch; "" end
    println("  VALIDATE_ERROR: $(first(valerr, 200))")
end

try
    r = run_wasm(bytes1, "test_dsub")
    println("  Node.js: $r (expected: 1)")
catch e
    println("  ERROR: $(sprint(showerror, e))")
end
rm(tmpf, force=true)

# ─── Test 2: wasm_subtype with FULL function set ───
println("\n" * "=" ^ 60)
println("Test 2: wasm_subtype(Int64, Number) with full function set")

test_wsub() = Int32(wasm_subtype(Int64, Number))

subtype_functions = [
    (wasm_subtype, (Any, Any)),
    (_subtype, (Any, Any, SubtypeEnv, Int)),
    (lookup, (SubtypeEnv, TypeVar)),
    (VarBinding, (TypeVar, Bool)),
    (_var_lt, (VarBinding, Any, SubtypeEnv, Int)),
    (_var_gt, (VarBinding, Any, SubtypeEnv, Int)),
    (_subtype_var, (VarBinding, Any, SubtypeEnv, Bool, Int)),
    (_record_var_occurrence, (VarBinding, SubtypeEnv, Int)),
    (_subtype_unionall, (Any, UnionAll, SubtypeEnv, Bool, Int)),
    (_subtype_inner, (Any, Any, SubtypeEnv, Bool, Int)),
    (_is_leaf_bound, (Any,)),
    (_type_contains_var, (Any, TypeVar)),
    (_subtype_check, (Any, Any)),
    (_subtype_datatypes, (DataType, DataType, SubtypeEnv, Int)),
    (_forall_exists_equal, (Any, Any, SubtypeEnv)),
    (_tuple_subtype_env, (DataType, DataType, SubtypeEnv, Int)),
    (_subtype_tuple_param, (Any, Any, SubtypeEnv)),
    (_datatype_subtype, (DataType, DataType)),
    (_tuple_subtype, (DataType, DataType)),
    (_subtype_param, (Any, Any)),
]

funcs2 = vcat(subtype_functions, [(test_wsub, ())])

bytes2 = compile_multi(funcs2)
println("  Compiled: $(length(bytes2)) bytes")
tmpf = tempname() * ".wasm"
write(tmpf, bytes2)
try
    run(`wasm-tools validate --features=gc $tmpf`)
    println("  VALIDATES ✓")
catch
    valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`) catch; "" end
    println("  VALIDATE_ERROR: $(first(valerr, 200))")
end

try
    r = run_wasm(bytes2, "test_wsub")
    println("  Node.js: $r (expected: 1)")
catch e
    println("  ERROR: $(sprint(showerror, e))")
end
rm(tmpf, force=true)

# ─── Test 3: Identify which function traps ───
println("\n" * "=" ^ 60)
println("Test 3: Trace which function traps via verbose Node.js")

# Write wasm to disk for detailed analysis
wasm_path = joinpath(@__DIR__, "debug_4151.wasm")
write(wasm_path, bytes2)

# Create JS that catches and prints stack trace
js = """
import fs from 'fs';
const bytes = fs.readFileSync('$(escape_string(wasm_path))');
async function run() {
    try {
        const importObject = { Math: { pow: Math.pow } };
        const wasmModule = await WebAssembly.instantiate(bytes, importObject);
        console.log("Module loaded OK");
        const exports = wasmModule.instance.exports;
        console.log("Exports:", Object.keys(exports).join(", "));
        try {
            const result = exports.test_wsub();
            console.log("test_wsub() =", result);
        } catch (e) {
            console.log("test_wsub TRAP:", e.message);
            console.log("Stack:", e.stack);
        }
    } catch (e) {
        console.log("INSTANTIATION TRAP:", e.message);
        console.log("Stack:", e.stack);
    }
}
run();
"""
js_path = joinpath(@__DIR__, "debug_4151.mjs")
open(js_path, "w") do io; print(io, js); end
output = read(`node $js_path`, String)
println(output)

println("\nDone.")
