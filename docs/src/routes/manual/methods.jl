# Manual Chapter: Methods (Multiple Dispatch)
#
# Interactive manual page covering Julia's multiple dispatch system -
# defining methods with the same function name but different type signatures.
# Based on docs.julialang.org/en/v1/manual/methods/
#
# Route: /manual/methods

# =============================================================================
# NOTE: This file uses pre-built islands from LiveExample.jl
# ShapeAreaDemo, ArithmeticDispatchDemo, and MethodSpecializationDemo
# are defined there and work correctly with SSR.
# =============================================================================

# =============================================================================
# Methods Chapter Page
# =============================================================================

"""
Methods chapter for the Interactive Julia Manual.
"""
function Methods()
    ManualLayout(chapter_id="methods", chapter_title="Methods (Multiple Dispatch)",
        # Title
        H1(:class => "text-3xl font-bold text-warm-800 dark:text-warm-100 mb-4",
            "Methods (Multiple Dispatch)"
        ),

        # Introduction
        P(:class => "text-lg text-warm-600 dark:text-warm-400 mb-8",
            "Multiple dispatch is one of Julia's most powerful features. It allows you to define ",
            Em("multiple methods"),
            " for the same function name, each specialized for different argument types. ",
            "Julia automatically selects the most appropriate method based on the types of all arguments."
        ),

        # Section: What is Multiple Dispatch?
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "What is Multiple Dispatch?"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "In Julia, a ",
            Em("function"),
            " is a named operation, while a ",
            Em("method"),
            " is a specific implementation of that function for particular argument types. ",
            "When you call a function, Julia looks at the types of ",
            Em("all"),
            " arguments to decide which method to run."
        ),

        Pre(:class => "bg-warm-800 dark:bg-warm-900 p-4 rounded-lg overflow-x-auto text-sm my-4",
            Code(:class => "language-julia text-warm-100 font-mono",
"""# One function name, multiple methods
function greet(x::String)
    return "Hello, " * x * "!"
end

function greet(x::Int32)
    return "You are number " * string(x)
end

# Julia dispatches based on argument type
greet("Julia")   # calls String method → "Hello, Julia!"
greet(Int32(42)) # calls Int32 method → "You are number 42\""""
            )
        ),

        # Tip about dispatch
        Div(:class => "p-4 bg-warm-50 dark:bg-warm-900/20 rounded-xl border border-warm-200 dark:border-warm-700 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-accent-600 dark:text-accent-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                ),
                Div(
                    P(:class => "text-sm text-warm-800 dark:text-warm-300 font-medium", "Compile-Time Dispatch"),
                    P(:class => "text-sm text-warm-700 dark:text-warm-400 mt-1",
                        "In WasmTarget.jl, dispatch is resolved at ",
                        Em("compile time"),
                        " because all types are known statically. This means there's no runtime overhead — ",
                        "the correct method is compiled directly into the WebAssembly output."
                    )
                )
            )
        ),

        # Section: Defining Methods for Custom Types
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Methods for Custom Types"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Multiple dispatch really shines when working with custom struct types. ",
            "You can define the same function name (like ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "area"),
            ") for different shapes, and Julia will call the right implementation."
        ),

        LiveExample(
            code = """# Define shape types
struct Circle
    radius::Int32
end

struct Rectangle
    width::Int32
    height::Int32
end

# Define area() for each shape
function area(c::Circle)::Int32
    return Int32(3) * c.radius * c.radius  # Approximation
end

function area(r::Rectangle)::Int32
    return r.width * r.height
end

# Julia dispatches to the correct method
circle = Circle(Int32(5))
rect = Rectangle(Int32(4), Int32(6))

area(circle)  # calls Circle method → 75
area(rect)    # calls Rectangle method → 24""",
            description = "Click different shapes to calculate their area using multiple dispatch.",
            example = ShapeAreaDemo
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "This pattern is fundamental to Julia programming. Instead of using ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "if/else"),
            " to check types, you define specialized methods and let dispatch handle it."
        ),

        # Section: Arithmetic on Custom Types
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Arithmetic on Custom Types"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "You can extend arithmetic operations to work with your own types. ",
            "In Julia, operators like ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "+"),
            " are just functions, so you can add methods for them."
        ),

        LiveExample(
            code = """# A 2D vector type
struct Vec2
    x::Int32
    y::Int32
end

# Define addition for Vec2
function add_vec(a::Vec2, b::Vec2)::Vec2
    return Vec2(a.x + b.x, a.y + b.y)
end

# Define scalar multiplication
function scale_vec(v::Vec2, s::Int32)::Vec2
    return Vec2(v.x * s, v.y * s)
end

# Use the operations
v1 = Vec2(Int32(3), Int32(4))
v2 = Vec2(Int32(1), Int32(2))

add_vec(v1, v2)       # Vec2(4, 6)
scale_vec(v1, Int32(2)) # Vec2(6, 8)""",
            description = "Perform vector arithmetic using methods specialized for Vec2.",
            example = VectorArithmeticDemo
        ),

        # Note about operators
        Div(:class => "p-4 bg-amber-50 dark:bg-amber-900/20 rounded-xl border border-amber-200 dark:border-amber-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-amber-600 dark:text-amber-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z")
                ),
                Div(
                    P(:class => "text-sm text-amber-800 dark:text-amber-200 font-medium", "Operator Overloading"),
                    P(:class => "text-sm text-amber-700 dark:text-amber-300 mt-1",
                        "In full Julia, you can extend ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "Base.+"),
                        " and other operators directly. In WasmTarget.jl, we use named functions like ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "add_vec"),
                        " instead, which compile more reliably to WebAssembly."
                    )
                )
            )
        ),

        # Section: Type Specialization
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Type Specialization"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Methods can be specialized to very specific types. ",
            "Julia will always choose the ",
            Em("most specific"),
            " method that matches the argument types."
        ),

        LiveExample(
            code = """# Generic method (fallback)
function describe(x)
    return "some value"
end

# Specialized for Int32
function describe(x::Int32)
    if x > Int32(0)
        return "positive integer"
    elseif x < Int32(0)
        return "negative integer"
    else
        return "zero"
    end
end

# Specialized for Bool
function describe(x::Bool)
    if x
        return "true boolean"
    else
        return "false boolean"
    end
end

# Julia picks the most specific method
describe(Int32(42))   # "positive integer"
describe(Int32(-5))   # "negative integer"
describe(true)        # "true boolean\"""",
            description = "Enter different types of values to see which method gets called.",
            example = TypeSpecializationDemo
        ),

        # Section: Methods with Multiple Arguments
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Multi-Argument Dispatch"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Multiple dispatch considers ",
            Em("all"),
            " argument types, not just the first one. This enables powerful patterns that are difficult to express in single-dispatch languages."
        ),

        Pre(:class => "bg-warm-800 dark:bg-warm-900 p-4 rounded-lg overflow-x-auto text-sm my-4",
            Code(:class => "language-julia text-warm-100 font-mono",
"""# Different methods for different combinations
function combine(a::Int32, b::Int32)::Int32
    return a + b  # Add numbers
end

function combine(a::Int32, b::Bool)::Int32
    if b
        return a * Int32(2)  # Double if true
    else
        return a             # Identity if false
    end
end

function combine(a::Bool, b::Int32)::Int32
    if a
        return -b   # Negate if true
    else
        return b    # Identity if false
    end
end

# Each combination calls a different method
combine(Int32(5), Int32(3))    # 8 (add)
combine(Int32(5), true)        # 10 (double)
combine(true, Int32(5))        # -5 (negate)"""
            )
        ),

        # Section: Method Ambiguity
        Div(:class => "p-4 bg-warm-100 dark:bg-warm-900 rounded-xl border border-warm-200 dark:border-warm-700 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-warm-500 dark:text-warm-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z")
                ),
                Div(
                    P(:class => "text-sm text-warm-700 dark:text-warm-300 font-medium", "About Method Ambiguity"),
                    P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-1",
                        "If Julia can't determine a single most-specific method (an ",
                        Em("ambiguity"),
                        "), it will raise an error at compile time. This helps catch design issues early. ",
                        "To resolve ambiguities, add a more specific method for the conflicting type combination."
                    )
                )
            )
        ),

        # Summary
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Summary"
        ),

        Ul(:class => "list-disc list-inside space-y-2 text-warm-600 dark:text-warm-400 mb-6",
            Li("A ", Em("function"), " is a name; a ", Em("method"), " is an implementation for specific types"),
            Li("Define methods by adding type annotations: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "function f(x::Type)")),
            Li("Julia dispatches based on the types of ", Em("all"), " arguments (multiple dispatch)"),
            Li("In WasmTarget.jl, dispatch happens at compile time for zero runtime overhead"),
            Li("Use specialized methods for custom structs like ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "area(c::Circle)"))
        ),

        # WasmTarget note
        Div(:class => "p-4 bg-warm-50 dark:bg-warm-900/20 rounded-xl border border-warm-200 dark:border-warm-700 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-accent-600 dark:text-accent-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                ),
                Div(
                    P(:class => "text-sm text-warm-800 dark:text-warm-300 font-medium", "WasmTarget.jl Dispatch"),
                    P(:class => "text-sm text-warm-700 dark:text-warm-400 mt-1",
                        "WasmTarget.jl compiles methods with known concrete types. Dynamic dispatch (where types are unknown until runtime) is not yet supported. ",
                        "For best results, ensure all types are known at compile time."
                    )
                )
            )
        ),

        # Next steps
        Div(:class => "p-6 bg-gradient-to-r from-warm-50 to-warm-100 dark:from-warm-900 dark:to-warm-950 rounded-xl border border-warm-200 dark:border-warm-700",
            H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-100 mb-2",
                "Next Steps"
            ),
            P(:class => "text-warm-600 dark:text-warm-400",
                "Now that you understand multiple dispatch, continue to ",
                A(:href => "../arrays/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Arrays"),
                " to learn about collections, or revisit ",
                A(:href => "../types/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Types (Structs)"),
                " to create more custom types for your methods to operate on."
            )
        )
    )
end

# Export
Methods
