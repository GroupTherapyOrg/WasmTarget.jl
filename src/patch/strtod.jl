# Base's parse of a Float64 or a Float32 by overlay (julia/base/parse.jl:262-300): each tryparse and
# tryparse_internal of a String or a SubString{String} asks libjulia's jl_try_substrtod or jl_try_substrtof
# (julia/src/rtutils.c:466, :525), which call jl_strtod_c or jl_strtof_c (julia/src/support/strtod.c:30,
# :35), the host libc's strtod_l and strtof_l in the C locale. A wasm module has no libjulia and no libc.
# The port follows Julia's own C where it has it and LLVM where it has the rest:
# - jl_try_substrtod and jl_try_substrtof as rtutils.c writes them, over the String's bytes between the
#   offset and its end (the C copies the substring to a NUL-terminated buffer when the byte after it could
#   continue a number: the port reads a NUL there, as that buffer holds);
# - jl_strtod_c as julia/src/support/strtod.c:101 writes it for a host with no strtod_l (Julia's own
#   portable definition: leading space, inf and nan by parse_inf_or_nan, the sign, the hexadecimal
#   prefix), its call of the system strtod on the unsigned digits the longest subject sequence C11's
#   strtod reads (7.22.1.3p3: decimal digits with an optional point and an optional e-exponent, or
#   hexadecimal ones after 0x with an optional p-exponent), converted, correctly rounded to nearest even,
#   by LLVM's APFloat (llvm/lib/Support/APFloat.cpp IEEEFloat::convertFromString and its decimal and
#   hexadecimal paths, over APInt's word arithmetic, llvm/lib/Support/APInt.cpp);
# - ERANGE is APFloat's overflow or underflow status, as libc sets it.
# Julia differs (D7): libc's strtod_l also reads nan(n-char-sequence) (C11 7.22.1.3p3); its payload's
# meaning is the host's (glibc reads it as an integer, Apple's libc as hexadecimal digits), so `nan()`
# reads as nan and a non-empty sequence raises, naming the gap. test/src/strtod.jl compares every overlay
# with Base's, which calls libc, natively over a wide sample, and compiled against native Julia.
# precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a device's
# overlays of Base in its method table).

# ---------------------------------------------------------------------------------------------------
# APInt's word arithmetic (llvm/lib/Support/APInt.cpp, "a representation of arbitrary precision,
# two's-complement, bignum integer values"). Julia differs: a C pointer into a word array is the array
# and a 0-based offset into it (`dst, d`); APInt::WordType is a UInt64, APINT_BITS_PER_WORD 64.

# APInt.cpp:2358 lowBitMask: the word with its least significant BITS bits set (BITS in 1:64)
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2358 lowBitMask)" "the word with its low bits set, as APInt's bignum routines mask a word; a wasm module has no libjulia whose libc or LLVM holds it" Base.:>> apint_lowBitMask(bits::UInt32)::UInt64 =
    typemax(UInt64) >> (UInt32(64) - bits)

# APInt.cpp:2364 lowHalf and :2368 highHalf: a word's lower and upper 32 bits
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2364 lowHalf)" "the lower half of a word, as APInt's multiplication splits a word" Base.:& apint_lowHalf(part::UInt64)::UInt64 =
    part & apint_lowBitMask(UInt32(32))
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2369 highHalf)" "the upper half of a word, as APInt's multiplication splits a word" Base.:>> apint_highHalf(part::UInt64)::UInt64 =
    part >> 32

# APInt.cpp:2375 APInt::tcSet: the least significant part set to PART, the higher parts zeroed
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2375 APInt::tcSet)" "a bignum set to one word, as APInt's tcSet sets it" Base.:+ function apint_tcSet!(dst::Vector{UInt64}, d::Int, part::UInt64, parts::Int)::Nothing
    dst[d + 1] = part
    for i in 1:parts-1
        dst[d + i + 1] = UInt64(0)
    end
    return nothing
end

# APInt.cpp:2383 APInt::tcAssign: one bignum assigned to another
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2383 APInt::tcAssign)" "a bignum assigned to another, as APInt's tcAssign copies it" Base.:+ function apint_tcAssign!(dst::Vector{UInt64}, d::Int, src::Vector{UInt64}, s::Int, parts::Int)::Nothing
    for i in 0:parts-1
        dst[d + i + 1] = src[s + i + 1]
    end
    return nothing
end

# APInt.cpp:2389 APInt::tcIsZero
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2389 APInt::tcIsZero)" "whether a bignum is zero, as APInt's tcIsZero answers" Base.:+ function apint_tcIsZero(src::Vector{UInt64}, s::Int, parts::Int)::Bool
    for i in 0:parts-1
        src[s + i + 1] != 0 && return false
    end
    return true
end

# APInt.cpp:2398 APInt::tcExtractBit: bit BIT of a bignum, 0 or 1 (whichWord and maskBit, APInt.h:1983, :1998)
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2398 APInt::tcExtractBit)" "one bit of a bignum, as APInt's tcExtractBit reads it" Base.:<< apint_tcExtractBit(parts::Vector{UInt64}, p::Int, bit::UInt32)::Int =
    (parts[p + Int(bit ÷ UInt32(64)) + 1] & (UInt64(1) << (bit % UInt32(64)))) != 0 ? 1 : 0

# APInt.cpp:2403 APInt::tcSetBit
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2403 APInt::tcSetBit)" "one bit of a bignum set, as APInt's tcSetBit sets it" Base.:<< function apint_tcSetBit!(parts::Vector{UInt64}, p::Int, bit::UInt32)::Nothing
    local w = p + Int(bit ÷ UInt32(64)) + 1
    parts[w] = parts[w] | (UInt64(1) << (bit % UInt32(64)))
    return nothing
end

# APInt.cpp:2414 APInt::tcLSB: the least significant set bit's number, UINT_MAX where none is set
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2414 APInt::tcLSB)" "a bignum's least significant set bit, as APInt's tcLSB finds it" Base.trailing_zeros function apint_tcLSB(parts::Vector{UInt64}, p::Int, n::Int)::UInt32
    for i in 0:n-1
        local w = parts[p + i + 1]
        w != 0 && return UInt32(trailing_zeros(w) + i * 64)
    end
    return typemax(UInt32)
end

# APInt.cpp:2427 APInt::tcMSB: the most significant set bit's number, UINT_MAX where none is set
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2427 APInt::tcMSB)" "a bignum's most significant set bit, as APInt's tcMSB finds it" Base.leading_zeros function apint_tcMSB(parts::Vector{UInt64}, p::Int, n::Int)::UInt32
    while n > 0
        n -= 1
        local w = parts[p + n + 1]
        w != 0 && return UInt32(63 - leading_zeros(w) + n * 64)
    end
    return typemax(UInt32)
end

# APInt.cpp:2447 APInt::tcExtract: the srcBITS bits of SRC from bit srcLSB copied to DST, its higher bits zero
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2447 APInt::tcExtract)" "a bit field of one bignum copied into another, as APInt's tcExtract copies it" Base.:<< function apint_tcExtract!(dst::Vector{UInt64}, d::Int, dstCount::Int, src::Vector{UInt64}, s::Int, srcBits::UInt32, srcLSB::UInt32)::Nothing
    local dstParts = Int((srcBits + UInt32(63)) ÷ UInt32(64))
    dstParts <= dstCount || throw(ErrorException("WasmTarget: APInt::tcExtract (llvm/lib/Support/APInt.cpp): more parts than the destination holds"))
    local firstSrcPart = Int(srcLSB ÷ UInt32(64))
    apint_tcAssign!(dst, d, src, s + firstSrcPart, dstParts)
    local shift = srcLSB % UInt32(64)
    apint_tcShiftRight!(dst, d, dstParts, shift)
    # now (dstParts * 64 - shift) bits of SRC are in DST: append the rest, or clear the high bits
    local n = UInt32(dstParts * 64) - shift
    if n < srcBits
        local mask = apint_lowBitMask(srcBits - n)
        dst[d + dstParts] = dst[d + dstParts] | ((src[s + firstSrcPart + dstParts + 1] & mask) << (n % UInt32(64)))
    elseif n > srcBits
        if srcBits % UInt32(64) != 0
            dst[d + dstParts] = dst[d + dstParts] & apint_lowBitMask(srcBits % UInt32(64))
        end
    end
    while dstParts < dstCount
        dst[d + dstParts + 1] = UInt64(0)
        dstParts += 1
    end
    return nothing
end

# APInt.cpp:2499 APInt::tcAddPart: SRC added to the bignum, the carry out returned; APInt.h's tcIncrement
# is tcAddPart of 1
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2499 APInt::tcAddPart)" "a word added to a bignum, as APInt's tcAddPart adds it" Base.:+ function apint_tcAddPart!(dst::Vector{UInt64}, d::Int, src::UInt64, parts::Int)::UInt64
    for i in 0:parts-1
        dst[d + i + 1] = dst[d + i + 1] + src
        dst[d + i + 1] >= src && return UInt64(0)
        src = UInt64(1)
    end
    return UInt64(1)
end

# APInt.cpp:2512 APInt::tcSubtract: DST -= RHS + C, the borrow returned
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2512 APInt::tcSubtract)" "one bignum subtracted from another, as APInt's tcSubtract subtracts it" Base.:- function apint_tcSubtract!(dst::Vector{UInt64}, d::Int, rhs::Vector{UInt64}, r::Int, c::UInt64, parts::Int)::UInt64
    for i in 0:parts-1
        local l = dst[d + i + 1]
        if c != 0
            dst[d + i + 1] = l - (rhs[r + i + 1] + UInt64(1))
            c = dst[d + i + 1] >= l ? UInt64(1) : UInt64(0)
        else
            dst[d + i + 1] = l - rhs[r + i + 1]
            c = dst[d + i + 1] > l ? UInt64(1) : UInt64(0)
        end
    end
    return c
end

# APInt.cpp:2565 APInt::tcMultiplyPart: DST (+)= SRC * MULTIPLIER + CARRY over dstParts parts, 1 where the
# result overflowed them
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2565 APInt::tcMultiplyPart)" "a bignum multiplied by a word, as APInt's tcMultiplyPart multiplies it" Base.:* function apint_tcMultiplyPart!(dst::Vector{UInt64}, d::Int, src::Vector{UInt64}, s::Int, multiplier::UInt64, carry::UInt64, srcParts::Int, dstParts::Int, add::Bool)::Int
    local n = min(dstParts, srcParts)
    for i in 0:n-1
        local srcPart = src[s + i + 1]
        local low::UInt64, mid::UInt64, high::UInt64
        if multiplier == 0 || srcPart == 0
            low = carry
            high = UInt64(0)
        else
            low = apint_lowHalf(srcPart) * apint_lowHalf(multiplier)
            high = apint_highHalf(srcPart) * apint_highHalf(multiplier)
            mid = apint_lowHalf(srcPart) * apint_highHalf(multiplier)
            high += apint_highHalf(mid)
            mid <<= 32
            low + mid < low && (high += UInt64(1))
            low += mid
            mid = apint_highHalf(srcPart) * apint_lowHalf(multiplier)
            high += apint_highHalf(mid)
            mid <<= 32
            low + mid < low && (high += UInt64(1))
            low += mid
            # now add carry
            low + carry < low && (high += UInt64(1))
            low += carry
        end
        if add
            low + dst[d + i + 1] < low && (high += UInt64(1))
            dst[d + i + 1] = dst[d + i + 1] + low
        else
            dst[d + i + 1] = low
        end
        carry = high
    end
    if srcParts < dstParts
        # full multiplication, there is no overflow
        dst[d + srcParts + 1] = carry
        return 0
    end
    carry != 0 && return 1
    if multiplier != 0
        for i in dstParts:srcParts-1
            src[s + i + 1] != 0 && return 1
        end
    end
    return 0
end

# APInt.cpp:2667 APInt::tcFullMultiply: DST = LHS * RHS over lhsParts + rhsParts parts, the narrower first
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2667 APInt::tcFullMultiply)" "the full product of two bignums, as APInt's tcFullMultiply multiplies them" Base.:+ function apint_tcFullMultiply!(dst::Vector{UInt64}, d::Int, lhs::Vector{UInt64}, l::Int, rhs::Vector{UInt64}, r::Int, lhsParts::Int, rhsParts::Int)::Nothing
    lhsParts > rhsParts && return apint_tcFullMultiply!(dst, d, rhs, r, lhs, l, rhsParts, lhsParts)
    for i in 0:lhsParts-1
        apint_tcMultiplyPart!(dst, d + i, rhs, r, lhs[l + i + 1], UInt64(0), rhsParts, rhsParts + 1, i != 0)
    end
    return nothing
end

# APInt.cpp:2734 APInt::tcShiftLeft: a bignum shifted left COUNT bits in place, zeros shifted in
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2734 APInt::tcShiftLeft)" "a bignum shifted left, as APInt's tcShiftLeft shifts it" Base.:<< function apint_tcShiftLeft!(dst::Vector{UInt64}, d::Int, words::Int, count::UInt32)::Nothing
    count == 0 && return nothing
    local wordShift = min(Int(count ÷ UInt32(64)), words)
    local bitShift = count % UInt32(64)
    if bitShift == 0
        # memmove of the words up by wordShift, the highest first
        for i in words-1:-1:wordShift
            dst[d + i + 1] = dst[d + i - wordShift + 1]
        end
    else
        local w = words
        while w > wordShift
            w -= 1
            dst[d + w + 1] = dst[d + w - wordShift + 1] << bitShift
            if w > wordShift
                dst[d + w + 1] = dst[d + w + 1] | (dst[d + w - wordShift] >> (UInt32(64) - bitShift))
            end
        end
    end
    for i in 0:wordShift-1
        dst[d + i + 1] = UInt64(0)
    end
    return nothing
end

# APInt.cpp:2761 APInt::tcShiftRight: a bignum shifted right COUNT bits in place, zeros shifted in
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2761 APInt::tcShiftRight)" "a bignum shifted right, as APInt's tcShiftRight shifts it" Base.:>> function apint_tcShiftRight!(dst::Vector{UInt64}, d::Int, words::Int, count::UInt32)::Nothing
    count == 0 && return nothing
    local wordShift = min(Int(count ÷ UInt32(64)), words)
    local bitShift = count % UInt32(64)
    local wordsToMove = words - wordShift
    if bitShift == 0
        for i in 0:wordsToMove-1
            dst[d + i + 1] = dst[d + i + wordShift + 1]
        end
    else
        for i in 0:wordsToMove-1
            dst[d + i + 1] = dst[d + i + wordShift + 1] >> bitShift
            if i + 1 != wordsToMove
                dst[d + i + 1] = dst[d + i + 1] | (dst[d + i + wordShift + 2] << (UInt32(64) - bitShift))
            end
        end
    end
    for i in wordsToMove:words-1
        dst[d + i + 1] = UInt64(0)
    end
    return nothing
end

# APInt.cpp:2787 APInt::tcCompare: the unsigned comparison of two bignums, -1, 0 or 1
@quarantine pin"precedent(llvm: llvm/lib/Support/APInt.cpp:2787 APInt::tcCompare)" "the unsigned comparison of two bignums, as APInt's tcCompare compares them" Base.:> function apint_tcCompare(lhs::Vector{UInt64}, l::Int, rhs::Vector{UInt64}, r::Int, parts::Int)::Int
    while parts > 0
        parts -= 1
        local a = lhs[l + parts + 1]
        local b = rhs[r + parts + 1]
        a != b && return a > b ? 1 : -1
    end
    return 0
end

# ---------------------------------------------------------------------------------------------------
# APFloat (llvm/lib/Support/APFloat.cpp): the string-to-float conversion of IEEEFloat. Julia differs:
# a StringRef iterator is a 0-based byte offset into the String; an Expected's error, which no text the
# strtod scan hands APFloat reaches, is raised, naming it, never read as a value; the semantics held are
# IEEE754's (IEEE single and double, and roundSignificandWithExponent's calculation semantics), so the
# arms of formats with no infinity, no zero or a NaN-only encoding are not ported.

# APFloat.h:1005 fltSemantics: an exponent range, a precision in bits and a size in bits; the values of
# IEEE single and double are APFloat.cpp's semIEEEsingle and semIEEEdouble (its lines 73 and 74)
@quarantine pin"precedent(llvm: llvm/include/llvm/ADT/APFloat.h:1005 fltSemantics)" "a floating-point format's exponent range and precision, as APFloat's fltSemantics holds them" Core.Int struct APFloatSemantics
    maxExponent::Int
    minExponent::Int
    precision::Int
    sizeInBits::Int
end
@quarantine pin"precedent(llvm: llvm/include/llvm/ADT/APFloat.h:1005 fltSemantics)" "IEEE single's semantics, APFloat's semIEEEsingle {127, -126, 24, 32}" Core.Int const APFLOAT_SEM_IEEESINGLE = APFloatSemantics(Int(127), Int(-126), Int(24), Int(32))
@quarantine pin"precedent(llvm: llvm/include/llvm/ADT/APFloat.h:1005 fltSemantics)" "IEEE double's semantics, APFloat's semIEEEdouble {1023, -1022, 53, 64}" Core.Int const APFLOAT_SEM_IEEEDOUBLE = APFloatSemantics(Int(1023), Int(-1022), Int(53), Int(64))

# APFloat.h:461 IEEEFloat: a sign, a category (fcInfinity, fcNaN, fcNormal, fcZero: APFloat.h's fltCategory,
# 0-3), an exponent and a significand of partCount() words, partCountForBits(precision + 1) (APFloat.cpp:1152)
@quarantine pin"precedent(llvm: llvm/include/llvm/ADT/APFloat.h:461 IEEEFloat)" "an arbitrary-precision float as APFloat's IEEEFloat holds it, its significand a vector of words" Core.Int mutable struct APFloatIEEE
    semantics::APFloatSemantics
    significand::Vector{UInt64}
    exponent::Int
    category::Int
    sign::Bool
end

# APFloat.h's fltCategory, opStatus and lostFraction values, and the rounding modes, named as LLVM names them;
# each is pinned at the function that reads it
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1560 IEEEFloat::normalize)" "APFloat's fltCategory fcInfinity, which normalize reads" Core.Int const APF_fcInfinity::Int = 0
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1560 IEEEFloat::normalize)" "APFloat's fltCategory fcNaN, which normalize reads" Core.Int const APF_fcNaN::Int = 1
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1560 IEEEFloat::normalize)" "APFloat's fltCategory fcNormal, which normalize reads" Core.Int const APF_fcNormal::Int = 2
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1560 IEEEFloat::normalize)" "APFloat's fltCategory fcZero, which normalize reads" Core.Int const APF_fcZero::Int = 3
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1560 IEEEFloat::normalize)" "APFloat's opStatus opOK, which normalize returns" Core.Int const APF_opOK::Int = 0x00
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1560 IEEEFloat::normalize)" "APFloat's opStatus opOverflow, which normalize returns" Core.Int const APF_opOverflow::Int = 0x04
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1560 IEEEFloat::normalize)" "APFloat's opStatus opUnderflow, which normalize returns" Core.Int const APF_opUnderflow::Int = 0x08
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1560 IEEEFloat::normalize)" "APFloat's opStatus opInexact, which normalize returns" Core.Int const APF_opInexact::Int = 0x10
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:580 lostFractionThroughTruncation)" "APFloat's lostFraction lfExactlyZero, which lostFractionThroughTruncation returns" Core.Int const APF_lfExactlyZero::Int = 0
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:580 lostFractionThroughTruncation)" "APFloat's lostFraction lfLessThanHalf, which lostFractionThroughTruncation returns" Core.Int const APF_lfLessThanHalf::Int = 1
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:580 lostFractionThroughTruncation)" "APFloat's lostFraction lfExactlyHalf, which lostFractionThroughTruncation returns" Core.Int const APF_lfExactlyHalf::Int = 2
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:580 lostFractionThroughTruncation)" "APFloat's lostFraction lfMoreThanHalf, which lostFractionThroughTruncation returns" Core.Int const APF_lfMoreThanHalf::Int = 3
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1522 IEEEFloat::roundAwayFromZero)" "the rounding mode toward zero, which roundAwayFromZero's switch names" Core.Int const APF_rmTowardZero::Int = 0
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1522 IEEEFloat::roundAwayFromZero)" "the rounding mode to nearest, ties to even, which roundAwayFromZero's switch names" Core.Int const APF_rmNearestTiesToEven::Int = 1
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1522 IEEEFloat::roundAwayFromZero)" "the rounding mode toward positive, which roundAwayFromZero's switch names" Core.Int const APF_rmTowardPositive::Int = 2
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1522 IEEEFloat::roundAwayFromZero)" "the rounding mode toward negative, which roundAwayFromZero's switch names" Core.Int const APF_rmTowardNegative::Int = 3
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1522 IEEEFloat::roundAwayFromZero)" "the rounding mode to nearest, ties away, which roundAwayFromZero's switch names" Core.Int const APF_rmNearestTiesToAway::Int = 4

# APFloat.cpp:231-236 maxExponent, maxPrecision and maxPowerOfFiveParts: 2 + ((16383 + 113 - 1) * 815) /
# (351 * 64), the parts powerOf5's tables hold
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:691 powerOf5)" "APFloat's maxPowerOfFiveParts, the size of powerOf5's tables, computed as APFloat.cpp writes it" Base.:÷ const APF_MAX_POWER_OF_FIVE_PARTS = 2 + ((16383 + 113 - 1) * 815) ÷ (351 * 64)

# APFloat.cpp:334 partCountForBits: the words that hold BITS bits, at least one
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:334 partCountForBits)" "the words a bit count needs, as APFloat's partCountForBits counts them" Base.:÷ apfloat_partCountForBits(bits::Int)::Int =
    max(1, (bits + 63) ÷ 64)

# APFloat.cpp:1152 IEEEFloat::partCount
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1152 IEEEFloat::partCount)" "the words of a float's significand, as APFloat's partCount counts them" Base.:+ apfloat_partCount(sem::APFloatSemantics)::Int =
    apfloat_partCountForBits(sem.precision + 1)

# APFloat.cpp:1125 the IEEEFloat(semantics) constructor: initialize (APFloat.cpp:826) and a positive zero
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1125 IEEEFloat::IEEEFloat)" "a float of a semantics, zero, as APFloat's IEEEFloat constructor makes it" Base.:- apfloat_new(sem::APFloatSemantics)::APFloatIEEE =
    APFloatIEEE(sem, zeros(UInt64, apfloat_partCount(sem)), sem.minExponent - 1, APF_fcZero, false)

# APFloat.cpp:341 decDigitValue: c - '0', unsigned, so a non-digit reads 10 or more
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:341 decDigitValue)" "a decimal digit's value, as APFloat's decDigitValue reads it" Base.:- apfloat_decDigitValue(c::UInt8)::UInt32 =
    UInt32(c) - UInt32(0x30)

# StringExtras.h:81 hexDigitValue: its table's entries, -1 read as an unsigned UINT_MAX
@quarantine pin"precedent(llvm: llvm/include/llvm/ADT/StringExtras.h:81 hexDigitValue)" "a hexadecimal digit's value, as LLVM's hexDigitValue reads it from its table: a digit 0-9, a-f or A-F, else UINT_MAX" Base.:- function apfloat_hexDigitValue(c::UInt8)::UInt32
    UInt8('0') <= c <= UInt8('9') && return UInt32(c - UInt8('0'))
    UInt8('A') <= c <= UInt8('F') && return UInt32(c - UInt8('A')) + UInt32(10)
    UInt8('a') <= c <= UInt8('f') && return UInt32(c - UInt8('a')) + UInt32(10)
    return typemax(UInt32)
end

# APFloat.cpp:351 readExponent: [+-]ddd, 0 where there is none, saturated at 24000
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:351 readExponent)" "a decimal exponent's value, as APFloat's readExponent reads it" Base.:* function apfloat_readExponent(s::String, b::Int, e::Int)::Int
    local overlargeExponent = UInt32(24000)
    local p = b
    (p == e || ((codeunit(s, p + 1) == UInt8('-') || codeunit(s, p + 1) == UInt8('+')) && p + 1 == e)) && return 0
    local isNegative = codeunit(s, p + 1) == UInt8('-')
    if codeunit(s, p + 1) == UInt8('-') || codeunit(s, p + 1) == UInt8('+')
        p += 1
        p == e && throw(ErrorException("WasmTarget: APFloat readExponent (llvm/lib/Support/APFloat.cpp): Exponent has no digits"))
    end
    local absExponent = apfloat_decDigitValue(codeunit(s, p + 1))
    p += 1
    absExponent >= 10 && throw(ErrorException("WasmTarget: APFloat readExponent (llvm/lib/Support/APFloat.cpp): Invalid character in exponent"))
    while p != e
        local value = apfloat_decDigitValue(codeunit(s, p + 1))
        value >= 10 && throw(ErrorException("WasmTarget: APFloat readExponent (llvm/lib/Support/APFloat.cpp): Invalid character in exponent"))
        absExponent = absExponent * UInt32(10) + value
        if absExponent >= overlargeExponent
            absExponent = overlargeExponent
            break
        end
        p += 1
    end
    return isNegative ? -Int(absExponent) : Int(absExponent)
end

# APFloat.cpp:391 totalExponent: [+-]ddd plus an adjustment, saturated at -32768 and 32767
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:391 totalExponent)" "a binary exponent's value with an adjustment, as APFloat's totalExponent reads it" Base.:* function apfloat_totalExponent(s::String, p::Int, e::Int, exponentAdjustment::Int)::Int
    local exponent = 0
    p == e && throw(ErrorException("WasmTarget: APFloat totalExponent (llvm/lib/Support/APFloat.cpp): Exponent has no digits"))
    local negative = codeunit(s, p + 1) == UInt8('-')
    if codeunit(s, p + 1) == UInt8('-') || codeunit(s, p + 1) == UInt8('+')
        p += 1
        p == e && throw(ErrorException("WasmTarget: APFloat totalExponent (llvm/lib/Support/APFloat.cpp): Exponent has no digits"))
    end
    local unsignedExponent = 0
    local overflow = false
    while p != e
        local value = apfloat_decDigitValue(codeunit(s, p + 1))
        value >= 10 && throw(ErrorException("WasmTarget: APFloat totalExponent (llvm/lib/Support/APFloat.cpp): Invalid character in exponent"))
        unsignedExponent = unsignedExponent * 10 + Int(value)
        if unsignedExponent > 32767
            overflow = true
            break
        end
        p += 1
    end
    (exponentAdjustment > 32767 || exponentAdjustment < -32768) && (overflow = true)
    if !overflow
        exponent = unsignedExponent
        negative && (exponent = -exponent)
        exponent += exponentAdjustment
        (exponent > 32767 || exponent < -32768) && (overflow = true)
    end
    overflow && (exponent = negative ? -32768 : 32767)
    return exponent
end

# APFloat.cpp:441 skipLeadingZeroesAndAnyDot: past the leading zeroes and a dot among them, and the dot's offset
# (END where there is none)
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:441 skipLeadingZeroesAndAnyDot)" "past a significand's leading zeroes, as APFloat's skipLeadingZeroesAndAnyDot skips them" Base.:- function apfloat_skipLeadingZeroesAndAnyDot(s::String, b::Int, e::Int)::Tuple{Int,Int}
    local p = b
    local dot = e
    while p != e && codeunit(s, p + 1) == UInt8('0')
        p += 1
    end
    if p != e && codeunit(s, p + 1) == UInt8('.')
        dot = p
        p += 1
        e - b == 1 && throw(ErrorException("WasmTarget: APFloat skipLeadingZeroesAndAnyDot (llvm/lib/Support/APFloat.cpp): Significand has no digits"))
        while p != e && codeunit(s, p + 1) == UInt8('0')
            p += 1
        end
    end
    return (p, dot)
end

# APFloat.cpp:481 interpretDecimal: a decimal significand's first and last significant digits, its exponent as
# an integer and its exponent normalized to one leading digit (the struct decimalInfo, APFloat.cpp:474, as a tuple)
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:481 interpretDecimal)" "a decimal number's significant digits and exponents, as APFloat's interpretDecimal reads them" Base.:- function apfloat_interpretDecimal(s::String, b::Int, e::Int)::NTuple{4,Int}
    local p, dot = apfloat_skipLeadingZeroesAndAnyDot(s, b, e)
    local firstSigDigit = p
    local exponent = 0
    local normalizedExponent = 0
    while p != e
        if codeunit(s, p + 1) == UInt8('.')
            dot != e && throw(ErrorException("WasmTarget: APFloat interpretDecimal (llvm/lib/Support/APFloat.cpp): String contains multiple dots"))
            dot = p
            p += 1
            p == e && break
        end
        apfloat_decDigitValue(codeunit(s, p + 1)) >= 10 && break
        p += 1
    end
    if p != e
        local c = codeunit(s, p + 1)
        c != UInt8('e') && c != UInt8('E') && throw(ErrorException("WasmTarget: APFloat interpretDecimal (llvm/lib/Support/APFloat.cpp): Invalid character in significand"))
        p == b && throw(ErrorException("WasmTarget: APFloat interpretDecimal (llvm/lib/Support/APFloat.cpp): Significand has no digits"))
        dot != e && p - b == 1 && throw(ErrorException("WasmTarget: APFloat interpretDecimal (llvm/lib/Support/APFloat.cpp): Significand has no digits"))
        exponent = apfloat_readExponent(s, p + 1, e)
        # implied decimal point?
        dot == e && (dot = p)
    end
    # if the number is all zeroes accept any exponent
    if p != firstSigDigit
        # drop insignificant trailing zeroes
        if p != b
            while true
                while true
                    p -= 1
                    (p != b && codeunit(s, p + 1) == UInt8('0')) || break
                end
                (p != b && codeunit(s, p + 1) == UInt8('.')) || break
            end
        end
        # adjust the exponents for any decimal point
        exponent += (dot - p) - (dot > p ? 1 : 0)
        normalizedExponent = exponent + ((p - firstSigDigit) - (dot > firstSigDigit && dot < p ? 1 : 0))
    end
    return (firstSigDigit, p, exponent, normalizedExponent)
end

# APFloat.cpp:551 trailingHexadecimalFraction: the fraction a hexadecimal significand loses past the bits it holds
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:551 trailingHexadecimalFraction)" "the fraction lost past a hexadecimal significand's held digits, as APFloat's trailingHexadecimalFraction finds it" Base.:> function apfloat_trailingHexadecimalFraction(s::String, p::Int, e::Int, digitValue::UInt64)::Int
    digitValue > 8 && return APF_lfMoreThanHalf
    digitValue < 8 && digitValue > 0 && return APF_lfLessThanHalf
    # otherwise we need to find the first non-zero digit
    while p != e && (codeunit(s, p + 1) == UInt8('0') || codeunit(s, p + 1) == UInt8('.'))
        p += 1
    end
    p == e && throw(ErrorException("WasmTarget: APFloat trailingHexadecimalFraction (llvm/lib/Support/APFloat.cpp): Invalid trailing hexadecimal fraction!"))
    local hexDigit = apfloat_hexDigitValue(codeunit(s, p + 1))
    # if we ran off the end it is exactly zero or one-half, otherwise a little more
    return hexDigit == typemax(UInt32) ? (digitValue == 0 ? APF_lfExactlyZero : APF_lfExactlyHalf) :
                                         (digitValue == 0 ? APF_lfLessThanHalf : APF_lfMoreThanHalf)
end

# APFloat.cpp:580 lostFractionThroughTruncation: the fraction lost were a bignum truncated of its BITS low bits
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:580 lostFractionThroughTruncation)" "the fraction a truncation loses, as APFloat's lostFractionThroughTruncation classifies it" Base.:<= function apfloat_lostFractionThroughTruncation(parts::Vector{UInt64}, p::Int, partCount::Int, bits::UInt32)::Int
    local lsb = apint_tcLSB(parts, p, partCount)
    # this is guaranteed true if bits == 0, or lsb == UINT_MAX
    bits <= lsb && return APF_lfExactlyZero
    bits == lsb + UInt32(1) && return APF_lfExactlyHalf
    bits <= UInt32(partCount * 64) && apint_tcExtractBit(parts, p, bits - UInt32(1)) != 0 && return APF_lfMoreThanHalf
    return APF_lfLessThanHalf
end

# APFloat.cpp:600 shiftRight: a bignum shifted right BITS bits, the fraction lost returned
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:600 shiftRight)" "a bignum shifted right noting the fraction lost, as APFloat's shiftRight shifts it" Core.UInt32 function apfloat_shiftRight!(dst::Vector{UInt64}, d::Int, parts::Int, bits::UInt32)::Int
    local lost_fraction = apfloat_lostFractionThroughTruncation(dst, d, parts, bits)
    apint_tcShiftRight!(dst, d, parts, bits)
    return lost_fraction
end

# APFloat.cpp:611 combineLostFractions: a more significant lost fraction made inexact by a less significant one
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:611 combineLostFractions)" "two lost fractions combined, as APFloat's combineLostFractions combines them" Base.:(==) function apfloat_combineLostFractions(moreSignificant::Int, lessSignificant::Int)::Int
    if lessSignificant != APF_lfExactlyZero
        if moreSignificant == APF_lfExactlyZero
            moreSignificant = APF_lfLessThanHalf
        elseif moreSignificant == APF_lfExactlyHalf
            moreSignificant = APF_lfMoreThanHalf
        end
    end
    return moreSignificant
end

# APFloat.cpp:632 HUerrBound: the bound, in half-ulps, on a product's error (Clinger, "How to Read Floating
# Point Numbers Accurately")
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:632 HUerrBound)" "the half-ulp error bound of a product, as APFloat's HUerrBound bounds it" Base.:* function apfloat_HUerrBound(inexactMultiply::Bool, HUerr1::UInt32, HUerr2::UInt32)::UInt32
    HUerr1 + HUerr2 == 0 && return UInt32(inexactMultiply) * UInt32(2)
    return UInt32(inexactMultiply) + UInt32(2) * (HUerr1 + HUerr2)
end

# APFloat.cpp:646 ulpsFromBoundary: the ulps from the rounding boundary (zero, or half if isNearest) when the
# least significant BITS bits are truncated, unsigned arithmetic wrapping as C's
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:646 ulpsFromBoundary)" "the ulps a truncation lies from its rounding boundary, as APFloat's ulpsFromBoundary counts them" Base.:- function apfloat_ulpsFromBoundary(parts::Vector{UInt64}, p::Int, bits::UInt32, isNearest::Bool)::UInt64
    bits != 0 || throw(ErrorException("WasmTarget: APFloat ulpsFromBoundary (llvm/lib/Support/APFloat.cpp): bits is zero"))
    bits -= UInt32(1)
    local count = Int(bits ÷ UInt32(64))
    local partBits = bits % UInt32(64) + UInt32(1)
    local part = parts[p + count + 1] & (typemax(UInt64) >> (UInt32(64) - partBits))
    local boundary = isNearest ? UInt64(1) << (partBits - UInt32(1)) : UInt64(0)
    if count == 0
        return part - boundary <= boundary - part ? part - boundary : boundary - part
    end
    if part == boundary
        while true
            count -= 1
            count == 0 && break
            parts[p + count + 1] != 0 && return typemax(UInt64)   # a lot
        end
        return parts[p + 1]
    elseif part == boundary - UInt64(1)
        while true
            count -= 1
            count == 0 && break
            ~parts[p + count + 1] != 0 && return typemax(UInt64)   # a lot
        end
        return UInt64(0) - parts[p + 1]
    end
    return typemax(UInt64)   # a lot
end

# APFloat.cpp:691 powerOf5: pow(5, power) into DST, the parts used returned; firstEightPowers, then the
# squares pow(5, pow(2, n + 3)) kept in pow5s and multiplied in where power's bit n is set
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:691 powerOf5)" "a power of five as a bignum, as APFloat's powerOf5 computes it" Base.:* function apfloat_powerOf5!(dst::Vector{UInt64}, power::UInt32)::Int
    local firstEightPowers = (UInt64(1), UInt64(5), UInt64(25), UInt64(125), UInt64(625), UInt64(3125), UInt64(15625), UInt64(78125))
    local pow5s = zeros(UInt64, APF_MAX_POWER_OF_FIVE_PARTS * 2 + 5)
    pow5s[1] = UInt64(78125) * UInt64(5)
    local partsCount = 1
    local scratch = zeros(UInt64, APF_MAX_POWER_OF_FIVE_PARTS)
    power <= UInt32(16383) || throw(ErrorException("WasmTarget: APFloat powerOf5 (llvm/lib/Support/APFloat.cpp): a power past maxExponent"))
    # p1 and p2 are DST and scratch, swapped as the product moves between them
    local p1 = dst
    local p2 = scratch
    p1[1] = firstEightPowers[Int(power & UInt32(7)) + 1]
    power >>= 3
    local result = 1
    local pow5 = 0
    local n = 0
    while power != 0
        # calculate pow(5, pow(2, n + 3)) if we haven't yet
        if n != 0
            apint_tcFullMultiply!(pow5s, pow5, pow5s, pow5 - partsCount, pow5s, pow5 - partsCount, partsCount, partsCount)
            partsCount *= 2
            pow5s[pow5 + partsCount] == 0 && (partsCount -= 1)
        end
        if power & UInt32(1) != 0
            apint_tcFullMultiply!(p2, 0, p1, 0, pow5s, pow5, result, partsCount)
            result += partsCount
            p2[result] == 0 && (result -= 1)
            # now result is in p1 with partsCount parts and p2 is scratch space
            local tmp = p1
            p1 = p2
            p2 = tmp
        end
        pow5 += partsCount
        power >>= 1
        n += 1
    end
    p1 !== dst && apint_tcAssign!(dst, 0, p1, 0, result)
    return result
end

# APFloat.cpp:1167 IEEEFloat::zeroSignificand
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1167 IEEEFloat::zeroSignificand)" "a float's significand zeroed, as APFloat's zeroSignificand zeroes it" Base.length apfloat_zeroSignificand!(f::APFloatIEEE)::Nothing =
    apint_tcSet!(f.significand, 0, UInt64(0), length(f.significand))

# APFloat.cpp:1172 IEEEFloat::incrementSignificand: its callers never overflow it
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1172 IEEEFloat::incrementSignificand)" "a float's significand incremented, as APFloat's incrementSignificand increments it" Base.:!= function apfloat_incrementSignificand!(f::APFloatIEEE)::Nothing
    local carry = apint_tcAddPart!(f.significand, 0, UInt64(1), length(f.significand))
    carry != 0 && throw(ErrorException("WasmTarget: APFloat incrementSignificand (llvm/lib/Support/APFloat.cpp): the significand overflowed"))
    return nothing
end

# APFloat.cpp:1206 IEEEFloat::multiplySignificand: the significand multiplied by RHS's, the product's MSB
# placed at the precision's integer bit, the fraction lost returned. Julia differs: the addend is the zero the
# one-argument form passes (APFloat.cpp:1331 multiplySignificand), so the fused multiply-add branch never runs
# and is not ported
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1206 IEEEFloat::multiplySignificand)" "a float's significand multiplied by another's, as APFloat's multiplySignificand multiplies them; Julia differs: the addend is the one-argument form's zero" Base.:* function apfloat_multiplySignificand!(f::APFloatIEEE, rhs::APFloatIEEE)::Int
    local precision = f.semantics.precision
    # space for twice as many bits as the significand, plus one extra bit for the addition to overflow into
    local newPartsCount = apfloat_partCountForBits(precision * 2 + 1)
    local fullSignificand = zeros(UInt64, max(newPartsCount, 4))
    local partsCount = length(f.significand)
    apint_tcFullMultiply!(fullSignificand, 0, f.significand, 0, rhs.significand, 0, partsCount, partsCount)
    local lost_fraction = APF_lfExactlyZero
    # one, not zero, based MSB
    local omsb = apint_tcMSB(fullSignificand, 0, newPartsCount) + UInt32(1)
    f.exponent += rhs.exponent
    # the product has three significant bits left of the radix point: move it left two bits
    f.exponent += 2
    # from 2 * precision significant bits back to precision
    f.exponent -= precision + 1
    if omsb > UInt32(precision)
        local bits = omsb - UInt32(precision)
        local significantParts = apfloat_partCountForBits(Int(omsb))
        local lf = apfloat_shiftRight!(fullSignificand, 0, significantParts, bits)
        lost_fraction = apfloat_combineLostFractions(lf, lost_fraction)
        f.exponent += Int(bits)
    end
    apint_tcAssign!(f.significand, 0, fullSignificand, 0, partsCount)
    return lost_fraction
end

# APFloat.cpp:1341 IEEEFloat::divideSignificand: the significand divided by RHS's by long division, its
# integer bit set, the fraction lost returned
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1341 IEEEFloat::divideSignificand)" "a float's significand divided by another's, as APFloat's divideSignificand divides them" Base.:- function apfloat_divideSignificand!(f::APFloatIEEE, rhs::APFloatIEEE)::Int
    local partsCount = length(f.significand)
    local dividend = zeros(UInt64, partsCount * 2)
    local divisor = partsCount   # the divisor is dividend's second half
    # copy the dividend and divisor as they will be modified in-place
    for i in 0:partsCount-1
        dividend[i + 1] = f.significand[i + 1]
        dividend[divisor + i + 1] = rhs.significand[i + 1]
        f.significand[i + 1] = UInt64(0)
    end
    f.exponent -= rhs.exponent
    local precision = UInt32(f.semantics.precision)
    # normalize the divisor
    local bit = precision - apint_tcMSB(dividend, divisor, partsCount) - UInt32(1)
    if bit != 0
        f.exponent += Int(bit)
        apint_tcShiftLeft!(dividend, divisor, partsCount, bit)
    end
    # normalize the dividend
    bit = precision - apint_tcMSB(dividend, 0, partsCount) - UInt32(1)
    if bit != 0
        f.exponent -= Int(bit)
        apint_tcShiftLeft!(dividend, 0, partsCount, bit)
    end
    # ensure the dividend >= divisor initially for the loop below
    if apint_tcCompare(dividend, 0, dividend, divisor, partsCount) < 0
        f.exponent -= 1
        apint_tcShiftLeft!(dividend, 0, partsCount, UInt32(1))
    end
    # long division
    bit = precision
    while bit != 0
        if apint_tcCompare(dividend, 0, dividend, divisor, partsCount) >= 0
            apint_tcSubtract!(dividend, 0, dividend, divisor, UInt64(0), partsCount)
            apint_tcSetBit!(f.significand, 0, bit - UInt32(1))
        end
        apint_tcShiftLeft!(dividend, 0, partsCount, UInt32(1))
        bit -= UInt32(1)
    end
    # figure out the lost fraction
    local cmp = apint_tcCompare(dividend, 0, dividend, divisor, partsCount)
    cmp > 0 && return APF_lfMoreThanHalf
    cmp == 0 && return APF_lfExactlyHalf
    apint_tcIsZero(dividend, 0, partsCount) && return APF_lfExactlyZero
    return APF_lfLessThanHalf
end

# APFloat.cpp:1426 IEEEFloat::shiftSignificandRight: a zero result is not normalized to fcZero
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1426 IEEEFloat::shiftSignificandRight)" "a float's significand shifted right, as APFloat's shiftSignificandRight shifts it" Core.Int function apfloat_shiftSignificandRight!(f::APFloatIEEE, bits::UInt32)::Int
    f.exponent += Int(bits)
    return apfloat_shiftRight!(f.significand, 0, length(f.significand), bits)
end

# APFloat.cpp:1436 IEEEFloat::shiftSignificandLeft: BITS subtracted from the exponent
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1436 IEEEFloat::shiftSignificandLeft)" "a float's significand shifted left, as APFloat's shiftSignificandLeft shifts it" Core.Int function apfloat_shiftSignificandLeft!(f::APFloatIEEE, bits::UInt32)::Nothing
    if bits != 0
        apint_tcShiftLeft!(f.significand, 0, length(f.significand), bits)
        f.exponent -= Int(bits)
    end
    return nothing
end

# APFloat.cpp:1490 IEEEFloat::handleOverflow: infinity where the rounding mode rounds away, else the largest
# finite number (tcSetLeastSignificantBits, APFloat.cpp:1476), the sign kept
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1490 IEEEFloat::handleOverflow)" "an overflow made infinity or the largest finite number, as APFloat's handleOverflow makes it" Base.:(==) function apfloat_handleOverflow!(f::APFloatIEEE, rounding_mode::Int)::Int
    if rounding_mode == APF_rmNearestTiesToEven || rounding_mode == APF_rmNearestTiesToAway ||
       (rounding_mode == APF_rmTowardPositive && !f.sign) || (rounding_mode == APF_rmTowardNegative && f.sign)
        f.category = APF_fcInfinity
        return APF_opOverflow | APF_opInexact
    end
    # otherwise we become the largest finite number
    f.category = APF_fcNormal
    f.exponent = f.semantics.maxExponent
    local bits = f.semantics.precision
    local i = 0
    while bits > 64
        f.significand[i + 1] = typemax(UInt64)
        i += 1
        bits -= 64
    end
    if bits != 0
        f.significand[i + 1] = typemax(UInt64) >> (64 - bits)
        i += 1
    end
    while i < length(f.significand)
        f.significand[i + 1] = UInt64(0)
        i += 1
    end
    return APF_opInexact
end

# APFloat.cpp:1522 IEEEFloat::roundAwayFromZero: whether truncating at bit BIT with the lost fraction rounds
# away from zero under the rounding mode; its callers never pass lfExactlyZero
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1522 IEEEFloat::roundAwayFromZero)" "whether a truncation rounds away from zero, as APFloat's roundAwayFromZero decides it" Base.:(==) function apfloat_roundAwayFromZero(f::APFloatIEEE, rounding_mode::Int, lost_fraction::Int, bit::UInt32)::Bool
    lost_fraction != APF_lfExactlyZero || throw(ErrorException("WasmTarget: APFloat roundAwayFromZero (llvm/lib/Support/APFloat.cpp): an exact fraction"))
    if rounding_mode == APF_rmNearestTiesToAway
        return lost_fraction == APF_lfExactlyHalf || lost_fraction == APF_lfMoreThanHalf
    elseif rounding_mode == APF_rmNearestTiesToEven
        lost_fraction == APF_lfMoreThanHalf && return true
        # our zeroes don't have a significand to test
        lost_fraction == APF_lfExactlyHalf && f.category != APF_fcZero && return apint_tcExtractBit(f.significand, 0, bit) != 0
        return false
    elseif rounding_mode == APF_rmTowardZero
        return false
    elseif rounding_mode == APF_rmTowardPositive
        return !f.sign
    elseif rounding_mode == APF_rmTowardNegative
        return f.sign
    end
    throw(ErrorException("WasmTarget: APFloat roundAwayFromZero (llvm/lib/Support/APFloat.cpp): Invalid rounding mode found"))
end

# APFloat.cpp:1560 IEEEFloat::normalize: the significand's MSB placed at the precision's integer bit, the
# exponent adjusted, a denormal's MSB forced by minExponent, overflow handled, and the number rounded by the
# lost fraction, an increment that carries renormalized
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:1560 IEEEFloat::normalize)" "a float normalized and rounded, as APFloat's normalize rounds it" Base.:- function apfloat_normalize!(f::APFloatIEEE, rounding_mode::Int, lost_fraction::Int)::Int
    f.category == APF_fcNormal || return APF_opOK
    local precision = f.semantics.precision
    # one, not zero, based MSB
    local omsb = apint_tcMSB(f.significand, 0, length(f.significand)) + UInt32(1)
    # only skip this if the value is exactly zero
    if omsb != 0 || lost_fraction != APF_lfExactlyZero
        local exponentChange = Int(omsb) - precision
        # if the resulting exponent is too high, overflow according to the rounding mode
        f.exponent + exponentChange > f.semantics.maxExponent && return apfloat_handleOverflow!(f, rounding_mode)
        # subnormal numbers have exponent minExponent, and their MSB is forced based on that
        f.exponent + exponentChange < f.semantics.minExponent && (exponentChange = f.semantics.minExponent - f.exponent)
        # shifting left is easy as we don't lose precision
        if exponentChange < 0
            lost_fraction == APF_lfExactlyZero || throw(ErrorException("WasmTarget: APFloat normalize (llvm/lib/Support/APFloat.cpp): a left shift with a lost fraction"))
            apfloat_shiftSignificandLeft!(f, UInt32(-exponentChange))
            return APF_opOK
        end
        if exponentChange > 0
            # shift right and capture any new lost fraction
            local lf = apfloat_shiftSignificandRight!(f, UInt32(exponentChange))
            lost_fraction = apfloat_combineLostFractions(lf, lost_fraction)
            # keep omsb up-to-date
            omsb = omsb > UInt32(exponentChange) ? omsb - UInt32(exponentChange) : UInt32(0)
        end
    end
    # as specified in IEEE 754, since we do not trap we do not report underflow for exact results
    if lost_fraction == APF_lfExactlyZero
        # canonicalize zeroes
        omsb == 0 && (f.category = APF_fcZero)
        return APF_opOK
    end
    # increment the significand if we're rounding away from zero
    if apfloat_roundAwayFromZero(f, rounding_mode, lost_fraction, UInt32(0))
        omsb == 0 && (f.exponent = f.semantics.minExponent)
        apfloat_incrementSignificand!(f)
        omsb = apint_tcMSB(f.significand, 0, length(f.significand)) + UInt32(1)
        # did the significand increment overflow?
        if omsb == UInt32(precision + 1)
            # renormalize by incrementing the exponent and shifting our significand right one; however if we
            # already have the maximum exponent we overflow to infinity
            f.exponent == f.semantics.maxExponent && return apfloat_handleOverflow!(f, f.sign ? APF_rmTowardNegative : APF_rmTowardPositive)
            apfloat_shiftSignificandRight!(f, UInt32(1))
            return APF_opInexact
        end
    end
    # the normal case: we were and are not denormal, and any significand increment above didn't overflow
    omsb == UInt32(precision) && return APF_opInexact
    # we have a non-zero denormal
    omsb < UInt32(precision) || throw(ErrorException("WasmTarget: APFloat normalize (llvm/lib/Support/APFloat.cpp): the MSB past the precision"))
    # canonicalize zeroes
    omsb == 0 && (f.category = APF_fcZero)
    # the fcZero case is a denormal that underflowed to zero
    return APF_opUnderflow | APF_opInexact
end

# APFloat.cpp:2736 IEEEFloat::convertFromUnsignedParts: the most significant precision bits of SRC, rounded
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:2736 IEEEFloat::convertFromUnsignedParts)" "a bignum converted to a float, as APFloat's convertFromUnsignedParts rounds it" Base.:<= function apfloat_convertFromUnsignedParts!(f::APFloatIEEE, src::Vector{UInt64}, srcCount::Int, rounding_mode::Int)::Int
    f.category = APF_fcNormal
    local omsb = apint_tcMSB(src, 0, srcCount) + UInt32(1)
    local dstCount = length(f.significand)
    local precision = UInt32(f.semantics.precision)
    local lost_fraction::Int
    # we want the most significant precision bits of src; there may not be that many, extract what we can
    if precision <= omsb
        f.exponent = Int(omsb) - 1
        lost_fraction = apfloat_lostFractionThroughTruncation(src, 0, srcCount, omsb - precision)
        apint_tcExtract!(f.significand, 0, dstCount, src, 0, precision, omsb - precision)
    else
        f.exponent = Int(precision) - 1
        lost_fraction = APF_lfExactlyZero
        apint_tcExtract!(f.significand, 0, dstCount, src, 0, omsb, UInt32(0))
    end
    return apfloat_normalize!(f, rounding_mode, lost_fraction)
end

# APFloat.cpp:2776 IEEEFloat::convertFromHexadecimalString: the hexadecimal digits after 0x, stored a nibble
# at a time from the significand's top, the fraction past them noted, the binary exponent adjusted for the
# digits and the point, and rounded
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:2776 IEEEFloat::convertFromHexadecimalString)" "a hexadecimal number's text converted to a float, as APFloat's convertFromHexadecimalString converts it" Base.:% function apfloat_convertFromHexadecimalString!(f::APFloatIEEE, s::String, b::Int, e::Int, rounding_mode::Int)::Int
    local lost_fraction = APF_lfExactlyZero
    f.category = APF_fcNormal
    apfloat_zeroSignificand!(f)
    f.exponent = 0
    local partsCount = length(f.significand)
    local bitPos = partsCount * 64
    local computedTrailingFraction = false
    # skip leading zeroes and any (hexa)decimal point
    local p, dot = apfloat_skipLeadingZeroesAndAnyDot(s, b, e)
    local firstSignificantDigit = p
    while p != e
        if codeunit(s, p + 1) == UInt8('.')
            dot != e && throw(ErrorException("WasmTarget: APFloat convertFromHexadecimalString (llvm/lib/Support/APFloat.cpp): String contains multiple dots"))
            dot = p
            p += 1
            continue
        end
        local hv = apfloat_hexDigitValue(codeunit(s, p + 1))
        hv == typemax(UInt32) && break
        local hex_value = UInt64(hv)
        p += 1
        # store the number while we have space
        if bitPos != 0
            bitPos -= 4
            hex_value <<= (bitPos % 64)
            f.significand[bitPos ÷ 64 + 1] = f.significand[bitPos ÷ 64 + 1] | hex_value
        elseif !computedTrailingFraction
            lost_fraction = apfloat_trailingHexadecimalFraction(s, p, e, hex_value)
            computedTrailingFraction = true
        end
    end
    # hex floats require an exponent but not a hexadecimal point
    p == e && throw(ErrorException("WasmTarget: APFloat convertFromHexadecimalString (llvm/lib/Support/APFloat.cpp): Hex strings require an exponent"))
    local c = codeunit(s, p + 1)
    c != UInt8('p') && c != UInt8('P') && throw(ErrorException("WasmTarget: APFloat convertFromHexadecimalString (llvm/lib/Support/APFloat.cpp): Invalid character in significand"))
    p == b && throw(ErrorException("WasmTarget: APFloat convertFromHexadecimalString (llvm/lib/Support/APFloat.cpp): Significand has no digits"))
    dot != e && p - b == 1 && throw(ErrorException("WasmTarget: APFloat convertFromHexadecimalString (llvm/lib/Support/APFloat.cpp): Significand has no digits"))
    # ignore the exponent if we are zero
    if p != firstSignificantDigit
        # implicit hexadecimal point?
        dot == e && (dot = p)
        # the exponent adjustment implicit in the number of significant digits
        local expAdjustment = dot - firstSignificantDigit
        expAdjustment < 0 && (expAdjustment += 1)
        expAdjustment = expAdjustment * 4 - 1
        # adjust for writing the significand starting at the most significant nibble
        expAdjustment += f.semantics.precision
        expAdjustment -= partsCount * 64
        # adjust for the given exponent
        f.exponent = apfloat_totalExponent(s, p + 1, e, expAdjustment)
    end
    return apfloat_normalize!(f, rounding_mode, lost_fraction)
end

# APFloat.cpp:2870 IEEEFloat::roundSignificandWithExponent: the decimal significand times pow(10, exp), as
# pow(5, exp) times pow(2, exp), computed in a precision that doubles until truncating it is known to round
# correctly (HUerrBound against ulpsFromBoundary), then rounded
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:2870 IEEEFloat::roundSignificandWithExponent)" "a decimal significand and exponent rounded to a float, as APFloat's roundSignificandWithExponent rounds them" Base.:* function apfloat_roundSignificandWithExponent!(f::APFloatIEEE, decSigParts::Vector{UInt64}, sigPartCount::Int, exp::Int, rounding_mode::Int)::Int
    local pow5Parts = zeros(UInt64, APF_MAX_POWER_OF_FIVE_PARTS)
    local isNearest = rounding_mode == APF_rmNearestTiesToEven || rounding_mode == APF_rmNearestTiesToAway
    local parts = apfloat_partCountForBits(f.semantics.precision + 11)
    # calculate pow(5, abs(exp))
    local pow5PartCount = apfloat_powerOf5!(pow5Parts, UInt32(exp >= 0 ? exp : -exp))
    while true
        local calcSemantics = APFloatSemantics(32767, -32767, parts * 64 - 1, 0)
        local excessPrecision = UInt32(calcSemantics.precision - f.semantics.precision)
        local truncatedBits = excessPrecision
        local decSig = apfloat_new(calcSemantics)
        decSig.sign = f.sign
        local pow5 = apfloat_new(calcSemantics)
        local sigStatus = apfloat_convertFromUnsignedParts!(decSig, decSigParts, sigPartCount, APF_rmNearestTiesToEven)
        local powStatus = apfloat_convertFromUnsignedParts!(pow5, pow5Parts, pow5PartCount, APF_rmNearestTiesToEven)
        # add exp, as 10^n = 5^n * 2^n
        decSig.exponent += exp
        local calcLostFraction::Int
        local powHUerr::UInt32
        if exp >= 0
            # multiplySignificand leaves the precision-th bit set to 1
            calcLostFraction = apfloat_multiplySignificand!(decSig, pow5)
            powHUerr = UInt32(powStatus != APF_opOK)
        else
            calcLostFraction = apfloat_divideSignificand!(decSig, pow5)
            # denormal numbers have less precision
            if decSig.exponent < f.semantics.minExponent
                excessPrecision += UInt32(f.semantics.minExponent - decSig.exponent)
                truncatedBits = excessPrecision
                excessPrecision = min(excessPrecision, UInt32(calcSemantics.precision))
            end
            # extra half-ulp lost in reciprocal of exponent
            powHUerr = powStatus == APF_opOK && calcLostFraction == APF_lfExactlyZero ? UInt32(0) : UInt32(2)
        end
        # both multiplySignificand and divideSignificand return the result with the integer bit set
        apint_tcExtractBit(decSig.significand, 0, UInt32(calcSemantics.precision - 1)) == 1 ||
            throw(ErrorException("WasmTarget: APFloat roundSignificandWithExponent (llvm/lib/Support/APFloat.cpp): the integer bit is clear"))
        local HUerr = UInt64(apfloat_HUerrBound(calcLostFraction != APF_lfExactlyZero, UInt32(sigStatus != APF_opOK), powHUerr))
        local HUdistance = UInt64(2) * apfloat_ulpsFromBoundary(decSig.significand, 0, excessPrecision, isNearest)
        # are we guaranteed to round correctly if we truncate?
        if HUdistance >= HUerr
            apint_tcExtract!(f.significand, 0, length(f.significand), decSig.significand,
                             0, UInt32(calcSemantics.precision) - excessPrecision, excessPrecision)
            # take the exponent of decSig; if we extracted fewer bits above we must adjust our exponent to
            # compensate for the implicit right shift
            f.exponent = decSig.exponent + f.semantics.precision - (calcSemantics.precision - Int(excessPrecision))
            calcLostFraction = apfloat_lostFractionThroughTruncation(decSig.significand, 0, length(decSig.significand), truncatedBits)
            return apfloat_normalize!(f, rounding_mode, calcLostFraction) | ((sigStatus | powStatus) & APF_opInexact)
        end
        parts *= 2
    end
end

# APFloat.cpp:2952 IEEEFloat::convertFromDecimalString: zero, an exponent that certainly overflows or
# underflows, or the significand's digits converted to a bignum a word at a time and rounded with the exponent
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:2952 IEEEFloat::convertFromDecimalString)" "a decimal number's text converted to a float, as APFloat's convertFromDecimalString converts it" Base.:* function apfloat_convertFromDecimalString!(f::APFloatIEEE, s::String, b::Int, e::Int, rounding_mode::Int)::Int
    # scan the text
    local p = b
    local firstSigDigit, lastSigDigit, dexponent, normalizedExponent = apfloat_interpretDecimal(s, b, e)
    local fs::Int
    # the quick cases: no significant digits (zero), and exponents that are obviously too large or too small,
    # by the bounds 42039/12655 < log 10 / log 2 < 28738/8651
    if firstSigDigit == e || apfloat_decDigitValue(codeunit(s, firstSigDigit + 1)) >= 10
        f.category = APF_fcZero
        fs = APF_opOK
    elseif normalizedExponent - 1 > typemax(Int32) ÷ 42039
        fs = apfloat_handleOverflow!(f, rounding_mode)
    elseif normalizedExponent - 1 < typemin(Int32) ÷ 42039 ||
           (normalizedExponent + 1) * 28738 <= 8651 * (f.semantics.minExponent - f.semantics.precision)
        # underflow to zero and round
        f.category = APF_fcNormal
        apfloat_zeroSignificand!(f)
        fs = apfloat_normalize!(f, rounding_mode, APF_lfLessThanHalf)
    elseif (normalizedExponent - 1) * 42039 >= 12655 * f.semantics.maxExponent
        # overflow and round
        fs = apfloat_handleOverflow!(f, rounding_mode)
    else
        # a tight upper bound on the bits an N-digit decimal integer needs is N * 196 / 59; an extra part
        # for tcMultiplyPart
        local partCount = lastSigDigit - firstSigDigit + 1
        partCount = apfloat_partCountForBits(1 + 196 * partCount ÷ 59)
        local decSignificand = zeros(UInt64, partCount + 1)
        partCount = 0
        # almost all multiplication in a word; a bignum multiplication where it would overflow
        while true
            local val = UInt64(0)
            local multiplier = UInt64(1)
            while true
                if codeunit(s, p + 1) == UInt8('.')
                    p += 1
                    p == e && break
                end
                local decValue = UInt64(apfloat_decDigitValue(codeunit(s, p + 1)))
                p += 1
                decValue >= 10 && throw(ErrorException("WasmTarget: APFloat convertFromDecimalString (llvm/lib/Support/APFloat.cpp): Invalid character in significand"))
                multiplier *= UInt64(10)
                val = val * UInt64(10) + decValue
                # the largest number that can be multiplied by ten with any digit added without overflowing
                (p <= lastSigDigit && multiplier <= (typemax(UInt64) - UInt64(9)) ÷ UInt64(10)) || break
            end
            # multiply out the current part
            apint_tcMultiplyPart!(decSignificand, 0, decSignificand, 0, multiplier, val, partCount, partCount + 1, false)
            # if we used another part (likely but not guaranteed), increase the count
            decSignificand[partCount + 1] != 0 && (partCount += 1)
            p <= lastSigDigit || break
        end
        f.category = APF_fcNormal
        fs = apfloat_roundSignificandWithExponent!(f, decSignificand, partCount, dexponent, rounding_mode)
    end
    return fs
end

# APFloat.cpp:3144 IEEEFloat::convertFromString: the sign, then a hexadecimal number after 0x or a decimal
# one. Julia differs: jl_strtod_c reads the special spellings and the sign itself, so this is handed unsigned
# digits alone, and convertFromStringSpecials, whose spellings are not strtod's, is not called
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:3144 IEEEFloat::convertFromString)" "a number's text converted to a float, as APFloat's convertFromString converts it; Julia differs: strtod's syntax reads the special values and the sign before it" Base.:- function apfloat_convertFromString!(f::APFloatIEEE, s::String, b::Int, e::Int, rounding_mode::Int)::Int
    b == e && throw(ErrorException("WasmTarget: APFloat convertFromString (llvm/lib/Support/APFloat.cpp): Invalid string length"))
    local p = b
    local slen = e - b
    f.sign = codeunit(s, p + 1) == UInt8('-')
    if codeunit(s, p + 1) == UInt8('-') || codeunit(s, p + 1) == UInt8('+')
        p += 1
        slen -= 1
        slen == 0 && throw(ErrorException("WasmTarget: APFloat convertFromString (llvm/lib/Support/APFloat.cpp): String has no digits"))
    end
    if slen >= 2 && codeunit(s, p + 1) == UInt8('0') && (codeunit(s, p + 2) == UInt8('x') || codeunit(s, p + 2) == UInt8('X'))
        slen == 2 && throw(ErrorException("WasmTarget: APFloat convertFromString (llvm/lib/Support/APFloat.cpp): Invalid string"))
        return apfloat_convertFromHexadecimalString!(f, s, p + 2, p + slen, rounding_mode)
    end
    return apfloat_convertFromDecimalString!(f, s, p, p + slen, rounding_mode)
end

# APFloat.cpp:859 IEEEFloat::makeNaN: a quiet NaN of no payload, its QNaN bit (precision - 2) set
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:859 IEEEFloat::makeNaN)" "a quiet NaN, as APFloat's makeNaN makes one with no fill" Base.:- function apfloat_makeNaN!(f::APFloatIEEE, negative::Bool)::Nothing
    f.category = APF_fcNaN
    f.sign = negative
    f.exponent = f.semantics.maxExponent + 1
    apint_tcSet!(f.significand, 0, UInt64(0), length(f.significand))
    apint_tcSetBit!(f.significand, 0, UInt32(f.semantics.precision - 2))
    return nothing
end

# APFloat.cpp:4560 IEEEFloat::makeInf
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:4560 IEEEFloat::makeInf)" "an infinity, as APFloat's makeInf makes it" Base.:+ function apfloat_makeInf!(f::APFloatIEEE, negative::Bool)::Nothing
    f.category = APF_fcInfinity
    f.sign = negative
    f.exponent = f.semantics.maxExponent + 1
    apint_tcSet!(f.significand, 0, UInt64(0), length(f.significand))
    return nothing
end

# APFloat.cpp:3443 IEEEFloat::convertIEEEFloatToAPInt: the IEEE encoding of a float of IEEE single or double
# semantics, its sign, biased exponent (0 for a zero or a denormal, all ones for an infinity or a NaN) and
# trailing significand bits, in the low sizeInBits bits of a word
@quarantine pin"precedent(llvm: llvm/lib/Support/APFloat.cpp:3443 IEEEFloat::convertIEEEFloatToAPInt)" "a float's IEEE encoding, as APFloat's convertIEEEFloatToAPInt encodes it" Base.:<< function apfloat_convertIEEEFloatToAPInt(f::APFloatIEEE)::UInt64
    local sem = f.semantics
    local trailing_significand_bits = sem.precision - 1
    local integer_bit = UInt64(1) << trailing_significand_bits
    local significand_mask = integer_bit - UInt64(1)
    local exponent_bits = sem.sizeInBits - 1 - trailing_significand_bits
    local exponent_mask = (UInt64(1) << exponent_bits) - UInt64(1)
    local bias = -(sem.minExponent - 1)
    local myexponent::UInt64
    local mysignificand::UInt64
    if f.category == APF_fcNormal
        myexponent = UInt64(f.exponent + bias)
        mysignificand = f.significand[1]
        myexponent == 1 && (f.significand[1] & integer_bit) == 0 && (myexponent = UInt64(0))   # denormal
    elseif f.category == APF_fcZero
        myexponent = UInt64(sem.minExponent - 1 + bias)
        mysignificand = UInt64(0)
    elseif f.category == APF_fcInfinity
        myexponent = UInt64(sem.maxExponent + 1 + bias)
        mysignificand = UInt64(0)
    else
        myexponent = UInt64(sem.maxExponent + 1 + bias)
        mysignificand = f.significand[1]
    end
    return (mysignificand & significand_mask) | (UInt64(f.sign) << (sem.sizeInBits - 1)) |
           ((myexponent & exponent_mask) << trailing_significand_bits)
end

# ---------------------------------------------------------------------------------------------------
# Julia's strtod (julia/src/support/strtod.c, its portable definition) and its callers (julia/src/rtutils.c).
# The C locale's character classes are LLVM's (llvm/include/llvm/ADT/StringExtras.h): isspace, isdigit,
# isxdigit and tolower in the "C" locale.

# StringExtras.h:158 isSpace: ' ', '\f', '\n', '\r', '\t' or '\v', C's isspace in the "C" locale
@quarantine pin"precedent(llvm: llvm/include/llvm/ADT/StringExtras.h:158 isSpace)" "whether a byte is white space in the C locale, as LLVM's isSpace answers" Base.:(==) c_isspace(c::UInt8)::Bool =
    c == UInt8(' ') || c == UInt8('\f') || c == UInt8('\n') || c == UInt8('\r') || c == UInt8('\t') || c == UInt8('\v')

# StringExtras.h:106 isDigit
@quarantine pin"precedent(llvm: llvm/include/llvm/ADT/StringExtras.h:106 isDigit)" "whether a byte is a decimal digit, as LLVM's isDigit answers" Base.:<= c_isdigit(c::UInt8)::Bool =
    UInt8('0') <= c <= UInt8('9')

# StringExtras.h:109 isHexDigit
@quarantine pin"precedent(llvm: llvm/include/llvm/ADT/StringExtras.h:109 isHexDigit)" "whether a byte is a hexadecimal digit, as LLVM's isHexDigit answers" Base.:!= c_isxdigit(c::UInt8)::Bool =
    apfloat_hexDigitValue(c) != typemax(UInt32)

# StringExtras.h:164 toLower: an upper-case ASCII letter's lower case, any other byte itself
@quarantine pin"precedent(llvm: llvm/include/llvm/ADT/StringExtras.h:164 toLower)" "a byte's lower case in the C locale, as LLVM's toLower lowers it" Base.:+ c_tolower(c::UInt8)::UInt8 =
    UInt8('A') <= c <= UInt8('Z') ? c - UInt8('A') + UInt8('a') : c

# the byte at offset p of a substring that ends at pend, and the NUL past its end: jl_try_substrtod hands strtod a
# NUL-terminated copy of the substring wherever the byte after it could continue a number (rtutils.c:475)
@quarantine pin"julia/src/rtutils.c:466 jl_try_substrtod" "jl_try_substrtod reads a substring NUL-terminated, copying it where the byte past it could continue a number; the port reads a NUL past its end" Base.codeunit strtod_byte(s::String, p::Int, pend::Int)::UInt8 =
    p < pend ? codeunit(s, p + 1) : 0x00

# strtod.c:59 case_insensitive_match: whether the text at p begins with t, case-insensitively, its length
# matched; the matched length returned (0 where it does not match), since C advances no pointer itself
@quarantine pin"julia/src/support/strtod.c:59 case_insensitive_match" "Julia's own match of strtod's special spellings, case-insensitive in the C locale" Base.ncodeunits function case_insensitive_match(s::String, p::Int, pend::Int, t::String)::Bool
    for k in 1:ncodeunits(t)
        c_tolower(strtod_byte(s, p + k - 1, pend)) == codeunit(t, k) || return false
    end
    return true
end

# strtod.c:68 parse_inf_or_nan: a signed inf, infinity or nan, the end of what it read, or p itself where it
# reads none. Julia differs (D7): the host's strtod_l reads nan(n-char-sequence) (C11 7.22.1.3p3: letters,
# digits and _ between the parentheses), which this reads too; an empty sequence is nan, a non-empty one's
# payload is the host's (glibc reads an integer, Apple's libc hexadecimal digits), so it raises, naming the gap
@quarantine pin"julia/src/support/strtod.c:68 parse_inf_or_nan" "Julia's own reading of strtod's infinities and NaNs; Julia differs: the host's strtod_l also reads nan(n-char-sequence), whose payload is the host's, so a non-empty one raises" Base.:+ function parse_inf_or_nan(s::String, p::Int, pend::Int, sem::APFloatSemantics)::Tuple{UInt64,Int}
    local q = p
    local negate = false
    if strtod_byte(s, q, pend) == UInt8('-')
        negate = true
        q += 1
    elseif strtod_byte(s, q, pend) == UInt8('+')
        q += 1
    end
    local f = apfloat_new(sem)
    if case_insensitive_match(s, q, pend, "inf")
        q += 3
        case_insensitive_match(s, q, pend, "inity") && (q += 5)
        apfloat_makeInf!(f, negate)
    elseif case_insensitive_match(s, q, pend, "nan")
        q += 3
        if strtod_byte(s, q, pend) == UInt8('(')
            local r = q + 1
            while true
                local c = strtod_byte(s, r, pend)
                (c_isdigit(c) || UInt8('a') <= c_tolower(c) <= UInt8('z') || c == UInt8('_')) || break
                r += 1
            end
            if strtod_byte(s, r, pend) == UInt8(')')
                r == q + 1 || throw(ErrorException("WasmTarget: strtod of nan(n-char-sequence): a NaN's payload is the host libc's (C11 7.22.1.3p3: implementation-defined), which no pinned source ports (src/patch/strtod.jl parse_inf_or_nan)"))
                q = r + 1
            end
        end
        apfloat_makeNaN!(f, negate)
    else
        return (UInt64(0), p)
    end
    return (apfloat_convertIEEEFloatToAPInt(f), q)
end

# strtod.c:101 jl_strtod_c: leading space skipped, inf and nan read, the sign read, then the unsigned digits
# converted, the end and the C's errno's ERANGE returned beside the value's bits. The digits: Julia's C calls the
# system strtod on them, which reads the longest subject sequence of C11 7.22.1.3p3 (decimal digits with at most
# one point and at least one digit, then an exponent e[+-]digits where one follows whole; or, after 0x,
# hexadecimal ones and an exponent p[+-]digits where one follows whole), correctly rounded; the port reads the
# same sequence and converts it by APFloat's convertFromString, rounding to nearest even, a hexadecimal one with
# no exponent given p0, which C's strtod takes as its value and APFloat requires; ERANGE is APFloat's overflow or
# underflow (C11 7.22.1.3p10). In the C locale the decimal point is '.', so the C's locale copy never runs
@quarantine pin"julia/src/support/strtod.c:101 jl_strtod_c" "Julia's own strtod of the C locale, its conversion of the digits LLVM's APFloat over the subject sequence C's strtod reads" Base.:- function jl_strtod_c(s::String, nptr::Int, pend::Int, sem::APFloatSemantics)::Tuple{UInt64,Int,Bool}
    local p = nptr
    # parse leading spaces
    while c_isspace(strtod_byte(s, p, pend))
        p += 1
    end
    # parse infinities and nans
    local val, endptr = parse_inf_or_nan(s, p, pend, sem)
    endptr != p && return (val, endptr, false)
    # process the leading sign, if present
    local negate = false
    if strtod_byte(s, p, pend) == UInt8('-')
        negate = true
        p += 1
    elseif strtod_byte(s, p, pend) == UInt8('+')
        p += 1
    end
    local digits_pos = p
    local fail_pos::Int
    local hex = strtod_byte(s, p, pend) == UInt8('0') && (strtod_byte(s, p + 1, pend) == UInt8('x') || strtod_byte(s, p + 1, pend) == UInt8('X'))
    if hex
        # this code path is used for hex floats
        p += 2
        # check that what's left begins with a digit or decimal point
        !c_isxdigit(strtod_byte(s, p, pend)) && strtod_byte(s, p, pend) != UInt8('.') && return (UInt64(0), nptr, false)
        local q = p
        local ndigits = 0
        while c_isxdigit(strtod_byte(s, q, pend))
            q += 1; ndigits += 1
        end
        if strtod_byte(s, q, pend) == UInt8('.')
            q += 1
            while c_isxdigit(strtod_byte(s, q, pend))
                q += 1; ndigits += 1
            end
        end
        # no hexadecimal digit: the system strtod reads the 0 before the x alone
        if ndigits == 0
            fail_pos = digits_pos + 1
        else
            local r = q
            local c = strtod_byte(s, r, pend)
            if c == UInt8('p') || c == UInt8('P')
                r += 1
                (strtod_byte(s, r, pend) == UInt8('+') || strtod_byte(s, r, pend) == UInt8('-')) && (r += 1)
                if c_isdigit(strtod_byte(s, r, pend))
                    while c_isdigit(strtod_byte(s, r, pend))
                        r += 1
                    end
                    q = r
                end
            end
            fail_pos = q
        end
    else
        # check that what's left begins with a digit or decimal point
        !c_isdigit(strtod_byte(s, p, pend)) && strtod_byte(s, p, pend) != UInt8('.') && return (UInt64(0), nptr, false)
        local q = p
        local ndigits = 0
        while c_isdigit(strtod_byte(s, q, pend))
            q += 1; ndigits += 1
        end
        if strtod_byte(s, q, pend) == UInt8('.')
            q += 1
            while c_isdigit(strtod_byte(s, q, pend))
                q += 1; ndigits += 1
            end
        end
        ndigits == 0 && return (UInt64(0), nptr, false)   # fail_pos == digits_pos: invalid_string
        local c = strtod_byte(s, q, pend)
        if c == UInt8('e') || c == UInt8('E')
            local r = q + 1
            (strtod_byte(s, r, pend) == UInt8('+') || strtod_byte(s, r, pend) == UInt8('-')) && (r += 1)
            if c_isdigit(strtod_byte(s, r, pend))
                while c_isdigit(strtod_byte(s, r, pend))
                    r += 1
                end
                q = r
            end
        end
        fail_pos = q
    end
    local f = apfloat_new(sem)
    local status::Int
    if hex && fail_pos == digits_pos + 1
        # the 0 alone: zero
        status = apfloat_convertFromString!(f, s, digits_pos, fail_pos, APF_rmNearestTiesToEven)
    elseif hex
        local hasexp = false
        for k in digits_pos+2:fail_pos-1
            local ck = codeunit(s, k + 1)
            (ck == UInt8('p') || ck == UInt8('P')) && (hasexp = true)
        end
        if hasexp
            status = apfloat_convertFromString!(f, s, digits_pos, fail_pos, APF_rmNearestTiesToEven)
        else
            # the digits and p0, a fresh String (wasm_string_copy!, wasm_string_write!)
            local n = fail_pos - digits_pos
            local text = Base._string_n(n + 2)
            wasm_string_copy!(text, 0, s, digits_pos, n)
            wasm_string_write!(text, n, UInt8('p'))
            wasm_string_write!(text, n + 1, UInt8('0'))
            status = apfloat_convertFromString!(f, text, 0, n + 2, APF_rmNearestTiesToEven)
        end
    else
        status = apfloat_convertFromString!(f, s, digits_pos, fail_pos, APF_rmNearestTiesToEven)
    end
    local erange = (status & (APF_opOverflow | APF_opUnderflow)) != 0
    local bits = apfloat_convertIEEEFloatToAPInt(f)
    # if negate and fail_pos != nptr: val = -val, the sign bit flipped
    negate && (bits = xor(bits, UInt64(1) << (sem.sizeInBits - 1)))
    return (bits, fail_pos, erange)
end

# rtutils.c:455 substr_isspace: whether every byte from p to pend is C's white space
@quarantine pin"julia/src/rtutils.c:455 substr_isspace" "Julia's own test that a substring's rest is white space" Base.:+ function substr_isspace(s::String, p::Int, pend::Int)::Bool
    while p != pend
        c_isspace(codeunit(s, p + 1)) || return false
        p += 1
    end
    return true
end

# rtutils.c:466 jl_try_substrtod: strtod of the substring at offset of length len, a value where it read some
# and only white space follows it, none where it read nothing or the value overflowed to an infinity or
# underflowed to zero (errno's ERANGE). Julia differs: the bytes past the substring are never read (the C's
# NUL-terminated copy), strtod_byte's NUL past pend; the result is Base's (hasvalue, value) tuple
@quarantine pin"julia/src/rtutils.c:466 jl_try_substrtod" "libjulia's strtod of a substring, ported over the String's bytes; a wasm module has no libjulia and no libc to call" Base.reinterpret function jl_try_substrtod(s::String, offset::Int, len::Int)::Tuple{Bool,Float64}
    local bstr = offset
    local pend = bstr + len
    local bits, p, erange = jl_strtod_c(s, bstr, pend, APFLOAT_SEM_IEEEDOUBLE)
    local out = reinterpret(Float64, bits)
    local hasvalue = if erange && (out == 0 || out == Inf || out == -Inf)
        false
    elseif p == bstr
        false
    else
        # "1 " is OK, "1 X" is not
        substr_isspace(s, p, pend)
    end
    return (hasvalue, out)
end

# rtutils.c:525 jl_try_substrtof: jl_try_substrtod's twin for a Float32, through strtof (jl_strtof_c,
# strtod.c:35), the digits rounded once to IEEE single as strtof_l rounds them
@quarantine pin"julia/src/rtutils.c:525 jl_try_substrtof" "libjulia's strtof of a substring, ported over the String's bytes; a wasm module has no libjulia and no libc to call" Base.reinterpret function jl_try_substrtof(s::String, offset::Int, len::Int)::Tuple{Bool,Float32}
    local bstr = offset
    local pend = bstr + len
    local bits, p, erange = jl_strtod_c(s, bstr, pend, APFLOAT_SEM_IEEESINGLE)
    local out = reinterpret(Float32, UInt32(bits))
    local hasvalue = if erange && (out == 0 || out == Inf32 || out == -Inf32)
        false
    elseif p == bstr
        false
    else
        substr_isspace(s, p, pend)
    end
    return (hasvalue, out)
end

# ---------------------------------------------------------------------------------------------------
# Base's own bodies (julia/base/parse.jl:262-300), each foreigncall the port above, over the String the C reads
# through its pointer (a SubString's parent String and offset)

@quarantine pin"julia/base/parse.jl:262 tryparse" "Base's tryparse of a Float64 from a String is a jl_try_substrtod foreigncall into libjulia; a wasm module has no libjulia, so its port" Base.tryparse @consistent_overlay METHOD_TABLE function Base.tryparse(::Type{Float64}, s::String)
    hasvalue, val = jl_try_substrtod(s, 0, sizeof(s))
    hasvalue ? val : nothing
end
@quarantine pin"julia/base/parse.jl:267 tryparse" "Base's tryparse of a Float64 from a SubString is a jl_try_substrtod foreigncall into libjulia; a wasm module has no libjulia, so its port" Base.tryparse @consistent_overlay METHOD_TABLE function Base.tryparse(::Type{Float64}, s::SubString{String})
    hasvalue, val = jl_try_substrtod(s.string, s.offset, s.ncodeunits)
    hasvalue ? val : nothing
end
@quarantine pin"julia/base/parse.jl:272 tryparse_internal" "Base's tryparse_internal of a Float64 from a String is a jl_try_substrtod foreigncall into libjulia; a wasm module has no libjulia, so its port" Base.tryparse_internal @consistent_overlay METHOD_TABLE function Base.tryparse_internal(::Type{Float64}, s::String, startpos::Int, endpos::Int)
    hasvalue, val = jl_try_substrtod(s, startpos-1, endpos-startpos+1)
    hasvalue ? val : nothing
end
@quarantine pin"julia/base/parse.jl:277 tryparse_internal" "Base's tryparse_internal of a Float64 from a SubString is a jl_try_substrtod foreigncall into libjulia; a wasm module has no libjulia, so its port" Base.tryparse_internal @consistent_overlay METHOD_TABLE function Base.tryparse_internal(::Type{Float64}, s::SubString{String}, startpos::Int, endpos::Int)
    hasvalue, val = jl_try_substrtod(s.string, s.offset+startpos-1, endpos-startpos+1)
    hasvalue ? val : nothing
end
@quarantine pin"julia/base/parse.jl:282 tryparse" "Base's tryparse of a Float32 from a String is a jl_try_substrtof foreigncall into libjulia; a wasm module has no libjulia, so its port" Base.tryparse @consistent_overlay METHOD_TABLE function Base.tryparse(::Type{Float32}, s::String)
    hasvalue, val = jl_try_substrtof(s, 0, sizeof(s))
    hasvalue ? val : nothing
end
@quarantine pin"julia/base/parse.jl:287 tryparse" "Base's tryparse of a Float32 from a SubString is a jl_try_substrtof foreigncall into libjulia; a wasm module has no libjulia, so its port" Base.tryparse @consistent_overlay METHOD_TABLE function Base.tryparse(::Type{Float32}, s::SubString{String})
    hasvalue, val = jl_try_substrtof(s.string, s.offset, s.ncodeunits)
    hasvalue ? val : nothing
end
@quarantine pin"julia/base/parse.jl:292 tryparse_internal" "Base's tryparse_internal of a Float32 from a String is a jl_try_substrtof foreigncall into libjulia; a wasm module has no libjulia, so its port" Base.tryparse_internal @consistent_overlay METHOD_TABLE function Base.tryparse_internal(::Type{Float32}, s::String, startpos::Int, endpos::Int)
    hasvalue, val = jl_try_substrtof(s, startpos-1, endpos-startpos+1)
    hasvalue ? val : nothing
end
@quarantine pin"julia/base/parse.jl:297 tryparse_internal" "Base's tryparse_internal of a Float32 from a SubString is a jl_try_substrtof foreigncall into libjulia; a wasm module has no libjulia, so its port" Base.tryparse_internal @consistent_overlay METHOD_TABLE function Base.tryparse_internal(::Type{Float32}, s::SubString{String}, startpos::Int, endpos::Int)
    hasvalue, val = jl_try_substrtof(s.string, s.offset+startpos-1, endpos-startpos+1)
    hasvalue ? val : nothing
end
