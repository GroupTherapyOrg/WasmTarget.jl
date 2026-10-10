using Test
using WasmTarget
using Random: Xoshiro

# A foreigncall whose lowering calls the host takes its import before any function is defined:
# an import is numbered ahead of every defined function, so one added later renumbers them
# under the calls already emitted to them.

@noinline _hi_inc(x::Int64)::Int64 = x + 1
@noinline _hi_mul(x::Int64)::Int64 = x * 100
_hi_clock(x::Int64)::Int64 = _hi_mul(x) + (time_ns() > 0 ? _hi_inc(x) : Int64(0))

@noinline function _hi_global_beside_rand(g::WasmGlobal{Int64,0})::Int64
    g[] = g[] + Int64(1)
    return rand() < 2.0 ? g[] : Int64(-1)
end

_hi_rand()::Float64 = rand()
_hi_rand_pair()::UInt64 = rand(UInt64) ⊻ rand(UInt64)

# `env.random_i64` answering the given words in order, as a JS closure
_hi_entropy(words) = "(() => { const s = [" *
    join(string.(reinterpret(Int64, collect(UInt64, words))) .* "n", ", ") *
    "]; let i = 0; return () => s[i++]; })()"

@testset "host imports precede every defined function" begin
    # time_ns() reads the host clock. Its import was once added while bodies compiled, and the
    # export `_hi_clock` then called the import: the module returned the clock's 1234.5.
    @test _hi_clock(Int64(3)) == 304
    bytes = WasmTarget.compile(_hi_clock, (Int64,); validate=true)
    clock = Dict{String,Any}("env" => Dict{String,Any}("perf_now" => "() => 1234.5"))
    @test run_wasm_with_imports(bytes, "_hi_clock", clock, Int64(3)) == 304

    # rand()'s state words are their own globals beside a WasmGlobal's: created first, they
    # took indices 0-3, and `WasmGlobal{Int64,0}` read and wrote the RNG's first state word.
    @test _hi_global_beside_rand(WasmGlobal{Int64,0}(0)) == 1
    bytes = WasmTarget.compile(_hi_global_beside_rand, (WasmGlobal{Int64,0},); validate=true)
    entropy = Dict{String,Any}("env" => Dict{String,Any}("random_i64" => _hi_entropy((1, 2, 3, 4))))
    @test run_wasm_with_imports(bytes, "_hi_global_beside_rand", entropy) == 1

    # The host seeds the RNG at startup, as Random.__init__ seeds the default RNG with four
    # draws from RandomDevice: given the same four words, the stream is Julia's own.
    words = (0x0123456789abcdef, 0xfedcba9876543210, 0x1111111122222222, 0x8000000000000001)
    entropy = Dict{String,Any}("env" => Dict{String,Any}("random_i64" => _hi_entropy(words)))
    bytes = WasmTarget.compile(_hi_rand, (); validate=true)
    @test run_wasm_with_imports(bytes, "_hi_rand", entropy) == rand(Xoshiro(words...))
    bytes = WasmTarget.compile(_hi_rand_pair, (); validate=true)
    native = let r = Xoshiro(words...); rand(r, UInt64) ⊻ rand(r, UInt64) end
    @test run_wasm_with_imports(bytes, "_hi_rand_pair", entropy) % UInt64 == native

    # the builder refuses an import after a definition
    mod = WasmTarget.WasmModule()
    WasmTarget.add_function!(mod, WasmTarget.WasmValType[], WasmTarget.WasmValType[],
                             WasmTarget.WasmValType[], UInt8[WasmTarget.Opcode.END]; name="f")
    @test_throws WasmTarget.ModuleValidationError WasmTarget.add_import!(mod, "env", "late",
        WasmTarget.WasmValType[], WasmTarget.WasmValType[])
end

# A declared import called only from a body the dynamic step enrolls in a later round: that
# round's compile! of the candidate infers the import's native fallback body with it, and
# every compile! output is cut by the declared imports before it merges, as the first
# collection is (collect_new_pairs!, dev/formal/ClosedWorld.tla LeavesNeverCollected). Merged
# uncut, the import's native body and its callee would enter the plan, and the callee's ccall,
# which WT does not lower, would reject the module. The native body is never run.
# Measured at batch 111: over smoke, the probes and the suite's other import tests, no later
# round reaches an import's body (0); this case is the first that does.
@noinline function _hi_late_native_only(x::Int64)::Int64
    native_offset = ccall(:jl_get_field_offset, Csize_t, (Any, Cint), Int, 0)
    Base.donotdelete(native_offset)
    return x * 1000 + 7
end
@noinline _hi_late_import(x::Int64)::Int64 = _hi_late_native_only(x)
abstract type _HiLateShape end
struct _HiLateA <: _HiLateShape; v::Int64; end
struct _HiLateB <: _HiLateShape; v::Int64; end
# six methods, so Julia leaves the call dynamic rather than splitting it over its classes
for (i, S) in enumerate((:_HiLateC, :_HiLateD, :_HiLateE, :_HiLateF))
    @eval struct $S <: _HiLateShape; v::Int64; end
    @eval @noinline _hi_late_area(s::$S)::Int64 = s.v + $(i + 1)
end
@noinline _hi_late_area(s::_HiLateA)::Int64 = _hi_late_import(s.v)
@noinline _hi_late_area(s::_HiLateB)::Int64 = s.v + 1
@noinline _hi_late_shapes(n::Int64) = _HiLateShape[_HiLateA(n), _HiLateB(n), _HiLateC(n), _HiLateD(n), _HiLateE(n), _HiLateF(n)]
function _hi_late_entry(n::Int64)::Int64
    xs = _hi_late_shapes(n)
    s = Int64(0)
    for x in xs
        s += _hi_late_area(x)::Int64
    end
    return s
end

@testset "an import reached in a later collection round is cut, as the first round's are" begin
    entry = WasmTarget.entry_method_instance(_hi_late_entry, (Int64,))
    leaf = WasmTarget.entry_method_instance(_hi_late_import, (Int64,))
    world = WasmTarget.collect_closed_world(Any[entry]; external_leaves=Set{Any}([leaf]))
    collected = [ci.def isa Core.MethodInstance ? ci.def : ci.def.def
                 for ci in world.codeinfos[1:2:end] if ci isa Core.CodeInstance]
    late_caller = which(_hi_late_area, (_HiLateA,))
    # the import's caller entered in a later round, as a dispatch candidate
    @test any(mi -> mi.def === late_caller, collected)
    @test any(mi -> mi.def === late_caller, world.dynamic_roots)
    # neither the import's native body nor its callee is in the closed world
    @test !any(mi -> mi.def === which(_hi_late_import, (Int64,)), collected)
    @test !any(mi -> mi.def === which(_hi_late_native_only, (Int64,)), collected)

    # end to end: the module compiles, and the call answers the host's import
    mod = WasmTarget.WasmModule()
    idx = WasmTarget.add_import!(mod, "host", "late", WasmTarget.WasmValType[WasmTarget.I64],
                                 WasmTarget.WasmValType[WasmTarget.I64])
    m = WasmTarget.compile_module(Any[(_hi_late_entry, (Int64,), "late_entry")];
        existing_module=mod, import_stubs=Any[(_hi_late_import, "late", (Int64,), idx, Int64)])
    # the import is called from a dispatch candidate's body, enrolled in a later round: every
    # call of it saves the top at its slot and restores it, as the export boundary's claim needs
    # (L156)
    @test unsaved_host_import_calls(m) == 0
    bytes = WasmTarget.to_bytes(m)
    driver = """
    const importObject = $(WasmTarget.host_runtime_js());
    importObject.host = { late: (x) => x * 2n };
    const { instance } = await WebAssembly.instantiate(bytes, ($(WasmTarget.host_glue_js()))(importObject), { builtins: ['js-string'] });
    return [{ ok: String(instance.exports.late_entry(3n)) }];
    """
    status, results = WasmRunner.run_driver_batch(bytes, driver; ninputs=1)
    @test status === :ok
    @test results[1]["ok"] == "36"   # the import's 3 * 2, plus 3 + 1, 3 + 2, 3 + 3, 3 + 4, 3 + 5
end

# An import_stubs entry stands for a host import: an index that is not a host-declared function
# import is refused, naming the stub. Unchecked, the stub's calls ran whatever function held the
# index: `_hi_c2_f(1)` answered `_hi_c2_h`'s 0 where native is 4, and the module validated
# (dev/AUDIT.md A14C2).
@noinline _hi_c2_g(x::Int64)::Int64 = x + 1
_hi_c2_f(x::Int64)::Int64 = 2 * _hi_c2_g(x)
@noinline _hi_c2_h(x::Int64)::Int64 = x - 1
@testset "an import stub's index names a host import" begin
    @test _hi_c2_f(1) == 4
    for idx in (1, 2, 0)   # two defined functions, and WT's own `wasmtarget.stack_trace` import
        err = try
            WasmTarget.compile_multi(Any[(_hi_c2_f, (Int64,)), (_hi_c2_h, (Int64,))];
                                     import_stubs=Any[(_hi_c2_g, "g", (Int64,), idx, Int64)])
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("import stub \"g\"", err.msg) &&
              occursin("not a host-declared function import", err.msg)
    end
end
