# ============================================================================
# Per-stdlib coverage report  →  test/fuzz/STDLIB_COVERAGE.md
# ============================================================================
# Enumerates each stdlib's FULL public surface (`names(Stdlib)`) and classifies
# every name. "supported" is GROUNDED — it means the name has an actual
# differential test (a catalogue entry the stochastic fuzzer composes + diffs,
# OR a `linalg_diff.jl` sweep) — so the % is provable, not asserted. The rest is
# an explicit BOUNDARY (in-scope, not yet verified) or OUT-OF-SCOPE (genuinely
# non-wasm: BLAS/LAPACK ccall plumbing, threads/timing, file I/O).
#
# Run: julia --project=test/fuzz test/fuzz/stdlib_coverage.jl
#
# This mirrors how core Julia is reported in COVERAGE.md (per-area matrices), but
# per stdlib and over the FULL surface with a real support percentage.

using WasmTarget   # linalg_diff.jl references WasmTarget.Bridge at include time
using LinearAlgebra, Statistics, Dates, Random
const _SCDIR = @__DIR__
include(joinpath(_SCDIR, "catalogue.jl"));   using .FuzzCatalogue
include(joinpath(_SCDIR, "linalg_diff.jl"))   # → LINALG_VERIFIED
include(joinpath(_SCDIR, "dates_diff.jl"))    # → DATES_VERIFIED
include(joinpath(_SCDIR, "random_diff.jl"))   # → RANDOM_VERIFIED
include(joinpath(_SCDIR, "stats_diff.jl"))    # → STATS_VERIFIED

# ── catalogue-verified names, grouped by the Base module a `mod` tag maps to ──
const _CAT_BY_MOD = let d = Dict{Symbol,Set{Symbol}}()
    for e in FuzzCatalogue.CATALOGUE
        push!(get!(d, e.mod, Set{Symbol}()), e.name)
    end
    d
end
_catset(mods...) = union(Set{Symbol}(), (get(_CAT_BY_MOD, m, Set{Symbol}()) for m in mods)...)

# ── per-stdlib spec: verified set (grounded) + out-of-scope set (curated) ──────
struct StdSpec
    name::String
    mod::Module
    verified::Set{Symbol}    # has a real differential test
    outofscope::Set{Symbol}  # genuinely non-wasm — loud-reject boundary
    note::String
end

const SPECS = StdSpec[
    StdSpec("LinearAlgebra", LinearAlgebra,
        union(LINALG_VERIFIED, _catset(:linalg)),
        # genuine CAN'T: LAPACK-packed factorizations WT can't lower (Householder
        # reflectors / Schur form) and have no tractable hand-roll; in-place
        # LAPACK `!`-variants of the object factorizations; general/complex eigen
        # (Jacobi is symmetric-only); matrix equations needing Schur; host/timing.
        Set([:peakflops,
             :qr, :qr!, :lq, :lq!, :schur, :schur!, :ordschur, :ordschur!,
             :hessenberg, :hessenberg!, :bunchkaufman, :bunchkaufman!, :ldlt, :ldlt!,
             :factorize, :lu!, :svd!, :svdvals!, :eigen!, :eigvals!, :eigvecs,
             :cholesky!, :sylvester, :lyap, :nullspace, :lowrankupdate,
             :lowrankupdate!, :lowrankdowndate, :lowrankdowndate!,
             :givens, :diagind, :diagview,
             # isposdef routes through cholesky's LAPACK check (validation error);
             # the rest are internal type-computers / dispatch helpers, not value ops.
             :isposdef, :isposdef!, :matprod_dest, :zeroslike, :haszero,
             :hermitian_type, :symmetric_type, :inertia, :issuccess]),
        "Matrix + factorization + structured-type surface verified by test/fuzz/linalg_diff.jl (61 differential sweeps): values (det/inv/\\/svdvals/eigvals/...), OBJECTS (lu/cholesky/eigen/svd via hand-rolled LU/Jacobi/one-sided-Jacobi, reconstruction-verified), pinv, in-place (mul!/triu!/tril!/lmul!/rmul!/axpy!/axpby!/normalize!), structured types. CAN'T (codegen wall, see out-of-scope): qr/schur/lq/hessenberg/bunchkaufman/ldlt packed forms, in-place LAPACK !-variants, general/complex eigen, sylvester/lyap."),
    StdSpec("Statistics", Statistics,
        union(_catset(:stats), STATS_VERIFIED),
        Set{Symbol}(),
        "Non-! surface fuzzed by the catalogue (mod=:stats; stochastic compose+diff); in-place mean!/median!/quantile! by test/fuzz/stats_diff.jl (mean! via a row-means ext overlay)."),
    StdSpec("Dates", Dates,
        union(DATES_VERIFIED, _catset(:dates)),
        Set([:now, :today, :unix2datetime, :now]),   # wall-clock = host time (defer to embedding)
        "Value layer (accessors / adjusters / arithmetic / construction) differentially fuzzed by test/fuzz/dates_diff.jl. now()/today() need host wall-clock (embedding import)."),
    StdSpec("Random", Random,
        RANDOM_VERIFIED,
        Set([:RandomDevice]),   # OS entropy — host-dependent
        "Seeded Xoshiro streams differentially fuzzed by test/fuzz/random_diff.jl: rand/randn/randexp/randperm/randcycle/shuffle. NB rand/randn are Base-owned (not in names(Random)) so they don't count below, but ARE verified. CAN'T: RandomDevice/seedless = host entropy (embedding); MersenneTwister state hits a codegen gap; randstring char-encoding differs."),
]

# is `nm` a Type / a Function / other, in module `M`?
function _kind(M, nm)
    isdefined(M, nm) || return :undef
    v = try getfield(M, nm) catch; return :undef end
    v isa Type     && return :type
    v isa Function && return :func
    v isa Module   && return :module
    return :const
end

function classify(spec::StdSpec, nm::Symbol)
    nm in spec.verified   && return "supported"
    nm in spec.outofscope && return "out-of-scope"
    k = _kind(spec.mod, nm)
    k === :module && return "out-of-scope"   # BLAS/LAPACK submodules
    return "boundary"
end

open(joinpath(_SCDIR, "STDLIB_COVERAGE.md"), "w") do io
    println(io, "# Stdlib Coverage — per-stdlib support, grounded in differential tests\n")
    println(io, "Regenerate: `julia --project=test/fuzz test/fuzz/stdlib_coverage.jl`\n")
    println(io, "`supported` = has a real differential test (catalogue entry the stochastic")
    println(io, "fuzzer composes+diffs, OR a `linalg_diff.jl` sweep — same bit-exact/tolerance")
    println(io, "oracle as core). `boundary` = in-scope, not yet verified. `out-of-scope` =")
    println(io, "genuinely non-wasm (BLAS/LAPACK ccall plumbing, threads/timing, I/O).\n")
    println(io, "**% support = supported / (supported + boundary)** — i.e. of the in-scope")
    println(io, "surface (out-of-scope excluded). Types listed separately.\n")

    summary = Tuple{String,Int,Int,Int,Int}[]
    for spec in SPECS
        ns = sort([n for n in names(spec.mod)
                   if n !== Symbol(spec.name) && !startswith(string(n), "@") &&
                      _kind(spec.mod, n) !== :undef])
        funcs = [n for n in ns if _kind(spec.mod, n) === :func]
        types = [n for n in ns if _kind(spec.mod, n) === :type]
        rows = [(n, classify(spec, n)) for n in funcs]
        sup = count(r -> r[2] == "supported", rows)
        bnd = count(r -> r[2] == "boundary", rows)
        oos = count(r -> r[2] == "out-of-scope", rows)
        tsup = count(n -> n in spec.verified, types)
        pct = (sup + bnd) == 0 ? 100 : round(Int, 100 * sup / (sup + bnd))
        push!(summary, (spec.name, pct, sup, bnd, oos))

        println(io, "## ", spec.name, " — ", pct, "% of in-scope functions supported")
        println(io, "\n", spec.note, "\n")
        println(io, "Functions: **", sup, " supported**, ", bnd, " boundary, ", oos,
                " out-of-scope (", length(funcs), " total). Types: ", tsup, "/", length(types),
                " with verified construction/ops.\n")
        println(io, "| function | status |")
        println(io, "|---|---|")
        for (n, st) in sort(rows; by = r -> (r[2] != "supported", string(r[1])))
            mark = st == "supported" ? "✅ supported" : st == "boundary" ? "⛔ boundary" : "▽ out-of-scope"
            println(io, "| `", n, "` | ", mark, " |")
        end
        if !isempty(types)
            println(io, "\n**Types** (", tsup, "/", length(types), " with verified ops): ")
            println(io, join(("`$(t)`" * (t in spec.verified ? "✅" : "") for t in types), ", "), "\n")
        end
        println(io)
    end

    println(io, "## Summary\n")
    println(io, "| stdlib | % in-scope supported | supported | boundary | out-of-scope |")
    println(io, "|---|---|---|---|---|")
    for (nm, pct, sup, bnd, oos) in summary
        println(io, "| ", nm, " | **", pct, "%** | ", sup, " | ", bnd, " | ", oos, " |")
    end
end
println("stdlib coverage → test/fuzz/STDLIB_COVERAGE.md")
