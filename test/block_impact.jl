# The blocking gate's selections, measured (dev/block.jl, test/block_groups.tsv; L194): which
# pieces of src/ each probe and each smoke group runs, and from that the probe core, the smoke
# core and each src file's smoke groups.
#
#   julia --code-coverage=@src --code-coverage="$TMPDIR/block_impact.info" --project=. test/block_impact.jl [<sets.tsv>]
#   julia --project=. test/block_impact.jl --from <sets.tsv>   # the selections from sets measured before
#   julia --project=. test/block_impact.jl --tables > test/block_tables.tsv   # each table entry's cases
#   julia --code-coverage=@src --code-coverage="$TMPDIR/block_impact.info" --project=. test/block_impact.jl --pieces <sets.tsv>
#                                    # the incremental re-record: only what moved since the sets
#
# (the second flag sends the process's own coverage, written at exit, to a tracefile instead of a
# .cov file beside every source file). Each probe of test/probe_corpus.jl is compiled as
# test/probe_bytes.jl compiles it and each smoke case run as test/smoke.jl runs it, with Julia's
# line coverage of src/ cleared before and written after (lcov): a probe's or a group's set is the
# pieces of src/ whose lines it ran, a piece being dev/block.jl's BLOCK_LINES lines of a top-level definition of a
# src/ file (inside a module, its definitions), `<file>:<name>#<k>`, the k-th from the definition's
# first line, so a long function is many pieces (calls.jl's compile_call! is thousands of lines) and
# a short one is one. It prints, as test/block_groups.tsv takes them:
#   probes   the greedy cover of every piece any probe runs (the probe running the most pieces not
#            yet run, then the next; a tie to the earlier probe)
#   core     the greedy cover by pieces per second of the pieces the smoke groups run, up to
#            CORE_SECONDS seconds (a group's cost is its recorded seconds, test/smoke_times.tsv's
#            1.12 column, the median for a group it lacks; a tie to the earlier group)
#   <file>   for each src file, the groups that cover, by the same rule up to FILE_SECONDS seconds,
#            pieces some group runs and the core does not (`-` when the core runs them all), then
#            the QA families that cover, by the same rule up to TESTS_SECONDS seconds (a family's
#            cost its recorded seconds, test/phase_times.tsv's `QA: <name>`), the file's pieces run
#            by the families the file's locks cite as behavior (`-` when they run none of its
#            pieces): a lock's file is a src file it reads by path (`joinpath(SRC, ...)` or
#            `joinpath(CODEGEN, ...)`, a directory meaning its files), its cited families the QA
#            families of test/runtests.jl its entry in test/parity_ratchet.jl names by path, each
#            measured as test/runtests.jl runs it alone (WT_QA_ONLY=<name>, after the prelude its
#            shard runs it after). A cited family past TESTS_SECONDS on its own is printed as such:
#            the full matrix runs it; then the file's 1.13 groups, set by hand and carried over
# With a path, the measured lines are also written there (a line per probe or group: its name, then
# the lines of src/ it ran), so `--from` recomputes the selections without measuring again.
# A piece is a definition's BLOCK_LINES lines, each line of a `const` table its own, any other
# top-level form's lines (dev/block.jl line_keys): every line of code is in one. A body no native run
# executes, an overlay or a bespoke body WT compiles in Julia's place, counts as run by a probe or a
# case whose plan compiles it (its definition's pieces, from the plan's functions). With --tables
# it writes, for each entry of the numeric lowering tables (dev/block.jl table_entry_keys), the
# generated cases that case it (test/registry_cases.jl's RC_ENTRY), which the gate runs when the
# entry changes. Without --code-coverage the measuring run refuses: no line would count.
#
# --pieces <sets.tsv> re-records incrementally (dev/block.jl's staleness budget prints it): from the
# sets a measurement saved there (the full run's `<sets.tsv>`; dev/block.jl names the main tree's
# dev/.block/impact_sets.tsv), it measures again only each probe, smoke group and QA family whose saved
# lines touch a src file that changed between the saved src tree and HEAD's (and any the sets lack),
# keeps every other one's lines (they lie in files that did not change), writes the sets back for HEAD's
# src tree and test/block_groups.tsv's rows in place under its header, and prints its summary. What it
# cannot see: an unchanged call that a new method makes select another (the entry ran no line of the
# changed file), and a probe, group or QA family whose own definition in test/ changed under the same
# name (it keeps its saved lines); a full re-record measures a fresh map.

const FROM = length(ARGS) == 2 && ARGS[1] == "--from" ? ARGS[2] : ""
const TABLES = ARGS == ["--tables"]
const PIECES = length(ARGS) == 2 && ARGS[1] == "--pieces" ? ARGS[2] : ""
const SETS_OUT = isempty(FROM) && isempty(PIECES) && !TABLES && length(ARGS) == 1 ? ARGS[1] : PIECES
isempty(FROM) && isempty(PIECES) && !TABLES && length(ARGS) > 1 && error("block_impact: unknown arguments $(join(ARGS, ' ')) (see the header)")

using WasmTarget

isempty(FROM) && !TABLES && Base.JLOptions().code_coverage == 0 && (println("block_impact: run with --code-coverage=@src"); exit(2))
# Coverage counts the lines WasmTarget's own code runs (codegen instruments them); Julia's optimizer
# would also mark coverage in the IR WasmTarget compiles, wherever an overlay from src/ is inlined
# into it, and that IR is the input the probes fingerprint and smoke runs (a `:code_coverage_effect`
# rejects): in this process the optimizer marks none, so each case compiles the IR it always does.
Core.eval(Core.Compiler, :(should_insert_coverage(mod::Module, debuginfo::Core.DebugInfo) = false))

# the gate's own reading of the map, the QA families and a file's pieces
const BLOCK = Module(:Block)
Base.include(BLOCK, joinpath(@__DIR__, "..", "dev", "block.jl"))

const CORE_SECONDS = 30.0
const FILE_SECONDS = 25.0
const TESTS_SECONDS = 20.0
const SRC = normpath(joinpath(@__DIR__, "..", "src"))

include(joinpath(@__DIR__, "probe_corpus.jl"))
include(joinpath(@__DIR__, "smoke.jl"))   # GROUPS; its main() runs only when it is the program
_build!(collect(keys(LAZY_FILE)))   # every lazy group's cases (test/registry_cases.jl's)

# a file's pieces, as the gate cuts them (dev/block.jl's line_keys)
line_keys(path::String) = Base.invokelatest(BLOCK.line_keys, read(path, String), relpath(path, dirname(SRC)))

# the files holding a lowering table (L194's rule: a `const` INTRINSIC_*, CHECKED_OPS, SHIFT_OPS,
# FMA_OPS, MISC_OPS, INT128_OPS or BUILTIN_LOWERINGS) and the two holding their lowering
const LOWERING_FILES = union(Set(["src/codegen/calls.jl", "src/codegen/int128.jl"]),
    Set("src/" * relpath(joinpath(d, f), joinpath(@__DIR__, "..", "src")) for (d, _, fs) in walkdir(joinpath(@__DIR__, "..", "src"))
        for f in fs if endswith(f, ".jl") &&
        occursin(r"^const (?:INTRINSIC_\w+|CHECKED_OPS|SHIFT_OPS|FMA_OPS|MISC_OPS|INT128_OPS|BUILTIN_LOWERINGS)\b"m, read(joinpath(d, f), String))))
const KEYS = Dict{String,Dict{Int,String}}()
for (d, _, fs) in walkdir(SRC), f in fs
    endswith(f, ".jl") && (KEYS[relpath(joinpath(d, f), dirname(SRC))] = line_keys(joinpath(d, f)))
end
const INFO = tempname() * ".info"
# the src tree a measurement is of: HEAD's, when src/ holds no uncommitted change (else of no tree);
# a recomputation from saved sets prints the tree the sets name
measured_tree() = success(`git -C $(dirname(SRC)) diff --quiet HEAD -- src`) ? readchomp(`git -C $(dirname(SRC)) rev-parse HEAD:src`) : "unknown"
const MEASURED = Ref("unknown")

# the lines of src/ (`<file>` => lines) `f()` runs
function covered(f)::Dict{String,Set{Int}}
    ccall(:jl_clear_coverage_data, Cvoid, ())
    f()
    ccall(:jl_write_coverage_data, Cvoid, (Cstring,), INFO)
    out = Dict{String,Set{Int}}(); file = ""
    for l in eachline(INFO)
        if startswith(l, "SF:")
            file = relpath(normpath(l[4:end]), dirname(SRC))
        elseif startswith(l, "DA:") && haskey(KEYS, file)
            ln, c = parse.(Int, split(l[4:end], ',')[1:2])
            c > 0 && push!(get!(out, file, Set{Int}()), ln)
        end
    end
    return out
end
merge_lines!(a, b) = (for (f, ls) in b; union!(get!(a, f, Set{Int}()), ls); end; a)

# the lines of src/ a plan compiles from bodies no native run executes: each planned function whose
# method src/ defines (an overlay, a bespoke body), every piece of its definition (A20C13)
function planned_lines(entries::Vector{Any})::Dict{String,Set{Int}}
    out = Dict{String,Set{Int}}()
    local plan = try
        WasmTarget.trim_compile_plan(entries)
    catch e
        e isa WasmTarget.WasmCompileError || rethrow()   # a case refused at its plan compiles no body
        return out
    end
    for fn in plan.functions
        local m = fn[4].def
        m isa Method || continue
        local file = relpath(normpath(string(m.file)), dirname(SRC))
        haskey(KEYS, file) && haskey(KEYS[file], m.line) || continue
        local def = first(split(KEYS[file][m.line], '#'))
        union!(get!(out, file, Set{Int}()), (l for (l, k) in KEYS[file] if first(split(k, '#')) == def))
    end
    return out
end
# a smoke case's entry and its run: a generated case over its inputs, any other over its arguments
case_types(g, c) = haskey(CASE_INPUTS, "$g/$(c[1])") ? Tuple(map(typeof, first(CASE_INPUTS["$g/$(c[1])"]))) : Tuple(map(typeof, c[3:end]))
run_case(g, c) = haskey(CASE_INPUTS, "$g/$(c[1])") ? compare_julia_wasm_inputs(c[2], CASE_INPUTS["$g/$(c[1])"]; admit=_rc_admit) :
                 length(c) > 2 ? compare_julia_wasm(c[2], c[3:end]...) : compare_julia_wasm(c[2])
pieces(lines) = Set{String}(KEYS[f][l] for (f, ls) in lines for l in ls if haskey(KEYS[f], l))

# greedy: the entry gaining the most of `left` per unit of cost, ties to the earlier, while the
# budget allows
function cover(sets::Vector{Pair{String,Set{String}}}, cost::Vector{<:Real}, left::Set{String}, budget)
    left = copy(left); out = String[]; spent = 0
    while !isempty(left)
        gains = [length(intersect(last(sets[i]), left)) for i in eachindex(sets)]
        ok = [i for i in eachindex(sets) if gains[i] > 0 && spent + cost[i] <= budget]
        isempty(ok) && break
        i = argmax(j -> (gains[j] / cost[j], -j), ok)
        push!(out, first(sets[i])); spent += cost[i]; setdiff!(left, last(sets[i]))
    end
    return out, left
end

# the QA families test/runtests.jl deals, read as the gate reads them (dev/block.jl's qa_families)
qa_families() = Base.invokelatest(BLOCK.qa_families)
# of them, the ones test/parity_ratchet.jl names by path: the families a lock cites as its behavior
# (the ratchet itself is the gate's own stage)
function cited_qa_families()
    pr = read(joinpath(@__DIR__, "parity_ratchet.jl"), String)
    return [n for n in qa_families() if occursin("test/" * n, pr) ||
            occursin("\"test\", " * join(map(p -> "\"" * p * "\"", split(n, '/')), ", "), pr)]
end

# each cited QA family => the src files the locks citing it read by path
function lock_reads()::Dict{String,Set{String}}
    pr = read(joinpath(@__DIR__, "parity_ratchet.jl"), String)
    fams = qa_families()
    srcfiles = collect(keys(KEYS))
    starts = [m.offset for m in eachmatch(r"^    \"[LR][0-9]+[a-z]?_[A-Za-z0-9_]+\" => \("m, pr)]
    out = Dict{String,Set{String}}()
    for (a, b) in zip(starts, vcat(starts[2:end], [ncodeunits(pr) + 1]))
        e = pr[a:prevind(pr, b)]
        cited = [f for f in fams if f != "parity_ratchet.jl" && (occursin("test/" * f, e) ||
                 occursin("\"test\", " * join(map(p -> "\"" * p * "\"", split(f, '/')), ", "), e))]
        isempty(cited) && continue
        reads = Set{String}()
        for m in eachmatch(r"joinpath\((SRC|CODEGEN)((?:, \"[^\"]+\")*)\)", e)
            path = join(vcat(m[1] == "SRC" ? ["src"] : ["src", "codegen"], [x[1] for x in eachmatch(r"\"([^\"]+)\"", m[2])]), '/')
            endswith(path, ".jl") ? push!(reads, path) : union!(reads, filter(f -> startswith(f, path * "/"), srcfiles))
        end
        for f in cited
            union!(get!(out, f, Set{String}()), reads)
        end
    end
    return out
end

# runs one QA family as test/runtests.jl runs it alone (WT_QA_ONLY): its prelude, then the family, in
# a module of its own; runtests' exit after the QA families ends the include, not this process
struct QAExit <: Exception
    code::Int
end
function run_qa(name)
    M = Module(:BlockImpactQA)
    Core.eval(M, :(include(p) = Base.include($M, p)))
    Core.eval(M, :(eval(x) = Core.eval($M, x)))
    Core.eval(M, :(exit(n = 0) = throw($QAExit(Int(n)))))
    try
        withenv(() -> Base.include(M, joinpath(@__DIR__, "runtests.jl")), "WT_QA_ONLY" => name)
    catch e
        x = e
        while x isa LoadError; x = x.error; end
        # a family that fails here still ran the lines it ran: they count, and the failure is printed
        x isa QAExit && x.code == 0 || println("block_impact: QA family $name failed while measured: ", first(sprint(showerror, x), 300))
    finally
        isdefined(M, :shutdown_pool!) && Base.invokelatest(getglobal(M, :shutdown_pool!))
    end
end

# measures every probe, group and QA family, or, given `redo`, only those its (kind, name) pairs name
function measure(redo = nothing)
    want(kind, n) = redo === nothing || (kind, n) in redo
    tests = [name => covered(() -> run_qa(name)) for name in cited_qa_families() if want("test", name)]
    probes = [name => merge_lines!(covered(() -> WasmTarget.to_bytes(WasmTarget.compile_module([(f, argtypes, name)]; options = WasmTarget.options_from_env()))),
                                   planned_lines(Any[(f, argtypes, name)]))
              for (name, (f, argtypes)) in CASES if want("probe", name)]
    groups = Pair{String,Dict{String,Set{Int}}}[]
    for (g, cases) in GROUPS
        want("group", g) || continue
        lines = Dict{String,Set{Int}}()
        for c in cases
            merge_lines!(lines, covered(() -> run_case(g, c)))
            merge_lines!(lines, planned_lines(Any[(c[2], case_types(g, c), string(c[1]))]))
        end
        push!(groups, g => lines)
    end
    rm(INFO; force = true)
    redo === nothing && !isempty(SETS_OUT) && write_sets(SETS_OUT, measured_tree(), probes, groups, tests)
    return probes, groups, tests
end

function write_sets(path, tree, probes, groups, tests)
    open(path, "w") do io
        println(io, "measured\t", tree)
        for (kind, sets) in (("probe", probes), ("group", groups), ("test", tests)), (n, lines) in sets
            println(io, kind, '\t', n, '\t', join([f * ":" * join(sort(collect(ls)), ',') for (f, ls) in sort(collect(lines); by = first)], ' '))
        end
    end
end

# the incremental re-record (--pieces, the header): the saved sets, measured again where src/ moved
function incremental(path)
    isfile(path) || error("block_impact --pieces: no saved sets at $path: run the full measurement with that path first")
    p0, g0, t0 = load_sets(path)
    old = MEASURED[]
    now = measured_tree()
    now == "unknown" && error("block_impact --pieces: src/ has uncommitted changes: commit them first (a measurement is of a src tree)")
    occursin(r"^[0-9a-f]{40}$", old) && success(`git -C $(dirname(SRC)) cat-file -e $old`) ||
        error("block_impact --pieces: the sets at $path measured src tree $old, which this repository does not hold: run the full measurement")
    moved = Set("src/" * f for f in split(readchomp(`git -C $(dirname(SRC)) diff --name-only $old $now`), '\n'; keepempty = false))
    names = Dict("probe" => first.(CASES), "group" => first.(GROUPS), "test" => cited_qa_families())
    saved = Dict("probe" => Dict(p0), "group" => Dict(g0), "test" => Dict(t0))
    redo = Set{Tuple{String,String}}()
    for kind in ("probe", "group", "test"), n in names[kind]
        lines = get(saved[kind], n, nothing)
        (lines === nothing || any(f -> f in moved, keys(lines))) && push!(redo, (kind, n))
    end
    println(stderr, "block_impact --pieces: src moved in $(length(moved)) files since $(first(old, 8)); measuring $(length(redo)) of ",
            sum(length, values(names)), " probes, groups and QA families again")
    p1, g1, t1 = measure(redo)
    fresh = Dict("probe" => Dict(p1), "group" => Dict(g1), "test" => Dict(t1))
    pick(kind) = [n => (haskey(fresh[kind], n) ? fresh[kind][n] : saved[kind][n]) for n in names[kind]]
    probes, groups, tests = pick("probe"), pick("group"), pick("test")
    write_sets(path, now, probes, groups, tests)
    return probes, groups, tests
end

function load_sets(path)
    sets = Dict(k => Pair{String,Dict{String,Set{Int}}}[] for k in ("probe", "group", "test"))
    for l in eachline(path)
        f = split(l, '\t')
        f[1] == "measured" && (MEASURED[] = String(f[2]); continue)   # the src tree the sets measured
        lines = Dict{String,Set{Int}}()
        for part in split(f[3])
            file, ls = split(part, ':')
            lines[String(file)] = Set(parse.(Int, split(ls, ',')))
        end
        push!(sets[f[1]], String(f[2]) => lines)
    end
    return sets["probe"], sets["group"], sets["test"]
end

# each entry of the numeric lowering tables (dev/block.jl table_entry_keys), the generated cases that
# case it (RC_ENTRY: the table and the key each case was generated for), one line each; an entry no
# case cases raises (the generator raises for a key no type reaches first)
function tables()
    println("# each numeric lowering-table entry and the generated cases that case it (test/block_impact.jl --tables;")
    println("# dev/block.jl runs them when the entry changes, A20C12): <file>\t<table>\t<entry key's text>\t<group/case ...>")
    for (d, _, fs) in walkdir(SRC), f in sort(fs)
        endswith(f, ".jl") || continue
        local rel = relpath(joinpath(d, f), dirname(SRC))
        local entries = Base.invokelatest(BLOCK.table_entry_keys, read(joinpath(d, f), String), rel)
        for (table, keytext) in sort(unique(collect(values(entries))))
            local tsym = Symbol(table)
            any(e -> first(e) === tsym, values(RC_ENTRY)) || continue   # a table no generator cases
            local key = Core.eval(WasmTarget, Meta.parse(keytext))
            local cases = sort([c for (c, e) in RC_ENTRY if e[1] === tsym && isequal(e[2], key) && !startswith(c, "registry_sample/")])
            isempty(cases) && error("block_impact: the entry $keytext of $table ($rel) has no generated case")
            println(rel, '\t', table, '\t', keytext, '\t', join(cases, ' '))
        end
    end
    return 0
end

function main()
    TABLES && return tables()
    if !isempty(PIECES)
        # the map's rows written in place under its header; the summary printed
        local p, g, t = incremental(PIECES)
        local out = IOBuffer()
        selections(out, p, g, t)
        # the header kept; the rows no measurement writes (a directory row such as ext/, a test
        # file's) carried over, after the measured rows and before their past-budget notes
        local header = String[]; local hand = String[]; local inheader = true
        for l in eachline(joinpath(@__DIR__, "block_groups.tsv"))
            inheader &= startswith(l, '#')
            inheader && (push!(header, l); continue)
            local f = split(l, '\t')
            (startswith(l, '#') || length(f) != 4 || startswith(f[1], "src/")) || push!(hand, l)
        end
        local rows = String[]; local notes = String[]
        for l in split(String(take!(out)), '\n'; keepempty = false)
            startswith(l, "block_impact: ") ? println(l) : startswith(l, "# ") ? push!(notes, l) : push!(rows, l)
        end
        write(joinpath(@__DIR__, "block_groups.tsv"), join(vcat(header, rows, hand, notes), '\n') * '\n')
        return 0
    end
    plines, glines, tlines = isempty(FROM) ? measure() : load_sets(FROM)
    return selections(stdout, plines, glines, tlines)
end

# the selections from measured sets, printed to `io` as test/block_groups.tsv takes them
function selections(io::IO, plines, glines, tlines)
    probes = [n => pieces(l) for (n, l) in plines]
    # a matrix-only group (test/block_groups.tsv) is no stage's here: never a cover's candidate
    local matrix = String[]
    for l in eachline(joinpath(@__DIR__, "block_groups.tsv"))
        startswith(l, "matrix-only\t") && append!(matrix, split(l, '\t')[2] |> split .|> String)
    end
    groups = [n => pieces(l) for (n, l) in glines if !(n in matrix)]
    tests = [n => pieces(l) for (n, l) in tlines]
    pu = reduce(union, last.(probes); init = Set{String}())
    pcore, _ = cover(probes, ones(Int, length(probes)), pu, typemax(Int))
    # a group's cost: its recorded seconds (test/smoke_times.tsv, 1.12), the median for one it lacks
    rec = Dict{String,Float64}()
    for l in eachline(joinpath(@__DIR__, "smoke_times.tsv"))
        f = split(l, '\t'); (startswith(l, '#') || length(f) != 3) && continue
        t = tryparse(Float64, f[1]); t === nothing || (rec[String(f[3])] = t)
    end
    med = sort(collect(values(rec)))[(length(rec) + 1) ÷ 2]
    secs = [get(rec, first(g), med) for g in groups]
    su = reduce(union, last.(groups); init = Set{String}())
    core, uncovered = cover(groups, secs, su, CORE_SECONDS)
    pick(c) = findfirst(g -> first(g) == c, groups)
    println(io, "block_impact: $(length(probes)) probes run $(length(pu)) pieces of src/, $(length(pcore)) cover them; ",
            "$(length(groups)) smoke groups run $(length(su)), the core's $(length(core)) groups ",
            "($(sum(length(GROUPS[pick(c)][2]) for c in core; init = 0)) cases, $(round(sum(secs[pick(c)] for c in core; init = 0.0); digits = 1)) s recorded) run $(length(su) - length(uncovered))")
    # the src tree measured, so the gate can say how far src/ has moved since (a measurement of a
    # src/ with uncommitted changes is of no tree)
    println(io, "measured\t", isempty(FROM) ? measured_tree() : MEASURED[])
    println(io, "probes\t", join(pcore, ' '))
    println(io, "core\t", join(core, ' '))
    println(io, "matrix-only\t", join(matrix, ' '))
    # a QA family's cost: its recorded seconds (test/phase_times.tsv, `QA: <name>`), the median for
    # one it lacks
    qrec = Dict{String,Float64}()
    for l in eachline(joinpath(@__DIR__, "phase_times.tsv"))
        f = split(l, '\t'; limit = 2)
        length(f) == 2 && startswith(f[2], "QA: ") || continue
        t = tryparse(Float64, f[1]); t === nothing || (qrec[String(f[2][5:end])] = t)
    end
    qmed = isempty(qrec) ? 1.0 : sort(collect(values(qrec)))[(length(qrec) + 1) ÷ 2]
    tsecs = [get(qrec, first(t), qmed) for t in tests]
    tu = reduce(union, last.(tests); init = Set{String}())
    println(io, "block_impact: the $(length(tests)) QA families the locks cite run $(length(tu)) pieces of src/")
    reads = lock_reads()
    # the 1.13 groups are set by hand (which file prints version-dependent text is not measured):
    # carried over from the map as it is
    v113 = Dict{String,String}()
    for l in eachline(joinpath(@__DIR__, "block_groups.tsv"))
        f = split(l, '\t')
        length(f) == 4 && (v113[String(f[1])] = String(f[4]))
    end
    past = String[]
    for (i, t) in enumerate(tests)
        tsecs[i] <= TESTS_SECONDS || push!(past, "$(first(t)): $(tsecs[i]) s recorded, past $TESTS_SECONDS s on its own: the full matrix runs it")
    end
    for file in sort(collect(keys(KEYS)))
        left = Set(k for k in uncovered if startswith(k, file * ":"))
        gs, rest = cover(groups, secs, left, FILE_SECONDS)
        isempty(rest) || push!(past, "$file: $(length(rest)) of its pieces the groups run past $FILE_SECONDS s")
        mine = [i for (i, t) in enumerate(tests) if file in get(reads, first(t), Set{String}())]
        tleft = Set(k for i in mine for k in last(tests[i]) if startswith(k, file * ":"))
        ts, trest = cover(tests[mine], tsecs[mine], tleft, TESTS_SECONDS)
        isempty(trest) || push!(past, "$file: $(length(trest)) of its pieces its locks' QA families run past $TESTS_SECONDS s")
        # a file holding a numeric lowering table, and calls.jl and int128.jl, which hold their lowering,
        # run the sample of the generated cases and the narrow integers whatever the cover (A20P12)
        file in LOWERING_FILES && foreach(g -> g in gs || push!(gs, g), ("registry_sample", "narrow_primitive"))
        println(io, file, "\t", isempty(gs) ? "-" : join(gs, ' '), "\t", isempty(ts) ? "-" : join(ts, ' '), "\t", get(v113, file, "-"))
    end
    foreach(l -> println(io, "# ", l), past)
    return 0
end

exit(main())
