# A constant of a 128-bit primitive type of its own (Julia's i128, two i64 halves like Int128's): its
# halves split off its bits (LLVM's ExpandIntRes_Constant) where a phi merges it with a run-time value,
# where an Any vector boxes it, and where flipsign_int reads it
primitive type _WpP128 128 end
_wp_k() = Core.bitcast(_WpP128, Int128(-7))
_wp_read(x::_WpP128) = (c = Core.bitcast(Int128, x); Int64(c >> 64) * 1000 + (c % Int64))
_g("numerics", Any[
    ("p128_const_phi", (n::Int64) -> _wp_read(n > 0 ? _wp_k() : Core.bitcast(_WpP128, Int128(n))), Int64(3)),
    ("p128_const_boxed", (n::Int64) -> (v = Any[_wp_k(), n]; _wp_read(v[1]::_WpP128) + v[2]::Int64), Int64(3)),
    ("p128_flipsign_const", (n::Int64) -> _wp_read(Core.Intrinsics.flipsign_int(_wp_k(), Core.bitcast(_WpP128, Int128(-n)))) +
                                          _wp_read(Core.Intrinsics.flipsign_int(Core.bitcast(_WpP128, Int128(n)), _wp_k())), Int64(3)),
])
