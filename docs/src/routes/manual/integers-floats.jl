# Manual Chapter: Integers and Floating-Point Numbers
#
# Interactive manual page covering numeric types - Int32, Int64, Float32, Float64,
# literals, overflow behavior.
# Based on docs.julialang.org/en/v1/manual/integers-and-floating-point-numbers/
#
# Route: /manual/integers-floats

# =============================================================================
# NOTE: This file uses pre-built islands from LiveExample.jl
# IntegerOverflowDemo, FloatPrecisionDemo, TypeConversionDemo, NumericLiteralsDemo
# are defined there and work correctly with SSR.
# =============================================================================

# =============================================================================
# Integers and Floating-Point Numbers Chapter Page
# =============================================================================

"""
Integers and Floating-Point Numbers chapter for the Interactive Julia Manual.
"""
function IntegersFloats()
    ManualLayout(chapter_id="integers-floats", chapter_title="Integers & Floats",
        # Title
        H1(:class => "text-3xl font-bold text-warm-800 dark:text-warm-100 mb-4",
            "Integers and Floating-Point Numbers"
        ),

        # Introduction
        P(:class => "text-lg text-warm-600 dark:text-warm-400 mb-8",
            "Julia provides a variety of primitive numeric types for representing integers and floating-point numbers. Understanding these types is essential for writing efficient code, especially when compiling to WebAssembly."
        ),

        # Section: Integer Types
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Integer Types"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "WasmTarget.jl supports both 32-bit and 64-bit signed integers. The type you choose affects both the range of values and the generated WebAssembly code."
        ),

        # Integer types table
        Div(:class => "my-6 overflow-x-auto",
            Table(:class => "w-full text-sm border-collapse",
                Thead(:class => "bg-warm-100 dark:bg-warm-900",
                    Tr(
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Type"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Wasm"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Bits"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Range")
                    )
                ),
                Tbody(
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "Int32"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-warm-500 dark:text-warm-400", "i32"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "32"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "-2,147,483,648 to 2,147,483,647")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "Int64"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-warm-500 dark:text-warm-400", "i64"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "64"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "-9,223,372,036,854,775,808 to 9,223,372,036,854,775,807")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "UInt32"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-warm-500 dark:text-warm-400", "i32"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "32"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "0 to 4,294,967,295")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "UInt64"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-warm-500 dark:text-warm-400", "i64"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "64"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "0 to 18,446,744,073,709,551,615")
                    )
                )
            )
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "In Julia, the default integer type ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Int"),
            " is an alias for ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Int64"),
            " on 64-bit systems. For WebAssembly, ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Int32"),
            " is often more efficient since Wasm has native 32-bit operations."
        ),

        # Section: Integer Overflow
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Integer Overflow"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "When an integer exceeds its maximum value, it wraps around to the minimum value. This behavior is called ",
            Em("overflow"),
            " and can lead to unexpected results if not handled carefully."
        ),

        LiveExample(
            code = """# Integer overflow demo
x::Int32 = 2147483647   # Maximum Int32 value
y::Int32 = x + 1        # Overflows!

# y is now -2147483648 (minimum Int32)
# This is called "wraparound" or "modular arithmetic"

# The same happens in reverse:
a::Int32 = -2147483648  # Minimum Int32
b::Int32 = a - 1        # Underflows to 2147483647""",
            description = "Watch what happens when you increment past the maximum Int32 value. The value wraps around to the minimum.",
            example = IntegerOverflowDemo
        ),

        Div(:class => "p-4 bg-amber-50 dark:bg-amber-900/20 rounded-xl border border-amber-200 dark:border-amber-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-amber-600 dark:text-amber-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z")
                ),
                Div(
                    P(:class => "text-sm text-amber-800 dark:text-amber-200 font-medium", "Important"),
                    P(:class => "text-sm text-amber-700 dark:text-amber-300 mt-1",
                        "Unlike Julia's ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "BigInt"),
                        ", which can grow arbitrarily large, fixed-size integers in WebAssembly will overflow silently. Always consider the range of your values when choosing integer types."
                    )
                )
            )
        ),

        # Section: Floating-Point Types
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Floating-Point Types"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "For numbers with fractional parts, Julia provides single-precision (",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Float32"),
            ") and double-precision (",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Float64"),
            ") floating-point numbers."
        ),

        # Float types table
        Div(:class => "my-6 overflow-x-auto",
            Table(:class => "w-full text-sm border-collapse",
                Thead(:class => "bg-warm-100 dark:bg-warm-900",
                    Tr(
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Type"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Wasm"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Bits"),
                        Th(:class => "text-left px-4 py-2 border border-warm-200 dark:border-warm-700 font-medium text-warm-700 dark:text-warm-300", "Precision")
                    )
                ),
                Tbody(
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "Float32"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-warm-500 dark:text-warm-400", "f32"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "32"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "~7 decimal digits")
                    ),
                    Tr(
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-accent-600 dark:text-accent-400", "Float64"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 font-mono text-warm-500 dark:text-warm-400", "f64"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "64"),
                        Td(:class => "px-4 py-2 border border-warm-200 dark:border-warm-700 text-warm-600 dark:text-warm-400", "~15-17 decimal digits")
                    )
                )
            )
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "Float literals in Julia are ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Float64"),
            " by default. To create a ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Float32"),
            ", append ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "f0"),
            " to the literal: ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "3.14f0"),
            "."
        ),

        # Section: Integer Division
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Integer Division and Remainder"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "When dividing integers, Julia provides two useful functions: ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "div"),
            " for integer division (discarding the remainder) and ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "%"),
            " for the remainder (modulo)."
        ),

        LiveExample(
            code = """# Integer division and remainder
a = 10
b = 3

# Integer division (truncates toward zero)
quotient = div(a, b)  # 3

# Remainder (modulo)
remainder = a % b     # 1

# Relationship: a == div(a, b) * b + (a % b)
# 10 == 3 * 3 + 1  ✓

# Regular division produces a float:
result = a / b        # 3.333...""",
            description = "Experiment with integer division and remainder. The quotient is always an integer.",
            example = FloatPrecisionDemo
        ),

        # Section: Type Conversion
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Type Conversion"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "You can convert between numeric types using type constructors or conversion functions."
        ),

        LiveExample(
            code = """# Type conversions
x::Int32 = 42

# Convert to Float64
y::Float64 = Float64(x)  # 42.0

# Convert to Int64
z::Int64 = Int64(x)      # 42

# Float to Int (truncates toward zero)
f = 3.7
i = Int32(f)             # 3 (not 4!)

# For rounding:
rounded = round(Int32, f) # 4""",
            description = "Adjust the integer value and see how it converts to different types.",
            example = TypeConversionDemo
        ),

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
                        "When converting from floats to integers, the decimal part is discarded (truncated toward zero). Use ",
                        Code(:class => "text-accent-600 dark:text-accent-400", "round()"),
                        ", ",
                        Code(:class => "text-accent-600 dark:text-accent-400", "floor()"),
                        ", or ",
                        Code(:class => "text-accent-600 dark:text-accent-400", "ceil()"),
                        " if you need different rounding behavior."
                    )
                )
            )
        ),

        # Section: Numeric Literals
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Numeric Literals"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Julia supports several formats for writing numeric literals in your code."
        ),

        LiveExample(
            code = """# Decimal literals (base 10)
a = 255        # Standard integer
b = 1_000_000  # Underscores for readability

# Hexadecimal literals (base 16)
c = 0xff       # = 255
d = 0xFF       # Case insensitive

# Binary literals (base 2)
e = 0b11111111 # = 255
f = 0b1010     # = 10

# Octal literals (base 8)
g = 0o377      # = 255

# Float literals
h = 3.14       # Float64 (double)
i = 3.14f0     # Float32 (single)
j = 1e6        # Scientific: 1000000.0
k = 2.5e-3     # Scientific: 0.0025""",
            description = "Click the buttons to see different literal formats and their decimal equivalents.",
            example = NumericLiteralsDemo
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
                        "WebAssembly natively supports four numeric types: ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "i32"),
                        ", ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "i64"),
                        ", ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "f32"),
                        ", and ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "f64"),
                        ". Julia's ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "Int128"),
                        " and ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "BigInt"),
                        " are not yet supported in WasmTarget.jl."
                    )
                )
            )
        ),

        # Summary
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Summary"
        ),

        Ul(:class => "list-disc list-inside space-y-2 text-warm-600 dark:text-warm-400 mb-6",
            Li(Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Int32"), " and ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Int64"), " for signed integers"),
            Li(Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Float32"), " and ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Float64"), " for floating-point numbers"),
            Li("Integer overflow wraps around silently - be mindful of value ranges"),
            Li("Use ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "div(a, b)"), " for integer division, ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "a % b"), " for remainder"),
            Li("Type constructors like ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Float64(x)"), " convert between types"),
            Li("Support for decimal, hex (", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "0x"), "), binary (", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "0b"), "), and scientific notation")
        ),

        # Next steps
        Div(:class => "p-6 bg-gradient-to-r from-warm-50 to-warm-100 dark:from-warm-900 dark:to-warm-950 rounded-xl border border-warm-200 dark:border-warm-700",
            H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-100 mb-2",
                "Next Steps"
            ),
            P(:class => "text-warm-600 dark:text-warm-400",
                "Now that you understand numeric types, continue to ",
                A(:href => "../math-operations/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Mathematical Operations"),
                " to learn about arithmetic, comparison, and bitwise operators, or go back to ",
                A(:href => "../variables/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Variables"),
                " to review the basics."
            )
        )
    )
end

# Export
IntegersFloats
