#!/usr/bin/env julia
# Test: progressively build up the parsestmt call chain to find the crash point
using WasmTarget, JuliaSyntax

const RUNTIME_JS = joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js")

function test_wasm(f, func_name::String, test_string::String)
    bytes = compile(f, (String,))
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    nfuncs = length(filter(l -> contains(l, "(func"), readlines(`wasm-tools print $tmpf`)))

    valid = try
        run(pipeline(`wasm-tools validate --features=gc $tmpf`; stderr=devnull))
        true
    catch
        false
    end

    if !valid
        println("  $func_name: VALIDATE_FAIL ($nfuncs funcs, $(length(bytes)) bytes)")
        return "VALIDATE_FAIL"
    end

    js = """
    const fs = require('fs');
    const runtimeCode = fs.readFileSync('$(escape_string(RUNTIME_JS))', 'utf-8');
    const WasmTargetRuntime = new Function(runtimeCode + '\\nreturn WasmTargetRuntime;')();

    (async () => {
        const rt = new WasmTargetRuntime();
        const wasmBytes = fs.readFileSync('$(escape_string(tmpf))');
        const mod = await rt.load(wasmBytes, 'test');
        const func = mod.exports['$func_name'];
        if (!func) {
            const exports = Object.keys(mod.exports).filter(k => typeof mod.exports[k] === 'function');
            console.log('EXPORT_NOT_FOUND');
            process.exit(1);
        }
        const s = await rt.jsToWasmString($(repr(test_string)));
        try {
            const result = func(s);
            if (typeof result === 'bigint') {
                console.log(result.toString());
            } else if (result === null || result === undefined) {
                console.log('null');
            } else {
                console.log(JSON.stringify(result));
            }
        } catch (e) {
            console.log('ERROR: ' + e.message);
        }
    })();
    """

    js_path = tempname() * ".js"
    write(js_path, js)

    result = try
        strip(read(`node $js_path`, String))
    catch
        "CRASH"
    end

    println("  $func_name: $result ($nfuncs funcs, $(length(bytes)) bytes)")
    return result
end

# Stage 1: SourceFile creation
println("=== Stage 1: SourceFile ===")
sf_test(s::String) = length(SourceFile(s).line_starts)
test_wasm(sf_test, "sf_test", "1")

# Stage 2: ParseStream + SourceFile
println("\n=== Stage 2: ParseStream + SourceFile ===")
function ps_sf_test(s::String)
    ps = JuliaSyntax.ParseStream(s)
    sf = SourceFile(ps)
    return length(sf.line_starts)
end
test_wasm(ps_sf_test, "ps_sf_test", "1")

# Stage 3: ParseStream + parse! (the actual parsing)
println("\n=== Stage 3: ParseStream + parse! ===")
function parse_test(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(ps)
    return Int64(1)
end
test_wasm(parse_test, "parse_test", "1")

# Stage 4: Full parsestmt
println("\n=== Stage 4: Full parsestmt ===")
function parsestmt_test(s::String)
    return parsestmt(Expr, s) isa Expr ? Int64(1) : Int64(0)
end
test_wasm(parsestmt_test, "parsestmt_test", "1")

println("\nDone!")
