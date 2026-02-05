# Manual Chapter: Mathematical Operations
#
# Interactive manual page covering arithmetic, comparison, and bitwise operators.
# Based on docs.julialang.org/en/v1/manual/mathematical-operations/
#
# Route: /manual/math-operations

# =============================================================================
# NOTE: This file uses pre-built islands from LiveExample.jl
# CalculatorDemo, ComparisonOpsDemo, BitwiseDemo, MathFunctionsDemo, NegationDemo
# are defined there and work correctly with SSR.
# =============================================================================

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
        Div(:class => "my-6 overflow-x-auto",
            Table(:class => "w-full text-sm border-collapse",
                Thead(:class => "bg-warm-100 dark:bg-warm-800",
                    Tr(
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Expression"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Name"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Description")
                    )
                ),
                Tbody(
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "+x"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "unary plus"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "identity operation")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "-x"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "unary minus"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "maps values to their additive inverses")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "x + y"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "addition"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "sum of x and y")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "x - y"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "subtraction"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "difference of x and y")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "x * y"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "multiplication"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "product of x and y")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "x / y"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "division"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "quotient of x and y (returns Float64)")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "div(x, y)"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "integer division"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "quotient truncated to an integer")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "x % y"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "remainder"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "remainder after integer division")
                    )
                )
            )
        ),

        LiveExample(
            code = """# Arithmetic operations
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
# 24 == 3 * 7 + 3  ✓""",
            description = "Click the operation buttons to compute different arithmetic results. Adjust a and b to experiment.",
            example = CalculatorDemo
        ),

        # Section: Negation
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Negation"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "The unary minus operator ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "-x"),
            " returns the additive inverse of ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "x"),
            ". This is equivalent to ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "0 - x"),
            "."
        ),

        LiveExample(
            code = """# Negation
x = 10
neg_x = -x         # -10

# Equivalent to:
also_neg = 0 - x   # -10

# Double negation returns original
double_neg = -(-x) # 10

# Negating negative numbers
y = -5
pos_y = -y         # 5""",
            description = "Adjust the value to see how negation works with positive and negative numbers.",
            example = NegationDemo
        ),

        # Section: Comparison Operators
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Comparison Operators"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Comparison operators are used to compare values and return a boolean (",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "true"),
            " or ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "false"),
            ")."
        ),

        # Comparison operators table
        Div(:class => "my-6 overflow-x-auto",
            Table(:class => "w-full text-sm border-collapse",
                Thead(:class => "bg-warm-100 dark:bg-warm-800",
                    Tr(
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Operator"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Name"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Example")
                    )
                ),
                Tbody(
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "=="),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "equality"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "5 == 5 → true")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "!="),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "inequality"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "5 != 3 → true")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "<"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "less than"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "3 < 5 → true")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "<="),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "less than or equal"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "3 <= 3 → true")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", ">"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "greater than"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "5 > 3 → true")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", ">="),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "greater than or equal"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400 font-mono", "5 >= 5 → true")
                    )
                )
            )
        ),

        LiveExample(
            code = """# Comparison operators
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
1 < x < 5  # true (x is between 1 and 5)""",
            description = "Adjust the values of a and b to see how all comparison operators respond.",
            example = ComparisonOpsDemo
        ),

        Div(:class => "p-4 bg-accent-50 dark:bg-accent-900/20 rounded-xl border border-accent-200 dark:border-accent-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-accent-600 dark:text-accent-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                ),
                Div(
                    P(:class => "text-sm text-accent-800 dark:text-accent-200 font-medium", "Tip"),
                    P(:class => "text-sm text-accent-700 dark:text-accent-300 mt-1",
                        "In Julia, comparison operators can be chained: ",
                        Code(:class => "text-accent-600 dark:text-accent-400", "1 < x < 10"),
                        " is equivalent to ",
                        Code(:class => "text-accent-600 dark:text-accent-400", "1 < x && x < 10"),
                        ". This is useful for range checks."
                    )
                )
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
        Div(:class => "my-6 overflow-x-auto",
            Table(:class => "w-full text-sm border-collapse",
                Thead(:class => "bg-warm-100 dark:bg-warm-800",
                    Tr(
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Expression"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Name"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Description")
                    )
                ),
                Tbody(
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "~x"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "bitwise NOT"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "inverts all bits")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "x & y"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "bitwise AND"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "1 only if both bits are 1")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "x | y"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "bitwise OR"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "1 if either bit is 1")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "xor(x, y)"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "bitwise XOR"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "1 if bits differ")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "x << n"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "left shift"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "shift bits left by n positions")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "x >> n"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "right shift"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "shift bits right by n positions")
                    )
                )
            )
        ),

        LiveExample(
            code = """# Bitwise operations
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
a >> 2  # 3  (12 / 4)""",
            description = "Experiment with bitwise operators. Values shown in both decimal and binary representation.",
            example = BitwiseDemo
        ),

        Div(:class => "p-4 bg-amber-50 dark:bg-amber-900/20 rounded-xl border border-amber-200 dark:border-amber-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-amber-600 dark:text-amber-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z")
                ),
                Div(
                    P(:class => "text-sm text-amber-800 dark:text-amber-200 font-medium", "Performance Tip"),
                    P(:class => "text-sm text-amber-700 dark:text-amber-300 mt-1",
                        "Left shift by ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "n"),
                        " is equivalent to multiplying by ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "2^n"),
                        ", and right shift is equivalent to integer division by ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "2^n"),
                        ". These operations are extremely fast at the hardware level."
                    )
                )
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
        Div(:class => "my-6 overflow-x-auto",
            Table(:class => "w-full text-sm border-collapse",
                Thead(:class => "bg-warm-100 dark:bg-warm-800",
                    Tr(
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Function"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Description"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "WASM Native")
                    )
                ),
                Tbody(
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "abs(x)"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "Absolute value"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-accent-600 dark:text-accent-400", "Yes (f32.abs, f64.abs)")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "sqrt(x)"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "Square root"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-accent-600 dark:text-accent-400", "Yes (f32.sqrt, f64.sqrt)")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "floor(x)"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "Round down to integer"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-accent-600 dark:text-accent-400", "Yes (f32.floor, f64.floor)")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "ceil(x)"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "Round up to integer"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-accent-600 dark:text-accent-400", "Yes (f32.ceil, f64.ceil)")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "round(x)"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "Round to nearest integer"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-accent-600 dark:text-accent-400", "Yes (f32.nearest, f64.nearest)")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "trunc(x)"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "Truncate toward zero"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-accent-600 dark:text-accent-400", "Yes (f32.trunc, f64.trunc)")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "min(x, y)"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "Minimum of two values"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-accent-600 dark:text-accent-400", "Yes (f32.min, f64.min)")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "max(x, y)"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "Maximum of two values"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-accent-600 dark:text-accent-400", "Yes (f32.max, f64.max)")
                    )
                )
            )
        ),

        LiveExample(
            code = """# Math functions
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
max(5, 3)   # 5""",
            description = "Experiment with different values to see absolute value and multiplication results.",
            example = MathFunctionsDemo
        ),

        # WasmTarget.jl note
        Div(:class => "p-4 bg-accent-50 dark:bg-accent-900/20 rounded-xl border border-accent-200 dark:border-accent-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-accent-600 dark:text-accent-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                ),
                Div(
                    P(:class => "text-sm text-accent-800 dark:text-accent-200 font-medium", "WasmTarget.jl Note"),
                    P(:class => "text-sm text-accent-700 dark:text-accent-300 mt-1",
                        "Functions marked as \"WASM Native\" compile directly to single WebAssembly instructions, making them extremely fast. Other math functions like ",
                        Code(:class => "text-accent-600 dark:text-accent-400", "sin"),
                        ", ",
                        Code(:class => "text-accent-600 dark:text-accent-400", "cos"),
                        ", and ",
                        Code(:class => "text-accent-600 dark:text-accent-400", "exp"),
                        " require more complex implementations."
                    )
                )
            )
        ),

        # Summary
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Summary"
        ),

        Ul(:class => "list-disc list-inside space-y-2 text-warm-600 dark:text-warm-400 mb-6",
            Li("Arithmetic: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "+"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "-"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "*"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "/"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "div()"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "%")),
            Li("Comparison: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "=="), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "!="), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "<"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "<="), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", ">"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", ">=")),
            Li("Bitwise: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "&"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "|"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "xor()"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "<<"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", ">>")),
            Li("Math functions like ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "abs"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "sqrt"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "floor"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "ceil"), " are WASM-native"),
            Li("Comparisons can be chained: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "a < x < b"))
        ),

        # Next steps
        Div(:class => "p-6 bg-gradient-to-r from-accent-50 to-accent-50 dark:from-accent-900/20 dark:to-accent-900/20 rounded-xl border border-accent-200 dark:border-accent-800",
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
