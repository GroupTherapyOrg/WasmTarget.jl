using Base64
using JSON
using SHA
using TOML
using WasmTarget

length(ARGS) == 1 || error("usage: verify_t0_promotion.jl ARTIFACT_ROOT")
include(joinpath(@__DIR__, "..", "..", "utils.jl"))
include(joinpath(@__DIR__, "canaries", "00_moi_values.jl"))
include(joinpath(@__DIR__, "evidence_utils.jl"))
using .JumpCertificationEvidence
using .JumpMOIValueCanaries

const ARTIFACT_ROOT = abspath(only(ARGS))
const CONFIG = TOML.parsefile(joinpath(@__DIR__, "capabilities.toml"))
const EXPECTED_OSES = Set(["linux", "macos", "windows"])
const EXPECTED_ARCHES = Set(["x86_64", "aarch64"])
const EXPECTED_CANDIDATE_TIERS = Set(["moi_values", "runtime_collections"])
const REQUIRED_GATES = Set([
    "native_oracle",
    "raw_wasm",
    "optimize_size",
    "optimize_speed",
    "unexpected_skip_is_failure",
    "independent_validation",
])
const REQUIRED_RUNS = Set(["raw", "size", "speed"])
const EXPECTED_CORE_CASE_PROFILE = "t0"
const EXPECTED_CASE_IDS = sort!([
    "moi_affine_value",
    "moi_quadratic_value",
    "moi_set_value",
    "ordered_dict_value",
])
const EXPECTED_NOTEBOOK_CELL_IDS = Set([
    "0a000008-0000-4000-8000-000000000008",
    "0a000009-0000-4000-8000-000000000009",
    "0a000009-0000-4000-8000-000000000019",
    "0a000009-0000-4000-8000-000000000029",
    "0a000010-0000-4000-8000-000000000010",
])
const REQUIRED_EVIDENCE = Set([
    "core_moi_prerequisites",
    "snapshot_browser_moi_prerequisites",
])
const EXPECTED_DELIVERIES = Set([
    (browser, delivery)
    for browser in ("chromium", "firefox")
    for delivery in (
        "split-http",
        "single-file",
        "negative-split-http",
        "negative-single-file",
    )
])
const ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const CORE_MANIFEST = joinpath(@__DIR__, "Manifest.toml")
const SNAPSHOT_MANIFEST =
    joinpath(@__DIR__, "snapshot", "Manifest.toml")
const CANARY_SOURCE =
    joinpath(@__DIR__, "canaries", "00_moi_values.jl")
const NOTEBOOK_SOURCE =
    joinpath(@__DIR__, "notebooks", "00_moi_values.jl")
const NEGATIVE_NOTEBOOK_SOURCE =
    joinpath(@__DIR__, "notebooks", "00_negative_unsupported.jl")

fail(message) = error("T0 promotion rejected: $message")
require(condition, message) = condition || fail(message)
is_sha256(value) = value isa AbstractString && occursin(r"^[0-9a-f]{64}$", value)
is_git_sha(value) = value isa AbstractString && occursin(r"^[0-9a-f]{40}$", value)

function checkout_sha()
    return strip(read(`git -C $ROOT rev-parse HEAD`, String))
end

function manifest_entry(path, name)
    dependencies = TOML.parsefile(path)["deps"]
    entries = dependencies[name]
    entries isa AbstractVector || (entries = [entries])
    return only(entries)
end

function evidence_files(filename)
    files = String[]
    for (root, _, names) in walkdir(ARTIFACT_ROOT)
        filename in names && push!(files, joinpath(root, filename))
    end
    return sort(files)
end

function only_value(values, label)
    unique_values = Set(values)
    length(unique_values) == 1 ||
        fail("$label mismatch: $unique_values")
    return only(unique_values)
end

function function_name(signature)
    signature isa Symbol && return string(signature)
    signature isa Expr || return nothing
    if signature.head == :call
        return string(first(signature.args))
    elseif signature.head == :(::)
        return function_name(first(signature.args))
    elseif signature.head == :where
        return function_name(first(signature.args))
    end
    return nothing
end

function function_contract(path)
    contracts = Dict{String,String}()
    function visit(node)
        node isa Expr || return
        if node.head == :function
            name = function_name(first(node.args))
            if name in EXPECTED_CASE_IDS
                normalized = deepcopy(node)
                Base.remove_linenums!(normalized)
                contracts[name] =
                    bytes2hex(sha256(sprint(show, normalized)))
            end
        end
        foreach(visit, node.args)
    end
    visit(Meta.parseall(read(path, String)))
    return contracts
end

function canonical_semantic_ledger(result)
    ledgers = Pair{String,String}[]
    for case in result["results"]
        lines = String["case=$(case["case"])"]
        for (index, variant) in enumerate(case["variants"])
            push!(lines, "variant.$index.args=$(JSON.json(variant["args"]))")
            push!(lines, "variant.$index.native=$(JSON.json(variant["native"]))")
            for run in ("raw", "size", "speed")
                push!(
                    lines,
                    "variant.$index.$run=" *
                    JSON.json(variant["runs"][run]["actual"]),
                )
            end
        end
        push!(
            ledgers,
            case["case"] => bytes2hex(sha256(join(lines, "\n"))),
        )
    end
    sort!(ledgers; by=first)
    return join(("$(pair.first)=$(pair.second)" for pair in ledgers), "\n")
end

function module_digest_ledger(result)
    return Dict(
        case["case"] => Dict(
            run => case["compile"]["module_sha256"][run]
            for run in sort!(collect(REQUIRED_RUNS))
        )
        for case in result["results"]
    )
end

function independent_node_version()
    invocation = WasmRunner._NODE
    invocation === nothing && fail("Node runtime is unavailable to promotion")
    executable = first(invocation.exec)
    return strip(read(`$executable --version`, String))
end

function independent_wasm_tools()
    executable = Sys.which("wasm-tools")
    executable === nothing && fail("wasm-tools is unavailable to promotion")
    version = strip(read(`$executable --version`, String))
    require(
        is_wasm_tools_version(version, CONFIG["versions"]["wasm_tools"]),
        "promotion used wrong wasm-tools version: $version",
    )
    return (executable=executable, version=version)
end

function require_clean_verifier_checkout()
    tracked = read(
        `git -C $ROOT status --porcelain --untracked-files=no`,
        String,
    )
    isempty(tracked) ||
        fail("promotion verifier checkout has tracked modifications")
end

function path_is_within(path, root)
    relative = relpath(path, root)
    parts = splitpath(relative)
    return !isabspath(relative) && !isempty(parts) && first(parts) != ".."
end

function validate_core(result, result_path)
    require(result["schema"] == 1, "invalid core schema")
    require(result["pass"] === true, "core prerequisite artifact did not pass")
    require(
        result["profile"] == CONFIG["profile"],
        "wrong core profile $(result["profile"])",
    )

    candidate_tiers = filter(
        pair -> get(pair.second, "status", "") == "candidate",
        collect(CONFIG["tiers"]),
    )
    require(
        Set(first.(candidate_tiers)) == EXPECTED_CANDIDATE_TIERS,
        "T0 candidate tier set changed",
    )
    expected_cases = Set(reduce(
        vcat,
        [String.(tier.second["cases"]) for tier in candidate_tiers];
        init=String[],
    ))
    cases = result["results"]
    actual_cases = [case["case"] for case in cases]
    require(
        length(actual_cases) == length(unique(actual_cases)),
        "duplicate core cases",
    )
    require(Set(actual_cases) == expected_cases, "wrong core case set")
    source_functions = function_contract(CANARY_SOURCE)
    require(
        Set(keys(source_functions)) == Set(EXPECTED_CASE_IDS),
        "committed canary source does not define every exact T0 case",
    )

    property_config = CONFIG["property"]
    versions = CONFIG["versions"]
    expected_seed = property_config["seed"]
    expected_random = 64
    for case in cases
        require(case["schema"] == 1 && case["pass"] === true, "case failed")
        require(case["phase"] == "complete", "case did not complete")
        require(
            Set(keys(case["gates"])) == REQUIRED_GATES &&
            all(==(true), values(case["gates"])),
            "required gate missing or false in $(case["case"])",
        )
        require(
            !isempty(case["budgets"]) && all(==(true), values(case["budgets"])),
            "budget failed in $(case["case"])",
        )
        property = case["property"]
        expected_inputs =
            case["case"] == "ordered_dict_value" ?
            property_config["integer_inputs"] : property_config["float_inputs"]
        require(property["kind"] == "bounded_deterministic", "wrong property kind")
        require(property["seed"] == expected_seed, "wrong property seed")
        require(property["random_samples"] == expected_random, "wrong random count")
        require(property["executed_inputs"] == expected_inputs, "wrong input count")
        require(property["bounded"] === true, "property domain is not bounded")
        require(length(case["variants"]) == expected_inputs, "input ledger truncated")
        require(
            Set(keys(case["compile"]["module_sha256"])) == REQUIRED_RUNS &&
            all(is_sha256, values(case["compile"]["module_sha256"])),
            "invalid module identity ledger",
        )
        module_files = case["compile"]["module_files"]
        require(
            Set(keys(module_files)) == REQUIRED_RUNS,
            "retained module file ledger is incomplete",
        )
        artifact_root = realpath(dirname(result_path))
        retained_modules = Dict{String,Vector{UInt8}}()
        for run in REQUIRED_RUNS
            relative = module_files[run]
            relative isa AbstractString && !isabspath(relative) ||
                fail("retained module path must be relative")
            module_path = normpath(joinpath(artifact_root, relative))
            require(
                path_is_within(module_path, artifact_root),
                "retained module path escapes its artifact",
            )
            require(isfile(module_path), "retained $run module is missing")
            require(!islink(module_path), "retained $run module is a symlink")
            resolved_module_path = realpath(module_path)
            require(
                path_is_within(resolved_module_path, artifact_root),
                "retained $run module resolves outside its artifact",
            )
            bytes = read(resolved_module_path)
            retained_modules[run] = bytes
            require(
                length(bytes) >= 8 && bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d],
                "retained $run module has invalid Wasm magic",
            )
            require(
                bytes2hex(sha256(bytes)) ==
                case["compile"]["module_sha256"][run],
                "retained $run module digest mismatch",
            )
            byte_limit =
                run == "raw" ?
                Int(CONFIG["budgets"]["raw_wasm_bytes_hard"]) :
                Int(CONFIG["budgets"]["optimized_wasm_bytes_hard"])
            require(
                length(bytes) <= byte_limit,
                "retained $run module exceeds its byte budget",
            )
            require(
                all(
                    variant ->
                        variant["runs"][run]["wasm_bytes"] == length(bytes),
                    case["variants"],
                ),
                "retained $run module size differs from its execution ledger",
            )
            require(
                success(pipeline(
                    ignorestatus(
                        `$(PROMOTION_WASM_TOOLS.executable) validate $resolved_module_path`,
                    ),
                    stdout=devnull,
                    stderr=devnull,
                )),
                "retained $run module failed independent validation",
            )
        end
        require(
            WasmTarget.optimize(retained_modules["raw"]; level=:size) ==
            retained_modules["size"],
            "retained size module is not the pinned optimizer output of raw",
        )
        require(
            WasmTarget.optimize(retained_modules["raw"]; level=:speed) ==
            retained_modules["speed"],
            "retained speed module is not the pinned optimizer output of raw",
        )
        input_digest = bytes2hex(sha256(JSON.json([
            variant["args"] for variant in case["variants"]
        ])))
        expected_digest =
            case["case"] == "ordered_dict_value" ?
            property_config["integer_input_ledger_sha256"] :
            property_config["float_input_ledger_sha256"]
        require(input_digest == expected_digest, "wrong generated input ledger")
        for variant in case["variants"]
            require(length(variant["args"]) == 1, "non-scalar T0 input")
            require(Set(keys(variant["runs"])) == REQUIRED_RUNS, "variant run missing")
            fresh_native = try
                JumpMOIValueCanaries.CASES[case["case"]].f(
                    variant["args"]...,
                )
            catch error
                fail(
                    "fresh native oracle failed for $(case["case"]): " *
                    sprint(showerror, error),
                )
            end
            require(
                variant["native"] == fresh_native,
                "recorded native result diverges from fresh committed oracle",
            )
            require(
                all(run -> run["pass"] === true, values(variant["runs"])),
                "variant diverged from native",
            )
            require(
                all(
                    run -> haskey(run, "actual") &&
                           run["actual"] == variant["native"],
                    values(variant["runs"]),
                ),
                "claimed pass does not match actual/native values",
            )
            for run in REQUIRED_RUNS
                actual = try
                    run_wasm_with_imports(
                        retained_modules[run],
                        case["case"],
                        Dict("Math" => Dict("pow" => "Math.pow")),
                        variant["args"]...,
                    )
                catch error
                    fail(
                        "independent execution failed for " *
                        "$(case["case"]) $run: $(sprint(showerror, error))",
                    )
                end
                require(
                    actual == fresh_native,
                    "retained $(case["case"]) $run module diverges from fresh native",
                )
            end
        end

        provenance = case["provenance"]
        require(provenance["julia"] == versions["julia"], "wrong Julia version")
        require(provenance["jump"] == versions["jump"], "wrong JuMP version")
        require(
            provenance["math_opt_interface"] == versions["math_opt_interface"],
            "wrong MathOptInterface version",
        )
        require(
            provenance["node"]["version"] == "v$(versions["node"])",
            "wrong Node version",
        )
        require(is_wasm_tools_version(
            provenance["wasm_tools"]["version"],
            versions["wasm_tools"],
        ), "wrong wasm-tools version")
        require(
            provenance["binaryen_jll"] == versions["binaryen_jll"],
            "wrong Binaryen_jll version",
        )
        require(
            provenance["independent_validation"] === true,
            "independent validation disabled",
        )
        require(
            provenance["os"] in EXPECTED_OSES &&
            provenance["canonical_arch"] in EXPECTED_ARCHES,
            "unsupported core platform identity",
        )
        require(
            provenance["wasmtarget"]["dirty"] === false,
            "core used a dirty WasmTarget checkout",
        )
        expected_contract = Dict(
            "profile" => EXPECTED_CORE_CASE_PROFILE,
            "case_ids" => EXPECTED_CASE_IDS,
            "canary_sha256" => bytes2hex(sha256(read(CANARY_SOURCE))),
            "functions" => source_functions,
        )
        require(
            provenance["source_contract"] == expected_contract,
            "core evidence is not tied to the committed canary contract",
        )
    end

    os = only_value(
        (case["provenance"]["os"] for case in cases),
        "core OS within artifact",
    )
    arch = only_value(
        (case["provenance"]["canonical_arch"] for case in cases),
        "core architecture within artifact",
    )
    manifest = only_value(
        (case["provenance"]["manifest_sha256"] for case in cases),
        "core manifest within artifact",
    )
    sha = only_value(
        (case["provenance"]["wasmtarget"]["sha"] for case in cases),
        "core WasmTarget SHA within artifact",
    )
    require(is_sha256(manifest), "invalid core manifest digest")
    require(is_git_sha(sha), "invalid core WasmTarget SHA")
    return (
        os=os,
        arch=arch,
        manifest=manifest,
        sha=sha,
        semantic_ledger=canonical_semantic_ledger(result),
        module_digests=module_digest_ledger(result),
    )
end

function embedded_report_bytes(html_path)
    source = read(html_path, String)
    match_result = match(
        r"""atob\("([A-Za-z0-9+/=]+)"\).*?__snapshotEmbeddedAssets"""s,
        source,
    )
    require(match_result !== nothing, "portable export has no embedded registry")
    files = JSON.parse(String(base64decode(only(match_result.captures))))
    report_key = only(filter(key -> endswith(key, "report.json"), keys(files)))
    return base64decode(files[report_key])
end

function raw_snapshot_contract(exports_path, exports)
    root = dirname(exports_path)
    split_path = joinpath(root, "split", "00_moi_values.islands", "report.json")
    negative_path =
        joinpath(root, "negative", "00_negative_unsupported.islands", "report.json")
    negative_portable_path =
        joinpath(root, "negative_portable", "00_negative_unsupported.html")
    portable_path = joinpath(root, "portable", "00_moi_values.html")
    all(isfile, (
        split_path,
        negative_path,
        portable_path,
        negative_portable_path,
    )) ||
        fail("raw Snapshot export artifacts are incomplete")
    split_bytes = read(split_path)
    portable_bytes = embedded_report_bytes(portable_path)
    negative_bytes = read(negative_path)
    negative_portable_bytes = embedded_report_bytes(negative_portable_path)
    # Preserve the retained bytes for the independent digest check below:
    # `String(::Vector{UInt8})` may take ownership of its input.
    split = JSON.parse(String(copy(split_bytes)))
    portable = JSON.parse(String(copy(portable_bytes)))
    negative = JSON.parse(String(copy(negative_bytes)))
    negative_portable =
        JSON.parse(String(copy(negative_portable_bytes)))
    for (label, report) in (("split", split), ("portable", portable))
        require(length(report) == 1, "$label raw report group count changed")
        group = only(report)
        require(
            group["bonds"] == ["x"] &&
            group["arg_types"] == ["Float64"] &&
            group["judgement"] == "island" &&
            group["oracle_samples"] == 5 &&
            isempty(group["reasons"]) &&
            length(group["cells"]) == 5 &&
            Set(cell["id"] for cell in group["cells"]) ==
            EXPECTED_NOTEBOOK_CELL_IDS &&
            all(cell -> cell["ok"] === true, group["cells"]),
            "$label raw report is not the exact full-island contract",
        )
    end
    for (label, report) in (
        ("negative split", negative),
        ("negative portable", negative_portable),
    )
        require(length(report) == 1, "$label report group count changed")
        group = only(report)
        cell = only(group["cells"])
        diagnostic = cell["diag"]
        require(
            group["bonds"] == ["x"] &&
            group["arg_types"] == ["Int64"] &&
            group["judgement"] == "fallback" &&
            group["oracle_samples"] == 0 &&
            group["reasons"] == ["no cells compiled"] &&
            length(group["cells"]) == 1 &&
            cell["id"] == "0b000004-0000-4000-8000-000000000004" &&
            cell["code"] == "deliberately_unsupported(Int64(x))" &&
            cell["ok"] === false &&
            diagnostic["kind"] == "unsupported_method" &&
            diagnostic["cell"] === nothing &&
            diagnostic["construct"] == "unknown function call (no handler arm)",
            "$label report did not fail loudly at the intended Any-dispatch boundary",
        )
    end
    digests = Dict(
        "split" => bytes2hex(sha256(split_bytes)),
        "portable" => bytes2hex(sha256(portable_bytes)),
        "negative" => bytes2hex(sha256(negative_bytes)),
        "negative_portable" =>
            bytes2hex(sha256(negative_portable_bytes)),
    )
    require(
        digests["split"] == exports["split"]["report_sha256"] &&
        digests["portable"] == exports["portable"]["report_sha256"] &&
        digests["negative"] == exports["negative"]["report_sha256"] &&
        digests["negative_portable"] ==
        exports["negative_portable"]["report_sha256"],
        "raw Snapshot report digest does not match export summary",
    )
    return digests
end

function validate_browser(result, result_path, exports_path, exports)
    require(result["schema"] == 2 && result["pass"] === true, "browser failed")
    versions = CONFIG["versions"]
    export_runtime = result["export_runtime"]
    browser_runtime = result["browser_runtime"]
    require(export_runtime["julia"] == versions["julia"], "wrong export Julia")
    require(
        export_runtime["os"] == browser_runtime["os"],
        "browser/export OS mismatch",
    )
    for (key, label) in (
        ("export_runtime", "runtime"),
        ("wasmtarget", "WasmTarget"),
        ("snapshot", "Snapshot"),
        ("binaryen_jll", "Binaryen_jll"),
        ("source_contract", "source contract"),
        ("validator", "validator"),
    )
        export_key = key == "export_runtime" ? "runtime" : key
        require(
            result[key] == exports[export_key],
            "browser $label evidence differs from its paired export",
        )
    end
    require(
        result["wt_sha"] == exports["wt_sha"] &&
        result["manifest_sha256"] == exports["manifest_sha256"],
        "browser source/manifest identity differs from its paired export",
    )
    require(
        result["binaryen_jll"]["version"] == versions["binaryen_jll"],
        "wrong Snapshot Binaryen_jll version",
    )
    source_contract = result["source_contract"]
    require(
        source_contract["case_ids"] == EXPECTED_CASE_IDS,
        "wrong browser source case contract",
    )
    expected_notebook = bytes2hex(sha256(read(NOTEBOOK_SOURCE)))
    expected_negative_notebook =
        bytes2hex(sha256(read(NEGATIVE_NOTEBOOK_SOURCE)))
    expected_canary = bytes2hex(sha256(read(CANARY_SOURCE)))
    require(
        source_contract["notebook_sha256"] == expected_notebook &&
        source_contract["negative_notebook_sha256"] ==
        expected_negative_notebook &&
        source_contract["canary_sha256"] == expected_canary,
        "browser evidence is not tied to the committed sources",
    )
    notebook_contract = function_contract(NOTEBOOK_SOURCE)
    canary_contract = function_contract(CANARY_SOURCE)
    require(
        sort!(collect(keys(notebook_contract))) == EXPECTED_CASE_IDS &&
        notebook_contract == canary_contract,
        "Snapshot functions diverge from the certified core canaries",
    )
    require(
        export_runtime["canonical_arch"] == browser_runtime["canonical_arch"],
        "browser/export architecture mismatch",
    )
    require(
        export_runtime["os"] in EXPECTED_OSES &&
        export_runtime["canonical_arch"] in EXPECTED_ARCHES,
        "unsupported browser platform identity",
    )
    require(
        browser_runtime["node"] == "v$(versions["node"])",
        "wrong browser Node",
    )
    require(
        browser_runtime["playwright"] == versions["playwright"],
        "wrong Playwright",
    )
    require(is_wasm_tools_version(
        result["validator"]["version"],
        versions["wasm_tools"],
    ), "wrong browser validator")
    require(
        result["wasmtarget"]["sha"] == result["wt_sha"] &&
        result["wasmtarget"]["dirty"] === false,
        "browser export did not use one clean WasmTarget revision",
    )
    positive = result["positive"]
    require(
        positive["split_judgement"] == "island" &&
        positive["portable_judgement"] == "island",
        "positive Snapshot export was not a full island",
    )
    require(
        positive["split_cells"] == 5 && positive["portable_cells"] == 5,
        "positive Snapshot export has the wrong cell count",
    )
    require(
        result["negative"]["judgement"] == "fallback" &&
        result["negative"]["portable_judgement"] == "fallback" &&
        result["negative"]["diagnostic_kind"] == "unsupported_method" &&
        result["negative"]["portable_diagnostic_kind"] ==
        "unsupported_method",
        "negative Snapshot contract changed",
    )
    for digest in values(result["report_sha256"])
        require(is_sha256(digest), "invalid positive report digest")
    end
    require(
        is_sha256(result["negative"]["report_sha256"]) &&
        is_sha256(result["negative"]["portable_report_sha256"]),
        "invalid negative report digest",
    )

    evidence = result["evidence"]
    tuples = [(row["browser"], row["delivery"]) for row in evidence]
    require(length(tuples) == length(unique(tuples)), "duplicate browser evidence")
    require(Set(tuples) == EXPECTED_DELIVERIES, "wrong browser evidence matrix")
    for row in evidence
        require(row["pass"] === true, "browser evidence row failed")
        require(
            row["browser_version"] == versions[row["browser"]],
            "wrong $(row["browser"]) version",
        )
        require(is_sha256(row["screenshot_sha256"]), "invalid screenshot digest")
        screenshot_path =
            joinpath(dirname(exports_path), "browser-evidence", row["screenshot"])
        require(isfile(screenshot_path), "retained browser screenshot missing")
        require(
            bytes2hex(sha256(read(screenshot_path))) == row["screenshot_sha256"],
            "browser screenshot digest mismatch",
        )
        screenshot_bytes = read(screenshot_path)
        require(
            length(screenshot_bytes) >= 24 &&
            screenshot_bytes[1:8] ==
            UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] &&
            screenshot_bytes[13:16] == collect(codeunits("IHDR")) &&
            foldl(
                (value, byte) -> (value << 8) | UInt32(byte),
                screenshot_bytes[17:20];
                init=UInt32(0),
            ) > 0 &&
            foldl(
                (value, byte) -> (value << 8) | UInt32(byte),
                screenshot_bytes[21:24];
                init=UInt32(0),
            ) > 0,
            "browser screenshot is not a nonempty PNG",
        )
        if startswith(row["delivery"], "negative-")
            require(
                row["expected_failure"] == "unsupported_method" &&
                occursin("static in this export", row["observed_status"]) &&
                row["observed_static_value"] == "10.5",
                "negative browser behavior changed",
            )
        else
            require(row["expected_input"] == 2.0, "wrong browser input")
            require(
                sort!(collect(keys(row["observed_cases"]))) == EXPECTED_CASE_IDS,
                "browser case ledger is incomplete",
            )
            require(
                row["observed_cases"] == Dict(
                    "moi_affine_value" => "7.0",
                    "moi_quadratic_value" => "-0.5",
                    "moi_set_value" => "10.25",
                    "ordered_dict_value" => "65",
                ),
                "browser case values changed",
            )
            require(
                row["observed_values"] == ["7.0", "-0.5", "10.25", "65"],
                "wrong browser values",
            )
        end
    end
    raw_digests = raw_snapshot_contract(exports_path, exports)
    require(
        result["report_sha256"]["split"] == raw_digests["split"] &&
        result["report_sha256"]["portable"] == raw_digests["portable"] &&
        result["negative"]["report_sha256"] == raw_digests["negative"] &&
        result["negative"]["portable_report_sha256"] ==
        raw_digests["negative_portable"],
        "browser summary is not linked to raw Snapshot reports",
    )
    require(is_sha256(result["manifest_sha256"]), "invalid Snapshot manifest digest")
    require(is_git_sha(result["wt_sha"]), "invalid browser WasmTarget SHA")
    require(
        is_git_sha(result["snapshot"]["tree_hash"]),
        "invalid Snapshot tree hash",
    )
    return (
        os=export_runtime["os"],
        arch=export_runtime["canonical_arch"],
        manifest=result["manifest_sha256"],
        sha=result["wt_sha"],
        snapshot_tree=result["snapshot"]["tree_hash"],
    )
end

required = Set(CONFIG["promotion"]["required_evidence"])
require(required == REQUIRED_EVIDENCE, "unknown promotion evidence configuration")
require(
    CONFIG["promotion"]["same_wasmtarget_sha"] === true &&
    CONFIG["promotion"]["same_snapshot_sha"] === true,
    "cross-artifact source identity gates must be enabled",
)

expected_wt_sha = checkout_sha()
expected_core_manifest = canonical_text_sha256(CORE_MANIFEST)
expected_snapshot_manifest = canonical_text_sha256(SNAPSHOT_MANIFEST)
expected_snapshot_entry = manifest_entry(SNAPSHOT_MANIFEST, "Snapshot")
expected_binaryen_entry = manifest_entry(SNAPSHOT_MANIFEST, "Binaryen_jll")
require(
    string(VERSION) == CONFIG["versions"]["julia"],
    "promotion used wrong Julia version: $VERSION",
)
require_clean_verifier_checkout()
verifier_node = independent_node_version()
require(
    verifier_node == "v$(CONFIG["versions"]["node"])",
    "promotion used wrong Node version: $verifier_node",
)
const PROMOTION_WASM_TOOLS = independent_wasm_tools()

core_files = evidence_files("jump-certification.json")
browser_files = evidence_files("jump-snapshot-browser.json")
exports_files = evidence_files("exports.json")
require(length(core_files) == 3, "expected three core artifacts")
require(length(browser_files) == 3, "expected three browser artifacts")
require(length(exports_files) == 3, "expected three raw Snapshot artifacts")
core = map(core_files) do path
    validate_core(JSON.parsefile(path), path)
end
exports_by_os = Dict(
    JSON.parsefile(path)["runtime"]["os"] => path
    for path in exports_files
)
require(
    Set(keys(exports_by_os)) == EXPECTED_OSES &&
    length(exports_by_os) == length(exports_files),
    "raw Snapshot artifacts do not contain one unique export per OS",
)
browser = map(browser_files) do path
    result = JSON.parsefile(path)
    os = result["export_runtime"]["os"]
    require(haskey(exports_by_os, os), "browser artifact has no raw exports")
    exports_path = exports_by_os[os]
    exports = JSON.parsefile(exports_path)
    validate_browser(result, path, exports_path, exports)
end

require(Set(item.os for item in core) == EXPECTED_OSES, "wrong core OS matrix")
require(Set(item.os for item in browser) == EXPECTED_OSES, "wrong browser OS matrix")
require(
    length(unique(item.os for item in core)) == 3 &&
    length(unique(item.os for item in browser)) == 3,
    "platform evidence is duplicated",
)
core_by_os = Dict(item.os => item for item in core)
browser_by_os = Dict(item.os => item for item in browser)
for os in EXPECTED_OSES
    require(core_by_os[os].arch == browser_by_os[os].arch, "$os arch mismatch")
    require(core_by_os[os].sha == browser_by_os[os].sha, "$os SHA mismatch")
end

wt_sha = only_value((item.sha for item in core), "WasmTarget SHA")
require(
    wt_sha == expected_wt_sha,
    "evidence revision does not match the verifier checkout",
)
require(
    Set(item.sha for item in browser) == Set([wt_sha]),
    "browser WasmTarget SHA mismatch",
)
core_manifest = only_value((item.manifest for item in core), "core manifest")
snapshot_manifest =
    only_value((item.manifest for item in browser), "Snapshot manifest")
snapshot_tree =
    only_value((item.snapshot_tree for item in browser), "Snapshot tree")
require(
    core_manifest == expected_core_manifest,
    "core evidence does not match the committed manifest",
)
require(
    snapshot_manifest == expected_snapshot_manifest,
    "Snapshot evidence does not match the committed manifest",
)
require(
    snapshot_tree == expected_snapshot_entry["git-tree-sha1"],
    "Snapshot evidence does not match the committed Snapshot tree",
)
for path in browser_files
    result = JSON.parsefile(path)
    require(
        result["binaryen_jll"]["tree_hash"] ==
        expected_binaryen_entry["git-tree-sha1"] &&
        result["binaryen_jll"]["version"] ==
        expected_binaryen_entry["version"],
        "Snapshot evidence does not match the committed Binaryen_jll",
    )
end
semantic_ledger = only_value(
    (item.semantic_ledger for item in core),
    "cross-platform semantic property ledger",
)
module_digests = Dict(
    item.os => Dict(
        "arch" => item.arch,
        "cases" => item.module_digests,
    )
    for item in core
)

summary = Dict(
    "schema" => 2,
    "pass" => true,
    "profile" => CONFIG["profile"],
    "evidence" => sort!(collect(required)),
    "platforms" => sort!(collect(EXPECTED_OSES)),
    "wasmtarget_sha" => wt_sha,
    "core_manifest_sha256" => core_manifest,
    "snapshot_tree" => snapshot_tree,
    "snapshot_manifest_sha256" => snapshot_manifest,
    # The semantic ledger is required to be identical across platforms. Module
    # bytes remain byte-exact, independently validated evidence within each
    # platform artifact, but are reported rather than conflated with behavioral
    # parity: Julia's platform-specific type metadata and identity hashes can
    # legitimately produce different valid Wasm encodings.
    "semantic_property_ledger_sha256" =>
        bytes2hex(sha256(semantic_ledger)),
    "module_digests_by_platform" => module_digests,
    "promotion_node" => verifier_node,
    "promotion_wasm_tools" => PROMOTION_WASM_TOOLS.version,
    "promotion_julia" => string(VERSION),
)
WasmRunner.shutdown_pool!()
println(JSON.json(summary, 2))
