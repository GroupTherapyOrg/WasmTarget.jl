# METH-001: Test return type lookup table
#
# Run: julia +1.12 --project=. test/selfhost/test_return_type_table.jl

using WasmTarget
using Test

# Load typeinf infrastructure via unified entry point
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "typeinf_wasm.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "typeid_registry.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "selfhost", "typeinf", "return_type_table.jl"))

println("=" ^ 70)
println("METH-001: Return Type Lookup Table Tests")
println("=" ^ 70)

# Define test functions
add_one_rt(x::Int64)::Int64 = x + Int64(1)
double_rt(x::Int64)::Int64 = x * Int64(2)

# Build test infrastructure
test_sigs = Any[
    Tuple{typeof(*), Int64, Int64},
    Tuple{typeof(+), Int64, Int64},
    Tuple{typeof(-), Int64, Int64},
    Tuple{typeof(add_one_rt), Int64},
    Tuple{typeof(double_rt), Int64},
]

table = populate_transitive(test_sigs)
registry = build_typeid_registry(table)
println("  Method table size: $(length(table.methods))")
println("  TypeID registry size: $(length(registry.id_to_type))")

@testset "Return Type Lookup Table" begin

    @testset "composite_hash deterministic" begin
        tid_mul = get_type_id(registry, typeof(*))
        tid_i64 = get_type_id(registry, Int64)
        @test tid_mul >= 0
        @test tid_i64 >= 0

        h1 = composite_hash(tid_mul, Int32[tid_i64, tid_i64])
        h2 = composite_hash(tid_mul, Int32[tid_i64, tid_i64])
        @test h1 == h2  # Same inputs → same hash

        # Different callee → different hash
        tid_add = get_type_id(registry, typeof(+))
        h3 = composite_hash(tid_add, Int32[tid_i64, tid_i64])
        @test h1 != h3
    end

    @testset "composite_hash different arg counts" begin
        tid_mul = get_type_id(registry, typeof(*))
        tid_i64 = get_type_id(registry, Int64)

        h_2args = composite_hash(tid_mul, Int32[tid_i64, tid_i64])
        h_1arg = composite_hash(tid_mul, Int32[tid_i64])
        @test h_2args != h_1arg  # Different arity → different hash
    end

    @testset "build_return_type_table" begin
        rt_table = build_return_type_table(table, registry)
        stats = return_type_table_stats(rt_table)
        println("  RT table size: $(stats.table_size)")
        println("  RT table entries: $(stats.n_entries)")
        println("  RT table load factor: $(round(stats.load_factor, digits=2))")
        println("  RT table bytes: $(stats.bytes)")

        @test stats.n_entries > 0
        @test stats.load_factor < 0.6  # ~50% load factor
        @test stats.table_size >= 16
    end

    @testset "lookup_return_type for Base arithmetic" begin
        rt_table = build_return_type_table(table, registry)
        tid_i64 = get_type_id(registry, Int64)
        @test tid_i64 >= 0

        # *(Int64, Int64) → Int64
        tid_mul = get_type_id(registry, typeof(*))
        if tid_mul >= 0
            h = composite_hash(tid_mul, Int32[tid_i64, tid_i64])
            ret = lookup_return_type(rt_table, h)
            println("  lookup(*, Int64, Int64) → TypeID $ret (expected $tid_i64)")
            @test ret == tid_i64
        end

        # +(Int64, Int64) → Int64
        tid_add = get_type_id(registry, typeof(+))
        if tid_add >= 0
            h = composite_hash(tid_add, Int32[tid_i64, tid_i64])
            ret = lookup_return_type(rt_table, h)
            println("  lookup(+, Int64, Int64) → TypeID $ret (expected $tid_i64)")
            @test ret == tid_i64
        end

        # -(Int64, Int64) → Int64
        tid_sub = get_type_id(registry, typeof(-))
        if tid_sub >= 0
            h = composite_hash(tid_sub, Int32[tid_i64, tid_i64])
            ret = lookup_return_type(rt_table, h)
            println("  lookup(-, Int64, Int64) → TypeID $ret (expected $tid_i64)")
            @test ret == tid_i64
        end
    end

    @testset "lookup_return_type negative lookup" begin
        rt_table = build_return_type_table(table, registry)

        # Non-existent hash → -1
        ret = lookup_return_type(rt_table, UInt32(0xDEADBEEF))
        @test ret == Int32(-1)

        # Empty table → -1
        empty_table = Int32[]
        ret = lookup_return_type(empty_table, UInt32(42))
        @test ret == Int32(-1)
    end

    @testset "lookup_return_type for user functions" begin
        rt_table = build_return_type_table(table, registry)
        tid_i64 = get_type_id(registry, Int64)

        # add_one_rt(Int64) → Int64
        tid_add_one = get_type_id(registry, typeof(add_one_rt))
        if tid_add_one >= 0
            h = composite_hash(tid_add_one, Int32[tid_i64])
            ret = lookup_return_type(rt_table, h)
            println("  lookup(add_one_rt, Int64) → TypeID $ret (expected $tid_i64)")
            @test ret == tid_i64
        end

        # double_rt(Int64) → Int64
        tid_double = get_type_id(registry, typeof(double_rt))
        if tid_double >= 0
            h = composite_hash(tid_double, Int32[tid_i64])
            ret = lookup_return_type(rt_table, h)
            println("  lookup(double_rt, Int64) → TypeID $ret (expected $tid_i64)")
            @test ret == tid_i64
        end
    end

    @testset "roundtrip: all DictMethodTable sigs have correct return types" begin
        rt_table = build_return_type_table(table, registry)
        world = table.world
        n_checked = 0
        n_correct = 0

        for (sig, _result) in table.methods
            if !(sig isa DataType && sig <: Tuple)
                continue
            end
            params = sig.parameters
            length(params) < 1 && continue

            callee_tid = get_type_id(registry, params[1])
            callee_tid < 0 && continue

            arg_tids = Int32[]
            all_known = true
            for i in 2:length(params)
                tid = get_type_id(registry, params[i])
                if tid < 0
                    all_known = false
                    break
                end
                push!(arg_tids, tid)
            end
            all_known || continue

            # Get expected return type
            expected_ret = try
                Core.Compiler.return_type(sig, world)
            catch
                continue
            end
            expected_ret === nothing && continue
            expected_ret === Union{} && continue

            expected_tid = get_type_id(registry, expected_ret)
            expected_tid < 0 && continue

            # Lookup in table
            h = composite_hash(callee_tid, arg_tids)
            actual_tid = lookup_return_type(rt_table, h)

            n_checked += 1
            if actual_tid == expected_tid
                n_correct += 1
            end
        end

        println("  Roundtrip: $n_correct/$n_checked correct")
        @test n_checked > 0
        @test n_correct == n_checked
    end

end

println("\nAll METH-001 tests complete.")
