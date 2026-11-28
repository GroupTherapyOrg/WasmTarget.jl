# A memory builtin on a reference held as Any is Julia's runtime builtin (builtins.c:1781
# jl_f_memoryrefget, :1806 jl_f_memoryrefset): a value that is no reference raises TypeError
# (JL_TYPECHK), a reference is read and written by its own type, an Int64 element stored in place
# and an unset String element unassigned
_g("memoryref_barrier", Any[
    ("memoryrefget_erased_not_ref", (n::Int64) -> (x = Base.inferencebarrier(n); try; Core.memoryrefget(x, :not_atomic, true); 0; catch e; e isa TypeError ? 1 : 2; end), Int64(3)),
    ("memoryrefset_erased_int", (n::Int64) -> (v = [1, 2]; r = Base.inferencebarrier(Core.memoryrefnew(v.ref.mem)); Core.memoryrefset!(r, n, :not_atomic, true); v[1] + v[2]), Int64(3)),
    # `nothing` is no reference either: the TypeError, never a trap at the top type's null
    ("memoryrefget_erased_nothing", (n::Int64) -> (x = Base.inferencebarrier(n > 2 ? nothing : n); try; Core.memoryrefget(x, :not_atomic, true); 0; catch e; e isa TypeError ? 1 : 2; end), Int64(3)),
    ("memoryref_isassigned_erased", (n::Int64) -> (v = Vector{String}(undef, n); r = Base.inferencebarrier(Core.memoryrefnew(v.ref.mem)); Core.memoryref_isassigned(r, :not_atomic, true) ? 1 : 2), Int64(3)),
])
