# ============================================================================
# eval_julia.jl — Real eval_julia pipeline
#
# This file implements the eval_julia pipeline:
#   1. Parse: JuliaSyntax.parsestmt(Expr, code) → Expr
#   2. Extract: function + arg types from parsed Expr
#   3. TypeInf: WasmInterpreter + Core.Compiler.typeinf → canonical CodeInfo
#   4. Codegen: compile_from_codeinfo(ci, rettype, name, arg_types) → .wasm bytes
#
# Stage 3 uses WasmInterpreter (custom AbstractInterpreter with DictMethodTable,
# PreDecompressedCodeInfo, pure Julia reimplementations). may_optimize=true ensures
# IR canonicalization runs, producing the same resolved-reference CodeInfo format
# that Base.code_typed returns.
#
# NO pre-computed WASM bytes. NO character matching. NO shortcuts.
# Every call runs the REAL Julia compiler pipeline from scratch.
# ============================================================================

"""
    eval_julia_to_bytes(code::String)::Vector{UInt8}

The REAL eval_julia pipeline. Chains all 4 stages using Julia's compiler.
Returns .wasm bytes that can be instantiated via WebAssembly.instantiate() in JS.

Pipeline:
    1. Parse: JuliaSyntax.parsestmt(Expr, code) → Expr(:call, :+, 1, 1)
    2. Extract: function symbol + arg types from the Expr
    3. TypeInf: WasmInterpreter typeinf → typed, canonical CodeInfo
    4. Codegen: compile_from_codeinfo(ci, rettype, name, arg_types) → .wasm bytes

Currently handles: binary arithmetic on Int64 literals (e.g. "1+1", "10-3", "2*3")
"""
function eval_julia_to_bytes(code::String)::Vector{UInt8}
    # Stage 1: Parse
    expr = JuliaSyntax.parsestmt(Expr, code)

    # Stage 2: Extract function and arguments from the Expr
    if !(expr isa Expr && expr.head === :call)
        error("eval_julia only supports call expressions, got: $(repr(expr))")
    end

    func_sym = expr.args[1]  # e.g. :+
    arg_literals = expr.args[2:end]  # e.g. [1, 1]

    # Resolve the function symbol to an actual function
    func = getfield(Base, func_sym)

    # Determine argument types from literals
    arg_types = tuple((typeof(a) for a in arg_literals)...)

    # Stage 3: Type inference using WasmInterpreter
    world = Base.get_world_counter()
    sig = Tuple{typeof(func), arg_types...}

    # Build WasmInterpreter with transitive method table
    interp = build_wasm_interpreter([sig]; world=world)

    # Find the MethodInstance for this signature
    native_mt = Core.Compiler.InternalMethodTable(world)
    lookup = Core.Compiler.findall(sig, native_mt; limit=3)
    if lookup === nothing
        error("No method found for $func_sym with types $arg_types")
    end
    mi = Core.Compiler.specialize_method(first(lookup.matches))

    # Retrieve untyped CodeInfo and run typeinf with WasmInterpreter
    src = Core.Compiler.retrieve_code_info(mi, world)
    if src === nothing
        error("retrieve_code_info returned nothing for $func_sym")
    end
    result = Core.Compiler.InferenceResult(mi)
    frame = Core.Compiler.InferenceState(result, src, :no, interp)

    _WASM_USE_REIMPL[] = true
    _WASM_CODE_CACHE[] = interp.code_info_cache
    try
        Core.Compiler.typeinf(interp, frame)
    finally
        _WASM_USE_REIMPL[] = false
        _WASM_CODE_CACHE[] = nothing
    end

    # Extract canonical CodeInfo and return type (may_optimize=true → resolved IR)
    code_info = result.src
    if !(code_info isa Core.CodeInfo)
        error("Expected CodeInfo from WasmInterpreter typeinf, got $(typeof(code_info))")
    end
    return_type = Core.Compiler.widenconst(result.result)

    # Stage 4: Codegen — return .wasm bytes
    func_name = string(func_sym)
    return WasmTarget.compile_from_codeinfo(code_info, return_type, func_name, arg_types)
end

"""
    eval_julia_native(code::String)::Int64

Native test harness: chains all 5 stages including Node.js execution.
This function cannot be compiled to WASM (uses subprocess execution).
Used for ground truth testing — the WASM version must produce identical results.
"""
function eval_julia_native(code::String)::Int64
    wasm_bytes = eval_julia_to_bytes(code)

    # Stage 5: Execute via Node.js
    tmpwasm = tempname() * ".wasm"
    write(tmpwasm, wasm_bytes)

    # Extract function name from the code
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
