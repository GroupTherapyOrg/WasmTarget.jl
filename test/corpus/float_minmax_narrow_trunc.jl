# Julia's min_float and max_float (llvm.minimum and llvm.maximum: a NaN operand gives NaN, -0.0 is
# below 0.0), and fptosi and fptoui of a float into an integer narrower than 32 bits (unsafe_trunc),
# each at values the integer holds
_g("numerics", Any[
    ("min_float_signed_zero", (x::Float64) -> min(x, -x), 0.0),
    ("max_float_signed_zero", (x::Float64) -> max(-x, x), 0.0),
    ("max_float_nan", (x::Float64) -> isnan(max(x, (x - x) * Inf)) ? Int64(1) : Int64(2), 2.0),
    ("min_max_float32", (x::Float32) -> min(x, 2.5f0) * max(x, -1f0), 1.5f0),
    ("fptoui_uint8", (x::Float64) -> Int64(unsafe_trunc(UInt8, x)), 200.75),
    ("fptosi_int8", (x::Float64) -> Int64(unsafe_trunc(Int8, x)), -100.5),
    ("fptosi_int16_f32", (x::Float32) -> Int64(unsafe_trunc(Int16, x)), -30000.5f0),
    ("fptoui_uint16_f32", (x::Float32) -> Int64(unsafe_trunc(UInt16, x)), 65000.25f0),
])
