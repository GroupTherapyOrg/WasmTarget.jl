using TOML

include(joinpath(@__DIR__, "browser_certification_runner.jl"))
using .JumpBrowserCertificationRunner

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

function run_browser_child(
    export_root;
    deadline_seconds=DEADLINE_SECONDS,
    ready_path=nothing,
    startup_deadline_seconds=30.0,
)
    return JumpBrowserCertificationRunner.run_browser_child(
        export_root;
        root=ROOT,
        browser_script=BROWSER_SCRIPT,
        timeout_fixture_script=TIMEOUT_FIXTURE_SCRIPT,
        deadline_seconds,
        output_limit_bytes=OUTPUT_LIMIT_BYTES,
        ready_path,
        startup_deadline_seconds,
    )
end

function main()
    run_browser_main(
        ARGS;
        root=ROOT,
        browser_script=BROWSER_SCRIPT,
        timeout_fixture_script=TIMEOUT_FIXTURE_SCRIPT,
        deadline_seconds=DEADLINE_SECONDS,
        output_limit_bytes=OUTPUT_LIMIT_BYTES,
        usage="usage: run_browser_t0.jl EXPORT_ROOT",
    )
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
