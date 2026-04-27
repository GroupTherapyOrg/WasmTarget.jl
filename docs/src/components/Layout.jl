"""WasmTarget.jl wordmark with colored .jl suffix"""
function WasmTargetWordmark()
    NavLink("/WasmTarget.jl/",
        RawHtml("""WasmTarget<span style="color:var(--jl-dot)">.</span><span style="color:var(--jl-j)">j</span><span style="color:var(--jl-l)">l</span>""");
        class = "text-xl font-serif font-bold text-warm-900 dark:text-warm-100 hover:opacity-80 transition-opacity no-underline",
        active_class = ""
    )
end

function Layout(content)
    Div(:class => "min-h-screen flex flex-col bg-warm-100 dark:bg-warm-950 text-warm-800 dark:text-warm-200 transition-colors",
        # Nav — sticky at the top of the viewport so long pages keep
        # the brand + navigation visible while scrolling. Matches the
        # canonical docs layout (Astro Starlight / Vercel / Supabase):
        # top nav always visible, content scrolls underneath.
        # `backdrop-blur` + translucent bg lets content scrolling
        # behind stay faintly visible. `z-40` keeps it above any
        # sticky page-level sidebars. `h-16` (fixed height) gives the
        # page a predictable anchor instead of the variable height a
        # `py-*` Nav would produce.
        Nav(:class => "sticky top-0 z-40 border-b border-warm-200 dark:border-warm-800 h-16 px-6 bg-warm-100/80 dark:bg-warm-950/80 backdrop-blur supports-[backdrop-filter]:bg-warm-100/60 supports-[backdrop-filter]:dark:bg-warm-950/60",
            Div(:class => "max-w-5xl mx-auto h-full flex items-center justify-between",
                WasmTargetWordmark(),
                Div(:class => "flex items-center gap-6",
                    NavLink("/WasmTarget.jl/getting-started/", "Getting Started";
                        class = "text-sm transition-colors no-underline",
                        active_class = "text-accent-600 dark:text-accent-400 font-medium",
                        inactive_class = "text-warm-600 dark:text-warm-400 hover:text-accent-600 dark:hover:text-accent-400"
                    ),
                    NavLink("/WasmTarget.jl/manual/", "Manual";
                        class = "text-sm transition-colors no-underline",
                        active_class = "text-accent-600 dark:text-accent-400 font-medium",
                        inactive_class = "text-warm-600 dark:text-warm-400 hover:text-accent-600 dark:hover:text-accent-400"
                    ),
                    NavLink("/WasmTarget.jl/api/", "API";
                        class = "text-sm transition-colors no-underline",
                        active_class = "text-accent-600 dark:text-accent-400 font-medium",
                        inactive_class = "text-warm-600 dark:text-warm-400 hover:text-accent-600 dark:hover:text-accent-400"
                    ),
                    A(:href => "https://github.com/GroupTherapyOrg/WasmTarget.jl", :target => "_blank",
                        :class => "text-warm-600 dark:text-warm-400 hover:text-warm-700 dark:hover:text-warm-300 transition-colors",
                        RawHtml("""<svg class="w-5 h-5" viewBox="0 0 24 24" fill="currentColor"><path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z"/></svg>""")
                    ),
                    DarkModeToggle()
                )
            )
        ),
        # Main content — id="page-content" enables SPA navigation (router swaps this)
        MainEl(:id => "page-content", :class => "flex-1 w-full max-w-5xl mx-auto px-6 py-12",
            content
        ),
        # Footer — 3 column: org name | package links | tagline
        Footer(:class => "border-t border-warm-200 dark:border-warm-800 px-6 py-6",
            Div(:class => "max-w-5xl mx-auto flex items-center justify-between",
                # Left: org name
                A(:href => "https://github.com/GroupTherapyOrg", :target => "_blank",
                    :class => "text-sm text-warm-600 dark:text-warm-400 hover:text-warm-700 dark:hover:text-warm-300 transition-colors no-underline",
                    "GroupTherapyOrg"
                ),
                # Center: package links
                Div(:class => "flex items-center gap-2 text-sm text-warm-500 dark:text-warm-500",
                    A(:href => "https://github.com/GroupTherapyOrg/WasmTarget.jl", :target => "_blank",
                        :class => "hover:text-warm-600 dark:hover:text-warm-300 transition-colors no-underline", "WasmTarget.jl"),
                    Span("/"),
                    A(:href => "https://github.com/GroupTherapyOrg/Therapy.jl", :target => "_blank",
                        :class => "hover:text-warm-600 dark:hover:text-warm-300 transition-colors no-underline", "Therapy.jl")
                ),
                # Right: tagline
                P(:class => "text-sm text-warm-500 dark:text-warm-500",
                    "Julia → ",
                    RawHtml("""<span class="font-serif font-semibold">WasmGC</span>""")
                )
            )
        )
    )
end
