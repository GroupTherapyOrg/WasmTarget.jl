#!/usr/bin/env julia
# diag_6021c_dump.jl — use wasm-tools dump to find the error at offset 0x935 in early_inline_special_case
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

function get_dump_around_offset(func, arg_types, error_hex; window=30)
    bytes = compile(func, arg_types)
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    # Use wasm-tools dump to get offset-labeled output
    dump_output = IOBuffer()
    try
        Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dump_output))
    catch e
        println("Dump failed: $e")
        return
    end
    dump = String(take!(dump_output))
    dump_lines = split(dump, '\n')
    println("Dump: $(length(dump_lines)) lines")

    # Find lines matching our error offset (or nearby)
    target_dec = Base.parse(Int, "0x" * error_hex)
    # wasm-tools dump shows offsets like "0x00000935|..."
    matches = findall(l -> contains(l, "0x" * lpad(error_hex, 8, '0')) ||
                           contains(l, string(target_dec)), dump_lines)

    println("Lines matching offset 0x$error_hex (dec $target_dec): $(length(matches))")

    # Also look for nearby hex offsets
    hex_nearby = [string("0x" * lpad(string(target_dec + i, base=16), 8, '0')) for i in -5:5]
    nearby_matches = findall(l -> any(h -> contains(l, h[3:end]), hex_nearby), dump_lines)

    println("Nearby offset lines: $(length(nearby_matches))")

    # Show context around earliest nearby match
    all_hits = sort(unique(vcat(matches, nearby_matches)))
    if !isempty(all_hits)
        hit = all_hits[1]
        ctx_start = max(1, hit - window)
        ctx_end = min(length(dump_lines), hit + window)
        println("\n--- Dump context around offset 0x$error_hex ---")
        for i in ctx_start:ctx_end
            mark = i in matches ? ">>>" : (i in nearby_matches ? ">>~" : "   ")
            println("$mark $i: $(dump_lines[i])")
        end
    else
        # Show first 50 lines to understand format
        println("\n--- First 50 lines of dump ---")
        for (i, l) in enumerate(dump_lines[1:min(50, end)])
            println("$i: $l")
        end
    end
end

println("=== early_inline_special_case [142] dump at 0x935 ===")
entry142 = resolve_func_entry(data_lines[findfirst(l -> startswith(l, "142 |"), data_lines)])
get_dump_around_offset(entry142.func, entry142.arg_types, "935"; window=20)
