#!/usr/bin/env julia
# diag_6021c_ir2.jl — show optimized IR for early_inline_special_case
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget, JuliaSyntax
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

manifest_path = joinpath(@__DIR__, "eval_julia_manifest.txt")
all_lines = readlines(manifest_path)
data_lines = filter(l -> !startswith(l, "#") && !isempty(strip(l)), all_lines)
line142 = data_lines[findfirst(l -> startswith(l, "142 |"), data_lines)]
parts = split(line142, " | ")
func = getfield(eval(Meta.parse(strip(parts[2]))), Symbol(strip(parts[3])))
arg_types = eval(Meta.parse(strip(parts[4])))

# Use WasmInterpreter to get the real IR
build_wasm_interpreter()
interp = WasmInterpreter()

mi = Core.Compiler.specialize_method(
    methods(func, arg_types)[1],
    Tuple{arg_types...},
    Core.svec()
)

frame = Core.Compiler.typeinf_frame(interp, mi, true)
ci = frame.result.src

println("=== Typed IR for early_inline_special_case ===")
println("$(length(ci.code)) statements")
println()
for (i, (stmt, typ)) in enumerate(zip(ci.code, ci.ssavaluetypes))
    println("%$i ::$typ")
    println("  = $stmt")
end
