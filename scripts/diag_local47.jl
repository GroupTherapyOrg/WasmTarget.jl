#!/usr/bin/env julia
# Find where local 47 is set and what type it is in early_inline_special_case
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

bytes = compile(func, arg_types)
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

dump_buf = IOBuffer()
Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dump_buf))
dump = String(take!(dump_buf))
dump_lines = split(dump, "\n")

# Find all local_set 47 (21 2f) and local_get 47 (20 2f) instructions
println("=== local_set 47 occurrences ===")
for (i, l) in enumerate(dump_lines)
    if contains(l, "local_set local_index:47")
        # Show context: 10 lines before
        ctx_start = max(1, i-10)
        for j in ctx_start:i+5
            mark = j == i ? ">>>" : "   "
            println("$mark $j: $(dump_lines[j])")
        end
        println("---")
    end
end

# Also check what type local 47 is (from local declarations)
println("\n=== local declarations for func 1 ===")
in_func = false
local_count = 0
for (i, l) in enumerate(dump_lines)
    if contains(l, "(func (;1;)") || contains(l, "function_index:1") ||
       (contains(l, "func ") && contains(l, "type_index"))
        in_func = true
    end
    if in_func && contains(l, "locals of type")
        # Parse count and type
        m = match(r"(\d+) locals of type (.+)$", strip(l))
        if !isnothing(m)
            cnt = Base.parse(Int, m.captures[1])
            typ = strip(m.captures[2])
            for j in 1:cnt
                if local_count == 47
                    println("Local 47: $typ  (source line $i)")
                end
                local_count += 1
            end
        end
    end
    if in_func && local_count > 60
        break
    end
end

# Find func 1 start in dump
println("\n=== Finding func 1 start ===")
for (i, l) in enumerate(dump_lines)
    if contains(l, "code[0]") || (contains(l, "| func") && contains(l, "0x"))
        println("$i: $l")
        break
    end
end

# Count total params+locals before reaching local 47
println("\n=== All local declarations (func 1) ===")
found_code = false
param_count = 4  # known: 4 params
running_idx = param_count  # locals start after params
for (i, l) in enumerate(dump_lines)
    if !found_code && contains(l, "locals of type")
        m = match(r"(\d+) locals of type (.+)$", strip(l))
        if !isnothing(m)
            cnt = Base.parse(Int, m.captures[1])
            typ = strip(m.captures[2])
            for j in 1:cnt
                if running_idx in 44:50
                    println("  local $running_idx: $typ")
                end
                running_idx += 1
            end
        end
    end
end
