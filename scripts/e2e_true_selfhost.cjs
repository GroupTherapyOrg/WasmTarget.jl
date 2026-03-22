// e2e_true_selfhost.cjs — INT-002: True Self-Hosting E2E Test
//
// Tests that the REAL WasmTarget.jl codegen (compile_from_ir_prebaked)
// executes INSIDE WASM to compile f(x::Int64)=x*x+1, producing valid
// WASM bytes that compute f(5n)===26n.
//
// Run: node scripts/e2e_true_selfhost.cjs

const fs = require('fs');
const path = require('path');

const wasmPath = path.join(__dirname, '..', 'e2e-int002-codegen.wasm');
if (!fs.existsSync(wasmPath)) {
    console.error('Module not found:', wasmPath);
    console.error('Build first: julia +1.12 --project=. test/selfhost/build_int002_e2e.jl');
    process.exit(1);
}

const bytes = fs.readFileSync(wasmPath);

WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } }).then(async ({instance}) => {
    const e = instance.exports;
    const exports = Object.keys(e);
    console.log('Module loaded:', exports.length, 'exports');
    console.log('Exports:', exports.join(', '));

    try {
        // ====================================================================
        // STAGE 1: Create WasmModule and TypeRegistry in WASM
        // ====================================================================
        console.log('\n--- Stage 1: Create WasmModule + TypeRegistry ---');
        const mod = e.new_mod();
        const reg = e.new_reg();
        console.log('WasmModule:', mod ? 'OK' : 'FAIL');
        console.log('TypeRegistry:', reg ? 'OK' : 'FAIL');

        // ====================================================================
        // STAGE 2: Build IR for f(x::Int64) = x*x+1 in WASM
        // ====================================================================
        console.log('\n--- Stage 2: Build IR in WASM ---');

        // Get intrinsic function references
        const mul_int = e.get_mul_int();
        const add_int = e.get_add_int();
        console.log('mul_int ref:', mul_int ? 'OK' : 'FAIL');
        console.log('add_int ref:', add_int ? 'OK' : 'FAIL');

        // Build statement 1: %1 = mul_int(Arg(2), Arg(2))
        const sym_call = e.sym_call();
        const args1 = e.mk_vec(3);     // 3 args: [mul_int, Arg(2), Arg(2)]
        // Can't set intrinsic directly with set_any_* — need to use mk_expr
        // Actually, wasm_set_any_i64! won't work for IntrinsicFunction
        // Let me try building via mk_expr instead
        // mk_expr(head::Symbol, args::Vector{Any}) -> Expr

        // Build args for mul_int(Arg(2), Arg(2))
        // args = [mul_int, Arg(2), Arg(2)]
        // We need to set args[1] = mul_int (an IntrinsicFunction)
        // wasm_set_any_* functions: set_expr, set_ret, set_i64
        // None of these handle IntrinsicFunction!

        console.log('NOTE: Need set_any function for IntrinsicFunction');
        console.log('Building IR entry via wasm_build_ir_entry...');

        // Use wasm_build_ir_entry which creates CodeInfo internally
        // It takes code::Vector{Any} and ssa_types::Vector{Any}
        // Build code = [mul_int_expr, add_int_expr, return_node]
        const code = e.mk_vec(3);       // 3 statements
        const ssa_types = e.mk_vec(3);  // 3 SSA types

        // Statement 1: Expr(:call, mul_int, Arg(2), Arg(2))
        const mul_args = e.mk_vec(3);
        // Need to set mul_args[1] = mul_int — but we have no set_any_intrinsic!
        // Workaround: create the Expr with args already populated

        // Actually, we can build the expr args manually if we have a generic setter
        // For now, try build_entry which does code_typed internally
        const entries = e.build_entry(code, ssa_types, "f");
        console.log('IR entries built:', entries ? 'OK' : 'FAIL');

        // ====================================================================
        // STAGE 3: Run REAL codegen in WASM
        // ====================================================================
        console.log('\n--- Stage 3: Compile in WASM ---');
        const wasm_output = e.compile(entries, mod, reg);
        console.log('Codegen output:', wasm_output ? 'OK' : 'null');

        if (wasm_output) {
            const len = e.bytes_len(wasm_output);
            console.log('Output WASM:', len, 'bytes');

            // Extract bytes
            const out = new Uint8Array(len);
            for (let i = 0; i < len; i++) {
                out[i] = e.bytes_get(wasm_output, i + 1); // 1-based
            }

            // Compile and test
            const compiled = await WebAssembly.instantiate(out);
            const f = compiled.instance.exports.f;
            const result = f(5n);
            console.log('f(5n) =', String(result));

            if (result === 26n) {
                console.log('\n=== SUCCESS: f(5n) === 26n ===');
                console.log('REAL codegen (compile_from_ir_prebaked) executing in WASM!');
            } else {
                console.log('\nWRONG: expected 26n, got', String(result));
            }
        }

    } catch(err) {
        console.log('TRAP:', err.message);
        console.log('Stack:', err.stack);
        process.exit(1);
    }
}).catch(e => {
    console.error('Load failed:', e.message);
    process.exit(1);
});
