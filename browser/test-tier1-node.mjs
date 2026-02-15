/**
 * PURE-311: Tier 1 execution test suite in Node.js.
 *
 * Verifies that simple Julia functions compiled to Wasm by WasmTarget.jl
 * EXECUTE CORRECTLY in Node.js — not just validate.
 *
 * Tier 1 = server compiles, browser/Node.js executes (the Therapy.jl use case).
 *
 * This test is self-contained: it spawns Julia to compile each function,
 * writes .wasm to temp files, loads them in Node.js, calls exports, and
 * compares results against native Julia ground truth.
 *
 * Run: node WasmTarget.jl/browser/test-tier1-node.mjs
 *      (from GroupTherapyOrg/ directory)
 */

import { readFile, writeFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";

const execFileAsync = promisify(execFile);

let passed = 0;
let failed = 0;
let skipped = 0;

function assert(condition, msg) {
    if (condition) {
        console.log(`  PASS: ${msg}`);
        passed++;
    } else {
        console.log(`  FAIL: ${msg}`);
        failed++;
    }
}

function skip(msg) {
    console.log(`  SKIP: ${msg}`);
    skipped++;
}

// ============================================================
// Julia compilation helper
// ============================================================

const JULIA_CMD = "julia";
const JULIA_FLAGS = ["+1.12", "--project=WasmTarget.jl"];

/**
 * Compile a Julia function to Wasm and return { wasmPath, groundTruth }.
 *
 * @param {string} funcDef - Julia function definition (e.g., "add_one(x::Int32) = x + Int32(1)")
 * @param {string} funcName - Export name (e.g., "add_one")
 * @param {string} argTypes - Tuple type string (e.g., "(Int32,)")
 * @param {Array<{args: string, expected: string}>} testCases - Ground truth from Julia
 *   args is Julia code producing args tuple, expected is Julia code producing expected value
 * @param {string} tmpDir - Temp directory for .wasm files
 * @returns {Promise<{wasmPath: string, groundTruth: Array<{args: any[], expected: any}>}>}
 */
async function compileAndGetGroundTruth(funcDef, funcName, argTypes, testCases, tmpDir) {
    const wasmPath = join(tmpDir, `${funcName}.wasm`);

    // Build Julia script that:
    // 1. Defines the function
    // 2. Compiles to Wasm
    // 3. Writes .wasm file
    // 4. Runs native Julia on each test case and prints ground truth as JSON lines
    const testLines = testCases.map((tc, i) => {
        return `
    args_${i} = ${tc.args}
    expected_${i} = ${funcName}(args_${i}...)
    println("GT:$i:", expected_${i})`;
    }).join("\n");

    const juliaScript = `
using WasmTarget
${funcDef}
bytes = compile(${funcName}, ${argTypes})
write("${wasmPath.replace(/\\/g, "\\\\")}", bytes)
println("WASM_SIZE:", length(bytes))
${testLines}
`;

    try {
        const { stdout, stderr } = await execFileAsync(JULIA_CMD, [...JULIA_FLAGS, "-e", juliaScript], {
            timeout: 60000,
            maxBuffer: 10 * 1024 * 1024,
        });

        // Parse ground truth from stdout
        const lines = stdout.trim().split("\n");
        const groundTruth = [];
        let wasmSize = 0;

        for (const line of lines) {
            if (line.startsWith("GT:")) {
                const parts = line.split(":");
                const idx = parseInt(parts[1]);
                const value = parts.slice(2).join(":");
                groundTruth[idx] = parseGroundTruth(value);
            } else if (line.startsWith("WASM_SIZE:")) {
                wasmSize = parseInt(line.split(":")[1]);
            }
        }

        return { wasmPath, groundTruth, wasmSize };
    } catch (err) {
        const msg = err.stderr ? err.stderr.trim().split("\n").slice(-3).join(" | ") : err.message;
        throw new Error(`Julia compilation failed for ${funcName}: ${msg}`);
    }
}

/**
 * Parse a Julia ground truth value to a JS value.
 * Handles: integers, negative integers, floats, booleans.
 */
function parseGroundTruth(str) {
    str = str.trim();
    if (str === "true") return 1;  // Wasm returns i32 for Bool
    if (str === "false") return 0;
    if (str.includes(".") || str.includes("e") || str.includes("E")) {
        return parseFloat(str);
    }
    // Integer — could be BigInt for Int64
    const n = BigInt(str);
    // If it fits in safe integer range and the function returns i32, use Number
    // We'll compare flexibly later
    return n;
}

/**
 * Load a .wasm file and call an exported function.
 */
async function callWasm(wasmPath, funcName, args) {
    const bytes = await readFile(wasmPath);
    const importObject = { Math: { pow: Math.pow } };
    const { instance } = await WebAssembly.instantiate(bytes, importObject);
    const func = instance.exports[funcName];
    if (typeof func !== "function") {
        throw new Error(`Export "${funcName}" not found or not a function`);
    }
    return func(...args);
}

/**
 * Compare Wasm result against ground truth, handling BigInt/Number differences.
 */
function resultsMatch(wasmResult, expected) {
    // Both BigInt
    if (typeof wasmResult === "bigint" && typeof expected === "bigint") {
        return wasmResult === expected;
    }
    // Both Number
    if (typeof wasmResult === "number" && typeof expected === "number") {
        if (Number.isNaN(wasmResult) && Number.isNaN(expected)) return true;
        return wasmResult === expected;
    }
    // Mixed BigInt/Number — compare as BigInt
    if (typeof wasmResult === "bigint" && typeof expected === "number") {
        return wasmResult === BigInt(expected);
    }
    if (typeof wasmResult === "number" && typeof expected === "bigint") {
        return BigInt(wasmResult) === expected;
    }
    // Null/undefined
    if (wasmResult === undefined && expected === undefined) return true;
    return false;
}

function formatResult(v) {
    if (typeof v === "bigint") return `${v}n`;
    return String(v);
}

// ============================================================
// Test Definitions
// ============================================================

/**
 * Each test group: { name, funcDef, funcName, argTypes, cases }
 * cases: [{ args (Julia code), jsArgs (JS values), expected (Julia code) }]
 */
const TEST_GROUPS = [
    // --- Int32 Arithmetic ---
    {
        name: "Int32 addition",
        funcDef: "add_i32(a::Int32, b::Int32) = a + b",
        funcName: "add_i32",
        argTypes: "(Int32, Int32)",
        cases: [
            { args: "(Int32(3), Int32(4))", jsArgs: [3, 4], expected: "7" },
            { args: "(Int32(0), Int32(0))", jsArgs: [0, 0], expected: "0" },
            { args: "(Int32(-1), Int32(1))", jsArgs: [-1, 1], expected: "0" },
            { args: "(Int32(100), Int32(-50))", jsArgs: [100, -50], expected: "50" },
        ],
    },
    {
        name: "Int32 subtraction",
        funcDef: "sub_i32(a::Int32, b::Int32) = a - b",
        funcName: "sub_i32",
        argTypes: "(Int32, Int32)",
        cases: [
            { args: "(Int32(10), Int32(3))", jsArgs: [10, 3], expected: "7" },
            { args: "(Int32(0), Int32(0))", jsArgs: [0, 0], expected: "0" },
            { args: "(Int32(5), Int32(10))", jsArgs: [5, 10], expected: "-5" },
        ],
    },
    {
        name: "Int32 multiplication",
        funcDef: "mul_i32(a::Int32, b::Int32) = a * b",
        funcName: "mul_i32",
        argTypes: "(Int32, Int32)",
        cases: [
            { args: "(Int32(6), Int32(7))", jsArgs: [6, 7], expected: "42" },
            { args: "(Int32(0), Int32(99))", jsArgs: [0, 99], expected: "0" },
            { args: "(Int32(-3), Int32(4))", jsArgs: [-3, 4], expected: "-12" },
        ],
    },
    {
        name: "Int32 negation",
        funcDef: "neg_i32(x::Int32) = -x",
        funcName: "neg_i32",
        argTypes: "(Int32,)",
        cases: [
            { args: "(Int32(42),)", jsArgs: [42], expected: "-42" },
            { args: "(Int32(-7),)", jsArgs: [-7], expected: "7" },
            { args: "(Int32(0),)", jsArgs: [0], expected: "0" },
        ],
    },
    {
        name: "Int32 identity",
        funcDef: "id_i32(x::Int32) = x",
        funcName: "id_i32",
        argTypes: "(Int32,)",
        cases: [
            { args: "(Int32(0),)", jsArgs: [0], expected: "0" },
            { args: "(Int32(123),)", jsArgs: [123], expected: "123" },
            { args: "(Int32(-1),)", jsArgs: [-1], expected: "-1" },
        ],
    },

    // --- Int64 Arithmetic ---
    {
        name: "Int64 addition",
        funcDef: "add_i64(a::Int64, b::Int64) = a + b",
        funcName: "add_i64",
        argTypes: "(Int64, Int64)",
        cases: [
            { args: "(Int64(3), Int64(4))", jsArgs: [3n, 4n], expected: "7" },
            { args: "(Int64(0), Int64(0))", jsArgs: [0n, 0n], expected: "0" },
            { args: "(Int64(-100), Int64(100))", jsArgs: [-100n, 100n], expected: "0" },
        ],
    },
    {
        name: "Int64 multiplication",
        funcDef: "mul_i64(a::Int64, b::Int64) = a * b",
        funcName: "mul_i64",
        argTypes: "(Int64, Int64)",
        cases: [
            { args: "(Int64(6), Int64(7))", jsArgs: [6n, 7n], expected: "42" },
            { args: "(Int64(0), Int64(99))", jsArgs: [0n, 99n], expected: "0" },
        ],
    },

    // --- Comparisons ---
    {
        name: "Int32 less-than",
        funcDef: "lt_i32(a::Int32, b::Int32) = Int32(a < b)",
        funcName: "lt_i32",
        argTypes: "(Int32, Int32)",
        cases: [
            { args: "(Int32(1), Int32(2))", jsArgs: [1, 2], expected: "1" },
            { args: "(Int32(2), Int32(1))", jsArgs: [2, 1], expected: "0" },
            { args: "(Int32(3), Int32(3))", jsArgs: [3, 3], expected: "0" },
        ],
    },
    {
        name: "Int32 equality",
        funcDef: "eq_i32(a::Int32, b::Int32) = Int32(a == b)",
        funcName: "eq_i32",
        argTypes: "(Int32, Int32)",
        cases: [
            { args: "(Int32(5), Int32(5))", jsArgs: [5, 5], expected: "1" },
            { args: "(Int32(5), Int32(6))", jsArgs: [5, 6], expected: "0" },
        ],
    },

    // --- Control Flow ---
    {
        name: "Ternary (max of two)",
        funcDef: "max_i32(a::Int32, b::Int32) = a > b ? a : b",
        funcName: "max_i32",
        argTypes: "(Int32, Int32)",
        cases: [
            { args: "(Int32(3), Int32(7))", jsArgs: [3, 7], expected: "7" },
            { args: "(Int32(10), Int32(2))", jsArgs: [10, 2], expected: "10" },
            { args: "(Int32(5), Int32(5))", jsArgs: [5, 5], expected: "5" },
        ],
    },
    {
        name: "Absolute value",
        funcDef: "abs_i32(x::Int32) = x < Int32(0) ? -x : x",
        funcName: "abs_i32",
        argTypes: "(Int32,)",
        cases: [
            { args: "(Int32(5),)", jsArgs: [5], expected: "5" },
            { args: "(Int32(-5),)", jsArgs: [-5], expected: "5" },
            { args: "(Int32(0),)", jsArgs: [0], expected: "0" },
        ],
    },

    // --- Bitwise Operations ---
    {
        name: "Bitwise AND",
        funcDef: "band_i32(a::Int32, b::Int32) = a & b",
        funcName: "band_i32",
        argTypes: "(Int32, Int32)",
        cases: [
            { args: "(Int32(0xFF), Int32(0x0F))", jsArgs: [0xFF, 0x0F], expected: "15" },
            { args: "(Int32(0), Int32(0xFF))", jsArgs: [0, 0xFF], expected: "0" },
        ],
    },
    {
        name: "Bitwise OR",
        funcDef: "bor_i32(a::Int32, b::Int32) = a | b",
        funcName: "bor_i32",
        argTypes: "(Int32, Int32)",
        cases: [
            { args: "(Int32(0xF0), Int32(0x0F))", jsArgs: [0xF0, 0x0F], expected: "255" },
            { args: "(Int32(0), Int32(0))", jsArgs: [0, 0], expected: "0" },
        ],
    },
    {
        name: "Bitwise XOR",
        funcDef: "bxor_i32(a::Int32, b::Int32) = xor(a, b)",
        funcName: "bxor_i32",
        argTypes: "(Int32, Int32)",
        cases: [
            { args: "(Int32(0xFF), Int32(0x0F))", jsArgs: [0xFF, 0x0F], expected: "240" },
            { args: "(Int32(42), Int32(42))", jsArgs: [42, 42], expected: "0" },
        ],
    },

    // --- Type Conversion ---
    {
        name: "Int32 to Int64 (widening)",
        funcDef: "widen_i32(x::Int32) = Int64(x)",
        funcName: "widen_i32",
        argTypes: "(Int32,)",
        cases: [
            { args: "(Int32(42),)", jsArgs: [42], expected: "42" },
            { args: "(Int32(-1),)", jsArgs: [-1], expected: "-1" },
        ],
    },

    // --- Multi-step computation ---
    {
        name: "Sum of squares",
        funcDef: "sum_sq_i32(a::Int32, b::Int32) = a * a + b * b",
        funcName: "sum_sq_i32",
        argTypes: "(Int32, Int32)",
        cases: [
            { args: "(Int32(3), Int32(4))", jsArgs: [3, 4], expected: "25" },
            { args: "(Int32(0), Int32(5))", jsArgs: [0, 5], expected: "25" },
            { args: "(Int32(1), Int32(1))", jsArgs: [1, 1], expected: "2" },
        ],
    },
    {
        name: "Three-arg sum",
        funcDef: "sum3_i32(a::Int32, b::Int32, c::Int32) = a + b + c",
        funcName: "sum3_i32",
        argTypes: "(Int32, Int32, Int32)",
        cases: [
            { args: "(Int32(1), Int32(2), Int32(3))", jsArgs: [1, 2, 3], expected: "6" },
            { args: "(Int32(0), Int32(0), Int32(0))", jsArgs: [0, 0, 0], expected: "0" },
            { args: "(Int32(-1), Int32(0), Int32(1))", jsArgs: [-1, 0, 1], expected: "0" },
        ],
    },

    // --- Boolean patterns (PURE-505 verified) ---
    {
        name: "Boolean AND",
        funcDef: "and_bool(a::Int32, b::Int32) = Int32(a != Int32(0) && b != Int32(0))",
        funcName: "and_bool",
        argTypes: "(Int32, Int32)",
        cases: [
            { args: "(Int32(1), Int32(1))", jsArgs: [1, 1], expected: "1" },
            { args: "(Int32(1), Int32(0))", jsArgs: [1, 0], expected: "0" },
            { args: "(Int32(0), Int32(1))", jsArgs: [0, 1], expected: "0" },
            { args: "(Int32(0), Int32(0))", jsArgs: [0, 0], expected: "0" },
        ],
    },
    {
        name: "Boolean OR",
        funcDef: "or_bool(a::Int32, b::Int32) = Int32(a != Int32(0) || b != Int32(0))",
        funcName: "or_bool",
        argTypes: "(Int32, Int32)",
        cases: [
            { args: "(Int32(1), Int32(1))", jsArgs: [1, 1], expected: "1" },
            { args: "(Int32(1), Int32(0))", jsArgs: [1, 0], expected: "1" },
            { args: "(Int32(0), Int32(1))", jsArgs: [0, 1], expected: "1" },
            { args: "(Int32(0), Int32(0))", jsArgs: [0, 0], expected: "0" },
        ],
    },

    // --- Clamp (nested return conditionals, PURE-506 verified) ---
    {
        name: "Clamp (nested ternary)",
        funcDef: "clamp_i64(x::Int64, lo::Int64, hi::Int64) = x < lo ? lo : (x > hi ? hi : x)",
        funcName: "clamp_i64",
        argTypes: "(Int64, Int64, Int64)",
        cases: [
            { args: "(Int64(-1), Int64(0), Int64(10))", jsArgs: [-1n, 0n, 10n], expected: "0" },
            { args: "(Int64(5), Int64(0), Int64(10))", jsArgs: [5n, 0n, 10n], expected: "5" },
            { args: "(Int64(20), Int64(0), Int64(10))", jsArgs: [20n, 0n, 10n], expected: "10" },
        ],
    },
];

// ============================================================
// Main test runner
// ============================================================

async function main() {
    console.log("PURE-311: Tier 1 Execution Test Suite\n");
    console.log("Compiling and testing simple Julia functions in Node.js.");
    console.log("Each function is compiled via Julia, then executed in Wasm,");
    console.log("and verified against native Julia ground truth.\n");

    // Check Julia availability
    try {
        const { stdout } = await execFileAsync(JULIA_CMD, ["+1.12", "--version"], { timeout: 10000 });
        console.log(`Julia: ${stdout.trim()}`);
    } catch (err) {
        console.log("FATAL: Julia not available. Cannot compile test functions.");
        console.log("Install Julia 1.12 and ensure 'julia +1.12' works.");
        process.exit(1);
    }

    // Create temp directory
    const tmpDir = await mkdtemp(join(tmpdir(), "tier1-"));
    console.log(`Temp dir: ${tmpDir}\n`);

    let groupIdx = 0;
    for (const group of TEST_GROUPS) {
        groupIdx++;
        console.log(`--- ${groupIdx}. ${group.name} ---\n`);

        // Compile function and get ground truth
        let compiled;
        try {
            compiled = await compileAndGetGroundTruth(
                group.funcDef,
                group.funcName,
                group.argTypes,
                group.cases,
                tmpDir,
            );
            assert(compiled.wasmSize > 0, `${group.funcName}: compiled (${compiled.wasmSize} bytes)`);
        } catch (err) {
            assert(false, `${group.funcName}: compilation failed — ${err.message}`);
            console.log("");
            continue;
        }

        // Test each case
        for (let i = 0; i < group.cases.length; i++) {
            const tc = group.cases[i];
            const expected = compiled.groundTruth[i];

            try {
                const result = await callWasm(compiled.wasmPath, group.funcName, tc.jsArgs);
                const match = resultsMatch(result, expected);
                assert(match,
                    `${group.funcName}(${tc.jsArgs.map(formatResult).join(", ")}) = ${formatResult(result)} (expected ${formatResult(expected)})`
                );
                if (!match) {
                    console.log(`    Types: result=${typeof result}, expected=${typeof expected}`);
                }
            } catch (err) {
                assert(false,
                    `${group.funcName}(${tc.jsArgs.map(formatResult).join(", ")}) TRAPS: ${err.message}`
                );
            }
        }

        console.log("");
    }

    // Cleanup
    try {
        await rm(tmpDir, { recursive: true });
    } catch {}

    // Summary
    console.log("=".repeat(50));
    console.log(`Results: ${passed} passed, ${failed} failed, ${skipped} skipped`);
    console.log(`Total test cases: ${passed + failed + skipped}`);
    console.log(failed === 0 ? "ALL TESTS PASSED" : "SOME TESTS FAILED");

    if (failed === 0) {
        console.log("\nPURE-311 Status: PASS");
        console.log("Tier 1 (server compile, Node.js execute) verified CORRECT:");
        console.log("- Int32 arithmetic: add, sub, mul, neg, identity");
        console.log("- Int64 arithmetic: add, mul");
        console.log("- Comparisons: less-than, equality");
        console.log("- Control flow: ternary/max, abs, clamp");
        console.log("- Bitwise: AND, OR, XOR");
        console.log("- Type conversion: Int32 → Int64");
        console.log("- Multi-step: sum of squares, three-arg sum");
        console.log("- Boolean: AND (&&), OR (||)");
    }

    process.exit(failed > 0 ? 1 : 0);
}

main().catch(err => {
    console.error("Unhandled error:", err);
    process.exit(1);
});
