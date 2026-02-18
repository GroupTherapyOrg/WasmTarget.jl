using WasmTarget, Core.Compiler

bytes = compile(Core.Compiler.tmerge_types_slow, (Type, Type))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
wat = read(`wasm-tools print $tmpf`, String)

# Find the func (;1;) line (main function)
lines = split(wat, "\n")
for (i, line) in enumerate(lines)
    if occursin("(func (;1;)", line)
        # Parse all (local ...) tokens
        # In WAT, locals are listed inside the func like:
        # (func ... (local i64 i32 ...) ...)
        # Count tokens to find local 649 and 632
        # Params are externref, externref (2 params)
        # So local index 2 is the first local, etc.

        # Extract local types by finding all (local ...) groups
        # Actually the WAT format puts all locals in one big (local ...) declaration
        local_re = r"\(local ([^)]+)\)"
        m = match(local_re, line)
        if !isnothing(m)
            local_types = split(strip(m.captures[1]))
            println("Total locals declared: $(length(local_types))")
            # Params are 0 and 1 (externref, externref)
            # Local index 2 → local_types[1], local index 3 → local_types[2], ...
            # Local index N → local_types[N-1]
            # Wait, in WAT: (local i64 i32) declares locals 2 and 3 (if params take 0,1)
            # Local 632 → local_types[632 - 2 + 1] = local_types[631]
            # Local 649 → local_types[649 - 2 + 1] = local_types[648]
            if length(local_types) >= 648
                println("Local 649 type: $(local_types[648])")
            end
            if length(local_types) >= 631
                println("Local 632 type: $(local_types[631])")
            end
        else
            println("No (local ...) found in func line")
        end
        break
    end
end
