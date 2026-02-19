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

    /**
     * Execute a Julia expression using the eval_julia WASM module.
     * Gap E: Codegen→Execute bridge.
     *
     * Pipeline:
     *   1. Convert JS string to WasmGC string
     *   2. Call eval_julia_wasm(code) → WasmGC String of bytes
     *   3. Extract bytes via eval_julia_result_length + eval_julia_result_byte
     *   4. Instantiate inner WASM module from bytes
     *   5. Parse expression to determine export name + arguments
     *   6. Call exported function → return result
     *
     * Currently supports: binary integer arithmetic ("+", "-", "*")
     * with Int64 literals (e.g. "1+1", "10-3", "2*3")
     *
     * @param {WebAssembly.Instance} evalInstance - Loaded eval_julia WASM instance
     * @param {string} code - A Julia arithmetic expression
     * @returns {Promise<bigint>} The computed result
     */
    async evalJulia(evalInstance, code) {
        const trimmed = code.trim();

        // Step 1: Parse expression to determine operator and operands.
        // We do this FIRST because eval_julia_wasm dispatches by str_char at position 2,
        // which only works for single-digit operands (e.g. "1+1" but not "10-3").
        // We build a canonical "1OP1" string for dispatch, use actual operands for execution.
        const m = trimmed.match(/^(-?\d+)\s*([+\-*])\s*(-?\d+)$/);
        if (!m) throw new Error(`evalJulia: unsupported expression: ${trimmed}`);
        const a = BigInt(m[1]), op = m[2], b = BigInt(m[3]);

        // Step 2: Convert canonical dispatch form to WasmGC string.
        // "1OP1" ensures the operator is always at position 2 (1-based),
        // matching eval_julia_wasm's str_char(code, Int32(2)) dispatch logic.
        const wasmCode = await this.jsToWasmString("1" + op + "1");

        // Step 3: Call eval_julia_wasm → WasmGC String bytes (pre-compiled WASM module)
        const vecRef = evalInstance.exports.eval_julia_wasm(wasmCode);

        // Step 4: Extract bytes via element-wise access
        const len = evalInstance.exports.eval_julia_result_length(vecRef);
        if (len < 8) throw new Error(`evalJulia: too few bytes (${len})`);
        const bytes = new Uint8Array(len);
        for (let i = 1; i <= len; i++) {
            bytes[i - 1] = evalInstance.exports.eval_julia_result_byte(vecRef, i);
        }

        // Validate WASM magic: 0x00 0x61 0x73 0x6d
        if (bytes[0] !== 0x00 || bytes[1] !== 0x61 || bytes[2] !== 0x73 || bytes[3] !== 0x6d) {
            throw new Error("evalJulia: invalid WASM magic bytes");
        }

        // Step 5: Instantiate the inner WASM module from extracted bytes
        const inner = await this.load(bytes.buffer);

        // Step 6: Call exported function with actual operands
        const fn = inner.exports[op];
        if (!fn) {
            const available = Object.keys(inner.exports).filter(k => typeof inner.exports[k] === "function");
            throw new Error(`evalJulia: export "${op}" not found. Available: ${available.join(", ")}`);
        }
        return fn(a, b);
    }
}

// Export for CommonJS (Node.js) or browser global (script tag)
if (typeof module !== "undefined" && module.exports) {
    module.exports = { WasmTargetRuntime };
} else if (typeof globalThis !== "undefined") {
    globalThis.WasmTargetRuntime = WasmTargetRuntime;
}
