#!/usr/bin/env julia
# PURE-324: Debug what SubString #SourceFile#40 passes to #SourceFile#8
using WasmTarget
using JuliaSyntax

# What does SourceFile(ParseStream) do? It creates a SubString from the stream's data
# Let me extract the SubString and check its fields

# Get the SubString that would be passed to #SourceFile#8
function get_sf_code_offset(s::String)::Int64
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream, rule=:statement)
    # SourceFile constructor gets the code via stream.textbuf
    # Let me check what field contains the source code
    sf = JuliaSyntax.SourceFile(stream)
    return sf.code.offset  # SubString's offset
end

function get_sf_code_ncodeunits(s::String)::Int64
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream, rule=:statement)
    sf = JuliaSyntax.SourceFile(stream)
    return sf.code.ncodeunits
end

# Test natively first
println("=== Native Julia ===")
for input in ["1", "hello", "a\nb"]
    stream = JuliaSyntax.ParseStream(input)
    JuliaSyntax.parse!(stream, rule=:statement)
    sf = JuliaSyntax.SourceFile(stream)
    println("SourceFile(\"$input\"):")
    println("  code.string = \"$(sf.code.string)\"")
    println("  code.offset = $(sf.code.offset)")
    println("  code.ncodeunits = $(sf.code.ncodeunits)")
    println("  byte_offset = $(sf.byte_offset)")
    println("  first_line = $(sf.first_line)")
    println("  line_starts = $(sf.line_starts)")
end

# Now let me isolate: does the issue happen during SubString creation or SourceFile construction?
# Test: extract SubString offset only (no SourceFile iteration)
function get_ss_offset_from_ps(s::String)::Int64
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream, rule=:statement)
    # Replicate what #SourceFile#40 does:
    # 1. Get byte_span from output[1]
    # 2. Create SubString
    code = SubString(String(stream.textbuf), 1, stream.output[1].byte_span + 1)
    return code.offset
end

println("\n=== Compile get_ss_offset_from_ps ===")
try
    bytes = compile(get_ss_offset_from_ps, (String,))
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    run(`wasm-tools validate --features=gc $tmpf`)
    n = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
    println("$n funcs, $(length(bytes)) bytes")

    cp(tmpf, joinpath(@__DIR__, "..", "browser", "test_ss_ps_offset.wasm"), force=true)
    node_code = """
import fs from 'fs';
const rc = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
const rt = new WRT();
const w = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "test_ss_ps_offset.wasm"))');
const mod = await rt.load(w, 'get_ss_offset_from_ps');
const s = await rt.jsToWasmString('1');
try {
    const r = mod.exports.get_ss_offset_from_ps(s);
    console.log('SubString offset from PS PASS:', r, '(expected 0)');
} catch(e) {
    console.log('SubString offset from PS FAIL:', e.message);
    console.log(e.stack.split('\\n').filter(l=>l.includes('wasm')).map(l=>'  '+l.trim()).join('\\n'));
}
"""
    tmpjs = tempname() * ".mjs"
    write(tmpjs, node_code)
    run(`node $tmpjs`)
catch e
    println("ERROR: ", e)
    showerror(stdout, e, catch_backtrace())
end
