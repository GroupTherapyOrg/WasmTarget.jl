# Home page - Clean static docs landing page
#
# Uses Suite.jl components for visual presentation.
# JuliaPlayground REMOVED (W4 cleanup) — replaced with static intro.

import Suite

function Index()
    Div(:class => "py-8",
        # Hero
        Div(:class => "text-center mb-12",
            H1(:class => "text-4xl font-serif font-semibold text-warm-800 dark:text-warm-100",
                "Julia → WebAssembly"
            ),
            P(:class => "text-xl text-warm-500 dark:text-warm-400 mt-3 max-w-2xl mx-auto",
                "Write Julia. Compile to WASM. Run in the browser."
            ),
            Div(:class => "mt-4 flex justify-center gap-3",
                Suite.Badge("Julia Compiler"),
                Suite.Badge("WebAssembly", variant="secondary"),
                Suite.Badge("Browser Runtime", variant="outline"),
            ),
            # CTAs
            Div(:class => "mt-8 flex justify-center gap-4 flex-wrap",
                A(:href => "./manual/",
                    Suite.Button(size="lg", "Get Started")
                ),
                A(:href => "https://github.com/GroupTherapyOrg/WasmTarget.jl", :target => "_blank",
                    Suite.Button(variant="outline", size="lg", "View Source")
                )
            )
        ),

        # Quick example
        Div(:class => "max-w-4xl mx-auto mb-16",
            Suite.Card(
                Suite.CardHeader(
                    Suite.CardTitle("Quick Example"),
                    Suite.CardDescription("Julia functions compile directly to WebAssembly instructions")
                ),
                Suite.CardContent(
                    Suite.CodeBlock("""# Define a Julia function with typed arguments
function sum_to_n(n::Int32)::Int32
    result = Int32(0)
    i = Int32(1)
    while i <= n
        result = result + i
        i = i + Int32(1)
    end
    return result
end

# Compiles to WASM:
#   local.get \$n     ;; load argument
#   i32.const 0      ;; initialize result
#   loop              ;; while loop → WASM loop/br
#     i32.add         ;; result + i
#   end
# sum_to_n(100) → 5050""", language="julia")
                )
            )
        ),

        # Feature grid
        Div(:class => "max-w-5xl mx-auto mb-16",
            H2(:class => "text-2xl font-serif font-semibold text-center text-warm-800 dark:text-warm-100 mb-8",
                "Key Features"
            ),
            Div(:class => "grid md:grid-cols-2 lg:grid-cols-3 gap-6",
                _FeatureCard(
                    "Native Types",
                    "Int32, Int64, Float32, Float64 compile to WASM i32, i64, f32, f64 — zero overhead."
                ),
                _FeatureCard(
                    "Control Flow",
                    "if/else, while, for loops compile to native WASM branch and loop instructions."
                ),
                _FeatureCard(
                    "Recursion",
                    "Recursive functions compile to WASM call instructions with proper stack management."
                ),
                _FeatureCard(
                    "Structs & Tuples",
                    "Julia structs compile to WasmGC struct types. Tuples are immutable value types."
                ),
                _FeatureCard(
                    "Closures",
                    "Closures with captured variables compile to WasmGC objects with function references."
                ),
                _FeatureCard(
                    "JS Interop",
                    "Import JavaScript functions, export WASM functions. Use externref for JS object handles."
                )
            )
        ),

        # Interactive Julia Manual Section
        _ManualFeatureSection()
    )
end

# --- Helper: static feature card ---
function _FeatureCard(title, description)
    Suite.Card(
        Suite.CardContent(class="p-5",
            H3(:class => "font-semibold text-warm-800 dark:text-warm-100 mb-2", title),
            P(:class => "text-sm text-warm-600 dark:text-warm-400", description)
        )
    )
end

# --- Manual section linking to the tutorial ---
function _ManualFeatureSection()
    Div(:class => "mt-8 mb-8",
        # Section header
        Div(:class => "text-center mb-8",
            H2(:class => "text-3xl font-serif font-semibold text-warm-800 dark:text-warm-100",
                "Julia Manual"
            ),
            P(:class => "text-warm-500 dark:text-warm-400 mt-2 max-w-2xl mx-auto",
                "Learn Julia through code examples that demonstrate features compiled to WebAssembly."
            )
        ),

        # Feature card
        A(:href => "./manual/",
          :class => "group block max-w-4xl mx-auto",
            Suite.Card(class="bg-gradient-to-br from-warm-50 to-warm-100 dark:from-warm-900 dark:to-warm-950 hover:border-accent-400 dark:hover:border-accent-600 hover:shadow-xl hover:shadow-accent-500/10 transition-all duration-300",
                Suite.CardContent(class="p-8",
                    Div(:class => "flex flex-col md:flex-row items-center gap-8",
                        # Icon
                        Div(:class => "flex-shrink-0 w-20 h-20 bg-gradient-to-br from-accent-400 to-accent-500 rounded-2xl flex items-center justify-center shadow-lg shadow-accent-500/20 group-hover:scale-105 transition-transform duration-300",
                            Svg(:class => "w-10 h-10 text-white", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                                Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                                     :d => "M12 6.253v13m0-13C10.832 5.477 9.246 5 7.5 5S4.168 5.477 3 6.253v13C4.168 18.477 5.754 18 7.5 18s3.332.477 4.5 1.253m0-13C13.168 5.477 14.754 5 16.5 5c1.747 0 3.332.477 4.5 1.253v13C19.832 18.477 18.247 18 16.5 18c-1.746 0-3.332.477-4.5 1.253")
                            )
                        ),
                        # Content
                        Div(:class => "flex-1 text-center md:text-left",
                            H3(:class => "text-2xl font-bold text-warm-800 dark:text-warm-100 group-hover:text-accent-600 dark:group-hover:text-accent-400 transition-colors",
                                "10 Chapters"
                            ),
                            P(:class => "text-warm-600 dark:text-warm-400 mt-2 mb-4",
                                "From variables to multiple dispatch, each chapter features code examples showing Julia compiled to WebAssembly."
                            ),
                            # Chapter tags using Suite.Badge
                            Div(:class => "flex flex-wrap justify-center md:justify-start gap-2",
                                Suite.Badge(variant="outline", "Variables"),
                                Suite.Badge(variant="outline", "Functions"),
                                Suite.Badge(variant="outline", "Control Flow"),
                                Suite.Badge(variant="outline", "Types"),
                                Suite.Badge(variant="outline", "Arrays"),
                                Suite.Badge(variant="secondary", "+5 more")
                            )
                        ),
                        # Arrow
                        Div(:class => "flex-shrink-0 hidden md:block",
                            Svg(:class => "w-8 h-8 text-accent-400 group-hover:text-accent-500 group-hover:translate-x-2 transition-all duration-300",
                                :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                                Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                                     :d => "M9 5l7 7-7 7")
                            )
                        )
                    )
                )
            )
        ),

        # Link to features
        Div(:class => "max-w-4xl mx-auto mt-4 text-center",
            P(:class => "text-sm text-warm-500 dark:text-warm-500",
                A(:href => "./features/", :class => "text-accent-500 hover:text-accent-600 dark:text-accent-400 dark:hover:text-accent-300 underline", "See supported features →")
            )
        )
    )
end

# Export
Index
