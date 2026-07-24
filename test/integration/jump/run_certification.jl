using JSON
using TOML

const ROOT = @__DIR__
const CONFIG = TOML.parsefile(joinpath(ROOT, "capabilities.toml"))
const DEADLINE_SECONDS = Float64(CONFIG["budgets"]["child_wall_seconds"])
const SUITE_DEADLINE_SECONDS =
    Float64(CONFIG["budgets"]["suite_wall_seconds"])
const OUTPUT_LIMIT_BYTES =
    Int(CONFIG["budgets"]["child_output_bytes_hard"])
const RESULT_PREFIX = "WT_JUMP_CERT_RESULT="
const REQUIRED_GATES = (
    "native_oracle",
    "raw_wasm",
    "optimize_size",
    "optimize_speed",
    "unexpected_skip_is_failure",
    "independent_validation",
)

function terminate_process(proc)
    process_exited(proc) && return
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

function wait_for_child(
    proc,
    out_path,
    err_path,
    deadline_seconds;
    ready_path=nothing,
    startup_deadline_seconds=30.0,
)
    startup_started = time()
    started = ready_path === nothing ? startup_started : nothing
    while !process_exited(proc)
        if ready_path !== nothing && started === nothing
            if isfile(ready_path) && filesize(ready_path) > 0
                started = time()
            elseif time() - startup_started > startup_deadline_seconds
                return :startup_timed_out
            end
        elseif time() - started > deadline_seconds
            return :timed_out
        end
        output_bytes =
            (isfile(out_path) ? filesize(out_path) : 0) +
            (isfile(err_path) ? filesize(err_path) : 0)
        output_bytes > OUTPUT_LIMIT_BYTES && return :output_limit
        sleep(0.1)
    end
    return :exited
end

function run_child(
    case_name::String,
    deadline_seconds::Float64;
    artifact_root=nothing,
    ready_path=nothing,
    startup_deadline_seconds=30.0,
)
    out_path, out_io = mktemp()
    err_path, err_io = mktemp()
    temporary_artifact_root = artifact_root === nothing
    child_artifact_root =
        temporary_artifact_root ? mktempdir() : abspath(artifact_root)
    try
        bootstrap = """
        if !Sys.iswindows()
            ccall(:setsid, Cint, ()) == -1 &&
                error("failed to create JuMP certification process group")
        end
        include(popfirst!(ARGS))
        """
        cmd = addenv(
            `$(Base.julia_cmd()) --startup-file=no --project=$ROOT -e $bootstrap $(joinpath(ROOT, "run_case.jl")) $case_name`,
            "WT_VALIDATE" => "1",
            "WT_JUMP_MODULE_ROOT" => child_artifact_root,
        )
        proc = run(pipeline(ignorestatus(cmd), stdout=out_io, stderr=err_io); wait=false)
        status = wait_for_child(
            proc,
            out_path,
            err_path,
            min(DEADLINE_SECONDS, deadline_seconds),
            ready_path=ready_path,
            startup_deadline_seconds=startup_deadline_seconds,
        )
        cleanup_ok = true
        if status !== :exited
            cleanup_ok = terminate_process(proc)
        end
        close(out_io)
        close(err_io)
        stdout = read(out_path, String)
        stderr = read(err_path, String)
        if status !== :exited
            return Dict(
                "schema" => 1,
                "case" => case_name,
                "pass" => false,
                "failure" =>
                    status === :timed_out ? "child_timeout" :
                    status === :startup_timed_out ? "child_startup_timeout" :
                    "child_output_limit",
                "deadline_seconds" => min(DEADLINE_SECONDS, deadline_seconds),
                "cleanup_ok" => cleanup_ok,
                "stdout_tail" => last(stdout, min(8_192, length(stdout))),
                "stderr_tail" => last(stderr, min(8_192, length(stderr))),
            )
        end
        result_lines = filter(startswith(RESULT_PREFIX), split(stdout, '\n'))
        if length(result_lines) != 1
            return Dict(
                "schema" => 1,
                "case" => case_name,
                "pass" => false,
                "failure" => "invalid_result_count",
                "result_count" => length(result_lines),
                "exit_code" => proc.exitcode,
                "stdout_tail" => last(stdout, min(8_192, length(stdout))),
                "stderr_tail" => last(stderr, min(8_192, length(stderr))),
            )
        end
        result = try
            JSON.parse(only(result_lines)[(length(RESULT_PREFIX) + 1):end])
        catch error
            return Dict(
                "schema" => 1,
                "case" => case_name,
                "pass" => false,
                "failure" => "invalid_result_json",
                "error" => sprint(showerror, error),
                "exit_code" => proc.exitcode,
            )
        end
        protocol_valid =
            get(result, "schema", nothing) == 1 &&
            get(result, "case", nothing) == case_name
        configured_gates = CONFIG["gates"]
        gates = get(result, "gates", Dict())
        gates_valid = all(
            gate -> get(configured_gates, gate, false) === true &&
                    get(gates, gate, false) === true,
            REQUIRED_GATES,
        )
        budgets = get(result, "budgets", Dict())
        budgets_valid =
            !isempty(budgets) &&
            all(value -> value === true, values(budgets))
        result["exit_code"] = proc.exitcode
        result["stderr"] = stderr
        result["pass"] =
            get(result, "pass", false) === true &&
            proc.exitcode == 0 &&
            protocol_valid &&
            get(result, "phase", nothing) == "complete" &&
            gates_valid &&
            budgets_valid
        protocol_valid || (result["failure"] = "invalid_result_protocol")
        gates_valid || (result["failure"] = "required_gate_failed")
        budgets_valid || (result["failure"] = "budget_failed")
        return result
    finally
        isopen(out_io) && close(out_io)
        isopen(err_io) && close(err_io)
        rm(out_path; force=true)
        rm(err_path; force=true)
        temporary_artifact_root &&
            rm(child_artifact_root; recursive=true, force=true)
    end
end

CONFIG["schema"] == 1 || error("unsupported capability schema")
all(gate -> get(CONFIG["gates"], gate, false) === true, REQUIRED_GATES) ||
    error("all certification gates must be explicitly enabled")
function main()
    length(ARGS) == 1 ||
        error("usage: run_certification.jl ARTIFACT_ROOT")
    artifact_root = abspath(only(ARGS))
    mkpath(artifact_root)
    candidate_tiers = sort(filter(
        pair -> get(pair.second, "status", "") == "candidate",
        collect(CONFIG["tiers"]),
    ); by=first)
    cases = reduce(
        vcat,
        [String.(tier.second["cases"]) for tier in candidate_tiers];
        init=String[],
    )
    length(unique(cases)) == length(cases) ||
        error("certification cases must be unique across candidate tiers")
    suite_started = time()
    results = Any[]
    for case in cases
        remaining = SUITE_DEADLINE_SECONDS - (time() - suite_started)
        if remaining <= 0
            push!(results, Dict(
                "schema" => 1,
                "case" => case,
                "pass" => false,
                "failure" => "suite_timeout",
            ))
        else
            push!(results, run_child(
                case,
                remaining;
                artifact_root=artifact_root,
            ))
        end
    end
    summary = Dict(
        "schema" => 1,
        "profile" => CONFIG["profile"],
        "pass" => all(result -> result["pass"] === true, results),
        "elapsed_seconds" => time() - suite_started,
        "results" => results,
    )
    println(JSON.json(summary, 2))
    return summary["pass"] ? 0 : 1
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && exit(main())
