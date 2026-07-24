module JumpBrowserCertificationRunner

using JSON
using NodeJS_24_jll

export run_browser_child, run_browser_main, terminate_browser_tree

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
    root,
    browser_script,
    timeout_fixture_script,
    deadline_seconds,
    output_limit_bytes,
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
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$root -e $bootstrap $(@__FILE__) --child $browser_script $timeout_fixture_script $export_root`
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
            if bytes > output_limit_bytes
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
        result["pass"] === true ||
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
    _, browser_script, timeout_fixture_script, export_root = ARGS
    fixture_pid_path =
        get(ENV, "WT_JUMP_BROWSER_TIMEOUT_FIXTURE_PID_FILE", "")
    node = NodeJS_24_jll.node()
    if !isempty(fixture_pid_path)
        proc = run(
            `$node $timeout_fixture_script $fixture_pid_path $(Base.julia_cmd().exec[1])`;
            wait=false,
        )
        wait(proc)
        exit(proc.exitcode)
    end
    proc = run(ignorestatus(`$node $browser_script $export_root`))
    exit(proc.exitcode)
end

function run_browser_main(
    args;
    root,
    browser_script,
    timeout_fixture_script,
    deadline_seconds,
    output_limit_bytes,
    usage,
)
    length(args) == 1 || error(usage)
    result = run_browser_child(
        abspath(only(args));
        root,
        browser_script,
        timeout_fixture_script,
        deadline_seconds,
        output_limit_bytes,
    )
    println(JSON.json(result, 2))
end

if !isempty(ARGS) && first(ARGS) == "--child"
    child_main()
end

end
