#!/usr/bin/env julia
# diag_6021c_wat.jl — get WAT context around error offset for specific functions
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
using JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)
@isdefined(SourceFile) || (@eval const SourceFile = JuliaSyntax.SourceFile)
@isdefined(InternalCodeCache) || (@eval const InternalCodeCache = Core.Compiler.InternalCodeCache)
@isdefined(WorldRange) || (@eval const WorldRange = Core.Compiler.WorldRange)
@isdefined(InferenceResult) || (@eval const InferenceResult = Core.Compiler.InferenceResult)
@isdefined(IRCode) || (@eval const IRCode = Core.Compiler.IRCode)
@isdefined(CFG) || (@eval const CFG = Core.Compiler.CFG)
@isdefined(InstructionStream) || (@eval const InstructionStream = Core.Compiler.InstructionStream)
@isdefined(CodeInfo) || (@eval const CodeInfo = Core.CodeInfo)
@isdefined(MethodInstance) || (@eval const MethodInstance = Core.MethodInstance)

manifest_path = joinpath(@__DIR__, "eval_julia_manifest.txt")
all_lines = readlines(manifest_path)
data_lines = filter(l -> !startswith(l, "#") && !isempty(strip(l)), all_lines)

function resolve_func_entry(line)
    parts = split(line, " | ")
    length(parts) < 4 && return nothing
    idx = Base.parse(Int, strip(parts[1]))
    mod_name = strip(parts[2])
    func_name = strip(parts[3])
    arg_types_str = strip(parts[4])
    mod = try eval(Meta.parse(mod_name)) catch; return nothing end
    mod isa Module || return nothing
    func = try getfield(mod, Symbol(func_name)) catch; return nothing end
    arg_types = try
        t = eval(Meta.parse(arg_types_str))
        t isa Tuple ? t : (t,)
    catch; return nothing end
    return (idx=idx, mod=mod_name, name=func_name, func=func, arg_types=arg_types)
end

function wat_context(func, arg_types, target_offset_hex; context_lines=30)
    bytes = compile(func, arg_types)
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    errbuf = IOBuffer()
    ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        ok = true
    catch; end

    msg = String(take!(errbuf))
    if ok
        println("VALIDATES")
        return
    end
    println("Error: $msg")

    wat_output = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=wat_output))
    wat = String(take!(wat_output))
    wat_lines = split(wat, '\n')
    println("WAT: $(length(wat_lines)) lines")

    # Search for the offset in WAT lines
    target = "0x" * target_offset_hex
    matches = findall(l -> contains(l, target), wat_lines)
    println("Offset $target found at WAT lines: $matches")

    if !isempty(matches)
        for hit in matches
            ctx_start = max(1, hit - context_lines)
            ctx_end = min(length(wat_lines), hit + 10)
            println("\n--- WAT context around $target (line $hit) ---")
            for i in ctx_start:ctx_end
                mark = i == hit ? ">>>" : "   "
                println("$mark $i: $(wat_lines[i])")
            end
        end
    else
        # Try searching decimal equivalent
        dec_offset = Base.parse(Int, "0x" * target_offset_hex)
        println("Decimal: $dec_offset")
        # Just show function body (func 1 is usually main func, skip imports)
        func1_start = findfirst(l -> contains(l, "(func \$func_1") || contains(l, "(func (;1;)"), wat_lines)
        if !isnothing(func1_start)
            println("\n--- func 1 body (200 lines) ---")
            for i in func1_start:min(func1_start+200, length(wat_lines))
                println("$i: $(wat_lines[i])")
            end
        end
    end
end

println("=== WAT diagnostic for builtin_effects [111] at offset 0xead ===")
entry111 = resolve_func_entry(data_lines[findfirst(l -> startswith(l, "111 |"), data_lines)])
println("Entry: [$(entry111.idx)] $(entry111.mod).$(entry111.name)")
wat_context(entry111.func, entry111.arg_types, "ead"; context_lines=40)

println("\n\n=== WAT diagnostic for early_inline_special_case [142] at offset 0x935 ===")
entry142 = resolve_func_entry(data_lines[findfirst(l -> startswith(l, "142 |"), data_lines)])
println("Entry: [$(entry142.idx)] $(entry142.mod).$(entry142.name)")
wat_context(entry142.func, entry142.arg_types, "935"; context_lines=40)
