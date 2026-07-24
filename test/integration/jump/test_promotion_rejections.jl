using JSON
using SHA
using Test
using TOML

length(ARGS) == 1 ||
    error("usage: test_promotion_rejections.jl ARTIFACT_ROOT")
include(joinpath(@__DIR__, "evidence_utils.jl"))
using .JumpCertificationEvidence

const SOURCE_ROOT = abspath(only(ARGS))
const VERIFIER = joinpath(@__DIR__, "verify_t0_promotion.jl")
const CONFIG = TOML.parsefile(joinpath(@__DIR__, "capabilities.toml"))
const REQUIRED_CASES = vcat(
    CONFIG["tiers"]["moi_values"]["cases"],
    CONFIG["tiers"]["runtime_collections"]["cases"],
)
const REQUIRED_RUNS = ["raw", "size", "speed"]

function evidence_files(root, filename)
    files = String[]
    for (dir, _, names) in walkdir(root)
        filename in names && push!(files, joinpath(dir, filename))
    end
    return sort(files)
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
        return success(pipeline(ignorestatus(cmd), stdout=devnull, stderr=devnull))
    end
end

function verifier_failure(mutate)
    copied_fixture() do root
        mutate(root)
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(@__DIR__) $VERIFIER $root`
        output = IOBuffer()
        process = run(
            pipeline(ignorestatus(cmd), stdout=output, stderr=output),
        )
        return (success=success(process), output=String(take!(output)))
    end
end

function verifier_summary()
    copied_fixture() do root
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(@__DIR__) $VERIFIER $root`
        return JSON.parse(read(cmd, String))
    end
end

function mutate_json(mutate, root, filename, index)
    path = evidence_files(root, filename)[index]
    document = JSON.parsefile(path)
    mutate(document)
    write(path, JSON.json(document))
end

function mutate_all_json(mutate, root, filename)
    for (index, _) in enumerate(evidence_files(root, filename))
        mutate_json(mutate, root, filename, index)
    end
end

function unsigned_leb128(value::Integer)
    value >= 0 || error("ULEB128 requires a nonnegative value")
    bytes = UInt8[]
    remaining = UInt(value)
    while true
        byte = UInt8(remaining & 0x7f)
        remaining >>= 7
        remaining == 0 || (byte |= 0x80)
        push!(bytes, byte)
        remaining == 0 && return bytes
    end
end

@testset "promotion retains platform-specific artifacts" begin
    summary = verifier_summary()
    @test summary["pass"] === true
    @test summary["promotion_node"] == "v$(CONFIG["versions"]["node"])"
    @test summary["promotion_wasm_tools"] ==
          "wasm-tools $(CONFIG["versions"]["wasm_tools"])"
    @test summary["promotion_julia"] == CONFIG["versions"]["julia"]
    @test Set(summary["platforms"]) == Set(["linux", "macos", "windows"])
    digests = summary["module_digests_by_platform"]
    @test Set(keys(digests)) == Set(["linux", "macos", "windows"])
    for platform in values(digests)
        @test Set(keys(platform["cases"])) == Set(REQUIRED_CASES)
        @test all(
            Set(keys(variants)) == Set(REQUIRED_RUNS)
            for variants in values(platform["cases"])
        )
        @test all(
            occursin(r"^[0-9a-f]{64}$", digest)
            for variants in values(platform["cases"])
            for digest in values(variants)
        )
    end
end

@testset "canonical text evidence" begin
    mktempdir() do root
        lf = joinpath(root, "lf")
        crlf = joinpath(root, "crlf")
        changed = joinpath(root, "changed")
        lone_cr = joinpath(root, "lone-cr")
        write(lf, "a = 1\nb = 2\n")
        write(crlf, "a = 1\r\nb = 2\r\n")
        write(changed, "a = 1\nb = 3\n")
        write(lone_cr, "a = 1\rb = 2\n")
        @test canonical_text_sha256(lf) == canonical_text_sha256(crlf)
        @test canonical_text_sha256(lf) != canonical_text_sha256(changed)
        @test_throws ErrorException canonical_text_sha256(lone_cr)
    end
end

@testset "promotion rejects forged evidence" begin
    fresh_oracle_forgery = verifier_failure() do root
        for path in evidence_files(root, "jump-certification.json")
            document = JSON.parsefile(path)
            case = first(filter(
                item -> item["case"] == "moi_affine_value",
                document["results"],
            ))
            variant = first(case["variants"])
            variant["native"] = 123456.0
            for run in values(variant["runs"])
                run["actual"] = 123456.0
            end
            write(path, JSON.json(document))
        end
    end
    @test fresh_oracle_forgery.success === false
    @test occursin(
        "recorded native result diverges from fresh committed oracle",
        fresh_oracle_forgery.output,
    )

    @test !verifier_succeeds() do root
        files = evidence_files(root, "jump-certification.json")
        first_doc = JSON.parsefile(files[1])
        duplicate_os = first_doc["results"][1]["provenance"]["os"]
        mutate_json(root, "jump-certification.json", 2) do document
            for case in document["results"]
                case["provenance"]["os"] = duplicate_os
            end
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, "jump-snapshot-browser.json", 1) do document
            document["browser_runtime"]["node"] = "v0.0.0"
        end
    end

    # Build metadata may be retained, but it cannot disguise a different
    # semantic wasm-tools version.
    @test !verifier_succeeds() do root
        mutate_json(root, "jump-certification.json", 1) do document
            for case in document["results"]
                case["provenance"]["wasm_tools"]["version"] =
                    "wasm-tools 1.245.0 (forged)"
            end
        end
    end

    # Metadata is accepted only in wasm-tools' current commit/date format.
    @test !verifier_succeeds() do root
        mutate_json(root, "jump-certification.json", 1) do document
            for case in document["results"]
                case["provenance"]["wasm_tools"]["version"] =
                    "wasm-tools $(CONFIG["versions"]["wasm_tools"]) (unbounded metadata)"
            end
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, "jump-certification.json", 1) do document
            pop!(document["results"][1]["variants"])
            document["results"][1]["property"]["executed_inputs"] -= 1
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, "jump-snapshot-browser.json", 1) do document
            push!(document["evidence"], deepcopy(first(document["evidence"])))
        end
    end

    # A `pass=true` flag cannot hide a wrong raw result.
    @test !verifier_succeeds() do root
        mutate_json(root, "jump-certification.json", 1) do document
            variant = document["results"][1]["variants"][1]
            variant["runs"]["raw"]["actual"] = variant["native"] + 1
            variant["runs"]["raw"]["pass"] = true
        end
    end

    # Identical arguments with platform-dependent native semantics are rejected.
    @test !verifier_succeeds() do root
        mutate_json(root, "jump-certification.json", 2) do document
            variant = document["results"][1]["variants"][1]
            variant["native"] += 1
            for run in values(variant["runs"])
                run["actual"] = variant["native"]
                run["pass"] = true
            end
        end
    end

    # Seed/count metadata cannot bless an unrelated input sequence.
    @test !verifier_succeeds() do root
        mutate_json(root, "jump-certification.json", 1) do document
            document["results"][1]["variants"][1]["args"][1] = 123456.0
        end
    end

    # Browser rows must retain all exact case IDs, not merely four values.
    @test !verifier_succeeds() do root
        mutate_json(root, "jump-snapshot-browser.json", 1) do document
            row = first(filter(
                row -> row["delivery"] == "split-http",
                document["evidence"],
            ))
            delete!(row["observed_cases"], "moi_set_value")
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, "jump-snapshot-browser.json", 1) do document
            document["snapshot"]["tree_hash"] = repeat("0", 40)
        end
    end

    # Self-reported report digests cannot override the retained raw report.
    @test !verifier_succeeds() do root
        report = first(filter(
            path -> occursin(
                joinpath("split", "00_moi_values.islands", "report.json"),
                path,
            ),
            evidence_files(root, "report.json"),
        ))
        write(report, "[]")
    end

    # Internally consistent but stale evidence cannot be replayed against a
    # newer checkout.
    @test !verifier_succeeds() do root
        stale = repeat("a", 40)
        mutate_all_json(root, "jump-certification.json") do document
            for case in document["results"]
                case["provenance"]["wasmtarget"]["sha"] = stale
            end
        end
        mutate_all_json(root, "exports.json") do document
            document["wt_sha"] = stale
            document["wasmtarget"]["sha"] = stale
        end
        mutate_all_json(root, "jump-snapshot-browser.json") do document
            document["wt_sha"] = stale
            document["wasmtarget"]["sha"] = stale
        end
    end

    # The retained module bytes, rather than their self-reported digest, are
    # promotion evidence.
    @test !verifier_succeeds() do root
        module_path = first(filter(
            path -> endswith(path, joinpath(
                "modules", "moi_affine_value", "raw.wasm",
            )),
            evidence_files(root, "raw.wasm"),
        ))
        open(module_path, "a") do io
            write(io, UInt8[0xde, 0xad, 0xbe, 0xef])
        end
    end

    # Optimization variants are derived evidence, not self-reported labels.
    # Even a self-consistent byte/digest/size relabel must fail the independent
    # pinned-optimizer derivation check.
    @test !verifier_succeeds() do root
        certification_path =
            first(evidence_files(root, "jump-certification.json"))
        certification = JSON.parsefile(certification_path)
        case = first(filter(
            item -> item["case"] == "moi_affine_value",
            certification["results"],
        ))
        artifact_root = dirname(certification_path)
        raw_path = joinpath(
            artifact_root,
            case["compile"]["module_files"]["raw"],
        )
        size_path = joinpath(
            artifact_root,
            case["compile"]["module_files"]["size"],
        )
        raw = read(raw_path)
        size = read(size_path)
        write(raw_path, size)
        write(size_path, raw)
        case["compile"]["module_sha256"]["raw"] =
            bytes2hex(sha256(size))
        case["compile"]["module_sha256"]["size"] =
            bytes2hex(sha256(raw))
        for variant in case["variants"]
            variant["runs"]["raw"]["wasm_bytes"] = length(size)
            variant["runs"]["size"]["wasm_bytes"] = length(raw)
        end
        write(certification_path, JSON.json(certification))
    end

    # A symlink cannot redirect a retained-module ledger to bytes outside the
    # downloaded artifact tree, even when those bytes have the expected digest.
    @test !verifier_succeeds() do root
        module_path = first(filter(
            path -> endswith(path, joinpath(
                "modules", "moi_affine_value", "raw.wasm",
            )),
            evidence_files(root, "raw.wasm"),
        ))
        external_path = joinpath(dirname(root), "external-retained-module.wasm")
        cp(module_path, external_path; force=true)
        rm(module_path)
        symlink(external_path, module_path)
    end

    # Self-reported booleans, digests, and execution sizes cannot bless an
    # oversized but otherwise valid retained module.
    @test !verifier_succeeds() do root
        certification_path =
            first(evidence_files(root, "jump-certification.json"))
        certification = JSON.parsefile(certification_path)
        case = first(filter(
            item -> item["case"] == "moi_affine_value",
            certification["results"],
        ))
        relative = case["compile"]["module_files"]["size"]
        module_path = joinpath(dirname(certification_path), relative)
        configured_limit =
            Int(CONFIG["budgets"]["optimized_wasm_bytes_hard"])
        payload_size = configured_limit + 1
        # A custom section is semantically inert and keeps the module valid.
        open(module_path, "a") do io
            write(io, UInt8(0x00))
            write(io, unsigned_leb128(payload_size))
            write(io, UInt8(0x00)) # empty custom-section name
            write(io, zeros(UInt8, payload_size - 1))
        end
        digest = bytes2hex(sha256(read(module_path)))
        case["compile"]["module_sha256"]["size"] = digest
        for variant in case["variants"]
            variant["runs"]["size"]["wasm_bytes"] = filesize(module_path)
        end
        write(certification_path, JSON.json(certification))
        filesize(module_path) > configured_limit ||
            error("oversized-module mutation did not cross the configured limit")
        wasm_tools = Sys.which("wasm-tools")
        wasm_tools === nothing && error("wasm-tools unavailable")
        success(`$wasm_tools validate $module_path`) ||
            error("oversized-module mutation did not remain valid Wasm")
    end

    # A browser summary may not substitute different exporter provenance while
    # retaining a valid configured tool version.
    @test !verifier_succeeds() do root
        mutate_json(root, "jump-snapshot-browser.json", 1) do document
            document["validator"]["path"] = "/forged/wasm-tools"
        end
    end

    # Internally consistent export/browser summaries cannot replay a negative
    # fixture from before the committed notebook changed.
    @test !verifier_succeeds() do root
        stale = repeat("b", 64)
        mutate_all_json(root, "exports.json") do document
            document["source_contract"]["negative_notebook_sha256"] = stale
        end
        mutate_all_json(root, "jump-snapshot-browser.json") do document
            document["source_contract"]["negative_notebook_sha256"] = stale
        end
    end

    # Even when a forged report digest is propagated through both summaries,
    # the exact correct-or-loud diagnostic contract is enforced.
    @test !verifier_succeeds() do root
        report = first(filter(
            path -> endswith(path, joinpath(
                "negative",
                "00_negative_unsupported.islands",
                "report.json",
            )),
            evidence_files(root, "report.json"),
        ))
        document = JSON.parsefile(report)
        only(only(document)["cells"])["diag"]["construct"] =
            "forged unsupported construct"
        write(report, JSON.json(document))
        digest = bytes2hex(sha256(read(report)))
        export_root = dirname(dirname(dirname(report)))
        exports_path = joinpath(export_root, "exports.json")
        exports = JSON.parsefile(exports_path)
        exports["negative"]["report_sha256"] = digest
        write(exports_path, JSON.json(exports))
        browser_path =
            joinpath(dirname(export_root), "jump-snapshot-browser.json")
        browser = JSON.parsefile(browser_path)
        browser["negative"]["report_sha256"] = digest
        write(browser_path, JSON.json(browser))
    end
end
