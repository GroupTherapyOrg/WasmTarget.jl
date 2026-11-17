# typeof of a nested tuple record held as an Any (src/record_class_generator.jl
# _generate_record_runtime_type_helper, dart's record_class_generator.dart:653 _generateRecordRuntimeType): each level
# of the chain T_k = Tuple{T_{k-1},T_{k-1}} is answered through its record class's _recordRuntimeType, a nested field's
# type that record's own call. Each case answers a code for the exact type typeof gave, among the chain's types of
# its depth and the one below, Int64 leaves and Float64 leaves, so a wrong level, leaf or miss reads wrong.
mutable struct _TrcSlot
    x::Any
end
@noinline _trc_dup(x) = (x, x)
@noinline _trc_c1(x) = _trc_dup(x)
@noinline _trc_c2(x) = _trc_dup(_trc_c1(x))
@noinline _trc_c3(x) = _trc_dup(_trc_c2(x))
@noinline _trc_c4(x) = _trc_dup(_trc_c3(x))
@noinline _trc_c5(x) = _trc_dup(_trc_c4(x))
@noinline _trc_c6(x) = _trc_dup(_trc_c5(x))
@noinline _trc_c7(x) = _trc_dup(_trc_c6(x))
@noinline _trc_c8(x) = _trc_dup(_trc_c7(x))
const _TRC_I1 = Tuple{Int64,Int64}
const _TRC_I2 = Tuple{_TRC_I1,_TRC_I1}
const _TRC_I3 = Tuple{_TRC_I2,_TRC_I2}
const _TRC_I4 = Tuple{_TRC_I3,_TRC_I3}
const _TRC_I5 = Tuple{_TRC_I4,_TRC_I4}
const _TRC_I6 = Tuple{_TRC_I5,_TRC_I5}
const _TRC_I7 = Tuple{_TRC_I6,_TRC_I6}
const _TRC_I8 = Tuple{_TRC_I7,_TRC_I7}
const _TRC_F1 = Tuple{Float64,Float64}
const _TRC_F2 = Tuple{_TRC_F1,_TRC_F1}
const _TRC_F3 = Tuple{_TRC_F2,_TRC_F2}
const _TRC_F4 = Tuple{_TRC_F3,_TRC_F3}
const _TRC_F5 = Tuple{_TRC_F4,_TRC_F4}
const _TRC_F6 = Tuple{_TRC_F5,_TRC_F5}
const _TRC_F7 = Tuple{_TRC_F6,_TRC_F6}
const _TRC_F8 = Tuple{_TRC_F7,_TRC_F7}
# the chain of depth 2: n picks its Int64 chain, its Float64 chain, the depth-1 Int64 chain or n itself
@noinline _trc_pick2(n::Int64) = _TrcSlot(n == 1 ? _trc_c2(n) : n == 2 ? _trc_c2(Float64(n)) : n == 3 ? _trc_c1(n) : n)
_trc_code2(n::Int64) = (T = typeof(_trc_pick2(n).x);
                        T === _TRC_I2 ? 1 : T === _TRC_F2 ? 2 : T === _TRC_I1 ? 3 : T === Int64 ? 4 : T === Memory{UInt8} ? 99 : 0)
@noinline _trc_pick4(n::Int64) = _TrcSlot(n == 1 ? _trc_c4(n) : n == 2 ? _trc_c4(Float64(n)) : n == 3 ? _trc_c3(n) : n)
_trc_code4(n::Int64) = (T = typeof(_trc_pick4(n).x);
                        T === _TRC_I4 ? 1 : T === _TRC_F4 ? 2 : T === _TRC_I3 ? 3 : T === Int64 ? 4 : T === Memory{UInt8} ? 99 : 0)
@noinline _trc_pick8(n::Int64) = _TrcSlot(n == 1 ? _trc_c8(n) : n == 2 ? _trc_c8(Float64(n)) : n == 3 ? _trc_c7(n) : n)
_trc_code8(n::Int64) = (T = typeof(_trc_pick8(n).x);
                        T === _TRC_I8 ? 1 : T === _TRC_F8 ? 2 : T === _TRC_I7 ? 3 : T === Int64 ? 4 : T === Memory{UInt8} ? 99 : 0)
_g("tuple_runtime_types", Any[
    ("record_chain2_int", (n::Int64) -> _trc_code2(n), Int64(1)),
    ("record_chain2_float", (n::Int64) -> _trc_code2(n), Int64(2)),
    ("record_chain2_below", (n::Int64) -> _trc_code2(n), Int64(3)),
    ("record_chain4_int", (n::Int64) -> _trc_code4(n), Int64(1)),
    ("record_chain4_float", (n::Int64) -> _trc_code4(n), Int64(2)),
    ("record_chain4_below", (n::Int64) -> _trc_code4(n), Int64(3)),
    ("record_chain8_int", (n::Int64) -> _trc_code8(n), Int64(1)),
    ("record_chain8_float", (n::Int64) -> _trc_code8(n), Int64(2)),
    ("record_chain8_below", (n::Int64) -> _trc_code8(n), Int64(3)),
])
