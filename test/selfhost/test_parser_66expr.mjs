/**
 * PARSE-001: Test 66 Julia expressions against parsestmt.wasm
 * Based on spec §3.2 expression categories.
 *
 * Run: node test/selfhost/test_parser_66expr.mjs [path-to-parsestmt.wasm]
 */
import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const browserDir = join(__dirname, '..', '..', 'browser');

// Load WasmTargetRuntime
const rtCode = readFileSync(join(browserDir, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rtCode + '\nreturn WasmTargetRuntime;')();

// Use path from arg or default
const wasmPath = process.argv[2] || join(browserDir, 'parsestmt.wasm');

const TEST_EXPRESSIONS = [
    // Literals (7)
    { input: '1',        category: 'Literals' },
    { input: '42',       category: 'Literals' },
    { input: '3.14',     category: 'Literals' },
    { input: 'true',     category: 'Literals' },
    { input: 'false',    category: 'Literals' },
    { input: 'nothing',  category: 'Literals' },
    { input: '0xff',     category: 'Literals' },

    // Identifiers (4)
    { input: 'x',        category: 'Identifiers' },
    { input: 'foo',      category: 'Identifiers' },
    { input: 'my_var',   category: 'Identifiers' },
    { input: 'Int64',    category: 'Identifiers' },

    // Binary ops (9)
    { input: '1+1',      category: 'Binary ops' },
    { input: 'x+y',      category: 'Binary ops' },
    { input: 'a*b',      category: 'Binary ops' },
    { input: 'a-b',      category: 'Binary ops' },
    { input: 'a/b',      category: 'Binary ops' },
    { input: 'a%b',      category: 'Binary ops' },
    { input: 'a||b',     category: 'Binary ops' },
    { input: 'a&&b',     category: 'Binary ops' },
    { input: '2^10',     category: 'Binary ops' },

    // Comparisons (6)
    { input: 'x==0',     category: 'Comparisons' },
    { input: 'x!=1',     category: 'Comparisons' },
    { input: 'x<y',      category: 'Comparisons' },
    { input: 'x>y',      category: 'Comparisons' },
    { input: 'x<=y',     category: 'Comparisons' },
    { input: 'x>=y',     category: 'Comparisons' },

    // Function calls (5)
    { input: 'f(x)',          category: 'Function calls' },
    { input: 'sin(x)',        category: 'Function calls' },
    { input: 'map(f,xs)',     category: 'Function calls' },
    { input: 'println(42)',   category: 'Function calls' },
    { input: 'push!(v,1)',    category: 'Function calls' },

    // Assignments (3)
    { input: 'a=1',       category: 'Assignments' },
    { input: 'x=y+z',     category: 'Assignments' },
    { input: 'a,b=1,2',   category: 'Assignments' },

    // Ranges (2)
    { input: '1:10',      category: 'Ranges' },
    { input: '1:2:10',    category: 'Ranges' },

    // Dot access (3)
    { input: 'a.b',       category: 'Dot access' },
    { input: 'a.b.c',     category: 'Dot access' },
    { input: 'x.f()',     category: 'Dot access' },

    // Symbols (2)
    { input: ':sym',      category: 'Symbols' },
    { input: ':foo',      category: 'Symbols' },

    // Arrays (3)
    { input: '[1,2,3]',   category: 'Arrays' },
    { input: '[x,y]',     category: 'Arrays' },
    { input: 'Int64[]',   category: 'Arrays' },

    // Tuples (2)
    { input: '(x,y)',     category: 'Tuples' },
    { input: '(1,2,3)',   category: 'Tuples' },

    // Lambdas (2)
    { input: 'x->x+1',       category: 'Lambdas' },
    { input: '(x,y)->x+y',   category: 'Lambdas' },

    // Blocks (1)
    { input: 'begin x end',  category: 'Blocks' },

    // === Previously failing categories ===

    // Unary ops (3)
    { input: '-x',        category: 'Unary ops' },
    { input: '!x',        category: 'Unary ops' },
    { input: '+x',        category: 'Unary ops' },

    // Ternary (1)
    { input: 'x>0 ? x : -x', category: 'Ternary' },

    // Control flow (3)
    { input: 'if x>0; x; else; -x; end',  category: 'Control flow' },
    { input: 'for i in 1:10; end',         category: 'Control flow' },
    { input: 'while x>0; x-=1; end',       category: 'Control flow' },

    // Definitions (3)
    { input: 'f(x)=x+1',                            category: 'Definitions' },
    { input: 'struct Point; x::Float64; end',        category: 'Definitions' },
    { input: 'function g(x); x*2; end',              category: 'Definitions' },

    // Strings (1)
    { input: '"hello"',   category: 'Strings' },

    // Edge cases (6)
    { input: '3.14',      category: 'Edge cases (float)' },
    { input: 'let x=1; x; end',  category: 'Edge cases (let)' },
    { input: '',           category: 'Edge cases (empty)' },
    { input: 'a ? b : c', category: 'Edge cases (ternary2)' },
    { input: '1 < x < 10', category: 'Edge cases (chained)' },
    { input: 'return x',  category: 'Edge cases (return)' },
];

async function test() {
    const rt = new WRT();
    const wasmBytes = readFileSync(wasmPath);
    console.log(`Loading parsestmt.wasm (${wasmBytes.length} bytes) from: ${wasmPath}`);

    let mod;
    try {
        mod = await rt.load(wasmBytes, 'parsestmt');
    } catch (e) {
        console.error(`FATAL: Cannot load module: ${e.message}`);
        process.exit(1);
    }

    const exports = Object.keys(mod.exports).filter(k => typeof mod.exports[k] === 'function');
    console.log(`Loaded: ${exports.length} exports\n`);

    const parseExpr = mod.exports.parse_expr_string;
    if (!parseExpr) {
        console.error('FATAL: parse_expr_string not exported');
        process.exit(1);
    }

    let passed = 0, failed = 0, trapped = 0;
    const results = {};

    for (const test of TEST_EXPRESSIONS) {
        const { input, category } = test;
        if (!results[category]) results[category] = { pass: 0, fail: 0, total: 0 };
        results[category].total++;

        try {
            const s = await rt.jsToWasmString(input);
            const result = parseExpr(s);
            // If it returns without trapping, it parsed
            results[category].pass++;
            passed++;
        } catch (e) {
            const msg = e.message || String(e);
            if (msg.includes('unreachable') || msg.includes('trap')) {
                results[category].fail++;
                trapped++;
                console.log(`  TRAP: "${input}" (${category}): ${msg.substring(0, 60)}`);
            } else {
                results[category].fail++;
                failed++;
                console.log(`  FAIL: "${input}" (${category}): ${msg.substring(0, 60)}`);
            }
        }
    }

    console.log('\n=== Results ===\n');
    console.log('| Category | Pass/Total | Status |');
    console.log('|----------|-----------|--------|');
    for (const [cat, r] of Object.entries(results)) {
        const status = r.pass === r.total ? '✅' : (r.pass > 0 ? '⚠️' : '❌');
        console.log(`| ${cat.padEnd(25)} | ${r.pass}/${r.total} | ${status} |`);
    }

    console.log(`\nTOTAL: ${passed}/${TEST_EXPRESSIONS.length} passing`);
    console.log(`  Passed: ${passed}, Trapped: ${trapped}, Failed: ${failed}`);
}

test().catch(e => { console.error(e); process.exit(1); });
