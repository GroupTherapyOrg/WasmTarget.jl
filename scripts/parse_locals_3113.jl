using WasmTarget, Core.Compiler

bytes = compile(Core.Compiler.tmerge_types_slow, (Type, Type))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
wat = read(`wasm-tools print $tmpf`, String)

lines = split(wat, "\n")
func_line = ""
for line in lines
    if occursin("(func (;1;)", line)
        func_line = line
        break
    end
end

# Parse the (local ...) declaration
m = match(r"\(local (.+)\)", func_line)
if isnothing(m)
    println("No locals found")
    return
end

# Parse the local types - they can be multi-word like "(ref null 9)"
local_str = m.captures[1]
local_types = String[]
i = 1
while i <= length(local_str)
    if local_str[i] == '('
        # Find matching closing paren
        depth = 1
        j = i + 1
        while j <= length(local_str) && depth > 0
            if local_str[j] == '('
                depth += 1
            elseif local_str[j] == ')'
                depth -= 1
            end
            j += 1
        end
        push!(local_types, local_str[i:j-1])
        i = j
    elseif local_str[i] == ' '
        i += 1
    else
        # Simple type like i32, i64, externref, structref, eqref
        j = i
        while j <= length(local_str) && local_str[j] != ' ' && local_str[j] != '('
            j += 1
        end
        push!(local_types, local_str[i:j-1])
        i = j
    end
end

println("Total locals: $(length(local_types))")
# Local indices: params are 0,1 (externref, externref)
# First local is index 2
# Local 632 → local_types[632 - 2 + 1] = local_types[631]
# Local 649 → local_types[649 - 2 + 1] = local_types[648]
for idx in [632, 649, 631, 648, 650, 651]
    array_idx = idx - 2 + 1
    if array_idx >= 1 && array_idx <= length(local_types)
        println("Local $idx: $(local_types[array_idx])")
    else
        println("Local $idx: OUT OF RANGE (array_idx=$array_idx)")
    end
end
