# Examples.jl - Playground example registry
#
# Central registry of all playground examples with:
# - Example metadata (id, name, category, description)
# - Julia source code for display
# - Reference to the pre-compiled island component for output
#
# Categories:
# - Numeric: arithmetic, factorial, fibonacci, sum operations
# - Control Flow: conditionals, sign function
# - Data Structures: (future) structs, arrays
# - UI Patterns: counter, toggles
#
# Story: PLAYGROUND-020, PLAYGROUND-021

"""
Example struct defining a playground example.
"""
struct PlaygroundExample
    id::String
    name::String
    category::String
    description::String
    code::String
end

"""
Get all playground examples grouped by category.
"""
const EXAMPLE_CATEGORIES = [
    "Numeric",
    "Control Flow",
    "UI Patterns"
]

"""
All available playground examples.
These correspond to pre-compiled islands in Demos.jl.
"""
const PLAYGROUND_EXAMPLES = [
    # =========================================================================
    # Numeric Examples
    # =========================================================================
    PlaygroundExample(
        "arithmetic",
        "Arithmetic Operations",
        "Numeric",
        "Demonstrates basic arithmetic operations (add, multiply, divide) compiled to WebAssembly.",
        """# Arithmetic Operations
# WasmTarget.jl compiles these to native Wasm instructions

a = 12
b = 5

# Addition
result_add = a + b  # → 17

# Multiplication
result_mul = a * b  # → 60

# Integer division
result_div = div(a, b)  # → 2

# Try changing the values and clicking the operation buttons!"""
    ),

    PlaygroundExample(
        "factorial",
        "Factorial (Recursion)",
        "Numeric",
        "Recursive factorial function showing WasmTarget.jl's support for recursive calls.",
        """# Recursive Factorial
# Demonstrates recursion compiled to WebAssembly

function factorial(n::Int32)::Int32
    if n <= Int32(1)
        return Int32(1)
    else
        return n * factorial(n - Int32(1))
    end
end

# Examples:
# factorial(0) → 1
# factorial(5) → 120
# factorial(6) → 720

# Click a number button to compute factorial!"""
    ),

    PlaygroundExample(
        "sum_to_n",
        "Sum 1 to N (Loop)",
        "Numeric",
        "While loop computing sum of integers, showing loop compilation to Wasm.",
        """# Sum of Integers from 1 to N
# Demonstrates while loops compiled to WebAssembly

function sum_to_n(n::Int32)::Int32
    result = Int32(0)
    i = Int32(1)
    while i <= n
        result = result + i
        i = i + Int32(1)
    end
    return result
end

# Mathematical formula: n * (n + 1) / 2
# sum_to_n(10) → 55
# sum_to_n(100) → 5050

# Adjust n with the +/- buttons and click Compute!"""
    ),

    # =========================================================================
    # Control Flow Examples
    # =========================================================================
    PlaygroundExample(
        "sign",
        "Sign Function (Conditionals)",
        "Control Flow",
        "If/elseif/else control flow compiled to WebAssembly branch instructions.",
        """# Sign Function
# Demonstrates if/elseif/else compiled to Wasm branches

function sign(n::Int32)::Int32
    if n > Int32(0)
        return Int32(1)
    elseif n < Int32(0)
        return Int32(-1)
    else
        return Int32(0)
    end
end

# sign(-5) → -1 (negative)
# sign(0)  → 0  (zero)
# sign(3)  → 1  (positive)

# Use +/- to change n, then click Compute sign(n)!"""
    ),

    # =========================================================================
    # UI Pattern Examples
    # =========================================================================
    PlaygroundExample(
        "counter",
        "Reactive Counter",
        "UI Patterns",
        "Interactive counter demonstrating Therapy.jl signals compiled to WebAssembly.",
        """# Reactive Counter with Signals
# Therapy.jl's reactivity compiled to WebAssembly

# Create a reactive signal
count, set_count = create_signal(Int32(0))

# Increment on click
Button(
    :on_click => () -> set_count(count() + Int32(1)),
    "Click: ", count()
)

# The count updates reactively when clicked!
# This is real Julia running as WebAssembly in your browser."""
    )
]

"""
Get examples for a specific category.
"""
function examples_by_category(category::String)
    filter(e -> e.category == category, PLAYGROUND_EXAMPLES)
end

"""
Get an example by its ID.
"""
function get_example(id::String)
    for example in PLAYGROUND_EXAMPLES
        if example.id == id
            return example
        end
    end
    return nothing
end

"""
Get the default example (first one).
"""
function default_example()
    return PLAYGROUND_EXAMPLES[1]
end

"""
Get all example IDs.
"""
function example_ids()
    return [e.id for e in PLAYGROUND_EXAMPLES]
end
