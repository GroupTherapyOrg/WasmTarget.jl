#!/usr/bin/env julia
# diag_local62.jl — Final diagnostic: find which function body contains 0x757d
# and what local 62 is declared as in THAT function.
#
# Known: wasm-tools validate says "func 14 failed to validate"
# Error: type mismatch: expected i64, found externref (at offset 0x757d)
# Dump: 0x7579 | local_get local_index:62, 0x757b | local_get local_index:79, 0x757d | i64_mul

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

const Compiler = Core.Compiler

function main()
    PL = Compiler.PartialsLattice{Compiler.ConstsLattice}
    argtypes_tuple = (PL, Core.Builtin, Vector{Any}, Any)

    println("=== Compiling builtin_effects(PartialsLattice, ...) ===")
    wasm_bytes = compile(Compiler.builtin_effects, argtypes_tuple)
    println("  $(length(wasm_bytes)) bytes")

    tmpf = tempname() * ".wasm"
    write(tmpf, wasm_bytes)

    # Validate
    errbuf = IOBuffer()
    validated = try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        true
    catch
        false
    end
    if !validated
        println("  VALIDATION ERROR:")
        println("  ", String(take!(errbuf)))
    end

    # ============================================================================
    # Get the binary dump and find function boundaries
    # ============================================================================
    dump_buf = IOBuffer()
    Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dump_buf, stderr=devnull))
    dump_text = String(take!(dump_buf))
    dump_lines = split(dump_text, '\n')

    # Find "size of function" markers to identify function boundaries
    println("\n=== Function boundaries in binary ===")
    func_boundaries = Tuple{Int, Int, String}[]  # (start_offset, end_offset, size_info)
    func_starts_offsets = Int[]
    func_sizes = Int[]

    for (i, l) in enumerate(dump_lines)
        if contains(l, "size of function")
            m = match(r"^\s+0x([0-9a-f]+)\s+\|\s+([0-9a-f ]+)\s+\|\s+size of function", l)
            if m !== nothing
                off = Base.parse(Int, "0x" * m.captures[1])
                push!(func_starts_offsets, off)
            end
        end
    end

    # Find which function contains offset 0x757d
    target_off = 0x757d
    println("  Found $(length(func_starts_offsets)) function start offsets")
    for (idx, start_off) in enumerate(func_starts_offsets)
        next_off = idx < length(func_starts_offsets) ? func_starts_offsets[idx + 1] : typemax(Int)
        if start_off <= target_off && target_off < next_off
            println("  Offset 0x757d is in function #$idx (binary func index $(idx-1)), starting at 0x$(string(start_off, base=16))")
            println("  Next function starts at 0x$(string(next_off, base=16))")

            # Show the function header (locals declaration) right after the size line
            println("\n  Local declarations for this function:")
            for (j, dl) in enumerate(dump_lines)
                m2 = match(r"^\s+0x([0-9a-f]+)", dl)
                if m2 !== nothing
                    doff = Base.parse(Int, "0x" * m2.captures[1])
                    if doff == start_off
                        # Print from here until we see first non-local instruction
                        for k in j:min(j+70, length(dump_lines))
                            println("    ", dump_lines[k])
                            if k > j + 2 && !contains(dump_lines[k], "locals of type") && !contains(dump_lines[k], "size of function") && !contains(dump_lines[k], "local blocks")
                                break
                            end
                        end
                        break
                    end
                end
            end
            break
        end
    end

    # Now count up to local 62 from the local declarations of the right function
    println("\n=== Detailed local analysis for the function containing 0x757d ===")

    # Find the function's locals in the dump
    # The format is: <offset> | <bytes> | N locals of type <TYPE>
    # These come right after "size of function" and "N local blocks"

    in_target_func = false
    local_index = 0
    local62_type = nothing

    for (idx, start_off) in enumerate(func_starts_offsets)
        next_off = idx < length(func_starts_offsets) ? func_starts_offsets[idx + 1] : typemax(Int)
        if start_off <= target_off && target_off < next_off
            # Found the function. Now parse its locals.
            for (j, dl) in enumerate(dump_lines)
                m2 = match(r"^\s+0x([0-9a-f]+)", dl)
                if m2 !== nothing && Base.parse(Int, "0x" * m2.captures[1]) == start_off
                    # This is the "size of function" line
                    # Next line is "N local blocks"
                    # Then N lines of "K locals of type TYPE"
                    println("  Function starts at dump line $j")

                    # First, find the param count from the WAT
                    # We need to count params separately since locals are 0-indexed after params.

                    # Parse local blocks
                    param_count = 1  # From WAT analysis: func 14 has 1 param (ref null 8)
                    local_index = param_count  # Locals start after params

                    for k in (j+2):min(j+200, length(dump_lines))
                        local_m = match(r"(\d+) locals of type (.+)", dump_lines[k])
                        if local_m !== nothing
                            count = Base.parse(Int, local_m.captures[1])
                            type_str = strip(local_m.captures[2])
                            for _ in 1:count
                                if local_index == 62
                                    local62_type = type_str
                                    println("  >>> local 62 declared as: $type_str")
                                end
                                if abs(local_index - 62) <= 3
                                    println("    local $local_index: $type_str")
                                end
                                local_index += 1
                            end
                        elseif !contains(dump_lines[k], "local blocks") && !contains(dump_lines[k], "size of function")
                            break  # End of local declarations
                        end
                    end
                    println("  Total locals (including params): $local_index")
                    break
                end
            end
            break
        end
    end

    if local62_type !== nothing
        println("\n  RESULT: local 62 is declared as: $local62_type")
        println("  At 0x757d, i64_mul expects i64 but local 62 provides $local62_type")
    end

    # ============================================================================
    # Show detailed context around the error
    # ============================================================================
    println("\n=== Context around 0x757d (60 lines) ===")
    for (i, l) in enumerate(dump_lines)
        m = match(r"^\s+0x([0-9a-f]+)", l)
        if m !== nothing
            off = Base.parse(Int, "0x" * m.captures[1])
            if abs(off - target_off) < 80
                marker = off == target_off ? " <<<ERROR>>>" : ""
                println("  $l$marker")
            end
        end
    end

    # ============================================================================
    # Find the IR for func 14 (memorynew_nothrow) and match SSA to local 62
    # ============================================================================
    println("\n=== IR analysis: memorynew_nothrow checked_smul_int operand ===")
    results = Base.code_typed(Compiler.memorynew_nothrow, Tuple{Vector{Any}}; optimize=true)
    ci, ret_type = results[1]
    code = ci.code
    ssatypes = ci.ssavaluetypes

    # The key stmt is %137: checked_smul_int(%101, %132)
    # %101 is typed Any (from getproperty on externref)
    # %132 is typed Int64 (from zext_int)
    # The mul needs i64, but %101 flows through as externref

    println("  %101 type: $(ssatypes[101])  stmt: $(sprint(show, code[101])[1:min(120,end)])")
    println("  %132 type: $(ssatypes[132])  stmt: $(sprint(show, code[132])[1:min(120,end)])")
    println("  %137 type: $(ssatypes[137])  stmt: $(sprint(show, code[137])[1:min(120,end)])")

    # Check how %101 gets its value
    println("\n  Tracing %101:")
    println("    %99: $(ssatypes[99]) = $(sprint(show, code[99])[1:min(120,end)])")
    println("    %100: $(ssatypes[100]) = $(sprint(show, code[100])[1:min(120,end)])")
    println("    %101: $(ssatypes[101]) = $(sprint(show, code[101])[1:min(120,end)])")

    # %101 is typed Any. It's a getproperty on an array element (memoryrefget returns Any).
    # checked_smul_int(%101, %132) — first arg is Any (externref), but mul needs i64
    # This is the root cause: %101 has Julia type Any but contains an Int at runtime.
    # The compiler correctly uses PiNode %104 and %107 to narrow %101 to Int64,
    # but %137 uses %101 directly (not through PiNode), so it's still typed Any.

    println("\n  === ROOT CAUSE ===")
    println("  %137 = checked_smul_int(%101, %132)")
    println("  %101 Julia type: $(ssatypes[101]) -> compiles to externref (since it's Any)")
    println("  %132 Julia type: $(ssatypes[132]) -> compiles to i64")
    println("  checked_smul_int needs both args as i64, but %101 is externref")
    println()
    println("  %101 = $(sprint(show, code[101]))")
    println("  This is Compiler.getproperty(args[2].val, :val) where args[2] is Any-typed")
    println("  (came from memoryrefget on a Vector{Any})")
    println()
    println("  The IR DOES have PiNodes that narrow %101 to Int64:")
    println("    %104 = PiNode(%101, Int64) - used in sle_int check")
    println("    %107 = PiNode(%101, Int64) - used in slt_int check")
    println("  But %137 uses %101 DIRECTLY, not through a PiNode!")
    println("  Julia's type system says checked_smul_int(%101, %132) returns Tuple{Any, Bool}")
    println("  but Julia KNOWS at inference time that %101 is Int64 (guarded by isa check at %102)")
    println()
    println("  FIX NEEDED: When compiling checked_smul_int (or any arithmetic intrinsic),")
    println("  if an operand is typed Any but the intrinsic requires a numeric type,")
    println("  emit an appropriate unboxing/conversion (extern.internalize + struct.get or similar)")
    println("  OR the phi/local allocation needs to recognize that %101 is used in arithmetic")
    println("  and allocate it as i64 instead of externref.")

    rm(tmpf; force=true)
    println("\n=== Done ===")
end

main()
