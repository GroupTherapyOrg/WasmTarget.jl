import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rc = readFileSync(join(__dirname, "wasmtarget-runtime.js"), "utf-8");
const WRT = new Function(rc + "\nreturn WasmTargetRuntime;")();

const rt = new WRT();

// We need to create a SubString struct in WASM
// SubString{String} has fields: string::String, offset::Int64, ncodeunits::Int64
// In WASM: struct { ref null 1 (array), i64, i64 }

// First, compile a wrapper that creates SubString from String
// We already know SubString(s) works, so let's chain them

// Instead, use parsestmt.wasm which already has SubString support
const pw = readFileSync(join(__dirname, "parsestmt.wasm"));
const pa = await rt.load(pw, "parsestmt");

// Let's test: call parse_expr_string but add more diagnostics
const s = await rt.jsToWasmString("1");
try {
  const result = pa.exports.parse_expr_string(s);
  console.log("PASS:", result);
} catch(e) {
  console.log("FAIL:", e.message);

  // Let's try simpler things through the exported functions
  // Try calling just the exported #SourceFile#8 in some way
  // But we can't easily - it needs SubString struct which is a GC type

  // Actually, let's look at what functions we CAN test from JS
  // that would exercise the SourceFile code path
  console.log("\nTrying validate_tokens (may use different path):");
  try {
    const r = pa.exports.validate_tokens(s);
    console.log("  validate_tokens:", r);
  } catch(e2) {
    console.log("  validate_tokens FAIL:", e2.message);
  }
}
