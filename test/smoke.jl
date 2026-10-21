# ============================================================================
# FAST differential smoke — the INNER-LOOP gate for the dart2wasm-parity march.
#
# Why: the full `Pkg.test()` is 18-30 min and gets OOM-killed (jetsam) under
# memory pressure. This runs a curated breadth of native-vs-wasm differential
# cases in ONE low-memory Julia session (~2-3 min after precompile), covering
# every dimension a codegen change is likely to touch. GREEN here = safe to run
# the full commit-gate; it is NOT a substitute for it (rule #0 still stands).
#
# Run:   julia --project=. test/smoke.jl
# Exit:  0 = all pass, 1 = any fail/error (so it is gate-able + CI-able).
# Filter: julia --project=. test/smoke.jl boxing phi   # only matching groups
# Exact:  WT_SMOKE_EXACT=1 julia --project=. test/smoke.jl memory phi_union   # exactly the groups (or
#         xfail groups) named, in the order named; a name no group has fails the run (dev/block.jl
#         selects its groups this way)
# Part:   WT_SMOKE_PART=i/N julia --project=. test/smoke.jl  # one of N parts (i in 0..N-1)
# Times:  WT_SMOKE_TIMES=1 also prints each group's wall seconds and the package load's, the
#         numbers dev/gate.sh --fast's part counts are sized from (.github/workflows/gate-fast.yml)
# ============================================================================
const SMOKE_T_START = time()
using WasmTarget
include(joinpath(@__DIR__, "utils.jl"))
include(joinpath(@__DIR__, "trace_localize.jl"))   # a WRONG answer's first divergent statement
include(joinpath(@__DIR__, "emission_fingerprint.jl"))   # the emission-diff check's head side

const FILTER = lowercase.(ARGS)
const EXACT = get(ENV, "WT_SMOKE_EXACT", "") == "1"
# WT_SMOKE_CASES="<group>/<case> ...": a selected group one of them names runs those cases alone (the
# blocking gate's cases for a changed lowering-table entry, dev/block.jl); a name no case has is refused
const ONLY_CASES = Set{String}(split(get(ENV, "WT_SMOKE_CASES", "")))
_only(group, name) = !any(c -> startswith(c, group * "/"), ONLY_CASES) || "$group/$name" in ONLY_CASES
_want(group) = isempty(FILTER) || (EXACT ? lowercase(group) in FILTER : any(f -> occursin(f, lowercase(group)), FILTER))
# the groups of `list` a run takes: in the file's order, or under WT_SMOKE_EXACT in the order named
# (dev/block.jl names its fixed core first, so the core's times do not depend on what follows it)
_selected(list) = EXACT ? sort(filter(g -> _want(first(g)), list); by = g -> findfirst(==(lowercase(first(g))), FILTER)) :
    filter(g -> _want(first(g)), list)
# WT_SMOKE_PART=i/N (dev/lanes.sh --lane smoke --part i/N, one job of dev/gate.sh's matrix): the
# groups are dealt by their recorded durations (test/smoke_times.tsv, measured on CI's runners per
# Julia version, as runtests.jl deals the suite's phases by test/phase_times.tsv): the longest
# first, each to the part whose load is least so far, then the xfail groups onto the loads the
# groups left. A missing file, a duration that is no number and a group with no recorded
# duration are errors, never a guess (L163 checks the file lists exactly the groups). The dealing
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

# Each case: (name, f, args...). Compared native-vs-wasm via compare_julia_wasm.
const GROUPS = Vector{Pair{String,Vector{Any}}}()
_g(name, cases) = push!(GROUPS, name => cases)
# A generated case's inputs, by "group/case": it runs over each (compare_julia_wasm_inputs)
const CASE_INPUTS = Dict{String,Vector{Tuple}}()
# A lazy group (test/registry_cases.jl's: cases generated from the lowering tables) is declared by
# name, its entry in GROUPS or XFAIL empty, and built when a run selects it: _build! includes the
# file that builds it (once) and fills the entry from the file's builder (LAZY_BUILDERS[file], a
# Dict of every group it builds). An unselected lazy group costs no include and no compile. A
# reader of every case (registry coverage, the emission base, block_impact) builds them all first.
const LAZY_FILE = Dict{String,String}()       # a lazy group => the file in test/ that builds it
const LAZY_BUILDERS = Dict{String,Function}()  # a file => its builder, set by the file
const LAZY_BUILT = Set{String}()
_lazy_g(name, file) = (LAZY_FILE[name] = file; _g(name, Any[]))
_lazy_xf(name, file) = (LAZY_FILE[name] = file; _xf(name, Any[]))
function _build!(names)
    for n in names
        (haskey(LAZY_FILE, n) && !(n in LAZY_BUILT)) || continue
        local file = LAZY_FILE[n]
        haskey(LAZY_BUILDERS, file) || Base.include(@__MODULE__, joinpath(@__DIR__, file))
        local built = Base.invokelatest(LAZY_BUILDERS[file])
        local k = findfirst(p -> first(p) == n, GROUPS)
        append!(last(k === nothing ? XFAIL[findfirst(p -> first(p) == n, XFAIL)] : GROUPS[k]), built[n])
        push!(LAZY_BUILT, n)
    end
    return nothing
end
# the lazy groups a run selects (its part and its filter), built before main runs
_selected_lazy() = [first(g) for g in vcat(_selected(_smoke_part(GROUPS)), _selected(_smoke_part(XFAIL)))
                    if haskey(LAZY_FILE, first(g))]

# ---- KNOWN-PENDING (xfail) — gaps with an open loop; reported, do NOT fail the gate.
# When one flips to passing, the smoke says so loudly (the loop that closes it is done).
const XFAIL = Vector{Pair{String,Vector{Any}}}()
_xf(name, cases) = push!(XFAIL, name => cases)
# The xfails that compile and then fail when they run, each with what it does: `:wrong`
# returns a value native does not (a module that runs and answers wrong, the worst outcome),
# `:trap` traps where native returns, and `:unreadable` returns a GC reference for an
# abstract return type that the harness cannot read back, so its value is unverified. Every
# other xfail rejects at compile time. The xfail lane measures each case against this table
# exactly, so a loud reject cannot turn into a wrong answer unseen; R39 counts the table
# (dev/CHARTER.md C6), terminal state 0.
const XFAIL_RUNTIME = Dict{String,Symbol}(
)
# What an xfail case does now: :pass, one of XFAIL_RUNTIME's outcomes, :loud (the compile
# rejects it at a statement it names, dev/CHARTER.md C6), or :crash (the compile raises
# anything else: a codegen bug, a rejection that names no statement), which no xfail may do.
function xfail_outcome(f, args)::Symbol
    expected = f(args...)
    bytes = try
        WasmTarget.compile(f, Tuple(map(typeof, args)); optimize=false)
    catch err
        return err isa WasmTarget.WasmCompileError && err.diag.stmt_idx > 0 ? :loud : :crash
    end
    status, val = WasmRunner.run_wasm_single(bytes, string(nameof(f)),
                                             join(map(format_js_arg, args), ", "))
    status === :ok && return unmarshal_result(val) == expected ? :pass : :wrong
    if status === :trap && startswith(val, "unserializable result")
        # read inside the module, through a typeassert to the native result's type
        w = typed_result_wrapper(f, typeof(expected))
        w === nothing && return :unreadable
        wb = try WasmTarget.compile(w, Tuple(map(typeof, args)); optimize=false) catch; return :unreadable end
        status, val = WasmRunner.run_wasm_single(wb, string(nameof(w)), join(map(format_js_arg, args), ", "))
        status === :ok && return unmarshal_result(val) == expected ? :pass : :wrong
    end
    status === :trap && return startswith(val, "unserializable result") ? :unreadable : :trap
    error("xfail lane: the runner answered $status: $val")
end

# the cases, one corpus for every compiler the smoke runs (dev/MARCH.md 1.A1)
include(joinpath(@__DIR__, "smoke_corpus.jl"))

# ============================================================================

# A WRONG answer located at its first divergent statement (TraceLocalize.first_divergence);
# the locator's own failure is reported in its place, never hidden.
function _smoke_locate(f, args)::String
    try
        return TraceLocalize.first_divergence(f, args...; js_args=join(map(format_js_arg, args), ", ")).summary
    catch e
        return "(the wrong value could not be located: $(first(sprint(showerror, e), 200)))"
    end
end

# An error's located lines — the headline (for a codegen bug, the compiler source line it was
# raised at), the statement, its innermost inline frame, and the cause — so a failing case
# names where to look without rerunning it; the full trace prints when the case runs alone.
function _smoke_error_text(e)::String
    local lines = split(sprint(showerror, e), '\n')
    local keep = [strip(l) for l in lines if !isempty(strip(l)) &&
                  !startswith(strip(l), "←") && !startswith(strip(l), "raised through")]
    local text = join(first(keep, 4), " | ")
    return length(text) > 600 ? first(text, 600) * "…" : text
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
    local nocase = [c for c in ONLY_CASES if !any(g -> any(k -> "$(first(g))/$(k[1])" == c, last(g)), _selected(_smoke_part(GROUPS)))]
    if !isempty(nocase)
        println("smoke: no selected case named ", join(sort(nocase), ", "))
        exit(1)
    end
    local case_secs = Float64[]
    npass = 0; nfail = 0; nerr = 0
    failures = String[]
    ngroups = 0
    # the emission-diff check's head side: each case's bodies, and which a passing run entered
    local edir = get(ENV, "WT_EMISSION_DIR", "")
    local rec = isempty(edir) ? nothing :
        EmissionFingerprint.recorder(edir, SMOKE_PART[1], SMOKE_PART[2];
                                     run_driver=WasmRunner.run_driver_batch, merge_js=WasmRunner.host_runtime_merge_js)
    for (group, cases) in _selected(_smoke_part(GROUPS))
        ngroups += 1
        local tg = time()
        for case in cases
            name = case[1]; f = case[2]; args = case[3:end]
            _only(group, name) || continue
            tag = "$group/$name"
            local tc = time()
            rec === nothing || (EMITTED_MODULES[] = Any[])
            local passed = false
            try
                r = haskey(CASE_INPUTS, tag) ? compare_julia_wasm_inputs(f, CASE_INPUTS[tag]; admit=_rc_admit) :
                    isempty(args) ? compare_julia_wasm(f) : compare_julia_wasm(f, args...)
                if r.pass
                    npass += 1; passed = true
                else
                    nfail += 1
                    haskey(CASE_INPUTS, tag) && (args = r.input)   # a generated case: its first wrong input
                    push!(failures, "WRONG $tag  exp=$(r.expected) act=$(r.actual)" *
                                    (haskey(CASE_INPUTS, tag) ? "  input=$(r.input)" : "") * "\n    " *
                                    replace(_smoke_locate(f, args), "\n" => "\n    "))
                end
            catch e
                nerr += 1; push!(failures, "ERROR $tag  $(_smoke_error_text(e))")
            end
            push!(case_secs, time() - tc)
            if rec !== nothing
                try
                    EmissionFingerprint.record!(rec, tag, passed, EmissionFingerprint.case_hash(f, Tuple(map(typeof, case[3:end]))),
                                                EMITTED_MODULES[])
                catch e
                    nerr += 1; push!(failures, "ERROR $tag  (its emission fingerprint) $(_smoke_error_text(e))")
                end
                EMITTED_MODULES[] = nothing
            end
        end
        _smoke_time("group $group", tg)
    end
    # xfail lane: known-pending gaps. A NEWLY-PASSING one is great news (its loop landed) and
    # never fails the gate; a still-failing one must fail the way XFAIL_RUNTIME says it does.
    xf_now_pass = String[]; xf_still = 0; xf_mismatch = String[]; xf_seen = Set{String}()
    xf_part = _smoke_part(XFAIL)
    for (group, cases) in _selected(xf_part)
        local tg = time()
        for case in cases
            name = case[1]; f = case[2]; args = case[3:end]
            tag = "$group/$name"; push!(xf_seen, tag)
            got = xfail_outcome(f, args)
            if got === :pass
                push!(xf_now_pass, tag)
            else
                xf_still += 1
                want = get(XFAIL_RUNTIME, tag, :loud)
                got === want || push!(xf_mismatch, "$tag: XFAIL_RUNTIME says $want, measured $got")
            end
        end
        _smoke_time("xfail group $group", tg)
    end
    for tag in keys(XFAIL_RUNTIME)
        # checked by the part its group is dealt to; a tag naming no xfail group, by part 0
        local g = String(first(split(tag, '/')))
        local k = findfirst(p -> first(p) == g, XFAIL)
        local owner = (k === nothing || SMOKE_PART[2] == 1) ? 0 : _smoke_owners(SMOKE_PART[2])["xfail " * g]
        _want(g) && owner == SMOKE_PART[1] && !(tag in xf_seen) &&
            push!(xf_mismatch, "$tag: listed in XFAIL_RUNTIME, but no xfail case has that name")
    end
    # the median case's wall (compile, both runs, the comparison): dev/block.jl's per-case budget
    SMOKE_TIMES && !isempty(case_secs) &&
        println("smoke time: case median ", round(sort(case_secs)[(length(case_secs) + 1) ÷ 2]; digits = 3), " s")
    dt = round(time() - t0; digits = 1)
    println("\n" * "="^60)
    for fl in failures; println("  ", fl); end
    println("="^60)
    if !isempty(xf_now_pass)
        println("xfail NOW PASSING (a gap closed — promote it out of XFAIL): ", join(xf_now_pass, ", "))
    end
    for m in xf_mismatch; println("  XFAIL OUTCOME ", m); end
    println("xfail: $(length(xf_now_pass)) now-passing, $xf_still still-pending (expected), " *
            "$(length(xf_mismatch)) outcome mismatch(es)")
    SMOKE_PART[2] > 1 && println("smoke part $(SMOKE_PART[1])/$(SMOKE_PART[2]): $ngroups of $(length(GROUPS)) groups, " *
                           "$(length(xf_part)) of $(length(XFAIL)) xfail groups")
    println("smoke: $npass passed, $nfail wrong, $nerr errored  ($(dt)s)")
    exit((nfail + nerr + length(xf_mismatch)) == 0 ? 0 : 1)
end
# main() runs when smoke.jl is the program, the lazy groups it selects built first (a statement of
# their own: main runs in the world their cases are defined in); test/registry_coverage.jl includes
# it for GROUPS only
abspath(PROGRAM_FILE) == (@__FILE__) && _build!(_selected_lazy())
abspath(PROGRAM_FILE) == (@__FILE__) && main()
