// run_true_selfhost_tests.cjs — INT-003: 10-function TRUE self-hosting regression suite
//
// Tests that 10 different Julia functions compile to valid WASM inside WASM,
// then execute correctly. Each test:
//   1. Calls a run_selfhost_* export (codegen in WASM produces WASM bytes)
//   2. Extracts bytes via wasm_bytes_length/wasm_bytes_get
//   3. WebAssembly.compile on the output bytes
//   4. Calls f() on the compiled module, verifies result
//
// Usage: node scripts/run_true_selfhost_tests.cjs [path-to-regression.wasm]
//        Default: test/selfhost/selfhost-regression.wasm

const fs = require('fs');
const path = require('path');

const wasmPath = process.argv[2] || path.join(__dirname, '..', 'test', 'selfhost', 'selfhost-regression.wasm');

if (!fs.existsSync(wasmPath)) {
    console.error(`WASM file not found: ${wasmPath}`);
    console.error('Run: julia +1.12 --project=. test/selfhost/build_e2e_regression.jl');
    process.exit(1);
}

const bytes = fs.readFileSync(wasmPath);

async function extractAndRun(exports, runName) {
    const wasmRef = exports[runName]();
    const len = exports.wasm_bytes_length(wasmRef);
    const arr = new Uint8Array(len);
    for (let i = 0; i < len; i++) {
        arr[i] = exports.wasm_bytes_get(wasmRef, i + 1);  // 1-based Julia indexing
    }
    return WebAssembly.instantiate(arr);
}

const tests = [
    // [exportName, args (as plain numbers), expected (as string), isFloat]
    ['run_identity',    [7],        '7',   false],
    ['run_constant',    [],         '42',  false],
    ['run_add_one',     [10],       '11',  false],
    ['run_double',      [5],        '10',  false],
    ['run_negate',      [3],        '-3',  false],
    ['run_add',         [3, 4],     '7',   false],
    ['run_multiply',    [6, 7],     '42',  false],
    ['run_polynomial',  [3],        '13',  false],
    ['run_cube',        [4],        '64',  false],
    ['run_float_add',   [1.5, 2.5], '4',   true],
    // Bonus: the original E2E function
    ['run_sq_plus_one', [5],        '26',  false],
];

WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } }).then(async m => {
    const e = m.instance.exports;
    const exportNames = Object.keys(e).filter(k => typeof e[k] === 'function');
    console.log(`Loaded: ${exportNames.length} exports from ${path.basename(wasmPath)}`);
    console.log(`Module size: ${(bytes.length / 1024).toFixed(1)} KB\n`);

    let pass = 0;
    let fail = 0;
    let skip = 0;

    for (const [name, args, expected, isFloat] of tests) {
        if (typeof e[name] !== 'function') {
            console.log(`  SKIP  ${name} (not exported)`);
            skip++;
            continue;
        }

        try {
            const m2 = await extractAndRun(e, name);
            const f = m2.instance.exports.f;
            const callArgs = isFloat ? args : args.map(x => BigInt(x));
            const result = f(...callArgs);
            const resultStr = String(result);
            const ok = resultStr === expected;

            if (ok) {
                console.log(`  PASS  ${name}: f(${args.join(',')}) = ${resultStr}`);
                pass++;
            } else {
                console.log(`  FAIL  ${name}: f(${args.join(',')}) = ${resultStr} (expected ${expected})`);
                fail++;
            }
        } catch (err) {
            console.log(`  FAIL  ${name}: ${err.message}`);
            fail++;
        }
    }

    console.log(`\n${'='.repeat(50)}`);
    console.log(`Results: ${pass} passed, ${fail} failed, ${skip} skipped`);
    console.log(`${'='.repeat(50)}`);

    if (pass >= 10) {
        console.log('\nSUCCESS: TRUE self-hosting regression suite PASSED');
    } else {
        console.log(`\nFAILURE: Only ${pass}/10 required tests passed`);
    }

    process.exit(fail === 0 && pass >= 10 ? 0 : 1);
}).catch(err => {
    console.error('Failed to load WASM module:', err.message);
    process.exit(1);
});
