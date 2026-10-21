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
#               batch's own cases)
#   smoke-1.13  the batch's own groups on `julia +1.13`, when it has any
#               (the smokes at Julia's default flags, so the native answer each case compares
#               against is Julia's own; dev/block_jit.jl lowers LLVM's level for WasmTarget's and
#               the compiler's own code only: at -O0 for the whole process three bit-exact cases
#               answer otherwise)
#   probes      test/probe_bytes.jl on the probe core (test/block_groups.tsv's `probes`: a cover of
#               every src function any probe runs, test/block_impact.jl) and the probes the change
#               touches, PROBE_CHUNK to a process (-O0: a probe is a hash of the module's bytes, no
#               Julia answer, and all 225 are byte-identical at -O0)
#   tlc         dev/formal/run_tlc.sh on the instances of the models the change touches (their
#               deep instances stay with the full run, run_tlc.sh's TLC_FAST list)
#
# WT_BLOCK_RUNNER=<command>: the stages that load the package (the smokes on 1.12, the probes) run,
# one after another, through a command `<command> <file> [args...]` that runs a check as `julia
# --project=. <file> [args...]` would, in a warm process already holding this tree's code (a
# session's server, stale code refused by it): compiling the compiler is then paid once per session,
# not per stage (measured under the agents' load: the smoke core 16 s and the probe core 8 s warm,
# 28 s and 12 s after an edit to a central function, against 116 s and 90 s fresh). The record names
# the runner; under it those stages are budgeted, not ratcheted (their time is the session's state),
# and the stages still fresh hold their bests as `<stage>@warm`.
#
# Hard budgets and a timing ratchet (dev/timing_best.toml): the whole run at most `total` seconds
# of wall and each stage at most its own budget; a stage whose work is fixed (load, ratchet,
# smoke-core, the probe core) more than 15% AND more than 0.3 s slower than its best fails. Times
# are scaled by the machine's speed while the stages ran (calibrate!, below): a stage's wall over
# the factor by which a fixed piece of work, timed throughout the run, was slower than its best.
# A stage that does more work or waits longer is slower; a busier machine is not. A budget or the
# total exceeded only on a slower machine (within it once scaled) is recorded, not blocking. A
# commit whose message carries `Timing: correctness fix (MARCH 13.<n>)`, a row dev/MARCH.md has,
# is recorded slower without failing. WT_TIMING_UPDATE=1 lowers each best a green run on a clean
# tree on a quiet machine beat, the calibration's too, never raises one; a stage with no best fails.
#
# The evidence record, dev/.block/<tree>.toml (git-ignored), on a clean tree only: the tree and
# commit, every command, its exit code, wall and CPU, the budgets and bests, the load average, the
# Julia, Node and Java versions, the changed files and the selections. `dev/land.sh merge` lands a
# commit only on a green record of exactly that commit.
#
#   bash dev/gate.sh --block [--base <rev>]   # the change = <rev> (default: the merge base with
#                                             # $WT_MARCH_BRANCH, wt-p0-strict-hygiene) .. the tree

# TOML is loaded where it is used (main), so test/parity_ratchet.jl can include this file for its
# decisions (L195) in an environment that does not declare it
const TOML_ID = Base.PkgId(Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76"), "TOML")

const ROOT = normpath(joinpath(@__DIR__, ".."))
const BEST_PATH = joinpath(ROOT, "dev", "timing_best.toml")
const MAP_PATH = joinpath(ROOT, "test", "block_groups.tsv")
const RECORD_DIR = joinpath(ROOT, "dev", ".block")
const PROBE_CHUNK = 60
# a stage this much slower than its best fails: more than 15% AND more than 0.3 s (RULES, Dale 2026-10-20)
const SLOWER_FRACTION = 0.15
const SLOWER_SECONDS = 0.3
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

git(args...) = readchomp(Cmd(`git -C $ROOT $args`))
gitok(args...) = success(Cmd(`git -C $ROOT $args`))

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

# test/block_groups.tsv: the `core` row (smoke groups), the `probes` row (the probe core), the
# `matrix-only` row (smoke groups the blocking tier never runs: the non-blocking matrix runs them,
# a sample of them runs here), then `<path or dir/><TAB>groups` rows
function read_map()
    core = String[]; probes = String[]; matrix = String[]; rows = Pair{String,Vector{String}}[]
    for (n, l) in enumerate(eachline(MAP_PATH))
        (isempty(strip(l)) || startswith(l, '#')) && continue
        f = split(l, '\t')
        length(f) == 2 || error("test/block_groups.tsv:$n: not \"<path><TAB><groups>\": $l")
        gs = filter(!=("-"), String.(split(f[2])))   # `-`: nothing beyond the core
        f[1] == "core" ? append!(core, gs) : f[1] == "probes" ? append!(probes, gs) :
            f[1] == "matrix-only" ? append!(matrix, gs) : push!(rows, String(f[1]) => gs)
    end
    isempty(core) && error("test/block_groups.tsv has no core row")
    isempty(probes) && error("test/block_groups.tsv has no probes row")
    isempty(intersect(core, matrix)) || error("test/block_groups.tsv: the core runs a matrix-only group, $(join(intersect(core, matrix), ", "))")
    return core, probes, matrix, rows
end

# the new-side line numbers a change touches in one file (a deletion: the line after it)
function touched_lines(base, path)::Vector{Int}
    out = Int[]
    for m in eachmatch(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@"m, git("diff", "-U0", base, "--", path))
        a = parse(Int, m[1]); n = m[2] === nothing ? 1 : parse(Int, m[2])
        append!(out, n == 0 ? [a] : a:a+n-1)
    end
    return out
end

# the probes a change touches: a probe whose definition in test/probe_corpus.jl (from its `_c("name"`
# line to the next) or whose line of test/probe_baseline.txt the change touches
function touched_probes(base)::Vector{String}
    out = String[]
    corpus = joinpath(ROOT, "test", "probe_corpus.jl")
    if isfile(corpus)
        lines = readlines(corpus)
        for h in touched_lines(base, "test/probe_corpus.jl")
            k = findlast(l -> startswith(l, "_c(\""), lines[1:min(h, length(lines))])
            k === nothing || push!(out, match(r"^_c\(\"([^\"]+)\"", lines[k])[1])
        end
    end
    bl = joinpath(ROOT, "test", "probe_baseline.txt")
    if isfile(bl)
        lines = readlines(bl)
        for h in touched_lines(base, "test/probe_baseline.txt")
            h <= length(lines) && !isempty(lines[h]) && push!(out, first(split(lines[h], '\t')))
        end
    end
    return unique(out)
end

# the groups whose lines test/smoke.jl's change touches: a changed line inside a group's list
# (from its `_g("name", Any[` / `_xf("name", Any[` line to the list's closing `])`) is that group's,
# a changed line between groups (a helper or a struct a case uses) the next group's, and one before
# the first group or after the last (the harness) none's. A case file smoke.jl includes
# (`include(joinpath(@__DIR__, "<file>"))` defining groups) has no harness: a changed line in no
# group's list (its generators and helpers) is every group's the file defines; and a file that
# builds lazy groups (`_lazy_g("<group>", "<file>")` in smoke.jl: registry_cases.jl's generated
# groups) is every one of those groups' (the matrix-only ones then dropped by the caller)
function touched_smoke_groups(base)::Vector{String}
    path = "test/smoke.jl"
    isfile(joinpath(ROOT, path)) || return String[]
    out = String[]
    local smk = read(joinpath(ROOT, path), String)
    files = [path; ["test/" * m[1] for m in eachmatch(r"^include\(joinpath\(@__DIR__, \"([^\"]+)\"\)\)"m, smk)]]
    for m in eachmatch(r"^_lazy_(?:g|xf)\(\"([^\"]+)\", \"([^\"]+)\"\)"m, smk)
        isempty(touched_lines(base, "test/" * m[2])) || push!(out, String(m[1]))
    end
    for file in files
        isfile(joinpath(ROOT, file)) || continue
        lines = readlines(joinpath(ROOT, file))
        starts = Tuple{Int,String}[]
        for (i, l) in enumerate(lines)
            m = match(r"^_(?:g|xf|lazy_g|lazy_xf)\(\"([^\"]+)\"", l)
            m === nothing || push!(starts, (i, String(m[1])))
        end
        (file == path || !isempty(starts)) || continue
        spans = map(starts) do (i, g)
            j = occursin(r"\)\s*$", lines[i]) ? i : findnext(l -> rstrip(l) == "])", lines, i)   # a one-line group: `_g("name", gen())`
            (i, j === nothing ? i : j, g)
        end
        for h in touched_lines(base, file)
            k = findfirst(s -> s[1] <= h <= s[2], spans)
            if k === nothing && file != path
                append!(out, last.(spans))   # an included case file's generators feed every group it defines
                continue
            end
            # between two groups: the next group's (a helper or a struct its cases use); before the first
            # group or after the last: the harness's, which the core runs
            k === nothing && !isempty(spans) && h > spans[1][1] && (k = findfirst(s -> s[1] > h, spans))
            k === nothing || push!(out, spans[k][3])   # past the last group: the harness, the core covers it
        end
    end
    return unique(out)
end

# the TLC instances of the models a change touches: a changed <Name>.tla, MC<Name>*.tla or
# MC<Name>*.cfg selects every MC<Name>*.cfg, less TLC_FAST's deep ones (the full run checks those)
function tlc_instances(changed)::Tuple{Vector{String},Vector{String}}
    fdir = joinpath(ROOT, "dev", "formal")
    cfgs = sort(filter(f -> startswith(f, "MC") && endswith(f, ".cfg"), readdir(fdir)))
    script = read(joinpath(fdir, "run_tlc.sh"), String)
    m = match(r"DEEP=\"\$\{TLC_DEEP:-([^}]*)\}\"", script)
    deep = m === nothing ? String[] : String.(split(m[1]))
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
# a stage's scaled time slower than its best by more than 15% and more than 0.3 s
slower(scaled, best) = !isnan(best) && scaled > best * (1 + SLOWER_FRACTION) && scaled - best > SLOWER_SECONDS
# the commit's declared correctness fix: the MARCH row its `Timing:` line cites, which must exist
function timing_exemption(msg::AbstractString, march::AbstractString)::String
    m = match(r"^Timing: correctness fix \(MARCH (13\.[0-9]+)\)"m, msg)
    m === nothing && return ""
    occursin(Regex("^\\| " * replace(m[1], "." => "\\.") * " \\|", "m"), march) ||
        error("block: the commit's Timing line cites MARCH $(m[1]), which dev/MARCH.md has no row for")
    return "correctness fix, MARCH $(m[1])"
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
    core, probe_core, matrix, rows = read_map()
    unmapped = String[]
    mapped = String[]
    for f in changed
        (startswith(f, "src/") || startswith(f, "ext/")) || any(r -> first(r) == f, rows) || continue
        hits = filter(r -> f == first(r) || (endswith(first(r), "/") && startswith(f, first(r))), rows)
        isempty(hits) && (push!(unmapped, f); continue)
        append!(mapped, last(hits[argmax(map(r -> length(first(r)), hits))]))
    end
    # a matrix-only group runs in the non-blocking matrix alone, never in a stage here
    touched = touched_smoke_groups(base)
    newgroups = setdiff(touched, matrix)
    batch = setdiff(unique(vcat(mapped, newgroups)), core, matrix)
    probes = unique(vcat(probe_core, touched_probes(base)))
    tlc, tlc_deep = tlc_instances(changed)
    timing = Base.invokelatest(TOML.parsefile, BEST_PATH)
    budget = timing["budget"]; best = timing["best"]; best_cpu = timing["best_cpu"]
    msg = git("log", "-1", "--format=%B", "HEAD")
    exempt = timing_exemption(msg, read(joinpath(ROOT, "dev", "MARCH.md"), String))

    notes = String[]
    fails = String[]
    isempty(unmapped) || push!(fails, "no row in test/block_groups.tsv for $(join(unmapped, ", ")): add one naming the smoke groups that exercise it")

    mkpath(joinpath(RECORD_DIR, "logs"))
    logdir = mktempdir(joinpath(RECORD_DIR, "logs"); prefix = tree[1:12] * "-", cleanup = false)
    logf(n) = joinpath(logdir, n * ".log")

    # the wasm engine is CI's: the Node major ci.yml's node-version names (dev/lanes.sh's rule)
    node_major = something(match(r"node-version: *'?([0-9]+)", read(joinpath(ROOT, ".github", "workflows", "ci.yml"), String)), (nothing,))[1]
    for pre in ("/opt/homebrew/opt/node@$node_major/bin", "/usr/local/opt/node@$node_major/bin")
        isfile(joinpath(pre, "node")) && (ENV["PATH"] = pre * ":" * ENV["PATH"]; break)
    end
    node = try readchomp(`node --version`) catch; "" end
    startswith(node, "v$node_major.") || push!(fails, "the wasm engine is node $(isempty(node) ? "(none)" : node), not CI's Node $node_major (brew install node@$node_major)")
    java = let out = IOBuffer()
        success(pipeline(ignorestatus(`java -version`); stdout = out, stderr = out)) ? strip(first(split(String(take!(out)), '\n'))) : ""
    end

    # every stage starts now, side by side
    samples = Float64[]; done = Ref(false)
    calibrator = @async calibrate!(samples, done)
    stages = Stage[]
    tasks = Task[]
    jl = `julia --startup-file=no`
    smokeenv = merge(ENV, Dict("WT_SMOKE_TIMES" => "1", "WT_SMOKE_EXACT" => "1"))
    launch!(s) = (push!(stages, s); push!(tasks, start!(s)); s)
    # WT_BLOCK_RUNNER: a command `R <file> [args...]` that runs a check as `julia --project=. <file>
    # [args...]` would, in a warm process holding this tree's code (the session's own: no compiling
    # the compiler per stage); its runs are the record's `runner`, and their times hold their own bests
    runner = Cmd(String.(split(get(ENV, "WT_BLOCK_RUNNER", ""))))
    # under a runner the stages it runs are not ratcheted (their time is the session's state: an edit
    # to a central function recompiles its callers, 16 s against 28 s for the smoke core), only
    # budgeted; the stages still fresh hold their bests as `<stage>@warm` (they share the machine
    # otherwise)
    bestkey(name) = !isempty(runner) ? name * "@warm" : name
    warm_stage(name) = !isempty(runner) && name in ("smoke-core", "probes")
    ld = launch!(Stage("load", `$jl --project=. -e 'using WasmTarget; print(VERSION)'`, logf("load")))
    rat = launch!(Stage("ratchet", `$jl -O0 --project=. test/parity_ratchet.jl`, logf("ratchet")))
    probe_env(c) = merge(ENV, Dict("WT_PROBE_ONLY" => join(c, ' ')))
    if isempty(runner)
        launch!(Stage("smoke-core", setenv(`$jl --project=. -L dev/block_jit.jl test/smoke.jl $core`, smokeenv), logf("smoke-core")))
        isempty(batch) ||
            launch!(Stage("smoke-batch", setenv(`$jl --project=. -L dev/block_jit.jl test/smoke.jl $batch`, smokeenv), logf("smoke-batch")))
        # the probes, PROBE_CHUNK to a process (each pays its own ~20 s of compiling the compiler)
        chunks = [probes[i:min(i + PROBE_CHUNK - 1, end)] for i in 1:PROBE_CHUNK:length(probes)]
        for (i, c) in enumerate(chunks)
            launch!(Stage("probes $i/$(length(chunks))", setenv(`$jl -O0 --project=. test/probe_bytes.jl`, probe_env(c)), logf("probes-$i")))
        end
    else
        # the warm runner (WT_BLOCK_RUNNER): one process with this tree's code, its stages one after another
        chunks = [probes]
        warm = [Stage("smoke-core", setenv(`$runner test/smoke.jl $core`, smokeenv), logf("smoke-core"))]
        isempty(batch) || push!(warm, Stage("smoke-batch", setenv(`$runner test/smoke.jl $batch`, smokeenv), logf("smoke-batch")))
        push!(warm, Stage("probes 1/1", setenv(`$runner test/probe_bytes.jl`, probe_env(probes)), logf("probes-1")))
        append!(stages, warm)
        push!(tasks, @async foreach(s -> wait(start!(s)), warm))
    end
    isempty(newgroups) ||
        launch!(Stage("smoke-1.13", setenv(`julia +1.13 --startup-file=no --project=. -L dev/block_jit.jl test/smoke.jl $newgroups`, smokeenv), logf("smoke-1.13")))
    if !isempty(tlc)
        isempty(java) && push!(fails, "tlc: no working java (brew install openjdk@17)")
        # two TLC workers: the Julia stages beside it keep their cores (TLC's default takes them all)
        launch!(Stage("tlc", setenv(`bash dev/formal/run_tlc.sh`, merge(ENV, Dict("TLC_ONLY" => join(tlc, ' '), "TLC_WORKERS" => "2"))), logf("tlc")))
    end
    isempty(tlc_deep) || push!(notes, "tlc: deep instances $(join(tlc_deep, ' ')) are the full run's (non-blocking)")
    foreach(wait, tasks)
    total = time() - t_start
    done[] = true; wait(calibrator)
    jver = ld.exit == 0 ? strip(last(readlines(ld.log))) : ""
    occursin(r"^1\.12\.", jver) || push!(fails, "load: the default julia is $(isempty(jver) ? "unloadable" : jver), not 1.12")

    # the machine's slowdown factor (1 at its best, never below): the calibration's median against
    # its best, the fastest it has run (an update takes this run's lower quartile when faster, so
    # the bests it records are scaled by the factor they are later compared under)
    updating = get(ENV, "WT_TIMING_UPDATE", "") == "1"
    calib = median(samples)
    bcal = get(best, "calibration", NaN)
    fastest = isempty(samples) ? NaN : sort(samples)[max(1, length(samples) ÷ 4)]   # the lower quartile: one lucky sample is no speed
    # a best is measured on a quiet machine (1-minute load average at most Julia's CPU threads): on a
    # busy one the calibration's own spread distorts the scale the bests are recorded under
    quiet = loadavg[1] <= Sys.CPU_THREADS
    updating && !quiet && (updating = false; push!(notes, "WT_TIMING_UPDATE: refused, the machine is busy (load $(loadavg[1]) on $(Sys.CPU_THREADS) CPU threads): a best is measured on a quiet one"))
    if updating && !isnan(fastest) && (isnan(bcal) || fastest < bcal)
        best["calibration"] = round(fastest; digits = 6)
        bcal = best["calibration"]
    end
    factor = machine_factor(calib, bcal)
    # a best not recorded bounds nothing: outside WT_TIMING_UPDATE it fails, as a ratchet with no
    # baseline line does (test/parity_ratchet.jl); the update records it
    isnan(bcal) && (updating ? push!(notes, "calibration: no best, recorded by this update") :
                    push!(fails, "calibration: no best in dev/timing_best.toml (WT_TIMING_UPDATE=1 records it)"))

    # ---- verdicts ----
    res = Dict{String,Any}()   # stage => fields for the record
    function judge!(name, wall, cpu, ok, detail; command = "", exitcode = 0, fixed = true)
        b = get(budget, name, nothing)
        runs = any(f -> any(p -> startswith(f, p), get(STAGE_INPUTS, name, ["src/"])), changed)
        v = ok ? "ok" : "FAIL"
        ok || push!(fails, "$name: $detail")
        scaled = wall / factor
        if b !== nothing && wall > b
            if scaled <= b
                push!(notes, "$name: $(fmt(wall)) s, over its $b s budget only on a machine $(round(factor; digits = 2)) times slower than its best ($(fmt(scaled)) s at its speed): not blocking")
            else
                push!(fails, "$name: $(fmt(wall)) s, over its budget of $b s ($(fmt(scaled)) s at the machine's best speed)"); v = "OVER BUDGET"
            end
        end
        bkey = bestkey(name)
        fixed &= !warm_stage(name)
        bw = get(best, bkey, NaN)
        if name in RATCHETED && fixed && isnan(bw)
            updating ? push!(notes, "$bkey: no best, recorded by this update") :
                push!(fails, "$bkey: no best in dev/timing_best.toml (WT_TIMING_UPDATE=1 records it)")
        end
        if name in RATCHETED && ok && fixed && slower(scaled, bw)
            why = "$(fmt(scaled)) s at the machine's best speed ($(fmt(wall)) s, factor $(round(factor; digits = 2))) against its best $(fmt(bw)) s"
            if !isempty(exempt)
                push!(notes, "$name: slower, $why: declared a $exempt")
            else
                push!(fails, "$name: more than 15% and 0.3 s slower than its best: $why"); v = "SLOWER"
            end
        end
        res[name] = Dict{String,Any}("command" => command, "exit" => exitcode, "wall" => round(wall; digits = 2),
                                     "scaled" => round(scaled; digits = 2), "cpu" => round(cpu; digits = 2), "verdict" => v,
                                     "detail" => detail, "runs_change" => runs, "ratcheted" => name in RATCHETED && fixed)
        b === nothing || (res[name]["budget"] = b)
        isnan(bw) || (res[name]["best"] = bw)
        haskey(best_cpu, bkey) && (res[name]["best_cpu"] = best_cpu[bkey])
    end
    cmdstr(s) = join(s.cmd.exec, ' ')
    judge!("load", ld.wall, ld.cpu, ld.exit == 0 && !isempty(jver), ld.exit == 0 ? "julia $jver" : "exit $(ld.exit) (log $(ld.log))";
           command = cmdstr(ld), exitcode = ld.exit)
    judge!("ratchet", rat.wall, rat.cpu, rat.exit == 0, rat.exit == 0 ? "every lock and ratchet holds" :
           "exit $(rat.exit): $(join(first(filter(l -> occursin(r"BROKEN|MISSING|STRAY|❌", l), readlines(rat.log)), 6), " | "))";
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
        median_case <= b || push!(fails, "case-median: the core's median smoke case took $median_case s, over its budget of $b s")
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
        s.name == "tlc" || continue
        judge!("tlc", s.wall, s.cpu, s.exit == 0, s.exit == 0 ? "$(length(tlc)) instances: $(join(tlc, ' '))" :
               join(filter(l -> occursin("FAIL", l), readlines(s.log)), " | "); command = "TLC_ONLY=\"$(join(tlc, ' '))\" " * cmdstr(s), exitcode = s.exit)
    end
    tb = budget["total"]
    if total > tb
        total / factor <= tb ?
            push!(notes, "total: $(fmt(total)) s, over the $tb s budget only on a machine $(round(factor; digits = 2)) times slower than its best ($(fmt(total / factor)) s at its speed): not blocking") :
            push!(fails, "total: $(fmt(total)) s, over the budget of $tb s ($(fmt(total / factor)) s at the machine's best speed)")
    end
    green = isempty(fails)
    j113 = try readchomp(`julia +1.13 --startup-file=no -e 'print(VERSION)'`) catch; "" end
    isempty(newgroups) && push!(notes, "smoke-1.13: the change adds no smoke case, so no 1.13 stage (the full run's smoke-1.13 is non-blocking)")
    isempty(intersect(touched, matrix)) ||
        push!(notes, "smoke: matrix-only $(join(intersect(touched, matrix), ' ')) run in the non-blocking matrix (test/block_groups.tsv)")

    # ---- WT_TIMING_UPDATE=1: a green run on a clean tree lowers each best it beat ----
    if updating
        if !green
            push!(notes, "WT_TIMING_UPDATE: refused, the run is not green")
        elseif !clean
            push!(notes, "WT_TIMING_UPDATE: refused, uncommitted changes (a best is measured on a committed tree)")
        else
            lowered = String[]
            push!(lowered, "calibration $(best["calibration"])")
            for k in RATCHETED
                haskey(res, k) && res[k]["ratcheted"] || continue
                w = res[k]["scaled"]; c = res[k]["cpu"]; bk = bestkey(k)
                (!haskey(best, bk) || w < best[bk]) && (best[bk] = w; push!(lowered, "$bk $w"))
                !isnan(c) && (!haskey(best_cpu, bk) || c < best_cpu[bk]) && (best_cpu[bk] = c)
            end
            write_best(budget, best, best_cpu)
            push!(notes, "WT_TIMING_UPDATE: " * (isempty(lowered) ? "no best beaten" : "lowered " * join(lowered, ", ")))
        end
    end

    record = Dict{String,Any}(
        "tree" => tree, "head" => head, "base" => base, "clean" => clean,
        "verdict" => green ? "green" : "red", "failures" => fails, "notes" => notes,
        "total_wall" => round(total; digits = 2), "total_budget" => tb,
        "machine_factor" => round(factor; digits = 3), "calibration" => isnan(calib) ? 0.0 : round(calib; digits = 6),
        "calibration_samples" => length(samples), "calibration_fastest" => isnan(fastest) ? 0.0 : round(fastest; digits = 6),
        "load_average" => loadavg, "cpu_threads" => Sys.CPU_THREADS,
        "julia" => jver, "julia_113" => j113, "node" => node, "java" => java,
        "changed" => changed, "smoke_core" => core, "smoke_batch" => batch, "smoke_new" => newgroups,
        "probes" => probes, "tlc" => tlc, "timing_exempt" => exempt, "runner" => join(runner.exec, ' '),
        "logs" => relpath(logdir, ROOT), "stage" => res)
    path = joinpath(RECORD_DIR, tree * ".toml")
    if clean
        open(io -> Base.invokelatest(TOML.print, io, record; sorted = true), path, "w")
    else
        push!(notes, "not recorded: uncommitted changes (dev/land.sh merge takes a record of a clean tree only)")
    end

    # ---- one screen ----
    println("block $(head[1:8]) (tree $(tree[1:8])) on $(base[1:8]): $(length(changed)) changed file$(length(changed) == 1 ? "" : "s")")
    println("  ", rpad("stage", 12), lpad("wall", 7), lpad("cpu", 7), lpad("scaled", 8), lpad("budget", 8), lpad("best", 7), "  verdict")
    for k in ("load", "ratchet", "smoke-core", "smoke-batch", "smoke-1.13", "probes", "tlc")
        haskey(res, k) || continue
        r = res[k]
        println("  ", rpad(k, 12), lpad(fmt(r["wall"]), 7), lpad(fmt(r["cpu"]), 7), lpad(fmt(r["scaled"]), 8),
                lpad(string(get(r, "budget", "")), 8), lpad(haskey(r, "best") ? fmt(r["best"]) : "", 7), "  ", r["verdict"], "  ", first(r["detail"], 100))
    end
    haskey(res, "case-median") && println("  case median $(res["case-median"]["wall"]) s (budget $(res["case-median"]["budget"]) s)")
    println("  smoke: core $(length(core)) groups; batch $(isempty(batch) ? "-" : join(batch, ' ')); its own $(isempty(newgroups) ? "-" : join(newgroups, ' ')); probes $(length(probes))")
    println("  total $(fmt(total)) s of $tb s; machine factor $(round(factor; digits = 2)) (load $(join(round.(loadavg; digits = 2), ' ')), ",
            "$(Sys.CPU_THREADS) CPU threads); julia $jver, +1.13 $j113, node $node")
    for n in notes; println("  note: ", n); end
    for f in fails; println("  FAIL ", f); end
    println(green ? "BLOCK green" : "BLOCK red", clean ? "  → $(relpath(path, ROOT))" : "  (not recorded: uncommitted changes)")
    return green ? 0 : 1
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
