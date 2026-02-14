import { readFileSync } from 'fs';
import { join } from 'path';

const dir = import.meta.dirname;
const rtCode = readFileSync(join(dir, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rtCode + '\nreturn WasmTargetRuntime;')();

async function testWasm(wasmFile, inputs) {
  const rt = new WRT();
  const bytes = readFileSync(join(dir, wasmFile));
  let mod;
  try {
    mod = await rt.load(bytes, 'parsestmt');
  } catch(e) {
    console.log(`\n=== ${wasmFile} === FAILED TO LOAD: ${e.message.slice(0, 200)}`);
    return;
  }

  console.log(`\n=== ${wasmFile} ===`);
  for (const input of inputs) {
    const s = await rt.jsToWasmString(input);
    try {
      mod.exports.parse_expr_string(s);
      process.stdout.write(`  "${input}": EXECUTES\n`);
    } catch(e) {
      process.stdout.write(`  "${input}": FAIL — ${e.message.slice(0, 80)}\n`);
      // Show stack trace for failures
      const lines = e.stack.split('\n').slice(0, 5);
      for (const l of lines) {
        const m = l.match(/wasm-function\[(\d+)\]:0x([0-9a-f]+)/);
        if (m) process.stdout.write(`    func[${m[1]}] @ 0x${m[2]}\n`);
      }
    }
  }
}

const inputs = ["1", "42", "0", "-1", "100", "a", "x", "+", "1+1", "1+2", "a+b", ""];

await testWasm('parsestmt.wasm', inputs);
