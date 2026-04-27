() -> begin
    code_block = "bg-warm-900 dark:bg-warm-950 p-4 rounded text-sm font-mono overflow-x-auto"

    sections = [
        ("installation", "Installation"),
        ("first-compile", "First Compilation"),
        ("multiple", "Multiple Functions"),
        ("optimization", "Optimization"),
    ]

    PageWithTOC(sections, Div(:class => "space-y-10",
        H1(:class => "text-3xl font-serif font-bold text-warm-900 dark:text-warm-100", "Getting Started"),

        # ── Installation ──
        H2(:id => "installation", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Installation"),
        Pre(:class => code_block, Code(:class => "language-julia", """using Pkg
Pkg.add(url="https://github.com/GroupTherapyOrg/WasmTarget.jl")""")),
        Div(:class => "border border-warm-200 dark:border-warm-800 rounded-lg p-5 space-y-2 bg-warm-100/50 dark:bg-warm-900/50",
            P(:class => "text-sm font-semibold text-warm-800 dark:text-warm-200", "Requirements"),
            Ul(:class => "list-disc ml-5 space-y-1 text-sm text-warm-600 dark:text-warm-400",
                Li("Julia 1.12 (required — IR format is version-specific)"),
                Li("Node.js 22+ or a WasmGC-capable browser (Chrome 119+, Firefox 120+)")
            ),
            P(:class => "text-sm font-semibold text-warm-800 dark:text-warm-200 pt-2", "Optional"),
            Ul(:class => "list-disc ml-5 space-y-1 text-sm text-warm-600 dark:text-warm-400",
                Li(A(:href => "https://github.com/WebAssembly/binaryen", :target => "_blank", :class => "text-accent-500 underline", "Binaryen"),
                   " (", Code(:class => "text-accent-500 font-mono text-xs", "wasm-opt"), ") for optimization"),
                Li(A(:href => "https://github.com/bytecodealliance/wasm-tools", :target => "_blank", :class => "text-accent-500 underline", "wasm-tools"),
                   " for validation")
            )
        ),

        # ── First Compilation ──
        H2(:id => "first-compile", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "First Compilation"),
        Pre(:class => code_block, Code(:class => "language-julia", """using WasmTarget

add(a::Int32, b::Int32)::Int32 = a + b
bytes = compile(add, (Int32, Int32))
write("add.wasm", bytes)""")),
        P(:class => "text-warm-600 dark:text-warm-400", "Run it from Node:"),
        Pre(:class => code_block, Code(:class => "language-bash", """node -e '
  const fs = require("fs");
  WebAssembly.instantiate(fs.readFileSync("add.wasm"))
    .then(m => console.log(m.instance.exports.add(3, 7)));
'
# => 10""")),

        # ── Multiple Functions ──
        H2(:id => "multiple", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Multiple Functions"),
        Pre(:class => code_block, Code(:class => "language-julia", """square(x::Float64)::Float64 = x * x
cube(x::Float64)::Float64 = x * square(x)

bytes = compile_multi([
    (square, (Float64,)),
    (cube,   (Float64,)),
])""")),
        P(:class => "text-warm-600 dark:text-warm-400",
            "Both are exported. ", Code(:class => "text-accent-500", "cube"),
            " calls ", Code(:class => "text-accent-500", "square"), " inside the module."),

        # ── Optimization ──
        H2(:id => "optimization", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Optimization"),
        Pre(:class => code_block, Code(:class => "language-julia", """bytes = compile(sin, (Float64,); optimize=true)""")),
        P(:class => "text-warm-600 dark:text-warm-400",
            "Requires ", Code(:class => "text-accent-500 font-mono", "wasm-opt"),
            " installed. Typical size reduction is 80–90%.")
    ))
end
