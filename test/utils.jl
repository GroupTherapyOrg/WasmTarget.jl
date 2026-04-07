# Test Utilities - Node.js Wasm Execution Harness
# This is the "Ground Truth" verification engine for TDD

using Test, Dates
import JSON

# ============================================================================
# Node.js Detection
# ============================================================================

"""
Check if Node.js is available and get the command.
Returns a tuple of (command, needs_experimental_flag).
Requires Node.js v20+ for WasmGC support.
- v20-22: WasmGC is experimental (needs --experimental-wasm-gc flag)
- v23+: WasmGC is stable (no flag needed)
"""
function detect_node()
    try
        version_str = read(`node --version`, String)
        # Parse version (format: v20.x.x)
        m = match(r"v(\d+)\.", version_str)
        if m !== nothing
            major_version = Base.parse(Int, m.captures[1])
            if major_version >= 23
                # WasmGC is stable in v23+
                return (`node`, false)
            elseif major_version >= 20
                # WasmGC is experimental in v20-22
                return (`node`, true)
            else
                @warn "Node.js version $version_str found, but v20+ required for WasmGC"
                return (nothing, false)
            end
        end
        return (nothing, false)
    catch
        @warn "Node.js not found. Wasm execution tests will be skipped."
        return (nothing, false)
    end
end

const (NODE_CMD, NEEDS_EXPERIMENTAL_FLAG) = detect_node()

# ============================================================================
# Wasm Execution
# ============================================================================

"""
    run_wasm(wasm_bytes::Vector{UInt8}, func_name::String, args...) -> Any

Execute a WebAssembly function in Node.js and return the result.

# Arguments
- `wasm_bytes`: The compiled WebAssembly binary
- `func_name`: Name of the exported function to call
- `args...`: Arguments to pass to the function

# Returns
The result of the function call, parsed from JSON.
Returns `nothing` if Node.js is not available.
"""
function run_wasm(wasm_bytes::Vector{UInt8}, func_name::String, args...)
    if NODE_CMD === nothing
        @warn "Node.js not available. Skipping Wasm execution."
        return nothing
    end

    dir = mktempdir()
    wasm_path = joinpath(dir, "module.wasm")
    js_path = joinpath(dir, "loader.mjs")

    # Write the Wasm binary
    write(wasm_path, wasm_bytes)

    # Convert Julia args to JS args
    # Handle BigInt for 64-bit integers
    js_args = join(map(arg -> format_js_arg(arg), args), ", ")

    # Generate the loader script
    loader_script = """
import fs from 'fs';

const bytes = fs.readFileSync('$(escape_string(wasm_path))');

async function run() {
    try {
        const importObject = { Math: { pow: Math.pow } };
        const wasmModule = await WebAssembly.instantiate(bytes, importObject);
        const func = wasmModule.instance.exports['$func_name'];

        if (typeof func !== 'function') {
            console.error('Export "$func_name" is not a function');
            process.exit(1);
        }

        const result = func($js_args);

        // Handle BigInt and special float serialization for JSON
        const serialized = JSON.stringify(result, (key, value) => {
            if (typeof value === 'bigint') {
                // Return as string with marker for parsing
                return { __bigint__: value.toString() };
            }
            if (typeof value === 'number') {
                if (value === Infinity) return "__Inf__";
                if (value === -Infinity) return "__-Inf__";
                if (Number.isNaN(value)) return "__NaN__";
            }
            return value;
        });

        console.log(serialized);
    } catch (e) {
        console.error('Wasm execution error:', e.message);
        process.exit(1);
    }
}

run();
"""

    open(js_path, "w") do io
        print(io, loader_script)
    end

    # Run Node.js (with experimental flag if needed for older versions)
    try
        node_cmd = NEEDS_EXPERIMENTAL_FLAG ? `$NODE_CMD --experimental-wasm-gc $js_path` : `$NODE_CMD $js_path`
        output = read(pipeline(node_cmd; stderr=stderr), String)
        output = strip(output)

        if isempty(output)
            return nothing
        end

        # Parse the JSON result
        result = JSON.parse(output)

        # Handle BigInt unmarshaling
        return unmarshal_result(result)
    catch e
        if e isa ProcessFailedException
            error("Wasm execution failed. Check stderr for details.")
        end
        rethrow()
    end
end

"""
Format a Julia argument for JavaScript code.
"""
function format_js_arg(arg)
    if arg isa Int64 || arg isa Int
        # Use BigInt with string argument to preserve precision
        # BigInt(number) loses precision for large numbers, but BigInt("string") doesn't
        return "BigInt(\"$(arg)\")"
    elseif arg isa Int32
        return string(arg)
    elseif arg isa Float64 || arg isa Float32
        return string(arg)
    elseif arg isa Char
        # Julia stores Char as UTF-8 bytes left-packed in UInt32.
        # WASM expects this same representation as i32.
        raw = reinterpret(Int32, reinterpret(UInt32, arg))
        return string(raw)
    else
        return repr(arg)
    end
end

"""
Unmarshal a JSON result, handling BigInt markers.
"""
function unmarshal_result(result)
    if result isa Dict && haskey(result, "__bigint__")
        return Base.parse(Int64, result["__bigint__"])
    elseif result isa Vector
        return [unmarshal_result(r) for r in result]
    elseif result isa Dict
        return Dict(k => unmarshal_result(v) for (k, v) in result)
    elseif result isa AbstractString
        # Handle special float values from JSON serialization
        result == "__Inf__" && return Inf
        result == "__-Inf__" && return -Inf
        result == "__NaN__" && return NaN
        # WBUILD-3000: BigInt values are serialized as strings to preserve Int64 precision
        # (JavaScript Number loses precision for values > 2^53)
        return try
            Base.parse(Int64, result)
        catch
            result
        end
    else
        return result
    end
end

# ============================================================================
# Wasm Execution with Imports
# ============================================================================

"""
    run_wasm_with_imports(wasm_bytes, func_name, imports, args...) -> Any

Execute a WebAssembly function with JavaScript imports.

# Arguments
- `wasm_bytes`: The compiled WebAssembly binary
- `func_name`: Name of the exported function to call
- `imports`: Dict of module_name => Dict of field_name => JS function code
- `args...`: Arguments to pass to the function

# Example
```julia
imports = Dict("env" => Dict("log" => "(x) => console.log(x)"))
run_wasm_with_imports(bytes, "main", imports, Int32(42))
```
"""
function run_wasm_with_imports(wasm_bytes::Vector{UInt8}, func_name::String,
                               imports::Dict, args...)
    if NODE_CMD === nothing
        @warn "Node.js not available. Skipping Wasm execution."
        return nothing
    end

    dir = mktempdir()
    wasm_path = joinpath(dir, "module.wasm")
    js_path = joinpath(dir, "loader.mjs")

    # Write the Wasm binary
    write(wasm_path, wasm_bytes)

    # Convert Julia args to JS args
    js_args = join(map(arg -> format_js_arg(arg), args), ", ")

    # Build imports object
    imports_js = build_imports_js(imports)

    # Generate the loader script
    loader_script = """
import fs from 'fs';

const bytes = fs.readFileSync('$(escape_string(wasm_path))');

$imports_js

async function run() {
    try {
        const wasmModule = await WebAssembly.instantiate(bytes, importObject);
        const func = wasmModule.instance.exports['$func_name'];

        if (typeof func !== 'function') {
            console.error('Export "$func_name" is not a function');
            process.exit(1);
        }

        const result = func($js_args);

        // Handle BigInt and special float serialization for JSON
        const serialized = JSON.stringify(result, (key, value) => {
            if (typeof value === 'bigint') {
                return { __bigint__: value.toString() };
            }
            if (typeof value === 'number') {
                if (value === Infinity) return "__Inf__";
                if (value === -Infinity) return "__-Inf__";
                if (Number.isNaN(value)) return "__NaN__";
            }
            return value;
        });

        console.log(serialized);
    } catch (e) {
        console.error('Wasm execution error:', e.message);
        process.exit(1);
    }
}

run();
"""

    open(js_path, "w") do io
        print(io, loader_script)
    end

    # Run Node.js
    try
        node_cmd = NEEDS_EXPERIMENTAL_FLAG ? `$NODE_CMD --experimental-wasm-gc $js_path` : `$NODE_CMD $js_path`
        output = read(pipeline(node_cmd; stderr=stderr), String)
        output = strip(output)

        if isempty(output)
            return nothing
        end

        result = JSON.parse(output)
        return unmarshal_result(result)
    catch e
        if e isa ProcessFailedException
            error("Wasm execution failed. Check stderr for details.")
        end
        rethrow()
    end
end

"""
Build JavaScript code for import object.
"""
function build_imports_js(imports::Dict)
    parts = String[]
    push!(parts, "const importObject = {")
    for (mod_name, fields) in imports
        push!(parts, "  \"$mod_name\": {")
        for (field_name, func_code) in fields
            push!(parts, "    \"$field_name\": $func_code,")
        end
        push!(parts, "  },")
    end
    push!(parts, "};")
    return join(parts, "\n")
end

# ============================================================================
# TDD Test Macros
# ============================================================================

"""
    @test_compile func_call

Test that compiling and running a Julia function in Wasm produces
the same result as running it natively in Julia.

# Example
```julia
my_add(a, b) = a + b
@test_compile my_add(1, 2)
```
"""
macro test_compile(func_call)
    quote
        # 1. Run in Julia (Ground Truth)
        expected = $(esc(func_call))

        # 2. Extract function and args
        f = $(esc(func_call.args[1]))
        args = ($(esc.(func_call.args[2:end])...),)
        arg_types = map(typeof, args)

        # 3. Compile to Wasm
        wasm_bytes = WasmTarget.compile(f, Tuple(arg_types))

        # 4. Run in Node
        actual = run_wasm(wasm_bytes, string(nameof(f)), args...)

        # 5. Verify
        if actual !== nothing
            @test actual == expected
        else
            @warn "Skipped Wasm verification (Node.js not available)"
        end
    end
end

"""
    @test_wasm_output wasm_bytes func_name args... expected

Test that running a Wasm binary produces the expected output.
Useful for testing hand-crafted Wasm binaries.
"""
macro test_wasm_output(wasm_bytes, func_name, args, expected)
    quote
        actual = run_wasm($(esc(wasm_bytes)), $(esc(func_name)), $(esc(args))...)
        if actual !== nothing
            @test actual == $(esc(expected))
        else
            @warn "Skipped Wasm verification (Node.js not available)"
        end
    end
end

# ============================================================================
# Wasm Validation
# ============================================================================

"""
    validate_wasm(wasm_bytes::Vector{UInt8}) -> Bool

Validate a WebAssembly module by attempting to instantiate it in Node.js.
Returns true if the module is valid, false otherwise.
"""
function validate_wasm(wasm_bytes::Vector{UInt8})
    if NODE_CMD === nothing
        @warn "Node.js not available. Skipping Wasm validation."
        return true  # Assume valid if we can't check
    end

    dir = mktempdir()
    wasm_path = joinpath(dir, "module.wasm")
    js_path = joinpath(dir, "validator.mjs")

    # Write the Wasm binary
    write(wasm_path, wasm_bytes)

    # Generate the validator script
    validator_script = """
import fs from 'fs';

const bytes = fs.readFileSync('$(escape_string(wasm_path))');

async function validate() {
    try {
        const importObject = { Math: { pow: Math.pow } };
        const wasmModule = await WebAssembly.instantiate(bytes, importObject);
        console.log("VALID");
        process.exit(0);
    } catch (e) {
        console.error('Validation error:', e.message);
        process.exit(1);
    }
}

validate();
"""

    open(js_path, "w") do io
        print(io, validator_script)
    end

    # Run Node.js
    try
        node_cmd = NEEDS_EXPERIMENTAL_FLAG ? `$NODE_CMD --experimental-wasm-gc $js_path` : `$NODE_CMD $js_path`
        output = read(pipeline(node_cmd; stderr=stderr), String)
        return strip(output) == "VALID"
    catch e
        return false
    end
end

# ============================================================================
# Comparison Harness — Automated Julia vs Wasm Verification
# ============================================================================

"""
    compare_julia_wasm(f, args...) -> NamedTuple

Run function `f` natively in Julia and compiled to Wasm, then compare results.
Returns `(pass=Bool, expected=Any, actual=Any)`.

This is the correctness oracle for M_PATTERNS: if Julia says `f(x) = 42`,
the Wasm must return 42. No approximate results, no simplified implementations.

# Example
```julia
r = compare_julia_wasm(x -> x + Int32(1), Int32(5))
@assert r.pass "Expected \$(r.expected), got \$(r.actual)"
```
"""
function compare_julia_wasm(f, args...)
    # 1. Run natively in Julia to get expected result
    expected = f(args...)

    # 2. Compile to Wasm
    arg_types = Tuple(map(typeof, args))
    bytes = WasmTarget.compile(f, arg_types)

    # 3. Run in Node.js to get actual result (with standard Math imports)
    func_name = string(nameof(f))
    imports = Dict("Math" => Dict("pow" => "Math.pow"))
    actual = run_wasm_with_imports(bytes, func_name, imports, args...)

    # 4. Compare (skip if Node.js unavailable)
    if actual === nothing && NODE_CMD === nothing
        return (pass=true, expected=expected, actual=nothing, skipped=true)
    end

    return (pass=(expected == actual), expected=expected, actual=actual, skipped=false)
end

"""
    compare_batch(f, test_cases::Vector) -> Vector{NamedTuple}

Run `compare_julia_wasm` for multiple inputs. Each element of `test_cases`
is a tuple of arguments to pass to `f`.

# Example
```julia
results = compare_batch(x -> x + Int32(1), [
    (Int32(0),),
    (Int32(5),),
    (Int32(-1),),
])
for r in results
    @assert r.pass "Args \$(r.args): expected \$(r.expected), got \$(r.actual)"
end
```
"""
function compare_batch(f, test_cases::Vector)
    results = NamedTuple[]
    for args in test_cases
        r = compare_julia_wasm(f, args...)
        push!(results, (args=args, expected=r.expected, actual=r.actual, pass=r.pass, skipped=r.skipped))
    end
    return results
end

# ============================================================================
# Manual Comparison — Pre-computed Expected Values
# ============================================================================

"""
    compare_julia_wasm_manual(f, args::Tuple, expected) -> NamedTuple

Compare Wasm output against a pre-computed expected value from native Julia.
Use this when compare_julia_wasm can't handle the argument or return types
(e.g., String args, struct returns) but you've already run the function
natively and know the expected numeric result.

The function `f` must return a type that the JS bridge can marshal (Int32, Int64, Float64, Bool).
The `args` tuple must contain types the JS bridge can marshal.

# Example
```julia
# Pre-compute in native Julia: length("hello") = 5
r = compare_julia_wasm_manual(s -> Int32(length(s)), (Int32(5),), Int32(5))
@assert r.pass
```
"""
function compare_julia_wasm_manual(f, args::Tuple, expected)
    # 1. Compile to Wasm
    arg_types = Tuple(map(typeof, args))
    bytes = WasmTarget.compile(f, arg_types)

    # 2. Run in Node.js (with standard Math imports)
    func_name = string(nameof(f))
    imports = Dict("Math" => Dict("pow" => "Math.pow"))
    actual = run_wasm_with_imports(bytes, func_name, imports, args...)

    # 3. Compare against pre-computed expected value
    if actual === nothing && NODE_CMD === nothing
        return (pass=true, expected=expected, actual=nothing, skipped=true)
    end

    return (pass=(expected == actual), expected=expected, actual=actual, skipped=false)
end

"""
    compare_batch_manual(f, test_cases::Vector) -> Vector{NamedTuple}

Batch version of compare_julia_wasm_manual. Each element of `test_cases`
is `(args_tuple, expected_value)`.

# Example
```julia
results = compare_batch_manual(x -> x * Int32(2), [
    ((Int32(3),), Int32(6)),
    ((Int32(0),), Int32(0)),
    ((Int32(-1),), Int32(-2)),
])
for r in results
    @assert r.pass "Args \$(r.args): expected \$(r.expected), got \$(r.actual)"
end
```
"""
function compare_batch_manual(f, test_cases::Vector)
    results = NamedTuple[]
    for (args, expected) in test_cases
        r = compare_julia_wasm_manual(f, args, expected)
        push!(results, (args=args, expected=expected, actual=r.actual, pass=r.pass, skipped=r.skipped))
    end
    return results
end

"""
    compare_julia_wasm_wrapper(wrapper_f, args...) -> NamedTuple

Like compare_julia_wasm but for functions whose args/return types aren't
directly marshalable by the JS bridge. The `wrapper_f` must accept
marshalable args and return a marshalable type (Int32, Int64, Float64, Bool).

The wrapper extracts a numeric summary from a complex computation.
Run both natively and in Wasm, compare the numeric results.

# Example
```julia
# Instead of testing parse!(ParseStream(s)) directly (returns struct),
# test a wrapper that returns a numeric summary:
parse_output_len(n::Int32) = Int32(n + 1)  # simplified example
r = compare_julia_wasm_wrapper(parse_output_len, Int32(5))
@assert r.pass
```

Note: This is identical to compare_julia_wasm in implementation — it exists
as a semantic alias to document that the function is a wrapper extracting
numeric results from complex operations.
"""
function compare_julia_wasm_wrapper(wrapper_f, args...)
    return compare_julia_wasm(wrapper_f, args...)
end

# ============================================================================
# Ground Truth Snapshots — Native Julia Reference Values
# ============================================================================

const GROUND_TRUTH_DIR = joinpath(@__DIR__, "ground_truth")

"""
    generate_ground_truth(name::String, f, inputs::Vector; overwrite=false) -> String

Run `f` natively in Julia for each input tuple, save results to a JSON snapshot
file in `test/ground_truth/`. Returns the path to the snapshot file.

Each input must be a tuple of marshalable arguments (Int32, Int64, Float64).
The function `f` must return a marshalable type.

# Example
```julia
generate_ground_truth("add_one", x -> x + Int32(1), [
    (Int32(0),),
    (Int32(5),),
    (Int32(-1),),
])
```
"""
function generate_ground_truth(name::String, f, inputs::Vector; overwrite::Bool=false)
    mkpath(GROUND_TRUTH_DIR)
    path = joinpath(GROUND_TRUTH_DIR, "$name.json")
    if isfile(path) && !overwrite
        @info "Ground truth '$name' already exists. Use overwrite=true to regenerate."
        return path
    end

    entries = []
    for args in inputs
        result = f(args...)
        push!(entries, Dict(
            "args" => collect(args),
            "expected" => result
        ))
    end

    snapshot = Dict(
        "name" => name,
        "generated" => string(Dates.now()),
        "julia_version" => string(VERSION),
        "entries" => entries
    )

    open(path, "w") do io
        JSON.print(io, snapshot, 2)
    end
    @info "Generated ground truth '$name' with $(length(entries)) entries at $path"
    return path
end

"""
    load_ground_truth(name::String) -> Dict

Load a ground truth snapshot by name from `test/ground_truth/`.
"""
function load_ground_truth(name::String)
    path = joinpath(GROUND_TRUTH_DIR, "$name.json")
    if !isfile(path)
        error("Ground truth '$name' not found at $path. Run generate_ground_truth first.")
    end
    return JSON.parsefile(path)
end

"""
    compare_against_ground_truth(name::String, f) -> Vector{NamedTuple}

Compile `f` to Wasm and compare its output against saved ground truth snapshots.
Returns a vector of `(args, expected, actual, pass, skipped)` named tuples.

The ground truth must have been generated with `generate_ground_truth` first.

# Example
```julia
generate_ground_truth("add_one", x -> x + Int32(1), [(Int32(0),), (Int32(5),)])
results = compare_against_ground_truth("add_one", x -> x + Int32(1))
for r in results
    @assert r.pass "Args \$(r.args): expected \$(r.expected), got \$(r.actual)"
end
```
"""
function compare_against_ground_truth(name::String, f)
    snapshot = load_ground_truth(name)
    entries = snapshot["entries"]

    results = NamedTuple[]
    for entry in entries
        args_raw = entry["args"]
        expected = entry["expected"]

        # Convert JSON arrays back to typed tuples
        # JSON stores numbers as Int64/Float64, so convert to match original types
        args = Tuple(Int32(a) for a in args_raw)

        r = compare_julia_wasm_manual(f, args, expected isa Integer ? Int32(expected) : expected)
        push!(results, (args=args, expected=expected, actual=r.actual, pass=r.pass, skipped=r.skipped))
    end
    return results
end

# ============================================================================
# JS↔WasmGC Bridge — Vector Marshalling (dart2wasm pattern)
# ============================================================================

# Bridge functions for Vector{Int64}
_bv_i64_new(n::Int64)::Vector{Int64} = Vector{Int64}(undef, n)
_bv_i64_set!(v::Vector{Int64}, i::Int64, val::Int64)::Int64 = (v[i] = val; Int64(0))
_bv_i64_get(v::Vector{Int64}, i::Int64)::Int64 = v[i]
_bv_i64_len(v::Vector{Int64})::Int64 = Int64(length(v))

# Bridge functions for Vector{Float64}
_bv_f64_new(n::Int64)::Vector{Float64} = Vector{Float64}(undef, n)
_bv_f64_set!(v::Vector{Float64}, i::Int64, val::Float64)::Int64 = (v[i] = val; Int64(0))
_bv_f64_get(v::Vector{Float64}, i::Int64)::Float64 = v[i]
_bv_f64_len(v::Vector{Float64})::Int64 = Int64(length(v))

# Bridge function specs: (func, arg_types) tuples for compile_multi
const BRIDGE_SPECS_I64 = [
    (_bv_i64_new, (Int64,)),
    (_bv_i64_set!, (Vector{Int64}, Int64, Int64)),
    (_bv_i64_get, (Vector{Int64}, Int64)),
    (_bv_i64_len, (Vector{Int64},)),
]

const BRIDGE_SPECS_F64 = [
    (_bv_f64_new, (Int64,)),
    (_bv_f64_set!, (Vector{Float64}, Int64, Float64)),
    (_bv_f64_get, (Vector{Float64}, Int64)),
    (_bv_f64_len, (Vector{Float64},)),
]

"""
    _needs_bridge(arg_types) -> (needs_i64::Bool, needs_f64::Bool)

Check if any argument types require the bridge for Vector marshalling.
"""
function _needs_bridge(arg_types)
    needs_i64 = any(T -> T === Vector{Int64}, arg_types)
    needs_f64 = any(T -> T === Vector{Float64}, arg_types)
    return (needs_i64, needs_f64)
end

"""
    _returns_vector(f, arg_types) -> Union{Nothing, Type}

Check if function returns a Vector type. Returns the element type or nothing.
"""
function _returns_vector(f, arg_types)
    ci, rt = Base.code_typed(f, arg_types; optimize=true)[1]
    if rt <: Vector{Int64}
        return Int64
    elseif rt <: Vector{Float64}
        return Float64
    end
    return nothing
end

"""
    _generate_bridge_loader(func_name, args, arg_types, return_vec_eltype) -> String

Generate JavaScript loader code that uses bridge functions to marshal Vector args.
"""
function _generate_bridge_loader(wasm_path, func_name, args, arg_types, return_vec_eltype)
    lines = String[]
    push!(lines, "import fs from 'fs';")
    push!(lines, "const bytes = fs.readFileSync('$(escape_string(wasm_path))');")
    push!(lines, "async function run() {")
    push!(lines, "  try {")
    push!(lines, "    const importObject = { Math: { pow: Math.pow } };")
    push!(lines, "    const wasmModule = await WebAssembly.instantiate(bytes, importObject);")
    push!(lines, "    const e = wasmModule.instance.exports;")

    # Marshal each argument
    call_args = String[]
    for (i, (arg, T)) in enumerate(zip(args, arg_types))
        if T === Vector{Int64}
            v = arg::Vector{Int64}
            push!(lines, "    const v$(i) = e._bv_i64_new($(length(v))n);")
            for (j, val) in enumerate(v)
                push!(lines, "    e['_bv_i64_set!'](v$(i), $(j)n, $(val)n);")
            end
            push!(call_args, "v$(i)")
        elseif T === Vector{Float64}
            v = arg::Vector{Float64}
            push!(lines, "    const v$(i) = e._bv_f64_new($(length(v))n);")
            for (j, val) in enumerate(v)
                js_val = isnan(val) ? "NaN" : isinf(val) ? (val > 0 ? "Infinity" : "-Infinity") : string(val)
                push!(lines, "    e['_bv_f64_set!'](v$(i), $(j)n, $(js_val));")
            end
            push!(call_args, "v$(i)")
        elseif T === Int64 || T === Int
            push!(call_args, "$(arg)n")
        elseif T === Int32
            push!(call_args, "$(arg)")
        elseif T === Float64 || T === Float32
            push!(call_args, "$(arg)")
        else
            push!(call_args, repr(arg))
        end
    end

    # Call the function
    push!(lines, "    const result = e['$(func_name)']($(join(call_args, ", ")));")

    # Extract result
    if return_vec_eltype === Int64
        push!(lines, "    const len = Number(e._bv_i64_len(result));")
        push!(lines, "    const out = [];")
        push!(lines, "    for (let i = 0; i < len; i++) out.push(e._bv_i64_get(result, BigInt(i+1)).toString());")
        push!(lines, "    console.log(JSON.stringify(out));")
    elseif return_vec_eltype === Float64
        push!(lines, "    const len = Number(e._bv_f64_len(result));")
        push!(lines, "    const out = [];")
        push!(lines, "    for (let i = 0; i < len; i++) {")
        push!(lines, "      const v = e._bv_f64_get(result, BigInt(i+1));")
        push!(lines, "      if (Number.isNaN(v)) out.push('NaN');")
        push!(lines, "      else if (v === Infinity) out.push('Inf');")
        push!(lines, "      else if (v === -Infinity) out.push('-Inf');")
        push!(lines, "      else out.push(v);")
        push!(lines, "    }")
        push!(lines, "    console.log(JSON.stringify(out));")
    else
        # Scalar result
        push!(lines, """    const serialized = JSON.stringify(result, (key, value) => {
      if (typeof value === 'bigint') return { __bigint__: value.toString() };
      if (typeof value === 'number') {
        if (value === Infinity) return "__Inf__";
        if (value === -Infinity) return "__-Inf__";
        if (Number.isNaN(value)) return "__NaN__";
      }
      return value;
    });""")
        push!(lines, "    console.log(serialized);")
    end

    push!(lines, "  } catch (e) {")
    push!(lines, "    console.error('Wasm execution error:', e.message);")
    push!(lines, "    process.exit(1);")
    push!(lines, "  }")
    push!(lines, "}")
    push!(lines, "run();")

    return join(lines, "\n")
end

"""
    compare_julia_wasm_vec(f, args...) -> NamedTuple

Like compare_julia_wasm but handles Vector{Int64} and Vector{Float64} arguments
via the JS↔WasmGC bridge pattern (dart2wasm style).

Bridge functions are compiled alongside `f` via compile_multi. The JS loader
uses bridge.new/set to create WasmGC vectors from JS arrays, calls the real
function, then uses bridge.get/len to extract results.

# Example
```julia
f_sort(v::Vector{Int64})::Vector{Int64} = sort(v)
r = compare_julia_wasm_vec(f_sort, Int64[3, 1, 2])
@test r.pass  # expected=[1,2,3], actual=[1,2,3]
```
"""
function compare_julia_wasm_vec(f, args...)
    # Deep-copy args before Julia reference call — mutating functions (push!, pop!, etc.)
    # modify the input Vector in-place, which would corrupt the args used later for the
    # WASM bridge if we don't copy first.
    args_for_wasm = deepcopy(args)

    if NODE_CMD === nothing
        expected = f(args...)
        return (pass=true, expected=expected, actual=nothing, skipped=true)
    end

    # 1. Run natively in Julia (may mutate args)
    expected = f(args...)

    # 2. Determine which bridges are needed
    arg_types = map(typeof, args)
    needs_i64, needs_f64 = _needs_bridge(arg_types)
    return_vec_eltype = _returns_vector(f, Tuple(arg_types))

    # Also need bridge for return type
    if return_vec_eltype === Int64
        needs_i64 = true
    elseif return_vec_eltype === Float64
        needs_f64 = true
    end

    # 3. Build compile_multi function list
    func_list = Any[(f, Tuple(arg_types))]
    if needs_i64
        append!(func_list, BRIDGE_SPECS_I64)
    end
    if needs_f64
        append!(func_list, BRIDGE_SPECS_F64)
    end

    # 4. Compile
    bytes = WasmTarget.compile_multi(func_list)

    # 5. Generate bridge-aware loader and run
    func_name = string(nameof(f))
    dir = mktempdir()
    wasm_path = joinpath(dir, "module.wasm")
    js_path = joinpath(dir, "loader.mjs")

    write(wasm_path, bytes)
    loader_code = _generate_bridge_loader(wasm_path, func_name, args_for_wasm, arg_types, return_vec_eltype)
    open(js_path, "w") do io
        print(io, loader_code)
    end

    # 6. Execute
    try
        node_cmd = NEEDS_EXPERIMENTAL_FLAG ? `$NODE_CMD --experimental-wasm-gc $js_path` : `$NODE_CMD $js_path`
        output = read(pipeline(node_cmd; stderr=stderr), String)
        output = strip(output)

        if isempty(output)
            return (pass=false, expected=expected, actual=nothing, skipped=false)
        end

        result = JSON.parse(output)
        actual = unmarshal_result(result)

        # For Vector returns, compare element-by-element
        if expected isa Vector
            expected_nums = if eltype(expected) === Int64
                [Int64(x) for x in expected]
            else
                [_parse_f64(x) for x in expected]
            end
            actual_nums = if actual isa Vector && return_vec_eltype === Float64
                [_parse_f64(x) for x in actual]
            elseif actual isa Vector
                actual
            else
                actual
            end
            pass = actual_nums isa Vector && length(actual_nums) == length(expected_nums) &&
                   all(i -> _approx_equal(actual_nums[i], expected_nums[i]), 1:length(expected_nums))
        else
            pass = (expected == actual)
        end

        return (pass=pass, expected=expected, actual=actual, skipped=false)
    catch e
        if e isa ProcessFailedException
            return (pass=false, expected=expected, actual="WASM_ERROR", skipped=false)
        end
        rethrow()
    end
end

"""
Parse a value to Float64, handling string markers for NaN/Inf.
"""
function _parse_f64(x)
    x isa AbstractString && x == "NaN" && return NaN
    x isa AbstractString && x == "Inf" && return Inf
    x isa AbstractString && x == "-Inf" && return -Inf
    return Float64(x)
end

"""
Approximate equality for float comparisons.
"""
function _approx_equal(a, b)
    if a isa AbstractFloat || b isa AbstractFloat
        fa, fb = Float64(a), Float64(b)
        if isnan(fa) && isnan(fb)
            return true
        end
        return isapprox(fa, fb; atol=1e-10, rtol=1e-10)
    end
    return a == b
end

# ============================================================================
# Debug Utilities
# ============================================================================

"""
    dump_wasm(wasm_bytes::Vector{UInt8}, path::String)

Write Wasm bytes to a file for debugging with external tools.
"""
function dump_wasm(wasm_bytes::Vector{UInt8}, path::String)
    write(path, wasm_bytes)
    println("Wrote $(length(wasm_bytes)) bytes to $path")
end

"""
    hexdump(bytes::Vector{UInt8})

Print bytes as hex for debugging.
"""
function hexdump(bytes::Vector{UInt8}; columns=16)
    for (i, b) in enumerate(bytes)
        print(string(b, base=16, pad=2), " ")
        if i % columns == 0
            println()
        end
    end
    if length(bytes) % columns != 0
        println()
    end
end

# ============================================================================
# Dual-Path Comparison — Self-Hosting Verification (PHASE-1M-T01, PHASE-1-T01)
# ============================================================================

"""
    compare_server_vs_mini(f, arg_types; test_args=nothing, func_name=nothing) -> NamedTuple

Compare server-compiled (compile()) vs mini/frozen-compiled path.
The mini path uses: code_typed → preprocess → serialize → deserialize → compile_module_from_ir.

Compares RESULTS (not bytes) since the mini path may produce different binary layout.

Returns (pass, native, server, transport, server_size, transport_size).
"""
function compare_server_vs_mini(f, arg_types::Tuple; test_args=nothing, func_name=nothing)
    if func_name === nothing
        func_name = string(nameof(f))
    end
    if test_args === nothing
        # Generate default test args: zeros of the right types
        test_args = Tuple(zero(T) for T in arg_types)
    end

    # Native Julia result
    native = f(test_args...)

    # Server path: compile() directly
    server_bytes = WasmTarget.compile(f, arg_types)
    server_result = nothing
    try
        server_result = run_wasm(server_bytes, func_name, test_args...)
    catch e
        server_result = "ERROR: $e"
    end

    # Transport/mini path: code_typed → preprocess → serialize → deserialize → compile
    ci, rt = Base.code_typed(f, arg_types; optimize=true)[1]
    entries = [(ci, rt, arg_types, func_name)]
    preprocessed = WasmTarget.preprocess_ir_entries(entries)
    json_str = WasmTarget.serialize_ir_entries(preprocessed)
    received = WasmTarget.deserialize_ir_entries(json_str)
    transport_bytes = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(received))
    transport_result = nothing
    try
        transport_result = run_wasm(transport_bytes, func_name, test_args...)
    catch e
        transport_result = "ERROR: $e"
    end

    # Compare results (not bytes)
    pass = (server_result == native) && (transport_result == native)

    return (pass=pass, native=native, server=server_result, transport=transport_result,
            server_size=length(server_bytes), transport_size=length(transport_bytes))
end

"""
    compare_server_vs_selfhosted(f, arg_types; test_args=nothing, func_name=nothing) -> NamedTuple

Compare server-compiled (compile()) vs self-hosted transport path.
The self-hosted path uses: code_typed → preprocess → serialize → deserialize → compile_module_from_ir.

Compares both BYTES (should be identical) and RESULTS.

Returns (pass, bytes_identical, native, server, transport, server_size, transport_size).
"""
function compare_server_vs_selfhosted(f, arg_types::Tuple; test_args=nothing, func_name=nothing)
    if func_name === nothing
        func_name = string(nameof(f))
    end
    if test_args === nothing
        test_args = Tuple(zero(T) for T in arg_types)
    end

    native = f(test_args...)

    # Server path
    server_bytes = WasmTarget.compile(f, arg_types)
    server_result = nothing
    try
        server_result = run_wasm(server_bytes, func_name, test_args...)
    catch e
        server_result = "ERROR: $e"
    end

    # Self-hosted path: code_typed → preprocess → serialize → deserialize → compile_module_from_ir
    ci, rt = Base.code_typed(f, arg_types; optimize=true)[1]
    entries = [(ci, rt, arg_types, func_name)]
    preprocessed = WasmTarget.preprocess_ir_entries(entries)
    json_str = WasmTarget.serialize_ir_entries(preprocessed)
    received = WasmTarget.deserialize_ir_entries(json_str)
    transport_bytes = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(received))
    transport_result = nothing
    try
        transport_result = run_wasm(transport_bytes, func_name, test_args...)
    catch e
        transport_result = "ERROR: $e"
    end

    bytes_identical = server_bytes == transport_bytes
    pass = bytes_identical && (server_result == native) && (transport_result == native)

    return (pass=pass, bytes_identical=bytes_identical, native=native,
            server=server_result, transport=transport_result,
            server_size=length(server_bytes), transport_size=length(transport_bytes))
end

# ============================================================================
# Browser TypeInf Comparison — Phase 2 (PHASE-2-T01)
# ============================================================================

# Global state: typeinf overrides loaded flag
const _TYPEINF_OVERRIDES_LOADED = Ref{Bool}(false)

"""
    compare_server_vs_browser_typeinf(functions::Vector; world=nothing) -> Vector{NamedTuple}

Batch three-way comparison: server typeinf vs browser (WasmInterpreter) typeinf vs native.

Each element of `functions` is a tuple: `(f, arg_types, name, test_args_list)` where
`test_args_list` is a vector of argument tuples.

For each function, compares:
1. Server: code_typed → return type
2. Browser: WasmInterpreter typeinf → return type (must match server)
3. Execution: compile → run in Node.js → result must match native Julia

IMPORTANT: This function loads typeinf overrides on first call. These overrides are
IRREVERSIBLE — Base._methods_by_ftype and Base.typeintersect are overridden globally.
ALL code_typed/code_lowered/methods()/process spawning MUST happen before overrides load.
Call this ONCE per process with all functions to compare.

Returns a vector of NamedTuples, one per function.
"""
function compare_server_vs_browser_typeinf(functions::Vector; world::Union{Nothing,UInt64}=nothing)
    if world === nothing
        world = Base.get_world_counter()
    end

    if _TYPEINF_OVERRIDES_LOADED[]
        error("Typeinf overrides already loaded. compare_server_vs_browser_typeinf can only be called ONCE per process (before overrides).")
    end

    native_mt = Core.Compiler.InternalMethodTable(world)

    # Common callee signatures (arithmetic, comparison ops)
    callee_sigs = [
        Tuple{typeof(+), Int64, Int64}, Tuple{typeof(-), Int64, Int64},
        Tuple{typeof(*), Int64, Int64}, Tuple{typeof(+), Float64, Float64},
        Tuple{typeof(-), Float64, Float64}, Tuple{typeof(*), Float64, Float64},
        Tuple{typeof(<), Float64, Float64}, Tuple{typeof(>), Float64, Float64},
        Tuple{typeof(>=), Int64, Int64}, Tuple{typeof(<=), Int64, Int64},
        Tuple{typeof(>), Int64, Int64}, Tuple{typeof(<), Int64, Int64},
        Tuple{typeof(÷), Int64, Int64}, Tuple{typeof(%), Int64, Int64},
        Tuple{typeof(⊻), Int64, Int64},
    ]

    # ── Phase A: Pre-compute ALL data BEFORE loading overrides ──
    precomputed = []
    shared_methods = Dict{Any, Core.Compiler.MethodLookupResult}()

    # Pre-compute callee methods
    for csig in callee_sigs
        r = Core.Compiler.findall(csig, native_mt; limit=3)
        if r !== nothing
            shared_methods[csig] = r
        end
    end

    for (f, arg_types, name, test_args_list) in functions
        sig = Tuple{typeof(f), arg_types...}

        # Server typeinf
        server_ci, server_ret = Base.code_typed(f, arg_types)[1]

        # Method table entry
        r = Core.Compiler.findall(sig, native_mt; limit=3)
        if r !== nothing
            shared_methods[sig] = r
        end

        # MethodInstance + CodeInfo for WasmInterpreter
        mi = Core.Compiler.specialize_method(
            first(methods(f, arg_types)),
            sig, Core.svec()
        )
        src = Core.Compiler.retrieve_code_info(mi, world)

        # Compile + execute for each test case
        exec_results = []
        try
            bytes = WasmTarget.compile(f, arg_types)
            for args in test_args_list
                native = f(args...)
                wasm = nothing
                try
                    wasm = run_wasm(bytes, name, args...)
                catch e
                    wasm = "ERROR: $e"
                end
                push!(exec_results, (args=args, native=native, wasm=wasm,
                    pass=(native isa Float64 ? (wasm isa Number && abs(Float64(wasm) - native) < 1e-10) : wasm == native)))
            end
        catch e
            push!(exec_results, (args=(), native=nothing, wasm="COMPILE ERROR: $e", pass=false))
        end

        push!(precomputed, (name=name, server_ret=server_ret, mi=mi, src=src,
                           exec_results=exec_results))
    end

    # ── Phase B: Load overrides (once, irreversible) ──
    typeinf_dir = joinpath(@__DIR__, "..", "src", "selfhost", "typeinf")
    include(joinpath(typeinf_dir, "ccall_stubs.jl"))
    include(joinpath(typeinf_dir, "subtype.jl"))
    include(joinpath(typeinf_dir, "matching.jl"))
    include(joinpath(typeinf_dir, "ccall_replacements.jl"))
    include(joinpath(typeinf_dir, "dict_method_table.jl"))
    _TYPEINF_OVERRIDES_LOADED[] = true

    # ── Phase C: Browser typeinf via WasmInterpreter ──
    results = NamedTuple[]
    for pc in precomputed
        browser_ret = nothing
        try
            browser_ret = @invokelatest _run_browser_typeinf(pc.mi, pc.src, world, shared_methods)
        catch e
            browser_ret = "ERROR: $(sprint(showerror, e))"
        end

        types_match = pc.server_ret == browser_ret
        exec_pass = all(r -> r.pass, pc.exec_results)
        pass = types_match && exec_pass

        push!(results, (name=pc.name, pass=pass,
            server_type=pc.server_ret, browser_type=browser_ret,
            types_match=types_match, exec_results=pc.exec_results))
    end

    return results
end

# Single-function convenience wrapper
function compare_server_vs_browser_typeinf(f, arg_types::Tuple;
                                            test_args=nothing, func_name=nothing)
    if func_name === nothing
        func_name = string(nameof(f))
    end
    if test_args === nothing
        test_args = Tuple(zero(T) for T in arg_types)
    end
    results = compare_server_vs_browser_typeinf(
        [(f, arg_types, func_name, [test_args])]
    )
    r = first(results)
    er = first(r.exec_results)
    return (pass=r.pass, server_type=r.server_type, browser_type=r.browser_type,
            types_match=r.types_match, native=er.native, server_wasm=er.wasm)
end

"""
    _run_browser_typeinf(mi, src, world, method_entries) -> Any

Internal helper. Runs WasmInterpreter typeinf in the new world context.
Must be called via @invokelatest to see dynamically loaded method definitions.
"""
function _run_browser_typeinf(mi::Core.MethodInstance, src::Core.CodeInfo,
                               world::UInt64, method_entries::Dict)
    table = DictMethodTable(world)
    for (k, v) in method_entries
        table.methods[k] = v
    end
    interp = WasmInterpreter(world, table)
    result = Core.Compiler.InferenceResult(mi)
    frame = Core.Compiler.InferenceState(result, src, :no, interp)
    Core.Compiler.typeinf(interp, frame)
    return result.result
end
