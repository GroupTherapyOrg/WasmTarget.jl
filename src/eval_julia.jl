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
# PreDecompressedCodeInfo, pure Julia reimplementations). may_optimize=false skips
# Julia's IR optimization passes (unnecessary for WASM — Binaryen handles it).
# The unoptimized CodeInfo may differ from Base.code_typed format.
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
# --- WASM byte vector helpers ---
# These are compiled to WASM and exported so JS can create Vector{UInt8}
# in the module's own type space (cross-module WasmGC types are incompatible).
function make_byte_vec(n::Int32)::Vector{UInt8}
    return Vector{UInt8}(undef, Int(n))
end

function set_byte_vec!(v::Vector{UInt8}, idx::Int32, val::Int32)::Int32
    v[Int(idx)] = UInt8(val)
    return Int32(0)
end

# --- PURE-6024: Diagnostic functions to test individual pipeline stages ---
function eval_julia_test_ps_create(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    return Int32(1)
end

function eval_julia_test_parse_only(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps, rule=:statement)
    return Int32(1)
end

function eval_julia_test_build_tree(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps, rule=:statement)
    try
        expr = JuliaSyntax.build_tree(Expr, ps)
        return Int32(42)
    catch
        return Int32(-42)
    end
end

function eval_julia_test_parse(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps, rule=:statement)
    expr = JuliaSyntax.build_tree(Expr, ps)
    if expr isa Expr && expr.head === :call
        return Int32(length(expr.args))
    end
    return Int32(-1)
end

# --- Entry point that takes Vector{UInt8} directly (WASM-compatible) ---
# Avoids ALL String operations (codeunit, ncodeunits, pointer, unsafe_load)
# which compile to `unreachable` in WASM.
function eval_julia_to_bytes_vec(code_bytes::Vector{UInt8})::Vector{UInt8}
    # Stage 1: Parse — bytes go directly to ParseStream
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps, rule=:statement)
    expr = JuliaSyntax.build_tree(Expr, ps)

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

    # Run typeinf_frame(interp, mi, run_optimizer=false) — skip Julia IR optimization.
    # Binaryen handles WASM-level optimization. Without the optimizer, the IR may
    # have extra statements (e.g. 3-stmt indirect calls vs 2-stmt resolved intrinsics).
    # Codegen must handle this unoptimized form.
    _WASM_USE_REIMPL[] = true
    _WASM_CODE_CACHE[] = interp.code_info_cache
    inf_frame = nothing
    try
        inf_frame = Core.Compiler.typeinf_frame(interp, mi, false)
    finally
        _WASM_USE_REIMPL[] = false
        _WASM_CODE_CACHE[] = nothing
    end
    if inf_frame === nothing
        error("typeinf_frame returned nothing for $func_sym")
    end

    # Extract canonical CodeInfo and return type
    code_info = inf_frame.result.src
    if !(code_info isa Core.CodeInfo)
        error("Expected CodeInfo from WasmInterpreter typeinf, got $(typeof(code_info))")
    end
    return_type = Core.Compiler.widenconst(inf_frame.result.result)

    # Stage 4: Codegen — return .wasm bytes
    func_name = string(func_sym)
    return WasmTarget.compile_from_codeinfo(code_info, return_type, func_name, arg_types)
end

# --- Native-only String entry point (NOT compiled to WASM) ---
# Uses codeunits/pointer operations that only work natively.
function eval_julia_to_bytes(code::String)::Vector{UInt8}
    return eval_julia_to_bytes_vec(Vector{UInt8}(codeunits(code)))
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
