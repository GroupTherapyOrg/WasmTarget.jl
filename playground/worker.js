// Web Worker for executing compiled Wasm modules
// Receives: {type: "run", wasm: ArrayBuffer}
// Sends: {type: "stdout"|"result"|"error"|"done", ...}

self.onmessage = async (e) => {
  if (e.data.type !== "run") return;

  const wasmBytes = e.data.wasm;

  const importObject = {
    "io": {
      "write_string": (s) => self.postMessage({ type: "stdout", data: s }),
      "write_int": (n) => self.postMessage({ type: "stdout", data: String(n) }),
      "write_float": (f) => self.postMessage({ type: "stdout", data: String(f) }),
      "write_bool": (b) => self.postMessage({ type: "stdout", data: b ? "true" : "false" }),
      "write_newline": () => self.postMessage({ type: "stdout", data: "\n" }),
      "write_nothing": () => self.postMessage({ type: "stdout", data: "nothing" }),
    },
    "Math": { "pow": Math.pow },
    "env": {
      "capture_stack": () => null,
      "perf_now": () => performance.now(),
      "random_i64": () => BigInt(Math.floor(Math.random() * 2**63)),
    },
  };

  try {
    const mod = await WebAssembly.compile(new Uint8Array(wasmBytes));
    const instance = await WebAssembly.instantiate(mod, importObject);

    const t0 = performance.now();
    if (instance.exports.main) {
      instance.exports.main();
    } else {
      const exports = Object.keys(instance.exports);
      self.postMessage({ type: "stdout", data: "Exported functions: " + exports.join(", ") + "\n" });
    }
    const execTime = performance.now() - t0;

    self.postMessage({ type: "done", execTime });
  } catch (err) {
    self.postMessage({ type: "error", error: err.message, stack: err.stack });
  }
};
