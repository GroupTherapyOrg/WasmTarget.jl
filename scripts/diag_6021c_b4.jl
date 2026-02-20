#!/usr/bin/env julia
# diag_6021c_b4.jl — get WAT and dump context around 0x1070 in builtin_effects [111]
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

# Get dump context around 0x1070
dump_out = IOBuffer()
Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dump_out))
dump_str = String(take!(dump_out))
dump_lines = split(dump_str, '\n')

# Find 0x1070 in dump lines
hits = findall(l -> startswith(strip(l), "0x1070 |"), dump_lines)
println("0x1070 at dump lines: $hits")

if !isempty(hits)
    hit = hits[1]
    println("\n--- Dump context around 0x1070 (lines $(hit-40):$(hit+30)) ---")
    for i in max(1,hit-40):min(length(dump_lines),hit+30)
        mark = i == hit ? ">>>" : "   "
        println("$mark $i: $(dump_lines[i])")
    end
end

# Also look for Julia IR for builtin_effects
println("\n\n=== Julia IR for builtin_effects ===")
try
    ir_results = code_typed(entry111.func, entry111.arg_types; optimize=true)
    if !isempty(ir_results)
        ir, rt = ir_results[1]
        println("Return type: $rt")
        stmts = ir.stmts
        println("Statements ($(length(stmts))):")
        for i in 1:length(stmts)
            stmt = stmts[i][:inst]
            typ = stmts[i][:type]
            println("  %$i ::$typ = $stmt")
        end
    end
catch e
    println("IR failed: $e")
end
