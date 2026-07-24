using JSON
using Pkg
using SHA
using TOML
using WasmTarget

include(joinpath(@__DIR__, "..", "..", "utils.jl"))
include(joinpath(@__DIR__, "evidence_utils.jl"))
include(joinpath(@__DIR__, "canaries", "f1", "00_nullable_layouts.jl"))
include(joinpath(@__DIR__, "canaries", "f1", "01_parallel_vector_lifecycle.jl"))

using .JumpCertificationEvidence

const CONFIG = TOML.parsefile(joinpath(@__DIR__, "capabilities.toml"))
const EVIDENCE_KIND = "executed_native_differential"
const REQUIRED_RUNS = Set(["raw", "size", "speed"])
const CERTIFICATION_MANIFEST = joinpath(@__DIR__, "Manifest.toml")
const REQUIRED_GATES = Set([
    "native_oracle",
    "raw_wasm",
    "optimize_size",
    "optimize_speed",
    "unexpected_skip_is_failure",
    "independent_validation",
])
const REQUIRED_BUDGETS = Set([
    "compile_wall_threshold",
    "raw_wasm_bytes",
    "size_wasm_bytes",
    "speed_wasm_bytes",
])

const SPECS = Dict(
    "f1a" => (
        profile="moi-storage-runtime-shapes-v1",
        evidence_file="jump-f1-certification.json",
        artifact_prefix="jump-f1a",
        canary=joinpath(@__DIR__, "canaries", "f1", "00_nullable_layouts.jl"),
        cases=JumpF1NullableLayoutCanaries.CASES,
        provenance=JumpF1NullableLayoutCanaries.SOURCE_PROVENANCE,
    ),
    "f1b" => (
        profile="moi-storage-vector-lifecycle-v1",
        evidence_file="jump-f1b-certification.json",
        artifact_prefix="jump-f1b",
        canary=joinpath(
            @__DIR__,
            "canaries",
            "f1",
            "01_parallel_vector_lifecycle.jl",
        ),
        cases=JumpF1ParallelVectorCanaries.CASES,
        provenance=JumpF1ParallelVectorCanaries.SOURCE_PROVENANCE,
    ),
)
const STAGE = get(ENV, "WT_F1_PROMOTION_STAGE", "")
haskey(SPECS, STAGE) ||
    error("WT_F1_PROMOTION_STAGE must be f1a or f1b")
const SPEC = SPECS[STAGE]
const PROFILE = SPEC.profile
const CASE_IDS = sort!(collect(keys(SPEC.cases)))
const ARTIFACT_OS = Dict(
    "$(SPEC.artifact_prefix)-ubuntu-latest" => "linux",
    "$(SPEC.artifact_prefix)-macos-latest" => "macos",
    "$(SPEC.artifact_prefix)-windows-latest" => "windows",
)

fail(message) =
    error("$(uppercase(STAGE)) promotion rejected: $message")
require(condition, message) = condition || fail(message)

function evidence_files(root)
    require(isdir(root), "artifact root is missing")
    require(!islink(root), "artifact root must not be a symlink")
    resolved_root = realpath(root)
    entries = readdir(root)
    require(
        Set(entries) == Set(keys(ARTIFACT_OS)),
        "artifact root must contain exactly the three named platform artifacts",
    )
    files = String[]
    for artifact in keys(ARTIFACT_OS)
        artifact_dir = joinpath(root, artifact)
        require(isdir(artifact_dir), "artifact $artifact is not a directory")
        require(!islink(artifact_dir), "artifact $artifact is a symlink")
        resolved_artifact = realpath(artifact_dir)
        require(
            dirname(resolved_artifact) == resolved_root &&
            basename(resolved_artifact) == artifact,
            "artifact $artifact does not resolve to its exact named directory",
        )
        evidence = joinpath(artifact_dir, SPEC.evidence_file)
        require(isfile(evidence), "artifact $artifact is missing evidence")
        require(!islink(evidence), "artifact $artifact evidence is a symlink")
        resolved_evidence = realpath(evidence)
        require(
            dirname(resolved_evidence) == resolved_artifact &&
            basename(resolved_evidence) == SPEC.evidence_file,
            "artifact $artifact evidence resolves outside its directory",
        )
        push!(files, resolved_evidence)
    end
    return sort(files)
end

function exact_match(value, expected, context)
    require(
        typeof(value) === typeof(expected) && isequal(value, expected),
        "$context has the wrong value or JSON type",
    )
    return true
end

function package_version(uuid::Base.UUID)
    dependency = get(Pkg.dependencies(), uuid, nothing)
    dependency === nothing && return nothing
    return string(dependency.version)
end

function current_revision()
    root = dirname(dirname(dirname(@__DIR__)))
    sha = strip(read(`git -C $root rev-parse HEAD`, String))
    dirty = !isempty(strip(read(`git -C $root status --porcelain`, String)))
    require(!dirty, "promotion verifier checkout has tracked modifications")
    return sha
end

function path_is_within(path, root)
    relative = relpath(path, root)
    parts = splitpath(relative)
    return !isabspath(relative) && !isempty(parts) && first(parts) != ".."
end

function independent_wasm_tools()
    executable = Sys.which("wasm-tools")
    require(executable !== nothing, "wasm-tools is unavailable")
    version = strip(read(`$executable --version`, String))
    require(
        is_wasm_tools_version(version, CONFIG["versions"]["wasm_tools"]),
        "promotion used wrong wasm-tools version: $version",
    )
    return executable
end

function independent_node_version()
    invocation = WasmRunner._NODE
    invocation === nothing && fail("Node runtime is unavailable to promotion")
    executable = first(invocation.exec)
    return strip(read(`$executable --version`, String))
end

function expected_artifact_os(path, root)
    resolved_root = realpath(root)
    resolved_path = realpath(path)
    artifact_dir = dirname(resolved_path)
    require(
        dirname(artifact_dir) == resolved_root,
        "evidence is not contained in an exact named CI artifact directory",
    )
    artifact = basename(artifact_dir)
    haskey(ARTIFACT_OS, artifact) ||
        fail("unknown $(uppercase(STAGE)) artifact identity: $artifact")
    return ARTIFACT_OS[artifact]
end

function validate_module(executable, path)
    require(success(pipeline(
        ignorestatus(`$executable validate $path`);
        stdout=devnull,
        stderr=devnull,
    )), "wasm-tools rejected retained module $(basename(path))")
end

function function_name(signature)
    signature isa Symbol && return string(signature)
    signature isa Expr || return nothing
    if signature.head == :call
        return string(first(signature.args))
    elseif signature.head == :(::) || signature.head == :where
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
            if name in CASE_IDS
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

json_value(value) = JSON.parse(JSON.json(value))

function retained_modules(result, evidence_path, wasm_tools)
    compile = result["compile"]
    require(
        Set(keys(compile["module_files"])) == REQUIRED_RUNS,
        "retained module set changed",
    )
    require(
        Set(keys(compile["module_sha256"])) == REQUIRED_RUNS &&
        all(value -> value isa AbstractString &&
                     occursin(r"^[0-9a-f]{64}$", value),
            values(compile["module_sha256"])),
        "module digest set changed or is malformed",
    )
    artifact_root = realpath(dirname(evidence_path))
    modules = Dict{String,Vector{UInt8}}()
    for label in REQUIRED_RUNS
        relative = compile["module_files"][label]
        relative isa AbstractString && !isabspath(relative) ||
            fail("retained module path must be relative")
        module_path = normpath(joinpath(artifact_root, relative))
        require(
            path_is_within(module_path, artifact_root),
            "retained $label module path escapes its artifact",
        )
        require(isfile(module_path), "retained $label module is missing")
        require(!islink(module_path), "retained $label module is a symlink")
        resolved = realpath(module_path)
        require(
            path_is_within(resolved, artifact_root),
            "retained $label module resolves outside its artifact",
        )
        bytes = read(resolved)
        modules[label] = bytes
        require(
            length(bytes) >= 8 &&
            bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d],
            "retained $label module has invalid Wasm magic",
        )
        require(
            bytes2hex(sha256(bytes)) ==
            compile["module_sha256"][label],
            "retained $label module digest mismatch",
        )
        limit =
            label == "raw" ?
            Int(CONFIG["budgets"]["raw_wasm_bytes_hard"]) :
            Int(CONFIG["budgets"]["optimized_wasm_bytes_hard"])
        require(
            length(bytes) <= limit,
            "retained $label module exceeds its byte budget",
        )
        require(
            all(
                variant ->
                    exact_match(
                        variant["runs"][label]["wasm_bytes"],
                        Int64(length(bytes)),
                        "retained $label module size",
                    ),
                result["variants"],
            ),
            "retained $label module size differs from its execution ledger",
        )
        validate_module(wasm_tools, resolved)
    end
    require(
        WasmTarget.optimize(modules["raw"]; level=:size) == modules["size"],
        "retained size module is not the pinned optimizer output of raw",
    )
    require(
        WasmTarget.optimize(modules["raw"]; level=:speed) == modules["speed"],
        "retained speed module is not the pinned optimizer output of raw",
    )
    return modules
end

function verify_document(
    path,
    artifact_root,
    expected_revision,
    expected_manifest,
    wasm_tools,
)
    document = JSON.parsefile(path)
    exact_match(document["schema"], Int64(1), "summary schema")
    require(document["profile"] == PROFILE, "wrong summary profile")
    require(document["evidence_kind"] == EVIDENCE_KIND,
            "compile-only or unknown evidence is ineligible")
    require(document["pass"] === true, "summary did not pass")
    results = document["results"]
    require(length(results) == length(CASE_IDS),
            "wrong result count")
    require(
        sort!([result["case"] for result in results]) == CASE_IDS,
        "result case set changed",
    )
    provenance = first(results)["provenance"]
    versions = CONFIG["versions"]
    require(provenance["julia"] == versions["julia"], "wrong Julia version")
    require(provenance["math_opt_interface"] ==
            versions["math_opt_interface"], "wrong MOI version")
    require(provenance["jump"] == versions["jump"], "wrong JuMP version")
    require(provenance["binaryen_jll"] ==
            versions["binaryen_jll"], "wrong Binaryen_jll version")
    require(provenance["node"]["version"] ==
            "v$(versions["node"])", "wrong Node version")
    require(is_wasm_tools_version(
        provenance["wasm_tools"]["version"],
        versions["wasm_tools"],
    ), "wrong wasm-tools version")
    require(provenance["independent_validation"] === true,
            "independent validation was not enabled")
    require(provenance["wasmtarget"]["sha"] == expected_revision,
            "evidence revision does not match verifier checkout")
    require(provenance["wasmtarget"]["dirty"] === false,
            "evidence came from a dirty checkout")
    require(
        provenance["manifest_sha256"] == expected_manifest,
        "evidence was produced from a different certification manifest",
    )
    expected_os = expected_artifact_os(path, artifact_root)
    require(
        provenance["os"] == expected_os,
        "artifact identity does not match its claimed OS",
    )

    contract = provenance["source_contract"]
    expected_contract = Dict(
        "profile" => PROFILE,
        "case_ids" => CASE_IDS,
        "canary_sha256" => bytes2hex(sha256(read(SPEC.canary))),
        "functions" => function_contract(SPEC.canary),
    )
    require(
        contract == expected_contract,
        "evidence is not tied to the exact committed source contract",
    )

    expected_source = json_value(SPEC.provenance)
    for result in results
        case_id = result["case"]
        case_spec = SPEC.cases[case_id]
        exact_match(result["schema"], Int64(1), "result schema")
        require(result["profile"] == PROFILE, "wrong result profile")
        require(result["evidence_kind"] == EVIDENCE_KIND,
                "result is not executed native differential evidence")
        require(result["phase"] == "complete", "result is incomplete")
        require(result["pass"] === true, "result did not pass")
        exact_match(result["exit_code"], Int64(0), "case exit code")
        require(isempty(result["stderr"]),
                "case emitted unexpected stderr")
        require(Set(keys(result["gates"])) == REQUIRED_GATES,
                "required gate set changed")
        require(all(value === true for value in values(result["gates"])),
                "a required gate failed")
        require(Set(keys(result["budgets"])) == REQUIRED_BUDGETS &&
                all(value === true for value in values(result["budgets"])),
                "certification budget set changed or a budget failed")
        require(
            result["provenance"] == provenance,
            "results within one artifact have inconsistent provenance",
        )
        require(
            result["source_provenance"] == expected_source,
            "evidence is not bound to the exact declared MOI provenance",
        )

        modules = retained_modules(result, path, wasm_tools)
        expected = case_spec.expected
        variants = result["variants"]
        require(length(variants) == length(expected),
                "wrong executed input count for $case_id")
        seen = Set{keytype(typeof(expected))}()
        for variant in variants
            raw_args = variant["args"]
            require(
                raw_args isa AbstractVector &&
                length(raw_args) == length(first(keys(expected))),
                "wrong input arity for $case_id",
            )
            require(
                all(value -> typeof(value) === Int64, raw_args),
                "input tuple for $case_id must contain exact JSON integers",
            )
            args = Tuple(raw_args)
            require(haskey(expected, args),
                    "unexpected input tuple $args for $case_id")
            require(!(args in seen),
                    "duplicate input tuple $args for $case_id")
            push!(seen, args)
            oracle = expected[args]
            exact_match(
                variant["native"],
                oracle,
                "recorded native oracle at $case_id$args",
            )
            exact_match(
                case_spec.f(args...),
                oracle,
                "fresh committed oracle at $case_id$args",
            )
            runs = variant["runs"]
            require(Set(keys(runs)) == REQUIRED_RUNS,
                    "run variants changed at $case_id$args")
            for label in REQUIRED_RUNS
                run = runs[label]
                require(
                    run["pass"] === true,
                    "recorded Wasm run failed for $label at $case_id$args",
                )
                exact_match(
                    run["actual"],
                    oracle,
                    "recorded Wasm result diverges for $label at $case_id$args",
                )
                actual = try
                    run_wasm_with_imports(
                        modules[label],
                        case_id,
                        Dict("Math" => Dict("pow" => "Math.pow")),
                        args...,
                    )
                catch error
                    fail(
                        "independent execution failed for $label at " *
                        "$case_id$args: " * sprint(showerror, error),
                    )
                end
                exact_match(
                    actual,
                    oracle,
                    "retained $label module diverges from fresh native at " *
                    "$case_id$args",
                )
            end
        end
        require(seen == Set(keys(expected)),
                "input ledger is incomplete for $case_id")
        exact_match(
            result["property"]["executed_inputs"],
            Int64(length(expected)),
            "property input count for $case_id",
        )
        require(result["property"]["bounded"] === true,
                "property domain is not bounded for $case_id")
    end

    return provenance["os"]
end

length(ARGS) == 1 ||
    error("usage: verify_$(STAGE)_promotion.jl ARTIFACT_ROOT")
root = abspath(only(ARGS))
files = evidence_files(root)
require(length(files) == 3, "expected three platform evidence files")
revision = current_revision()
expected_manifest = canonical_text_sha256(CERTIFICATION_MANIFEST)
node_version = independent_node_version()
require(
    node_version == "v$(CONFIG["versions"]["node"])",
    "promotion used wrong Node version: $node_version",
)
wasm_tools = independent_wasm_tools()
platforms =
    Set(
        verify_document(
            path,
            root,
            revision,
            expected_manifest,
            wasm_tools,
        )
        for path in files
    )
require(platforms == Set(["linux", "macos", "windows"]),
        "missing or duplicate platform evidence")
summary = Dict(
    "schema" => 1,
    "profile" => PROFILE,
    "evidence_kind" => EVIDENCE_KIND,
    "pass" => true,
    "revision" => revision,
    "platforms" => sort!(collect(platforms)),
)
println(JSON.json(summary, 2))
