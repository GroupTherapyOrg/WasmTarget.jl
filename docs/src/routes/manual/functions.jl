# Manual Chapter: Functions
#
# Interactive manual page covering Julia functions - definition, calling,
# return values, recursion, and closures.
# Based on docs.julialang.org/en/v1/manual/functions/
#
# Route: /manual/functions

# =============================================================================
# NOTE: This file uses pre-built islands from LiveExample.jl
# SquareDemo, MultiArgDemo, ReturnValueDemo, ClosureDemo, CompactFunctionDemo,
# and FactorialDemo are already defined there and work correctly with SSR.
# =============================================================================

# =============================================================================
# Functions Chapter Page
# =============================================================================

"""
Functions chapter for the Interactive Julia Manual.
"""
function Functions()
    ManualLayout(chapter_id="functions", chapter_title="Functions",
        # Title
        H1(:class => "text-3xl font-bold text-stone-800 dark:text-stone-100 mb-4",
            "Functions"
        ),

        # Introduction
        P(:class => "text-lg text-stone-600 dark:text-stone-400 mb-8",
            "Functions are the fundamental building blocks of Julia programs. They take inputs (arguments), perform computations, and return outputs. Julia provides multiple ways to define functions, from compact one-liners to multi-line blocks with explicit returns."
        ),

        # Section: Function Definition
        H2(:class => "text-2xl font-semibold text-stone-800 dark:text-stone-100 mt-10 mb-4",
            "Defining Functions"
        ),

        P(:class => "text-stone-600 dark:text-stone-400 mb-4",
            "The basic syntax for defining a function uses the ",
            Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "function"),
            " keyword, followed by the function name, arguments in parentheses, and the function body. The function ends with ",
            Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "end"),
            "."
        ),

        LiveExample(
            code = """# Standard function definition
function square(x)
    return x * x
end

# Call the function
result = square(5)  # result = 25

# Functions can have type annotations
function square_int(x::Int32)::Int32
    return x * x
end""",
            description = "A basic function that squares its input. Adjust the value of x to see the result change.",
            example = SquareDemo
        ),

        P(:class => "text-stone-600 dark:text-stone-400 my-4",
            "Julia also supports a compact assignment form for simple functions. This is equivalent to the longer form but more concise:"
        ),

        LiveExample(
            code = """# Compact (assignment) form
add(a, b) = a + b
mul(a, b) = a * b

# These are equivalent to:
# function add(a, b)
#     return a + b
# end

result = add(7, 3)   # result = 10
product = mul(7, 3)  # product = 21""",
            description = "Compact function definitions using assignment syntax. Try different values for a and b.",
            example = CompactFunctionDemo
        ),

        # Section: Arguments
        H2(:class => "text-2xl font-semibold text-stone-800 dark:text-stone-100 mt-10 mb-4",
            "Function Arguments"
        ),

        P(:class => "text-stone-600 dark:text-stone-400 mb-4",
            "Functions can accept multiple arguments separated by commas. Each argument can optionally have a type annotation to specify what types are accepted."
        ),

        LiveExample(
            code = """# Function with multiple arguments
function hypot(x::Int32, y::Int32)::Int32
    # Calculate integer approximation of sqrt(x^2 + y^2)
    sum_sq = x * x + y * y
    # Simple integer square root
    r = Int32(1)
    while r * r <= sum_sq
        r = r + Int32(1)
    end
    return r - Int32(1)
end

# Pythagorean triples work perfectly
hypot(3, 4)   # returns 5
hypot(5, 12)  # returns 13""",
            description = "A function taking two arguments. Try the preset Pythagorean triples or adjust x and y manually.",
            example = MultiArgDemo
        ),

        # Warning about varargs/kwargs
        Div(:class => "p-4 bg-amber-50 dark:bg-amber-900/20 rounded-xl border border-amber-200 dark:border-amber-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-amber-600 dark:text-amber-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z")
                ),
                Div(
                    P(:class => "text-sm text-amber-800 dark:text-amber-200 font-medium", "WasmTarget.jl Limitation"),
                    P(:class => "text-sm text-amber-700 dark:text-amber-300 mt-1",
                        "Variadic arguments (",
                        Code(:class => "text-amber-800 dark:text-amber-200", "args..."),
                        ") and keyword arguments (",
                        Code(:class => "text-amber-800 dark:text-amber-200", "foo(; kwarg=value)"),
                        ") are not yet supported in WasmTarget.jl. Use positional arguments with explicit types for best compatibility."
                    )
                )
            )
        ),

        # Section: Return Values
        H2(:class => "text-2xl font-semibold text-stone-800 dark:text-stone-100 mt-10 mb-4",
            "Return Values"
        ),

        P(:class => "text-stone-600 dark:text-stone-400 mb-4",
            "Functions return a value to the caller. You can use the explicit ",
            Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "return"),
            " keyword, or Julia will implicitly return the value of the last expression in the function body."
        ),

        LiveExample(
            code = """# Explicit return (useful for early exit)
function my_abs(x::Int32)::Int32
    if x < Int32(0)
        return -x  # Early return for negative
    end
    return x
end

# Implicit return (last expression)
function my_sign(x::Int32)::Int32
    if x > Int32(0)
        Int32(1)
    elseif x < Int32(0)
        Int32(-1)
    else
        Int32(0)
    end  # Last expression is returned
end""",
            description = "Two functions showing explicit vs implicit return. Adjust the value to see both behaviors.",
            example = ReturnValueDemo
        ),

        P(:class => "text-stone-600 dark:text-stone-400 my-4",
            "The explicit ",
            Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "return"),
            " statement is especially useful for early exits from a function, such as when checking error conditions or handling special cases."
        ),

        # Section: Recursion
        H2(:class => "text-2xl font-semibold text-stone-800 dark:text-stone-100 mt-10 mb-4",
            "Recursion"
        ),

        P(:class => "text-stone-600 dark:text-stone-400 mb-4",
            "A function can call itself, which is called ",
            Em("recursion"),
            ". This is useful for problems that can be broken down into smaller instances of the same problem."
        ),

        LiveExample(
            code = """# Recursive factorial function
function factorial(n::Int32)::Int32
    if n <= Int32(1)
        return Int32(1)  # Base case
    else
        return n * factorial(n - Int32(1))  # Recursive call
    end
end

# factorial(5) = 5 * 4 * 3 * 2 * 1 = 120
factorial(5)  # returns 120
factorial(6)  # returns 720""",
            description = "The classic recursive factorial function. Click different values of n to see the computed factorial.",
            example = FactorialDemo
        ),

        Div(:class => "p-4 bg-cyan-50 dark:bg-cyan-900/20 rounded-xl border border-cyan-200 dark:border-cyan-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-cyan-600 dark:text-cyan-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                ),
                Div(
                    P(:class => "text-sm text-cyan-800 dark:text-cyan-200 font-medium", "Recursion Tips"),
                    P(:class => "text-sm text-cyan-700 dark:text-cyan-300 mt-1",
                        "Every recursive function needs: (1) a ",
                        Em("base case"),
                        " that stops the recursion, and (2) a ",
                        Em("recursive case"),
                        " that moves toward the base case. Without a proper base case, the function will recurse infinitely!"
                    )
                )
            )
        ),

        # Section: Closures
        H2(:class => "text-2xl font-semibold text-stone-800 dark:text-stone-100 mt-10 mb-4",
            "Closures"
        ),

        P(:class => "text-stone-600 dark:text-stone-400 mb-4",
            "A ",
            Em("closure"),
            " is a function that captures variables from its surrounding scope. This allows you to create functions that \"remember\" values from where they were defined."
        ),

        LiveExample(
            code = """# Create a closure that captures 'offset'
offset = 10

# This function captures 'offset' from outer scope
function add_offset(x::Int32)::Int32
    return x + offset
end

add_offset(5)   # returns 15 (5 + 10)

# Change offset and the closure sees the new value
offset = 20
add_offset(5)   # returns 25 (5 + 20)""",
            description = "A closure captures the 'offset' variable. Change offset to see how it affects the function's behavior.",
            example = ClosureDemo
        ),

        P(:class => "text-stone-600 dark:text-stone-400 my-4",
            "Closures are commonly used for creating specialized functions, callbacks, and maintaining state. In WasmTarget.jl, closures compile to WebAssembly structs that store the captured variables."
        ),

        # WasmTarget.jl note
        Div(:class => "p-4 bg-amber-50 dark:bg-amber-900/20 rounded-xl border border-amber-200 dark:border-amber-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-amber-600 dark:text-amber-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z")
                ),
                Div(
                    P(:class => "text-sm text-amber-800 dark:text-amber-200 font-medium", "WasmTarget.jl Note"),
                    P(:class => "text-sm text-amber-700 dark:text-amber-300 mt-1",
                        "WasmTarget.jl compiles closures to WasmGC structs where captured variables become struct fields. This matches how Julia handles closures internally, but complex closure patterns may have limitations."
                    )
                )
            )
        ),

        # Summary
        H2(:class => "text-2xl font-semibold text-stone-800 dark:text-stone-100 mt-10 mb-4",
            "Summary"
        ),

        Ul(:class => "list-disc list-inside space-y-2 text-stone-600 dark:text-stone-400 mb-6",
            Li("Define functions with ", Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "function name(args) ... end"), " or compact ", Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "name(args) = expression")),
            Li("Functions can have multiple arguments with optional type annotations"),
            Li("Use ", Code(:class => "text-cyan-600 dark:text-cyan-400 bg-stone-100 dark:bg-stone-800 px-1.5 py-0.5 rounded", "return"), " for explicit returns, or let the last expression be returned implicitly"),
            Li("Recursive functions call themselves and need a base case to terminate"),
            Li("Closures capture variables from their surrounding scope"),
            Li("WasmTarget.jl supports basic function patterns; varargs/kwargs are not yet available")
        ),

        # Next steps
        Div(:class => "p-6 bg-gradient-to-r from-cyan-50 to-teal-50 dark:from-cyan-900/20 dark:to-teal-900/20 rounded-xl border border-cyan-200 dark:border-cyan-800",
            H3(:class => "text-lg font-semibold text-stone-800 dark:text-stone-100 mb-2",
                "Next Steps"
            ),
            P(:class => "text-stone-600 dark:text-stone-400",
                "Now that you understand functions, continue to ",
                A(:href => "../control-flow/",
                  :class => "text-cyan-600 dark:text-cyan-400 font-medium hover:underline",
                  "Control Flow"),
                " to learn about conditional statements and loops, or explore ",
                A(:href => "../types/",
                  :class => "text-cyan-600 dark:text-cyan-400 font-medium hover:underline",
                  "Types (Structs)"),
                " to see how to define custom data structures."
            )
        )
    )
end

# Export
Functions
