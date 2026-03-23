# build_int002_e2e_v3.jl — INT-002-impl: Full E2E with constructor wrappers
#
# Run: julia +1.12 --project=. test/selfhost/build_int002_e2e_v3.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_from_codeinfo,
                  WasmModule, TypeRegistry,
                  InplaceCompilationContext,
                  WasmValType, I64,
                  wasm_bytes_length, wasm_bytes_get,
                  generate_body, to_bytes_mvp, create_ictx,
                  CompositeType, WasmImport, WasmFunction, WasmTable,
                  WasmMemory, WasmGlobalDef, WasmExport,
                  WasmElemSegment, WasmDataSegment, WasmTag

println("=" ^ 70)
println("INT-002-impl v3: Full E2E")
println("=" ^ 70)

ci_f, _ = Base.code_typed(x -> x * x + Int64(1), (Int64,))[1]
const _baked_ci = ci_f

# Constructor wrappers — avoid Type{T} dispatch (which compile_invoke stubs)
function new_wasm_module()::WasmModule
    WasmModule(CompositeType[], Vector{UInt32}[], WasmImport[], WasmFunction[],
        WasmTable[], WasmMemory[], WasmGlobalDef[], WasmExport[],
        WasmElemSegment[], WasmDataSegment[], WasmTag[], nothing)
end

function new_type_registry()::TypeRegistry
    TypeRegistry(Val(:minimal))
end

# ictx_create uses wrappers (Julia will inline these if small enough)
function ictx_create()::InplaceCompilationContext
    mod = new_wasm_module()
    reg = new_type_registry()
    create_ictx(_baked_ci, (Int64,), Int64, mod, reg)
end

function do_codegen(ctx::InplaceCompilationContext)::Vector{UInt8}
    body = generate_body(ctx)
    to_bytes_mvp(body, ctx.locals)
end

function run_selfhost()::Vector{UInt8}
    ctx = ictx_create()
    do_codegen(ctx)
end

# Native verify
println("Native: $(length(run_selfhost())) bytes, f(5n)=", begin
    tmp = tempname() * ".wasm"; write(tmp, run_selfhost())
    out = strip(read(`node -e "WebAssembly.instantiate(require('fs').readFileSync('$tmp')).then(m=>console.log(String(m.instance.exports.f(5n))))"`, String))
    rm(tmp, force=true); out
end)

# ═══════════════════════════════════════════════════════════════════════════
# Collect functions + kwarg constructor
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Collecting ---")

ci_ictx, _ = Base.code_typed(ictx_create, (); optimize=true)[1]
println("ictx_create: $(length(ci_ictx.code)) stmts, invokes:")
global kwarg_ci_g = nothing
global kwarg_args_g = nothing
global kwarg_func_g = nothing
for stmt in ci_ictx.code
    if stmt isa Expr && stmt.head === :invoke
        mi_or_ci = stmt.args[1]
        if isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
            mi = mi_or_ci.def
            name = String(mi.def.name)
            println("  → $name")
            if occursin("#", name)
                func_instance = mi.def.sig.parameters[1].instance
                arg_types = Tuple{mi.specTypes.parameters[2:end]...}
                result = Base.code_typed(func_instance, arg_types; optimize=true)
                if !isempty(result)
                    global kwarg_ci_g = result[1][1]
                    global kwarg_args_g = arg_types
                    global kwarg_func_g = func_instance
                    println("    → code_typed: $(length(kwarg_ci_g.code)) stmts ✓")
                end
            end
        end
    end
end

# Build entries
ci_dc, rt_dc = Base.code_typed(do_codegen, (InplaceCompilationContext,); optimize=true)[1]
ci_run, rt_run = Base.code_typed(run_selfhost, (); optimize=true)[1]
ci_gb, rt_gb = Base.code_typed(generate_body, (InplaceCompilationContext,); optimize=false)[1]
ci_tb, rt_tb = Base.code_typed(to_bytes_mvp, (Vector{UInt8}, Vector{WasmValType}); optimize=true)[1]
ci_bl, rt_bl = Base.code_typed(wasm_bytes_length, (Vector{UInt8},); optimize=true)[1]
ci_bg, rt_bg = Base.code_typed(wasm_bytes_get, (Vector{UInt8}, Int32); optimize=true)[1]
ci_nm, rt_nm = Base.code_typed(new_wasm_module, (); optimize=true)[1]
ci_nr, rt_nr = Base.code_typed(new_type_registry, (); optimize=true)[1]

all_funcs = Any[
    (ci_ictx, InplaceCompilationContext, (), "ictx_create", ictx_create),
    (ci_dc, rt_dc, (InplaceCompilationContext,), "do_codegen", do_codegen),
    (ci_run, rt_run, (), "run", run_selfhost),
    (ci_gb, rt_gb, (InplaceCompilationContext,), "generate_body", generate_body),
    (ci_tb, rt_tb, (Vector{UInt8}, Vector{WasmValType}), "to_bytes_mvp", to_bytes_mvp),
    (ci_bl, rt_bl, (Vector{UInt8},), "bytes_len", wasm_bytes_length),
    (ci_bg, rt_bg, (Vector{UInt8}, Int32), "bytes_get", wasm_bytes_get),
    (ci_nm, rt_nm, (), "new_wasm_module", new_wasm_module),
    (ci_nr, rt_nr, (), "new_type_registry", new_type_registry),
]
if kwarg_ci_g !== nothing
    push!(all_funcs, (kwarg_ci_g, InplaceCompilationContext, kwarg_args_g, "ictx_kwarg", kwarg_func_g))
end
println("Total: $(length(all_funcs)) functions")

# ═══════════════════════════════════════════════════════════════════════════
# Validate + build
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Validation ---")
valid_funcs = Any[]
for (ci, rt, args, name, f) in all_funcs
    try
        bytes = WasmTarget.compile_from_codeinfo(ci, rt, name, args)
        tmp = tempname() * ".wasm"; write(tmp, bytes)
        result = try read(`wasm-tools validate --features=gc $tmp`, String) catch e; "error" end
        ok = isempty(result)
        rm(tmp, force=true)
        println("  $(ok ? "✓" : "✗") $name: $(length(bytes))B $(length(ci.code))st$(ok ? "" : " $(result[1:min(60,end)])")")
        if ok push!(valid_funcs, (ci, rt, args, name, f)) end
    catch e
        println("  ✗ $name: ERR $(sprint(showerror, e)[1:min(80,end)])")
    end
end
println("Valid: $(length(valid_funcs))/$(length(all_funcs))")

println("\n--- Combined module ---")
entries = Any[(ci, rt, args, name, f) for (ci, rt, args, name, f) in valid_funcs]
println("Funcs: $(join([e[4] for e in entries], ", "))")

output_path = joinpath(@__DIR__, "..", "..", "e2e-int002-v3.wasm")
global module_ok = false
try
    mod = compile_module_from_ir(entries)
    mbytes = WasmTarget.to_bytes(mod)
    write(output_path, mbytes)
    result = try read(`wasm-tools validate --features=gc $output_path`, String) catch e; "error" end
    global module_ok = isempty(result)
    println("$(length(mbytes))B ($(round(length(mbytes)/1024, digits=1))KB) $(length(mod.exports)) exports: $(module_ok ? "PASS ✓" : "FAIL $(result[1:min(100,end)])")")
catch e
    println("FAIL: $(sprint(showerror, e)[1:min(100,end)])")
end

# E2E
global e2e_ok = false
if module_ok && any(x->x[4]=="run", valid_funcs)
    println("\n--- E2E ---")
    js = """
    const fs=require('fs'),b=fs.readFileSync('$output_path');
    (async()=>{try{
    const{instance}=await WebAssembly.instantiate(b,{Math:{pow:Math.pow}});
    const e=instance.exports;console.log('Exports:',Object.keys(e).join(','));
    console.log('run()...');const w=e.run();
    if(w&&e.bytes_len&&e.bytes_get){const n=e.bytes_len(w);console.log('Output:',n,'bytes');
    if(n>0){const o=new Uint8Array(n);for(let i=0;i<n;i++)o[i]=e.bytes_get(w,i+1);
    console.log('Hdr:',Array.from(o.slice(0,8)).map(b=>'0x'+b.toString(16).padStart(2,'0')).join(' '));
    const{instance:inner}=await WebAssembly.instantiate(o);const r=inner.exports.f(5n);
    console.log('f(5n)='+r);console.log('f(5n)===26n:',r===26n);
    if(r===26n)console.log('SUCCESS: TRUE SELF-HOSTING E2E!');}}
    }catch(e){console.log('Error:',e.message||e)}})();
    """
    nr = try read(`node -e $js`, String) catch e; "err: $e" end
    for l in split(nr,'\n'); println("  $l"); end
    global e2e_ok = occursin("f(5n)===26n: true", nr)
end

println("\n" * "=" ^ 70)
println(e2e_ok ? "SUCCESS ✓ f(5n)===26n via TRUE SELF-HOSTING" :
    "$(length(valid_funcs))/$(length(all_funcs)) valid, module=$(module_ok ? "PASS" : "FAIL"), e2e=$(e2e_ok)")
println("=" ^ 70)
