#!/usr/bin/env julia
# PURE-5002 Agent 3: Test float parsing with pure Julia override
#
# Strategy: Include float_parse.jl override BEFORE compilation so that
# code_typed sees the pure Julia version without ccall(:jl_strtod_c)

using WasmTarget
using JuliaSyntax

# Override parse_float_literal with pure Julia implementation
include(joinpath(@__DIR__, "..", "src", "runtime", "float_parse.jl"))

println("=" ^ 60)
println("PURE-5002: Test float literal parsing with override")
println("=" ^ 60)

# Test functions — simple indicators that return Int32 for easy comparison
function parse_float_ok()::Int32
    ps = JuliaSyntax.ParseStream("1.0")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_sin_ok()::Int32
    ps = JuliaSyntax.ParseStream("sin(1.0)")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_1plus1_ok()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_fundef_ok()::Int32
    ps = JuliaSyntax.ParseStream("f(x) = x + 1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

tests = [
    ("parse_1plus1_ok", parse_1plus1_ok),
    ("parse_float_ok", parse_float_ok),
    ("parse_sin_ok", parse_sin_ok),
    ("parse_fundef_ok", parse_fundef_ok),
]

println("\n--- Native Ground Truth ---")
native_vals = Dict{String, Int32}()
for (name, func) in tests
    n = func()
    println("  $name: $n")
    native_vals[name] = n
end

println("\n--- Compile ---")
funcs = [(f, ()) for (_, f) in tests]
bytes = try
    compile_multi(funcs)
catch e
    println("COMPILE ERROR: $(sprint(showerror, e))")
    exit(1)
end
println("Compiled: $(length(bytes)) bytes")

tmpf = tempname() * ".wasm"
write(tmpf, bytes)

nfuncs = try
    read(`wasm-tools print $tmpf`, String) |> s -> count("(func", s)
catch; "?" end
println("Functions: $nfuncs")

valid = try
    run(`wasm-tools validate --features=gc $tmpf`)
    true
catch; false end
println("Validates: $valid")

if !valid
    println("VALIDATION FAILED — aborting")
    rm(tmpf, force=true)
    exit(1)
end

println("\n--- Test in Node.js ---")
for (name, _) in tests
    native = native_vals[name]
    jsf = tempname() * ".mjs"
    write(jsf, """
import fs from "fs";
const bytes = fs.readFileSync("$(tmpf)");
async function run() {
    try {
        const {instance} = await WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } });
        const result = instance.exports["$name"]();
        console.log("OK:" + (typeof result === "bigint" ? result.toString() : JSON.stringify(result)));
    } catch(e) { console.log("TRAP:" + e.message); }
}
run();
""")
    output = strip(read(`timeout 10 node $jsf`, String))
    if startswith(output, "OK:")
        val = try Base.parse(Int32, output[4:end]) catch; output[4:end] end
        if val == native
            println("  $name: CORRECT ($val)")
        else
            println("  $name: WRONG (native=$native, wasm=$val)")
        end
    else
        println("  $name: $output")
    end
    rm(jsf, force=true)
end

rm(tmpf, force=true)
println("\nDone.")
