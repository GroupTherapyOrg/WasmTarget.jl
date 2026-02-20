#!/usr/bin/env julia
# diag_6021c_critical.jl — Focused diagnostic for Category D critical path functions
# Tests compact! (21 stmts) and adce_pass! which are DEFINITELY in the critical path
# (may_optimize=true means ALL optimization passes run for "1+1")
#
# testCommand: julia +1.12 --project=. scripts/diag_6021c_critical.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
using JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)
@isdefined(IRCode) || (@eval const IRCode = Core.Compiler.IRCode)

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
        println("  ARG PARSE FAIL for $func_name: $e")
        return nothing
    end
    return (idx=idx, mod=mod_name, name=func_name, func=func, arg_types=arg_types)
end

function diagnose(entry; show_wat_ctx=50)
    println("\n" * "="^60)
    println("=== [$(entry.idx)] $(entry.mod).$(entry.name) ===")
    println("Args: $(entry.arg_types)")

    t0 = time()
    bytes = try
        compile(entry.func, entry.arg_types)
    catch e
        println("COMPILE_ERROR: $(sprint(showerror, e))")
        return :compile_error
    end
    t1 = time()
    println("Compiled: $(length(bytes)) bytes in $(round(t1-t0, digits=2))s")

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
        rm(tmpf; force=true)
        return :validates
    end

    msg = String(take!(errbuf))
    println("VALIDATE_ERROR:")
    println(msg)

    # Extract hex offset
    m = match(r"at offset 0x([0-9a-f]+)", msg)
    if isnothing(m)
        rm(tmpf; force=true)
        return :validate_error
    end

    hex_offset = m.captures[1]
    dec_offset = Base.parse(Int, "0x" * hex_offset)
    println("\nError at offset 0x$hex_offset (decimal: $dec_offset)")

    # Get WAT with the binary dump to find the instruction
    dump_buf = IOBuffer()
    try
        Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dump_buf))
    catch e
        println("Dump failed: $e")
        rm(tmpf; force=true)
        return :validate_error
    end
    dump_str = String(take!(dump_buf))
    dump_lines = split(dump_str, '\n')

    # Find lines near the error offset
    nearby_lines = Int[]
    for (i, line) in enumerate(dump_lines)
        m2 = match(r"0x([0-9a-f]+)\s*\|", line)
        isnothing(m2) && continue
        off = try Base.parse(Int, "0x" * m2.captures[1]) catch; continue end
        if abs(off - dec_offset) <= 200
            push!(nearby_lines, i)
        end
    end

    println("\n--- Dump context around offset 0x$hex_offset (±200 bytes) ---")
    println("($(length(nearby_lines)) instructions in range)")
    start_line = isempty(nearby_lines) ? 1 : max(1, nearby_lines[1] - 5)
    end_line = isempty(nearby_lines) ? min(30, length(dump_lines)) : min(length(dump_lines), nearby_lines[end] + 5)
    for i in start_line:end_line
        mark = dec_offset > 0 && i in nearby_lines && let
            m3 = match(r"0x([0-9a-f]+)\s*\|", dump_lines[i])
            !isnothing(m3) && try Base.parse(Int, "0x" * m3.captures[1]) catch; -1 end == dec_offset
        end ? ">>>" : "   "
        println("$mark $(dump_lines[i])")
    end

    rm(tmpf; force=true)
    return :validate_error
end

println("=== PURE-6021c: Critical path diagnostic ===")
println("Targeting Category D functions (stack underflow in adce_pass!, compact!)")
println()

# Get compact! [121] - only 21 statements, fastest to compile
line121 = data_lines[findfirst(l -> startswith(l, "121 |"), data_lines)]
entry121 = resolve_func_entry(line121)
println("Found compact!: $(entry121 !== nothing ? "OK" : "FAILED")")

# Get adce_pass! [95] - 711 statements, optimization pass
line95 = data_lines[findfirst(l -> startswith(l, "95 |"), data_lines)]
entry95 = resolve_func_entry(line95)
println("Found adce_pass!: $(entry95 !== nothing ? "OK" : "FAILED")")

# Get builtin_effects [111] - Category B
line111 = data_lines[findfirst(l -> startswith(l, "111 |"), data_lines)]
entry111 = resolve_func_entry(line111)
println("Found builtin_effects: $(entry111 !== nothing ? "OK" : "FAILED")")

# Get early_inline_special_case [142] - Category B
line142 = data_lines[findfirst(l -> startswith(l, "142 |"), data_lines)]
entry142 = resolve_func_entry(line142)
println("Found early_inline_special_case: $(entry142 !== nothing ? "OK" : "FAILED")")

println()

# Test compact! first (smallest, 21 stmts)
if entry121 !== nothing
    diagnose(entry121)
end

# Test builtin_effects [111] (Category B - may have simpler fix)
if entry111 !== nothing
    diagnose(entry111)
end

println("\n=== Done ===")
println("Run time: $(round(time(), digits=0))")
