#!/usr/bin/env julia
# PURE-5002: Diagnose why "sin(1.0)" and "f(x) = x + 1" TRAP in Wasm parser
#
# The parser works for "1+1" and "42" but TRAPs for more complex inputs.
# Progressive isolation: find the simplest input that triggers the TRAP.

using WasmTarget
using JuliaSyntax

println("=" ^ 60)
println("PURE-5002: Diagnose parse TRAP for complex inputs")
println("=" ^ 60)

# Test inputs from simplest to most complex
inputs = [
    "1",         # single int literal
    "42",        # multi-digit int
    "1+1",       # binary op
    "x",         # identifier
    "1.0",       # float literal
    ":x",        # symbol
    "f(1)",      # function call with int arg
    "sin(1.0)",  # function call with float arg
    "x + 1",     # binary op with identifier
    "f(x) = x",  # short function def
]

for input in inputs
    # Create a test function dynamically
    # Since we can't use string interpolation in function bodies,
    # we define functions for each input statically
end

# Actually, we need static function definitions. Let's define them all.
function parse_1()::Int32
    ps = JuliaSyntax.ParseStream("1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_42()::Int32
    ps = JuliaSyntax.ParseStream("42")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_1plus1()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_x()::Int32
    ps = JuliaSyntax.ParseStream("x")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_float()::Int32
    ps = JuliaSyntax.ParseStream("1.0")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_symbol()::Int32
    ps = JuliaSyntax.ParseStream(":x")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_call_int()::Int32
    ps = JuliaSyntax.ParseStream("f(1)")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_sin()::Int32
    ps = JuliaSyntax.ParseStream("sin(1.0)")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_x_plus_1()::Int32
    ps = JuliaSyntax.ParseStream("x + 1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_fundef()::Int32
    ps = JuliaSyntax.ParseStream("f(x) = x")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

tests = [
    ("parse_1",       parse_1,       "1"),
    ("parse_42",      parse_42,      "42"),
    ("parse_1plus1",  parse_1plus1,  "1+1"),
    ("parse_x",       parse_x,       "x"),
    ("parse_float",   parse_float,   "1.0"),
    ("parse_symbol",  parse_symbol,  ":x"),
    ("parse_call_int",parse_call_int,"f(1)"),
    ("parse_sin",     parse_sin,     "sin(1.0)"),
    ("parse_x_plus_1",parse_x_plus_1,"x + 1"),
    ("parse_fundef",  parse_fundef,  "f(x) = x"),
]

println("\n--- Native Ground Truth ---")
for (name, func, input) in tests
    native = func()
    println("  $name ($input): native=$native")
end

println("\n--- Compile & Test ---")
for (name, func, input) in tests
    native = func()
    print("$name ($input): ")

    local bytes
    try
        bytes = compile_multi([(func, ())])
    catch e
        println("COMPILE_ERROR: $(first(sprint(showerror, e), 100))")
        continue
    end

    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    valid = try
        run(`wasm-tools validate --features=gc $tmpf`)
        true
    catch; false end

    if !valid
        println("VALIDATE_ERROR")
        rm(tmpf, force=true)
        continue
    end

    jsf = tempname() * ".mjs"
    write(jsf, """
import fs from "fs";
const bytes = fs.readFileSync("$(tmpf)");
async function run() {
    try {
        const {instance} = await WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } });
        const result = instance.exports["$name"]();
        console.log("OK:" + (typeof result === "bigint" ? result.toString() : JSON.stringify(result)));
    } catch(e) { console.log("TRAP:" + e.constructor.name); }
}
run();
""")
    output = strip(read(`node $jsf`, String))
    if startswith(output, "OK:")
        val = output[4:end]
        actual = try Base.parse(Int32, val) catch; val end
        if actual == native
            println("CORRECT")
        else
            println("WRONG (native=$native, wasm=$actual)")
        end
    else
        println(output)
    end
    rm(tmpf, force=true)
    rm(jsf, force=true)
end

println("\nDone.")
