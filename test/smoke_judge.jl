# ============================================================================
# The judging entry and the corpus's program (spec v14 V2). The native answer of a case is computed by a process that
# runs this file and loads exactly the answering program: this file, test/oracle.jl (WTOracle, the capture's write
# half) and test/corpus_loader.jl (CorpusLoader), then the snapshot (test/smoke_corpus.jl) and the label's own unit,
# each read by ONE function, _judge_read, which records the file's path and git blob; the list is printed in the
# label's block (`loads <label> <path>=<blob>;...`) before its case runs, and the driver refuses an answer whose list
# is not exactly the store key's files (dev/climb/core.py JUDGE_WRITE, their blobs at origin the key's `judge` field)
# plus the snapshot and the label's unit (dev/climb/measure.py answer_labels). test/runner.jl, the keeper's, is never
# loaded here; nor is test/smoke.jl, the compiling and comparing side, so an edit of either replays nothing.
#
# Run:   WT_SMOKE_JUDGE=1 WT_SMOKE_ONLY=<file naming one label> WT_SMOKE_UNITS=<units log> julia test/smoke_judge.jl
#        the judging process: no WasmTarget, JULIA_LOAD_PATH=@stdlib; it writes its records to its stdout alone (a pipe
#        the driver drains as it is written; everything else it prints goes to stderr): `started <label>`, `loads
#        <label> <files> <process>` (<process>: what it ran with, _process_record), then that case's `answer`, `group`
#        and `leaf` records (or `noanswer <label> <why>`) and, for
#        a unit's label, `digest <label> <fields>` (its unit's load: test/corpus_loader.jl's digest_fields), and
#        `ended` after the last; it runs no node and reads no module. The driver keeps a block only between its label's
#        `started` and the next record and reads nothing after `ended`, so no code that runs at load or at exit writes
#        a case's answer (R8-1)
#        WT_SMOKE_KEY=1 julia test/smoke_judge.jl
#        Julia's and the host's half of the store's key (test/oracle.jl's oracle_key) and what it ran with
#        (_process_record), loading no corpus
# Included by test/smoke.jl (its compiling, comparing and standalone processes) last, for the corpus's registry and
# its load, after every judge definition of its own: the code that loads the corpus is one, here.
# Corpus: the snapshot (included into Main) and the units after it (test/corpus/<slug>.jl, one a landing, each loaded
# by test/corpus_loader.jl into a module of its own, in landing order: WT_SMOKE_UNITS names the file holding git's log
# the driver ran, else this checkout's own git is read). Worlds: the judge's code runs at W_JUDGE, the world before the
# snapshot; each label is compiled, and its native answer computed, at its own world (_WORLD), the snapshot's for a
# snapshot label and the world just after its unit loaded for a unit's, so no unit reaches the judge or an earlier label.
# ============================================================================
import SHA, Base64

const _JUDGE_ROOT = dirname(@__DIR__)
# every file the answering program loads, in order: (its path under the checkout, its git blob)
const _JUDGE_LOADS = Tuple{String,String}[]
_judge_blob(bytes::Vector{UInt8}) = bytes2hex(SHA.sha1(vcat(Vector{UInt8}("blob $(length(bytes))\0"), bytes)))
"""    _judge_read(path) -> String

THE reader of a file the answering program loads (this entry, test/oracle.jl, test/corpus_loader.jl, the snapshot, a
unit): its bytes, read once, recorded by path and git blob (_JUDGE_LOADS), and returned, so what is loaded is exactly
what is recorded."""
function _judge_read(path::AbstractString)::String
    local bytes = read(path)
    push!(_JUDGE_LOADS, (relpath(abspath(path), _JUDGE_ROOT), _judge_blob(bytes)))
    return String(bytes)
end
_judge_include(m::Module, path::AbstractString) = (Base.include_string(m, _judge_read(path), String(path)); nothing)

const SMOKE_JUDGE = get(ENV, "WT_SMOKE_JUDGE", "")
"""    _process_record() -> String

What this process ran with (spec v16 X3): its ARGS, its whole environment (sorted) and every field of Base.JLOptions()
(a string a pointer names, NULL, or its value), one `<arg|env|opt>\t<name>\t<value>` line each (a value holding a
newline reads as a line of nothing, refused), base64 as one field of its `loads` record (and of the key's line): the
driver refuses any difference from the process it declared (dev/climb/measure.py ANSWER_PROCESS, loads_checked), by
name, so a new input is a located refusal."""
function _process_record()::String
    local o, ls = Base.JLOptions(), String[]
    foreach(((i, a),) -> push!(ls, "arg\t$i\t$a"), enumerate(ARGS))
    foreach(k -> push!(ls, "env\t$k\t$(ENV[k])"), sort!(collect(keys(ENV))))
    for f in fieldnames(Base.JLOptions)
        local x = getfield(o, f)
        local v = x isa Ptr ? (x == C_NULL ? "NULL" : x isa Ptr{UInt8} ? unsafe_string(x) : "a pointer") : string(x)
        push!(ls, "opt\t$f\t$v")
    end
    return Base64.base64encode(join(ls, '\n'))
end
const _JUDGING = abspath(PROGRAM_FILE) == @__FILE__
# (each a top-level statement of its own: a name an include defines is seen only by the statements after it)
_JUDGING && _judge_read(@__FILE__)   # this entry, the first file of the answering program's record
# a file any code loads by `include` (Base's _include, which reads it apart from _judge_read) is recorded too, by
# Julia's own hook for it (Base.include_callbacks, the hook Revise.jl tracks files by), so it is in the record the
# driver checks and refused there as loaded besides the answering program
_JUDGING && push!(Base.include_callbacks, (m::Module, path::AbstractString) -> (_judge_read(path); nothing))
_JUDGING && get(ENV, "WT_SMOKE_KEY", "") != "1" && isempty(SMOKE_JUDGE) &&
    error("test/smoke_judge.jl runs as the judging process (WT_SMOKE_JUDGE=1) or the key's (WT_SMOKE_KEY=1)")
# the judging process's records: its stdout, saved before anything else runs; every other print goes to stderr
const _RECORDS = stdout
_JUDGING && redirect_stdout(stderr)
_JUDGING && _judge_include(Main, joinpath(@__DIR__, "oracle.jl"))
# WT_SMOKE_KEY=1: Julia's and the host's half of the oracle's key (test/oracle.jl's oracle_key), and exit, loading no
# corpus and no WasmTarget (dev/climb/measure.py julia_host)
_JUDGING && get(ENV, "WT_SMOKE_KEY", "") == "1" && (print(_RECORDS, WTOracle.oracle_key(), '\t', _process_record()); exit(0))
_JUDGING && _judge_include(Main, joinpath(@__DIR__, "corpus_loader.jl"))

# ---- the corpus's registry: each case (name, f, args...)
const GROUPS = Vector{Pair{String,Vector{Any}}}()
_g(name, cases) = push!(GROUPS, name => cases)
const XFAIL = Vector{Pair{String,Vector{Any}}}()
_xf(name, cases) = push!(XFAIL, name => cases)
# the registrar test/corpus_loader.jl calls for a unit's registration, at the judge's world
_register(kind::Symbol, name, cases) = kind === :_g ? _g(name, cases) : _xf(name, cases)
# each label's own world (set as the corpus loads, below, after every judge definition), read once into the run's list
# of cases before any case's body runs: no case reads it back from here
const _WORLD = Dict{String,UInt}()
# each unit label's unit, as this process loaded it (its digest: test/corpus_loader.jl's digest_fields)
const _UNIT_OF = Dict{String,Any}()
# the labels a run is named (WT_SMOKE_ONLY: a file, `<group/case>` a line), or nothing for every label
_labels(var) = (p = get(ENV, var, ""); isempty(p) ? nothing : Set(String.(filter(!isempty, strip.(readlines(p))))))
const SMOKE_ONLY = _labels("WT_SMOKE_ONLY")

# an error's located lines, so a failing case names where to look without rerunning it
function _smoke_error_text(e)::String
    local lines = split(sprint(showerror, e), '\n')
    local keep = [strip(l) for l in lines if !isempty(strip(l))]
    local text = join(first(keep, 4), " | ")
    return length(text) > 600 ? first(text, 600) * "…" : text
end
# every label of a group list, read with no closure called per case (one compiled per case's tuple type, 1.7 s)
function _labels_of(list)::Vector{String}
    local out = String[]
    for (g, cs) in list, c in cs
        push!(out, string(g, "/", Core.getfield(c, 1)::String))
    end
    return out
end
function _unit_paths()::Vector{String}
    local handed = get(ENV, "WT_SMOKE_UNITS", nothing)
    handed === nothing && (_JUDGING || !isempty(get(ENV, "WT_SMOKE_COMPILED", ""))) &&
        error("the judging and compiling processes load the units in the order the driver hands (WT_SMOKE_UNITS): none handed")
    return CorpusLoader.unit_paths(dirname(@__DIR__); handed, labels = SMOKE_ONLY)   # the units of the labels it is named
end

# ---- the judging process: the one definition of a native answer (dev/climb/HILL.md, the oracle). It is named exactly
# one case (WT_SMOKE_ONLY), loads the snapshot and that case's unit alone (the driver's judging directory holds no other),
# prints the files it loaded, calls the case once at its world (test/oracle.jl's answer_of), writes its records between
# its `started` and `ended`, and exits; a case whose answer cannot be read gets `noanswer` and why
const _ANSWER_CAP = parse(Int, get(ENV, "WT_SMOKE_ANSWER_CAP", "0"))   # the driver's band; 0: none
_started(fields...) = (println(_RECORDS, join(fields, '\t')); flush(_RECORDS))
function _judge_main()
    SMOKE_ONLY !== nothing && length(SMOKE_ONLY) == 1 ||
        error("WT_SMOKE_JUDGE answers exactly one case a process (WT_SMOKE_ONLY names one): it is named $(SMOKE_ONLY === nothing ? "none" : length(SMOKE_ONLY))")
    local label = only(SMOKE_ONLY)
    # the case's facts (its registration tuple, its world, its unit's digest) taken before its body runs
    local hits = [c for (g, cs) in vcat(GROUPS, XFAIL) for c in cs if string(g, "/", Core.getfield(c, 1)::String) == label]
    length(hits) == 1 || error("WT_SMOKE_JUDGE is named $label, which the corpus it loaded registers $(length(hits)) times")
    local case, world, u = hits[1], _WORLD[label], get(_UNIT_OF, label, nothing)
    local digest = u === nothing ? nothing : Tuple(CorpusLoader.digest_fields(u))
    local loads = join(("$p=$b" for (p, b) in _JUDGE_LOADS), ';')
    _started("started", label)
    _started("loads", label, loads, _process_record())   # the answering program and what it ran with, before the case runs
    local lines = try
        WTOracle.answer_lines(label, WTOracle.answer_of("", case[2], Tuple(case[3:end]); world))
    catch e
        ["noanswer\t$label\t" * Base64.base64encode(_smoke_error_text(e))]
    end
    # an answer past the driver's band (WT_SMOKE_ANSWER_CAP, dev/climb/defaults.py answer_cap_bytes) is refused here,
    # located, as the driver refuses one past it at its drain (dev/climb/measure.py drain)
    local n = sum(l -> sizeof(l) + 1, lines)
    0 < _ANSWER_CAP < n && (lines = ["noanswer\t$label\t" * Base64.base64encode(
        "its answer's records are $n bytes, past the driver's band of $(_ANSWER_CAP) (answer_cap_bytes)")])
    foreach(_started, lines)
    # a unit label's answer closes with its unit's digest, the program the answer is of
    digest === nothing || !startswith(lines[1], "answer\t") || _started("digest", label, digest...)
    _started("ended")
    println("smoke_judge: answered $label; no verdict (WT_SMOKE_JUDGE)")
    exit(0)
end

# ---- the corpus, loaded after every definition of the judge's, so the judge's world holds none of it; never in the
# comparing process. The snapshot is included into Main as it stands; each unit after it is loaded by
# test/corpus_loader.jl, its registrations read and handed to _g and _xf; each label's world recorded. Every file is read
# by _judge_read.
# the judge's world: after every judge definition, before the corpus; a constant, so no code the corpus runs moves it
const W_JUDGE = Base.get_world_counter()
# the judge's modules (CorpusLoader.JUDGE_MODULES, the one list), each named where a process that loads the corpus holds
# it (the answering process WTOracle and CorpusLoader; the compiling process those, WTOracleRead, WTVerdict and WasmTarget)
let
    isdefined(Main, :WTRunner) && error("test/runner.jl is loaded in a process that loads the corpus: no verdict's or answer's process holds it (spec v16 X1)")
    CorpusLoader.judge!(W_JUDGE, Module[getglobal(Main, s) for s in CorpusLoader.JUDGE_MODULES if isdefined(Main, s)])
_judge_include(Main, joinpath(@__DIR__, "smoke_corpus.jl"))   # (at the line's start: the snapshot's one include)
    let w = Base.get_world_counter()
        foreach(l -> _WORLD[l] = w, _labels_of(GROUPS)); foreach(l -> _WORLD[l] = w, _labels_of(XFAIL))
    end
    for u in CorpusLoader.load_units(_unit_paths(); register = _register, read_file = _judge_read,
                                     labels = Set{String}(Iterators.flatten((_labels_of(GROUPS), _labels_of(XFAIL)))))
        foreach(l -> (_WORLD[l] = u.world; _UNIT_OF[l] = u), u.labels)
    end
end

_JUDGING && Base.invoke_in_world(W_JUDGE, _judge_main)
