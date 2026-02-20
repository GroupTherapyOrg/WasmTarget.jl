#!/usr/bin/env julia
# diag_6021c_b2.jl — investigate new error for builtin_effects [111] after Category B fix
# Error: "expected ref but found i32 (at offset 0x1070)"
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

function dump_around_offset(func, arg_types, error_hex; window=20)
    bytes = compile(func, arg_types)
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    errbuf = IOBuffer()
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        println("VALIDATES")
        return
    catch; end
    msg = String(take!(errbuf))
    println("Error: $msg")

    # Use wasm-tools dump for binary-level view
    dump_output = IOBuffer()
    try
        Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dump_output))
    catch e
        println("Dump failed: $e")
        return
    end
    dump_str = String(take!(dump_output))
    dump_lines = split(dump_str, '\n')

    target_dec = Base.parse(Int, "0x" * error_hex)
    # Look for lines containing the hex offset
    padded = lpad(string(target_dec, base=16), 8, '0')
    nearby_range = (target_dec - 8):(target_dec + 8)
    nearby_hexes = Set([lpad(string(n, base=16), 8, '0') for n in nearby_range if n >= 0])

    hits = findall(l -> any(h -> contains(l, h), nearby_hexes), dump_lines)
    println("Lines near offset 0x$error_hex (dec $target_dec): $(length(hits)) matches")

    if !isempty(hits)
        ctx_start = max(1, hits[1] - window)
        ctx_end = min(length(dump_lines), hits[end] + window)
        println("\n--- Dump context around offset 0x$error_hex ---")
        for i in ctx_start:ctx_end
            mark = any(h -> contains(dump_lines[i], h), [lpad(string(target_dec, base=16), 8, '0')]) ? ">>>" : "   "
            println("$mark $i: $(dump_lines[i])")
        end
    else
        println("\n--- First 60 dump lines ---")
        for (i, l) in enumerate(dump_lines[1:min(60, end)])
            println("$i: $l")
        end
    end
end

line111 = data_lines[findfirst(l -> startswith(l, "111 |"), data_lines)]
entry111 = resolve_func_entry(line111)
println("Entry: [$(entry111.idx)] $(entry111.mod).$(entry111.name)")
println("Args: $(entry111.arg_types)")
dump_around_offset(entry111.func, entry111.arg_types, "1070"; window=15)
