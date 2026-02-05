# Manual Chapter: Strings
#
# Interactive manual page covering string basics - literals, concatenation,
# length, and comparison. Scoped to WasmTarget.jl string support.
#
# Route: /manual/strings

# =============================================================================
# NOTE: This file uses pre-built islands from LiveExample.jl
# StringConcatDemo, StringLengthDemo, StringComparisonDemo
# are defined there and work correctly with SSR.
# =============================================================================

# =============================================================================
# Strings Chapter Page
# =============================================================================

"""
Strings chapter for the Interactive Julia Manual.
"""
function Strings()
    ManualLayout(chapter_id="strings", chapter_title="Strings",
        # Title
        H1(:class => "text-3xl font-bold text-warm-800 dark:text-warm-100 mb-4",
            "Strings"
        ),

        # Introduction
        P(:class => "text-lg text-warm-600 dark:text-warm-400 mb-8",
            "Strings are sequences of characters. Julia has a rich set of string operations, and WasmTarget.jl supports a subset of these that compile efficiently to WebAssembly."
        ),

        # WasmTarget.jl note
        Div(:class => "p-4 bg-amber-50 dark:bg-amber-900/20 rounded-xl border border-amber-200 dark:border-amber-800 mb-8",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-amber-600 dark:text-amber-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z")
                ),
                Div(
                    P(:class => "text-sm text-amber-800 dark:text-amber-200 font-medium", "WasmTarget.jl String Support"),
                    P(:class => "text-sm text-amber-700 dark:text-amber-300 mt-1",
                        "WasmTarget.jl supports basic string operations including literals, concatenation, length, and comparison. Character indexing and UTF-8 string manipulation are not yet supported. Strings are immutable - you cannot modify individual characters."
                    )
                )
            )
        ),

        # Section: String Literals
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "String Literals"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Strings are created using double quotes. Julia strings are sequences of Unicode characters."
        ),

        # Code example for literals
        Div(:class => "my-6 p-4 bg-warm-800 dark:bg-warm-900 rounded-lg",
            Pre(:class => "text-sm text-warm-100 font-mono",
                Code(:class => "language-julia", """# String literals use double quotes
greeting = "Hello, World!"
name = "Julia"
empty = ""  # Empty string

# Strings can contain Unicode
emoji = "👋"  # (Note: limited WASM support)""")
            )
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "Use single quotes for individual characters (",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "Char"),
            "), not strings:"
        ),

        Div(:class => "my-6 p-4 bg-warm-800 dark:bg-warm-900 rounded-lg",
            Pre(:class => "text-sm text-warm-100 font-mono",
                Code(:class => "language-julia", """# Char vs String
c = 'A'      # Char - single character
s = "A"      # String - contains one character
typeof(c)    # Char
typeof(s)    # String""")
            )
        ),

        # Section: String Length
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "String Length"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "The ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "length()"),
            " function returns the number of characters in a string."
        ),

        LiveExample(
            code = """# String length
s1 = "Hello"
length(s1)  # 5

s2 = "Hello, World"
length(s2)  # 12

empty = ""
length(empty)  # 0""",
            description = "Click different strings to see their lengths. Note that length counts characters, not bytes.",
            example = StringLengthDemo
        ),

        # Important note about length
        Div(:class => "p-4 bg-warm-50 dark:bg-warm-900/20 rounded-xl border border-warm-200 dark:border-warm-700 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-accent-600 dark:text-accent-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                ),
                Div(
                    P(:class => "text-sm text-warm-800 dark:text-warm-300 font-medium", "Tip"),
                    P(:class => "text-sm text-warm-700 dark:text-warm-400 mt-1",
                        "In full Julia, ",
                        Code(:class => "text-accent-600 dark:text-accent-400", "length()"),
                        " returns the number of Unicode characters, while ",
                        Code(:class => "text-accent-600 dark:text-accent-400", "sizeof()"),
                        " returns the number of bytes. For ASCII strings, these are equal."
                    )
                )
            )
        ),

        # Section: String Concatenation
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "String Concatenation"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Strings can be joined together using the ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "*"),
            " operator or the ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "string()"),
            " function."
        ),

        # Concatenation operators table
        Div(:class => "my-6 overflow-x-auto",
            Table(:class => "w-full text-sm border-collapse",
                Thead(:class => "bg-warm-100 dark:bg-warm-800",
                    Tr(
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Method"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Example"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Result")
                    )
                ),
                Tbody(
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "*"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "\"Hello\" * \" World\""),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "\"Hello World\"")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "string()"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "string(\"Hi\", \" \", \"there\")"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "\"Hi there\"")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "^"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "\"ha\" ^ 3"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "\"hahaha\"")
                    )
                )
            )
        ),

        LiveExample(
            code = """# String concatenation
a = "Hello"
b = "World"

# Using * operator
c = a * ", " * b * "!"  # "Hello, World!"

# Using string() function
d = string(a, " ", b)   # "Hello World"

# Repeat with ^
e = "ha" ^ 3            # "hahaha" """,
            description = "Click different words to see string concatenation in action.",
            example = StringConcatDemo
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "Note: Julia uses ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "*"),
            " for string concatenation (not ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "+"),
            "). This follows the mathematical convention where * is a non-commutative operator (order matters)."
        ),

        # Section: String Comparison
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "String Comparison"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Strings can be compared using the standard comparison operators. Comparison is lexicographic (dictionary order)."
        ),

        # Comparison operators table
        Div(:class => "my-6 overflow-x-auto",
            Table(:class => "w-full text-sm border-collapse",
                Thead(:class => "bg-warm-100 dark:bg-warm-800",
                    Tr(
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Operator"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Description"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Example")
                    )
                ),
                Tbody(
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "=="),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "Equal"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "\"abc\" == \"abc\"  # true")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "!="),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "Not equal"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "\"abc\" != \"xyz\"  # true")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "<"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "Less than (lexicographic)"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "\"apple\" < \"banana\"  # true")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", ">"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "Greater than (lexicographic)"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "\"cherry\" > \"banana\"  # true")
                    )
                )
            )
        ),

        LiveExample(
            code = """# String comparison
a = "apple"
b = "banana"
c = "cherry"

# Equality
a == b     # false
a == a     # true

# Lexicographic ordering
a < b      # true ("apple" comes before "banana")
b < c      # true ("banana" comes before "cherry")
c > a      # true ("cherry" comes after "apple")""",
            description = "Select different strings for a and b to see comparison results. Strings compare in dictionary order.",
            example = StringComparisonDemo
        ),

        # Note about lexicographic comparison
        Div(:class => "p-4 bg-warm-50 dark:bg-warm-900/20 rounded-xl border border-warm-200 dark:border-warm-700 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-accent-600 dark:text-accent-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                ),
                Div(
                    P(:class => "text-sm text-warm-800 dark:text-warm-300 font-medium", "Lexicographic Comparison"),
                    P(:class => "text-sm text-warm-700 dark:text-warm-400 mt-1",
                        "Strings are compared character by character from left to right. ",
                        Code(:class => "text-accent-600 dark:text-accent-400", "\"apple\" < \"banana\""),
                        " because 'a' < 'b'. If one string is a prefix of another, the shorter one is \"less than\": ",
                        Code(:class => "text-accent-600 dark:text-accent-400", "\"app\" < \"apple\""),
                        "."
                    )
                )
            )
        ),

        # Section: String Interpolation (not supported note)
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "String Interpolation"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "In standard Julia, string interpolation with ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "\$"),
            " is a powerful feature:"
        ),

        Div(:class => "my-6 p-4 bg-warm-800 dark:bg-warm-900 rounded-lg",
            Pre(:class => "text-sm text-warm-100 font-mono",
                Code(:class => "language-julia", """# Standard Julia string interpolation
name = "Julia"
age = 30
greeting = "Hello, \$name! You are \$age years old."
# Result: "Hello, Julia! You are 30 years old." """)
            )
        ),

        # Not supported warning
        Div(:class => "p-4 bg-amber-50 dark:bg-amber-900/20 rounded-xl border border-amber-200 dark:border-amber-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-amber-600 dark:text-amber-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z")
                ),
                Div(
                    P(:class => "text-sm text-amber-800 dark:text-amber-200 font-medium", "Not Yet Supported in WasmTarget.jl"),
                    P(:class => "text-sm text-amber-700 dark:text-amber-300 mt-1",
                        "String interpolation is not yet supported in WasmTarget.jl. Use ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "string()"),
                        " or ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "*"),
                        " for concatenation instead."
                    )
                )
            )
        ),

        # Summary
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Summary"
        ),

        Ul(:class => "list-disc list-inside space-y-2 text-warm-600 dark:text-warm-400 mb-6",
            Li("Create strings with double quotes: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "\"Hello\"")),
            Li("Get length with ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "length(s)")),
            Li("Concatenate with ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "*"), " or ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "string()")),
            Li("Compare with ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "=="), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "<"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", ">"), " (lexicographic)"),
            Li("Strings are immutable - you cannot modify individual characters")
        ),

        # Next steps
        Div(:class => "p-6 bg-gradient-to-r from-warm-50 to-warm-100 dark:from-warm-900 dark:to-warm-950 rounded-xl border border-warm-200 dark:border-warm-700",
            H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-100 mb-2",
                "Next Steps"
            ),
            P(:class => "text-warm-600 dark:text-warm-400",
                "Continue to ",
                A(:href => "../functions/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Functions"),
                " to learn about defining and calling functions, or go back to ",
                A(:href => "../math-operations/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Math Operations"),
                " to review mathematical operators."
            )
        )
    )
end

# Export
Strings
