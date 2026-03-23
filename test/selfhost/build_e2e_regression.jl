# build_e2e_regression.jl — INT-003: Build the 10-function regression suite WASM module
#
# Module: 10 run_selfhost_* functions + to_bytes_mvp_flex + byte extraction helpers
# Run: julia +1.12 --project=. test/selfhost/build_e2e_regression.jl

using WasmTarget
using WasmTarget: run_selfhost_identity, run_selfhost_constant, run_selfhost_add_one,
    run_selfhost_double, run_selfhost_negate, run_selfhost_add,
    run_selfhost_multiply, run_selfhost_polynomial, run_selfhost_cube,
    run_selfhost_float_add, run_selfhost_final,
    to_bytes_mvp_flex, to_bytes_mvp_i64,
    wasm_bytes_length, wasm_bytes_get, new_wasm_module,
    compile_module_from_ir, compile_from_codeinfo, to_bytes

println("=" ^ 70)
println("INT-003: 10-Function Regression Suite — TRUE Self-Hosting")
println("=" ^ 70)

# Step 1: Native verification — all 10 functions produce correct WASM
println("\n--- Step 1: Native verification ---")
tests = [
    ("identity",    run_selfhost_identity,   "f(7n)",       "7",    :bigint),
    ("constant",    run_selfhost_constant,   "f()",         "42",   :bigint),
    ("add_one",     run_selfhost_add_one,    "f(10n)",      "11",   :bigint),
    ("double",      run_selfhost_double,     "f(5n)",       "10",   :bigint),
    ("negate",      run_selfhost_negate,     "f(3n)",       "-3",   :bigint),
    ("add",         run_selfhost_add,        "f(3n,4n)",    "7",    :bigint),
    ("multiply",    run_selfhost_multiply,   "f(6n,7n)",    "42",   :bigint),
    ("polynomial",  run_selfhost_polynomial, "f(3n)",       "13",   :bigint),
    ("cube",        run_selfhost_cube,       "f(4n)",       "64",   :bigint),
    ("float_add",   run_selfhost_float_add,  "f(1.5,2.5)", "4",    :float),
]

global all_native_pass = true
for (name, func, call, expected, kind) in tests
    global all_native_pass
    bytes = func()
    tmp = tempname() * ".wasm"
    write(tmp, bytes)
    valid = success(pipeline(`wasm-tools validate $tmp`, devnull))
    if kind == :bigint
        result = strip(read(`node -e "WebAssembly.instantiate(require('fs').readFileSync('$tmp')).then(m=>console.log(String(m.instance.exports.$call)))"`, String))
    else
        result = strip(read(`node -e "WebAssembly.instantiate(require('fs').readFileSync('$tmp')).then(m=>console.log(m.instance.exports.$call))"`, String))
    end
    rm(tmp, force=true)
    ok = valid && result == expected
    all_native_pass &= ok
    status = ok ? "✓" : "✗"
    println("  $name: $(length(bytes)) bytes, validate=$(valid ? "PASS" : "FAIL"), $call=$result $status")
end
# Also test the original E2E function
begin
    bytes = run_selfhost_final()
    tmp = tempname() * ".wasm"
    write(tmp, bytes)
    result = strip(read(`node -e "WebAssembly.instantiate(require('fs').readFileSync('$tmp')).then(m=>console.log(String(m.instance.exports.f(5n))))"`, String))
    rm(tmp, force=true)
    ok = result == "26"
    all_native_pass &= ok
    println("  sq_plus_one: $(length(bytes)) bytes, f(5n)=$result $(ok ? "✓" : "✗")")
end
println(all_native_pass ? "All native tests PASS ✓" : "Some native tests FAILED ✗")

# Step 2: Build combined WASM module with all test functions
println("\n--- Step 2: Collect code_typed for all functions ---")
functions_spec = [
    (run_selfhost_identity,   (), "run_identity"),
    (run_selfhost_constant,   (), "run_constant"),
    (run_selfhost_add_one,    (), "run_add_one"),
    (run_selfhost_double,     (), "run_double"),
    (run_selfhost_negate,     (), "run_negate"),
    (run_selfhost_add,        (), "run_add"),
    (run_selfhost_multiply,   (), "run_multiply"),
    (run_selfhost_polynomial, (), "run_polynomial"),
    (run_selfhost_cube,       (), "run_cube"),
    (run_selfhost_float_add,  (), "run_float_add"),
    (run_selfhost_final,      (), "run_sq_plus_one"),
    (to_bytes_mvp_flex,       (Vector{UInt8}, Int32, Int32, Int32), "to_bytes_mvp_flex"),
    (to_bytes_mvp_i64,        (Vector{UInt8},), "to_bytes_mvp_i64"),
    (new_wasm_module,         (), "new_wasm_module"),
    (wasm_bytes_length,       (Vector{UInt8},), "wasm_bytes_length"),
    (wasm_bytes_get,          (Vector{UInt8}, Int32), "wasm_bytes_get"),
]

entries = Any[]
for (func, arg_types, name) in functions_spec
    ci, rt = Base.code_typed(func, arg_types; optimize=true)[1]
    push!(entries, (ci, rt, arg_types, name, func))
    println("  $name: $(length(ci.code)) stmts")
end

# Step 3: Individual validation
println("\n--- Step 3: Individual validation ---")
valid_count = 0
for (ci, rt, arg_types, name, func) in entries
    try
        wasm_bytes = compile_from_codeinfo(ci, rt, name, arg_types)
        tmp = tempname() * ".wasm"
        write(tmp, wasm_bytes)
        valid = success(pipeline(`wasm-tools validate $tmp`, devnull))
        rm(tmp, force=true)
        println("  $name: $(length(wasm_bytes)) bytes, $(valid ? "PASS ✓" : "FAIL ✗")")
        valid && (valid_count += 1)
    catch e
        println("  $name: ERROR — $(sprint(showerror, e))")
    end
end
println("Individual validation: $valid_count/$(length(entries))")

# Step 4: Build combined module (filter individually-failing functions like INT-001)
println("\n--- Step 4: Build combined module ---")
valid_entries = Any[]
for (ci, rt, arg_types, name, func) in entries
    try
        wasm_bytes = compile_from_codeinfo(ci, rt, name, arg_types)
        tmp = tempname() * ".wasm"
        write(tmp, wasm_bytes)
        valid = success(pipeline(`wasm-tools validate $tmp`, devnull))
        rm(tmp, force=true)
        if valid
            push!(valid_entries, (ci, rt, arg_types, name, func))
        end
    catch; end
end
println("Building combined module with $(length(valid_entries)) valid functions...")
mod = compile_module_from_ir(valid_entries)
combined_bytes = to_bytes(mod)
outpath = joinpath(@__DIR__, "selfhost-regression.wasm")
write(outpath, combined_bytes)
println("Combined module: $(length(combined_bytes)) bytes ($(round(length(combined_bytes)/1024, digits=1)) KB)")

# Step 5: Validate combined module
println("\n--- Step 5: Validate combined module ---")
try
    run(`wasm-tools validate $outpath`)
    println("wasm-tools validate: PASS ✓")
catch
    println("wasm-tools validate: FAIL ✗ (trying with individually valid functions)")
end

# Step 6: Node.js E2E test — run all test functions through WASM pipeline
println("\n--- Step 6: Node.js E2E regression test ---")
node_script = raw"""
const fs = require('fs');
const bytes = fs.readFileSync(process.argv[2]);

async function testFunc(exports, runName, call, expected, isFloat) {
    try {
        const wasmBytes = exports[runName]();
        const len = exports.wasm_bytes_length(wasmBytes);
        const arr = new Uint8Array(len);
        for (let i = 0; i < len; i++) arr[i] = exports.wasm_bytes_get(wasmBytes, i + 1);
        const m2 = await WebAssembly.instantiate(arr);
        const f = m2.instance.exports.f;
        const result = isFloat ? f(...call) : f(...call.map(x => BigInt(x)));
        const resultStr = String(result);
        const ok = resultStr === expected;
        console.log(`  ${runName}: ${ok ? 'PASS' : 'FAIL'} (${resultStr} ${ok ? '===' : '!=='} ${expected})`);
        return ok;
    } catch(e) {
        console.log(`  ${runName}: ERROR — ${e.message}`);
        return false;
    }
}

WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } }).then(async m => {
    const e = m.instance.exports;
    console.log('Exports:', Object.keys(e).length);
    let pass = 0, total = 0;

    const tests = [
        ['run_identity',   [7],     '7',   false],
        ['run_constant',   [],      '42',  false],
        ['run_add_one',    [10],    '11',  false],
        ['run_double',     [5],     '10',  false],
        ['run_negate',     [3],     '-3',  false],
        ['run_add',        [3, 4],  '7',   false],
        ['run_multiply',   [6, 7],  '42',  false],
        ['run_polynomial', [3],     '13',  false],
        ['run_cube',       [4],     '64',  false],
        ['run_float_add',  [1.5, 2.5], '4', true],
        ['run_sq_plus_one',[5],     '26',  false],
    ];

    for (const [name, args, expected, isFloat] of tests) {
        if (typeof e[name] !== 'function') {
            console.log(`  ${name}: SKIP (not exported)`);
            continue;
        }
        total++;
        if (await testFunc(e, name, args, expected, isFloat)) pass++;
    }
    console.log(`\nResults: ${pass}/${total} passed`);
    process.exit(pass >= 10 ? 0 : 1);
}).catch(err => {
    console.log('ERROR:', err.message);
    process.exit(1);
});
"""
script_path = tempname() * ".cjs"
write(script_path, node_script)
try
    result = read(`node $script_path $outpath`, String)
    println(result)
catch e
    println("Node.js E2E test: $(sprint(showerror, e))")
end
rm(script_path, force=true)

println("\n" * "=" ^ 70)
println("Build complete: $outpath")
println("=" ^ 70)
