using Base64
using JSON
using Pkg
using SHA
using Snapshot
using TOML
using WasmTarget

include(joinpath(@__DIR__, "evidence_utils.jl"))
include(joinpath(@__DIR__, "snapshot_certification_support.jl"))
using .JumpCertificationEvidence
using .JumpSnapshotCertificationSupport

const ROOT = @__DIR__
const NOTEBOOK = joinpath(ROOT, "notebooks", "00_moi_values.jl")
const CANARY_SOURCE = joinpath(ROOT, "canaries", "00_moi_values.jl")
const NEGATIVE_NOTEBOOK =
    joinpath(ROOT, "notebooks", "00_negative_unsupported.jl")
const ENVIRONMENT = joinpath(ROOT, "snapshot")
const CONFIG = TOML.parsefile(joinpath(ROOT, "capabilities.toml"))
const DEADLINE_SECONDS = Float64(CONFIG["budgets"]["snapshot_export_wall_seconds"])
const OUTPUT_LIMIT_BYTES = Int(CONFIG["budgets"]["child_output_bytes_hard"])
const CASE_IDS = sort!([
    "moi_affine_value",
    "moi_quadratic_value",
    "moi_set_value",
    "ordered_dict_value",
])

assert_environment_provenance() =
    JumpSnapshotCertificationSupport.assert_environment_provenance(
        ENVIRONMENT,
        ROOT,
    )

function export_variant(output_dir; single_file, negative=false)
    mkpath(output_dir)
    html = Snapshot.export_notebook(
        negative ? NEGATIVE_NOTEBOOK : NOTEBOOK;
        output_dir,
        env_dir=ENVIRONMENT,
        optimize=:size,
        single_file,
    )
    stem = negative ? "00_negative_unsupported" : "00_moi_values"
    report_path = joinpath(output_dir, "$stem.islands", "report.json")
    report_bytes = single_file ? embedded_report(html).bytes : read(report_path)
    # `String(::Vector{UInt8})` may take ownership of and empty the vector.
    # Preserve the retained raw bytes because their digest is promotion evidence.
    report = JSON.parse(String(copy(report_bytes)))
    group = if negative
        length(report) == 1 ||
            error("expected one negative bond group, found $(length(report))")
        candidate = only(report)
        candidate["judgement"] == "fallback" ||
            error(
                "unsupported fixture expected fallback, got " *
                string(candidate["judgement"]),
            )
        candidate["reasons"] == ["no cells compiled"] ||
            error("unexpected group rejection reasons: $(candidate["reasons"])")
        length(candidate["cells"]) == 1 ||
            error("unsupported fixture expected exactly one claimed cell")
        cell = only(candidate["cells"])
        cell["ok"] === false ||
            error("unsupported fixture unexpectedly shipped its claimed cell")
        diagnostic = cell["diag"]
        diagnostic isa AbstractDict ||
            error("unsupported fixture has no machine-readable diagnostic")
        diagnostic["kind"] == "unsupported_method" ||
            error("unexpected diagnostic kind: $(diagnostic["kind"])")
        diagnostic["construct"] == "unknown function call (no handler arm)" ||
            error("unexpected unsupported construct: $(diagnostic["construct"])")
        diagnostic["cell"] === nothing ||
            error("unsupported diagnostic unexpectedly claimed another cell")
        cell["id"] == "0b000004-0000-4000-8000-000000000004" ||
            error("unsupported fixture failed in the wrong cell")
        cell["code"] == "deliberately_unsupported(Int64(x))" ||
            error("unsupported fixture source contract changed")
        candidate
    else
        assert_full_island(report)
    end
    return Dict(
        "html" => html,
        "report" => single_file ? "embedded" : report_path,
        "report_sha256" => bytes2hex(sha256(report_bytes)),
        "judgement" => group["judgement"],
        "cells" => length(group["cells"]),
        "single_file" => single_file,
        "negative" => negative,
        "diagnostic_kind" =>
            negative ? only(group["cells"])["diag"]["kind"] : nothing,
    )
end

function run_variant_child(
    name,
    output_dir;
    deadline_seconds=DEADLINE_SECONDS,
    ready_path=nothing,
    startup_deadline_seconds=30.0,
)
    return run_export_child(
        @__FILE__,
        name,
        output_dir;
        environment=ENVIRONMENT,
        deadline_seconds,
        output_limit_bytes=OUTPUT_LIMIT_BYTES,
        ready_path,
        startup_deadline_seconds,
    )
end

function child_main()
    _, name, output_dir, result_path = ARGS
    if name == "__timeout_fixture__"
        pid_path = ENV["WT_JUMP_SNAPSHOT_TIMEOUT_PID_FILE"]
        grandchild = run(
            `$(Base.julia_cmd()) --startup-file=no -e 'sleep(60)'`;
            wait=false,
        )
        write(pid_path, string(getpid(grandchild)))
        sleep(60)
        return
    end
    result = export_variant(
        output_dir;
        single_file=name in ("portable", "negative_portable"),
        negative=name in ("negative", "negative_portable"),
    )
    write(result_path, JSON.json(result, 2))
end

function main()
    get(ENV, "WT_VALIDATE", "") == "1" ||
        error("WT_VALIDATE=1 is required for Snapshot certification")
    wasm_tools = Sys.which("wasm-tools")
    wasm_tools === nothing &&
        error("wasm-tools is required for independent Snapshot validation")
    length(ARGS) == 1 || error("usage: run_snapshot_t0.jl OUTPUT_DIR")
    output_root = abspath(only(ARGS))
    rm(output_root; recursive=true, force=true)
    mkpath(output_root)
    manifest_path = joinpath(ENVIRONMENT, "Manifest.toml")
    snapshot = assert_environment_provenance()
    result = Dict(
        "schema" => 2,
        "runtime" => Dict(
            "julia" => string(VERSION),
            "os" => canonical_os(),
            "canonical_arch" => canonical_arch(),
            "kernel" => string(Sys.KERNEL),
            "arch" => string(Sys.ARCH),
        ),
        "wasmtarget" => git_provenance(pathof(WasmTarget)),
        "snapshot" => snapshot,
        # Pkg may refresh a manifest with native line endings. Preserve the
        # committed environment's cross-platform text identity.
        "manifest_sha256" => canonical_text_sha256(manifest_path),
        "validator" => Dict(
            "path" => wasm_tools,
            "version" => strip(read(`$wasm_tools --version`, String)),
        ),
        "binaryen_jll" => package_provenance("Binaryen_jll"),
        "source_contract" => Dict(
            "case_ids" => CASE_IDS,
            "notebook_sha256" => bytes2hex(sha256(read(NOTEBOOK))),
            "negative_notebook_sha256" =>
                bytes2hex(sha256(read(NEGATIVE_NOTEBOOK))),
            "canary_sha256" => bytes2hex(sha256(read(CANARY_SOURCE))),
        ),
        "split" => run_variant_child("split", joinpath(output_root, "split")),
        "portable" =>
            run_variant_child("portable", joinpath(output_root, "portable")),
        "negative" =>
            run_variant_child("negative", joinpath(output_root, "negative")),
        "negative_portable" => run_variant_child(
            "negative_portable",
            joinpath(output_root, "negative_portable"),
        ),
    )
    result["wt_sha"] = result["wasmtarget"]["sha"]
    write(joinpath(output_root, "exports.json"), JSON.json(result, 2))
    println(JSON.json(result, 2))
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    if !isempty(ARGS) && first(ARGS) == "--child"
        child_main()
    else
        main()
    end
end
