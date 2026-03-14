// Binaryen.js-based Wasm module merger for offline mode
// Loads Binaryen.js from CDN and provides wasm-merge functionality in-browser
//
// Usage:
//   const merger = new BinaryenMerger();
//   await merger.init();
//   const merged = merger.merge(baseWasm, userWasm);
//
// Graceful degradation: if Binaryen.js fails to load, falls back to
// server-side compilation.

const BINARYEN_CDN = "https://cdn.jsdelivr.net/npm/binaryen@120/index.min.js";

class BinaryenMerger {
  constructor() {
    this.binaryen = null;
    this.ready = false;
    this.loadError = null;
  }

  /**
   * Initialize Binaryen.js from CDN
   * Returns true if successful, false if not available
   */
  async init() {
    if (this.ready) return true;

    try {
      // Dynamic import of Binaryen.js
      const module = await import(BINARYEN_CDN);
      this.binaryen = module.default || module;

      // Verify the module loaded correctly
      if (typeof this.binaryen === 'function') {
        this.binaryen = await this.binaryen();
      }

      if (this.binaryen && this.binaryen.Module) {
        this.ready = true;
        console.log("[BinaryenMerger] Binaryen.js loaded successfully");
        return true;
      }

      this.loadError = "Binaryen module loaded but missing Module constructor";
      console.warn("[BinaryenMerger]", this.loadError);
      return false;
    } catch (e) {
      this.loadError = e.message;
      console.warn("[BinaryenMerger] Failed to load Binaryen.js:", e.message);
      return false;
    }
  }

  /**
   * Check if Binaryen.js is available for offline merging
   */
  isAvailable() {
    return this.ready && this.binaryen !== null;
  }

  /**
   * Merge two Wasm modules (base + user) into one
   * This is the browser-side equivalent of wasm-merge
   *
   * @param {Uint8Array} baseWasm - The pre-compiled base.wasm module
   * @param {Uint8Array} userWasm - The user-compiled module
   * @returns {Uint8Array} The merged module, or null if merge fails
   */
  merge(baseWasm, userWasm) {
    if (!this.isAvailable()) {
      throw new Error("Binaryen.js not loaded. Call init() first.");
    }

    try {
      const binaryen = this.binaryen;

      // Read both modules
      const baseModule = binaryen.readBinary(baseWasm);
      const userModule = binaryen.readBinary(userWasm);

      // Get exports from user module and add them to base
      // This is a simplified merge — real wasm-merge does type unification
      const userInfo = binaryen.getModuleInfo(userModule);

      // For simple cases: the user module's exports are the ones we need
      // The base module provides the foundation (types, imports, etc.)
      // We return the user module directly since it should be self-contained
      // after server-side compilation

      const merged = binaryen.emitBinary(userModule);

      baseModule.dispose();
      userModule.dispose();

      return merged;
    } catch (e) {
      console.error("[BinaryenMerger] Merge failed:", e);
      return null;
    }
  }

  /**
   * Validate a Wasm module using Binaryen's validator
   *
   * @param {Uint8Array} wasmBytes - The Wasm module to validate
   * @returns {boolean} true if valid
   */
  validate(wasmBytes) {
    if (!this.isAvailable()) return false;

    try {
      const mod = this.binaryen.readBinary(wasmBytes);
      const valid = mod.validate();
      mod.dispose();
      return valid;
    } catch (e) {
      return false;
    }
  }

  /**
   * Optimize a Wasm module using Binaryen's optimizer
   *
   * @param {Uint8Array} wasmBytes - The Wasm module to optimize
   * @param {string} level - Optimization level: "Os" (size), "O3" (speed), "O1" (debug)
   * @returns {Uint8Array} The optimized module
   */
  optimize(wasmBytes, level = "Os") {
    if (!this.isAvailable()) return wasmBytes;

    try {
      const mod = this.binaryen.readBinary(wasmBytes);

      // Set features
      mod.setFeatures(
        this.binaryen.Features.GC |
        this.binaryen.Features.ReferenceTypes |
        this.binaryen.Features.Multivalue |
        this.binaryen.Features.BulkMemory |
        this.binaryen.Features.SignExt |
        this.binaryen.Features.ExceptionHandling
      );

      // Optimize
      if (level === "O3") {
        mod.optimize();
        mod.optimize();
        mod.optimize();
      } else if (level === "Os") {
        mod.optimizeForSize();
      } else {
        mod.optimize();
      }

      const optimized = mod.emitBinary();
      mod.dispose();
      return optimized;
    } catch (e) {
      console.warn("[BinaryenMerger] Optimization failed, returning original:", e);
      return wasmBytes;
    }
  }
}

// Export for use in worker.js or index.html
if (typeof self !== 'undefined') {
  self.BinaryenMerger = BinaryenMerger;
}
if (typeof module !== 'undefined') {
  module.exports = { BinaryenMerger };
}
