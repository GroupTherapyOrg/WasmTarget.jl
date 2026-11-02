# ---- Julia's runtime: libjulia's functions the code generator calls, each rooted in every closed world (RUNTIME_ROOTS) ----
# The functions of Julia's own C runtime (src/rtutils.c, src/runtime_intrinsics.c, julia.h, builtins.c)
# which Julia's codegen calls: the raises where a builtin or an intrinsic fails, each building Julia's
# exception and throwing it through the runtime's thrower (src/runtime/common/errors_patch.jl
# Error._throwWithCurrentStackTrace), jl_egal where === compares no inline, and a type tag's type.
# They have no dart counterpart: dart raises its own errors in dart code (boxed_int.dart's
# `throw IntegerDivisionByZeroException()`), where Julia's are raised by its runtime, so they are
# quarantined, each naming Julia's own function. libjulia is linked whole into every Julia process, so
# each is in every closed world (dev/skeleton.jl roots every function of this section), and the code
# generator emits one only where its code calls it.

# jl_diverror_exception, raised by checked_sdiv_int and its kin at a zero divisor (runtime_intrinsics.c)
@quarantine "Julia's runtime raises DivideError where a checked integer division fails" Core.DivideError @noinline throw_divide_error()::Union{} =
    Runtime.Error__throw_with_current_stack_trace(DivideError())

# the ArgumentError Julia's codegen raises where memorynew's element count is negative or its byte size
# too large for the address width (cgutils.cpp emit_memorynew's error_unless over jlargumenterror_func,
# genericmemory.c _new_genericmemory_'s jl_exceptionf), its message Julia's
@quarantine "julia/src/cgutils.cpp:4563 emit_memorynew raises ArgumentError where a GenericMemory's size is invalid, as julia/src/genericmemory.c:55 _new_genericmemory_ does" Core.ArgumentError @noinline throw_invalid_memory_size()::Union{} =
    Runtime.Error__throw_with_current_stack_trace(ArgumentError("invalid GenericMemory size: the number of elements is either negative or too large for system address width"))

# jl_memory_exception (julia.h), the OutOfMemoryError Julia's allocator throws where a memory's
# allocation (genericmemory.c jl_alloc_genericmemory_unchecked, through jl_gc_managed_malloc) cannot be
# satisfied
@quarantine "julia/src/genericmemory.c:30 jl_alloc_genericmemory_unchecked raises Julia's OutOfMemoryError where a memory's allocation cannot be satisfied" Core.OutOfMemoryError @noinline throw_out_of_memory()::Union{} =
    Runtime.Error__throw_with_current_stack_trace(OutOfMemoryError())

# jl_atomic_error, raised by Julia's codegen (cgutils.cpp emit_atomic_error) where an access's atomic
# ordering does not fit its field, with codegen's message
@quarantine "julia/src/rtutils.c:181 jl_atomic_error raises ConcurrencyViolationError with codegen's message" Core.ConcurrencyViolationError @noinline throw_atomic_error(msg::String)::Union{} =
    Runtime.Error__throw_with_current_stack_trace(ConcurrencyViolationError(msg))

# jl_undefref_exception, raised where an undefined field or array element is read (rtutils.c)
@quarantine "Julia's runtime raises UndefRefError where an undefined reference is read" Core.UndefRefError @noinline throw_undef_ref_error()::Union{} =
    Runtime.Error__throw_with_current_stack_trace(UndefRefError())

# jl_bounds_error_int, raised with the indexed value and the integer index where a bounds check fails
# (rtutils.c); BoundsError's constructor specializes on its index, so the index is an Int, as the C
# runtime's size_t
@quarantine "Julia's runtime raises BoundsError with the value and the index where a bounds check fails" Core.BoundsError @noinline throw_bounds_error(@nospecialize(a::Any), i::Int)::Union{} =
    Runtime.Error__throw_with_current_stack_trace(BoundsError(a, i))

# jl_method_error (julia/src/gf.c:3057), raised by the builtin throw_methoderror (builtins.c:604) where
# Julia's inference proved no method matches a call: MethodError of the function and its arguments'
# tuple (jl_f_tuple). Julia records the task's world age; a compiled program runs in no session's world,
# so the error carries Base's own default, MethodError's two-argument constructor's
@quarantine "julia/src/gf.c:3057 jl_method_error raises MethodError with the function and the tuple of its arguments" Core.MethodError @noinline throw_method_error(@nospecialize(f::Any), @nospecialize(args::Tuple))::Union{} =
    Runtime.Error__throw_with_current_stack_trace(MethodError(f, args))

# Julia's egal of two values of any classes, which Julia's codegen calls for `===` where it cannot
# compare its operands inline (julia/src/codegen.cpp:3379 emit_box_compare: the pointers, then the
# type tags, then jl_egal__unboxed): jl_egal_ (julia.h:1885), its pointer and tag tests and
# jl_egal__unboxed_'s switch over the value's class, the intrinsifier's egal arm (wasm_egal), each
# class's arm builtins.c's own. A root of every closed world, as every function of this section
@quarantine "julia/src/julia.h:1885 jl_egal_ compares two values by their pointers, their type tags and then jl_egal__unboxed_'s arm for their class" Core.Bool @noinline jl_egal(@nospecialize(a::Any), @nospecialize(b::Any))::Bool =
    wasm_egal(a, b)

"""
    wasm_egal(a, b) -> Bool

jl_egal_'s body, which the intrinsifier writes as a class-id switch over the closed world's
classes (src/intrinsics.jl, the egal arm): each class's arm Julia's own (builtins.c:243
jl_egal__bitstag, :100 compare_fields), a field that holds a reference compared by jl_egal again.
Natively Julia's `===`.
"""
@quarantine "julia/src/builtins.c:237 jl_egal__unboxed compares two values of one type by that type's arm; WasmTarget's arm is a class-id switch the intrinsifier writes" Core.:(===) @noinline wasm_egal(@nospecialize(a::Any), @nospecialize(b::Any))::Bool = a === b

# Julia's type of a type tag: a value's header holds its tag, the type read from the table of tags'
# types (julia.h:971 jl_to_typeof over jl_small_typeof). A class id is WasmTarget's tag of every
# class, its type read from the table of each class's type value, translator.classes by id; the code
# generator lowers the call to that read
# (src/intrinsics.jl), and natively no tag exists, so the body raises
@quarantine "julia/src/julia.h:971 jl_to_typeof reads a type tag's type from the table of tags' types (jl_small_typeof)" Core.DataType @noinline jl_to_typeof(tag::Int32) =
    _wasm_only(Core.DataType)

# JL_TYPECHK (julia.h), the check Julia's isa and typeassert builtins make of their type argument
# (builtins.c:584 in jl_f_isa, :591 in jl_f_typeassert): the value itself where it is a type, else
# Julia's TypeError naming the builtin; the code generator calls it before a run-time type test
@quarantine "julia/src/builtins.c:581 jl_f_isa checks its type argument (JL_TYPECHK), raising TypeError naming the builtin, as jl_f_typeassert does" Core.TypeError @noinline jl_typechk_type(fname::Symbol, @nospecialize(t::Any))::Type =
    jl_typetagis(t, Type) ? Runtime.unsafe_cast(Type, t) : Runtime.Error__throw_with_current_stack_trace(TypeError(fname, "", Type, t))

# jl_egal of two host references, a field of a class the egal arm compares (src/intrinsics.jl): wasm
# reads no externref's bits, so the two are compared as dart compares two JS values, JSValue's ==, by
# areEqualInJS, JS's === (Runtime.are_equal_in_js)
@quarantine "sdk/lib/_internal/wasm/js_common/js_helper.dart:42 JSValue.== compares two JS values by areEqualInJS, JS's ===, where Julia's jl_egal compares a field's bits (julia/src/builtins.c:100 compare_fields), which wasm cannot read of a host reference" Core.Bool @noinline jl_egal_host_references(l::WasmExternRef, r::WasmExternRef)::Bool =
    Runtime.are_equal_in_js(l, r)

# jl_egal of two host references in a standalone module, which has no JS runtime and so no areEqualInJS,
# and no wasm instruction compares two externrefs: the comparison raises, naming the gap, never answering
@quarantine "dart2wasm/lib/translator.dart:112 Translator.isStandalone: a standalone module has no JS runtime, so no sdk/lib/_internal/wasm/js_common/js_helper.dart:151 areEqualInJS; Julia's jl_egal compares a field's bits (julia/src/builtins.c:100 compare_fields), which wasm cannot read of a host reference" Core.ErrorException @noinline throw_host_reference_egal()::Union{} =
    Runtime.Error__throw_with_current_stack_trace(ErrorException("WasmTarget: === on two values holding a host reference in a standalone module, which has no JS runtime to compare them (areEqualInJS)"))

# compiler-rt's 128-bit division and remainder (compiler-rt/lib/builtins at the llvm pin), the libcalls
# LLVM's WebAssembly backend makes for an i128 SDIV, SREM, UDIV and UREM (src/llvm/legalize_integer_types.jl,
# ExpandIntRes_SDIV and its kin: wasm has no UDIVREM of an i128), each ported over WasmTarget's 128-bit
# integers (src/intrinsics.jl's int128 arm) and their 64-bit halves, utwords' s.low and s.high, a
# remainder returned beside the quotient where the C stores it through a pointer. Julia's checks run
# first (checked_sdiv_int and its kin raise DivideError), so no divisor is 0

# The 128-bit dividend (u1, u0) divided by v where the quotient fits in 64 bits, and the remainder
# (Hacker's Delight's divlu: Knuth's Algorithm D in 32-bit digits)
@quarantine "compiler-rt/lib/builtins/udivmodti4.c:23 udiv128by64to64default divides a 128-bit dividend by a 64-bit divisor in 32-bit digits, Knuth's Algorithm D" Core.UInt64 @noinline function udiv128by64to64default(u1::UInt64, u0::UInt64, v::UInt64)::Tuple{UInt64,UInt64}
    local n_udword_bits = 64
    local b = UInt64(1) << (n_udword_bits ÷ 2)   # Number base (32 bits)
    local un64::UInt64 = u1; local un10::UInt64 = u0
    # Shift amount for normalization
    local s = leading_zeros(v)
    if s > 0
        # Normalize the divisor
        v = v << s
        un64 = (u1 << s) | (u0 >> (n_udword_bits - s))
        un10 = u0 << s   # Shift dividend left
    else
        # Avoid undefined behavior of (u0 >> 64)
        un64 = u1
        un10 = u0
    end
    # Break divisor up into two 32-bit digits
    local vn1 = v >> (n_udword_bits ÷ 2)
    local vn0 = v & 0xFFFFFFFF
    # Break right half of dividend into two digits
    local un1 = un10 >> (n_udword_bits ÷ 2)
    local un0 = un10 & 0xFFFFFFFF
    # Compute the first quotient digit, q1
    local q1 = div(un64, vn1)
    local rhat = un64 - q1 * vn1
    # q1 has at most error 2. No more than 2 iterations
    while q1 >= b || q1 * vn0 > b * rhat + un1
        q1 = q1 - UInt64(1)
        rhat = rhat + vn1
        rhat >= b && break
    end
    local un21 = un64 * b + un1 - q1 * v
    # Compute the second quotient digit
    local q0 = div(un21, vn1)
    rhat = un21 - q0 * vn1
    # q0 has at most error 2. No more than 2 iterations
    while q0 >= b || q0 * vn0 > b * rhat + un0
        q0 = q0 - UInt64(1)
        rhat = rhat + vn1
        rhat >= b && break
    end
    return (q1 * b + q0, (un21 * b + un0 - q0 * v) >> s)
end

# The 128-by-64 step: x86-64's divq where the target is x86-64, udiv128by64to64default elsewhere, wasm among them
@quarantine "compiler-rt/lib/builtins/udivmodti4.c:84 udiv128by64to64 takes udiv128by64to64default on a target other than x86-64" Core.UInt64 @noinline udiv128by64to64(u1::UInt64, u0::UInt64, v::UInt64)::Tuple{UInt64,UInt64} =
    udiv128by64to64default(u1, u0, v)

# a / b and a % b
@quarantine "compiler-rt/lib/builtins/udivmodti4.c:100 __udivmodti4 is the quotient and remainder of two 128-bit integers, a 64-bit divisor through the 128-by-64 step, a wider one by shift and subtract" Core.UInt128 @noinline function udivmodti4(a::UInt128, b::UInt128)::Tuple{UInt128,UInt128}
    local n_utword_bits = 128
    local dividend = a
    local divisor = b
    local quotient_low = UInt64(0); local quotient_high = UInt64(0); local remainder_low = UInt64(0)
    if divisor > dividend
        return (UInt128(0), dividend)
    end
    local dividend_low = dividend % UInt64
    local dividend_high = (dividend >> 64) % UInt64
    local divisor_low = divisor % UInt64
    local divisor_high = (divisor >> 64) % UInt64
    # When the divisor fits in 64 bits, we can use an optimized path
    if divisor_high == UInt64(0)
        if dividend_high < divisor_low
            # The result fits in 64 bits
            (quotient_low, remainder_low) = udiv128by64to64(dividend_high, dividend_low, divisor_low)
            quotient_high = UInt64(0)
        else
            # First, divide with the high part to get the remainder in dividend.s.high. After that
            # dividend.s.high < divisor.s.low
            quotient_high = div(dividend_high, divisor_low)
            dividend_high = rem(dividend_high, divisor_low)
            (quotient_low, remainder_low) = udiv128by64to64(dividend_high, dividend_low, divisor_low)
        end
        # remainder.s.high = 0
        return ((UInt128(quotient_high) << 64) | UInt128(quotient_low), UInt128(remainder_low))
    end
    # 0 <= shift <= 63
    local shift = leading_zeros(divisor_high) - leading_zeros(dividend_high)
    divisor <<= shift
    quotient_high = UInt64(0)
    quotient_low = UInt64(0)
    while shift >= 0
        quotient_low <<= 1
        # Branch free version of: if (dividend.all >= divisor.all) dividend.all -= divisor.all, carry = 1
        local s = reinterpret(UInt128, reinterpret(Int128, divisor - dividend - UInt128(1)) >> (n_utword_bits - 1))
        quotient_low |= (s % UInt64) & UInt64(1)
        dividend -= divisor & s
        divisor >>= 1
        shift -= 1
    end
    return ((UInt128(quotient_high) << 64) | UInt128(quotient_low), dividend)
end

# a / b
@quarantine "compiler-rt/lib/builtins/udivti3.c:19 __udivti3 is __udivmodti4's quotient" Core.UInt128 @noinline udivti3(a::UInt128, b::UInt128)::UInt128 = udivmodti4(a, b)[1]

# a % b
@quarantine "compiler-rt/lib/builtins/umodti3.c:19 __umodti3 is __udivmodti4's remainder" Core.UInt128 @noinline umodti3(a::UInt128, b::UInt128)::UInt128 = udivmodti4(a, b)[2]

# a / b, signed: the magnitudes' quotient, negated where the signs differ
@quarantine "compiler-rt/lib/builtins/divti3.c:24 __divti3 returns compiler-rt/lib/builtins/int_div_impl.inc:73 __divXi3, the magnitudes' quotient (COMPUTE_UDIV, __udivmodti4's) with the operands' signs' xor" Core.Int128 @noinline function divti3(a::Int128, b::Int128)::Int128
    local N = 127
    local s_a = a >> N   # s_a = a < 0 ? -1 : 0
    local s_b = b >> N   # s_b = b < 0 ? -1 : 0
    local a_u = reinterpret(UInt128, a ⊻ s_a) + reinterpret(UInt128, -s_a)   # negate if s_a == -1
    local b_u = reinterpret(UInt128, b ⊻ s_b) + reinterpret(UInt128, -s_b)   # negate if s_b == -1
    s_a ⊻= s_b   # sign of quotient
    return reinterpret(Int128, (udivmodti4(a_u, b_u)[1] ⊻ reinterpret(UInt128, s_a)) + reinterpret(UInt128, -s_a))   # negate if s_a == -1
end

# a % b, signed: the magnitudes' remainder, the dividend's sign
@quarantine "compiler-rt/lib/builtins/modti3.c:24 __modti3 returns compiler-rt/lib/builtins/int_div_impl.inc:85 __modXi3, the magnitudes' remainder (ASSIGN_UMOD, __udivmodti4's) with the dividend's sign" Core.Int128 @noinline function modti3(a::Int128, b::Int128)::Int128
    local N = 127
    local s = b >> N   # s = b < 0 ? -1 : 0
    local b_u = reinterpret(UInt128, b ⊻ s) + reinterpret(UInt128, -s)   # negate if s == -1
    s = a >> N   # s = a < 0 ? -1 : 0
    local a_u = reinterpret(UInt128, a ⊻ s) + reinterpret(UInt128, -s)   # negate if s == -1
    local res = udivmodti4(a_u, b_u)[2]
    return reinterpret(Int128, (res ⊻ reinterpret(UInt128, s)) + reinterpret(UInt128, -s))   # negate if s == -1
end

# ---- end of Julia's runtime ----

# Julia's test of a value's kind by its type tag (julia.h:136 jl_typetagis, as jl_is_datatype and
# jl_is_uniontype read it): the value's class id against the classes under `K` (getConcreteClassIdRange,
# a kind's one class, or every kind for Type), the intrinsifier's class-id range check. The runtime's
# type code tests a type value's kind by it, holding no type test of its own (`isa`), as dart's type.dart
# tests by ClassID.getID. Natively no tag exists, so the body raises
@quarantine "julia/src/julia.h:136 jl_typetagis tests a value's type tag" Core.Bool @noinline jl_typetagis(@nospecialize(x::Any), ::Type{K}) where {K} =
    _wasm_only(Bool)

"""
    run_time_type_test!(translator, at)

Records a type test against a type value only run time knows (types.dart's `_isSubtype`/`_asSubtype`
of a value, src/runtime/common/type.jl), at `at`, and on the first one registers the link-time check
of the program's type values (`check_run_time_type_values`).
"""
@quarantine "dart patches a read once every use is known, in a linking action (pkg/dart2wasm/lib/constants.dart:1860 _ConstantAccessor.loadConstant); a run-time type test is checked against the program's type values once every function is generated" Base.isempty function run_time_type_test!(translator, at::String)::Nothing
    local tests = translator.types[].rtt[].run_time_type_tests
    isempty(tests) && push!(translator.linking_actions, () -> check_run_time_type_values(translator))
    push!(tests, at)
    return nothing
end

"""
    run_time_type_gap(T) -> Union{Nothing,Rejection}

Why the runtime's type test cannot decide `T`, or `nothing` where it can: it decides a class's
DataType by the class table, Any (dart's _TopType), Union{} (dart's _BottomType) and a Union by its
members. A UnionAll or a free TypeVar, which Julia's subtype decides by its environment
(julia/src/subtype.c:1419), and a Type{X}, whose values jl_isa tells by jl_types_equal
(subtype.c:2523), are Julia's own, with no dart kind: Unquarantined. A tuple type but Tuple{}, dart's
record type, waits for _RecordType._checkInstance to read a record's fields (a tuple in a top-typed slot
is its arity's record, src/julia/classes.jl TupleRecord, under no class-table row): Unported. The one
reading the code generator's general arm (types.jl, a constant type) and the link-time walk (a type only
run time knows) share.
"""
@quarantine "julia/src/subtype.c:2511 jl_isa decides a UnionAll by its environment and a Type{X} by jl_types_equal, which the runtime does not port" Base.isType function run_time_type_gap(@nospecialize(T::Type))::Union{Nothing,Rejection}
    (T isa UnionAll || Base.has_free_typevars(T)) &&
        return Unquarantined("src/julia/runtime/rtutils.jl run_time_type_gap: the type $T, a UnionAll or a free TypeVar, which a run-time type test cannot decide (julia/src/subtype.c:1419, its environment)")
    if T isa Union
        for m in Base.uniontypes(T)
            local g = run_time_type_gap(m)
            g === nothing || return g
        end
        return nothing
    end
    T isa DataType && Base.isType(T) &&
        return Unquarantined("src/julia/runtime/rtutils.jl run_time_type_gap: the type $T, whose values jl_isa tells by jl_types_equal (julia/src/subtype.c:2523), a kind dart has no counterpart of")
    T isa DataType && T <: Tuple && T !== Tuple{} && return Unported("sdk/lib/_internal/wasm/common/type.dart:585 _RecordType._checkInstance")
    return nothing
end

"""
    run_time_type_value!(code_gen, value, fname)

Pushes a type only run time knows for the runtime's type test: records the test (run_time_type_test!,
the link-time check), then the value checked a type as Julia's isa and typeassert check it
(jl_typechk_type, JL_TYPECHK naming `fname`). The type's own value where dart's makeType builds a type
from the type parameters in scope (types.dart:349).
"""
@quarantine "julia/src/builtins.c:581 jl_f_isa checks its type argument (JL_TYPECHK); dart's makeType builds a type from its parameters in scope (pkg/dart2wasm/lib/types.dart:349 Types.makeType)" Base.string function run_time_type_value!(code_gen, value::NirValue, fname::Symbol)::Nothing
    local t = code_gen.translator
    local at = "$(code_gen.enclosing_member)"
    run_time_type_test!(t, at)
    Dart2Wasm.instantiate_constant(code_gen, NirConst(Core.Const(fname)), Dart2Wasm.translate_type(t, Symbol))
    Dart2Wasm.translate_expression(code_gen, value, t.top_type[])
    Dart2Wasm.call(code_gen, nir_runtime_member(t.component, jl_typechk_type, at))
    return nothing
end

"""
    check_run_time_type_values(translator)

A run-time type test decides by the kinds the runtime ports (type.dart's `_checkInstance`: a class's
DataType by the class table, a Union by its members, Union{}), so every type value the program holds
must be one of those: each literal operand of the program's own bodies (WasmTarget's runtime aside)
and each binding they read (a NirGlobal operand, a GlobalRef statement, its value at compile time), and
every value those hold, their elements and fields. A UnionAll or a free TypeVar, which
Julia's subtype decides by its environment (julia/src/subtype.c:1419), rejects, Unquarantined, at the
first run-time test; a Type{X} (jl_isa's `jl_types_equal`, subtype.c:2523) or a tuple type but Tuple{}
(type.dart's `_RecordType._checkInstance`, reading a record's fields) rejects, Unported, there. A program's type value is a literal:
one made at run time (apply_type, typeof) rejects at its statement (src/intrinsics.jl).
"""
@quarantine "julia/src/subtype.c:2511 jl_isa decides a UnionAll by subtyping with an environment, which the runtime does not port; dart patches what every use needs once every use is known (pkg/dart2wasm/lib/constants.dart:1860 _ConstantAccessor.loadConstant)" Base.IdSet function check_run_time_type_values(translator)::Nothing
    local at = first(translator.types[].rtt[].run_time_type_tests)
    local seen = Base.IdSet{Any}()
    local visit(@nospecialize(v)) = begin
        (v isa Union{Module,Function,Symbol,String,Number,Nothing} || v in seen) && return
        push!(seen, v)
        if v isa Type
            local gap = run_time_type_gap(v)
            gap === nothing || reject!(gap, "$at: a run-time type test where the program holds the type $v")
        elseif v isa Union{Tuple,Core.SimpleVector,AbstractArray}
            for x in v
                visit(x)
            end
        elseif isstructtype(typeof(v))
            for i in 1:nfields(v)
                isdefined(v, i) && visit(getfield(v, i))
            end
        end
    end
    for body in translator.component
        local m = body.ci.def.def
        m isa Method && (parentmodule(m) === Runtime || m.module === @__MODULE__) && continue
        for st in body.stmts, x in nir_operands(st)
            # the type an isa or a typeassert names as a literal is the static test's (types.jl
            # emitIsTest, emitAsCheck), never a value a run-time test meets
            st isa NirCall && (nir_callee(st) === Core.isa || nir_callee(st) === Core.typeassert) &&
                length(st.args) == 3 && x === st.args[3] && continue
            x isa NirConst && visit(x.c.val)
            # a binding's value, the other place a program's value comes from at compile time
            # (src/julia/classes.jl meets each)
            x isa NirGlobal && isdefined(x.ref.mod, x.ref.name) && visit(getglobal(x.ref.mod, x.ref.name))
        end
        for st in body.stmts
            st isa NirGlobalRead && isdefined(st.ref.mod, st.ref.name) && visit(getglobal(st.ref.mod, st.ref.name))
        end
    end
    return nothing
end

"""
    nir_runtime_member(world, f) -> Core.MethodInstance

The MethodInstance of the runtime's function `f` in the closed world `world`: an entry point's
(RUNTIME_ROOTS keeps each) or a callee one reaches, its one specialization there, the method
dart2wasm's KernelNodes names by `index.getProcedure`. None, or more than one, is WasmTarget's own
defect.
"""
@quarantine "the runtime's method is found among the closed world's CodeInstances, by its Method" Core.MethodInstance function nir_runtime_member(world::NirWorld, f::Function, at::String)::Core.MethodInstance
    local ms = methods(f)
    local hits = Core.MethodInstance[b.ci.def for b in world if b.ci.def.def in ms]
    length(hits) == 1 || reject!(Internal("src/julia/runtime/rtutils.jl nir_runtime_member: $f has $(length(hits)) specializations in the closed world, not one"), at)
    return only(hits)
end

# the exception tag's export name (src/tags.jl _define_dart_exception_tag): a host matches a Julia
# exception by the tag the main module exports under it. `$` keeps it apart from every export a
# program names, a Julia identifier holding none
@quarantine "dart exports no tag for its host; a Julia program's host matches its exceptions by the exported tag" Core.String const EXCEPTION_TAG_EXPORT::Core.String = "\$exceptionTag"

# the module of the JS string builtins (`builtins: ['js-string']`, the JS String Builtins proposal's
# `wasm:js-string`), which the engine supplies or the JS runtime's polyfill stands in for
# (src/js/runtime_generator.jl's JS_POLYFILL_IMPORT): one name for both
@quarantine "dart's runtime imports its JS string polyfill (pkg/dart2wasm/lib/js/runtime_blob.dart:126 jsStringPolyfill) under the JS string builtins' module name (runtime_generator.dart:150); WasmTarget's host imports read the same name" Core.String const JS_STRING_BUILTINS_MODULE::Core.String = "wasm:js-string"

# the standalone embedder's module, which every import of dart's standalone embedder library names
# (`@pragma("wasm:import", "dart.<name>")`), its functions the embedder's own
@quarantine "dart's standalone embedder library names its imports' module (sdk/lib/_internal/wasm/standalone/embedder.dart:238 stackTraceGetCurrent); WasmTarget's host imports read the same name" Core.String const STANDALONE_EMBEDDER_MODULE::Core.String = "dart"

# the library a port's foreign call names for dart's inline JS (`JS<T>(code, ...)` of dart:_js_helper):
# the runtime's internal interop module, whose name the interop namer gives at the import
# (interop_module_name, "dart2wasm" or "_" when minified), its symbol the JS code itself
# (nir_js_sites), as Julia's own llvmcall carries its IR text as an argument of the call
# (julia/src/ccall.cpp:721 emit_llvmcall). Only the runtime's ports may name it, as only dart's internal
# libraries may import dart:_js_helper (nir_foreign_import)
@quarantine "dart's inline JS is an import of the internal interop module (pkg/dart2wasm/lib/namer.dart:108 _InteropHelperMemberNamer.interopModuleName); a Julia port names it in its foreign call" Core.String const JS_INTEROP_LIBRARY::Core.String = "dart2wasm"

"""
    nir_statement_frame(body, k) -> Tuple{Method,Int}

Where statement `k` of `body` was written: the innermost frame of its debug info (Julia's own
reading, IRShow's buildLineInfoNode), the inlined callee's where Julia inlined it, else the body's own
method's: its method and line.
"""
@quarantine "Julia records where each statement was written, inlined frames innermost last (julia/Compiler/src/ssair/show.jl:405 buildLineInfoNode)" Core.Method function nir_statement_frame(body::NirBody, k::Int)::Tuple{Method,Int}
    local frames = Base.IRShow.buildLineInfoNode(body.ci.debuginfo, body.ci.def, k)
    local own = body.ci.def.def::Method
    isempty(frames) && return (own, Int(own.line))
    local f = last(frames)
    local m = f.method isa Core.MethodInstance ? f.method.def : f.method
    return m isa Method ? (m, Int(f.line)) : (own, Int(f.line))
end

"""
    nir_js_site(method, line) -> String

An inline JS site's key, where it was written: its method, by its module, name and signature (two
methods of one name are two), and its line, `"<module>.<name><signature>:<line>"`. Julia's debug info
records no column, so two sites on one line are one key (nir_js_sites refuses two codes at one).
"""
@quarantine "dart makes one inline JS procedure per written site (pkg/dart2wasm/lib/js/inline_expander.dart:21 InlineExpander.expand); Julia records a statement's method and line in its debug info, no column" Core.Method nir_js_site(m::Method, line::Int)::String =
    "$(m.module).$(m.name)$(Base.unwrap_unionall(m.sig).parameters[2:end]):$line"

"""
    nir_js_sites(world, mi) -> Vector{Tuple{String,String,String}}

The inline JS sites `mi`'s body hands its host (dart's JsCodeData, the `wasm:js-code` pragma
JsInteropMemberData.fromMember reads from the procedure dart's inline expander makes of each JS<T>
site, js/util.dart:33, one `_JS_Inline_<n>` per site, inline_expander.dart:64): each foreign call to the internal interop
module (JS_INTEROP_LIBRARY), in statement order, as `(site, name, code)`. A site is where it was
written, the innermost frame of its debug info (nir_statement_frame), its method and line
(nir_js_site), so a site Julia inlined into several callers is one site, as dart's is one procedure;
`name` is its method's, the base of its import's name; `code` its symbol. Two codes at one site, two
sites written on one line, refuse, located.
"""
@quarantine "dart makes one inline JS procedure per written site (pkg/dart2wasm/lib/js/inline_expander.dart:21 InlineExpander.expand); Julia records a site's method and line in its debug info" Core.String function nir_js_sites(world::NirWorld, mi::Core.MethodInstance)::Vector{Tuple{String,String,String}}
    local body = nir_body_of(world, mi)
    local out = Tuple{String,String,String}[]
    for (k, st) in enumerate(body.stmts)
        st isa NirForeignCall && st.args[1] isa NirConst || continue
        local name = st.args[1].c.val
        name isa Tuple{Union{Symbol,String},Union{Symbol,String}} && String(name[2]) == JS_INTEROP_LIBRARY || continue
        local (m, line) = nir_statement_frame(body, k)
        local site = nir_js_site(m, line)
        local code = String(name[1])
        local seen = findfirst(x -> x[1] == site, out)
        if seen === nothing
            push!(out, (site, String(m.name), code))
        elseif out[seen][3] != code
            # two sites on one line, whose debug info tells them apart by no column: one name would run
            # the first's JS for both
            reject!(Internal("src/julia/runtime/rtutils.jl nir_js_sites: two inline JS sites at $site, $(repr(out[seen][3])) and $(repr(code)): a runtime port writes each on its own line"), "nir_js_sites")
        end
    end
    return out
end

"""
    host_modules() -> Vector{String}

The modules a WasmTarget host supplies to a module's imports: the property names of the JS runtime's
`baseImports` object (src/js/runtime_blob.jl, dart's runtime_blob.dart:84), read by dart's mini JS
parser (src/julia/js_parser.jl, pkg/js_ast's MiniJsParser) from the template instantiated as the
runtime generator instantiates it for a program with no interop methods and no string constants (every
variable empty but the internal imports' module name, a hole `#`, the runtime's own, never a program's
host library), the JS string builtins' module, which the engine or the runtime's polyfill supplies
(the generator's JS_POLYFILL_IMPORT, JS_STRING_BUILTINS_MODULE), and the standalone embedder's module
(STANDALONE_EMBEDDER_MODULE), which a module compiled without JavaScript imports from. Read once
(HOST_MODULES).
"""
@quarantine "Julia's foreign call names a library; the host's libraries are the import object dart's runtime blob declares (its baseImports in pkg/dart2wasm/lib/js/runtime_blob.dart:5 jsRuntimeBlobTemplate), read by dart's own JS parser from the template's one statement declaring it, found by that declaration's text: the template is a module with a class, no program the mini parser takes whole, so the statement is not read as its parseVariableDeclarationList reads one (pkg/js_ast/lib/src/builder.dart:1142 MiniJsParser.parseVariableDeclarationList)" Base.findfirst function host_modules()::Vector{String}
    local template = Dart2Wasm.js_runtime_blob_template[]
    local vars = Dict{String,String}(p.variable => (p.variable == "INTERNAL_IMPORTS_MODULE_NAME" ? "#$(p.variable)" : "")
                                     for p in template._parts if p isa Dart2Wasm._TemplateVariablePart)
    local text = Dart2Wasm.instantiate(template, vars)
    local declaration = "const baseImports = "
    local at = findfirst(declaration, text)
    at === nothing && reject!(Internal("src/julia/runtime/rtutils.jl host_modules: the JS runtime's template declares no baseImports object"), "host_modules")
    local parser = MiniJsParser(text[last(at)+1:end])
    js_expect_category!(parser, :lbrace)
    local out = String[name for name in js_parse_object_initializer!(parser) if name !== nothing]
    push!(out, JS_STRING_BUILTINS_MODULE, STANDALONE_EMBEDDER_MODULE)
    return out
end

# the host's modules, read once from the template (host_modules), as dart's runtime generator holds
# its template once
@quarantine "the host's modules are read once, the template being fixed (pkg/dart2wasm/lib/js/runtime_blob.dart:5 jsRuntimeBlobTemplate)" Core.String const HOST_MODULES = Late{Vector{String}}("src/julia/runtime/rtutils.jl HOST_MODULES", host_modules)

"""
    NirForeignImport

The callee of a foreign call to a library the host supplies, as Julia's ccall lowering reads it at
the call site (julia/src/ccall.cpp:1419 emit_ccall): its library and symbol (interpret_symbol_arg),
the Julia type each argument crosses as (`params`) and the declared return type (`rt`). A wasm
import: dart2wasm's ffi transformer makes a `@Native<sig>(symbol:, asset:)` declaration a synthesized
procedure `@pragma("wasm:import", "<asset>.<symbol>")` typed by its native signature
(pkg/dart2wasm/lib/ffi_native_transformer.dart:159 visitProcedure), which getFunction imports; this is
that procedure for one call site, typed, as dart types it, by the declared signature. An argument
declared `Any` crosses by one rule keyed by its operand's class (nir_foreign_param_type): the top
reference type, as julia_to_native passes every boxed argument as one jl_value_t*
(julia/src/ccall.cpp:528 julia_to_native), but for a class of dart:_wasm's, which crosses as that
wasm type, nullable, as dart declares such a parameter (`WasmArray<WasmI16>? array`,
sdk/lib/_internal/wasm/js_common/js_string.dart:858 jsStringFromCharCodeArray).

precedent(julia: src/ccall.cpp:1980 function_sig_t::emit_a_ccall, which declares the callee in
the module by its symbol and the call site's signature, getOrInsertFunction). Julia's differs: a
foreign call is a statement, not a declaration, so each call site names its import.
"""
@quarantine "Julia's ccall lowering reads a foreign call's callee at its call site (julia/src/ccall.cpp:1419 emit_ccall); dart2wasm's ffi transformer makes the callee a wasm:import procedure (pkg/dart2wasm/lib/ffi_native_transformer.dart:160 WasmFfiNativeTransformer.visitProcedure)" Core.Type struct NirForeignImport
    lib::String
    name::String
    params::Vector{Type}
    rt::Type
    # an inline JS site's place and its method's name (nir_js_sites), "" for a host call
    site::String
    site_name::String
end

# what a function type is made for (_makeFunctionType, _getInputTypes, typeOfReturnValue): dart's
# Reference, a member or a field's accessor, and the import procedure dart2wasm's ffi transformer
# synthesizes for a foreign declaration (NirForeignImport), a closed sum matched @exhaustive
@quarantine "dart types a function for a member's Reference (pkg/dart2wasm/lib/functions.dart:890 _makeFunctionType), the ffi transformer's import procedure among them; a closed sum is a Union in Julia" Core.Union @closed const FunctionTarget = Union{MethodInstance, FieldReference, NirForeignImport}

"""
    nir_foreign_operands(node) -> Vector{NirValue}

The arguments a foreign call passes, one per declared argument type, Julia's `args[6:5+nccallargs]`
(julia/src/ccall.cpp:1419 emit_ccall); the GC roots after them are no argument.
"""
@quarantine "Julia's foreigncall lists its arguments after its five header operands (julia/src/ccall.cpp:1419 emit_ccall)" Core.SimpleVector function nir_foreign_operands(node::NirForeignCall)::Vector{NirValue}
    local at = node.args[3]
    local types = at isa NirConst ? at.c.val : nothing
    types isa Core.SimpleVector ||
        reject!(Internal("src/julia/runtime/rtutils.jl nir_foreign_operands: a foreign call whose argument types are no constant svec"), "nir_foreign_operands")
    return node.args[6:5 + length(types)]
end

"""
    nir_foreign_import(body, node) -> Union{NirForeignImport,Nothing}

The host import a foreign call of `body` calls (NirForeignImport), read as Julia's ccall lowering
reads it (julia/src/ccall.cpp:1419 emit_ccall): its name a literal `(symbol, library)`
(interpret_symbol_arg) whose library is a host module (`host_modules`), its calling convention C
(convert_cconv), its argument count fixed. A call to any other library is no import, nothing, and the
code generator rejects it, located; a host call by another convention or with C varargs, which a
wasm import cannot take, rejects here, located.
"""
@quarantine "Julia's ccall lowering reads the callee's name, convention and signature from the foreigncall (julia/src/ccall.cpp:571 interpret_symbol_arg)" Core.SimpleVector function nir_foreign_import(body::NirBody, node::NirForeignCall)::Union{NirForeignImport,Nothing}
    local at = "src/julia/runtime/rtutils.jl nir_foreign_import"
    local sym = node.args[1]
    sym isa NirConst && sym.c.val isa Tuple{Union{Symbol,String},Union{Symbol,String}} || return nothing
    local item, lib = String(sym.c.val[1]), String(sym.c.val[2])
    lib in HOST_MODULES[] || lib == JS_INTEROP_LIBRARY || return nothing
    # inline JS is the runtime's own (dart:_js_helper, an internal library no program imports): a call to
    # the interop module written outside Runtime's ports is the program's error, located
    local site, site_name = "", ""
    if lib == JS_INTEROP_LIBRARY
        local k = findfirst(st -> st === node, body.stmts)
        local frame = k === nothing ? nothing : nir_statement_frame(body, k)
        frame !== nothing && frame[1].module === Runtime ||
            reject!(ProgramError("src/julia/runtime/rtutils.jl nir_foreign_import: the foreign call $(repr(item)) of the runtime's internal interop module $lib, written outside WasmTarget's runtime, as no program may import dart's internal dart:_js_helper"), at)
        # the site is where it was written (nir_js_sites), one name per written site
        site, site_name = nir_js_site(frame...), String(frame[1].name)
    end
    local rt, argtypes, nreq, cc = node.args[2], node.args[3], node.args[4], node.args[5]
    rt isa NirConst && rt.c.val isa Type && argtypes isa NirConst && argtypes.c.val isa Core.SimpleVector ||
        reject!(Internal("$at: the foreign call $lib.$item, whose return and argument types are no constants"), at)
    # convert_cconv: `ccall` is C's convention, the one a wasm import has
    local conv = cc isa NirConst ? (cc.c.val isa Tuple ? cc.c.val[1] : cc.c.val) : nothing
    conv === :ccall || conv === :cdecl ||
        reject!(Unquarantined("$at: the foreign call $lib.$item by the convention $(repr(conv)), where a wasm import takes C's"), at)
    # nreqargs > 0 is a C varargs function, which no wasm import's fixed arity takes
    nreq isa NirConst && nreq.c.val == 0 ||
        reject!(Unquarantined("$at: the foreign call $lib.$item of a C varargs function, which no wasm import's fixed arity takes"), at)
    all(t -> t isa Type, argtypes.c.val) ||
        reject!(Internal("$at: the foreign call $lib.$item, an argument type of which is no type: $(argtypes.c.val)"), at)
    local operands = nir_foreign_operands(node)
    local params = Type[t === Any ? nir_foreign_param_type(nir_value_type(body, operands[i])) : t for (i, t) in enumerate(argtypes.c.val)]
    return NirForeignImport(lib, item, params, rt.c.val, site, site_name)
end

"""
    nir_foreign_param_type(T) -> Type

The type a foreign call's argument declared `Any` crosses as, given its operand's inferred type `T`,
one rule keyed by class, so every call site of a foreign function passing one class shares one
import type: a class of dart:_wasm's (a WasmArray, WasmExternRef), the operand `nothing` aside,
crosses as that wasm type, nullable, as dart declares such a parameter; any other is Julia's top type,
`Any`, the one jl_value_t* julia_to_native passes for a boxed argument.
"""
@quarantine "Julia passes an Any argument as one boxed reference (julia/src/ccall.cpp:528 julia_to_native); dart declares a wasm-typed parameter as its nullable wasm type (sdk/lib/_internal/wasm/js_common/js_string.dart:858 jsStringFromCharCodeArray)" Core.Union function nir_foreign_param_type(@nospecialize(T::Type))::Type
    local cls = T isa Union ? Base.nonnothingtype(T) : T
    cls isa DataType && (cls <: WasmArray || cls === WasmExternRef) && return Union{Nothing, cls}
    return Any
end
