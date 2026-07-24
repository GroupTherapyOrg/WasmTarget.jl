using JSON
using SHA
using TOML

length(ARGS) == 1 ||
    error("usage: verify_f1_browser_promotion.jl ARTIFACT_ROOT")

include(joinpath(@__DIR__, "evidence_utils.jl"))
include(joinpath(@__DIR__, "materialize_notebook.jl"))
include(joinpath(@__DIR__, "snapshot_certification_support.jl"))
include(joinpath(@__DIR__, "canaries", "f1", "00_nullable_layouts.jl"))
include(joinpath(
    @__DIR__,
    "canaries",
    "f1",
    "01_parallel_vector_lifecycle.jl",
))

using .JumpCertificationEvidence
using .JumpNotebookMaterialization
using .JumpSnapshotCertificationSupport

const ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const ARTIFACT_ROOT = abspath(only(ARGS))
const CONFIG = TOML.parsefile(joinpath(@__DIR__, "capabilities.toml"))
const EXPECTED_ARTIFACTS = Dict(
    "jump-snapshot-browser-ubuntu-latest" => "linux",
    "jump-snapshot-browser-macos-latest" => "macos",
    "jump-snapshot-browser-windows-latest" => "windows",
)
const EXPECTED_TUPLES = Set(
    (browser, stage, delivery)
    for browser in ("chromium", "firefox")
    for stage in ("f1a", "f1b")
    for delivery in ("split-http", "single-file")
)
const SOURCE_SPECS = Dict(
    "f1a" => (
        profile="moi-runtime-nullable-layouts-v1",
        stem="01_f1a_nullable_layouts",
        template=joinpath(
            @__DIR__,
            "notebooks",
            "01_f1a_nullable_layouts.jl",
        ),
        canary=joinpath(
            @__DIR__,
            "canaries",
            "f1",
            "00_nullable_layouts.jl",
        ),
        cases=["f1_nullable_objective_layout"],
        bonds=["state", "x_slot"],
        cells=3,
        cell_ids=[
            "1a000009-0000-4000-8000-000000000009",
            "1a000006-0000-4000-8000-000000000006",
            "1a000007-0000-4000-8000-000000000007",
        ],
        outputs=7,
        defaults=Dict("state" => 1, "x_slot" => 5),
    ),
    "f1b" => (
        profile="moi-runtime-parallel-vectors-v1",
        stem="02_f1b_parallel_vectors",
        template=joinpath(
            @__DIR__,
            "notebooks",
            "02_f1b_parallel_vectors.jl",
        ),
        canary=joinpath(
            @__DIR__,
            "canaries",
            "f1",
            "01_parallel_vector_lifecycle.jl",
        ),
        cases=[
            "f1_parallel_variable_layout",
            "f1_vector_reference_lifecycle",
        ],
        bonds=["boundary", "mode"],
        cells=4,
        cell_ids=[
            "1b000007-0000-4000-8000-000000000007",
            "1b000008-0000-4000-8000-000000000008",
            "1b000009-0000-4000-8000-000000000009",
            "1b000010-0000-4000-8000-000000000010",
        ],
        outputs=8,
        defaults=Dict("mode" => 1, "boundary" => 3),
    ),
)
const NOTEBOOK_ENVIRONMENT = joinpath(@__DIR__, "f1_notebook")
const SNAPSHOT_ENVIRONMENT = joinpath(@__DIR__, "snapshot")

fail(message) = error("F1 browser promotion rejected: $message")
require(condition, message) = condition || fail(message)
is_sha256(value) =
    value isa AbstractString && occursin(r"^[0-9a-f]{64}$", value)

function safe_file(root, relative, label)
    require(
        relative isa AbstractString && !isabspath(relative),
        "$label path must be relative",
    )
    require(!occursin('\\', relative), "$label path uses a backslash")
    candidate = normpath(joinpath(root, relative))
    rel = relpath(candidate, root)
    require(
        !isabspath(rel) && !startswith(rel, ".."),
        "$label path escapes its export",
    )
    current = root
    for component in splitpath(rel)
        current = joinpath(current, component)
        require(!islink(current), "$label path contains a symlink")
    end
    require(isfile(candidate), "$label file is missing")
    resolved = realpath(candidate)
    resolved_root = realpath(root)
    resolved_rel = relpath(resolved, resolved_root)
    require(
        !isabspath(resolved_rel) && !startswith(resolved_rel, ".."),
        "$label resolves outside its export",
    )
    return resolved
end

function exactly_one_file(root, filename)
    matches = String[]
    for (dir, dirs, files) in walkdir(root)
        filter!(name -> !islink(joinpath(dir, name)), dirs)
        filename in files && push!(matches, joinpath(dir, filename))
    end
    require(length(matches) == 1, "expected exactly one $filename in $root")
    require(!islink(only(matches)), "$filename must not be a symlink")
    return realpath(only(matches))
end

function expected_ledger()
    f1a = [
        Dict(
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
                    JumpF1ParallelVectorCanaries.PARALLEL_EXPECTED[(mode, n)],
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

function manifest_entry(path, name)
    dependencies = TOML.parsefile(path)["deps"]
    require(haskey(dependencies, name), "$name is absent from $path")
    entries = dependencies[name]
    entries isa AbstractVector || (entries = [entries])
    require(length(entries) == 1, "$name is ambiguous in $path")
    return only(entries)
end

function validate_package_provenance(actual, manifest_path, name)
    entry = manifest_entry(manifest_path, name)
    require(actual["name"] == name, "$name provenance has wrong name")
    require(
        actual["version"] == entry["version"],
        "$name provenance has wrong version",
    )
    expected_tree = get(entry, "git-tree-sha1", nothing)
    require(
        actual["tree_hash"] == expected_tree,
        "$name provenance has wrong tree hash",
    )
end

function validate_report(report, stage)
    spec = SOURCE_SPECS[stage]
    require(report isa AbstractVector, "$stage report is not an array")
    require(length(report) == 1, "$stage report has multiple bond groups")
    group = only(report)
    require(group["judgement"] == "island", "$stage report degraded")
    require(isempty(group["reasons"]), "$stage report contains reasons")
    require(
        sort!(String.(group["bonds"])) == spec.bonds,
        "$stage report has the wrong bonds",
    )
    require(
        length(group["cells"]) == spec.cells &&
        all(cell -> cell["ok"] === true, group["cells"]) &&
        [String(cell["id"]) for cell in group["cells"]] == spec.cell_ids,
        "$stage report has failed or unexpected cells",
    )
    return group
end

function validate_materialized_notebook(variant, export_root, stage)
    spec = SOURCE_SPECS[stage]
    notebook = safe_file(
        export_root,
        variant["notebook"],
        "$stage materialized notebook",
    )
    require(
        bytes2hex(sha256(read(notebook))) == variant["notebook_sha256"],
        "$stage materialized notebook digest mismatch",
    )
    mktempdir() do temp
        reconstructed = materialize_notebook(
            spec.template,
            joinpath(temp, "$(spec.stem).jl"),
            NOTEBOOK_ENVIRONMENT,
            [spec.canary],
        )
        require(
            read(reconstructed) == read(notebook),
            "$stage materialized notebook differs from committed inputs",
        )
    end
end

function validate_export(exports, export_root, expected_os, sha, wasm_tools)
    require(exports["schema"] == 1, "wrong export schema")
    require(
        exports["profile"] == "moi-runtime-f1-snapshot-v1",
        "wrong export profile",
    )
    require(
        exports["wt_sha"] == sha &&
        exports["wasmtarget"]["sha"] == sha &&
        exports["wasmtarget"]["dirty"] === false,
        "export is not tied to the clean promotion checkout",
    )
    require(exports["runtime"]["os"] == expected_os, "wrong export OS")
    require(
        exports["runtime"]["julia"] == CONFIG["versions"]["julia"],
        "wrong Julia version",
    )
    expected_versions = Dict(
        key => CONFIG["versions"][key]
        for key in (
            "node",
            "playwright",
            "chromium",
            "firefox",
            "wasm_tools",
        )
    )
    require(
        exports["expected_versions"] == expected_versions,
        "export version contract changed",
    )
    require(
        exports["resource_contract"] == CONFIG["resource"]["f1_browser"],
        "export resource contract changed",
    )
    require(
        exports["manifest_sha256"] ==
            canonical_text_sha256(
                joinpath(SNAPSHOT_ENVIRONMENT, "Manifest.toml"),
            ) &&
        exports["notebook_manifest_sha256"] ==
            canonical_text_sha256(
                joinpath(NOTEBOOK_ENVIRONMENT, "Manifest.toml"),
            ),
        "export manifest digest differs from the committed environment",
    )
    require(
        exports["expected_ledger"] == expected_ledger(),
        "export semantic ledger differs from committed Julia oracles",
    )
    require(
        exports["nodejs_24_jll"]["version"] ==
            CONFIG["versions"]["nodejs_24_jll"],
        "wrong bundled Node JLL",
    )
    validate_package_provenance(
        exports["snapshot"],
        joinpath(SNAPSHOT_ENVIRONMENT, "Manifest.toml"),
        "Snapshot",
    )
    validate_package_provenance(
        exports["binaryen_jll"],
        joinpath(SNAPSHOT_ENVIRONMENT, "Manifest.toml"),
        "Binaryen_jll",
    )
    validate_package_provenance(
        exports["nodejs_24_jll"],
        joinpath(SNAPSHOT_ENVIRONMENT, "Manifest.toml"),
        "NodeJS_24_jll",
    )
    require(
        is_wasm_tools_version(
            exports["validator"]["version"],
            CONFIG["versions"]["wasm_tools"],
        ),
        "export used the wrong wasm-tools version",
    )
    for stage in ("f1a", "f1b")
        spec = SOURCE_SPECS[stage]
        source = exports["source_contract"][stage]
        require(
            source["profile"] == spec.profile &&
            source["case_ids"] == spec.cases &&
            source["template_sha256"] ==
                canonical_text_sha256(spec.template) &&
            source["canary_sha256"] ==
                canonical_text_sha256(spec.canary),
            "$stage source contract differs from committed sources",
        )
        for delivery in ("split", "portable")
            variant = exports[stage][delivery]
            require(variant["judgement"] == "island", "$stage degraded")
            require(
                variant["bonds"] == spec.bonds &&
                variant["cells"] == spec.cells &&
                variant["single_file"] == (delivery == "portable"),
                "$stage/$delivery export contract changed",
            )
            validate_materialized_notebook(
                variant,
                export_root,
                stage,
            )
            require(is_sha256(variant["wasm_sha256"]), "bad Wasm digest")
            retained_wasm = safe_file(
                export_root,
                variant["wasm"],
                "$stage/$delivery retained Wasm",
            )
            retained_bytes = read(retained_wasm)
            require(
                bytes2hex(sha256(retained_bytes)) ==
                    variant["wasm_sha256"],
                "$stage/$delivery retained Wasm digest mismatch",
            )
            require(
                length(retained_bytes) == variant["wasm_bytes"],
                "$stage/$delivery retained Wasm size mismatch",
            )
            require(
                success(pipeline(
                    ignorestatus(`$wasm_tools validate $retained_wasm`);
                    stdout=devnull,
                    stderr=devnull,
                )),
                "$stage/$delivery retained Wasm failed validation",
            )
            html = safe_file(
                export_root,
                variant["html"],
                "$stage/$delivery HTML",
            )
            report_bytes = nothing
            delivered_bytes = nothing
            if delivery == "split"
                require(
                    variant["report"] != "embedded" &&
                    variant["delivered_wasm"] != "embedded",
                    "$stage split delivery uses embedded markers",
                )
                report_path = safe_file(
                    export_root,
                    variant["report"],
                    "$stage split report",
                )
                delivered_wasm = safe_file(
                    export_root,
                    variant["delivered_wasm"],
                    "$stage split delivered Wasm",
                )
                report_bytes = read(report_path)
                delivered_bytes = read(delivered_wasm)
            else
                require(
                    variant["report"] == "embedded" &&
                    variant["delivered_wasm"] == "embedded",
                    "$stage portable delivery lacks embedded markers",
                )
                assets = embedded_assets(html)
                reports = [
                    bytes for (path, bytes) in assets
                    if endswith(path, "report.json")
                ]
                modules = [
                    bytes for (path, bytes) in assets
                    if endswith(path, ".wasm")
                ]
                require(
                    length(reports) == 1 && length(modules) == 1,
                    "$stage portable asset registry is ambiguous",
                )
                report_bytes = only(reports)
                delivered_bytes = only(modules)
            end
            require(
                bytes2hex(sha256(report_bytes)) ==
                    variant["report_sha256"],
                "$stage/$delivery delivered report digest mismatch",
            )
            validate_report(
                JSON.parse(String(copy(report_bytes))),
                stage,
            )
            require(
                delivered_bytes == retained_bytes,
                "$stage/$delivery delivered Wasm differs from retained evidence",
            )
        end
    end
end

function validate_browser(browser, exports, export_root, expected_os, sha)
    require(
        browser["schema"] == 2 &&
        browser["profile"] == "moi-runtime-f1-snapshot-browser-v2" &&
        browser["pass"] === true,
        "browser summary failed or changed schema",
    )
    require(
        browser["wt_sha"] == sha &&
        browser["wasmtarget"] == exports["wasmtarget"],
        "browser evidence is not linked to the exact checkout",
    )
    require(
        browser["source_contract"] == exports["source_contract"] &&
        browser["manifest_sha256"] == exports["manifest_sha256"] &&
        browser["notebook_manifest_sha256"] ==
            exports["notebook_manifest_sha256"],
        "browser/export source or manifest identity differs",
    )
    require(
        browser["binaryen_jll"] == exports["binaryen_jll"] &&
        browser["nodejs_24_jll"] == exports["nodejs_24_jll"] &&
        browser["snapshot"] == exports["snapshot"],
        "browser/export toolchain identity differs",
    )
    require(
        browser["export_runtime"] == exports["runtime"],
        "browser is paired with the wrong export runtime",
    )
    runtime = browser["browser_runtime"]
    require(runtime["os"] == expected_os, "wrong browser OS")
    require(
        runtime["canonical_arch"] ==
            exports["runtime"]["canonical_arch"],
        "browser/export architecture differs",
    )
    require(runtime["node"] == "v$(CONFIG["versions"]["node"])", "wrong Node")
    require(
        runtime["playwright"] == CONFIG["versions"]["playwright"],
        "wrong Playwright",
    )
    require(
        browser["resource_contract"] == CONFIG["resource"]["f1_browser"],
        "browser resource contract changed",
    )
    require(
        browser["validator"] == exports["validator"],
        "browser/export validator identity differs",
    )
    expected_report_sha = Dict(
        stage => Dict(
            delivery => exports[stage][delivery]["report_sha256"]
            for delivery in ("split", "portable")
        )
        for stage in ("f1a", "f1b")
    )
    expected_wasm_sha = Dict(
        stage => Dict(
            delivery => exports[stage][delivery]["wasm_sha256"]
            for delivery in ("split", "portable")
        )
        for stage in ("f1a", "f1b")
    )
    require(
        browser["report_sha256"] == expected_report_sha &&
        browser["wasm_sha256"] == expected_wasm_sha,
        "browser/export report or Wasm identity differs",
    )
    tuples = [
        (row["browser"], row["stage"], row["delivery"])
        for row in browser["evidence"]
    ]
    require(
        length(tuples) == length(unique(tuples)) &&
        Set(tuples) == EXPECTED_TUPLES,
        "browser/stage/delivery matrix is incomplete or duplicated",
    )
    ledgers = exports["expected_ledger"]
    contract = browser["resource_contract"]
    for row in browser["evidence"]
        spec = SOURCE_SPECS[row["stage"]]
        require(row["pass"] === true, "browser evidence row failed")
        require(
            row["browser_version"] ==
                CONFIG["versions"][row["browser"]],
            "wrong $(row["browser"]) version",
        )
        ledger = ledgers[row["stage"]]
        require(
            row["exhaustive_cases"] == length(ledger),
            "wrong exhaustive case count",
        )
        require(
            row["same_page_rounds"] == contract["same_page_rounds"] &&
            row["fresh_pages"] == contract["fresh_pages"] &&
            length(row["instances"]) == contract["fresh_pages"],
            "wrong repeated-instance coverage",
        )
        expected_wasm_requests =
            row["delivery"] == "split-http" ?
            contract["split_wasm_requests_per_page"] :
            contract["single_file_wasm_requests_per_page"]
        for (instance_index, instance) in enumerate(row["instances"])
            require(
                instance["instance"] == instance_index,
                "fresh-instance identity changed",
            )
            require(
                instance["initial_controls"] == spec.defaults,
                "fresh instance has wrong default controls",
            )
            initial_row = only(filter(
                ledger_row ->
                    ledger_row["controls"] == spec.defaults,
                ledger,
            ))
            require(
                instance["initial_cases"] == initial_row["expected"],
                "fresh instance has wrong initial semantic output",
            )
            require(
                instance["dom"] == Dict(
                    "bonds" => length(spec.bonds),
                    "cases" => length(spec.cases),
                    "outputs" => spec.outputs,
                ),
                "fresh instance has wrong DOM topology",
            )
            require(
                isempty(instance["page_errors"]) &&
                isempty(instance["console_errors"]) &&
                isempty(instance["failed_requests"]),
                "fresh instance contains runtime diagnostics",
            )
            require(
                instance["page_closed"] === true &&
                instance["context_pages_after_page_close"] == 0 &&
                instance["context_closed"] === true,
                "fresh page or browser context was not closed",
            )
            require(
                instance["wasm_requests"] == expected_wasm_requests,
                "wrong Wasm request count",
            )
            expected_response_digests =
                row["delivery"] == "split-http" ?
                [exports[row["stage"]]["split"]["wasm_sha256"]] :
                String[]
            require(
                instance["wasm_response_sha256"] ==
                    expected_response_digests,
                "browser consumed unexpected Wasm bytes",
            )
            calls = instance["wasm_runtime_calls"]
            expected_calls = row["delivery"] == "split-http" ?
                Dict(
                    "compile" => 0,
                    "compileStreaming" => 1,
                    "instantiate" => 1,
                    "instantiateStreaming" => 0,
                ) :
                Dict(
                    "compile" => 1,
                    "compileStreaming" => 0,
                    "instantiate" => 1,
                    "instantiateStreaming" => 0,
                )
            require(
                calls == expected_calls &&
                all(
                    value -> value isa Integer && value >= 0,
                    values(calls),
                ) &&
                sum(calls[key] for key in ("compile", "compileStreaming")) ==
                    contract["wasm_compile_calls_per_page"] &&
                sum(calls[key] for key in ("instantiate", "instantiateStreaming")) ==
                    contract["wasm_instantiate_calls_per_page"],
                "wrong per-page Wasm lifecycle counts",
            )
            require(
                length(instance["rounds"]) == contract["same_page_rounds"],
                "same-page rounds are incomplete",
            )
            for (index, round) in enumerate(instance["rounds"])
                require(round["round"] == index, "round ordering changed")
                require(
                    round["transitions"] == length(ledger) &&
                    length(round["observations"]) == length(ledger),
                    "browser observation count differs from the Julia ledger",
                )
                for (actual, expected) in
                    zip(round["observations"], ledger)
                    require(
                        actual["controls"] == expected["controls"] &&
                        actual["semantic_inputs"] ==
                            expected["semantic_inputs"] &&
                        actual["observed"] == expected["expected"],
                        "browser observation differs from the Julia ledger",
                    )
                end
                require(
                    round["dom"] == instance["dom"],
                    "DOM topology changed during repeated execution",
                )
            end
            should_have_screenshot =
                instance_index == contract["fresh_pages"]
            require(
                (instance["screenshot"] !== nothing) ==
                    should_have_screenshot &&
                (instance["screenshot_sha256"] !== nothing) ==
                    should_have_screenshot,
                "screenshot count or placement changed",
            )
            if should_have_screenshot
                screenshot = safe_file(
                    export_root,
                    instance["screenshot"],
                    "browser screenshot",
                )
                bytes = read(screenshot)
                require(
                    length(bytes) >= 8 &&
                    bytes[1:8] ==
                        UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
                    "browser screenshot is not a PNG",
                )
                require(
                    bytes2hex(sha256(bytes)) ==
                        instance["screenshot_sha256"],
                    "browser screenshot digest mismatch",
                )
            end
        end
    end
end

require(isdir(ARTIFACT_ROOT), "artifact root is missing")
require(!islink(ARTIFACT_ROOT), "artifact root must not be a symlink")
entries = Set(readdir(ARTIFACT_ROOT))
require(
    entries == Set(keys(EXPECTED_ARTIFACTS)),
    "artifact root must contain exactly the three platform artifacts",
)
sha = strip(read(`git -C $ROOT rev-parse HEAD`, String))
require(
    isempty(strip(read(`git -C $ROOT status --porcelain --untracked-files=no`, String))),
    "promotion verifier checkout has tracked modifications",
)
wasm_tools = Sys.which("wasm-tools")
require(wasm_tools !== nothing, "wasm-tools is unavailable")
require(
    occursin(
        CONFIG["versions"]["wasm_tools"],
        strip(read(`$wasm_tools --version`, String)),
    ),
    "wrong wasm-tools version",
)

observed_oses = String[]
for (artifact, expected_os) in EXPECTED_ARTIFACTS
    artifact_root = joinpath(ARTIFACT_ROOT, artifact)
    require(isdir(artifact_root), "$artifact is not a directory")
    require(!islink(artifact_root), "$artifact is a symlink")
    export_path = exactly_one_file(artifact_root, "exports.json")
    browser_path =
        exactly_one_file(artifact_root, "jump-snapshot-f1-browser.json")
    export_root = dirname(export_path)
    require(
        dirname(browser_path) == export_root,
        "browser summary is not paired with its F1 export",
    )
    exports = JSON.parsefile(export_path)
    browser = JSON.parsefile(browser_path)
    validate_export(exports, export_root, expected_os, sha, wasm_tools)
    validate_browser(browser, exports, export_root, expected_os, sha)
    push!(observed_oses, expected_os)
end
require(
    Set(observed_oses) == Set(values(EXPECTED_ARTIFACTS)),
    "cross-platform browser matrix is incomplete",
)

println(JSON.json(Dict(
    "schema" => 1,
    "profile" => "moi-runtime-f1-browser-promotion-v1",
    "pass" => true,
    "wt_sha" => sha,
    "oses" => sort!(observed_oses),
    "artifacts" => sort!(collect(keys(EXPECTED_ARTIFACTS))),
), 2))
