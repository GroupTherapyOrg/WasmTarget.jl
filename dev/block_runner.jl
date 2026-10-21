# dev/block_runner.jl — the blocking gate's warm runner (dev/block.jl `--warm`; dev/CHARTER.md C10,
# L194, L195): one Julia process per worktree that holds this tree's code, compiled once, and runs a
# check as a fresh `julia --project=. <file> [args...]` would, so the gate pays for compiling the
# compiler once per session instead of once per stage.
#
#   julia --startup-file=no dev/block_runner.jl start [<launcher>...]   # start this tree's server
#       (in the background, through <launcher> when given, e.g. a slot scheduler) and wait until warm
#   julia --startup-file=no dev/block_runner.jl stop | status
#   julia --startup-file=no dev/block_runner.jl run <file> [args...]    # a check, through the server:
#       its stdout, stderr and exit status are the check's; the environment is passed as it is
#
# The server: `julia --project=<tree> -e 'Base.include(Module(:BlockRunner), "<this file>")' serve`,
# its own code in that module, so Main holds nothing of it. Revise (dev/runner_env, exact versions)
# tracks every file of WasmTarget and its extensions; before each request every tracked file whose
# mtime moved is revised, and a change Revise cannot apply, or to Project.toml, Manifest.toml,
# LocalPreferences.toml, this file or dev/runner_env, restarts the server and reruns the request
# (never stale code). The
# test entry points' packages (PRELOAD) load at start, so the package set does not depend on which
# request came first. A request that sets WT_PROBE_RECORD, WT_RATCHET_UPDATE or WT_RECORD_TIMES is
# refused: a baseline is recorded by a fresh process. The server stops after IDLE_MIN idle minutes.
#
# Each request reports its state first, `block_runner: warm <blob>` or `block_runner: cold
# (<why>) <blob>`: cold until its check (the file it runs, with these arguments and WT_* variables)
# has run once on the code as it now is,
# i.e. its first run on this server or since a revise (its time is then compiling the change and the
# check's paths, not running them; dev/block.jl's verdict on time takes no cold run), <blob> the git
# blob of the dev/block_runner.jl the server runs (dev/block.jl refuses a
# server running another, and the record names it).
#
# The reset (parity(quarantine: a Julia process has no API to give Main a fresh binding table; the
# probe bytes hold closure names drawn from Main's table and lowering counter, and WasmTarget compares
# against Main itself, so a request cannot run in a fresh module)): before every request Main's
# binding table, its key set, the length of its `using` list and its lowering counter are stored
# back, by address into jl_module_t (julia.h, the same in 1.12 and 1.13: name, parent, bindings,
# bindingkeyset, file, line, usings_backedges, scanned_methods, then the usings arraylist, its
# length at byte 64, three words per module used, appended; the counter at byte 352), to the values
# read when this process started, before anything ran in Main. The layout is checked at start (the
# read table is Main's, a closure's lowering draws the counter and a reset draws the same name again,
# the length is three words per module Main uses, and a `using` added then reset is gone with the
# names it brought) or the server does not start. Not reset, and so not a fresh process:
# methods a check adds to Base's or WasmTarget's functions, WasmTarget's own globals, packages
# loaded by an earlier request, the session's threads. Should Main's `using` list still differ
# from its start at a request (the reset failing), the server restarts rather than run the check
# where a name it defines again is ambiguous between two modules, which a fresh process never sees. The final evidence before PR #128 merges is
# the full matrix, fresh processes on CI's runners.
#
# Wire (client -> server): u32 nfields, then per field u32 len + bytes:
#   [mode, cwd, nargs, args..., nenv, "K=V"...]   mode ∈ file | stop | ping
# Server -> client frames: 1 tag byte + u32 len + bytes. o = stdout, e = stderr, x = exit status
# (decimal), r = the server is restarting (the reason; the client starts it again and resends).

using Sockets, Logging

const ROOT = normpath(joinpath(@__DIR__, ".."))
const DIR = joinpath(ROOT, "dev", ".block", "runner")   # git-ignored with the gate's records
const SOCK = joinpath(DIR, "sock")
const ENVDIR = joinpath(ROOT, "dev", "runner_env")
const RESTART = 75
const IDLE_MIN = 20
const PRELOAD = ("Test", "Random", "SHA", "LinearAlgebra", "Statistics", "Dates", "JSON")
const REFUSED = ("WT_PROBE_RECORD", "WT_RATCHET_UPDATE", "WT_RECORD_TIMES")

# the git blob of this file as it is on disk: the version a server runs and a client expects
blob() = readchomp(`git -C $ROOT hash-object $(joinpath(ROOT, "dev", "block_runner.jl"))`)

# ── wire ──
readu32(io) = ntoh(read(io, UInt32))
readreq(io) = [String(read(io, readu32(io))) for _ in 1:readu32(io)]
function writereq(io, fields)
    write(io, hton(UInt32(length(fields))))
    for f in fields
        b = Vector{UInt8}(f)
        write(io, hton(UInt32(length(b))), b)
    end
end

# ═════════════════════════════════ the client ═════════════════════════════════
pidof(f) = (p = isfile(f) ? tryparse(Int, strip(read(f, String))) : nothing; p === nothing ? 0 : p)
alive(pid) = pid > 0 && ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0
ready() = alive(pidof(joinpath(DIR, "ready"))) && ispath(SOCK)

function start(launcher::Vector{String})
    mkpath(DIR)
    ready() && (println("block_runner: already serving $ROOT (pid $(pidof(joinpath(DIR, "ready"))))"); return 0)
    write(joinpath(DIR, "launcher"), join(launcher, '\n'))
    if !isfile(joinpath(ENVDIR, "Manifest.toml"))
        println("block_runner: instantiating dev/runner_env")
        run(`$(Base.julia_cmd()) --startup-file=no --project=$ENVDIR -e 'using Pkg; Pkg.instantiate()'`)
    end
    rm(SOCK; force = true); rm(joinpath(DIR, "ready"); force = true)
    serve = `$(Base.julia_cmd()) --startup-file=no --project=$ROOT -e $("Base.include(Module(:BlockRunner), $(repr(@__FILE__)))") serve`
    log = joinpath(DIR, "server.log")
    open(io -> println(io, "\n=== start $(Libc.strftime("%F %T", time())) ==="), log, "a")
    # this tree's package image, built first in a process of its own: the server loads Revise's
    # environment before WasmTarget, and a package compiled there sees other versions of its
    # dependencies already loaded (a fresh worktree's first start failed so: "Missing source file for
    # ... WasmTargetRandomExt", A20P23)
    image = `$(Base.julia_cmd()) --startup-file=no --project=$ROOT -e 'using WasmTarget'`
    built = run(pipeline(ignorestatus(Cmd(Cmd(vcat(launcher, image.exec)); dir = ROOT)); stdin = devnull, stdout = log, stderr = log, append = true))
    built.exitcode == 0 || (println(stderr, "block_runner: this tree's package does not load (exit $(built.exitcode); log $log):\n", error_lines(log)); return 1)
    p = run(pipeline(detach(Cmd(Cmd(vcat(launcher, serve.exec)); dir = ROOT)); stdin = devnull, stdout = log, stderr = log, append = true); wait = false)
    t0 = time()
    while !ready()
        process_exited(p) && (println(stderr, "block_runner: the server exited before it was ready (exit $(p.exitcode); log $log):\n",
                                      error_lines(log)); return 1)
        time() - t0 > 900 && (println(stderr, "block_runner: no server after 15 min (log $log)"); return 1)
        sleep(0.5)
    end
    println("block_runner: ready in $(round(time() - t0; digits = 1)) s (pid $(pidof(joinpath(DIR, "ready"))), log $log)")
    return 0
end

# the first error since this start's marker in the log, with the lines that say what it is (the
# stack trace's frames left out): the cause, not what failed after it
function error_lines(log)::String
    all_ = readlines(log)
    ls = all_[something(findlast(l -> startswith(l, "=== start "), all_), 0)+1:end]
    k = findfirst(l -> startswith(l, "ERROR"), ls)
    k === nothing && return join(last(ls, 6), '\n')
    return join(first(filter(l -> !occursin(r"^\s*(\[\d+\]|@ )", l), ls[k:end]), 8), '\n')
end

function connect_server()
    ready() || return nothing
    try
        return connect(SOCK)
    catch
        return nothing
    end
end

function stop()
    s = connect_server()
    s === nothing && (println("block_runner: no server for $ROOT"); return 0)
    writereq(s, ["stop"]); try; read(s); catch; end; close(s)
    pid = pidof(joinpath(DIR, "server.pid")); t0 = time()
    while alive(pid) && time() - t0 < 15; sleep(0.2); end
    println("block_runner: stopped the server for $ROOT")
    return 0
end

status() = (println(ready() ? "block_runner: serving $ROOT (pid $(pidof(joinpath(DIR, "ready"))), runner $(read(joinpath(DIR, "blob"), String)))" :
                    "block_runner: no server for $ROOT"); 0)

# one check through the server, its output streamed to this process's own
function request(file, args)
    fields = ["file", pwd(), string(1 + length(args)), file, args..., string(length(ENV)), ["$k=$v" for (k, v) in ENV]...]
    for attempt in 1:3
        s = connect_server()
        s === nothing && (println(stderr, "block_runner: no server for $ROOT: julia --startup-file=no dev/block_runner.jl start"); return 2)
        writereq(s, fields)
        reason = nothing
        while true
            eof(s) && (println(stderr, "block_runner: the server closed the connection without an exit status (log $(joinpath(DIR, "server.log")))"); return 1)
            tag = Char(read(s, UInt8)); data = read(s, readu32(s))
            tag == 'o' ? (write(stdout, data); flush(stdout)) :
            tag == 'e' ? (write(stderr, data); flush(stderr)) :
            tag == 'x' ? (return parse(Int, String(data))) :
            tag == 'r' ? (reason = String(data); break) : nothing
        end
        close(s)
        println(stderr, "block_runner: the server is restarting ($reason); the request reruns on a new one")
        pid = pidof(joinpath(DIR, "server.pid")); t0 = time()
        while alive(pid) && time() - t0 < 30; sleep(0.2); end
        launcher = isfile(joinpath(DIR, "launcher")) ? filter(!isempty, split(read(joinpath(DIR, "launcher"), String), '\n')) : String[]
        start(String.(launcher)) == 0 || return 1
    end
    println(stderr, "block_runner: the server restarted three times for one request")
    return 1
end

function client_main(args)
    isempty(args) && (println(stderr, "usage: julia dev/block_runner.jl start [<launcher>...] | stop | status | run <file> [args...]"); return 2)
    cmd = args[1]
    cmd == "start" && return start(String.(args[2:end]))
    cmd == "stop" && return stop()
    cmd == "status" && return status()
    cmd == "run" && length(args) >= 2 && return request(args[2], String.(args[3:end]))
    println(stderr, "block_runner: unknown command $(join(args, ' '))")
    return 2
end

# ═════════════════════════════════ the server ═════════════════════════════════
function serve()
    # Main as this process started it, read before anything runs in it (the reset, above)
    MAIN_P = pointer_from_objref(Main)
    BINDINGS0 = Core.svec(unsafe_pointer_to_objref(unsafe_load(Ptr{Ptr{Cvoid}}(MAIN_P), 3))...)
    KEYSET0 = copy(unsafe_pointer_to_objref(unsafe_load(Ptr{Ptr{Cvoid}}(MAIN_P), 4)))
    COUNTER0 = unsafe_load(Ptr{UInt32}(MAIN_P + COUNTER_OFFSET))
    USINGS0 = ccall(:jl_module_usings, Any, (Any,), Main)
    USINGS_LEN0 = unsafe_load(Ptr{Csize_t}(MAIN_P + USINGS_LEN_OFFSET))
    rooted = Ref{Any}(nothing)
    function reset_main!()
        b = Core.svec(BINDINGS0...)   # a copy each time: the runtime fills a table's free slots in place
        k = copy(KEYSET0)
        rooted[] = (b, k)             # rooted here: the stores below bypass the GC write barrier
        unsafe_store!(Ptr{Ptr{Cvoid}}(MAIN_P), pointer_from_objref(b), 3)
        unsafe_store!(Ptr{Ptr{Cvoid}}(MAIN_P), pointer_from_objref(k), 4)
        unsafe_store!(Ptr{UInt32}(MAIN_P + COUNTER_OFFSET), COUNTER0)
        unsafe_store!(Ptr{Csize_t}(MAIN_P + USINGS_LEN_OFFSET), USINGS_LEN0)
        return nothing
    end
    ok = BINDINGS0 isa Core.SimpleVector && KEYSET0 isa GenericMemory &&
         all(b -> b === nothing || (b isa Core.Binding && b.globalref.mod === Main), BINDINGS0) &&
         issubset(names(Main; all = true), [b.globalref.name for b in BINDINGS0 if b !== nothing])
    ok || error("block_runner: Main's layout is not the one this file reads (Julia $VERSION)")
    c = Ptr{UInt32}(MAIN_P + COUNTER_OFFSET)
    draw() = (reset_main!(); Meta.lower(Main, :(x -> x)); unsafe_load(c))
    c1, c2 = draw(), draw()
    reset_main!()
    c1 == c2 > COUNTER0 || error("block_runner: Main's lowering counter is not at byte $COUNTER_OFFSET (Julia $VERSION: $COUNTER0, $c1, $c2)")
    # Main's `using` list: three words per module used at byte 64, and a `using` added then reset gone
    USINGS_LEN0 == 3 * length(USINGS0) || error("block_runner: Main's using list is not at byte $USINGS_LEN_OFFSET (Julia $VERSION: $USINGS_LEN0 for $(length(USINGS0)) modules)")
    Core.eval(Main, :(module BlockRunnerProbe; export block_runner_probe; const block_runner_probe = 1; end))
    Core.eval(Main, :(using .BlockRunnerProbe))
    seen(name) = Base.invokelatest(isdefined, Main, name)   # in the world the eval made, not this function's
    added = seen(:block_runner_probe)
    reset_main!()
    added && ccall(:jl_module_usings, Any, (Any,), Main) == USINGS0 && !seen(:block_runner_probe) && !seen(:BlockRunnerProbe) ||
        error("block_runner: a `using` added to Main is not taken back by storing its length at byte $USINGS_LEN_OFFSET (Julia $VERSION)")

    mkpath(DIR)
    T0 = time()
    LOG = stdout   # start() sends the server's output to dev/.block/runner/server.log
    logmsg(s) = (println(LOG, "[$(round(time() - T0; digits = 1)) s] ", s); flush(LOG))
    write(joinpath(DIR, "server.pid"), string(getpid()))
    BLOB = blob()
    write(joinpath(DIR, "blob"), BLOB)

    # a check's exit() ends its request, never the server
    Core.eval(Base, :(exit(n) = throw($RequestExit(Int(n)))))
    real_exit(n) = ccall(:jl_exit, Union{}, (Int32,), n)

    # Revise first, so it tracks every file of WasmTarget and its extensions; its environment stays
    # second on LOAD_PATH, before @v#.#, whose older CodeTracking would break it
    insert!(LOAD_PATH, 2, ENVDIR)
    t_rev = @elapsed (Revise = Base.require(Base.PkgId(Base.UUID("295af30f-e4ad-537b-8983-00126c2a3abe"), "Revise")))
    t_wt = @elapsed Base.require(Base.identify_package("WasmTarget"))
    t_pre = @elapsed for p in PRELOAD
        id = Base.identify_package(p)
        id === nothing && error("block_runner: $(Base.active_project()) cannot load $p")
        Base.require(id)
    end
    logmsg("loaded Revise $(round(t_rev; digits = 1)) s, WasmTarget $(round(t_wt; digits = 1)) s, $(join(PRELOAD, ' ')) $(round(t_pre; digits = 1)) s")
    # the rest runs in the world those packages were loaded into
    usings_changed() = ccall(:jl_module_usings, Any, (Any,), Main) != USINGS0
    Base.invokelatest(serve_loop, Revise, reset_main!, usings_changed, logmsg, real_exit, T0, BLOB)
end

function serve_loop(Revise, reset_main!, usings_changed, logmsg, real_exit, T0, BLOB)
    # a change Revise cannot apply restarts the server, as does a change to this file (the runner's
    # version, which dev/block.jl checks) or its environment
    restart_files = [joinpath(ROOT, f) for f in ("Project.toml", "Manifest.toml", "LocalPreferences.toml",
                                                 "dev/block_runner.jl", "dev/runner_env/Project.toml")]
    mt(f) = isfile(f) ? mtime(f) : 0.0
    restart_snap = Dict(f => mt(f) for f in restart_files)
    function tracked()
        out = Dict{String,Tuple{Any,String}}()
        for pd in values(Revise.pkgdatas)
            startswith(joinpath(abspath(Revise.basedir(pd)), ""), ROOT) || continue   # ROOT ends in /
            for f in Revise.srcfiles(pd)
                out[normpath(joinpath(Revise.basedir(pd), f))] = (pd, String(f))
            end
        end
        return out
    end
    src_snap = Dict{String,Float64}(f => mt(f) for f in keys(tracked()))
    logmsg("Revise tracks $(length(src_snap)) files under $ROOT")
    # the running code brought up to the tree on disk: the files revised, or the reason to restart
    function sync()
        for f in restart_files
            mt(f) == restart_snap[f] || return "$(relpath(f, ROOT)) changed"
        end
        changed = String[]
        for (f, (pd, rel)) in tracked()
            mt(f) != get(src_snap, f, -1.0) || continue
            push!(Revise.revision_queue, (pd, rel))   # not waiting for the file watcher's event
            push!(changed, relpath(f, ROOT))
        end
        try
            Base.invokelatest(Revise.revise; throw = true)
        catch err
            return "Revise could not apply $(join(changed, ", ")): " * sprint(showerror, err)
        end
        isempty(Revise.queue_errors) ||
            return "Revise could not apply " * join([relpath(joinpath(Revise.basedir(pd), f), ROOT) for (pd, f) in keys(Revise.queue_errors)], ", ")
        for f in keys(tracked())
            src_snap[f] = mt(f)
        end
        return changed
    end
    sync()   # compiled now, not on the first request

    wlock = ReentrantLock()
    frame(sock, tag::Char, data) = lock(wlock) do
        bytes = data isa AbstractVector{UInt8} ? data : Vector{UInt8}(string(data))
        try; write(sock, UInt8(tag), hton(UInt32(length(bytes))), bytes); catch; end
    end
    pump(src, sock, tag) = @async try
        while !eof(src); frame(sock, tag, readavailable(src)); end
    catch
    end
    function shutdown(code)
        for f in (SOCK, joinpath(DIR, "ready"), joinpath(DIR, "server.pid"))
            try; rm(f; force = true); catch; end
        end
        real_exit(code)
    end

    nreq = Ref(0); last = Ref(time()); busy = Ref(false)
    # the code's version (revisions applied) and, per check, the version it last ran on
    version = Ref(0); ran_on = Dict{String,Int}()
    function handle(sock)
        eof(sock) && return
        req = readreq(sock)
        mode = req[1]
        if mode == "ping"
            frame(sock, 'o', "block_runner $(getpid()) up $(round(Int, time() - T0)) s, $(nreq[]) requests, $BLOB\n"); frame(sock, 'x', "0"); return
        elseif mode == "stop"
            frame(sock, 'o', "block_runner: stopping $(getpid())\n"); frame(sock, 'x', "0"); shutdown(0)
        end
        cwd = req[2]; nargs = parse(Int, req[3]); args = req[4:3+nargs]; nenv = parse(Int, req[4+nargs])
        env = Dict{String,String}()
        for kv in req[5+nargs:4+nargs+nenv]
            k, v = split(kv, '='; limit = 2)
            env[k] = v
        end
        target, args = args[1], args[2:end]
        for v in REFUSED
            if get(env, v, "") ∉ ("", "0")
                frame(sock, 'e', "block_runner: $v is set: a baseline is recorded by a fresh `julia --project=.` run, never by the warm runner\n")
                frame(sock, 'x', "2"); return
            end
        end
        t = time()
        s = sync()
        s isa String || !usings_changed() || (s = "Main's `using` list differs from its start after the reset")
        if s isa String
            logmsg("restart: $s")
            frame(sock, 'r', s); close(sock); shutdown(RESTART)
        end
        nreq[] += 1
        isempty(s) || (version[] += 1)
        key = join(vcat(normpath(abspath(cwd, target)), args, sort([k * "=" * v for (k, v) in env if startswith(k, "WT_")])), '\0')
        state = get(ran_on, key, -1) == version[] ? "warm" :
                haskey(ran_on, key) || version[] > 0 ? "cold (this check's first run since a revise)" : "cold (this check's first run on this server)"
        ran_on[key] = version[]
        logmsg("request $(nreq[]): $target $(join(args, ' ')) — $state (sync $(round(time() - t; digits = 2)) s)")
        frame(sock, 'e', "block_runner: $state $BLOB\n")
        out = Pipe(); Base.link_pipe!(out; reader_supports_async = true, writer_supports_async = true)
        err = Pipe(); Base.link_pipe!(err; reader_supports_async = true, writer_supports_async = true)
        p1 = pump(out.out, sock, 'o'); p2 = pump(err.out, sock, 'e')
        # a task of its own: no task-local include path, no leftover testset stack
        task = Task(() -> Base.invokelatest(run_in_main, reset_main!, target, args, env, cwd, out, err))
        schedule(task)
        # the client went away: the check is interrupted at its next yield, or the server ends
        @async try
            while !istaskdone(task)
                if bytesavailable(sock) == 0 && eof(sock)
                    istaskdone(task) && break
                    logmsg("request $(nreq[]): the client went away; interrupting it")
                    schedule(task, InterruptException(); error = true)
                    t0 = time()
                    while !istaskdone(task) && time() - t0 < 20; sleep(0.5); end
                    istaskdone(task) || (logmsg("request $(nreq[]) did not stop; restarting"); shutdown(RESTART))
                    break
                end
            end
        catch
        end
        code = try; fetch(task); catch; 130; end
        close(out.in); close(err.in); wait(p1); wait(p2)
        logmsg("request $(nreq[]) exit $code in $(round(time() - t; digits = 1)) s")
        frame(sock, 'x', string(code))
    end

    rm(SOCK; force = true)
    server = listen(SOCK)
    write(joinpath(DIR, "ready"), string(getpid()))
    logmsg("ready on $SOCK, runner $BLOB")
    Timer(30; interval = 30) do _
        !busy[] && time() - last[] > 60 * IDLE_MIN && (logmsg("idle $IDLE_MIN min, stopping"); shutdown(0))
    end
    while true
        sock = accept(server)
        busy[] = true
        try
            handle(sock)
        catch e
            logmsg("request failed: " * sprint(showerror, e, catch_backtrace()))
            frame(sock, 'e', "block_runner: server error: " * sprint(showerror, e) * "\n"); frame(sock, 'x', "1")
        finally
            try; close(sock); catch; end
            busy[] = false; last[] = time()
        end
    end
end

const COUNTER_OFFSET = 352
const USINGS_LEN_OFFSET = 64
struct RequestExit <: Exception
    code::Int
end

# one request, in Main, as `julia --project=<tree> <file> args...` runs it
function run_in_main(reset_main!, target, args, env, cwd, out, err)
    saved_args = copy(Base.ARGS); saved_pf = Base.PROGRAM_FILE; saved_env = copy(ENV)
    saved_cwd = pwd(); saved_hooks = copy(Base.atexit_hooks)
    code = 0
    try
        reset_main!()
        cd(cwd)
        for k in collect(keys(ENV)); haskey(env, k) || delete!(ENV, k); end
        for (k, v) in env; ENV[k] = v; end
        empty!(Base.ARGS); append!(Base.ARGS, args)
        Core.eval(Base, :(PROGRAM_FILE = $target))
        redirect_stdio(stdin = devnull, stdout = out, stderr = err) do
            with_logger(ConsoleLogger(err)) do
                try
                    Base.include(Main, abspath(cwd, target))
                catch e
                    x = e
                    while x isa LoadError; x = x.error; end
                    if x isa RequestExit
                        code = x.code
                    else
                        code = 1
                        try
                            Base.invokelatest(Base.display_error, err, current_exceptions())
                        catch
                            println(err, "ERROR: ", sprint(showerror, e))
                        end
                    end
                end
                # the hooks a check registered (a Node pool's shutdown) run, as at a process's exit
                for h in collect(Base.atexit_hooks)
                    any(x -> x === h, saved_hooks) && continue
                    try
                        Base.invokelatest(h)
                    catch
                        try; Base.invokelatest(h, Int32(code)); catch; end
                    end
                end
                flush(out); flush(err)
            end
        end
    finally
        reset_main!()   # what the check left in Main goes with it, before the next request is looked at
        empty!(Base.atexit_hooks); append!(Base.atexit_hooks, saved_hooks)
        empty!(Base.ARGS); append!(Base.ARGS, saved_args)
        Core.eval(Base, :(PROGRAM_FILE = $saved_pf))
        for k in collect(keys(ENV)); haskey(saved_env, k) || delete!(ENV, k); end
        for (k, v) in saved_env; ENV[k] = v; end
        cd(saved_cwd)
    end
    return code
end

if !isempty(ARGS) && ARGS[1] == "serve" && @__MODULE__() !== Main
    serve()
elseif abspath(PROGRAM_FILE) == @__FILE__
    exit(client_main(ARGS))
end
