# A union-find over the integers from 0: dart2wasm's closures.dart imports vm's UnionFind
# (pkg/vm/lib/transformations/type_flow/utils.dart:359, outside the pin table's packages) to cluster
# the named parameters that occur together.
#
# precedent(dart: vm's UnionFind, union by weight with path compression; c++: boost's
# disjoint_sets). Julia's differs: Base has no disjoint sets (DataStructures.jl's IntDisjointSets is a
# package), and Julia's vectors count from 1 where the elements count from 0.

"""
    UnionFind()

Disjoint sets of the integers from 0, as vm's UnionFind keeps them: each element's entry is its
parent, or the negated size of its set for a root.
"""
@quarantine "dart2wasm imports vm's UnionFind; Julia's Base has no disjoint sets" Base.Vector struct UnionFind
    _elements::Vector{Int}
    UnionFind() = new(Vector{Int}())
end

"""    uf_add!(u) -> Int

Adds a new singleton set and returns its element (vm's `add`)."""
@quarantine "vm's UnionFind.add: a new singleton set, Julia's push!" Base.push! function uf_add!(u::UnionFind)::Int
    local id = length(u._elements)
    push!(u._elements, -1)
    return id
end

"""    uf_find!(u, id) -> Int

The canonical element of the set holding `id`, the path to it compressed (vm's `find`)."""
@quarantine "vm's UnionFind.find, its recursion written as two loops" Core.Int function uf_find!(u::UnionFind, id::Int)::Int
    local root = id
    while u._elements[root + 1] >= 0
        root = u._elements[root + 1]
    end
    while u._elements[id + 1] >= 0
        local parent = u._elements[id + 1]
        u._elements[id + 1] = root
        id = parent
    end
    return root
end

"""    uf_union!(u, id1, id2) -> Nothing

Merges the sets holding `id1` and `id2`, the heavier root the new one's (vm's `union`)."""
@quarantine "vm's UnionFind.union, by weight" Core.Int function uf_union!(u::UnionFind, id1::Int, id2::Int)::Nothing
    id1 = uf_find!(u, id1)
    id2 = uf_find!(u, id2)
    id1 == id2 && return nothing
    local w1 = u._elements[id1 + 1]
    local w2 = u._elements[id2 + 1]
    w1 < 0 && w2 < 0 || reject!(Internal("src/julia/union_find.jl uf_union!: a root of positive weight"), "UnionFind.union")
    if w1 < w2
        u._elements[id1 + 1] += w2
        u._elements[id2 + 1] = id1
    else
        u._elements[id2 + 1] += w1
        u._elements[id1 + 1] = id2
    end
    return nothing
end
