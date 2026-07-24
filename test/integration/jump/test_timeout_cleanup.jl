using Test

include(joinpath(@__DIR__, "run_certification.jl"))

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
    ENV["WT_JUMP_TIMEOUT_FIXTURE_PID_FILE"] = pid_path
    try
        result = run_child("__timeout_fixture__", 2.0)
        @test result["pass"] === false
        @test result["failure"] == "child_timeout"
        @test result["cleanup_ok"] === true
        @test timedwait(() -> filesize(pid_path) > 0, 10.0) == :ok
        grandchild_pid = parse(Int, strip(read(pid_path, String)))
        @test timedwait(() -> !process_exists(grandchild_pid), 10.0) == :ok
    finally
        delete!(ENV, "WT_JUMP_TIMEOUT_FIXTURE_PID_FILE")
    end
end
