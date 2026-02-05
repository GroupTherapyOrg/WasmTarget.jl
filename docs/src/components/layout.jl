# Layout.jl - Main documentation layout component
#
# Color scheme: Cyan/teal accents for WasmTarget.jl
# to differentiate from Therapy.jl's orange/yellow
#
# This is the app-level layout (specified in app.jl as layout = :Layout).
# Routes return just content — this Layout wraps them with nav + footer.
# The #page-content div enables SPA navigation (client-side router swaps its contents).

"""
Main documentation layout with navigation and footer.
Uses cyan/teal accent colors with dark mode support.
Uses NavLink for SPA navigation and active state highlighting.
"""
function Layout(children...; title="WasmTarget.jl")
    Div(:class => "min-h-screen bg-warm-50 dark:bg-warm-950 transition-colors duration-200",
        # Navigation
        Nav(:class => "bg-warm-100 dark:bg-warm-900 border-b border-warm-200 dark:border-warm-700 transition-colors duration-200",
            Div(:class => "max-w-7xl mx-auto px-4 sm:px-6 lg:px-8",
                Div(:class => "flex justify-between h-16",
                    # Logo
                    Div(:class => "flex items-center",
                        A(:href => "./", :class => "flex items-center",
                            Span(:class => "text-2xl font-bold text-warm-800 dark:text-warm-300", "WasmTarget"),
                            Span(:class => "text-2xl font-light",
                                Span(:class => "text-[#4063d8]/30 dark:text-[#4063d8]/40", "."),
                                Span(:class => "text-[#9558b2]/30 dark:text-[#9558b2]/40", "j"),
                                Span(:class => "text-[#389826]/30 dark:text-[#389826]/40", "l")
                            )
                        )
                    ),
                    # Navigation Links - use ./ prefix for base_path compatibility
                    # The client-side router's resolveUrl() prepends CONFIG.basePath to ./ paths
                    Div(:class => "hidden sm:flex sm:items-center sm:space-x-6",
                        NavLink("./", "Home";
                            class = "text-warm-600 dark:text-warm-300 hover:text-warm-900 dark:hover:text-white px-3 py-2 text-sm font-medium transition-colors",
                            active_class = "text-accent-600 dark:text-accent-400 font-semibold",
                            exact = true
                        ),
                        NavLink("./playground/", "Playground";
                            class = "text-warm-600 dark:text-warm-300 hover:text-warm-900 dark:hover:text-white px-3 py-2 text-sm font-medium transition-colors",
                            active_class = "text-accent-600 dark:text-accent-400 font-semibold"
                        ),
                        NavLink("./manual/", "Manual";
                            class = "text-warm-600 dark:text-warm-300 hover:text-warm-900 dark:hover:text-white px-3 py-2 text-sm font-medium transition-colors",
                            active_class = "text-accent-600 dark:text-accent-400 font-semibold"
                        ),
                        NavLink("./features/", "Features";
                            class = "text-warm-600 dark:text-warm-300 hover:text-warm-900 dark:hover:text-white px-3 py-2 text-sm font-medium transition-colors",
                            active_class = "text-accent-600 dark:text-accent-400 font-semibold",
                            exact = true
                        ),
                        NavLink("./api/", "API";
                            class = "text-warm-600 dark:text-warm-300 hover:text-warm-900 dark:hover:text-white px-3 py-2 text-sm font-medium transition-colors",
                            active_class = "text-accent-600 dark:text-accent-400 font-semibold",
                            exact = true
                        ),
                        # GitHub link (external, use regular A tag)
                        A(:href => "https://github.com/GroupTherapyOrg/WasmTarget.jl",
                          :class => "text-warm-500 hover:text-warm-700 dark:text-warm-400 dark:hover:text-warm-200 transition-colors",
                          :target => "_blank",
                          :title => "View on GitHub",
                            Svg(:class => "h-5 w-5", :fill => "currentColor", :viewBox => "0 0 24 24",
                                Path(:d => "M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z")
                            )
                        ),
                        # Theme Toggle
                        Div(:class => "ml-2", ThemeToggle())
                    )
                )
            )
        ),

        # Main Content - this #page-content ID is REQUIRED for SPA navigation
        # The client-side router swaps this element's contents during navigation
        MainEl(:id => "page-content", :class => "max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8",
            children...
        ),

        # Footer
        Footer(:class => "bg-warm-100 dark:bg-warm-900 border-t border-warm-200 dark:border-warm-700 mt-auto transition-colors duration-200",
            Div(:class => "max-w-7xl mx-auto py-6 px-4 sm:px-6 lg:px-8",
                Div(:class => "flex justify-between items-center",
                    P(:class => "text-warm-500 dark:text-warm-400 text-sm",
                        "Built with ",
                        A(:href => "https://github.com/GroupTherapyOrg/Therapy.jl", :class => "text-accent-500 dark:text-accent-400 hover:text-accent-600 dark:hover:text-accent-300", :target => "_blank", "Therapy.jl"),
                        " - Powered by ",
                        A(:href => "./", :class => "text-accent-500 dark:text-accent-400 hover:text-accent-600 dark:hover:text-accent-300", "WasmTarget.jl")
                    ),
                    P(:class => "text-warm-400 dark:text-warm-500 text-sm",
                        "MIT License"
                    )
                )
            )
        )
    )
end
