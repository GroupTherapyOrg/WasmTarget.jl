#!/usr/bin/env julia
# diag_6021c_offsets.jl — use wasm-tools print with offsets to find error location
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

function find_offset_in_wat(func, arg_types, error_hex; ctx=30)
    bytes = compile(func, arg_types)
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    # Use --offsets flag to get binary offsets in WAT text
    wat_output = IOBuffer()
    try
        Base.run(pipeline(`wasm-tools print --offsets $tmpf`, stdout=wat_output))
    catch e
        println("WAT print failed: $e")
        # Try without --offsets
        Base.run(pipeline(`wasm-tools print $tmpf`, stdout=wat_output))
    end
    wat = String(take!(wat_output))
    wat_lines = split(wat, '\n')

    target = error_hex
    # wasm-tools print --offsets shows offsets like "@0x1234" or "0x1234:"
    matches = findall(l -> contains(l, "@0x" * target) || contains(l, "0x" * target * ")") ||
                           contains(l, "0x" * target * " "), wat_lines)
    println("Looking for offset 0x$target in $(length(wat_lines)) WAT lines")
    println("Found $(length(matches)) matching lines: $matches")

    if !isempty(matches)
        for hit in matches
            ctx_start = max(1, hit - ctx)
            ctx_end = min(length(wat_lines), hit + 10)
            println("\n--- Context around line $hit ---")
            for i in ctx_start:ctx_end
                mark = i == hit ? ">>>" : "   "
                println("$mark $i: $(wat_lines[i])")
            end
        end
    else
        # Also try partial matches
        partial = filter(l -> contains(l, "0xea") || contains(l, "@0xea"), wat_lines)
        println("\nLines containing 0xea* pattern: $(length(partial)) matches")
        for (i, l) in enumerate(partial[1:min(20, end)])
            println("  $l")
        end
    end
end

# Test early_inline_special_case first (smaller file = easier to read)
println("=== early_inline_special_case [142] at 0x935 ===")
entry142 = resolve_func_entry(data_lines[findfirst(l -> startswith(l, "142 |"), data_lines)])
find_offset_in_wat(entry142.func, entry142.arg_types, "935"; ctx=30)
