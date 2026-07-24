using JSON
using SHA
using Snapshot
using TOML
using WasmTarget

include(joinpath(@__DIR__, "evidence_utils.jl"))
include(joinpath(@__DIR__, "materialize_notebook.jl"))
include(joinpath(@__DIR__, "snapshot_certification_support.jl"))

using .JumpCertificationEvidence
using .JumpNotebookMaterialization
using .JumpSnapshotCertificationSupport

const ROOT = @__DIR__
const ENVIRONMENT = joinpath(ROOT, "snapshot")
const NOTEBOOK_ENVIRONMENT = joinpath(ROOT, "f1_notebook")
const CONFIG = TOML.parsefile(joinpath(ROOT, "capabilities.toml"))
const DEADLINE_SECONDS =
    Float64(CONFIG["budgets"]["snapshot_export_wall_seconds"])
const OUTPUT_LIMIT_BYTES =
    Int(CONFIG["budgets"]["child_output_bytes_hard"])
const SPECS = Dict(
    "f1a" => (
        profile="moi-runtime-nullable-layouts-v1",
        template=joinpath(ROOT, "notebooks", "01_f1a_nullable_layouts.jl"),
        source=joinpath(
            ROOT,
            "canaries",
            "f1",
            "00_nullable_layouts.jl",
        ),
        stem="01_f1a_nullable_layouts",
        case_ids=["f1_nullable_objective_layout"],
        bonds=["state", "x_slot"],
        cells=3,
    ),
    "f1b" => (
        profile="moi-runtime-parallel-vectors-v1",
        template=joinpath(ROOT, "notebooks", "02_f1b_parallel_vectors.jl"),
        source=joinpath(
            ROOT,
            "canaries",
            "f1",
            "01_parallel_vector_lifecycle.jl",
        ),
        stem="02_f1b_parallel_vectors",
        case_ids=[
            "f1_parallel_variable_layout",
            "f1_vector_reference_lifecycle",
        ],
        bonds=["boundary", "mode"],
        cells=4,
    ),
)

include(SPECS["f1a"].source)
include(SPECS["f1b"].source)

function validate_wasm(bytes, output_dir)
    wasm_tools = Sys.which("wasm-tools")
    wasm_tools === nothing &&
        error("wasm-tools is required for independent Snapshot validation")
    evidence_dir = joinpath(output_dir, "evidence")
    mkpath(evidence_dir)
    path = joinpath(evidence_dir, "retained-group.wasm")
    write(path, bytes)
    proc = run(ignorestatus(`$wasm_tools validate $path`))
    success(proc) || error("wasm-tools rejected retained Snapshot module")
    return (
        path=path,
        sha256=bytes2hex(sha256(bytes)),
        bytes=length(bytes),
    )
end

function export_variant(stage, delivery, output_dir; single_file)
    spec = SPECS[stage]
    mkpath(output_dir)
    evidence_dir = joinpath(output_dir, "evidence")
    mkpath(evidence_dir)
    source_notebook = materialize_notebook(
        spec.template,
        joinpath(evidence_dir, "materialized-source.jl"),
        NOTEBOOK_ENVIRONMENT,
        [spec.source],
    )
    materialized = joinpath(output_dir, "$(spec.stem).jl")
    cp(source_notebook, materialized; force=true)
    read(materialized) == read(source_notebook) ||
        error("$stage execution copy differs before Snapshot export")
    html = Snapshot.export_notebook(
        materialized;
        output_dir,
        optimize=:size,
        single_file,
    )
    report_path = joinpath(output_dir, "$(spec.stem).islands", "report.json")
    assets = single_file ? embedded_assets(html) : nothing
    report_bytes = single_file ?
                   only(
        bytes for (path, bytes) in assets if endswith(path, "report.json")
    ) : read(report_path)
    report = JSON.parse(String(copy(report_bytes)))
    group = assert_full_island(report)
    sort!(String.(group["bonds"])) == spec.bonds ||
        error("$stage export has the wrong bond set")
    length(group["cells"]) == spec.cells ||
        error("$stage export has the wrong interactive cell count")
    wasm_bytes = single_file ?
                 only(
        bytes for (path, bytes) in assets if endswith(path, ".wasm")
    ) : read(joinpath(output_dir, "$(spec.stem).islands", "group_0.wasm"))
    prefix = "$stage/$delivery"
    delivered_wasm_path = single_file ?
                          "embedded" :
                          "$prefix/$(spec.stem).islands/group_0.wasm"
    retained = validate_wasm(wasm_bytes, output_dir)
    return Dict(
        "profile" => spec.profile,
        "html" => "$prefix/$(basename(html))",
        "notebook" =>
            "$prefix/evidence/$(basename(source_notebook))",
        "notebook_sha256" => bytes2hex(sha256(read(source_notebook))),
        "exported_notebook" => "$prefix/$(basename(materialized))",
        "exported_notebook_sha256" =>
            bytes2hex(sha256(read(materialized))),
        "report" => single_file ?
                    "embedded" :
                    "$prefix/$(spec.stem).islands/report.json",
        "report_sha256" => bytes2hex(sha256(report_bytes)),
        "wasm" => "$prefix/evidence/$(basename(retained.path))",
        "delivered_wasm" => delivered_wasm_path,
        "wasm_sha256" => retained.sha256,
        "wasm_bytes" => retained.bytes,
        "judgement" => group["judgement"],
        "bonds" => sort!(String.(group["bonds"])),
        "cells" => length(group["cells"]),
        "single_file" => single_file,
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
    stage, delivery = split(name, '_'; limit=2)
    haskey(SPECS, stage) || error("unknown F1 Snapshot stage: $stage")
    delivery in ("split", "portable") ||
        error("unknown F1 Snapshot delivery: $delivery")
    result = export_variant(
        stage,
        delivery,
        output_dir;
        single_file=delivery == "portable",
    )
    write(result_path, JSON.json(result, 2))
end

function expected_ledger()
    f1a = [
        Dict(
            # PlutoUI Slider serializes range positions into the DOM. The
            # zero-based semantic state therefore occupies one-based slot
            # state + 1; x_slot is already one-based.
            "controls" =>
                Dict("state" => state + Int64(1), "x_slot" => x_slot),
            "semantic_inputs" => Dict("state" => state, "x" => x),
            "expected" => Dict(
                "f1_nullable_objective_layout" => string(
                    JumpF1NullableLayoutCanaries.EXPECTED[(state, x)],
                ),
            ),
        )
        for state in Int64(0):Int64(3)
        for (x_slot, x) in
            enumerate(JumpF1NullableLayoutCanaries.BOUNDARY_X)
    ]
    f1b = [
        Dict(
            "controls" => Dict(
                "mode" => mode + Int64(1),
                "boundary" => boundary,
            ),
            "semantic_inputs" => Dict("mode" => mode, "n" => n),
            "expected" => Dict(
                "f1_parallel_variable_layout" => string(
                    JumpF1ParallelVectorCanaries.PARALLEL_EXPECTED[
                        (mode, n)
                    ],
                ),
                "f1_vector_reference_lifecycle" => string(
                    JumpF1ParallelVectorCanaries.REFERENCE_EXPECTED[
                        (min(mode, Int64(3)), n)
                    ],
                ),
            ),
        )
        for mode in Int64(0):Int64(5)
        for (boundary, n) in
            enumerate(JumpF1ParallelVectorCanaries.BOUNDARY_N)
    ]
    return Dict("f1a" => f1a, "f1b" => f1b)
end

function source_contract()
    return Dict(
        stage => Dict(
            "profile" => spec.profile,
            "case_ids" => spec.case_ids,
            "template_sha256" => canonical_text_sha256(spec.template),
            "canary_sha256" => canonical_text_sha256(spec.source),
        )
        for (stage, spec) in SPECS
    )
end

function main()
    get(ENV, "WT_VALIDATE", "") == "1" ||
        error("WT_VALIDATE=1 is required for Snapshot certification")
    wasm_tools = Sys.which("wasm-tools")
    wasm_tools === nothing &&
        error("wasm-tools is required for independent Snapshot validation")
    length(ARGS) == 1 || error("usage: run_snapshot_f1.jl OUTPUT_DIR")
    output_root = abspath(only(ARGS))
    rm(output_root; recursive=true, force=true)
    mkpath(output_root)
    manifest_path = joinpath(ENVIRONMENT, "Manifest.toml")
    notebook_manifest = joinpath(NOTEBOOK_ENVIRONMENT, "Manifest.toml")
    result = Dict(
        "schema" => 1,
        "profile" => "moi-runtime-f1-snapshot-v1",
        "expected_versions" => Dict(
            key => CONFIG["versions"][key]
            for key in (
                "node",
                "playwright",
                "chromium",
                "firefox",
                "wasm_tools",
            )
        ),
        "resource_contract" => CONFIG["resource"]["f1_browser"],
        "runtime" => Dict(
            "julia" => string(VERSION),
            "os" => canonical_os(),
            "canonical_arch" => canonical_arch(),
            "kernel" => string(Sys.KERNEL),
            "arch" => string(Sys.ARCH),
        ),
        "wasmtarget" => git_provenance(pathof(WasmTarget)),
        "snapshot" => assert_environment_provenance(ENVIRONMENT, ROOT),
        "manifest_sha256" => canonical_text_sha256(manifest_path),
        "notebook_manifest_sha256" =>
            canonical_text_sha256(notebook_manifest),
        "validator" => Dict(
            "path" => wasm_tools,
            "version" => strip(read(`$wasm_tools --version`, String)),
        ),
        "binaryen_jll" => package_provenance("Binaryen_jll"),
        "nodejs_24_jll" => package_provenance("NodeJS_24_jll"),
        "source_contract" => source_contract(),
        "expected_ledger" => expected_ledger(),
        "f1a" => Dict{String,Any}(
            "split" => run_variant_child(
                "f1a_split",
                joinpath(output_root, "f1a", "split"),
            ),
            "portable" => run_variant_child(
                "f1a_portable",
                joinpath(output_root, "f1a", "portable"),
            ),
        ),
        "f1b" => Dict{String,Any}(
            "split" => run_variant_child(
                "f1b_split",
                joinpath(output_root, "f1b", "split"),
            ),
            "portable" => run_variant_child(
                "f1b_portable",
                joinpath(output_root, "f1b", "portable"),
            ),
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
