using JSON
using TOML

const ROOT = @__DIR__
const CONFIG = TOML.parsefile(joinpath(ROOT, "capabilities.toml"))
const DEADLINE_SECONDS =
    Float64(CONFIG["budgets"]["browser_wall_seconds"])
const OUTPUT_LIMIT_BYTES =
    Int(CONFIG["budgets"]["child_output_bytes_hard"])
const BROWSER_SCRIPT =
    normpath(joinpath(ROOT, "..", "..", "browser", "jump_t0.mjs"))
const TIMEOUT_FIXTURE_SCRIPT =
    normpath(joinpath(ROOT, "..", "..", "browser", "jump_timeout_tree.mjs"))

function terminate_browser_tree(proc)
    process_exited(proc) && return true
    pid = getpid(proc)
    try
        if Sys.iswindows()
            run(ignorestatus(`taskkill /PID $pid /T /F`))
        else
            ccall(:kill, Cint, (Cint, Cint), -pid, 15)
        end
    catch
    end
    timedwait(() -> process_exited(proc), 5.0)
    if !process_exited(proc) && !Sys.iswindows()
        try
            ccall(:kill, Cint, (Cint, Cint), -pid, 9)
        catch
        end
        timedwait(() -> process_exited(proc), 5.0)
    end
    return process_exited(proc)
end

function run_browser_child(
    export_root;
    deadline_seconds=DEADLINE_SECONDS,
    ready_path=nothing,
    startup_deadline_seconds=30.0,
)
    out_path, out_io = mktemp()
    err_path, err_io = mktemp()
    try
        bootstrap = """
        if !Sys.iswindows()
            ccall(:setsid, Cint, ()) == -1 &&
                error("failed to create browser certification process group")
        end
        include(popfirst!(ARGS))
        """
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$ROOT -e $bootstrap $(@__FILE__) --child $export_root`
        proc = run(
            pipeline(ignorestatus(cmd), stdout=out_io, stderr=err_io);
            wait=false,
        )
        startup_started = time()
        started = ready_path === nothing ? startup_started : nothing
        failure = nothing
        while !process_exited(proc)
            if ready_path !== nothing && started === nothing
                if isfile(ready_path) && filesize(ready_path) > 0
                    started = time()
                elseif time() - startup_started > startup_deadline_seconds
                    failure = "startup_timeout"
                    break
                end
            elseif time() - started > deadline_seconds
                failure = "timeout"
                break
            end
            bytes = (isfile(out_path) ? filesize(out_path) : 0) +
                    (isfile(err_path) ? filesize(err_path) : 0)
            if bytes > OUTPUT_LIMIT_BYTES
                failure = "output_limit"
                break
            end
            sleep(0.1)
        end
        cleanup_ok = true
        failure === nothing || (cleanup_ok = terminate_browser_tree(proc))
        close(out_io)
        close(err_io)
        stdout = read(out_path, String)
        stderr = read(err_path, String)
        failure === nothing ||
            error(
                "browser certification failed closed: $failure; " *
                "cleanup_ok=$cleanup_ok; stderr=" *
                last(stderr, min(length(stderr), 8192)),
            )
        success(proc) ||
            error(
                "browser certification exited $(proc.exitcode): " *
                last(stderr, min(length(stderr), 8192)),
            )
        result = JSON.parse(stdout)
        result["schema"] == 2 && result["pass"] === true ||
            error("browser certification returned an invalid result")
        return result
    finally
        isopen(out_io) && close(out_io)
        isopen(err_io) && close(err_io)
        rm(out_path; force=true)
        rm(err_path; force=true)
    end
end

function child_main()
    _, export_root = ARGS
    fixture_pid_path =
        get(ENV, "WT_JUMP_BROWSER_TIMEOUT_FIXTURE_PID_FILE", "")
    if !isempty(fixture_pid_path)
        node = Sys.which("node")
        node === nothing && error("Node runtime required by timeout fixture")
        proc = run(
            `$node $TIMEOUT_FIXTURE_SCRIPT $fixture_pid_path $(Base.julia_cmd().exec[1])`;
            wait=false,
        )
        wait(proc)
        exit(proc.exitcode)
    end
    node = Sys.which("node")
    node === nothing && error("pinned Node runtime is required")
    proc = run(ignorestatus(`$node $BROWSER_SCRIPT $export_root`))
    exit(proc.exitcode)
end

function main()
    length(ARGS) == 1 ||
        error("usage: run_browser_t0.jl EXPORT_ROOT")
    result = run_browser_child(abspath(only(ARGS)))
    println(JSON.json(result, 2))
end

if !isempty(ARGS) && first(ARGS) == "--child"
    child_main()
elseif abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
