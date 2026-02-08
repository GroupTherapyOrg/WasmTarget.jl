# Playground page - Coming Soon placeholder
#
# InterpreterPlayground REMOVED (W4 cleanup) — replaced with Coming Soon page.
# Uses Suite.jl components for clean TBD layout.

import Suite

function PlaygroundPage()
    Div(:class => "w-full max-w-4xl mx-auto py-8",

        # Page Header
        Div(:class => "text-center mb-8",
            H1(:class => "text-3xl font-serif font-semibold text-warm-800 dark:text-warm-100",
                "Julia Playground"
            ),
            P(:class => "text-warm-500 dark:text-warm-400 mt-2 max-w-2xl mx-auto",
                "Write and run Julia code directly in your browser."
            ),
            Div(:class => "mt-3",
                Suite.Badge(variant="secondary", "In Development")
            )
        ),

        # Coming Soon alert
        Suite.Alert(class="mb-8",
            Suite.AlertTitle("Coming Soon"),
            Suite.AlertDescription(
                "The Julia Playground is under active development. When complete, it will let you write Julia code in the browser, compile it to WebAssembly using WasmTarget.jl, and see results instantly — all without a server."
            )
        ),

        # What the playground will do
        Suite.Card(class="mb-8",
            Suite.CardHeader(
                Suite.CardTitle("Planned Features")
            ),
            Suite.CardContent(
                Ul(:class => "space-y-3 text-warm-600 dark:text-warm-400",
                    Li(:class => "flex items-start gap-2",
                        Span(:class => "text-warm-400 mt-0.5", "○"),
                        Span("Write Julia code in a browser-based editor with syntax highlighting")
                    ),
                    Li(:class => "flex items-start gap-2",
                        Span(:class => "text-warm-400 mt-0.5", "○"),
                        Span("Compile Julia to WebAssembly client-side using WasmTarget.jl")
                    ),
                    Li(:class => "flex items-start gap-2",
                        Span(:class => "text-warm-400 mt-0.5", "○"),
                        Span("Execute compiled WASM and display results — no server required")
                    ),
                    Li(:class => "flex items-start gap-2",
                        Span(:class => "text-warm-400 mt-0.5", "○"),
                        Span("Support for all WasmTarget.jl features: integers, floats, control flow, structs, closures")
                    )
                )
            )
        ),

        # Technical note
        Suite.Alert(class="mb-8",
            Suite.AlertTitle("How It Will Work"),
            Suite.AlertDescription(
                "The playground will use a trimmed Julia runtime compiled to WebAssembly. Your code will be parsed by JuliaSyntax, type-inferred, and compiled to WASM by WasmTarget.jl — all running entirely in the browser."
            )
        ),

        # CTA
        Div(:class => "text-center",
            A(:href => "./features/",
                Suite.Button(size="lg", "Explore Supported Features")
            )
        )
    )
end

# Export
PlaygroundPage
