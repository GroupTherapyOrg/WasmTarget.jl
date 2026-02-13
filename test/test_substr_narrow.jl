#!/usr/bin/env julia
# Narrow down SubString crash: which SubString operation fails?
using WasmTarget

const RUNTIME_JS = joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js")

function test_wasm_substr(f, func_name::String, test_string::String)
    bytes = compile(f, (SubString{String},))
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    # Check for stubs during compilation
    # Validate
    try
        run(pipeline(`wasm-tools validate --features=gc $tmpf`; stderr=devnull))
    catch
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
            console.log('EXPORT_NOT_FOUND');
            process.exit(1);
        }
        // Create the SubString — it's a struct with (string, offset, ncodeunits)
        // In WasmTarget, SubString is compiled as a GC struct
        // We need to construct it properly
        // Actually, the runtime's jsToWasmString creates a String, not a SubString
        // We need a function that takes String and converts to SubString internally
        console.log('NEED_STRING_INPUT');
    })();
    """
    return "NEED_STRING_INPUT"
end

# Actually, the problem is we can't easily pass a SubString from JS.
# Let's test functions that take String and create SubString internally.

function test_wasm_string(f, func_name::String, test_string::String)
    bytes = compile(f, (String,))
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    try
        run(pipeline(`wasm-tools validate --features=gc $tmpf`; stderr=devnull))
    catch
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
            console.log('EXPORT_NOT_FOUND');
            process.exit(1);
        }
        const s = await rt.jsToWasmString($(repr(test_string)));
        try {
            const result = func(s);
            if (typeof result === 'bigint') {
                console.log(result.toString());
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

    try
        return strip(read(`node $js_path`, String))
    catch
        return "CRASH"
    end
end

# ============================================================
# Layer 1: SubString creation
# ============================================================
println("=== Layer 1: SubString creation ===")
substr_len(s::String) = ncodeunits(SubString(s, 1, ncodeunits(s)))
result = test_wasm_string(substr_len, "substr_len", "hello")
expected = substr_len("hello")
println("  substr_len(\"hello\"): expected=$expected, got=$result")

# ============================================================
# Layer 2: SubString ncodeunits (should be same as String)
# ============================================================
println("\n=== Layer 2: ncodeunits of SubString ===")
substr_ncu(s::String) = ncodeunits(SubString(s, 1, ncodeunits(s)))
result = test_wasm_string(substr_ncu, "substr_ncu", "hello")
expected = substr_ncu("hello")
println("  substr_ncu(\"hello\"): expected=$expected, got=$result")

# ============================================================
# Layer 3: SubString codeunit access (single char)
# ============================================================
println("\n=== Layer 3: SubString codeunit ===")
substr_cu1(s::String) = Int64(codeunit(SubString(s, 1, ncodeunits(s)), 1))
result = test_wasm_string(substr_cu1, "substr_cu1", "hello")
expected = substr_cu1("hello")
println("  substr_cu1(\"hello\"): expected=$expected, got=$result")

# ============================================================
# Layer 4: SubString getindex (s[1])
# ============================================================
println("\n=== Layer 4: SubString getindex ===")
substr_gi1(s::String) = Int64(SubString(s, 1, ncodeunits(s))[1])
result = test_wasm_string(substr_gi1, "substr_gi1", "hello")
expected = substr_gi1("hello")
println("  substr_gi1(\"hello\"): expected=$expected, got=$result")

# ============================================================
# Layer 5: SubString iteration with eachindex
# ============================================================
println("\n=== Layer 5: SubString eachindex ===")
function substr_eachidx(s::String)
    ss = SubString(s, 1, ncodeunits(s))
    n = Int64(0)
    for i in eachindex(ss)
        n += Int64(1)
    end
    return n
end
result = test_wasm_string(substr_eachidx, "substr_eachidx", "hello")
expected = substr_eachidx("hello")
println("  substr_eachidx(\"hello\"): expected=$expected, got=$result")

# ============================================================
# Layer 6: SubString iteration with codeunit access
# ============================================================
println("\n=== Layer 6: SubString iteration + codeunit ===")
function substr_iter_cu(s::String)
    ss = SubString(s, 1, ncodeunits(s))
    total = Int64(0)
    for i in 1:ncodeunits(ss)
        total += Int64(codeunit(ss, i))
    end
    return total
end
result = test_wasm_string(substr_iter_cu, "substr_iter_cu", "hello")
expected = substr_iter_cu("hello")
println("  substr_iter_cu(\"hello\"): expected=$expected, got=$result")

# ============================================================
# Layer 7: SubString iteration with getindex
# ============================================================
println("\n=== Layer 7: SubString iteration + getindex ===")
function substr_iter_gi(s::String)
    ss = SubString(s, 1, ncodeunits(s))
    n = Int64(0)
    for i in eachindex(ss)
        ss[i] == '\n' && (n += Int64(1))
    end
    return n
end
result = test_wasm_string(substr_iter_gi, "substr_iter_gi", "hello")
expected = substr_iter_gi("hello")
println("  substr_iter_gi(\"hello\"): expected=$expected, got=$result")

println("\nDone!")
