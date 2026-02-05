# Manual Chapter: Variables
#
# Interactive manual page covering Julia variables - naming, assignment, types.
# Based on docs.julialang.org/en/v1/manual/variables/
#
# Route: /manual/variables

# =============================================================================
# NOTE: This file uses pre-built islands from LiveExample.jl
# CounterDemo, SimpleValueDemo, and ArithmeticExampleDemo are already defined
# there and work correctly with SSR.
# =============================================================================

# =============================================================================
# Variables Chapter Page
# =============================================================================

"""
Variables chapter for the Interactive Julia Manual.
"""
function Variables()
    ManualLayout(chapter_id="variables", chapter_title="Variables",
        # Title
        H1(:class => "text-3xl font-bold text-warm-800 dark:text-warm-100 mb-4",
            "Variables"
        ),

        # Introduction
        P(:class => "text-lg text-warm-600 dark:text-warm-400 mb-8",
            "A variable is a name that refers to a value. Julia makes it easy to assign values to names and use them throughout your program. This chapter covers how to create, name, and use variables in Julia."
        ),

        # Section: Variable Assignment
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Assignment"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Use the ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "="),
            " operator to assign a value to a variable. The variable name goes on the left, and the value (or expression) goes on the right."
        ),

        LiveExample(
            code = """# Assign a value to a variable
x = 10

# Use the variable
y = x + 5  # y is now 15

# Reassign to update the value
x = x + 1  # x is now 11

# Variables can hold any value
count = 0
count = count + 1  # Increment: count is now 1""",
            description = "Variables can be assigned, reassigned, and used in expressions. Click Increment to update the count variable.",
            example = CounterDemo
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "Assignment in Julia is straightforward: the right-hand side is evaluated first, then the result is bound to the variable name on the left. When you write ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "y = x"),
            ", you're copying the ",
            Em("value"),
            " of ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "x"),
            " to ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "y"),
            ", not creating a link between them."
        ),

        # Section: Naming Conventions
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Naming Conventions"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Julia has flexible naming rules for variables. Names must start with a letter (A-Z or a-z), underscore (_), or a Unicode character above 0x00A0. After the first character, you can also use digits (0-9) and exclamation marks (!)."
        ),

        # Code example for naming (no interactive demo needed)
        Div(:class => "my-6 rounded-xl overflow-hidden border border-warm-200 dark:border-warm-700 shadow-sm",
            Div(:class => "px-4 py-2 bg-warm-700 dark:bg-warm-800 flex justify-between items-center",
                Span(:class => "text-warm-300 text-xs font-medium uppercase tracking-wider", "Julia"),
                Span(:class => "text-warm-500 text-xs", "Naming examples")
            ),
            Pre(:class => "bg-warm-800 dark:bg-warm-900 p-4 overflow-x-auto text-sm",
                Code(:class => "language-julia text-warm-100 font-mono", """# Valid variable names
x = 1
my_variable = 2
myVariable = 3          # camelCase works
MyVariable = 4          # PascalCase (often used for types)
_private = 5            # underscore prefix (convention for internal use)
x2 = 6                  # numbers allowed after first character
longer_name_here = 7    # snake_case is common for variables

# Convention: lowercase for variables and functions
count = 0
total_sum = 0
user_name = "Alice"

# Convention: UPPERCASE for constants
const PI_APPROX = 314
const MAX_SIZE = 1000""")
            )
        ),

        Div(:class => "p-4 bg-warm-50 dark:bg-warm-900/20 rounded-xl border border-warm-200 dark:border-warm-700 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-accent-600 dark:text-accent-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                ),
                Div(
                    P(:class => "text-sm text-warm-800 dark:text-warm-300 font-medium", "Style Tip"),
                    P(:class => "text-sm text-warm-700 dark:text-warm-400 mt-1",
                        "Julia convention uses ",
                        Code(:class => "text-accent-600 dark:text-accent-400", "snake_case"),
                        " for variables and functions, and ",
                        Code(:class => "text-accent-600 dark:text-accent-400", "PascalCase"),
                        " for types and modules. Following these conventions makes your code easier for others to read."
                    )
                )
            )
        ),

        # Section: Type Annotations
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Type Annotations"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "While Julia infers types automatically, you can explicitly annotate a variable's type using the ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "::"),
            " syntax. This is useful for performance and documentation."
        ),

        LiveExample(
            code = """# Explicit type annotation
x::Int32 = 100

# Type is enforced - value must be convertible
x = 255    # OK: integer fits in Int32

# Common types in WasmTarget.jl:
a::Int32 = 42       # 32-bit signed integer
b::Int64 = 100      # 64-bit signed integer
c::Float32 = 3.14f0 # 32-bit float
d::Float64 = 3.14   # 64-bit float
e::Bool = true      # boolean (true/false)""",
            description = "Type annotations declare what kind of value a variable holds. Use the buttons to adjust the value.",
            example = SimpleValueDemo
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "In WasmTarget.jl, type annotations are particularly important because they guide the compiler in generating efficient WebAssembly code. The supported primitive types are ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "Int32"),
            ", ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "Int64"),
            ", ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "Float32"),
            ", ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "Float64"),
            ", and ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "Bool"),
            "."
        ),

        # Section: Variables in Expressions
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Variables in Expressions"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Variables can be used in any expression. When Julia evaluates an expression, it looks up the current value of each variable and uses it in the computation."
        ),

        LiveExample(
            code = """# Define two variables
a = 10
b = 3

# Use them in expressions
sum = a + b      # 13
difference = a - b   # 7
product = a * b      # 30
quotient = a / b     # 3 (integer division)

# The result of an expression can be
# assigned to a new variable
result = a + b""",
            description = "Variables a and b can be used in arithmetic expressions. Click the operation buttons to compute different results.",
            example = ArithmeticExampleDemo
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
                        "WasmTarget.jl compiles Julia to WebAssembly, which has direct support for ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "i32"),
                        ", ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "i64"),
                        ", ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "f32"),
                        ", and ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "f64"),
                        " types. Using explicit type annotations helps the compiler generate optimal code."
                    )
                )
            )
        ),

        # Summary
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Summary"
        ),

        Ul(:class => "list-disc list-inside space-y-2 text-warm-600 dark:text-warm-400 mb-6",
            Li("Use ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "="), " to assign values to variables"),
            Li("Variable names should start with a letter or underscore"),
            Li("Follow Julia conventions: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "snake_case"), " for variables, ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "PascalCase"), " for types"),
            Li("Use ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "::Type"), " for explicit type annotations"),
            Li("WasmTarget.jl supports ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "Int32"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "Int64"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "Float32"), ", ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "Float64"), ", and ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "Bool"))
        ),

        # Next steps
        Div(:class => "p-6 bg-gradient-to-r from-warm-50 to-warm-100 dark:from-warm-900 dark:to-warm-950 rounded-xl border border-warm-200 dark:border-warm-700",
            H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-100 mb-2",
                "Next Steps"
            ),
            P(:class => "text-warm-600 dark:text-warm-400",
                "Now that you understand variables, continue to ",
                A(:href => "../integers-floats/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Integers & Floating-Point Numbers"),
                " to learn more about numeric types, or explore ",
                A(:href => "../math-operations/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Mathematical Operations"),
                " to see what you can do with these values."
            )
        )
    )
end

# Export
Variables
