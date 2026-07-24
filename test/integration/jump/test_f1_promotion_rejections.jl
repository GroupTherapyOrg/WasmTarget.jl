using JSON
using SHA
using Test
using WasmTarget

length(ARGS) == 1 ||
    error("usage: test_f1*_promotion_rejections.jl ARTIFACT_ROOT")
const STAGE = get(ENV, "WT_F1_PROMOTION_STAGE", "")
STAGE in ("f1a", "f1b") ||
    error("WT_F1_PROMOTION_STAGE must be f1a or f1b")
const SOURCE_ROOT = abspath(only(ARGS))
const VERIFIER = joinpath(@__DIR__, "verify_$(STAGE)_promotion.jl")
const EVIDENCE_FILE =
    STAGE == "f1a" ?
    "jump-f1-certification.json" :
    "jump-f1b-certification.json"
const FIRST_CASE =
    STAGE == "f1a" ?
    "f1_nullable_objective_layout" :
    "f1_parallel_variable_layout"

function evidence_files(root)
    files = String[]
    for (dir, _, names) in walkdir(root)
        EVIDENCE_FILE in names &&
            push!(files, joinpath(dir, EVIDENCE_FILE))
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
        return success(pipeline(
            ignorestatus(cmd);
            stdout=devnull,
            stderr=devnull,
        ))
    end
end

function mutate_json(mutate, root, index)
    path = evidence_files(root)[index]
    document = JSON.parsefile(path)
    mutate(document)
    write(path, JSON.json(document))
end

function first_result(root)
    path = evidence_files(root)[1]
    document = JSON.parsefile(path)
    return path, document, document["results"][1]
end

@testset "$(uppercase(STAGE)) promotion rejects ineligible or forged evidence" begin
    @test verifier_succeeds()

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["evidence_kind"] = "compiled"
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["results"][1]["evidence_kind"] = "compiled"
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["profile"] = "forged-profile"
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["results"][1]["case"] = "forged-case"
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["results"][1]["gates"]["native_oracle"] = false
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["results"][1]["gates"]["forged_gate"] = true
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["results"][1]["budgets"]["raw_wasm_bytes"] = false
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["results"][1]["budgets"]["forged_budget"] = true
        end
    end

    # Rewriting both the recorded native and Wasm answer cannot forge a fresh
    # committed oracle.
    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            variant = document["results"][1]["variants"][1]
            variant["native"] += 1
            for run in values(variant["runs"])
                run["actual"] = variant["native"]
                run["pass"] = true
            end
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            pop!(document["results"][1]["variants"])
            document["results"][1]["property"]["executed_inputs"] -= 1
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            variants = document["results"][1]["variants"]
            variants[2] = deepcopy(variants[1])
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["results"][1]["variants"][1]["args"][1] = true
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["results"][1]["variants"][1]["args"][1] = 0.0
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            variant = document["results"][1]["variants"][1]
            variant["native"] = Float64(variant["native"])
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            run = document["results"][1]["variants"][1]["runs"]["raw"]
            run["actual"] = Float64(run["actual"])
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            property = document["results"][1]["property"]
            property["executed_inputs"] =
                Float64(property["executed_inputs"])
        end
    end

    @test !verifier_succeeds() do root
        path = evidence_files(root)[1]
        document = JSON.parsefile(path)
        relative =
            document["results"][1]["compile"]["module_files"]["raw"]
        rm(joinpath(dirname(path), relative))
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["results"][1]["compile"]["module_sha256"]["raw"] =
                repeat("0", 64)
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            source = document["results"][1]["source_provenance"]
            source["sources"][1]["lines"] = "13-44"
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            contract =
                document["results"][1]["provenance"]["source_contract"]
            contract["functions"][FIRST_CASE] =
                repeat("0", 64)
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            contract =
                document["results"][1]["provenance"]["source_contract"]
            contract["canary_sha256"] = repeat("0", 64)
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            provenance = document["results"][1]["provenance"]
            provenance["os"] =
                provenance["os"] == "linux" ? "windows" : "linux"
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["results"][1]["provenance"]["node"]["version"] =
                "v0.0.0"
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["results"][1]["provenance"]["wasm_tools"]["version"] =
                "wasm-tools 0.0.0"
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["results"][1]["provenance"]["wasmtarget"]["sha"] =
                repeat("0", 40)
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["results"][1]["provenance"]["wasmtarget"]["dirty"] =
                true
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["results"][1]["provenance"]["manifest_sha256"] =
                repeat("0", 64)
        end
    end

    # A valid but independently different module cannot be blessed by
    # rewriting all self-reported digests, sizes, and execution results.
    @test !verifier_succeeds() do root
        path, document, result = first_result(root)
        replacement(::Int64, ::Int64)::Int64 = 0
        raw = WasmTarget.compile(
            replacement,
            (Int64, Int64);
            optimize=false,
        )
        modules = Dict(
            "raw" => raw,
            "size" => WasmTarget.optimize(raw; level=:size),
            "speed" => WasmTarget.optimize(raw; level=:speed),
        )
        for (label, bytes) in modules
            relative = result["compile"]["module_files"][label]
            write(joinpath(dirname(path), relative), bytes)
            result["compile"]["module_sha256"][label] =
                bytes2hex(sha256(bytes))
            for variant in result["variants"]
                run = variant["runs"][label]
                run["wasm_bytes"] = length(bytes)
                run["actual"] = variant["native"]
                run["pass"] = true
            end
        end
        write(path, JSON.json(document))
    end

    # Optimized modules must be exact products of the pinned optimizer, not
    # merely valid Wasm with internally consistent metadata.
    @test !verifier_succeeds() do root
        path, document, result = first_result(root)
        raw_relative = result["compile"]["module_files"]["raw"]
        size_relative = result["compile"]["module_files"]["size"]
        raw_path = joinpath(dirname(path), raw_relative)
        size_path = joinpath(dirname(path), size_relative)
        raw = read(raw_path)
        size = read(size_path)
        write(raw_path, size)
        write(size_path, raw)
        result["compile"]["module_sha256"]["raw"] =
            bytes2hex(sha256(size))
        result["compile"]["module_sha256"]["size"] =
            bytes2hex(sha256(raw))
        for variant in result["variants"]
            variant["runs"]["raw"]["wasm_bytes"] = length(size)
            variant["runs"]["size"]["wasm_bytes"] = length(raw)
        end
        write(path, JSON.json(document))
    end

    @test !verifier_succeeds() do root
        path, document, result = first_result(root)
        relative = result["compile"]["module_files"]["raw"]
        module_path = joinpath(dirname(path), relative)
        external = joinpath(dirname(root), "external-f1a.wasm")
        cp(module_path, external; force=true)
        rm(module_path)
        symlink(external, module_path)
    end

    @test !verifier_succeeds() do root
        path = evidence_files(root)[1]
        external = joinpath(dirname(root), "external-$(STAGE)-evidence.json")
        cp(path, external; force=true)
        rm(path)
        symlink(external, path)
    end

    @test !verifier_succeeds() do root
        source = dirname(evidence_files(root)[1])
        external = joinpath(dirname(root), "external-$(STAGE)-artifact")
        mv(source, external)
        symlink(external, source)
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            document["results"][1]["compile"]["module_files"]["raw"] =
                "../../outside.wasm"
        end
    end

    @test !verifier_succeeds() do root
        source = dirname(evidence_files(root)[1])
        destination = joinpath(
            dirname(source),
            "$(STAGE)-unknown-platform",
        )
        mv(source, destination)
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            variant = document["results"][1]["variants"][1]
            variant["runs"]["raw"]["wasm_bytes"] += 1
        end
    end

    @test !verifier_succeeds() do root
        mutate_json(root, 1) do document
            run = document["results"][1]["variants"][1]["runs"]["raw"]
            run["wasm_bytes"] = Float64(run["wasm_bytes"])
        end
    end
end
