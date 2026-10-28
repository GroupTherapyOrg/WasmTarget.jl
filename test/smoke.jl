# ============================================================================
# The differential smoke of the rebuild, its acceptance ladder (dev/MARCH.md Phase 1): every case
# of the one corpus, test/smoke_corpus.jl, compiled by WasmTarget, its outcome DERIVED from what
# the compile does, never listed by hand:
#   loud, unported   the compile rejects with Unported or Unquarantined: the path reaches a
#                    definition not yet written (green)
#   loud, outside    Julia's trim verifier rejects the program, OutsideSubset (green)
#   passed           the module is compiled and its answer equals native's (green)
#   wrong / errored  the module answers otherwise, or the compile raises anything else, an
#                    InvalidModule or Internal rejection among them (red)
# A case is loud only through a stub or Julia's own verdict; there is no xfail table for the
# rebuild (the _xf groups are corpus groups like any other). Until the rebuild has its runner (the
# JS/Node host, 1.B and 1.F), a compiled case cannot be judged and is red.
#
# Run:   julia --project=. test/smoke.jl [group ...]   # only matching groups
# Exit:  0 = no case wrong or errored, 1 otherwise.
# Exact:  WT_SMOKE_EXACT=1: exactly the groups (or xfail groups) named, in the order named; a name
#         no group has fails the run
# Part:   WT_SMOKE_PART=i/N: one of N parts (i in 0..N-1), dealt by test/smoke_times.tsv
# Times:  WT_SMOKE_TIMES=1 also prints each group's wall seconds and the package load's
# ============================================================================
const SMOKE_T_START = time()
using WasmTarget

const FILTER = lowercase.(ARGS)
const EXACT = get(ENV, "WT_SMOKE_EXACT", "") == "1"
_want(group) = isempty(FILTER) || (EXACT ? lowercase(group) in FILTER : any(f -> occursin(f, lowercase(group)), FILTER))
# the groups of `list` a run takes: in the file's order, or under WT_SMOKE_EXACT in the order named
_selected(list) = EXACT ? sort(filter(g -> _want(first(g)), list); by = g -> findfirst(==(lowercase(first(g))), FILTER)) :
    filter(g -> _want(first(g)), list)
# WT_SMOKE_PART=i/N (dev/lanes.sh --lane smoke --part i/N, one job of dev/gate.sh's matrix): the
# groups are dealt by their recorded durations (test/smoke_times.tsv, measured on CI's runners per
# Julia version, as runtests.jl deals the suite's phases by test/phase_times.tsv): the longest
# first, each to the part whose load is least so far, then the xfail groups onto the loads the
# groups left. A missing file, a duration that is no number and a group with no recorded
# duration are errors, never a guess (L153 checks the file lists exactly the groups). The dealing
# is a pure function of the file, the lists and N, so the N parts together run every group exactly
# once. Unset: every group.
const SMOKE_PART = let s = get(ENV, "WT_SMOKE_PART", "")
    m = match(r"^([0-9]+)/([1-9][0-9]*)$", s)
    if isempty(s)
        (0, 1)
    elseif m === nothing || parse(Int, m[1]) >= parse(Int, m[2])
        error("WT_SMOKE_PART=$s: expected i/N with 0 <= i < N")
    else
        (parse(Int, m[1]), parse(Int, m[2]))
    end
end
# the recorded durations, "<seconds on 1.12>\t<seconds on 1.13>\t<group>" per group ("xfail <group>"
# for an xfail group), this Julia version's column
const SMOKE_TIMES_TSV = joinpath(@__DIR__, "smoke_times.tsv")
const SMOKE_RECORDED = let d = Dict{String,Float64}(), col = VERSION >= v"1.13-" ? 2 : 1
    isfile(SMOKE_TIMES_TSV) || error("test/smoke_times.tsv is missing: the parts are dealt by its durations")
    for ln in eachline(SMOKE_TIMES_TSV)
        (isempty(ln) || startswith(ln, '#')) && continue
        local f = split(ln, '\t'; limit = 3)
        length(f) == 3 || error("test/smoke_times.tsv: a line is not \"<1.12 s>\\t<1.13 s>\\t<group>\": $ln")
        local t = tryparse(Float64, f[col])
        t === nothing && error("test/smoke_times.tsv: $(repr(f[col])) is no duration: $ln")
        d[String(f[3])] = t
    end
    d
end
# the part (0-based) each group of GROUPS and each of XFAIL is dealt to, for n parts
function _smoke_owners(n::Int)
    local key(prefix, g) = prefix * first(g)
    local load = zeros(n)
    local owners = Dict{String,Int}()
    for (prefix, list) in (("", GROUPS), ("xfail ", XFAIL))
        local dur = [haskey(SMOKE_RECORDED, key(prefix, g)) ? SMOKE_RECORDED[key(prefix, g)] :
                     error("test/smoke_times.tsv records no duration for smoke group $(key(prefix, g))")
                     for g in list]
        for k in sort(collect(eachindex(list)); by = j -> (-dur[j], j))
            local p = argmin(load)
            owners[key(prefix, list[k])] = p - 1
            load[p] += dur[k]
        end
    end
    return owners
end
# the entries of `list` (GROUPS or XFAIL) part i of n runs
function _smoke_part(list, i = SMOKE_PART[1], n = SMOKE_PART[2])
    n == 1 && return list
    local owners = _smoke_owners(n)
    local prefix = list === XFAIL ? "xfail " : ""
    return [g for g in list if owners[prefix * first(g)] == i]
end

# Each case: (name, f, args...).
const GROUPS = Vector{Pair{String,Vector{Any}}}()
_g(name, cases) = push!(GROUPS, name => cases)
const XFAIL = Vector{Pair{String,Vector{Any}}}()
_xf(name, cases) = push!(XFAIL, name => cases)

# the cases, one corpus for every compiler the smoke runs (dev/MARCH.md 1.A1)
include(joinpath(@__DIR__, "smoke_corpus.jl"))

# ============================================================================

# an error's located lines, so a failing case names where to look without rerunning it
function _smoke_error_text(e)::String
    local lines = split(sprint(showerror, e), '\n')
    local keep = [strip(l) for l in lines if !isempty(strip(l))]
    local text = join(first(keep, 4), " | ")
    return length(text) > 600 ? first(text, 600) * "…" : text
end

# A case's outcome, derived from its compile (the ladder above): :unported, :outside or :errored,
# with the text that says why
function _ladder(f, args)::Tuple{Symbol,String}
    try
        WasmTarget.compile(f, Tuple(map(typeof, args)))
    catch e
        e isa WasmTarget.RejectionError || return (:errored, _smoke_error_text(e))
        local r = e.rejection
        (r isa WasmTarget.Unported || r isa WasmTarget.Unquarantined) && return (:unported, sprint(showerror, e))
        r isa WasmTarget.OutsideSubset && return (:outside, sprint(showerror, e))
        return (:errored, sprint(showerror, e))
    end
    return (:errored, "the module compiled, and the rebuild has no runner to judge it against native yet (dev/MARCH.md 1.B)")
end

const SMOKE_TIMES = get(ENV, "WT_SMOKE_TIMES", "") == "1"
_smoke_time(what, t) = SMOKE_TIMES && println("smoke time: ", what, " ", round(time() - t; digits = 1), " s")

function main()
    t0 = time()
    _smoke_time("load", SMOKE_T_START)
    # under WT_SMOKE_EXACT a name that names no group or xfail group selects nothing: refused,
    # never a green run of 0 cases
    local unknown = EXACT ? [f for f in FILTER if !any(g -> lowercase(first(g)) == f, vcat(GROUPS, XFAIL))] : String[]
    if !isempty(unknown)
        println("smoke: no group named ", join(unknown, ", "))
        exit(1)
    end
    local case_secs = Float64[]
    local count = Dict(:passed => 0, :unported => 0, :outside => 0, :wrong => 0, :errored => 0)
    local failures = String[]
    local ngroups = 0
    for (group, cases) in vcat(_selected(_smoke_part(GROUPS)), _selected(_smoke_part(XFAIL)))
        ngroups += 1
        local tg = time()
        for case in cases
            local name, f, args = case[1], case[2], case[3:end]
            local tc = time()
            local outcome, why = _ladder(f, args)
            count[outcome] += 1
            outcome === :errored && push!(failures, "ERROR $group/$name  $why")
            push!(case_secs, time() - tc)
        end
        _smoke_time("group $group", tg)
    end
    # the median case's wall
    SMOKE_TIMES && !isempty(case_secs) &&
        println("smoke time: case median ", round(sort(case_secs)[(length(case_secs) + 1) ÷ 2]; digits = 3), " s")
    local dt = round(time() - t0; digits = 1)
    println("\n" * "="^60)
    for fl in failures; println("  ", fl); end
    println("="^60)
    SMOKE_PART[2] > 1 && println("smoke part $(SMOKE_PART[1])/$(SMOKE_PART[2]): $ngroups of $(length(GROUPS) + length(XFAIL)) groups")
    println("smoke: $(count[:passed]) passed, $(count[:wrong]) wrong, $(count[:errored]) errored, " *
            "$(count[:unported] + count[:outside]) loud ($(count[:unported]) unported, $(count[:outside]) outside the subset)  ($(dt)s)")
    exit(count[:wrong] + count[:errored] == 0 ? 0 : 1)
end
abspath(PROGRAM_FILE) == (@__FILE__) && main()
