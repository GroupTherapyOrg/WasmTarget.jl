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

// Embedded string bridge module (164 bytes, compiled by WasmTarget.jl).
// Exports: str_new(i32)->array<i32>, str_setchar!(array,i32,i32), str_char(array,i32)->i32, str_len(array)->i32
const STRING_BRIDGE_BASE64 = "AGFzbQEAAAABJgZgAnx8AXxPAF5/AWABfwFjAWADYwF/fwBgAmMBfwF/YAFjAQF/AgwBBE1hdGgDcG93AAADBQQCAwQFBy8EB3N0cl9uZXcAAQxzdHJfc2V0Y2hhciEAAghzdHJfY2hhcgADB3N0cl9sZW4ABAosBAcAIAD7BwELDgAgACABQQFrIAL7DgELDAAgACABQQFr+wsBCwYAIAD7Dws=";

class WasmTargetRuntime {
    constructor() {
        this.modules = new Map(); // name -> WebAssembly.Instance
        this._stringBridge = null; // Lazily initialized
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
            bytes = source.buffer.slice(source.byteOffset, source.byteOffset + source.byteLength);
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

    /**
     * Initialize the string bridge module (lazy, called automatically).
     * The bridge provides str_new, str_setchar!, str_char, str_len as Wasm exports
     * that create and manipulate WasmGC array<i32> strings compatible with all
     * WasmTarget-compiled modules (structural typing).
     *
     * @returns {Promise<void>}
     */
    async _initStringBridge() {
        if (this._stringBridge) return;

        // Decode base64 to bytes
        let bytes;
        if (typeof atob === "function") {
            // Browser
            const bin = atob(STRING_BRIDGE_BASE64);
            bytes = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        } else {
            // Node.js
            bytes = Buffer.from(STRING_BRIDGE_BASE64, "base64");
        }

        const imports = this.getImports();
        const { instance } = await WebAssembly.instantiate(bytes, imports);
        this._stringBridge = instance.exports;
    }

    /**
     * Convert a JavaScript string to a WasmGC array<i32> (one codepoint per element).
     * Handles full Unicode including emoji and supplementary plane characters.
     *
     * @param {string} str - The JavaScript string to convert
     * @returns {Promise<object>} A WasmGC array<i32> ref usable as a string argument
     */
    async jsToWasmString(str) {
        await this._initStringBridge();
        const { str_new, "str_setchar!": str_setchar } = this._stringBridge;

        const codepoints = [...str]; // Iterate by codepoint, not UTF-16 code unit
        const wasmStr = str_new(codepoints.length);
        for (let i = 0; i < codepoints.length; i++) {
            str_setchar(wasmStr, i + 1, codepoints[i].codePointAt(0)); // 1-based index
        }
        return wasmStr;
    }

    /**
     * Convert a WasmGC array<i32> string back to a JavaScript string.
     *
     * @param {object} wasmStr - A WasmGC array<i32> ref (from jsToWasmString or module output)
     * @returns {Promise<string>} The JavaScript string
     */
    async wasmToJsString(wasmStr) {
        await this._initStringBridge();
        const { str_char, str_len } = this._stringBridge;

        const len = str_len(wasmStr);
        let result = "";
        for (let i = 0; i < len; i++) {
            result += String.fromCodePoint(str_char(wasmStr, i + 1)); // 1-based index
        }
        return result;
    }
}

// Export for both ES modules and script tags
if (typeof module !== "undefined" && module.exports) {
    module.exports = { WasmTargetRuntime };
}
