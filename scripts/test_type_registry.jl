#!/usr/bin/env julia
# PURE-324: Compare type registries between Stage C3 (pass) and Stage C4 (fail)
using WasmTarget
using JuliaSyntax

# Hook into compile to see type registries
# We need to look at what types are registered for SourceFile#8 in each case

function stage_c3(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream, rule=:statement)
    return nothing
end

function stage_c4(s::String)
    JuliaSyntax._parse(:statement, false, Expr, s, 1)
end

# Compile C3 and check SubString type
println("=== Stage C3 compilation ===")
bytes_c3 = compile(stage_c3, (String,))
tmpf_c3 = tempname() * ".wasm"
write(tmpf_c3, bytes_c3)

# Check what type index SubString gets
# Look for the 3-field struct pattern in the wasm
println("\nC3 types matching SubString pattern (3 fields with ref+i64+i64):")
types_c3 = read(`bash -c "wasm-tools print $tmpf_c3 | head -200"`, String)
for line in split(types_c3, '\n')
    if occursin("struct", line) && (occursin("(ref null", line) || occursin("i64", line))
        stripped = strip(line)
        # Count fields
        nfields = count("field", stripped)
        if nfields == 3
            println("  ", stripped)
        end
    end
end

println("\n=== Stage C4 compilation ===")
bytes_c4 = compile(stage_c4, (String,))
tmpf_c4 = tempname() * ".wasm"
write(tmpf_c4, bytes_c4)

println("\nC4 types matching SubString pattern (3 fields with ref+i64+i64):")
types_c4 = read(`bash -c "wasm-tools print $tmpf_c4 | head -200"`, String)
for line in split(types_c4, '\n')
    if occursin("struct", line) && (occursin("(ref null", line) || occursin("i64", line))
        stripped = strip(line)
        nfields = count("field", stripped)
        if nfields == 3
            println("  ", stripped)
        end
    end
end

# Also check: what does #SourceFile#8 look like in both?
println("\n=== #SourceFile#8 function in C3 ===")
sf_c3 = read(`bash -c "wasm-tools print $tmpf_c3 | grep -A1 'SourceFile'"`, String)
println(strip(sf_c3) == "" ? "NOT FOUND as named function" : sf_c3)

# Check all func signatures that might be SourceFile
println("\nC3 func signatures:")
funcs_c3 = read(`bash -c "wasm-tools print $tmpf_c3 | grep '(func ' | head -20"`, String)
println(funcs_c3)

println("\nC4 func signatures:")
funcs_c4 = read(`bash -c "wasm-tools print $tmpf_c4 | grep '(func ' | head -20"`, String)
println(funcs_c4)
