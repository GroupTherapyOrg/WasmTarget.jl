# ============================================================================
# FuzzStructPool — seeded pool of generated struct TYPES for the fuzz universe
# ============================================================================
#
# Per-example struct *definitions* don't work under Supposition (each def needs
# a top-level `eval` + world-age step). Instead: a POOL of K random struct types
# is generated ONCE per process from a seed (deterministic — same seed, same
# pool, so corpus replay and shrunk counterexamples stay meaningful), eval'd at
# load time, and registered with the generator as ordinary types: construction,
# field access, and field-set (mutable) become catalogue-style productions, and
# the bit-exact bridge handles their values like any other struct.

module FuzzStructPool

export POOL, PoolStruct, pool_structs, pool_field_entries

using Random

struct PoolStruct
    T::Type
    name::Symbol
    mutable::Bool
    fieldtypes::Vector{Type}
end

# Field types drawn for generated structs — primitive + one nesting level
# (earlier pool structs may appear as fields of later ones).
const _FIELD_CHOICES = Type[Int64, Int32, Float64, Float32, Bool, Int8, UInt8, Char, String]

const POOL = PoolStruct[]

"""
    build_pool!(; k = 6, seed = 0x57AB1E)

Idempotently generate + `eval` the pool (call once per process before
generating programs). Deterministic in `seed`. Roughly half the structs are
mutable; later structs may nest earlier ones one level deep.
"""
function build_pool!(; k::Int = 6, seed::Integer = 0x57AB1E)
    isempty(POOL) || return POOL
    rng = Xoshiro(seed)
    for i in 1:k
        nf = rand(rng, 1:4)
        mut = isodd(i)
        # one nesting level: structs after the 3rd may embed an earlier pool struct
        choices = i > 3 ? vcat(_FIELD_CHOICES, Type[p.T for p in POOL[1:min(2, end)]]) : _FIELD_CHOICES
        fts = Type[choices[rand(rng, 1:length(choices))] for _ in 1:nf]
        name = Symbol("FuzzPS", i, mut ? "m" : "")
        fields = [Expr(:(::), Symbol("f", j), nameof_expr(fts[j])) for j in 1:nf]
        def = Expr(:struct, mut, name, Expr(:block, fields...))
        Core.eval(Main, def)
        # invokelatest: 1.12 strict binding world-age — the binding was created
        # in a newer world than this function's.
        T = Base.invokelatest(getfield, Main, name)
        push!(POOL, PoolStruct(T, name, mut, fts))
    end
    return POOL
end

# Render a type as the expression that names it (pool structs live in Main).
nameof_expr(T::Type) = Meta.parse(string(T))

pool_structs() = [p.T for p in POOL]

"""
    pool_field_entries() -> Vector{(fieldtype, struct_T, fieldname)}

Field-access productions: an expression of `fieldtype` can be produced as
`<expr-of-struct_T>.fieldname`.
"""
function pool_field_entries()
    out = Tuple{Type,Type,Symbol}[]
    for p in POOL
        for (j, ft) in enumerate(p.fieldtypes)
            push!(out, (ft, p.T, Symbol("f", j)))
        end
    end
    return out
end

end # module FuzzStructPool
