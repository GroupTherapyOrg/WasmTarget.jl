// WasmTarget.jl docs — live WASM demo runner
// Loads pre-compiled .wasm files and runs exported functions in the browser.

document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll("[data-wasm-demo]").forEach(initDemo);
});

async function initDemo(container) {
  const file = container.dataset.wasmDemo;       // e.g. "sin"
  const func = container.dataset.wasmFunc || file; // export name
  const argsRaw = container.dataset.wasmArgs || ""; // e.g. "1.5708"
  const isBigInt = container.dataset.wasmBigint === "true";

  const btn = container.querySelector("button");
  const output = container.querySelector("pre.wasm-output");
  if (!btn || !output) return;

  btn.addEventListener("click", async () => {
    btn.disabled = true;
    output.textContent = "Loading...";
    try {
      const url = new URL(`../assets/examples/${file}.wasm`, import.meta.url || location.href);
      const response = await fetch(url);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const bytes = await response.arrayBuffer();
      const { instance } = await WebAssembly.instantiate(bytes);
      const args = parseArgs(argsRaw, isBigInt);
      const result = instance.exports[func](...args);
      output.textContent = formatResult(result);
    } catch (err) {
      output.textContent = "Error: " + err.message;
    } finally {
      btn.disabled = false;
    }
  });
}

function parseArgs(raw, isBigInt) {
  if (!raw) return [];
  return raw.split(",").map(s => {
    s = s.trim();
    if (isBigInt) return BigInt(s);
    if (s.includes(".")) return parseFloat(s);
    return parseInt(s, 10);
  });
}

function formatResult(val) {
  if (typeof val === "bigint") return val.toString();
  if (typeof val === "number") {
    return Number.isInteger(val) ? val.toString() : val.toPrecision(15);
  }
  return String(val);
}
