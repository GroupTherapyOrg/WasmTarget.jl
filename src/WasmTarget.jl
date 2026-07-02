module WasmTarget

using PrecompileTools: @setup_workload, @compile_workload

# Builder - Low-level Wasm binary emitter
include("builder/types.jl")
include("builder/writer.jl")
include("builder/instructions.jl")
include("builder/validator.jl")
include("builder/instr_ir.jl")
include("builder/instr_builder.jl")

# Codegen - Julia IR to Wasm bytecode
include("codegen/diagnostics.jl")  # strict-mode diagnostics; must precede context.jl (struct field)
include("codegen/interpreter.jl")
include("codegen/trimcollect.jl")
include("codegen/ir.jl")
include("codegen/int_key_map.jl")
include("codegen/types.jl")
include("codegen/dispatch.jl")
include("codegen/compile.jl")
include("codegen/structs.jl")
include("codegen/unions.jl")
include("codegen/int128.jl")
include("codegen/box_capture.jl")  # F3 mutable-capture (dev/F3_LOOP.md); L0 = inference only (dormant)
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
include("codegen/sourcemap.jl")
include("codegen/cache.jl")
include("codegen/packages.jl")

# Packages - Domain-specific extensions
include("packages/statistics.jl")

include("codegen/wasm_constructors.jl")

# Runtime - Intrinsics and stdlib mapping
include("runtime/intrinsics.jl")
include("runtime/stringops.jl")
include("runtime/arrayops.jl")
include("bridge.jl")


# Main API
export compile, compile_multi, compile_from_codeinfo, compile_with_base, optimize, WasmModule, to_bytes
export FrozenCompilationState, build_frozen_state, compile_module_from_ir_frozen, compile_module_from_ir_frozen_no_dict
export wasm_bytes_length, wasm_bytes_get, wasm_compile_source, wasm_compile_flat
export wasm_create_ssa_value, wasm_create_argument, wasm_create_goto_node
export wasm_create_goto_if_not, wasm_create_return_node, wasm_create_return_node_nothing
export wasm_create_phi_node, wasm_create_expr, wasm_set_code_info!, wasm_create_simple_codeinfo
export SimpleCodeInfo
export wasm_create_any_vector, wasm_set_any_ssa!, wasm_set_any_arg!, wasm_set_any_i64!
export wasm_set_any_expr!, wasm_set_any_return!, wasm_set_any_gotoifnot!
export wasm_set_any_goto!, wasm_set_any_phi!
export wasm_get_ssa_id, wasm_get_gotoifnot_dest, wasm_any_vector_length
export wasm_create_i32_vector, wasm_set_i32!, wasm_get_i32, wasm_i32_vector_length
export wasm_create_ssatypes_all_i64
export wasm_symbol_call, wasm_symbol_invoke, wasm_symbol_new
export wasm_symbol_boundscheck, wasm_symbol_foreigncall
export collect_globalrefs, resolve_globalrefs, substitute_globalrefs, preprocess_ir_entries
export compile_with_sourcemap, compile_multi_with_sourcemap
export compile_cached, compile_multi_cached, enable_cache!, disable_cache!, clear_cache!, cache_stats
export register_package!, list_packages, package_functions, precompile_package
export compile_with_packages, detect_using_statements, register_builtin_packages!
export WasmGlobal, global_index, global_eltype
# AbstractInterpreter with overlay method table (GPUCompiler pattern)
export WasmInterpreter, get_wasm_interpreter, WASM_METHOD_TABLE
# Therapy.jl integration - direct IR compilation for reactive handlers
export compile_handler, compile_closure_body, DOMBindingSpec, TypeRegistry, FunctionRegistry, register_function!
export serialize_type_registry, serialize_function_table, serialize_type_ids, serialize_dispatch_tables
export add_import!, add_global!, add_global_export!, add_function!, add_export!
export I32, I64, F32, F64, NumType, Opcode, ExternRef
# Soundness: strict-mode diagnostics + validation gate
export WasmDiagnostic, WasmCompileError, WasmValidationError, validate_wasm_bytes

"""
    _wt_default_validate() -> Bool

parity(M4) — the wasm-tools DEMOTION (dart parity: dart2wasm ships no external validator;
its builder IS the gate). Since 2026-07-01 every InstrBuilder hard-gates each emission
against the full subtype lattice (strict by default, mod threaded), so the module is valid
BY CONSTRUCTION and the external `wasm-tools validate` pass is a redundant double-check —
now OFF by default. Re-enable per-call (`validate=true`) or globally (`WT_VALIDATE=1`,
recommended in CI as the independent cross-check).
"""
_wt_default_validate() = get(ENV, "WT_VALIDATE", "") == "1"

"""
    compile(f, arg_types; optimize=false) -> Vector{UInt8}

Compile a Julia function `f` with the given argument types to WebAssembly bytes.
Returns a valid WebAssembly binary that can be instantiated and executed.

Set `optimize=true` for size-optimized output (default `-Os` like dart2wasm),
`optimize=:speed` for `-O3`, or `optimize=:debug` for `-O1` without `--traps-never-happen`.
"""
function compile(f, arg_types::Tuple; optimize=false, optimize_ir::Bool=true,
                 strict::Bool=true, validate::Bool=_wt_default_validate())::Vector{UInt8}
    # Get function name for export
    func_name = string(nameof(f))

    # Compile to WasmModule (strict=true raises WasmCompileError on unsupported constructs)
    mod = compile_function(f, arg_types, func_name; optimize_ir=optimize_ir, strict=strict)

    # Serialize to bytes
    bytes = to_bytes(mod)
    if optimize === false
        # Soundness gate: validate the emitted module (raises WasmValidationError on reject)
        validate && validate_wasm_bytes(bytes; label="compiled module")
        return bytes
    end
    level = optimize === true ? :size : optimize
    return WasmTarget.optimize(bytes; level=level, validate=validate)
end

# Convenience method for single argument type
compile(f, arg_type::Type; optimize=false, optimize_ir::Bool=true, strict::Bool=true, validate::Bool=_wt_default_validate()) =
    compile(f, (arg_type,); optimize=optimize, optimize_ir=optimize_ir, strict=strict, validate=validate)

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
                       return_registries::Bool=false, optimize_ir::Bool=true,
                       register_ir_types::Bool=false, strict::Bool=true, validate::Bool=_wt_default_validate(),
                       discovery::Symbol=:trim)
    result = compile_module(functions; stub_names=stub_names, return_registries=return_registries,
                           optimize_ir=optimize_ir, register_ir_types=register_ir_types, strict=strict,
                           discovery=discovery)
    if return_registries
        mod, type_registry, func_registry, dispatch_registry = result
        bytes = to_bytes(mod)
        if optimize !== false
            level = optimize === true ? :size : optimize
            bytes = WasmTarget.optimize(bytes; level=level, validate=validate)
        else
            validate && validate_wasm_bytes(bytes; label="compiled module")
        end
        return (bytes, type_registry, func_registry, dispatch_registry)
    else
        mod = result
        bytes = to_bytes(mod)
        if optimize === false
            validate && validate_wasm_bytes(bytes; label="compiled module")
            return bytes
        end
        level = optimize === true ? :size : optimize
        return WasmTarget.optimize(bytes; level=level, validate=validate)
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

# NOTE: dart2wasm also passes --traps-never-happen, but that assumption is
# UNSOUND here: WasmTarget uses wasm traps as Julia's error semantics (div by
# zero, bounds checks, throw paths), and -tnh lets binaryen delete/reorder
# those paths — optimized builds returned garbage where native throws
# (ledger gaps dacbfa51e334, 5cc6c2b2ac64, c77a8f98bb53, …). Dart never relies
# on traps; Julia-compiled code does.
const WASM_OPT_PRODUCTION_FLAGS = [
    "--closed-world",
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
function optimize(bytes::Vector{UInt8}; level::Symbol=:size, validate::Bool=_wt_default_validate())::Vector{UInt8}
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
        append!(flags, ["--closed-world",   # no --traps-never-happen: see WASM_OPT_PRODUCTION_FLAGS
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

        # Soundness gate: validate optimized output (raises WasmValidationError on reject)
        validate && validate_wasm_bytes(opt_bytes; label="optimized module")

        return opt_bytes
    end
end

# ============================================================================
# Validation gate — wasm-tools validate (default-on soundness check)
# ============================================================================

const _WARNED_NO_WASM_TOOLS = Ref(false)
function _warn_no_wasm_tools_once()
    if !_WARNED_NO_WASM_TOOLS[]
        @warn "wasm-tools not found — skipping the wasm validation gate (install: `cargo install wasm-tools`)"
        _WARNED_NO_WASM_TOOLS[] = true
    end
end

"""
Disassemble ±12 instructions around the first `(at offset 0x…)` in a validator
message. Best-effort: any failure returns "" (validation errors must never be
masked by their own diagnostics).
"""
function _disassembly_context(wasm_tools, wasm_path::AbstractString, validator_msg::AbstractString)::String
    try
        m = match(r"at offset 0x([0-9a-f]+)", validator_msg)
        m === nothing && return ""
        target = parse(UInt64, m.captures[1]; base=16)
        dis = read(pipeline(`$(wasm_tools) print --print-offsets $(wasm_path)`, stderr=devnull), String)
        lines = split(dis, '\n')
        # offsets appear as leading `(;@1fd2  ;)` comments
        best = 0
        for (i, ln) in enumerate(lines)
            om = match(r"^\(;@([0-9a-f]+)\s*;\)", ln)
            om === nothing && continue
            off = parse(UInt64, om.captures[1]; base=16)
            off <= target && (best = i)
            off > target && break
        end
        best == 0 && return ""
        lo, hi = max(1, best - 12), min(length(lines), best + 2)
        join(lines[lo:hi], "\n")
    catch
        ""
    end
end

"""
    validate_wasm_bytes(bytes; label="module") -> Vector{UInt8}

Run `wasm-tools validate --features=gc` on `bytes`. Throws [`WasmValidationError`](@ref)
if the validator rejects the module. If `wasm-tools` is not installed, this is a no-op
(with a one-time warning) so the package stays usable without the tool. Returns `bytes`
unchanged so it can be used inline.
"""
function validate_wasm_bytes(bytes::Vector{UInt8}; label::AbstractString="module")
    wasm_tools = Sys.which("wasm-tools")
    if wasm_tools === nothing
        _warn_no_wasm_tools_once()
        return bytes
    end
    mktempdir() do dir
        p = joinpath(dir, "validate.wasm")
        write(p, bytes)
        err = IOBuffer()
        ok = try
            Base.run(pipeline(`$(wasm_tools) validate --features=gc $(p)`, stdout=devnull, stderr=err))
            true
        catch
            false
        end
        if !ok
            # debug escape hatch: keep the rejected module for offline objdump
            dump_to = get(ENV, "WT_DUMP_INVALID", "")
            isempty(dump_to) || (write(dump_to, bytes); @info "invalid module dumped" dump_to)
            details = String(take!(err))
            # self-diagnosing failures: disassemble around the failing offset so the
            # error names the construct (e.g. WHICH callee a mis-arity call targets)
            ctx_dis = _disassembly_context(wasm_tools, p, details)
            isempty(ctx_dis) || (details *= "\n\nemitted code at the failing offset:\n" * ctx_dis)
            throw(WasmValidationError("wasm-tools rejected the emitted $label", details))
        end
    end
    return bytes
end

# ── Precompile workload ──────────────────────────────────────────────────────
# `compile(f, types)` JIT-compiles the WasmInterpreter + codegen for that
# signature. The test suite's wall-time is dominated by paying that JIT warmup at
# runtime (Julia's global codegen lock serializes it, so threads can't hide it).
# Exercising representative signatures HERE bakes those compiler method instances
# into the `.ji` cache — the warmup is paid once at `]precompile` and is ~free on
# every cached run. Compile-only (no Node, no binaryen). Each call is guarded so a
# value-stub on some path can never break precompilation.
struct _PCStruct; a::Int32; b::Float64; end
_pc_iadd(x::Int64)            = x + Int64(1)
_pc_imix(x::Int64)           = ((x * Int64(3)) ÷ Int64(2)) % Int64(7) | Int64(1)
_pc_i32(x::Int32)            = (x * Int32(3)) % Int32(7)
_pc_fmath(x::Float64)        = sin(x) + sqrt(abs(x)) * 2.0 - cos(x)
_pc_fmix(x::Float64)         = (x * 2.0 + 1.0) / (abs(x) + 1.0)
_pc_conv(x::Int64)           = Float64(x) * 1.5
_pc_cond(x::Int64)           = x > Int64(0) ? x * Int64(2) : -x
_pc_loop(n::Int64)           = (s = Int64(0); i = Int64(1); while i <= n; s += i; i += Int64(1); end; s)
_pc_rec(n::Int64)            = n <= Int64(1) ? Int64(1) : n * _pc_rec(n - Int64(1))
_pc_vsort(v::Vector{Int64})    = sort(v)
_pc_vsum(v::Vector{Float64})   = sum(v)
_pc_vmap(v::Vector{Int64})     = map(y -> y * Int64(2), v)
_pc_vfilter(v::Vector{Int64})  = filter(y -> y > Int64(0), v)
_pc_vreduce(v::Vector{Int64})  = reduce(min, v)
_pc_vstat(v::Vector{Int64})    = maximum(v) + length(v) + (isempty(v) ? Int64(0) : first(v))
_pc_dict(x::Int64)           = get(Dict(Int64(0) => Int64(1), Int64(1) => Int64(2)), x, Int64(0))
_pc_set(x::Int64)            = length(Set([x, x, x + Int64(1)]))
_pc_strlen(x::Int64)         = length(string(x))
_pc_strup(s::String)         = length(uppercase(s))
_pc_struct(x::Int32)         = (s = _PCStruct(x, 1.5); s.a + Int32(s.b))
_pc_tuple(x::Int64)          = (t = (x, x + Int64(1), x + Int64(2)); t[1] + t[3])

@setup_workload begin
    @compile_workload begin
        for (f, ts) in (
            (_pc_iadd, (Int64,)), (_pc_imix, (Int64,)), (_pc_i32, (Int32,)),
            (_pc_fmath, (Float64,)), (_pc_fmix, (Float64,)), (_pc_conv, (Int64,)),
            (_pc_cond, (Int64,)), (_pc_loop, (Int64,)), (_pc_rec, (Int64,)),
            (_pc_dict, (Int64,)), (_pc_set, (Int64,)),
            (_pc_strlen, (Int64,)), (_pc_strup, (String,)),
            (_pc_struct, (Int32,)), (_pc_tuple, (Int64,)),
            (_pc_vsort, (Vector{Int64},)), (_pc_vsum, (Vector{Float64},)),
            (_pc_vmap, (Vector{Int64},)), (_pc_vfilter, (Vector{Int64},)),
            (_pc_vreduce, (Vector{Int64},)), (_pc_vstat, (Vector{Int64},)),
        )
            try; compile(f, ts; validate=false); catch; end
        end
    end
end

end # module
