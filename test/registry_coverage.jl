# Registry coverage lane (dev/MARCH.md §5): every entry of every lowering registry is
# exercised by the fast lanes — the differential smoke corpus or the byte-identity probe
# corpus. Without this, `dev/lanes.sh` green says nothing about an entry no case reaches:
# on 2026-09-08 a NIR conversion broke `jl_type_intersection`'s lowering (all 19 seeded
# Random differentials failed in the full suite) while smoke and probes stayed green.
#
# Measured from the test side only: each entry's function is wrapped to record the hit,
# then both corpora compile in this process. Production code is untouched. A smoke case
# that compiles is also run differentially by the smoke lane, and a probe's bytes are
# fingerprinted by the probe lane, so a hit here is exercised by a gate there.
#
#   julia --project=. test/registry_coverage.jl          # exit 1 on an unexercised entry
#   WT_COVERAGE_LIST=1 julia --project=. test/registry_coverage.jl   # also list covered
#   WT_COVERAGE_PART=i/N WT_COVERAGE_DIR=<dir> ...   # compile part i of N of the cases (dealt
#       round-robin, probes then smoke) and write its units and hits to <dir>, no verdict
#   WT_COVERAGE_MERGE=1 WT_COVERAGE_DIR=<dir> ...    # the verdict on the union of the parts in
#       <dir>: parts 0..N-1 of one N, each with the same units (dev/lanes.sh --lane coverage
#       --part i/N, then --merge: dev/gate.sh's coverage jobs)
#
# Coverage unit: the key, for registries keyed by what the lowering matches (foreigncall
# symbol, builtin callee, numeric op/type tuple); the entry function, for registries keyed
# by Method (one entry registers every method of a generic function — `println`'s methods
# are one lowering, not forty).
const _MERGE = get(ENV, "WT_COVERAGE_MERGE", "") == "1"
const _PART = let s = get(ENV, "WT_COVERAGE_PART", "")
    m = match(r"^([0-9]+)/([1-9][0-9]*)$", s)
    if isempty(s)
        (0, 1)
    elseif m === nothing || parse(Int, m[1]) >= parse(Int, m[2])
        error("WT_COVERAGE_PART=$s: expected i/N with 0 <= i < N")
    else
        (parse(Int, m[1]), parse(Int, m[2]))
    end
end
const _DIR = get(ENV, "WT_COVERAGE_DIR", "")
(_MERGE || _PART[2] > 1) && isempty(_DIR) && error("WT_COVERAGE_PART and WT_COVERAGE_MERGE need WT_COVERAGE_DIR")

const ALLOWLIST = Dict{Tuple{Symbol,String},String}(
    (:BUILTIN_LOWERINGS, "Core.apply_type") => "fires for a runtime Union{T, Nothing} and rejects: jl_type_union's normalization is not ported — smoke xfail apply_type_union (measured 2026-09-27)",
    (:BUILTIN_LOWERINGS, "Base.getproperty") => "fires on an Any receiver; the struct and primitive candidates compile (smoke getfield_runtime_name), and the getproperty(::Memory{Any}, ::Symbol) candidate rejects: a runtime-name read of a Memory could be its `ptr` — smoke xfail builtin_crashes/getproperty_any (measured 2026-09-29)",
    (:BUILTIN_LOWERINGS, "Base.setproperty!") => "fires on an Any receiver; the setproperty!(::Memory{Any}, ::Symbol, ::Int64) candidate rejects at fieldtype(Memory{Any}, name) with a runtime name — smoke xfail builtin_crashes/setproperty_any (measured 2026-09-29)",
    (:FOREIGN_LOWERINGS, "jl_ptr_to_array_1d") => "fires for unsafe_wrap(Array, pointer(v), n) and declines (pointer not traced) — smoke xfail pointer_foreigncalls/unsafe_wrap_pointer (measured 2026-09-22)",
    (:FOREIGN_LOWERINGS, "jl_value_ptr") => "every measured spelling (pointer_from_objref of a Ref, graphemes, isgraphemebreak!) rejects 'escapes storage-relative WasmGC operations' — smoke xfail pointer_foreigncalls/ref_pointer_load (measured 2026-09-22)",
)

# The verdict on the units (registry, label) and the units hit: exit status 0 only when every
# unit is hit or allowlisted and no allowlist entry is hit.
function coverage_verdict(units, hits)::Int
    uncovered = sort!([x for x in units if x ∉ hits])
    unexpected = [x for x in uncovered if !haskey(ALLOWLIST, x)]
    stale = [x for x in keys(ALLOWLIST) if x ∉ uncovered]
    if get(ENV, "WT_COVERAGE_LIST", "") == "1"
        for (reg, u) in sort!(collect(hits)); println("  covered    ", reg, "  ", u); end
    end
    for (reg, label) in unexpected; println("  UNEXERCISED ", reg, "  ", label); end
    for (reg, label) in stale; println("  STALE allowlist entry (now covered — delete it): ", reg, "  ", label); end
    byreg = Dict{Symbol,Tuple{Int,Int}}()
    for (reg, u) in units
        c, t = get(byreg, reg, (0, 0)); byreg[reg] = (c + ((reg, u) in hits), t + 1)
    end
    println(join(["$r $(c)/$(t)" for (r, (c, t)) in sort!(collect(byreg); by=first)], " · "))
    println("registry_coverage: $(length(units)) entries, $(length(unexpected)) unexercised, $(length(stale)) stale")
    return isempty(unexpected) && isempty(stale) ? 0 : 1
end

# merge: the parts' files, each "part i N" then its "unit"/"hit" lines (registry, label)
if _MERGE
    parts = Dict{Int,Tuple{Int,Set{Tuple{Symbol,String}},Set{Tuple{Symbol,String}}}}()
    for f in filter(f -> endswith(f, ".tsv"), readdir(_DIR; join=true))
        local ls = split.(readlines(f), '\t')
        (isempty(ls) || ls[1][1] != "part") && error("registry_coverage merge: $f is no part file")
        local i, n = parse(Int, ls[1][2]), parse(Int, ls[1][3])
        haskey(parts, i) && error("registry_coverage merge: part $i twice")
        parts[i] = (n, Set((Symbol(l[2]), String(l[3])) for l in ls if l[1] == "unit"),
                       Set((Symbol(l[2]), String(l[3])) for l in ls if l[1] == "hit"))
    end
    isempty(parts) && error("registry_coverage merge: no part files in $_DIR")
    n = first(values(parts))[1]
    all(p -> p[1] == n, values(parts)) && sort!(collect(keys(parts))) == collect(0:n-1) ||
        error("registry_coverage merge: parts $(sort!(collect(keys(parts)))) of $(unique(first.(values(parts)))), not 0..N-1 of one N")
    units = first(values(parts))[2]
    all(p -> p[2] == units, values(parts)) || error("registry_coverage merge: the parts disagree on the units")
    println("registry_coverage: the union of $n parts")
    exit(coverage_verdict(units, union((p[3] for p in values(parts))...)))
end

using WasmTarget
const WT = WasmTarget

const HITS = Set{Tuple{Symbol,Any}}()
const UNITS = Dict{Tuple{Symbol,Any},String}()   # unit => display label

_rec(reg, unit, f) = (args...; kw...) -> (push!(HITS, (reg, unit)); f(args...; kw...))

# A callee key is labelled with its owning module: `Core.ifelse` and `Base.ifelse` (likewise
# `sizeof`) are different objects with the same name, and one ALLOWLIST line must name one unit.
_label(k) = (k isa Function || k isa Type) ? string(parentmodule(k), ".", nameof(k)) : string(k)

function _wrap_keyed!(reg::Symbol, d)
    for (k, v) in collect(d)
        UNITS[(reg, k)] = _label(k)
        d[k] = v isa Function ? _rec(reg, k, v) : typeof(v)(_rec(reg, k, v.emit!), v.result)
    end
end

function _wrap_by_fn!(reg::Symbol, d, getfn, rebuild)
    for (k, v) in collect(d)
        fn = getfn(v)
        UNITS[(reg, fn)] = string(nameof(fn))
        d[k] = rebuild(v, _rec(reg, fn, fn))
    end
end

_wrap_keyed!(:FOREIGN_LOWERINGS, WT.FOREIGN_LOWERINGS)
_wrap_keyed!(:BUILTIN_LOWERINGS, WT.BUILTIN_LOWERINGS)
_wrap_keyed!(:CHECKED_OPS, WT.CHECKED_OPS)
_wrap_keyed!(:SHIFT_OPS, WT.SHIFT_OPS)
_wrap_keyed!(:FMA_OPS, WT.FMA_OPS)
_wrap_keyed!(:MISC_OPS, WT.MISC_OPS)
_wrap_keyed!(:INTRINSIC_BINOPS, WT.INTRINSIC_BINOPS)
_wrap_keyed!(:INTRINSIC_UNOPS, WT.INTRINSIC_UNOPS)
_wrap_keyed!(:INTRINSIC_CONVERSIONS, WT.INTRINSIC_CONVERSIONS)
_wrap_by_fn!(:STANDALONE_INTRINSIC_BODIES, WT.STANDALONE_INTRINSIC_BODIES, identity, (_, g) -> g)
let labels = [(reg, l) for ((reg, _), l) in UNITS]
    allunique(labels) || error("registry_coverage: two units share a label — ",
                               unique(filter(x -> count(==(x), labels) > 1, labels)))
end

# ---- the two corpora, compiled exactly as their lanes compile them ----
include(joinpath(@__DIR__, "probe_corpus.jl"))
const _SMOKE = joinpath(@__DIR__, "smoke.jl")
include(_SMOKE)   # defines GROUPS; main() runs only when smoke.jl is the program

failed = String[]
# the cases, probes then smoke, the k-th compiled by part (k-1) % N
const _COV_CASES = Any[]
for (name, (f, argtypes)) in CASES
    push!(_COV_CASES, ("probe $name", () -> WT.compile_multi([(f, argtypes, name)]; validate=false)))
end
for (group, gcases) in GROUPS, case in gcases
    local name, f, args = case[1], case[2], case[3:end]
    push!(_COV_CASES, ("smoke $group/$name", () -> WT.compile(f, Tuple(map(typeof, args)))))
end
for (k, (label, build)) in enumerate(_COV_CASES)
    (k - 1) % _PART[2] == _PART[1] || continue
    try
        build()
    catch e
        push!(failed, "$label: $(first(sprint(showerror, e), 100))")
    end
end
units = Set((reg, l) for ((reg, _), l) in UNITS)
hits = Set((reg, UNITS[(reg, u)]) for (reg, u) in HITS)
for msg in failed; println("  (did not compile) ", msg); end
if _PART[2] > 1
    mkpath(_DIR)
    open(joinpath(_DIR, "part-$(_PART[1])-of-$(_PART[2]).tsv"), "w") do io
        println(io, "part\t", _PART[1], "\t", _PART[2])
        for (reg, l) in sort!(collect(units)); println(io, "unit\t", reg, "\t", l); end
        for (reg, l) in sort!(collect(hits)); println(io, "hit\t", reg, "\t", l); end
    end
    println("registry_coverage: part $(_PART[1])/$(_PART[2]) hit $(length(hits)) of $(length(units)) entries (the verdict is the merge's)")
    exit(0)
end
exit(coverage_verdict(units, hits))
