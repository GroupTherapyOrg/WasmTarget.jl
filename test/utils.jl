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
        const wasmModule = await WebAssembly.instantiate(bytes, {});
        const func = wasmModule.instance.exports['$func_name'];

        if (typeof func !== 'function') {
            console.error('Export "$func_name" is not a function');
            process.exit(1);
        }

        const result = func($js_args);

        // Handle BigInt serialization for JSON
        const serialized = JSON.stringify(result, (key, value) => {
            if (typeof value === 'bigint') {
                // Return as string with marker for parsing
                return { __bigint__: value.toString() };
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
    else
        return repr(arg)
    end
end

"""
Unmarshal a JSON result, handling BigInt markers.
"""
function unmarshal_result(result)
    if result isa Dict && haskey(result, "__bigint__")
        return parse(Int64, result["__bigint__"])
    elseif result isa Vector
        return [unmarshal_result(r) for r in result]
    elseif result isa Dict
        return Dict(k => unmarshal_result(v) for (k, v) in result)
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

        // Handle BigInt serialization for JSON
        const serialized = JSON.stringify(result, (key, value) => {
            if (typeof value === 'bigint') {
                return { __bigint__: value.toString() };
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
        const wasmModule = await WebAssembly.instantiate(bytes, {});
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
