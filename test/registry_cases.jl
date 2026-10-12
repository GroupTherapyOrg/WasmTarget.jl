# The numeric lowering tables case themselves (dev/CHARTER.md C5): one smoke group per table, its
# cases generated from the table's own keys, never from a copy of them. A key's case runs its
# intrinsic over every Julia type whose register is the key's, each compiled once and run
# differentially over its inputs (compare_julia_wasm_inputs, test/utils.jl).
#
# The types: Bool, the 8- to 64-bit integers and Float16/32/64; a 128-bit integer is held in a
# struct, the register of no key. A type is a key's when julia_to_wasm_type (the one width rule)
# gives the key's register, and Julia's intrinsic accepts it (a native call: Julia decides).
# The inputs: per type its boundaries (typemin, typemax, 0, 1, -1, the half-width and sign-bit
# values; for a float ±0, NaN, ±Inf, a subnormal, floatmin, floatmax and 2^60 + 2^36), and, for a
# type narrower than its register whose every bit pattern is a value (Int8, UInt8, Int16, UInt16,
# Float16), a dirty operand: the result of a @noinline add of two bit patterns that overflows the
# width inside the i32 register, the junk a narrow register carries (test/smoke.jl's
# narrow_widening); a 64-bit integer also has 2^60 + 2^36 + 1, which a second rounding moves. Every
# operand passes through that add (with a zero addend when clean), so each case has one shape. A
# conversion's target is named as source names it, a global. Excluded by rule, not by name: an input native answers with an exception
# (a native throw is matched by the strict throw match, which this runner does not have), an input
# whose native result is a Bool that is neither 0 nor 1, an fptosi/fptoui input that is NaN or
# truncates outside the target, an unchecked division by zero or of typemin by -1, and a NaN, an
# infinity or a zero, as an operand or as the strict result, under a fast-math intrinsic (Julia
# leaves those undefined, or to the host).
# A type passes to the host through its carrier: a float as the unsigned integer of its bits, so
# every input bit pattern reaches the module as it is; a result through _rc_out: a narrow integer
# widened to Int64 (Julia's conversion reads it at its width), UInt32 and UInt64 as the signed
# integer of their bits (the host reads an i32 or i64 signed), a float as the signed integer of its
# bits, so a float result is compared by its bits, NaN's included where they are determined: IEEE
# 754's sign bit operations (5.5.1: negate, abs and copySign, Julia's neg_float, abs_float and
# copysign_float) and a bitcast set every bit of their result (_rc_exact); any other operation's NaN
# is an arithmetic NaN, whose sign and payload wasm (its numerics' nondeterministic NaN) and
# Julia's host leave unspecified, so it is compared as a NaN (as the canonical NaN's bits).

const RC_TYPES = (Bool, Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, Float16, Float32, Float64)
# The types whose cases wait for the width rule to cover them (a ratchet counts this table, R42):
# no case of these is generated, as an operand or a target, until the row's fix lands.
const RC_HELD = Dict{DataType,String}(
    Bool => "a Bool under an integer intrinsic is its lowest bit, Julia's i1 (add_int(true, true) is false, " *
            "sext_int(Int16, true) -1, slt_int(false, true) false, ctlz_int(false) true): dev/MARCH.md 13.1",
    Float16 => "a Float16 under an integer intrinsic is its 16 bits, which the width rule reads as 32 " *
               "(eq_int of two Float16s differing above bit 16 answers false; sext_int(Int32, x) does not " *
               "extend bit 15), and fma over Float16 raises an unlocated codegen error: dev/MARCH.md 13.1",
)
const RC_REGISTERS = (WasmTarget.I32, WasmTarget.I64, WasmTarget.F32, WasmTarget.F64)
const CASE_INPUTS = Dict{String,Vector{Tuple}}()   # a generated case's inputs, by "group/case"

_rc_register(T) = WasmTarget.julia_to_wasm_type(T)
_rc_carrier(T) = T <: AbstractFloat ? Base.uinttype(T) : T
_rc_unsigned(T) = T === Bool ? Bool : T <: AbstractFloat ? Base.uinttype(T) : unsigned(T)
_rc_dirtyable(T) = T in (Int8, UInt8, Int16, UInt16, Float16)

@inline _rc_in(::Type{T}, c) where {T} = T <: AbstractFloat ? reinterpret(T, c) : c
# a result as the host reads it: a narrow integer (or Float16's bits) widened to Int64 by Julia's own
# conversion, which reads it at its width, so the register's junk above it is not what is compared;
# a float as its bits, an arithmetic NaN as the canonical NaN's (_rc_out) or as it is (_rc_exact)
@inline _rc_exact(r) = r isa Float16 ? Int64(reinterpret(UInt16, r)) : r isa Float32 ? reinterpret(Int32, r) :
                       r isa Float64 ? reinterpret(Int64, r) : r isa Union{Int8,UInt8,Int16,UInt16} ? Int64(r) :
                       r isa UInt32 ? reinterpret(Int32, r) : r isa UInt64 ? reinterpret(Int64, r) : r
@inline _rc_out(r) = (r isa AbstractFloat && isnan(r)) ? _rc_exact(typeof(r)(NaN)) : _rc_exact(r)
# the operations whose NaN result is determined, by IEEE 754 5.5.1 and the bitcast's definition
const RC_EXACT = (:neg_float, :abs_float, :copysign_float, :bitcast)
_rc_outf(op::Symbol) = op in RC_EXACT ? :_rc_exact : :_rc_out
# an operand: the add of two bit patterns, so a narrow one may carry junk above its width
@noinline _rc_operand(x::Bool, y::Bool) = xor(x, y)
@noinline function _rc_operand(x::T, y::T) where {T}
    local U = _rc_unsigned(T)
    return Core.Intrinsics.bitcast(T, Core.Intrinsics.add_int(Core.Intrinsics.bitcast(U, x), Core.Intrinsics.bitcast(U, y)))
end

function _rc_values(T)::Vector{Any}
    T === Bool && return Any[false, true]
    if T <: Integer
        local w = 8 * sizeof(T)
        local v = Any[typemin(T), typemax(T), zero(T), one(T), -one(T), T(3), -T(7),
                      one(T) << (w ÷ 2), (one(T) << (w ÷ 2)) - one(T), one(T) << (w - 1),
                      (one(T) << (w - 1)) - one(T)]
        # 2^60 + 2^36 + 1 rounds to 2^60 + 2^37 as a Float32 once, to 2^60 through a Float64
        w == 64 && push!(v, (one(T) << 60) + (one(T) << 36) + one(T))
        return unique!(v)
    end
    return unique!(x -> reinterpret(_rc_unsigned(T), x),
                   Any[zero(T), -zero(T), one(T), T(-1.5), T(NaN), T(Inf), T(-Inf), nextfloat(zero(T)),
                       floatmin(T), floatmax(T), T(2.0^60 + 2.0^36)])
end
# the bit-pattern pairs whose add overflows a narrow width: (x, y) with x + y past the register's
function _rc_dirty_pairs(T)::Vector{Tuple{Any,Any}}
    _rc_dirtyable(T) || return Tuple{Any,Any}[]
    local U = _rc_unsigned(T)
    local top = one(U) << (8 * sizeof(U) - 1)
    return Tuple{Any,Any}[(reinterpret(T, a), reinterpret(T, b)) for (a, b) in
                          ((typemax(U), typemax(U)), (typemax(U), one(U)), (top, top), (top | U(0x22), top | U(0x33)))]
end
# the carrier of each operand's two halves; a clean operand's second half is zero
_rc_clean(x) = (_rc_c(x), _rc_c(_rc_zero(typeof(x))))
_rc_zero(T) = T === Bool ? false : reinterpret(T, zero(_rc_unsigned(T)))
_rc_c(x) = x isa AbstractFloat ? reinterpret(Base.uinttype(typeof(x)), x) : x

# the operand lists of one type: every boundary clean, and every dirty pair
function _rc_operands(T)::Vector{Tuple}
    local out = Tuple[_rc_clean(x) for x in _rc_values(T)]
    append!(out, [(_rc_c(a), _rc_c(b)) for (a, b) in _rc_dirty_pairs(T)])
    return out
end

# whether a native answer is an input's expectation (compare_julia_wasm_inputs's `admit`): a value,
# and not a Bool that is neither 0 nor 1, by the rules above
_rc_admit(ok::Bool, v) = ok && !(v isa Bool && reinterpret(UInt8, v) > 0x01)

# a case: its first input's types are its signature (what every lane that compiles a GROUPS case
# reads), every input run by smoke
function _rc_case!(group::Vector{Any}, gname::String, name::String, f, inputs::Vector{Tuple})
    isempty(inputs) && error("registry_cases: $gname/$name has no input")
    push!(group, (name, f, inputs[1]...))
    CASE_INPUTS["$gname/$name"] = inputs
    return nothing
end

_rc_accepts(f, args...) = try f(args...); true catch; false end
_rc_sample(T) = T === Bool ? true : one(T)
_rc_types_of(reg) = [T for T in RC_TYPES if !haskey(RC_HELD, T) && _rc_register(T) === reg]
_rc_name(x) = x isa Tuple ? join(map(_rc_name, x), "_") : string(x)

# a key no Julia type reaches is a table entry no program can (dead, C9) or one a hand case needs
_rc_unreached(table, key) = error("registry_cases: $table has the key $key, which no Julia type reaches")

# an unchecked division Julia leaves undefined (LLVM's sdiv/udiv/srem/urem): by zero, or a signed one
# of typemin by -1 (Base's div throws first; the checked intrinsics throw themselves)
function _rc_undefined_division(op::Symbol, x, y)
    op in (:sdiv_int, :srem_int, :udiv_int, :urem_int) || return false
    local U = _rc_unsigned(typeof(x))
    local yb = Core.Intrinsics.bitcast(U, y)
    iszero(yb) && return true
    op in (:sdiv_int, :srem_int) || return false
    local w = 8 * sizeof(U)
    return Core.Intrinsics.bitcast(U, x) == one(U) << (w - 1) && yb == typemax(U)
end

# a fast-math intrinsic carries Julia's fast flags (no NaN, no infinity, no signed zero: LLVM's
# `fast`), so its result is undefined where an operand or the strict intrinsic's result is a NaN,
# an infinity or a zero (x86 answers max_float_fast(0.0, -0.0) as -0.0, aarch64 as 0.0; Julia 1.13
# on x86 answers sqrt_llvm_fast(-1.5) as a NaN whose sign its own isnan test cannot see)
function _rc_fast_undefined(op::Symbol, xs...)
    endswith(string(op), "_fast") || return false
    any(x -> x isa AbstractFloat && !isfinite(x), xs) && return true
    local strict = Symbol(replace(string(op), "_fast" => ""))
    isdefined(Core.Intrinsics, strict) || error("registry_cases: $op has no strict intrinsic $strict")
    local r = getfield(Core.Intrinsics, strict)(xs...)
    return r isa AbstractFloat && (!isfinite(r) || iszero(r))
end
_rc_undefined(op::Symbol, x, y) = _rc_undefined_division(op, x, y) || _rc_fast_undefined(op, x, y)

# ---- INTRINSIC_BINOPS: (register, register, op) => op(x::T, y::T) ----
function _rc_binops()
    local g = Any[]
    for key in sort!(collect(keys(WasmTarget.INTRINSIC_BINOPS)); by=string)
        local (wl, wr, op) = key
        local fn = getfield(Core.Intrinsics, op)
        local ts = [T for T in _rc_types_of(wl) if _rc_register(T) === wr && _rc_accepts(fn, _rc_sample(T), _rc_sample(T))]
        isempty(ts) && _rc_unreached(:INTRINSIC_BINOPS, key)
        for T in ts
            local C = _rc_carrier(T)
            local out = _rc_outf(op)
            local f = @eval (a::$C, b::$C, c::$C, d::$C) -> $out(Core.Intrinsics.$op(_rc_operand(_rc_in($T, a), _rc_in($T, b)),
                                                                                     _rc_operand(_rc_in($T, c), _rc_in($T, d))))
            local ops = _rc_operands(T)
            local clean = [_rc_clean(x) for x in _rc_values(T)]
            local inputs = Tuple[(x..., y...) for x in ops for y in clean]
            append!(inputs, Tuple[(x..., y...) for x in clean for y in ops[length(clean)+1:end]])
            filter!(inp -> !_rc_undefined(op, _rc_operand(_rc_in(T, inp[1]), _rc_in(T, inp[2])),
                                         _rc_operand(_rc_in(T, inp[3]), _rc_in(T, inp[4]))), inputs)
            _rc_case!(g, "registry_binops", "$(op)_$(T)", f, inputs)
        end
    end
    return g
end

# ---- INTRINSIC_UNOPS: (register, op) => op(x::T) ----
function _rc_unops()
    local g = Any[]
    for key in sort!(collect(keys(WasmTarget.INTRINSIC_UNOPS)); by=string)
        local (w, op) = key
        local fn = getfield(Core.Intrinsics, op)
        local ts = [T for T in _rc_types_of(w) if _rc_accepts(fn, _rc_sample(T))]
        isempty(ts) && _rc_unreached(:INTRINSIC_UNOPS, key)
        for T in ts
            local C = _rc_carrier(T)
            local out = _rc_outf(op)
            local f = @eval (a::$C, b::$C) -> $out(Core.Intrinsics.$op(_rc_operand(_rc_in($T, a), _rc_in($T, b))))
            local inputs = filter(inp -> !_rc_fast_undefined(op, _rc_operand(_rc_in(T, inp[1]), _rc_in(T, inp[2]))), _rc_operands(T))
            _rc_case!(g, "registry_unops", "$(op)_$(T)", f, inputs)
        end
    end
    return g
end

# ---- INTRINSIC_CONVERSIONS: (source register, target register, op) => op(D, x::S) ----
# Each op's pairs (S, D) Julia accepts whose registers are one of the op's keys, and, for the
# integer conversions and bitcast, every pair of integer registers or of one register (their arms
# emit without the table: emit_conversion!, emit_bitcast!).
# fptosi reads its target's bits as a signed integer of the target's width, fptoui as an unsigned one
function _rc_in_range(op::Symbol, D, x)
    isfinite(x) || return false
    local w = 8 * sizeof(D)
    local t = trunc(BigFloat(x; precision=256))
    return op === :fptosi ? -big(2)^(w - 1) <= t <= big(2)^(w - 1) - 1 : 0 <= t <= big(2)^w - 1
end
function _rc_conversions()
    local g = Any[]
    local ops = sort!(unique!([k[3] for k in keys(WasmTarget.INTRINSIC_CONVERSIONS)]))
    local reached = Set{Any}()
    for op in ops
        local fn = getfield(Core.Intrinsics, op)
        local keyed = Set((k[1], k[2]) for k in keys(WasmTarget.INTRINSIC_CONVERSIONS) if k[3] === op)
        for S in RC_TYPES, D in RC_TYPES
            (haskey(RC_HELD, S) || haskey(RC_HELD, D)) && continue
            local rs, rd = _rc_register(S), _rc_register(D)
            local arm = (op in (:sext_int, :zext_int, :trunc_int) && rs in (WasmTarget.I32, WasmTarget.I64) &&
                         rd in (WasmTarget.I32, WasmTarget.I64)) || (op === :bitcast && rs === rd)
            ((rs, rd) in keyed || arm) || continue
            _rc_accepts(fn, D, _rc_sample(S)) || continue
            (rs, rd) in keyed && push!(reached, (rs, rd, op))
            local C = _rc_carrier(S)
            # the target named as source names it, a global (resolved once at the call)
            local out = _rc_outf(op)
            local f = @eval (a::$C, b::$C) -> $out(Core.Intrinsics.$op($(nameof(D)), _rc_operand(_rc_in($S, a), _rc_in($S, b))))
            local inputs = _rc_operands(S)
            op in (:fptosi, :fptoui) && filter!(inp -> _rc_in_range(op, D, _rc_operand(_rc_in(S, inp[1]), _rc_in(S, inp[2]))), inputs)
            _rc_case!(g, "registry_conversions", "$(op)_$(S)_$(D)", f, inputs)
        end
    end
    for key in keys(WasmTarget.INTRINSIC_CONVERSIONS)
        key in reached || _rc_unreached(:INTRINSIC_CONVERSIONS, key)
    end
    return g
end

# ---- the op-keyed tables: every type in a register Julia's intrinsic accepts ----
_rc_reg_types() = [T for T in RC_TYPES if !haskey(RC_HELD, T) && _rc_register(T) in RC_REGISTERS]
function _rc_checked()
    local g = Any[]
    for op in sort!(collect(keys(WasmTarget.CHECKED_OPS)))
        local fn = getfield(Core.Intrinsics, op)
        local ts = [T for T in _rc_reg_types() if T <: Integer && T !== Bool && _rc_accepts(fn, one(T), one(T))]
        isempty(ts) && _rc_unreached(:CHECKED_OPS, op)
        for T in ts
            local C = _rc_carrier(T)
            # the flag flips every bit of the value, so a wrong value or a wrong flag answers wrong
            local f = @eval (a::$C, b::$C, c::$C, d::$C) -> (r = Core.Intrinsics.$op(_rc_operand(a, b), _rc_operand(c, d));
                                                             _rc_out(r[2] ? ~r[1] : r[1]))
            local ops = _rc_operands(T)
            local clean = [_rc_clean(x) for x in _rc_values(T)]
            local inputs = Tuple[(x..., y...) for x in ops for y in clean]
            _rc_case!(g, "registry_checked", "$(op)_$(T)", f, inputs)
        end
    end
    return g
end
# a shift's amount is any integer type the intrinsic accepts: each one's boundary amounts (0, 1, the
# shifted width less one, the width and past it, 255 where the type holds it, typemax, and the
# amount whose top bit alone is set, -1 and typemin for a signed amount, which Julia reads
# unsigned) and, narrower than its register, its dirty amounts (an add whose junk sits above the
# amount's width)
function _rc_amounts(U, w::Int)::Vector{Tuple}
    local ks = Any[U(k) for k in unique!([0, 1, w - 1, w, w + 1, 2w, 255]) if k <= typemax(U)]
    append!(ks, Any[typemax(U), one(U) << (8 * sizeof(U) - 1)])
    U <: Signed && push!(ks, -one(U))
    local out = Tuple[(k, zero(U)) for k in unique!(ks)]
    append!(out, Tuple[(a, b) for (a, b) in _rc_dirty_pairs(U)])
    return out
end
function _rc_shift()
    local g = Any[]
    local ints = [T for T in _rc_reg_types() if T <: Integer && T !== Bool]
    for op in sort!(collect(keys(WasmTarget.SHIFT_OPS)))
        local fn = getfield(Core.Intrinsics, op)
        local found = false
        for T in ints, U in ints
            _rc_accepts(fn, one(T), one(U)) || continue
            found = true
            local f = @eval (a::$T, b::$T, n::$U, m::$U) -> _rc_out(Core.Intrinsics.$op(_rc_operand(a, b), _rc_operand(n, m)))
            local inputs = Tuple[(x..., n...) for x in _rc_operands(T) for n in _rc_amounts(U, 8 * sizeof(T))]
            _rc_case!(g, "registry_shift", "$(op)_$(T)_$(U)", f, inputs)
        end
        found || _rc_unreached(:SHIFT_OPS, op)
    end
    return g
end
function _rc_fma()
    local g = Any[]
    for op in sort!(collect(keys(WasmTarget.FMA_OPS)))
        local fn = getfield(Core.Intrinsics, op)
        if op === :have_fma
            local ts = [T for T in _rc_reg_types() if T <: AbstractFloat && _rc_accepts(fn, T)]
            isempty(ts) && _rc_unreached(:FMA_OPS, op)
            for T in ts
                local f = @eval (a::Int64) -> Core.Intrinsics.have_fma($T)
                _rc_case!(g, "registry_fma", "$(op)_$(T)", f, Tuple[(Int64(0),)])
            end
            continue
        end
        local ts = [T for T in _rc_reg_types() if T <: AbstractFloat && _rc_accepts(fn, one(T), one(T), one(T))]
        isempty(ts) && _rc_unreached(:FMA_OPS, op)
        for T in ts
            local C = _rc_carrier(T)
            local f = @eval (a::$C, b::$C, c::$C, d::$C, e::$C, h::$C) ->
                _rc_out(Core.Intrinsics.$op(_rc_operand(_rc_in($T, a), _rc_in($T, b)), _rc_operand(_rc_in($T, c), _rc_in($T, d)),
                                            _rc_operand(_rc_in($T, e), _rc_in($T, h))))
            local ops = _rc_operands(T)
            local inputs = Tuple[(x..., y..., z...) for x in ops for y in ops[1:6] for z in ops[1:6]]
            # one rounding: x*y + z exact in no wider type than the product of two halves of 2^k
            push!(inputs, (_rc_clean(T(1) + eps(T))..., _rc_clean(T(1) - eps(T))..., _rc_clean(T(-1))...))
            _rc_case!(g, "registry_fma", "$(op)_$(T)", f, inputs)
        end
    end
    return g
end
function _rc_misc()
    local g = Any[]
    for op in sort!(collect(keys(WasmTarget.MISC_OPS)))
        local fn = getfield(Core.Intrinsics, op)
        local found = false
        for T in _rc_reg_types()
            (T <: Integer && T !== Bool) || continue
            local args = op === :flipsign_int ? (one(T), one(T)) : (one(T),)
            _rc_accepts(fn, args...) || continue
            found = true
            local C = _rc_carrier(T)
            if op === :flipsign_int
                local f = @eval (a::$C, b::$C, c::$C, d::$C) -> _rc_out(Core.Intrinsics.$op(_rc_operand(a, b), _rc_operand(c, d)))
                local inputs = Tuple[(x..., y...) for x in _rc_operands(T) for y in _rc_operands(T)]
                _rc_case!(g, "registry_misc", "$(op)_$(T)", f, inputs)
            else
                local f = @eval (a::$C, b::$C) -> _rc_out(Core.Intrinsics.$op(_rc_operand(a, b)))
                _rc_case!(g, "registry_misc", "$(op)_$(T)", f, _rc_operands(T))
            end
        end
        found || _rc_unreached(:MISC_OPS, op)
    end
    return g
end

# ---- the operator fallback: operator_intrinsic's answer for each callee and type, asked of it ----
# Its two consumers: the surface-operator call (a BUILTIN_LOWERINGS entry, a captured, mutated
# accumulator's operator reaching codegen as a call) and _apply_iterate's reduce (an intrinsic or
# operator splatted over a vector). The callees are found by asking operator_intrinsic: of
# BUILTIN_LOWERINGS's keys for the first, of every Core.Intrinsics intrinsic and every Base binary
# operator for the second, those it answers for some type. Per callee and type, the consumer's own
# rule decides (operator_intrinsic for the call, reduce_intrinsic, which is no reduction for `-`, for
# the reduce): an answer is a case; for the first type it answers `nothing` for where Julia
# answers, a loud case (an xfail: the consumer rejects at its statement).
# The reduce's case is the splat of two elements, where Julia answers the call of two; a splat of
# one or three, where Julia throws for an intrinsic or `-`, waits for the strict throw match (A16E4).
_rc_answers(rule, f, types) = any(T -> rule(f, T) !== nothing, types)
function _rc_operator_candidates()::Vector{Any}
    local fs = Any[]
    for s in names(Core.Intrinsics; all=true)
        isdefined(Core.Intrinsics, s) || continue
        local v = getfield(Core.Intrinsics, s)
        v isa Core.IntrinsicFunction && push!(fs, v)
    end
    for s in names(Base)
        (Base.isbinaryoperator(s) && isdefined(Base, s)) || continue
        local v = getfield(Base, s)
        (v isa Function && !any(x -> x === v, fs)) && push!(fs, v)
    end
    return fs
end
const RC_OPERATOR_REJECTS = Any[]   # the loud cases, an xfail group
_rc_fname(f) = f isa Core.IntrinsicFunction ? Symbol(f) : nameof(f)
_rc_fexpr(f) = f isa Core.IntrinsicFunction ? :(Core.Intrinsics.$(Symbol(f))) : :(Base.$(nameof(f)))
function _rc_operators()
    local g = Any[]
    local types = [T for T in RC_TYPES if !haskey(RC_HELD, T)]
    # the call: s = f(s, b), n times
    local calls = sort!(Any[f for f in keys(WasmTarget.BUILTIN_LOWERINGS) if _rc_answers(WasmTarget.operator_intrinsic, f, types)]; by=string)
    isempty(calls) && error("registry_cases: operator_intrinsic answers for no BUILTIN_LOWERINGS key")
    for f in calls
        local nothing_seen = false
        for T in types
            local C = _rc_carrier(T)
            local fx = _rc_fexpr(f)
            local fc = @eval (n::Int64, a::$C, b::$C) -> _rc_out((s = _rc_in($T, a); foreach(i -> (s = $fx(s, _rc_in($T, b))), 1:n); s)::$T)
            local inputs = Tuple[(Int64(n), _rc_c(a), _rc_c(b)) for n in (1, 2) for a in _rc_values(T) for b in _rc_values(T)]
            if WasmTarget.operator_intrinsic(f, T) !== nothing
                _rc_case!(g, "registry_operators", "call_$(_rc_fname(f))_$(T)", fc, inputs)
            elseif !nothing_seen
                nothing_seen = true
                push!(RC_OPERATOR_REJECTS, ("call_$(_rc_fname(f))_$(T)", fc, inputs[end]...))
            end
        end
    end
    # the reduce: f(v...) over a vector of two
    local reduced = Any[f for f in _rc_operator_candidates() if _rc_answers(WasmTarget.operator_intrinsic, f, types)]
    isempty(reduced) && error("registry_cases: operator_intrinsic answers for no candidate")
    for f in sort!(reduced; by=string)
        local nothing_seen = false
        for T in types
            local C = _rc_carrier(T)
            local fx = _rc_fexpr(f)
            local fr = @eval (a::$C, b::$C) -> _rc_out((v = $T[_rc_in($T, a), _rc_in($T, b)]; $fx(v...)))
            local inputs = Tuple[(_rc_c(a), _rc_c(b)) for a in _rc_values(T) for b in _rc_values(T)]
            _rc_accepts(f, _rc_in(T, inputs[end][1]), _rc_in(T, inputs[end][2])) || continue
            if WasmTarget.reduce_intrinsic(f, T) !== nothing
                _rc_case!(g, "registry_operators", "splat2_$(_rc_fname(f))_$(T)", fr, inputs)
            elseif !nothing_seen
                nothing_seen = true
                push!(RC_OPERATOR_REJECTS, ("splat2_$(_rc_fname(f))_$(T)", fr, inputs[end]...))
            end
        end
    end
    return g
end

# ---- the lowering entries no table generates: their probes ran nothing ----
_g("registry_foreign", Any[
    ("task_rand_range", (n::Int64) -> (x = rand(); (0.0 <= x < 1.0 ? 1 : 0) + n), Int64(1)),         # jl_get_current_task
    ("hrtime_monotone", (n::Int64) -> (t = time_ns(); (time_ns() >= t ? 1 : 0) + n), Int64(1)),         # jl_hrtime
    ("object_id_stable", (n::Int64) -> (r = Ref(n); objectid(r) == objectid(r) ? n : -n), Int64(5)),    # jl_object_id
])

_g("registry_binops", _rc_binops())
_g("registry_unops", _rc_unops())
_g("registry_conversions", _rc_conversions())
_g("registry_checked", _rc_checked())
_g("registry_shift", _rc_shift())
_g("registry_fma", _rc_fma())
_g("registry_misc", _rc_misc())
_g("registry_operators", _rc_operators())
# operator_intrinsic's `nothing`: each consumer rejects at its statement, where Julia answers
_xf("registry_operators_rejected", RC_OPERATOR_REJECTS)
