# Manual Chapter: Tuples
#
# Manual page covering Julia tuples - creation, indexing,
# destructuring, and using tuples for multiple return values.
# Based on docs.julialang.org/en/v1/manual/functions/#Tuples
# Interactive demos have been removed and replaced with static code examples.
#
# Route: /manual/tuples

import Suite

# =============================================================================
# Tuples Chapter Page
# =============================================================================

"""
Tuples chapter for the Julia Manual.
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

        Suite.CodeBlock("""# Create a tuple with parentheses
t = (42, 3.14, 100)

# Access elements by index (1-based)
t[1]   # returns 42
t[2]   # returns 3.14
t[3]   # returns 100

# Get the length
length(t)  # returns 3

# Tuples are immutable - this would error:
# t[1] = 99  # ERROR!""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Click on index buttons to access different tuple elements."
        ),

        # Tip about immutability
        Suite.Alert(class="my-6",
            Suite.AlertTitle("Immutability"),
            Suite.AlertDescription(
                "Tuples are immutable — once created, you cannot change their elements. ",
                "This makes tuples safe to share and efficient to use. If you need a mutable collection, use an array instead."
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

        Suite.CodeBlock("""# Function returning multiple values
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
end""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Adjust a and b to see how the function returns both sum and difference as a tuple."
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "Destructuring assignment (also called \"unpacking\") lets you extract tuple elements directly into separate variables. ",
            "This is more readable than accessing elements by index."
        ),

        # Code example for destructuring
        Suite.CodeBlock("""# Destructuring examples
t = (1, 2, 3)

# Extract all elements
a, b, c = t
# a = 1, b = 2, c = 3

# Swap variables using tuples
x, y = 10, 20
x, y = y, x  # Now x = 20, y = 10

# Ignore elements with underscore
first, _, third = (10, 20, 30)
# first = 10, third = 30""", language="julia"),

        # Section: Mixed Types
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Mixed-Type Tuples"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Unlike arrays (which typically hold elements of the same type), tuples can hold values of different types. ",
            "Julia's type system tracks the type of each element individually."
        ),

        Suite.CodeBlock("""# Tuple with mixed types
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
end""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Tuples preserve the type of each element. Toggle the boolean and adjust the integer to see different values."
        ),

        # WasmTarget note about tuples
        Suite.Alert(class="my-6",
            Suite.AlertTitle("Tuples in WasmTarget.jl"),
            Suite.AlertDescription(
                "WasmTarget.jl compiles tuples as WasmGC struct types, with each field corresponding to a tuple element. ",
                "This provides efficient, type-safe tuple operations in WebAssembly."
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
        Suite.Table(
            Suite.TableHeader(Suite.TableRow(
                Suite.TableHead("Feature"),
                Suite.TableHead("Tuple"),
                Suite.TableHead("Array")
            )),
            Suite.TableBody(
                Suite.TableRow(
                    Suite.TableCell(:class => "font-medium", "Size"),
                    Suite.TableCell("Fixed at creation"),
                    Suite.TableCell("Can grow/shrink")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-medium", "Element types"),
                    Suite.TableCell("Can be different"),
                    Suite.TableCell("Usually same type")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-medium", "Mutability"),
                    Suite.TableCell("Immutable"),
                    Suite.TableCell("Mutable")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-medium", "Syntax"),
                    Suite.TableCell(Code(:class => "text-accent-600 dark:text-accent-400", "(a, b, c)")),
                    Suite.TableCell(Code(:class => "text-accent-600 dark:text-accent-400", "[a, b, c]"))
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-medium", "Use case"),
                    Suite.TableCell("Multiple return values, records"),
                    Suite.TableCell("Collections, lists")
                )
            )
        ),

        # Summary
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Summary"
        ),

        Ul(:class => "list-disc list-inside space-y-2 text-warm-600 dark:text-warm-400 mb-6",
            Li("Create tuples with parentheses: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "(a, b, c)")),
            Li("Access elements with 1-based indexing: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "t[1]"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "t[2]")),
            Li("Tuples are immutable — elements cannot be changed after creation"),
            Li("Use tuples to return multiple values from functions"),
            Li("Destructure with ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "a, b = tuple")),
            Li("Tuples can hold different types: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "(42, 3.14, true)"))
        ),

        # Scope note
        Suite.Alert(class="my-6",
            Suite.AlertTitle("Named Tuples"),
            Suite.AlertDescription(
                "Julia also supports ",
                Em("named tuples"),
                " like ",
                Code(:class => "text-accent-600 dark:text-accent-400", "(x=1, y=2)"),
                ", which allow accessing elements by name. Named tuples have limited support in WasmTarget.jl."
            )
        ),

        # Next steps
        Div(:class => "p-6 bg-gradient-to-r from-warm-50 to-warm-100 dark:from-warm-900 dark:to-warm-950 rounded-xl border border-warm-200 dark:border-warm-700",
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
