# ============================================================================
# C6 soundness suspects — executed evidence for the 2026-09-22 read-only audit.
#
# Each suspect is one or more ordinary Julia functions compared native-vs-wasm with
# `compare_julia_wasm`. Every variant is classified:
#   WRONG   compiles, runs, returns a different value than native
#   TRAP    compiles, traps at runtime
#   LOUD    compilation rejects (correct behavior)
#   OK      native and wasm agree
# A suspect's line reports its worst variant: CONFIRMED-WRONG > CONFIRMED-TRAP > LOUD > REFUTED.
# Results are Int64-encoded so `==` cannot hide a sign of zero, a Bool/Int mixup, or a type.
#
# Run:   julia --project=. test/soundness_suspects.jl [suspect numbers...]
# Exit:  always 0 — this is an evidence lane, not a gate.
# ============================================================================
using WasmTarget
include(joinpath(@__DIR__, "utils.jl"))

const SUSPECTS = Vector{Tuple{Int,String,Vector{Any}}}()
_s(n, title, cases) = push!(SUSPECTS, (n, title, cases))

# A value whose static type is Any: indexing a Vector{Any} at a runtime index.
@noinline _anyat(v::Vector{Any}, i::Int64) = v[i]

# ---- 1 mixed-width egal ------------------------------------------------------
s1_static(x::Int32) = Int64(x === Int64(x))
s1_any(i::Int64) = (v = Any[Int32(1), Int64(1), UInt8(1), true]; Int64(_anyat(v, i) === _anyat(v, i + 1)))
s1_any_i32_u8(i::Int64) = (v = Any[Int32(1), UInt8(1)]; Int64(_anyat(v, i) === _anyat(v, i + 1)))
s1_any_bool_int(i::Int64) = (v = Any[true, Int64(1)]; Int64(_anyat(v, i) === _anyat(v, i + 1)))
# Measured: inference folds the static spelling to `return 0` (disjoint concrete types), and the
# Any spellings lower to `ref.eq` on two distinct boxes, which is right here only by accident
# (see suspect 4, two boxes of the same Int64). The mixed-width arm at calls.jl:1708 is not reached.
_s(1, "Int32(1) === Int64(1)", Any[
    ("static", s1_static, Int32(1)),
    ("any_i32_i64", s1_any, Int64(1)),
    ("any_i64_u8", s1_any, Int64(2)),
    ("any_u8_bool", s1_any, Int64(3)),
    ("any_i32_u8", s1_any_i32_u8, Int64(1)),
    ("any_bool_i64", s1_any_bool_int, Int64(1)),
])

# ---- 2 float egal ------------------------------------------------------------
s2_f64(x::Float64, y::Float64) = Int64(x === y)
s2_f32(x::Float32, y::Float32) = Int64(x === y)
s2_payload(x::Float64) = Int64(x === reinterpret(Float64, reinterpret(UInt64, x) | 0x1))
s2_any(i::Int64) = (v = Any[NaN, NaN, 0.0, -0.0]; Int64(_anyat(v, i) === _anyat(v, i + 1)))
s2_isequal(x::Float64, y::Float64) = Int64(isequal(x, y))
_s(2, "NaN === NaN, 0.0 === -0.0", Any[
    ("f64_nan", s2_f64, NaN, NaN),
    ("f64_zero_negzero", s2_f64, 0.0, -0.0),
    ("f32_nan", s2_f32, NaN32, NaN32),
    ("f32_zero_negzero", s2_f32, 0.0f0, -0.0f0),
    ("f64_nan_payload", s2_payload, NaN),
    ("any_nan_nan", s2_any, Int64(1)),
    ("any_zero_negzero", s2_any, Int64(3)),
    ("isequal_zero_negzero", s2_isequal, 0.0, -0.0),
])

# ---- 3 isa through Any ---------------------------------------------------------
const _S3V = Any[UInt8(3), Int64(5), "a", :a, 2.5]
s3_signed(i::Int64) = Int64(_anyat(_S3V, i) isa Signed)
s3_unsigned(i::Int64) = Int64(_anyat(_S3V, i) isa Unsigned)
s3_isint64(i::Int64) = Int64(_anyat(_S3V, i) isa Int64)
s3_isstring(i::Int64) = Int64(_anyat(_S3V, i) isa String)
s3_issymbol(i::Int64) = Int64(_anyat(_S3V, i) isa Symbol)
s3_typeof_symbol(i::Int64) = Int64(typeof(_anyat(_S3V, i)) === Symbol)
s3_typeof_string(i::Int64) = Int64(typeof(_anyat(_S3V, i)) === String)
_s(3, "isa / typeof through Any (UInt8, String, Symbol)", Any[
    ("u8_isa_Signed", s3_signed, Int64(1)),
    ("u8_isa_Unsigned", s3_unsigned, Int64(1)),
    ("u8_isa_Int64", s3_isint64, Int64(1)),
    ("f64_isa_Int64", s3_isint64, Int64(5)),
    ("str_isa_Symbol", s3_issymbol, Int64(3)),
    ("sym_isa_Symbol", s3_issymbol, Int64(4)),
    ("sym_isa_String", s3_isstring, Int64(4)),
    ("str_isa_String", s3_isstring, Int64(3)),
    ("typeof_sym_is_Symbol", s3_typeof_symbol, Int64(4)),
    ("typeof_str_is_Symbol", s3_typeof_symbol, Int64(3)),
    ("typeof_sym_is_String", s3_typeof_string, Int64(4)),
])

# ---- 4 String vs Symbol egal; !== boxed number vs ref ---------------------------
const _S4V = Any["a", :a, Int64(1), "x", :a]
s4_egal(i::Int64, j::Int64) = Int64(_anyat(_S4V, i) === _anyat(_S4V, j))
s4_boxes(x::Int64) = (v = Any[x, x + 0]; Int64(_anyat(v, 1) === _anyat(v, 2)))
s4_strs(x::Int64) = (v = Any["ab", string('a', Char(x))]; Int64(_anyat(v, 1) === _anyat(v, 2)))
s4_notegal(i::Int64, j::Int64) = Int64(_anyat(_S4V, i) !== _anyat(_S4V, j))
_s(4, "\"a\" === :a; !== boxed number vs ref", Any[
    ("str_egal_sym", s4_egal, Int64(1), Int64(2)),
    ("sym_egal_sym", s4_egal, Int64(2), Int64(5)),
    ("num_notegal_str", s4_notegal, Int64(3), Int64(4)),
    ("num_notegal_num", s4_notegal, Int64(3), Int64(3)),
    ("str_notegal_str", s4_notegal, Int64(1), Int64(1)),
    ("num_egal_num_two_boxes", s4_boxes, Int64(7)),
    ("str_egal_str_two_objects", s4_strs, Int64(98)),
])

# ---- 5 === nothing on a Union field ---------------------------------------------
struct S5; f::Union{Nothing,Int64}; end
@noinline _s5mk(x::Int64) = S5(x > 0 ? x : nothing)
s5_field(x::Int64) = Int64(_s5mk(x).f === nothing)
s5_field_ne(x::Int64) = Int64(_s5mk(x).f !== nothing)
s5_any(i::Int64) = (v = Any[Int64(0), nothing]; Int64(_anyat(v, i) === nothing))
_s(5, "Int64 === nothing / x !== nothing on a Union field", Any[
    ("field_int_is_nothing", s5_field, Int64(3)),
    ("field_nothing_is_nothing", s5_field, Int64(-3)),
    ("field_int_isnot_nothing", s5_field_ne, Int64(3)),
    ("field_nothing_isnot_nothing", s5_field_ne, Int64(-3)),
    ("any_int_is_nothing", s5_any, Int64(1)),
    ("any_nothing_is_nothing", s5_any, Int64(2)),
])

# ---- 6 const mutable globals: one identity per module ----------------------------
# Every case restores the global before returning, so the native run leaves the
# snapshot the compiler embeds unchanged and a rebuilt-per-use constant reads 0 / -1.
const G6V = Int64[0, 0, 0]
const G6D = Dict{Int64,Int64}()
mutable struct M6; v::Int64; end
const G6M = M6(0)
@noinline _g6v_read() = G6V[1]
@noinline _g6v_bump!() = (G6V[1] += 1; nothing)
@noinline _g6d_read() = get(G6D, 1, -1)
@noinline _g6m_read() = G6M.v
s6_vec_inline(x::Int64) = (G6V[1] = x; r = G6V[1]; G6V[1] = 0; r)
s6_vec_noinline(x::Int64) = (G6V[1] = x; _g6v_bump!(); r = _g6v_read(); G6V[1] = 0; r)
s6_dict(x::Int64) = (G6D[1] = x; r = _g6d_read(); delete!(G6D, 1); r)
s6_mstruct(x::Int64) = (G6M.v = x; r = _g6m_read(); G6M.v = 0; r)
_s(6, "const mutable global mutated at one site, read at another", Any[
    ("vec_inline", s6_vec_inline, Int64(7)),
    ("vec_noinline", s6_vec_noinline, Int64(7)),
    ("dict", s6_dict, Int64(7)),
    ("mutable_struct", s6_mstruct, Int64(7)),
])

# ---- 7 length of non-ASCII String ---------------------------------------------------
@noinline _s7str(x::Int64) = x > 0 ? "héllo" : "abc"
s7_const() = length("é")
s7_runtime(x::Int64) = length(_s7str(x))
s7_built(x::Int64) = length(string('é', 'λ', Char(x)))
s7_concat(x::Int64) = length(_s7str(x) * "λ")
_s(7, "length of a non-ASCII String", Any[
    ("const_e_acute", s7_const),
    ("runtime_hello", s7_runtime, Int64(1)),
    ("built_from_chars", s7_built, Int64(0x3bb)),
    ("concat", s7_concat, Int64(1)),
])

# ---- 8 nextind / thisind / iterate over multibyte chars --------------------------------
s8_nextind(i::Int64) = nextind(_s7str(Int64(1)), i)
s8_thisind(i::Int64) = thisind(_s7str(Int64(1)), i)
s8_iter(x::Int64) = (c = 0; for ch in _s7str(x); c += 1; end; c)
s8_iter_codes(x::Int64) = (c = 0; for ch in _s7str(x); c = c * 7 + Int64(UInt32(ch)); end; c)
s8_prevind(i::Int64) = prevind(_s7str(Int64(1)), i)
_s(8, "nextind / thisind / iterate multibyte String", Any[
    ("nextind_2", s8_nextind, Int64(2)),
    ("thisind_3", s8_thisind, Int64(3)),
    ("prevind_4", s8_prevind, Int64(4)),
    ("iterate_count", s8_iter, Int64(1)),
    ("iterate_codepoints", s8_iter_codes, Int64(1)),
])

# ---- 9 SubString -------------------------------------------------------------------
s9_ncu(j::Int64) = ncodeunits(SubString(_s7str(Int64(1)), 2, j))
s9_len(j::Int64) = length(SubString(_s7str(Int64(1)), 2, j))
s9_invalid(j::Int64) = try; ncodeunits(SubString(_s7str(Int64(1)), 2, j)); catch e; e isa StringIndexError ? -1 : -2; end
s9_char(j::Int64) = Int64(UInt32(SubString(_s7str(Int64(1)), 2, j)[1]))
_s(9, "SubString of a multibyte String", Any[
    ("invalid_end_2_3_throws", s9_invalid, Int64(3)),
    ("ncodeunits_2_4", s9_ncu, Int64(4)),
    ("length_2_4", s9_len, Int64(4)),
    ("first_char_2_4", s9_char, Int64(4)),
])

# ---- 10 first(s, n) non-ASCII; Char predicates / case mapping beyond Latin-1 --------------
s10_first_ncu(n::Int64) = ncodeunits(first(_s7str(Int64(1)), n))
s10_first_len(n::Int64) = length(first(_s7str(Int64(1)), n))
s10_last_ncu(n::Int64) = ncodeunits(last(_s7str(Int64(1)), n))
s10_isletter(c::Char) = Int64(isletter(c))
s10_upper(c::Char) = Int64(UInt32(uppercase(c)))
s10_lower(c::Char) = Int64(UInt32(lowercase(c)))
s10_isupper(c::Char) = Int64(isuppercase(c))
_s(10, "first(s,n) non-ASCII; Char predicates/case beyond Latin-1", Any[
    ("first_2_ncodeunits", s10_first_ncu, Int64(2)),
    ("first_2_length", s10_first_len, Int64(2)),
    ("last_4_ncodeunits", s10_last_ncu, Int64(4)),
    ("isletter_lambda", s10_isletter, 'λ'),
    ("isletter_cjk", s10_isletter, '中'),
    ("uppercase_sharp_s", s10_upper, 'ß'),
    ("uppercase_lambda", s10_upper, 'λ'),
    ("lowercase_Sigma", s10_lower, 'Σ'),
    ("isuppercase_Sigma", s10_isupper, 'Σ'),
])

# ---- 11 strip / chomp return SubString -----------------------------------------------
@noinline _s11str(x::Int64) = x > 0 ? "  héllo \n" : "abc\n"
s11_strip_type(x::Int64) = Int64(typeof(strip(_s11str(x))) === SubString{String})
s11_strip_offset(x::Int64) = strip(_s11str(x)).offset
s11_chomp_offset(x::Int64) = chomp(_s11str(x)).offset + ncodeunits(chomp(_s11str(x)))
s11_strip_ncu(x::Int64) = ncodeunits(strip(_s11str(x)))
_s(11, "strip/chomp return SubString", Any[
    ("strip_typeof", s11_strip_type, Int64(1)),
    ("strip_offset", s11_strip_offset, Int64(1)),
    ("chomp_offset_ncu", s11_chomp_offset, Int64(1)),
    ("strip_ncodeunits", s11_strip_ncu, Int64(1)),
])

# ---- 12 fill! --------------------------------------------------------------------
s12_u8(x::Int64) = (v = zeros(UInt8, 5); fill!(v, UInt8(x)); Int64(sum(Int64, v)) * 1000 + Int64(v[3]))
s12_u8_wide(x::Int64) = (v = zeros(UInt8, 5); fill!(v, x % UInt8); Int64(sum(Int64, v)))
s12_zero(x::Int64) = (v = collect(1:x); fill!(v, 0); sum(v) + length(v))
s12_i64(x::Int64) = (v = zeros(Int64, 4); fill!(v, x); sum(v))
s12_i32(x::Int64) = (v = zeros(Int32, 4); fill!(v, Int32(x)); Int64(sum(v)))
_s(12, "fill! with a runtime value", Any[
    ("u8_runtime", s12_u8, Int64(7)),
    ("u8_runtime_big", s12_u8, Int64(200)),
    ("u8_wrapped", s12_u8_wide, Int64(0x1ff)),
    ("zero_on_data", s12_zero, Int64(5)),
    ("i64_runtime", s12_i64, Int64(-9)),
    ("i32_runtime", s12_i32, Int64(-9)),
])

# ---- 13 sizeof(Vector), length(Matrix) --------------------------------------------------
s13_sizeof_vec(n::Int64) = sizeof(Vector{Int64}(undef, n))
s13_sizeof_vec_f32(n::Int64) = sizeof(zeros(Float32, n))
s13_length_mat(n::Int64) = length(zeros(n, n + 2))
s13_size_mat(n::Int64) = (m = zeros(n, n + 2); size(m, 1) * 100 + size(m, 2))
s13_sizeof_mat(n::Int64) = sizeof(zeros(n, n + 2))
_s(13, "sizeof(Vector{Int64}); length(Matrix)", Any[
    ("sizeof_vec_i64", s13_sizeof_vec, Int64(5)),
    ("sizeof_vec_f32", s13_sizeof_vec_f32, Int64(5)),
    ("length_matrix", s13_length_mat, Int64(3)),
    ("size_matrix", s13_size_mat, Int64(3)),
    ("sizeof_matrix", s13_sizeof_mat, Int64(3)),
])

# ---- 14 unalias / overlapping copies ------------------------------------------------------
_s14enc(v) = (r = 0; for x in v; r = r * 10 + x; end; r)
s14_copyto_self(n::Int64) = (v = collect(1:n); copyto!(v, 2, v, 1, n - 1); _s14enc(v))
s14_copyto_self_back(n::Int64) = (v = collect(1:n); copyto!(v, 1, v, 2, n - 1); _s14enc(v))
s14_view_overlap(n::Int64) = (v = collect(1:n); copyto!(view(v, 2:n), view(v, 1:n-1)); _s14enc(v))
s14_bcast_rev(n::Int64) = (v = collect(1:n); v .= @view v[end:-1:1]; _s14enc(v))
s14_bcast_rev_copy(n::Int64) = (v = collect(1:n); v .= v[end:-1:1]; _s14enc(v))
_s(14, "unalias / overlapping copyto! and broadcast", Any[
    ("copyto_self_fwd", s14_copyto_self, Int64(5)),
    ("copyto_self_back", s14_copyto_self_back, Int64(5)),
    ("copyto_view_overlap", s14_view_overlap, Int64(5)),
    ("bcast_reverse_view", s14_bcast_rev, Int64(5)),
    ("bcast_reverse_copy", s14_bcast_rev_copy, Int64(5)),
])

# ---- 15 memoryrefoffset from a runtime ref ---------------------------------------------
s15_direct(i::Int64) = (m = Memory{Int64}(undef, 10); r = Core.memoryrefnew(Core.memoryrefnew(m), i, false); Base.memoryrefoffset(r))
s15_popfirst(n::Int64) = (v = collect(1:n); popfirst!(v); popfirst!(v); Base.memoryrefoffset(v.ref))
s15_growbeg(n::Int64) = (v = collect(1:n); popfirst!(v); popfirst!(v); pushfirst!(v, 100); pushfirst!(v, 200); _s14enc(v) + length(v.ref.mem) * 1_000_000_000)
s15_growend(n::Int64) = (v = collect(1:n); popfirst!(v); for k in 1:20; push!(v, k); end; sum(v) * 100 + length(v))
_s(15, "memoryrefoffset of a runtime MemoryRef", Any[
    ("direct_offset", s15_direct, Int64(4)),
    ("after_popfirst", s15_popfirst, Int64(5)),
    ("growbeg_reuses_front", s15_growbeg, Int64(5)),
    ("growend_after_popfirst", s15_growend, Int64(5)),
])

# ---- 16 overlay-covered array ops -----------------------------------------------------
s16_sortperm(x::Int64) = _s14enc(sortperm([3, x, 1, 2]))
s16_max_unsigned(x::Int64) = Int64(maximum(UInt64[0x1, x % UInt64, 0x7]) % Int64)
s16_max_u8(x::Int64) = Int64(maximum(UInt8[0x1, x % UInt8, 0x7]))
s16_matadd(x::Int64) = (a = [1 2; 3 4] .* x; b = [10 20; 30 40]; c = a + b; c[1, 2] * 10000 + c[2, 1] * 100 + c[2, 2])
s16_copymat(x::Int64) = (a = [1 2; 3 x]; c = copy(a); a[2, 2] = 0; c[2, 2] * 100 + c[1, 2] * 10 + length(c))
s16_firstlast(x::Int64) = (v = [x, 2, 3, x + 10]; first(v) * 100 + last(v))
_s(16, "sortperm, maximum(unsigned), Matrix+Matrix, copy(Matrix), first/last", Any[
    ("sortperm", s16_sortperm, Int64(4)),
    ("maximum_u64_high_bit", s16_max_unsigned, Int64(-1)),
    ("maximum_u8", s16_max_u8, Int64(200)),
    ("matrix_add", s16_matadd, Int64(2)),
    ("copy_matrix", s16_copymat, Int64(9)),
    ("first_last", s16_firstlast, Int64(5)),
])

# ---- 17 bswap on narrow ints --------------------------------------------------------------
s17_u16(x::Int64) = Int64(bswap(x % UInt16))
s17_i16(x::Int64) = Int64(bswap(x % Int16))
s17_i8(x::Int64) = Int64(bswap(x % Int8))
s17_u32(x::Int64) = Int64(bswap(x % UInt32))
_s(17, "bswap(UInt16/Int16/Int8)", Any[
    ("u16", s17_u16, Int64(0x1234)),
    ("i16", s17_i16, Int64(0x12f4)),
    ("i8", s17_i8, Int64(-3)),
    ("u32", s17_u32, Int64(0x12345678)),
])

# ---- 18 mod / rem sign of zero -------------------------------------------------------------
_enc_f(y) = Int64(signbit(y)) * 1000 + Int64(round(y * 10))
s18_mod64(x::Float64, y::Float64) = _enc_f(mod(x, y))
s18_rem64(x::Float64, y::Float64) = _enc_f(rem(x, y))
s18_mod32(x::Float32, y::Float32) = _enc_f(Float64(mod(x, y)))
s18_rem32(x::Float32, y::Float32) = _enc_f(Float64(rem(x, y)))
_s(18, "mod/rem sign of zero, Float32", Any[
    ("mod_m3_3", s18_mod64, -3.0, 3.0),
    ("mod_3_m3", s18_mod64, 3.0, -3.0),
    ("mod_m1_3", s18_mod64, -1.0, 3.0),
    ("rem_m3_3", s18_rem64, -3.0, 3.0),
    ("mod32_m3_3", s18_mod32, -3.0f0, 3.0f0),
    ("mod32_3_m3", s18_mod32, 3.0f0, -3.0f0),
    ("rem32_m7_2", s18_rem32, -7.5f0, 2.0f0),
])

# ---- 19 fma single rounding -------------------------------------------------------------------
s19_fma(a::Float64, b::Float64, c::Float64) = reinterpret(Int64, fma(a, b, c))
s19_muladd(a::Float64, b::Float64, c::Float64) = reinterpret(Int64, a * b + c)
s19_fma32(a::Float32, b::Float32, c::Float32) = Int64(reinterpret(Int32, fma(a, b, c)))
_s(19, "fma(a,b,c) single rounding", Any[
    ("fma_f64", s19_fma, 0.1, 10.0, -1.0),
    ("mul_add_f64_control", s19_muladd, 0.1, 10.0, -1.0),
    ("fma_f32", s19_fma32, 0.1f0, 10.0f0, -1.0f0),
])

# ---- 20 Int128 sign extension of narrow negatives -----------------------------------------
s20_i8(x::Int64) = Int64((Int128(x % Int8) >> 64) % Int64) * 1000 + Int64(Int128(x % Int8) % Int64)
s20_i16(x::Int64) = Int64((Int128(x % Int16) >> 64) % Int64) * 1000 + Int64(Int128(x % Int16) % Int64)
s20_i32(x::Int64) = Int64((Int128(x % Int32) >> 64) % Int64) * 1000 + Int64(Int128(x % Int32) % Int64)
s20_u8(x::Int64) = Int64((UInt128(x % UInt8) >> 64) % Int64) * 1000 + Int64(UInt128(x % UInt8) % Int64)
_s(20, "Int128(narrow negative) sign extension", Any[
    ("int8", s20_i8, Int64(-3)),
    ("int16", s20_i16, Int64(-3)),
    ("int32", s20_i32, Int64(-3)),
    ("uint8", s20_u8, Int64(-3)),
])

# ---- 21 Bool + Bool --------------------------------------------------------------------
s21_static(a::Int64) = (b = a > 0; b + b)
s21_any(i::Int64) = (v = Any[true, true, false]; (_anyat(v, i) + _anyat(v, i + 1))::Int64)
s21_any_typeof(i::Int64) = (v = Any[true, true, false]; Int64(typeof(_anyat(v, i) + _anyat(v, i + 1)) === Int64))
_s(21, "Bool + Bool", Any[
    ("static", s21_static, Int64(1)),
    ("through_any", s21_any, Int64(1)),
    ("through_any_typeof", s21_any_typeof, Int64(1)),
])

# ---- 22 ArgumentError from _throw_argerror ---------------------------------------------------
s22_pop(n::Int64) = (v = collect(1:n); try; pop!(v); 0; catch e; e isa ArgumentError ? 1 : 2; end)
s22_resize(n::Int64) = (v = collect(1:3); try; resize!(v, n); 0; catch e; e isa ArgumentError ? 1 : 2; end)
s22_msg(n::Int64) = (v = collect(1:n); try; pop!(v); 0; catch e; e isa ArgumentError ? ncodeunits(e.msg) : -1; end)
_s(22, "ArgumentError from Base._throw_argerror", Any[
    ("pop_empty", s22_pop, Int64(0)),
    ("resize_negative", s22_resize, Int64(-1)),
    ("pop_empty_msg_len", s22_msg, Int64(0)),
])

# ---- 23 BoundsError ---------------------------------------------------------------------
s23_type(i::Int64) = (v = [10, 20, 30]; try; v[i]; catch e; e isa BoundsError ? 1 : 2; end)
s23_index(i::Int64) = (v = [10, 20, 30]; try; v[i]; catch e; e isa BoundsError ? (e.i isa Tuple ? Int64(e.i[1]::Int64) : -1) : -2; end)
s23_array(i::Int64) = (v = [10, 20, 30]; try; v[i]; catch e; e isa BoundsError ? Int64(e.a === v) : -2; end)
_s(23, "BoundsError from throw_boundserror", Any[
    ("type", s23_type, Int64(5)),
    ("field_i", s23_index, Int64(5)),
    ("field_a_identity", s23_array, Int64(5)),
])

# ---- 24 _tuple_error (MethodError(convert, ...)) --------------------------------------------
@noinline _s24conv(x::Tuple{Int64}) = convert(Tuple{Int64,Int64}, x)
s24_type(x::Int64) = try; _s24conv((x,)); 0; catch e; e isa MethodError ? 1 : 2; end
s24_f(x::Int64) = try; _s24conv((x,)); 0; catch e; e isa MethodError ? Int64(e.f === convert) : 2; end
_s(24, "Base._tuple_error MethodError", Any[
    ("type", s24_type, Int64(1)),
    ("field_f", s24_f, Int64(1)),
])

# ---- 25 truncate(::IOBuffer) ----------------------------------------------------------------
s25_take(n::Int64) = (io = IOBuffer(); write(io, "hello"); truncate(io, n); ncodeunits(String(take!(io))))
s25_read(n::Int64) = (io = IOBuffer(); write(io, "hello"); truncate(io, n); seekstart(io); ncodeunits(read(io, String)))
s25_pos(n::Int64) = (io = IOBuffer(); write(io, "hello"); truncate(io, n); position(io) * 10 + io.size)
_s(25, "truncate(::IOBuffer, n) then read", Any[
    ("take", s25_take, Int64(2)),
    ("seek_read", s25_read, Int64(2)),
    ("position_size", s25_pos, Int64(2)),
])

# ---- 26 setfield! on a RefValue ------------------------------------------------------------
@noinline _s26set!(r::Base.RefValue{Int64}, x::Int64) = (r[] = x; nothing)
@noinline _s26get(r::Base.RefValue{Int64}) = r[]
s26_inline(x::Int64) = (r = Ref{Int64}(1); r[] = x; r[])
s26_noinline(x::Int64) = (r = Ref{Int64}(1); _s26set!(r, x); _s26get(r))
s26_float(x::Float64) = (r = Ref(1.0); _s26setf!(r, x); r[] * 2)
@noinline _s26setf!(r::Base.RefValue{Float64}, x::Float64) = (r[] = x; nothing)
_s(26, "setfield! on a Base.RefValue", Any[
    ("inline", s26_inline, Int64(5)),
    ("noinline", s26_noinline, Int64(5)),
    ("float_noinline", s26_float, 2.5),
])

# ---- 27 Union{Nothing,Int64} field set to nothing; %new of a Memory -------------------------------
mutable struct M27; f::Union{Nothing,Int64}; end
@noinline _s27clear!(m::M27) = (m.f = nothing; nothing)
@noinline _s27set!(m::M27, x::Int64) = (m.f = x; nothing)
s27_nothing(x::Int64) = (m = M27(x); _s27clear!(m); Int64(m.f === nothing))
s27_roundtrip(x::Int64) = (m = M27(nothing); _s27set!(m, x); a = m.f === nothing ? -1 : m.f::Int64; _s27clear!(m); b = m.f === nothing ? 1 : 0; a * 10 + b)
s27_memory(n::Int64) = (m = Memory{Int64}(undef, n); fill!(m, 3); length(m) * 100 + sum(m))
s27_memory_neg(n::Int64) = try; length(Memory{Int64}(undef, n)); catch e; e isa ArgumentError ? -1 : -2; end
s27_memory_zero(n::Int64) = (m = Memory{Int64}(undef, n); length(m))
_s(27, "Union{Nothing,Int64} field := nothing; %new of a Memory", Any[
    ("field_set_nothing", s27_nothing, Int64(4)),
    ("field_roundtrip", s27_roundtrip, Int64(4)),
    ("memory_new_fill", s27_memory, Int64(4)),
    ("memory_new_len", s27_memory_zero, Int64(4)),
    ("memory_new_negative", s27_memory_neg, Int64(-1)),
])

# ============================================================================
const _RANK = Dict(:WRONG => 4, :TRAP => 3, :LOUD => 2, :OK => 1)
const _SUSPECT_LABEL = Dict(:WRONG => "CONFIRMED-WRONG", :TRAP => "CONFIRMED-TRAP",
                            :LOUD => "LOUD", :OK => "REFUTED")

_firstline(e) = first(first(split(sprint(showerror, e), '\n')), 240)

function run_case(f, args)
    local bytes
    arg_types = Tuple(map(typeof, args))
    expected = try
        f(args...)
    catch e
        return (:NATIVE_THROWS, _firstline(e))
    end
    try
        bytes = WasmTarget.compile(f, arg_types)
    catch e
        return (:LOUD, "$(nameof(typeof(e))): " * _firstline(e))
    end
    imports = Dict{String,Any}()
    actual = try
        run_wasm_with_imports(bytes, string(nameof(f)), imports, args...)
    catch e
        return (:TRAP, _firstline(e))
    end
    ok = expected == actual && !(expected isa Integer && actual isa AbstractFloat && !isinteger(actual))
    return ok ? (:OK, "native=$(repr(expected)) wasm=$(repr(actual))") :
                (:WRONG, "native=$(repr(expected)) wasm=$(repr(actual))")
end

function main(which)
    for (n, title, cases) in SUSPECTS
        (isempty(which) || n in which) || continue
        worst = :OK; lines = String[]
        for case in cases
            name, f, args = case[1], case[2], case[3:end]
            cls, ev = run_case(f, args)
            cls === :NATIVE_THROWS && (push!(lines, "    [SETUP] $name native threw: $ev"); continue)
            _RANK[cls] > _RANK[worst] && (worst = cls)
            push!(lines, "    [$(rpad(cls, 5))] $name$(isempty(args) ? "" : repr(Tuple(args)))  $ev")
        end
        println(lpad(n, 2), " ", rpad(_SUSPECT_LABEL[worst], 16), title)
        foreach(println, lines)
        flush(stdout)
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(parse.(Int, ARGS))
