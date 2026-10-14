# An overlay's quarantine reason is a claim about Julia's own method. A reason that names a
# BLAS or LAPACK routine — `parity(quarantine: BLAS gemm: …)` directly above the overlay —
# says the method the overlay replaces reaches that routine's foreigncall at the overlay's
# signature. This checks each such claim against Julia's typed IR (the method Julia would
# run, found without the overlay table), following its invokes (dev/CHARTER.md C3, L140).
using Test
using WasmTarget
using LinearAlgebra

const _OR_FILE = joinpath(pkgdir(WasmTarget), "ext", "WasmTargetLinearAlgebraExt.jl")

# overlay line => the routine its reason names
function _or_tagged_lines()::Dict{Int,String}
    L = readlines(_OR_FILE)
    out = Dict{Int,String}()
    for (i, l) in enumerate(L)
        occursin(r"^@overlay WasmTarget\.WASM_METHOD_TABLE", l) || continue
        j = i - 1
        while j >= 1 && startswith(L[j], "#")
            m = match(r"parity\(quarantine: (?:BLAS|LAPACK) (\w+):", L[j])
            if m !== nothing
                out[i] = m.captures[1]
                break
            end
            j -= 1
        end
    end
    return out
end

# A concrete signature for an overlay's: each type variable and each abstract parameter takes
# the first stand-in its bounds admit (Float64, then an array dimension 1, then Int64, a pivot
# vector Vector{Int64}, Char, Symbol), backtracking until the result is a dispatch tuple.
const _OR_STANDINS = Any[Float64, 1, Int64, Vector{Int64}, Char, Symbol]

function _or_close(@nospecialize(T))
    T isa UnionAll || return T
    v = T.var
    for c in _OR_STANDINS
        (c isa Type ? (v.lb <: c <: v.ub) : v.ub === Any) || continue
        inst = try T{c} catch; continue end
        r = _or_close(inst)
        r === nothing || return r
    end
    return nothing
end

function _or_param(@nospecialize(p))
    p = _or_close(p)
    p === nothing && return nothing
    (p isa DataType && isconcretetype(p)) && return p
    p isa Type || return p
    for c in _OR_STANDINS
        c isa Type && c <: p && return c
    end
    return p
end

# the dispatch tuple a closed signature gives, or nothing
function _or_dispatch(@nospecialize(s))
    s isa UnionAll && return nothing
    ps = Any[_or_param(p) for p in s.parameters]
    any(p -> p === nothing, ps) && return nothing
    t = Tuple{ps...}
    Base.isdispatchtuple(t) || return nothing
    typed = try Base.code_typed_by_type(t; optimize = false) catch; Any[] end
    return isempty(typed) ? nothing : t     # a stand-in Julia cannot type is no signature
end

# the first combination of stand-ins for the signature's type variables that Julia types
function _or_concrete(@nospecialize(sig))
    sig isa UnionAll || return something(_or_dispatch(sig), sig)
    v = sig.var
    # an unbounded variable here is an array's dimension count (element types are bounded)
    for c in (v.ub === Any ? Any[1; _OR_STANDINS] : _OR_STANDINS)
        (c isa Type ? (v.lb <: c <: v.ub) : v.ub === Any) || continue
        inst = try sig{c} catch; continue end
        t = inst isa UnionAll ? _or_concrete(inst) : _or_dispatch(inst)
        (t isa Type && Base.isdispatchtuple(t) && !isempty(try Base.code_typed_by_type(t; optimize = false) catch; Any[] end)) && return t
    end
    return sig
end

# the foreigncall names Julia's own method reaches at `sig`, through its invokes
function _or_foreigncalls(@nospecialize(sig); depth::Int = 12, seen::Set{Any} = Set{Any}())::Set{String}
    out = Set{String}()
    depth == 0 && return out
    res = try
        Base.code_typed_by_type(sig; optimize = true)
    catch
        Any[]
    end
    for (ci, _) in res, st in ci.code
        st isa Expr || continue
        if st.head === :foreigncall
            push!(out, string(st.args[1]))
        elseif st.head === :invoke
            x = st.args[1]
            mi = x isa Core.CodeInstance ? x.def : x
            (mi isa Core.MethodInstance && !(mi in seen)) || continue
            push!(seen, mi)
            union!(out, _or_foreigncalls(mi.specTypes; depth = depth - 1, seen))
        end
    end
    return out
end

@testset "an overlay's BLAS/LAPACK reason is true of Julia's method" begin
    tagged = _or_tagged_lines()
    @test length(tagged) >= 30
    overlays = Method[]
    Base.visit(m -> push!(overlays, m), WasmTarget.WASM_METHOD_TABLE)
    here = [m for m in overlays if endswith(string(m.file), "WasmTargetLinearAlgebraExt.jl") &&
                                   !startswith(string(m.name), "#")]
    for (line, routine) in sort!(collect(tagged))
        ms = [m for m in here if m.line == line]
        @test !isempty(ms)
        reached = any(m -> any(n -> occursin(routine, n), _or_foreigncalls(_or_concrete(m.sig))), ms)
        reached || @error "an overlay's reason names a routine Julia's method does not reach" line routine methods = ms
        @test reached
    end
end
