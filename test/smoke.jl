# ============================================================================
# The differential smoke of the rebuild, its acceptance ladder (dev/MARCH.md Phase 1): every case
# of the one corpus, test/smoke_corpus.jl, compiled by WasmTarget, its outcome DERIVED from what
# the compile does, never listed by hand:
#   loud, unported   the compile rejects with Unported or Unquarantined: the path reaches a
#                    definition not yet written (green)
#   loud, outside    Julia's trim verifier rejects the program, OutsideSubset (green)
#   passed           the module is compiled and its answer in node equals native's, in both
#                    modules, codegen's and wasm-opt's (green)
#   wrong / errored  the module answers otherwise, or the compile raises anything else, an
#                    InvalidModule or Internal rejection among them (red)
# A case is loud only through a stub or Julia's own verdict; there is no xfail table for the
# rebuild (the _xf groups are corpus groups like any other). A compiled case's modules run in node
# (test/runner.jl, the keeper's, in a process of its own) and each fact of its answer is judged by
# test/verdict.jl (the judge's): a type the judge has no leaf kind for, a trap or a missing entry is
# wrong, never a pass.
#
# Run:   julia --project=. test/smoke.jl [group ...]   # only matching groups
# Exit:  0 = no case wrong or errored, 1 otherwise.
# Exact:  WT_SMOKE_EXACT=1: exactly the groups (or xfail groups) named, in the order named; a name
#         no group has fails the run
# Part:   WT_SMOKE_PART=i/N: one of N parts (i in 0..N-1), dealt by test/smoke_times.tsv
# Times:  WT_SMOKE_TIMES=1 also prints each group's wall seconds and the package load's
# Cases:  WT_SMOKE_CASES=<file> also writes each case's outcome, one line per case,
#         `<group/case>\t<outcome>\t<seconds>\t<why>` (outcome one of the ladder's: passed, wrong,
#         errored, unported, outside), the input of the climb's score (dev/climb/climb.py)
# Only:   WT_SMOKE_ONLY=<file> runs, of the groups taken, only the cases the file lists (`<group/case>` a line), sorted:
#         the climb's measurement names each process's labels exactly (dev/climb/measure.py smoke)
# Split:  the climb measures a candidate in four processes (test/verdict.jl's header: answer, compile, run, verdict), so
#         no file a move may edit is loaded where a verdict is written and no process that runs the measured src is
#         handed an answer (spec v16 X1): WT_SMOKE_COMPILED=<file> with WT_SMOKE_SHAPES=<shapes> is the compiling
#         process: handed each stored answer's shape alone (test/oracle_read.jl's Shape), it compiles each case and
#         writes there a case that did not compile (unported, outside or errored, nothing else) or its modules, its
#         readers shaped by the shape and the calls that read them (test/verdict.jl's bind and plan), and runs no node
#         and no case's function (R2); this file never loads test/runner.jl, and the verdict is test/verdict.jl's
# Corpus: test/smoke_judge.jl's, included last (the snapshot and the units, each label at its own world); a unit label is
#         compiled only when the program its load made is the one answered (its stored digest, compared in _ladder)
# ============================================================================
const SMOKE_T_START = time()
const SMOKE_COMPILED = get(ENV, "WT_SMOKE_COMPILED", "")
const SMOKE_SHAPES = get(ENV, "WT_SMOKE_SHAPES", "")
isempty(SMOKE_COMPILED) || !isempty(SMOKE_SHAPES) ||
    error("WT_SMOKE_COMPILED compiles each case against its stored answer's shape: WT_SMOKE_SHAPES names none (dev/climb/measure.py smoke)")
isempty(get(ENV, "WT_SMOKE_JUDGE", "")) && get(ENV, "WT_SMOKE_KEY", "") != "1" ||
    error("the judging process and the key's are test/smoke_judge.jl's, never test/smoke.jl's (spec v14 V2)")
using WasmTarget
import Base64
# the judge's files, each a module of its own: the capture (test/oracle.jl), the store's decoder (test/oracle_read.jl),
# the verdict (test/verdict.jl: the binding, the plan, the leaf kinds), the corpus loader (test/corpus_loader.jl);
# test/runner.jl, the keeper's, is never loaded here: its node runs in a process of its own (_run)
isdefined(Main, :WTOracle) || include(joinpath(@__DIR__, "oracle.jl"))
isdefined(Main, :WTOracleRead) || include(joinpath(@__DIR__, "oracle_read.jl"))
isdefined(Main, :WTVerdict) || include(joinpath(@__DIR__, "verdict.jl"))
isdefined(Main, :CorpusLoader) || include(joinpath(@__DIR__, "corpus_loader.jl"))

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

# ============================================================================

# ============================================================================

# A case's outcome, derived from its compile (the ladder above): :unported, :outside or :errored,
# with the text that says why, or :compiled with the cases that read its answer in node (a reader
# that does not compile is :errored: the case compiled, and its answer goes unjudged); in the climb's compiling
# process the answer's shape is the stored one's (WT_SMOKE_SHAPES), a case with none errored, located, and a case is
# compiled only when the program its load made is the one answered: the one compare (test/corpus_loader.jl's
# digest_mismatch) of the stored digest with this process's load, here, in the one compile path, so no caller can skip it
# (spec v14 V3)
function _ladder(label, f, args, world::UInt)::Tuple{Symbol,Union{String,Vector{WTVerdict.RunCase}}}
    if !isempty(SMOKE_COMPILED)
        local s = get(_SHAPES, label, nothing)
        # a stored noanswer is the label's own reason, never a digest's (its why is the driver's to book)
        s isa WTOracleRead.Shape || return (:errored, s === nothing ? "the driver's shapes (WT_SMOKE_SHAPES) hold none for it" : s)
        local dwhy = CorpusLoader.digest_mismatch(get(_STORED_DIGESTS, label, nothing), get(_UNIT_OF, label, nothing))
        dwhy === nothing || return (:errored, dwhy)
    end
    try
        WasmTarget.compile(f, Tuple(map(typeof, args)); world)
    catch e
        e isa WasmTarget.RejectionError || return (:errored, _smoke_error_text(e))
        local r = e.rejection
        (r isa WasmTarget.Unported || r isa WasmTarget.Unquarantined) && return (:unported, sprint(showerror, e))
        r isa WasmTarget.OutsideSubset && return (:outside, sprint(showerror, e))
        return (:errored, sprint(showerror, e))
    end
    return try
        if isempty(SMOKE_COMPILED)   # the standalone suite: its own modules, then its native answer, then its readers,
            # each compile recorded as the climb's compiling process records it, and its answer's records kept, so the
            # one judge (test/verdict.jl's judge) decides both (spec v17 Y2, red S8)
            local _, f′, args′ = WTOracle._bound("", f, Tuple(args))
            local own = WTVerdict._modules(_recording_compile, f′, args′)
            local a = WTOracle.answer_of("", f, Tuple(args); world)
            append!(_ANSWERS, WTOracle.answer_lines(label, a))
            (:compiled, WTVerdict.bind(WTOracleRead.Shape(a), Tuple(args), _recording_compile; a, f, own, world))
        else   # the climb's compiling process: the case's stored shape shapes its readers; no case's function runs (R2)
            (:compiled, WTVerdict.bind(_SHAPES[label]::WTOracleRead.Shape, Tuple(args), _recording_compile; f, world))
        end
    catch e
        (:errored, "the module compiled, and the reader of its answer does not: " * _smoke_error_text(e))
    end
end

# ---- the split measurement (WT_SMOKE_COMPILED): one line a record, tab-separated, texts in base64:
# `row <label> <outcome> <secs> <why>` a case that did not compile; `compiled <label> <secs>` one that did, preceded
# by each compile the binding asked for it, in order, `module <label> <key> <bytes>` or `rejected <label> <key> <text>`
# (a reader WasmTarget rejects as Unported or Unquarantined), the key its argument types' paths (test/oracle.jl's
# type_path, read by field access, never by show), then each call that reads it, `call <label> <j> <entry> <args...>`
# (its j-th module, from 0; its wire arguments: test/verdict.jl's plan, which the verdict checks against the answer's);
# before each case `started <label>`, flushed, which no reader takes as an outcome
const _REC = Ref{Union{Nothing,IO}}(nothing)
const _COMPILE_WORLD = Ref{UInt}(0)   # the compiling process's case in flight (it runs no case's body: R2)
const _LABEL = Ref("")
const _MODULE_AT = IdDict{Any,Int}()  # the case in flight's modules, each its index among its `module` records
_rec(fields...) = println(_REC[], join(fields, '\t'))
_compile_key(argtypes, kw) = string(WTOracle._key(argtypes), get(kw, :optimize, true) ? "" : " unoptimized")
# the compile the binding calls in the compiling process: WasmTarget's, each module or reader rejection recorded
function _recording_compile(f, argtypes; kw...)
    local key = _compile_key(argtypes, kw)
    try
        local bytes = WasmTarget.compile(f, argtypes; world = _COMPILE_WORLD[], kw...)
        _rec("module", _LABEL[], key, Base64.base64encode(bytes))
        _MODULE_AT[bytes] = length(_MODULE_AT)
        return bytes
    catch e
        e isa WasmTarget.RejectionError && (e.rejection isa WasmTarget.Unported || e.rejection isa WasmTarget.Unquarantined) &&
            _rec("rejected", _LABEL[], key, Base64.base64encode(sprint(showerror, e)))
        rethrow()
    end
end
# each call of a case's cases (test/verdict.jl's plan: no native value in it), as `call` records
function _rec_calls(label::String, cases::Vector{WTVerdict.RunCase})
    local calls, _ = WTVerdict.plan(cases)
    for c in calls
        _rec("call", label, get(_MODULE_AT, c.bytes, -1), isempty(c.entry) ? "-" : c.entry, c.args...)
    end
end
# the stored shapes the compiling process binds (the driver's, dev/climb/measure.py smoke): {label => Shape or why},
# and each unit label's stored digest of its unit's load ({label => its fields})
const _STORED_DIGESTS = Dict{String,Vector{String}}()
const _SHAPES = isempty(SMOKE_SHAPES) ? Dict{String,Union{WTOracleRead.Shape,String}}() :
    WTOracleRead.read_shapes(eachline(SMOKE_SHAPES); digests = _STORED_DIGESTS)

# the standalone suite's answers, as test/smoke_judge.jl writes them (test/oracle.jl's answer_lines), for the one judge
const _ANSWERS = String[]

const SMOKE_TIMES = get(ENV, "WT_SMOKE_TIMES", "") == "1"
const SMOKE_CASES = get(ENV, "WT_SMOKE_CASES", "")
_runs(label) = SMOKE_ONLY === nothing || label in SMOKE_ONLY
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
    local runs = Tuple{String,Vector{WTVerdict.RunCase}}[]
    # each case's (label, outcome, seconds, why), written to WT_SMOKE_CASES when it is set
    local records = Tuple{String,Symbol,Float64,String}[]
    local case_sec = Dict{String,Float64}()
    local ngroups = 0
    # the compile's records: the climb's compiling process's file, or the standalone suite's own, which its verdict reads
    local recfile = isempty(SMOKE_COMPILED) ? joinpath(mktempdir(), "compiled.tsv") : SMOKE_COMPILED
    _REC[] = open(recfile, "w")
    local selected = vcat(_selected(_smoke_part(GROUPS)), _selected(_smoke_part(XFAIL)))
    ngroups = length(selected)
    # every case's facts (its group, its registration tuple, its world) taken before any case's body runs, into a list
    # no body can reach (a local), so a body that rewrites GROUPS or _WORLD changes no other case's facts
    # a loop, no closure, and the case's name read by the getfield builtin: a comprehension's closure called with each
    # case compiled once per case, each case's tuple type its own (its lambda's)
    local todo = Tuple{String,Any,UInt}[]
    for (group, cases) in selected, case in cases
        local label = string(group, "/", Core.getfield(case, 1)::String)
        _runs(label) && push!(todo, (group, case, _WORLD[label]))
    end
    # the climb's driver names the labels (WT_SMOKE_ONLY) and reads each `started` line against them in sorted order,
    # so the label whose budget a case gets is the one it expects next (dev/climb/measure.py watched)
    SMOKE_ONLY === nothing || sort!(todo; by = t -> string(t[1], "/", t[2][1]))
    local tg, gnow = time(), nothing
    for (group, case, world) in todo
        if group != gnow
            gnow === nothing || _smoke_time("group $gnow", tg)
            gnow, tg = group, time()
        end
        begin
            local name, f, args = case[1], case[2], case[3:end]
            local tc = time()
            _LABEL[] = "$group/$name"
            _COMPILE_WORLD[] = world
            empty!(_MODULE_AT)
            # the compiling process says which case it starts, flushed, so the driver can stop one past its budget
            # and name it (dev/climb/measure.py compile_watched; the rule that no hang is allowed)
            _REC[] === nothing || (_rec("started", "$group/$name"); flush(_REC[]))
            local outcome, why = _ladder("$group/$name", f, args, world)
            local secs = time() - tc
            outcome === :compiled ? (_rec_calls("$group/$name", why); _rec("compiled", "$group/$name", round(secs; digits = 2))) :
                _rec("row", "$group/$name", outcome, round(secs; digits = 2), Base64.base64encode(why))
            if outcome === :compiled
                push!(runs, ("$group/$name", why))
                case_sec["$group/$name"] = secs
            else
                count[outcome] += 1
                outcome === :errored && push!(failures, "ERROR $group/$name  $why")
                push!(records, ("$group/$name", outcome, secs, why))
            end
            push!(case_secs, secs)
        end
    end
    gnow === nothing || _smoke_time("group $gnow", tg)
    close(_REC[])
    if !isempty(SMOKE_COMPILED)   # the compiling process: its records are its whole answer; the run and the verdict follow it
        println("smoke: compiled $(length(runs)) case(s); $(sum(values(count))) did not compile; no verdict (WT_SMOKE_COMPILED)")
        exit(0)
    end
    _verdict(t0, recfile, case_secs, ngroups)
end

# the standalone verdict: the compile's records (every compiled case's modules and calls, every other case's row) run by
# test/runner.jl in a process of its own, after the judge's fixtures, and judged by the one judge, test/verdict.jl's
# judge, against this process's own answers (spec v17 Y2, red S8: the driver's verdict process decides the same way);
# the cases written, the summary printed
function _verdict(t0, recfile, case_secs, ngroups)
    local raw = _run(recfile)
    local records, failures, count = try
        WTVerdict.judge(eachline(recfile), _ANSWERS, raw)
    catch e
        e isa WTVerdict.FixtureFailure || rethrow()
        error("test/runner.jl fails the judge's fixtures (test/fixtures): " * e.text)
    end
    if !isempty(SMOKE_CASES)
        open(SMOKE_CASES, "w") do io
            foreach(r -> println(io, WTVerdict._case_line(r...)), records)
        end
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
            "$(count[:unported] + count[:outside]) loud ($(count[:unported]) unported, $(count[:outside]) outside the subset), " *
            "$(count[WTVerdict.JUDGE_GAP]) judge-gap, $(count[WTVerdict.RUNNER_GAP]) runner-gap  ($(dt)s)")
    exit(count[:wrong] + count[:errored] == 0 ? 0 : 1)
end
# the run, a process of its own (test/runner.jl, the keeper's, never loaded here): the judge's fixtures first, then the
# compile's records (the runner reads their `module` and `call` records alone); one raw line a call, in order
function _run(recfile)::Vector{String}
    local dir = mktempdir()
    local out = joinpath(dir, "raw.tsv")
    run(`$(Base.julia_cmd()) --startup-file=no $(joinpath(@__DIR__, "runner.jl")) $out $(joinpath(WTVerdict.FIXTURES, "runner_calls.tsv")) $recfile`)
    local raw = readlines(out)
    rm(dir; recursive = true, force = true)
    return raw
end

# the corpus: test/smoke_judge.jl's registry and load, after every definition of this file's, so the judge's world
# (W_JUDGE, taken there) holds none of the corpus
include(joinpath(@__DIR__, "smoke_judge.jl"))

abspath(PROGRAM_FILE) == (@__FILE__) && Base.invoke_in_world(W_JUDGE, main)
