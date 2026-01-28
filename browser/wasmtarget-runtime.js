/**
 * WasmTarget.jl Browser Runtime
 *
 * Loads WasmGC modules compiled by WasmTarget.jl, provides required imports,
 * and exposes JS<->Wasm string conversion utilities.
 *
 * Usage:
 *   const rt = new WasmTargetRuntime();
 *   const mod = await rt.load("parsestmt.wasm");
 *   console.log(Object.keys(mod.exports));
 */

class WasmTargetRuntime {
    constructor() {
        this.modules = new Map(); // name -> WebAssembly.Instance
    }

    /**
     * Build the import object required by WasmTarget-compiled modules.
     * Currently all modules only import Math.pow.
     */
    getImports() {
        return {
            Math: { pow: Math.pow }
        };
    }

    /**
     * Load and instantiate a WasmGC module from a URL or ArrayBuffer.
     *
     * @param {string|ArrayBuffer|Uint8Array} source - URL string, ArrayBuffer, or Uint8Array of wasm bytes
     * @param {string} [name] - Optional name to register the module for later retrieval
     * @returns {Promise<WebAssembly.Instance>} The instantiated module
     */
    async load(source, name) {
        let bytes;

        if (typeof source === "string") {
            const response = await fetch(source);
            if (!response.ok) {
                throw new Error(`Failed to fetch ${source}: ${response.status} ${response.statusText}`);
            }
            bytes = await response.arrayBuffer();
            if (!name) {
                // Derive name from URL: "path/to/parsestmt.wasm" -> "parsestmt"
                name = source.split("/").pop().replace(/\.wasm$/, "");
            }
        } else if (source instanceof ArrayBuffer) {
            bytes = source;
        } else if (source instanceof Uint8Array) {
            bytes = source.buffer;
        } else {
            throw new Error("source must be a URL string, ArrayBuffer, or Uint8Array");
        }

        const imports = this.getImports();
        const { instance } = await WebAssembly.instantiate(bytes, imports);

        if (name) {
            this.modules.set(name, instance);
        }

        return instance;
    }

    /**
     * Get a previously loaded module by name.
     *
     * @param {string} name - The module name
     * @returns {WebAssembly.Instance|undefined}
     */
    get(name) {
        return this.modules.get(name);
    }

    /**
     * List all loaded module names.
     *
     * @returns {string[]}
     */
    list() {
        return Array.from(this.modules.keys());
    }

    /**
     * Call an exported function on a named module.
     *
     * @param {string} moduleName - The module name
     * @param {string} funcName - The exported function name
     * @param {...*} args - Arguments to pass
     * @returns {*} The function's return value
     */
    call(moduleName, funcName, ...args) {
        const instance = this.modules.get(moduleName);
        if (!instance) {
            throw new Error(`Module "${moduleName}" not loaded`);
        }
        const fn = instance.exports[funcName];
        if (typeof fn !== "function") {
            throw new Error(`"${funcName}" is not an exported function of "${moduleName}"`);
        }
        return fn(...args);
    }
}

// Export for both ES modules and script tags
if (typeof module !== "undefined" && module.exports) {
    module.exports = { WasmTargetRuntime };
}
