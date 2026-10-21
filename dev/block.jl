# dev/block.jl — the blocking gate (dev/CHARTER.md C10; L194, L195): `bash dev/gate.sh --block`.
#
# Gives a landing its verdict on this machine in at most 60 s of wall, never waiting on CI. Each
# stage is the very command a fresh check runs (`julia --project=. test/<file>`), in a process of
# its own, the stages side by side: one process per stage keeps each one fresh (a test's Main holds
# only what the test loads, as the probe bytes' closure names need), and side by side keeps the
# wall the slowest stage's, not their sum (a fresh process spends ~20 s compiling the compiler
# before its first case, which no stage can share with another).
#
#   load        `using WasmTarget`: the package image this tree needs, built once (a stage that
#               loads the package waits for it on Julia's own precompile lock)
#   ratchet     test/parity_ratchet.jl (-O0: it reads text and runs the builder's rows; no Julia
#               answer is compared, and LLVM's level changes no string it reads)
#   smoke-core  test/smoke.jl on test/block_groups.tsv's fixed `core` groups
#   smoke-batch test/smoke.jl on the groups the changed files map to there, then the groups whose
#               lines the change touches in test/smoke.jl and the case files it includes (the
#               batch's own cases), then the generated cases of each lowering-table entry the change
#               touches (test/block_tables.tsv, WT_SMOKE_CASES; an entry with none fails, and so
#               does a changed entry of a table no generator cases, naming the table) (A20C12, A22E3).
#               A change to src/ fails when the map is stale: more than STALE_PIECES pieces of src
#               changed between the tree test/block_groups.tsv measured and the change's base (the
#               count and the re-record command printed), a measured tree this repository does not
#               hold, or a changed line of code in no piece; a change to ext/, which no map
#               measures, fails (A20C13)
#   smoke-1.13  on `julia +1.13`: the batch's own groups, and the 1.13 groups test/block_groups.tsv's
#               row of each changed file names (a file whose output prints Julia's own signatures or
#               types, which differ between versions, as the export namer does), when there are any
#               (the smokes at Julia's default flags, so the native answer each case compares
#               against is Julia's own; dev/block_jit.jl lowers LLVM's level for WasmTarget's and
#               the compiler's own code only: at -O0 for the whole process three bit-exact cases
#               answer otherwise)
#   probes      test/probe_bytes.jl on the probe core (test/block_groups.tsv's `probes`: a cover of
#               every src function any probe runs, test/block_impact.jl) and the probes the change
#               touches, PROBE_CHUNK to a process (-O0: a probe is a hash of the module's bytes, no
#               Julia answer, and all 225 are byte-identical at -O0); under --warm, through the runner,
#               whose reset gives each request a fresh process's Main (its binding table and lowering
#               counter, which the closure names in the bytes are drawn from)
#   tests       test/runtests.jl on the QA families and phases the change selects (WT_QA_ONLY),
#               each as the shard it is dealt to runs it: every changed QA family, the families and
#               phases whose lines test/runtests.jl's change touches, and the QA families the row of
#               each changed file names in test/block_groups.tsv (of the families a lock cites as
#               its behavior, the cover of the file's pieces they run, test/block_impact.jl)
#   tlc         dev/formal/run_tlc.sh on the instances of the models the change touches (their
#               deep instances stay with the full run, run_tlc.sh's TLC_FAST list)
#
# --warm: the stages that load the package (the smokes on 1.12, the probes, the tests) run one after
# another through this tree's warm runner, dev/block_runner.jl (`julia --startup-file=no
# dev/block_runner.jl start` first), which runs a check as `julia --project=. <file> [args...]`
# would in a process already holding this tree's code, revised before each request: compiling the
# compiler is then paid once per session, not per stage (measured under the agents' load: the smoke
# core 16 s and the probe core 8 s warm, 28 s and 12 s after an edit to a central function, against
# 116 s and 90 s fresh). The record names the runner by its git blob, which must be this tree's
# (dev/land.sh merge takes a record of no other runner); every stage's best and budget under it is
# `<stage>@warm` where one is recorded. A run whose runner was cold (a request that was its server's
# first or the first after a revise) or that built the package image (its load stage precompiled)
# measures compiling the change, not running it: its time is judged by nothing, its checks are (a
# cold run whose checks pass is green with `timing = "unjudged"`, A19P2, A19P4).
#
# Hard budgets and a timing ratchet (dev/timing_best.toml): the whole run at most `total` seconds
# of wall and each stage at most its own budget; a stage whose work is fixed (load, ratchet,
# smoke-core, the probe core) more than 15% AND more than 0.3 s slower than its best fails. Times
# are scaled by the machine's speed while the stages ran (calibrate!, below): a stage's wall over
# the factor by which a fixed piece of work, timed throughout the run, was slower than its best.
# A stage that does more work or waits longer is slower; a busier machine is not. The budgets and
# the total are literal walls, never scaled: a machine more than FACTOR_CAP times slower than its
# best while the stages ran leaves the run's timing ratchet unjudged: no stage is compared with its
# best, a run whose checks pass and whose literal budgets hold is green with `timing = "unjudged"` in
# its record (`dev/land.sh land` prints the unjudged streak, L198), and the budgets still hold at any
# factor (a stage or the run over its budget is red, A19P5). CI judges no timing (gate.yml has no
# timing stage): the ratchet is judged here whenever the machine is quiet enough, recorded as
# unjudged otherwise, never silently skipped. A
# change is judged by its own dev/timing_best.toml, held to the base's: no budget or best of the
# base's removed or raised (a best compared at one calibration), and an update that lowers the
# calibration lowers every best with it (A19P6). A
# commit whose message carries `Timing: correctness fix (MARCH 13.<n>)`, a row the change itself adds
# to dev/MARCH.md naming the stages it leaves slower, records those stages slower without failing,
# and its update raises their bests to what it measured, in the same reviewed diff (A19P7). WT_TIMING_UPDATE=1 lowers each best a green run on a clean
# tree on a quiet machine beat, the calibration's too, never raises one; a stage with no best fails.
#
# The verdict: red when the change fails (a stage's check, a file with no row, a budget or the
# timing ratchet), no verdict when the machine cannot give one (its Julia, Node or Java is not the
# one the gate needs), green otherwise; a run whose runner was cold (its first request, or the first
# after a revise, measures compiling the change rather than running it) is red only for a check that
# fails and otherwise green with its timing unjudged. Exit 0 green, 1 red, 3 no verdict.
#
# The evidence record, one per run, dev/.block/<tree>-<n>.toml (git-ignored; n counts the runs of
# that tree, never overwriting one), on a clean tree only: the tree and commit, the verdict and why,
# when it finished, every command, its exit code, wall and CPU, the budgets and bests, the load
# average, the runner and its state, the Julia, Node and Java versions, the changed files and the
# selections. `dev/land.sh merge` lands a commit only when no record of its tree is red (a red run
# stands, whatever runs after it) and the last one is green, of exactly that commit (A19P2).
#
#   bash dev/gate.sh --block [--warm] [--base <rev>]   # the change = <rev> (default: the merge base
#                                             # with $WT_MARCH_BRANCH, wt-p0-strict-hygiene) .. the tree

# TOML is loaded where it is used (main), so test/parity_ratchet.jl can include this file for its
# decisions (L195) in an environment that does not declare it
const TOML_ID = Base.PkgId(Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76"), "TOML")

const ROOT = normpath(joinpath(@__DIR__, ".."))
const BEST_PATH = joinpath(ROOT, "dev", "timing_best.toml")
const MAP_PATH = joinpath(ROOT, "test", "block_groups.tsv")
const TABLES_PATH = joinpath(ROOT, "test", "block_tables.tsv")
const RECORD_DIR = joinpath(ROOT, "dev", ".block")
const PROBE_CHUNK = 60
# a stage this much slower than its best fails: more than 15% AND more than 0.3 s (RULES, Dale 2026-10-20)
const SLOWER_FRACTION = 0.15
const SLOWER_SECONDS = 0.3
# a machine more than this many times slower than its best, measured while the stages ran, gives
# no verdict: its times say nothing of the change's, and no budget is scaled to pass it (A19P5)
const FACTOR_CAP = 1.5
# the stages whose work is fixed from run to run, so their time has a best to hold
const RATCHETED = ("load", "ratchet", "smoke-core", "probes")
# each stage's own code: a change to one of these paths runs that stage's code anew
const STAGE_INPUTS = Dict(
    "load" => ["src/", "ext/", "Project.toml"],
    "ratchet" => ["src/", "ext/", "test/", "dev/", "docs/", "AGENTS.md", ".github/"],
    "smoke-core" => ["src/", "ext/", "test/smoke.jl", "test/utils.jl", "test/wasm_runner.jl", "test/runner.mjs", "test/trace_localize.jl",
                     "test/emission_fingerprint.jl", "test/registry_cases.jl"],
    "probes" => ["src/", "ext/", "test/probe_bytes.jl", "test/probe_corpus.jl"],
    "tlc" => ["dev/formal/"])
for k in ("smoke-batch", "smoke-1.13")
    STAGE_INPUTS[k] = STAGE_INPUTS["smoke-core"]
end
STAGE_INPUTS["tests"] = ["src/", "ext/", "test/"]

git(args...) = readchomp(Cmd(`git -C $ROOT $args`))
gitok(args...) = success(Cmd(`git -C $ROOT $args`))

# A stage sees no WT_*, TLC_* or WASMTARGET_* variable of the caller's, only the gate's own (A19P3):
# a caller's WT_RATCHET_INCLUDED would make the ratchet exit 0 having run no lock, WT_SMOKE_PART
# would cut the core to one part, WT_RATCHET_UPDATE would rewrite the baseline and turn a missing
# key into a pass; the record lists the variables removed and each stage's own
const OWN_VARS = ("WT_SMOKE_TIMES", "WT_SMOKE_EXACT", "WT_SMOKE_CASES", "WT_PROBE_ONLY", "WT_QA_ONLY", "TLC_ONLY", "TLC_WORKERS")
foreign_var(k) = any(p -> startswith(k, p), ("WT_", "TLC_", "WASMTARGET_"))
function stage_env(own::AbstractDict = Dict{String,String}())
    all(k -> k in OWN_VARS, keys(own)) || error("block: $(join(setdiff(keys(own), OWN_VARS), ", ")) is not one of the gate's own variables")
    return merge(Dict{String,String}(k => v for (k, v) in ENV if !foreign_var(k)), Dict{String,String}(own))
end

# ---- the change ----------------------------------------------------------------------------
function change_base(args)::String
    i = findfirst(==("--base"), args)
    if i !== nothing
        i < length(args) || error("block: --base needs a revision")
        return git("rev-parse", "--verify", args[i+1] * "^{commit}")
    end
    march = get(ENV, "WT_MARCH_BRANCH", "wt-p0-strict-hygiene")
    gitok("rev-parse", "--verify", "-q", march) || error("block: no branch $march to take the change from (pass --base <rev>)")
    return git("merge-base", "HEAD", march)
end

changed_files(base) = sort(unique(vcat(split(git("diff", "--name-only", base), '\n'; keepempty = false),
                                       split(git("ls-files", "--others", "--exclude-standard"), '\n'; keepempty = false))))

# test/block_groups.tsv: the `measured` row (the src tree measured), the `core` row (smoke groups),
# the `probes` row (the probe core), the `matrix-only` row (smoke groups the blocking tier never
# runs: the non-blocking matrix runs them, a sample of them runs here), then
# `<path or dir/><TAB><groups><TAB><QA families><TAB><1.13 groups>` rows
function read_map()
    core = String[]; probes = String[]; matrix = String[]; measured = ""
    rows = Pair{String,Tuple{Vector{String},Vector{String},Vector{String}}}[]
    for (n, l) in enumerate(eachline(MAP_PATH))
        (isempty(strip(l)) || startswith(l, '#')) && continue
        f = split(l, '\t')
        names(x) = filter(!=("-"), String.(split(x)))   # `-`: nothing beyond the core
        if f[1] == "measured"
            length(f) == 2 || error("test/block_groups.tsv:$n: not \"measured<TAB><src tree>\": $l")
            measured = String(f[2])
        elseif f[1] in ("core", "probes", "matrix-only")
            length(f) == 2 || error("test/block_groups.tsv:$n: not \"$(f[1])<TAB><names>\": $l")
            append!(f[1] == "core" ? core : f[1] == "probes" ? probes : matrix, names(f[2]))
        else
            length(f) == 4 || error("test/block_groups.tsv:$n: not \"<path><TAB><groups><TAB><QA families><TAB><1.13 groups>\": $l")
            push!(rows, String(f[1]) => (names(f[2]), names(f[3]), names(f[4])))
        end
    end
    isempty(core) && error("test/block_groups.tsv has no core row")
    isempty(probes) && error("test/block_groups.tsv has no probes row")
    isempty(measured) && error("test/block_groups.tsv has no measured row (the src tree test/block_impact.jl measured)")
    isempty(intersect(core, matrix)) || error("test/block_groups.tsv: the core runs a matrix-only group, $(join(intersect(core, matrix), ", "))")
    return core, probes, matrix, rows, measured
end

# the QA families test/runtests.jl deals, by the name its `_wt_qa` takes (`_wt_qa_include("<name>")`;
# a joinpath under test/ by its relative path); test/block_impact.jl measures them by this list too
function qa_families(root = ROOT)::Vector{String}
    rt = read(joinpath(root, "test", "runtests.jl"), String)
    return [m[1] !== nothing ? String(m[1]) : String(m[2]) * "/" * String(m[3])
            for m in eachmatch(r"_wt_qa_include\((?:\"([^\"]+)\"|joinpath\(@__DIR__, \"([^\"]+)\", \"([^\"]+)\"\))\)", rt)]
end

# the test files a stage runs itself (a change to one is run by that stage)
const STAGE_TESTS = ["test/smoke.jl", "test/utils.jl", "test/wasm_runner.jl", "test/trace_localize.jl",
                     "test/emission_fingerprint.jl", "test/registry_cases.jl",
                     "test/probe_bytes.jl", "test/probe_corpus.jl", "test/parity_ratchet.jl", "test/builder_cases.jl"]

# what test/runtests.jl's changed lines run: a changed `_wt_qa_include` line its QA family, a changed
# line inside a phase (from its `@pphase "name"` line to the next phase or the registration block's
# end) that phase; a line of its harness (anywhere else) runs nothing here (the full matrix runs it)
function runtests_touched(lines, hunks)::Vector{String}
    stop = something(findfirst(l -> startswith(l, "end  # end of phase-registration block"), lines), length(lines))
    out = String[]
    for h in hunks
        h <= length(lines) || continue
        m = match(r"_wt_qa_include\((?:\"([^\"]+)\"|joinpath\(@__DIR__, \"([^\"]+)\", \"([^\"]+)\"\))\)", lines[h])
        if m !== nothing
            push!(out, m[1] !== nothing ? String(m[1]) : String(m[2]) * "/" * String(m[3]))
            continue
        end
        h < stop || continue
        k = findlast(l -> occursin(r"^\s*@pphase \"", l), lines[1:h])
        k === nothing || push!(out, match(r"@pphase \"([^\"]+)\"", lines[k])[1])
    end
    return unique(out)
end
touched_runtests(base) = runtests_touched(file_lines("test/runtests.jl"), touched_lines(base, "test/runtests.jl"))

# ---- the selections: each a decision over text (L194 runs them on fixed diffs), read from git here --
# the new-side line numbers a diff's hunks touch (`git diff -U0`); a deletion (`+a,0`, a the line
# before it) touches the lines on both sides of it, a and a + 1
function hunk_lines(diff::AbstractString)::Vector{Int}
    out = Int[]
    for m in eachmatch(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@"m, diff)
        a = parse(Int, m[1]); n = m[2] === nothing ? 1 : parse(Int, m[2])
        append!(out, n == 0 ? [a, a + 1] : a:a+n-1)
    end
    return out
end
touched_lines(base, path) = hunk_lines(git("diff", "-U0", base, "--", path))
file_lines(rel) = (p = joinpath(ROOT, rel); isfile(p) ? readlines(p) : String[])

# the probes touched lines select: a line of test/probe_corpus.jl within a probe's definition (from its
# `_c("name"` line to the next), a line of test/probe_baseline.txt naming a probe
function probes_touched(corpus, corpus_hunks, baseline, baseline_hunks)::Vector{String}
    out = String[]
    for h in corpus_hunks
        k = findlast(l -> startswith(l, "_c(\""), corpus[1:min(h, length(corpus))])
        k === nothing || push!(out, match(r"^_c\(\"([^\"]+)\"", corpus[k])[1])
    end
    for h in baseline_hunks
        h <= length(baseline) && !isempty(baseline[h]) && push!(out, first(split(baseline[h], '\t')))
    end
    return unique(out)
end
touched_probes(base) = probes_touched(file_lines("test/probe_corpus.jl"), touched_lines(base, "test/probe_corpus.jl"),
                                      file_lines("test/probe_baseline.txt"), touched_lines(base, "test/probe_baseline.txt"))

# the smoke groups touched lines of one smoke file select: a line inside a group's list (from its
# `_g("name", Any[` / `_xf("name", Any[` line to the list's closing `])`, or the line alone for a
# one-line group, `_g("name", gen())`) is that group's. In test/smoke.jl itself (`harness`), a line
# between groups (a helper or a struct a case uses) is the next group's, and one before the first
# group or after the last (the harness, which the core runs) none's; a case file smoke.jl includes
# has no harness: a line in no group's list (its generators and helpers) is every group's it defines
function groups_touched(lines, hunks, harness::Bool)::Vector{String}
    starts = Tuple{Int,String}[]
    for (i, l) in enumerate(lines)
        m = match(r"^_(?:g|xf|lazy_g|lazy_xf)\(\"([^\"]+)\"", l)
        m === nothing || push!(starts, (i, String(m[1])))
    end
    spans = map(starts) do (i, g)
        j = occursin(r"\)\s*$", lines[i]) ? i : findnext(l -> rstrip(l) == "])", lines, i)
        (i, j === nothing ? i : j, g)
    end
    out = String[]
    for h in hunks
        k = findfirst(s -> s[1] <= h <= s[2], spans)
        if k === nothing && !harness
            append!(out, last.(spans))
            continue
        end
        k === nothing && !isempty(spans) && h > spans[1][1] && (k = findfirst(s -> s[1] > h, spans))
        k === nothing || push!(out, spans[k][3])
    end
    return unique(out)
end
# the groups a change to test/smoke.jl, the case files it includes and the files its lazy groups are
# built from (`_lazy_g("<group>", "<file>")`: test/registry_cases.jl's generated groups, every one of
# them touched by a change to that file; the matrix-only ones then dropped by the caller) selects
function touched_smoke_groups(base)::Vector{String}
    path = "test/smoke.jl"
    isfile(joinpath(ROOT, path)) || return String[]
    smk = read(joinpath(ROOT, path), String)
    out = String[]
    for m in eachmatch(r"^_lazy_(?:g|xf)\(\"([^\"]+)\", \"([^\"]+)\"\)"m, smk)
        isempty(touched_lines(base, "test/" * m[2])) || push!(out, String(m[1]))
    end
    for file in [path; ["test/" * m[1] for m in eachmatch(r"^include\(joinpath\(@__DIR__, \"([^\"]+)\"\)\)"m, smk)]]
        isfile(joinpath(ROOT, file)) && append!(out, groups_touched(file_lines(file), touched_lines(base, file), file == path))
    end
    return unique(out)
end

# the TLC instances a change's files select: a changed <Name>.tla, MC<Name>*.tla or MC<Name>*.cfg
# selects every MC<Name>*.cfg, the deep ones apart (the full run checks those)
function tlc_select(changed, cfgs, deep)::Tuple{Vector{String},Vector{String}}
    want = String[]
    for f in changed
        startswith(f, "dev/formal/") && !startswith(f, "dev/formal/nightly/") || continue
        b = basename(f)
        (endswith(b, ".tla") || endswith(b, ".cfg")) || continue
        stem = replace(replace(splitext(b)[1], r"^MC" => ""), r"Broken$" => "")
        append!(want, filter(c -> startswith(c, "MC" * stem), cfgs))
    end
    want = unique(want)
    return filter(c -> !(c in deep), want), filter(c -> c in deep, want)
end
function tlc_instances(changed)
    fdir = joinpath(ROOT, "dev", "formal")
    m = match(r"DEEP=\"\$\{TLC_DEEP:-([^}]*)\}\"", read(joinpath(fdir, "run_tlc.sh"), String))
    return tlc_select(changed, sort(filter(f -> startswith(f, "MC") && endswith(f, ".cfg"), readdir(fdir))),
                      m === nothing ? String[] : String.(split(m[1])))
end

# a changed file's row of test/block_groups.tsv: its own, else the longest directory row (`dir/`)
# holding it; nothing when none does
function row_for(f, rows)
    hits = filter(r -> f == first(r) || (endswith(first(r), "/") && startswith(f, first(r))), rows)
    return isempty(hits) ? nothing : last(hits[argmax(map(r -> length(first(r)), hits))])
end

const BLOCK_LINES = 40
# the name a top-level definition gives, or nothing (a struct, a const, a using)
function defname(ex)
    ex isa Expr || return nothing
    ex.head === :macrocall && return defname(ex.args[end])
    if ex.head in (:function, :(=)) && !isempty(ex.args)
        sig = ex.args[1]
        while sig isa Expr && sig.head in (:where, :(::))
            sig = sig.args[1]
        end
        sig isa Expr && sig.head === :call || return nothing
        f = sig.args[1]
        f isa Expr && f.head === :curly && (f = f.args[1])
        return string(f)
    end
    return nothing
end

# line => piece key, for every line of every top-level form of a src file's text (`rel` its path),
# each form running to the line before the next (inside a module, its forms): a definition's
# `<rel>:<name>@<line>#<k>`, the k-th BLOCK_LINES-line piece from its first line, by its line so
# two methods of one name are two pieces (A19C1 (c)); a `const` over more than
# one line (a lowering table) each line its own key, `<rel>:<line>`, so an entry's coverage is its
# own; any other form (a struct, a macro call, a `using`) `<rel>:L<first line>#<k>` — so no line of
# code is outside a piece (A20C12). test/block_impact.jl's unit of measure, and the gate's
function line_keys(text::AbstractString, rel::AbstractString)::Dict{Int,String}
    out = Dict{Int,String}()
    function walk(args, stop)
        items = [(args[i].line, args[i+1]) for i in 1:length(args)-1 if args[i] isa LineNumberNode]
        for (k, (l, ex)) in enumerate(items)
            last = k < length(items) ? items[k+1][1] - 1 : stop
            if ex isa Expr && ex.head === :module
                walk(ex.args[3].args, last)
                continue
            end
            if ex isa Expr && ex.head === :const && last > l
                for x in l:last
                    out[x] = "$rel:$x"
                end
                continue
            end
            n = defname(ex)
            label = n === nothing ? "L$l" : "$n@$l"
            for x in l:last
                out[x] = "$rel:$label#$((x - l) ÷ BLOCK_LINES)"
            end
        end
    end
    walk(Meta.parseall(text; filename = rel).args, count(==('\n'), text) + 1)
    return out
end

# line => (table, entry key's text) for each line of a lowering table's literal in a src file's text:
# a `const NAME = Dict…(…)` over more than one line, each `key => value` entry's lines, over as many
# lines as its parse needs (the key's text as Julia prints its parse) (A20C12)
function table_entry_keys(text::AbstractString, rel::AbstractString)::Dict{Int,Tuple{String,String}}
    out = Dict{Int,Tuple{String,String}}()
    lines = split(text, '\n')
    parsed = Meta.parseall(text; filename = rel).args
    items = [(parsed[i].line, parsed[i+1]) for i in 1:length(parsed)-1 if parsed[i] isa LineNumberNode]
    for (k, (l, ex)) in enumerate(items)
        last = k < length(items) ? items[k+1][1] - 1 : length(lines)
        (ex isa Expr && ex.head === :const && ex.args[1] isa Expr && ex.args[1].head === :(=) && last > l) || continue
        name = string(ex.args[1].args[1])
        x = l + 1
        while x <= last
            t = strip(lines[x])
            (isempty(t) || startswith(t, "#")) && (x += 1; continue)
            # the entry starting here, over as many lines as its parse needs, a trailing comment and
            # comma dropped
            entry(a, b) = rstrip(replace(join(strip.(lines[a:b]), '\n'), r"\s+#[^\"\n]*$" => ""), ',')
            j = x
            e = Meta.parse(entry(x, j); raise = false)
            while e isa Expr && e.head === :incomplete && j < last
                j += 1
                e = Meta.parse(entry(x, j); raise = false)
            end
            # an entry's trailing comma before a comment parses as a one-tuple
            (e isa Expr && e.head === :tuple && length(e.args) == 1) && (e = e.args[1])
            if e isa Expr && e.head === :call && length(e.args) == 3 && e.args[1] === :(=>)
                for y in x:j
                    out[y] = (name, string(e.args[2]))
                end
            end
            x = j + 1
        end
    end
    return out
end

# test/block_tables.tsv: `<file><TAB><table><TAB><entry key's text><TAB><group/case ...>`, the
# generated cases that case each lowering-table entry (test/block_impact.jl --tables writes it)
function read_tables()::Dict{Tuple{String,String,String},Vector{String}}
    out = Dict{Tuple{String,String,String},Vector{String}}()
    isfile(TABLES_PATH) || error("block: test/block_tables.tsv is missing (test/block_impact.jl --tables writes it)")
    for (n, l) in enumerate(eachline(TABLES_PATH))
        (isempty(l) || startswith(l, "#")) && continue
        f = split(l, '\t')
        length(f) == 4 || error("test/block_tables.tsv:$n: not \"<file>\t<table>\t<key>\t<cases>\": $l")
        out[(String(f[1]), String(f[2]), String(f[3]))] = String.(split(f[4]))
    end
    return out
end

# the old-side and new-side line numbers a diff's hunks change (`git diff -U0`)
function hunk_sides(diff::AbstractString)::Tuple{Vector{Int},Vector{Int}}
    old = Int[]; new = Int[]
    for m in eachmatch(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"m, diff)
        a = parse(Int, m[1]); na = m[2] === nothing ? 1 : parse(Int, m[2])
        b = parse(Int, m[3]); nb = m[4] === nothing ? 1 : parse(Int, m[4])
        append!(old, a:a+na-1); append!(new, b:b+nb-1)
    end
    return old, new
end

# the lowering-table entries a change touches, (file, table, key text): each changed line of a
# table's literal, on the head's side and, for a deleted or changed line, the base's (a decision
# over text, L194 runs it on fixed texts)
function table_entries_touched(rel, base_text, head_text, diff)::Vector{Tuple{String,String,String}}
    old, new = hunk_sides(diff)
    out = Tuple{String,String,String}[]
    for (text, ls) in ((base_text, old), (head_text, new))
        keys_of = table_entry_keys(text, rel)
        for x in ls
            haskey(keys_of, x) && push!(out, (rel, keys_of[x]...))
        end
    end
    return unique(out)
end
function touched_table_entries(base, changed)::Vector{Tuple{String,String,String}}
    out = Tuple{String,String,String}[]
    for f in changed
        (startswith(f, "src/") && endswith(f, ".jl")) || continue
        base_text = gitok("cat-file", "-e", "$base:$f") ? git("show", "$base:$f") : ""
        head_text = isfile(joinpath(ROOT, f)) ? read(joinpath(ROOT, f), String) : ""
        append!(out, table_entries_touched(f, base_text, head_text, git("diff", "-U0", base, "--", f)))
    end
    return unique(out)
end

# the generated cases the changed table entries run, and the failures: an entry of a table
# test/block_tables.tsv cases with no row of its own, and an entry of a table it cases nowhere (a
# table whose entries table_entry_keys keys, `key => value` a line, is a lowering table: a change to
# it that runs no case is a change no stage checks, A22E3), each naming its table (a decision over
# text, L194 runs it on fixed inputs)
function table_cases(entries, tables::AbstractDict)::Tuple{Vector{String},Vector{String}}
    cases = String[]; fails = String[]
    known = Set((f, t) for (f, t, _) in keys(tables))
    for e in entries
        c = get(tables, e, nothing)
        if c !== nothing
            append!(cases, c)
        elseif (e[1], e[2]) in known
            push!(fails, "the entry $(e[3]) of $(e[2]) ($(e[1])) has no generated case in test/block_tables.tsv: " *
                         "re-record it with test/block_impact.jl --tables")
        else
            push!(fails, "the entry $(e[3]) of $(e[2]) ($(e[1])) changed, and no generator cases the table $(e[2]): the change runs " *
                         "no case of it. Give $(e[2]) a generator in test/registry_cases.jl and its rows with test/block_impact.jl --tables (A22E3)")
        end
    end
    return unique(cases), fails
end

# how far src/ had moved, under the change, since test/block_groups.tsv was measured (its `measured`
# row, the src tree test/block_impact.jl ran): the pieces of src that differ between that tree and
# `now` (the change's base's src tree), keyed on `now`'s text, a removed file one piece; nothing when
# the measured tree is unknown here
function pieces_moved(measured, now)::Union{Nothing,Int}
    occursin(r"^[0-9a-f]{40}$", measured) && gitok("cat-file", "-e", measured) && !isempty(now) || return nothing
    moved = Set{String}()
    for f in split(git("diff", "--name-only", measured, now), '\n'; keepempty = false)
        gitok("cat-file", "-e", "$now:$f") || (push!(moved, "src/$f:(removed)"); continue)
        keys_of = line_keys(git("show", "$now:$f"), "src/" * f)
        for h in hunk_lines(git("diff", "-U0", measured, now, "--", f))
            haskey(keys_of, h) && push!(moved, keys_of[h])
        end
    end
    return length(moved)
end

# the staleness budget: a change to src/ is judged by a map that measured a tree at most this many
# pieces of src away from the change's base; past it the map is re-recorded, off the landing path
# (a measurement of about 34 minutes, at JLRUN_PRIO=5, landing as its own commit of
# test/block_groups.tsv), never by the landing (A20C13)
const STALE_PIECES = 8
const RERECORD = "julia --code-coverage=@src --code-coverage=\"\$TMPDIR/block_impact.info\" --project=. test/block_impact.jl " *
                 "(off the landing path, at JLRUN_PRIO=5; test/block_groups.tsv lands as its own commit)"

# a stale map fails a change it cannot judge (a decision over text, L194 runs it on fixed inputs):
# for a change to src/, `moved` (pieces_moved at the change's base) past STALE_PIECES or unknown,
# and each changed line of code (`touched`, the head's line numbers) in no piece of the head's text;
# for a change to ext/, which no map measures, always (A20C13)
function stale_map(moved::Union{Nothing,Int}, measured, changed, head_texts::AbstractDict, touched::AbstractDict)::Vector{String}
    fails = String[]
    exts = filter(f -> startswith(f, "ext/"), changed)
    isempty(exts) || push!(fails, "ext/ is measured by no map (test/block_impact.jl measures src/): $(join(exts, ", ")) cannot be judged here")
    any(f -> startswith(f, "src/"), changed) || return fails
    if moved === nothing
        push!(fails, "test/block_groups.tsv measured src tree $(first(measured, 8)), which this repository does not hold: re-record it: $RERECORD")
    elseif moved > STALE_PIECES
        push!(fails, "test/block_groups.tsv is stale: $moved pieces of src changed between the src tree it measured ($(first(measured, 8))) " *
                     "and this change's base, over the budget of $STALE_PIECES: re-record it: $RERECORD")
    end
    for (f, text) in head_texts
        keys_of = line_keys(text, f)
        lines = split(text, '\n')
        for x in get(touched, f, Int[])
            1 <= x <= length(lines) || continue
            t = strip(lines[x])
            (isempty(t) || startswith(t, "#") || haskey(keys_of, x)) && continue
            push!(fails, "$f:$x is a line of code in no piece of the map (dev/block.jl line_keys)")
        end
    end
    return fails
end

# ---- one stage ------------------------------------------------------------------------------
mutable struct Stage
    name::String
    cmd::Cmd
    log::String
    wall::Float64
    cpu::Float64
    exit::Int
end
Stage(name, cmd, log) = Stage(name, cmd, log, NaN, NaN, -1)

# runs the stage under /usr/bin/time (its CPU seconds and its children's), output to its log
function start!(s::Stage)
    tfile = s.log * ".time"
    io = open(s.log, "w")
    timed = Cmd(Cmd(vcat(["/usr/bin/time", "-p", "-o", tfile], s.cmd.exec)); env = s.cmd.env, dir = s.cmd.dir)
    t0 = time()
    p = run(pipeline(ignorestatus(timed); stdout = io, stderr = io); wait = false)
    return @async begin
        wait(p)
        s.wall = time() - t0
        close(io)
        s.exit = p.exitcode
        t = isfile(tfile) ? read(tfile, String) : ""
        u = match(r"user\s+([0-9.]+)", t); y = match(r"sys\s+([0-9.]+)", t)
        s.cpu = u === nothing || y === nothing ? NaN : parse(Float64, u[1]) + parse(Float64, y[1])
        rm(tfile; force = true)
        s
    end
end

lastline(path, rx) = (ls = filter(l -> occursin(rx, l), readlines(path)); isempty(ls) ? "" : ls[end])

# ---- the machine's speed while the stages run -------------------------------------------------
# A fixed piece of work, timed every quarter second for the whole run in this process, which the
# stages' processes share the cores with: its median against its best is the machine's slowdown
# factor while they ran (other work on the machine, the stages on each other, a stage moved to an
# efficiency core: on this machine's 4 performance and 6 efficiency cores one stage's CPU seconds
# measured 2.4 times its quiet value under the agents' load). A stage's time is compared with its
# best divided by that factor, so a slower machine is not a slower stage, and a stage that does
# more work, or waits longer (a planted sleep), is.
# The work is the stages' kind: lowering, inferring and optimizing a new small function each time,
# pointer-chasing and allocating as compiling does (a vectorized arithmetic loop measured 1.7 where a
# stage slowed 2.9 times, the cores it ran on being slower ones as well as shared).
const CALIBRATION_MODULE = Module(:BlockCalibration)
const CALIBRATION_N = Ref(0)
function calibration_work()
    k = (CALIBRATION_N[] += 1)
    f = Core.eval(CALIBRATION_MODULE, :(function (x::Int)
        s = 0
        for i in 1:x
            s += i % $k == 0 ? i : (i < $k ? -1 : 2)
        end
        return string(s, $k)
    end))
    return length(Base.code_typed(f, (Int,); optimize = true))
end
function calibrate!(samples::Vector{Float64}, done::Ref{Bool})
    for _ in 1:3; calibration_work(); end   # compiled before the first sample
    while !done[]
        t = time_ns(); for _ in 1:4; calibration_work(); end; push!(samples, (time_ns() - t) / 1e9)
        sleep(0.25)
    end
end

fmt(x) = isnan(x) ? "  --" : string(round(x; digits = 1))
median(v) = (c = sort(v); isempty(c) ? NaN : c[(length(c) + 1) ÷ 2])

# ---- the decisions (L195 runs them) -------------------------------------------------------------
# the machine's slowdown factor: the calibration's median over its best, 1 at best, never below
machine_factor(calib, best_calib) = isnan(best_calib) || isnan(calib) || best_calib <= 0 ? 1.0 : max(1.0, calib / best_calib)
# the run's verdict: red when a check fails; no verdict only when the machine cannot judge for a
# reason of its tools or the tree (a tool missing, the tree changed during the run), never for load;
# green when the run was cold or past the factor cap and its checks pass, its timing unjudged (a cold
# run measures compiling the change; past the cap the machine's times say nothing of the change's,
# its missed budgets included: `dev/land.sh land` lands on it, judges a cold landing's timing by a
# warm run right after, and prints the unjudged streak, L198); red when a budget or a best is missed
# on a run neither cold nor past the cap; green otherwise
run_verdict(fails, tfails, efails, cold) =
    !isempty(fails) ? "red" : !isempty(efails) ? "none" : cold ? "green" : !isempty(tfails) ? "red" : "green"
# the timing failures a run is judged on: every budget and best missed, none on a cold run or one past
# the cap (its timing unjudged, the budgets it missed named in its timing)
timing_failures(tfails, sfails, capped, cold) = cold || capped ? String[] : vcat(tfails, sfails)
# a stage's scaled time slower than its best by more than 15% and more than 0.3 s
slower(scaled, best) = !isnan(best) && scaled > best * (1 + SLOWER_FRACTION) && scaled - best > SLOWER_SECONDS
# the timing a change is judged by, against its base's (L195 runs it): every budget and best the base
# holds is still held, a budget no higher, a best no higher once both are put at one calibration (a
# best is held as best / calibration; the update rounds a best to 0.01 s); the problems, if any
function timing_against_base(timing, base_timing, exempt_stages = String[])::Vector{String}
    out = String[]
    for (k, b) in base_timing["budget"]
        haskey(timing["budget"], k) || (push!(out, "timing: budget $k removed (the base holds $b)"); continue)
        timing["budget"][k] <= b || push!(out, "timing: budget $k raised to $(timing["budget"][k]) (the base holds $b): a budget is lowered, never raised")
    end
    bc = get(base_timing["best"], "calibration", NaN); c = get(timing["best"], "calibration", NaN)
    for (k, b) in base_timing["best"]
        haskey(timing["best"], k) || (push!(out, "timing: best $k removed (the base holds $b)"); continue)
        k == "calibration" && continue
        lim = isnan(bc) || isnan(c) ? b : b * c / bc
        first(split(k, '@')) in exempt_stages || timing["best"][k] <= lim + 0.006 ||
            push!(out, "timing: best $k is $(timing["best"][k]), above the base's $b at this calibration ($(round(lim; digits = 3))): a best is lowered, never raised")
    end
    return out
end
const STAGE_NAMES = ("load", "ratchet", "smoke-core", "smoke-batch", "smoke-1.13", "probes", "tests", "tlc")
# the commit's declared correctness fix: the MARCH row its `Timing:` line cites, which the change
# adds (a `+` line of `git diff <base>..HEAD -- dev/MARCH.md`) under a number the base's MARCH does not
# have (an existing row, edited, exempts nothing, A20P26) and which names the stages the fix leaves
# slower; the exemption's text and those stages (A19P7)
function timing_exemption(msg::AbstractString, march_diff::AbstractString, base_march::AbstractString)::Tuple{String,Vector{String}}
    m = match(r"^Timing: correctness fix \(MARCH (13\.[0-9]+)\)"m, msg)
    m === nothing && return ("", String[])
    occursin(Regex("^\\| " * replace(m[1], "." => "\\.") * " \\|", "m"), base_march) &&
        error("block: the commit's Timing line cites MARCH $(m[1]), a row the base already has: an edited row exempts nothing; the exemption is a new row")
    row = match(Regex("^\\+\\| " * replace(m[1], "." => "\\.") * " \\|(.*)\$", "m"), march_diff)
    row === nothing && error("block: the commit's Timing line cites MARCH $(m[1]), a row this change does not add to dev/MARCH.md")
    stages = [s for s in STAGE_NAMES if occursin(Regex("(?<![a-z0-9.-])" * replace(s, "." => "\\.") * "(?![a-z0-9.-])"), row[1])]
    isempty(stages) && error("block: MARCH $(m[1]), the row the Timing line cites, names no stage of the gate ($(join(STAGE_NAMES, ", ")))")
    return ("correctness fix, MARCH $(m[1]) ($(join(stages, ", ")))", stages)
end

function main(args)
    TOML = Base.require(TOML_ID)
    t_start = time()
    cd(ROOT)
    loadavg = collect(Sys.loadavg())
    head = git("rev-parse", "HEAD"); tree = git("rev-parse", "HEAD^{tree}")
    clean = isempty(git("status", "--porcelain", "--untracked-files=normal"))
    base = change_base(args)
    changed = changed_files(base)
    core, probe_core, matrix, rows, measured = read_map()
    families = qa_families()
    unmapped = String[]
    mapped = String[]
    tests = String[]
    v113 = String[]
    for f in changed
        # a changed QA family runs itself, test/runtests.jl its changed families and phases, and a
        # test file a stage runs is run by that stage; any other changed test file, like a changed
        # src or ext file, is run by what its row names
        if startswith(f, "test/") && endswith(f, ".jl")
            name = f[length("test/")+1:end]
            name in families && name != "parity_ratchet.jl" && (push!(tests, name); continue)
            f == "test/runtests.jl" && (append!(tests, touched_runtests(base)); continue)
            f in STAGE_TESTS && continue
        elseif !(startswith(f, "src/") || startswith(f, "ext/")) && !any(r -> first(r) == f, rows)
            continue
        end
        row = row_for(f, rows)
        row === nothing && (push!(unmapped, f); continue)
        append!(mapped, row[1]); append!(tests, row[2]); append!(v113, row[3])
    end
    tests = unique(tests)
    # a changed lowering-table entry runs the generated cases that case it, whatever group holds
    # them (test/block_tables.tsv, A20C12); an entry with none fails, as does an entry of a table no
    # generator cases (A22E3)
    cases, tablefails = table_cases(touched_table_entries(base, changed), read_tables())
    case_groups = unique([String(first(split(c, '/'))) for c in cases])
    # a matrix-only group runs in the non-blocking matrix alone, never in a stage here, but for the
    # cases a changed table entry names
    touched = touched_smoke_groups(base)
    newgroups = setdiff(touched, matrix)
    batch = unique(vcat(setdiff(unique(vcat(mapped, newgroups)), core, matrix), case_groups))
    # on 1.13: the batch's own cases, and the groups a changed file's version-dependent output needs
    smoke113 = setdiff(unique(vcat(newgroups, v113)), matrix)
    probes = unique(vcat(probe_core, touched_probes(base)))
    tlc, tlc_deep = tlc_instances(changed)
    timing = Base.invokelatest(TOML.parsefile, BEST_PATH)
    budget = timing["budget"]; best = timing["best"]; best_cpu = timing["best_cpu"]
    msg = git("log", "-1", "--format=%B", "HEAD")
    # a Timing line the change does not back with its own MARCH row is a failure of the change
    exempt_problem = ""
    exempt, exempt_stages = try
        timing_exemption(msg, git("diff", "$base..HEAD", "--", "dev/MARCH.md"),
                         gitok("cat-file", "-e", "$base:dev/MARCH.md") ? git("show", "$base:dev/MARCH.md") : "")
    catch err
        exempt_problem = sprint(showerror, err)
        ("", String[])
    end
    # the budgets and bests are this tree's file, each no looser than the base's (A19P6): a change
    # cannot loosen what judges it
    base_text = gitok("cat-file", "-e", "$base:dev/timing_best.toml") ? git("show", "$base:dev/timing_best.toml") : ""
    loosened = isempty(base_text) ? String[] : timing_against_base(timing, Base.invokelatest(TOML.parse, base_text), exempt_stages)

    notes = String[]
    fails = String[]    # the change fails: red
    tfails = String[]   # over a budget: red, unless the runner was cold
    sfails = String[]   # slower than a best: red, unless the runner was cold or the timing is unjudged
    efails = String[]   # the machine cannot judge: no verdict
    moved = pieces_moved(measured, gitok("rev-parse", "$base:src") ? git("rev-parse", "$base:src") : "")
    push!(notes, moved === nothing ? "test/block_groups.tsv: measured on src tree $(first(measured, 8)), which this repository does not hold" :
                 "test/block_groups.tsv: measured on src tree $(measured[1:8]); $moved pieces of src changed since, at the change's base " *
                 "(a change to src/ fails past $STALE_PIECES)")
    # a narrower change than the merge base's selects less; such a record is not one land.sh takes
    "--base" in args && push!(notes, "the change is taken from --base $(base[1:8]): dev/land.sh merge takes a record of the change from its merge base only")
    append!(fails, loosened)
    isempty(exempt_problem) || push!(fails, exempt_problem)
    isempty(base_text) && push!(notes, "timing: the base has no dev/timing_best.toml to hold this one to")
    isempty(unmapped) || push!(fails, "no row in test/block_groups.tsv for $(join(unmapped, ", ")): add one naming the smoke groups and QA families that exercise it")
    append!(fails, tablefails)
    isempty(cases) || push!(notes, "the changed lowering-table entries run their generated cases: $(join(cases, ' '))")
    head_texts = Dict(f => read(joinpath(ROOT, f), String) for f in changed
                      if startswith(f, "src/") && endswith(f, ".jl") && isfile(joinpath(ROOT, f)))
    append!(fails, stale_map(moved, measured, changed, head_texts, Dict(f => touched_lines(base, f) for f in keys(head_texts))))

    mkpath(joinpath(RECORD_DIR, "logs"))
    logdir = mktempdir(joinpath(RECORD_DIR, "logs"); prefix = tree[1:12] * "-", cleanup = false)
    logf(n) = joinpath(logdir, n * ".log")

    # the wasm engine is CI's: the Node major ci.yml's node-version names (dev/lanes.sh's rule)
    node_major = something(match(r"node-version: *'?([0-9]+)", read(joinpath(ROOT, ".github", "workflows", "ci.yml"), String)), (nothing,))[1]
    for pre in ("/opt/homebrew/opt/node@$node_major/bin", "/usr/local/opt/node@$node_major/bin")
        isfile(joinpath(pre, "node")) && (ENV["PATH"] = pre * ":" * ENV["PATH"]; break)
    end
    node = try readchomp(`node --version`) catch; "" end
    startswith(node, "v$node_major.") || push!(efails, "the wasm engine is node $(isempty(node) ? "(none)" : node), not CI's Node $node_major (brew install node@$node_major)")
    java = let out = IOBuffer()
        success(pipeline(ignorestatus(`java -version`); stdout = out, stderr = out)) ? strip(first(split(String(take!(out)), '\n'))) : ""
    end

    # every stage starts now, side by side
    samples = Float64[]; done = Ref(false)
    calibrator = @async calibrate!(samples, done)
    stages = Stage[]
    tasks = Task[]
    jl = `julia --startup-file=no`
    removed = sort([k for k in keys(ENV) if foreign_var(k)])
    isempty(removed) || push!(notes, "env: the caller's $(join(removed, ", ")) removed from every stage")
    smokeenv = stage_env(Dict("WT_SMOKE_TIMES" => "1", "WT_SMOKE_EXACT" => "1"))
    # the batch's own: a changed table entry's cases alone of the groups they name (WT_SMOKE_CASES)
    batchenv = stage_env(Dict("WT_SMOKE_TIMES" => "1", "WT_SMOKE_EXACT" => "1", "WT_SMOKE_CASES" => join(cases, ' ')))
    launch!(s) = (push!(stages, s); push!(tasks, start!(s)); s)
    # --warm: this tree's runner (dev/block_runner.jl), versioned with the tree and named in the record
    # by its blob; a runner from outside the tree is not one the record can name
    haskey(ENV, "WT_BLOCK_RUNNER") && error("block: WT_BLOCK_RUNNER is retired: `bash dev/gate.sh --block --warm` runs this tree's runner, dev/block_runner.jl")
    runner = "--warm" in args ? `julia --startup-file=no dev/block_runner.jl run` : ``
    runner_blob = isempty(runner) ? "" : git("hash-object", "dev/block_runner.jl")
    # under the runner every stage holds its own best and budget, `<stage>@warm`
    bestkey(name) = !isempty(runner) ? name * "@warm" : name
    ld = launch!(Stage("load", setenv(`$jl --project=. -e 'using WasmTarget; print(VERSION)'`, stage_env()), logf("load")))
    rat = launch!(Stage("ratchet", setenv(`$jl -O0 --project=. test/parity_ratchet.jl`, stage_env()), logf("ratchet")))
    probe_env(c) = stage_env(Dict("WT_PROBE_ONLY" => join(c, ' ')))
    # the QA families and phases the change selects, run as test/runtests.jl runs them in their shard
    tests_env = stage_env(Dict("WT_QA_ONLY" => join(tests, '\n')))
    if isempty(runner)
        launch!(Stage("smoke-core", setenv(`$jl --project=. -L dev/block_jit.jl test/smoke.jl $core`, smokeenv), logf("smoke-core")))
        isempty(batch) ||
            launch!(Stage("smoke-batch", setenv(`$jl --project=. -L dev/block_jit.jl test/smoke.jl $batch`, batchenv), logf("smoke-batch")))
        # the probes, PROBE_CHUNK to a process (each pays its own ~20 s of compiling the compiler)
        chunks = [probes[i:min(i + PROBE_CHUNK - 1, end)] for i in 1:PROBE_CHUNK:length(probes)]
        for (i, c) in enumerate(chunks)
            launch!(Stage("probes $i/$(length(chunks))", setenv(`$jl -O0 --project=. test/probe_bytes.jl`, probe_env(c)), logf("probes-$i")))
        end
        isempty(tests) || launch!(Stage("tests", setenv(`$jl --project=. test/runtests.jl`, tests_env), logf("tests")))
    else
        # the warm runner (--warm): one process with this tree's code, its stages one after another
        chunks = [probes]
        chain = [Stage("smoke-core", setenv(`$runner test/smoke.jl $core`, smokeenv), logf("smoke-core"))]
        isempty(batch) || push!(chain, Stage("smoke-batch", setenv(`$runner test/smoke.jl $batch`, batchenv), logf("smoke-batch")))
        push!(chain, Stage("probes 1/1", setenv(`$runner test/probe_bytes.jl`, probe_env(probes)), logf("probes-1")))
        isempty(tests) || push!(chain, Stage("tests", setenv(`$runner test/runtests.jl`, tests_env), logf("tests")))
        append!(stages, chain)
        push!(tasks, @async foreach(s -> wait(start!(s)), chain))
    end
    isempty(smoke113) ||
        launch!(Stage("smoke-1.13", setenv(`julia +1.13 --startup-file=no --project=. -L dev/block_jit.jl test/smoke.jl $smoke113`, smokeenv), logf("smoke-1.13")))
    if !isempty(tlc)
        isempty(java) && push!(efails, "tlc: no working java (brew install openjdk@17)")
        # two TLC workers: the Julia stages beside it keep their cores (TLC's default takes them all)
        launch!(Stage("tlc", setenv(`bash dev/formal/run_tlc.sh`, stage_env(Dict("TLC_ONLY" => join(tlc, ' '), "TLC_WORKERS" => "2"))), logf("tlc")))
    end
    isempty(tlc_deep) || push!(notes, "tlc: deep instances $(join(tlc_deep, ' ')) are the full run's (non-blocking)")
    foreach(wait, tasks)
    total = time() - t_start
    # what the record is of, read again: a commit or an edit made while the stages ran is not what
    # they ran, so it gives no verdict and no record (A19P3)
    unchanged = git("rev-parse", "HEAD") == head && git("rev-parse", "HEAD^{tree}") == tree &&
                isempty(git("status", "--porcelain", "--untracked-files=normal")) == clean
    unchanged || push!(efails, "the tree changed while the stages ran (HEAD, or what is uncommitted): no verdict, rerun")
    done[] = true; wait(calibrator)
    jver = ld.exit == 0 ? strip(last(readlines(ld.log))) : ""
    occursin(r"^1\.12\.", jver) || push!(efails, "load: the default julia is $(isempty(jver) ? "unloadable" : jver), not 1.12")

    # the machine's slowdown factor (1 at its best, never below): the calibration's median against
    # its best, the fastest it has run (an update takes this run's lower quartile when faster, so
    # the bests it records are scaled by the factor they are later compared under)
    updating = get(ENV, "WT_TIMING_UPDATE", "") == "1"
    calib = median(samples)
    bcal = get(best, "calibration", NaN)
    fastest = isempty(samples) ? NaN : sort(samples)[max(1, length(samples) ÷ 4)]   # the lower quartile: one lucky sample is no speed
    # a best is measured on a quiet machine (1-minute load average at most the machine's CPUs): on a
    # busy one the calibration's own spread distorts the scale the bests are recorded under
    loadavg_end = collect(Sys.loadavg())
    # the machine's CPUs, every core the load average counts (Sys.CPU_THREADS is Julia's own count, 4 inside
    # the runner on this 10-core machine, so the machine's working floor read as busy)
    cpus = length(Sys.cpu_info())
    quiet = loadavg[1] <= cpus
    updating && !quiet && (updating = false; push!(notes, "WT_TIMING_UPDATE: refused, the machine is busy (load $(loadavg[1]) on $cpus CPUs): a best is measured on a quiet one"))
    if updating && !isnan(fastest) && (isnan(bcal) || fastest < bcal)
        old = bcal
        best["calibration"] = round(fastest; digits = 6)
        bcal = best["calibration"]
        # a best is held at the calibration it was recorded under: lowering the calibration lowers
        # every best in proportion in the same write, so no later factor loosens one (A19P6)
        isnan(old) || for k in collect(keys(best))
            k == "calibration" || (best[k] = round(best[k] * bcal / old; digits = 2))
        end
    end
    factor = machine_factor(calib, bcal)
    # past the cap the machine's scaled times say nothing of the change's: the stages are not compared
    # with their bests (the timing is unjudged), the budgets and the checks still are
    capped = factor > FACTOR_CAP
    capped && push!(notes, "timing unjudged: the machine was $(round(factor; digits = 2)) times slower than its best while the stages ran, past the cap of $FACTOR_CAP: no stage is compared with its best on this run")
    # a best not recorded bounds nothing: outside WT_TIMING_UPDATE it fails, as a ratchet with no
    # baseline line does (test/parity_ratchet.jl); the update records it
    isnan(bcal) && (updating ? push!(notes, "calibration: no best, recorded by this update") :
                    push!(fails, "calibration: no best in dev/timing_best.toml (WT_TIMING_UPDATE=1 records it)"))

    # ---- verdicts ----
    res = Dict{String,Any}()   # stage => fields for the record
    # each stage's own variables (the only WT_*, TLC_* the stage saw)
    own_of = Dict{String,Vector{String}}()
    for s in stages
        k = startswith(s.name, "probes") ? "probes" : s.name
        own_of[k] = sort(unique(vcat(get(own_of, k, String[]), [e for e in something(s.cmd.env, String[]) if foreign_var(first(split(e, '=')))])))
    end
    function judge!(name, wall, cpu, ok, detail; command = "", exitcode = 0, fixed = true)
        b = get(budget, bestkey(name), get(budget, name, nothing))   # a warm runner's own budget first
        runs = any(f -> any(p -> startswith(f, p), get(STAGE_INPUTS, name, ["src/"])), changed)
        v = ok ? "ok" : "FAIL"
        ok || push!(fails, "$name: $detail")
        scaled = wall / factor
        if b !== nothing && wall > b
            push!(tfails, "$name: $(fmt(wall)) s of wall, over its budget of $b s"); v = "OVER BUDGET"
        end
        bkey = bestkey(name)
        bw = get(best, bkey, NaN)
        if name in RATCHETED && fixed && isnan(bw)
            updating ? push!(notes, "$bkey: no best, recorded by this update") :
                push!(fails, "$bkey: no best in dev/timing_best.toml (WT_TIMING_UPDATE=1 records it)")
        end
        if name in RATCHETED && ok && fixed && slower(scaled, bw)
            why = "$(fmt(scaled)) s at the machine's best speed ($(fmt(wall)) s, factor $(round(factor; digits = 2))) against its best $(fmt(bw)) s"
            if name in exempt_stages
                push!(notes, "$name: slower, $why: declared a $exempt")
            else
                push!(sfails, "$name: more than 15% and 0.3 s slower than its best: $why"); v = capped ? "UNJUDGED" : "SLOWER"
            end
        end
        res[name] = Dict{String,Any}("command" => command, "env" => get(own_of, name, String[]), "exit" => exitcode, "wall" => round(wall; digits = 2),
                                     "scaled" => round(scaled; digits = 2), "cpu" => round(cpu; digits = 2), "verdict" => v,
                                     "detail" => detail, "runs_change" => runs, "ratcheted" => name in RATCHETED && fixed)
        b === nothing || (res[name]["budget"] = b)
        isnan(bw) || (res[name]["best"] = bw)
        haskey(best_cpu, bkey) && (res[name]["best_cpu"] = best_cpu[bkey])
    end
    cmdstr(s) = join(s.cmd.exec, ' ')
    judge!("load", ld.wall, ld.cpu, ld.exit == 0 && !isempty(jver), ld.exit == 0 ? "julia $jver" : "exit $(ld.exit) (log $(ld.log))";
           command = cmdstr(ld), exitcode = ld.exit)
    rat_bad = filter(l -> occursin(r"BROKEN|MISSING|STRAY|❌|^ERROR", l), readlines(rat.log))
    judge!("ratchet", rat.wall, rat.cpu, rat.exit == 0, rat.exit == 0 ? "every lock and ratchet holds" :
           "exit $(rat.exit): $(join(first(rat_bad, 6), " | "))";
           command = cmdstr(rat), exitcode = rat.exit)
    median_case = NaN
    for s in stages
        startswith(s.name, "smoke") || continue
        ls = readlines(s.log)
        summary = lastline(s.log, r"^smoke: ")
        m = match(r"^smoke: (\d+) passed, (\d+) wrong, (\d+) errored", summary)
        ok = s.exit == 0 && m !== nothing && parse(Int, m[1]) > 0
        bad = filter(l -> occursin(r"^\s+(WRONG|ERROR|XFAIL OUTCOME)|^smoke: no group", l), ls)
        detail = m === nothing ? "exit $(s.exit), no verdict line (log $(s.log))" : summary * (isempty(bad) ? "" : " | " * join(first(bad, 4), " | "))
        if s.name == "smoke-core"
            c = match(r"^smoke time: case median ([0-9.]+) s"m, join(ls, '\n'))
            c === nothing || (median_case = parse(Float64, c[1]))
        end
        judge!(s.name, s.wall, s.cpu, ok, detail; command = cmdstr(s), exitcode = s.exit)
    end
    if !isnan(median_case)
        b = budget["case-median"]
        res["case-median"] = Dict{String,Any}("wall" => median_case, "budget" => b, "verdict" => median_case <= b ? "ok" : "OVER BUDGET")
        median_case <= b || push!(tfails, "case-median: the core's median smoke case took $median_case s, over its budget of $b s")
    end
    pstages = filter(s -> startswith(s.name, "probes"), stages)
    if !isempty(pstages)
        n = 0; nchanged = 0; ok = true; bad = String[]
        for s in pstages
            l = lastline(s.log, r"^probe_bytes: ")
            m = match(r"^probe_bytes: (\d+) probes.*, (\d+) changed", l)
            m === nothing ? (ok = false) : (n += parse(Int, m[1]); nchanged += parse(Int, m[2]))
            s.exit == 0 || (ok = false; append!(bad, filter(l -> occursin(r"CHANGED|NEW probe|MISSING|NOT DART|NAMED GLOBAL|^probe_bytes", l), readlines(s.log))))
        end
        judge!("probes", maximum(s.wall for s in pstages), sum(s.cpu for s in pstages), ok,
               "$n probes in $(length(pstages)) process$(length(pstages) == 1 ? "" : "es"), $nchanged changed" * (isempty(bad) ? "" : " | " * join(first(bad, 6), " | "));
               command = join(["WT_PROBE_ONLY=\"$(join(c, ' '))\" " * cmdstr(s) for (s, c) in zip(pstages, chunks)], " ; "),
               exitcode = maximum(s.exit for s in pstages), fixed = probes == probe_core)
    end
    for s in stages
        s.name == "tests" || continue
        # each family and phase selected ran to its end (its WT_QA_TIME / WT_PHASE_TIME line) and the
        # process exited 0: a failing testset throws, an unknown name fails the run
        ls = readlines(s.log)
        ran = Set(String(m[1]) for m in (match(r"^WT_(?:QA|PHASE)_TIME\t[0-9.]+\t(.+)$", l) for l in ls) if m !== nothing)
        missing = filter(t -> !(t in ran), tests)
        ok = s.exit == 0 && isempty(missing)
        bad = filter(l -> occursin(r"^runtests: |Test Failed|Error During Test|^ERROR: |\| +[0-9]+ +[0-9]+ .*(Fail|Error)", l), ls)
        detail = ok ? "$(length(tests)) QA families and phases: $(join(tests, ' '))" :
            "exit $(s.exit)" * (isempty(missing) ? "" : ", did not finish $(join(missing, ' '))") * (isempty(bad) ? "" : " | " * join(first(bad, 4), " | "))
        judge!("tests", s.wall, s.cpu, ok, detail; command = "WT_QA_ONLY=\"$(join(tests, "\\n"))\" " * cmdstr(s), exitcode = s.exit, fixed = false)
    end
    for s in stages
        s.name == "tlc" || continue
        judge!("tlc", s.wall, s.cpu, s.exit == 0, s.exit == 0 ? "$(length(tlc)) instances: $(join(tlc, ' '))" :
               join(filter(l -> occursin("FAIL", l), readlines(s.log)), " | "); command = "TLC_ONLY=\"$(join(tlc, ' '))\" " * cmdstr(s), exitcode = s.exit)
    end
    tb = budget["total"]
    total > tb && push!(tfails, "total: $(fmt(total)) s of wall, over the budget of $tb s")
    # cold: a runner request was its server's first or the first after a revise (each request's first
    # line, `block_runner: warm|cold (why) <blob>`, the blob this tree's runner), or the load stage
    # built the package image; either way the run's time is compiling the change
    rstates = String[]
    for s in stages
        isempty(runner) || startswith(s.name, "smoke-1.13") || s.name in ("load", "ratchet", "tlc") || begin
            m = match(r"^block_runner: (warm|cold(?: \([^)]*\))?) ([0-9a-f]{40})$"m, read(s.log, String))
            if m === nothing
                push!(efails, "$(s.name): the runner did not state its state (is `julia dev/block_runner.jl start` running?)")
            else
                push!(rstates, String(m[1]))
                m[2] == runner_blob || push!(efails, "$(s.name): the runner serving this tree runs dev/block_runner.jl $(m[2][1:8]), not this tree's $(runner_blob[1:8]): `julia dev/block_runner.jl stop`, then start")
            end
        end
    end
    occursin("Precompiling", read(ld.log, String)) && pushfirst!(rstates, "cold (the load stage built the package image)")
    cold = any(startswith("cold"), rstates)
    runner_state = cold ? first(filter(startswith("cold"), rstates)) : isempty(runner) ? "fresh" : "warm"
    capped && !cold && append!(notes, "timing unjudged, past the cap: " .* vcat(tfails, sfails))
    cold && append!(notes, "timing unjudged, the run was cold: " .* vcat(tfails, sfails))
    judged_tfails = timing_failures(tfails, sfails, capped, cold)
    verdict = run_verdict(fails, judged_tfails, efails, cold)
    # the timing and why it is unjudged: a cold run, or a run past the cap with the budgets it missed
    # (each stage and its wall), a missed budget there the machine's by the cap's definition
    budget_missed = [string(m[1], " ", m[2]) for m in (match(r"^([a-z0-9.-]+): ([0-9.]+) s of wall", f) for f in tfails) if m !== nothing]
    timing = cold ? "unjudged (cold)" :
             capped ? "unjudged ($(isempty(budget_missed) ? "" : "budget " * join(budget_missed, " ") * " ")past cap, factor $(round(factor; digits = 2)))" :
             "judged"
    # the stages whose timing failed (over a budget or slower than a best), by name: `dev/land.sh land`
    # writes them into the landing log when its warm run after a cold landing is red
    timing_failed = sort(unique(String[first(split(f, ':')) for f in judged_tfails]))
    # the stages a check failed in, and the timing's two kinds judged under the cap (a budget missed:
    # over; a best missed: slower), by name, for the landing log's judgement of a cold landing
    stagename(f) = String(first(split(f, ':')))
    checks_failed = sort(unique(stagename.(fails)))
    timing_over = capped || cold ? String[] : sort(unique(stagename.(tfails)))
    timing_slower = capped || cold ? String[] : sort(unique(stagename.(sfails)))
    why = verdict == "green" ? (cold ? "timing unjudged: the run was $runner_state" :
                                capped ? "timing $timing" : "") : verdict == "red" ? (isempty(fails) ? "over a budget or slower than a best" : "a check fails") :
          "the machine cannot judge"
    green = verdict == "green"
    j113 = try readchomp(`julia +1.13 --startup-file=no -e 'print(VERSION)'`) catch; "" end
    isempty(smoke113) && push!(notes, "smoke-1.13: the change adds no smoke case and changes no file with 1.13 groups, so no 1.13 stage (the full run's smoke-1.13 is non-blocking)")
    isempty(intersect(touched, matrix)) ||
        push!(notes, "smoke: matrix-only $(join(intersect(touched, matrix), ' ')) run in the non-blocking matrix (test/block_groups.tsv)")

    # ---- WT_TIMING_UPDATE=1: a green run on a clean tree lowers each best it beat ----
    if updating
        if !green || timing != "judged"
            push!(notes, "WT_TIMING_UPDATE: refused, the run is not green ($verdict) or its timing is unjudged ($timing)")
        elseif !clean
            push!(notes, "WT_TIMING_UPDATE: refused, uncommitted changes (a best is measured on a committed tree)")
        else
            lowered = String[]
            push!(lowered, "calibration $(best["calibration"])")
            for k in RATCHETED
                haskey(res, k) && res[k]["ratcheted"] || continue
                w = res[k]["scaled"]; c = res[k]["cpu"]; bk = bestkey(k)
                (!haskey(best, bk) || w < best[bk]) && (best[bk] = w; push!(lowered, "$bk $w"))
                # a declared correctness fix's stage: its best is what it now takes, raised in this diff
                k in exempt_stages && w > best[bk] && (best[bk] = w; push!(lowered, "$bk $w (raised: $exempt)"))
                !isnan(c) && (!haskey(best_cpu, bk) || c < best_cpu[bk]) && (best_cpu[bk] = c)
            end
            write_best(budget, best, best_cpu)
            push!(notes, "WT_TIMING_UPDATE: " * (isempty(lowered) ? "no best beaten" : "lowered " * join(lowered, ", ")))
        end
    end

    # one record per run: the next n for this tree, never overwriting an earlier run's (A19P2)
    n = 1 + maximum((m = match(Regex("^" * tree * "-([0-9]+)\\.toml\$"), f); m === nothing ? 0 : parse(Int, m[1])) for f in readdir(RECORD_DIR); init = 0)
    path = joinpath(RECORD_DIR, "$tree-$n.toml")
    record = Dict{String,Any}(
        "tree" => tree, "head" => head, "base" => base, "clean" => clean, "env_removed" => removed,
        "verdict" => verdict, "verdict_why" => why, "timing" => timing, "timing_failed" => timing_failed, "checks_failed" => checks_failed,
        "timing_over" => timing_over, "timing_slower" => timing_slower, "failures" => vcat(fails, judged_tfails, efails), "notes" => notes,
        "run" => n, "finished" => round(time(); digits = 3), "runner_state" => runner_state,
        "total_wall" => round(total; digits = 2), "total_budget" => tb,
        "machine_factor" => round(factor; digits = 3), "calibration" => isnan(calib) ? 0.0 : round(calib; digits = 6),
        "calibration_samples" => length(samples), "calibration_fastest" => isnan(fastest) ? 0.0 : round(fastest; digits = 6),
        "load_average" => loadavg, "load_average_end" => loadavg_end, "cpus" => cpus,
        "julia" => jver, "julia_113" => j113, "node" => node, "java" => java,
        "changed" => changed, "smoke_core" => core, "smoke_batch" => batch, "smoke_new" => newgroups, "smoke_113" => smoke113, "tests" => tests,
        "probes" => probes, "tlc" => tlc, "timing_exempt" => exempt, "runner" => isempty(runner) ? "" : "dev/block_runner.jl $runner_blob",
        "logs" => relpath(logdir, ROOT), "stage" => res)
    if clean && unchanged
        open(io -> Base.invokelatest(TOML.print, io, record; sorted = true), path, "w")
    elseif !unchanged
        push!(notes, "not recorded: the tree changed while the stages ran")
    else
        push!(notes, "not recorded: uncommitted changes (dev/land.sh merge takes a record of a clean tree only)")
    end

    # ---- one screen ----
    println("block $(head[1:8]) (tree $(tree[1:8])) on $(base[1:8]): $(length(changed)) changed file$(length(changed) == 1 ? "" : "s")")
    println("  ", rpad("stage", 12), lpad("wall", 7), lpad("cpu", 7), lpad("scaled", 8), lpad("budget", 8), lpad("best", 7), "  verdict")
    for k in ("load", "ratchet", "smoke-core", "smoke-batch", "smoke-1.13", "probes", "tests", "tlc")
        haskey(res, k) || continue
        r = res[k]
        println("  ", rpad(k, 12), lpad(fmt(r["wall"]), 7), lpad(fmt(r["cpu"]), 7), lpad(fmt(r["scaled"]), 8),
                lpad(string(get(r, "budget", "")), 8), lpad(haskey(r, "best") ? fmt(r["best"]) : "", 7), "  ", r["verdict"], "  ", first(r["detail"], 100))
    end
    haskey(res, "case-median") && println("  case median $(res["case-median"]["wall"]) s (budget $(res["case-median"]["budget"]) s)")
    println("  smoke: core $(length(core)) groups; batch $(isempty(batch) ? "-" : join(batch, ' ')); its own $(isempty(newgroups) ? "-" : join(newgroups, ' ')); probes $(length(probes)); tests $(isempty(tests) ? "-" : join(tests, ' '))")
    println("  runner ", isempty(runner) ? "none (fresh processes)" : "dev/block_runner.jl $(runner_blob[1:8])", ": $runner_state")
    println("  total $(fmt(total)) s of $tb s; machine factor $(round(factor; digits = 2)) (load $(join(round.(loadavg; digits = 2), ' ')), ",
            "$cpus CPUs); julia $jver, +1.13 $j113, node $node")
    for n in notes; println("  note: ", n); end
    for f in vcat(fails, judged_tfails, efails); println("  FAIL ", f); end
    println(verdict == "green" ? (timing != "judged" ? "BLOCK green ($why)" : "BLOCK green") : verdict == "red" ? "BLOCK red ($why)" : "BLOCK no verdict ($why)",
            clean && unchanged ? "  → $(relpath(path, ROOT))" : "  (not recorded)")
    return verdict == "green" ? 0 : verdict == "red" ? 1 : 3
end

function write_best(budget, best, best_cpu)
    head = filter(l -> startswith(l, '#'), readlines(BEST_PATH))   # the header stays as written
    open(BEST_PATH, "w") do io
        foreach(l -> println(io, l), head)
        for (name, d) in (("budget", budget), ("best", best), ("best_cpu", best_cpu))
            println(io, "\n[", name, "]")
            for k in sort(collect(keys(d)))
                println(io, "\"", k, "\" = ", d[k])
            end
        end
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && exit(main(ARGS))
