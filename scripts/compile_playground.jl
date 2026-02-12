#!/usr/bin/env julia
# compile_playground.jl — Generates parser.wasm and evaluator.wasm for the browser playground
#
# parser.wasm: JuliaSyntax.parsestmt compiled to WasmGC (proves the parser works in Wasm)
# evaluator.wasm: ExprNode tree-walker with JS-callable helpers (executes parsed ASTs)

using WasmTarget
using JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "Runtime", "ExprEval.jl"))

const OUTPUT_DIR = joinpath(@__DIR__, "..", "docs", "dist", "wasm")
mkpath(OUTPUT_DIR)

# === Parser Module ===
# Compiles JuliaSyntax.parsestmt to WasmGC
println("=== Compiling parser.wasm ===")
parser_bytes = compile(s -> JuliaSyntax.parsestmt(JuliaSyntax.ParseStream(s)), (String,))
open(joinpath(OUTPUT_DIR, "parser.wasm"), "w") do io
    write(io, parser_bytes)
end
println("  parser.wasm: $(length(parser_bytes)) bytes")

# === Evaluator Module ===
# ExprNode tree-walker with helper functions callable from JavaScript.
# JS builds the ExprNode array using nodes_new/nodes_set!, then calls eval_node.
println("=== Compiling evaluator.wasm ===")

# Helper: create a nodes array of given capacity
function nodes_new(capacity::Int32)::Vector{ExprNode}
    return Vector{ExprNode}(undef, Int(capacity))
end

# Helper: set a node in the array (all primitive args, JS-callable)
function nodes_set!(nodes::Vector{ExprNode}, idx::Int32, tag::Int32, value::Int64, c1::Int32, c2::Int32, c3::Int32)::Int32
    nodes[idx] = ExprNode(tag, value, c1, c2, c3)
    return Int32(0)
end

# Helper: create an environment with given number of slots
function env_new(num_slots::Int32)::EvalEnv
    return EvalEnv(zeros(Int64, Int(num_slots)))
end

eval_bytes = compile_multi([
    (nodes_new, (Int32,)),
    (nodes_set!, (Vector{ExprNode}, Int32, Int32, Int64, Int32, Int32, Int32)),
    (env_new, (Int32,)),
    (eval_node, (Vector{ExprNode}, Int32, EvalEnv)),
])
open(joinpath(OUTPUT_DIR, "evaluator.wasm"), "w") do io
    write(io, eval_bytes)
end
println("  evaluator.wasm: $(length(eval_bytes)) bytes")

# === Validate ===
println("\n=== Validating ===")
for f in ["parser.wasm", "evaluator.wasm"]
    path = joinpath(OUTPUT_DIR, f)
    result = try
        run(pipeline(`wasm-tools validate $path`, stderr=devnull))
        "VALID"
    catch
        "INVALID"
    end
    println("  $f: $result")
end

# === Binaryen Optimization (if wasm-opt is available) ===
println("\n=== Binaryen Optimization ===")
if Sys.which("wasm-opt") !== nothing
    for (name, raw_bytes) in [("parser.wasm", parser_bytes), ("evaluator.wasm", eval_bytes)]
        try
            opt_bytes = WasmTarget.optimize(raw_bytes)
            opt_path = joinpath(OUTPUT_DIR, replace(name, ".wasm" => ".opt.wasm"))
            write(opt_path, opt_bytes)
            saved_pct = round((1 - length(opt_bytes) / length(raw_bytes)) * 100, digits=1)
            println("  $name: $(length(raw_bytes)) → $(length(opt_bytes)) bytes (-$(saved_pct)%)")
        catch e
            println("  $name: optimization failed ($(e))")
        end
    end
else
    println("  wasm-opt not found — install with: brew install binaryen")
end

println("\nDone! Files written to $OUTPUT_DIR")
