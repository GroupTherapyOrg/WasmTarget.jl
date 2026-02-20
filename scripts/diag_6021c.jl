#!/usr/bin/env julia
# diag_6021c.jl — targeted diagnosis for PURE-6021c categories B, A, C-G
# Tests specific functions by name from manifest

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
    catch e
        println("  ARG PARSE FAIL: $e")
        return nothing
    end
    return (idx=idx, mod=mod_name, name=func_name, func=func, arg_types=arg_types)
end

function diag_func(entry; show_wat_lines=60)
    println("\n=== [$(entry.idx)] $(entry.mod).$(entry.name) ===")
    println("Args: $(entry.arg_types)")

    bytes = try
        compile(entry.func, entry.arg_types)
    catch e
        println("COMPILE_ERROR: $(sprint(showerror, e))")
        return :compile_error
    end
    println("Compiled: $(length(bytes)) bytes")

    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    errbuf = IOBuffer()
    ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        ok = true
    catch; end

    if ok
        println("VALIDATES ✓")
        return :validates
    else
        msg = String(take!(errbuf))
        println("VALIDATE_ERROR:")
        println(msg)

        m = match(r"at offset 0x([0-9a-f]+)", msg)
        if !isnothing(m)
            hex_offset = m.captures[1]
            println("\nError at hex offset 0x$hex_offset")

            wat_output = IOBuffer()
            try
                Base.run(pipeline(`wasm-tools print $tmpf`, stdout=wat_output))
                wat = String(take!(wat_output))
                wat_lines = split(wat, '\n')
                println("WAT: $(length(wat_lines)) lines total")

                # Find lines around error offset
                target = "0x" * hex_offset
                nearby = findall(l -> contains(l, target), wat_lines)
                if !isempty(nearby)
                    ctx_start = max(1, nearby[1] - 5)
                    ctx_end = min(length(wat_lines), nearby[end] + 15)
                    println("\n--- WAT context around offset ---")
                    for i in ctx_start:ctx_end
                        mark = i in nearby ? ">>>" : "   "
                        println("$mark $i: $(wat_lines[i])")
                    end
                else
                    println("\n--- First $show_wat_lines lines of WAT ---")
                    for (i, l) in enumerate(wat_lines[1:min(show_wat_lines, end)])
                        println("$i: $l")
                    end
                end
            catch e
                println("WAT dump failed: $e")
            end
        end
        return :validate_error
    end
end

# Target functions for PURE-6021c (categories A-G)
target_names = [
    # B: "expected i64, found externref"
    "builtin_effects",
    "early_inline_special_case",
    # A: "expected externref, found (ref $type)"
    "_builtin_nothrow",
    # C: incompatible ConcreteRef types
    "cfg_inline_item!",
    "cfg_inline_unionsplit!",
    # D: stack underflow
    "adce_pass!",
    "compact!",
    # E: expected arrayref, found ConcreteRef
    "assemble_inline_todo!",
    "concrete_result_item",
    # F: values remaining
    "batch_inline!",
    "convert_to_ircode",
]

println("=== PURE-6021c Targeted Diagnostics ===")
println("Testing $(length(target_names)) functions by category\n")

# Only test indices ≤ 150 (first batch)
for target_name in target_names
    matching = filter(l -> contains(l, " | $target_name | ") ||
                           endswith(split(l, " | ")[min(3,length(split(l," | ")))], target_name),
                      data_lines[1:min(150,end)])
    for line in matching
        entry = resolve_func_entry(line)
        isnothing(entry) && continue
        entry.idx > 150 && continue
        diag_func(entry; show_wat_lines=40)
    end
end

println("\n=== Done ===")
