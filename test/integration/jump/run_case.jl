using JSON
using Pkg
using SHA
using TOML
using WasmTarget

include(joinpath(@__DIR__, "..", "..", "utils.jl"))
include(joinpath(@__DIR__, "evidence_utils.jl"))

using .JumpCertificationEvidence

const CONFIG = TOML.parsefile(joinpath(@__DIR__, "capabilities.toml"))
const RESULT_PREFIX = "WT_JUMP_CERT_RESULT="
const CURRENT_PHASE = Ref("startup")
const CASE_PROFILE = get(ENV, "WT_JUMP_CASE_PROFILE", "t0")
const CASE_SOURCE, CASES, PROPERTY_SEED, PROPERTY_RANDOM_SAMPLES =
    if CASE_PROFILE == "t0"
        source = joinpath(@__DIR__, "canaries", "00_moi_values.jl")
        include(source)
        (
            source,
            JumpMOIValueCanaries.CASES,
            JumpMOIValueCanaries.PROPERTY_SEED,
            JumpMOIValueCanaries.PROPERTY_RANDOM_SAMPLES,
        )
    elseif CASE_PROFILE == "moi-storage-runtime-shapes-v1"
        source =
            joinpath(@__DIR__, "canaries", "f1", "00_nullable_layouts.jl")
        include(source)
        (
            source,
            JumpF1NullableLayoutCanaries.CASES,
            nothing,
            0,
        )
    elseif CASE_PROFILE == "moi-storage-vector-lifecycle-v1"
        source = joinpath(
            @__DIR__,
            "canaries",
            "f1",
            "01_parallel_vector_lifecycle.jl",
        )
        include(source)
        (
            source,
            JumpF1ParallelVectorCanaries.CASES,
            nothing,
            0,
        )
    else
        error("unknown JuMP certification profile: $CASE_PROFILE")
    end
const CASE_IDS = sort!(collect(keys(CASES)))

canonical_os() =
    Sys.iswindows() ? "windows" :
    Sys.isapple() ? "macos" :
    Sys.islinux() ? "linux" : "unsupported"

canonical_arch() =
    Sys.ARCH === :x86_64 ? "x86_64" :
    Sys.ARCH === :aarch64 ? "aarch64" : string(Sys.ARCH)

function package_version(uuid::Base.UUID)
    dependency = get(Pkg.dependencies(), uuid, nothing)
    dependency === nothing && return nothing
    return string(dependency.version)
end

function git_provenance(path::AbstractString)
    root = dirname(dirname(path))
    try
        sha = strip(read(pipeline(
            `git -C $root rev-parse HEAD`;
            stderr=devnull,
        ), String))
        dirty = !isempty(strip(read(pipeline(
            `git -C $root status --porcelain`;
            stderr=devnull,
        ), String)))
        return Dict("sha" => sha, "dirty" => dirty)
    catch
        return Dict("sha" => nothing, "dirty" => nothing)
    end
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

function node_provenance()
    invocation = WasmRunner._NODE
    invocation === nothing &&
        return Dict("invocation" => nothing, "version" => nothing)
    executable = first(invocation.exec)
    version = try
        strip(read(`$executable --version`, String))
    catch
        nothing
    end
    return Dict("invocation" => string(invocation), "version" => version)
end

function command_provenance(executable::AbstractString, version_args...)
    path = Sys.which(executable)
    path === nothing &&
        return Dict("path" => nothing, "version" => nothing)
    version = try
        cmd = Cmd(vcat([path], string.(collect(version_args))))
        strip(read(cmd, String))
    catch
        nothing
    end
    return Dict("path" => path, "version" => version)
end

function provenance()
    manifest = joinpath(@__DIR__, "Manifest.toml")
    canary = CASE_SOURCE
    return Dict(
        "julia" => string(VERSION),
        "os" => canonical_os(),
        "canonical_arch" => canonical_arch(),
        "kernel" => string(Sys.KERNEL),
        "arch" => string(Sys.ARCH),
        "wasmtarget" => merge(
            Dict("path" => pathof(WasmTarget)),
            git_provenance(pathof(WasmTarget)),
        ),
        "jump" => package_version(Base.UUID("4076af6c-e467-56ae-b986-b466b2749572")),
        "math_opt_interface" =>
            package_version(Base.UUID("b8f27783-ece8-5eb3-8dc8-9495eed66fee")),
        "binaryen_jll" =>
            package_version(Base.UUID("a54ac8ab-712d-5a0e-8e11-9296c0d3c20e")),
        # Pkg writes native line endings when it refreshes a manifest. Hash
        # the canonical Git text so one committed environment has one identity
        # on Windows, macOS, and Linux.
        "manifest_sha256" => canonical_text_sha256(manifest),
        "source_contract" => Dict(
            "profile" => CASE_PROFILE,
            "case_ids" => CASE_IDS,
            "canary_sha256" => bytes2hex(SHA.sha256(read(canary))),
            "functions" => function_contract(canary),
        ),
        "node" => node_provenance(),
        "wasm_tools" => command_provenance("wasm-tools", "--version"),
        "independent_validation" => get(ENV, "WT_VALIDATE", "") == "1",
    )
end

function retain_modules(name, modules)
    root = get(ENV, "WT_JUMP_MODULE_ROOT", "")
    isempty(root) && error("WT_JUMP_MODULE_ROOT is required")
    relative = Dict{String,String}()
    for (label, bytes) in modules
        relative_path = joinpath("modules", name, "$label.wasm")
        path = joinpath(root, relative_path)
        mkpath(dirname(path))
        write(path, bytes)
        relative[label] = replace(relative_path, '\\' => '/')
    end
    return relative
end

function timed(f)
    started = time_ns()
    value = f()
    return value, (time_ns() - started) / 1.0e9
end

function run_case(name::String)
    haskey(CASES, name) ||
        error("unknown JuMP certification case: $name")
    case = CASES[name]
    isempty(case.inputs) && error("case $name has no inputs")
    arg_types = Tuple(map(typeof, first(case.inputs)))
    all(input -> Tuple(map(typeof, input)) == arg_types, case.inputs) ||
        error("case $name must use one argument signature")

    CURRENT_PHASE[] = "compile_raw"
    raw, compile_seconds = timed() do
        WasmTarget.compile(case.f, arg_types; optimize=false)
    end
    CURRENT_PHASE[] = "optimize_size"
    size_wasm, size_optimize_seconds = timed() do
        WasmTarget.optimize(raw; level=:size)
    end
    CURRENT_PHASE[] = "optimize_speed"
    speed_wasm, speed_optimize_seconds = timed() do
        WasmTarget.optimize(raw; level=:speed)
    end

    compile_budget =
        Float64(CONFIG["budgets"]["compile_wall_threshold_seconds"])
    raw_budget = Int(CONFIG["budgets"]["raw_wasm_bytes_hard"])
    optimized_budget = Int(CONFIG["budgets"]["optimized_wasm_bytes_hard"])
    budget_checks = Dict(
        "compile_wall_threshold" => compile_seconds <= compile_budget,
        "raw_wasm_bytes" => length(raw) <= raw_budget,
        "size_wasm_bytes" => length(size_wasm) <= optimized_budget,
        "speed_wasm_bytes" => length(speed_wasm) <= optimized_budget,
    )

    modules = (
        ("raw", raw),
        ("size", size_wasm),
        ("speed", speed_wasm),
    )
    module_files = retain_modules(name, modules)
    func_name = string(nameof(case.f))
    imports = Dict("Math" => Dict("pow" => "Math.pow"))
    variants = Any[]
    all_pass = all(values(budget_checks))
    WasmRunner.runner_available() ||
        error("Node runtime unavailable; certification cannot skip execution")
    for args in case.inputs
        CURRENT_PHASE[] = "native_oracle"
        native = case.f(args...)
        if hasproperty(case, :expected)
            expected = case.expected[args]
            native == expected ||
                error("committed oracle mismatch for $name at $args: expected $expected, got $native")
        end
        runs = Dict{String,Any}()
        for (label, bytes) in modules
            CURRENT_PHASE[] = "execute_$label"
            actual, execute_seconds = timed() do
                run_wasm_with_imports(bytes, func_name, imports, args...)
            end
            passed = native == actual
            all_pass &= passed
            runs[label] = Dict(
                "pass" => passed,
                "actual" => actual,
                "execute_seconds" => execute_seconds,
                "wasm_bytes" => length(bytes),
            )
        end
        push!(variants, Dict(
            "args" => collect(args),
            "native" => native,
            "runs" => runs,
        ))
    end
    return Dict(
        "schema" => 1,
        "evidence_kind" => "executed_native_differential",
        "profile" => CASE_PROFILE,
        "case" => name,
        "source_provenance" =>
            hasproperty(case, :provenance) ? case.provenance : nothing,
        "pass" => all_pass,
        "phase" => "complete",
        "gates" => Dict(
            "native_oracle" => true,
            "raw_wasm" => all(v -> v["runs"]["raw"]["pass"], variants),
            "optimize_size" =>
                all(v -> v["runs"]["size"]["pass"], variants),
            "optimize_speed" =>
                all(v -> v["runs"]["speed"]["pass"], variants),
            "unexpected_skip_is_failure" => true,
            "independent_validation" =>
                get(ENV, "WT_VALIDATE", "") == "1" &&
                Sys.which("wasm-tools") !== nothing,
        ),
        "provenance" => provenance(),
        "compile" => Dict(
            "raw_seconds" => compile_seconds,
            "size_optimize_seconds" => size_optimize_seconds,
            "speed_optimize_seconds" => speed_optimize_seconds,
            "module_sha256" => Dict(
                label => bytes2hex(SHA.sha256(bytes))
                for (label, bytes) in modules
            ),
            "module_files" => module_files,
        ),
        "budgets" => budget_checks,
        "property" => Dict(
            "kind" => string(case.property),
            "seed" => PROPERTY_SEED === nothing ? nothing : string(PROPERTY_SEED),
            "random_samples" => PROPERTY_RANDOM_SAMPLES,
            "executed_inputs" => length(case.inputs),
            "bounded" => true,
        ),
        "variants" => variants,
    )
end

function failure_result(name, error, backtrace, source_provenance)
    rendered_error = sprint() do io
        showerror(io, error, backtrace)
    end
    return Dict(
        "schema" => 1,
        "case" => name,
        "pass" => false,
        "phase" => CURRENT_PHASE[],
        "provenance" => source_provenance,
        "error_type" => string(typeof(error)),
        "error" => rendered_error,
    )
end

length(ARGS) == 1 || error("usage: run_case.jl CASE")
case_name = only(ARGS)
if case_name == "__timeout_fixture__"
    pid_path = ENV["WT_JUMP_TIMEOUT_FIXTURE_PID_FILE"]
    grandchild = run(
        `$(Base.julia_cmd()) --startup-file=no -e 'sleep(60)'`;
        wait=false,
    )
    write(pid_path, string(getpid(grandchild)))
    sleep(60)
end
source_provenance = try
    provenance()
catch
    Dict("unavailable" => true)
end
result = try
    run_case(case_name)
catch error
    failure_result(case_name, error, catch_backtrace(), source_provenance)
end
println(RESULT_PREFIX, JSON.json(result))
WasmRunner.shutdown_pool!()
exit(result["pass"] ? 0 : 1)
