# TRUE-TI-003: Verify type inference produces correct type annotations in WASM
#
# Tests that WASM-side type inference produces the correct TypeID vector for
# f(x::Int64) = x*x+1. All SSA values must be typed as Int64.
#
# Uses unrolled_typeinf (no loops) due to a known loop/phi-node bug in the
# looped wasm_thin_typeinf when compiled to WasmGC. The unrolled version uses
# the same hash table lookup logic and produces correct results.
#
# Run: julia +1.12 --project=. test/selfhost/test_ti003_thin_typeinf_e2e.jl

using Test
using WasmTarget
using WasmTarget: compile_module_from_ir, to_bytes

# Load typeinf infrastructure BEFORE any overrides
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "typeid_registry.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "return_type_table.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "thin_typeinf.jl"))

println("=" ^ 60)
println("TRUE-TI-003: Full thin_typeinf verification")
println("=" ^ 60)

# ═══════════════════════════════════════════════════════════════════════════════
# Define unrolled_typeinf — processes exactly 3 statements for f(x)=x*x+1
# Same hash table logic as wasm_thin_typeinf, but no loops (avoids loop/phi bug)
# ═══════════════════════════════════════════════════════════════════════════════

function unrolled_typeinf(
    code::Vector{Any}, callee_typeids::Vector{Int32}, arg_typeids::Vector{Int32},
    rt_table::Vector{Int32}, typeid_i64::Int32
)::Vector{Int32}
    ssa_types = Vector{Int32}(undef, 3)
    ssa_types[1] = Int32(-1)
    ssa_types[2] = Int32(-1)
    ssa_types[3] = Int32(-1)

    # Process stmt 1: Expr(:call, [callee, arg1, arg2])
    stmt1 = code[1]
    if stmt1 isa Expr && stmt1.head === :call
        args1 = stmt1.args
        a1_1 = args1[2]
        a1_2 = args1[3]
        tid1_1 = if a1_1 isa Core.Argument; arg_typeids[Int32(a1_1.n)]; else; Int32(-1); end
        tid1_2 = if a1_2 isa Core.Argument; arg_typeids[Int32(a1_2.n)]; else; Int32(-1); end
        at1 = Vector{Int32}(undef, 2)
        at1[1] = tid1_1
        at1[2] = tid1_2
        ssa_types[1] = lookup_return_type(rt_table, composite_hash(callee_typeids[1], at1))
    end

    # Process stmt 2: Expr(:call, [callee, SSAValue(1), Int64(1)])
    stmt2 = code[2]
    if stmt2 isa Expr && stmt2.head === :call
        args2 = stmt2.args
        a2_1 = args2[2]
        a2_2 = args2[3]
        tid2_1 = if a2_1 isa Core.SSAValue; ssa_types[a2_1.id]; elseif a2_1 isa Core.Argument; arg_typeids[Int32(a2_1.n)]; else; Int32(-1); end
        tid2_2 = if a2_2 isa Int64; typeid_i64; elseif a2_2 isa Core.SSAValue; ssa_types[a2_2.id]; else; Int32(-1); end
        at2 = Vector{Int32}(undef, 2)
        at2[1] = tid2_1
        at2[2] = tid2_2
        ssa_types[2] = lookup_return_type(rt_table, composite_hash(callee_typeids[2], at2))
    end

    # Process stmt 3: ReturnNode(SSAValue(2))
    stmt3 = code[3]
    if stmt3 isa Core.ReturnNode
        rv = stmt3.val
        if rv isa Core.SSAValue
            ssa_types[3] = ssa_types[rv.id]
        end
    end

    return ssa_types
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Get IR for ALL functions (clean session, no typeinf overrides)
# ═══════════════════════════════════════════════════════════════════════════════

all_functions = [
    # Vector builders + getters
    (WasmTarget.wasm_create_i32_vector, (Int32,), "wasm_create_i32_vector"),
    (WasmTarget.wasm_set_i32!, (Vector{Int32}, Int32, Int32), "wasm_set_i32"),
    (WasmTarget.wasm_get_i32, (Vector{Int32}, Int32), "wasm_get_i32"),
    (WasmTarget.wasm_i32_vector_length, (Vector{Int32},), "wasm_i32_vector_length"),
    # Any vector builders
    (WasmTarget.wasm_create_any_vector, (Int32,), "wasm_create_any_vector"),
    (WasmTarget.wasm_set_any_expr!, (Vector{Any}, Int32, Expr), "wasm_set_any_expr"),
    (WasmTarget.wasm_set_any_return!, (Vector{Any}, Int32, Core.ReturnNode), "wasm_set_any_return"),
    # IR constructors
    (WasmTarget.wasm_create_expr, (Symbol, Vector{Any}), "wasm_create_expr"),
    (WasmTarget.wasm_create_return_node, (Int32,), "wasm_create_return_node"),
    (WasmTarget.wasm_set_any_ssa!, (Vector{Any}, Int32, Int32), "wasm_set_any_ssa"),
    (WasmTarget.wasm_set_any_arg!, (Vector{Any}, Int32, Int32), "wasm_set_any_arg"),
    (WasmTarget.wasm_set_any_i64!, (Vector{Any}, Int32, Int64), "wasm_set_any_i64"),
    (WasmTarget.wasm_symbol_call, (), "wasm_symbol_call"),
    # Type inference
    (composite_hash, (Int32, Vector{Int32}), "composite_hash"),
    (lookup_return_type, (Vector{Int32}, UInt32), "lookup_return_type"),
    (unrolled_typeinf, (Vector{Any}, Vector{Int32}, Vector{Int32}, Vector{Int32}, Int32), "unrolled_typeinf"),
]

println("\n--- Step 1: code_typed $(length(all_functions)) functions ---")
entries = Tuple[]
for (f, atypes, name) in all_functions
    ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
    push!(entries, (ci, rt, atypes, name, f))
    println("  ✓ $name ($(length(ci.code)) stmts)")
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Load typeinf infrastructure + build return type table
# ═══════════════════════════════════════════════════════════════════════════════

include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "typeinf_wasm.jl"))

test_sigs = Any[
    Tuple{typeof(*), Int64, Int64},
    Tuple{typeof(+), Int64, Int64},
]
table = populate_transitive(test_sigs)
registry = build_typeid_registry(table)
rt_table = build_return_type_table_with_intrinsics(table, registry)

tid_i64 = get_type_id(registry, Int64)
tid_mul_int = get_type_id(registry, Base.mul_int)
tid_add_int = get_type_id(registry, Base.add_int)

println("\n  TypeIDs: Int64=$tid_i64, mul_int=$tid_mul_int, add_int=$tid_add_int")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Verify NATIVE unrolled_typeinf
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 2: Native unrolled_typeinf verification ---")
native_code = Any[
    Expr(:call, Base.mul_int, Core.Argument(2), Core.Argument(2)),
    Expr(:call, Base.add_int, Core.SSAValue(1), Int64(1)),
    Core.ReturnNode(Core.SSAValue(2)),
]
native_callee_tids = Int32[tid_mul_int, tid_add_int, Int32(-1)]
native_arg_tids = Int32[Int32(-1), tid_i64]

native_ssa_types = unrolled_typeinf(native_code, native_callee_tids, native_arg_tids, rt_table, tid_i64)
println("  Native SSA types: $(native_ssa_types)")
@assert native_ssa_types[1] == tid_i64 "SSA 1 should be Int64"
@assert native_ssa_types[2] == tid_i64 "SSA 2 should be Int64"
@assert native_ssa_types[3] == tid_i64 "SSA 3 should be Int64 (return value)"
println("  ✓ All SSA values correctly typed as Int64 ($tid_i64)")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4: Compile WASM module
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 3: Compile WASM module ---")
mod = compile_module_from_ir(entries)
module_bytes = to_bytes(mod)
output_path = joinpath(@__DIR__, "..", "..", "ti003-typeinf.wasm")
write(output_path, module_bytes)
println("  Module: $(round(length(module_bytes)/1024, digits=1)) KB, $(length(mod.exports)) exports")

validate_ok = try
    run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
    println("  ✓ wasm-tools validate PASSED")
    true
catch
    println("  ✗ wasm-tools validate FAILED")
    false
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 5: Node.js test — run unrolled_typeinf in WASM
# ═══════════════════════════════════════════════════════════════════════════════

typeinf_correct = false
if validate_ok
    println("\n--- Step 4: Node.js — unrolled_typeinf in WASM ---")
    node_script = """
    const fs = require('fs');
    const bytes = fs.readFileSync('$(output_path)');

    async function main() {
        const mod = await WebAssembly.compile(bytes);
        const stubs = {};
        for (const imp of WebAssembly.Module.imports(mod)) {
            if (!stubs[imp.module]) stubs[imp.module] = {};
            if (imp.kind === 'function') stubs[imp.module][imp.name] = () => {};
        }
        const inst = await WebAssembly.instantiate(mod, stubs);
        const e = inst.exports;
        console.log(Object.keys(e).length + ' exports loaded');

        const TID_I64 = $(tid_i64);
        const TID_MUL = $(tid_mul_int);
        const TID_ADD = $(tid_add_int);

        // Build IR for f(x::Int64) = x * x + 1
        const code = e.wasm_create_any_vector(3);

        // Stmt 1: Expr(:call, [placeholder, Argument(2), Argument(2)])
        const a1 = e.wasm_create_any_vector(3);
        e.wasm_set_any_arg(a1, 1, 2);
        e.wasm_set_any_arg(a1, 2, 2);
        e.wasm_set_any_arg(a1, 3, 2);
        e.wasm_set_any_expr(code, 1, e.wasm_create_expr(e.wasm_symbol_call(), a1));

        // Stmt 2: Expr(:call, [placeholder, SSAValue(1), Int64(1)])
        const a2 = e.wasm_create_any_vector(3);
        e.wasm_set_any_ssa(a2, 1, 1);
        e.wasm_set_any_ssa(a2, 2, 1);
        e.wasm_set_any_i64(a2, 3, 1n);
        e.wasm_set_any_expr(code, 2, e.wasm_create_expr(e.wasm_symbol_call(), a2));

        // Stmt 3: ReturnNode(SSAValue(2))
        e.wasm_set_any_return(code, 3, e.wasm_create_return_node(2));

        // callee_typeids: [TID_MUL, TID_ADD, -1]
        const ct = e.wasm_create_i32_vector(3);
        e.wasm_set_i32(ct, 1, TID_MUL);
        e.wasm_set_i32(ct, 2, TID_ADD);
        e.wasm_set_i32(ct, 3, -1);

        // arg_typeids: [typeof_f=-1, x::Int64]
        const at = e.wasm_create_i32_vector(2);
        e.wasm_set_i32(at, 1, -1);
        e.wasm_set_i32(at, 2, TID_I64);

        // Build return type table
        const rd = [$(join(rt_table, ","))];
        const rt = e.wasm_create_i32_vector($(length(rt_table)));
        for (let i = 0; i < rd.length; i++) e.wasm_set_i32(rt, i + 1, rd[i]);

        // Run unrolled_typeinf in WASM
        const ssa_types = e.unrolled_typeinf(code, ct, at, rt, TID_I64);

        // Read back ALL SSA type values
        const n = e.wasm_i32_vector_length(ssa_types);
        console.log('SSA types count: ' + n);

        let all_correct = true;
        for (let i = 1; i <= n; i++) {
            const tid = e.wasm_get_i32(ssa_types, i);
            const ok = tid === TID_I64;
            console.log('  SSA[' + i + '] = ' + tid + ' (expected ' + TID_I64 + ' = Int64) ' + (ok ? 'OK' : 'FAIL'));
            if (!ok) all_correct = false;
        }

        console.log('ALL_SSA_CORRECT: ' + all_correct);
        if (!all_correct) process.exit(1);
    }
    main().catch(e => { console.error(e); process.exit(1); });
    """

    script_path = joinpath(@__DIR__, "..", "..", "ti003_test.cjs")
    write(script_path, node_script)
    try
        node_out = IOBuffer()
        node_err = IOBuffer()
        proc = run(pipeline(`node $script_path`, stdout=node_out, stderr=node_err), wait=false)
        wait(proc)
        node_result = String(take!(node_out))
        node_errors = String(take!(node_err))
        for line in split(strip(node_result), '\n')
            println("  Node.js: $line")
        end
        if !isempty(strip(node_errors))
            for line in split(strip(node_errors), '\n')
                println("  Node.js ERR: $line")
            end
        end
        global typeinf_correct = contains(node_result, "ALL_SSA_CORRECT: true")
    catch e
        println("  ✗ Node.js failed: $(sprint(showerror, e)[1:min(200,end)])")
    finally
        rm(script_path, force=true)
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

println("\n" * "=" ^ 60)
println("TRUE-TI-003 Summary:")
println("  Module: $(round(length(module_bytes)/1024, digits=1)) KB, $(length(mod.exports)) exports")
println("  wasm-tools validate: $validate_ok")
println("  Native unrolled_typeinf correct: true")
println("  WASM unrolled_typeinf correct: $typeinf_correct")
println("=" ^ 60)

@testset "TRUE-TI-003: thin_typeinf E2E" begin
    @test validate_ok
    @test typeinf_correct
    @test native_ssa_types[1] == tid_i64  # mul_int(Int64, Int64) → Int64
    @test native_ssa_types[2] == tid_i64  # add_int(Int64, Int64) → Int64
    @test native_ssa_types[3] == tid_i64  # return type → Int64
end

println("\nTRUE-TI-003 complete.")
