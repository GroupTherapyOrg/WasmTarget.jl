#!/usr/bin/env julia
# playground/build_codegen.jl — Build the WASM codegen module for the browser playground
# Usage: julia +1.12 --project=. playground/build_codegen.jl

using WasmTarget
using WasmTarget: to_bytes_mvp_flex

# ── IR types (must match test/runtests.jl) ──

struct IRBinCall; name::Symbol; arg1::Any; arg2::Any; end
struct IRRet; val::Any; end
struct IRRef; id::Int64; end
struct IRArg; n::Int64; end
struct IRConst; val::Int64; end

# ── Codegen dispatch (ref.test in WASM) ──

@noinline function e2e_emit_val(bytes::Vector{UInt8}, val::Any)::Vector{UInt8}
    if val isa IRRef
        push!(bytes, 0x20); push!(bytes, UInt8(val.id))
    elseif val isa IRArg
        push!(bytes, 0x20); push!(bytes, UInt8(val.n))
    elseif val isa IRConst
        push!(bytes, 0x42); push!(bytes, UInt8(val.val))
    end
    return bytes
end

@noinline function e2e_emit_op(bytes::Vector{UInt8}, name::Symbol)::Vector{UInt8}
    if name === :mul_int
        push!(bytes, 0x7e)
    elseif name === :add_int
        push!(bytes, 0x7c)
    elseif name === :sub_int
        push!(bytes, 0x7d)
    end
    return bytes
end

@noinline function e2e_compile_stmt(bytes::Vector{UInt8}, stmt::Any, idx::Int32)::Vector{UInt8}
    if stmt isa IRRet
        bytes = e2e_emit_val(bytes, stmt.val)
        push!(bytes, 0x0f)
    elseif stmt isa IRBinCall
        bytes = e2e_emit_val(bytes, stmt.arg1)
        bytes = e2e_emit_val(bytes, stmt.arg2)
        bytes = e2e_emit_op(bytes, stmt.name)
        push!(bytes, 0x21); push!(bytes, UInt8(idx))
    end
    return bytes
end

# ── Source functions ──

src_01(x::Int64) = x * x + Int64(1)                         # x²+1
src_02(x::Int64, y::Int64) = x + y                          # x+y
src_03(x::Int64) = x * Int64(3) - Int64(7)                  # 3x-7
src_04(x::Int64, y::Int64) = x * y + Int64(10)              # xy+10
src_05(x::Int64) = x * x * x                                # x³
src_06(x::Int64, y::Int64) = x * x - y * y                  # x²-y²
src_07(x::Int64) = (x + Int64(1)) * (x - Int64(1))          # (x+1)(x-1)
src_08(x::Int64, y::Int64) = Int64(2) * x + Int64(3) * y    # 2x+3y
src_09(x::Int64) = x                                        # identity
src_10(x::Int64, y::Int64, z::Int64) = x + y + z            # x+y+z
src_11(x::Int64) = x + Int64(1)                             # x+1
src_12(x::Int64) = x * Int64(2)                             # 2x
src_13(x::Int64) = x * x                                    # x²
src_14(x::Int64, y::Int64) = x - y                          # x-y
src_15(x::Int64, y::Int64) = x * y                          # xy
src_16(x::Int64) = x * x + x + Int64(1)                     # x²+x+1
src_17(x::Int64, y::Int64) = x * y + x + y                  # xy+x+y
src_18(x::Int64) = x + x + x                                # 3x (x+x+x)
src_19(x::Int64) = x * Int64(10) + Int64(5)                 # 10x+5
src_20(x::Int64) = Int64(42)                                # const 42
src_21(x::Int64) = x - Int64(1)                             # x-1
src_22(x::Int64, y::Int64, z::Int64) = x * y + z            # xy+z

# ── Auto-generate entry points from Base.code_typed ──

function _val_expr(val, np)
    val isa Core.SSAValue && return :(IRRef(Int64($(np + val.id - 1))))
    val isa Core.Argument && return :(IRArg(Int64($(val.n - 2))))
    val isa Integer && return :(IRConst(Int64($val)))
    error("Unsupported IR value: $(typeof(val))")
end

function _make_entry(name::Symbol, f, types)
    ci = Base.code_typed(f, types, optimize=true)[1][1]
    np = length(types)
    lines, nl = Expr[], 0
    for (k, stmt) in enumerate(ci.code)
        if stmt isa Core.ReturnNode
            (!isdefined(stmt, :val) || stmt.val === nothing) && continue
            push!(lines, :(bytes = e2e_compile_stmt(bytes, IRRet($(_val_expr(stmt.val, np))), Int32(0))))
        elseif stmt isa Expr && stmt.head === :call && length(stmt.args) >= 3
            gref = stmt.args[1]
            if gref isa GlobalRef && (gref.mod === Core.Intrinsics || gref.mod === Base)
                a1, a2 = _val_expr(stmt.args[2], np), _val_expr(stmt.args[3], np)
                push!(lines, :(bytes = e2e_compile_stmt(bytes, IRBinCall($(QuoteNode(gref.name)), $a1, $a2), Int32($(np + k - 1)))))
                nl += 1
            end
        end
    end
    @eval function $name()::Vector{UInt8}
        bytes = UInt8[]
        $(lines...)
        push!(bytes, 0x0b)
        return to_bytes_mvp_flex(bytes, Int32($np), Int32($nl), Int32(0x7e))
    end
end

for (name, f, types) in [
    (:p01, src_01, (Int64,)),     (:p02, src_02, (Int64, Int64)),
    (:p03, src_03, (Int64,)),     (:p04, src_04, (Int64, Int64)),
    (:p05, src_05, (Int64,)),     (:p06, src_06, (Int64, Int64)),
    (:p07, src_07, (Int64,)),     (:p08, src_08, (Int64, Int64)),
    (:p09, src_09, (Int64,)),     (:p10, src_10, (Int64, Int64, Int64)),
    (:p11, src_11, (Int64,)),     (:p12, src_12, (Int64,)),
    (:p13, src_13, (Int64,)),     (:p14, src_14, (Int64, Int64)),
    (:p15, src_15, (Int64, Int64)), (:p16, src_16, (Int64,)),
    (:p17, src_17, (Int64, Int64)), (:p18, src_18, (Int64,)),
    (:p19, src_19, (Int64,)),     (:p20, src_20, (Int64,)),
    (:p21, src_21, (Int64,)),     (:p22, src_22, (Int64, Int64, Int64)),
]
    _make_entry(name, f, types)
end

# ── Build module ──

mod = compile_multi([
    (e2e_compile_stmt, (Vector{UInt8}, Any, Int32)),
    (e2e_emit_val, (Vector{UInt8}, Any)),
    (e2e_emit_op, (Vector{UInt8}, Symbol)),
    (wasm_bytes_length, (Vector{UInt8},), "blen"),
    (wasm_bytes_get, (Vector{UInt8}, Int32), "bget"),
    (p01, (), "p01"), (p02, (), "p02"), (p03, (), "p03"),
    (p04, (), "p04"), (p05, (), "p05"), (p06, (), "p06"),
    (p07, (), "p07"), (p08, (), "p08"), (p09, (), "p09"),
    (p10, (), "p10"), (p11, (), "p11"), (p12, (), "p12"),
    (p13, (), "p13"), (p14, (), "p14"), (p15, (), "p15"),
    (p16, (), "p16"), (p17, (), "p17"), (p18, (), "p18"),
    (p19, (), "p19"), (p20, (), "p20"), (p21, (), "p21"),
    (p22, (), "p22"),
])

outpath = joinpath(@__DIR__, "codegen.wasm")
write(outpath, mod)
println("Built codegen.wasm: $(length(mod)) bytes ($(round(length(mod)/1024, digits=1)) KB)")
