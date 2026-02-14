using WasmTarget

# Check if WasmTarget defines ! on something unexpected
f = (!)
ms = methods(f)
println("Total ! methods: $(length(ms))")
for m in ms
    mod = m.module
    if mod !== Base && mod !== Core
        println("  Non-Base/Core: $m from module $mod")
    end
end
