# Build-Time Compilation Showcase
#
# Static page demonstrating WasmTarget.jl's compile() and compile_multi()
# capabilities. Shows Julia input → WASM output pairs as static code examples.
# Runtime compilation (eval_julia.wasm) is paused — noted in "Coming Soon" alert.

import Suite

function PlaygroundPage()
    Div(:class => "w-full max-w-4xl mx-auto py-8",

        # Header
        Div(:class => "text-center mb-10",
            H1(:class => "text-3xl font-serif font-semibold text-warm-800 dark:text-warm-100",
                "Build-Time Compilation Showcase"
            ),
            P(:class => "text-warm-500 dark:text-warm-400 mt-2 max-w-2xl mx-auto",
                "WasmTarget.jl compiles Julia functions to WebAssembly at build time. ",
                "Here are examples of ", Code(:class => "text-accent-600 dark:text-accent-400", "compile()"),
                " in action."
            ),
            Div(:class => "mt-3 flex justify-center gap-2",
                Suite.Badge("Build-Time"),
                Suite.Badge(variant="secondary", "Julia → WASM")
            )
        ),

        # Example 1: Arithmetic
        Suite.Card(class="mb-8",
            Suite.CardHeader(
                Suite.CardTitle("Arithmetic Functions"),
                Suite.CardDescription("Integer operations compile to direct WASM i32 instructions")
            ),
            Suite.CardContent(
                P(:class => "text-sm text-warm-600 dark:text-warm-400 mb-3", "Julia source:"),
                Suite.CodeBlock("""function add(a::Int32, b::Int32)::Int32
    return a + b
end

function multiply(a::Int32, b::Int32)::Int32
    return a * b
end""", language="julia"),
                P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-4 mb-3", "Compiles to WebAssembly:"),
                Suite.CodeBlock("""(module
  (func \$add (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add)
  (func \$multiply (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.mul))""", language="wasm")
            )
        ),

        # Example 2: Control Flow
        Suite.Card(class="mb-8",
            Suite.CardHeader(
                Suite.CardTitle("Control Flow"),
                Suite.CardDescription("if/else branches compile to WASM if/else blocks")
            ),
            Suite.CardContent(
                P(:class => "text-sm text-warm-600 dark:text-warm-400 mb-3", "Julia source:"),
                Suite.CodeBlock("""function abs_val(n::Int32)::Int32
    if n < Int32(0)
        return -n
    else
        return n
    end
end""", language="julia"),
                P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-4 mb-3", "Compiles to WebAssembly:"),
                Suite.CodeBlock("""(module
  (func \$abs_val (param i32) (result i32)
    local.get 0
    i32.const 0
    i32.lt_s
    if (result i32)
      i32.const 0
      local.get 0
      i32.sub
    else
      local.get 0
    end))""", language="wasm")
            )
        ),

        # Example 3: Loops
        Suite.Card(class="mb-8",
            Suite.CardHeader(
                Suite.CardTitle("Loops & Accumulation"),
                Suite.CardDescription("while loops compile to WASM loop/br_if instructions")
            ),
            Suite.CardContent(
                P(:class => "text-sm text-warm-600 dark:text-warm-400 mb-3", "Julia source:"),
                Suite.CodeBlock("""function sum_to(n::Int32)::Int32
    result = Int32(0)
    i = Int32(1)
    while i <= n
        result = result + i
        i = i + Int32(1)
    end
    return result
end""", language="julia"),
                P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-4 mb-3", "Compiles to WebAssembly:"),
                Suite.CodeBlock("""(module
  (func \$sum_to (param i32) (result i32)
    (local i32 i32)       ;; result, i
    i32.const 0
    local.set 1           ;; result = 0
    i32.const 1
    local.set 2           ;; i = 1
    block \$break
      loop \$continue
        local.get 2
        local.get 0
        i32.gt_s
        br_if \$break      ;; break if i > n
        local.get 1
        local.get 2
        i32.add
        local.set 1       ;; result += i
        local.get 2
        i32.const 1
        i32.add
        local.set 2       ;; i += 1
        br \$continue
      end
    end
    local.get 1))""", language="wasm")
            )
        ),

        # Architecture explanation
        Suite.Card(class="mb-8",
            Suite.CardHeader(
                Suite.CardTitle("How It Works"),
                Suite.CardDescription("The compilation pipeline from Julia to WebAssembly")
            ),
            Suite.CardContent(
                Div(:class => "space-y-4",
                    _PipelineStep("1", "Julia AST",
                        "Your Julia function is parsed and lowered to a typed intermediate representation using Julia's compiler infrastructure."
                    ),
                    _PipelineStep("2", "WasmTarget IR",
                        "Type inference maps Julia types to WASM types (Int32→i32, Float64→f64). Control flow, function calls, and memory operations are translated to WASM instructions."
                    ),
                    _PipelineStep("3", "WASM Binary",
                        "The IR is serialized to a valid .wasm binary module. The output can be loaded by any WebAssembly runtime — browsers, Node.js, or Wasmtime."
                    )
                ),
                Div(:class => "mt-6",
                    P(:class => "text-sm text-warm-600 dark:text-warm-400 mb-3", "Usage:"),
                    Suite.CodeBlock("""using WasmTarget

# Single function
wasm_bytes = compile(add, (Int32, Int32))
write("add.wasm", wasm_bytes)

# Multiple functions in one module
wasm_bytes = compile_multi([
    (add, (Int32, Int32)),
    (multiply, (Int32, Int32)),
    (sum_to, (Int32,))
])
write("math.wasm", wasm_bytes)""", language="julia")
                )
            )
        ),

        # Coming Soon callout
        Suite.Alert(class="mb-8",
            Suite.AlertTitle("Coming Soon: Runtime Compilation"),
            Suite.AlertDescription(
                "A future goal is to compile arbitrary Julia expressions to WebAssembly directly in the browser — " *
                "no server required. This would enable an interactive playground where you can type Julia code and see " *
                "it compiled and executed as WASM in real time. Build-time compilation via ",
                Code(:class => "text-accent-600 dark:text-accent-400", "compile()"),
                " and ",
                Code(:class => "text-accent-600 dark:text-accent-400", "compile_multi()"),
                " is fully working today and powers ",
                A(:href => "https://github.com/GroupTherapyOrg/Therapy.jl", :class => "text-accent-500 hover:text-accent-600 dark:text-accent-400 underline", :target => "_blank", "Therapy.jl"),
                " and ",
                A(:href => "https://github.com/GroupTherapyOrg/Sessions.jl", :class => "text-accent-500 hover:text-accent-600 dark:text-accent-400 underline", :target => "_blank", "Sessions.jl"),
                "."
            )
        ),

        # CTA
        Div(:class => "text-center py-4",
            Div(:class => "flex justify-center gap-4",
                A(:href => "./features/",
                    Suite.Button("See All Features")
                ),
                A(:href => "./api/",
                    Suite.Button(variant="outline", "API Reference")
                )
            )
        )
    )
end

# --- Helper: Pipeline step ---
function _PipelineStep(number, title, description)
    Div(:class => "flex gap-4",
        Div(:class => "flex-shrink-0 w-8 h-8 rounded-full bg-accent-100 dark:bg-accent-900 flex items-center justify-center",
            Span(:class => "text-sm font-bold text-accent-700 dark:text-accent-300", number)
        ),
        Div(
            H4(:class => "font-semibold text-warm-800 dark:text-warm-100", title),
            P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-1", description)
        )
    )
end

# Export
PlaygroundPage
