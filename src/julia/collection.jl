# What the ported wasm_builder calls from package:collection (dart-lang/core pkgs/collection at
# be0b1531, the SDK's DEPS core_rev), a dependency outside the pinned SDK: ported line for line,
# each function naming its source.

"""
    strongly_connected_components(graph) -> Vector{LinkedHashSet{T}}

The strongly connected components of `graph`, in topological order, by Tarjan's algorithm: every
vertex is a key of `graph`, its edges the key's set. package:collection's
`stronglyConnectedComponents` (pkgs/collection/lib/src/functions.dart:176), which wasm_builder's
types.dart:246 calls to form the rec groups.
"""
@quarantine "package:collection's stronglyConnectedComponents (dart-lang/core be0b1531 pkgs/collection/lib/src/functions.dart:176), which wasm_builder's types.dart:246 calls; a dependency outside the pinned SDK" Base.IdDict function strongly_connected_components(graph::LinkedHashMap{T,LinkedHashSet{T}})::Vector{LinkedHashSet{T}} where {T}
    index = 0
    stack = T[]
    result = LinkedHashSet{T}[]

    # The order of these does not matter (dart uses unlinked HashMap and HashSet).
    indices = IdDict{T,Int}()
    low_links = IdDict{T,Int}()
    on_stack = IdDict{T,Nothing}()

    function strong_connect(vertex::T)
        indices[vertex] = index
        low_links[vertex] = index
        index += 1

        push!(stack, vertex)
        on_stack[vertex] = nothing

        for successor in graph[vertex]
            if !haskey(indices, successor)
                strong_connect(successor)
                low_links[vertex] = min(low_links[vertex], low_links[successor])
            elseif haskey(on_stack, successor)
                low_links[vertex] = min(low_links[vertex], low_links[successor])
            end
        end

        if low_links[vertex] == indices[vertex]
            component = LinkedHashSet{T}()
            while true
                neighbor = pop!(stack)
                delete!(on_stack, neighbor)
                push!(component, neighbor)
                neighbor === vertex && break
            end
            push!(result, component)
        end
    end

    for (vertex, _) in graph
        haskey(indices, vertex) || strong_connect(vertex)
    end

    # Tarjan's algorithm produces a reverse topological sort; reversed, a topological sort.
    reverse(result)
end
