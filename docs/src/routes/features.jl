# Features page - Supported Julia features with static code examples
#
# Uses Suite.jl components for visual presentation.
# All 4 WASM demos REMOVED (W4 cleanup) — replaced with static Suite.CodeBlock.

import Suite

function Features()
    Div(
        # Header
        Div(:class => "py-8 text-center",
            H1(:class => "text-4xl font-serif font-semibold text-warm-800 dark:text-warm-100 mb-4",
                "Supported Features"
            ),
            P(:class => "text-xl text-warm-500 dark:text-warm-400 max-w-2xl mx-auto",
                "Julia features that compile to WebAssembly with WasmTarget.jl"
            )
        ),

        # Feature demos (static)
        Div(:class => "space-y-16",
            # Arithmetic
            _FeatureSection(
                "Integer Arithmetic",
                "Native i32/i64 operations compile to direct WASM instructions",
                """add(a::Int32, b::Int32)::Int32 = a + b
multiply(a::Int32, b::Int32)::Int32 = a * b
divide(a::Int32, b::Int32)::Int32 = div(a, b)""",
                """# Example results:
# add(12, 5)      → 17
# multiply(12, 5) → 60
# divide(12, 5)   → 2

# Compiles to WASM i32.add, i32.mul, i32.div_s instructions"""
            ),

            # Control Flow
            _FeatureSection(
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
                """# Example results:
# sign(5)  → 1
# sign(-3) → -1
# sign(0)  → 0

# Compiles to nested WASM if/else blocks with i32.gt_s, i32.lt_s"""
            ),

            # Recursion
            _FeatureSection(
                "Recursion",
                "Self-recursive calls compile to WASM call instructions",
                """function factorial(n::Int32)::Int32
    if n <= 1
        return Int32(1)
    end
    return n * factorial(n - Int32(1))
end""",
                """# Example results:
# factorial(0) → 1
# factorial(1) → 1
# factorial(5) → 120
# factorial(6) → 720

# Compiles to WASM call instruction (self-reference)"""
            ),

            # Loops
            _FeatureSection(
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
                """# Example results:
# sum_to_n(10)  → 55
# sum_to_n(100) → 5050

# Compiles to WASM loop + br_if for the while condition"""
            )
        ),

        # Full feature list
        Div(:class => "py-16 mt-8",
            H2(:class => "text-2xl font-serif font-semibold text-center text-warm-800 dark:text-warm-100 mb-8",
                "Complete Feature List"
            ),
            Div(:class => "grid md:grid-cols-2 lg:grid-cols-3 gap-4 px-8 max-w-5xl mx-auto",
                # Supported
                _FeatureItem("Integers", "i32, i64, u32, u64", true),
                _FeatureItem("Floats", "f32, f64", true),
                _FeatureItem("Arithmetic", "+, -, *, /, %, ^", true),
                _FeatureItem("Comparisons", "==, !=, <, >, <=, >=", true),
                _FeatureItem("Bitwise", "&, |, xor, <<, >>", true),
                _FeatureItem("Booleans", "&&, ||, !", true),
                _FeatureItem("if/else", "Conditionals", true),
                _FeatureItem("while", "Loops", true),
                _FeatureItem("for", "Range loops", true),
                _FeatureItem("Recursion", "Self & mutual", true),
                _FeatureItem("Structs", "WasmGC structs", true),
                _FeatureItem("Tuples", "Immutable", true),
                _FeatureItem("Vector{T}", "1D arrays", true),
                _FeatureItem("Strings", "Concat, compare", true),
                _FeatureItem("Closures", "Captured vars", true),
                _FeatureItem("Exceptions", "try/catch/throw", true),
                _FeatureItem("Union{Nothing,T}", "Optional types", true),
                _FeatureItem("JS Interop", "externref, imports", true),

                # Coming soon
                _FeatureItem("Matrix{T}", "Multi-dim arrays", false),
                _FeatureItem("Full Dict", "Hash tables", false),
                _FeatureItem("Varargs", "Variable args", false)
            )
        ),

        # Advanced Examples Section
        Div(:class => "py-16 mt-8",
            H2(:class => "text-2xl font-serif font-semibold text-center text-warm-800 dark:text-warm-100 mb-4",
                "Advanced Examples"
            ),
            P(:class => "text-center text-warm-500 dark:text-warm-400 mb-8 max-w-2xl mx-auto",
                "See how WasmTarget.jl features combine for real-world patterns. All examples are tested in the main test suite."
            ),

            # Reactive State Pattern (Counter)
            Suite.Card(class="max-w-4xl mx-auto mb-8",
                Suite.CardHeader(
                    Div(:class => "flex items-start justify-between flex-wrap gap-2",
                        Div(
                            Suite.CardTitle("Reactive State Pattern"),
                            Suite.CardDescription("WASM globals for state + exported functions as event handlers (Therapy.jl pattern)")
                        ),
                        A(:href => "https://github.com/GroupTherapyOrg/WasmTarget.jl/blob/main/test/runtests.jl#L1455",
                          :class => "text-xs text-accent-500 hover:text-accent-600 dark:text-accent-400 flex items-center gap-1",
                          :target => "_blank",
                            Svg(:class => "w-4 h-4", :fill => "currentColor", :viewBox => "0 0 24 24",
                                Path(:d => "M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z")
                            ),
                            "View test on GitHub"
                        )
                    )
                ),
                Suite.CardContent(
                    Suite.CodeBlock("""# WASM globals serve as reactive state (like Signals)
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
add_export!(mod, "increment", 0, func_idx)""", language="julia"),
                    P(:class => "text-warm-500 dark:text-warm-400 text-xs mt-4",
                        "This pattern enables Therapy.jl to store reactive state in WASM globals and generate event handlers as exported functions."
                    )
                )
            ),

            # Low-level Builder API
            Suite.Card(class="max-w-4xl mx-auto",
                Suite.CardHeader(
                    Div(:class => "flex items-start justify-between flex-wrap gap-2",
                        Div(
                            Suite.CardTitle("Low-Level Builder API"),
                            Suite.CardDescription("Tables, memory, and data segments for advanced use cases")
                        ),
                        A(:href => "https://github.com/GroupTherapyOrg/WasmTarget.jl/blob/main/test/runtests.jl#L1477",
                          :class => "text-xs text-accent-500 hover:text-accent-600 dark:text-accent-400 flex items-center gap-1",
                          :target => "_blank",
                            Svg(:class => "w-4 h-4", :fill => "currentColor", :viewBox => "0 0 24 24",
                                Path(:d => "M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z")
                            ),
                            "View test on GitHub"
                        )
                    )
                ),
                Suite.CardContent(
                    Suite.CodeBlock("""# Tables for function references (dynamic dispatch)
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
# This enables runtime function selection""", language="julia"),
                    P(:class => "text-warm-500 dark:text-warm-400 text-xs mt-4",
                        "Function tables enable indirect calls for dynamic dispatch patterns and callback registries."
                    )
                )
            )
        ),

        # CTA
        Div(:class => "py-12 text-center",
            A(:href => "./manual/",
                Suite.Button(size="lg", "Read the Manual")
            )
        )
    )
end

# --- Helper: Feature section with static code + output ---
function _FeatureSection(title, subtitle, code, output)
    Suite.Card(class="max-w-5xl mx-auto",
        Suite.CardHeader(
            Suite.CardTitle(title),
            Suite.CardDescription(subtitle)
        ),
        Suite.CardContent(
            Div(:class => "grid lg:grid-cols-2 gap-6",
                Div(
                    P(:class => "text-xs font-medium text-warm-500 dark:text-warm-400 mb-2", "Julia Code"),
                    Suite.CodeBlock(code, language="julia")
                ),
                Div(
                    P(:class => "text-xs font-medium text-warm-500 dark:text-warm-400 mb-2", "Output"),
                    Suite.CodeBlock(output, language="julia")
                )
            )
        )
    )
end

# --- Helper: Feature list item with Suite.Card ---
function _FeatureItem(name, detail, supported)
    Suite.Card(class=supported ? "" : "opacity-50",
        Suite.CardContent(class="p-3",
            Div(:class => "flex items-center gap-3",
                Span(:class => supported ? "text-green-500 text-lg" : "text-warm-400 text-lg",
                    supported ? "✓" : "○"
                ),
                Div(
                    P(:class => "font-medium text-warm-800 dark:text-warm-100 text-sm", name),
                    P(:class => "text-warm-500 dark:text-warm-400 text-xs", detail)
                )
            )
        )
    )
end

# Export
Features
