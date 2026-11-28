# Which arities the closed world's records cover, read by every site that asks (src/class_info.jl
# ClassIdNumbering.covered_arities): jl_f_tuple's splat picks its arity's record or the array class, an
# open tuple slot holds the records of the arities it admits, and an is check tests each covered arity's
# record field by field. A tuple a splat
# makes must be the class every other reader takes it for.
@noinline _cra_mk(v::Vector{Int64}) = Core.tuple(v...)
@noinline _cra_mka(v::Vector{Any}) = Core.tuple(v...)
struct _CraBox
    t::Tuple
end
@noinline _cra_open(@nospecialize(t::Tuple)) = _CraBox(t)
@noinline _cra_isa3(@nospecialize(x)) = x isa NTuple{3,Int64}
@noinline _cra_isa_least2(@nospecialize(x)) = x isa Tuple{Int64,Int64,Vararg{Int64}}
_g("runtime_length_tuple", Any[
    # a covered arity (3, the NTuple an is check names): the splat's record is the one the check tests
    ("covered_arities_splat_isa", (n::Int64) -> _cra_isa3(_cra_mk(collect(1:n))) ? 1 : 2, Int64(3)),
    # the same record through an open tuple slot (a field typed Tuple), then tested
    ("covered_arities_open_slot_isa", (n::Int64) -> _cra_isa3(_cra_open(_cra_mk(collect(1:n))).t) ? 1 : 2, Int64(3)),
    # an arity at least 2, the splat's record of a covered arity tested by the open shape's every arity
    ("covered_arities_least_length", (n::Int64) -> _cra_isa_least2(_cra_mk(collect(1:n))) ? 1 : 2, Int64(3)),
    # a splat of mixed elements to a covered arity (1, which every world holds), tested by its element's type
    ("covered_arities_any_splat_isa", (n::Int64) -> _cra_mka(Any[n]) isa Tuple{Int64} ? 3 : 4, Int64(2)),
    # an arity no record covers: the array class, through the open slot, its length read back
    ("covered_arities_uncovered_open_slot", (n::Int64) -> nfields(_cra_open(_cra_mk(collect(1:n))).t), Int64(7)),
    ("covered_arities_uncovered_index", (n::Int64) -> _cra_open(_cra_mk(collect(1:n))).t[n], Int64(9)),
])
