import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rc = readFileSync(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(rc + "\nreturn WasmTargetRuntime;")();

const rt = new WRT();
const w = readFileSync(join(__dirname, "parsestmt.wasm"));
const pa = await rt.load(w, "parsestmt");

// Test: try calling validate_tokens with "1"
const s = await rt.jsToWasmString("1");
try {
  const result = pa.exports.parse_expr_string(s);
  console.log("PASS:", result);
} catch(e) {
  console.log("FAIL:", e.message);
  const lines = (e.stack||'').split('\n').filter(l => l.includes('wasm-function'));
  for (const l of lines) console.log(`  ${l.trim()}`);

  // Now: what is the EXACT function call stack?
  // func 1 -> func 2 -> func 8 -> func 16
  // parse_expr_string -> #_parse#75 -> #SourceFile#40 -> #SourceFile#8

  // The crash is at the END of parsing (building SourceFile from ParseStream)
  // This means the parsing itself may succeed, but creating the result SourceFile fails
}
