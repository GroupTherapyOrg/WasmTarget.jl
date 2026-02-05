# LiveExample.jl - Reusable island component for interactive code examples
#
# Displays Julia code with syntax highlighting (via Prism.js) alongside
# an interactive output panel. Examples are pre-compiled to WASM at build time.
#
# This component is the core building block for the interactive Julia manual.
#
# Usage:
#   LiveExample(
#       code = "function add(a, b) a + b end",
#       description = "Basic addition function",
#       example = AdditionDemo
#   )
#
# Where AdditionDemo is an island that demonstrates the code interactively.

# =============================================================================
# LiveExample Component Factory
# =============================================================================

"""
Create a LiveExample component that displays code alongside an interactive demo.

Arguments:
- `code`: Julia source code to display (with syntax highlighting)
- `description`: Brief explanation of what the code demonstrates
- `example`: An island component that provides interactive demonstration
- `initial_output`: Initial text shown in the output area before interaction

The component layout:
┌─────────────────────────────────────────────────────────────┐
│ [description]                                               │
├─────────────────────────────────────────────────────────────┤
│ Julia Code (syntax highlighted)          │ Interactive Demo │
│                                          │                  │
│ function example(x)                      │  [Buttons/UI]    │
│     return x + 1                         │                  │
│ end                                      │  Output: 42      │
└─────────────────────────────────────────────────────────────┘
"""
function LiveExample(;
    code::String,
    description::String = "",
    example = nothing,
    initial_output::String = "Click Run or interact with the demo"
)
    # Generate a unique ID for this example (for JS targeting)
    example_id = string(hash(code) % 10000)

    Div(:class => "my-8 rounded-xl overflow-hidden border border-warm-200 dark:border-warm-700 shadow-sm",
        # Description header (if provided)
        description != "" ?
            Div(:class => "px-4 py-3 bg-warm-100 dark:bg-warm-800 border-b border-warm-200 dark:border-warm-700",
                P(:class => "text-sm text-warm-600 dark:text-warm-400", description)
            ) : nothing,

        # Main content: code + demo side by side on large screens
        Div(:class => "grid lg:grid-cols-2",
            # Left: Code display with syntax highlighting
            Div(:class => "relative",
                # Code header
                Div(:class => "flex items-center justify-between px-4 py-2 bg-warm-700 dark:bg-warm-800",
                    Span(:class => "text-warm-300 text-xs font-medium uppercase tracking-wider", "Julia"),
                    # Action buttons container
                    Div(:class => "flex items-center gap-3",
                        # Try in Playground link
                        A(:href => "../",
                          :class => "text-accent-400 hover:text-accent-300 text-xs flex items-center gap-1 transition-colors",
                          :data_code => code,
                          :onclick => "event.preventDefault(); localStorage.setItem('playground-code', this.dataset.code); window.location.href = this.href;",
                          :title => "Open this code in the main playground",
                            Svg(:class => "w-3.5 h-3.5", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                                Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                                     :d => "M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z")
                            ),
                            Span("Try in Playground")
                        ),
                        # Separator
                        Span(:class => "text-warm-500", "|"),
                        # Copy button
                        Button(:class => "text-warm-400 hover:text-white text-xs flex items-center gap-1 transition-colors",
                               :data_code => code,
                               :onclick => "navigator.clipboard.writeText(this.dataset.code).then(() => { this.textContent = 'Copied!'; setTimeout(() => this.textContent = 'Copy', 2000); })",
                            "Copy"
                        )
                    )
                ),
                # Code block with Prism.js highlighting
                Pre(:class => "bg-warm-800 dark:bg-warm-900 p-4 overflow-x-auto text-sm",
                    Code(:class => "language-julia text-warm-100 font-mono", code)
                )
            ),

            # Right: Interactive demo
            Div(:class => "flex flex-col bg-warm-50 dark:bg-warm-800",
                # Demo header
                Div(:class => "flex items-center justify-between px-4 py-2 bg-warm-100 dark:bg-warm-700 border-t lg:border-t-0 lg:border-l border-warm-200 dark:border-warm-600",
                    Span(:class => "text-warm-600 dark:text-warm-300 text-xs font-medium uppercase tracking-wider", "Interactive Demo"),
                    Span(:id => "status-$(example_id)", :class => "text-xs text-accent-500", "Ready")
                ),
                # Demo content
                Div(:class => "flex-1 p-4 border-t lg:border-t-0 lg:border-l border-warm-200 dark:border-warm-600",
                    # If example island provided, render it
                    example !== nothing ?
                        Div(:class => "h-full", example) :
                        # Otherwise show fallback
                        Div(:id => "fallback-$(example_id)",
                            :class => "h-full flex items-center justify-center text-warm-400 dark:text-warm-500 text-sm",
                            initial_output
                        )
                )
            )
        ),

        # Prism.js initialization script (runs after DOM ready)
        Script("""
            (function() {
                // Wait for Prism to be available
                if (typeof Prism !== 'undefined') {
                    Prism.highlightAll();
                } else {
                    // Prism not loaded yet, wait for it
                    document.addEventListener('DOMContentLoaded', function() {
                        if (typeof Prism !== 'undefined') {
                            Prism.highlightAll();
                        }
                    });
                }
            })();
        """)
    )
end

"""
Graceful fallback component shown when WASM fails to load.
Displays a static representation and error message.
"""
function LiveExampleFallback(; message::String = "Interactive demo unavailable")
    Div(:class => "p-6 bg-amber-50 dark:bg-amber-900/20 rounded-lg border border-amber-200 dark:border-amber-700",
        Div(:class => "flex items-start gap-3",
            # Warning icon
            Svg(:class => "w-5 h-5 text-amber-500 flex-shrink-0 mt-0.5",
                :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                     :d => "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z")
            ),
            Div(
                P(:class => "text-amber-800 dark:text-amber-200 font-medium text-sm", message),
                P(:class => "text-amber-600 dark:text-amber-400 text-xs mt-1",
                    "This demo requires WebAssembly support. Please use a modern browser."
                )
            )
        )
    )
end

"""
Prism.js CSS and JS includes for syntax highlighting.
Add this to the page head for Julia syntax highlighting.
"""
function PrismIncludes()
    Fragment(
        # Prism.js core CSS (Tomorrow Night theme for dark mode compatibility)
        Link(:rel => "stylesheet",
             :href => "https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/themes/prism-tomorrow.min.css"),
        # Prism.js core
        Script(:src => "https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/prism.min.js"),
        # Julia language support (uses the generic highlight for now)
        Script(:src => "https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/components/prism-julia.min.js"),
        # Custom Julia styling tweaks
        Style(raw"""
            /* Julia syntax highlighting customizations */
            .language-julia .token.keyword { color: #c792ea; }
            .language-julia .token.function { color: #82aaff; }
            .language-julia .token.number { color: #f78c6c; }
            .language-julia .token.string { color: #c3e88d; }
            .language-julia .token.comment { color: #676e95; font-style: italic; }
            .language-julia .token.operator { color: #89ddff; }
            .language-julia .token.punctuation { color: #89ddff; }

            /* Code block styling */
            pre[class*="language-"] {
                margin: 0;
                border-radius: 0;
            }

            code[class*="language-"] {
                font-family: 'JetBrains Mono', 'Fira Code', monospace;
            }
        """)
    )
end

# =============================================================================
# Pre-built Example Islands for Common Patterns
# =============================================================================

"""
Simple value display island - shows a computed result.
Useful for demonstrating pure functions.
"""
SimpleValueDemo = island(:SimpleValueDemo) do
    value, set_value = create_signal(0)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[150px]",
        # Input controls
        Div(:class => "flex items-center gap-4 mb-4",
            Button(:class => "w-10 h-10 rounded-full bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-lg font-medium hover:bg-warm-300 dark:hover:bg-warm-500 transition-colors",
                :on_click => () -> set_value(value() - 1),
                "-"
            ),
            Span(:class => "text-3xl font-mono text-accent-500 w-16 text-center", value),
            Button(:class => "w-10 h-10 rounded-full bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-lg font-medium hover:bg-warm-300 dark:hover:bg-warm-500 transition-colors",
                :on_click => () -> set_value(value() + 1),
                "+"
            )
        ),
        Span(:class => "text-sm text-warm-500 dark:text-warm-400", "Adjust the value")
    )
end

"""
Counter demo - basic increment/decrement with result display.
Used for demonstrating variables and basic operations.
"""
CounterDemo = island(:CounterDemo) do
    count, set_count = create_signal(0)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[150px]",
        Span(:class => "text-5xl font-mono font-bold text-accent-500 mb-4", count),
        Div(:class => "flex gap-2",
            Button(:class => "px-4 py-2 bg-accent-500 hover:bg-accent-600 text-white rounded-lg font-medium transition-colors",
                :on_click => () -> set_count(count() + 1),
                "Increment"
            ),
            Button(:class => "px-4 py-2 bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white rounded-lg font-medium hover:bg-warm-300 dark:hover:bg-warm-500 transition-colors",
                :on_click => () -> set_count(0),
                "Reset"
            )
        )
    )
end

"""
Arithmetic demo - two operands with operation selection.
Used for demonstrating math operations.
"""
ArithmeticExampleDemo = island(:ArithmeticExampleDemo) do
    a, set_a = create_signal(10)
    b, set_b = create_signal(3)
    result, set_result = create_signal(13)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[200px] gap-4",
        # Operands display
        Div(:class => "flex items-center gap-4",
            # Operand A
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "a"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                        :on_click => () -> set_a(a() - 1), "-"),
                    Span(:class => "w-10 text-center text-xl font-mono text-accent-500", a),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                        :on_click => () -> set_a(a() + 1), "+")
                )
            ),
            # Operand B
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "b"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                        :on_click => () -> set_b(b() - 1), "-"),
                    Span(:class => "w-10 text-center text-xl font-mono text-accent-500", b),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                        :on_click => () -> set_b(b() + 1), "+")
                )
            )
        ),
        # Operation buttons
        Div(:class => "flex gap-2",
            Button(:class => "px-3 py-1 rounded bg-accent-500 hover:bg-accent-600 text-white text-sm font-mono",
                :on_click => () -> set_result(a() + b()), "+"),
            Button(:class => "px-3 py-1 rounded bg-accent-500 hover:bg-accent-600 text-white text-sm font-mono",
                :on_click => () -> set_result(a() - b()), "-"),
            Button(:class => "px-3 py-1 rounded bg-accent-500 hover:bg-accent-600 text-white text-sm font-mono",
                :on_click => () -> set_result(a() * b()), "*"),
            Button(:class => "px-3 py-1 rounded bg-accent-500 hover:bg-accent-600 text-white text-sm font-mono",
                :on_click => () -> set_result(div(a(), b())), "/")
        ),
        # Result
        Div(:class => "text-center p-3 bg-warm-100 dark:bg-warm-700 rounded-lg",
            Span(:class => "text-warm-500 dark:text-warm-400 text-sm", "Result: "),
            Span(:class => "text-accent-500 font-bold text-2xl font-mono", result)
        )
    )
end

"""
Boolean/comparison demo - shows comparison results.
Used for demonstrating comparison operators.
"""
ComparisonDemo = island(:ComparisonDemo) do
    a, set_a = create_signal(5)
    b, set_b = create_signal(3)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[180px] gap-3",
        # Values
        Div(:class => "flex items-center gap-6",
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block", "a"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> set_a(a() - 1), "-"),
                    Span(:class => "w-8 text-center text-xl font-mono text-accent-500", a),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> set_a(a() + 1), "+")
                )
            ),
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block", "b"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> set_b(b() - 1), "-"),
                    Span(:class => "w-8 text-center text-xl font-mono text-accent-500", b),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> set_b(b() + 1), "+")
                )
            )
        ),
        # Comparison results as a grid
        Div(:class => "grid grid-cols-3 gap-2 text-sm font-mono",
            Div(:class => "px-2 py-1 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500", "a < b: "),
                Span(:class => () -> a() < b() ? "text-accent-500" : "text-rose-500",
                    () -> a() < b() ? "true" : "false")
            ),
            Div(:class => "px-2 py-1 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500", "a == b: "),
                Span(:class => () -> a() == b() ? "text-accent-500" : "text-rose-500",
                    () -> a() == b() ? "true" : "false")
            ),
            Div(:class => "px-2 py-1 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500", "a > b: "),
                Span(:class => () -> a() > b() ? "text-accent-500" : "text-rose-500",
                    () -> a() > b() ? "true" : "false")
            )
        )
    )
end

"""
String concatenation demo - shows string operations.
Uses integer index signal with show/hide for string content.
"""
StringConcatDemo = island(:StringConcatDemo) do
    # Integer signal for which concatenation result to show (1=Hello, World!, 2=Julia rocks!, 3=World of WASM)
    result_idx, set_result_idx = create_signal(1)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[150px] gap-4",
        # String selection buttons
        Div(:class => "flex flex-wrap gap-2 justify-center",
            Button(:class => () -> result_idx() == 1 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> set_result_idx(1), "Hello"),
            Button(:class => () -> result_idx() == 2 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> set_result_idx(2), "Julia"),
            Button(:class => () -> result_idx() == 3 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> set_result_idx(3), "World")
        ),
        # Result display - show/hide based on index
        Div(:class => "text-center p-4 bg-warm-100 dark:bg-warm-700 rounded-lg min-w-[200px]",
            Span(:class => () -> result_idx() == 1 ? "text-accent-500 font-mono text-lg" : "hidden", "Hello, World!"),
            Span(:class => () -> result_idx() == 2 ? "text-accent-500 font-mono text-lg" : "hidden", "Julia rocks!"),
            Span(:class => () -> result_idx() == 3 ? "text-accent-500 font-mono text-lg" : "hidden", "World of WASM")
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Select a word to see concatenation")
    )
end

"""
Factorial recursion demo - shows recursive function calls.
"""
FactorialDemo = island(:FactorialDemo) do
    n, set_n = create_signal(5)
    result, set_result = create_signal(120)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[180px] gap-4",
        # N selector
        Div(:class => "flex items-center gap-2",
            Span(:class => "text-sm text-warm-500 dark:text-warm-400", "n ="),
            Div(:class => "flex gap-1",
                Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> begin set_n(0); set_result(1) end, "0"),
                Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> begin set_n(1); set_result(1) end, "1"),
                Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> begin set_n(2); set_result(2) end, "2"),
                Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> begin set_n(3); set_result(6) end, "3"),
                Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> begin set_n(4); set_result(24) end, "4"),
                Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> begin set_n(5); set_result(120) end, "5"),
                Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> begin set_n(6); set_result(720) end, "6")
            )
        ),
        # Result display
        Div(:class => "text-center p-4 bg-warm-100 dark:bg-warm-700 rounded-lg",
            Span(:class => "text-warm-500 dark:text-warm-400", "factorial("),
            Span(:class => "text-accent-500 font-mono text-xl", n),
            Span(:class => "text-warm-500 dark:text-warm-400", ") = "),
            Span(:class => "text-accent-500 font-bold text-3xl font-mono", result)
        )
    )
end

"""
Loop/sum demo - shows iteration results.
"""
SumLoopDemo = island(:SumLoopDemo) do
    n, set_n = create_signal(10)
    result, set_result = create_signal(55)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[180px] gap-4",
        # N adjuster
        Div(:class => "flex items-center gap-3",
            Button(:class => "w-8 h-8 rounded-full bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    new_n = n() - 5
                    if new_n >= 0
                        set_n(new_n)
                        set_result(div(new_n * (new_n + 1), 2))
                    end
                end, "-5"),
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block", "n"),
                Span(:class => "text-2xl font-mono text-accent-500", n)
            ),
            Button(:class => "w-8 h-8 rounded-full bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    new_n = n() + 5
                    set_n(new_n)
                    set_result(div(new_n * (new_n + 1), 2))
                end, "+5")
        ),
        # Result
        Div(:class => "text-center p-4 bg-warm-100 dark:bg-warm-700 rounded-lg",
            Span(:class => "text-warm-500 dark:text-warm-400", "sum(1..", ),
            Span(:class => "text-accent-500 font-mono", n),
            Span(:class => "text-warm-500 dark:text-warm-400", ") = "),
            Span(:class => "text-accent-500 font-bold text-2xl font-mono", result)
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Uses formula: n*(n+1)/2")
    )
end

"""
Control flow demo - sign function with if/elseif/else.
Uses signal for result to avoid SSR issues with reactive classes.
"""
SignDemo = island(:SignDemo) do
    n, set_n = create_signal(0)
    result, set_result = create_signal(0)  # -1, 0, or 1

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[180px] gap-4",
        # N adjuster
        Div(:class => "flex items-center gap-3",
            Button(:class => "w-10 h-10 rounded-full bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-lg",
                :on_click => () -> begin
                    new_n = n() - 1
                    set_n(new_n)
                    if new_n > 0
                        set_result(1)
                    elseif new_n < 0
                        set_result(-1)
                    else
                        set_result(0)
                    end
                end, "-"),
            Span(:class => "text-3xl font-mono text-accent-500 w-16 text-center", n),
            Button(:class => "w-10 h-10 rounded-full bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-lg",
                :on_click => () -> begin
                    new_n = n() + 1
                    set_n(new_n)
                    if new_n > 0
                        set_result(1)
                    elseif new_n < 0
                        set_result(-1)
                    else
                        set_result(0)
                    end
                end, "+")
        ),
        # Result display
        Div(:class => "text-center p-4 bg-warm-100 dark:bg-warm-700 rounded-lg min-w-[200px]",
            Span(:class => "text-warm-500 dark:text-warm-400", "sign("),
            Span(:class => "text-accent-500 font-mono", n),
            Span(:class => "text-warm-500 dark:text-warm-400", ") = "),
            Span(:class => "text-accent-500 font-bold text-2xl font-mono", result)
        ),
        # Legend
        Div(:class => "flex gap-4 text-xs",
            Span(:class => "text-accent-500", "positive: +1"),
            Span(:class => "text-amber-500", "zero: 0"),
            Span(:class => "text-rose-500", "negative: -1")
        )
    )
end

"""
Struct demo - shows struct field access.
Uses signals for computed values to avoid world-age SSR issues.
"""
StructDemo = island(:StructDemo) do
    x, set_x = create_signal(10)
    y, set_y = create_signal(20)
    # Use signals for computed values
    sum_val, set_sum = create_signal(30)
    prod_val, set_prod = create_signal(200)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[200px] gap-4",
        # Point struct visualization
        Div(:class => "p-4 bg-warm-100 dark:bg-warm-700 rounded-lg",
            Span(:class => "text-warm-500 dark:text-warm-400 text-sm block mb-2", "struct Point"),
            Div(:class => "flex gap-4",
                # X field
                Div(:class => "text-center",
                    Span(:class => "text-xs text-warm-500 dark:text-warm-400 block", "x"),
                    Div(:class => "flex items-center gap-1",
                        Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                            :on_click => () -> begin
                                new_x = x() - 1
                                set_x(new_x)
                                set_sum(new_x + y())
                                set_prod(new_x * y())
                            end, "-"),
                        Span(:class => "w-8 text-center text-xl font-mono text-accent-500", x),
                        Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                            :on_click => () -> begin
                                new_x = x() + 1
                                set_x(new_x)
                                set_sum(new_x + y())
                                set_prod(new_x * y())
                            end, "+")
                    )
                ),
                # Y field
                Div(:class => "text-center",
                    Span(:class => "text-xs text-warm-500 dark:text-warm-400 block", "y"),
                    Div(:class => "flex items-center gap-1",
                        Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                            :on_click => () -> begin
                                new_y = y() - 1
                                set_y(new_y)
                                set_sum(x() + new_y)
                                set_prod(x() * new_y)
                            end, "-"),
                        Span(:class => "w-8 text-center text-xl font-mono text-accent-500", y),
                        Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                            :on_click => () -> begin
                                new_y = y() + 1
                                set_y(new_y)
                                set_sum(x() + new_y)
                                set_prod(x() * new_y)
                            end, "+")
                    )
                )
            )
        ),
        # Computed values - use signals directly
        Div(:class => "flex gap-4 text-sm",
            Div(:class => "px-3 py-2 bg-warm-100 dark:bg-warm-700 rounded",
                Span(:class => "text-warm-500", "p.x + p.y = "),
                Span(:class => "text-accent-500 font-mono", sum_val)
            ),
            Div(:class => "px-3 py-2 bg-warm-100 dark:bg-warm-700 rounded",
                Span(:class => "text-warm-500", "p.x * p.y = "),
                Span(:class => "text-accent-500 font-mono", prod_val)
            )
        )
    )
end

"""
Tuple demo - shows tuple creation and indexing.
Uses integer index signal and show/hide for display values to avoid string signals.
"""
TupleDemo = island(:TupleDemo) do
    idx, set_idx = create_signal(1)

    # Tuple values (fixed)
    Div(:class => "flex flex-col items-center justify-center h-full min-h-[180px] gap-4",
        # Tuple visualization
        Div(:class => "p-4 bg-warm-100 dark:bg-warm-700 rounded-lg",
            Span(:class => "text-warm-500 dark:text-warm-400 text-sm", "t = "),
            Span(:class => "text-accent-500 font-mono text-lg", "(42, 3.14, 100)")
        ),
        # Index selector
        Div(:class => "flex items-center gap-2",
            Span(:class => "text-sm text-warm-500 dark:text-warm-400", "t["),
            Div(:class => "flex gap-1",
                Button(:class => () -> idx() == 1 ? "w-8 h-8 rounded bg-accent-500 text-white" : "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> set_idx(1), "1"),
                Button(:class => () -> idx() == 2 ? "w-8 h-8 rounded bg-accent-500 text-white" : "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> set_idx(2), "2"),
                Button(:class => () -> idx() == 3 ? "w-8 h-8 rounded bg-accent-500 text-white" : "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> set_idx(3), "3")
            ),
            Span(:class => "text-sm text-warm-500 dark:text-warm-400", "] = "),
            # Show the appropriate value based on index using show/hide
            Span(:class => () -> idx() == 1 ? "text-accent-500 font-bold text-2xl font-mono" : "hidden", "42"),
            Span(:class => () -> idx() == 2 ? "text-accent-500 font-bold text-2xl font-mono" : "hidden", "3.14"),
            Span(:class => () -> idx() == 3 ? "text-accent-500 font-bold text-2xl font-mono" : "hidden", "100")
        )
    )
end

"""
Array demo - shows array indexing and mutation.
Uses a display_val signal updated by handlers to avoid SSR world-age issues.
"""
ArrayDemo = island(:ArrayDemo) do
    idx, set_idx = create_signal(1)
    val1, set_val1 = create_signal(10)
    val2, set_val2 = create_signal(20)
    val3, set_val3 = create_signal(30)
    val4, set_val4 = create_signal(40)
    # Display value signal - updated when index or values change
    display_val, set_display_val = create_signal(10)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[200px] gap-4",
        # Array visualization
        Div(:class => "flex gap-1",
            Span(:class => "text-warm-500 dark:text-warm-400", "["),
            Div(:class => () -> idx() == 1 ? "px-3 py-1 bg-accent-500 text-white rounded font-mono" : "px-3 py-1 bg-warm-200 dark:bg-warm-600 rounded font-mono",
                :onclick => "event.stopPropagation()",
                Button(:class => "cursor-pointer", :on_click => () -> begin set_idx(1); set_display_val(val1()) end, val1)
            ),
            Div(:class => () -> idx() == 2 ? "px-3 py-1 bg-accent-500 text-white rounded font-mono" : "px-3 py-1 bg-warm-200 dark:bg-warm-600 rounded font-mono",
                Button(:class => "cursor-pointer", :on_click => () -> begin set_idx(2); set_display_val(val2()) end, val2)
            ),
            Div(:class => () -> idx() == 3 ? "px-3 py-1 bg-accent-500 text-white rounded font-mono" : "px-3 py-1 bg-warm-200 dark:bg-warm-600 rounded font-mono",
                Button(:class => "cursor-pointer", :on_click => () -> begin set_idx(3); set_display_val(val3()) end, val3)
            ),
            Div(:class => () -> idx() == 4 ? "px-3 py-1 bg-accent-500 text-white rounded font-mono" : "px-3 py-1 bg-warm-200 dark:bg-warm-600 rounded font-mono",
                Button(:class => "cursor-pointer", :on_click => () -> begin set_idx(4); set_display_val(val4()) end, val4)
            ),
            Span(:class => "text-warm-500 dark:text-warm-400", "]")
        ),
        # Selected element modification
        Div(:class => "flex items-center gap-3",
            Span(:class => "text-sm text-warm-500 dark:text-warm-400", "arr["),
            Span(:class => "text-accent-500 font-mono", idx),
            Span(:class => "text-sm text-warm-500 dark:text-warm-400", "] = "),
            Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    i = idx()
                    if i == 1
                        nv = val1() - 1
                        set_val1(nv)
                        set_display_val(nv)
                    elseif i == 2
                        nv = val2() - 1
                        set_val2(nv)
                        set_display_val(nv)
                    elseif i == 3
                        nv = val3() - 1
                        set_val3(nv)
                        set_display_val(nv)
                    else
                        nv = val4() - 1
                        set_val4(nv)
                        set_display_val(nv)
                    end
                end, "-"),
            # Use display_val signal directly instead of computed closure
            Span(:class => "text-accent-500 font-bold text-xl font-mono w-12 text-center", display_val),
            Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    i = idx()
                    if i == 1
                        nv = val1() + 1
                        set_val1(nv)
                        set_display_val(nv)
                    elseif i == 2
                        nv = val2() + 1
                        set_val2(nv)
                        set_display_val(nv)
                    elseif i == 3
                        nv = val3() + 1
                        set_val3(nv)
                        set_display_val(nv)
                    else
                        nv = val4() + 1
                        set_val4(nv)
                        set_display_val(nv)
                    end
                end, "+")
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Click an element to select, then modify")
    )
end

"""
Integer overflow demo - shows what happens when integers wrap around.
For Int32, max is 2147483647, min is -2147483648.
"""
IntegerOverflowDemo = island(:IntegerOverflowDemo) do
    value, set_value = create_signal(2147483640)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[200px] gap-4",
        # Current value display
        Div(:class => "text-center",
            Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "Int32 value"),
            Span(:class => "text-3xl font-mono text-accent-500", value)
        ),
        # Controls
        Div(:class => "flex gap-2",
            Button(:class => "px-4 py-2 bg-accent-500 hover:bg-accent-600 text-white rounded-lg font-medium transition-colors",
                :on_click => () -> set_value(value() + 1),
                "+1"
            ),
            Button(:class => "px-4 py-2 bg-accent-500 hover:bg-accent-600 text-white rounded-lg font-medium transition-colors",
                :on_click => () -> set_value(value() + 10),
                "+10"
            ),
            Button(:class => "px-4 py-2 bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white rounded-lg font-medium hover:bg-warm-300 dark:hover:bg-warm-500 transition-colors",
                :on_click => () -> set_value(2147483640),
                "Near Max"
            )
        ),
        # Max value reference
        Div(:class => "text-xs text-warm-500 dark:text-warm-400 text-center",
            "Int32 max: 2147483647 (wraps to -2147483648)"
        )
    )
end

"""
Float precision demo - shows integer division and remainder.
"""
FloatPrecisionDemo = island(:FloatPrecisionDemo) do
    a, set_a = create_signal(10)
    b, set_b = create_signal(3)
    quotient, set_quotient = create_signal(3)
    remainder, set_remainder = create_signal(1)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[200px] gap-4",
        # Operand display
        Div(:class => "flex items-center gap-4",
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "a"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                        :on_click => () -> begin
                            new_a = a() - 1
                            set_a(new_a)
                            set_quotient(div(new_a, b()))
                            set_remainder(new_a % b())
                        end, "-"),
                    Span(:class => "w-8 text-center text-xl font-mono text-accent-500", a),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                        :on_click => () -> begin
                            new_a = a() + 1
                            set_a(new_a)
                            set_quotient(div(new_a, b()))
                            set_remainder(new_a % b())
                        end, "+")
                )
            ),
            Span(:class => "text-2xl text-warm-400", "/"),
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "b"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                        :on_click => () -> begin
                            if b() > 1
                                new_b = b() - 1
                                set_b(new_b)
                                set_quotient(div(a(), new_b))
                                set_remainder(a() % new_b)
                            end
                        end, "-"),
                    Span(:class => "w-8 text-center text-xl font-mono text-accent-500", b),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                        :on_click => () -> begin
                            new_b = b() + 1
                            set_b(new_b)
                            set_quotient(div(a(), new_b))
                            set_remainder(a() % new_b)
                        end, "+")
                )
            )
        ),
        # Result display (integer division)
        Div(:class => "text-center p-4 bg-warm-100 dark:bg-warm-700 rounded-lg w-full max-w-xs",
            Div(:class => "mb-2",
                Span(:class => "text-warm-500 dark:text-warm-400 text-sm", "div(a, b) = "),
                Span(:class => "text-accent-500 font-bold text-xl font-mono", quotient)
            ),
            Div(
                Span(:class => "text-warm-500 dark:text-warm-400 text-sm", "a % b = "),
                Span(:class => "text-accent-500 font-bold text-xl font-mono", remainder)
            )
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Adjust values to see integer division and remainder")
    )
end

"""
Type conversion demo - convert between integer and float types.
"""
TypeConversionDemo = island(:TypeConversionDemo) do
    int_val, set_int_val = create_signal(42)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[200px] gap-4",
        # Integer input
        Div(:class => "flex items-center gap-3",
            Span(:class => "text-sm text-warm-500 dark:text-warm-400", "Int32:"),
            Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> set_int_val(int_val() - 10), "-10"),
            Span(:class => "text-2xl font-mono text-accent-500 w-16 text-center", int_val),
            Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> set_int_val(int_val() + 10), "+10")
        ),
        # Conversion results - use direct signal binding
        Div(:class => "grid grid-cols-1 gap-2 w-full max-w-xs",
            Div(:class => "p-2 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500 dark:text-warm-400 text-sm", "Float64: "),
                Span(:class => "text-accent-500 font-mono", int_val),
                Span(:class => "text-accent-500 font-mono", ".0")
            ),
            Div(:class => "p-2 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500 dark:text-warm-400 text-sm", "Int64: "),
                Span(:class => "text-accent-500 font-mono", int_val)
            )
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Adjust the integer to see type conversions")
    )
end

"""
Numeric literals demo - shows different ways to write numbers.
Uses integer index signal with show/hide for text content.
"""
NumericLiteralsDemo = island(:NumericLiteralsDemo) do
    # Integer signal for which format to show (1=decimal, 2=hex, 3=binary, 4=float)
    format_idx, set_format = create_signal(1)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[200px] gap-4",
        # Literal type selector - simplified buttons
        Div(:class => "flex flex-wrap gap-2 justify-center",
            Button(:class => () -> format_idx() == 1 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> set_format(1), "Decimal"),
            Button(:class => () -> format_idx() == 2 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> set_format(2), "Hex"),
            Button(:class => () -> format_idx() == 3 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> set_format(3), "Binary"),
            Button(:class => () -> format_idx() == 4 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> set_format(4), "Float")
        ),
        # Display area - show/hide based on format index
        Div(:class => "p-4 bg-warm-100 dark:bg-warm-700 rounded-lg text-center min-w-[250px]",
            # Decimal (format 1)
            Div(:class => () -> format_idx() == 1 ? "block" : "hidden",
                Span(:class => "text-warm-500 dark:text-warm-400 text-sm block mb-2", "Decimal (base 10)"),
                Span(:class => "text-accent-500 font-mono text-xl block", "255 → 255")
            ),
            # Hex (format 2)
            Div(:class => () -> format_idx() == 2 ? "block" : "hidden",
                Span(:class => "text-warm-500 dark:text-warm-400 text-sm block mb-2", "Hexadecimal (base 16)"),
                Span(:class => "text-accent-500 font-mono text-xl block", "0xff → 255")
            ),
            # Binary (format 3)
            Div(:class => () -> format_idx() == 3 ? "block" : "hidden",
                Span(:class => "text-warm-500 dark:text-warm-400 text-sm block mb-2", "Binary (base 2)"),
                Span(:class => "text-accent-500 font-mono text-xl block", "0b11111111 → 255")
            ),
            # Float (format 4)
            Div(:class => () -> format_idx() == 4 ? "block" : "hidden",
                Span(:class => "text-warm-500 dark:text-warm-400 text-sm block mb-2", "Float literal"),
                Span(:class => "text-accent-500 font-mono text-xl block", "3.14f0 → Float32")
            )
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Click to see different literal formats")
    )
end

# =============================================================================
# Mathematical Operations Demos
# =============================================================================

"""
Calculator demo - interactive arithmetic operations with all basic operators.
Uses signal for result only, avoiding SSR issues with reactive classes.
"""
CalculatorDemo = island(:CalculatorDemo) do
    a, set_a = create_signal(24)
    b, set_b = create_signal(7)
    result, set_result = create_signal(31)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[220px] gap-4",
        # Operands display with adjusters
        Div(:class => "flex items-center gap-4",
            # Operand A
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "a"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-7 h-7 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                        :on_click => () -> set_a(a() - 1), "-"),
                    Span(:class => "w-12 text-center text-2xl font-mono text-accent-500", a),
                    Button(:class => "w-7 h-7 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                        :on_click => () -> set_a(a() + 1), "+")
                )
            ),
            # Operand B
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "b"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-7 h-7 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                        :on_click => () -> begin
                            if b() > 1
                                set_b(b() - 1)
                            end
                        end, "-"),
                    Span(:class => "w-12 text-center text-2xl font-mono text-accent-500", b),
                    Button(:class => "w-7 h-7 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                        :on_click => () -> set_b(b() + 1), "+")
                )
            )
        ),
        # Operation buttons - static classes
        Div(:class => "flex gap-2",
            Button(:class => "px-4 py-2 rounded bg-accent-500 hover:bg-accent-600 text-white font-mono text-lg",
                :on_click => () -> set_result(a() + b()), "+"),
            Button(:class => "px-4 py-2 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white font-mono text-lg hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> set_result(a() - b()), "-"),
            Button(:class => "px-4 py-2 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white font-mono text-lg hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> set_result(a() * b()), "*"),
            Button(:class => "px-4 py-2 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white font-mono text-lg hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> set_result(div(a(), b())), "÷"),
            Button(:class => "px-4 py-2 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white font-mono text-lg hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> set_result(a() % b()), "%")
        ),
        # Result display
        Div(:class => "text-center p-4 bg-warm-100 dark:bg-warm-700 rounded-lg min-w-[200px]",
            Span(:class => "text-warm-500 dark:text-warm-400 text-sm", "Result = "),
            Span(:class => "text-accent-500 font-bold text-3xl font-mono", result)
        )
    )
end

"""
Comparison operators demo - uses integer signals (1=true, 0=false) for results.
Shows all comparison results with show/hide for true/false display.
"""
ComparisonOpsDemo = island(:ComparisonOpsDemo) do
    a, set_a = create_signal(5)
    b, set_b = create_signal(5)
    # Use integer signals for comparison results (1=true, 0=false)
    lt_result, set_lt = create_signal(0)
    eq_result, set_eq = create_signal(1)
    gt_result, set_gt = create_signal(0)
    le_result, set_le = create_signal(1)
    ne_result, set_ne = create_signal(0)
    ge_result, set_ge = create_signal(1)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[220px] gap-4",
        # Values
        Div(:class => "flex items-center gap-6",
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block", "a"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            new_a = a() - 1
                            set_a(new_a)
                            cur_b = b()
                            set_lt(new_a < cur_b ? 1 : 0)
                            set_eq(new_a == cur_b ? 1 : 0)
                            set_gt(new_a > cur_b ? 1 : 0)
                            set_le(new_a <= cur_b ? 1 : 0)
                            set_ne(new_a != cur_b ? 1 : 0)
                            set_ge(new_a >= cur_b ? 1 : 0)
                        end, "-"),
                    Span(:class => "w-10 text-center text-2xl font-mono text-accent-500", a),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            new_a = a() + 1
                            set_a(new_a)
                            cur_b = b()
                            set_lt(new_a < cur_b ? 1 : 0)
                            set_eq(new_a == cur_b ? 1 : 0)
                            set_gt(new_a > cur_b ? 1 : 0)
                            set_le(new_a <= cur_b ? 1 : 0)
                            set_ne(new_a != cur_b ? 1 : 0)
                            set_ge(new_a >= cur_b ? 1 : 0)
                        end, "+")
                )
            ),
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block", "b"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            new_b = b() - 1
                            set_b(new_b)
                            cur_a = a()
                            set_lt(cur_a < new_b ? 1 : 0)
                            set_eq(cur_a == new_b ? 1 : 0)
                            set_gt(cur_a > new_b ? 1 : 0)
                            set_le(cur_a <= new_b ? 1 : 0)
                            set_ne(cur_a != new_b ? 1 : 0)
                            set_ge(cur_a >= new_b ? 1 : 0)
                        end, "-"),
                    Span(:class => "w-10 text-center text-2xl font-mono text-accent-500", b),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            new_b = b() + 1
                            set_b(new_b)
                            cur_a = a()
                            set_lt(cur_a < new_b ? 1 : 0)
                            set_eq(cur_a == new_b ? 1 : 0)
                            set_gt(cur_a > new_b ? 1 : 0)
                            set_le(cur_a <= new_b ? 1 : 0)
                            set_ne(cur_a != new_b ? 1 : 0)
                            set_ge(cur_a >= new_b ? 1 : 0)
                        end, "+")
                )
            )
        ),
        # Comparison results grid - using show/hide for true/false
        Div(:class => "grid grid-cols-3 gap-2 text-sm font-mono",
            Div(:class => "px-3 py-2 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500 block", "a < b"),
                Span(:class => () -> lt_result() == 1 ? "text-accent-500 font-bold" : "hidden", "true"),
                Span(:class => () -> lt_result() == 0 ? "text-accent-500 font-bold" : "hidden", "false")
            ),
            Div(:class => "px-3 py-2 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500 block", "a == b"),
                Span(:class => () -> eq_result() == 1 ? "text-accent-500 font-bold" : "hidden", "true"),
                Span(:class => () -> eq_result() == 0 ? "text-accent-500 font-bold" : "hidden", "false")
            ),
            Div(:class => "px-3 py-2 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500 block", "a > b"),
                Span(:class => () -> gt_result() == 1 ? "text-accent-500 font-bold" : "hidden", "true"),
                Span(:class => () -> gt_result() == 0 ? "text-accent-500 font-bold" : "hidden", "false")
            ),
            Div(:class => "px-3 py-2 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500 block", "a <= b"),
                Span(:class => () -> le_result() == 1 ? "text-accent-500 font-bold" : "hidden", "true"),
                Span(:class => () -> le_result() == 0 ? "text-accent-500 font-bold" : "hidden", "false")
            ),
            Div(:class => "px-3 py-2 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500 block", "a != b"),
                Span(:class => () -> ne_result() == 1 ? "text-accent-500 font-bold" : "hidden", "true"),
                Span(:class => () -> ne_result() == 0 ? "text-accent-500 font-bold" : "hidden", "false")
            ),
            Div(:class => "px-3 py-2 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500 block", "a >= b"),
                Span(:class => () -> ge_result() == 1 ? "text-accent-500 font-bold" : "hidden", "true"),
                Span(:class => () -> ge_result() == 0 ? "text-accent-500 font-bold" : "hidden", "false")
            )
        )
    )
end

"""
Bitwise operations demo - shows AND, OR, XOR, and shifts.
Simplified to use just integer result signals.
"""
BitwiseDemo = island(:BitwiseDemo) do
    a, set_a = create_signal(12)  # Binary: 1100
    b, set_b = create_signal(10)  # Binary: 1010
    result, set_result = create_signal(8)  # 12 & 10 = 8

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[240px] gap-3",
        # Binary representation header
        Div(:class => "text-xs text-warm-500 dark:text-warm-400 text-center",
            "Adjust values and click operation buttons"
        ),
        # Values display
        Div(:class => "flex items-center gap-4",
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block", "a"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            if a() > 0
                                set_a(a() - 1)
                            end
                        end, "-"),
                    Span(:class => "w-10 text-center text-xl font-mono text-accent-500", a),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            if a() < 15
                                set_a(a() + 1)
                            end
                        end, "+")
                )
            ),
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block", "b"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            if b() > 0
                                set_b(b() - 1)
                            end
                        end, "-"),
                    Span(:class => "w-10 text-center text-xl font-mono text-accent-500", b),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            if b() < 15
                                set_b(b() + 1)
                            end
                        end, "+")
                )
            )
        ),
        # Operation buttons
        Div(:class => "flex gap-1",
            Button(:class => "px-3 py-1 rounded bg-accent-500 text-white font-mono text-sm",
                :on_click => () -> set_result(a() & b()), "&"),
            Button(:class => "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white font-mono text-sm",
                :on_click => () -> set_result(a() | b()), "|"),
            Button(:class => "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white font-mono text-sm",
                :on_click => () -> set_result(xor(a(), b())), "xor"),
            Button(:class => "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white font-mono text-sm",
                :on_click => () -> set_result(a() << b()), "<<"),
            Button(:class => "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white font-mono text-sm",
                :on_click => () -> set_result(a() >> b()), ">>")
        ),
        # Result
        Div(:class => "text-center p-3 bg-warm-100 dark:bg-warm-700 rounded-lg",
            Span(:class => "text-warm-500 dark:text-warm-400 text-sm", "Result = "),
            Span(:class => "text-accent-500 font-bold text-2xl font-mono", result)
        ),
        # Note about binary
        Span(:class => "text-xs text-warm-500 dark:text-warm-400",
            "12 = 1100₂, 10 = 1010₂, 8 = 1000₂"
        )
    )
end

"""
Math functions demo - abs, multiply, and basic math.
Simplified to avoid helper closures that can't compile to WASM.
"""
MathFunctionsDemo = island(:MathFunctionsDemo) do
    value, set_value = create_signal(49)
    abs_result, set_abs = create_signal(49)
    double_result, set_double = create_signal(98)
    square_result, set_square = create_signal(2401)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[240px] gap-4",
        # Input value
        Div(:class => "flex items-center gap-3",
            Span(:class => "text-sm text-warm-500 dark:text-warm-400", "x ="),
            Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    new_v = value() - 10
                    set_value(new_v)
                    av = new_v
                    if av < 0
                        av = -av
                    end
                    set_abs(av)
                    set_double(new_v * 2)
                    set_square(new_v * new_v)
                end, "-10"),
            Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    new_v = value() - 1
                    set_value(new_v)
                    av = new_v
                    if av < 0
                        av = -av
                    end
                    set_abs(av)
                    set_double(new_v * 2)
                    set_square(new_v * new_v)
                end, "-1"),
            Span(:class => "text-3xl font-mono text-accent-500 w-16 text-center", value),
            Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    new_v = value() + 1
                    set_value(new_v)
                    av = new_v
                    if av < 0
                        av = -av
                    end
                    set_abs(av)
                    set_double(new_v * 2)
                    set_square(new_v * new_v)
                end, "+1"),
            Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    new_v = value() + 10
                    set_value(new_v)
                    av = new_v
                    if av < 0
                        av = -av
                    end
                    set_abs(av)
                    set_double(new_v * 2)
                    set_square(new_v * new_v)
                end, "+10")
        ),
        # Quick presets
        Div(:class => "flex gap-2",
            Button(:class => "px-2 py-1 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                :on_click => () -> begin
                    set_value(-25)
                    set_abs(25)
                    set_double(-50)
                    set_square(625)
                end, "-25"),
            Button(:class => "px-2 py-1 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                :on_click => () -> begin
                    set_value(0)
                    set_abs(0)
                    set_double(0)
                    set_square(0)
                end, "0"),
            Button(:class => "px-2 py-1 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                :on_click => () -> begin
                    set_value(49)
                    set_abs(49)
                    set_double(98)
                    set_square(2401)
                end, "49"),
            Button(:class => "px-2 py-1 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                :on_click => () -> begin
                    set_value(100)
                    set_abs(100)
                    set_double(200)
                    set_square(10000)
                end, "100")
        ),
        # Function results grid - using signals directly
        Div(:class => "grid grid-cols-2 gap-2 text-sm font-mono w-full max-w-xs",
            Div(:class => "p-2 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500 text-xs block", "abs(x)"),
                Span(:class => "text-accent-500 font-bold text-lg", abs_result)
            ),
            Div(:class => "p-2 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500 text-xs block", "x * 2"),
                Span(:class => "text-accent-500 font-bold text-lg", double_result)
            ),
            Div(:class => "p-2 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500 text-xs block", "x * x"),
                Span(:class => "text-accent-500 font-bold text-lg", square_result)
            )
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Adjust x to see math results")
    )
end

"""
Negative number demo - shows how negation and subtraction work.
Uses two signals to track both the original value and its negation.
"""
NegationDemo = island(:NegationDemo) do
    value, set_value = create_signal(10)
    neg_value, set_neg_value = create_signal(-10)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[180px] gap-4",
        # Value adjuster
        Div(:class => "flex items-center gap-3",
            Button(:class => "w-10 h-10 rounded-full bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-lg",
                :on_click => () -> begin
                    new_val = value() - 5
                    set_value(new_val)
                    set_neg_value(-new_val)
                end, "-5"),
            Span(:class => "text-4xl font-mono text-accent-500 w-20 text-center", value),
            Button(:class => "w-10 h-10 rounded-full bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-lg",
                :on_click => () -> begin
                    new_val = value() + 5
                    set_value(new_val)
                    set_neg_value(-new_val)
                end, "+5")
        ),
        # Results - display both signals directly
        Div(:class => "grid grid-cols-2 gap-3 text-center",
            Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg",
                Span(:class => "text-warm-500 dark:text-warm-400 text-sm block", "-x = "),
                Span(:class => "text-accent-500 font-bold text-2xl font-mono", neg_value)
            ),
            Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg",
                Span(:class => "text-warm-500 dark:text-warm-400 text-sm block", "0 - x = "),
                Span(:class => "text-accent-500 font-bold text-2xl font-mono", neg_value)
            )
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Negation is the same as subtraction from zero")
    )
end

# =============================================================================
# String Demos
# =============================================================================

"""
String length demo - shows different strings and their lengths.
Uses integer index signal with show/hide for string content.
"""
StringLengthDemo = island(:StringLengthDemo) do
    # Integer signal for which string to show (1=Hello, 2=Julia, 3=Hello, World, 4=empty)
    str_idx, set_str_idx = create_signal(1)
    length_val, set_length = create_signal(5)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[180px] gap-4",
        # String selection buttons
        Div(:class => "flex flex-wrap gap-2 justify-center",
            Button(:class => () -> str_idx() == 1 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> begin
                    set_str_idx(1)
                    set_length(5)
                end, "\"Hello\""),
            Button(:class => () -> str_idx() == 2 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> begin
                    set_str_idx(2)
                    set_length(5)
                end, "\"Julia\""),
            Button(:class => () -> str_idx() == 3 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> begin
                    set_str_idx(3)
                    set_length(12)
                end, "\"Hello, World\""),
            Button(:class => () -> str_idx() == 4 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> begin
                    set_str_idx(4)
                    set_length(0)
                end, "\"\"")
        ),
        # String display - show/hide based on index
        Div(:class => "text-center p-4 bg-warm-100 dark:bg-warm-700 rounded-lg min-w-[250px]",
            Div(:class => "text-accent-500 font-mono text-lg mb-2",
                Span(:class => () -> str_idx() == 1 ? "inline" : "hidden", "\"Hello\""),
                Span(:class => () -> str_idx() == 2 ? "inline" : "hidden", "\"Julia\""),
                Span(:class => () -> str_idx() == 3 ? "inline" : "hidden", "\"Hello, World\""),
                Span(:class => () -> str_idx() == 4 ? "inline" : "hidden", "\"\"")
            ),
            Div(:class => "text-warm-500 dark:text-warm-400 text-sm",
                Span("length = "),
                Span(:class => "text-accent-500 font-bold font-mono", length_val)
            )
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Click a string to see its length")
    )
end

"""
String comparison demo - compares two preset strings.
Shows equality and lexicographic comparison results.
Uses integer indices for strings and boolean signals for results.
"""
StringComparisonDemo = island(:StringComparisonDemo) do
    # Integer signals: 1=apple, 2=banana, 3=cherry
    str_a_idx, set_str_a = create_signal(1)
    str_b_idx, set_str_b = create_signal(2)
    # Integer signals for results (1=true, 0=false)
    eq_result, set_eq = create_signal(0)
    lt_result, set_lt = create_signal(1)

    # Helper to compute comparison results based on indices
    # Lexicographic order: apple(1) < banana(2) < cherry(3)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[220px] gap-4",
        # String A selection
        Div(:class => "text-center",
            Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "String a"),
            Div(:class => "flex gap-1",
                Button(:class => () -> str_a_idx() == 1 ? "px-2 py-1 rounded bg-accent-500 text-white text-xs" : "px-2 py-1 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        set_str_a(1)
                        b = str_b_idx()
                        set_eq(b == 1 ? 1 : 0)
                        set_lt(b == 1 ? 0 : 1)
                    end, "\"apple\""),
                Button(:class => () -> str_a_idx() == 2 ? "px-2 py-1 rounded bg-accent-500 text-white text-xs" : "px-2 py-1 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        set_str_a(2)
                        b = str_b_idx()
                        set_eq(b == 2 ? 1 : 0)
                        set_lt(b == 3 ? 1 : 0)
                    end, "\"banana\""),
                Button(:class => () -> str_a_idx() == 3 ? "px-2 py-1 rounded bg-accent-500 text-white text-xs" : "px-2 py-1 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        set_str_a(3)
                        b = str_b_idx()
                        set_eq(b == 3 ? 1 : 0)
                        set_lt(0)
                    end, "\"cherry\"")
            )
        ),
        # String B selection
        Div(:class => "text-center",
            Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "String b"),
            Div(:class => "flex gap-1",
                Button(:class => () -> str_b_idx() == 1 ? "px-2 py-1 rounded bg-accent-500 text-white text-xs" : "px-2 py-1 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        set_str_b(1)
                        a = str_a_idx()
                        set_eq(a == 1 ? 1 : 0)
                        set_lt(0)
                    end, "\"apple\""),
                Button(:class => () -> str_b_idx() == 2 ? "px-2 py-1 rounded bg-accent-500 text-white text-xs" : "px-2 py-1 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        set_str_b(2)
                        a = str_a_idx()
                        set_eq(a == 2 ? 1 : 0)
                        set_lt(a == 1 ? 1 : 0)
                    end, "\"banana\""),
                Button(:class => () -> str_b_idx() == 3 ? "px-2 py-1 rounded bg-accent-500 text-white text-xs" : "px-2 py-1 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        set_str_b(3)
                        a = str_a_idx()
                        set_eq(a == 3 ? 1 : 0)
                        set_lt(a == 3 ? 0 : 1)
                    end, "\"cherry\"")
            )
        ),
        # Display selected strings - show/hide based on indices
        Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg text-center",
            Div(:class => "flex gap-4 justify-center mb-2",
                Span(:class => () -> str_a_idx() == 1 ? "text-accent-500 font-mono" : "hidden", "apple"),
                Span(:class => () -> str_a_idx() == 2 ? "text-accent-500 font-mono" : "hidden", "banana"),
                Span(:class => () -> str_a_idx() == 3 ? "text-accent-500 font-mono" : "hidden", "cherry"),
                Span(:class => "text-warm-500", " vs "),
                Span(:class => () -> str_b_idx() == 1 ? "text-accent-500 font-mono" : "hidden", "apple"),
                Span(:class => () -> str_b_idx() == 2 ? "text-accent-500 font-mono" : "hidden", "banana"),
                Span(:class => () -> str_b_idx() == 3 ? "text-accent-500 font-mono" : "hidden", "cherry")
            )
        ),
        # Comparison results - show/hide for true/false
        Div(:class => "flex gap-4 text-sm font-mono",
            Div(:class => "px-3 py-2 bg-warm-100 dark:bg-warm-700 rounded",
                Span(:class => "text-warm-500", "a == b: "),
                Span(:class => () -> eq_result() == 1 ? "text-accent-500 font-bold" : "hidden", "true"),
                Span(:class => () -> eq_result() == 0 ? "text-accent-500 font-bold" : "hidden", "false")
            ),
            Div(:class => "px-3 py-2 bg-warm-100 dark:bg-warm-700 rounded",
                Span(:class => "text-warm-500", "a < b: "),
                Span(:class => () -> lt_result() == 1 ? "text-accent-500 font-bold" : "hidden", "true"),
                Span(:class => () -> lt_result() == 0 ? "text-accent-500 font-bold" : "hidden", "false")
            )
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Strings compare lexicographically (dictionary order)")
    )
end

# =============================================================================
# Function Demos
# =============================================================================

"""
Function definition demo - shows a simple function that squares a number.
"""
SquareDemo = island(:SquareDemo) do
    input, set_input = create_signal(5)
    result, set_result = create_signal(25)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[180px] gap-4",
        # Input with label
        Div(:class => "flex items-center gap-3",
            Span(:class => "text-sm text-warm-500 dark:text-warm-400", "x ="),
            Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    new_x = input() - 1
                    set_input(new_x)
                    set_result(new_x * new_x)
                end, "-"),
            Span(:class => "text-2xl font-mono text-accent-500 w-12 text-center", input),
            Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    new_x = input() + 1
                    set_input(new_x)
                    set_result(new_x * new_x)
                end, "+")
        ),
        # Result display
        Div(:class => "text-center p-4 bg-warm-100 dark:bg-warm-700 rounded-lg",
            Span(:class => "text-warm-500 dark:text-warm-400", "square("),
            Span(:class => "text-accent-500 font-mono", input),
            Span(:class => "text-warm-500 dark:text-warm-400", ") = "),
            Span(:class => "text-accent-500 font-bold text-2xl font-mono", result)
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "square(x) = x * x")
    )
end

"""
Multiple arguments demo - shows a function with two arguments (simplified hypot).
"""
MultiArgDemo = island(:MultiArgDemo) do
    x, set_x = create_signal(3)
    y, set_y = create_signal(4)
    result, set_result = create_signal(5)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[200px] gap-4",
        # Arguments display
        Div(:class => "flex items-center gap-6",
            # X input
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "x"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            new_x = x() - 1
                            set_x(new_x)
                            # Integer sqrt approximation
                            sum_sq = new_x * new_x + y() * y()
                            r = 1
                            while r * r <= sum_sq
                                r = r + 1
                            end
                            set_result(r - 1)
                        end, "-"),
                    Span(:class => "w-8 text-center text-xl font-mono text-accent-500", x),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            new_x = x() + 1
                            set_x(new_x)
                            sum_sq = new_x * new_x + y() * y()
                            r = 1
                            while r * r <= sum_sq
                                r = r + 1
                            end
                            set_result(r - 1)
                        end, "+")
                )
            ),
            # Y input
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "y"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            new_y = y() - 1
                            set_y(new_y)
                            sum_sq = x() * x() + new_y * new_y
                            r = 1
                            while r * r <= sum_sq
                                r = r + 1
                            end
                            set_result(r - 1)
                        end, "-"),
                    Span(:class => "w-8 text-center text-xl font-mono text-accent-500", y),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            new_y = y() + 1
                            set_y(new_y)
                            sum_sq = x() * x() + new_y * new_y
                            r = 1
                            while r * r <= sum_sq
                                r = r + 1
                            end
                            set_result(r - 1)
                        end, "+")
                )
            )
        ),
        # Quick presets (3,4,5), (5,12,13), (8,15,17)
        Div(:class => "flex gap-2",
            Button(:class => "px-2 py-1 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                :on_click => () -> begin
                    set_x(3); set_y(4); set_result(5)
                end, "3,4"),
            Button(:class => "px-2 py-1 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                :on_click => () -> begin
                    set_x(5); set_y(12); set_result(13)
                end, "5,12"),
            Button(:class => "px-2 py-1 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                :on_click => () -> begin
                    set_x(8); set_y(15); set_result(17)
                end, "8,15")
        ),
        # Result display
        Div(:class => "text-center p-4 bg-warm-100 dark:bg-warm-700 rounded-lg",
            Span(:class => "text-warm-500 dark:text-warm-400", "hypot("),
            Span(:class => "text-accent-500 font-mono", x),
            Span(:class => "text-warm-500 dark:text-warm-400", ", "),
            Span(:class => "text-accent-500 font-mono", y),
            Span(:class => "text-warm-500 dark:text-warm-400", ") = "),
            Span(:class => "text-accent-500 font-bold text-2xl font-mono", result)
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Integer approximation of sqrt(x*x + y*y)")
    )
end

"""
Return value demo - shows explicit return vs implicit return.
"""
ReturnValueDemo = island(:ReturnValueDemo) do
    value, set_value = create_signal(10)
    abs_result, set_abs = create_signal(10)
    sign_result, set_sign = create_signal(1)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[200px] gap-4",
        # Value adjuster
        Div(:class => "flex items-center gap-3",
            Button(:class => "w-10 h-10 rounded-full bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-lg",
                :on_click => () -> begin
                    new_v = value() - 5
                    set_value(new_v)
                    set_abs(new_v < 0 ? -new_v : new_v)
                    set_sign(new_v > 0 ? 1 : (new_v < 0 ? -1 : 0))
                end, "-5"),
            Span(:class => "text-3xl font-mono text-accent-500 w-16 text-center", value),
            Button(:class => "w-10 h-10 rounded-full bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-lg",
                :on_click => () -> begin
                    new_v = value() + 5
                    set_value(new_v)
                    set_abs(new_v < 0 ? -new_v : new_v)
                    set_sign(new_v > 0 ? 1 : (new_v < 0 ? -1 : 0))
                end, "+5")
        ),
        # Results
        Div(:class => "grid grid-cols-2 gap-3",
            Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg text-center",
                Span(:class => "text-warm-500 dark:text-warm-400 text-sm block", "my_abs(x)"),
                Span(:class => "text-accent-500 font-bold text-xl font-mono", abs_result)
            ),
            Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg text-center",
                Span(:class => "text-warm-500 dark:text-warm-400 text-sm block", "my_sign(x)"),
                Span(:class => "text-accent-500 font-bold text-xl font-mono", sign_result)
            )
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "my_abs uses early return, my_sign uses implicit return")
    )
end

"""
Closure demo - shows a function that captures a variable from outer scope.
"""
ClosureDemo = island(:ClosureDemo) do
    # Captured variable
    offset, set_offset = create_signal(10)
    input, set_input = create_signal(5)
    result, set_result = create_signal(15)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[220px] gap-4",
        # Offset (captured variable)
        Div(:class => "p-3 bg-amber-50 dark:bg-amber-900/20 rounded-lg border border-amber-200 dark:border-amber-700",
            Div(:class => "flex items-center gap-3",
                Span(:class => "text-sm text-amber-700 dark:text-amber-300", "offset ="),
                Button(:class => "w-6 h-6 rounded bg-amber-200 dark:bg-amber-700 text-amber-800 dark:text-amber-100 text-sm",
                    :on_click => () -> begin
                        new_off = offset() - 5
                        set_offset(new_off)
                        set_result(input() + new_off)
                    end, "-"),
                Span(:class => "w-10 text-center text-lg font-mono text-amber-600 dark:text-amber-400", offset),
                Button(:class => "w-6 h-6 rounded bg-amber-200 dark:bg-amber-700 text-amber-800 dark:text-amber-100 text-sm",
                    :on_click => () -> begin
                        new_off = offset() + 5
                        set_offset(new_off)
                        set_result(input() + new_off)
                    end, "+")
            ),
            Span(:class => "text-xs text-amber-600 dark:text-amber-400 block mt-1", "Captured by closure")
        ),
        # Input argument
        Div(:class => "flex items-center gap-3",
            Span(:class => "text-sm text-warm-500 dark:text-warm-400", "x ="),
            Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    new_x = input() - 1
                    set_input(new_x)
                    set_result(new_x + offset())
                end, "-"),
            Span(:class => "text-2xl font-mono text-accent-500 w-12 text-center", input),
            Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    new_x = input() + 1
                    set_input(new_x)
                    set_result(new_x + offset())
                end, "+")
        ),
        # Result
        Div(:class => "text-center p-3 bg-warm-100 dark:bg-warm-700 rounded-lg",
            Span(:class => "text-warm-500 dark:text-warm-400", "add_offset("),
            Span(:class => "text-accent-500 font-mono", input),
            Span(:class => "text-warm-500 dark:text-warm-400", ") = "),
            Span(:class => "text-accent-500 font-bold text-xl font-mono", result)
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Closure captures 'offset' from outer scope")
    )
end

"""
Compact function syntax demo - shows one-liner function definition.
"""
CompactFunctionDemo = island(:CompactFunctionDemo) do
    a, set_a = create_signal(7)
    b, set_b = create_signal(3)
    add_result, set_add = create_signal(10)
    mul_result, set_mul = create_signal(21)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[200px] gap-4",
        # Arguments
        Div(:class => "flex items-center gap-4",
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "a"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            new_a = a() - 1
                            set_a(new_a)
                            set_add(new_a + b())
                            set_mul(new_a * b())
                        end, "-"),
                    Span(:class => "w-8 text-center text-xl font-mono text-accent-500", a),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            new_a = a() + 1
                            set_a(new_a)
                            set_add(new_a + b())
                            set_mul(new_a * b())
                        end, "+")
                )
            ),
            Div(:class => "text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "b"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            new_b = b() - 1
                            set_b(new_b)
                            set_add(a() + new_b)
                            set_mul(a() * new_b)
                        end, "-"),
                    Span(:class => "w-8 text-center text-xl font-mono text-accent-500", b),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            new_b = b() + 1
                            set_b(new_b)
                            set_add(a() + new_b)
                            set_mul(a() * new_b)
                        end, "+")
                )
            )
        ),
        # Results
        Div(:class => "grid grid-cols-2 gap-3 text-sm font-mono",
            Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500 block", "add(a, b)"),
                Span(:class => "text-accent-500 font-bold text-xl", add_result)
            ),
            Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded text-center",
                Span(:class => "text-warm-500 block", "mul(a, b)"),
                Span(:class => "text-accent-500 font-bold text-xl", mul_result)
            )
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "add(a, b) = a + b  |  mul(a, b) = a * b")
    )
end

# =============================================================================
# Control Flow Demos
# =============================================================================

"""
While loop demo - sum from 1 to n using while loop.
Shows the classic sum pattern with iteration.
"""
WhileLoopDemo = island(:WhileLoopDemo) do
    n, set_n = create_signal(10)
    result, set_result = create_signal(55)  # sum(1:10) = 55

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[200px] gap-4",
        # N adjuster
        Div(:class => "flex items-center gap-3",
            Span(:class => "text-sm text-warm-500 dark:text-warm-400", "n ="),
            Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    if n() > 1
                        new_n = n() - 1
                        set_n(new_n)
                        set_result(div(new_n * (new_n + 1), 2))
                    end
                end, "-"),
            Span(:class => "text-2xl font-mono text-accent-500 w-12 text-center", n),
            Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    new_n = n() + 1
                    set_n(new_n)
                    set_result(div(new_n * (new_n + 1), 2))
                end, "+")
        ),
        # Quick presets
        Div(:class => "flex gap-2",
            Button(:class => "px-3 py-1 rounded bg-accent-500 hover:bg-accent-600 text-white text-sm",
                :on_click => () -> begin set_n(10); set_result(55) end, "n=10"),
            Button(:class => "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300",
                :on_click => () -> begin set_n(50); set_result(1275) end, "n=50"),
            Button(:class => "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300",
                :on_click => () -> begin set_n(100); set_result(5050) end, "n=100")
        ),
        # Result
        Div(:class => "text-center p-4 bg-warm-100 dark:bg-warm-700 rounded-lg min-w-[200px]",
            Span(:class => "text-warm-500 dark:text-warm-400", "sum(1.."),
            Span(:class => "text-accent-500 font-mono", n),
            Span(:class => "text-warm-500 dark:text-warm-400", ") = "),
            Span(:class => "text-accent-500 font-bold text-2xl font-mono", result)
        ),
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Formula: n×(n+1)÷2")
    )
end

"""
For loop demo - factorial calculation using for loop.
Shows iteration over a range.
"""
ForLoopDemo = island(:ForLoopDemo) do
    n, set_n = create_signal(5)
    result, set_result = create_signal(120)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[200px] gap-4",
        # N selector
        Div(:class => "flex items-center gap-2",
            Span(:class => "text-sm text-warm-500 dark:text-warm-400", "n ="),
            Div(:class => "flex gap-1",
                Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> begin set_n(1); set_result(1) end, "1"),
                Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> begin set_n(2); set_result(2) end, "2"),
                Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> begin set_n(3); set_result(6) end, "3"),
                Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> begin set_n(4); set_result(24) end, "4"),
                Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> begin set_n(5); set_result(120) end, "5"),
                Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> begin set_n(6); set_result(720) end, "6"),
                Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                    :on_click => () -> begin set_n(7); set_result(5040) end, "7")
            )
        ),
        # Visual representation of the for loop
        Div(:class => "text-sm text-warm-500 dark:text-warm-400 font-mono text-center",
            "for i in 2:",
            Span(:class => "text-accent-500", n),
            " → result *= i"
        ),
        # Result display
        Div(:class => "text-center p-4 bg-warm-100 dark:bg-warm-700 rounded-lg min-w-[220px]",
            Span(:class => "text-warm-500 dark:text-warm-400", "factorial("),
            Span(:class => "text-accent-500 font-mono text-xl", n),
            Span(:class => "text-warm-500 dark:text-warm-400", ") = "),
            Span(:class => "text-accent-500 font-bold text-2xl font-mono", result)
        )
    )
end

"""
Short-circuit evaluation demo - shows && and || behavior.
Uses integer index signal for scenario selection with show/hide for text.
"""
ShortCircuitDemo = island(:ShortCircuitDemo) do
    # Integer signals for results (1=true, 0=false)
    and_result, set_and = create_signal(1)
    or_result, set_or = create_signal(1)
    # Integer signal for scenario (1-4)
    scenario, set_scenario = create_signal(1)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[240px] gap-4",
        # Scenario selector
        Div(:class => "grid grid-cols-2 gap-2",
            Button(:class => () -> scenario() == 1 ? "px-3 py-2 rounded bg-accent-500 text-white text-sm" : "px-3 py-2 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300",
                :on_click => () -> begin
                    set_scenario(1)
                    set_and(1)
                    set_or(1)
                end,
                "a>0, b>0"
            ),
            Button(:class => () -> scenario() == 2 ? "px-3 py-2 rounded bg-accent-500 text-white text-sm" : "px-3 py-2 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300",
                :on_click => () -> begin
                    set_scenario(2)
                    set_and(0)
                    set_or(1)
                end,
                "a>0, b≤0"
            ),
            Button(:class => () -> scenario() == 3 ? "px-3 py-2 rounded bg-accent-500 text-white text-sm" : "px-3 py-2 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300",
                :on_click => () -> begin
                    set_scenario(3)
                    set_and(0)
                    set_or(1)
                end,
                "a≤0, b>0"
            ),
            Button(:class => () -> scenario() == 4 ? "px-3 py-2 rounded bg-accent-500 text-white text-sm" : "px-3 py-2 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm hover:bg-warm-300",
                :on_click => () -> begin
                    set_scenario(4)
                    set_and(0)
                    set_or(0)
                end,
                "a≤0, b≤0"
            )
        ),
        # Results display - show/hide for true/false
        Div(:class => "grid grid-cols-2 gap-3 w-full max-w-xs",
            Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg text-center",
                Span(:class => "text-warm-500 dark:text-warm-400 text-xs block mb-1", "(a>0) && (b>0)"),
                Span(:class => () -> and_result() == 1 ? "text-accent-500 font-bold text-xl font-mono" : "hidden", "true"),
                Span(:class => () -> and_result() == 0 ? "text-accent-500 font-bold text-xl font-mono" : "hidden", "false")
            ),
            Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg text-center",
                Span(:class => "text-warm-500 dark:text-warm-400 text-xs block mb-1", "(a>0) || (b>0)"),
                Span(:class => () -> or_result() == 1 ? "text-accent-500 font-bold text-xl font-mono" : "hidden", "true"),
                Span(:class => () -> or_result() == 0 ? "text-accent-500 font-bold text-xl font-mono" : "hidden", "false")
            )
        ),
        # Explanation - show/hide based on scenario
        Div(:class => "text-xs text-warm-500 dark:text-warm-400 text-center max-w-xs p-2 bg-warm-100 dark:bg-warm-700 rounded",
            Span(:class => () -> scenario() == 1 ? "block" : "hidden", "&&: both evaluated. ||: short-circuits on true"),
            Span(:class => () -> scenario() == 2 ? "block" : "hidden", "&&: both evaluated (false). ||: short-circuits on true"),
            Span(:class => () -> scenario() == 3 ? "block" : "hidden", "&&: short-circuits on false. ||: both evaluated"),
            Span(:class => () -> scenario() == 4 ? "block" : "hidden", "&&: short-circuits on false. ||: both evaluated (false)")
        )
    )
end

"""
Try/catch demo - shows exception handling.
Integer square root that throws on negative input.
Uses integer index signal for status selection with show/hide.
"""
TryCatchDemo = island(:TryCatchDemo) do
    n, set_n = create_signal(16)
    result, set_result = create_signal(4)
    # Integer signal for status selection (1=-9 error, 2=0, 3=4, 4=16, 5=25, 6=100)
    status_idx, set_status = create_signal(4)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[220px] gap-4",
        # N selector buttons
        Div(:class => "flex items-center gap-2",
            Span(:class => "text-sm text-warm-500 dark:text-warm-400", "n ="),
            Div(:class => "flex gap-1",
                Button(:class => () -> status_idx() == 1 ? "w-10 h-8 rounded bg-rose-500 text-white text-sm" : "w-10 h-8 rounded bg-rose-200 dark:bg-rose-700 text-rose-800 dark:text-rose-100 text-sm hover:bg-rose-300",
                    :on_click => () -> begin
                        set_n(-9)
                        set_result(-1)
                        set_status(1)
                    end, "-9"),
                Button(:class => () -> status_idx() == 2 ? "w-10 h-8 rounded bg-accent-500 text-white text-sm" : "w-10 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                    :on_click => () -> begin
                        set_n(0)
                        set_result(0)
                        set_status(2)
                    end, "0"),
                Button(:class => () -> status_idx() == 3 ? "w-10 h-8 rounded bg-accent-500 text-white text-sm" : "w-10 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                    :on_click => () -> begin
                        set_n(4)
                        set_result(2)
                        set_status(3)
                    end, "4"),
                Button(:class => () -> status_idx() == 4 ? "w-10 h-8 rounded bg-accent-500 text-white text-sm" : "w-10 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                    :on_click => () -> begin
                        set_n(16)
                        set_result(4)
                        set_status(4)
                    end, "16"),
                Button(:class => () -> status_idx() == 5 ? "w-10 h-8 rounded bg-accent-500 text-white text-sm" : "w-10 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                    :on_click => () -> begin
                        set_n(25)
                        set_result(5)
                        set_status(5)
                    end, "25"),
                Button(:class => () -> status_idx() == 6 ? "w-10 h-8 rounded bg-accent-500 text-white text-sm" : "w-10 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                    :on_click => () -> begin
                        set_n(100)
                        set_result(10)
                        set_status(6)
                    end, "100")
            )
        ),
        # Selected value display
        Div(:class => "text-center",
            Span(:class => "text-warm-500 dark:text-warm-400 text-sm", "safe_sqrt("),
            Span(:class => "text-accent-500 font-mono text-xl", n),
            Span(:class => "text-warm-500 dark:text-warm-400 text-sm", ")")
        ),
        # Result display
        Div(:class => "text-center p-4 bg-warm-100 dark:bg-warm-700 rounded-lg min-w-[240px]",
            Span(:class => "text-warm-500 dark:text-warm-400 text-sm", "Result: "),
            Span(:class => "text-accent-500 font-bold text-2xl font-mono", result),
            Div(:class => "text-sm text-warm-600 dark:text-warm-400 mt-2",
                Span(:class => () -> status_idx() == 1 ? "text-rose-500 block" : "hidden", "Error: n < 0"),
                Span(:class => () -> status_idx() == 2 ? "block" : "hidden", "√0 = 0 ✓"),
                Span(:class => () -> status_idx() == 3 ? "block" : "hidden", "√4 = 2 ✓"),
                Span(:class => () -> status_idx() == 4 ? "block" : "hidden", "√16 = 4 ✓"),
                Span(:class => () -> status_idx() == 5 ? "block" : "hidden", "√25 = 5 ✓"),
                Span(:class => () -> status_idx() == 6 ? "block" : "hidden", "√100 = 10 ✓")
            )
        ),
        # Explanation
        Div(:class => "text-xs text-warm-500 dark:text-warm-400 text-center max-w-xs",
            "Click -9 to trigger the error path (n < 0 throws exception)"
        )
    )
end

"""
Break/continue demo - shows loop control statements.
Finds numbers divisible by both 3 and 7.
Uses pre-computed results to avoid complex loop compilation issues.
"""
BreakContinueDemo = island(:BreakContinueDemo) do
    limit, set_limit = create_signal(50)
    result, set_result = create_signal(21)
    skipped, set_skipped = create_signal(14)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[220px] gap-4",
        # Limit selector - pre-computed values for different limits
        Div(:class => "flex items-center gap-2",
            Span(:class => "text-sm text-warm-500 dark:text-warm-400", "search 1.."),
            Div(:class => "flex gap-1",
                Button(:class => "w-10 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                    :on_click => () -> begin
                        set_limit(10)
                        set_result(-1)  # 21 not found in 1..10
                        set_skipped(7)  # 1,2,4,5,7,8,10 not divisible by 3
                    end, "10"),
                Button(:class => "w-10 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                    :on_click => () -> begin
                        set_limit(20)
                        set_result(-1)  # 21 not found in 1..20
                        set_skipped(14) # non-multiples of 3 up to 20
                    end, "20"),
                Button(:class => "w-10 h-8 rounded bg-accent-500 hover:bg-accent-600 text-white text-sm",
                    :on_click => () -> begin
                        set_limit(50)
                        set_result(21)  # Found!
                        set_skipped(14) # 14 non-multiples of 3 before 21
                    end, "50"),
                Button(:class => "w-10 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                    :on_click => () -> begin
                        set_limit(100)
                        set_result(21)  # Same result, loop breaks at 21
                        set_skipped(14)
                    end, "100")
            )
        ),
        # Algorithm visualization
        Div(:class => "text-xs text-warm-500 dark:text-warm-400 text-center max-w-xs font-mono",
            "for i in 1..",
            Span(:class => "text-accent-500", limit),
            ": skip if i%3≠0; break if i%7==0"
        ),
        # Results
        Div(:class => "grid grid-cols-2 gap-3",
            Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg text-center",
                Span(:class => "text-warm-500 dark:text-warm-400 text-xs block", "First (n%3==0 && n%7==0)"),
                Span(:class => "text-accent-500 font-bold text-2xl font-mono", result)
            ),
            Div(:class => "p-3 bg-amber-50 dark:bg-amber-900/20 rounded-lg text-center border border-amber-200 dark:border-amber-700",
                Span(:class => "text-amber-700 dark:text-amber-300 text-xs block", "Skipped (continue)"),
                Span(:class => "text-amber-600 dark:text-amber-400 font-bold text-2xl font-mono", skipped)
            )
        ),
        # Explanation
        Span(:class => "text-xs text-warm-500 dark:text-warm-400 text-center",
            "21 = 3×7 is the smallest number divisible by both. Try limit=10 to see \"not found\"."
        )
    )
end

# =============================================================================
# Struct Demos for Types Chapter
# =============================================================================

"""
Mutable struct demo - shows mutating fields of a mutable struct.
Demonstrates: mutable struct definition, field mutation via setfield!
"""
MutableStructDemo = island(:MutableStructDemo) do
    # Simulate a mutable Counter struct with count field
    count_val, set_count_val = create_signal(0)
    step_val, set_step_val = create_signal(1)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[220px] gap-4",
        # Mutable struct visualization
        Div(:class => "p-4 bg-warm-100 dark:bg-warm-700 rounded-lg",
            Span(:class => "text-warm-500 dark:text-warm-400 text-sm block mb-2", "mutable struct Counter"),
            Div(:class => "flex flex-col gap-2",
                # count field
                Div(:class => "flex items-center gap-2",
                    Span(:class => "text-xs text-warm-500 dark:text-warm-400 w-16", "count:"),
                    Span(:class => "text-xl font-mono text-accent-500 w-16 text-center", count_val)
                ),
                # step field
                Div(:class => "flex items-center gap-2",
                    Span(:class => "text-xs text-warm-500 dark:text-warm-400 w-16", "step:"),
                    Div(:class => "flex items-center gap-1",
                        Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                            :on_click => () -> begin
                                if step_val() > 1
                                    set_step_val(step_val() - 1)
                                end
                            end, "-"),
                        Span(:class => "w-8 text-center text-lg font-mono text-accent-500", step_val),
                        Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                            :on_click => () -> set_step_val(step_val() + 1), "+")
                    )
                )
            )
        ),
        # Mutation buttons
        Div(:class => "flex gap-2",
            Button(:class => "px-4 py-2 bg-accent-500 hover:bg-accent-600 text-white rounded-lg font-medium transition-colors",
                :on_click => () -> set_count_val(count_val() + step_val()),
                "c.count += c.step"
            ),
            Button(:class => "px-4 py-2 bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white rounded-lg font-medium hover:bg-warm-300 dark:hover:bg-warm-500 transition-colors",
                :on_click => () -> set_count_val(0),
                "c.count = 0"
            )
        ),
        # Explanation
        Span(:class => "text-xs text-warm-500 dark:text-warm-400 text-center",
            "Mutable struct fields can be modified after creation"
        )
    )
end

"""
Nested struct demo - shows structs containing other structs.
Demonstrates: nested struct definition, field access chains.
Uses signals for computed values to avoid world-age SSR issues.
"""
NestedStructDemo = island(:NestedStructDemo) do
    # Simulate nested structs: Line has two Point fields (start_pt and end_pt)
    # Point has x and y fields
    start_x, set_start_x = create_signal(0)
    start_y, set_start_y = create_signal(0)
    end_x, set_end_x = create_signal(10)
    end_y, set_end_y = create_signal(10)
    # Computed signals
    delta_x, set_delta_x = create_signal(10)
    delta_y, set_delta_y = create_signal(10)
    len_sq, set_len_sq = create_signal(200)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[280px] gap-4",
        # Nested struct visualization
        Div(:class => "p-4 bg-warm-100 dark:bg-warm-700 rounded-lg",
            Span(:class => "text-warm-500 dark:text-warm-400 text-sm block mb-2", "struct Line"),
            # Start point
            Div(:class => "ml-4 mb-2",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block", "start_pt: Point"),
                Div(:class => "flex gap-3 ml-4",
                    Div(:class => "text-center",
                        Span(:class => "text-xs text-warm-400", "x"),
                        Div(:class => "flex items-center gap-1",
                            Button(:class => "w-5 h-5 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                                :on_click => () -> begin
                                    new_sx = start_x() - 1
                                    set_start_x(new_sx)
                                    dx = end_x() - new_sx
                                    dy = end_y() - start_y()
                                    set_delta_x(dx)
                                    set_len_sq(dx * dx + dy * dy)
                                end, "-"),
                            Span(:class => "w-6 text-center font-mono text-accent-500", start_x),
                            Button(:class => "w-5 h-5 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                                :on_click => () -> begin
                                    new_sx = start_x() + 1
                                    set_start_x(new_sx)
                                    dx = end_x() - new_sx
                                    dy = end_y() - start_y()
                                    set_delta_x(dx)
                                    set_len_sq(dx * dx + dy * dy)
                                end, "+")
                        )
                    ),
                    Div(:class => "text-center",
                        Span(:class => "text-xs text-warm-400", "y"),
                        Div(:class => "flex items-center gap-1",
                            Button(:class => "w-5 h-5 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                                :on_click => () -> begin
                                    new_sy = start_y() - 1
                                    set_start_y(new_sy)
                                    dx = end_x() - start_x()
                                    dy = end_y() - new_sy
                                    set_delta_y(dy)
                                    set_len_sq(dx * dx + dy * dy)
                                end, "-"),
                            Span(:class => "w-6 text-center font-mono text-accent-500", start_y),
                            Button(:class => "w-5 h-5 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                                :on_click => () -> begin
                                    new_sy = start_y() + 1
                                    set_start_y(new_sy)
                                    dx = end_x() - start_x()
                                    dy = end_y() - new_sy
                                    set_delta_y(dy)
                                    set_len_sq(dx * dx + dy * dy)
                                end, "+")
                        )
                    )
                )
            ),
            # End point
            Div(:class => "ml-4",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block", "end_pt: Point"),
                Div(:class => "flex gap-3 ml-4",
                    Div(:class => "text-center",
                        Span(:class => "text-xs text-warm-400", "x"),
                        Div(:class => "flex items-center gap-1",
                            Button(:class => "w-5 h-5 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                                :on_click => () -> begin
                                    new_ex = end_x() - 1
                                    set_end_x(new_ex)
                                    dx = new_ex - start_x()
                                    dy = end_y() - start_y()
                                    set_delta_x(dx)
                                    set_len_sq(dx * dx + dy * dy)
                                end, "-"),
                            Span(:class => "w-6 text-center font-mono text-accent-500", end_x),
                            Button(:class => "w-5 h-5 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                                :on_click => () -> begin
                                    new_ex = end_x() + 1
                                    set_end_x(new_ex)
                                    dx = new_ex - start_x()
                                    dy = end_y() - start_y()
                                    set_delta_x(dx)
                                    set_len_sq(dx * dx + dy * dy)
                                end, "+")
                        )
                    ),
                    Div(:class => "text-center",
                        Span(:class => "text-xs text-warm-400", "y"),
                        Div(:class => "flex items-center gap-1",
                            Button(:class => "w-5 h-5 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                                :on_click => () -> begin
                                    new_ey = end_y() - 1
                                    set_end_y(new_ey)
                                    dx = end_x() - start_x()
                                    dy = new_ey - start_y()
                                    set_delta_y(dy)
                                    set_len_sq(dx * dx + dy * dy)
                                end, "-"),
                            Span(:class => "w-6 text-center font-mono text-accent-500", end_y),
                            Button(:class => "w-5 h-5 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                                :on_click => () -> begin
                                    new_ey = end_y() + 1
                                    set_end_y(new_ey)
                                    dx = end_x() - start_x()
                                    dy = new_ey - start_y()
                                    set_delta_y(dy)
                                    set_len_sq(dx * dx + dy * dy)
                                end, "+")
                        )
                    )
                )
            )
        ),
        # Computed values showing field access chains - use signals directly
        Div(:class => "flex flex-wrap gap-2 text-sm justify-center",
            Div(:class => "px-3 py-1 bg-warm-100 dark:bg-warm-700 rounded",
                Span(:class => "text-warm-500", "Δx: "),
                Span(:class => "text-accent-500 font-mono", delta_x)
            ),
            Div(:class => "px-3 py-1 bg-warm-100 dark:bg-warm-700 rounded",
                Span(:class => "text-warm-500", "Δy: "),
                Span(:class => "text-accent-500 font-mono", delta_y)
            ),
            Div(:class => "px-3 py-1 bg-warm-100 dark:bg-warm-700 rounded",
                Span(:class => "text-warm-500", "length²: "),
                Span(:class => "text-accent-500 font-mono", len_sq)
            )
        ),
        # Explanation
        Span(:class => "text-xs text-warm-500 dark:text-warm-400 text-center",
            "line.end_pt.x accesses nested struct fields"
        )
    )
end

"""
Primitive types demo - shows different primitive types and their ranges.
Uses integer index signal with show/hide for type information.
"""
PrimitiveTypesDemo = island(:PrimitiveTypesDemo) do
    # Integer signal for type selection (1=Int32, 2=Int64, 3=Float32, 4=Float64, 5=Bool)
    selected_type, set_selected_type = create_signal(1)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[200px] gap-4",
        # Type selector buttons
        Div(:class => "flex flex-wrap gap-2 justify-center",
            Button(:class => () -> selected_type() == 1 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                :on_click => () -> set_selected_type(1), "Int32"),
            Button(:class => () -> selected_type() == 2 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                :on_click => () -> set_selected_type(2), "Int64"),
            Button(:class => () -> selected_type() == 3 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                :on_click => () -> set_selected_type(3), "Float32"),
            Button(:class => () -> selected_type() == 4 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                :on_click => () -> set_selected_type(4), "Float64"),
            Button(:class => () -> selected_type() == 5 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                :on_click => () -> set_selected_type(5), "Bool")
        ),
        # Type info display - show/hide based on selection
        Div(:class => "p-4 bg-warm-100 dark:bg-warm-700 rounded-lg w-full max-w-sm text-center",
            # Type names
            Span(:class => () -> selected_type() == 1 ? "text-accent-500 font-mono text-xl font-bold" : "hidden", "Int32"),
            Span(:class => () -> selected_type() == 2 ? "text-accent-500 font-mono text-xl font-bold" : "hidden", "Int64"),
            Span(:class => () -> selected_type() == 3 ? "text-accent-500 font-mono text-xl font-bold" : "hidden", "Float32"),
            Span(:class => () -> selected_type() == 4 ? "text-accent-500 font-mono text-xl font-bold" : "hidden", "Float64"),
            Span(:class => () -> selected_type() == 5 ? "text-accent-500 font-mono text-xl font-bold" : "hidden", "Bool"),
            # Range descriptions
            Div(:class => "text-sm text-warm-500 dark:text-warm-400 mt-2",
                Span(:class => () -> selected_type() == 1 ? "block" : "hidden", "32-bit signed integer: -2³¹ to 2³¹-1"),
                Span(:class => () -> selected_type() == 2 ? "block" : "hidden", "64-bit signed integer: -2⁶³ to 2⁶³-1"),
                Span(:class => () -> selected_type() == 3 ? "block" : "hidden", "32-bit floating point (single precision)"),
                Span(:class => () -> selected_type() == 4 ? "block" : "hidden", "64-bit floating point (double precision)"),
                Span(:class => () -> selected_type() == 5 ? "block" : "hidden", "Boolean: true (1) or false (0)")
            )
        ),
        # Example value - show/hide based on selection
        Div(:class => "text-center",
            Span(:class => "text-xs text-warm-500 dark:text-warm-400 block", "Example value"),
            Span(:class => () -> selected_type() == 1 ? "text-2xl font-mono text-accent-500" : "hidden", "42"),
            Span(:class => () -> selected_type() == 2 ? "text-2xl font-mono text-accent-500" : "hidden", "9223372036854775807"),
            Span(:class => () -> selected_type() == 3 ? "text-2xl font-mono text-accent-500" : "hidden", "3.14f0"),
            Span(:class => () -> selected_type() == 4 ? "text-2xl font-mono text-accent-500" : "hidden", "2.71828"),
            Span(:class => () -> selected_type() == 5 ? "text-2xl font-mono text-accent-500" : "hidden", "true")
        )
    )
end

# =============================================================================
# Multiple Dispatch / Methods Demos
# =============================================================================

"""
Shape area demo - demonstrates multiple dispatch with area() function.
Shows Circle and Rectangle with different area calculations.
Uses integer signals with show/hide for text content.
"""
ShapeAreaDemo = island(:ShapeAreaDemo) do
    # Integer signals for all state
    field_value, set_field_value = create_signal(5)
    area_result, set_area_result = create_signal(75)  # 3 * 5 * 5

    # Current shape type: 1=Circle, 2=Rectangle
    shape_type, set_shape_type = create_signal(1)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[250px] gap-4",
        # Shape type selector
        Div(:class => "flex gap-2",
            Button(:class => () -> shape_type() == 1 ? "px-4 py-2 rounded-lg bg-accent-500 text-white font-medium" : "px-4 py-2 rounded-lg bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    set_shape_type(1)
                    set_field_value(5)
                    set_area_result(75)
                end,
                "Circle"
            ),
            Button(:class => () -> shape_type() == 2 ? "px-4 py-2 rounded-lg bg-accent-500 text-white font-medium" : "px-4 py-2 rounded-lg bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin
                    set_shape_type(2)
                    set_field_value(24)
                    set_area_result(24)
                end,
                "Rectangle"
            )
        ),

        # Shape visualization - unified display with show/hide for labels
        Div(:class => "p-4 bg-warm-100 dark:bg-warm-700 rounded-lg min-w-[280px]",
            Div(:class => "text-center",
                # Shape type label - show/hide
                Span(:class => () -> shape_type() == 1 ? "text-sm text-warm-500 dark:text-warm-400 block mb-3" : "hidden", "struct Circle"),
                Span(:class => () -> shape_type() == 2 ? "text-sm text-warm-500 dark:text-warm-400 block mb-3" : "hidden", "struct Rectangle"),
                # Field display with controls
                Div(:class => "flex items-center justify-center gap-2",
                    Span(:class => () -> shape_type() == 1 ? "text-xs text-warm-500 dark:text-warm-400" : "hidden", "radius"),
                    Span(:class => () -> shape_type() == 2 ? "text-xs text-warm-500 dark:text-warm-400" : "hidden", "width × height"),
                    Span(:class => "text-warm-400 dark:text-warm-500", " = "),
                    Div(:class => "flex items-center gap-1",
                        Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                            :on_click => () -> begin
                                if field_value() > 1
                                    new_val = field_value() - 1
                                    set_field_value(new_val)
                                    if shape_type() == 1
                                        set_area_result(3 * new_val * new_val)
                                    else
                                        set_area_result(new_val)
                                    end
                                end
                            end, "-"),
                        Span(:class => "w-12 text-center text-xl font-mono text-accent-500", field_value),
                        Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                            :on_click => () -> begin
                                new_val = field_value() + 1
                                set_field_value(new_val)
                                if shape_type() == 1
                                    set_area_result(3 * new_val * new_val)
                                else
                                    set_area_result(new_val)
                                end
                            end, "+")
                    )
                ),
                # Method result - show/hide for method labels
                Div(:class => "mt-4 p-2 bg-warm-200 dark:bg-warm-600 rounded text-sm",
                    Span(:class => () -> shape_type() == 1 ? "text-warm-600 dark:text-warm-300" : "hidden", "area(c::Circle)"),
                    Span(:class => () -> shape_type() == 2 ? "text-warm-600 dark:text-warm-300" : "hidden", "area(r::Rectangle)"),
                    Span(:class => "text-warm-600 dark:text-warm-300", " = "),
                    Span(:class => "text-accent-500 font-mono font-bold", area_result)
                )
            )
        ),

        # Explanation
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Same function name, different method per type")
    )
end

"""
Vector arithmetic demo - shows custom arithmetic operations on Vec2 type.
Uses integer signals with show/hide for text labels.
"""
VectorArithmeticDemo = island(:VectorArithmeticDemo) do
    # Vector 1
    v1_x, set_v1_x = create_signal(3)
    v1_y, set_v1_y = create_signal(4)

    # Second operand value (either v2.x/v2.y or scale factor)
    operand_value, set_operand_value = create_signal(2)

    # Results
    result_x, set_result_x = create_signal(5)  # 3 + 2 for add_vec
    result_y, set_result_y = create_signal(6)  # 4 + 2 for add_vec

    # Operation: 1 = add, 2 = scale
    operation, set_operation = create_signal(1)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[250px] gap-4",
        # Operation selector
        Div(:class => "flex gap-2",
            Button(:class => () -> operation() == 1 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                :on_click => () -> begin
                    set_operation(1)
                    set_result_x(v1_x() + operand_value())
                    set_result_y(v1_y() + operand_value())
                end, "add_vec"
            ),
            Button(:class => () -> operation() == 2 ? "px-3 py-1 rounded bg-accent-500 text-white text-sm" : "px-3 py-1 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                :on_click => () -> begin
                    set_operation(2)
                    set_result_x(v1_x() * operand_value())
                    set_result_y(v1_y() * operand_value())
                end, "scale_vec"
            )
        ),

        # Vectors display
        Div(:class => "flex items-center gap-3",
            # Vector 1
            Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-2", "v1 = Vec2"),
                Div(:class => "flex gap-2",
                    Div(:class => "text-center",
                        Span(:class => "text-xs text-warm-400", "x"),
                        Div(:class => "flex items-center gap-0.5",
                            Button(:class => "w-5 h-5 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                                :on_click => () -> begin
                                    new_x = v1_x() - 1
                                    set_v1_x(new_x)
                                    if operation() == 1
                                        set_result_x(new_x + operand_value())
                                    else
                                        set_result_x(new_x * operand_value())
                                    end
                                end, "-"),
                            Span(:class => "w-6 text-center font-mono text-accent-500", v1_x),
                            Button(:class => "w-5 h-5 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                                :on_click => () -> begin
                                    new_x = v1_x() + 1
                                    set_v1_x(new_x)
                                    if operation() == 1
                                        set_result_x(new_x + operand_value())
                                    else
                                        set_result_x(new_x * operand_value())
                                    end
                                end, "+")
                        )
                    ),
                    Div(:class => "text-center",
                        Span(:class => "text-xs text-warm-400", "y"),
                        Div(:class => "flex items-center gap-0.5",
                            Button(:class => "w-5 h-5 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                                :on_click => () -> begin
                                    new_y = v1_y() - 1
                                    set_v1_y(new_y)
                                    if operation() == 1
                                        set_result_y(new_y + operand_value())
                                    else
                                        set_result_y(new_y * operand_value())
                                    end
                                end, "-"),
                            Span(:class => "w-6 text-center font-mono text-accent-500", v1_y),
                            Button(:class => "w-5 h-5 rounded bg-warm-200 dark:bg-warm-600 text-xs",
                                :on_click => () -> begin
                                    new_y = v1_y() + 1
                                    set_v1_y(new_y)
                                    if operation() == 1
                                        set_result_y(new_y + operand_value())
                                    else
                                        set_result_y(new_y * operand_value())
                                    end
                                end, "+")
                        )
                    )
                )
            ),

            # Second operand (shows as v2 or s based on mode) - use show/hide for labels
            Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg text-center",
                Span(:class => () -> operation() == 1 ? "text-xs text-warm-500 dark:text-warm-400 block mb-2" : "hidden", "v2.x = v2.y"),
                Span(:class => () -> operation() == 2 ? "text-xs text-warm-500 dark:text-warm-400 block mb-2" : "hidden", "scalar s"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            new_v = operand_value() - 1
                            set_operand_value(new_v)
                            if operation() == 1
                                set_result_x(v1_x() + new_v)
                                set_result_y(v1_y() + new_v)
                            else
                                set_result_x(v1_x() * new_v)
                                set_result_y(v1_y() * new_v)
                            end
                        end, "-"),
                    Span(:class => "w-8 text-center text-xl font-mono text-accent-500", operand_value),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            new_v = operand_value() + 1
                            set_operand_value(new_v)
                            if operation() == 1
                                set_result_x(v1_x() + new_v)
                                set_result_y(v1_y() + new_v)
                            else
                                set_result_x(v1_x() * new_v)
                                set_result_y(v1_y() * new_v)
                            end
                        end, "+")
                )
            )
        ),

        # Method name and result - show/hide for method labels
        Div(:class => "text-center",
            Span(:class => () -> operation() == 1 ? "text-sm text-warm-500 dark:text-warm-400 block mb-1" : "hidden", "add_vec(v1, v2)"),
            Span(:class => () -> operation() == 2 ? "text-sm text-warm-500 dark:text-warm-400 block mb-1" : "hidden", "scale_vec(v1, s)"),
            Div(:class => "p-2 bg-accent-100 dark:bg-accent-900/30 rounded-lg",
                Span(:class => "text-sm text-accent-700 dark:text-accent-300", "→ Vec2("),
                Span(:class => "font-mono font-bold text-accent-600 dark:text-accent-400", result_x),
                Span(:class => "text-accent-700 dark:text-accent-300", ", "),
                Span(:class => "font-mono font-bold text-accent-600 dark:text-accent-400", result_y),
                Span(:class => "text-accent-700 dark:text-accent-300", ")")
            )
        ),

        # Explanation
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Methods defined for Vec2 type")
    )
end

"""
Type specialization demo - shows describe() with different type-specific behaviors.
Uses integer index signal with show/hide for all text content.
"""
TypeSpecializationDemo = island(:TypeSpecializationDemo) do
    # Input type: 1 = Int32 positive, 2 = Int32 negative, 3 = Int32 zero, 4 = Bool true, 5 = Bool false
    input_type, set_input_type = create_signal(1)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[250px] gap-4",
        # Type/value selector
        Div(:class => "grid grid-cols-3 gap-2",
            Button(:class => () -> input_type() == 1 ? "px-3 py-2 rounded bg-accent-500 text-white text-sm" : "px-3 py-2 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                :on_click => () -> set_input_type(1), "Int32(42)"
            ),
            Button(:class => () -> input_type() == 2 ? "px-3 py-2 rounded bg-accent-500 text-white text-sm" : "px-3 py-2 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                :on_click => () -> set_input_type(2), "Int32(-5)"
            ),
            Button(:class => () -> input_type() == 3 ? "px-3 py-2 rounded bg-accent-500 text-white text-sm" : "px-3 py-2 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                :on_click => () -> set_input_type(3), "Int32(0)"
            ),
            Button(:class => () -> input_type() == 4 ? "px-3 py-2 rounded bg-accent-500 text-white text-sm" : "px-3 py-2 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                :on_click => () -> set_input_type(4), "true"
            ),
            Button(:class => () -> input_type() == 5 ? "px-3 py-2 rounded bg-accent-500 text-white text-sm" : "px-3 py-2 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-sm",
                :on_click => () -> set_input_type(5), "false"
            )
        ),

        # Call visualization
        Div(:class => "p-4 bg-warm-100 dark:bg-warm-700 rounded-lg min-w-[280px]",
            # Function call - show/hide for input display
            Div(:class => "text-center mb-3",
                Span(:class => "text-warm-600 dark:text-warm-300 font-mono", "describe("),
                Span(:class => () -> input_type() == 1 ? "text-accent-500 font-mono font-bold" : "hidden", "42"),
                Span(:class => () -> input_type() == 2 ? "text-accent-500 font-mono font-bold" : "hidden", "-5"),
                Span(:class => () -> input_type() == 3 ? "text-accent-500 font-mono font-bold" : "hidden", "0"),
                Span(:class => () -> input_type() == 4 ? "text-accent-500 font-mono font-bold" : "hidden", "true"),
                Span(:class => () -> input_type() == 5 ? "text-accent-500 font-mono font-bold" : "hidden", "false"),
                Span(:class => "text-warm-600 dark:text-warm-300 font-mono", ")")
            ),
            # Arrow
            Div(:class => "flex justify-center my-2",
                Svg(:class => "w-5 h-5 text-warm-400", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M19 14l-7 7m0 0l-7-7m7 7V3")
                )
            ),
            # Method called - show/hide for method display
            Div(:class => "text-center text-sm text-warm-500 dark:text-warm-400 mb-2",
                "calls: ",
                Span(:class => () -> input_type() <= 3 ? "text-accent-600 dark:text-accent-400 font-mono" : "hidden", "describe(x::Int32)"),
                Span(:class => () -> input_type() >= 4 ? "text-accent-600 dark:text-accent-400 font-mono" : "hidden", "describe(x::Bool)")
            ),
            # Result - show/hide for result display
            Div(:class => "text-center p-2 bg-accent-100 dark:bg-accent-900/30 rounded",
                Span(:class => "text-xs text-accent-700 dark:text-accent-300", "returns: \""),
                Span(:class => () -> input_type() == 1 ? "text-accent-600 dark:text-accent-400 font-bold" : "hidden", "positive integer"),
                Span(:class => () -> input_type() == 2 ? "text-accent-600 dark:text-accent-400 font-bold" : "hidden", "negative integer"),
                Span(:class => () -> input_type() == 3 ? "text-accent-600 dark:text-accent-400 font-bold" : "hidden", "zero"),
                Span(:class => () -> input_type() == 4 ? "text-accent-600 dark:text-accent-400 font-bold" : "hidden", "true boolean"),
                Span(:class => () -> input_type() == 5 ? "text-accent-600 dark:text-accent-400 font-bold" : "hidden", "false boolean"),
                Span(:class => "text-accent-600 dark:text-accent-400 font-bold", "\"")
            )
        ),

        # Explanation
        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Julia picks the most specific method for the argument type")
    )
end

# =============================================================================
# Array Chapter Demos
# =============================================================================

"""
Vector mutation demo - shows how to select an index and modify array elements.
"""
VectorMutationDemo = island(:VectorMutationDemo) do
    # Array values
    v1, set_v1 = create_signal(1)
    v2, set_v2 = create_signal(2)
    v3, set_v3 = create_signal(3)
    v4, set_v4 = create_signal(4)
    v5, set_v5 = create_signal(5)

    # Selected index
    selected, set_selected = create_signal(1)

    # New value to set
    new_val, set_new_val = create_signal(100)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[220px] gap-4",
        # Array visualization
        Div(:class => "flex items-center gap-1",
            Span(:class => "text-warm-500 dark:text-warm-400", "arr = ["),
            Button(:class => () -> selected() == 1 ? "px-3 py-1 bg-accent-500 text-white rounded font-mono" : "px-3 py-1 bg-warm-200 dark:bg-warm-600 rounded font-mono text-warm-700 dark:text-white",
                :on_click => () -> set_selected(1), v1),
            Span(:class => "text-warm-400", ", "),
            Button(:class => () -> selected() == 2 ? "px-3 py-1 bg-accent-500 text-white rounded font-mono" : "px-3 py-1 bg-warm-200 dark:bg-warm-600 rounded font-mono text-warm-700 dark:text-white",
                :on_click => () -> set_selected(2), v2),
            Span(:class => "text-warm-400", ", "),
            Button(:class => () -> selected() == 3 ? "px-3 py-1 bg-accent-500 text-white rounded font-mono" : "px-3 py-1 bg-warm-200 dark:bg-warm-600 rounded font-mono text-warm-700 dark:text-white",
                :on_click => () -> set_selected(3), v3),
            Span(:class => "text-warm-400", ", "),
            Button(:class => () -> selected() == 4 ? "px-3 py-1 bg-accent-500 text-white rounded font-mono" : "px-3 py-1 bg-warm-200 dark:bg-warm-600 rounded font-mono text-warm-700 dark:text-white",
                :on_click => () -> set_selected(4), v4),
            Span(:class => "text-warm-400", ", "),
            Button(:class => () -> selected() == 5 ? "px-3 py-1 bg-accent-500 text-white rounded font-mono" : "px-3 py-1 bg-warm-200 dark:bg-warm-600 rounded font-mono text-warm-700 dark:text-white",
                :on_click => () -> set_selected(5), v5),
            Span(:class => "text-warm-500 dark:text-warm-400", "]")
        ),

        # New value input
        Div(:class => "flex items-center gap-3",
            Span(:class => "text-sm text-warm-600 dark:text-warm-400", "arr["),
            Span(:class => "text-accent-500 font-mono font-bold", selected),
            Span(:class => "text-sm text-warm-600 dark:text-warm-400", "] = "),
            Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> set_new_val(new_val() - 10), "-"),
            Span(:class => "text-accent-500 font-mono font-bold w-12 text-center", new_val),
            Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> set_new_val(new_val() + 10), "+")
        ),

        # Set button
        Button(:class => "px-4 py-2 bg-accent-500 hover:bg-accent-600 text-white rounded-lg font-medium",
            :on_click => () -> begin
                idx = selected()
                val = new_val()
                if idx == 1
                    set_v1(val)
                elseif idx == 2
                    set_v2(val)
                elseif idx == 3
                    set_v3(val)
                elseif idx == 4
                    set_v4(val)
                else
                    set_v5(val)
                end
            end, "Set Value"
        ),

        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Click element to select, adjust value, then Set")
    )
end

"""
Matrix demo - 3x3 matrix with cell selection showing row, col coordinates.
Uses a display_val signal updated by handlers to avoid SSR world-age issues.
"""
MatrixDemo = island(:MatrixDemo) do
    # Selected cell
    sel_row, set_sel_row = create_signal(2)
    sel_col, set_sel_col = create_signal(2)
    # Display value - updated when cell is clicked
    display_val, set_display_val = create_signal(5)  # Center cell value

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[250px] gap-4",
        # Matrix grid - values are static since matrix doesn't change
        Div(:class => "grid grid-cols-3 gap-1",
            # Row 1
            Button(:class => () -> sel_row() == 1 && sel_col() == 1 ? "w-12 h-12 bg-accent-500 text-white rounded font-mono text-lg" : "w-12 h-12 bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white rounded font-mono text-lg hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> begin set_sel_row(1); set_sel_col(1); set_display_val(1) end, "1"),
            Button(:class => () -> sel_row() == 1 && sel_col() == 2 ? "w-12 h-12 bg-accent-500 text-white rounded font-mono text-lg" : "w-12 h-12 bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white rounded font-mono text-lg hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> begin set_sel_row(1); set_sel_col(2); set_display_val(2) end, "2"),
            Button(:class => () -> sel_row() == 1 && sel_col() == 3 ? "w-12 h-12 bg-accent-500 text-white rounded font-mono text-lg" : "w-12 h-12 bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white rounded font-mono text-lg hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> begin set_sel_row(1); set_sel_col(3); set_display_val(3) end, "3"),
            # Row 2
            Button(:class => () -> sel_row() == 2 && sel_col() == 1 ? "w-12 h-12 bg-accent-500 text-white rounded font-mono text-lg" : "w-12 h-12 bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white rounded font-mono text-lg hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> begin set_sel_row(2); set_sel_col(1); set_display_val(4) end, "4"),
            Button(:class => () -> sel_row() == 2 && sel_col() == 2 ? "w-12 h-12 bg-accent-500 text-white rounded font-mono text-lg" : "w-12 h-12 bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white rounded font-mono text-lg hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> begin set_sel_row(2); set_sel_col(2); set_display_val(5) end, "5"),
            Button(:class => () -> sel_row() == 2 && sel_col() == 3 ? "w-12 h-12 bg-accent-500 text-white rounded font-mono text-lg" : "w-12 h-12 bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white rounded font-mono text-lg hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> begin set_sel_row(2); set_sel_col(3); set_display_val(6) end, "6"),
            # Row 3
            Button(:class => () -> sel_row() == 3 && sel_col() == 1 ? "w-12 h-12 bg-accent-500 text-white rounded font-mono text-lg" : "w-12 h-12 bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white rounded font-mono text-lg hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> begin set_sel_row(3); set_sel_col(1); set_display_val(7) end, "7"),
            Button(:class => () -> sel_row() == 3 && sel_col() == 2 ? "w-12 h-12 bg-accent-500 text-white rounded font-mono text-lg" : "w-12 h-12 bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white rounded font-mono text-lg hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> begin set_sel_row(3); set_sel_col(2); set_display_val(8) end, "8"),
            Button(:class => () -> sel_row() == 3 && sel_col() == 3 ? "w-12 h-12 bg-accent-500 text-white rounded font-mono text-lg" : "w-12 h-12 bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white rounded font-mono text-lg hover:bg-warm-300 dark:hover:bg-warm-500",
                :on_click => () -> begin set_sel_row(3); set_sel_col(3); set_display_val(9) end, "9")
        ),

        # Selected cell info - use display_val signal
        Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg min-w-[200px] text-center",
            Span(:class => "text-warm-600 dark:text-warm-300 font-mono", "mat["),
            Span(:class => "text-accent-500 font-bold", sel_row),
            Span(:class => "text-warm-600 dark:text-warm-300 font-mono", ", "),
            Span(:class => "text-accent-500 font-bold", sel_col),
            Span(:class => "text-warm-600 dark:text-warm-300 font-mono", "] = "),
            Span(:class => "text-accent-500 font-bold text-xl font-mono", display_val)
        ),

        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Click a cell to see its [row, col] coordinates")
    )
end

"""
Array iteration demo - step through array elements and accumulate sum.
Uses simple integer signals with static labels to avoid compilation issues.
"""
ArrayIterationDemo = island(:ArrayIterationDemo) do
    # Current index (0 = not started, 1-4 = at element, 5 = done)
    idx, set_idx = create_signal(0)

    # Running sum
    running_sum, set_running_sum = create_signal(0)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[220px] gap-4",
        # Array visualization with current position highlighted
        Div(:class => "flex items-center gap-1",
            Span(:class => "text-warm-500 dark:text-warm-400 font-mono", "arr = ["),
            Span(:class => () -> idx() == 1 ? "px-2 py-1 bg-accent-500 text-white rounded font-mono" : "px-2 py-1 bg-warm-200 dark:bg-warm-600 rounded font-mono text-warm-700 dark:text-white", "10"),
            Span(:class => "text-warm-400", ", "),
            Span(:class => () -> idx() == 2 ? "px-2 py-1 bg-accent-500 text-white rounded font-mono" : "px-2 py-1 bg-warm-200 dark:bg-warm-600 rounded font-mono text-warm-700 dark:text-white", "20"),
            Span(:class => "text-warm-400", ", "),
            Span(:class => () -> idx() == 3 ? "px-2 py-1 bg-accent-500 text-white rounded font-mono" : "px-2 py-1 bg-warm-200 dark:bg-warm-600 rounded font-mono text-warm-700 dark:text-white", "30"),
            Span(:class => "text-warm-400", ", "),
            Span(:class => () -> idx() == 4 ? "px-2 py-1 bg-accent-500 text-white rounded font-mono" : "px-2 py-1 bg-warm-200 dark:bg-warm-600 rounded font-mono text-warm-700 dark:text-white", "40"),
            Span(:class => "text-warm-500 dark:text-warm-400 font-mono", "]")
        ),

        # Current index and sum display
        Div(:class => "grid grid-cols-2 gap-3",
            Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "index"),
                Span(:class => "text-accent-500 font-bold text-2xl font-mono", idx)
            ),
            Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "sum"),
                Span(:class => "text-accent-500 font-bold text-2xl font-mono", running_sum)
            )
        ),

        # Controls
        Div(:class => "flex gap-2",
            Button(:class => "px-4 py-2 bg-accent-500 hover:bg-accent-600 text-white rounded-lg font-medium transition-colors",
                :on_click => () -> begin
                    current = idx()
                    if current < 4
                        next_idx = current + 1
                        set_idx(next_idx)
                        # Add the value at next_idx to running sum
                        if next_idx == 1
                            set_running_sum(running_sum() + 10)
                        elseif next_idx == 2
                            set_running_sum(running_sum() + 20)
                        elseif next_idx == 3
                            set_running_sum(running_sum() + 30)
                        else
                            set_running_sum(running_sum() + 40)
                        end
                    end
                end, "Step"
            ),
            Button(:class => "px-4 py-2 bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white rounded-lg font-medium hover:bg-warm-300 dark:hover:bg-warm-500 transition-colors",
                :on_click => () -> begin
                    set_idx(0)
                    set_running_sum(0)
                end, "Reset"
            )
        ),

        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Click Step to iterate, watch sum accumulate (total: 100)")
    )
end

"""
Array sum demo - adjustable array values with live sum and average.
Uses explicit signals for sum/average and inlines computations in handlers.
"""
ArraySumDemo = island(:ArraySumDemo) do
    # Array values
    v1, set_v1 = create_signal(10)
    v2, set_v2 = create_signal(20)
    v3, set_v3 = create_signal(30)
    v4, set_v4 = create_signal(40)
    v5, set_v5 = create_signal(50)

    # Computed sum and average stored as signals (updated by handlers)
    sum_val, set_sum_val = create_signal(150)
    avg_val, set_avg_val = create_signal(30)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[250px] gap-4",
        # Array with adjustable values
        Div(:class => "flex items-center gap-1 flex-wrap justify-center",
            Span(:class => "text-warm-500 dark:text-warm-400", "["),
            # Element 1
            Div(:class => "flex flex-col items-center",
                Button(:class => "w-6 h-5 rounded-t bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        nv = v1() + 5
                        set_v1(nv)
                        total = nv + v2() + v3() + v4() + v5()
                        set_sum_val(total)
                        set_avg_val(div(total, 5))
                    end, "+"),
                Span(:class => "px-2 py-1 bg-accent-100 dark:bg-accent-900/30 font-mono text-accent-600 dark:text-accent-400 w-10 text-center", v1),
                Button(:class => "w-6 h-5 rounded-b bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        nv = v1() - 5
                        set_v1(nv)
                        total = nv + v2() + v3() + v4() + v5()
                        set_sum_val(total)
                        set_avg_val(div(total, 5))
                    end, "-")
            ),
            Span(:class => "text-warm-400 mx-1", ","),
            # Element 2
            Div(:class => "flex flex-col items-center",
                Button(:class => "w-6 h-5 rounded-t bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        nv = v2() + 5
                        set_v2(nv)
                        total = v1() + nv + v3() + v4() + v5()
                        set_sum_val(total)
                        set_avg_val(div(total, 5))
                    end, "+"),
                Span(:class => "px-2 py-1 bg-accent-100 dark:bg-accent-900/30 font-mono text-accent-600 dark:text-accent-400 w-10 text-center", v2),
                Button(:class => "w-6 h-5 rounded-b bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        nv = v2() - 5
                        set_v2(nv)
                        total = v1() + nv + v3() + v4() + v5()
                        set_sum_val(total)
                        set_avg_val(div(total, 5))
                    end, "-")
            ),
            Span(:class => "text-warm-400 mx-1", ","),
            # Element 3
            Div(:class => "flex flex-col items-center",
                Button(:class => "w-6 h-5 rounded-t bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        nv = v3() + 5
                        set_v3(nv)
                        total = v1() + v2() + nv + v4() + v5()
                        set_sum_val(total)
                        set_avg_val(div(total, 5))
                    end, "+"),
                Span(:class => "px-2 py-1 bg-accent-100 dark:bg-accent-900/30 font-mono text-accent-600 dark:text-accent-400 w-10 text-center", v3),
                Button(:class => "w-6 h-5 rounded-b bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        nv = v3() - 5
                        set_v3(nv)
                        total = v1() + v2() + nv + v4() + v5()
                        set_sum_val(total)
                        set_avg_val(div(total, 5))
                    end, "-")
            ),
            Span(:class => "text-warm-400 mx-1", ","),
            # Element 4
            Div(:class => "flex flex-col items-center",
                Button(:class => "w-6 h-5 rounded-t bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        nv = v4() + 5
                        set_v4(nv)
                        total = v1() + v2() + v3() + nv + v5()
                        set_sum_val(total)
                        set_avg_val(div(total, 5))
                    end, "+"),
                Span(:class => "px-2 py-1 bg-accent-100 dark:bg-accent-900/30 font-mono text-accent-600 dark:text-accent-400 w-10 text-center", v4),
                Button(:class => "w-6 h-5 rounded-b bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        nv = v4() - 5
                        set_v4(nv)
                        total = v1() + v2() + v3() + nv + v5()
                        set_sum_val(total)
                        set_avg_val(div(total, 5))
                    end, "-")
            ),
            Span(:class => "text-warm-400 mx-1", ","),
            # Element 5
            Div(:class => "flex flex-col items-center",
                Button(:class => "w-6 h-5 rounded-t bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        nv = v5() + 5
                        set_v5(nv)
                        total = v1() + v2() + v3() + v4() + nv
                        set_sum_val(total)
                        set_avg_val(div(total, 5))
                    end, "+"),
                Span(:class => "px-2 py-1 bg-accent-100 dark:bg-accent-900/30 font-mono text-accent-600 dark:text-accent-400 w-10 text-center", v5),
                Button(:class => "w-6 h-5 rounded-b bg-warm-200 dark:bg-warm-600 text-xs",
                    :on_click => () -> begin
                        nv = v5() - 5
                        set_v5(nv)
                        total = v1() + v2() + v3() + v4() + nv
                        set_sum_val(total)
                        set_avg_val(div(total, 5))
                    end, "-")
            ),
            Span(:class => "text-warm-500 dark:text-warm-400", "]")
        ),

        # Sum and average display - use signal getters directly (not closures)
        Div(:class => "grid grid-cols-2 gap-4",
            Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "sum"),
                Span(:class => "text-accent-500 font-bold text-2xl font-mono", sum_val)
            ),
            Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg text-center",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400 block mb-1", "average"),
                Span(:class => "text-accent-500 font-bold text-2xl font-mono", avg_val)
            )
        ),

        Span(:class => "text-xs text-warm-500 dark:text-warm-400", "Adjust array values to see sum and average update")
    )
end

# =============================================================================
# Tuple Demos for Tuples Chapter
# =============================================================================

"""
FunctionReturnTupleDemo - demonstrates a function that returns multiple values as a tuple.
Shows how tuples enable functions to return multiple values.
"""
FunctionReturnTupleDemo = island(:FunctionReturnTupleDemo) do
    a, set_a = create_signal(10)
    b, set_b = create_signal(3)
    # Pre-computed results to avoid SSR world-age issues
    sum_result, set_sum = create_signal(13)
    diff_result, set_diff = create_signal(7)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[220px] gap-4",
        # Function definition display
        Div(:class => "p-3 bg-warm-100 dark:bg-warm-700 rounded-lg text-sm font-mono text-center",
            Span(:class => "text-warm-500 dark:text-warm-400", "sum_and_diff(a, b) = "),
            Span(:class => "text-accent-500", "(a + b, a - b)")
        ),

        # Input controls
        Div(:class => "flex items-center gap-4",
            # Input a
            Div(:class => "flex flex-col items-center gap-1",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400", "a"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            nv = a() - 1
                            set_a(nv)
                            set_sum(nv + b())
                            set_diff(nv - b())
                        end, "-"),
                    Span(:class => "w-10 text-center font-mono text-lg", a),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            nv = a() + 1
                            set_a(nv)
                            set_sum(nv + b())
                            set_diff(nv - b())
                        end, "+")
                )
            ),
            # Input b
            Div(:class => "flex flex-col items-center gap-1",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400", "b"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            nv = b() - 1
                            set_b(nv)
                            set_sum(a() + nv)
                            set_diff(a() - nv)
                        end, "-"),
                    Span(:class => "w-10 text-center font-mono text-lg", b),
                    Button(:class => "w-6 h-6 rounded bg-warm-200 dark:bg-warm-600 text-sm",
                        :on_click => () -> begin
                            nv = b() + 1
                            set_b(nv)
                            set_sum(a() + nv)
                            set_diff(a() - nv)
                        end, "+")
                )
            )
        ),

        # Result tuple display
        Div(:class => "p-4 bg-gradient-to-r from-accent-50 to-accent-50 dark:from-accent-900/20 dark:to-accent-900/20 rounded-lg",
            Div(:class => "text-center",
                Span(:class => "text-sm text-warm-500 dark:text-warm-400", "result = "),
                Span(:class => "text-accent-500 font-mono text-lg", "("),
                Span(:class => "text-accent-600 dark:text-accent-400 font-mono font-bold text-xl", sum_result),
                Span(:class => "text-accent-500 font-mono text-lg", ", "),
                Span(:class => "text-accent-600 dark:text-accent-400 font-mono font-bold text-xl", diff_result),
                Span(:class => "text-accent-500 font-mono text-lg", ")")
            ),
            Div(:class => "flex justify-center gap-6 mt-2 text-xs text-warm-500 dark:text-warm-400",
                Span("result[1] = sum"),
                Span("result[2] = diff")
            )
        )
    )
end

"""
MixedTypeTupleDemo - demonstrates tuples containing different types.
Shows that tuples can hold heterogeneous values (Int, Float, Bool).
Uses integer signal (1/0) for bool to make Wasm compilation work.
"""
MixedTypeTupleDemo = island(:MixedTypeTupleDemo) do
    # Tuple with mixed types: (Int32, Float32, Bool)
    int_val, set_int = create_signal(42)
    # Use 1 for true, 0 for false to avoid string comparisons in handlers
    bool_val, set_bool = create_signal(1)

    Div(:class => "flex flex-col items-center justify-center h-full min-h-[200px] gap-4",
        # Tuple visualization
        Div(:class => "p-4 bg-warm-100 dark:bg-warm-700 rounded-lg",
            Span(:class => "text-warm-500 dark:text-warm-400 text-sm", "mixed = "),
            Span(:class => "text-accent-500 font-mono text-lg", "("),
            Span(:class => "text-blue-500 font-mono font-bold", int_val),
            Span(:class => "text-warm-400", " :: Int32"),
            Span(:class => "text-accent-500 font-mono", ", "),
            Span(:class => "text-green-500 font-mono font-bold", "3.14"),
            Span(:class => "text-warm-400", " :: Float64"),
            Span(:class => "text-accent-500 font-mono", ", "),
            Span(:id => "mixed-bool-display", :class => "text-amber-500 font-mono font-bold", "true"),
            Span(:class => "text-warm-400", " :: Bool"),
            Span(:class => "text-accent-500 font-mono text-lg", ")")
        ),

        # Type info
        Div(:class => "text-xs text-warm-500 dark:text-warm-400 text-center",
            "typeof(mixed) = Tuple{Int32, Float64, Bool}"
        ),

        # Controls
        Div(:class => "flex items-center gap-6",
            # Integer control
            Div(:class => "flex flex-col items-center gap-1",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400", "mixed[1]"),
                Div(:class => "flex items-center gap-1",
                    Button(:class => "w-6 h-6 rounded bg-blue-200 dark:bg-blue-800 text-blue-800 dark:text-blue-200 text-sm",
                        :on_click => () -> set_int(int_val() - 1), "-"),
                    Span(:class => "w-12 text-center font-mono text-blue-500", int_val),
                    Button(:class => "w-6 h-6 rounded bg-blue-200 dark:bg-blue-800 text-blue-800 dark:text-blue-200 text-sm",
                        :on_click => () -> set_int(int_val() + 1), "+")
                )
            ),
            # Bool toggle - uses JS onclick to update display, signal tracks state for potential future use
            Div(:class => "flex flex-col items-center gap-1",
                Span(:class => "text-xs text-warm-500 dark:text-warm-400", "mixed[3]"),
                Button(:id => "mixed-bool-btn",
                    :class => "px-4 py-1 rounded bg-amber-500 text-white font-mono",
                    :onclick => """
                        let btn = this;
                        let display = document.getElementById('mixed-bool-display');
                        if (display.textContent === 'true') {
                            display.textContent = 'false';
                            btn.textContent = 'false';
                            btn.className = 'px-4 py-1 rounded bg-warm-300 dark:bg-warm-600 text-warm-600 dark:text-warm-300 font-mono';
                        } else {
                            display.textContent = 'true';
                            btn.textContent = 'true';
                            btn.className = 'px-4 py-1 rounded bg-amber-500 text-white font-mono';
                        }
                    """,
                    "true"
                )
            )
        ),

        Span(:class => "text-xs text-warm-500 dark:text-warm-400 mt-2",
            "Tuples preserve the type of each element")
    )
end
