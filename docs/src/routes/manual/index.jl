# Manual Index Page - Chapter overview for the Interactive Julia Manual
#
# Landing page for /manual route showing all chapters with descriptions and links.
# Explains that examples run real Julia code via WebAssembly.

# Chapter data: (id, title, description, feature_tags)
const CHAPTERS = [
    (
        "variables",
        "Variables",
        "Learn about naming conventions, assignment, and type annotations in Julia.",
        ["naming", "assignment", "types"]
    ),
    (
        "integers-floats",
        "Integers & Floating-Point Numbers",
        "Explore numeric types including Int32, Int64, Float32, Float64, literals, and overflow behavior.",
        ["Int32", "Float64", "literals"]
    ),
    (
        "math-operations",
        "Mathematical Operations",
        "Master arithmetic, comparison, and bitwise operators with interactive examples.",
        ["arithmetic", "comparison", "bitwise"]
    ),
    (
        "strings",
        "Strings",
        "Work with string literals, concatenation, length, and comparison operations.",
        ["String", "concat", "length"]
    ),
    (
        "functions",
        "Functions",
        "Define functions, use arguments and return values, explore recursion and closures.",
        ["function", "recursion", "closure"]
    ),
    (
        "control-flow",
        "Control Flow",
        "Control program flow with if/else, while loops, for loops, and short-circuit operators.",
        ["if/else", "while", "for"]
    ),
    (
        "types",
        "Types (Structs)",
        "Create composite types with struct, understand mutable vs immutable, and access fields.",
        ["struct", "mutable", "fields"]
    ),
    (
        "methods",
        "Methods (Multiple Dispatch)",
        "Define methods with the same name but different type signatures for compile-time dispatch.",
        ["dispatch", "methods", "types"]
    ),
    (
        "arrays",
        "Arrays",
        "Create and manipulate vectors and matrices with indexing and iteration.",
        ["Vector", "Matrix", "indexing"]
    ),
    (
        "tuples",
        "Tuples",
        "Use tuples for fixed-size collections, multiple return values, and destructuring.",
        ["Tuple", "indexing", "return"]
    ),
]

"""
Feature tag badge component.
"""
function FeatureTag(tag)
    Span(:class => "inline-block px-2 py-0.5 text-xs rounded-full bg-accent-100 dark:bg-accent-900/30 text-warm-700 dark:text-warm-400",
        tag
    )
end

"""
Chapter card component for the manual index grid.
"""
function ChapterCard(id, title, description, tags)
    A(:href => "./manual/$(id)/",
      :class => "group block p-6 bg-warm-50 dark:bg-warm-900 rounded-xl border border-warm-200 dark:border-warm-700 hover:border-accent-300 dark:hover:border-accent-600 hover:shadow-lg hover:shadow-accent-500/10 transition-all duration-200",
        # Title with arrow
        Div(:class => "flex items-center justify-between mb-3",
            H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-100 group-hover:text-accent-600 dark:group-hover:text-accent-400 transition-colors",
                title
            ),
            Svg(:class => "w-5 h-5 text-warm-400 group-hover:text-accent-500 transition-colors group-hover:translate-x-1 duration-200",
                :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                     :d => "M9 5l7 7-7 7")
            )
        ),
        # Description
        P(:class => "text-warm-600 dark:text-warm-400 text-sm mb-4 line-clamp-2",
            description
        ),
        # Feature tags
        Div(:class => "flex flex-wrap gap-2",
            [FeatureTag(tag) for tag in tags]...
        )
    )
end

"""
Manual index page with hero section and chapter grid.
"""
function ManualIndex()
    ManualLayout(chapter_id="", chapter_title=nothing,
        # Hero section
        Div(:class => "text-center mb-12",
            # Icon
            Div(:class => "w-16 h-16 mx-auto mb-6 bg-gradient-to-br from-accent-400 to-accent-500 rounded-2xl flex items-center justify-center shadow-lg shadow-accent-500/20",
                Svg(:class => "w-8 h-8 text-white", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M12 6.253v13m0-13C10.832 5.477 9.246 5 7.5 5S4.168 5.477 3 6.253v13C4.168 18.477 5.754 18 7.5 18s3.332.477 4.5 1.253m0-13C13.168 5.477 14.754 5 16.5 5c1.747 0 3.332.477 4.5 1.253v13C19.832 18.477 18.247 18 16.5 18c-1.746 0-3.332.477-4.5 1.253")
                )
            ),
            H1(:class => "text-4xl font-bold text-warm-800 dark:text-warm-100 mb-4",
                "Interactive Julia Manual"
            ),
            P(:class => "text-xl text-warm-600 dark:text-warm-400 max-w-2xl mx-auto mb-6",
                "Learn Julia through hands-on examples that run real code in your browser via WebAssembly."
            ),
            # Explanation box
            Div(:class => "max-w-2xl mx-auto p-4 bg-warm-50 dark:bg-warm-900/20 rounded-xl border border-warm-200 dark:border-warm-700",
                Div(:class => "flex items-start gap-3",
                    Svg(:class => "w-5 h-5 text-accent-600 dark:text-accent-400 flex-shrink-0 mt-0.5",
                        :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                        Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                             :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                    ),
                    Div(
                        P(:class => "text-sm text-warm-800 dark:text-warm-300",
                            "Each chapter includes ",
                            Span(:class => "font-semibold", "live interactive examples"),
                            " powered by WasmTarget.jl. The Julia code is compiled to WebAssembly at build time, so you can experiment with real compiled code directly in your browser."
                        )
                    )
                )
            )
        ),

        # WasmTarget.jl subset note
        Div(:class => "mb-10 p-4 bg-amber-50 dark:bg-amber-900/20 rounded-xl border border-amber-200 dark:border-amber-800",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-amber-600 dark:text-amber-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z")
                ),
                Div(
                    P(:class => "text-sm text-amber-800 dark:text-amber-200 font-medium",
                        "WasmTarget.jl Subset"
                    ),
                    P(:class => "text-sm text-amber-700 dark:text-amber-300 mt-1",
                        "This manual covers the subset of Julia that compiles to WebAssembly via WasmTarget.jl. Some features like varargs, keyword arguments, and the full standard library are not yet supported. ",
                        A(:href => "./features/",
                          :class => "text-amber-800 dark:text-amber-200 underline hover:text-amber-900 dark:hover:text-amber-100",
                          "See the full list of supported features →"
                        )
                    )
                )
            )
        ),

        # Chapter grid
        Div(:class => "mb-8",
            H2(:class => "text-2xl font-bold text-warm-800 dark:text-warm-100 mb-6",
                "Chapters"
            ),
            Div(:class => "grid md:grid-cols-2 gap-4",
                [ChapterCard(id, title, desc, tags) for (id, title, desc, tags) in CHAPTERS]...
            )
        ),

        # Quick start CTA
        Div(:class => "text-center py-8 px-6 bg-gradient-to-r from-accent-500 to-accent-500 rounded-2xl",
            H3(:class => "text-2xl font-bold text-white mb-2",
                "Ready to dive in?"
            ),
            P(:class => "text-warm-100 mb-6",
                "Start with Variables to learn the basics, or jump to any chapter that interests you."
            ),
            A(:href => "./manual/variables/",
              :class => "inline-flex items-center gap-2 bg-warm-50 text-accent-600 px-6 py-3 rounded-lg font-semibold hover:bg-accent-50 transition-colors shadow-lg",
                "Start with Variables",
                Svg(:class => "w-4 h-4", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M9 5l7 7-7 7")
                )
            )
        )
    )
end

# Export
ManualIndex
