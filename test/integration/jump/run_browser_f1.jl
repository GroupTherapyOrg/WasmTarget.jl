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
    normpath(joinpath(ROOT, "..", "..", "browser", "jump_f1.mjs"))
const TIMEOUT_FIXTURE_SCRIPT =
    normpath(joinpath(ROOT, "..", "..", "browser", "jump_timeout_tree.mjs"))

function main()
    run_browser_main(
        ARGS;
        root=ROOT,
        browser_script=BROWSER_SCRIPT,
        timeout_fixture_script=TIMEOUT_FIXTURE_SCRIPT,
        deadline_seconds=DEADLINE_SECONDS,
        output_limit_bytes=OUTPUT_LIMIT_BYTES,
        usage="usage: run_browser_f1.jl EXPORT_ROOT",
    )
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
