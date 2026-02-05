# Features page - Supported Julia features with live WASM demos
#
# These are PRE-COMPILED WASM examples demonstrating what WasmTarget.jl supports.
# Unlike the playground (which compiles arbitrary code), these demos show
# specific features with interactive inputs that run actual compiled WASM.
#
# Demo components are defined in components/Demos.jl

function Features()
    Div(
        # Header
        Div(:class => "py-8 text-center",
            H1(:class => "text-4xl font-bold text-warm-800 dark:text-warm-100 mb-4",
                "Supported Features"
            ),
            P(:class => "text-xl text-warm-500 dark:text-warm-400 max-w-2xl mx-auto",
                "Pre-compiled WASM demos showing what Julia features compile to WebAssembly"
            )
        ),

        # Feature demos
        Div(:class => "space-y-16",
            # Arithmetic
            FeatureSection(
                "Integer Arithmetic",
                "Native i32/i64 operations compile to direct WASM instructions",
                """add(a::Int32, b::Int32)::Int32 = a + b
multiply(a::Int32, b::Int32)::Int32 = a * b
divide(a::Int32, b::Int32)::Int32 = div(a, b)""",
                ArithmeticDemo()
            ),

            # Control Flow
            FeatureSection(
                "Control Flow",
                "if/elseif/else compiles to WASM if/else blocks",
                """function sign(n::Int32)::Int32
    if n > 0
        return Int32(1)
    elseif n < 0
        return Int32(-1)
    else
        return Int32(0)
    end
end""",
                ControlFlowDemo()
            ),

            # Recursion
            FeatureSection(
                "Recursion",
                "Self-recursive calls compile to WASM call instructions",
                """function factorial(n::Int32)::Int32
    if n <= 1
        return Int32(1)
    end
    return n * factorial(n - Int32(1))
end""",
                RecursionDemo()
            ),

            # Loops
            FeatureSection(
                "Loops",
                "while and for loops compile to WASM loop/br instructions",
                """function sum_to_n(n::Int32)::Int32
    result = Int32(0)
    i = Int32(1)
    while i <= n
        result = result + i
        i = i + Int32(1)
    end
    return result
end""",
                LoopDemo()
            )
        ),

        # Full feature list
        Div(:class => "py-16 mt-8 bg-warm-50 dark:bg-warm-900 rounded-2xl",
            H2(:class => "text-2xl font-bold text-center text-warm-800 dark:text-warm-100 mb-8",
                "Complete Feature List"
            ),
            Div(:class => "grid md:grid-cols-2 lg:grid-cols-3 gap-4 px-8 max-w-5xl mx-auto",
                # Supported
                FeatureItem("Integers", "i32, i64, u32, u64", true),
                FeatureItem("Floats", "f32, f64", true),
                FeatureItem("Arithmetic", "+, -, *, /, %, ^", true),
                FeatureItem("Comparisons", "==, !=, <, >, <=, >=", true),
                FeatureItem("Bitwise", "&, |, xor, <<, >>", true),
                FeatureItem("Booleans", "&&, ||, !", true),
                FeatureItem("if/else", "Conditionals", true),
                FeatureItem("while", "Loops", true),
                FeatureItem("for", "Range loops", true),
                FeatureItem("Recursion", "Self & mutual", true),
                FeatureItem("Structs", "WasmGC structs", true),
                FeatureItem("Tuples", "Immutable", true),
                FeatureItem("Vector{T}", "1D arrays", true),
                FeatureItem("Strings", "Concat, compare", true),
                FeatureItem("Closures", "Captured vars", true),
                FeatureItem("Exceptions", "try/catch/throw", true),
                FeatureItem("Union{Nothing,T}", "Optional types", true),
                FeatureItem("JS Interop", "externref, imports", true),

                # Coming soon
                FeatureItem("Matrix{T}", "Multi-dim arrays", false),
                FeatureItem("Full Dict", "Hash tables", false),
                FeatureItem("Varargs", "Variable args", false)
            )
        ),

        # Advanced Examples Section
        Div(:class => "py-16 mt-8",
            H2(:class => "text-2xl font-bold text-center text-warm-800 dark:text-warm-100 mb-4",
                "Advanced Examples"
            ),
            P(:class => "text-center text-warm-500 dark:text-warm-400 mb-8 max-w-2xl mx-auto",
                "See how WasmTarget.jl features combine for real-world patterns. All examples are tested in the main test suite."
            ),

            # Reactive State Pattern (Counter)
            Div(:class => "max-w-4xl mx-auto bg-warm-50 dark:bg-warm-900 rounded-2xl p-8 mb-8",
                Div(:class => "flex items-start justify-between mb-4 flex-wrap gap-2",
                    Div(
                        H3(:class => "text-xl font-bold text-warm-800 dark:text-warm-100",
                            "Reactive State Pattern"
                        ),
                        P(:class => "text-warm-500 dark:text-warm-400 text-sm mt-1",
                            "WASM globals for state + exported functions as event handlers (Therapy.jl pattern)"
                        )
                    ),
                    A(:href => "https://github.com/GroupTherapyOrg/WasmTarget.jl/blob/main/test/runtests.jl#L1455",
                      :class => "text-xs text-accent-500 hover:text-accent-600 dark:text-accent-400 flex items-center gap-1",
                      :target => "_blank",
                        Svg(:class => "w-4 h-4", :fill => "currentColor", :viewBox => "0 0 24 24",
                            Path(:d => "M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z")
                        ),
                        "View test on GitHub"
                    )
                ),
                Pre(:class => "bg-warm-800 dark:bg-warm-900 rounded-xl p-4 overflow-x-auto text-sm",
                    Code(:class => "text-warm-100 font-mono", """# WASM globals serve as reactive state (like Signals)
mod = WasmModule()

# Add mutable i32 global initialized to 0
count_idx = add_global!(mod, I32, true, 0)

# Export the global so JS can read it
add_global_export!(mod, "count", count_idx)

# Increment function - modifies global, JS calls it on click
increment_body = UInt8[
    Opcode.GLOBAL_GET, 0x00,  # get count
    Opcode.I32_CONST, 0x01,   # push 1
    Opcode.I32_ADD,           # add
    Opcode.GLOBAL_SET, 0x00,  # set count
    Opcode.END
]
func_idx = add_function!(mod, [], [], [], increment_body)
add_export!(mod, "increment", 0, func_idx)""")
                ),
                P(:class => "text-warm-500 dark:text-warm-400 text-xs mt-4",
                    "This pattern enables Therapy.jl to store reactive state in WASM globals and generate event handlers as exported functions."
                )
            ),

            # Low-level Builder API
            Div(:class => "max-w-4xl mx-auto bg-warm-50 dark:bg-warm-900 rounded-2xl p-8",
                Div(:class => "flex items-start justify-between mb-4 flex-wrap gap-2",
                    Div(
                        H3(:class => "text-xl font-bold text-warm-800 dark:text-warm-100",
                            "Low-Level Builder API"
                        ),
                        P(:class => "text-warm-500 dark:text-warm-400 text-sm mt-1",
                            "Tables, memory, and data segments for advanced use cases"
                        )
                    ),
                    A(:href => "https://github.com/GroupTherapyOrg/WasmTarget.jl/blob/main/test/runtests.jl#L1477",
                      :class => "text-xs text-accent-500 hover:text-accent-600 dark:text-accent-400 flex items-center gap-1",
                      :target => "_blank",
                        Svg(:class => "w-4 h-4", :fill => "currentColor", :viewBox => "0 0 24 24",
                            Path(:d => "M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z")
                        ),
                        "View test on GitHub"
                    )
                ),
                Pre(:class => "bg-warm-800 dark:bg-warm-900 rounded-xl p-4 overflow-x-auto text-sm",
                    Code(:class => "text-warm-100 font-mono", """# Tables for function references (dynamic dispatch)
mod = WasmModule()
table_idx = add_table!(mod, FuncRef, 4)

# Add functions to populate the table
func_double = add_function!(mod, [I32], [I32], [],
    UInt8[LOCAL_GET, 0x00, I32_CONST, 0x02, I32_MUL, END])
func_triple = add_function!(mod, [I32], [I32], [],
    UInt8[LOCAL_GET, 0x00, I32_CONST, 0x03, I32_MUL, END])

# Element segment to initialize table slots
add_element_segment!(mod, table_idx, 0, [func_double, func_triple])

# call_indirect dispatches based on table index
# This enables runtime function selection""")
                ),
                P(:class => "text-warm-500 dark:text-warm-400 text-xs mt-4",
                    "Function tables enable indirect calls for dynamic dispatch patterns and callback registries."
                )
            )
        ),

        # CTA
        Div(:class => "py-12 text-center",
            A(:href => "./playground/",
              :class => "bg-accent-500 hover:bg-accent-600 text-white px-8 py-3 rounded-lg font-semibold transition-colors",
              "Try the Playground"
            )
        )
    )
end

function FeatureSection(title, subtitle, code, demo)
    Div(:class => "max-w-5xl mx-auto",
        # Header
        H2(:class => "text-2xl font-bold text-warm-800 dark:text-warm-100 mb-2", title),
        P(:class => "text-warm-500 dark:text-warm-400 mb-6", subtitle),

        # Content: code + demo
        Div(:class => "grid lg:grid-cols-2 gap-6",
            # Code
            Pre(:class => "bg-warm-800 dark:bg-warm-900 rounded-xl p-4 overflow-x-auto",
                Code(:class => "text-sm text-warm-100 font-mono", code)
            ),

            # Demo
            Div(:class => "flex items-center justify-center",
                demo
            )
        )
    )
end

function FeatureItem(name, detail, supported)
    Div(:class => "flex items-center gap-3 p-3 rounded-lg " *
                  (supported ? "bg-warm-50 dark:bg-warm-700" : "bg-warm-100 dark:bg-warm-900 opacity-50"),
        Span(:class => supported ? "text-green-500 text-lg" : "text-warm-400 text-lg",
            supported ? "✓" : "○"
        ),
        Div(
            P(:class => "font-medium text-warm-800 dark:text-warm-100 text-sm", name),
            P(:class => "text-warm-500 dark:text-warm-400 text-xs", detail)
        )
    )
end

# Export
Features
