using JSON

include(joinpath(@__DIR__, "run_certification.jl"))
include(joinpath(
    @__DIR__,
    "canaries",
    "f1",
    "01_parallel_vector_lifecycle.jl",
))

const F1B_PROFILE = "moi-storage-vector-lifecycle-v1"
const F1B_CASES =
    sort!(collect(keys(JumpF1ParallelVectorCanaries.CASES)))

function main_f1b()
    length(ARGS) == 1 ||
        error("usage: run_f1b_certification.jl ARTIFACT_ROOT")
    artifact_root = abspath(only(ARGS))
    mkpath(artifact_root)
    suite_started = time()
    results = Any[]
    for case in F1B_CASES
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
                case_profile=F1B_PROFILE,
            ))
        end
    end
    summary = Dict(
        "schema" => 1,
        "profile" => F1B_PROFILE,
        "evidence_kind" => "executed_native_differential",
        "pass" => all(result -> result["pass"] === true, results),
        "elapsed_seconds" => time() - suite_started,
        "results" => results,
    )
    output = joinpath(artifact_root, "jump-f1b-certification.json")
    write(output, JSON.json(summary, 2))
    println(JSON.json(summary, 2))
    return summary["pass"] ? 0 : 1
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && exit(main_f1b())
