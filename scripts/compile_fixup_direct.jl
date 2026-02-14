# Test fixup_Expr_child with directly constructed Expr
using WasmTarget
using JuliaSyntax

# Create a simple Expr and pass it through fixup_Expr_child
function test_fixup_simple()
    e = Expr(:call, :+, 1, 1)
    wrapper_head = JuliaSyntax.SyntaxHead(JuliaSyntax.Kind(0x0010), UInt16(0))
    result = JuliaSyntax.fixup_Expr_child(wrapper_head, e, false)
    if result === nothing
        return Int32(0)
    elseif result isa Expr
        return Int32(1)
    else
        return Int32(2)
    end
end

# Return the fixup result directly
function test_fixup_return()
    e = Expr(:call, :+, 1, 1)
    wrapper_head = JuliaSyntax.SyntaxHead(JuliaSyntax.Kind(0x0010), UInt16(0))
    return JuliaSyntax.fixup_Expr_child(wrapper_head, e, false)
end

# For comparison: return an Expr directly
function test_return_expr()
    return Expr(:call, :+, 1, 1)
end

println("Compiling...")
for (name, f, types) in [
    ("test_fixup_simple", test_fixup_simple, ()),
    ("test_fixup_return", test_fixup_return, ()),
    ("test_return_expr", test_return_expr, ()),
]
    try
        bytes = compile(f, types)
        fname = "/Users/daleblack/Documents/dev/GroupTherapyOrg/WasmTarget.jl/browser/$name.wasm"
        write(fname, bytes)
        run(`wasm-tools validate $fname`)
        println("  $name: $(length(bytes)) bytes, VALIDATES")
    catch e
        println("  $name: ERROR: $(sprint(showerror, e)[1:min(end,200)])")
    end
end
