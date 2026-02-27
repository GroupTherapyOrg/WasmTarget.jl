# Manual Chapter: Strings
#
# Manual page covering string basics - literals, concatenation,
# length, and comparison. Scoped to WasmTarget.jl string support.
# Interactive demos have been removed and replaced with static code examples.
#
# Route: /manual/strings

import Suite

# =============================================================================
# Strings Chapter Page
# =============================================================================

"""
Strings chapter for the Julia Manual.
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
        Suite.Alert(class="mb-8",
            Suite.AlertTitle("WasmTarget.jl String Support"),
            Suite.AlertDescription(
                "WasmTarget.jl supports basic string operations including literals, concatenation, length, and comparison. Character indexing and UTF-8 string manipulation are not yet supported. Strings are immutable - you cannot modify individual characters."
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
        Suite.CodeBlock("""# String literals use double quotes
greeting = "Hello, World!"
name = "Julia"
empty = ""  # Empty string

# Strings can contain Unicode
emoji = "👋"  # (Note: limited WASM support)""", language="julia"),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "Use single quotes for individual characters (",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Char"),
            "), not strings:"
        ),

        Suite.CodeBlock("""# Char vs String
c = 'A'      # Char - single character
s = "A"      # String - contains one character
typeof(c)    # Char
typeof(s)    # String""", language="julia"),

        # Section: String Length
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "String Length"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "The ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "length()"),
            " function returns the number of characters in a string."
        ),

        Suite.CodeBlock("""# String length
s1 = "Hello"
length(s1)  # 5

s2 = "Hello, World"
length(s2)  # 12

empty = ""
length(empty)  # 0""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Click different strings to see their lengths. Note that length counts characters, not bytes."
        ),

        # Important note about length
        Suite.Alert(class="my-6",
            Suite.AlertTitle("Tip"),
            Suite.AlertDescription(
                "In full Julia, ",
                Code(:class => "text-accent-600 dark:text-accent-400", "length()"),
                " returns the number of Unicode characters, while ",
                Code(:class => "text-accent-600 dark:text-accent-400", "sizeof()"),
                " returns the number of bytes. For ASCII strings, these are equal."
            )
        ),

        # Section: String Concatenation
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "String Concatenation"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Strings can be joined together using the ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "*"),
            " operator or the ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "string()"),
            " function."
        ),

        # Concatenation operators table
        Suite.Table(
            Suite.TableHeader(Suite.TableRow(
                Suite.TableHead("Method"),
                Suite.TableHead("Example"),
                Suite.TableHead("Result")
            )),
            Suite.TableBody(
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "*"),
                    Suite.TableCell(:class => "font-mono", "\"Hello\" * \" World\""),
                    Suite.TableCell(:class => "font-mono", "\"Hello World\"")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "string()"),
                    Suite.TableCell(:class => "font-mono", "string(\"Hi\", \" \", \"there\")"),
                    Suite.TableCell(:class => "font-mono", "\"Hi there\"")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "^"),
                    Suite.TableCell(:class => "font-mono", "\"ha\" ^ 3"),
                    Suite.TableCell(:class => "font-mono", "\"hahaha\"")
                )
            )
        ),

        Suite.CodeBlock("""# String concatenation
a = "Hello"
b = "World"

# Using * operator
c = a * ", " * b * "!"  # "Hello, World!"

# Using string() function
d = string(a, " ", b)   # "Hello World"

# Repeat with ^
e = "ha" ^ 3            # "hahaha" """, language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Click different words to see string concatenation in action."
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "Note: Julia uses ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "*"),
            " for string concatenation (not ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "+"),
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
        Suite.Table(
            Suite.TableHeader(Suite.TableRow(
                Suite.TableHead("Operator"),
                Suite.TableHead("Description"),
                Suite.TableHead("Example")
            )),
            Suite.TableBody(
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "=="),
                    Suite.TableCell("Equal"),
                    Suite.TableCell(:class => "font-mono", "\"abc\" == \"abc\"  # true")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "!="),
                    Suite.TableCell("Not equal"),
                    Suite.TableCell(:class => "font-mono", "\"abc\" != \"xyz\"  # true")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "<"),
                    Suite.TableCell("Less than (lexicographic)"),
                    Suite.TableCell(:class => "font-mono", "\"apple\" < \"banana\"  # true")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", ">"),
                    Suite.TableCell("Greater than (lexicographic)"),
                    Suite.TableCell(:class => "font-mono", "\"cherry\" > \"banana\"  # true")
                )
            )
        ),

        Suite.CodeBlock("""# String comparison
a = "apple"
b = "banana"
c = "cherry"

# Equality
a == b     # false
a == a     # true

# Lexicographic ordering
a < b      # true ("apple" comes before "banana")
b < c      # true ("banana" comes before "cherry")
c > a      # true ("cherry" comes after "apple")""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Select different strings for a and b to see comparison results. Strings compare in dictionary order."
        ),

        # Note about lexicographic comparison
        Suite.Alert(class="my-6",
            Suite.AlertTitle("Lexicographic Comparison"),
            Suite.AlertDescription(
                "Strings are compared character by character from left to right. ",
                Code(:class => "text-accent-600 dark:text-accent-400", "\"apple\" < \"banana\""),
                " because 'a' < 'b'. If one string is a prefix of another, the shorter one is \"less than\": ",
                Code(:class => "text-accent-600 dark:text-accent-400", "\"app\" < \"apple\""),
                "."
            )
        ),

        # Section: String Interpolation (not supported note)
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "String Interpolation"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "In standard Julia, string interpolation with ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "\$"),
            " is a powerful feature:"
        ),

        Suite.CodeBlock("""# Standard Julia string interpolation
name = "Julia"
age = 30
greeting = "Hello, \$name! You are \$age years old."
# Result: "Hello, Julia! You are 30 years old." """, language="julia"),

        # Not supported warning
        Suite.Alert(class="my-6",
            Suite.AlertTitle("Not Yet Supported in WasmTarget.jl"),
            Suite.AlertDescription(
                "String interpolation is not yet supported in WasmTarget.jl. Use ",
                Code(:class => "text-accent-600 dark:text-accent-400", "string()"),
                " or ",
                Code(:class => "text-accent-600 dark:text-accent-400", "*"),
                " for concatenation instead."
            )
        ),

        # Summary
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Summary"
        ),

        Ul(:class => "list-disc list-inside space-y-2 text-warm-600 dark:text-warm-400 mb-6",
            Li("Create strings with double quotes: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "\"Hello\"")),
            Li("Get length with ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "length(s)")),
            Li("Concatenate with ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "*"), " or ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "string()")),
            Li("Compare with ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "=="), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "<"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", ">"), " (lexicographic)"),
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
