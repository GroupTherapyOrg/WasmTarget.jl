using Base64
using JSON
using SHA
using Test

length(ARGS) == 1 ||
    error("usage: test_f1_browser_promotion_rejections.jl ARTIFACT_ROOT")

const SOURCE_ROOT = abspath(only(ARGS))
const VERIFIER = joinpath(@__DIR__, "verify_f1_browser_promotion.jl")

function evidence_files(root, filename)
    files = String[]
    for (dir, _, names) in walkdir(root)
        filename in names && push!(files, joinpath(dir, filename))
    end
    return sort!(files)
end

function copied_fixture(f)
    mktempdir() do root
        fixture = joinpath(root, "artifacts")
        cp(SOURCE_ROOT, fixture; force=true)
        return f(fixture)
    end
end

function verifier_succeeds(mutate=(root -> nothing))
    copied_fixture() do root
        mutate(root)
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(@__DIR__) $VERIFIER $root`
        return success(pipeline(
            ignorestatus(cmd);
            stdout=devnull,
            stderr=devnull,
        ))
    end
end

function mutate_json(root, filename, mutate; index=1)
    path = evidence_files(root, filename)[index]
    document = JSON.parsefile(path)
    mutate(document)
    write(path, JSON.json(document))
end

function first_variant(root, stage, delivery)
    exports = only(filter(
        path -> occursin("ubuntu-latest", path),
        evidence_files(root, "exports.json"),
    ))
    document = JSON.parsefile(exports)
    return (exports, dirname(exports), document[stage][delivery])
end

function rewrite_portable_registry(path, mutate)
    source = read(path, String)
    pattern =
        r"""atob\("([A-Za-z0-9+/=]+)"\).*?__snapshotEmbeddedAssets"""s
    matches = collect(eachmatch(pattern, source))
    @assert length(matches) == 1
    encoded = only(only(matches).captures)
    registry = JSON.parse(String(base64decode(encoded)))
    mutate(registry)
    replacement = base64encode(JSON.json(registry))
    write(path, replace(source, encoded => replacement; count=1))
end

function write_json(path, document)
    write(path, JSON.json(document))
end

@testset "F1 browser promotion accepts authentic evidence" begin
    @test verifier_succeeds()
end

@testset "F1 browser promotion rejects forged or substituted evidence" begin
    @test !verifier_succeeds() do root
        mutate_json(root, "jump-snapshot-f1-browser.json") do document
            observation =
                document["evidence"][1]["instances"][1]["rounds"][1][
                    "observations"
                ][1]
            first_key = first(keys(observation["observed"]))
            observation["observed"][first_key] = "forged"
        end
    end

    @test !verifier_succeeds() do root
        _, export_root, variant = first_variant(root, "f1a", "split")
        path = joinpath(export_root, variant["delivered_wasm"])
        bytes = read(path)
        bytes[end] ⊻= 0x01
        write(path, bytes)
    end

    @test !verifier_succeeds() do root
        _, export_root, variant = first_variant(root, "f1a", "split")
        delivered = joinpath(export_root, variant["delivered_wasm"])
        retained = joinpath(export_root, variant["wasm"])
        rm(delivered)
        symlink(retained, delivered)
    end

    @test !verifier_succeeds() do root
        _, export_root, variant = first_variant(root, "f1a", "split")
        path = joinpath(export_root, variant["report"])
        write(path, "[]")
    end

    @test !verifier_succeeds() do root
        _, export_root, variant = first_variant(root, "f1b", "portable")
        path = joinpath(export_root, variant["html"])
        source = read(path, String)
        write(path, replace(
            source,
            "__snapshotEmbeddedAssets" => "__forgedEmbeddedAssets";
            count=1,
        ))
    end

    @test !verifier_succeeds() do root
        _, export_root, variant = first_variant(root, "f1b", "portable")
        path = joinpath(export_root, variant["html"])
        rewrite_portable_registry(path) do registry
            wasm = only(filter(name -> endswith(name, ".wasm"), keys(registry)))
            bytes = base64decode(registry[wasm])
            bytes[end] ⊻= 0x01
            registry[wasm] = base64encode(bytes)
        end
    end

    @test !verifier_succeeds() do root
        _, export_root, variant = first_variant(root, "f1b", "portable")
        path = joinpath(export_root, variant["html"])
        source = read(path, String)
        registry = only(collect(eachmatch(
            r"""atob\("([A-Za-z0-9+/=]+)"\).*?__snapshotEmbeddedAssets"""s,
            source,
        )))
        write(
            path,
            source * "\n<script>atob(\"$(only(registry.captures))\");" *
            "globalThis.__snapshotEmbeddedAssets = {};</script>\n",
        )
    end

    @test !verifier_succeeds() do root
        _, export_root, variant = first_variant(root, "f1b", "split")
        open(joinpath(export_root, variant["notebook"]), "a") do io
            write(io, "\n# forged\n")
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, "jump-snapshot-f1-browser.json") do document
            instance = document["evidence"][1]["instances"][1]
            push!(instance["console_errors"], "forged hidden error")
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, "jump-snapshot-f1-browser.json") do document
            instance = document["evidence"][1]["instances"][1]
            instance["page_closed"] = false
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, "jump-snapshot-f1-browser.json") do document
            instances = document["evidence"][1]["instances"]
            instances[2]["instance"] = instances[1]["instance"]
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, "jump-snapshot-f1-browser.json") do document
            instance = document["evidence"][1]["instances"][1]
            instance["wasm_response_sha256"] = [repeat("0", 64)]
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, "jump-snapshot-f1-browser.json") do document
            document["nodejs_24_jll"]["tree_hash"] = repeat("0", 40)
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, "exports.json") do document
            document["manifest_sha256"] = repeat("0", 64)
        end
    end

    @test !verifier_succeeds() do root
        _, export_root, variant = first_variant(root, "f1a", "split")
        path = joinpath(export_root, variant["wasm"])
        bytes = read(path)
        bytes[end] ⊻= 0x01
        write(path, bytes)
    end

    @test !verifier_succeeds() do root
        exports_path, export_root, variant =
            first_variant(root, "f1a", "split")
        report_path = joinpath(export_root, variant["report"])
        report = JSON.parsefile(report_path)
        report[1]["cells"][1]["id"] =
            "ffffffff-ffff-4fff-8fff-ffffffffffff"
        report_bytes = Vector{UInt8}(codeunits(JSON.json(report)))
        write(report_path, report_bytes)
        digest = bytes2hex(sha256(report_bytes))

        exports = JSON.parsefile(exports_path)
        exports["f1a"]["split"]["report_sha256"] = digest
        write_json(exports_path, exports)
        browser_path =
            joinpath(export_root, "jump-snapshot-f1-browser.json")
        browser = JSON.parsefile(browser_path)
        browser["report_sha256"]["f1a"]["split"] = digest
        write_json(browser_path, browser)
    end

    @test !verifier_succeeds() do root
        mutate_json(root, "jump-snapshot-f1-browser.json") do document
            document["browser_runtime"]["playwright"] = "0.0.0-forged"
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, "jump-snapshot-f1-browser.json") do document
            push!(document["evidence"], deepcopy(document["evidence"][1]))
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, "jump-snapshot-f1-browser.json") do document
            rounds = document["evidence"][1]["instances"][1]["rounds"]
            rounds[2]["round"] = rounds[1]["round"]
        end
    end

    @test !verifier_succeeds() do root
        _, export_root, variant = first_variant(root, "f1a", "split")
        delivered = joinpath(export_root, variant["delivered_wasm"])
        parent = dirname(delivered)
        moved = parent * "-real"
        mv(parent, moved)
        symlink(moved, parent; dir_target=true)
    end

    @test !verifier_succeeds() do root
        browser = evidence_files(root, "jump-snapshot-f1-browser.json")[1]
        document = JSON.parsefile(browser)
        screenshot = first(
            instance["screenshot"]
            for row in document["evidence"]
            for instance in row["instances"]
            if instance["screenshot"] !== nothing
        )
        export_root = dirname(browser)
        rm(joinpath(export_root, screenshot))
    end

    @test !verifier_succeeds() do root
        artifact = first(readdir(root; join=true))
        rm(artifact; recursive=true)
    end
end
