using Base64
using JSON
using Pkg
using SHA
using Snapshot
using TOML
using WasmTarget

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

canonical_os() =
    Sys.iswindows() ? "windows" :
    Sys.isapple() ? "macos" :
    Sys.islinux() ? "linux" : "unsupported"

canonical_arch() =
    Sys.ARCH === :x86_64 ? "x86_64" :
    Sys.ARCH === :aarch64 ? "aarch64" : string(Sys.ARCH)

function assert_full_island(report)
    length(report) == 1 ||
        error("expected one bond group, found $(length(report))")
    group = only(report)
    group["judgement"] == "island" ||
        error("expected a full island, got $(group["judgement"])")
    isempty(group["reasons"]) ||
        error("unexpected island reasons: $(group["reasons"])")
    all(cell -> cell["ok"] === true, group["cells"]) ||
        error("one or more notebook cells failed island compilation")
    return group
end

function embedded_report(html)
    source = read(html, String)
    match_result = match(
        r"""atob\("([A-Za-z0-9+/=]+)"\).*?__snapshotEmbeddedAssets"""s,
        source,
    )
    match_result === nothing &&
        error("single-file export has no embedded asset registry")
    files = JSON.parse(String(base64decode(only(match_result.captures))))
    report_key = only(filter(key -> endswith(key, "report.json"), keys(files)))
    bytes = base64decode(files[report_key])
    return (report=JSON.parse(String(copy(bytes))), bytes=bytes)
end

function package_provenance(name)
    dependency = only(filter(
        dependency -> dependency.second.name == name,
        collect(Pkg.dependencies()),
    )).second
    return Dict(
        "name" => name,
        "version" => string(dependency.version),
        "source" => dependency.source,
        "tree_hash" => isnothing(dependency.tree_hash) ?
                       nothing : string(dependency.tree_hash),
    )
end

function assert_environment_provenance()
    dependencies = TOML.parsefile(joinpath(ENVIRONMENT, "Manifest.toml"))["deps"]
    snapshot_manifest = only(dependencies["Snapshot"])
    snapshot = package_provenance("Snapshot")
    snapshot["tree_hash"] == snapshot_manifest["git-tree-sha1"] ||
        error("loaded Snapshot tree does not match the pinned manifest")

    expected_wt_root = realpath(joinpath(ROOT, "..", "..", ".."))
    loaded_wt_root = realpath(dirname(dirname(pathof(WasmTarget))))
    loaded_wt_root == expected_wt_root ||
        error(
            "Snapshot certification loaded WasmTarget from $loaded_wt_root, " *
            "expected $expected_wt_root",
        )
    return snapshot
end

function git_provenance(path)
    root = dirname(dirname(path))
    return Dict(
        "sha" => strip(read(`git -C $root rev-parse HEAD`, String)),
        "dirty" =>
            !isempty(strip(read(`git -C $root status --porcelain`, String))),
    )
end

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

function terminate_process(proc)
    process_exited(proc) && return true
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

function run_variant_child(
    name,
    output_dir;
    deadline_seconds=DEADLINE_SECONDS,
    ready_path=nothing,
    startup_deadline_seconds=30.0,
)
    result_path = joinpath(dirname(output_dir), ".$name-result.json")
    out_path, out_io = mktemp()
    err_path, err_io = mktemp()
    try
        bootstrap = """
        if !Sys.iswindows()
            ccall(:setsid, Cint, ()) == -1 &&
                error("failed to create Snapshot export process group")
        end
        include(popfirst!(ARGS))
        child_main()
        """
        cmd = addenv(
            `$(Base.julia_cmd()) --startup-file=no --project=$ENVIRONMENT -e $bootstrap $(@__FILE__) --child $name $output_dir $result_path`,
            "WT_JUMP_PROCESS_GROUP" => "1",
            "WT_VALIDATE" => "1",
        )
        proc = run(pipeline(ignorestatus(cmd), stdout=out_io, stderr=err_io); wait=false)
        startup_started = time()
        started = ready_path === nothing ? startup_started : nothing
        failure = nothing
        while !process_exited(proc)
            if ready_path !== nothing && started === nothing
                if isfile(ready_path) && filesize(ready_path) > 0
                    started = time()
                elseif time() - startup_started > startup_deadline_seconds
                    failure = "startup_timeout"
                    break
                end
            elseif time() - started > deadline_seconds
                failure = "timeout"
                break
            end
            bytes = (isfile(out_path) ? filesize(out_path) : 0) +
                    (isfile(err_path) ? filesize(err_path) : 0)
            if bytes > OUTPUT_LIMIT_BYTES
                failure = "output_limit"
                break
            end
            sleep(0.1)
        end
        failure === nothing || begin
            cleanup_ok = terminate_process(proc)
            error(
                "Snapshot $name export failed closed: $failure; " *
                "cleanup_ok=$cleanup_ok",
            )
        end
        if !success(proc)
            stderr = read(err_path, String)
            error(
                "Snapshot $name export exited $(proc.exitcode): " *
                last(stderr, min(length(stderr), 8192)),
            )
        end
        isfile(result_path) ||
            error("Snapshot $name export produced no structured result")
        return JSON.parsefile(result_path)
    finally
        close(out_io)
        close(err_io)
        rm(out_path; force=true)
        rm(err_path; force=true)
        rm(result_path; force=true)
    end
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
        "manifest_sha256" => bytes2hex(sha256(read(manifest_path))),
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
