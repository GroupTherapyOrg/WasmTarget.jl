import fs from 'fs';
import path from 'path';

// Load the wasm module and wrap #SourceFile#8 to intercept its call
const d = path.join(import.meta.dirname, '..', 'browser');
const rc = fs.readFileSync(path.join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\nreturn WasmTargetRuntime;')();

const rt = new WRT();
const wasmBytes = fs.readFileSync(path.join(d, 'test_c4.wasm'));

// Use raw instantiation to inspect the module
const module = await WebAssembly.compile(wasmBytes);

// Compile again, but this time we'll monkey-patch using Table
const importObject = { Math: { pow: Math.pow } };
const instance = await WebAssembly.instantiate(module, importObject);

// Get the Table export (if it exists) — wasm modules with indirect calls have tables
const table = instance.exports.__indirect_function_table;
if (table) {
  console.log('Table exists, size:', table.length);

  // Find #SourceFile#8 function index in the table
  // We know from exports that #SourceFile#8 is func 16
  // Table entries are usually at their func index
  try {
    const sf8 = table.get(16);
    console.log('Table[16]:', sf8);
  } catch(e) {
    console.log('Table[16] error:', e.message);
  }
}

// Let's try a different approach: Create a WebAssembly module that imports our functions
// and wraps them to log arguments

// Actually, the simplest approach: check the memory/globals state before the call
console.log('\n=== Globals ===');
for (const [name, val] of Object.entries(instance.exports)) {
  if (val instanceof WebAssembly.Global) {
    console.log(`  ${name}: ${val.value}`);
  }
}

// Try calling #SourceFile#8 directly with test args
console.log('\n=== Direct #SourceFile#8 call test ===');
const sf8 = instance.exports['#SourceFile#8'];
// Expected params: (i32, i64, i64, i32, ref null 32)
// i32=0, i64=0n, i64=1n, i32=0, SubString ref = null
try {
  // Try with null for SubString (ref null 32 can be null)
  const result = sf8(0, 0n, 1n, 0, null);
  console.log('Direct call result:', result);
} catch(e) {
  console.log('Direct call error:', e.message);
}

// Now try the full call path but catch at a lower level
console.log('\n=== Calling stage_c4 ===');
const s = await rt.jsToWasmString('1');
try {
  instance.exports.stage_c4(s);
} catch(e) {
  console.log('stage_c4 error:', e.message);
}

// Let's check what jsToWasmString actually creates
// The 's' should be a WasmGC array of i32 (the byte array)
console.log('\nInput string object:', Object.getPrototypeOf(s));
console.log('Input string constructor:', s?.constructor?.name);

// Can we read the array elements?
// In WasmGC, we can't directly access struct/array fields from JS
// But we can export accessor functions

// Check memory
const memory = instance.exports.memory;
if (memory) {
  console.log('\nMemory:', memory.buffer.byteLength, 'bytes');
}
