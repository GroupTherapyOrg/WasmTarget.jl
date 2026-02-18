module WasmTarget

# Builder - Low-level Wasm binary emitter
include("builder/types.jl")
include("builder/writer.jl")
include("builder/instructions.jl")
include("builder/validator.jl")

# Compiler - Julia IR to Wasm translation
include("compiler/ir.jl")
include("compiler/codegen.jl")

# Runtime - Intrinsics and stdlib mapping
include("runtime/intrinsics.jl")
include("runtime/stringops.jl")
include("runtime/arrayops.jl")
include("runtime/simpledict.jl")
include("runtime/bytebuffer.jl")
include("runtime/tokenizer.jl")

# Main API
export compile, compile_multi, compile_from_codeinfo, optimize, WasmModule, to_bytes
export WasmGlobal, global_index, global_eltype
# Therapy.jl integration - direct IR compilation for reactive handlers
export compile_handler, compile_closure_body, DOMBindingSpec, TypeRegistry
export add_import!, add_global!, add_global_export!, add_function!, add_export!
export I32, I64, F32, F64, NumType, Opcode, ExternRef

"""
    compile(f, arg_types; optimize=false) -> Vector{UInt8}

Compile a Julia function `f` with the given argument types to WebAssembly bytes.
Returns a valid WebAssembly binary that can be instantiated and executed.

Set `optimize=true` for size-optimized output (default `-Os` like dart2wasm),
`optimize=:speed` for `-O3`, or `optimize=:debug` for `-O1` without `--traps-never-happen`.
"""
function compile(f, arg_types::Tuple; optimize=false)::Vector{UInt8}
    # Get function name for export
    func_name = string(nameof(f))

    # Compile to WasmModule
    mod = compile_function(f, arg_types, func_name)

    # Serialize to bytes
    bytes = to_bytes(mod)
    optimize === false && return bytes
    level = optimize === true ? :size : optimize
    return WasmTarget.optimize(bytes; level=level)
end

# Convenience method for single argument type
compile(f, arg_type::Type; optimize=false) = compile(f, (arg_type,); optimize=optimize)

"""
    compile_multi(functions; optimize=false) -> Vector{UInt8}

Compile multiple Julia functions into a single WebAssembly module.

Each element should be (function, arg_types) or (function, arg_types, name).

Set `optimize=true` for size-optimized output, `optimize=:speed` for `-O3`,
or `optimize=:debug` for `-O1` without `--traps-never-happen`.

# Example
```julia
wasm_bytes = compile_multi([
    (add, (Int32, Int32)),
    (sub, (Int32, Int32)),
    (helper, (Int32,), "internal_helper"),
])
```

Functions can call each other within the module.
"""
function compile_multi(functions::Vector; optimize=false)::Vector{UInt8}
    mod = compile_module(functions)
    bytes = to_bytes(mod)
    optimize === false && return bytes
    level = optimize === true ? :size : optimize
    return WasmTarget.optimize(bytes; level=level)
end

"""
    compile_from_codeinfo(code_info, return_type, func_name, arg_types; optimize=false) -> Vector{UInt8}

Compile a pre-computed typed CodeInfo to WebAssembly bytes, bypassing Base.code_typed().
This is the entry point for the eval_julia pipeline where type inference has already been run.

# Arguments
- `code_info::Core.CodeInfo`: Typed CodeInfo (from Base.code_typed or equivalent)
- `return_type::Type`: The inferred return type
- `func_name::String`: Export name for the WASM function
- `arg_types::Tuple`: Argument types for the function
- `optimize`: Same as compile() — false, true, :speed, or :debug
"""
function compile_from_codeinfo(code_info::Core.CodeInfo, return_type::Type,
                                func_name::String, arg_types::Tuple;
                                optimize=false)::Vector{UInt8}
    mod = compile_module_from_ir([(code_info, return_type, arg_types, func_name)])
    bytes = to_bytes(mod)
    optimize === false && return bytes
    level = optimize === true ? :size : optimize
    return WasmTarget.optimize(bytes; level=level)
end

# ============================================================================
# Binaryen wasm-opt Post-Processing
# ============================================================================

# dart2wasm's production flags for WasmGC optimization
const WASM_OPT_GC_FLAGS = [
    "--enable-gc", "--enable-reference-types", "--enable-multivalue",
    "--enable-bulk-memory", "--enable-sign-ext", "--enable-exception-handling",
]

const WASM_OPT_PRODUCTION_FLAGS = [
    "--closed-world", "--traps-never-happen",
    "--type-unfinalizing", "-Os", "--type-ssa", "--gufa", "-Os",
    "--type-merging", "-Os", "--type-finalizing", "--minimize-rec-groups",
]

"""
    optimize(bytes::Vector{UInt8}; level=:size, validate=true) -> Vector{UInt8}

Run Binaryen `wasm-opt` on compiled WebAssembly bytes for size and performance optimization.
Uses dart2wasm's production WasmGC flags by default.

# Keywords
- `level`: Optimization level — `:size` (default, `-Os` like dart2wasm), `:speed` (`-O3`), or `:debug` (`-O1`, no `--traps-never-happen`)
- `validate`: Run `wasm-tools validate` after optimization (default `true`)

# Returns
Optimized `Vector{UInt8}`.

# Throws
- Error if `wasm-opt` is not found (with install instructions)
- Error if optimization or validation fails
"""
function optimize(bytes::Vector{UInt8}; level::Symbol=:size, validate::Bool=true)::Vector{UInt8}
    # Check wasm-opt availability
    wasm_opt = Sys.which("wasm-opt")
    if wasm_opt === nothing
        error("wasm-opt not found. Install Binaryen: brew install binaryen (macOS) or apt install binaryen (Linux)")
    end

    # Build flags based on level
    flags = copy(WASM_OPT_GC_FLAGS)
    if level === :size
        append!(flags, WASM_OPT_PRODUCTION_FLAGS)
    elseif level === :speed
        append!(flags, ["--closed-world", "--traps-never-happen",
                        "--type-unfinalizing", "-O3", "--type-ssa", "--gufa", "-O3",
                        "--type-merging", "-O3", "--type-finalizing", "--minimize-rec-groups"])
    elseif level === :debug
        append!(flags, ["--closed-world",
                        "--type-unfinalizing", "-O1", "--type-ssa", "--gufa", "-O1",
                        "--type-merging", "-O1", "--type-finalizing"])
    else
        error("Unknown optimization level: $level. Use :size, :speed, or :debug")
    end

    # Write input, run wasm-opt, read output
    mktempdir() do dir
        input_path = joinpath(dir, "input.wasm")
        output_path = joinpath(dir, "output.wasm")
        write(input_path, bytes)

        cmd = `$(wasm_opt) $(flags) $(input_path) -o $(output_path)`
        try
            Base.run(cmd)
        catch e
            error("wasm-opt failed: $(e)")
        end

        opt_bytes = read(output_path)

        # Validate optimized output
        if validate
            wasm_tools = Sys.which("wasm-tools")
            if wasm_tools !== nothing
                try
                    Base.run(pipeline(`$(wasm_tools) validate --features=gc $(output_path)`, stderr=devnull))
                catch
                    @warn "wasm-tools validate failed on optimized output"
                end
            end
        end

        return opt_bytes
    end
end

end # module
