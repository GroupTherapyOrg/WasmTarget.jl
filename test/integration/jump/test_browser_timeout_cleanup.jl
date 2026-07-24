using Test

include(joinpath(@__DIR__, "run_browser_t0.jl"))

function process_exists(pid::Int)
    if Sys.iswindows()
        output = read(
            ignorestatus(`tasklist /FI "PID eq $pid" /FO CSV /NH`),
            String,
        )
        return occursin("\"$pid\"", output)
    end
    return ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0
end

mktemp() do pid_path, io
    close(io)
    ENV["WT_JUMP_BROWSER_TIMEOUT_FIXTURE_PID_FILE"] = pid_path
    try
        error = try
            run_browser_child(
                mktempdir();
                deadline_seconds=1.0,
                ready_path=pid_path,
                startup_deadline_seconds=30.0,
            )
            nothing
        catch caught
            caught
        end
        @test error isa ErrorException
        @test occursin("failed closed: timeout", sprint(showerror, error))
        @test timedwait(() -> filesize(pid_path) > 0, 10.0) == :ok
        pids = JSON.parsefile(pid_path)
        @test Set(keys(pids)) == Set(["julia", "node", "leaf"])
        for role in ("julia", "node", "leaf")
            pid = Int(pids[role])
            @test timedwait(() -> !process_exists(pid), 10.0) == :ok
        end
    finally
        delete!(ENV, "WT_JUMP_BROWSER_TIMEOUT_FIXTURE_PID_FILE")
    end
end
