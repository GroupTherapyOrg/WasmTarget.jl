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
        H1(:class => "text-3xl font-bold text-stone-800 dark:text-stone-100 mb-4",
            "Strings"
        ),

        # Introduction
        P(:class => "text-lg text-stone-600 dark:text-stone-400 mb-8",
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
        H2(:class => "text-2xl font-semibold text-stone-800 dark:text-stone-100 mt-10 mb-4",
            "String Literals"
        ),

        P(:class => "text-stone-600 dark:text-stone-400 mb-4",
            "Strings are created using double quotes. Julia strings are sequences of Unicode characters."
        ),

        # Code example for literals
        Div(:class => "my-6 p-4 bg-stone-800 dark:bg-stone-900 rounded-lg",
            Pre(:class => "text-sm text-stone-100 font-mono",
                Code(:class => "language-julia", """# String literals use double quotes
greeting = "Hello, World!"
name = "Julia"
empty = ""  # Empty string

# Strings can contain Unicode
emoji = "👋"  # (Note: limited WASM support)""")
            )
        ),

        P(:class => "text-stone-600 dark:text-stone-400 my-4",
            "Use single quotes for individual characters (",
            Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "Char"),
            "), not strings:"
        ),

        Div(:class => "my-6 p-4 bg-stone-800 dark:bg-stone-900 rounded-lg",
            Pre(:class => "text-sm text-stone-100 font-mono",
                Code(:class => "language-julia", """# Char vs String
c = 'A'      # Char - single character
s = "A"      # String - contains one character
typeof(c)    # Char
typeof(s)    # String""")
            )
        ),

        # Section: String Length
        H2(:class => "text-2xl font-semibold text-stone-800 dark:text-stone-100 mt-10 mb-4",
            "String Length"
        ),

        P(:class => "text-stone-600 dark:text-stone-400 mb-4",
            "The ",
            Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "length()"),
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
        Div(:class => "p-4 bg-cyan-50 dark:bg-cyan-900/20 rounded-xl border border-cyan-200 dark:border-cyan-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-cyan-600 dark:text-cyan-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                ),
                Div(
                    P(:class => "text-sm text-cyan-800 dark:text-cyan-200 font-medium", "Tip"),
                    P(:class => "text-sm text-cyan-700 dark:text-cyan-300 mt-1",
                        "In full Julia, ",
                        Code(:class => "text-cyan-600 dark:text-cyan-400", "length()"),
                        " returns the number of Unicode characters, while ",
                        Code(:class => "text-cyan-600 dark:text-cyan-400", "sizeof()"),
                        " returns the number of bytes. For ASCII strings, these are equal."
                    )
                )
            )
        ),

        # Section: String Concatenation
        H2(:class => "text-2xl font-semibold text-stone-800 dark:text-stone-100 mt-10 mb-4",
            "String Concatenation"
        ),

        P(:class => "text-stone-600 dark:text-stone-400 mb-4",
            "Strings can be joined together using the ",
            Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "*"),
            " operator or the ",
            Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "string()"),
            " function."
        ),

        # Concatenation operators table
        Div(:class => "my-6 overflow-x-auto",
            Table(:class => "w-full text-sm border-collapse",
                Thead(:class => "bg-stone-100 dark:bg-stone-800",
                    Tr(
                        Th(:class => "text-left px-4 py-2 border border-stone-200 dark:border-stone-700 font-medium text-stone-700 dark:text-stone-300", "Method"),
                        Th(:class => "text-left px-4 py-2 border border-stone-200 dark:border-stone-700 font-medium text-stone-700 dark:text-stone-300", "Example"),
                        Th(:class => "text-left px-4 py-2 border border-stone-200 dark:border-stone-700 font-medium text-stone-700 dark:text-stone-300", "Result")
                    )
                ),
                Tbody(
                    Tr(
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 font-mono text-cyan-600 dark:text-cyan-400", "*"),
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 text-stone-600 dark:text-stone-400 font-mono", "\"Hello\" * \" World\""),
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 text-stone-600 dark:text-stone-400 font-mono", "\"Hello World\"")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 font-mono text-cyan-600 dark:text-cyan-400", "string()"),
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 text-stone-600 dark:text-stone-400 font-mono", "string(\"Hi\", \" \", \"there\")"),
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 text-stone-600 dark:text-stone-400 font-mono", "\"Hi there\"")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 font-mono text-cyan-600 dark:text-cyan-400", "^"),
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 text-stone-600 dark:text-stone-400 font-mono", "\"ha\" ^ 3"),
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 text-stone-600 dark:text-stone-400 font-mono", "\"hahaha\"")
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

        P(:class => "text-stone-600 dark:text-stone-400 my-4",
            "Note: Julia uses ",
            Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "*"),
            " for string concatenation (not ",
            Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "+"),
            "). This follows the mathematical convention where * is a non-commutative operator (order matters)."
        ),

        # Section: String Comparison
        H2(:class => "text-2xl font-semibold text-stone-800 dark:text-stone-100 mt-10 mb-4",
            "String Comparison"
        ),

        P(:class => "text-stone-600 dark:text-stone-400 mb-4",
            "Strings can be compared using the standard comparison operators. Comparison is lexicographic (dictionary order)."
        ),

        # Comparison operators table
        Div(:class => "my-6 overflow-x-auto",
            Table(:class => "w-full text-sm border-collapse",
                Thead(:class => "bg-stone-100 dark:bg-stone-800",
                    Tr(
                        Th(:class => "text-left px-4 py-2 border border-stone-200 dark:border-stone-700 font-medium text-stone-700 dark:text-stone-300", "Operator"),
                        Th(:class => "text-left px-4 py-2 border border-stone-200 dark:border-stone-700 font-medium text-stone-700 dark:text-stone-300", "Description"),
                        Th(:class => "text-left px-4 py-2 border border-stone-200 dark:border-stone-700 font-medium text-stone-700 dark:text-stone-300", "Example")
                    )
                ),
                Tbody(
                    Tr(
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 font-mono text-cyan-600 dark:text-cyan-400", "=="),
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 text-stone-600 dark:text-stone-400", "Equal"),
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 text-stone-600 dark:text-stone-400 font-mono", "\"abc\" == \"abc\"  # true")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 font-mono text-cyan-600 dark:text-cyan-400", "!="),
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 text-stone-600 dark:text-stone-400", "Not equal"),
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 text-stone-600 dark:text-stone-400 font-mono", "\"abc\" != \"xyz\"  # true")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 font-mono text-cyan-600 dark:text-cyan-400", "<"),
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 text-stone-600 dark:text-stone-400", "Less than (lexicographic)"),
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 text-stone-600 dark:text-stone-400 font-mono", "\"apple\" < \"banana\"  # true")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 font-mono text-cyan-600 dark:text-cyan-400", ">"),
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 text-stone-600 dark:text-stone-400", "Greater than (lexicographic)"),
                        Td(:class => "px-4 py-2 border border-stone-200 dark:border-stone-700 text-stone-600 dark:text-stone-400 font-mono", "\"cherry\" > \"banana\"  # true")
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
        Div(:class => "p-4 bg-cyan-50 dark:bg-cyan-900/20 rounded-xl border border-cyan-200 dark:border-cyan-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-cyan-600 dark:text-cyan-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                ),
                Div(
                    P(:class => "text-sm text-cyan-800 dark:text-cyan-200 font-medium", "Lexicographic Comparison"),
                    P(:class => "text-sm text-cyan-700 dark:text-cyan-300 mt-1",
                        "Strings are compared character by character from left to right. ",
                        Code(:class => "text-cyan-600 dark:text-cyan-400", "\"apple\" < \"banana\""),
                        " because 'a' < 'b'. If one string is a prefix of another, the shorter one is \"less than\": ",
                        Code(:class => "text-cyan-600 dark:text-cyan-400", "\"app\" < \"apple\""),
                        "."
                    )
                )
            )
        ),

        # Section: String Interpolation (not supported note)
        H2(:class => "text-2xl font-semibold text-stone-800 dark:text-stone-100 mt-10 mb-4",
            "String Interpolation"
        ),

        P(:class => "text-stone-600 dark:text-stone-400 mb-4",
            "In standard Julia, string interpolation with ",
            Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "\$"),
            " is a powerful feature:"
        ),

        Div(:class => "my-6 p-4 bg-stone-800 dark:bg-stone-900 rounded-lg",
            Pre(:class => "text-sm text-stone-100 font-mono",
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
        H2(:class => "text-2xl font-semibold text-stone-800 dark:text-stone-100 mt-10 mb-4",
            "Summary"
        ),

        Ul(:class => "list-disc list-inside space-y-2 text-stone-600 dark:text-stone-400 mb-6",
            Li("Create strings with double quotes: ", Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "\"Hello\"")),
            Li("Get length with ", Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "length(s)")),
            Li("Concatenate with ", Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "*"), " or ", Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "string()")),
            Li("Compare with ", Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "=="), ", ", Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "<"), ", ", Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", ">"), " (lexicographic)"),
            Li("Strings are immutable - you cannot modify individual characters")
        ),

        # Next steps
        Div(:class => "p-6 bg-gradient-to-r from-cyan-50 to-teal-50 dark:from-cyan-900/20 dark:to-teal-900/20 rounded-xl border border-cyan-200 dark:border-cyan-800",
            H3(:class => "text-lg font-semibold text-stone-800 dark:text-stone-100 mb-2",
                "Next Steps"
            ),
            P(:class => "text-stone-600 dark:text-stone-400",
                "Continue to ",
                A(:href => "../functions/",
                  :class => "text-cyan-600 dark:text-cyan-400 font-medium hover:underline",
                  "Functions"),
                " to learn about defining and calling functions, or go back to ",
                A(:href => "../math-operations/",
                  :class => "text-cyan-600 dark:text-cyan-400 font-medium hover:underline",
                  "Math Operations"),
                " to review mathematical operators."
            )
        )
    )
end

# Export
Strings
