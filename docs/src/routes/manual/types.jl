# Manual Chapter: Types (Structs)
#
# Interactive manual page covering Julia types - primitive types,
# composite types (struct), mutable structs, and field access.
# Based on docs.julialang.org/en/v1/manual/types/
#
# Route: /manual/types

# =============================================================================
# NOTE: This file uses pre-built islands from LiveExample.jl
# PrimitiveTypesDemo, StructDemo, MutableStructDemo, and NestedStructDemo
# are already defined there and work correctly with SSR.
# =============================================================================

# =============================================================================
# Types Chapter Page
# =============================================================================

"""
Types chapter for the Interactive Julia Manual.
"""
function Types()
    ManualLayout(chapter_id="types", chapter_title="Types (Structs)",
        # Title
        H1(:class => "text-3xl font-bold text-warm-800 dark:text-warm-100 mb-4",
            "Types (Structs)"
        ),

        # Introduction
        P(:class => "text-lg text-warm-600 dark:text-warm-400 mb-8",
            "Julia's type system allows you to define custom data types that group related data together. ",
            "These ",
            Em("composite types"),
            " (called ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "struct"),
            "s) are the foundation for organizing data in Julia programs."
        ),

        # Section: Primitive Types
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Primitive Types"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Julia provides several built-in primitive types for representing basic values like numbers and booleans. ",
            "In WasmTarget.jl, these map directly to WebAssembly's native types."
        ),

        LiveExample(
            code = """# Integer types
x::Int32 = 42        # 32-bit signed integer
y::Int64 = 1000000   # 64-bit signed integer (default Int)

# Floating-point types
pi_approx::Float32 = 3.14f0   # 32-bit float
e_approx::Float64 = 2.71828   # 64-bit float (default)

# Boolean
flag::Bool = true    # true or false

# Type checking
typeof(x)    # returns Int32
typeof(flag) # returns Bool""",
            description = "Julia's primitive types map directly to WebAssembly types. Click a type to see its range and example value.",
            example = PrimitiveTypesDemo
        ),

        # Tip about WasmTarget types
        Div(:class => "p-4 bg-accent-50 dark:bg-accent-900/20 rounded-xl border border-accent-200 dark:border-accent-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-accent-600 dark:text-accent-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                ),
                Div(
                    P(:class => "text-sm text-accent-800 dark:text-accent-200 font-medium", "WasmTarget.jl Type Mapping"),
                    P(:class => "text-sm text-accent-700 dark:text-accent-300 mt-1",
                        "Int32 → i32, Int64 → i64, Float32 → f32, Float64 → f64, Bool → i32 (0 or 1). ",
                        "These types compile directly to WebAssembly's native number types for optimal performance."
                    )
                )
            )
        ),

        # Section: Composite Types (Structs)
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Composite Types (Structs)"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "A ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "struct"),
            " defines a new composite type with named fields. By default, structs are ",
            Em("immutable"),
            " — their fields cannot be changed after creation."
        ),

        LiveExample(
            code = """# Define an immutable struct
struct Point
    x::Int32
    y::Int32
end

# Create an instance
p = Point(10, 20)

# Access fields
p.x  # returns 10
p.y  # returns 20

# Compute with fields
p.x + p.y  # returns 30
p.x * p.y  # returns 200""",
            description = "A 2D Point struct with x and y coordinates. Adjust the field values to see computed results.",
            example = StructDemo
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "Structs can have any number of fields, and each field can have a type annotation. ",
            "If no type is specified, the field can hold any value (though explicit types are recommended for WasmTarget.jl)."
        ),

        # Immutability note
        Div(:class => "p-4 bg-amber-50 dark:bg-amber-900/20 rounded-xl border border-amber-200 dark:border-amber-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-amber-600 dark:text-amber-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z")
                ),
                Div(
                    P(:class => "text-sm text-amber-800 dark:text-amber-200 font-medium", "Immutable by Default"),
                    P(:class => "text-sm text-amber-700 dark:text-amber-300 mt-1",
                        "Regular ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "struct"),
                        "s are immutable. Attempting to modify a field like ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "p.x = 5"),
                        " will result in an error. Use ",
                        Code(:class => "text-amber-800 dark:text-amber-200", "mutable struct"),
                        " if you need to modify fields."
                    )
                )
            )
        ),

        # Section: Mutable Structs
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Mutable Structs"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "When you need to modify fields after creation, use ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "mutable struct"),
            ". Mutable structs allow field reassignment, making them useful for objects that change over time."
        ),

        LiveExample(
            code = """# Define a mutable struct
mutable struct Counter
    count::Int32
    step::Int32
end

# Create an instance
c = Counter(0, 1)

# Read fields
c.count  # returns 0
c.step   # returns 1

# Modify fields (only works for mutable structs!)
c.count = c.count + c.step
c.count  # now returns 1

# Reset the counter
c.count = 0""",
            description = "A mutable Counter struct. Click buttons to increment the count or reset it.",
            example = MutableStructDemo
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "Use mutable structs sparingly — immutable structs are generally more efficient and easier to reason about. ",
            "Choose mutable structs when the object genuinely represents changing state."
        ),

        # Section: Nested Structs
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Nested Structs"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Structs can contain other structs as fields, allowing you to build complex data structures. ",
            "Field access chains like ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "line.start_pt.x"),
            " traverse through the nested structure."
        ),

        LiveExample(
            code = """# Define nested structs
struct Point
    x::Int32
    y::Int32
end

struct Line
    start_pt::Point
    end_pt::Point
end

# Create instances
p1 = Point(0, 0)
p2 = Point(10, 10)
line = Line(p1, p2)

# Access nested fields
line.start_pt.x   # returns 0
line.end_pt.x     # returns 10

# Compute delta
dx = line.end_pt.x - line.start_pt.x  # 10
dy = line.end_pt.y - line.start_pt.y  # 10

# Length squared (avoids sqrt)
len_sq = dx * dx + dy * dy  # 200""",
            description = "A Line struct containing two Point structs. Adjust the endpoints to see the computed delta and length².",
            example = NestedStructDemo
        ),

        # Section: Constructors
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Constructors"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "When you define a struct, Julia automatically creates a ",
            Em("default constructor"),
            " that takes arguments in field order. You can also define custom constructors for more flexibility."
        ),

        Pre(:class => "bg-warm-800 dark:bg-warm-900 p-4 rounded-lg overflow-x-auto text-sm my-4",
            Code(:class => "language-julia text-warm-100 font-mono",
"""# Default constructor (automatically created)
struct Rectangle
    width::Int32
    height::Int32
end

# Use the default constructor
r = Rectangle(10, 20)

# You can add custom constructors (inner constructors)
struct Circle
    radius::Int32

    # Custom constructor with validation
    function Circle(r::Int32)
        if r <= Int32(0)
            throw(ArgumentError(\"radius must be positive\"))
        end
        new(r)
    end
end

# Outer constructor (convenience)
Circle() = Circle(Int32(1))  # Default radius of 1"""
            )
        ),

        # WasmTarget note about constructors
        Div(:class => "p-4 bg-amber-50 dark:bg-amber-900/20 rounded-xl border border-amber-200 dark:border-amber-800 my-6",
            Div(:class => "flex items-start gap-3",
                Svg(:class => "w-5 h-5 text-amber-600 dark:text-amber-400 flex-shrink-0 mt-0.5",
                    :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z")
                ),
                Div(
                    P(:class => "text-sm text-amber-800 dark:text-amber-200 font-medium", "WasmTarget.jl Constructor Note"),
                    P(:class => "text-sm text-amber-700 dark:text-amber-300 mt-1",
                        "WasmTarget.jl supports basic constructors. Complex inner constructors with validation may have limitations. ",
                        "For best results, use the default constructor with explicit field types."
                    )
                )
            )
        ),

        # Summary
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Summary"
        ),

        Ul(:class => "list-disc list-inside space-y-2 text-warm-600 dark:text-warm-400 mb-6",
            Li("Primitive types (Int32, Float64, Bool) map directly to WebAssembly types"),
            Li("Define composite types with ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "struct Name ... end")),
            Li("Regular structs are immutable — fields cannot be changed after creation"),
            Li("Use ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "mutable struct"), " when fields need to be modified"),
            Li("Structs can contain other structs as fields (nested structs)"),
            Li("Access fields with dot notation: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-800 px-1.5 py-0.5 rounded", "instance.field_name"))
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
                    P(:class => "text-sm text-warm-700 dark:text-warm-300 font-medium", "Beyond This Chapter"),
                    P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-1",
                        "Julia also supports ",
                        Em("abstract types"),
                        " and ",
                        Em("parametric types"),
                        " (like ",
                        Code(:class => "text-warm-600 dark:text-warm-400", "Vector{T}"),
                        "). These advanced features have limited support in WasmTarget.jl — see the ",
                        A(:href => "./features/",
                          :class => "text-accent-600 dark:text-accent-400 hover:underline",
                          "Features page"),
                        " for current support status."
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
                "Now that you understand types and structs, continue to ",
                A(:href => "../methods/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Methods (Multiple Dispatch)"),
                " to learn how to define functions that behave differently for different types, or explore ",
                A(:href => "../arrays/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Arrays"),
                " to see how to work with collections of values."
            )
        )
    )
end

# Export
Types
