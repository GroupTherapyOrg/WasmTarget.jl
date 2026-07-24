using Test

include(joinpath(@__DIR__, "run_snapshot_t0.jl"))

function process_is_alive(pid::Int)
    if Sys.iswindows()
        output = read(ignorestatus(`tasklist /FI "PID eq $pid" /NH`), String)
        return occursin(string(pid), output)
    end
    return ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0
end

@testset "Snapshot export watchdog terminates descendants" begin
    mktempdir() do root
        pid_path = joinpath(root, "grandchild.pid")
        error_message = ""
        withenv("WT_JUMP_SNAPSHOT_TIMEOUT_PID_FILE" => pid_path) do
            try
                run_variant_child(
                    "__timeout_fixture__",
                    joinpath(root, "export");
                    deadline_seconds=1.0,
                    ready_path=pid_path,
                    startup_deadline_seconds=30.0,
                )
            catch error
                error_message = sprint(showerror, error)
            end
        end
        @test occursin("timeout", error_message)
        @test occursin("cleanup_ok=true", error_message)
        @test isfile(pid_path)
        pid = parse(Int, read(pid_path, String))
        timedwait(() -> !process_is_alive(pid), 10.0)
        @test !process_is_alive(pid)
    end
end
