# Ryu's shortest float digits by overlay (julia/base/ryu/shortest.jl:228 writeshortest), as
# src/patch/io.jl's IOBuffer writes: Base inserts the decimal point into the digits it has written by
# shifting the bytes after it one place through the buffer's raw pointer (memmove(ptr + pos + pointoff,
# ptr + pos + pointoff - 1, n), ptr = pointer(buf)), and WasmGC has no raw memory, so the method is
# replaced in WasmTarget's overlay method table (METHOD_TABLE, src/julia/interpreter.jl) for a byte
# Vector, Base's body with that shift the Vector's own copyto! of the same bytes one element on (the
# overlapping copy memmove makes, its elements from pos + pointoff to pos + pointoff + 1: pointer(buf) + k
# addresses element k + 1), a wasm array.copy (src/patch/genericmemory.jl unsafe_copyto!). The overlay
# is consistent: natively it computes Base's answer. Any other buffer stays Base's, a located rejection
# where it is reached. precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm;
# gpucompiler: a device's overlays of Base in its method table).

# Base's body (julia/base/ryu/shortest.jl:228), Ryu's own definitions by their names in Base.Ryu
@quarantine pin"julia/base/ryu/shortest.jl:228 writeshortest" "Base's writeshortest shifts its digits for the decimal point by memmove through pointer(buf); WasmGC has no raw memory, so a byte Vector's digits are shifted by its copyto!, an array.copy" Base.Ryu.writeshortest @consistent_overlay METHOD_TABLE function Base.Ryu.writeshortest(buf::Vector{UInt8}, pos, x::T,
                       plus=false, space=false, hash=true,
                       precision=-1, expchar=UInt8('e'), padexp=false, decchar=UInt8('.'),
                       typed=false, compact=false) where {T}
    @assert 0 < pos <= length(buf) "invalid pos"
    # special cases
    if x == 0
        if typed && x isa Float16
            @inbounds buf[pos] = UInt8('F')
            @inbounds buf[pos + 1] = UInt8('l')
            @inbounds buf[pos + 2] = UInt8('o')
            @inbounds buf[pos + 3] = UInt8('a')
            @inbounds buf[pos + 4] = UInt8('t')
            @inbounds buf[pos + 5] = UInt8('1')
            @inbounds buf[pos + 6] = UInt8('6')
            @inbounds buf[pos + 7] = UInt8('(')
            pos += 8
        end
        pos = Base.Ryu.append_sign(x, plus, space, buf, pos)
        @inbounds buf[pos] = UInt8('0')
        pos += 1
        if hash
            @inbounds buf[pos] = decchar
            pos += 1
        end
        if precision == -1
            @inbounds buf[pos] = UInt8('0')
            pos += 1
            if typed && x isa Float32
                @inbounds buf[pos] = UInt8('f')
                @inbounds buf[pos + 1] = UInt8('0')
                pos += 2
            end
            if typed && x isa Float16
                @inbounds buf[pos] = UInt8(')')
                pos += 1
            end
            return pos
        end
        while hash && precision > 1
            @inbounds buf[pos] = UInt8('0')
            pos += 1
            precision -= 1
        end
        if typed && x isa Float32
            @inbounds buf[pos] = UInt8('f')
            @inbounds buf[pos + 1] = UInt8('0')
            pos += 2
        end
        if typed && x isa Float16
            @inbounds buf[pos] = UInt8(')')
            pos += 1
        end
        return pos
    elseif isnan(x)
        pos = Base.Ryu.append_sign(x, plus, space, buf, pos)
        @inbounds buf[pos] = UInt8('N')
        @inbounds buf[pos + 1] = UInt8('a')
        @inbounds buf[pos + 2] = UInt8('N')
        if typed
            if x isa Float32
                @inbounds buf[pos + 3] = UInt8('3')
                @inbounds buf[pos + 4] = UInt8('2')
            elseif x isa Float16
                @inbounds buf[pos + 3] = UInt8('1')
                @inbounds buf[pos + 4] = UInt8('6')
            end
        end
        return pos + 3 + (typed && x isa Union{Float32, Float16} ? 2 : 0)
    elseif !isfinite(x)
        pos = Base.Ryu.append_sign(x, plus, space, buf, pos)
        @inbounds buf[pos] = UInt8('I')
        @inbounds buf[pos + 1] = UInt8('n')
        @inbounds buf[pos + 2] = UInt8('f')
        if typed
            if x isa Float32
                @inbounds buf[pos + 3] = UInt8('3')
                @inbounds buf[pos + 4] = UInt8('2')
            elseif x isa Float16
                @inbounds buf[pos + 3] = UInt8('1')
                @inbounds buf[pos + 4] = UInt8('6')
            end
        end
        return pos + 3 + (typed && x isa Union{Float32, Float16} ? 2 : 0)
    end

    output, nexp = Base.Ryu.reduce_shortest(x, compact ? 999_999 : nothing)

    if typed && x isa Float16
        @inbounds buf[pos] = UInt8('F')
        @inbounds buf[pos + 1] = UInt8('l')
        @inbounds buf[pos + 2] = UInt8('o')
        @inbounds buf[pos + 3] = UInt8('a')
        @inbounds buf[pos + 4] = UInt8('t')
        @inbounds buf[pos + 5] = UInt8('1')
        @inbounds buf[pos + 6] = UInt8('6')
        @inbounds buf[pos + 7] = UInt8('(')
        pos += 8
    end
    pos = Base.Ryu.append_sign(x, plus, space, buf, pos)

    olength = Base.Ryu.decimallength(output)
    exp_form = true
    pt = nexp + olength
    if -4 < pt <= (precision == -1 ? (T == Float16 ? 3 : 6) : precision) &&
        !(pt >= olength && abs(mod(x + 0.05, 10^(pt - olength)) - 0.05) > 0.05)
        exp_form = false
        if pt <= 0
            @inbounds buf[pos] = UInt8('0')
            pos += 1
            @inbounds buf[pos] = decchar
            pos += 1
            for _ = 1:abs(pt)
                @inbounds buf[pos] = UInt8('0')
                pos += 1
            end
        # elseif pt >= olength
            # nothing to do at this point
        # else
            # nothing to do at this point
        end
    else
        # make space for decchar
        pos += 1
    end

    Base.Ryu.append_c_digits(olength, output, buf, pos)

    if !exp_form
        if pt <= 0
            pos += olength
            precision -= olength
        elseif pt >= olength
            pos += olength
            precision -= olength
            for _ = 1:nexp
                @inbounds buf[pos] = UInt8('0')
                pos += 1
                precision -= 1
            end
            if hash
                @inbounds buf[pos] = decchar
                pos += 1
                if precision < 0
                    @inbounds buf[pos] = UInt8('0')
                    pos += 1
                end
            end
        else
            pointoff = olength - abs(nexp)
            # shift bytes after pointoff to make room for decchar
            copyto!(buf, pos + pointoff + 1, buf, pos + pointoff, olength - pointoff + 1)
            @inbounds buf[pos + pointoff] = decchar
            pos += olength + 1
            precision -= olength
        end
        if hash
            while precision > 0
                @inbounds buf[pos] = UInt8('0')
                pos += 1
                precision -= 1
            end
        end
        if typed && x isa Float32
            @inbounds buf[pos] = UInt8('f')
            @inbounds buf[pos + 1] = UInt8('0')
            pos += 2
        end
    else
        # move leading digit into place
        @inbounds buf[pos - 1] = buf[pos]
        if olength > 1 || hash
            @inbounds buf[pos] = decchar
            pos += olength
            precision -= olength
        end
        if hash
            if olength == 1
                @inbounds buf[pos] = UInt8('0')
                pos += 1
            end
            while precision > 0
                @inbounds buf[pos] = UInt8('0')
                pos += 1
                precision -= 1
            end
        end

        @inbounds buf[pos] = expchar
        pos += 1
        exp2 = nexp + olength - 1
        if exp2 < 0
            @inbounds buf[pos] = UInt8('-')
            pos += 1
            exp2 = -exp2
        elseif padexp
            @inbounds buf[pos] = UInt8('+')
            pos += 1
        end

        if exp2 >= 100
            c = exp2 % 10
            @inbounds d100 = Base.Ryu.DIGIT_TABLE16[(div(exp2, 10) % Int) + 1]
            @inbounds buf[pos] = d100 % UInt8
            @inbounds buf[pos + 1] = (d100 >> 0x8) % UInt8
            @inbounds buf[pos + 2] = UInt8('0') + (c % UInt8)
            pos += 3
        elseif exp2 >= 10
            @inbounds d100 = Base.Ryu.DIGIT_TABLE16[(exp2 % Int) + 1]
            @inbounds buf[pos] = d100 % UInt8
            @inbounds buf[pos + 1] = (d100 >> 0x8) % UInt8
            pos += 2
        else
            if padexp
                @inbounds buf[pos] = UInt8('0')
                pos += 1
            end
            @inbounds buf[pos] = UInt8('0') + (exp2 % UInt8)
            pos += 1
        end
    end
    if typed && x isa Float16
        @inbounds buf[pos] = UInt8(')')
        pos += 1
    end

    return pos
end
