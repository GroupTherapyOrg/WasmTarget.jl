#!/usr/bin/env julia
# diag_6021c_b3.jl — find offset 0x1070 in builtin_effects dump
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

line111 = data_lines[findfirst(l -> startswith(l, "111 |"), data_lines)]
entry111 = resolve_func_entry(line111)
bytes = compile(entry111.func, entry111.arg_types)
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("Compiled: $(length(bytes)) bytes")

# Validate
errbuf = IOBuffer()
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    println("VALIDATES")
catch; end
println("Error: $(String(take!(errbuf)))")

# Dump and search for 0x1070
dump_out = IOBuffer()
Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dump_out))
dump_str = String(take!(dump_out))
dump_lines = split(dump_str, '\n')
println("Dump: $(length(dump_lines)) lines")

# Search multiple representations of 0x1070
target = 0x1070
patterns = [
    "0x" * string(target, base=16),
    "0x" * lpad(string(target, base=16), 4, '0'),
    "0x" * lpad(string(target, base=16), 6, '0'),
    "0x" * lpad(string(target, base=16), 8, '0'),
    string(target),
]
println("Searching for patterns: $patterns")
for pat in patterns
    hits = findall(l -> contains(l, pat), dump_lines)
    if !isempty(hits)
        println("  Found '$pat' at lines: $(hits[1:min(5,end)])")
        hit = hits[1]
        for i in max(1,hit-5):min(length(dump_lines),hit+10)
            mark = i == hit ? ">>>" : "   "
            println("$mark $(dump_lines[i])")
        end
        break
    end
end

# Also: show dump lines around the code section - search for the instruction section
code_section_idx = findfirst(l -> contains(l, "code section"), dump_lines)
println("\nCode section found at dump line: $code_section_idx")
if !isnothing(code_section_idx)
    for i in code_section_idx:min(length(dump_lines), code_section_idx+5)
        println("  $(dump_lines[i])")
    end
end

# Look for lines with offsets in the range 0x1060-0x1080
println("\nLooking for offsets in range 0x1060-0x1080:")
for (i, l) in enumerate(dump_lines)
    for dec in 0x1060:0x1080
        h = "0x" * string(dec, base=16)
        if startswith(strip(l), h * " ") || startswith(strip(l), h * "|")
            println("  Line $i: $l")
            break
        end
    end
end
