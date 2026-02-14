import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

// SyntaxHead is a struct with kind::Kind(I32) and flags::RawFlags(I32)
// In WasmGC: (struct (field i32) (field i32))
// K"Integer" = 44, K"Identifier" = 90, K"Float" = 43

async function testWasm(filename, funcName, args, expected) {
  try {
    const bytes = readFileSync(join(__dirname, filename));
    const { instance } = await WebAssembly.instantiate(bytes, {
      Math: { pow: Math.pow }
    });
    const result = instance.exports[funcName](...args);
    const status = result === expected ? 'CORRECT' : `WRONG (got ${result}, expected ${expected})`;
    console.log(`  ${funcName}(${args.join(', ')}) = ${result} — ${status}`);
    return result === expected;
  } catch (e) {
    console.log(`  ${funcName}(${args.join(', ')}) — CRASH: ${e.message.substring(0, 200)}`);
    return false;
  }
}

console.log('=== Kind Comparison Isolation Tests ===\n');

console.log('test_kind_extract (return numeric value of kind):');
await testWasm('test_kind_extract.wasm', 'test_kind_extract', [44, 0], 44);   // Integer head
await testWasm('test_kind_extract.wasm', 'test_kind_extract', [90, 0], 90);   // Identifier head
await testWasm('test_kind_extract.wasm', 'test_kind_extract', [43, 0], 43);   // Float head
console.log('');

console.log('test_kind_direct (Kind param, === comparison):');
await testWasm('test_kind_direct.wasm', 'test_kind_direct', [44], 44);   // K"Integer"
await testWasm('test_kind_direct.wasm', 'test_kind_direct', [90], 90);   // K"Identifier"
console.log('');

console.log('test_kind_from_head (SyntaxHead param, extract kind, === comparison):');
await testWasm('test_kind_from_head.wasm', 'test_kind_from_head', [44, 0], 44);   // Integer → 44
await testWasm('test_kind_from_head.wasm', 'test_kind_from_head', [90, 0], 90);   // Identifier → 90
await testWasm('test_kind_from_head.wasm', 'test_kind_from_head', [43, 0], 43);   // Float → 43
console.log('');

console.log('test_kind_is_literal (SyntaxHead param, if/elseif chain like parse_julia_literal):');
await testWasm('test_kind_is_literal.wasm', 'test_kind_is_literal', [44, 0], 5);   // Integer → 5
await testWasm('test_kind_is_literal.wasm', 'test_kind_is_literal', [90, 0], 6);   // Identifier → 6
await testWasm('test_kind_is_literal.wasm', 'test_kind_is_literal', [43, 0], 1);   // Float → 1
console.log('');

console.log('Decode: 44=K"Integer", 90=K"Identifier", 43=K"Float"');
