# A tuple whose length only run time knows, Core.tuple(v...) for a Vector v (Core._apply_iterate(iterate, Core.tuple,
# v), julia/src/builtins.c:661 jl_f__apply_iterate then :946 jl_f_tuple): its arity's record where the program's world
# has one (Julia's type cache's hit), else the one array class (the miss). The miss cases build tuples of an arity no
# concrete tuple type of the program has (collect and fill, never a vect literal of that length, no isa against an
# NTuple of it), so they reach the array class; the hit cases an arity a literal or a tested NTuple brings.
@noinline _rlts_mk(v::Vector{Int64}) = Core.tuple(v...)
@noinline _rlts_mks(v::Vector{String}) = Core.tuple(v...)
@noinline _rlts_mka(v::Vector{Any}) = Core.tuple(v...)
@noinline _rlts_cat(n::Int64, v::Vector{Int64}) = (n, v...)
@noinline _rlts_mat(m::Matrix{Int64}) = Core.tuple(m...)
_g("runtime_length_tuple", Any[
    # the hit: the NTuple{7,Int64} an isa tests is a class of the world, which brings its arity's record
    ("splat_hit_isa_ntuple", (n::Int64) -> _rlts_mk(collect(1:n)) isa NTuple{7,Int64} ? 1 : 2, Int64(7)),
    # the miss: no concrete 7-, 9- or 12-tuple type anywhere in these programs
    ("splat_miss_nfields", (n::Int64) -> nfields(_rlts_mk(collect(1:n))), Int64(9)),
    ("splat_empty_nfields", (n::Int64) -> nfields(_rlts_mk(collect(1:n))) + 1, Int64(0)),
    ("splat_miss_index", (n::Int64) -> _rlts_mk(collect(1:n))[n - 1], Int64(7)),
    ("splat_miss_index_bounds", (n::Int64) -> (try; _rlts_mk(collect(1:n))[n + 1]; 0; catch e; e isa BoundsError ? 1 : 2; end), Int64(7)),
    ("splat_miss_egal_same", (n::Int64) -> _rlts_mk(collect(1:n)) === _rlts_mk(collect(1:n)) ? 1 : 2, Int64(7)),
    ("splat_miss_egal_other", (n::Int64) -> _rlts_mk(collect(1:n)) === _rlts_mk(collect(2:n + 1)) ? 1 : 2, Int64(7)),
    ("splat_miss_isa_least_length", (n::Int64) -> _rlts_mk(collect(1:n)) isa Tuple{Int64,Int64,Vararg{Int64}} ? 1 : 2, Int64(7)),
    # a hit: every world holds the record of 1 element
    ("splat_hit_short_isa_least_length", (n::Int64) -> _rlts_mk(collect(1:n)) isa Tuple{Int64,Int64,Vararg{Int64}} ? 1 : 2, Int64(1)),
    ("splat_hit_erased_isa", (n::Int64) -> Any[_rlts_mk(collect(1:n))][1] isa NTuple{7,Int64} ? 1 : 2, Int64(7)),
    # a 3-tuple literal brings its record, so the splat's tuple of 3 is that record, === the literal's
    ("splat_hit_egal_literal", (n::Int64) -> _rlts_mk(fill(n, 3)) === (n, n, n) ? 1 : 2, Int64(3)),
    # each element by its own class, `nothing` among them
    ("splat_heterogeneous_isa", (n::Int64) -> _rlts_mka(Any[n, "a", 2.5, nothing]) isa Tuple{Int64,String,Float64,Nothing} ? 1 : 2, Int64(3)),
    # the buffer's fill reads each element: an unset one raises UndefRefError (builtins.c:820-823); the tuple is used,
    # so Julia keeps the splat
    ("splat_unset_element_throws", (n::Int64) -> (v = Vector{String}(undef, n); v[1] = "a"; v[2] = "b"; try; nfields(_rlts_mks(v)); catch e; e isa UndefRefError ? -1 : -2; end), Int64(7)),
    ("splat_unset_any_element_throws", (n::Int64) -> (v = Vector{Any}(undef, n); v[1] = 1; try; nfields(_rlts_mka(v)); catch e; e isa UndefRefError ? -1 : -2; end), Int64(11)),
    # Base's callers of the same statement, several segments and an Array of two dimensions
    ("splat_base_tuple_of_vector", (n::Int64) -> Tuple(collect(1:n))[end], Int64(12)),
    ("splat_base_ntuple", (n::Int64) -> ntuple(i -> i, n)[end], Int64(12)),
    ("splat_two_segments", (n::Int64) -> _rlts_cat(n, collect(1:n))[end] + nfields(_rlts_cat(n, collect(1:n))), Int64(7)),
    ("splat_matrix", (n::Int64) -> _rlts_mat(reshape(collect(1:2n), n, 2))[end], Int64(5)),
])
