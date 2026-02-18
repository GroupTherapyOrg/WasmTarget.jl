#!/usr/bin/env julia
# PURE-5002: Further isolation — what exactly triggers the trap beyond floats?

using WasmTarget, JuliaSyntax

function parse_x_eq_1()::Int32
    ps = JuliaSyntax.ParseStream("x = 1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_chain_add()::Int32
    ps = JuliaSyntax.ParseStream("1 + 2 + 3")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_fx_eq_xplus1()::Int32
    ps = JuliaSyntax.ParseStream("f(x) = x + 1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_nested_call()::Int32
    ps = JuliaSyntax.ParseStream("f(g(1))")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

function parse_tuple()::Int32
    ps = JuliaSyntax.ParseStream("(1, 2, 3)")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    return result === nothing ? Int32(0) : Int32(1)
end

# Also test: can we EXTRACT the inner Expr from toplevel?
# build_tree wraps in :toplevel, we need to get the actual expression
function parse_1plus1_inner_head()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr)
        return Int32(-1)
    end
    # result is :toplevel with args [LineNumberNode, inner_expr]
    if length(result.args) < 2
        return Int32(-2)
    end
    inner = result.args[2]
    if !(inner isa Expr)
        return Int32(-3)
    end
    # inner should be Expr(:call, :+, 1, 1)
    return inner.head === :call ? Int32(1) : Int32(0)
end

function parse_1plus1_inner_nargs()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr) || length(result.args) < 2
        return Int32(-1)
    end
    inner = result.args[2]
    if !(inner isa Expr)
        return Int32(-2)
    end
    return Int32(length(inner.args))  # should be 3: :+, 1, 1
end

tests = [
    ("parse_x_eq_1", parse_x_eq_1),
    ("parse_chain_add", parse_chain_add),
    ("parse_fx_eq_xplus1", parse_fx_eq_xplus1),
    ("parse_nested_call", parse_nested_call),
    ("parse_tuple", parse_tuple),
    ("parse_1plus1_inner_head", parse_1plus1_inner_head),
    ("parse_1plus1_inner_nargs", parse_1plus1_inner_nargs),
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
            println("WRONG (got=$val)")
        end
    else
        println(output)
    end
    rm(tmpf, force=true)
    rm(jsf, force=true)
end

println("\nDone.")
