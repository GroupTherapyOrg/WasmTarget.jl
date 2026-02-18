#!/usr/bin/env julia
# PURE-5002: Verify the AST is USABLE — can we extract meaningful data?
# Using :statement rule to get the inner Expr directly (no toplevel wrapper).

using WasmTarget, JuliaSyntax

# ═══════════════════════════════════════════════════════════════
# Test: "1+1" → Expr(:call, :+, 1, 1)
# Can we verify: head=:call, nargs=3, args[1]=:+, args[2]=1, args[3]=1
# ═══════════════════════════════════════════════════════════════

# Test: head is :call
function test_1plus1_head_is_call()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr)
        return Int32(0)
    end
    return result.head === :call ? Int32(1) : Int32(0)
end

# Test: nargs is 3
function test_1plus1_nargs()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr)
        return Int32(-1)
    end
    return Int32(length(result.args))
end

# Test: args[1] is :+ (a Symbol)
function test_1plus1_op_is_plus()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr) || length(result.args) < 1
        return Int32(0)
    end
    op = result.args[1]
    return op === :+ ? Int32(1) : Int32(0)
end

# Test: args[2] is Int64 with value 1
function test_1plus1_arg2_is_int()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr) || length(result.args) < 2
        return Int32(0)
    end
    arg2 = result.args[2]
    return arg2 isa Int64 ? Int32(1) : Int32(0)
end

# Test: args[2] == 1
function test_1plus1_arg2_value()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr) || length(result.args) < 2
        return Int32(-1)
    end
    arg2 = result.args[2]
    if !(arg2 isa Int64)
        return Int32(-2)
    end
    return arg2 == 1 ? Int32(1) : Int32(0)
end

# Test: args[3] == 1
function test_1plus1_arg3_value()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr) || length(result.args) < 3
        return Int32(-1)
    end
    arg3 = result.args[3]
    if !(arg3 isa Int64)
        return Int32(-2)
    end
    return arg3 == 1 ? Int32(1) : Int32(0)
end

# ═══════════════════════════════════════════════════════════════
# Test: "2*3" → Expr(:call, :*, 2, 3) — different op, different values
# ═══════════════════════════════════════════════════════════════

function test_2mul3_head_is_call()::Int32
    ps = JuliaSyntax.ParseStream("2*3")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr)
        return Int32(0)
    end
    return result.head === :call ? Int32(1) : Int32(0)
end

function test_2mul3_op_is_star()::Int32
    ps = JuliaSyntax.ParseStream("2*3")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr) || length(result.args) < 1
        return Int32(0)
    end
    return result.args[1] === :* ? Int32(1) : Int32(0)
end

function test_2mul3_arg2_is_2()::Int32
    ps = JuliaSyntax.ParseStream("2*3")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr) || length(result.args) < 2
        return Int32(-1)
    end
    arg = result.args[2]
    return (arg isa Int64 && arg == 2) ? Int32(1) : Int32(0)
end

function test_2mul3_arg3_is_3()::Int32
    ps = JuliaSyntax.ParseStream("2*3")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr) || length(result.args) < 3
        return Int32(-1)
    end
    arg = result.args[3]
    return (arg isa Int64 && arg == 3) ? Int32(1) : Int32(0)
end

# ═══════════════════════════════════════════════════════════════
# Test: "f(1)" → Expr(:call, :f, 1) — function call
# ═══════════════════════════════════════════════════════════════

function test_f1_head_is_call()::Int32
    ps = JuliaSyntax.ParseStream("f(1)")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr)
        return Int32(0)
    end
    return result.head === :call ? Int32(1) : Int32(0)
end

function test_f1_nargs()::Int32
    ps = JuliaSyntax.ParseStream("f(1)")
    JuliaSyntax.parse!(ps; rule=:statement)
    result = JuliaSyntax.build_tree(Expr, ps)
    if !(result isa Expr)
        return Int32(-1)
    end
    return Int32(length(result.args))
end

tests = [
    # 1+1 tests
    ("test_1plus1_head_is_call", test_1plus1_head_is_call),
    ("test_1plus1_nargs", test_1plus1_nargs),
    ("test_1plus1_op_is_plus", test_1plus1_op_is_plus),
    ("test_1plus1_arg2_is_int", test_1plus1_arg2_is_int),
    ("test_1plus1_arg2_value", test_1plus1_arg2_value),
    ("test_1plus1_arg3_value", test_1plus1_arg3_value),
    # 2*3 tests
    ("test_2mul3_head_is_call", test_2mul3_head_is_call),
    ("test_2mul3_op_is_star", test_2mul3_op_is_star),
    ("test_2mul3_arg2_is_2", test_2mul3_arg2_is_2),
    ("test_2mul3_arg3_is_3", test_2mul3_arg3_is_3),
    # f(1) tests
    ("test_f1_head_is_call", test_f1_head_is_call),
    ("test_f1_nargs", test_f1_nargs),
]

println("--- Native Ground Truth ---")
native_vals = Dict{String, Int32}()
for (name, func) in tests
    n = func()
    println("  $name: $n")
    native_vals[name] = n
end

println("\n--- Compile & Test ---")
correct = 0
total = length(tests)
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
            correct += 1
        else
            println("WRONG (got=$val)")
        end
    else
        println(output)
    end
    rm(tmpf, force=true)
    rm(jsf, force=true)
end

println("\n$correct/$total CORRECT")
