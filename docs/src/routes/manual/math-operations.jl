# Manual Chapter: Mathematical Operations
#
# Manual page covering arithmetic, comparison, and bitwise operators.
# Based on docs.julialang.org/en/v1/manual/mathematical-operations/
# Interactive demos have been removed and replaced with static code examples.
#
# Route: /manual/math-operations

import Suite

# =============================================================================
# Mathematical Operations Chapter Page
# =============================================================================

"""
Mathematical Operations chapter for the Interactive Julia Manual.
"""
function MathOperations()
    ManualLayout(chapter_id="math-operations", chapter_title="Math Operations",
        # Title
        H1(:class => "text-3xl font-bold text-warm-800 dark:text-warm-100 mb-4",
            "Mathematical Operations"
        ),

        # Introduction
        P(:class => "text-lg text-warm-600 dark:text-warm-400 mb-8",
            "Julia provides a complete collection of basic arithmetic, comparison, and bitwise operators across all numeric types. These operations compile directly to efficient WebAssembly instructions, giving you native performance in the browser."
        ),

        # Section: Arithmetic Operators
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Arithmetic Operators"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "The following arithmetic operators are supported on all primitive numeric types:"
        ),

        # Arithmetic operators table
        Suite.Table(
            Suite.TableHeader(Suite.TableRow(
                Suite.TableHead("Expression"),
                Suite.TableHead("Name"),
                Suite.TableHead("Description")
            )),
            Suite.TableBody(
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "+x"),
                    Suite.TableCell("unary plus"),
                    Suite.TableCell("identity operation")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "-x"),
                    Suite.TableCell("unary minus"),
                    Suite.TableCell("maps values to their additive inverses")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "x + y"),
                    Suite.TableCell("addition"),
                    Suite.TableCell("sum of x and y")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "x - y"),
                    Suite.TableCell("subtraction"),
                    Suite.TableCell("difference of x and y")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "x * y"),
                    Suite.TableCell("multiplication"),
                    Suite.TableCell("product of x and y")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "x / y"),
                    Suite.TableCell("division"),
                    Suite.TableCell("quotient of x and y (returns Float64)")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "div(x, y)"),
                    Suite.TableCell("integer division"),
                    Suite.TableCell("quotient truncated to an integer")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "x % y"),
                    Suite.TableCell("remainder"),
                    Suite.TableCell("remainder after integer division")
                )
            )
        ),

        Suite.CodeBlock("""# Arithmetic operations
a = 24
b = 7

# Addition and subtraction
sum = a + b        # 31
diff = a - b       # 17

# Multiplication
prod = a * b       # 168

# Division (returns Float64)
quot = a / b       # 3.4285...

# Integer division (truncates)
int_quot = div(a, b)  # 3

# Remainder (modulo)
rem = a % b        # 3

# Relationship: a == div(a,b) * b + a % b
# 24 == 3 * 7 + 3  ✓""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Click the operation buttons to compute different arithmetic results. Adjust a and b to experiment."
        ),

        # Section: Negation
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Negation"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "The unary minus operator ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "-x"),
            " returns the additive inverse of ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "x"),
            ". This is equivalent to ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "0 - x"),
            "."
        ),

        Suite.CodeBlock("""# Negation
x = 10
neg_x = -x         # -10

# Equivalent to:
also_neg = 0 - x   # -10

# Double negation returns original
double_neg = -(-x) # 10

# Negating negative numbers
y = -5
pos_y = -y         # 5""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Adjust the value to see how negation works with positive and negative numbers."
        ),

        # Section: Comparison Operators
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Comparison Operators"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Comparison operators are used to compare values and return a boolean (",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "true"),
            " or ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "false"),
            ")."
        ),

        # Comparison operators table
        Suite.Table(
            Suite.TableHeader(Suite.TableRow(
                Suite.TableHead("Operator"),
                Suite.TableHead("Name"),
                Suite.TableHead("Example")
            )),
            Suite.TableBody(
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "=="),
                    Suite.TableCell("equality"),
                    Suite.TableCell(:class => "font-mono", "5 == 5 → true")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "!="),
                    Suite.TableCell("inequality"),
                    Suite.TableCell(:class => "font-mono", "5 != 3 → true")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "<"),
                    Suite.TableCell("less than"),
                    Suite.TableCell(:class => "font-mono", "3 < 5 → true")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "<="),
                    Suite.TableCell("less than or equal"),
                    Suite.TableCell(:class => "font-mono", "3 <= 3 → true")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", ">"),
                    Suite.TableCell("greater than"),
                    Suite.TableCell(:class => "font-mono", "5 > 3 → true")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", ">="),
                    Suite.TableCell("greater than or equal"),
                    Suite.TableCell(:class => "font-mono", "5 >= 5 → true")
                )
            )
        ),

        Suite.CodeBlock("""# Comparison operators
a = 5
b = 5

# Equality
a == b    # true
a != b    # false

# Ordering
a < b     # false
a <= b    # true
a > b     # false
a >= b    # true

# Comparisons can be chained
x = 3
1 < x < 5  # true (x is between 1 and 5)""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Adjust the values of a and b to see how all comparison operators respond."
        ),

        Suite.Alert(class="my-6",
            Suite.AlertTitle("Tip"),
            Suite.AlertDescription(
                "In Julia, comparison operators can be chained: ",
                Code(:class => "text-accent-600 dark:text-accent-400", "1 < x < 10"),
                " is equivalent to ",
                Code(:class => "text-accent-600 dark:text-accent-400", "1 < x && x < 10"),
                ". This is useful for range checks."
            )
        ),

        # Section: Bitwise Operators
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Bitwise Operators"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Bitwise operators work on the binary representation of integers. These are useful for low-level programming, flags, and performance optimization."
        ),

        # Bitwise operators table
        Suite.Table(
            Suite.TableHeader(Suite.TableRow(
                Suite.TableHead("Expression"),
                Suite.TableHead("Name"),
                Suite.TableHead("Description")
            )),
            Suite.TableBody(
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "~x"),
                    Suite.TableCell("bitwise NOT"),
                    Suite.TableCell("inverts all bits")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "x & y"),
                    Suite.TableCell("bitwise AND"),
                    Suite.TableCell("1 only if both bits are 1")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "x | y"),
                    Suite.TableCell("bitwise OR"),
                    Suite.TableCell("1 if either bit is 1")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "xor(x, y)"),
                    Suite.TableCell("bitwise XOR"),
                    Suite.TableCell("1 if bits differ")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "x << n"),
                    Suite.TableCell("left shift"),
                    Suite.TableCell("shift bits left by n positions")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "x >> n"),
                    Suite.TableCell("right shift"),
                    Suite.TableCell("shift bits right by n positions")
                )
            )
        ),

        Suite.CodeBlock("""# Bitwise operations
# Using small numbers for clarity
a = 12  # binary: 1100
b = 10  # binary: 1010

# AND: 1 only where both have 1
a & b   # 8  (binary: 1000)

# OR: 1 where either has 1
a | b   # 14 (binary: 1110)

# XOR: 1 where bits differ
xor(a, b)  # 6 (binary: 0110)

# Left shift (multiply by 2^n)
a << 1  # 24 (12 * 2)
a << 2  # 48 (12 * 4)

# Right shift (integer divide by 2^n)
a >> 1  # 6  (12 / 2)
a >> 2  # 3  (12 / 4)""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Experiment with bitwise operators. Values shown in both decimal and binary representation."
        ),

        Suite.Alert(class="my-6",
            Suite.AlertTitle("Performance Tip"),
            Suite.AlertDescription(
                "Left shift by ",
                Code(:class => "text-accent-600 dark:text-accent-400", "n"),
                " is equivalent to multiplying by ",
                Code(:class => "text-accent-600 dark:text-accent-400", "2^n"),
                ", and right shift is equivalent to integer division by ",
                Code(:class => "text-accent-600 dark:text-accent-400", "2^n"),
                ". These operations are extremely fast at the hardware level."
            )
        ),

        # Section: Math Functions
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Math Functions"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Julia provides many mathematical functions. In WasmTarget.jl, several of these map directly to WebAssembly instructions for optimal performance."
        ),

        # Math functions table
        Suite.Table(
            Suite.TableHeader(Suite.TableRow(
                Suite.TableHead("Function"),
                Suite.TableHead("Description"),
                Suite.TableHead("WASM Native")
            )),
            Suite.TableBody(
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "abs(x)"),
                    Suite.TableCell("Absolute value"),
                    Suite.TableCell(:class => "text-accent-600 dark:text-accent-400", "Yes (f32.abs, f64.abs)")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "sqrt(x)"),
                    Suite.TableCell("Square root"),
                    Suite.TableCell(:class => "text-accent-600 dark:text-accent-400", "Yes (f32.sqrt, f64.sqrt)")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "floor(x)"),
                    Suite.TableCell("Round down to integer"),
                    Suite.TableCell(:class => "text-accent-600 dark:text-accent-400", "Yes (f32.floor, f64.floor)")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "ceil(x)"),
                    Suite.TableCell("Round up to integer"),
                    Suite.TableCell(:class => "text-accent-600 dark:text-accent-400", "Yes (f32.ceil, f64.ceil)")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "round(x)"),
                    Suite.TableCell("Round to nearest integer"),
                    Suite.TableCell(:class => "text-accent-600 dark:text-accent-400", "Yes (f32.nearest, f64.nearest)")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "trunc(x)"),
                    Suite.TableCell("Truncate toward zero"),
                    Suite.TableCell(:class => "text-accent-600 dark:text-accent-400", "Yes (f32.trunc, f64.trunc)")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "min(x, y)"),
                    Suite.TableCell("Minimum of two values"),
                    Suite.TableCell(:class => "text-accent-600 dark:text-accent-400", "Yes (f32.min, f64.min)")
                ),
                Suite.TableRow(
                    Suite.TableCell(:class => "font-mono text-accent-600 dark:text-accent-400", "max(x, y)"),
                    Suite.TableCell("Maximum of two values"),
                    Suite.TableCell(:class => "text-accent-600 dark:text-accent-400", "Yes (f32.max, f64.max)")
                )
            )
        ),

        Suite.CodeBlock("""# Math functions
x = 49

# Absolute value (works on negative too)
abs(-25)   # 25
abs(25)    # 25

# Multiplication and exponentiation
x * 2      # 98 (doubling)
x * x      # 2401 (squaring)

# Square root (Float64)
sqrt(49.0)  # 7.0
sqrt(2.0)   # 1.4142...

# Min and max
min(5, 3)   # 3
max(5, 3)   # 5""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Experiment with different values to see absolute value and multiplication results."
        ),

        # WasmTarget.jl note
        Suite.Alert(class="my-6",
            Suite.AlertTitle("WasmTarget.jl Note"),
            Suite.AlertDescription(
                "Functions marked as \"WASM Native\" compile directly to single WebAssembly instructions, making them extremely fast. Other math functions like ",
                Code(:class => "text-accent-600 dark:text-accent-400", "sin"),
                ", ",
                Code(:class => "text-accent-600 dark:text-accent-400", "cos"),
                ", and ",
                Code(:class => "text-accent-600 dark:text-accent-400", "exp"),
                " require more complex implementations."
            )
        ),

        # Summary
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Summary"
        ),

        Ul(:class => "list-disc list-inside space-y-2 text-warm-600 dark:text-warm-400 mb-6",
            Li("Arithmetic: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "+"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "-"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "*"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "/"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "div()"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "%")),
            Li("Comparison: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "=="), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "!="), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "<"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "<="), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", ">"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", ">=")),
            Li("Bitwise: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "&"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "|"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "xor()"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "<<"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", ">>")),
            Li("Math functions like ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "abs"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "sqrt"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "floor"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "ceil"), " are WASM-native"),
            Li("Comparisons can be chained: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "a < x < b"))
        ),

        # Next steps
        Div(:class => "p-6 bg-gradient-to-r from-warm-50 to-warm-100 dark:from-warm-900 dark:to-warm-950 rounded-xl border border-warm-200 dark:border-warm-700",
            H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-100 mb-2",
                "Next Steps"
            ),
            P(:class => "text-warm-600 dark:text-warm-400",
                "Now that you understand operators, continue to ",
                A(:href => "../strings/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Strings"),
                " to learn about text manipulation, or go back to ",
                A(:href => "../integers-floats/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Integers & Floats"),
                " to review numeric types."
            )
        )
    )
end

# Export
MathOperations
