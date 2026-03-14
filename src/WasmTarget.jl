module WasmTarget

# Builder - Low-level Wasm binary emitter
include("builder/types.jl")
include("builder/writer.jl")
include("builder/instructions.jl")
include("builder/validator.jl")

# Compiler - Julia IR to Wasm translation
include("compiler/ir.jl")

# Codegen - Julia IR to Wasm bytecode (split from compiler/codegen.jl)
include("codegen/types.jl")
include("codegen/dispatch.jl")
include("codegen/compile.jl")
include("codegen/structs.jl")
include("codegen/unions.jl")
include("codegen/int128.jl")
include("codegen/context.jl")
include("codegen/generate.jl")
include("codegen/flow.jl")
include("codegen/stackified.jl")
include("codegen/conditionals.jl")
include("codegen/statements.jl")
include("codegen/values.jl")
include("codegen/calls.jl")
include("codegen/invoke.jl")
include("codegen/helpers.jl")
include("codegen/strings.jl")
include("codegen/dicts.jl")
include("codegen/sourcemap.jl")
include("codegen/cache.jl")

# Runtime - Intrinsics and stdlib mapping
include("runtime/intrinsics.jl")
include("runtime/stringops.jl")
include("runtime/arrayops.jl")
include("runtime/simpledict.jl")
include("runtime/bytebuffer.jl")
include("runtime/tokenizer.jl")

# Main API
export compile, compile_multi, compile_from_codeinfo, compile_with_base, optimize, WasmModule, to_bytes
export compile_with_sourcemap, compile_multi_with_sourcemap
export compile_cached, compile_multi_cached, enable_cache!, disable_cache!, clear_cache!, cache_stats
export WasmGlobal, global_index, global_eltype
# Therapy.jl integration - direct IR compilation for reactive handlers
export compile_handler, compile_closure_body, DOMBindingSpec, TypeRegistry, FunctionRegistry
export serialize_type_registry, serialize_function_table, serialize_type_ids, serialize_dispatch_tables
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
function compile_multi(functions::Vector; optimize=false, stub_names::Set{String}=Set{String}(),
                       return_registries::Bool=false)
    result = compile_module(functions; stub_names=stub_names, return_registries=return_registries)
    if return_registries
        mod, type_registry, func_registry, dispatch_registry = result
        bytes = to_bytes(mod)
        if optimize !== false
            level = optimize === true ? :size : optimize
            bytes = WasmTarget.optimize(bytes; level=level)
        end
        return (bytes, type_registry, func_registry, dispatch_registry)
    else
        mod = result
        bytes = to_bytes(mod)
        optimize === false && return bytes
        level = optimize === true ? :size : optimize
        return WasmTarget.optimize(bytes; level=level)
    end
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
# PURE-9047: Compile with base.wasm merge
# ============================================================================

const WASM_MERGE_GC_FLAGS = [
    "--enable-gc", "--enable-reference-types", "--enable-multivalue",
    "--enable-bulk-memory", "--enable-sign-ext", "--enable-exception-handling",
]

"""
    compile_with_base(functions; base_wasm_path, optimize=false) -> Vector{UInt8}

Compile user functions and merge with a pre-compiled base.wasm module.
User functions that would normally be compiled standalone are instead compiled
into a separate user.wasm module, then merged with base.wasm via wasm-merge.

The merged module contains all base exports + user exports, and user code
can call base functions directly.

# Arguments
- `functions`: Same format as `compile_multi` — `[(f, arg_types, name), ...]`
- `base_wasm_path`: Path to pre-compiled base.wasm (default: base.wasm in project root)
- `optimize`: Same as compile() — false, true, :speed, or :debug

# Returns
Merged `Vector{UInt8}` containing both base and user functions.
"""
function compile_with_base(functions::Vector;
                           base_wasm_path::String=joinpath(@__DIR__, "..", "base.wasm"),
                           optimize=false)::Vector{UInt8}
    # Check tools
    wasm_merge = Sys.which("wasm-merge")
    if wasm_merge === nothing
        error("wasm-merge not found. Install Binaryen: brew install binaryen (macOS) or apt install binaryen (Linux)")
    end

    if !isfile(base_wasm_path)
        error("base.wasm not found at $base_wasm_path. Run: julia --project=. scripts/build_base.jl")
    end

    # Compile user functions
    user_bytes = compile_multi(functions)

    # Merge with base.wasm
    mktempdir() do dir
        user_path = joinpath(dir, "user.wasm")
        merged_path = joinpath(dir, "merged.wasm")
        write(user_path, user_bytes)

        cmd = `$(wasm_merge) $(WASM_MERGE_GC_FLAGS) $(base_wasm_path) base $(user_path) user -o $(merged_path)`
        try
            Base.run(cmd)
        catch e
            error("wasm-merge failed: $(e)")
        end

        merged_bytes = read(merged_path)

        if optimize !== false
            level = optimize === true ? :size : optimize
            return WasmTarget.optimize(merged_bytes; level=level)
        end
        return merged_bytes
    end
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
