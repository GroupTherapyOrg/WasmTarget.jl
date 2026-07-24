module JumpSnapshotCertificationSupport

using Base64
using JSON
using Pkg
using SHA
using TOML
using WasmTarget

export assert_environment_provenance,
       assert_full_island,
       canonical_arch,
       canonical_os,
       embedded_assets,
       embedded_report,
       git_provenance,
       package_provenance,
       run_export_child,
       terminate_process

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

function embedded_assets(html)
    source = read(html, String)
    matches = collect(eachmatch(
        r"""atob\("([A-Za-z0-9+/=]+)"\).*?__snapshotEmbeddedAssets"""s,
        source,
    ))
    length(matches) == 1 ||
        error(
            "single-file export must contain exactly one embedded asset " *
            "registry, found $(length(matches))",
        )
    match_result = only(matches)
    encoded_files =
        JSON.parse(String(base64decode(only(match_result.captures))))
    return Dict(
        String(path) => base64decode(String(encoded))
        for (path, encoded) in encoded_files
    )
end

function embedded_report(html)
    files = embedded_assets(html)
    report_key = only(filter(key -> endswith(key, "report.json"), keys(files)))
    bytes = files[report_key]
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

function assert_environment_provenance(environment, root)
    dependencies =
        TOML.parsefile(joinpath(environment, "Manifest.toml"))["deps"]
    snapshot_manifest = only(dependencies["Snapshot"])
    snapshot = package_provenance("Snapshot")
    snapshot["tree_hash"] == snapshot_manifest["git-tree-sha1"] ||
        error("loaded Snapshot tree does not match the pinned manifest")

    expected_wt_root = realpath(joinpath(root, "..", "..", ".."))
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

function run_export_child(
    script,
    name,
    output_dir;
    environment,
    deadline_seconds,
    output_limit_bytes,
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
            `$(Base.julia_cmd()) --startup-file=no --project=$environment -e $bootstrap $script --child $name $output_dir $result_path`,
            "WT_JUMP_PROCESS_GROUP" => "1",
            "WT_VALIDATE" => "1",
        )
        proc = run(
            pipeline(ignorestatus(cmd), stdout=out_io, stderr=err_io);
            wait=false,
        )
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
            if bytes > output_limit_bytes
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

end
