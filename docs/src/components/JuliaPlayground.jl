# JuliaPlayground.jl - True Rust Playground-style Julia REPL
#
# Architecture:
# - Ships trimmed Julia runtime (~2-5MB WASM) to browser
# - User writes ANY Julia code in editable textarea
# - "Run" compiles code via Julia compiler running in browser
# - Compiled WASM executes and shows result
#
# This is like Rust Playground - the compiler runs IN the browser,
# not on a server. Requires Julia 1.12 trimming.

# Starter code shown when page loads
const STARTER_CODE = """
# Write any Julia code here!
# The trimmed Julia compiler runs in your browser.

function hello(n::Int32)::Int32
    result = Int32(0)
    i = Int32(1)
    while i <= n
        result = result + i
        i = i + Int32(1)
    end
    return result
end

# Call: hello(10)
"""

# Example snippets user can load
const SNIPPETS = [
    (
        name = "Sum to N",
        code = """function sum_to_n(n::Int32)::Int32
    result = Int32(0)
    i = Int32(1)
    while i <= n
        result = result + i
        i = i + Int32(1)
    end
    return result
end

# Call: sum_to_n(100)"""
    ),
    (
        name = "Fibonacci",
        code = """function fibonacci(n::Int32)::Int32
    if n <= 1
        return n
    end
    return fibonacci(n - Int32(1)) + fibonacci(n - Int32(2))
end

# Call: fibonacci(10)"""
    ),
    (
        name = "Factorial",
        code = """function factorial(n::Int32)::Int32
    if n <= 1
        return Int32(1)
    end
    return n * factorial(n - Int32(1))
end

# Call: factorial(5)"""
    ),
    (
        name = "Is Prime",
        code = """function is_prime(n::Int32)::Int32
    if n <= 1
        return Int32(0)
    end
    if n <= 3
        return Int32(1)
    end
    if n % Int32(2) == 0
        return Int32(0)
    end
    i = Int32(3)
    while i * i <= n
        if n % i == 0
            return Int32(0)
        end
        i = i + Int32(2)
    end
    return Int32(1)
end

# Call: is_prime(17)"""
    ),
    (
        name = "GCD",
        code = """function gcd(a::Int32, b::Int32)::Int32
    while b != Int32(0)
        t = b
        b = a % b
        a = t
    end
    return a
end

# Call: gcd(48, 18)"""
    )
]

"""
Julia Playground - True REPL with arbitrary code execution.

User writes any Julia code in an editable textarea.
When trimmed Julia runtime is ready, "Run" compiles and executes it.
"""
JuliaPlayground = island(:JuliaPlayground) do
    # State
    code, set_code = create_signal(STARTER_CODE)
    output, set_output = create_signal("")
    is_running, set_is_running = create_signal(false)
    runtime_loaded, set_runtime_loaded = create_signal(false)

    Div(:class => "max-w-6xl mx-auto",
        # Top bar: Snippet loader + Run button
        Div(:class => "flex items-center justify-between mb-4 gap-4 flex-wrap",
            # Left: Snippet selector
            Div(:class => "flex items-center gap-2",
                Label(:class => "text-stone-600 dark:text-stone-400 text-sm font-medium", "Load snippet:"),
                Select(:class => "bg-stone-100 dark:bg-stone-800 border border-stone-300 dark:border-stone-600 rounded-lg px-3 py-2 text-stone-800 dark:text-stone-200 text-sm",
                    :on_change => (e) -> begin
                        idx = parse(Int, e.target.value)
                        if idx > 0
                            set_code(SNIPPETS[idx].code)
                            set_output("")
                        end
                    end,
                    Option(:value => "0", "Select example..."),
                    [Option(:value => string(i), snippet.name) for (i, snippet) in enumerate(SNIPPETS)]...
                )
            ),

            # Right: Run button
            Button(:class => "flex items-center gap-2 bg-cyan-500 hover:bg-cyan-600 disabled:bg-stone-400 text-white px-6 py-2 rounded-lg font-semibold transition-colors shadow-lg shadow-cyan-500/20",
                :on_click => () -> compile_and_run(code(), set_output, set_is_running, runtime_loaded()),
                :disabled => is_running(),
                # Play icon
                Svg(:class => "w-4 h-4", :fill => "currentColor", :viewBox => "0 0 24 24",
                    Path(:d => "M8 5v14l11-7z")
                ),
                is_running() ? "Compiling..." : "Run"
            )
        ),

        # Main content: Editor + Output side by side
        Div(:class => "grid lg:grid-cols-2 gap-4",
            # Code editor panel
            Div(:class => "flex flex-col",
                Div(:class => "flex items-center justify-between px-4 py-2 bg-stone-700 dark:bg-stone-800 rounded-t-xl",
                    Span(:class => "text-stone-300 text-sm font-medium", "Julia"),
                    Span(:class => "text-stone-500 text-xs", "Edit freely")
                ),
                Textarea(:class => "bg-stone-800 dark:bg-stone-900 p-4 rounded-b-xl text-sm text-stone-100 font-mono min-h-[400px] w-full resize-y focus:outline-none focus:ring-2 focus:ring-cyan-500",
                    :value => code,
                    :on_input => (e) -> set_code(e.target.value),
                    :spellcheck => "false"
                )
            ),

            # Output panel
            Div(:class => "flex flex-col",
                Div(:class => "flex items-center justify-between px-4 py-2 bg-stone-700 dark:bg-stone-800 rounded-t-xl",
                    Span(:class => "text-stone-300 text-sm font-medium", "Output"),
                    # Status indicator
                    runtime_loaded() ?
                        Span(:class => "flex items-center gap-1 text-green-400 text-xs",
                            Span(:class => "w-2 h-2 bg-green-400 rounded-full"),
                            "Runtime ready"
                        ) :
                        Span(:class => "flex items-center gap-1 text-amber-400 text-xs",
                            Span(:class => "w-2 h-2 bg-amber-400 rounded-full animate-pulse"),
                            "Loading runtime..."
                        )
                ),
                Div(:class => "bg-stone-900 dark:bg-black p-4 rounded-b-xl flex-1 min-h-[400px] font-mono overflow-auto",
                    output() == "" ?
                        Div(:class => "text-stone-500 text-sm space-y-2",
                            P("Click 'Run' to compile and execute your code."),
                            P(:class => "text-xs mt-4",
                                "The Julia compiler runs entirely in your browser via WebAssembly."
                            )
                        ) :
                        Pre(:class => "text-sm whitespace-pre-wrap",
                            output()
                        )
                )
            )
        ),

        # Footer info
        Div(:class => "mt-6 p-4 bg-stone-100 dark:bg-stone-800 rounded-xl",
            Div(:class => "flex items-start gap-3",
                # Info icon
                Div(:class => "flex-shrink-0 w-8 h-8 bg-cyan-500 rounded-full flex items-center justify-center",
                    Svg(:class => "w-4 h-4 text-white", :fill => "currentColor", :viewBox => "0 0 24 24",
                        Path(:d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                    )
                ),
                Div(
                    P(:class => "text-stone-700 dark:text-stone-200 font-medium text-sm",
                        "How it works"
                    ),
                    P(:class => "text-stone-500 dark:text-stone-400 text-xs mt-1",
                        "A trimmed Julia runtime (~2-5MB) runs in your browser. When you click Run, your code is parsed by JuliaSyntax, type-inferred, and compiled to WebAssembly by WasmTarget.jl - all client-side. No server required."
                    ),
                    P(:class => "text-stone-400 dark:text-stone-500 text-xs mt-2",
                        "Powered by Julia 1.12 trimming and WasmGC."
                    )
                )
            )
        )
    )
end

"""
Compile and run the Julia code.

When runtime_loaded is true, this will:
1. Parse the code using JuliaSyntax (running in browser as WASM)
2. Type-infer using Julia's compiler (running in browser as WASM)
3. Generate WASM bytecode using WasmTarget.jl (running in browser as WASM)
4. Instantiate and execute the generated WASM
5. Return the result

For now, shows status messages while runtime is being developed.
"""
function compile_and_run(code_str, set_output, set_is_running, runtime_ready)
    set_is_running(true)

    if !runtime_ready
        # Runtime not yet loaded - show informative message
        set_output("""
<span class="text-amber-400">Trimmed Julia runtime loading...</span>

The browser-based Julia compiler requires:
- JuliaSyntax.jl (parser)
- Type inference
- WasmTarget.jl (codegen)

This is compiled to ~2-5MB of WebAssembly using Julia 1.12's
experimental trimming feature.

<span class="text-stone-500">Status: In development</span>
<span class="text-stone-500">See: https://github.com/GroupTherapyOrg/WasmTarget.jl</span>
""")
        set_is_running(false)
        return
    end

    # When runtime is ready, this will actually compile and run
    # For now, placeholder for the JS interop that will call the WASM compiler
    try
        set_output("Parsing...")
        # js_call(:julia_parse, code_str)

        set_output("Type inferring...")
        # js_call(:julia_infer, ast)

        set_output("Generating WASM...")
        # wasm_bytes = js_call(:wasmtarget_compile, typed_ir)

        set_output("Executing...")
        # result = js_call(:wasm_run, wasm_bytes)

        set_output("<span class=\"text-cyan-400\">Result: [coming with trimmed runtime]</span>")
    catch e
        set_output("<span class=\"text-red-400\">Error: $(e)</span>")
    end

    set_is_running(false)
end
