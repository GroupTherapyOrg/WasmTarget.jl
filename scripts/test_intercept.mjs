import fs from 'fs';
import path from 'path';

const d = path.join(import.meta.dirname, '..', 'browser');
const rc = fs.readFileSync(path.join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

// Load test_c4.wasm (Stage C4 — same crash as parsestmt)
const wasmFile = path.join(d, 'test_c4.wasm');
if (!fs.existsSync(wasmFile)) {
  console.log('test_c4.wasm not found — run test_stage_c3.jl first');
  process.exit(1);
}

const rt = new WRT();
const wasmBytes = fs.readFileSync(wasmFile);

// Use raw WebAssembly API to intercept calls
const module = await WebAssembly.compile(wasmBytes);

// Get the imports
const importObject = {
  Math: { pow: Math.pow }
};

// Wrap functions to trace calls
const instance = await WebAssembly.instantiate(module, importObject);
const exports = instance.exports;

// List all exports
console.log('=== Exports ===');
for (const [name, fn] of Object.entries(exports)) {
  if (typeof fn === 'function') {
    console.log(`  ${name} (function)`);
  } else if (fn instanceof WebAssembly.Memory) {
    console.log(`  ${name} (memory)`);
  } else if (fn instanceof WebAssembly.Table) {
    console.log(`  ${name} (table)`);
  } else if (fn instanceof WebAssembly.Global) {
    console.log(`  ${name} (global: ${fn.value})`);
  }
}

// Create a string using jsToWasmString
const s = await rt.jsToWasmString('1');
console.log('\n=== Input string ===');
console.log('jsToWasmString result:', s, typeof s);

// Try calling #SourceFile#40 directly with the string
console.log('\n=== Testing #SourceFile#40 ===');
const sf40 = exports['#SourceFile#40'];
if (sf40) {
  console.log('#SourceFile#40 exists');
} else {
  console.log('#SourceFile#40 NOT exported');
}

// Try calling #SourceFile#8 directly
const sf8 = exports['#SourceFile#8'];
if (sf8) {
  console.log('#SourceFile#8 exists, params expected: (i32, i64, i64, i32, ref null 32)');
} else {
  console.log('#SourceFile#8 NOT exported');
}

// Try calling stage_c4 and catch the error with function index info
console.log('\n=== Testing stage_c4("1") ===');
try {
  const result = exports.stage_c4(s);
  console.log('PASS:', result);
} catch(e) {
  console.log('FAIL:', e.message);
  // Print the call stack
  const lines = e.stack.split('\n');
  for (const l of lines.slice(0, 10)) {
    console.log('  ', l.trim());
  }
}

// Let me also try calling ParseStream directly to see what it returns
console.log('\n=== Testing ParseStream("1") ===');
const ps = exports.ParseStream;
if (ps) {
  try {
    const stream = ps(s);
    console.log('ParseStream result:', stream, typeof stream);
  } catch(e) {
    console.log('ParseStream FAIL:', e.message);
  }
}
