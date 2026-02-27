# Manual Chapter: Arrays
#
# Manual page covering Julia arrays - vectors (1D arrays),
# multi-dimensional arrays (matrices), indexing, and iteration.
# Based on docs.julialang.org/en/v1/manual/arrays/
#
# Route: /manual/arrays

# =============================================================================
# Arrays Chapter Page
# =============================================================================

import Suite

"""
Arrays chapter for the Julia Manual.
"""
function Arrays()
    ManualLayout(chapter_id="arrays", chapter_title="Arrays",
        # Title
        H1(:class => "text-3xl font-bold text-warm-800 dark:text-warm-100 mb-4",
            "Arrays"
        ),

        # Introduction
        P(:class => "text-lg text-warm-600 dark:text-warm-400 mb-8",
            "Arrays are fundamental data structures in Julia for storing collections of values. ",
            "A ",
            Em("Vector"),
            " is a 1-dimensional array, while a ",
            Em("Matrix"),
            " is a 2-dimensional array. Julia arrays are 1-indexed, meaning the first element is at index 1."
        ),

        # Section: Creating Vectors
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Creating Vectors"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "A ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Vector"),
            " (also called a 1D array) stores an ordered sequence of elements. ",
            "You can create vectors using square bracket notation or the ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Vector{T}(...)"),
            " constructor."
        ),

        Suite.CodeBlock("""# Create a vector using brackets
arr = [10, 20, 30, 40]

# Access elements (1-indexed!)
arr[1]    # returns 10 (first element)
arr[2]    # returns 20
arr[4]    # returns 40 (last element)

# Get the length
length(arr)  # returns 4

# Create with explicit type
typed_arr = Int32[1, 2, 3, 4, 5]""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Click on array elements to select them. Adjust the selected element's value with +/- buttons."
        ),

        # Tip about 1-indexing
        Suite.Alert(class="my-6",
            Suite.AlertTitle("1-Based Indexing"),
            Suite.AlertDescription(
                "Unlike C, Python, or JavaScript, Julia arrays start at index 1, not 0. ",
                "This matches mathematical notation and is natural for many scientific applications."
            )
        ),

        # Section: Vector Mutation
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Vector Mutation"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Arrays in Julia are mutable by default - you can change individual elements after creation. ",
            "Use indexed assignment to modify elements: ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "arr[i] = new_value"),
            "."
        ),

        Suite.CodeBlock("""# Create a mutable vector
arr = [1, 2, 3, 4, 5]

# Modify elements by index
arr[1] = 100    # arr is now [100, 2, 3, 4, 5]
arr[3] = 300    # arr is now [100, 2, 300, 4, 5]

# Read modified values
arr[1]   # returns 100
arr[3]   # returns 300

# You can also modify based on computation
arr[2] = arr[1] + arr[3]  # arr[2] = 100 + 300 = 400""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Click an index button to select a position, then use Set to modify the value at that position."
        ),

        # WasmTarget note about arrays
        Suite.Alert(class="my-6",
            Suite.AlertTitle("Fixed-Size Arrays in WasmTarget.jl"),
            Suite.AlertDescription(
                "WasmTarget.jl currently supports fixed-size arrays. Dynamic operations like ",
                Code(:class => "text-amber-800 dark:text-amber-200", "push!"),
                " and ",
                Code(:class => "text-amber-800 dark:text-amber-200", "pop!"),
                " are not yet supported. Create arrays with the size you need upfront."
            )
        ),

        # Section: Multi-dimensional Arrays (Matrices)
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Multi-dimensional Arrays (Matrices)"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "A ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "Matrix"),
            " is a 2-dimensional array. Create matrices using spaces to separate columns and semicolons (or newlines) to separate rows. ",
            "Access elements with two indices: ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "matrix[row, col]"),
            "."
        ),

        Suite.CodeBlock("""# Create a 3x3 matrix
# Spaces separate columns, semicolons separate rows
mat = [1 2 3; 4 5 6; 7 8 9]

# Access elements with [row, col]
mat[1, 1]  # top-left: 1
mat[1, 3]  # top-right: 3
mat[2, 2]  # center: 5
mat[3, 1]  # bottom-left: 7

# Get dimensions
size(mat)      # returns (3, 3)
size(mat, 1)   # rows: 3
size(mat, 2)   # cols: 3""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Click on matrix cells to see their row,col coordinates and value."
        ),

        P(:class => "text-warm-600 dark:text-warm-400 my-4",
            "The first index is always the row, and the second is the column. ",
            "This column-major ordering is important for performance when iterating over arrays."
        ),

        # Section: Iterating Over Arrays
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Iterating Over Arrays"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Use ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "for"),
            " loops to iterate over array elements. You can iterate by element or by index."
        ),

        Suite.CodeBlock("""# Iterate by element
arr = [10, 20, 30, 40]
sum = 0
for x in arr
    sum = sum + x
end
sum  # returns 100

# Iterate by index
for i in 1:length(arr)
    arr[i]  # access each element
end

# Sum function
function sum_array(arr)
    total = 0
    for x in arr
        total = total + x
    end
    return total
end""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Click Step to iterate through the array one element at a time, watching the sum accumulate."
        ),

        Suite.CodeBlock("""# Find the maximum element
function find_max(arr)
    max_val = arr[1]  # Start with first element
    for i in 2:length(arr)
        if arr[i] > max_val
            max_val = arr[i]
        end
    end
    return max_val
end

# Count occurrences
function count_value(arr, target)
    count = 0
    for x in arr
        if x == target
            count = count + 1
        end
    end
    return count
end""", language="julia"),

        # Section: Computing with Arrays
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Computing with Arrays"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Arrays are ideal for storing and processing collections of numerical data. ",
            "Common operations include computing sums, averages, and finding min/max values."
        ),

        Suite.CodeBlock("""# Compute sum and average
arr = [10, 20, 30, 40, 50]

function compute_sum(arr)
    total = 0
    for x in arr
        total = total + x
    end
    return total
end

function compute_avg(arr)
    return compute_sum(arr) / length(arr)
end

compute_sum(arr)  # returns 150
compute_avg(arr)  # returns 30""", language="julia"),

        P(:class => "text-sm text-warm-600 dark:text-warm-400 mt-3",
            "Adjust array values to see the sum and average update in real-time."
        ),

        # Section: Bounds Checking
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Bounds Checking"
        ),

        P(:class => "text-warm-600 dark:text-warm-400 mb-4",
            "Julia performs bounds checking by default to prevent accessing invalid array indices. ",
            "Attempting to access an index outside the valid range (1 to length) will throw a ",
            Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "BoundsError"),
            "."
        ),

        Suite.CodeBlock("""arr = [1, 2, 3, 4, 5]

# Valid indices: 1 to 5
arr[1]  # OK: first element
arr[5]  # OK: last element

# Invalid indices throw BoundsError
# arr[0]  # ERROR: index 0 is out of bounds
# arr[6]  # ERROR: index 6 is out of bounds

# Use @inbounds to disable bounds checking (use carefully!)
function fast_sum(arr)
    total = 0
    for i in 1:length(arr)
        @inbounds total = total + arr[i]
    end
    return total
end""", language="julia"),

        Suite.Alert(class="my-6",
            Suite.AlertTitle("Use @inbounds with Care"),
            Suite.AlertDescription(
                "The ",
                Code(:class => "text-amber-800 dark:text-amber-200", "@inbounds"),
                " macro disables bounds checking for performance. Only use it when you're absolutely certain your indices are valid, ",
                "as out-of-bounds access with @inbounds causes undefined behavior."
            )
        ),

        # Summary
        H2(:class => "text-2xl font-semibold text-warm-800 dark:text-warm-100 mt-10 mb-4",
            "Summary"
        ),

        Ul(:class => "list-disc list-inside space-y-2 text-warm-600 dark:text-warm-400 mb-6",
            Li("Vectors are 1D arrays created with ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "[a, b, c]")),
            Li("Julia arrays are 1-indexed: first element is ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "arr[1]")),
            Li("Matrices are 2D arrays: access with ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "mat[row, col]")),
            Li("Arrays are mutable: modify with ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "arr[i] = value")),
            Li("Use ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "length(arr)"), " for 1D and ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "size(mat)"), " for dimensions"),
            Li("Iterate with ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "for x in arr"), " or ", Code(:class => "text-accent-600 dark:text-accent-400 bg-warm-100 dark:bg-warm-900 px-1.5 py-0.5 rounded", "for i in 1:length(arr)"))
        ),

        # Scope note
        Suite.Alert(class="my-6",
            Suite.AlertTitle("Beyond This Chapter"),
            Suite.AlertDescription(
                "Julia also supports ",
                Em("comprehensions"),
                " (like ",
                Code(:class => "text-accent-600 dark:text-accent-400", "[x^2 for x in 1:10]"),
                "), ",
                Em("broadcasting"),
                " (like ",
                Code(:class => "text-accent-600 dark:text-accent-400", "arr .+ 1"),
                "), and resizable arrays. These advanced features have varying support in WasmTarget.jl."
            )
        ),

        # Next steps
        Div(:class => "p-6 bg-gradient-to-r from-warm-50 to-warm-100 dark:from-warm-900 dark:to-warm-950 rounded-xl border border-warm-200 dark:border-warm-700",
            H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-100 mb-2",
                "Next Steps"
            ),
            P(:class => "text-warm-600 dark:text-warm-400",
                "Now that you understand arrays, continue to ",
                A(:href => "../tuples/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Tuples"),
                " to learn about fixed-size, heterogeneous collections, or revisit ",
                A(:href => "../control-flow/",
                  :class => "text-accent-600 dark:text-accent-400 font-medium hover:underline",
                  "Control Flow"),
                " to see more loop patterns for array processing."
            )
        )
    )
end

# Export
Arrays
