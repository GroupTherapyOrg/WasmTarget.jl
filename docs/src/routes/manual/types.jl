# Manual Chapter: Types (Structs)
#
# Manual page covering Julia types - primitive types,
# composite types (struct), mutable structs, and field access.
# Based on docs.julialang.org/en/v1/manual/types/
#
# Route: /manual/types

# =============================================================================
# Types Chapter Page
# =============================================================================

import Suite

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
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "struct"),
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

        Suite.CodeBlock("""# Integer types
x::Int32 = 42        # 32-bit signed integer
y::Int64 = 1000000   # 64-bit signed integer (default Int)

# Floating-point types
pi_approx::Float32 = 3.14f0   # 32-bit float
e_approx::Float64 = 2.71828   # 64-bit float (default)

# Boolean
flag::Bool = true    # true or false

# Type checking
typeof(x)    # returns Int32
typeof(flag) # returns Bool""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Julia's primitive types map directly to WebAssembly types. Click a type to see its range and example value."
        ),

        # Tip about WasmTarget types
        Suite.Alert(class="my-6",
            Suite.AlertTitle("WasmTarget.jl Type Mapping"),
            Suite.AlertDescription(
                "Int32 → i32, Int64 → i64, Float32 → f32, Float64 → f64, Bool → i32 (0 or 1). ",
                "These types compile directly to WebAssembly's native number types for optimal performance."
            )
        ),

        # Section: Composite Types (Structs)
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Composite Types (Structs)"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "A ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "struct"),
            " defines a new composite type with named fields. By default, structs are ",
            Em("immutable"),
            " — their fields cannot be changed after creation."
        ),

        Suite.CodeBlock("""# Define an immutable struct
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
p.x * p.y  # returns 200""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "A 2D Point struct with x and y coordinates. Adjust the field values to see computed results."
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "Structs can have any number of fields, and each field can have a type annotation. ",
            "If no type is specified, the field can hold any value (though explicit types are recommended for WasmTarget.jl)."
        ),

        # Immutability note
        Suite.Alert(class="my-6",
            Suite.AlertTitle("Immutable by Default"),
            Suite.AlertDescription(
                "Regular ",
                Code(:class => "text-amber-800 dark:text-amber-200", "struct"),
                "s are immutable. Attempting to modify a field like ",
                Code(:class => "text-amber-800 dark:text-amber-200", "p.x = 5"),
                " will result in an error. Use ",
                Code(:class => "text-amber-800 dark:text-amber-200", "mutable struct"),
                " if you need to modify fields."
            )
        ),

        # Section: Mutable Structs
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Mutable Structs"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "When you need to modify fields after creation, use ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "mutable struct"),
            ". Mutable structs allow field reassignment, making them useful for objects that change over time."
        ),

        Suite.CodeBlock("""# Define a mutable struct
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
c.count = 0""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "A mutable Counter struct. Click buttons to increment the count or reset it."
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
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "line.start_pt.x"),
            " traverse through the nested structure."
        ),

        Suite.CodeBlock("""# Define nested structs
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
len_sq = dx * dx + dy * dy  # 200""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "A Line struct containing two Point structs. Adjust the endpoints to see the computed delta and length²."
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

        Suite.CodeBlock("""# Default constructor (automatically created)
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
            throw(ArgumentError("radius must be positive"))
        end
        new(r)
    end
end

# Outer constructor (convenience)
Circle() = Circle(Int32(1))  # Default radius of 1""", language="julia"),

        # WasmTarget note about constructors
        Suite.Alert(class="my-6",
            Suite.AlertTitle("WasmTarget.jl Constructor Note"),
            Suite.AlertDescription(
                "WasmTarget.jl supports basic constructors. Complex inner constructors with validation may have limitations. ",
                "For best results, use the default constructor with explicit field types."
            )
        ),

        # Summary
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Summary"
        ),

        Ul(:class => "list-disc list-inside space-y-2 text-warm-600 dark:text-warm-400 mb-6",
            Li("Primitive types (Int32, Float64, Bool) map directly to WebAssembly types"),
            Li("Define composite types with ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "struct Name ... end")),
            Li("Regular structs are immutable — fields cannot be changed after creation"),
            Li("Use ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "mutable struct"), " when fields need to be modified"),
            Li("Structs can contain other structs as fields (nested structs)"),
            Li("Access fields with dot notation: ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "instance.field_name"))
        ),

        # Scope note
        Suite.Alert(class="my-6",
            Suite.AlertTitle("Beyond This Chapter"),
            Suite.AlertDescription(
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
        ),

        # Next steps
        Div(:class => "p-6 bg-gradient-to-r from-warm-50 to-warm-100 dark:from-warm-900 dark:to-warm-950 rounded-xl border border-warm-200 dark:border-warm-700",
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
