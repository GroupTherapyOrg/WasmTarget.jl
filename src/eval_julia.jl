"""
    eval_julia_to_bytes(code::String)::Vector{UInt8}

WASM-targetable version: chains stages 1-4 and returns .wasm bytes.
Stage 5 (execution) happens on the JS side via WebAssembly.instantiate().

Pipeline:
  1. Parse: JuliaSyntax.parsestmt(Expr, code) → Expr
  2. Extract: function + arg types from parsed Expr
  3. TypeInf: Base.code_typed(func, arg_types) → typed CodeInfo
  4. Codegen: compile_from_codeinfo(ci, rettype, name, arg_types) → .wasm bytes

Currently handles: binary arithmetic on Int64 literals (e.g. "1+1", "10-3", "2*3")

NOTE: Stage 3 calls Base.code_typed which is a C function — it gets stubbed when
compiled to WASM. For true self-hosting, this needs to be replaced with the
WasmInterpreter + DictMethodTable reimplementation.
"""
function eval_julia_to_bytes(code::String)::Vector{UInt8}
    # Stage 1: Parse
    expr = JuliaSyntax.parsestmt(Expr, code)

    # Stage 2: Extract function and arguments from the Expr
    if !(expr isa Expr && expr.head === :call)
        error("eval_julia_native only supports call expressions, got: $(repr(expr))")
    end

    func_sym = expr.args[1]  # e.g. :+
    arg_literals = expr.args[2:end]  # e.g. [1, 1]

    # Resolve the function symbol to an actual function
    func = getfield(Base, func_sym)

    # Determine argument types from literals (as a tuple of types)
    arg_types = tuple((typeof(a) for a in arg_literals)...)

    # Stage 3: Type inference (lowering + typeinf combined)
    results = Base.code_typed(func, arg_types)
    if isempty(results)
        error("No method found for $func_sym with types $arg_types")
    end
    code_info, return_type = results[1]

    # Stage 4: Codegen — return .wasm bytes
    func_name = string(func_sym)
    return WasmTarget.compile_from_codeinfo(code_info, return_type, func_name, arg_types)
end

"""
    eval_julia_native(code::String)::Int64

Native version: chains all 5 stages including Node.js execution.
This function cannot be compiled to WASM (uses subprocess execution).
Use eval_julia_to_bytes for WASM compilation.
"""
function eval_julia_native(code::String)::Int64
    wasm_bytes = eval_julia_to_bytes(code)

    # Stage 5: Execute via Node.js
    tmpwasm = tempname() * ".wasm"
    write(tmpwasm, wasm_bytes)

    # Extract function name from the code (same logic as eval_julia_to_bytes)
    expr = JuliaSyntax.parsestmt(Expr, code)
    func_name = string(expr.args[1])
    arg_literals = expr.args[2:end]

    js_args = join(["$(a)n" for a in arg_literals], ", ")  # BigInt for i64
    tmpjs = tempname() * ".mjs"
    write(tmpjs, """
import { readFile } from 'fs/promises';
const bytes = await readFile('$tmpwasm');
const { instance } = await WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } });
const result = instance.exports['$func_name']($js_args);
process.stdout.write(String(result));
""")

    output = read(`node $tmpjs`, String)
    rm(tmpwasm; force=true)
    rm(tmpjs; force=true)

    return Base.parse(Int64, output)
end
