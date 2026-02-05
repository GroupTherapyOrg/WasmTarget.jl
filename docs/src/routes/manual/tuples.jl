# Manual Chapter: Tuples
#
# Interactive manual page covering Julia tuples - creation, indexing,
# destructuring, and using tuples for multiple return values.
# Based on docs.julialang.org/en/v1/manual/functions/#Tuples
#
# Route: /manual/tuples

# =============================================================================
# NOTE: This file uses pre-built islands from LiveExample.jl
# TupleDemo, FunctionReturnTupleDemo, and MixedTypeTupleDemo are defined there.
# =============================================================================

# =============================================================================
# Tuples Chapter Page
# =============================================================================

"""
Tuples chapter for the Interactive Julia Manual.
"""
function Tuples()
    ManualLayout(chapter_id="tuples", chapter_title="Tuples",
        # Title
        H1(:class => "text-3xl font-bold text-warm-800 dark:text-warm-100 mb-4",
            "Tuples"
        ),

        # Introduction
        P(:class => "text-lg text-warm-600 dark:text-warm-400 mb-8",
            "A ",
            Em("tuple"),
            " is an ordered, immutable collection of values. Unlike arrays, tuples can contain elements of different types and have a fixed size. ",
            "Tuples are commonly used to return multiple values from functions."
        ),

        # Section: Creating Tuples
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Creating Tuples"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Create a tuple by enclosing values in parentheses, separated by commas. ",
            "Access elements using square bracket indexing, just like arrays. ",
            "Remember: Julia uses 1-based indexing, so the first element is at index 1."
        ),

        LiveExample(
            code = """# Create a tuple with parentheses
t = (42, 3.14, 100)

# Access elements by index (1-based)
t[1]   # returns 42
t[2]   # returns 3.14
t[3]   # returns 100

# Get the length
length(t)  # returns 3

# Tuples are immutable - this would error:
# t[1] = 99  # ERROR!""",
            description = "Click on index buttons to access different tuple elements.",
            example = TupleDemo
        ),

        # Tip about immutability
        Div(:class => "p-4 bg-accent-50 dark:bg-accent-900/20 rounded-xl border border-accent-200 dark:border-accent-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-accent-600 dark:text-accent-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                ),
                Div(
                    P(:class => "text-sm text-accent-800 dark:text-accent-200 font-medium", "Immutability"),
                    P(:class => "text-sm text-accent-700 dark:text-accent-300 mt-1",
                        "Tuples are immutable \u2014 once created, you cannot change their elements. ",
                        "This makes tuples safe to share and efficient to use. If you need a mutable collection, use an array instead."
                    )
                )
            )
        ),

        # Section: Multiple Return Values
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Multiple Return Values"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "One of the most common uses for tuples is returning multiple values from a function. ",
            "Julia makes this natural: just return values separated by commas, and they're automatically wrapped in a tuple."
        ),

        LiveExample(
            code = """# Function returning multiple values
function sum_and_diff(a, b)
    return (a + b, a - b)
end

# Call the function
result = sum_and_diff(10, 3)
result[1]  # sum: 13
result[2]  # diff: 7

# Destructuring assignment
sum, diff = sum_and_diff(10, 3)
# sum is 13, diff is 7

# Parentheses are optional in return
function minmax(a, b)
    return a < b ? (a, b) : (b, a)
end""",
            description = "Adjust a and b to see how the function returns both sum and difference as a tuple.",
            example = FunctionReturnTupleDemo
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "Destructuring assignment (also called \"unpacking\") lets you extract tuple elements directly into separate variables. ",
            "This is more readable than accessing elements by index."
        ),

        # Code example for destructuring
        Pre(:class => "bg-warm-800 dark:bg-warm-900 p-4 rounded-lg overflow-x-auto text-sm my-4",
            Code(:class => "language-julia text-warm-100 font-mono",
"""# Destructuring examples
t = (1, 2, 3)

# Extract all elements
a, b, c = t
# a = 1, b = 2, c = 3

# Swap variables using tuples
x, y = 10, 20
x, y = y, x  # Now x = 20, y = 10

# Ignore elements with underscore
first, _, third = (10, 20, 30)
# first = 10, third = 30"""
            )
        ),

        # Section: Mixed Types
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Mixed-Type Tuples"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Unlike arrays (which typically hold elements of the same type), tuples can hold values of different types. ",
            "Julia's type system tracks the type of each element individually."
        ),

        LiveExample(
            code = """# Tuple with mixed types
mixed = (42, 3.14, true)

# Julia infers the type
typeof(mixed)  # Tuple{Int64, Float64, Bool}

# Each element has its own type
typeof(mixed[1])  # Int64
typeof(mixed[2])  # Float64
typeof(mixed[3])  # Bool

# Common pattern: returning value with status
function safe_divide(a, b)
    if b == 0
        return (0, false)  # (result, success)
    end
    return (a / b, true)
end""",
            description = "Tuples preserve the type of each element. Toggle the boolean and adjust the integer to see different values.",
            example = MixedTypeTupleDemo
        ),

        # WasmTarget note about tuples
        Div(:class => "p-4 bg-amber-50 dark:bg-amber-900/20 rounded-xl border border-amber-200 dark:border-amber-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-amber-600 dark:text-amber-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z")
                ),
                Div(
                    P(:class => "text-sm text-amber-800 dark:text-amber-200 font-medium", "Tuples in WasmTarget.jl"),
                    P(:class => "text-sm text-amber-700 dark:text-amber-300 mt-1",
                        "WasmTarget.jl compiles tuples as WasmGC struct types, with each field corresponding to a tuple element. ",
                        "This provides efficient, type-safe tuple operations in WebAssembly."
                    )
                )
            )
        ),

        # Section: Tuples vs Arrays
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Tuples vs Arrays"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Choose tuples when you have a fixed number of related values, possibly of different types. ",
            "Choose arrays when you have a variable-length collection of same-type elements."
        ),

        # Comparison table
        Div(:class => "overflow-x-auto my-6",
            Table(:class => "w-full text-sm text-left",
                Thead(:class => "text-xs text-warm-700 dark:text-warm-300 uppercase bg-warm-100 dark:bg-warm-800",
                    Tr(
                        Th(:class => "px-4 py-3", "Feature"),
                        Th(:class => "px-4 py-3", "Tuple"),
                        Th(:class => "px-4 py-3", "Array")
                    )
                ),
                Tbody(
                    Tr(:class => "border-b border-warm-200 dark:border-warm-700",
                        Td(:class => "px-4 py-3 font-medium", "Size"),
                        Td(:class => "px-4 py-3", "Fixed at creation"),
                        Td(:class => "px-4 py-3", "Can grow/shrink")
                    ),
                    Tr(:class => "border-b border-warm-200 dark:border-warm-700",
                        Td(:class => "px-4 py-3 font-medium", "Element types"),
                        Td(:class => "px-4 py-3", "Can be different"),
                        Td(:class => "px-4 py-3", "Usually same type")
                    ),
                    Tr(:class => "border-b border-warm-200 dark:border-warm-700",
                        Td(:class => "px-4 py-3 font-medium", "Mutability"),
                        Td(:class => "px-4 py-3", "Immutable"),
                        Td(:class => "px-4 py-3", "Mutable")
                    ),
                    Tr(:class => "border-b border-warm-200 dark:border-warm-700",
                        Td(:class => "px-4 py-3 font-medium", "Syntax"),
                        Td(:class => "px-4 py-3", Code(:class => "text-accent-600", "(a, b, c)")),
                        Td(:class => "px-4 py-3", Code(:class => "text-accent-600", "[a, b, c]"))
                    ),
                    Tr(
                        Td(:class => "px-4 py-3 font-medium", "Use case"),
                        Td(:class => "px-4 py-3", "Multiple return values, records"),
                        Td(:class => "px-4 py-3", "Collections, lists")
                    )
                )
            )
        ),

        # Summary
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Summary"
        ),

        Ul(:class => "list-disc list-inside space-y-2 text-warm-600 dark:text-warm-400 mb-6",
            Li("Create tuples with parentheses: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "(a, b, c)")),
            Li("Access elements with 1-based indexing: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "t[1]"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "t[2]")),
            Li("Tuples are immutable \u2014 elements cannot be changed after creation"),
            Li("Use tuples to return multiple values from functions"),
            Li("Destructure with ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "a, b = tuple")),
            Li("Tuples can hold different types: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "(42, 3.14, true)"))
        ),

        # Scope note
        Div(:class => "p-4 bg-warm-100 dark:bg-warm-800 rounded-xl border border-warm-200 dark:border-warm-700 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-warm-500 dark:text-warm-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z")
                ),
                Div(
                    P(:class => "text-sm text-warm-700 dark:text-warm-300 font-medium", "Named Tuples"),
                    P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-1",
                        "Julia also supports ",
                        Em("named tuples"),
                        " like ",
                        Code(:class => "text-warm-600 dark:text-warm-400", "(x=1, y=2)"),
                        ", which allow accessing elements by name. Named tuples have limited support in WasmTarget.jl."
                    )
                )
            )
        ),

        # Next steps
        Div(:class => "p-6 bg-gradient-to-r from-accent-50 to-accent-50 dark:from-accent-900/20 dark:to-accent-900/20 rounded-xl border border-accent-200 dark:border-accent-800",
            H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-100 mb-2",
                "Next Steps"
            ),
            P(:class => "text-warm-600 dark:text-warm-400",
                "Now that you understand tuples, explore ",
                A(:href => "../functions/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Functions"),
                " to see more ways to use multiple return values, or check out ",
                A(:href => "../types/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Types (Structs)"),
                " for when you need named fields instead of indexed positions."
            )
        )
    )
end

# Export
Tuples
