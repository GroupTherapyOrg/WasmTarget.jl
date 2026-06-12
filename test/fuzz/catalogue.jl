# ============================================================================
# FuzzCatalogue — the op catalogue as DATA, tagged and grouped by Base module
# ============================================================================
#
# Every entry the generator may emit lives here as
#   CatEntry(name, argtypes, ret; mod, throws, mutates)
# - `mod`     groups entries by the Base area they exercise (the unit Phase 3
#             (julia 1.13) diffs and Phase 4 (stdlibs) extends — a new stdlib is
#             a new builder function here, nothing else).
# - `throws`  marks ops that can throw for in-domain inputs (÷0, empty
#             collections, DomainError…) — M5 generates try/catch around these.
# - `mutates` marks `!`-ops — the args-bridge re-reads their arguments
#             post-call (mutation parity).
#
# The table is built programmatically across the type lattice (the whole point:
# arbitrary well-typed combos, not hand-picked cases). Keep entries WELL-TYPED:
# `gen_expr` trusts (argtypes → ret) blindly.

module FuzzCatalogue

export CatEntry, CATALOGUE, catalogue_by_ret, catalogue_throwy_by_ret, Fn, BinOp
export INT_TYPES, SINT_TYPES, FLOAT_TYPES, NUM_TYPES, VEC_ELT, VEC_NUM, SET_ELT, DICT_KV
export TUPLE_TYPES, NT_TYPES

# A function-typed argument slot: a generated unary lambda `param -> <ret expr>`.
struct Fn
    param::Type
    ret::Type
end
# A binary-operator argument slot (for reduce/foldl): renders as a bare op symbol.
struct BinOp end

struct CatEntry
    name::Symbol
    argtypes::Tuple
    ret::Type
    mod::Symbol          # :arith :bits :cmp :math :conv :bool :vector :dict :set :char :string :tuple
    throws::Bool
    mutates::Bool
end
CatEntry(n, a, r; mod = :arith, throws = false, mutates = false) =
    CatEntry(n, a, r, mod, throws, mutates)

# Indexing compatibility with the old (name, argtypes, ret) tuples.
Base.getindex(e::CatEntry, i::Int) = i == 1 ? e.name : i == 2 ? e.argtypes : i == 3 ? e.ret :
    throw(BoundsError(e, i))

# --- Type lattice -------------------------------------------------------------
const INT_TYPES   = (Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64)
const SINT_TYPES  = (Int8, Int16, Int32, Int64)
const FLOAT_TYPES = (Float32, Float64)
const NUM_TYPES   = (INT_TYPES..., FLOAT_TYPES...)
const VEC_ELT     = (Int64, Int32, Int8, Float64, Float32, Bool)
const VEC_NUM     = (Int64, Int32, Int8, Float64, Float32)
const SET_ELT     = (Int64, Int32, String)
const DICT_KV     = ((Int64, Int64), (Int32, Int64), (Int64, Float64),
                     (String, Int64), (Int64, String), (String, String))
# Composite value types woven through the expression lattice (M3): kept to a
# representative set — the BRIDGE supports arbitrary shapes; the generator just
# needs enough variety to compose them with everything else.
const TUPLE_TYPES = (Tuple{Int64,Int64}, Tuple{Int64,Float64}, Tuple{Float64,Bool},
                     Tuple{Int64,Int64,Int64}, Tuple{Float64,Float64})
const NT_TYPES    = (NamedTuple{(:a, :b),Tuple{Int64,Float64}},
                     NamedTuple{(:n, :flag),Tuple{Int64,Bool}})

function _build()
    O = CatEntry[]
    add(n, a, r; kw...) = push!(O, CatEntry(n, a, r; kw...))
    for T in NUM_TYPES
        add(:+, (T, T), T); add(:-, (T, T), T); add(:*, (T, T), T)
        add(:min, (T, T), T); add(:max, (T, T), T); add(:abs, (T,), T); add(:sign, (T,), T)
        add(:(==), (T, T), Bool; mod = :cmp); add(:(!=), (T, T), Bool; mod = :cmp)
        add(:<, (T, T), Bool; mod = :cmp); add(:<=, (T, T), Bool; mod = :cmp); add(:>, (T, T), Bool; mod = :cmp)
        add(:iszero, (T,), Bool; mod = :cmp)
    end
    for T in (SINT_TYPES..., FLOAT_TYPES...)
        add(:-, (T,), T)            # unary negate (skip on unsigned to avoid wrap noise)
    end
    for T in INT_TYPES
        add(:div, (T, T), T; throws = true); add(:rem, (T, T), T; throws = true)
        add(:mod, (T, T), T; throws = true)                       # ÷0 / typemin÷-1
        add(:&, (T, T), T; mod = :bits); add(:|, (T, T), T; mod = :bits)
        add(:xor, (T, T), T; mod = :bits); add(:~, (T,), T; mod = :bits)
        add(:<<, (T, Int64), T; mod = :bits); add(:>>, (T, Int64), T; mod = :bits)
        add(:isodd, (T,), Bool; mod = :cmp); add(:iseven, (T,), Bool; mod = :cmp)
    end
    for T in SINT_TYPES
        add(:gcd, (T, T), T; throws = true); add(:lcm, (T, T), T; throws = true)  # typemin overflow
    end
    for T in FLOAT_TYPES
        add(:/, (T, T), T); add(:hypot, (T, T), T; mod = :math); add(:copysign, (T, T), T)
        add(:^, (T, T), T; mod = :math)
        add(:mod, (T, T), T); add(:rem, (T, T), T)
        for u in (:sqrt, :cbrt, :sin, :cos, :tan, :asin, :acos, :atan, :sinh, :cosh, :tanh,
                  :exp, :exp2, :expm1, :log, :log2, :log10, :log1p,
                  :floor, :ceil, :round, :trunc, :inv, :sinpi, :cospi, :deg2rad, :rad2deg)
            # sqrt/log/asin/acos throw DomainError on negative/out-of-range args
            add(u, (T,), T; mod = :math, throws = u in (:sqrt, :log, :log2, :log10, :log1p, :asin, :acos))
        end
        add(:isnan, (T,), Bool; mod = :cmp); add(:isinf, (T,), Bool; mod = :cmp)
        add(:isfinite, (T,), Bool; mod = :cmp); add(:signbit, (T,), Bool; mod = :cmp)
    end
    # Conversions: bridge the lattice back to top types; narrowing conversions THROW
    # on out-of-range (InexactError) — prime try/catch fodder.
    for T in (Int8, Int16, Int32, UInt8, UInt16, UInt32)
        add(:Int64, (T,), Int64; mod = :conv)
    end
    add(:signed, (UInt64,), Int64; mod = :conv)
    for T in INT_TYPES
        add(:Float64, (T,), Float64; mod = :conv); add(:Float32, (T,), Float32; mod = :conv)
    end
    add(:Float64, (Float32,), Float64; mod = :conv); add(:Float32, (Float64,), Float32; mod = :conv)
    for T in (Int8, Int16, Int32)
        add(T |> nameof, (Int64,), T; mod = :conv, throws = true)   # narrowing InexactError
    end
    add(:Int64, (Float64,), Int64; mod = :conv, throws = true)      # InexactError on non-integral
    # NOTE: round(Int64, x) needs a TYPE-literal first slot the generator can't
    # type-direct (an Int64-typed EXPR is not the type Int64) — covered by the
    # Int64(::Float64) ctor entry above instead.
    # ── P4-stdlib: Dates scalar predicates (the Date-typed surface needs
    # value generators — deferred; these compose freely with Int64 exprs).
    add(:isleapyear, (Int64,), Bool; mod = :dates)
    add(:daysinmonth, (Int64, Int64), Int64; mod = :dates, throws = true)  # month ∉ 1:12 throws

    # Bool logic
    add(:&, (Bool, Bool), Bool; mod = :bool); add(:|, (Bool, Bool), Bool; mod = :bool)
    add(:!, (Bool,), Bool; mod = :bool); add(:xor, (Bool, Bool), Bool; mod = :bool)
    add(:(==), (Bool, Bool), Bool; mod = :bool)
    add(:ifelse, (Bool, Int64, Int64), Int64; mod = :bool)
    add(:ifelse, (Bool, Float64, Float64), Float64; mod = :bool)
    # Vector{T}
    for T in VEC_ELT
        VT = Vector{T}
        # ── P4-stdlib: Statistics (the stdlib-integration pilot). Names
        # resolve in Main via `using Statistics` in the fuzz runner. All
        # reductions return Float64; empty vectors throw for median/middle
        # (ArgumentError/BoundsError) and quantile throws for p ∉ [0,1] —
        # throws=true makes the harness check throw-parity, not skip them.
        if T === Float64 || T === Int64
            add(:mean, (VT,), Float64; mod = :stats)
        end
        if T === Float64
            # median/middle restricted to Float64: the Int64 radix path
            # stores a memoryrefnew [ref,idx] stack pair to an SSA local
            # (open gap family a517b4c8372d — two-value SSA architectural
            # item). Re-add Int64 when pair-locals land.
            add(:median, (VT,), Float64; mod = :stats, throws = true)
            add(:middle, (VT,), Float64; mod = :stats, throws = true)
            add(:var, (VT,), Float64; mod = :stats)
            add(:std, (VT,), Float64; mod = :stats)
            add(:quantile, (VT, Float64), Float64; mod = :stats, throws = true)
            add(:cor, (VT, VT), Float64; mod = :stats, throws = true)   # length mismatch throws
        end
        add(:sort, (VT,), VT; mod = :vector); add(:reverse, (VT,), VT; mod = :vector)
        add(:unique, (VT,), VT; mod = :vector)
        add(:length, (VT,), Int64; mod = :vector); add(:isempty, (VT,), Bool; mod = :vector)
        add(:map, (Fn(T, T), VT), VT; mod = :vector); add(:filter, (Fn(T, Bool), VT), VT; mod = :vector)
        add(:first, (VT,), T; mod = :vector, throws = true)   # empty → BoundsError
        add(:last, (VT,), T; mod = :vector, throws = true)
        add(:getindex, (VT, Int64), T; mod = :vector, throws = true)   # BoundsError
        add(:in, (T, VT), Bool; mod = :vector); add(:count, (Fn(T, Bool), VT), Int64; mod = :vector)
        add(:any, (Fn(T, Bool), VT), Bool; mod = :vector); add(:all, (Fn(T, Bool), VT), Bool; mod = :vector)
        add(:push!, (VT, T), VT; mod = :vector, mutates = true)
        add(:pushfirst!, (VT, T), VT; mod = :vector, mutates = true)
        add(:sort!, (VT,), VT; mod = :vector, mutates = true)
        add(:reverse!, (VT,), VT; mod = :vector, mutates = true)
        # NOTE: collect(Vector) omitted — raw-pointer memmove foreigncall (see FINDINGS.md).
    end
    for T in VEC_NUM
        VT = Vector{T}
        add(:sum, (VT,), T; mod = :vector); add(:prod, (VT,), T; mod = :vector)
        add(:maximum, (VT,), T; mod = :vector, throws = true)   # empty → ArgumentError
        add(:minimum, (VT,), T; mod = :vector, throws = true)
        add(:reduce, (BinOp(), VT), T; mod = :vector, throws = true)
        add(:foldl, (BinOp(), VT), T; mod = :vector, throws = true)
        add(:argmax, (VT,), Int64; mod = :vector, throws = true)
        add(:argmin, (VT,), Int64; mod = :vector, throws = true)
        add(:cumsum, (VT,), VT; mod = :vector)
    end
    # Dict{K,V}
    for (K, V) in DICT_KV
        DT = Dict{K,V}
        add(:length, (DT,), Int64; mod = :dict); add(:isempty, (DT,), Bool; mod = :dict)
        add(:haskey, (DT, K), Bool; mod = :dict); add(:get, (DT, K, V), V; mod = :dict)
        add(:getindex, (DT, K), V; mod = :dict, throws = true)   # KeyError
    end
    # Set{T}
    for T in SET_ELT
        ST = Set{T}
        add(:length, (ST,), Int64; mod = :set); add(:isempty, (ST,), Bool; mod = :set)
        add(:in, (T, ST), Bool; mod = :set)
    end
    # Char
    for u in (:isdigit, :isspace, :isletter, :isuppercase, :islowercase, :isascii)
        add(u, (Char,), Bool; mod = :char)
    end
    add(:uppercase, (Char,), Char; mod = :char); add(:lowercase, (Char,), Char; mod = :char)
    add(:Int, (Char,), Int64; mod = :char)
    add(:<, (Char, Char), Bool; mod = :char); add(:(==), (Char, Char), Bool; mod = :char)
    # String
    for u in (:uppercase, :lowercase, :reverse, :strip, :lstrip, :rstrip,
              :chomp, :titlecase, :uppercasefirst, :lowercasefirst)
        add(u, (String,), String; mod = :string)
    end
    add(:*, (String, String), String; mod = :string)
    add(:string, (Int64,), String; mod = :string); add(:string, (Float64,), String; mod = :string)
    add(:length, (String,), Int64; mod = :string); add(:ncodeunits, (String,), Int64; mod = :string)
    add(:isempty, (String,), Bool; mod = :string); add(:isascii, (String,), Bool; mod = :string)
    for b in (:startswith, :endswith, :contains, :occursin)
        add(b, (String, String), Bool; mod = :string)
    end
    add(:cmp, (String, String), Int64; mod = :string)
    # Tuples / NamedTuples: element access (literals are generator productions).
    for TT in TUPLE_TYPES
        for i in 1:fieldcount(TT)
            add(:getindex, (TT, Val{i}), fieldtype(TT, i); mod = :tuple)  # rendered as t[i] literal index
        end
        add(:length, (TT,), Int64; mod = :tuple)
        fieldcount(TT) == 2 && fieldtype(TT, 1) === fieldtype(TT, 2) &&
            add(:reverse, (TT,), TT; mod = :tuple)
    end
    for NT in NT_TYPES
        for (i, nm) in enumerate(fieldnames(NT))
            add(Symbol(".", nm), (NT,), fieldtype(NT, i); mod = :tuple)  # rendered as x.nm
        end
    end
    return O
end

const CATALOGUE = _build()

# Throw-capable entries by return type — M5 biases try-bodies toward these.
function catalogue_throwy_by_ret()
    d = Dict{Type,Vector{CatEntry}}()
    for e in CATALOGUE
        e.throws && push!(get!(d, e.ret, CatEntry[]), e)
    end
    return d
end

function catalogue_by_ret()
    d = Dict{Type,Vector{CatEntry}}()
    for e in CATALOGUE
        push!(get!(d, e.ret, CatEntry[]), e)
    end
    return d
end

end # module FuzzCatalogue
