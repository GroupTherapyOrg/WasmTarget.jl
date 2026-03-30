# Self-hosting test suite for WasmTarget.jl
# Run separately: julia +1.12 --project=. test/selfhost/runtests.jl
#
# These tests cover the self-hosting pipeline:
# - Transport path (serialize/deserialize IR)
# - Browser typeinf
# - Architecture A/B/C E2E
# - WASM-in-WASM codegen

using WasmTarget
using Test

include(joinpath(@__DIR__, "..", "utils.jl"))

@testset "WasmTarget.jl Self-Hosting" begin

    # ========================================================================
    # Phase 40: Self-Hosted Codegen — Transport Path Verification (PHASE-1-T03)
    # ========================================================================
    # Verifies that the self-hosting transport path (code_typed → preprocess →
    # serialize → deserialize → compile_module_from_ir) produces correct results.

    @testset "Phase 40: Self-Hosted Codegen (Transport Path)" begin

        @testset "Transport roundtrip — arithmetic" begin
            sh_add(x::Int64, y::Int64) = x + y
            sh_sub(x::Int64, y::Int64) = x - y
            sh_mul(x::Int64, y::Int64) = x * y
            sh_neg(x::Int64) = -x

            for (f, atypes, args, expected) in [
                (sh_add, (Int64, Int64), (3, 4), 7),
                (sh_sub, (Int64, Int64), (10, 3), 7),
                (sh_mul, (Int64, Int64), (6, 7), 42),
                (sh_neg, (Int64,), (-99,), 99),
            ]
                ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
                entries = [(ci, rt, atypes, string(nameof(f)))]
                prep = WasmTarget.preprocess_ir_entries(entries)
                json = WasmTarget.serialize_ir_entries(prep)
                recv = WasmTarget.deserialize_ir_entries(json)
                bytes_orig = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(prep))
                bytes_rt = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(recv))
                @test bytes_orig == bytes_rt
                result = run_wasm(bytes_rt, string(nameof(f)), args...)
                result !== nothing && @test result == expected
            end
        end

        @testset "Transport roundtrip — conditionals" begin
            sh_max(x::Int64, y::Int64) = x > y ? x : y
            sh_abs(x::Int64) = x < Int64(0) ? -x : x

            for (f, atypes, args, expected) in [
                (sh_max, (Int64, Int64), (10, 20), 20),
                (sh_max, (Int64, Int64), (-5, -3), -3),
                (sh_abs, (Int64,), (-42,), 42),
                (sh_abs, (Int64,), (42,), 42),
            ]
                ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
                entries = [(ci, rt, atypes, string(nameof(f)))]
                prep = WasmTarget.preprocess_ir_entries(entries)
                json = WasmTarget.serialize_ir_entries(prep)
                recv = WasmTarget.deserialize_ir_entries(json)
                bytes = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(recv))
                result = run_wasm(bytes, string(nameof(f)), args...)
                result !== nothing && @test result == expected
            end
        end

        @testset "Transport roundtrip — while loops" begin
            function sh_sum(n::Int64)::Int64
                s = Int64(0); i = Int64(1)
                while i <= n; s += i; i += Int64(1); end
                return s
            end

            ci, rt = Base.code_typed(sh_sum, (Int64,); optimize=true)[1]
            prep = WasmTarget.preprocess_ir_entries([(ci, rt, (Int64,), "sh_sum")])
            json = WasmTarget.serialize_ir_entries(prep)
            recv = WasmTarget.deserialize_ir_entries(json)
            bytes = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(recv))
            result = run_wasm(bytes, "sh_sum", Int64(100))
            result !== nothing && @test result == 5050
        end

        @testset "Transport roundtrip — floats" begin
            sh_circle(r::Float64) = 3.14159265358979 * r * r
            sh_f2c(f::Float64) = (f - 32.0) / 1.8

            for (f, atypes, args, expected) in [
                (sh_circle, (Float64,), (2.0,), sh_circle(2.0)),
                (sh_f2c, (Float64,), (212.0,), 100.0),
            ]
                ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
                entries = [(ci, rt, atypes, string(nameof(f)))]
                prep = WasmTarget.preprocess_ir_entries(entries)
                json = WasmTarget.serialize_ir_entries(prep)
                recv = WasmTarget.deserialize_ir_entries(json)
                bytes = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(recv))
                result = run_wasm(bytes, string(nameof(f)), args...)
                result !== nothing && @test result ≈ expected atol=1e-10
            end
        end

        @testset "Transport roundtrip — golden file verification" begin
            golden_dir = joinpath(@__DIR__, "..", "golden")
            if isdir(golden_dir)
                golden_files = filter(f -> startswith(f, "golden_") && endswith(f, ".json"),
                                       readdir(golden_dir))
                @test length(golden_files) >= 20
                current_ver = string(VERSION.major, ".", VERSION.minor)
                verified = 0
                for gf in golden_files
                    data = JSON.parsefile(joinpath(golden_dir, gf))
                    codeinfo_json = JSON.json(data["codeinfo"])
                    ir_entries = WasmTarget.deserialize_ir_entries(codeinfo_json)
                    bytes = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(ir_entries))
                    golden_ver = get(data, "julia_version", "unknown")
                    if golden_ver == current_ver
                        @test length(bytes) == data["wasm_size"]
                    else
                        # Different Julia version — verify wasm compiles but don't check exact size
                        @test length(bytes) > 0
                    end
                    verified += 1
                end
                @test verified == length(golden_files)
            end
        end

    end

    # Phase 41: Browser TypeInf Path (PHASE-2-T03)
    # Runs as subprocess because typeinf overrides are irreversible
    # (Base._methods_by_ftype + Base.typeintersect are overridden globally)
    @testset "Phase 41: Browser TypeInf Path (subprocess)" begin
        regression_script = joinpath(@__DIR__, "regression_typeinf.jl")
        if isfile(regression_script)
            julia_cmd = Base.julia_cmd()
            output = try
                read(`$julia_cmd --project=. $regression_script`, String)
            catch e
                "SUBPROCESS FAILED: $(sprint(showerror, e))"
            end
            # Check for key success indicators
            has_typeinf_match = occursin("Typeinf match: 20/20", output)
            has_exec_correct = occursin(r"Execution: \d+/\d+ correct", output)
            exec_match = match(r"Execution: (\d+)/(\d+) correct", output)
            all_exec_correct = exec_match !== nothing && exec_match[1] == exec_match[2]

            @test has_typeinf_match
            @test all_exec_correct
            if !has_typeinf_match || !all_exec_correct
                println("  Subprocess output (last 500 chars): ", output[max(1,end-499):end])
            end
        else
            @test_broken false  # regression_typeinf.jl not found
        end
    end

    # Phase 42: Full Self-Hosting Parity (PHASE-3-T02)
    # Runs parity_50.jl — 50 functions compiled via server path, 86 test cases
    @testset "Phase 42: Self-Hosting Parity (50 functions)" begin
        parity_script = joinpath(@__DIR__, "parity_50.jl")
        if isfile(parity_script)
            julia_cmd = Base.julia_cmd()
            output = try
                read(`$julia_cmd --project=. $parity_script`, String)
            catch e
                "SUBPROCESS FAILED: $(sprint(showerror, e))"
            end
            # Check for success: "Results: N/N CORRECT (0 failed)"
            result_match = match(r"Results: (\d+)/(\d+) CORRECT \((\d+) failed\)", output)
            all_correct = result_match !== nothing && result_match[1] == result_match[2] && result_match[3] == "0"

            @test all_correct
            if !all_correct
                println("  Subprocess output (last 500 chars): ", output[max(1,end-499):end])
            end
        else
            @test_broken false  # parity_50.jl not found
        end
    end

    # Phase 43: E2E Self-Hosting (Architecture A + C)
    # Runs 20 functions through full E2E pipelines as subprocesses
    @testset "Phase 43: E2E Self-Hosting (Architecture A + C)" begin
        julia_cmd = Base.julia_cmd()

        # Architecture A: server CodeInfo → browser JS codegen → execute
        arch_a_script = joinpath(@__DIR__, "e2e_arch_a_tests.jl")
        if isfile(arch_a_script)
            output_a = try
                read(`$julia_cmd --project=. $arch_a_script`, String)
            catch e
                "SUBPROCESS FAILED: $(sprint(showerror, e))"
            end
            arch_a_pass = occursin("ALL PASS", output_a)
            @test arch_a_pass
            if !arch_a_pass
                println("  Arch A output (last 500 chars): ", output_a[max(1,end-499):end])
            end
        else
            @test_broken false  # e2e_arch_a_tests.jl not found
        end

        # Architecture C: server parse+lower → browser WASM typeinf + codegen → execute
        arch_c_script = joinpath(@__DIR__, "e2e_arch_c_tests.jl")
        if isfile(arch_c_script)
            output_c = try
                read(`$julia_cmd --project=. $arch_c_script`, String)
            catch e
                "SUBPROCESS FAILED: $(sprint(showerror, e))"
            end
            arch_c_pass = occursin("ALL PASS", output_c)
            @test arch_c_pass
            if !arch_c_pass
                println("  Arch C output (last 500 chars): ", output_c[max(1,end-499):end])
            end
        else
            @test_broken false  # e2e_arch_c_tests.jl not found
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 44: Architecture B — Zero-Server WASM Compilation
    # ═══════════════════════════════════════════════════════════════════════════
    @testset "Phase 44: Architecture B Zero-Server (subprocess)" begin
        archb_wasm = joinpath(@__DIR__, "..", "..", "archb-compiler.wasm")
        archb_regression = joinpath(@__DIR__, "..", "..", "scripts", "run_archb_regression.cjs")
        archb_e2e = joinpath(@__DIR__, "..", "..", "scripts", "e2e_archb_final.cjs")

        if isfile(archb_wasm) && isfile(archb_regression)
            output = try
                read(`node $archb_regression $archb_wasm`, String)
            catch e
                "SUBPROCESS FAILED: $(sprint(showerror, e))"
            end
            regression_pass = occursin("30/30 passed", output)
            @test regression_pass
            if !regression_pass
                println("  Arch B regression output (last 500 chars): ", output[max(1,end-499):end])
            end
        else
            @test_broken false  # archb-compiler.wasm or regression script not found
        end

        if isfile(archb_wasm) && isfile(archb_e2e)
            output = try
                read(`node $archb_e2e $archb_wasm`, String)
            catch e
                "SUBPROCESS FAILED: $(sprint(showerror, e))"
            end
            e2e_pass = occursin("10/10 tests passed", output)
            @test e2e_pass
            if !e2e_pass
                println("  Arch B E2E output (last 500 chars): ", output[max(1,end-499):end])
            end
        else
            @test_broken false  # archb files not found
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 45: TRUE Self-Hosting — WASM Codegen Producing WASM (INT-003/INT-004)
    # ═══════════════════════════════════════════════════════════════════════════
    @testset "Phase 45: TRUE Self-Hosting (WASM-in-WASM)" begin
        selfhost_final = joinpath(@__DIR__, "selfhost-final.wasm")
        selfhost_regression = joinpath(@__DIR__, "selfhost-regression.wasm")
        regression_script = joinpath(@__DIR__, "..", "..", "scripts", "run_true_selfhost_tests.cjs")

        # --- 45a: E2E self-hosting — f(5n)===26n via WASM codegen ---
        @testset "E2E: f(5n)===26n via WASM codegen" begin
            if isfile(selfhost_final)
                node_script = """
                const fs = require('fs');
                const bytes = fs.readFileSync(process.argv[2]);
                WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } }).then(async m => {
                    const e = m.instance.exports;
                    const result = e.run();
                    const len = e.wasm_bytes_length(result);
                    const arr = new Uint8Array(len);
                    for (let i = 0; i < len; i++) arr[i] = e.wasm_bytes_get(result, i + 1);
                    const m2 = await WebAssembly.instantiate(arr);
                    const r = m2.instance.exports.f(5n);
                    console.log(r === 26n ? 'E2E_PASS' : 'E2E_FAIL:' + String(r));
                    process.exit(r === 26n ? 0 : 1);
                }).catch(err => { console.log('E2E_FAIL:' + err.message); process.exit(1); });
                """
                script_path = tempname() * ".cjs"
                write(script_path, node_script)
                output = try
                    read(`node $script_path $selfhost_final`, String)
                catch e
                    "E2E_FAIL: $(sprint(showerror, e))"
                end
                rm(script_path, force=true)
                @test occursin("E2E_PASS", output)
                if !occursin("E2E_PASS", output)
                    println("  E2E output: ", strip(output))
                end

                # Document binary size
                sz = filesize(selfhost_final)
                println("  selfhost-final.wasm: $(sz) bytes ($(round(sz/1024, digits=1)) KB)")
            else
                @test_broken false  # selfhost-final.wasm not built
            end
        end

        # --- 45b: 11-function regression suite ---
        @testset "Regression suite: 11 functions via WASM codegen" begin
            if isfile(selfhost_regression) && isfile(regression_script)
                output = try
                    read(`node $regression_script $selfhost_regression`, String)
                catch e
                    "SUBPROCESS FAILED: $(sprint(showerror, e))"
                end
                # Script prints "SUCCESS: TRUE self-hosting regression suite PASSED"
                regression_pass = occursin("SUCCESS", output) && occursin("regression suite PASSED", output)
                @test regression_pass
                if !regression_pass
                    println("  Regression output (last 500 chars): ", output[max(1,end-499):end])
                end

                # Document binary size
                sz = filesize(selfhost_regression)
                println("  selfhost-regression.wasm: $(sz) bytes ($(round(sz/1024, digits=1)) KB)")
            else
                @test_broken false  # selfhost-regression.wasm or test script not built
            end
        end

    end

end
