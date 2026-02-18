#!/usr/bin/env julia
# PURE-5002: Investigate Expr.args access in Wasm
# The toplevel Expr has args in native Julia but length(args) < 2 in Wasm.

using WasmTarget, JuliaSyntax

# Simplest test: what is length(result.args)?
function parse_1plus1_nargs_toplevel()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr)
        return Int32(-1)
    end
    return Int32(length(result.args))
end

# Does result.head work?
function parse_1plus1_head()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr)
        return Int32(-1)
    end
    return result.head === :toplevel ? Int32(1) : Int32(0)
end

# With :statement rule instead of default
function parse_1plus1_stmt_nargs()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr)
        return Int32(-1)
    end
    return Int32(length(result.args))
end

function parse_1plus1_stmt_is_call()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr)
        return Int32(-1)
    end
    return result.head === :call ? Int32(1) : Int32(0)
end

# What if we access args[1]? Is it always the issue?
function parse_1plus1_has_any_args()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr)
        return Int32(-1)
    end
    args = result.args
    return length(args) > 0 ? Int32(1) : Int32(0)
end

tests = [
    ("parse_1plus1_head", parse_1plus1_head),
    ("parse_1plus1_nargs_toplevel", parse_1plus1_nargs_toplevel),
    ("parse_1plus1_has_any_args", parse_1plus1_has_any_args),
    ("parse_1plus1_stmt_nargs", parse_1plus1_stmt_nargs),
    ("parse_1plus1_stmt_is_call", parse_1plus1_stmt_is_call),
]

println("--- Native Ground Truth ---")
native_vals = Dict{String, Int32}()
for (name, func) in tests
    n = func()
    println("  $name: $n")
    native_vals[name] = n
end

println("\n--- Compile & Test ---")
for (name, func) in tests
    native = native_vals[name]
    print("$name (native=$native): ")

    bytes = compile_multi([(func, ())])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    run(`wasm-tools validate --features=gc $tmpf`)

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
        val = try Base.parse(Int32, output[4:end]) catch; output[4:end] end
        if val == native
            println("CORRECT ($val)")
        else
            println("WRONG (got=$val, expected=$native)")
        end
    else
        println(output)
    end
    rm(tmpf, force=true)
    rm(jsf, force=true)
end

println("\nDone.")
