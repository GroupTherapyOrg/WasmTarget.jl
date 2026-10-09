# Test Utilities - Node.js Wasm Execution Harness
# This is the "Ground Truth" verification engine for TDD

using Test, Dates
import JSON

# Persistent Node worker pool — replaces per-call `node` spawns (≈150–300ms each)
# with long-lived workers (~0.2ms/run). Shared with the differential fuzzer.
include(joinpath(@__DIR__, "wasm_runner.jl"));  using .WasmRunner


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
function run_wasm(wasm_bytes::Vector{UInt8}, func_name::String, args...;
                  source_map::Union{Nothing,String}=nothing)
    js_args = join(map(arg -> format_js_arg(arg), args), ", ")
    status, val = WasmRunner.run_wasm_single(wasm_bytes, func_name, js_args; source_map=source_map)
    (status === :trap || status === :error) && error("Wasm execution failed: $(val)")
    return unmarshal_result(val)
end

"""
Format a Julia argument for JavaScript code.
"""
function format_js_arg(arg)
    if arg isa Int64 || arg isa Int
        # Use BigInt with string argument to preserve precision
        # BigInt(number) loses precision for large numbers, but BigInt("string") doesn't
        return "BigInt(\"$(arg)\")"
    elseif arg isa UInt64
        # UInt64 maps to i64 in Wasm — pass as BigInt of the reinterpreted signed value
        return "BigInt(\"$(reinterpret(Int64, arg))\")"
    elseif arg isa Int32
        return string(arg)
    elseif arg isa UInt32
        # UInt32 maps to i32 in Wasm — pass as reinterpreted signed value
        return string(reinterpret(Int32, arg))
    elseif arg isa Float64 || arg isa Float32
        isnan(arg) && return "NaN"
        arg == Inf && return "Infinity"
        arg == -Inf && return "-Infinity"
        arg == Inf32 && return "Infinity"
        arg == -Inf32 && return "-Infinity"
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

Accepts `AbstractDict` (not just `Dict`) so JSON.jl 1.x's `JSON.Object`
return type is handled the same as 0.21's plain `Dict`.
"""
function unmarshal_result(result)
    if result isa AbstractDict && haskey(result, "__bigint__")
        return Base.parse(Int64, result["__bigint__"])
    elseif result isa Vector
        return [unmarshal_result(r) for r in result]
    elseif result isa AbstractDict
        return Dict(k => unmarshal_result(v) for (k, v) in result)
    elseif result isa AbstractString
        # Handle special float values from JSON serialization
        result == "__Inf__" && return Inf
        result == "__-Inf__" && return -Inf
        result == "__NaN__" && return NaN
        result == "__-0__" && return -0.0   # JSON writes -0 as 0; the sign is part of the value
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
                               imports::Dict, args...;
                               source_map::Union{Nothing,String}=nothing)
    js_args = join(map(arg -> format_js_arg(arg), args), ", ")
    status, val = WasmRunner.run_wasm_single(wasm_bytes, func_name, js_args;
                                             import_js = build_imports_js(imports),
                                             source_map = source_map)
    (status === :trap || status === :error) && error("Wasm execution failed: $(val)")
    return unmarshal_result(val)
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

        # 5. Verify (bit-exact: 0.0 and -0.0 differ, NaN is NaN)
        @test isequal(actual, expected)
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
        @test actual == $(esc(expected))
    end
end

# ============================================================================
# The export boundary, the host's
# ============================================================================

# a module as wasm-tools prints it, its name section stripped so every index is a number
_printed_lines(mod::WasmTarget.WasmModule)::Vector{String} =
    String[strip(l) for l in split(read(pipeline(pipeline(`wasm-tools strip --all`;
        stdin=IOBuffer(WasmTarget.to_bytes(mod))), `wasm-tools print`), String), '\n')]

"""
    unsaved_host_import_calls(mod) -> Int

The calls of a host-declared import in `mod` that do not sit directly between the save of the top
at the open import's slot and its restore after a normal return (emit_direct_call!): the call of
the module's one save helper, `import_tops save`, directly before, and `global.get \$import_tops;
global.get \$host_imports_open; array.get; global.set \$exc_top` directly after. The premise of the
export boundary's claim (dev/formal/ExceptionStack.tla ImportCall and ImportReturn): an unsaved
call leaves a re-entrant export to take a stale top, and an unrestored one leaves its caller the
callee's. Which imports are host-declared is the compiler's own rule (_is_host_declared_import).
Read from the module's code as wasm-tools prints it (L156).
"""
function unsaved_host_import_calls(mod::WasmTarget.WasmModule)::Int
    local funcs = [imp for imp in mod.imports if imp.kind == 0x00]
    local host = Set(i - 1 for (i, imp) in enumerate(funcs) if WasmTarget._is_host_declared_import(imp))
    local count = WasmTarget.global_named(mod, "\$host_imports_open")
    local tops = WasmTarget.global_named(mod, "\$import_tops")
    local top = WasmTarget.global_named(mod, "\$exc_top")
    local save = findfirst(f -> f.name == "import_tops save", mod.functions)
    local lines = _printed_lines(mod)
    local n = 0
    for (k, l) in enumerate(lines)
        local c = match(r"^call (\d+)$", l)
        (c !== nothing && parse(Int, c.captures[1]) in host) || continue
        local saved = save !== nothing && k > 1 && lines[k-1] == "call $(length(funcs) + save - 1)"
        local restored = tops !== nothing && count !== nothing && top !== nothing && k + 4 <= length(lines) &&
            lines[k+1:k+4] == ["global.get $tops", "global.get $count",
                               "array.get $(mod.globals[tops + 1].valtype.type_idx)", "global.set $top"]
        (saved && restored) || (n += 1)
    end
    return n
end

"""
    wasm_boundary_sites(mod) -> Int

The places where `mod`'s wasm code takes part of the export boundary the host owns: a `global.set`
of the imported count `\$host_imports_open` (only the glue's finally writes it, host_glue_js), and in
each export entry (a function named "<name> (export)") a `try`, a `try_table` or a declared local
(the entry is a prologue that passes every escape untouched, emit_export_entry!). Read from the
module's code as wasm-tools prints it (L156).
"""
function wasm_boundary_sites(mod::WasmTarget.WasmModule)::Int
    local count = WasmTarget.global_named(mod, "\$host_imports_open")
    local entries = Set(WasmTarget.num_imported_funcs(mod) + i - 1 for (i, f) in enumerate(mod.functions)
                        if endswith(f.name, " (export)"))
    local n = 0
    local in_entry = false
    for l in _printed_lines(mod)
        local f = match(r"^\(func \(;(\d+);\)", l)
        if f !== nothing
            in_entry = parse(Int, f.captures[1]) in entries
        elseif startswith(l, "(") && !startswith(l, "(local")
            in_entry = false
        end
        count !== nothing && l == "global.set $count" && (n += 1)
        in_entry && (startswith(l, "(local") || occursin(r"^try(_table)?\b", l)) && (n += 1)
    end
    return n
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
        const importObject = $(WasmTarget.host_runtime_js());
        const wasmModule = await WebAssembly.instantiate(bytes, ($(WasmTarget.host_glue_js()))(importObject), { builtins: ['js-string'] });
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
        node_cmd = `$NODE $js_path`
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
function compare_julia_wasm(f, args...; optimize::Bool=false)
    # 1. Run natively in Julia to get expected result
    expected = f(args...)

    # 2. Compile to Wasm (with optional binaryen optimization), with its source map: a trap
    #    names the Julia statement of every wasm frame it unwound through
    arg_types = Tuple(map(typeof, args))
    bytes, source_map = WasmTarget.compile_with_sourcemap(f, arg_types; optimize=optimize)

    # 3. Run in Node.js to get actual result (no host imports)
    func_name = string(nameof(f))
    imports = Dict{String,Any}()
    actual = try
        run_wasm_with_imports(bytes, func_name, imports, args...; source_map=source_map)
    catch e
        # a result the host cannot read (an Any result, a GC reference) is read inside the
        # module, through a typeassert to the native result's type
        (e isa ErrorException && occursin("unserializable result", e.msg)) || rethrow()
        w = typed_result_wrapper(f, typeof(expected))
        w === nothing && rethrow()
        wbytes, wmap = WasmTarget.compile_with_sourcemap(w, arg_types; optimize=optimize)
        run_wasm_with_imports(wbytes, string(nameof(w)), imports, args...; source_map=wmap)
    end

    # 4. Compare, bit-exact: 0.0 and -0.0 differ, NaN is NaN

    return (pass=isequal(expected, actual), expected=expected, actual=actual, wasm_size=length(bytes))
end

"""
    typed_result_wrapper(f, T) -> Union{Function, Nothing}

A function computing `f(args...)::T`, for reading a result the host cannot serialize (an Any
result is a GC reference): the typeassert unboxes it inside the module, to a value the host
reads. `nothing` when `T` is not a concrete value type the host reads (a number, Bool, Char).
"""
function typed_result_wrapper(@nospecialize(f), @nospecialize(T))
    (T <: Union{Number, Bool, Char} && isconcretetype(T)) || return nothing
    name = gensym(:typed_result)
    return Core.eval(@__MODULE__, :($name(args...) = $f(args...)::$T))
end

"""
    compare_julia_wasm_both(f, args...) -> NamedTuple

Test `f` with BOTH optimize=false (raw) and optimize=true (binaryen).
Returns `(raw_pass, opt_pass, pass, raw_size, opt_size)`.
`pass` is true only if BOTH raw and optimized produce correct results.
"""
function compare_julia_wasm_both(f, args...)
    raw = compare_julia_wasm(f, args...; optimize=false)
    opt = compare_julia_wasm(f, args...; optimize=true)
    return (pass=raw.pass && opt.pass, raw_pass=raw.pass, opt_pass=opt.pass,
            expected=raw.expected, raw_actual=raw.actual, opt_actual=opt.actual,
            raw_size=raw.wasm_size, opt_size=opt.wasm_size)
end

"""
    compare_julia_wasm_vec_both(f, args...) -> NamedTuple

Test vector function `f` with BOTH optimize=false and optimize=true.
Returns `(raw_pass, opt_pass, pass, raw_size, opt_size)`.
"""
function compare_julia_wasm_vec_both(f, args...)
    raw = compare_julia_wasm_vec(f, deepcopy(args)...; optimize=false)
    opt = compare_julia_wasm_vec(f, deepcopy(args)...; optimize=true)
    return (pass=raw.pass && opt.pass, raw_pass=raw.pass, opt_pass=opt.pass,
            expected=raw.expected, raw_actual=raw.actual, opt_actual=opt.actual,
            raw_size=raw.wasm_size, opt_size=opt.wasm_size)
end

"""
    test_type_matrix(f, types_and_args::Vector) -> Vector{NamedTuple}

Test a scalar function across multiple type signatures, both raw and binaryen-optimized.
Each element is a tuple of arguments to pass to `f` (the types are inferred).

Returns a vector of `(args, raw_pass, opt_pass, pass, raw_size, opt_size, error)`.

# Example
```julia
results = test_type_matrix(abs, [
    (Int32(-5),),
    (Int64(-5),),
    (Float32(-3.14f0),),
    (Float64(-3.14),),
])
for r in results
    println("\$(typeof.(r.args)): raw=\$(r.raw_pass) opt=\$(r.opt_pass)")
end
```
"""
function test_type_matrix(f, types_and_args::Vector)
    results = NamedTuple[]
    for args_tuple in types_and_args
        args = args_tuple isa Tuple ? args_tuple : (args_tuple,)
        try
            r = compare_julia_wasm_both(f, args...)
            push!(results, (args=args, raw_pass=r.raw_pass, opt_pass=r.opt_pass,
                           pass=r.pass, raw_size=r.raw_size, opt_size=r.opt_size, error=nothing))
        catch e
            push!(results, (args=args, raw_pass=false, opt_pass=false,
                           pass=false, raw_size=0, opt_size=0, error=sprint(showerror, e)))
        end
    end
    return results
end

"""
    test_type_matrix_vec(f, types_and_args::Vector) -> Vector{NamedTuple}

Like test_type_matrix but for vector functions using the bridge harness.
Each element is a tuple of arguments (including Vector args) to pass to `f`.

# Example
```julia
f_sort(v::Vector{Int64})::Vector{Int64} = sort(v)
results = test_type_matrix_vec(f_sort, [
    (Int64[3, 1, 2],),
])
```
"""
function test_type_matrix_vec(f, types_and_args::Vector)
    results = NamedTuple[]
    for args_tuple in types_and_args
        args = args_tuple isa Tuple ? args_tuple : (args_tuple,)
        try
            r = compare_julia_wasm_vec_both(f, args...)
            push!(results, (args=args, raw_pass=r.raw_pass, opt_pass=r.opt_pass,
                           pass=r.pass, raw_size=r.raw_size, opt_size=r.opt_size, error=nothing))
        catch e
            push!(results, (args=args, raw_pass=false, opt_pass=false,
                           pass=false, raw_size=0, opt_size=0, error=sprint(showerror, e)))
        end
    end
    return results
end

"""
    print_type_matrix(f_name::String, results::Vector)

Pretty-print a type matrix result table.
"""
function print_type_matrix(f_name::String, results::Vector)
    println("\n  Type Matrix: $f_name")
    println("  ", "-"^70)
    for r in results
        types_str = join([string(typeof(a)) for a in r.args], ", ")
        status = r.pass ? "✓" : (r.raw_pass ? "✓raw ✗opt" : "✗")
        size_str = r.raw_size > 0 ? "$(r.raw_size)→$(r.opt_size)" : "N/A"
        err_str = r.error !== nothing ? " ERR: $(first(r.error, 60))" : ""
        println("  $status  ($types_str)  [$size_str]$err_str")
    end
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
        push!(results, (args=args, expected=r.expected, actual=r.actual, pass=r.pass))
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

    # 2. Run in Node.js (no host imports)
    func_name = string(nameof(f))
    imports = Dict{String,Any}()
    actual = run_wasm_with_imports(bytes, func_name, imports, args...)

    # 3. Compare against pre-computed expected value

    return (pass=isequal(expected, actual), expected=expected, actual=actual)
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
        push!(results, (args=args, expected=expected, actual=r.actual, pass=r.pass))
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
function generate_ground_truth(name::String, f, inputs::Vector; overwrite::Bool=false,
                               dir::AbstractString=GROUND_TRUTH_DIR)
    mkpath(dir)
    path = joinpath(dir, "$name.json")
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
function load_ground_truth(name::String; dir::AbstractString=GROUND_TRUTH_DIR)
    path = joinpath(dir, "$name.json")
    if !isfile(path)
        error("Ground truth '$name' not found at $path. Run generate_ground_truth first.")
    end
    return JSON.parsefile(path)
end

"""
    compare_against_ground_truth(name::String, f) -> Vector{NamedTuple}

Compile `f` to Wasm and compare its output against saved ground truth snapshots.
Returns a vector of `(args, expected, actual, pass)` named tuples.

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
function compare_against_ground_truth(name::String, f; dir::AbstractString=GROUND_TRUTH_DIR)
    snapshot = load_ground_truth(name; dir=dir)
    entries = snapshot["entries"]

    results = NamedTuple[]
    for entry in entries
        args_raw = entry["args"]
        expected = entry["expected"]

        # Convert JSON arrays back to typed tuples
        # JSON stores numbers as Int64/Float64, so convert to match original types
        args = Tuple(Int32(a) for a in args_raw)

        r = compare_julia_wasm_manual(f, args, expected isa Integer ? Int32(expected) : expected)
        push!(results, (args=args, expected=expected, actual=r.actual, pass=r.pass))
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
function _generate_bridge_driver(func_name, args, arg_types, return_vec_eltype)
    # Driver body for the persistent runner pool: `bytes` is injected, and we
    # RETURN a 1-element results array ([{ok:…}] | [{trap:"msg"}]) instead of
    # reading a file and console.logging.
    lines = String[]
    push!(lines, "  try {")
    push!(lines, "    const importObject = $(WasmTarget.host_runtime_js());")
    push!(lines, "    const wasmModule = await WebAssembly.instantiate(bytes, ($(WasmTarget.host_glue_js()))(importObject), { builtins: ['js-string'] });")
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

    # Extract result → out, then `return [{ok: out}]`
    if return_vec_eltype === Int64
        push!(lines, "    const len = Number(e._bv_i64_len(result));")
        push!(lines, "    const out = [];")
        push!(lines, "    for (let i = 0; i < len; i++) out.push(e._bv_i64_get(result, BigInt(i+1)).toString());")
        push!(lines, "    return [{ ok: out }];")
    elseif return_vec_eltype === Float64
        push!(lines, "    const len = Number(e._bv_f64_len(result));")
        push!(lines, "    const out = [];")
        push!(lines, "    for (let i = 0; i < len; i++) {")
        push!(lines, "      const v = e._bv_f64_get(result, BigInt(i+1));")
        push!(lines, "      if (Number.isNaN(v)) out.push('NaN');")
        push!(lines, "      else if (v === Infinity) out.push('Inf');")
        push!(lines, "      else if (v === -Infinity) out.push('-Inf');")
        push!(lines, "      else if (Object.is(v, -0)) out.push('__-0__');")
        push!(lines, "      else out.push(v);")
        push!(lines, "    }")
        push!(lines, "    return [{ ok: out }];")
    else
        # Scalar result
        push!(lines, """    const enc = (key, value) => {
      if (typeof value === 'bigint') return { __bigint__: value.toString() };
      if (typeof value === 'number') {
        if (value === Infinity) return "__Inf__";
        if (value === -Infinity) return "__-Inf__";
        if (Number.isNaN(value)) return "__NaN__";
        if (Object.is(value, -0)) return "__-0__";
      }
      return value;
    };""")
        push!(lines, "    return [{ ok: JSON.parse(JSON.stringify(result, enc)) }];")
    end

    push!(lines, "  } catch (err) {")
    push!(lines, "    return [{ trap: String(err && err.message || err) }];")
    push!(lines, "  }")

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
function compare_julia_wasm_vec(f, args...; optimize::Bool=false)
    # Deep-copy args before Julia reference call — mutating functions (push!, pop!, etc.)
    # modify the input Vector in-place, which would corrupt the args used later for the
    # WASM bridge if we don't copy first.
    args_for_wasm = deepcopy(args)

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

    # 4. Compile (with optional binaryen optimization)
    bytes = WasmTarget.compile_multi(func_list; optimize=optimize)

    # 5. Generate bridge-aware driver and run via the persistent pool
    func_name = string(nameof(f))
    driver = _generate_bridge_driver(func_name, args_for_wasm, arg_types, return_vec_eltype)

    # 6. Execute
    let
        status, results = WasmRunner.run_driver_batch(bytes, driver; ninputs=1)
        if status === :error
            return (pass=false, expected=expected, actual="WASM_ERROR", wasm_size=length(bytes))
        end
        r = results[1]
        if haskey(r, "trap")
            return (pass=false, expected=expected, actual="WASM_ERROR", wasm_size=length(bytes))
        end
        actual = unmarshal_result(r["ok"])

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
                   all(i -> isequal(actual_nums[i], expected_nums[i]), 1:length(expected_nums))
        else
            pass = isequal(expected, actual)
        end

        return (pass=pass, expected=expected, actual=actual, wasm_size=length(bytes))
    end
end

# ============================================================================
# Sidecar differential comparison (native linear-memory module,
# dev/PARITY_MASTER.md, Scope)
# ============================================================================

"""
    _generate_sidecar_bridge_driver(sidecar_bytes, sidecar_module_name, func_name, args, arg_types) -> String

Driver body for the persistent runner pool, sidecar-aware: embeds
`sidecar_bytes` as a hex literal directly in the generated JS (the pool's
`bytes` channel — `run_driver_batch(main_bytes, src)` — only carries ONE
binary, the main GC module; the sidecar rides inline in `src` instead).
Instantiates the sidecar FIRST with no imports of its own, passes its
exports as `importObject[sidecar_module_name]`, THEN instantiates `bytes`
(the main module) against that import object — the two-module HOST-linking
shape `add_import!`/`import_stubs` target, not `wasm-merge` (L98's road is
for two WT-compiled GC binaries sharing one object model; the sidecar owns
its own linear memory and shares no object model with the caller at all).

Only scalar Float64 args and Vector{Float64} args are supported (daxpy's
signature); Vector{Float64} args/results marshal through the `_bv_f64_*`
bridge, which must already be compiled into the main module.
"""
function _generate_sidecar_bridge_driver(sidecar_bytes::Vector{UInt8}, sidecar_module_name::AbstractString,
                                          func_name::AbstractString, args, arg_types)
    lines = String[]
    push!(lines, "  try {")
    push!(lines, "    const sidecarHex = \"$(WasmRunner.enc_wasm(sidecar_bytes))\";")
    push!(lines, "    const sidecarBytes = Buffer.from(sidecarHex, 'hex');")
    push!(lines, "    const sidecarInst = await WebAssembly.instantiate(sidecarBytes, {});")
    push!(lines, "    const importObject = $(WasmTarget.host_runtime_js());")
    push!(lines, "    importObject['$(sidecar_module_name)'] = sidecarInst.instance.exports;")
    push!(lines, "    const wasmModule = await WebAssembly.instantiate(bytes, ($(WasmTarget.host_glue_js()))(importObject), { builtins: ['js-string'] });")
    push!(lines, "    const e = wasmModule.instance.exports;")

    call_args = String[]
    for (i, (arg, T)) in enumerate(zip(args, arg_types))
        if T === Vector{Float64}
            v = arg::Vector{Float64}
            push!(lines, "    const v$(i) = e._bv_f64_new($(length(v))n);")
            for (j, val) in enumerate(v)
                js_val = isnan(val) ? "NaN" : isinf(val) ? (val > 0 ? "Infinity" : "-Infinity") : string(val)
                push!(lines, "    e['_bv_f64_set!'](v$(i), $(j)n, $(js_val));")
            end
            push!(call_args, "v$(i)")
        elseif T === Float64
            js_val = isnan(arg) ? "NaN" : isinf(arg) ? (arg > 0 ? "Infinity" : "-Infinity") : string(arg)
            push!(call_args, js_val)
        else
            error("_generate_sidecar_bridge_driver: unsupported arg type $T")
        end
    end

    push!(lines, "    const result = e['$(func_name)']($(join(call_args, ", ")));")
    push!(lines, "    const len = Number(e._bv_f64_len(result));")
    push!(lines, "    const out = [];")
    push!(lines, "    for (let i = 0; i < len; i++) {")
    push!(lines, "      const v = e._bv_f64_get(result, BigInt(i+1));")
    push!(lines, "      if (Number.isNaN(v)) out.push('NaN');")
    push!(lines, "      else if (v === Infinity) out.push('Inf');")
    push!(lines, "      else if (v === -Infinity) out.push('-Inf');")
    push!(lines, "      else if (Object.is(v, -0)) out.push('__-0__');")
    push!(lines, "      else out.push(v);")
    push!(lines, "    }")
    push!(lines, "    return [{ ok: out }];")
    push!(lines, "  } catch (err) {")
    push!(lines, "    return [{ trap: String(err && err.message || err) }];")
    push!(lines, "  }")
    return join(lines, "\n")
end

"""
    compare_sidecar_wasm_vec(main_bytes, sidecar_bytes, sidecar_module_name,
                              func_name, expected, args...) -> NamedTuple

Sidecar-aware variant of [`compare_julia_wasm_vec`](@ref) for the two-module
host-linking pattern (`parity(functions.dart:90 wasm:import/export;
translator.dart:213 ffiMemory)`). `expected` is a precomputed oracle — NEVER
derived by calling `func_name`'s Julia function natively, since its import
stub calls are `Base.inferencebarrier`/`Base.donotdelete` no-ops off the wasm
boundary — compared element-wise (bit-exact, `isequal`) against the
`Vector{Float64}` wasm result of calling `func_name(args...)` in the
compiled `main_bytes` module, with the `sidecar_bytes` module instantiated
first and wired in as `importObject[sidecar_module_name]`.

Returns `(pass, expected, actual, wasm_size)`, matching every other
`compare_julia_wasm_*` helper's shape.
"""
function compare_sidecar_wasm_vec(main_bytes::Vector{UInt8}, sidecar_bytes::Vector{UInt8},
                                   sidecar_module_name::AbstractString, func_name::AbstractString,
                                   expected::Vector{Float64}, args...)
    arg_types = map(typeof, args)
    driver = _generate_sidecar_bridge_driver(sidecar_bytes, sidecar_module_name, func_name, args, arg_types)
    status, results = WasmRunner.run_driver_batch(main_bytes, driver; ninputs=1)
    if status === :error
        return (pass=false, expected=expected, actual="WASM_ERROR", wasm_size=length(main_bytes))
    end
    r = results[1]
    if haskey(r, "trap")
        return (pass=false, expected=expected, actual="WASM_ERROR", wasm_size=length(main_bytes))
    end
    actual_raw = unmarshal_result(r["ok"])
    actual = actual_raw isa Vector ? [_parse_f64(x) for x in actual_raw] : actual_raw
    pass = actual isa Vector && length(actual) == length(expected) &&
           all(i -> isequal(actual[i], expected[i]), 1:length(expected))
    return (pass=pass, expected=expected, actual=actual, wasm_size=length(main_bytes))
end

"""
    compare_julia_wasm_bridge(f, args...; rettype=nothing, optimize=false) -> NamedTuple

Robust differential check for `f` over scalar args (Int/Float/Bool/Char) whose
RETURN is ANY bridge-supported type — `String`, structs, `Vector`, tuples, nested
combos — not just the scalars/`_bv_` vectors `compare_julia_wasm`/`_vec` handle.

Uses the in-package bit-exact `WasmTarget.Bridge` (`descriptor` → `WALK_JS` →
`tree_matches`), i.e. the SAME transport Snapshot.jl and the differential fuzzer
use. This is what lets real island cells (which return strings/HTML/structs) be
exercised directly in WT's own unit suite instead of only in downstream CI: the
plain harness `JSON.stringify`s a WasmGC array/struct ref to `"undefined"`, while
the bridge walks it field-by-field.

Returns `(pass, expected, actual, wasm_size)`. A native throw is matched by a wasm trap.
"""
function compare_julia_wasm_bridge(f, args...; rettype=nothing, name=nothing, optimize::Bool=false)
    arg_types = map(typeof, args)
    nat = try (true, f(args...)) catch e; (false, e) end
    rt = rettype === nothing ?
        Core.Compiler.widenconst(Base.code_typed(f, Tuple(arg_types))[1][2]) : rettype
    rt === Union{} && (rt = Int64)
    dp = WasmTarget.Bridge.descriptor(rt)
    dp === nothing && error("compare_julia_wasm_bridge: return type $rt is outside the bridge universe")
    desc, accs = dp
    # Anonymous fns (e.g. PI island cells extracted as `function (n::Int64,) … end`)
    # have a gensym nameof; callers pass an explicit `name` for the wasm export.
    fname = name === nothing ? string(nameof(f)) : name
    func_list = Any[(f, Tuple(arg_types), fname)]
    append!(func_list, accs)
    bytes = WasmTarget.compile_multi(func_list; validate=true, optimize=optimize)
    inputs_js = "[[" * join((format_js_arg(a) for a in args), ", ") * "]]"
    driver = """
    const inputs = $(inputs_js);
    const importObject = $(WasmTarget.host_runtime_js());
    const { instance } = await WebAssembly.instantiate(bytes, ($(WasmTarget.host_glue_js()))(importObject), { builtins: ['js-string'] });
    const ex = instance.exports;
    const f = ex['$fname'];
    const desc = $(JSON.json(desc));
    $(WasmTarget.Bridge.WALK_JS)
    return inputs.map(args => {
        try { return { ok: walk(desc, f(...args)) }; }
        catch (e) { return { trap: String(e && e.message || e) }; }
    });
    """
    status, results = WasmRunner.run_driver_batch(bytes, driver; ninputs=1)
    if status === :error
        return (pass = !nat[1], expected=(nat[1] ? nat[2] : :throw),
                actual="WASM_ERROR", wasm_size=length(bytes))
    end
    r = results[1]
    if haskey(r, "trap")
        return (pass = !nat[1], expected=(nat[1] ? nat[2] : :throw),
                actual="trap: " * string(get(r, "trap", "?")), wasm_size=length(bytes))
    end
    walked = r["ok"]
    pass = nat[1] && WasmTarget.Bridge.tree_matches(desc, nat[2], walked)
    return (pass=pass, expected=(nat[1] ? nat[2] : :throw),
            actual=walked, wasm_size=length(bytes))
end

"""
    compare_julia_wasm_bridge_args(f, args...; rettype=nothing, name=nothing) -> NamedTuple

Like `compare_julia_wasm_bridge`, but every ARGUMENT also crosses the bit-exact
in-package bridge (`arg_descriptor` + `value_to_tree` + `BUILD_JS`) — not just the
return. This lets island cells whose `@bind` inputs are non-scalar (`String`,
`Bool`, `Char`, `Symbol`, structs, `Vector`/`Tuple`/`NamedTuple`) be exercised in
WT's unit suite. (Port of the fuzzer's `bridge_run_args`, return-compare only —
PI island cells are pure functions of their bonds, so no mutable-arg re-reads.)
Returns `(pass, expected, actual, wasm_size)`; native throw ⇒ wasm trap.
"""
function compare_julia_wasm_bridge_args(f, args...; rettype=nothing, name=nothing, optimize::Bool=false)
    arg_types = map(typeof, args)
    nat = try (true, f(args...)) catch e; (false, e) end
    rt = rettype === nothing ?
        Core.Compiler.widenconst(Base.code_typed(f, Tuple(arg_types))[1][2]) : rettype
    rt === Union{} && (rt = Int64)
    rp = WasmTarget.Bridge.descriptor(rt)
    rp === nothing && error("compare_julia_wasm_bridge_args: return type $rt outside the bridge universe")
    rdesc, raccs = rp
    accs = Any[]; names = Set{String}()
    for (fn_, at_, nm_) in raccs
        WasmTarget.Bridge._acc!(accs, names, nm_, fn_, at_)
    end
    adescs = Any[]
    for T in arg_types
        ap = WasmTarget.Bridge.arg_descriptor(T)
        ap === nothing && error("compare_julia_wasm_bridge_args: arg type $T outside the bridge universe")
        ad, aaccs = ap
        for (fn_, at_, nm_) in aaccs
            WasmTarget.Bridge._acc!(accs, names, nm_, fn_, at_)
        end
        push!(adescs, ad)
    end
    fname = name === nothing ? string(nameof(f)) : name
    funcs = Any[(f, Tuple(arg_types), fname)]
    append!(funcs, accs)
    bytes = WasmTarget.compile_multi(funcs; validate=true, optimize=optimize)
    enc = Any[WasmTarget.Bridge.value_to_tree(adescs[j], args[j]) for j in eachindex(adescs)]
    driver = """
    const importObject = $(WasmTarget.host_runtime_js());
    const { instance } = await WebAssembly.instantiate(bytes, ($(WasmTarget.host_glue_js()))(importObject), { builtins: ['js-string'] });
    const ex = instance.exports;
    const f = ex['$fname'];
    const adescs = $(JSON.json(adescs));
    const rdesc = $(JSON.json(rdesc));
    const input = $(JSON.json(enc));
    $(WasmTarget.Bridge.WALK_JS)
    $(WasmTarget.Bridge.BUILD_JS)
    try {
        const args = input.map((t, j) => build(adescs[j], t));
        return [{ ok: walk(rdesc, f(...args)) }];
    } catch (e) { return [{ trap: String(e && e.message || e) }]; }
    """
    status, results = WasmRunner.run_driver_batch(bytes, driver; ninputs=1)
    if status === :error
        return (pass = !nat[1], expected=(nat[1] ? nat[2] : :throw),
                actual="WASM_ERROR", wasm_size=length(bytes))
    end
    r = results[1]
    if haskey(r, "trap")
        return (pass = !nat[1], expected=(nat[1] ? nat[2] : :throw),
                actual="trap: " * string(get(r, "trap", "?")), wasm_size=length(bytes))
    end
    walked = r["ok"]
    pass = nat[1] && WasmTarget.Bridge.tree_matches(rdesc, nat[2], walked)
    return (pass=pass, expected=(nat[1] ? nat[2] : :throw),
            actual=walked, wasm_size=length(bytes))
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

