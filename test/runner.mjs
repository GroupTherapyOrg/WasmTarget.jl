// ============================================================================
// Persistent wasm runner — one long-lived Node process per pool worker.
// ============================================================================
// Replaces the "spawn a fresh `node` per program" pattern (≈150–300ms startup
// each) with a single process that services many requests over stdin/stdout,
// so Node startup amortizes to ~0 across an entire test/fuzz run.
//
//   Request  (one NDJSON line):  {"id":N,"wasmHex":"<hex>","src":"<body>"}
//       `src` is the body of an async function with `bytes` (Buffer) in scope
//       that RETURNS an array of per-input results ({ok:…} | {trap:"msg"}).
//   Response (one NDJSON line):  {"id":N,"results":[…]}        on success
//                                {"id":N,"error":"msg"}        on instantiate/driver failure
//
// A hung wasm call (genuine infinite loop — a real native-vs-wasm divergence)
// blocks this process; the Julia-side pool detects the missed deadline, kills
// this worker, and restarts a fresh one. Workers are therefore disposable.

import { createInterface } from 'node:readline';

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

rl.on('line', async (raw) => {
  const line = raw.trim();
  if (!line) return;
  let req;
  try {
    req = JSON.parse(line);
  } catch (e) {
    emit({ id: -1, error: 'bad-json: ' + String(e && e.message || e) });
    return;
  }
  const { id, wasmHex, src } = req;
  try {
    const bytes = Buffer.from(wasmHex, 'hex');
    const driver = new AsyncFunction('bytes', src);
    const results = await driver(bytes);
    emit({ id, results });
  } catch (e) {
    emit({ id, error: String(e && e.message || e) });
  }
});

rl.on('close', () => process.exit(0));

// Readiness handshake: the pool reads exactly one line before sending work.
emit({ ready: true });
