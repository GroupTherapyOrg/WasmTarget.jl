"""
    eval_julia_native(code::String)::Int64

Chain all stages of the Julia compilation pipeline natively for simple
arithmetic expressions, returning the integer result.

Pipeline:
  1. Parse: JuliaSyntax.parsestmt(Expr, code) → Expr
  2. Extract: function + arg types from parsed Expr
  3. TypeInf: Base.code_typed(func, arg_types) → typed CodeInfo
  4. Codegen: compile_from_codeinfo(ci, rettype, name, arg_types) → .wasm bytes
  5. Execute: run the .wasm in Node.js → result

Currently handles: binary arithmetic on Int64 literals (e.g. "1+1", "10-3", "2*3")
"""
function eval_julia_native(code::String)::Int64
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

    # Stage 4: Codegen
    func_name = string(func_sym)
    wasm_bytes = WasmTarget.compile_from_codeinfo(code_info, return_type, func_name, arg_types)

    # Stage 5: Execute via Node.js
    tmpwasm = tempname() * ".wasm"
    write(tmpwasm, wasm_bytes)

    # Generate JS that loads the wasm, calls the function with the literal args, and prints result
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
