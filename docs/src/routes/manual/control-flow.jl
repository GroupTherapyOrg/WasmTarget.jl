# Manual Chapter: Control Flow
#
# Interactive manual page covering Julia control flow - if/else, while loops,
# for loops, short-circuit operators (&&/||), and try/catch/throw.
# Based on docs.julialang.org/en/v1/manual/control-flow/
#
# Route: /manual/control-flow

# =============================================================================
# NOTE: This file uses pre-built islands from LiveExample.jl
# SignDemo, WhileLoopDemo, ForLoopDemo, ShortCircuitDemo, and TryCatchDemo
# are defined there and work correctly with SSR.
# =============================================================================

# =============================================================================
# Control Flow Chapter Page
# =============================================================================

"""
Control Flow chapter for the Interactive Julia Manual.
"""
function ControlFlow()
    ManualLayout(chapter_id="control-flow", chapter_title="Control Flow",
        # Title
        H1(:class => "text-3xl font-bold text-warm-800 dark:text-warm-100 mb-4",
            "Control Flow"
        ),

        # Introduction
        P(:class => "text-lg text-warm-600 dark:text-warm-400 mb-8",
            "Control flow constructs determine the order in which statements execute. Julia provides familiar constructs like ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "if"),
            "/",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "else"),
            " for conditional execution, ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "while"),
            " and ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "for"),
            " loops for iteration, and short-circuit operators for efficient boolean evaluation."
        ),

        # Section: Conditional Evaluation (if/elseif/else)
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Conditional Evaluation: if/elseif/else"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "The ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "if"),
            " statement evaluates a condition and executes code based on whether it's true or false. You can chain multiple conditions with ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "elseif"),
            " and provide a fallback with ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "else"),
            "."
        ),

        LiveExample(
            code = """# The sign function - classic if/elseif/else example
function sign(x::Int32)::Int32
    if x > Int32(0)
        return Int32(1)    # positive
    elseif x < Int32(0)
        return Int32(-1)   # negative
    else
        return Int32(0)    # zero
    end
end

sign(5)    # returns 1
sign(-3)   # returns -1
sign(0)    # returns 0""",
            description = "The sign function returns +1 for positive numbers, -1 for negative, and 0 for zero. Adjust the value to see the branch taken.",
            example = SignDemo
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "Unlike some languages, Julia's ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "if"),
            " is an expression that returns a value. The value is the result of the last expression in the branch that executes."
        ),

        # Info box about if as expression
        Div(:class => "p-4 bg-accent-50 dark:bg-accent-900/20 rounded-xl border border-accent-200 dark:border-accent-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-accent-600 dark:text-accent-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                ),
                Div(
                    P(:class => "text-sm text-accent-800 dark:text-accent-200 font-medium", "if as an Expression"),
                    P(:class => "text-sm text-accent-700 dark:text-accent-300 mt-1",
                        "In Julia, ",
                        Code(:class => "text-accent-800 dark:text-accent-200", "if"),
                        " returns a value: ",
                        Code(:class => "text-accent-800 dark:text-accent-200", "result = if x > 0 \"pos\" else \"non-pos\" end"),
                        ". This is equivalent to the ternary operator: ",
                        Code(:class => "text-accent-800 dark:text-accent-200", "x > 0 ? \"pos\" : \"non-pos\""),
                        "."
                    )
                )
            )
        ),

        # Section: While Loops
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Repeated Evaluation: while Loops"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "The ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "while"),
            " loop repeatedly executes a block of code as long as a condition remains true. The condition is checked before each iteration."
        ),

        LiveExample(
            code = """# Sum integers from 1 to n using a while loop
function sum_to_n(n::Int32)::Int32
    sum = Int32(0)
    i = Int32(1)
    while i <= n
        sum = sum + i
        i = i + Int32(1)
    end
    return sum
end

# sum_to_n(10) = 1+2+3+...+10 = 55
sum_to_n(10)  # returns 55
sum_to_n(100) # returns 5050""",
            description = "A while loop that sums integers from 1 to n. Adjust n to see the sum change. Uses Gauss's formula: n*(n+1)/2.",
            example = WhileLoopDemo
        ),

        # Section: For Loops
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Repeated Evaluation: for Loops"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "The ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "for"),
            " loop iterates over a sequence of values. In Julia, you typically iterate over a range like ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "1:n"),
            " or a collection."
        ),

        LiveExample(
            code = """# Calculate factorial using a for loop
function factorial(n::Int32)::Int32
    result = Int32(1)
    for i in Int32(2):n
        result = result * i
    end
    return result
end

# factorial(5) = 1*2*3*4*5 = 120
factorial(5)  # returns 120
factorial(6)  # returns 720""",
            description = "Factorial computed with a for loop. The range 2:n iterates from 2 up to n (inclusive).",
            example = ForLoopDemo
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "Ranges in Julia are inclusive: ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "1:5"),
            " includes 1, 2, 3, 4, and 5. You can also specify a step: ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "1:2:10"),
            " gives 1, 3, 5, 7, 9."
        ),

        # Section: Short-Circuit Evaluation
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Short-Circuit Evaluation: && and ||"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Julia's ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "&&"),
            " (and) and ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "||"),
            " (or) operators use ",
            Em("short-circuit evaluation"),
            ": they only evaluate the second operand if necessary to determine the result."
        ),

        LiveExample(
            code = """# Short-circuit && (AND)
# Second part only runs if first is true
function safe_divide(a::Int32, b::Int32)::Int32
    # Only divide if b != 0
    return (b != Int32(0)) && (a / b > Int32(0)) ? Int32(1) : Int32(0)
end

# Short-circuit || (OR)
# Second part only runs if first is false
function default_value(x::Int32, default::Int32)::Int32
    # Return x if positive, otherwise default
    return (x > Int32(0)) ? x : default
end

# a && b: if a is false, return false without evaluating b
# a || b: if a is true, return true without evaluating b""",
            description = "Short-circuit operators avoid evaluating the second operand when unnecessary. && stops on false, || stops on true.",
            example = ShortCircuitDemo
        ),

        # Info box about short-circuit idioms
        Div(:class => "p-4 bg-warm-100 dark:bg-warm-800 rounded-xl my-6",
            H3(:class => "text-sm font-semibold text-warm-800 dark:text-warm-200 mb-3", "Common Short-Circuit Idioms"),
            Div(:class => "space-y-2 text-sm font-mono",
                P(:class => "text-warm-600 dark:text-warm-400",
                    Code(:class => "text-accent-600 dark:text-accent-400", "condition && action()"),
                    Span(:class => "text-warm-500 ml-2", "# execute action only if condition is true")
                ),
                P(:class => "text-warm-600 dark:text-warm-400",
                    Code(:class => "text-accent-600 dark:text-accent-400", "condition || action()"),
                    Span(:class => "text-warm-500 ml-2", "# execute action only if condition is false")
                ),
                P(:class => "text-warm-600 dark:text-warm-400",
                    Code(:class => "text-accent-600 dark:text-accent-400", "x != 0 && do_something(x)"),
                    Span(:class => "text-warm-500 ml-2", "# guard against zero")
                )
            )
        ),

        # Section: Exception Handling
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Exception Handling: try/catch/throw"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Julia uses exceptions to handle errors. You can ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "throw"),
            " an exception when an error occurs, and ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "try"),
            "/",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "catch"),
            " to handle it gracefully."
        ),

        LiveExample(
            code = """# Safe integer square root with exception handling
function safe_sqrt(n::Int32)::Int32
    if n < Int32(0)
        throw(DomainError(n, "sqrt requires non-negative input"))
    end
    # Integer square root approximation
    r = Int32(0)
    while r * r <= n
        r = r + Int32(1)
    end
    return r - Int32(1)
end

# Using try/catch to handle errors
function compute_sqrt(n::Int32)::Int32
    try
        return safe_sqrt(n)
    catch
        return Int32(-1)  # Return -1 on error
    end
end""",
            description = "Exception handling with try/catch. Try a negative number to see the error path.",
            example = TryCatchDemo
        ),

        # Warning about exception limitations
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
                        "WasmTarget.jl compiles try/catch to WebAssembly's ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "try_table"),
                        " with ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "catch_all"),
                        ". Basic exception handling works, but complex exception types and ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "finally"),
                        " blocks have limitations."
                    )
                )
            )
        ),

        # Section: break and continue
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Loop Control: break and continue"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Inside loops, ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "break"),
            " exits the loop immediately, while ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "continue"),
            " skips to the next iteration."
        ),

        LiveExample(
            code = """# Find first value divisible by both 3 and 7
function find_divisible()::Int32
    for i in Int32(1):Int32(100)
        # Skip if not divisible by 3
        if i % Int32(3) != Int32(0)
            continue
        end
        # Check if also divisible by 7
        if i % Int32(7) == Int32(0)
            return i  # Found it! (break is implicit with return)
        end
    end
    return Int32(-1)  # Not found
end

# First number divisible by both 3 and 7 is 21
find_divisible()  # returns 21""",
            description = "Using continue to skip iterations. The loop finds the first number divisible by both 3 and 7.",
            example = BreakContinueDemo
        ),

        # Summary
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Summary"
        ),

        Ul(:class => "list-disc list-inside space-y-2 text-warm-600 dark:text-warm-400 mb-6",
            Li(Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "if"), "/", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "elseif"), "/", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "else"), " for conditional execution; ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "if"), " is an expression that returns a value"),
            Li(Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "while condition ... end"), " repeats while condition is true"),
            Li(Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "for i in range ... end"), " iterates over a sequence (e.g., ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "1:10"), ")"),
            Li(Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "&&"), " short-circuits on false; ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "||"), " short-circuits on true"),
            Li(Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "try"), "/", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "catch"), " handles exceptions; ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "throw"), " raises them"),
            Li(Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "break"), " exits a loop; ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "continue"), " skips to the next iteration")
        ),

        # Next steps
        Div(:class => "p-6 bg-gradient-to-r from-accent-50 to-accent-50 dark:from-accent-900/20 dark:to-accent-900/20 rounded-xl border border-accent-200 dark:border-accent-800",
            H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-100 mb-2",
                "Next Steps"
            ),
            P(:class => "text-warm-600 dark:text-warm-400",
                "Now that you understand control flow, continue to ",
                A(:href => "../types/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Types (Structs)"),
                " to learn about defining custom data structures, or explore ",
                A(:href => "../methods/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Methods"),
                " to see how multiple dispatch works with different types."
            )
        )
    )
end

# Export
ControlFlow
