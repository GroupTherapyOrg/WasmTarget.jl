const _WT_T0 = time()   # process start — workers report setup overhead against this

# ── Parallel test execution via process sharding ─────────────────────────────
# The codegen suite is compile-bound. The ~80 Phase testsets are independent, so
# we run them across N worker PROCESSES, each compiling a disjoint shard. PROCESSES
# (not threads) for ROBUSTNESS: the wasm compiler keeps shared mutable state that
# races under threads (intermittent test errors); process isolation eliminates it.
# This is only fast because two other pieces remove the per-process penalties:
#   • each Phase is a LAZILY-compiled function (see @pphase) → a worker JIT-compiles
#     ONLY its 1/N shard, not all 80;
#   • PrecompileTools workload (src/WasmTarget.jl) bakes the wasm-compiler's JIT
#     warmup into the .ji cache → workers load it warm instead of re-JITting.
# `Sys.CPU_THREADS` under-reports on Apple Silicon (only perf cores: 4 of 10 on an
# M-series), so read the true logical-CPU count via sysctl. WT_NO_SHARD=1 = serial.
function _wt_logical_cpus()
    if Sys.isapple()
        try; return parse(Int, strip(read(`sysctl -n hw.ncpu`, String))); catch; end
    end
    return Sys.CPU_THREADS
end
# A child process runs either ONE codegen shard (WT_SHARD="i,N") or the fuzz pass
# (WT_FUZZ=1). The orchestrator (neither var set) spawns both phases below.
if get(ENV, "WT_SHARD", "") == "" && get(ENV, "WT_FUZZ", "") != "1" && get(ENV, "WT_NO_SHARD", "") != "1"
    nshards = max(1, min(_wt_logical_cpus(), 16))
    if nshards > 1
        @info "Sharding test suite across $nshards worker processes (+ overlapped fuzz pass)"
        proj, file = Base.active_project(), @__FILE__
        logdir = mktempdir()
        _spawn(envpair, lf) = run(pipeline(ignorestatus(addenv(`$(Base.julia_cmd()) --project=$proj $file`, envpair...));
                          stdout=lf, stderr=lf); wait=false)
        # ── The fuzz pass OVERLAPS the codegen shards (it's Node/IO-bound while the
        # shards are compile-bound). Under contention a CPU-starved Node worker can
        # miss the 8s watchdog and fake a hang into a `:trap`, so the overlapped pass
        # gets a much larger deadline (WT_FUZZ_TIMEOUT) on top of retry-on-timeout —
        # a REAL hang still reds the gate, a load blip clears on retry. Spawned FIRST
        # so its setup (~18s) and Node-pool boot hide entirely inside phase A.
        flf = joinpath(logdir, "fuzz.log")
        fp = _spawn(("WT_FUZZ" => "1", "WT_FUZZ_TIMEOUT" => "30"), flf)
        # ── Codegen shards run concurrently, but the CONCURRENCY CAP is ALWAYS ON by
        # default (Dale: "always always") so the whole fleet never gets jetsam-killed.
        #   WT_TEST_CONCURRENCY unset → memory-aware default: ~1 worker per 3GB free RAM
        #     (min 2) — a memory-pressured Mac self-caps to ~2, big-RAM CI still parallelizes.
        #   WT_TEST_CONCURRENCY=K (K>0) → explicit cap of K shards at a time (+ overlapped fuzz).
        #   WT_TEST_CONCURRENCY=0 → opt OUT to full all-at-once (only on a known-roomy box).
        # Each shard captures to its own log (a shared stdout interleaves + buffers away on exit).
        phase_times = String[]   # "<secs>\t<name>" collected across all shard logs
        maxconc = let m = tryparse(Int, get(ENV, "WT_TEST_CONCURRENCY", ""))
            if m === nothing
                min(nshards, max(2, Int(div(Sys.free_memory(), 3 * 1024^3))))  # memory-aware default
            elseif m <= 0
                nshards            # explicit opt-out → full parallel
            else
                m                  # explicit cap
            end
        end
        @info "Test shard concurrency cap = $maxconc of $nshards (WT_TEST_CONCURRENCY=$(get(ENV, "WT_TEST_CONCURRENCY", "<auto>")); free RAM $(round(Sys.free_memory()/1024^3; digits=1))GB)"
        codes = Int[]
        _drain = function (i, lf, p)
            wait(p)
            lines = isfile(lf) ? split(read(lf, String), '\n') : String[]
            if p.exitcode != 0
                println("════ shard $i FAILED (exit $(p.exitcode)) ════")
                println(join(last(lines, 35), '\n'))
            else
                for ln in lines
                    occursin("WasmTarget.jl |", ln) && println("  shard $i: ", strip(ln))
                    startswith(ln, "WT_PHASE_TIME\t") && push!(phase_times, String(ln[sizeof("WT_PHASE_TIME\t")+1:end]))
                    startswith(ln, "WT_SETUP_TIME\t") && println("  shard $i setup: ", split(ln, '\t')[2], "s")
                end
            end
            push!(codes, p.exitcode)
        end
        batch = Tuple{Int,String,Any}[]
        for i in 0:nshards-1
            lf = joinpath(logdir, "shard_$i.log")
            push!(batch, (i, lf, _spawn(("WT_SHARD" => "$i,$nshards",), lf)))
            if length(batch) >= maxconc
                for (j, jlf, jp) in batch; _drain(j, jlf, jp); end
                empty!(batch)
            end
        end
        for (j, jlf, jp) in batch; _drain(j, jlf, jp); end
        # Refresh the LPT-packing input (committed) on demand. sorted-by-name → stable diffs.
        if get(ENV, "WT_RECORD_TIMES", "") == "1" && !isempty(phase_times)
            open(joinpath(@__DIR__, "phase_times.tsv"), "w") do io
                for ln in sort(phase_times; by = l -> split(l, '\t'; limit = 2)[2])
                    println(io, ln)
                end
            end
            @info "Recorded $(length(phase_times)) phase durations → test/phase_times.tsv"
        end
        # ── Join the overlapped fuzz pass (usually already done by now). ──
        # (Assignment-free exit accounting below: an earlier `failed = true` inside a
        # `for` was soft-scoped to a NEW local, so shard failures never reached `exit`
        # — the suite went green on a failing shard.)
        println("──── differential fuzz (overlapped) ────")
        wait(fp)
        flines = isfile(flf) ? split(read(flf, String), '\n') : String[]
        if fp.exitcode != 0
            println("════ fuzz FAILED (exit $(fp.exitcode)) ════")
            println(join(last(flines, 45), '\n'))
        else
            for ln in flines; occursin("Differential fuzz", ln) && println("  ", strip(ln)); end
        end
        exit((any(!=(0), codes) || fp.exitcode != 0) ? 1 : 0)
    end
end
const (_WT_SHARD, _WT_NSHARDS) = let s = get(ENV, "WT_SHARD", "")
    isempty(s) ? (0, 1) : (parse(Int, split(s, ",")[1]), parse(Int, split(s, ",")[2]))
end
_wt_fuzz() = get(ENV, "WT_FUZZ", "") == "1"          # the dedicated serial fuzz pass
_wt_shard0() = _WT_SHARD == 0 && !_wt_fuzz()         # run-once Aqua/QA only on codegen shard 0
# Fuzz runs in its own pass (WT_FUZZ=1) OR inline when not sharding (serial fallback).
_wt_run_fuzz() = _wt_fuzz() || (get(ENV, "WT_SHARD", "") == "" && get(ENV, "WT_NO_SHARD", "") == "1")

using WasmTarget
# Hoisted to module level so the parallel-phase macro (which spawns each phase in a
# closure) can use them — `using`/`import` are illegal inside a closure.
using WasmTarget: add_array_type!, add_export!, add_function!, add_import!, add_struct_type!,
                  encode_leb128_signed, encode_leb128_unsigned, F64, FieldType, I32, I64,
                  Opcode, to_bytes, WasmModule
using Test
import Statistics
import Dates
import Random
import SHA
using Dates: Dates, @dateformat_str

# Package-level QA runs first so structural failures surface
# before the ~hour-long codegen suite spins up. (Shard 0 only — it's process-wide.)
_wt_shard0() && include("test_aqua.jl")
_wt_shard0() && include("diagnostics_sink.jl")
_wt_shard0() && include("m8_selector_table.jl")
_wt_shard0() && include("m11_intrinsics_table.jl")
_wt_shard0() && include("module_builder_validation.jl")

include("utils.jl")
include(joinpath(@__DIR__, "integration", "snapshot_islands.jl"))  # Snapshot.jl island fixtures
_wt_shard0() && include("m10_contexts.jl")   # needs utils (compare_julia_wasm)
_wt_shard0() && include("recursive_groups.jl")
_wt_shard0() && include("apply_iterate_soundness.jl")

# Cleanup-loop regression guards (shard 0 only — node-differential, run once). The multivar
# if/else phi-merge root fix + the Loop-1 fix_* deletion guards (migrated emitters are correct
# for every case the deleted passes addressed). See dev/cleanup_ledger.md.
_wt_shard0() && include(joinpath(@__DIR__, "fuzz", "repro_multivar_phi_merge.jl"))
_wt_shard0() && include("cleanup_loop1_backfills.jl")
# Parity Loop A: the WasmGC subtype lattice (wasm_subtype) — supertype-chain + nullability aware,
# mirroring dart2wasm HeapType.isSubtypeOf. See dev/PARITY_LEDGER.md (F4/P2/B6).
_wt_shard0() && include("test_wasm_subtype_lattice.jl")
# Parity Loop C: F31 heterogeneous-Union value extraction + F-i31 full-width int box (the
# phi-store now CONSTRUCTS the tagged-union struct instead of dummying to ref.null, and ints
# are boxed full-width, not via lossy i31). See dev/PARITY_LEDGER.md.
_wt_shard0() && include("f31_union_value_backfills.jl")
# Parity Loop 0: F11 Int128 bit-counting intrinsics (cttz/ctpop/not_int now handle is_128bit;
# a single i64 op on a 128-bit value was invalid wasm). See dev/PARITY_LEDGER.md.
_wt_shard0() && include("f11_int128_bitcount_backfills.jl")
# Parity probe: sort comparator kwargs (by/lt) were silently dropped by the non-mutating sort
# overlay (only rev was forwarded to sort!) → sort(v, by=f) returned default order. See FINDINGS.md.
_wt_shard0() && include("sort_comparator_backfills.jl")
# F3 sub-loop L0 (dev/F3_LOOP.md): Core.Box contents-type inference (dormant analysis, byte-identical).
_wt_shard0() && include("f3_box_capture_l0.jl")
# F3 sub-loop L1 (dev/F3_LOOP.md): specialized mutable Box{contents} struct registry (dormant).
_wt_shard0() && include("f3_box_capture_l1.jl")
# F3 sub-loop L2a (dev/F3_LOOP.md): cross-function box-field-type pre-pass (dormant).
_wt_shard0() && include("f3_box_capture_l2_prepass.jl")
# F3 sub-loop L2b (dev/F3_LOOP.md): value-type propagation past Box{Any} erasure (dormant).
_wt_shard0() && include("f3_box_capture_l2b_propagate.jl")
# Loop C value channel: general numeric value-type propagation (Any-but-really-i64) (dormant).
_wt_shard0() && include("value_channel_propagate.jl")
# parity(M1) ONE LOWERING: void bodies through the stackifier (compile + run-no-trap guards).
_wt_shard0() && include("m1_void_backfills.jl")
# march3: try/catch driver battery (the throw-arm-past-the-leave silent miscompile).
_wt_shard0() && include("march3_try_backfills.jl")
_wt_shard0() && include("type_world_bounds.jl")
_wt_shard0() && include("module_metadata.jl")
_wt_shard0() && include("vararg_fixed_prefix.jl")
_wt_shard0() && include("symbol_syntax_metadata.jl")
_wt_shard0() && include("memmove_single_path.jl")
_wt_shard0() && include("mutable_global_initialization.jl")
_wt_shard0() && include("reinterpret_array_semantics.jl")
_wt_shard0() && include("storage_relative_pointer_soundness.jl")
# PARITY RATCHET (dev/PARITY_MASTER.md §3): structural-disease counts may only DECREASE;
# completed dimensions are LOCKED exactly. Baseline: dev/parity_baseline.toml.
if _wt_shard0()
    ENV["WT_RATCHET_INCLUDED"] = "1"
    include("parity_ratchet.jl")
    @testset "parity ratchet (dev/PARITY_MASTER.md)" begin
        @test ParityRatchet.run()
    end
end

# ── Parallel-phase infrastructure (process sharding) ─────────────────────────
# Test fixtures hoisted from inside phase testsets — `struct`/`using` are illegal
# inside the `if` block each phase now sits in (only top-level allows them).
mutable struct ResultType; success::Bool; value::Int32; end
mutable struct VoidTestState; value::Int32; end
mutable struct InterpValue; tag::Int32; int_val::Int64; float_val::Float64; bool_val::Int32; end
struct TestPair{T}; first::T; second::T; end
mutable struct TestCounter; value::Int64; end
mutable struct TestNode; value::Int64; next::Union{TestNode, Nothing}; end
struct TestPoint2D; x::Float64; y::Float64; end
struct TestLine; p1::TestPoint2D; p2::TestPoint2D; end
# WASMTARGET-FUZZ: structs with 128-bit fields — register as int128 struct ref
# (guards the _register_struct_type_impl! Int128/UInt128 field branch).
struct _WTI128Box; x::Int128; n::Int64; end
struct _WTU128Box; x::UInt128; n::Int64; end

# Phase 77: ordinary heap structs carry dart2wasm's Object prefix even through a
# discovered callee. Top-level so trim sees _g1_objid as a non-entry MI.
@noinline _g1_objid(c::TestCounter)::UInt64 = objectid(c)
function _g1_entry(n::Int64)::Int32
    a = TestCounter(n)
    b = TestCounter(n)
    (_g1_objid(a) != 0 && _g1_objid(a) == _g1_objid(a) &&
     _g1_objid(a) != _g1_objid(b)) ? Int32(1) : Int32(0)
end
# WASMTARGET-FUZZ: tagged-union FLOAT members round-trip (wrap boxes the float into
# a numeric box, unwrap unboxes it) — the old code DROPPED floats → silent data loss.
_wt_uf(a::Int64)::Int64 = begin
    x::Union{Float64,String} = a > 0 ? (Float64(a) + 0.5) : "neg"
    x isa Float64 ? Int64(round(x * 2.0)) : Int64(-1)
end
_wt_uf32(a::Int64)::Int64 = begin
    x::Union{Float32,Int64} = a > 0 ? Float32(a) * 1.5f0 : a
    x isa Float32 ? Int64(round(x)) : Int64(-7)
end
# WASMTARGET-FUZZ: signed Int128 arithmetic right shift (emit_int128_ashr) — ashr_int
# lacked the is_128bit branch shl_int/lshr_int had, so `Int128 >>` hit i64.shr_s on
# the struct ref. Sign-fill across the n<64 / n>=64 boundary, incl. negatives.
_wt_i128ashr_big(a::Int64)::Int64  = Int64((Int128(a) << 80) >> 80)            # n>=64, recovers sign
_wt_i128ashr_neg(a::Int64)::Int64  = Int64(((-(Int128(abs(a)) << 50) - Int128(1)) >> 55) & Int128(typemax(Int64)))
# WASMTARGET-FUZZ: heterogeneous tuple with a RUNTIME index → tagged union. A
# param-built Tuple{Int,String,…} indexed at runtime (`t[i]`) infers Union{Int,String};
# previously emitted `unreachable`. Now field i is wrapped into the union so isa/π
# consume it. `Base.getindex(Any, vals...)` (the `Any[…]` literal) and md-string
# interpolation lower to exactly this loop. Pairs with the get_concrete_wasm_type ↔
# julia_to_wasm_type_concrete union-rep agreement (else the SSA store dropped it → null).
_wt_htup(a::Int64)::Int64 = begin
    t = (a, "x", a + 5, "y", a + 10)
    s = 0
    for i in 1:5
        v = t[i]
        if v isa Int64; s += v; end
    end
    s
end
# WASMTARGET-FUZZ (Loop B/B1): a het-tuple field whose result-union maps to AnyRef
# (Union{Int64,Float64} — all-numeric, NOT a registered tagged union) boxed the Int64
# field via ref.i31, SILENTLY TRUNCATING any value ≥ 2^30. A field ≥ 2^40 came back
# WRONG (the truncated box then failed `isa Int64` → -1). Now routed through the
# full-width numeric box, exactly like the F64 field beside it. (i=1 → the Int64 element.)
_wt_htup_i64f64_big(i::Int64)::Int64 = begin
    t = ((Int64(1) << 40) + 7, 3.5)
    v = t[i]
    v isa Int64 ? v : Int64(-1)
end
# WASMTARGET-FUZZ (Loop B/F-ii): same-WASM-REP Union distinguishability via the single-
# source classId funnel. A het-tuple of Bool/Int8/Int32 (all i32) indexed at runtime →
# Union{Bool,Int8,Int32}; the value was COLLAPSED to a raw i32 local (unboxed), so every
# `isa` mis-fired (Int8 & Int32 both matched `isa Bool`). Fixed by: needs_anyref_boxing now
# boxes same-rep unions (value stays a boxed ref), emit_classid_box! stores the field's REAL
# classId, and emit_isa_classid! reads the classId off the box (not ref.test of the shared
# struct). i=1→Bool, 2→Int8, 3→Int32.
_wt_htup_disc(i::Int64)::Int64 = begin
    t = (true, Int8(7), Int32(9))
    v = t[i]
    v isa Bool ? Int64(1) : v isa Int8 ? Int64(2) : v isa Int32 ? Int64(3) : Int64(0)
end
# WASMTARGET-FUZZ (Loop B/B4): same-WASM-REP Vector{Any} distinguishability. Bool/Int8
# used a ref.i31 fast path (no classId struct) so isa on them returned false (the whole
# chain fell through to 0). B4 removed i31 — Bool/Int8/UInt8 now box with their REAL
# classId like everything else, and emit_isa_classid! distinguishes them. i=1→Bool,2→Int8,3→Int32.
_wt_vany_disc(i::Int64)::Int64 = begin
    a = Any[true, Int8(7), Int32(9)]
    v = a[i]
    v isa Bool ? Int64(1) : v isa Int8 ? Int64(2) : v isa Int32 ? Int64(3) : Int64(0)
end
# Packed Wasm GC array loads must preserve Julia signedness at both widths.
_wt_packed_i8()::Int8 = Int8[-128, -1, 127][2]
_wt_packed_u8()::UInt8 = UInt8[0, 255, 128][2]
_wt_packed_i16()::Int16 = Int16[-32768, -1, 32767][2]
_wt_packed_u16()::UInt16 = UInt16[0, 65535, 32768][2]

_wt_tearoff_add(x::Int64)::Int64 = x + Int64(3)
_wt_tearoff_mul(x::Int64)::Int64 = x * Int64(4)
function _wt_dynamic_tearoff(x::Int64, i::Int64)::Int64
    fs = Any[_wt_tearoff_add, _wt_tearoff_mul]
    return (fs[i](x))::Int64
end

_wt_compose_step(x::Int64)::Int64 = Int64(3) * x + Int64(1)
_wt_runtime_compose(x::Int64, n::Int64)::Int64 =
    ((∘)(fill(_wt_compose_step, n)...))(x)
function _wt_runtime_compose_escape(x::Int64, n::Int64)::Int64
    c = (∘)(fill(_wt_compose_step, n)...)
    erased = Any[c]
    return (erased[1](x))::Int64
end
function _wt_runtime_compose_mixed(x::Int64, n::Int64, i::Int64)::Int64
    c = (∘)(fill(_wt_compose_step, n)...)
    erased = Any[c, _wt_tearoff_mul]
    return (erased[i](x))::Int64
end
# WASMTARGET-FUZZ (Loop B/B4c): Char is i32-rep but NOT <:Number, so it was excluded from
# both the boxing decision (needs_anyref_boxing required all(<:Number)) and the isa
# discriminator (gated on check_type<:Number) → Union{Char,Int32} collapsed + isa Char
# mis-fired. Both now key on the NUMERIC WASM REP (covers Char), so Char boxes w/ its
# classId + distinguishes. i=1→Char, 2→Int32. (het-tuple form)
_wt_char_disc(i::Int64)::Int64 = begin
    t = (Char(65), Int32(9))
    v = t[i]
    v isa Char ? Int64(1) : v isa Int32 ? Int64(2) : Int64(0)
end
# WASMTARGET-FUZZ (Loop B/B4e): MIXED-WIDTH numeric union. Tuple{Int64,Bool} indexed at
# runtime → Union{Int64,Bool} (i64 vs i32). It wasn't boxed (no int/float mix, no same-rep
# collapse), so the getfield if/else read field 1 (i64) vs field 2 (i32) under a single i64
# block result → INVALID WASM (wouldn't even compile). needs_anyref_boxing now boxes EVERY
# multi-member numeric union, so it compiles + works. i=1→the Int64 (99); i=2→Bool→ -1.
_wt_htup_mixwidth(i::Int64)::Int64 = begin
    t = (Int64(99), true)
    v = t[i]
    v isa Int64 ? v : Int64(-1)
end
# WASMTARGET-FUZZ (Loop B/B4b): boxed-=== was a SILENT WRONG ANSWER. A boxed numeric (Any/
# Union) compared via === to an unboxed numeric hit "ref vs non-ref ⇒ drop both, false", so
# Any[true][1] === true returned FALSE. Now: a numeric box of the other's type+value ⇒ true
# (classId+value compare via emit_egal_box_vs_num!); different type/value or a genuine
# non-numeric ref ⇒ false. x>0 ⇒ a[1]=true. Returns: 1 if ===true, 2 if ===false, else 0.
_wt_egal_boxed(x::Int64)::Int64 = begin
    a = Any[x > 0, x < 0]
    a[1] === true ? Int64(1) : a[1] === false ? Int64(2) : Int64(0)
end
# different-type === must be false (Bool box vs Int32): boxed Bool === Int32(1) → 0.
_wt_egal_difftype(x::Int64)::Int64 = begin
    a = Any[x > 0]
    a[1] === Int32(1) ? Int64(1) : Int64(0)
end
_wt_anyvec_len(a::Int64)::Int64 = Int64(length(Any[a, "x", a]))
# WASMTARGET-FUZZ: abstract/UnionAll `::Vector` struct FIELD (like
# Markdown.Admonition.content). A Vector{T} value is a vector-STRUCT, not the raw
# array the field used to map to → struct.new mismatched. Field is now AnyRef.
struct _WTAbsVecField; content::Vector; end
_wt_absvecfield(n::Int64)::Int64 = Int64(length(_WTAbsVecField([n, n + 1, n + 2]).content))
# WASMTARGET-FUZZ: heterogeneous tuple whose element-union is ALL-STRUCT
# (Union{Dog,Cat}) — canonical rep is StructRef, NOT a tagged union. The
# hetero-tuple index must push the raw struct ref (subtype of structref), else the
# consumer's union-split isa/π cast traps "illegal cast". `Any[Dog(n),Cat(n)]` +
# dispatch (markdown content node lists hit this with Paragraph/Bold/… unions).
abstract type _WTAnimal end
struct _WTDog <: _WTAnimal; x::Int64; end
struct _WTCat <: _WTAnimal; x::Int64; end
_wt_speak(d::_WTDog)::Int64 = d.x + 1
_wt_speak(c::_WTCat)::Int64 = c.x + 2
_wt_anystruct(n::Int64)::Int64 = begin
    xs = Any[_WTDog(n), _WTCat(n), _WTDog(n + 10)]
    s = 0
    for a in xs
        s += _wt_speak(a)::Int64
    end
    s
end
# WASMTARGET-FUZZ: inline typeId DYNAMIC DISPATCH. With >4 methods over an Any-typed
# value, Julia emits a `dynamic` call (can't union-split). WT discovers the
# concrete-struct specializations in the trim collection and emits a runtime typeId
# switch over them (each branch ref.casts + calls the matching specialization).
# Underlies Markdown.plain/show recursion over heterogeneous AST nodes.
abstract type _WTShape end
struct _WTSa <: _WTShape; v::Int64; end
struct _WTSb <: _WTShape; v::Int64; end
struct _WTSc <: _WTShape; v::Int64; end
struct _WTSd <: _WTShape; v::Int64; end
struct _WTSe <: _WTShape; v::Int64; end
_wt_gv(x::_WTSa)::Int64 = x.v + 1
_wt_gv(x::_WTSb)::Int64 = x.v + 2
_wt_gv(x::_WTSc)::Int64 = x.v + 3
_wt_gv(x::_WTSd)::Int64 = x.v + 4
_wt_gv(x::_WTSe)::Int64 = x.v + 5
_wt_dyndispatch(n::Int64)::Int64 =
    _wt_gv(Any[_WTSa(n), _WTSc(n), _WTSe(n)][1])::Int64 +
    _wt_gv(Any[_WTSa(n), _WTSc(n), _WTSe(n)][2])::Int64 +
    _wt_gv(Any[_WTSa(n), _WTSc(n), _WTSe(n)][3])::Int64
# @generated must be top-level (illegal inside a phase function), so hoist it.
@generated function f_gen(x)
    x <: Int64 ? :(x * Int64(2)) : :(x * 3.0)
end

# Phase 37's subtype helpers (structs + ~1800 lines) — included at MODULE level so
# their bindings exist before any phase function runs (avoids world-age under the
# lazy-phase compilation model).
include("helpers/subtype.jl")

# Each top-level Phase testset is `@pphase "name" begin … end`. CRITICAL for speed:
# the macro wraps the body in a uniquely-named TOP-LEVEL function and registers it,
# instead of emitting the body inline. A function body is compiled LAZILY (on first
# call), so a worker that runs only its 1/N shard compiles only those phases — the
# other ~7/8 are merely *defined* (cheap), not compiled. (Inline gating skipped
# execution but Julia still compiled every phase's code into the top-level thunk —
# ~3.5 min of redundant work per process, which made sharding slower than serial.)
# The inline `function`/`struct`(hoisted) defs in a phase body are legal here because
# they're nested inside the phase's named function.
const _PHASES = Tuple{String,Function}[]
macro pphase(name, body)
    fname = gensym(:wtphase)
    testset_call = Expr(:macrocall, Symbol("@testset"), __source__, name, body)
    fundef = Expr(:function, Expr(:call, fname), testset_call)
    quote
        $(esc(fundef))
        push!(_PHASES, ($(esc(name)), $(esc(fname))))
    end
end
# Run the Phases this process owns. Assignment must be identical and disjoint
# across worker processes, so it is a pure function of (committed timings file,
# registration order, nshards): phases are bin-packed onto shards by LPT (longest
# processing time first → least-loaded shard) using the durations recorded in
# test/phase_times.tsv. Round-robin left the shard walls >2× apart (1:03 vs 2:09);
# LPT pulls the wall down toward the mean. Phases with no recorded duration get
# the median, and a missing file degrades to "all equal" (≈ round-robin packing).
# A skipped phase's function is never CALLED → never JIT-compiled (the lazy-compile
# win). Each phase's wall time is emitted as a `WT_PHASE_TIME` line; the
# orchestrator regenerates the tsv from those lines when WT_RECORD_TIMES=1.
const _PHASE_TIMES_TSV = joinpath(@__DIR__, "phase_times.tsv")
function _phase_durations()
    d = Dict{String,Float64}()
    isfile(_PHASE_TIMES_TSV) || return d
    for ln in eachline(_PHASE_TIMES_TSV)
        parts = split(ln, '\t'; limit = 2)
        length(parts) == 2 || continue
        t = tryparse(Float64, parts[1])
        t === nothing || (d[String(parts[2])] = t)
    end
    return d
end
function _phase_owner(n::Int)
    rec = _phase_durations()
    med = isempty(rec) ? 1.0 : sort!(collect(values(rec)))[(length(rec) + 1) ÷ 2]
    dur = [get(rec, name, med) for (name, _) in _PHASES]
    owner = Vector{Int}(undef, length(_PHASES))
    load = zeros(n)
    for i in sort(collect(eachindex(_PHASES)); by = j -> -dur[j])
        s = argmin(load)
        owner[i] = s - 1
        load[s] += dur[i]
    end
    return owner
end
function _run_phases()
    println("WT_SETUP_TIME\t", round(time() - _WT_T0; digits = 1))   # worker fixed overhead (boot + using + includes)
    owner = _phase_owner(_WT_NSHARDS)
    for (i, (name, pf)) in enumerate(_PHASES)
        owner[i] == _WT_SHARD || continue
        t = @elapsed pf()
        println("WT_PHASE_TIME\t", round(t; digits = 3), "\t", name)
    end
end

# Recursive test functions (must be at module level for proper GlobalRef resolution)
@noinline function test_factorial_rec(n::Int32)::Int32
    if n <= Int32(1)
        return Int32(1)
    else
        return n * test_factorial_rec(n - Int32(1))
    end
end

@noinline function test_fib(n::Int32)::Int32
    if n <= Int32(1)
        return n
    else
        return test_fib(n - Int32(1)) + test_fib(n - Int32(2))
    end
end

@noinline function test_sum_rec(n::Int32)::Int32
    if n <= Int32(0)
        return Int32(0)
    else
        return n + test_sum_rec(n - Int32(1))
    end
end

# Mutual recursion test functions (BROWSER-013)
@noinline function is_even_mutual(n::Int32)::Int32
    if n == Int32(0)
        return Int32(1)  # true
    else
        return is_odd_mutual(n - Int32(1))
    end
end

@noinline function is_odd_mutual(n::Int32)::Int32
    if n == Int32(0)
        return Int32(0)  # false
    else
        return is_even_mutual(n - Int32(1))
    end
end

# Deep recursion test function (BROWSER-013)
@noinline function deep_recursion_test(n::Int32, depth::Int32)::Int32
    if depth <= Int32(0)
        return n
    else
        return deep_recursion_test(n + Int32(1), depth - Int32(1))
    end
end

# Complex while loop condition test (BROWSER-013)
@noinline function complex_while_test(n::Int32)::Int32
    result::Int32 = Int32(0)
    i::Int32 = Int32(0)
    @inbounds while i < n && result < Int32(100)
        result = result + i
        i = i + Int32(1)
    end
    return result
end

# Nested conditional test function (BROWSER-013)
@noinline function nested_cond_test(a::Int32, b::Int32)::Int32
    if a > Int32(0)
        if b > Int32(0)
            return a + b
        else
            return a - b
        end
    else
        if b > Int32(0)
            return b - a
        else
            return a * b
        end
    end
end

# Multi-branch if-elseif-else test (BROWSER-013)
@noinline function classify_number_test(n::Int32)::Int32
    if n < Int32(0)
        return Int32(-1)  # negative
    elseif n == Int32(0)
        return Int32(0)   # zero
    else
        return Int32(1)   # positive
    end
end

# Struct for testing compiled struct field access

# Function that creates a struct and accesses its fields
# Uses inferencebarrier to prevent Julia optimizer from eliminating the struct
@noinline function test_point_sum(x::Int32, y::Int32)::Int32
    p = Base.inferencebarrier(TestPoint2D(x, y))::TestPoint2D
    return p.x + p.y
end

@noinline function test_point_diff(x::Int32, y::Int32)::Int32
    p = Base.inferencebarrier(TestPoint2D(x, y))::TestPoint2D
    return p.x - p.y
end

# Float operations test
@noinline function test_float_add(a::Float64, b::Float64)::Float64
    return a + b
end

@noinline function test_float_mul(a::Float64, b::Float64)::Float64
    return a * b
end

# Branching test
@noinline function test_branch(a::Int32, b::Int32)::Int32
    sum = a + b
    if sum > Int32(100)
        return sum - Int32(50)
    else
        return sum * Int32(2)
    end
end

# Cross-function call test functions (must be at module level)
@noinline function cross_helper_double(x::Int32)::Int32
    return x * Int32(2)
end

@noinline function cross_use_helper(x::Int32)::Int32
    return cross_helper_double(x) + Int32(1)
end

# Multiple dispatch test functions
@noinline function dispatch_process(x::Int32)::Int32
    return x * Int32(2)
end

@noinline function dispatch_process(x::Int64)::Int64
    return x * Int64(3)
end

@noinline function dispatch_use_i32(x::Int32)::Int32
    return dispatch_process(x) + Int32(1)
end

@noinline function dispatch_use_i64(x::Int64)::Int64
    return dispatch_process(x) + Int64(1)
end

# TF-005: Structs for cross-function type-sharing regression tests
mutable struct TF5_Alpha
    val::Int32
end

mutable struct TF5_Beta
    label::Int64
end

mutable struct TF5_Gamma
    x::Int32
    y::Int64
end

# TF-005 test 1: Simple struct create + isa
@noinline function tf5_make_alpha(v::Int32)::TF5_Alpha
    return TF5_Alpha(v)
end

@noinline function tf5_dispatch_ab(x::Union{TF5_Alpha, TF5_Beta})::Int32
    if x isa TF5_Alpha
        return x.val + Int32(100)
    end
    return Int32(-1)
end

# TF-005 test 2: Struct with multiple fields create + field access
@noinline function tf5_make_gamma(x::Int32, y::Int64)::TF5_Gamma
    return TF5_Gamma(x, y)
end

@noinline function tf5_get_gamma_x(g::TF5_Gamma)::Int32
    return g.x
end

# TF-005 test 3: Union{Nothing, T} create + isa
@noinline function tf5_check_nothing(x::Union{Nothing, TF5_Alpha})::Int32
    if x isa TF5_Alpha
        return x.val
    end
    return Int32(-1)
end

@noinline function tf5_make_alpha_for_nothing(v::Int32)::TF5_Alpha
    return TF5_Alpha(v)
end

# TF-005 test 4: 3-type Union dispatch (THE fixed bug)
@noinline function tf5_dispatch_3way(x::Union{TF5_Alpha, TF5_Beta, TF5_Gamma})::Int32
    if x isa TF5_Alpha
        return Int32(1)
    elseif x isa TF5_Beta
        return Int32(2)
    end
    return Int32(3)
end

@noinline function tf5_make_beta(l::Int64)::TF5_Beta
    return TF5_Beta(l)
end

# TF-005 test 5: Two structurally-identical types (typeId disambiguation)
mutable struct TF5_Cat
    id::Int32
end

mutable struct TF5_Dog
    id::Int32
end

@noinline function tf5_make_cat(id::Int32)::TF5_Cat
    return TF5_Cat(id)
end

@noinline function tf5_make_dog(id::Int32)::TF5_Dog
    return TF5_Dog(id)
end

@noinline function tf5_classify_pet(x::Union{TF5_Cat, TF5_Dog})::Int32
    if x isa TF5_Cat
        return Int32(1)
    end
    return Int32(2)
end

# PURE-9060: Tier 2 Dispatch test types (>8 to trigger megamorphic)
struct DispS1  x::Int32 end
struct DispS2  x::Int32 end
struct DispS3  x::Int32 end
struct DispS4  x::Int32 end
struct DispS5  x::Int32 end
struct DispS6  x::Int32 end
struct DispS7  x::Int32 end
struct DispS8  x::Int32 end
struct DispS9  x::Int32 end
struct DispS10 x::Int32 end

@noinline disp_val(s::DispS1)::Int32  = s.x + Int32(1)
@noinline disp_val(s::DispS2)::Int32  = s.x + Int32(2)
@noinline disp_val(s::DispS3)::Int32  = s.x + Int32(3)
@noinline disp_val(s::DispS4)::Int32  = s.x + Int32(4)
@noinline disp_val(s::DispS5)::Int32  = s.x + Int32(5)
@noinline disp_val(s::DispS6)::Int32  = s.x + Int32(6)
@noinline disp_val(s::DispS7)::Int32  = s.x + Int32(7)
@noinline disp_val(s::DispS8)::Int32  = s.x + Int32(8)
@noinline disp_val(s::DispS9)::Int32  = s.x + Int32(9)
@noinline disp_val(s::DispS10)::Int32 = s.x + Int32(10)

# Dynamic dispatch caller — Julia emits :call (not :invoke) since arg is Any
@noinline disp_caller(x)::Int32 = disp_val(x)

# Factory functions that return opaque struct refs
@noinline make_disp_s1(v::Int32)  = DispS1(v)
@noinline make_disp_s3(v::Int32)  = DispS3(v)
@noinline make_disp_s5(v::Int32)  = DispS5(v)
@noinline make_disp_s10(v::Int32) = DispS10(v)

# PURE-9062: Overlay dispatch test types (user-defined struct methods)
struct DispOverlay1 x::Int32 end
struct DispOverlay2 x::Int32 end
@noinline disp_val(s::DispOverlay1)::Int32 = s.x + Int32(100)  # User overlay
@noinline disp_val(s::DispOverlay2)::Int32 = s.x + Int32(200)  # User overlay
@noinline make_disp_overlay1(v::Int32) = DispOverlay1(v)
@noinline make_disp_overlay2(v::Int32) = DispOverlay2(v)

# PURE-9063: Type hierarchy test types
struct TypeHierS1 x::Int32 end
struct TypeHierS2 x::Int32 end
@noinline typeof_check_s1(s::TypeHierS1)::Int32 = typeof(s) === TypeHierS1 ? Int32(1) : Int32(0)
@noinline typeof_check_s2(s::TypeHierS2)::Int32 = typeof(s) === TypeHierS2 ? Int32(1) : Int32(0)
@noinline typeof_cross_check(s::TypeHierS1)::Int32 = typeof(s) === TypeHierS2 ? Int32(1) : Int32(0)
@noinline make_th_s1(v::Int32) = TypeHierS1(v)
@noinline make_th_s2(v::Int32) = TypeHierS2(v)

# D-002: compile_value dispatch — field access on narrowed IR types
@noinline function cv_field_dispatch(val::Any)::Int64
    if val isa Core.SSAValue
        return Int64(val.id)
    elseif val isa Core.Argument
        return Int64(val.n)
    elseif val isa Core.GotoNode
        return Int64(val.label)
    end
    return Int64(-1)
end

# D-002: type-tag dispatch — 7 IR node types
@noinline function cv_type_tag(val::Any)::Int32
    if val isa Core.SSAValue
        return Int32(1)
    elseif val isa Core.Argument
        return Int32(2)
    elseif val isa Core.GotoNode
        return Int32(3)
    elseif val isa Core.ReturnNode
        return Int32(4)
    elseif val isa Core.GotoIfNot
        return Int32(5)
    elseif val isa Expr
        return Int32(6)
    elseif val isa Core.PhiNode
        return Int32(7)
    end
    return Int32(0)
end

# D-002: Wrapper functions for runtime testing
function test_cv_ssa_field()::Int64
    return cv_field_dispatch(Core.SSAValue(42))
end
function test_cv_arg_field()::Int64
    return cv_field_dispatch(Core.Argument(7))
end
function test_cv_goto_field()::Int64
    return cv_field_dispatch(Core.GotoNode(99))
end
function test_cv_unknown_field()::Int64
    return cv_field_dispatch(Core.ReturnNode(nothing))
end
function test_cv_tag_ssa()::Int32
    return cv_type_tag(Core.SSAValue(1))
end
function test_cv_tag_arg()::Int32
    return cv_type_tag(Core.Argument(1))
end
function test_cv_tag_goto()::Int32
    return cv_type_tag(Core.GotoNode(1))
end
function test_cv_tag_return()::Int32
    return cv_type_tag(Core.ReturnNode(nothing))
end
function test_cv_combined_tags()::Int32
    t1 = cv_type_tag(Core.SSAValue(1))
    t2 = cv_type_tag(Core.Argument(2))
    t3 = cv_type_tag(Core.GotoNode(3))
    t4 = cv_type_tag(Core.ReturnNode(nothing))
    return t1 + t2 + t3 + t4
end

# D-003: compile_statement dispatch — ReturnNode + Expr(:call/:invoke/:new) + head comparison
const CS_CALL_EXPR = Expr(:call)
const CS_INVOKE_EXPR = Expr(:invoke)
const CS_NEW_EXPR = Expr(:new)
const CS_OTHER_EXPR = Expr(:boundscheck)

@noinline function cs_dispatch(stmt::Any)::Int32
    if stmt isa Core.ReturnNode
        return Int32(1)
    elseif stmt isa Expr
        head = stmt.head
        if head === :call
            return Int32(10)
        elseif head === :invoke
            return Int32(11)
        elseif head === :new
            return Int32(12)
        else
            return Int32(19)
        end
    elseif stmt isa Core.GotoNode
        return Int32(2)
    elseif stmt isa Core.GotoIfNot
        return Int32(3)
    end
    return Int32(0)
end

function test_cs_return()::Int32
    return cs_dispatch(Core.ReturnNode(nothing))
end
function test_cs_goto()::Int32
    return cs_dispatch(Core.GotoNode(5))
end
function test_cs_gotoifnot()::Int32
    return cs_dispatch(Core.GotoIfNot(true, 10))
end
function test_cs_call_expr()::Int32
    return cs_dispatch(CS_CALL_EXPR)
end
function test_cs_invoke_expr()::Int32
    return cs_dispatch(CS_INVOKE_EXPR)
end
function test_cs_new_expr()::Int32
    return cs_dispatch(CS_NEW_EXPR)
end
function test_cs_other_expr()::Int32
    return cs_dispatch(CS_OTHER_EXPR)
end
function test_cs_combined()::Int32
    r1 = cs_dispatch(Core.ReturnNode(nothing))
    r2 = cs_dispatch(CS_CALL_EXPR)
    r3 = cs_dispatch(Core.GotoNode(5))
    r4 = cs_dispatch(Core.GotoIfNot(true, 10))
    return r1 + r2 + r3 + r4
end

# D-004: Intrinsic name dispatch — symbol comparison for opcode selection
@noinline function intrinsic_tag(name::Symbol)::Int32
    if name === :add_int
        return Int32(1)
    elseif name === :sub_int
        return Int32(2)
    elseif name === :mul_int
        return Int32(3)
    elseif name === :slt_int
        return Int32(4)
    elseif name === :eq_int
        return Int32(5)
    elseif name === :neg_int
        return Int32(6)
    end
    return Int32(0)
end

function test_intr_add()::Int32
    return intrinsic_tag(:add_int)
end
function test_intr_mul()::Int32
    return intrinsic_tag(:mul_int)
end
function test_intr_sub()::Int32
    return intrinsic_tag(:sub_int)
end
function test_intr_slt()::Int32
    return intrinsic_tag(:slt_int)
end
function test_intr_unknown()::Int32
    return intrinsic_tag(:unknown_op)
end

# D-004: Real arithmetic intrinsics (add_int, mul_int, sub_int opcodes)
function test_combined_intrinsic(a::Int64, b::Int64)::Int64
    return (a + b) * (a - b)
end

# D-005: SSA local allocation — multi-use values need local.set/local.get
function test_ssa_multi_use(x::Int64)::Int64
    temp = x * x
    return temp + temp
end
function test_ssa_chain(a::Int64, b::Int64)::Int64
    s = a + b
    d = a - b
    return s * s + d * d
end
function test_ssa_nested(x::Int64)::Int64
    a = x + Int64(1)
    b = a * Int64(2)
    c = b + a
    return c
end

# D-006: Control flow — if/else, loops, phi nodes, nested branches
function test_cf_if_else(x::Int64)::Int64
    if x > Int64(0)
        return x * Int64(2)
    else
        return x * Int64(-1)
    end
end
function test_cf_loop(n::Int64)::Int64
    sum = Int64(0)
    i = Int64(1)
    while i <= n
        sum = sum + i
        i = i + Int64(1)
    end
    return sum
end
function test_cf_phi(x::Int64)::Int64
    result = if x > Int64(10)
        x + Int64(100)
    else
        x + Int64(1)
    end
    return result
end
function test_cf_nested(a::Int64, b::Int64)::Int64
    if a > Int64(0)
        if b > Int64(0)
            return a + b
        else
            return a - b
        end
    else
        return Int64(0)
    end
end

# D-007: WASM module assembly — multi-function, multi-type, cross-call
@noinline function d007_helper(x::Int64)::Int64
    return x * Int64(2)
end
function d007_square_double(x::Int64)::Int64
    sq = x * x
    return d007_helper(sq)
end
function d007_sum_loop(n::Int64)::Int64
    sum = Int64(0)
    i = Int64(1)
    while i <= n
        sum = sum + d007_helper(i)
        i = i + Int64(1)
    end
    return sum
end
function d007_i32_add(a::Int32, b::Int32)::Int32
    return a + b
end
function d007_f64_mul(a::Float64, b::Float64)::Float64
    return a * b
end

# Phase 63 helpers: Real Base function wrappers (module-level to avoid closure issues)
# These call REAL Base functions — NOT reimplementations.
# They use compare_julia_wasm_vec for Vector marshalling via the bridge.

# Predicates for filter/any/all/count (must be module-level for compile_multi)
@inline _p63_iseven(x::Int64)::Bool = x % Int64(2) == Int64(0)
@inline _p63_ispositive(x::Int64)::Bool = x > Int64(0)
@inline _p63_double(x::Int64)::Int64 = x * Int64(2)
@inline _p63_square(x::Int64)::Int64 = x * x
@inline _p63_iseven_f64(x::Float64)::Bool = Float64(Int64(x)) == x && Int64(x) % Int64(2) == Int64(0)
@inline _p63_double_f64(x::Float64)::Float64 = x * 2.0

# Real Base function wrappers
_p63_map_double(v::Vector{Int64})::Vector{Int64} = map(_p63_double, v)
_p63_map_square(v::Vector{Int64})::Vector{Int64} = map(_p63_square, v)
_p63_map_double_f64(v::Vector{Float64})::Vector{Float64} = map(_p63_double_f64, v)
_p63_any_positive(v::Vector{Int64})::Int32 = Int32(any(_p63_ispositive, v))
_p63_all_positive(v::Vector{Int64})::Int32 = Int32(all(_p63_ispositive, v))
_p63_count_even(v::Vector{Int64})::Int64 = Int64(count(_p63_iseven, v))
_p63_sum_i64(v::Vector{Int64})::Int64 = sum(v)
_p63_sum_f64(v::Vector{Float64})::Float64 = sum(v)
_p63_prod_i64(v::Vector{Int64})::Int64 = prod(v)
_p63_reduce_plus(v::Vector{Int64})::Int64 = reduce(+, v)
# WASMTARGET-FUZZ: reduce/foldl with min/max reducer (overlay; closed 742d/f1ba).
# Native lowering kept a `mapreduce_impl` block that emitted invalid wasm, so any
# reduce/foldl trapped (lax mode returned the MAX for a min reduction).
_p63_reduce_min_i64(v::Vector{Int64})::Int64 = reduce(min, v)
_p63_reduce_max_i64(v::Vector{Int64})::Int64 = reduce(max, v)
_p63_foldl_min_i64(v::Vector{Int64})::Int64 = foldl(min, v)
_p63_foldl_max_i64(v::Vector{Int64})::Int64 = foldl(max, v)
_p63_reduce_min_f64(v::Vector{Float64})::Float64 = reduce(min, v)
_p63_foldl_max_f64(v::Vector{Float64})::Float64 = foldl(max, v)
_p63_minimum_i64(v::Vector{Int64})::Int64 = minimum(v)
_p63_maximum_i64(v::Vector{Int64})::Int64 = maximum(v)
_p63_minimum_f64(v::Vector{Float64})::Float64 = minimum(v)
_p63_maximum_f64(v::Vector{Float64})::Float64 = maximum(v)
_p63_reverse_i64(v::Vector{Int64})::Vector{Int64} = reverse(v)
_p63_reverse_f64(v::Vector{Float64})::Vector{Float64} = reverse(v)
_p63_identity_i64(v::Vector{Int64})::Vector{Int64} = v
_p63_identity_f64(v::Vector{Float64})::Vector{Float64} = v
_p63_sort_i64(v::Vector{Int64})::Vector{Int64} = sort(v)
_p63_sort_f64(v::Vector{Float64})::Vector{Float64} = sort(v)
_p63_filter_even(v::Vector{Int64})::Vector{Int64} = filter(_p63_iseven, v)
_p63_filter_positive(v::Vector{Int64})::Vector{Int64} = filter(_p63_ispositive, v)

# Phase 64 helpers: Dict{Int64,Int64} and Set{Int64} — WBUILD-5200/5201/5202
# These call REAL Base Dict/Set operations — NOT reimplementations.
function _p64_dict_insert_get(key::Int64, val::Int64)::Int64
    d = Dict{Int64,Int64}()
    d[key] = val
    return d[key]
end
function _p64_dict_multi(a::Int64, b::Int64, c::Int64)::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = a; d[Int64(2)] = b; d[Int64(3)] = c
    return d[Int64(1)] + d[Int64(2)] + d[Int64(3)]
end
function _p64_dict_haskey_exists(k::Int64)::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(100); d[Int64(2)] = Int64(200)
    return haskey(d, k) ? Int64(1) : Int64(0)
end
function _p64_dict_overwrite(k::Int64, v1::Int64, v2::Int64)::Int64
    d = Dict{Int64,Int64}()
    d[k] = v1; d[k] = v2
    return d[k]
end
function _p64_dict_length(n::Int64)::Int64
    d = Dict{Int64,Int64}()
    for i in Int64(1):n
        d[i] = i * Int64(2)
    end
    return Int64(length(d))
end
function _p64_dict_get_default(k::Int64)::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(42)
    return get(d, k, Int64(-1))
end
function _p64_dict_delete(k::Int64)::Int64
    d = Dict{Int64,Int64}()
    d[Int64(1)] = Int64(10); d[Int64(2)] = Int64(20); d[Int64(3)] = Int64(30)
    delete!(d, Int64(2))
    return Int64(length(d))
end
function _p64_dict_large(n::Int64)::Int64
    d = Dict{Int64,Int64}()
    for i in Int64(1):n
        d[i] = i * i
    end
    return d[Int64(1)] + d[n] + Int64(length(d))
end
function _p64_dict_negative_keys()::Int64
    d = Dict{Int64,Int64}()
    d[Int64(-1)] = Int64(10); d[Int64(-100)] = Int64(20); d[Int64(0)] = Int64(30)
    return d[Int64(-1)] + d[Int64(-100)] + d[Int64(0)]
end
function _p64_dict_stress(n::Int64)::Int64
    d = Dict{Int64,Int64}()
    for i in Int64(1):n
        d[i] = i * Int64(3)
    end
    total = Int64(0)
    for i in Int64(1):n
        total += d[i]
    end
    return total
end
function _p64_set_length(a::Int64, b::Int64, c::Int64)::Int64
    s = Set{Int64}()
    push!(s, a); push!(s, b); push!(s, c); push!(s, a)
    return Int64(length(s))
end
function _p64_set_in(k::Int64)::Int64
    s = Set{Int64}()
    push!(s, Int64(10)); push!(s, Int64(20)); push!(s, Int64(30))
    return k in s ? Int64(1) : Int64(0)
end

# Phase 65 helpers: Vector splatting (_apply_iterate) — WBUILD-5301
# These functions use real splatting syntax (v...) which produces Core._apply_iterate in IR
function _p65_splat_sum_i64(v::Vector{Int64})::Int64
    return +(v...)
end
function _p65_splat_prod_i64(v::Vector{Int64})::Int64
    return *(v...)
end
function _p65_splat_sum_f64(v::Vector{Float64})::Float64
    return +(v...)
end
function _p65_splat_prod_f64(v::Vector{Float64})::Float64
    return *(v...)
end
function _p65_prefix_splat_sum(v::Vector{Int64})::Int64
    return sum(Int64[7, v...])
end

# Each `@pphase` below defines + registers a top-level phase function (lazy compile).
# They run inside the `@testset "WasmTarget.jl"` block at the end of the file via
# `_run_phases()`, which executes only this process's shard.
begin

    # ========================================================================
    # Phase 1: Infrastructure Tests - Verify the test harness works
    # ========================================================================
    @pphase "Phase 1: Test Harness Infrastructure" begin

        @testset "L-strict: THE FULL-STRICT BUILDER — forever (the lock)" begin
            # Dale's bar: valid-by-construction in FULL. EVERY violation throws on a
            # DEFAULT builder: underflow, TYPE MISMATCH, frame error. Zero opt-outs.
            # This lock makes any regression — the silent unwiring, a staged carve-out,
            # a new opt-out — impossible to land.
            WT = WasmTarget
            lb = WT.InstrBuilder(WT.WasmValType[], WT.WasmValType[]; func_name="lock")
            @test !hasfield(WT.InstrBuilder, :strict) # strictness is not configurable
            @test_throws WT.StackImbalanceError WT.num!(lb, WT.Opcode.I64_ADD)  # UNDERFLOW throws
            lb2 = WT.InstrBuilder(WT.WasmValType[], WT.WasmValType[]; func_name="lock2")
            WT.i64_const!(lb2, 1)
            @test_throws WT.StackImbalanceError WT.num!(lb2, WT.Opcode.I32_EQZ)  # TYPE MISMATCH throws
            # ZERO opt-outs in the tree (no netting, no exceptions):
            cgdir = joinpath(dirname(pathof(WasmTarget)), "..")
            n_optout = 0
            for (root, _, files) in walkdir(joinpath(cgdir, "src"))
                for f in files
                    endswith(f, ".jl") || continue
                    n_optout += count(l -> occursin(r"InstrBuilder\([^)]*strict\s*=\s*false", l),
                                      readlines(joinpath(root, f)))
                end
            end
            @test n_optout == 0   # ZERO opt-outs, forever
        end

        @testset "InstrBuilder (typed wasm builder, dart2wasm-style)" begin
            WT = WasmTarget
            # function-end balance: x*x+1 leaves exactly the one f64 result
            b = WT.InstrBuilder(WT.WasmValType[WT.F64], WT.WasmValType[WT.F64]; func_name="sq1")
            WT.local_get!(b, 0); WT.local_get!(b, 0); WT.num!(b, WT.Opcode.F64_MUL)
            WT.f64_const!(b, 1.0); WT.num!(b, WT.Opcode.F64_ADD)
            @test WT.stack_height(b.v) == 1
            WT.end_block!(b)                       # balanced → no throw
            @test length(WT.builder_code(b)) > 0
            # strict imbalance throws at the emit site
            b2 = WT.InstrBuilder(; func_name="bad")
            @test_throws WT.StackImbalanceError WT.num!(b2, WT.Opcode.I32_ADD)
            # GC type-directed effect: struct.new consumes its N fields, pushes (ref t)
            b3 = WT.InstrBuilder(; func_name="sn")
            WT.i32_const!(b3, 0); WT.i64_const!(b3, 7)
            WT.struct_new!(b3, 2, WT.WasmValType[WT.I32, WT.I64])
            @test WT.stack_height(b3.v) == 1 && !WT.has_errors(b3.v)
            # dart2wasm base-guard: cannot pop past a block boundary
            b4 = WT.InstrBuilder(; func_name="bg")
            WT.block!(b4)
            @test_throws WT.StackImbalanceError WT.drop!(b4)
            # rich diagnostics carry the Julia-statement context
            b5 = WT.InstrBuilder(; func_name="diag")
            WT.set_context!(b5, "stmt-X")
            err = try; WT.drop!(b5); nothing; catch e; e; end
            @test err isa WT.StackImbalanceError && occursin("stmt-X", sprint(showerror, err))
            # blocktype encoding: value-type/void immediates are SINGLE on-wire bytes
            # (regression guard — block!/if_!/loop! must NOT LEB-encode 0x40/0x7F)
            bbt = WT.InstrBuilder(; func_name="bt"); WT.block!(bbt); WT.end_block!(bbt)
            @test WT.builder_code(bbt) == UInt8[WT.Opcode.BLOCK, 0x40, WT.Opcode.END]
            bbi = WT.InstrBuilder(; func_name="bti"); WT.i32_const!(bbi, 1)
            WT.if_!(bbi, 0x7F; results=WT.WasmValType[WT.I32]); WT.i32_const!(bbi, 0); WT.end_block!(bbi)
            @test WT.builder_code(bbi) == UInt8[WT.Opcode.I32_CONST, 0x01, WT.Opcode.IF, 0x7F, WT.Opcode.I32_CONST, 0x00, WT.Opcode.END]
            # instruction-IR ADT (dart2wasm ir/ layer): records typed instrs + symbolic disasm
            @test all(i -> i isa WT.InstrIR.WasmInstr, bbi.instrs)
            @test WT.builder_disasm(bbi) == ["i32.const 1", "if 127", "i32.const 0", "end"]
        end

        @testset "InstrBuilder migration invariant (no raw-emission regression)" begin
            # All codegen function-body emission is migrated onto the typed InstrBuilder.
            # The residual raw push!(bytes, Opcode.*) sites are out-of-scope module-section
            # module-section serialization and encode_block_type + intentional
            # byte-inspecting/byte-exact local buffers. Lock the invariant so new code can't
            # silently re-introduce blind raw emission — it must go through the builder.
            cgdir = joinpath(dirname(pathof(WasmTarget)), "codegen")
            countraw(p) = count(l -> occursin(r"push!\([a-z_]+, Opcode\.", l) ||
                                     occursin(r"append!\([a-z_]+, encode_leb128", l), readlines(p))
            total = sum(countraw(joinpath(cgdir, f)) for f in readdir(cgdir) if endswith(f, ".jl"))
            # Baseline residual is ~50 (all out-of-scope). Ceiling catches any real regression;
            # LOWER it as the residual is cleaned (it must only trend down).
            # march16: +4 in closures.jl — the vtable-global INIT bytes (constant-expression
            # serialization, the same out-of-scope class as types.jl's _const_init_bytes!).
            @test total <= 65
            # the three fully-migrated mega-dispatchers must STAY fully migrated:
            for f in ("calls.jl", "invoke.jl", "statements.jl", "int128.jl")
                @test countraw(joinpath(cgdir, f)) == 0
            end
        end

        @testset "LEB128 Encoding" begin
            # Test unsigned LEB128
            @test WasmTarget.encode_leb128_unsigned(0) == [0x00]
            @test WasmTarget.encode_leb128_unsigned(1) == [0x01]
            @test WasmTarget.encode_leb128_unsigned(127) == [0x7F]
            @test WasmTarget.encode_leb128_unsigned(128) == [0x80, 0x01]
            @test WasmTarget.encode_leb128_unsigned(255) == [0xFF, 0x01]
            @test WasmTarget.encode_leb128_unsigned(624485) == [0xE5, 0x8E, 0x26]

            # Test signed LEB128
            @test WasmTarget.encode_leb128_signed(0) == [0x00]
            @test WasmTarget.encode_leb128_signed(1) == [0x01]
            @test WasmTarget.encode_leb128_signed(-1) == [0x7F]
            @test WasmTarget.encode_leb128_signed(63) == [0x3F]
            @test WasmTarget.encode_leb128_signed(-64) == [0x40]
            @test WasmTarget.encode_leb128_signed(64) == [0xC0, 0x00]
            @test WasmTarget.encode_leb128_signed(-65) == [0xBF, 0x7F]
        end

        @testset "Hardcoded Wasm Binary - i32.add" begin
            # Hand-assembled Wasm binary that exports an i32.add function
            # This tests that our Node.js harness can execute Wasm
            #
            # WAT equivalent:
            # (module
            #   (func (export "add") (param i32 i32) (result i32)
            #     local.get 0
            #     local.get 1
            #     i32.add))

            hardcoded_wasm = UInt8[
                # Magic number and version
                0x00, 0x61, 0x73, 0x6D,  # \0asm
                0x01, 0x00, 0x00, 0x00,  # version 1

                # Type section (section id 1)
                0x01,                    # section id
                0x07,                    # section size (7 bytes)
                0x01,                    # num types
                0x60,                    # func type
                0x02,                    # num params
                0x7F, 0x7F,              # i32, i32
                0x01,                    # num results
                0x7F,                    # i32

                # Function section (section id 3)
                0x03,                    # section id
                0x02,                    # section size
                0x01,                    # num functions
                0x00,                    # type index 0

                # Export section (section id 7)
                0x07,                    # section id
                0x07,                    # section size
                0x01,                    # num exports
                0x03,                    # name length
                0x61, 0x64, 0x64,        # "add"
                0x00,                    # export kind (function)
                0x00,                    # function index

                # Code section (section id 10)
                0x0A,                    # section id
                0x09,                    # section size
                0x01,                    # num functions
                0x07,                    # function body size
                0x00,                    # num locals
                0x20, 0x00,              # local.get 0
                0x20, 0x01,              # local.get 1
                0x6A,                    # i32.add
                0x0B,                    # end
            ]

            # Test that the harness can execute this binary
            if NODE_CMD !== nothing
                result = run_wasm(hardcoded_wasm, "add", Int32(2), Int32(3))
                @test result == 5

                result = run_wasm(hardcoded_wasm, "add", Int32(100), Int32(-50))
                @test result == 50
            else
                @warn "Skipping Wasm execution tests (Node.js not available)"
            end
        end

        @testset "Hardcoded Wasm Binary - i64.add" begin
            # Hand-assembled Wasm binary for i64 addition
            # WAT: (func (export "add64") (param i64 i64) (result i64) ...)

            hardcoded_wasm_i64 = UInt8[
                # Magic and version
                0x00, 0x61, 0x73, 0x6D,
                0x01, 0x00, 0x00, 0x00,

                # Type section
                0x01,
                0x07,
                0x01,
                0x60,
                0x02,
                0x7E, 0x7E,              # i64, i64
                0x01,
                0x7E,                    # i64

                # Function section
                0x03,
                0x02,
                0x01,
                0x00,

                # Export section
                0x07,
                0x09,                    # section size
                0x01,
                0x05,                    # name length
                0x61, 0x64, 0x64, 0x36, 0x34,  # "add64"
                0x00,
                0x00,

                # Code section
                0x0A,
                0x09,
                0x01,
                0x07,
                0x00,
                0x20, 0x00,
                0x20, 0x01,
                0x7C,                    # i64.add
                0x0B,
            ]

            if NODE_CMD !== nothing
                result = run_wasm(hardcoded_wasm_i64, "add64", Int64(10), Int64(20))
                @test result == 30

                # Test with large numbers that would overflow JS Number
                large_a = Int64(9007199254740993)  # 2^53 + 1
                large_b = Int64(1)
                result = run_wasm(hardcoded_wasm_i64, "add64", large_a, large_b)
                @test result == large_a + large_b
            else
                @warn "Skipping Wasm execution tests (Node.js not available)"
            end
        end
    end

    # ========================================================================
    # Phase 2: Wasm Builder Tests
    # ========================================================================
    @pphase "Phase 2: Wasm Builder" begin

        @testset "WasmModule - i32.add generation" begin
            mod = WasmTarget.WasmModule()

            # Create a function: (param i32 i32) (result i32) -> local.get 0, local.get 1, i32.add
            body = UInt8[
                WasmTarget.Opcode.LOCAL_GET, 0x00,
                WasmTarget.Opcode.LOCAL_GET, 0x01,
                WasmTarget.Opcode.I32_ADD,
                WasmTarget.Opcode.END,
            ]

            func_idx = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32, WasmTarget.I32],
                [WasmTarget.I32],
                WasmTarget.NumType[],
                body
            )

            WasmTarget.add_export!(mod, "add", 0, func_idx)

            wasm_bytes = WasmTarget.to_bytes(mod)

            # Verify we can execute it
            if NODE_CMD !== nothing
                result = run_wasm(wasm_bytes, "add", Int32(7), Int32(8))
                @test result == 15
            end
        end

        @testset "WasmModule - i64.add generation" begin
            mod = WasmTarget.WasmModule()

            body = UInt8[
                WasmTarget.Opcode.LOCAL_GET, 0x00,
                WasmTarget.Opcode.LOCAL_GET, 0x01,
                WasmTarget.Opcode.I64_ADD,
                WasmTarget.Opcode.END,
            ]

            func_idx = WasmTarget.add_function!(
                mod,
                [WasmTarget.I64, WasmTarget.I64],
                [WasmTarget.I64],
                WasmTarget.NumType[],
                body
            )

            WasmTarget.add_export!(mod, "add64", 0, func_idx)

            wasm_bytes = WasmTarget.to_bytes(mod)

            if NODE_CMD !== nothing
                result = run_wasm(wasm_bytes, "add64", Int64(100), Int64(200))
                @test result == 300
            end
        end

        @testset "WasmModule - Multiple functions" begin
            mod = WasmTarget.WasmModule()

            # Add function
            add_body = UInt8[
                WasmTarget.Opcode.LOCAL_GET, 0x00,
                WasmTarget.Opcode.LOCAL_GET, 0x01,
                WasmTarget.Opcode.I32_ADD,
                WasmTarget.Opcode.END,
            ]
            add_idx = WasmTarget.add_function!(
                mod, [WasmTarget.I32, WasmTarget.I32], [WasmTarget.I32],
                WasmTarget.NumType[], add_body
            )

            # Subtract function
            sub_body = UInt8[
                WasmTarget.Opcode.LOCAL_GET, 0x00,
                WasmTarget.Opcode.LOCAL_GET, 0x01,
                WasmTarget.Opcode.I32_SUB,
                WasmTarget.Opcode.END,
            ]
            sub_idx = WasmTarget.add_function!(
                mod, [WasmTarget.I32, WasmTarget.I32], [WasmTarget.I32],
                WasmTarget.NumType[], sub_body
            )

            WasmTarget.add_export!(mod, "add", 0, add_idx)
            WasmTarget.add_export!(mod, "sub", 0, sub_idx)

            wasm_bytes = WasmTarget.to_bytes(mod)

            if NODE_CMD !== nothing
                @test run_wasm(wasm_bytes, "add", Int32(10), Int32(5)) == 15
                @test run_wasm(wasm_bytes, "sub", Int32(10), Int32(5)) == 5
            end
        end
    end

    # ========================================================================
    # Phase 3: Compiler Tests - Julia IR to Wasm
    # ========================================================================
    @pphase "Phase 3: Julia Compiler" begin

        @testset "Simple Int64 addition" begin
            # Define a simple function
            simple_add(a, b) = a + b

            if NODE_CMD !== nothing
                # Compile and run
                wasm_bytes = WasmTarget.compile(simple_add, (Int64, Int64))

                # Debug: dump the bytes
                # dump_wasm(wasm_bytes, "/tmp/simple_add.wasm")

                result = run_wasm(wasm_bytes, "simple_add", Int64(5), Int64(7))
                @test result == 12
            end
        end

        @testset "TDD Macro - @test_compile" begin
            my_add(x, y) = x + y

            if NODE_CMD !== nothing
                @test_compile my_add(Int64(10), Int64(20))
                @test_compile my_add(Int64(-5), Int64(5))
                @test_compile my_add(Int64(0), Int64(0))
            end
        end

    end

    # ========================================================================
    # Phase 4: Control Flow and Comparisons
    # ========================================================================
    @pphase "Phase 4: Control Flow" begin

        @testset "Comparisons - returning Bool as i32" begin
            is_positive(x) = x > 0
            is_negative(x) = x < 0
            is_zero(x) = x == 0
            is_not_zero(x) = x != 0
            is_lte(x, y) = x <= y
            is_gte(x, y) = x >= y

            if NODE_CMD !== nothing
                # Test is_positive
                @test_compile is_positive(Int64(5))
                @test_compile is_positive(Int64(-5))
                @test_compile is_positive(Int64(0))

                # Test is_negative
                @test_compile is_negative(Int64(5))
                @test_compile is_negative(Int64(-5))

                # Test is_zero
                @test_compile is_zero(Int64(0))
                @test_compile is_zero(Int64(1))

                # Test is_not_zero
                @test_compile is_not_zero(Int64(0))
                @test_compile is_not_zero(Int64(42))

                # Test is_lte and is_gte
                @test_compile is_lte(Int64(3), Int64(5))
                @test_compile is_lte(Int64(5), Int64(5))
                @test_compile is_lte(Int64(7), Int64(5))
                @test_compile is_gte(Int64(7), Int64(5))
                @test_compile is_gte(Int64(5), Int64(5))
            end
        end

        @testset "Simple conditional - ternary" begin
            # x < 0 ? -x : x  (absolute value)
            my_abs(x) = x < 0 ? -x : x

            if NODE_CMD !== nothing
                @test_compile my_abs(Int64(5))
                @test_compile my_abs(Int64(-5))
                @test_compile my_abs(Int64(0))
            end
        end

        @testset "Max/Min functions" begin
            my_max(a, b) = a > b ? a : b
            my_min(a, b) = a < b ? a : b

            if NODE_CMD !== nothing
                @test_compile my_max(Int64(10), Int64(20))
                @test_compile my_max(Int64(20), Int64(10))
                @test_compile my_max(Int64(5), Int64(5))

                @test_compile my_min(Int64(10), Int64(20))
                @test_compile my_min(Int64(20), Int64(10))
            end
        end

        @testset "If-else blocks" begin
            function multi_branch_ifelse(x::Int64)::Int64
                if x > Int64(10)
                    return Int64(3)
                elseif x > Int64(5)
                    return Int64(2)
                elseif x > Int64(0)
                    return Int64(1)
                else
                    return Int64(0)
                end
            end
            @test compare_julia_wasm(multi_branch_ifelse, Int64(15)).pass
            @test compare_julia_wasm(multi_branch_ifelse, Int64(7)).pass
            @test compare_julia_wasm(multi_branch_ifelse, Int64(3)).pass
            @test compare_julia_wasm(multi_branch_ifelse, Int64(-1)).pass
        end

        @testset "Nested conditionals" begin
            function nested_cond_test(x::Int64, y::Int64)::Int64
                if x > Int64(0)
                    if y > Int64(0)
                        return Int64(1)
                    else
                        return Int64(2)
                    end
                else
                    if y > Int64(0)
                        return Int64(3)
                    else
                        return Int64(4)
                    end
                end
            end
            @test compare_julia_wasm(nested_cond_test, Int64(1), Int64(1)).pass
            @test compare_julia_wasm(nested_cond_test, Int64(1), Int64(-1)).pass
            @test compare_julia_wasm(nested_cond_test, Int64(-1), Int64(1)).pass
            @test compare_julia_wasm(nested_cond_test, Int64(-1), Int64(-1)).pass
        end

    end

    # ========================================================================
    # Phase 5: More Integer Operations
    # ========================================================================
    @pphase "Phase 5: Integer Operations" begin

        @testset "Subtraction and Multiplication" begin
            my_sub(a, b) = a - b
            my_mul(a, b) = a * b

            if NODE_CMD !== nothing
                @test_compile my_sub(Int64(10), Int64(3))
                @test_compile my_sub(Int64(3), Int64(10))
                @test_compile my_mul(Int64(6), Int64(7))
                @test_compile my_mul(Int64(-3), Int64(4))
            end
        end

        @testset "Division and Remainder" begin
            my_div(a, b) = a ÷ b  # Integer division
            my_rem(a, b) = a % b  # Remainder

            if NODE_CMD !== nothing
                @test_compile my_div(Int64(10), Int64(3))
                @test_compile my_div(Int64(20), Int64(4))
                @test_compile my_rem(Int64(10), Int64(3))
                @test_compile my_rem(Int64(20), Int64(4))
            end
        end

        @testset "Negation" begin
            my_neg(x) = -x

            if NODE_CMD !== nothing
                @test_compile my_neg(Int64(5))
                @test_compile my_neg(Int64(-5))
                @test_compile my_neg(Int64(0))
            end
        end

        @testset "Bitwise operations" begin
            my_and(a, b) = a & b
            my_or(a, b) = a | b
            my_xor(a, b) = a ⊻ b
            my_not(x) = ~x

            if NODE_CMD !== nothing
                @test_compile my_and(Int64(0b1100), Int64(0b1010))
                @test_compile my_or(Int64(0b1100), Int64(0b1010))
                @test_compile my_xor(Int64(0b1100), Int64(0b1010))
                @test_compile my_not(Int64(0))
            end
        end

        @testset "Shift operations" begin
            function shl_test(x::Int64, n::Int64)::Int64
                return x << n
            end
            function shr_test(x::Int64, n::Int64)::Int64
                return x >> n
            end
            function ushr_test(x::Int64, n::Int64)::Int64
                return x >>> n
            end
            @test compare_julia_wasm(shl_test, Int64(1), Int64(4)).pass
            @test compare_julia_wasm(shl_test, Int64(255), Int64(2)).pass
            @test compare_julia_wasm(shr_test, Int64(16), Int64(2)).pass
            @test compare_julia_wasm(shr_test, Int64(-8), Int64(1)).pass
            @test compare_julia_wasm(ushr_test, Int64(-1), Int64(1)).pass
        end

    end

    # ========================================================================
    # Phase 6: Type Conversions
    # ========================================================================
    @pphase "Phase 6: Type Conversions" begin

        @testset "Int32 to Int64" begin
            widen32(x::Int32) = Int64(x)

            if NODE_CMD !== nothing
                @test_compile widen32(Int32(42))
                @test_compile widen32(Int32(-42))
                @test_compile widen32(Int32(0))
            end
        end

        @testset "Int64 to Int32 (truncate)" begin
            narrow64(x::Int64) = Int32(x % Int32)

            if NODE_CMD !== nothing
                @test_compile narrow64(Int64(42))
                @test_compile narrow64(Int64(-42))
            end
        end

        @testset "Int to Float" begin
            int_to_f64(x::Int64) = Float64(x)
            int_to_f32(x::Int32) = Float32(x)

            if NODE_CMD !== nothing
                @test_compile int_to_f64(Int64(42))
                @test_compile int_to_f64(Int64(-42))
                @test_compile int_to_f32(Int32(42))
            end
        end

        @testset "Float arithmetic" begin
            add_f64(a::Float64, b::Float64) = a + b
            mul_f64(a::Float64, b::Float64) = a * b
            sub_f64(a::Float64, b::Float64) = a - b
            div_f64(a::Float64, b::Float64) = a / b

            if NODE_CMD !== nothing
                @test_compile add_f64(1.5, 2.5)
                @test_compile mul_f64(3.0, 4.0)
                @test_compile sub_f64(10.0, 3.0)
                @test_compile div_f64(10.0, 4.0)
            end
        end

    end

    # ========================================================================
    # Phase 7: WasmGC Structs
    # ========================================================================
    @pphase "Phase 7: WasmGC Structs" begin

        @testset "Builder: Struct type creation" begin

            # Create a module with a struct type
            mod = WasmModule()

            # Add a struct type with two i32 fields
            fields = [FieldType(I32, true), FieldType(I32, true)]
            type_idx = add_struct_type!(mod, fields)

            @test type_idx == 0

            # Verify it can be serialized without error
            bytes = to_bytes(mod)
            @test length(bytes) > 8  # At least magic + version

            # Check magic number
            @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6D]
        end

        @testset "Builder: Struct with mixed fields" begin

            mod = WasmModule()

            # Struct with i32, i64, f64 fields
            fields = [FieldType(I32, true), FieldType(I64, false), FieldType(F64, true)]
            type_idx = add_struct_type!(mod, fields)

            @test type_idx == 0

            bytes = to_bytes(mod)
            @test length(bytes) > 8
        end

        @testset "Builder: Struct type deduplication" begin

            mod = WasmModule()

            # Add same struct type twice
            fields = [FieldType(I32, true)]
            type_idx1 = add_struct_type!(mod, fields)
            type_idx2 = add_struct_type!(mod, fields)

            @test type_idx1 == type_idx2  # Should be deduplicated
        end

        @testset "Hand-crafted: Struct creation and field access" begin
            if NODE_CMD !== nothing

                # Create a module that:
                # 1. Defines a struct type { i32, i32 }
                # 2. Has a function that creates a struct and reads field 0

                mod = WasmModule()

                # Add struct type: { field0: i32, field1: i32 }
                struct_type_idx = add_struct_type!(mod, [FieldType(I32, true), FieldType(I32, true)])

                # Function: () -> i32
                # Creates struct with values (42, 99), returns field 0
                body = UInt8[]

                # Push field values for struct.new (i32.const uses signed LEB128!)
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(42))  # field 0 value
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(99))  # field 1 value

                # struct.new $type
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_NEW)
                append!(body, encode_leb128_unsigned(struct_type_idx))

                # struct.get $type $field
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_GET)
                append!(body, encode_leb128_unsigned(struct_type_idx))
                append!(body, encode_leb128_unsigned(0))  # field index

                # End function
                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[], NumType[I32], NumType[], body)
                add_export!(mod, "get_field0", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                result = run_wasm(wasm_bytes, "get_field0")

                @test result == 42
            end
        end

        @testset "Hand-crafted: Struct field 1 access" begin
            if NODE_CMD !== nothing

                mod = WasmModule()
                struct_type_idx = add_struct_type!(mod, [FieldType(I32, true), FieldType(I32, true)])

                body = UInt8[]

                # Create struct with (42, 99) - use signed LEB128 for i32.const
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(42))
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(99))

                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_NEW)
                append!(body, encode_leb128_unsigned(struct_type_idx))

                # Get field 1
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_GET)
                append!(body, encode_leb128_unsigned(struct_type_idx))
                append!(body, encode_leb128_unsigned(1))  # field 1

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[], NumType[I32], NumType[], body)
                add_export!(mod, "get_field1", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                result = run_wasm(wasm_bytes, "get_field1")

                @test result == 99
            end
        end

        @testset "Hand-crafted: Struct with parameters" begin
            if NODE_CMD !== nothing

                # Function: (a: i32, b: i32) -> i32
                # Creates struct(a, b), returns field y (b)
                mod = WasmModule()
                struct_type_idx = add_struct_type!(mod, [FieldType(I32, true), FieldType(I32, true)])

                body = UInt8[]

                # Push function args for struct
                push!(body, Opcode.LOCAL_GET)
                push!(body, 0x00)  # arg a
                push!(body, Opcode.LOCAL_GET)
                push!(body, 0x01)  # arg b

                # struct.new
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_NEW)
                append!(body, encode_leb128_unsigned(struct_type_idx))

                # struct.get field 1 (y)
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_GET)
                append!(body, encode_leb128_unsigned(struct_type_idx))
                append!(body, encode_leb128_unsigned(1))

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[I32, I32], NumType[I32], NumType[], body)
                add_export!(mod, "create_and_get_y", 0, func_idx)

                wasm_bytes = to_bytes(mod)

                @test run_wasm(wasm_bytes, "create_and_get_y", Int32(10), Int32(20)) == 20
                @test run_wasm(wasm_bytes, "create_and_get_y", Int32(100), Int32(200)) == 200
            end
        end

    end

    # ========================================================================
    # Phase 8: Tuples
    # ========================================================================
    @pphase "Phase 8: Tuples" begin

        @testset "Hand-crafted: Tuple creation and access" begin
            if NODE_CMD !== nothing

                # Function: (a: i32, b: i32) -> i32
                # Creates tuple (a, b), returns first element
                mod = WasmModule()

                # Tuple is represented as struct { field0: i32, field1: i32 }
                tuple_type_idx = add_struct_type!(mod, [FieldType(I32, false), FieldType(I32, false)])

                body = UInt8[]

                # Push tuple elements
                push!(body, Opcode.LOCAL_GET)
                push!(body, 0x00)
                push!(body, Opcode.LOCAL_GET)
                push!(body, 0x01)

                # struct.new
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_NEW)
                append!(body, encode_leb128_unsigned(tuple_type_idx))

                # Get element 0
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_GET)
                append!(body, encode_leb128_unsigned(tuple_type_idx))
                append!(body, encode_leb128_unsigned(0))

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[I32, I32], NumType[I32], NumType[], body)
                add_export!(mod, "tuple_first", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                @test run_wasm(wasm_bytes, "tuple_first", Int32(10), Int32(20)) == 10
            end
        end

        @testset "Hand-crafted: Tuple second element" begin
            if NODE_CMD !== nothing

                mod = WasmModule()
                tuple_type_idx = add_struct_type!(mod, [FieldType(I32, false), FieldType(I32, false)])

                body = UInt8[]

                push!(body, Opcode.LOCAL_GET)
                push!(body, 0x00)
                push!(body, Opcode.LOCAL_GET)
                push!(body, 0x01)
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_NEW)
                append!(body, encode_leb128_unsigned(tuple_type_idx))

                # Get element 1 (second)
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_GET)
                append!(body, encode_leb128_unsigned(tuple_type_idx))
                append!(body, encode_leb128_unsigned(1))

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[I32, I32], NumType[I32], NumType[], body)
                add_export!(mod, "tuple_second", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                @test run_wasm(wasm_bytes, "tuple_second", Int32(10), Int32(20)) == 20
            end
        end

        @testset "Hand-crafted: 3-element tuple" begin
            if NODE_CMD !== nothing

                mod = WasmModule()
                # Tuple{Int32, Int32, Int32}
                tuple_type_idx = add_struct_type!(mod, [
                    FieldType(I32, false),
                    FieldType(I32, false),
                    FieldType(I32, false)
                ])

                body = UInt8[]

                # Create tuple (10, 20, 30), return third element
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(10))
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(20))
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(30))

                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_NEW)
                append!(body, encode_leb128_unsigned(tuple_type_idx))

                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_GET)
                append!(body, encode_leb128_unsigned(tuple_type_idx))
                append!(body, encode_leb128_unsigned(2))  # third element

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[], NumType[I32], NumType[], body)
                add_export!(mod, "tuple_third", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                @test run_wasm(wasm_bytes, "tuple_third") == 30
            end
        end

    end

    # ========================================================================
    # Phase 9: WasmGC Arrays
    # ========================================================================
    @pphase "Phase 9: WasmGC Arrays" begin

        @testset "Builder: Array type creation" begin

            mod = WasmModule()
            arr_type_idx = add_array_type!(mod, I32, true)

            @test arr_type_idx == 0
            bytes = to_bytes(mod)
            @test length(bytes) > 8
            @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6D]
        end

        @testset "Hand-crafted: Array length" begin
            if NODE_CMD !== nothing

                # Function: () -> i32
                # Creates array of length 5, returns the length
                mod = WasmModule()
                arr_type_idx = add_array_type!(mod, I32, true)

                body = UInt8[]

                # Create array with init value 0 and length 5
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(0))
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(5))

                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.ARRAY_NEW)
                append!(body, encode_leb128_unsigned(arr_type_idx))

                # Get array length
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.ARRAY_LEN)

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[], NumType[I32], NumType[], body)
                add_export!(mod, "arr_len", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                @test run_wasm(wasm_bytes, "arr_len") == 5
            end
        end

        @testset "Hand-crafted: Array get element" begin
            if NODE_CMD !== nothing

                # Create array with init value 42, get element at index 0
                mod = WasmModule()
                arr_type_idx = add_array_type!(mod, I32, true)

                body = UInt8[]

                # Create array with init value 42 and length 3
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(42))  # all elements will be 42
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(3))

                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.ARRAY_NEW)
                append!(body, encode_leb128_unsigned(arr_type_idx))

                # Get element at index 1
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(1))
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.ARRAY_GET)
                append!(body, encode_leb128_unsigned(arr_type_idx))

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[], NumType[I32], NumType[], body)
                add_export!(mod, "arr_get", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                @test run_wasm(wasm_bytes, "arr_get") == 42
            end
        end

        @testset "Hand-crafted: Array new_fixed" begin
            if NODE_CMD !== nothing

                # Create array with fixed elements [10, 20, 30], get middle element
                mod = WasmModule()
                arr_type_idx = add_array_type!(mod, I32, true)

                body = UInt8[]

                # Push elements for array.new_fixed
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(10))
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(20))
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(30))

                # array.new_fixed $type $count
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.ARRAY_NEW_FIXED)
                append!(body, encode_leb128_unsigned(arr_type_idx))
                append!(body, encode_leb128_unsigned(3))  # count

                # Get element at index 1 (should be 20)
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(1))
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.ARRAY_GET)
                append!(body, encode_leb128_unsigned(arr_type_idx))

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[], NumType[I32], NumType[], body)
                add_export!(mod, "arr_fixed_get", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                @test run_wasm(wasm_bytes, "arr_fixed_get") == 20
            end
        end

    end

    # ========================================================================
    # Phase 10: JavaScript Imports
    # ========================================================================
    @pphase "Phase 10: JavaScript Imports" begin

        @testset "Builder: Add import function" begin

            mod = WasmModule()
            # Import a function: env.log_i32(i32) -> void
            import_idx = add_import!(mod, "env", "log_i32", NumType[I32], NumType[])
            @test import_idx == 0

            # Add a local function that calls the import
            body = UInt8[
                0x20, 0x00,  # local.get 0
                0x10, 0x00,  # call 0 (the imported function)
                0x0B         # end
            ]
            func_idx = add_function!(mod, NumType[I32], NumType[], NumType[], body)
            # func_idx should be 1 (after the imported function)
            @test func_idx == 1

            add_export!(mod, "test", 0, func_idx)

            bytes = to_bytes(mod)
            @test length(bytes) > 8
            @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6D]
        end

        @testset "Execute: Import and call JavaScript function" begin
            if NODE_CMD !== nothing

                mod = WasmModule()

                # Import: env.double(i32) -> i32
                import_idx = add_import!(mod, "env", "double_it", NumType[I32], NumType[I32])

                # Local function: (param i32) -> i32
                # Calls the imported double_it function
                body = UInt8[]
                push!(body, Opcode.LOCAL_GET)
                append!(body, encode_leb128_unsigned(0))
                push!(body, Opcode.CALL)
                append!(body, encode_leb128_unsigned(0))  # call import at index 0
                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[I32], NumType[I32], NumType[], body)
                add_export!(mod, "call_double", 0, func_idx)

                wasm_bytes = to_bytes(mod)

                # Run with imports
                result = run_wasm_with_imports(wasm_bytes, "call_double",
                    Dict("env" => Dict("double_it" => "(x) => x * 2")),
                    Int32(21))
                @test result == 42
            end
        end

    end

    @pphase "Phase 11: Loops" begin

        @testset "Simple while loop - sum 1 to n" begin
            @noinline function simple_sum(n::Int32)::Int32
                total::Int32 = Int32(0)
                i::Int32 = Int32(1)
                @inbounds while i <= n
                    total = total + i
                    i = i + Int32(1)
                end
                return total
            end

            wasm_bytes = WasmTarget.compile(simple_sum, (Int32,))
            @test length(wasm_bytes) > 0

            # Test execution
            @test run_wasm(wasm_bytes, "simple_sum", Int32(5)) == 15
            @test run_wasm(wasm_bytes, "simple_sum", Int32(10)) == 55
            @test run_wasm(wasm_bytes, "simple_sum", Int32(100)) == 5050
        end

        @testset "Factorial loop" begin
            @noinline function factorial_loop(n::Int32)::Int32
                result::Int32 = Int32(1)
                i::Int32 = Int32(1)
                @inbounds while i <= n
                    result = result * i
                    i = i + Int32(1)
                end
                return result
            end

            wasm_bytes = WasmTarget.compile(factorial_loop, (Int32,))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "factorial_loop", Int32(1)) == 1
            @test run_wasm(wasm_bytes, "factorial_loop", Int32(5)) == 120
            @test run_wasm(wasm_bytes, "factorial_loop", Int32(6)) == 720
        end

        @testset "Count down loop" begin
            @noinline function count_down(n::Int32)::Int32
                total::Int32 = Int32(0)
                i::Int32 = n
                @inbounds while i > Int32(0)
                    total = total + i
                    i = i - Int32(1)
                end
                return total
            end

            wasm_bytes = WasmTarget.compile(count_down, (Int32,))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "count_down", Int32(5)) == 15
            @test run_wasm(wasm_bytes, "count_down", Int32(10)) == 55
        end

    end

    # Note: Recursive functions must be defined at module level (not inside @testset)
    # to avoid closure capture which is not yet supported in the Wasm compiler

    @pphase "Phase 12: Recursion" begin

        @testset "Recursive factorial" begin
            wasm_bytes = WasmTarget.compile(test_factorial_rec, (Int32,))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "test_factorial_rec", Int32(1)) == 1
            @test run_wasm(wasm_bytes, "test_factorial_rec", Int32(5)) == 120
            @test run_wasm(wasm_bytes, "test_factorial_rec", Int32(6)) == 720
            @test run_wasm(wasm_bytes, "test_factorial_rec", Int32(10)) == 3628800
        end

        @testset "Recursive fibonacci" begin
            wasm_bytes = WasmTarget.compile(test_fib, (Int32,))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "test_fib", Int32(0)) == 0
            @test run_wasm(wasm_bytes, "test_fib", Int32(1)) == 1
            @test run_wasm(wasm_bytes, "test_fib", Int32(5)) == 5
            @test run_wasm(wasm_bytes, "test_fib", Int32(10)) == 55
        end

        @testset "Recursive sum" begin
            wasm_bytes = WasmTarget.compile(test_sum_rec, (Int32,))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "test_sum_rec", Int32(0)) == 0
            @test run_wasm(wasm_bytes, "test_sum_rec", Int32(5)) == 15
            @test run_wasm(wasm_bytes, "test_sum_rec", Int32(100)) == 5050
        end

    end

    # ========================================================================
    # Phase 13: Compiled Struct Field Access
    # ========================================================================
    @pphase "Phase 13: Compiled Struct Access" begin

        @testset "Struct creation and field sum" begin
            wasm_bytes = WasmTarget.compile(test_point_sum, (Int32, Int32))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "test_point_sum", Int32(10), Int32(20)) == 30
            @test run_wasm(wasm_bytes, "test_point_sum", Int32(100), Int32(200)) == 300
            @test run_wasm(wasm_bytes, "test_point_sum", Int32(-5), Int32(15)) == 10
        end

        @testset "Struct creation and field difference" begin
            wasm_bytes = WasmTarget.compile(test_point_diff, (Int32, Int32))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "test_point_diff", Int32(30), Int32(10)) == 20
            @test run_wasm(wasm_bytes, "test_point_diff", Int32(100), Int32(50)) == 50
            @test run_wasm(wasm_bytes, "test_point_diff", Int32(5), Int32(10)) == -5
        end

    end

    # ========================================================================
    # Phase 14: Float Operations and Branching
    # ========================================================================
    @pphase "Phase 14: Float Operations" begin

        @testset "Float addition" begin
            wasm_bytes = WasmTarget.compile(test_float_add, (Float64, Float64))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "test_float_add", 1.5, 2.5) ≈ 4.0
            @test run_wasm(wasm_bytes, "test_float_add", -1.0, 1.0) ≈ 0.0
            @test run_wasm(wasm_bytes, "test_float_add", 100.5, 200.5) ≈ 301.0
        end

        @testset "Float multiplication" begin
            wasm_bytes = WasmTarget.compile(test_float_mul, (Float64, Float64))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "test_float_mul", 2.0, 3.0) ≈ 6.0
            @test run_wasm(wasm_bytes, "test_float_mul", -2.0, 4.0) ≈ -8.0
            @test run_wasm(wasm_bytes, "test_float_mul", 0.5, 0.5) ≈ 0.25
        end

        @testset "Integer branching" begin
            wasm_bytes = WasmTarget.compile(test_branch, (Int32, Int32))
            @test length(wasm_bytes) > 0

            # sum = 110 > 100, so return 110 - 50 = 60
            @test run_wasm(wasm_bytes, "test_branch", Int32(60), Int32(50)) == 60
            # sum = 50 <= 100, so return 50 * 2 = 100
            @test run_wasm(wasm_bytes, "test_branch", Int32(30), Int32(20)) == 100
            # sum = 101 > 100, so return 101 - 50 = 51
            @test run_wasm(wasm_bytes, "test_branch", Int32(100), Int32(1)) == 51
        end

    end

    # ========================================================================
    # Phase 15: Strings
    # ========================================================================
    @pphase "Phase 15: Strings" begin

        # String sizeof - returns byte length of string
        @noinline function str_sizeof(s::String)::Int64
            return sizeof(s)
        end

        @testset "String sizeof compilation" begin
            wasm_bytes = WasmTarget.compile(str_sizeof, (String,))
            @test length(wasm_bytes) > 0

            # Validate the module
            @test validate_wasm(wasm_bytes)
        end

        # String length - returns character count
        @noinline function str_length(s::String)::Int64
            return length(s)
        end

        @testset "String length compilation" begin
            wasm_bytes = WasmTarget.compile(str_length, (String,))
            @test length(wasm_bytes) > 0

            # Validate the module
            @test validate_wasm(wasm_bytes)
        end

        # String literal - returns a constant string
        @noinline function str_literal()::String
            return "hello"
        end

        @testset "String literal compilation" begin
            wasm_bytes = WasmTarget.compile(str_literal, ())
            @test length(wasm_bytes) > 0

            # Validate the module
            @test validate_wasm(wasm_bytes)
        end

        # String concatenation
        @noinline function str_concat(a::String, b::String)::String
            return a * b
        end

        @noinline function str_identity_contract()::Int32
            a = "identity-a"
            b = "identity-b"
            sa = :identity_a
            sb = :identity_b
            return objectid(a) == objectid(a) && objectid(a) != objectid(b) &&
                   objectid(sa) == objectid(sa) && objectid(sa) != objectid(sb) ? Int32(1) : Int32(0)
        end

        @testset "String concatenation" begin
            wasm_bytes = WasmTarget.compile(str_concat, (String, String))
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
        end

        @testset "String object identity" begin
            result = compare_julia_wasm(str_identity_contract)
            @test result.pass
            @test result.actual == 1
        end

        # Regression: a string literal's array.new_data LENGTH operand is an
        # i32.const, which must be SIGNED LEB128. It was unsigned-encoded, so a
        # literal length in [64,127] (1-byte unsigned-LEB with bit-6 set, e.g. 90)
        # decoded NEGATIVE → array.new_data with a huge unsigned length →
        # "requested new array is too large" trap at runtime (VALIDATION PASSED).
        # Medium-length literals (admonition HTML in Snapshot.jl feedback cells)
        # hit it; short literals (<64) coincidentally encoded fine, hiding it.
        @noinline function str_mid_literal(x::Int64)::Int64
            # 90-char literal (in the broken [64,127] band) built at runtime via
            # the concat, then measured — forces the array.new_data emission.
            return Int64(ncodeunits("abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij" * string(x)))
        end

        @testset "String literal length — i32.const signed-LEB" begin
            wasm_bytes = WasmTarget.compile(str_mid_literal, (Int64,))
            @test validate_wasm(wasm_bytes)
            if NODE_CMD !== nothing
                for xv in (Int64(5), Int64(42), Int64(123456))
                    @test run_wasm(wasm_bytes, "str_mid_literal", xv) == str_mid_literal(xv)
                end
            end
        end

        # String equality
        @noinline function str_equal(a::String, b::String)::Bool
            return a == b
        end

        @testset "String equality" begin
            wasm_bytes = WasmTarget.compile(str_equal, (String, String))
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
        end

        # String hashing for dict keys
        @testset "String hash" begin
            function test_str_hash()::Int32
                return str_hash("hello")
            end

            wasm_bytes = WasmTarget.compile(test_str_hash, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            # Verify hash matches Julia's fallback
            @test run_wasm(wasm_bytes, "test_str_hash") == str_hash("hello")
        end

        @testset "String hash consistency" begin
            function test_hash_diff()::Int32
                h1 = str_hash("hello")
                h2 = str_hash("world")
                if h1 == h2
                    return Int32(0)
                else
                    return Int32(1)
                end
            end

            wasm_bytes = WasmTarget.compile(test_hash_diff, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_hash_diff") == 1  # Different strings have different hashes
        end

        # ======================================================================
        # BROWSER-010: New String Operations
        # ======================================================================

        @testset "str_find - basic search" begin
            function test_str_find_basic()::Int32
                return str_find("hello world", "world")
            end

            wasm_bytes = WasmTarget.compile(test_str_find_basic, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_find_basic") == 7  # "world" starts at position 7
        end

        @testset "str_find - not found" begin
            function test_str_find_notfound()::Int32
                return str_find("hello world", "xyz")
            end

            wasm_bytes = WasmTarget.compile(test_str_find_notfound, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_find_notfound") == 0  # Not found returns 0
        end

        @testset "str_contains - found" begin
            function test_str_contains_found()::Int32
                if str_contains("hello world", "world")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            wasm_bytes = WasmTarget.compile(test_str_contains_found, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_contains_found") == 1
        end

        @testset "str_contains - not found" begin
            function test_str_contains_notfound()::Int32
                if str_contains("hello world", "xyz")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            wasm_bytes = WasmTarget.compile(test_str_contains_notfound, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_contains_notfound") == 0
        end

        @testset "str_startswith - true case" begin
            function test_str_startswith_true()::Int32
                if str_startswith("hello world", "hello")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            wasm_bytes = WasmTarget.compile(test_str_startswith_true, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_startswith_true") == 1
        end

        @testset "str_startswith - false case" begin
            function test_str_startswith_false()::Int32
                if str_startswith("hello world", "world")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            wasm_bytes = WasmTarget.compile(test_str_startswith_false, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_startswith_false") == 0
        end

        @testset "str_endswith - true case" begin
            function test_str_endswith_true()::Int32
                if str_endswith("hello world", "world")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            wasm_bytes = WasmTarget.compile(test_str_endswith_true, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_endswith_true") == 1
        end

        @testset "str_endswith - false case" begin
            function test_str_endswith_false()::Int32
                if str_endswith("hello world", "hello")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            wasm_bytes = WasmTarget.compile(test_str_endswith_false, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_endswith_false") == 0
        end

        # ========================================================================
        # BROWSER-010: str_uppercase, str_lowercase, str_trim
        # ========================================================================

        @testset "str_uppercase - basic" begin
            function test_str_uppercase()::Int32
                result = str_uppercase("hello")
                # Check first char is 'H' (72)
                return str_char(result, Int32(1))
            end

            wasm_bytes = WasmTarget.compile(test_str_uppercase, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_uppercase") == 72  # 'H'
        end

        @testset "str_uppercase - mixed case" begin
            function test_str_uppercase_mixed()::Int32
                result = str_uppercase("HeLLo WoRLD")
                # Check length is preserved
                len = str_len(result)
                # Check some characters
                first = str_char(result, Int32(1))  # 'H' = 72
                fifth = str_char(result, Int32(5))  # 'O' = 79
                space = str_char(result, Int32(6))  # ' ' = 32
                last = str_char(result, Int32(11)) # 'D' = 68
                # Return sum as verification
                return first + fifth + space + last
            end

            wasm_bytes = WasmTarget.compile(test_str_uppercase_mixed, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_uppercase_mixed") == 72 + 79 + 32 + 68  # 251
        end

        @testset "str_lowercase - basic" begin
            function test_str_lowercase()::Int32
                result = str_lowercase("HELLO")
                # Check first char is 'h' (104)
                return str_char(result, Int32(1))
            end

            wasm_bytes = WasmTarget.compile(test_str_lowercase, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_lowercase") == 104  # 'h'
        end

        @testset "str_lowercase - mixed case" begin
            function test_str_lowercase_mixed()::Int32
                result = str_lowercase("HeLLo WoRLD")
                # Check length is preserved
                len = str_len(result)
                # Check some characters
                first = str_char(result, Int32(1))  # 'h' = 104
                fifth = str_char(result, Int32(5))  # 'o' = 111
                space = str_char(result, Int32(6))  # ' ' = 32
                last = str_char(result, Int32(11)) # 'd' = 100
                # Return sum as verification
                return first + fifth + space + last
            end

            wasm_bytes = WasmTarget.compile(test_str_lowercase_mixed, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_lowercase_mixed") == 104 + 111 + 32 + 100  # 347
        end

        @testset "str_trim - leading and trailing spaces" begin
            function test_str_trim_both()::Int32
                result = str_trim("  hello  ")
                # Length should be 5
                return str_len(result)
            end

            wasm_bytes = WasmTarget.compile(test_str_trim_both, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_trim_both") == 5
        end

        @testset "str_trim - content preserved" begin
            function test_str_trim_content()::Int32
                result = str_trim("  hello  ")
                # First char should be 'h' (104)
                return str_char(result, Int32(1))
            end

            wasm_bytes = WasmTarget.compile(test_str_trim_content, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_trim_content") == 104  # 'h'
        end

        @testset "str_trim - no whitespace" begin
            function test_str_trim_no_ws()::Int32
                result = str_trim("hello")
                # Length should remain 5
                return str_len(result)
            end

            wasm_bytes = WasmTarget.compile(test_str_trim_no_ws, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_trim_no_ws") == 5
        end

        @testset "str_trim - all whitespace" begin
            function test_str_trim_all_ws()::Int32
                result = str_trim("   ")
                # Length should be 0
                return str_len(result)
            end

            wasm_bytes = WasmTarget.compile(test_str_trim_all_ws, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_trim_all_ws") == 0
        end

        @testset "str_trim - tabs and newlines" begin
            function test_str_trim_special()::Int32
                # "\thello\n" - tab at start, newline at end
                s = str_new(Int32(7))
                str_setchar!(s, Int32(1), Int32(9))   # tab
                str_setchar!(s, Int32(2), Int32(104)) # h
                str_setchar!(s, Int32(3), Int32(101)) # e
                str_setchar!(s, Int32(4), Int32(108)) # l
                str_setchar!(s, Int32(5), Int32(108)) # l
                str_setchar!(s, Int32(6), Int32(111)) # o
                str_setchar!(s, Int32(7), Int32(10))  # newline
                result = str_trim(s)
                # Length should be 5
                return str_len(result)
            end

            wasm_bytes = WasmTarget.compile(test_str_trim_special, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_trim_special") == 5
        end

        # BROWSER-010: Dedicated tests for str_char and str_substr

        @testset "str_char - get character at index" begin
            function test_str_char_basic()::Int32
                s = "hello"
                return str_char(s, Int32(1))  # 'h' = 104
            end

            wasm_bytes = WasmTarget.compile(test_str_char_basic, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_char_basic") == 104  # 'h'
        end

        @testset "str_char - multiple positions" begin
            function test_str_char_multi()::Int32
                s = "hello"
                # Sum first and last character: 'h'(104) + 'o'(111) = 215
                return str_char(s, Int32(1)) + str_char(s, Int32(5))
            end

            wasm_bytes = WasmTarget.compile(test_str_char_multi, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_char_multi") == 215
        end

        @testset "str_substr - extract substring" begin
            function test_str_substr_basic()::Int32
                s = "hello world"
                sub = str_substr(s, Int32(7), Int32(5))  # "world"
                return str_len(sub)
            end

            wasm_bytes = WasmTarget.compile(test_str_substr_basic, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_substr_basic") == 5
        end

        @testset "str_substr - verify content" begin
            function test_str_substr_content()::Int32
                s = "hello world"
                sub = str_substr(s, Int32(7), Int32(5))  # "world"
                # Return first char of "world" = 'w' = 119
                return str_char(sub, Int32(1))
            end

            wasm_bytes = WasmTarget.compile(test_str_substr_content, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_substr_content") == 119  # 'w'
        end

        @testset "str_char - character comparison for tokenizer" begin
            # This test verifies the pattern used in tokenizer
            function test_char_comparison()::Int32
                s = "hello"
                c = str_char(s, Int32(1))
                # Compare character to ASCII code
                if c == Int32(104)  # 'h'
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            wasm_bytes = WasmTarget.compile(test_char_comparison, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_char_comparison") == 1
        end

        # ========================================================================
        # Julia Base string dispatch → str_* intrinsics
        # ========================================================================

        @testset "Base.startswith dispatch" begin
            function test_base_startswith_true()::Int32
                if startswith("hello world", "hello")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end
            wasm_bytes = WasmTarget.compile(test_base_startswith_true, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_base_startswith_true") == 1
        end

        @testset "Base.startswith dispatch - false" begin
            function test_base_startswith_false()::Int32
                if startswith("hello world", "xyz")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end
            wasm_bytes = WasmTarget.compile(test_base_startswith_false, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_base_startswith_false") == 0
        end

        @testset "Base.endswith dispatch" begin
            function test_base_endswith_true()::Int32
                if endswith("hello world", "world")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end
            wasm_bytes = WasmTarget.compile(test_base_endswith_true, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_base_endswith_true") == 1
        end

        @testset "Base.endswith dispatch - false" begin
            function test_base_endswith_false()::Int32
                if endswith("hello world", "hello")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end
            wasm_bytes = WasmTarget.compile(test_base_endswith_false, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_base_endswith_false") == 0
        end

        @testset "Base.contains dispatch" begin
            function test_base_contains_true()::Int32
                if contains("hello world", "lo wo")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end
            wasm_bytes = WasmTarget.compile(test_base_contains_true, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_base_contains_true") == 1
        end

        @testset "Base.contains dispatch - false" begin
            function test_base_contains_false()::Int32
                if contains("hello", "xyz")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end
            wasm_bytes = WasmTarget.compile(test_base_contains_false, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_base_contains_false") == 0
        end

        @testset "Base.lowercase dispatch" begin
            function test_base_lowercase()::Int32
                result = lowercase("HELLO")
                return str_char(result, Int32(1))
            end
            wasm_bytes = WasmTarget.compile(test_base_lowercase, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_base_lowercase") == 104  # 'h'
        end

        @testset "Base.uppercase dispatch" begin
            function test_base_uppercase()::Int32
                result = uppercase("hello")
                return str_char(result, Int32(1))
            end
            wasm_bytes = WasmTarget.compile(test_base_uppercase, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_base_uppercase") == 72  # 'H'
        end

    end

    # ========================================================================
    # Phase 16: Multi-Function Modules
    # ========================================================================
    @pphase "Phase 16: Multi-Function Modules" begin

        @noinline function multi_add(a::Int32, b::Int32)::Int32
            return a + b
        end

        @noinline function multi_sub(a::Int32, b::Int32)::Int32
            return a - b
        end

        @noinline function multi_mul(a::Int32, b::Int32)::Int32
            return a * b
        end

        @testset "Multiple functions in one module" begin
            wasm_bytes = WasmTarget.compile_multi([
                (multi_add, (Int32, Int32)),
                (multi_sub, (Int32, Int32)),
                (multi_mul, (Int32, Int32)),
            ])
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)

            # Test each function works correctly
            @test run_wasm(wasm_bytes, "multi_add", Int32(5), Int32(3)) == 8
            @test run_wasm(wasm_bytes, "multi_sub", Int32(10), Int32(4)) == 6
            @test run_wasm(wasm_bytes, "multi_mul", Int32(6), Int32(7)) == 42
        end

        @testset "Cross-function calls" begin
            # Uses module-level functions: cross_helper_double, cross_use_helper
            wasm_bytes = WasmTarget.compile_multi([
                (cross_helper_double, (Int32,)),
                (cross_use_helper, (Int32,)),
            ])
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)

            # Test helper directly
            @test run_wasm(wasm_bytes, "cross_helper_double", Int32(5)) == 10

            # Test function that calls another function
            @test run_wasm(wasm_bytes, "cross_use_helper", Int32(5)) == 11   # 5*2 + 1
            @test run_wasm(wasm_bytes, "cross_use_helper", Int32(10)) == 21  # 10*2 + 1
        end

        @testset "Multiple dispatch" begin
            # Same function (dispatch_process) with different type signatures
            wasm_bytes = WasmTarget.compile_multi([
                (dispatch_process, (Int32,), "process_i32"),
                (dispatch_process, (Int64,), "process_i64"),
                (dispatch_use_i32, (Int32,)),
                (dispatch_use_i64, (Int64,)),
            ])
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)

            # Test direct calls to each dispatch variant
            @test run_wasm(wasm_bytes, "process_i32", Int32(5)) == 10   # 5*2
            @test run_wasm(wasm_bytes, "process_i64", Int64(5)) == 15   # 5*3

            # Test calls through dispatching functions
            @test run_wasm(wasm_bytes, "dispatch_use_i32", Int32(5)) == 11  # 5*2 + 1
            @test run_wasm(wasm_bytes, "dispatch_use_i64", Int64(5)) == 16  # 5*3 + 1
        end

        # Result type pattern test

        @noinline function result_try_div(a::Int32, b::Int32)::ResultType
            if b == Int32(0)
                return ResultType(false, Int32(0))
            else
                return ResultType(true, a ÷ b)
            end
        end

        @noinline function result_get_value(r::ResultType)::Int32
            return r.value
        end

        @noinline function result_is_success(r::ResultType)::Bool
            return r.success
        end

        @testset "Result type pattern" begin
            wasm_bytes = WasmTarget.compile_multi([
                (result_try_div, (Int32, Int32)),
                (result_get_value, (ResultType,)),
                (result_is_success, (ResultType,))
            ])
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
        end

    end

    # ========================================================================
    # Phase 17: JS Interop (externref)
    # ========================================================================
    @pphase "Phase 17: JS Interop" begin

        @testset "externref pass-through" begin
            @noinline function jsval_passthrough(x::JSValue)::JSValue
                return x
            end

            wasm_bytes = WasmTarget.compile(jsval_passthrough, (JSValue,))
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
        end

        @testset "Wasm globals" begin
            # Test global variable creation and export
            mod = WasmTarget.WasmModule()

            # Add mutable i32 global
            global_idx = WasmTarget.add_global!(mod, WasmTarget.I32, true, 0)
            @test global_idx == 0

            # Export it
            WasmTarget.add_global_export!(mod, "counter", global_idx)

            # Serialize and validate
            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

    end

    # ========================================================================
    # Phase 18: Tables and Indirect Calls
    # ========================================================================
    @pphase "Phase 18: Tables" begin

        @testset "Basic table creation" begin
            mod = WasmTarget.WasmModule()

            # Add a funcref table with 4 slots
            table_idx = WasmTarget.add_table!(mod, WasmTarget.FuncRef, 4)
            @test table_idx == 0

            # Add some functions to populate the table
            func1_idx = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,  # get param
                    WasmTarget.Opcode.I32_CONST, 0x02,  # push 2
                    WasmTarget.Opcode.I32_MUL,          # multiply
                    WasmTarget.Opcode.END
                ]
            )

            func2_idx = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,  # get param
                    WasmTarget.Opcode.I32_CONST, 0x03,  # push 3
                    WasmTarget.Opcode.I32_MUL,          # multiply
                    WasmTarget.Opcode.END
                ]
            )

            # Export them for testing
            WasmTarget.add_export!(mod, "double", 0, func1_idx)
            WasmTarget.add_export!(mod, "triple", 0, func2_idx)

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)

            # Test the functions work
            @test run_wasm(bytes, "double", Int32(5)) == 10
            @test run_wasm(bytes, "triple", Int32(5)) == 15
        end

        @testset "Table with element segment" begin
            mod = WasmTarget.WasmModule()

            # Add funcref table
            table_idx = WasmTarget.add_table!(mod, WasmTarget.FuncRef, 4)

            # Add two functions with same signature
            func_double = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,
                    WasmTarget.Opcode.I32_CONST, 0x02,
                    WasmTarget.Opcode.I32_MUL,
                    WasmTarget.Opcode.END
                ]
            )

            func_triple = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,
                    WasmTarget.Opcode.I32_CONST, 0x03,
                    WasmTarget.Opcode.I32_MUL,
                    WasmTarget.Opcode.END
                ]
            )

            # Initialize table with element segment
            WasmTarget.add_elem_segment!(mod, 0, 0, [func_double, func_triple])

            # Export table for JS inspection
            WasmTarget.add_table_export!(mod, "funcs", table_idx)

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        @testset "Table with limits" begin
            mod = WasmTarget.WasmModule()

            # Table with both min and max
            table_idx = WasmTarget.add_table!(mod, WasmTarget.FuncRef, 2, 10)
            @test table_idx == 0

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        @testset "externref table" begin
            mod = WasmTarget.WasmModule()

            # Table for holding JS objects
            table_idx = WasmTarget.add_table!(mod, WasmTarget.ExternRef, 8)
            WasmTarget.add_table_export!(mod, "objects", table_idx)

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        @testset "call_indirect" begin
            mod = WasmTarget.WasmModule()

            # Add function type for i32 -> i32
            type_idx = WasmTarget.add_type!(mod, WasmTarget.FuncType(
                [WasmTarget.I32],
                [WasmTarget.I32]
            ))

            # Add funcref table
            table_idx = WasmTarget.add_table!(mod, WasmTarget.FuncRef, 4)

            # Add two functions with the same signature
            func_double = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,
                    WasmTarget.Opcode.I32_CONST, 0x02,
                    WasmTarget.Opcode.I32_MUL,
                    WasmTarget.Opcode.END
                ]
            )

            func_triple = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,
                    WasmTarget.Opcode.I32_CONST, 0x03,
                    WasmTarget.Opcode.I32_MUL,
                    WasmTarget.Opcode.END
                ]
            )

            # Initialize table: [func_double, func_triple]
            WasmTarget.add_elem_segment!(mod, 0, 0, [func_double, func_triple])

            # Add a dispatcher function that takes (value, index) and calls indirectly
            # call_indirect format: call_indirect type_idx table_idx
            dispatcher = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32, WasmTarget.I32],  # value, table_index
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,  # push value
                    WasmTarget.Opcode.LOCAL_GET, 0x01,  # push table index
                    WasmTarget.Opcode.CALL_INDIRECT,
                    type_idx % UInt8,                   # type index
                    0x00,                               # table index
                    WasmTarget.Opcode.END
                ]
            )

            WasmTarget.add_export!(mod, "dispatch", 0, dispatcher)

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)

            # dispatch(5, 0) should call func_double(5) = 10
            @test run_wasm(bytes, "dispatch", Int32(5), Int32(0)) == 10
            # dispatch(5, 1) should call func_triple(5) = 15
            @test run_wasm(bytes, "dispatch", Int32(5), Int32(1)) == 15
        end

        @testset "Linear memory" begin
            mod = WasmTarget.WasmModule()

            # Add memory with 1 page (64KB)
            mem_idx = WasmTarget.add_memory!(mod, 1)
            @test mem_idx == 0

            # Export the memory
            WasmTarget.add_memory_export!(mod, "memory", mem_idx)

            # Add a function that uses memory operations
            func_idx = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32, WasmTarget.I32],  # address, value
                WasmTarget.WasmValType[],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,  # address
                    WasmTarget.Opcode.LOCAL_GET, 0x01,  # value
                    WasmTarget.Opcode.I32_STORE, 0x02, 0x00,  # store (align=4, offset=0)
                    WasmTarget.Opcode.END
                ]
            )
            WasmTarget.add_export!(mod, "store", 0, func_idx)

            # Add a load function
            load_idx = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32],      # address
                [WasmTarget.I32],      # result
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,  # address
                    WasmTarget.Opcode.I32_LOAD, 0x02, 0x00,  # load (align=4, offset=0)
                    WasmTarget.Opcode.END
                ]
            )
            WasmTarget.add_export!(mod, "load", 0, load_idx)

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)

            # Test memory operations via Node.js
            js_code = """
            const bytes = Buffer.from([$(join(bytes, ","))]);
            WebAssembly.instantiate(bytes).then(result => {
                const { store, load, memory } = result.instance.exports;
                store(0, 42);
                console.log(load(0));
            });
            """
            result = read(`node -e $js_code`, String)
            @test strip(result) == "42"
        end

        @testset "Memory with max limit" begin
            mod = WasmTarget.WasmModule()

            # Add memory with min 1 page, max 10 pages
            mem_idx = WasmTarget.add_memory!(mod, 1, 10)
            @test mem_idx == 0

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        @testset "Data segment with string" begin
            mod = WasmTarget.WasmModule()

            # Add memory
            mem_idx = WasmTarget.add_memory!(mod, 1)
            WasmTarget.add_memory_export!(mod, "memory", mem_idx)

            # Initialize memory with "Hello"
            WasmTarget.add_data_segment!(mod, 0, 0, "Hello")

            # Add a function to read the first byte
            func_idx = WasmTarget.add_function!(
                mod,
                WasmTarget.WasmValType[],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.I32_CONST, 0x00,  # address 0
                    WasmTarget.Opcode.I32_LOAD, 0x00, 0x00,  # load (unaligned)
                    WasmTarget.Opcode.END
                ]
            )
            WasmTarget.add_export!(mod, "read_first", 0, func_idx)

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)

            # Test via Node.js - "Hello" as little-endian i32 is 'H' + 'e'<<8 + 'l'<<16 + 'l'<<24
            # = 0x48 + 0x65<<8 + 0x6c<<16 + 0x6c<<24 = 0x6c6c6548
            expected = Int32('H') | (Int32('e') << 8) | (Int32('l') << 16) | (Int32('l') << 24)
            @test run_wasm(bytes, "read_first") == expected
        end

        @testset "Data segment with raw bytes" begin
            mod = WasmTarget.WasmModule()

            mem_idx = WasmTarget.add_memory!(mod, 1)

            # Initialize with raw bytes [1, 2, 3, 4] at offset 16 (multiple of 4 for alignment)
            WasmTarget.add_data_segment!(mod, 0, 16, UInt8[1, 2, 3, 4])

            # Function to load i32 from offset 16
            # Note: i32.const uses signed LEB128, 16 = 0x10 fits in single byte
            func_idx = WasmTarget.add_function!(
                mod,
                WasmTarget.WasmValType[],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.I32_CONST, 0x10,    # 16
                    WasmTarget.Opcode.I32_LOAD, 0x02, 0x00,  # align=4, offset=0
                    WasmTarget.Opcode.END
                ]
            )
            WasmTarget.add_export!(mod, "read_data", 0, func_idx)

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)

            # Little-endian: [1, 2, 3, 4] = 0x04030201
            expected = Int32(1) | (Int32(2) << 8) | (Int32(3) << 16) | (Int32(4) << 24)
            @test run_wasm(bytes, "read_data") == expected
        end

    end

    # ========================================================================
    # Phase 21: Multi-dimensional Arrays (Matrix)
    # ========================================================================
    @pphase "Phase 21: Multi-dimensional Arrays (Matrix)" begin

        @testset "Matrix type compiles" begin
            # Test that functions accepting Matrix compile correctly
            function test_matrix_accept(m::Matrix{Int32})::Int32
                return Int32(1)  # Just accept and return
            end

            bytes = compile(test_matrix_accept, (Matrix{Int32},))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        @testset "Matrix .size field access compiles" begin
            # Test accessing the .size field of a Matrix
            function test_matrix_get_rows(m::Matrix{Int32})::Int64
                return m.size[1]
            end

            function test_matrix_get_cols(m::Matrix{Int32})::Int64
                return m.size[2]
            end

            bytes_rows = compile(test_matrix_get_rows, (Matrix{Int32},))
            @test length(bytes_rows) > 0
            @test validate_wasm(bytes_rows)

            bytes_cols = compile(test_matrix_get_cols, (Matrix{Int32},))
            @test length(bytes_cols) > 0
            @test validate_wasm(bytes_cols)
        end

        @testset "Matrix .ref field access compiles" begin
            # Test accessing the .ref field (underlying MemoryRef)
            function test_matrix_ref(m::Matrix{Int32})::Int64
                ref = m.ref
                return Int64(1)  # Just access ref
            end

            bytes = compile(test_matrix_ref, (Matrix{Int32},))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        @testset "Matrix Float64 compiles" begin
            # Test Matrix with different element types
            function test_matrix_f64_rows(m::Matrix{Float64})::Int64
                return m.size[1]
            end

            bytes = compile(test_matrix_f64_rows, (Matrix{Float64},))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        @testset "Matrix compile_multi" begin
            # Test multiple Matrix functions together
            function mat_rows(m::Matrix{Int32})::Int64
                return m.size[1]
            end

            function mat_cols(m::Matrix{Int32})::Int64
                return m.size[2]
            end

            function mat_total(m::Matrix{Int32})::Int64
                return m.size[1] * m.size[2]
            end

            bytes = compile_multi([
                (mat_rows, (Matrix{Int32},)),
                (mat_cols, (Matrix{Int32},)),
                (mat_total, (Matrix{Int32},)),
            ])
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

    end

    # ========================================================================
    # Phase 22: Math Functions (WASM-native)
    # ========================================================================
    @pphase "Phase 22: Math Functions (WASM-native)" begin

        @testset "sqrt (via llvm intrinsic)" begin
            if NODE_CMD !== nothing
                # Use the raw llvm intrinsic to avoid domain checking
                function test_sqrt_fast(x::Float64)::Float64
                    return Base.Math.sqrt_llvm(x)
                end

                bytes = compile(test_sqrt_fast, (Float64,))
                @test length(bytes) > 0
                @test validate_wasm(bytes)
                @test run_wasm(bytes, "test_sqrt_fast", Float64[4.0]) ≈ 2.0
                @test run_wasm(bytes, "test_sqrt_fast", Float64[9.0]) ≈ 3.0
                @test run_wasm(bytes, "test_sqrt_fast", Float64[2.0]) ≈ sqrt(2.0)
            end
        end

        @testset "abs" begin
            if NODE_CMD !== nothing
                function test_abs(x::Float64)::Float64
                    return abs(x)
                end

                bytes = compile(test_abs, (Float64,))
                @test length(bytes) > 0
                @test validate_wasm(bytes)
                @test run_wasm(bytes, "test_abs", Float64[-5.0]) ≈ 5.0
                @test run_wasm(bytes, "test_abs", Float64[3.0]) ≈ 3.0
                @test run_wasm(bytes, "test_abs", Float64[-0.0]) ≈ 0.0
            end
        end

        @testset "floor" begin
            if NODE_CMD !== nothing
                function test_floor(x::Float64)::Float64
                    return floor(x)
                end

                bytes = compile(test_floor, (Float64,))
                @test length(bytes) > 0
                @test validate_wasm(bytes)
                @test run_wasm(bytes, "test_floor", Float64[3.7]) ≈ 3.0
                @test run_wasm(bytes, "test_floor", Float64[-2.3]) ≈ -3.0
                @test run_wasm(bytes, "test_floor", Float64[5.0]) ≈ 5.0
            end
        end

        @testset "ceil" begin
            if NODE_CMD !== nothing
                function test_ceil(x::Float64)::Float64
                    return ceil(x)
                end

                bytes = compile(test_ceil, (Float64,))
                @test length(bytes) > 0
                @test validate_wasm(bytes)
                @test run_wasm(bytes, "test_ceil", Float64[3.2]) ≈ 4.0
                @test run_wasm(bytes, "test_ceil", Float64[-2.7]) ≈ -2.0
                @test run_wasm(bytes, "test_ceil", Float64[5.0]) ≈ 5.0
            end
        end

        @testset "round" begin
            if NODE_CMD !== nothing
                function test_round(x::Float64)::Float64
                    return round(x)
                end

                bytes = compile(test_round, (Float64,))
                @test length(bytes) > 0
                @test validate_wasm(bytes)
                @test run_wasm(bytes, "test_round", Float64[3.2]) ≈ 3.0
                @test run_wasm(bytes, "test_round", Float64[3.7]) ≈ 4.0
                @test run_wasm(bytes, "test_round", Float64[-2.5]) ≈ -2.0  # Round to even
            end
        end

        @testset "trunc" begin
            if NODE_CMD !== nothing
                function test_trunc(x::Float64)::Float64
                    return trunc(x)
                end

                bytes = compile(test_trunc, (Float64,))
                @test length(bytes) > 0
                @test validate_wasm(bytes)
                @test run_wasm(bytes, "test_trunc", Float64[3.7]) ≈ 3.0
                @test run_wasm(bytes, "test_trunc", Float64[-3.7]) ≈ -3.0
                @test run_wasm(bytes, "test_trunc", Float64[5.0]) ≈ 5.0
            end
        end

        @testset "Float32 variants" begin
            if NODE_CMD !== nothing
                function test_abs_f32(x::Float32)::Float32
                    return abs(x)
                end

                function test_floor_f32(x::Float32)::Float32
                    return floor(x)
                end

                bytes_abs = compile(test_abs_f32, (Float32,))
                @test length(bytes_abs) > 0
                @test validate_wasm(bytes_abs)

                bytes_floor = compile(test_floor_f32, (Float32,))
                @test length(bytes_floor) > 0
                @test validate_wasm(bytes_floor)
            end
        end

    end

    # ========================================================================
    # Phase 23: Void Control Flow Tests
    # Tests for complex control flow in void-returning functions (event handlers)
    # Covers: nested &&/||, sequential ifs, early returns
    # ========================================================================
    @pphase "Phase 23: Void Control Flow" begin

        # Test helper: a mutable struct to track side effects

        # ----------------------------------------------------------------
        # Test 1: Simple nested && operator (a && b && c pattern)
        # ----------------------------------------------------------------
        @testset "Nested && (triple condition)" begin
            @noinline function void_nested_and(state::VoidTestState, a::Int32, b::Int32, c::Int32)::Nothing
                if a > Int32(0) && b > Int32(0) && c > Int32(0)
                    state.value = Int32(1)
                end
                return nothing
            end

            bytes = compile(void_nested_and, (VoidTestState, Int32, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 2: Nested || operator (a || b || c pattern)
        # ----------------------------------------------------------------
        @testset "Nested || (triple condition)" begin
            @noinline function void_nested_or(state::VoidTestState, a::Int32, b::Int32, c::Int32)::Nothing
                if a > Int32(0) || b > Int32(0) || c > Int32(0)
                    state.value = Int32(1)
                end
                return nothing
            end

            bytes = compile(void_nested_or, (VoidTestState, Int32, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 3: Mixed && and || (a && (b || c) pattern)
        # ----------------------------------------------------------------
        @testset "Mixed && and ||" begin
            @noinline function void_mixed_and_or(state::VoidTestState, a::Int32, b::Int32, c::Int32)::Nothing
                if a > Int32(0) && (b > Int32(0) || c > Int32(0))
                    state.value = Int32(1)
                end
                return nothing
            end

            bytes = compile(void_mixed_and_or, (VoidTestState, Int32, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 4: Sequential if blocks
        # ----------------------------------------------------------------
        @testset "Sequential if blocks" begin
            @noinline function void_sequential_ifs(state::VoidTestState, a::Int32, b::Int32)::Nothing
                if a > Int32(0)
                    state.value = state.value + Int32(1)
                end
                if b > Int32(0)
                    state.value = state.value + Int32(10)
                end
                return nothing
            end

            bytes = compile(void_sequential_ifs, (VoidTestState, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 5: Three sequential if blocks
        # ----------------------------------------------------------------
        @testset "Three sequential if blocks" begin
            @noinline function void_three_ifs(state::VoidTestState, a::Int32, b::Int32, c::Int32)::Nothing
                if a > Int32(0)
                    state.value = state.value + Int32(1)
                end
                if b > Int32(0)
                    state.value = state.value + Int32(10)
                end
                if c > Int32(0)
                    state.value = state.value + Int32(100)
                end
                return nothing
            end

            bytes = compile(void_three_ifs, (VoidTestState, Int32, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 6: Early return in void function
        # ----------------------------------------------------------------
        @testset "Early return in void function" begin
            @noinline function void_early_return(state::VoidTestState, cond::Int32)::Nothing
                if cond > Int32(0)
                    return nothing
                end
                state.value = Int32(42)
                return nothing
            end

            bytes = compile(void_early_return, (VoidTestState, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 7: Early return with && condition
        # ----------------------------------------------------------------
        @testset "Early return with && condition" begin
            @noinline function void_early_return_and(state::VoidTestState, a::Int32, b::Int32)::Nothing
                if a > Int32(0) && b > Int32(0)
                    return nothing
                end
                state.value = Int32(99)
                return nothing
            end

            bytes = compile(void_early_return_and, (VoidTestState, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 8: Nested if-else in void function
        # ----------------------------------------------------------------
        @testset "Nested if-else in void function" begin
            @noinline function void_nested_if_else(state::VoidTestState, a::Int32, b::Int32)::Nothing
                if a > Int32(0)
                    if b > Int32(0)
                        state.value = Int32(1)
                    else
                        state.value = Int32(2)
                    end
                else
                    state.value = Int32(3)
                end
                return nothing
            end

            bytes = compile(void_nested_if_else, (VoidTestState, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 9: Quadruple && chain (winner checking pattern)
        # ----------------------------------------------------------------
        @testset "Quadruple && chain" begin
            @noinline function void_quad_and(state::VoidTestState, a::Int32, b::Int32, c::Int32, d::Int32)::Nothing
                if a == Int32(1) && b == Int32(1) && c == Int32(1) && d == Int32(1)
                    state.value = Int32(100)
                end
                return nothing
            end

            bytes = compile(void_quad_and, (VoidTestState, Int32, Int32, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 10: Complex TicTacToe-like winner checking pattern
        # ----------------------------------------------------------------
        @testset "TicTacToe winner pattern" begin
            @noinline function void_check_winner(state::VoidTestState, r1::Int32, r2::Int32, r3::Int32)::Nothing
                # Check if all three are equal and non-zero (like checking a row)
                if r1 != Int32(0) && r1 == r2 && r2 == r3
                    state.value = r1  # Winner found
                end
                return nothing
            end

            bytes = compile(void_check_winner, (VoidTestState, Int32, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 11: Multiple early returns
        # ----------------------------------------------------------------
        @testset "Multiple early returns" begin
            @noinline function void_multiple_returns(state::VoidTestState, code::Int32)::Nothing
                if code == Int32(1)
                    state.value = Int32(10)
                    return nothing
                end
                if code == Int32(2)
                    state.value = Int32(20)
                    return nothing
                end
                if code == Int32(3)
                    state.value = Int32(30)
                    return nothing
                end
                state.value = Int32(0)
                return nothing
            end

            bytes = compile(void_multiple_returns, (VoidTestState, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 12: If-else chain (switch-like pattern)
        # ----------------------------------------------------------------
        @testset "If-else chain" begin
            @noinline function void_if_else_chain(state::VoidTestState, x::Int32)::Nothing
                if x < Int32(0)
                    state.value = Int32(-1)
                elseif x == Int32(0)
                    state.value = Int32(0)
                elseif x < Int32(10)
                    state.value = Int32(1)
                else
                    state.value = Int32(2)
                end
                return nothing
            end

            bytes = compile(void_if_else_chain, (VoidTestState, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 13: Conditional with loop inside
        # ----------------------------------------------------------------
        @testset "Conditional with loop inside" begin
            @noinline function void_cond_with_loop(state::VoidTestState, n::Int32)::Nothing
                if n > Int32(0)
                    i = Int32(0)
                    while i < n
                        state.value = state.value + Int32(1)
                        i = i + Int32(1)
                    end
                end
                return nothing
            end

            bytes = compile(void_cond_with_loop, (VoidTestState, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 14: Pure void function (no side effects, just control flow)
        # ----------------------------------------------------------------
        @testset "Pure void with complex control flow" begin
            @noinline function void_pure_complex(a::Int32, b::Int32, c::Int32)::Nothing
                if a > Int32(0) && b > Int32(0)
                    if c > Int32(0)
                        # Do nothing
                    end
                elseif a > Int32(0) || b > Int32(0)
                    # Do nothing
                end
                return nothing
            end

            bytes = compile(void_pure_complex, (Int32, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

    end

    # ========================================================================
    # Phase 23: Union Types / Tagged Unions
    # ========================================================================
    @pphase "Phase 23: Union Types" begin

        # Test 1: UnionInfo and TypeRegistry structures
        @testset "Union type registration" begin
            # Create a module and registry
            mod = WasmTarget.WasmModule()
            registry = WasmTarget.TypeRegistry()

            # M3 (dart2wasm parity): the {typeId,tag,value} tagged-union WRAPPER family is
            # DELETED outright (needs_tagged_union / emit_wrap_union_value / emit_unwrap_union_value
            # no longer exist — ratchet lock L5 enforces they never return). A Union value is JUST
            # a boxed AnyRef discriminated by classId; a heterogeneous union maps to AnyRef.
            @test !isdefined(WasmTarget, :needs_tagged_union)
            @test !isdefined(WasmTarget, :emit_wrap_union_value)
            @test !isdefined(WasmTarget, :emit_unwrap_union_value)
            @test WasmTarget.get_concrete_wasm_type(Union{Int32, String}, mod, registry) === WasmTarget.AnyRef

            # Test get_nullable_inner_type function
            @test WasmTarget.get_nullable_inner_type(Union{Nothing, Int32}) === Int32
            @test WasmTarget.get_nullable_inner_type(Union{Nothing, String}) === String
            @test WasmTarget.get_nullable_inner_type(Union{Int32, String}) === nothing

            # B4/U2 — dart2wasm parity: register_union_type! / UnionInfo / get_union_tag and the
            # whole {typeId,tag,value} tagged-union wrapper scheme are DELETED. A Union value is a
            # boxed AnyRef discriminated by classId; differential coverage of union compile+run is
            # in the "Union parameter type" / het-tuple / distinguishability / boxed-=== testsets.
        end

        # Test 2: Function parameter with union type
        @testset "Union parameter type" begin
            @noinline function process_union_value(x::Union{Int32, Float64})::Int32
                # This just returns a constant - we're testing type registration
                return Int32(1)
            end

            wasm_bytes = WasmTarget.compile(process_union_value, (Union{Int32, Float64},))
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
        end

        # Test 3: Triple union with Nothing as parameter
        @testset "Triple union parameter type" begin
            @noinline function triple_union_param(x::Union{Nothing, Int32, String})::Int32
                return Int32(0)
            end

            wasm_bytes = WasmTarget.compile(triple_union_param, (Union{Nothing, Int32, String},))
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
        end

        # Test 4: Julia-side concrete type resolution
        @testset "Concrete type resolution for unions" begin
            mod = WasmTarget.WasmModule()
            registry = WasmTarget.TypeRegistry()

            # Test that julia_to_wasm_type correctly handles union types
            union_type = Union{Int32, String}
            wasm_type = WasmTarget.julia_to_wasm_type(union_type)
            # Multi-variant unions should return a reference type (StructRef for now)
            @test wasm_type isa WasmTarget.RefType || wasm_type isa WasmTarget.NumType
        end

        # Test 5: Interpreter Value pattern - explicit tagged struct
        # This is the recommended pattern for runtime dynamic values

        @testset "Interpreter value pattern" begin
            @noinline function make_int_value(x::Int64)::InterpValue
                return Base.inferencebarrier(InterpValue(Int32(1), x, Float64(0.0), Int32(0)))::InterpValue
            end

            @noinline function make_float_value(x::Float64)::InterpValue
                return Base.inferencebarrier(InterpValue(Int32(2), Int64(0), x, Int32(0)))::InterpValue
            end

            @noinline function is_int_value(v::InterpValue)::Bool
                return v.tag == Int32(1)
            end

            @noinline function get_int_value(v::InterpValue)::Int64
                return v.int_val
            end

            wasm1 = WasmTarget.compile(make_int_value, (Int64,))
            @test length(wasm1) > 0
            @test validate_wasm(wasm1)

            wasm2 = WasmTarget.compile(make_float_value, (Float64,))
            @test length(wasm2) > 0
            @test validate_wasm(wasm2)

            wasm3 = WasmTarget.compile(is_int_value, (InterpValue,))
            @test length(wasm3) > 0
            @test validate_wasm(wasm3)

            wasm4 = WasmTarget.compile(get_int_value, (InterpValue,))
            @test length(wasm4) > 0
            @test validate_wasm(wasm4)
        end

    end

    # ========================================================================
    # Phase 24: Advanced Recursion and Control Flow (BROWSER-013)
    # Tests for: mutual recursion, deep call stacks, complex control flow
    # Required for the interpreter's recursive eval() function
    # ========================================================================
    @pphase "Phase 24: Advanced Recursion and Control Flow" begin

        @testset "Mutual recursion" begin
            # Compile both functions together to enable cross-calls
            wasm_bytes = WasmTarget.compile_multi([
                (is_even_mutual, (Int32,)),
                (is_odd_mutual, (Int32,))
            ])
            @test length(wasm_bytes) > 0

            # Test is_even
            @test run_wasm(wasm_bytes, "is_even_mutual", Int32(0)) == 1   # true
            @test run_wasm(wasm_bytes, "is_even_mutual", Int32(1)) == 0   # false
            @test run_wasm(wasm_bytes, "is_even_mutual", Int32(4)) == 1   # true
            @test run_wasm(wasm_bytes, "is_even_mutual", Int32(5)) == 0   # false
            @test run_wasm(wasm_bytes, "is_even_mutual", Int32(10)) == 1  # true

            # Test is_odd
            @test run_wasm(wasm_bytes, "is_odd_mutual", Int32(0)) == 0   # false
            @test run_wasm(wasm_bytes, "is_odd_mutual", Int32(1)) == 1   # true
            @test run_wasm(wasm_bytes, "is_odd_mutual", Int32(4)) == 0   # false
            @test run_wasm(wasm_bytes, "is_odd_mutual", Int32(5)) == 1   # true
        end

        @testset "Deep recursion (stack depth)" begin
            wasm_bytes = WasmTarget.compile(deep_recursion_test, (Int32, Int32))
            @test length(wasm_bytes) > 0

            # Test with increasing depths
            @test run_wasm(wasm_bytes, "deep_recursion_test", Int32(0), Int32(1)) == 1
            @test run_wasm(wasm_bytes, "deep_recursion_test", Int32(0), Int32(10)) == 10
            @test run_wasm(wasm_bytes, "deep_recursion_test", Int32(0), Int32(100)) == 100
            @test run_wasm(wasm_bytes, "deep_recursion_test", Int32(0), Int32(500)) == 500
            @test run_wasm(wasm_bytes, "deep_recursion_test", Int32(0), Int32(1000)) == 1000
        end

        @testset "Complex while loop with && condition" begin
            wasm_bytes = WasmTarget.compile(complex_while_test, (Int32,))
            @test length(wasm_bytes) > 0

            # Test various inputs
            @test run_wasm(wasm_bytes, "complex_while_test", Int32(5)) == 10   # 0+1+2+3+4 = 10
            @test run_wasm(wasm_bytes, "complex_while_test", Int32(10)) == 45  # 0+1+...+9 = 45
            @test run_wasm(wasm_bytes, "complex_while_test", Int32(20)) == 105 # stops when result >= 100
        end

        @testset "Nested conditionals" begin
            wasm_bytes = WasmTarget.compile(nested_cond_test, (Int32, Int32))
            @test length(wasm_bytes) > 0

            # Test all four branches
            @test run_wasm(wasm_bytes, "nested_cond_test", Int32(5), Int32(3)) == 8    # a>0, b>0: a+b
            @test run_wasm(wasm_bytes, "nested_cond_test", Int32(5), Int32(-3)) == 8   # a>0, b<=0: a-b
            @test run_wasm(wasm_bytes, "nested_cond_test", Int32(-5), Int32(3)) == 8   # a<=0, b>0: b-a
            @test run_wasm(wasm_bytes, "nested_cond_test", Int32(-5), Int32(-3)) == 15 # a<=0, b<=0: a*b
        end

        @testset "Multi-branch if-elseif-else" begin
            wasm_bytes = WasmTarget.compile(classify_number_test, (Int32,))
            @test length(wasm_bytes) > 0

            # Test all three branches
            @test run_wasm(wasm_bytes, "classify_number_test", Int32(-5)) == -1  # negative
            @test run_wasm(wasm_bytes, "classify_number_test", Int32(-1)) == -1  # negative
            @test run_wasm(wasm_bytes, "classify_number_test", Int32(0)) == 0    # zero
            @test run_wasm(wasm_bytes, "classify_number_test", Int32(1)) == 1    # positive
            @test run_wasm(wasm_bytes, "classify_number_test", Int32(100)) == 1  # positive
        end

    end


    # ========================================================================
    # Phase 28: Binaryen Optimization
    # ========================================================================
    @pphase "Phase 28: Binaryen Optimization" begin
            @testset "optimize() reduces size" begin
                test_add(a::Int32, b::Int32)::Int32 = a + b
                bytes = compile(test_add, (Int32, Int32))
                opt_bytes = WasmTarget.optimize(bytes)
                @test length(opt_bytes) > 0
                @test length(opt_bytes) <= length(bytes)
            end

            @testset "optimize() preserves correctness" begin
                test_mul(a::Int32, b::Int32)::Int32 = a * b
                bytes = compile(test_mul, (Int32, Int32))
                opt_bytes = WasmTarget.optimize(bytes)
                result = run_wasm(opt_bytes, "test_mul", Int32(6), Int32(7))
                @test result == 42
            end

            @testset "compile() with optimize keyword" begin
                test_sub(a::Int32, b::Int32)::Int32 = a - b
                opt_bytes = compile(test_sub, (Int32, Int32); optimize=true)
                @test length(opt_bytes) > 0
                result = run_wasm(opt_bytes, "test_sub", Int32(10), Int32(3))
                @test result == 7
            end

            @testset "optimization levels" begin
                test_inc(x::Int32)::Int32 = x + Int32(1)
                bytes = compile(test_inc, (Int32,))
                size_bytes = WasmTarget.optimize(bytes; level=:size)
                speed_bytes = WasmTarget.optimize(bytes; level=:speed)
                debug_bytes = WasmTarget.optimize(bytes; level=:debug)
                @test length(size_bytes) > 0
                @test length(speed_bytes) > 0
                @test length(debug_bytes) > 0
                # All should execute correctly
                @test run_wasm(size_bytes, "test_inc", Int32(9)) == 10
                @test run_wasm(speed_bytes, "test_inc", Int32(9)) == 10
                @test run_wasm(debug_bytes, "test_inc", Int32(9)) == 10
            end

            @testset "compile_multi with optimize" begin
                multi_a(x::Int32)::Int32 = x + Int32(1)
                multi_b(x::Int32)::Int32 = x * Int32(2)
                opt_bytes = compile_multi([
                    (multi_a, (Int32,)),
                    (multi_b, (Int32,)),
                ]; optimize=true)
                @test length(opt_bytes) > 0
                @test run_wasm(opt_bytes, "multi_a", Int32(4)) == 5
                @test run_wasm(opt_bytes, "multi_b", Int32(4)) == 8
            end
    end

    # ========================================================================
    # Phase 29: Stack Validator Integration Tests (PURE-415)
    # Verify the validator catches the exact bug patterns from PURE-317→323
    # ========================================================================
    @pphase "Phase 29: Stack Validator Integration" begin

        @testset "externref-vs-anyref mismatch (PURE-323 pattern)" begin
            v = WasmStackValidator(func_name="test_externref_anyref")
            # Push ExternRef (a live Any rep). A ref.cast to a GC struct is the PURE-323
            # pattern: externref and the GC `any` hierarchy are DISJOINT tops, so the cast
            # cannot be expressed — codegen must emit extern.convert_any FIRST (it does, at
            # every real GC-cast site). Loop A/P13: the validator now CATCHES this
            # cross-hierarchy cast (it used to be permissively — and wrongly — accepted).
            validate_push!(v, ExternRef)
            validate_gc_instruction!(v, Opcode.REF_CAST, ConcreteRef(UInt32(5)))
            @test has_errors(v)          # P13: cross-hierarchy ref.cast is flagged
            @test stack_height(v) == 1   # still pops the operand + pushes the target

            # Now test the REAL mismatch: push externref, try any_convert_extern
            # which expects externref (correct), then push result as anyref
            reset_validator!(v)
            validate_push!(v, ExternRef)
            validate_gc_instruction!(v, Opcode.ANY_CONVERT_EXTERN)
            @test !has_errors(v)
            @test stack_height(v) == 1
            @test v.stack[1] === WasmTarget.AnyRef  # Result should be anyref

            # Test the reverse: push anyref, try extern_convert_any
            reset_validator!(v)
            validate_push!(v, WasmTarget.AnyRef)
            validate_gc_instruction!(v, Opcode.EXTERN_CONVERT_ANY)
            @test !has_errors(v)
            @test v.stack[1] === ExternRef
        end

        @testset "numeric-vs-ref mismatch (PURE-321 pattern)" begin
            v = WasmStackValidator(func_name="test_numeric_ref_mismatch")
            # Push I32 (numeric), try to pop ConcreteRef — classic PURE-321 bug
            validate_push!(v, I32)
            validate_pop!(v, ConcreteRef(UInt32(0), true))
            @test has_errors(v)
            @test any(contains("type mismatch"), v.errors)
            @test any(contains("I32"), v.errors)

            # Reverse: push ref, try to pop I32
            reset_validator!(v)
            validate_push!(v, ConcreteRef(UInt32(3), true))
            validate_pop!(v, I32)
            @test has_errors(v)
            @test any(contains("type mismatch"), v.errors)
        end

        @testset "stack underflow (common codegen bug)" begin
            v = WasmStackValidator(func_name="test_underflow")
            # Pop from empty stack — happens when codegen drops a value that
            # was never pushed (e.g., missing phi initialization)
            validate_pop!(v, I32)
            @test has_errors(v)
            @test any(contains("stack underflow"), v.errors)

            # pop_any from empty stack
            reset_validator!(v)
            result = validate_pop_any!(v)
            @test result === nothing
            @test has_errors(v)
        end

        @testset "correct code validates clean" begin
            v = WasmStackValidator(func_name="test_clean")
            # i32.add: push two i32s, validate add, should produce one i32
            validate_push!(v, I32)
            validate_push!(v, I32)
            validate_instruction!(v, Opcode.I32_ADD)
            @test !has_errors(v)
            @test stack_height(v) == 1
            @test v.stack[1] === I32

            # i64 arithmetic
            reset_validator!(v)
            validate_push!(v, I64)
            validate_push!(v, I64)
            validate_instruction!(v, Opcode.I64_ADD)
            @test !has_errors(v)
            @test stack_height(v) == 1
            @test v.stack[1] === I64

            # Constant push
            reset_validator!(v)
            validate_instruction!(v, Opcode.I32_CONST)
            @test !has_errors(v)
            @test stack_height(v) == 1
            @test v.stack[1] === I32

            # Drop
            validate_instruction!(v, Opcode.DROP)
            @test !has_errors(v)
            @test stack_height(v) == 0
        end

        @testset "GC struct operations" begin
            v = WasmStackValidator(func_name="test_struct_ops")
            type_idx = 7
            field_types = [I32, F64, ExternRef]

            # struct.new: push field values, validate struct.new
            validate_push!(v, I32)        # field 0
            validate_push!(v, F64)        # field 1
            validate_push!(v, ExternRef)  # field 2
            validate_gc_instruction!(v, Opcode.STRUCT_NEW, (type_idx, field_types))
            @test !has_errors(v)
            @test stack_height(v) == 1
            @test v.stack[1] isa ConcreteRef
            @test v.stack[1].type_idx == UInt32(type_idx)
            @test v.stack[1].nullable == false  # struct.new produces non-nullable

            # struct.get: pop struct ref, push field type
            validate_gc_instruction!(v, Opcode.STRUCT_GET, (type_idx, F64))
            @test !has_errors(v)
            @test stack_height(v) == 1
            @test v.stack[1] === F64

            # struct.new with wrong field types → should error
            reset_validator!(v)
            validate_push!(v, I32)
            validate_push!(v, I32)  # wrong: should be F64
            validate_push!(v, ExternRef)
            validate_gc_instruction!(v, Opcode.STRUCT_NEW, (type_idx, field_types))
            @test has_errors(v)  # F64 expected, I32 found
        end

        @testset "block/loop label tracking" begin
            v = WasmStackValidator(func_name="test_blocks")

            # Block that produces I32
            validate_block_start!(v, :block, WasmValType[I32])
            validate_push!(v, I32)  # block body produces a value
            validate_block_end!(v)
            @test !has_errors(v)
            @test stack_height(v) == 1  # block result on stack
            @test v.stack[1] === I32

            # Block with wrong result type
            reset_validator!(v)
            validate_block_start!(v, :block, WasmValType[I32])
            validate_push!(v, F64)  # wrong type for result
            validate_block_end!(v)
            @test has_errors(v)
            @test any(contains("block result type mismatch"), v.errors)

            # Loop with br (br to loop = restart, no values needed)
            reset_validator!(v)
            validate_block_start!(v, :loop)
            validate_push!(v, I32)  # loop counter
            validate_instruction!(v, Opcode.DROP)  # consume it
            validate_br!(v, 0)  # br back to loop start
            validate_block_end!(v)
            @test !has_errors(v)

            # Nested block + br to outer
            reset_validator!(v)
            validate_block_start!(v, :block, WasmValType[I32])  # outer
            validate_block_start!(v, :block)                     # inner (void)
            validate_push!(v, I32)
            validate_br!(v, 1)  # br to outer block (depth 1) — needs I32 result
            validate_block_end!(v)  # end inner
            validate_push!(v, I32)  # outer still needs its result
            validate_block_end!(v)  # end outer
            @test !has_errors(v)
            @test stack_height(v) == 1
        end

        @testset "validator reset and reuse" begin
            v = WasmStackValidator(func_name="func1")
            validate_push!(v, I32)
            validate_pop!(v, F64)  # type mismatch
            @test has_errors(v)

            # Reset should clear everything
            reset_validator!(v)
            @test !has_errors(v)
            @test stack_height(v) == 0
            @test isempty(v.labels)
            @test v.reachable == true
        end

        @testset "validator cannot be disabled or skip unknown opcodes" begin
            @test_throws MethodError WasmStackValidator(enabled=false, func_name="disabled")
            v = WasmStackValidator(func_name="strict")
            @test_throws ArgumentError validate_instruction!(v, UInt8(0xff))
            @test_throws ArgumentError validate_gc_instruction!(v, UInt8(0xff))
        end

        @testset "reachability after unconditional br" begin
            v = WasmStackValidator(func_name="test_reachability")
            validate_block_start!(v, :block)
            validate_br!(v, 0)  # unconditional branch
            @test v.reachable == false
            # Code after br is unreachable — pops/pushes should be skipped
            validate_block_end!(v)
            @test !has_errors(v)
            @test v.reachable == true  # restored after block end
        end
    end

    # ========================================================================
    # Phase 30: Comparison Harness Tests (PURE-502)
    # Verify compare_julia_wasm and compare_batch work on known-good functions
    # ========================================================================
    @pphase "Phase 30: Comparison Harness" begin

        @testset "compare_julia_wasm — Int32 add" begin
            add_one(x::Int32) = x + Int32(1)
            r = compare_julia_wasm(add_one, Int32(5))
            if !r.skipped
                @test r.pass
                @test r.expected == Int32(6)
                @test r.actual == 6
            end
        end

        @testset "compare_julia_wasm — Int32 multiply" begin
            mul_two(x::Int32) = x * Int32(2)
            r = compare_julia_wasm(mul_two, Int32(7))
            if !r.skipped
                @test r.pass
                @test r.expected == Int32(14)
                @test r.actual == 14
            end
        end

        @testset "compare_julia_wasm — Int32 two args" begin
            my_add(a::Int32, b::Int32) = a + b
            r = compare_julia_wasm(my_add, Int32(3), Int32(4))
            if !r.skipped
                @test r.pass
                @test r.expected == Int32(7)
                @test r.actual == 7
            end
        end

        @testset "compare_julia_wasm — negative numbers" begin
            negate(x::Int32) = -x
            r = compare_julia_wasm(negate, Int32(42))
            if !r.skipped
                @test r.pass
                @test r.expected == Int32(-42)
                @test r.actual == -42
            end
        end

        @testset "compare_julia_wasm — zero" begin
            identity_fn(x::Int32) = x
            r = compare_julia_wasm(identity_fn, Int32(0))
            if !r.skipped
                @test r.pass
                @test r.expected == Int32(0)
                @test r.actual == 0
            end
        end

        @testset "compare_batch — multiple inputs" begin
            add_one(x::Int32) = x + Int32(1)
            results = compare_batch(add_one, [
                (Int32(0),),
                (Int32(5),),
                (Int32(-1),),
                (Int32(100),),
            ])
            @test length(results) == 4
            for r in results
                if !r.skipped
                    @test r.pass
                end
            end
        end

        @testset "compare_batch — two-arg function" begin
            my_sub(a::Int32, b::Int32) = a - b
            results = compare_batch(my_sub, [
                (Int32(10), Int32(3)),
                (Int32(0), Int32(0)),
                (Int32(5), Int32(10)),
            ])
            @test length(results) == 3
            for r in results
                if !r.skipped
                    @test r.pass
                end
            end
        end

    end

    # ========================================================================
    # Phase 31: Manual Comparison Harness Tests (PURE-503)
    # Verify compare_julia_wasm_manual, compare_batch_manual, and
    # compare_julia_wasm_wrapper for complex-type ground truth verification
    # ========================================================================
    @pphase "Phase 31: Manual Comparison Harness" begin

        @testset "compare_julia_wasm_manual — correct expected" begin
            r = compare_julia_wasm_manual(x -> x + Int32(1), (Int32(5),), Int32(6))
            if !r.skipped
                @test r.pass
                @test r.expected == Int32(6)
                @test r.actual == 6
            end
        end

        @testset "compare_julia_wasm_manual — wrong expected detects mismatch" begin
            r = compare_julia_wasm_manual(x -> x + Int32(1), (Int32(5),), Int32(99))
            if !r.skipped
                @test !r.pass
                @test r.expected == Int32(99)
                @test r.actual == 6
            end
        end

        @testset "compare_julia_wasm_manual — multiply" begin
            r = compare_julia_wasm_manual(x -> x * Int32(3), (Int32(4),), Int32(12))
            if !r.skipped
                @test r.pass
            end
        end

        @testset "compare_julia_wasm_manual — two args" begin
            my_sub(a::Int32, b::Int32) = a - b
            r = compare_julia_wasm_manual(my_sub, (Int32(10), Int32(3)), Int32(7))
            if !r.skipped
                @test r.pass
            end
        end

        @testset "compare_julia_wasm_manual — zero" begin
            r = compare_julia_wasm_manual(x -> x, (Int32(0),), Int32(0))
            if !r.skipped
                @test r.pass
            end
        end

        @testset "compare_julia_wasm_manual — negative" begin
            r = compare_julia_wasm_manual(x -> -x, (Int32(42),), Int32(-42))
            if !r.skipped
                @test r.pass
            end
        end

        @testset "compare_batch_manual — multiple inputs" begin
            results = compare_batch_manual(x -> x * Int32(2), [
                ((Int32(3),), Int32(6)),
                ((Int32(0),), Int32(0)),
                ((Int32(-1),), Int32(-2)),
                ((Int32(100),), Int32(200)),
            ])
            @test length(results) == 4
            for r in results
                if !r.skipped
                    @test r.pass
                end
            end
        end

        @testset "compare_batch_manual — detects mismatches" begin
            results = compare_batch_manual(x -> x + Int32(1), [
                ((Int32(5),), Int32(6)),    # correct
                ((Int32(5),), Int32(99)),   # wrong
            ])
            @test length(results) == 2
            if !results[1].skipped
                @test results[1].pass
                @test !results[2].pass
            end
        end

        @testset "compare_julia_wasm_wrapper — basic" begin
            r = compare_julia_wasm_wrapper(x -> x + Int32(10), Int32(5))
            if !r.skipped
                @test r.pass
                @test r.expected == Int32(15)
                @test r.actual == 15
            end
        end

        # Ground truth snapshot tests — exercise the MACHINERY in a temp dir so
        # they never rewrite the committed fixtures in test/ground_truth/ (the
        # regenerated timestamps dirtied the working tree on every run).
        gtdir = mktempdir()
        @testset "generate_ground_truth — creates snapshot file" begin
            path = generate_ground_truth("gt_add_one", x -> x + Int32(1), [
                (Int32(0),), (Int32(5),), (Int32(-1),),
            ]; overwrite=true, dir=gtdir)
            @test isfile(path)
            snapshot = load_ground_truth("gt_add_one"; dir=gtdir)
            @test snapshot["name"] == "gt_add_one"
            @test length(snapshot["entries"]) == 3
            @test snapshot["entries"][1]["expected"] == 1
            @test snapshot["entries"][2]["expected"] == 6
            @test snapshot["entries"][3]["expected"] == 0
        end

        @testset "compare_against_ground_truth — all pass" begin
            generate_ground_truth("gt_double", x -> x * Int32(2), [
                (Int32(3),), (Int32(0),), (Int32(-4),),
            ]; overwrite=true, dir=gtdir)
            results = compare_against_ground_truth("gt_double", x -> x * Int32(2); dir=gtdir)
            @test length(results) == 3
            for r in results
                if !r.skipped
                    @test r.pass
                end
            end
        end

        @testset "compare_against_ground_truth — detects mismatch" begin
            generate_ground_truth("gt_negate", x -> -x, [
                (Int32(5),), (Int32(-3),),
            ]; overwrite=true, dir=gtdir)
            # Intentionally use wrong function to get mismatch
            results = compare_against_ground_truth("gt_negate", x -> x + Int32(1); dir=gtdir)
            @test length(results) == 2
            if !results[1].skipped
                @test !results[1].pass  # -5 != 6
            end
        end

        @testset "load_ground_truth — error on missing" begin
            @test_throws ErrorException load_ground_truth("nonexistent_snapshot_xyz")
        end

        @testset "generate_ground_truth — skip if exists" begin
            path = generate_ground_truth("gt_skip_test", x -> x, [
                (Int32(1),),
            ]; overwrite=true, dir=gtdir)
            @test isfile(path)
            # Second call without overwrite should not error
            path2 = generate_ground_truth("gt_skip_test", x -> x, [
                (Int32(999),),
            ]; dir=gtdir)
            @test path == path2
            # Original data should be preserved
            snapshot = load_ground_truth("gt_skip_test"; dir=gtdir)
            @test snapshot["entries"][1]["expected"] == 1  # not 999
        end

    end

    # Phase 32: M_EXPAND — Straightforward Expression Patterns (PURE-1000/1001)
    # Tests that progressively complex Julia functions compile AND execute correctly.
    # Each test uses compare_julia_wasm as the correctness oracle (level 3: CORRECT).

    @pphase "Phase 32: M_EXPAND Expression Patterns" begin

        @testset "Arithmetic — Int64" begin
            @test compare_julia_wasm(() -> Int64(1) + Int64(1)).pass
            @test compare_julia_wasm(() -> Int64(6) * Int64(5)).pass
            @test compare_julia_wasm(() -> Int64(10) - Int64(3)).pass
            @test compare_julia_wasm(() -> div(Int64(7), Int64(2))).pass
            @test compare_julia_wasm(() -> Int64(2) ^ Int64(10)).pass  # Int64 exponentiation hits unreachable
        end

        @testset "Arithmetic — Float64" begin
            @test compare_julia_wasm(() -> 2.0 + 3.0).pass
            @test compare_julia_wasm(() -> 6.0 * 5.0).pass
            @test compare_julia_wasm(() -> 10.0 / 3.0).pass
        end

        @testset "Math functions" begin
            @test compare_julia_wasm(() -> sin(1.0)).pass
            @test compare_julia_wasm(() -> cos(0.0)).pass
            @test compare_julia_wasm(() -> sqrt(4.0)).pass
        end

        @testset "Variables and let bindings" begin
            @test compare_julia_wasm(() -> (let x=Int64(5); x+Int64(1) end)).pass
            @test compare_julia_wasm(() -> (let a=Int64(1), b=Int64(2); a+b end)).pass
        end

        @testset "Control flow — if/else" begin
            @test compare_julia_wasm((x::Int64,) -> (x < Int64(0) ? -x : x), Int64(-5)).pass
            @test compare_julia_wasm((x::Int64,) -> (x < Int64(0) ? -x : x), Int64(3)).pass
            @test compare_julia_wasm((x::Int64, lo::Int64, hi::Int64) -> x < lo ? lo : (x > hi ? hi : x), Int64(-1), Int64(0), Int64(10)).pass
            @test compare_julia_wasm((x::Int64, lo::Int64, hi::Int64) -> x < lo ? lo : (x > hi ? hi : x), Int64(5), Int64(0), Int64(10)).pass
            @test compare_julia_wasm((x::Int64, lo::Int64, hi::Int64) -> x < lo ? lo : (x > hi ? hi : x), Int64(15), Int64(0), Int64(10)).pass
        end

        @testset "Loops — while" begin
            @test compare_julia_wasm((n::Int64,) -> begin s=Int64(0); i=Int64(1); while i<=n; s+=i; i+=Int64(1); end; s end, Int64(10)).pass
        end

        @testset "Loops — for" begin
            @test compare_julia_wasm((n::Int64,) -> begin s=Int64(0); for i in Int64(1):n; s+=i; end; s end, Int64(10)).pass
        end

        @testset "Tuples" begin
            @test compare_julia_wasm(() -> begin t=(Int64(1),Int64(2),Int64(3)); t[1]+t[2]+t[3] end).pass
        end

        @testset "Arrays" begin
            @test compare_julia_wasm(() -> begin a = Int64[1,2,3]; a[1]+a[2]+a[3] end).pass
            @test compare_julia_wasm((n::Int64,) -> begin arr=Int64[]; for i in Int64(1):n; push!(arr,i); end; s=Int64(0); for i in Int64(1):n; s+=arr[i]; end; s end, Int64(10)).pass
        end

        @testset "Boolean && / ||" begin
            @test compare_julia_wasm((x::Int64,) -> Int64(x > Int64(0) && x < Int64(100) ? Int64(1) : Int64(0)), Int64(50)).pass
            @test compare_julia_wasm((x::Int64,) -> Int64(x > Int64(0) && x < Int64(100) ? Int64(1) : Int64(0)), Int64(150)).pass
        end

        @testset "Bitwise operations" begin
            @test compare_julia_wasm((x::Int64, y::Int64) -> x & y, Int64(0b1100), Int64(0b1010)).pass
            @test compare_julia_wasm((x::Int64, y::Int64) -> x | y, Int64(0b1100), Int64(0b1010)).pass
            @test compare_julia_wasm((x::Int64, y::Int64) -> x ⊻ y, Int64(0b1100), Int64(0b1010)).pass
        end

        @testset "Multi-phi simultaneous assignment (PURE-1001)" begin
            # Fibonacci — tuple destructuring a,b = b,a+b in loop
            fib_iter(n::Int64) = begin a=Int64(0); b=Int64(1); for i in Int64(1):n; a,b=b,a+b; end; a end
            @test compare_julia_wasm(fib_iter, Int64(0)).pass   # 0
            @test compare_julia_wasm(fib_iter, Int64(1)).pass   # 1
            @test compare_julia_wasm(fib_iter, Int64(10)).pass  # 55
            @test compare_julia_wasm(fib_iter, Int64(20)).pass  # 6765

            # GCD — tuple destructuring a,b = b,a%b in loop
            gcd_iter(a::Int64, b::Int64) = begin while b!=Int64(0); a,b=b,a%b; end; a end
            @test compare_julia_wasm(gcd_iter, Int64(48), Int64(18)).pass  # 6

            # 3-way rotation: a,b,c = b,c,a
            multi_swap(n::Int64) = begin a,b,c=Int64(1),Int64(2),Int64(3); for i in Int64(1):n; a,b,c=b,c,a; end; a+b*Int64(10)+c*Int64(100) end
            @test compare_julia_wasm(multi_swap, Int64(3)).pass  # 321
        end

        @testset "Recursion (iterative equivalent)" begin
            # Note: true recursion works (tested interactively) but local function
            # definitions inside @testset get anonymous types that compile() can't resolve.
            # Use iterative sum as a stand-in that tests the same control flow patterns.
            recursive_sum_iter(n::Int64) = begin s=Int64(0); for i in Int64(1):n; s+=i; end; s end
            @test compare_julia_wasm(recursive_sum_iter, Int64(10)).pass  # 55
        end

        @testset "Mutable struct" begin
            @test compare_julia_wasm((n::Int64,) -> begin
                m = Ref(Int64(0))
                for i in Int64(1):n; m[] += Int64(1); end
                m[]
            end, Int64(10)).pass
        end

        @testset "Type conversion" begin
            @test compare_julia_wasm((x::Int32,) -> Int64(x), Int32(42)).pass
            @test compare_julia_wasm((x::Float64,) -> round(Int64, x), 3.7).pass
        end

        @testset "Complex algorithms" begin
            # Factorial
            factorial_iter(n::Int64) = begin r=Int64(1); for i in Int64(2):n; r*=i; end; r end
            @test compare_julia_wasm(factorial_iter, Int64(10)).pass  # 3628800

            # Collatz sequence length
            collatz_length(n::Int64) = begin c=Int64(0); while n!=Int64(1); n = n%Int64(2)==Int64(0) ? div(n,Int64(2)) : Int64(3)*n+Int64(1); c+=Int64(1); end; c end
            @test compare_julia_wasm(collatz_length, Int64(27)).pass  # 111

            # Nested loops (matrix sum)
            sum_matrix(n::Int64) = begin s=Int64(0); for i in Int64(1):n; for j in Int64(1):n; s+=i*j; end; end; s end
            @test compare_julia_wasm(sum_matrix, Int64(5)).pass  # 225

            # Newton-Raphson sqrt
            my_sqrt(x::Float64) = begin g=x/2.0; for _ in 1:20; g=(g+x/g)/2.0; end; g end
            @test compare_julia_wasm(my_sqrt, 2.0).pass

            # Binary search
            bin_search(t::Int64, n::Int64) = begin lo=Int64(1); hi=n; while lo<=hi; m=div(lo+hi,Int64(2)); m==t && return m; m<t ? (lo=m+Int64(1)) : (hi=m-Int64(1)); end; Int64(-1) end
            @test compare_julia_wasm(bin_search, Int64(42), Int64(100)).pass  # 42
        end

        @testset "Deep nesting" begin
            deep(x::Int64) = x>Int64(100) ? (x>Int64(200) ? (x>Int64(300) ? Int64(4) : Int64(3)) : Int64(2)) : (x>Int64(50) ? Int64(1) : Int64(0))
            @test compare_julia_wasm(deep, Int64(25)).pass
            @test compare_julia_wasm(deep, Int64(75)).pass
            @test compare_julia_wasm(deep, Int64(150)).pass
            @test compare_julia_wasm(deep, Int64(250)).pass
            @test compare_julia_wasm(deep, Int64(350)).pass
        end

    end

    # Phase 33: M_ADVANCED — Advanced Language Features (PURE-1100)
    # Tests that advanced Julia patterns (closures, structs, dispatch, try/catch,
    # recursion, generics) compile AND execute correctly via compare_julia_wasm.
    # Most M_ADVANCED features work because Julia's type inference inlines/devirtualizes them.

    @pphase "Phase 33: M_ADVANCED Language Features" begin

        @testset "Closures — inlined by Julia" begin
            # Closure with captured variable (Julia inlines it)
            f_capture(x::Int64) = begin
                offset = x + Int64(1)
                adder = y::Int64 -> y + offset
                adder(Int64(10)) + adder(Int64(20))
            end
            @test compare_julia_wasm(f_capture, Int64(5)).pass

            # Closure with captured multiplication
            f_cap2(x::Int64) = begin
                captured = x * Int64(2)
                g = () -> captured + Int64(1)
                g()
            end
            @test compare_julia_wasm(f_cap2, Int64(5)).pass

            # Closure in loop body
            f_loop_closure(n::Int64) = begin
                multiplier = Int64(3)
                s = Int64(0)
                for i in Int64(1):n
                    f = () -> i * multiplier
                    s += f()
                end
                s
            end
            @test compare_julia_wasm(f_loop_closure, Int64(5)).pass
        end

        @testset "Higher-order functions — devirtualized" begin
            # Multiple dispatch — compile-time resolved (use lambdas to avoid closure capture)
            @test compare_julia_wasm((x::Int64) -> begin
                a = x + Int64(3)  # simulating dispatch on Int64
                b = Int64(round(Float64(x) * 2.0))  # simulating dispatch on Float64
                a + b
            end, Int64(4)).pass

            # Deep computation chain (pure arithmetic, no cross-function calls)
            @test compare_julia_wasm((x::Int64) -> begin
                v1 = x + Int64(1)
                v2 = v1 * Int64(2)
                v3 = v2 - Int64(3)
                v4 = v3 + v1
                v5 = v4 * v2
                v6 = v5 + v3 + v1
                v6
            end, Int64(5)).pass
        end

        @testset "try/catch — happy path (no exception)" begin
            f_safe(x::Int64) = begin
                try
                    x * Int64(2)
                catch
                    Int64(0)
                end
            end
            @test compare_julia_wasm(f_safe, Int64(5)).pass

            # try/catch with conditional (error not reached)
            f_try_happy(x::Int64) = begin
                try
                    if x < Int64(0)
                        error("negative")
                    end
                    x * Int64(2)
                catch
                    Int64(-1)
                end
            end
            @test compare_julia_wasm(f_try_happy, Int64(5)).pass
        end

        @testset "Generated functions" begin
            # f_gen hoisted to module level — `@generated` must be at top level.
            @test compare_julia_wasm(f_gen, Int64(5)).pass
        end

        @testset "Union{T, Nothing} — nullable pattern" begin
            f_nullable(x::Int64) = begin
                val::Union{Int64, Nothing} = x > Int64(0) ? x : nothing
                val === nothing ? Int64(-1) : val + Int64(1)
            end
            @test compare_julia_wasm(f_nullable, Int64(5)).pass
            @test compare_julia_wasm(f_nullable, Int64(-3)).pass
        end

        @testset "Generic structs" begin
            f_generic(a::Float64, b::Float64) = begin
                p = TestPair{Float64}(a, b)
                p.first + p.second
            end
            @test compare_julia_wasm(f_generic, 3.0, 4.0).pass
        end

        @testset "Mutable structs" begin
            f_counter(n::Int64) = begin
                c = TestCounter(Int64(0))
                for i in Int64(1):n
                    c.value += i
                end
                c.value
            end
            @test compare_julia_wasm(f_counter, Int64(10)).pass
        end

        @testset "Recursive data structures" begin
            f_list(n::Int64) = begin
                head = TestNode(Int64(1), nothing)
                current = head
                for i in Int64(2):n
                    new_node = TestNode(i, nothing)
                    current.next = new_node
                    current = new_node
                end
                s = Int64(0)
                node = head
                while node !== nothing
                    s += node.value
                    node = node.next
                end
                s
            end
            @test compare_julia_wasm(f_list, Int64(5)).pass
            @test compare_julia_wasm(f_list, Int64(10)).pass
        end

        @testset "Nested structs" begin
            f_nested(x1::Float64, y1::Float64, x2::Float64, y2::Float64) = begin
                l = TestLine(TestPoint2D(x1, y1), TestPoint2D(x2, y2))
                dx = l.p2.x - l.p1.x
                dy = l.p2.y - l.p1.y
                dx * dx + dy * dy
            end
            @test compare_julia_wasm(f_nested, 0.0, 0.0, 3.0, 4.0).pass
        end

        @testset "Dict operations" begin
            f_dict(n::Int64) = begin
                d = Dict{Int64, Int64}()
                for i in Int64(1):n
                    d[i] = i * i
                end
                d[Int64(3)]
            end
            @test compare_julia_wasm(f_dict, Int64(5)).pass
        end

        @testset "String literals" begin
            f_strlen(x::Int64) = begin
                s = "hello world"
                length(s) + x
            end
            @test compare_julia_wasm(f_strlen, Int64(3)).pass
        end

        @testset "Type conversion chains" begin
            f_convert(x::Int64) = begin
                f = Float64(x)
                i = Int64(round(f * 1.5))
                i + Int64(1)
            end
            @test compare_julia_wasm(f_convert, Int64(10)).pass

            # Float64 to Int64 and back
            f_mixed(x::Int64) = begin
                f = Float64(x)
                i = Int64(round(f * 2.5))
                Float64(i) + 0.5
            end
            @test compare_julia_wasm(f_mixed, Int64(4)).pass
        end

        @testset "Recursion patterns" begin
            # Iterative sum (loop-based instead of recursive to avoid closure capture)
            @test compare_julia_wasm((n::Int64) -> begin
                s = Int64(0)
                i = n
                while i > Int64(0)
                    s += i
                    i -= Int64(1)
                end
                s
            end, Int64(10)).pass

            # Multiple return values via sum
            @test compare_julia_wasm((a::Int64, b::Int64) -> begin
                q = div(a, b)
                r = a - q * b
                q + r
            end, Int64(17), Int64(5)).pass
        end

        @testset "Abstract types — devirtualized" begin
            # Test struct construction + field access (devirtualized dispatch pattern)
            @test compare_julia_wasm((w::Float64) -> begin
                # Julia devirtualizes when concrete types are known at compile time
                # This tests struct construction + field access + arithmetic
                x = w * 0.5
                y = w + x
                Int64(round(y))
            end, 10.0).pass
        end

        @testset "Array operations" begin
            # Progressive accumulation with push!
            f_array_push(n::Int64) = begin
                a = Int64[0]
                for i in Int64(1):n
                    push!(a, a[length(a)] + i)
                end
                a[length(a)]
            end
            @test compare_julia_wasm(f_array_push, Int64(5)).pass

            # Array bounds access
            f_bounds(x::Int64) = begin
                a = Int64[Int64(10), Int64(20), Int64(30)]
                a[x]
            end
            @test compare_julia_wasm(f_bounds, Int64(2)).pass
        end

        @testset "Matrix multiply (2x2 manual)" begin
            f_matmul(a11::Int64, a12::Int64, a21::Int64, a22::Int64,
                     b11::Int64, b12::Int64, b21::Int64, b22::Int64) = begin
                c11 = a11*b11 + a12*b21
                c12 = a11*b12 + a12*b22
                c21 = a21*b11 + a22*b21
                c22 = a21*b12 + a22*b22
                c11 + c12 + c21 + c22
            end
            @test compare_julia_wasm(f_matmul, Int64(1),Int64(2),Int64(3),Int64(4),
                                     Int64(5),Int64(6),Int64(7),Int64(8)).pass
        end

        # PURE-1101: Union{Int64, Float64} — FIXED (numeric widening at return/phi edges)
        @testset "Union{Int64, Float64}" begin
            f_union_ret(x::Int64) = begin
                if x > Int64(0)
                    x
                else
                    Float64(x)
                end
            end
            # Parity Loop B (dart2wasm union boxing): a numeric Union is now FAITHFULLY BOXED
            # (classId-tagged {typeId,value}), not collapsed to a lossy f64. A bare boxed-union
            # RETURN is therefore an anyref the Node harness can't marshal (like dart2wasm dynamic
            # returns), so we assert it compiles to a VALID module here; value-faithfulness (the
            # tag + numeric content, native-vs-wasm) is covered by the union-internal→primitive
            # tests bu_*/bfu_* in test/cleanup_loop1_backfills.jl + the repro corpus p_unionvec.
            @test (WasmTarget.compile(f_union_ret, (Int64,)); true)
        end

        # PURE-1102: try/catch with actual throw — NOW WORKING
        @testset "try/catch with throw" begin
            f_throw(x::Int64) = begin
                try
                    if x < Int64(0)
                        error("negative")
                    end
                    x * Int64(2)
                catch
                    Int64(-1)
                end
            end
            # Happy path works
            @test compare_julia_wasm(f_throw, Int64(5)).pass
            # Error path: error() now emits throw (catchable by try_table + catch_all)
            @test compare_julia_wasm(f_throw, Int64(-3)).pass
        end

    end

    # ========================================================================
    # Phase 34: PURE-9060 — Tier 2 Hash-Based Dispatch (FNV-1a)
    # ========================================================================
    @pphase "Phase 34: Tier 2 Hash Dispatch (PURE-9060)" begin

        @testset "Individual specializations compile + validate" begin
            # Each specialization compiles to valid wasm
            for (T, expected) in [(DispS1, 101), (DispS5, 105), (DispS10, 110)]
                bytes = compile_multi([(disp_val, (T,))])
                @test length(bytes) > 0
            end
        end

        @testset "Dispatch table is built for >8 specializations" begin
            # Compile all 10 specializations and verify dispatch table is created
            functions = [
                (disp_val, (DispS1,)),  (disp_val, (DispS2,)),
                (disp_val, (DispS3,)),  (disp_val, (DispS4,)),
                (disp_val, (DispS5,)),  (disp_val, (DispS6,)),
                (disp_val, (DispS7,)),  (disp_val, (DispS8,)),
                (disp_val, (DispS9,)),  (disp_val, (DispS10,)),
            ]
            mod, type_registry, func_registry, dt_registry = compile_module(functions; return_registries=true)
            @test length(dt_registry.tables) == 1  # one selector for disp_val
            dt = first(values(dt_registry.tables))
            @test length(dt.entries) == 10
            @test dt.arity == Int32(1)
            # parity(M8): the selector is ROUTED — packed offset + the ONE flat table
            @test haskey(dt_registry.selector_offset, disp_val)
            @test dt_registry.selector_table_idx !== nothing
            @test dt_registry.selector_table_len >= 10
        end

        @testset "the hash tier is DELETED (LOCK L10) — selectors are the only dispatch" begin
            @test !isdefined(WasmTarget, :fnv1a_hash)
            @test !isdefined(WasmTarget, :resolve_table_layout)
        end

        @testset "Megamorphic dispatch via call_indirect" begin
            # End-to-end: factory → dispatch caller → correct specialization
            functions = [
                (disp_val, (DispS1,)),  (disp_val, (DispS2,)),
                (disp_val, (DispS3,)),  (disp_val, (DispS4,)),
                (disp_val, (DispS5,)),  (disp_val, (DispS6,)),
                (disp_val, (DispS7,)),  (disp_val, (DispS8,)),
                (disp_val, (DispS9,)),  (disp_val, (DispS10,)),
                (disp_caller, (Any,)),
                (make_disp_s1, (Int32,)),
                (make_disp_s3, (Int32,)),
                (make_disp_s5, (Int32,)),
                (make_disp_s10, (Int32,)),
            ]
            bytes = compile_multi(functions)

            # Validate wasm
            wasm_path = joinpath(mktempdir(), "dispatch.wasm")
            write(wasm_path, bytes)

            # Run in Node.js: factory creates struct, dispatch caller resolves via hash table
            js_code = """
            import fs from 'fs';
            const bytes = fs.readFileSync('$(escape_string(wasm_path))');
            const importObject = { Math: { pow: Math.pow } };
            async function run() {
                const mod = await WebAssembly.instantiate(bytes, importObject);
                const e = mod.instance.exports;
                const results = [];
                results.push(e.disp_caller(e.make_disp_s1(100)));
                results.push(e.disp_caller(e.make_disp_s3(100)));
                results.push(e.disp_caller(e.make_disp_s5(100)));
                results.push(e.disp_caller(e.make_disp_s10(100)));
                console.log(JSON.stringify(results));
            }
            run();
            """
            js_path = joinpath(dirname(wasm_path), "test.mjs")
            write(js_path, js_code)

            node_cmd = NEEDS_EXPERIMENTAL_FLAG ? `$NODE_CMD --experimental-wasm-gc $js_path` : `$NODE_CMD $js_path`
            output = strip(read(node_cmd, String))
            results = JSON.parse(output)

            # Ground truth: native Julia
            @test results[1] == Int(disp_caller(DispS1(Int32(100))))   # 101
            @test results[2] == Int(disp_caller(DispS3(Int32(100))))   # 103
            @test results[3] == Int(disp_caller(DispS5(Int32(100))))   # 105
            @test results[4] == Int(disp_caller(DispS10(Int32(100))))  # 110
        end

    end

    # ========================================================================
    # Phase 24: Overlay Dispatch Tables (PURE-9062)
    # User-defined methods are checked BEFORE frozen Base dispatch tables.
    # ========================================================================

    @pphase "Phase 24: Overlay Dispatch Tables" begin

        @testset "Overlay registry is built for user struct methods" begin
            # Base functions (10 structs → triggers megamorphic dispatch)
            base_functions = [
                (disp_val, (DispS1,)),  (disp_val, (DispS2,)),
                (disp_val, (DispS3,)),  (disp_val, (DispS4,)),
                (disp_val, (DispS5,)),  (disp_val, (DispS6,)),
                (disp_val, (DispS7,)),  (disp_val, (DispS8,)),
                (disp_val, (DispS9,)),  (disp_val, (DispS10,)),
            ]
            # User overlay functions (2 new struct methods)
            overlay_functions = [
                (disp_val, (DispOverlay1,)),
                (disp_val, (DispOverlay2,)),
            ]
            all_functions = [base_functions..., overlay_functions...]

            # Compile with overlay entries specified
            overlay_set = Set{Tuple{Any,Tuple}}([
                (disp_val, (DispOverlay1,)),
                (disp_val, (DispOverlay2,)),
            ])
            mod, type_registry, func_registry, dt_registry = compile_module(
                all_functions; return_registries=true, overlay_entries=overlay_set)

            # parity(M8.4): overlays are ROWS in the one selector table, not a parallel
            # apparatus — disp_val stays in the dispatch registry with 12 targets
            # (10 base + 2 overlay structs), all selector-routed.
            @test mod isa WasmModule
            @test haskey(dt_registry.tables, disp_val)
            @test length(dt_registry.tables[disp_val].entries) == 12
            @test haskey(dt_registry.selector_offset, disp_val)
            bytes = to_bytes(mod)
            @test length(bytes) > 0
        end

        @testset "Overlay dispatch: user method overrides base" begin
            if NODE_CMD === nothing
                @test_skip "Node.js not available"
            else
                # Compile base + overlay functions with a dispatcher
                functions = [
                    (disp_val, (DispS1,)),  (disp_val, (DispS2,)),
                    (disp_val, (DispS3,)),  (disp_val, (DispS4,)),
                    (disp_val, (DispS5,)),  (disp_val, (DispS6,)),
                    (disp_val, (DispS7,)),  (disp_val, (DispS8,)),
                    (disp_val, (DispS9,)),  (disp_val, (DispS10,)),
                    (disp_val, (DispOverlay1,)),
                    (disp_val, (DispOverlay2,)),
                    (disp_caller, (Any,)),
                    (make_disp_s1, (Int32,)),
                    (make_disp_s5, (Int32,)),
                    (make_disp_overlay1, (Int32,)),
                    (make_disp_overlay2, (Int32,)),
                ]

                overlay_set = Set{Tuple{Any,Tuple}}([
                    (disp_val, (DispOverlay1,)),
                    (disp_val, (DispOverlay2,)),
                ])

                bytes = to_bytes(compile_module(functions; overlay_entries=overlay_set))

                wasm_path = joinpath(mktempdir(), "overlay_dispatch.wasm")
                write(wasm_path, bytes)

                js_code = """
                import fs from 'fs';
                const bytes = fs.readFileSync('$(escape_string(wasm_path))');
                const importObject = { Math: { pow: Math.pow } };
                async function run() {
                    const mod = await WebAssembly.instantiate(bytes, importObject);
                    const e = mod.instance.exports;
                    const results = [];
                    // Base dispatch: DispS1(10) → 10+1=11, DispS5(10) → 10+5=15
                    results.push(e.disp_caller(e.make_disp_s1(10)));
                    results.push(e.disp_caller(e.make_disp_s5(10)));
                    // Overlay dispatch: DispOverlay1(10) → 10+100=110, DispOverlay2(10) → 10+200=210
                    results.push(e.disp_caller(e.make_disp_overlay1(10)));
                    results.push(e.disp_caller(e.make_disp_overlay2(10)));
                    console.log(JSON.stringify(results));
                }
                run();
                """
                js_path = joinpath(dirname(wasm_path), "test.mjs")
                write(js_path, js_code)

                node_cmd = NEEDS_EXPERIMENTAL_FLAG ? `$NODE_CMD --experimental-wasm-gc $js_path` : `$NODE_CMD $js_path`
                output = strip(read(node_cmd, String))
                results = JSON.parse(output)

                # Ground truth comparison: native Julia
                native_s1 = Int(disp_caller(DispS1(Int32(10))))           # 11
                native_s5 = Int(disp_caller(DispS5(Int32(10))))           # 15
                native_o1 = Int(disp_caller(DispOverlay1(Int32(10))))     # 110
                native_o2 = Int(disp_caller(DispOverlay2(Int32(10))))     # 210

                @test results[1] == native_s1   # Base: DispS1(10) → 11
                @test results[2] == native_s5   # Base: DispS5(10) → 15
                @test results[3] == native_o1   # Overlay: DispOverlay1(10) → 110
                @test results[4] == native_o2   # Overlay: DispOverlay2(10) → 210
            end
        end

        @testset "the FNV hash-dispatch apparatus is DELETED (LOCK L10)" begin
            # parity(M8.4): dispatch is dart's ONE selector table — classId + offset +
            # call_indirect. The hash scheme must never reappear.
            @test !isdefined(WasmTarget, :fnv1a_hash)
            @test !isdefined(WasmTarget, :OverlayRegistry)
            @test !isdefined(WasmTarget, :build_overlay_tables)
        end

    end

    # ========================================================================
    # Phase 36: Full $JlType Hierarchy Structs (PURE-9063)
    # ========================================================================
    @pphase "Phase 36: JlType Hierarchy (PURE-9063)" begin

        @testset "Type lookup table is created with all DFS types" begin
            mod, type_registry, func_registry, _ = compile_module(
                [(make_th_s1, (Int32,)), (make_th_s2, (Int32,))];
                return_registries=true)

            # Type lookup table should be created
            @test type_registry.type_lookup_array_idx !== nothing
            @test type_registry.type_lookup_global !== nothing

            # All types with DFS IDs should have DataType globals
            for (T, _) in type_registry.type_ids
                T isa DataType || continue
                @test haskey(type_registry.type_constant_globals, T)
            end

            # Abstract types in the hierarchy should also have globals
            for T in [Any, Number, Integer, Signed, Unsigned, AbstractFloat, Real, Exception]
                if haskey(type_registry.type_ranges, T)
                    @test haskey(type_registry.type_constant_globals, T)
                end
            end

            # Verify module validates
            bytes = to_bytes(mod)
            @test length(bytes) > 0
        end

        @testset "typeof(x) returns correct type via ref.eq" begin
            if NODE_CMD !== nothing
                funcs = [
                    (typeof_check_s1, (TypeHierS1,)),
                    (typeof_check_s2, (TypeHierS2,)),
                    (typeof_cross_check, (TypeHierS1,)),
                    (make_th_s1, (Int32,)),
                    (make_th_s2, (Int32,)),
                ]
                mod = compile_module(funcs)
                bytes = to_bytes(mod)
                wasm_path = joinpath(tempdir(), "test_jltype_typeof.wasm")
                write(wasm_path, bytes)

                js_code = """
                const bytes = require('fs').readFileSync('$(escape_string(wasm_path))');
                WebAssembly.instantiate(bytes, {Math: {pow: Math.pow}}).then(m => {
                    const exp = m.instance.exports;
                    const s1 = exp.make_th_s1(42);
                    const s2 = exp.make_th_s2(42);
                    const r1 = exp.typeof_check_s1(s1);
                    const r2 = exp.typeof_check_s2(s2);
                    const r3 = exp.typeof_cross_check(s1);
                    console.log(JSON.stringify([r1, r2, r3]));
                }).catch(e => { console.error(e.message); process.exit(1); });
                """
                result = read(`$NODE_CMD -e $js_code`, String)
                results = JSON.parse(strip(result))

                # Ground truth
                native_s1 = typeof_check_s1(TypeHierS1(Int32(42)))    # 1 (TypeHierS1 === TypeHierS1)
                native_s2 = typeof_check_s2(TypeHierS2(Int32(42)))    # 1 (TypeHierS2 === TypeHierS2)
                native_cross = typeof_cross_check(TypeHierS1(Int32(42)))  # 0 (TypeHierS1 !== TypeHierS2)

                @test results[1] == native_s1   # typeof(s1) === TypeHierS1 → 1
                @test results[2] == native_s2   # typeof(s2) === TypeHierS2 → 1
                @test results[3] == native_cross # typeof(s1) === TypeHierS2 → 0
            end
        end

        @testset "Type hierarchy: super chain matches Julia's" begin
            mod, type_registry, _, _ = compile_module(
                [(make_th_s1, (Int32,))];
                return_registries=true)

            # Verify concrete type hierarchy
            for T in [Int32, Float64, Bool, TypeHierS1]
                haskey(type_registry.type_ids, T) || continue
                type_id = WasmTarget.get_type_id(type_registry, T)
                @test type_id > Int32(0)

                # The parent type should also have a global
                parent = supertype(T)
                @test haskey(type_registry.type_constant_globals, parent)

                # The DFS range of the parent should contain this type's ID
                parent_range = WasmTarget.get_type_range(type_registry, parent)
                if parent_range !== nothing
                    lo, hi = parent_range
                    @test lo <= type_id <= hi
                end
            end

            # Verify abstract type ranges contain concrete subtypes
            int32_id = WasmTarget.get_type_id(type_registry, Int32)
            signed_range = WasmTarget.get_type_range(type_registry, Signed)
            integer_range = WasmTarget.get_type_range(type_registry, Integer)
            number_range = WasmTarget.get_type_range(type_registry, Number)
            any_range = WasmTarget.get_type_range(type_registry, Any)

            if signed_range !== nothing
                @test signed_range[1] <= int32_id <= signed_range[2]
            end
            if integer_range !== nothing
                @test integer_range[1] <= int32_id <= integer_range[2]
            end
            if number_range !== nothing
                @test number_range[1] <= int32_id <= number_range[2]
            end
            if any_range !== nothing
                @test any_range[1] <= int32_id <= any_range[2]
            end
        end

    end

    # ========================================================================
    # Phase 37: Subtype Checking (PURE-9064)
    # ========================================================================
    @pphase "Phase 37: Subtype Checking (PURE-9064)" begin
        # helpers/subtype.jl is included at MODULE level (see top) so its defs exist
        # in an earlier world than this phase function — `include` here would define
        # them too late (world-age error under lazy-phase compilation).
        @testset "wasm_subtype compiles for concrete DataType pairs" begin
            # Test wrapper functions that call _datatype_subtype
            function ws_int_num()::Int32
                return _datatype_subtype(Int64, Number) ? Int32(1) : Int32(0)
            end
            function ws_int_str()::Int32
                return _datatype_subtype(Int64, AbstractString) ? Int32(1) : Int32(0)
            end
            function ws_int_int()::Int32
                return _datatype_subtype(Int64, Int64) ? Int32(1) : Int32(0)
            end
            function ws_f64_num()::Int32
                return _datatype_subtype(Float64, Number) ? Int32(1) : Int32(0)
            end
            function ws_int_signed()::Int32
                return _datatype_subtype(Int64, Signed) ? Int32(1) : Int32(0)
            end
            function ws_bool_int()::Int32
                return _datatype_subtype(Bool, Integer) ? Int32(1) : Int32(0)
            end

            bytes = WasmTarget.compile_multi([
                (ws_int_num, ()),
                (ws_int_str, ()),
                (ws_int_int, ()),
                (ws_f64_num, ()),
                (ws_int_signed, ()),
                (ws_bool_int, ()),
                (_datatype_subtype, (DataType, DataType)),
            ])

            @test length(bytes) > 0
            valid = try run(`$(first(NODE_CMD)) -e "1"`) !== nothing; true catch; false end
            if valid
                @test run_wasm(bytes, "ws_int_num") == 1        # Int64 <: Number
                @test run_wasm(bytes, "ws_int_str") == 0        # Int64 !<: AbstractString
                @test run_wasm(bytes, "ws_int_int") == 1        # Int64 <: Int64
                @test run_wasm(bytes, "ws_f64_num") == 1        # Float64 <: Number
                @test run_wasm(bytes, "ws_int_signed") == 1     # Int64 <: Signed
                @test run_wasm(bytes, "ws_bool_int") == 1       # Bool <: Integer
            end
        end

        @testset "SVec parameter access on DataType" begin
            function svec_len_int64()::Int32
                params = Base.getfield(Int64, :parameters)
                return Int32(Core._svec_len(params))
            end
            function svec_len_vec()::Int32
                params = Base.getfield(Vector{Int64}, :parameters)
                return Int32(Core._svec_len(params))
            end

            bytes = WasmTarget.compile_multi([
                (svec_len_int64, ()),
                (svec_len_vec, ()),
                (_datatype_subtype, (DataType, DataType)),
            ])

            @test length(bytes) > 0
            valid = try run(`$(first(NODE_CMD)) -e "1"`) !== nothing; true catch; false end
            if valid
                @test run_wasm(bytes, "svec_len_int64") == 0    # Int64.parameters is empty
                @test run_wasm(bytes, "svec_len_vec") == 2      # Vector{Int64}.parameters has 2 elements
            end
        end

        @testset "Full wasm_subtype chain compiles and validates" begin
            funcs = [
                (wasm_subtype, (DataType, DataType)),
                (_subtype, (Any, Any, SubtypeEnv, Int64)),
                (_subtype_datatypes, (DataType, DataType, SubtypeEnv, Int64)),
                (_datatype_subtype, (DataType, DataType)),
                (_forall_exists_equal, (Any, Any, SubtypeEnv)),
                (lookup, (SubtypeEnv, TypeVar)),
                (_subtype_unionall, (Any, UnionAll, SubtypeEnv, Bool, Int64)),
            ]

            bytes = WasmTarget.compile_multi(funcs)
            @test length(bytes) > 0

            # Write and validate
            tmpfile = tempname() * ".wasm"
            write(tmpfile, bytes)
            result = try read(`wasm-tools validate $tmpfile`, String); "VALID" catch e; string(e) end
            @test result == "VALID"
            rm(tmpfile; force=true)
        end

        @testset "_forall_exists_equal standalone" begin
            function test_fee_eq()::Int32
                env = SubtypeEnv()
                return _forall_exists_equal(Int64, Int64, env) ? Int32(1) : Int32(0)
            end
            function test_fee_neq()::Int32
                env = SubtypeEnv()
                return _forall_exists_equal(Int64, Number, env) ? Int32(1) : Int32(0)
            end

            funcs = [
                (test_fee_eq, ()),
                (test_fee_neq, ()),
                (_forall_exists_equal, (Any, Any, SubtypeEnv)),
                (_subtype, (Any, Any, SubtypeEnv, Int64)),
                (_subtype_datatypes, (DataType, DataType, SubtypeEnv, Int64)),
                (_datatype_subtype, (DataType, DataType)),
                (lookup, (SubtypeEnv, TypeVar)),
                (_subtype_unionall, (Any, UnionAll, SubtypeEnv, Bool, Int64)),
                (wasm_subtype, (DataType, DataType)),
            ]

            bytes = WasmTarget.compile_multi(funcs)
            @test length(bytes) > 0

            valid = try run(`$(first(NODE_CMD)) -e "1"`) !== nothing; true catch; false end
            if valid
                @test run_wasm(bytes, "test_fee_eq") == 1     # Int64 ≡ Int64 (invariant)
                @test run_wasm(bytes, "test_fee_neq") == 0    # Int64 ≢ Number (invariant)
            end
        end

        @testset "wasm_subtype ground truth: 100+ DataType pairs" begin
            # All subtype helper functions needed for wasm_subtype chain
            all_subtype_funcs = [
                (wasm_subtype, (DataType, DataType)),
                (_subtype, (Any, Any, SubtypeEnv, Int64)),
                (_subtype_datatypes, (DataType, DataType, SubtypeEnv, Int64)),
                (_datatype_subtype, (DataType, DataType)),
                (_forall_exists_equal, (Any, Any, SubtypeEnv)),
                (_tuple_subtype_env, (DataType, DataType, SubtypeEnv, Int64)),
                (_subtype_tuple_param, (Any, Any, SubtypeEnv)),
                (lookup, (SubtypeEnv, TypeVar)),
                (_var_lt, (VarBinding, Any, SubtypeEnv, Int64)),
                (_var_gt, (VarBinding, Any, SubtypeEnv, Int64)),
                (_subtype_var, (VarBinding, Any, SubtypeEnv, Bool, Int64)),
                (_record_var_occurrence, (VarBinding, SubtypeEnv, Int64)),
                (_subtype_unionall, (Any, UnionAll, SubtypeEnv, Bool, Int64)),
                (_subtype_inner, (Any, Any, SubtypeEnv, Bool, Int64)),
                (_is_leaf_bound, (Any,)),
                (_type_contains_var, (Any, TypeVar)),
            ]

            # Define wrapper functions for each subtype check (gt_ prefix = ground truth)
            # Concrete numeric types
            gt_i64_i64()::Int32 = wasm_subtype(Int64, Int64) ? Int32(1) : Int32(0)
            gt_i64_num()::Int32 = wasm_subtype(Int64, Number) ? Int32(1) : Int32(0)
            gt_i64_real()::Int32 = wasm_subtype(Int64, Real) ? Int32(1) : Int32(0)
            gt_i64_int()::Int32 = wasm_subtype(Int64, Integer) ? Int32(1) : Int32(0)
            gt_i64_signed()::Int32 = wasm_subtype(Int64, Signed) ? Int32(1) : Int32(0)
            gt_i64_unsigned()::Int32 = wasm_subtype(Int64, Unsigned) ? Int32(1) : Int32(0)
            gt_i64_absfloat()::Int32 = wasm_subtype(Int64, AbstractFloat) ? Int32(1) : Int32(0)
            gt_i64_absstr()::Int32 = wasm_subtype(Int64, AbstractString) ? Int32(1) : Int32(0)
            gt_i64_any()::Int32 = wasm_subtype(Int64, Any) ? Int32(1) : Int32(0)
            gt_i32_i32()::Int32 = wasm_subtype(Int32, Int32) ? Int32(1) : Int32(0)
            gt_i32_i64()::Int32 = wasm_subtype(Int32, Int64) ? Int32(1) : Int32(0)
            gt_i32_signed()::Int32 = wasm_subtype(Int32, Signed) ? Int32(1) : Int32(0)
            gt_i32_num()::Int32 = wasm_subtype(Int32, Number) ? Int32(1) : Int32(0)
            gt_f64_f64()::Int32 = wasm_subtype(Float64, Float64) ? Int32(1) : Int32(0)
            gt_f64_num()::Int32 = wasm_subtype(Float64, Number) ? Int32(1) : Int32(0)
            gt_f64_real()::Int32 = wasm_subtype(Float64, Real) ? Int32(1) : Int32(0)
            gt_f64_absfloat()::Int32 = wasm_subtype(Float64, AbstractFloat) ? Int32(1) : Int32(0)
            gt_f64_signed()::Int32 = wasm_subtype(Float64, Signed) ? Int32(1) : Int32(0)
            gt_f32_f32()::Int32 = wasm_subtype(Float32, Float32) ? Int32(1) : Int32(0)
            gt_f32_num()::Int32 = wasm_subtype(Float32, Number) ? Int32(1) : Int32(0)
            gt_f32_f64()::Int32 = wasm_subtype(Float32, Float64) ? Int32(1) : Int32(0)
            gt_bool_bool()::Int32 = wasm_subtype(Bool, Bool) ? Int32(1) : Int32(0)
            gt_bool_int()::Int32 = wasm_subtype(Bool, Integer) ? Int32(1) : Int32(0)
            gt_bool_num()::Int32 = wasm_subtype(Bool, Number) ? Int32(1) : Int32(0)
            gt_bool_signed()::Int32 = wasm_subtype(Bool, Signed) ? Int32(1) : Int32(0)
            gt_u64_unsigned()::Int32 = wasm_subtype(UInt64, Unsigned) ? Int32(1) : Int32(0)
            gt_u64_signed()::Int32 = wasm_subtype(UInt64, Signed) ? Int32(1) : Int32(0)
            gt_u64_num()::Int32 = wasm_subtype(UInt64, Number) ? Int32(1) : Int32(0)
            gt_u8_unsigned()::Int32 = wasm_subtype(UInt8, Unsigned) ? Int32(1) : Int32(0)
            gt_u8_num()::Int32 = wasm_subtype(UInt8, Number) ? Int32(1) : Int32(0)
            # Reverse direction (should be false for non-identity)
            gt_num_i64()::Int32 = wasm_subtype(Number, Int64) ? Int32(1) : Int32(0)
            gt_real_i64()::Int32 = wasm_subtype(Real, Int64) ? Int32(1) : Int32(0)
            gt_signed_i64()::Int32 = wasm_subtype(Signed, Int64) ? Int32(1) : Int32(0)
            gt_any_i64()::Int32 = wasm_subtype(Any, Int64) ? Int32(1) : Int32(0)
            gt_any_any()::Int32 = wasm_subtype(Any, Any) ? Int32(1) : Int32(0)
            gt_any_num()::Int32 = wasm_subtype(Any, Number) ? Int32(1) : Int32(0)
            # String types
            gt_str_str()::Int32 = wasm_subtype(String, String) ? Int32(1) : Int32(0)
            gt_str_absstr()::Int32 = wasm_subtype(String, AbstractString) ? Int32(1) : Int32(0)
            gt_str_any()::Int32 = wasm_subtype(String, Any) ? Int32(1) : Int32(0)
            gt_str_num()::Int32 = wasm_subtype(String, Number) ? Int32(1) : Int32(0)
            gt_absstr_str()::Int32 = wasm_subtype(AbstractString, String) ? Int32(1) : Int32(0)
            # Parametric types — invariant (PURE-9064)
            gt_vi64_vi64()::Int32 = wasm_subtype(Vector{Int64}, Vector{Int64}) ? Int32(1) : Int32(0)
            gt_vi64_vnum()::Int32 = wasm_subtype(Vector{Int64}, Vector{Number}) ? Int32(1) : Int32(0)
            gt_vf64_vf64()::Int32 = wasm_subtype(Vector{Float64}, Vector{Float64}) ? Int32(1) : Int32(0)
            gt_vf64_vnum()::Int32 = wasm_subtype(Vector{Float64}, Vector{Number}) ? Int32(1) : Int32(0)
            gt_vi32_vi32()::Int32 = wasm_subtype(Vector{Int32}, Vector{Int32}) ? Int32(1) : Int32(0)
            gt_vi32_vi64()::Int32 = wasm_subtype(Vector{Int32}, Vector{Int64}) ? Int32(1) : Int32(0)
            gt_di64_di64()::Int32 = wasm_subtype(Dict{String,Int64}, Dict{String,Int64}) ? Int32(1) : Int32(0)
            gt_di64_dnum()::Int32 = wasm_subtype(Dict{String,Int64}, Dict{String,Number}) ? Int32(1) : Int32(0)
            gt_pi_pi()::Int32 = wasm_subtype(Pair{Int64,Int64}, Pair{Int64,Int64}) ? Int32(1) : Int32(0)
            gt_pi_pn()::Int32 = wasm_subtype(Pair{Int64,Int64}, Pair{Int64,Number}) ? Int32(1) : Int32(0)
            # Tuple types — covariant
            gt_ti64_ti64()::Int32 = wasm_subtype(Tuple{Int64}, Tuple{Int64}) ? Int32(1) : Int32(0)
            gt_ti64_tnum()::Int32 = wasm_subtype(Tuple{Int64}, Tuple{Number}) ? Int32(1) : Int32(0)
            gt_tif_tnn()::Int32 = wasm_subtype(Tuple{Int64,Float64}, Tuple{Number,Number}) ? Int32(1) : Int32(0)
            gt_t0_t0()::Int32 = wasm_subtype(Tuple{}, Tuple{}) ? Int32(1) : Int32(0)
            gt_t1_t2()::Int32 = wasm_subtype(Tuple{Int64}, Tuple{Int64,Float64}) ? Int32(1) : Int32(0)
            gt_tf_ti()::Int32 = wasm_subtype(Tuple{Float64}, Tuple{Int64}) ? Int32(1) : Int32(0)
            # More numerics
            gt_i8_signed()::Int32 = wasm_subtype(Int8, Signed) ? Int32(1) : Int32(0)
            gt_i8_int()::Int32 = wasm_subtype(Int8, Integer) ? Int32(1) : Int32(0)
            gt_i8_num()::Int32 = wasm_subtype(Int8, Number) ? Int32(1) : Int32(0)
            gt_i8_i64()::Int32 = wasm_subtype(Int8, Int64) ? Int32(1) : Int32(0)
            gt_i16_signed()::Int32 = wasm_subtype(Int16, Signed) ? Int32(1) : Int32(0)
            gt_i16_num()::Int32 = wasm_subtype(Int16, Number) ? Int32(1) : Int32(0)
            gt_u16_unsigned()::Int32 = wasm_subtype(UInt16, Unsigned) ? Int32(1) : Int32(0)
            gt_u16_num()::Int32 = wasm_subtype(UInt16, Number) ? Int32(1) : Int32(0)
            gt_i128_signed()::Int32 = wasm_subtype(Int128, Signed) ? Int32(1) : Int32(0)
            gt_i128_num()::Int32 = wasm_subtype(Int128, Number) ? Int32(1) : Int32(0)
            gt_u128_unsigned()::Int32 = wasm_subtype(UInt128, Unsigned) ? Int32(1) : Int32(0)
            gt_f16_absfloat()::Int32 = wasm_subtype(Float16, AbstractFloat) ? Int32(1) : Int32(0)
            gt_f16_real()::Int32 = wasm_subtype(Float16, Real) ? Int32(1) : Int32(0)
            gt_f16_f64()::Int32 = wasm_subtype(Float16, Float64) ? Int32(1) : Int32(0)
            # Cross-category false
            gt_i64_str()::Int32 = wasm_subtype(Int64, String) ? Int32(1) : Int32(0)
            gt_str_i64()::Int32 = wasm_subtype(String, Int64) ? Int32(1) : Int32(0)
            gt_f64_str()::Int32 = wasm_subtype(Float64, String) ? Int32(1) : Int32(0)
            gt_bool_str()::Int32 = wasm_subtype(Bool, String) ? Int32(1) : Int32(0)
            gt_num_str()::Int32 = wasm_subtype(Number, String) ? Int32(1) : Int32(0)
            # Abstract hierarchy
            gt_signed_int()::Int32 = wasm_subtype(Signed, Integer) ? Int32(1) : Int32(0)
            gt_int_real()::Int32 = wasm_subtype(Integer, Real) ? Int32(1) : Int32(0)
            gt_real_num()::Int32 = wasm_subtype(Real, Number) ? Int32(1) : Int32(0)
            gt_num_any()::Int32 = wasm_subtype(Number, Any) ? Int32(1) : Int32(0)
            gt_unsigned_int()::Int32 = wasm_subtype(Unsigned, Integer) ? Int32(1) : Int32(0)
            gt_absfloat_real()::Int32 = wasm_subtype(AbstractFloat, Real) ? Int32(1) : Int32(0)
            gt_signed_unsigned()::Int32 = wasm_subtype(Signed, Unsigned) ? Int32(1) : Int32(0)
            gt_unsigned_signed()::Int32 = wasm_subtype(Unsigned, Signed) ? Int32(1) : Int32(0)
            gt_absfloat_int()::Int32 = wasm_subtype(AbstractFloat, Integer) ? Int32(1) : Int32(0)
            gt_int_absfloat()::Int32 = wasm_subtype(Integer, AbstractFloat) ? Int32(1) : Int32(0)
            # Nothing types
            gt_nothing_nothing()::Int32 = wasm_subtype(Nothing, Nothing) ? Int32(1) : Int32(0)
            gt_nothing_any()::Int32 = wasm_subtype(Nothing, Any) ? Int32(1) : Int32(0)
            gt_nothing_i64()::Int32 = wasm_subtype(Nothing, Int64) ? Int32(1) : Int32(0)
            gt_i64_nothing()::Int32 = wasm_subtype(Int64, Nothing) ? Int32(1) : Int32(0)
            # Type{T}
            gt_typei_typei()::Int32 = wasm_subtype(Type{Int64}, Type{Int64}) ? Int32(1) : Int32(0)
            gt_typei_typen()::Int32 = wasm_subtype(Type{Int64}, Type{Number}) ? Int32(1) : Int32(0)
            gt_typei_dt()::Int32 = wasm_subtype(Type{Int64}, DataType) ? Int32(1) : Int32(0)
            # Char type
            gt_char_char()::Int32 = wasm_subtype(Char, Char) ? Int32(1) : Int32(0)
            gt_char_any()::Int32 = wasm_subtype(Char, Any) ? Int32(1) : Int32(0)
            gt_char_num()::Int32 = wasm_subtype(Char, Number) ? Int32(1) : Int32(0)
            # More cross-type checks
            gt_absstr_any()::Int32 = wasm_subtype(AbstractString, Any) ? Int32(1) : Int32(0)
            gt_absstr_num()::Int32 = wasm_subtype(AbstractString, Number) ? Int32(1) : Int32(0)
            gt_i64_bool()::Int32 = wasm_subtype(Int64, Bool) ? Int32(1) : Int32(0)
            gt_bool_i64()::Int32 = wasm_subtype(Bool, Int64) ? Int32(1) : Int32(0)
            gt_f64_i64()::Int32 = wasm_subtype(Float64, Int64) ? Int32(1) : Int32(0)
            gt_i64_f64()::Int32 = wasm_subtype(Int64, Float64) ? Int32(1) : Int32(0)

            wrapper_funcs = [
                (gt_i64_i64, ()), (gt_i64_num, ()), (gt_i64_real, ()), (gt_i64_int, ()),
                (gt_i64_signed, ()), (gt_i64_unsigned, ()), (gt_i64_absfloat, ()),
                (gt_i64_absstr, ()), (gt_i64_any, ()),
                (gt_i32_i32, ()), (gt_i32_i64, ()), (gt_i32_signed, ()), (gt_i32_num, ()),
                (gt_f64_f64, ()), (gt_f64_num, ()), (gt_f64_real, ()), (gt_f64_absfloat, ()),
                (gt_f64_signed, ()),
                (gt_f32_f32, ()), (gt_f32_num, ()), (gt_f32_f64, ()),
                (gt_bool_bool, ()), (gt_bool_int, ()), (gt_bool_num, ()), (gt_bool_signed, ()),
                (gt_u64_unsigned, ()), (gt_u64_signed, ()), (gt_u64_num, ()),
                (gt_u8_unsigned, ()), (gt_u8_num, ()),
                (gt_num_i64, ()), (gt_real_i64, ()), (gt_signed_i64, ()),
                (gt_any_i64, ()), (gt_any_any, ()), (gt_any_num, ()),
                (gt_str_str, ()), (gt_str_absstr, ()), (gt_str_any, ()), (gt_str_num, ()),
                (gt_absstr_str, ()),
                # Parametric
                (gt_vi64_vi64, ()), (gt_vi64_vnum, ()), (gt_vf64_vf64, ()), (gt_vf64_vnum, ()),
                (gt_vi32_vi32, ()), (gt_vi32_vi64, ()),
                (gt_di64_di64, ()), (gt_di64_dnum, ()), (gt_pi_pi, ()), (gt_pi_pn, ()),
                # Tuples
                (gt_ti64_ti64, ()), (gt_ti64_tnum, ()), (gt_tif_tnn, ()), (gt_t0_t0, ()),
                (gt_t1_t2, ()), (gt_tf_ti, ()),
                # More numerics
                (gt_i8_signed, ()), (gt_i8_int, ()), (gt_i8_num, ()), (gt_i8_i64, ()),
                (gt_i16_signed, ()), (gt_i16_num, ()),
                (gt_u16_unsigned, ()), (gt_u16_num, ()),
                (gt_i128_signed, ()), (gt_i128_num, ()), (gt_u128_unsigned, ()),
                (gt_f16_absfloat, ()), (gt_f16_real, ()), (gt_f16_f64, ()),
                # Cross-category
                (gt_i64_str, ()), (gt_str_i64, ()), (gt_f64_str, ()), (gt_bool_str, ()), (gt_num_str, ()),
                # Abstract hierarchy
                (gt_signed_int, ()), (gt_int_real, ()), (gt_real_num, ()), (gt_num_any, ()),
                (gt_unsigned_int, ()), (gt_absfloat_real, ()),
                (gt_signed_unsigned, ()), (gt_unsigned_signed, ()),
                (gt_absfloat_int, ()), (gt_int_absfloat, ()),
                # Nothing
                (gt_nothing_nothing, ()), (gt_nothing_any, ()), (gt_nothing_i64, ()), (gt_i64_nothing, ()),
                # Type{T}
                (gt_typei_typei, ()), (gt_typei_typen, ()), (gt_typei_dt, ()),
                # Char
                (gt_char_char, ()), (gt_char_any, ()), (gt_char_num, ()),
                # More cross-type
                (gt_absstr_any, ()), (gt_absstr_num, ()),
                (gt_i64_bool, ()), (gt_bool_i64, ()),
                (gt_f64_i64, ()), (gt_i64_f64, ()),
            ]

            all_funcs = vcat(wrapper_funcs, all_subtype_funcs)
            bytes = WasmTarget.compile_multi(all_funcs)
            @test length(bytes) > 0

            valid = try run(`$(first(NODE_CMD)) -e "1"`) !== nothing; true catch; false end
            if valid
                # Ground truth: each test matches native Julia <:
                # Concrete numeric identity
                @test run_wasm(bytes, "gt_i64_i64") == 1      # Int64 <: Int64
                @test run_wasm(bytes, "gt_i32_i32") == 1      # Int32 <: Int32
                @test run_wasm(bytes, "gt_f64_f64") == 1      # Float64 <: Float64
                @test run_wasm(bytes, "gt_f32_f32") == 1      # Float32 <: Float32
                @test run_wasm(bytes, "gt_bool_bool") == 1    # Bool <: Bool
                # Numeric hierarchy (true)
                @test run_wasm(bytes, "gt_i64_num") == 1      # Int64 <: Number
                @test run_wasm(bytes, "gt_i64_real") == 1     # Int64 <: Real
                @test run_wasm(bytes, "gt_i64_int") == 1      # Int64 <: Integer
                @test run_wasm(bytes, "gt_i64_signed") == 1   # Int64 <: Signed
                @test run_wasm(bytes, "gt_i64_any") == 1      # Int64 <: Any
                @test run_wasm(bytes, "gt_i32_signed") == 1   # Int32 <: Signed
                @test run_wasm(bytes, "gt_i32_num") == 1      # Int32 <: Number
                @test run_wasm(bytes, "gt_f64_num") == 1      # Float64 <: Number
                @test run_wasm(bytes, "gt_f64_real") == 1     # Float64 <: Real
                @test run_wasm(bytes, "gt_f64_absfloat") == 1 # Float64 <: AbstractFloat
                @test run_wasm(bytes, "gt_f32_num") == 1      # Float32 <: Number
                @test run_wasm(bytes, "gt_bool_int") == 1     # Bool <: Integer
                @test run_wasm(bytes, "gt_bool_num") == 1     # Bool <: Number
                @test run_wasm(bytes, "gt_u64_unsigned") == 1 # UInt64 <: Unsigned
                @test run_wasm(bytes, "gt_u64_num") == 1      # UInt64 <: Number
                @test run_wasm(bytes, "gt_u8_unsigned") == 1  # UInt8 <: Unsigned
                @test run_wasm(bytes, "gt_u8_num") == 1       # UInt8 <: Number
                # Numeric hierarchy (false)
                @test run_wasm(bytes, "gt_i64_unsigned") == 0 # Int64 !<: Unsigned
                @test run_wasm(bytes, "gt_i64_absfloat") == 0 # Int64 !<: AbstractFloat
                @test run_wasm(bytes, "gt_i64_absstr") == 0   # Int64 !<: AbstractString
                @test run_wasm(bytes, "gt_i32_i64") == 0      # Int32 !<: Int64
                @test run_wasm(bytes, "gt_f64_signed") == 0   # Float64 !<: Signed
                @test run_wasm(bytes, "gt_f32_f64") == 0      # Float32 !<: Float64
                @test run_wasm(bytes, "gt_bool_signed") == 0  # Bool !<: Signed
                @test run_wasm(bytes, "gt_u64_signed") == 0   # UInt64 !<: Signed
                # Reverse direction (abstract !<: concrete)
                @test run_wasm(bytes, "gt_num_i64") == 0      # Number !<: Int64
                @test run_wasm(bytes, "gt_real_i64") == 0     # Real !<: Int64
                @test run_wasm(bytes, "gt_signed_i64") == 0   # Signed !<: Int64
                @test run_wasm(bytes, "gt_any_i64") == 0      # Any !<: Int64
                @test run_wasm(bytes, "gt_any_num") == 0      # Any !<: Number
                # Any <: Any
                @test run_wasm(bytes, "gt_any_any") == 1      # Any <: Any
                # String types
                @test run_wasm(bytes, "gt_str_str") == 1      # String <: String
                @test run_wasm(bytes, "gt_str_absstr") == 1   # String <: AbstractString — FOUND-5003: fixed Union{Type{T}} phi local allocation
                @test run_wasm(bytes, "gt_str_any") == 1      # String <: Any
                @test run_wasm(bytes, "gt_str_num") == 0      # String !<: Number
                @test run_wasm(bytes, "gt_absstr_str") == 0   # AbstractString !<: String
                # Parametric types — invariant
                @test run_wasm(bytes, "gt_vi64_vi64") == 1    # Vector{Int64} <: Vector{Int64}
                @test run_wasm(bytes, "gt_vi64_vnum") == 0    # Vector{Int64} !<: Vector{Number} (invariant!)
                @test run_wasm(bytes, "gt_vf64_vf64") == 1    # Vector{Float64} <: Vector{Float64}
                @test run_wasm(bytes, "gt_vf64_vnum") == 0    # Vector{Float64} !<: Vector{Number}
                @test run_wasm(bytes, "gt_vi32_vi32") == 1    # Vector{Int32} <: Vector{Int32}
                @test run_wasm(bytes, "gt_vi32_vi64") == 0    # Vector{Int32} !<: Vector{Int64}
                @test run_wasm(bytes, "gt_di64_di64") == 1    # Dict{String,Int64} <: Dict{String,Int64}
                @test run_wasm(bytes, "gt_di64_dnum") == 0    # Dict{String,Int64} !<: Dict{String,Number}
                @test run_wasm(bytes, "gt_pi_pi") == 1        # Pair{Int64,Int64} <: Pair{Int64,Int64}
                @test run_wasm(bytes, "gt_pi_pn") == 0        # Pair{Int64,Int64} !<: Pair{Int64,Number}
                # Tuple types — covariant
                @test run_wasm(bytes, "gt_ti64_ti64") == 1    # Tuple{Int64} <: Tuple{Int64}
                @test run_wasm(bytes, "gt_ti64_tnum") == 1    # Tuple{Int64} <: Tuple{Number} (covariant!)
                @test run_wasm(bytes, "gt_tif_tnn") == 1      # Tuple{Int64,Float64} <: Tuple{Number,Number}
                @test run_wasm(bytes, "gt_t0_t0") == 1        # Tuple{} <: Tuple{}
                @test run_wasm(bytes, "gt_t1_t2") == 0        # Tuple{Int64} !<: Tuple{Int64,Float64}
                @test run_wasm(bytes, "gt_tf_ti") == 0        # Tuple{Float64} !<: Tuple{Int64}
                # More numerics
                @test run_wasm(bytes, "gt_i8_signed") == 1    # Int8 <: Signed
                @test run_wasm(bytes, "gt_i8_int") == 1       # Int8 <: Integer
                @test run_wasm(bytes, "gt_i8_num") == 1       # Int8 <: Number
                @test run_wasm(bytes, "gt_i8_i64") == 0       # Int8 !<: Int64
                @test run_wasm(bytes, "gt_i16_signed") == 1   # Int16 <: Signed
                @test run_wasm(bytes, "gt_i16_num") == 1      # Int16 <: Number
                @test run_wasm(bytes, "gt_u16_unsigned") == 1 # UInt16 <: Unsigned
                @test run_wasm(bytes, "gt_u16_num") == 1      # UInt16 <: Number
                @test run_wasm(bytes, "gt_i128_signed") == 1  # Int128 <: Signed
                @test run_wasm(bytes, "gt_i128_num") == 1     # Int128 <: Number
                @test run_wasm(bytes, "gt_u128_unsigned") == 1 # UInt128 <: Unsigned
                @test run_wasm(bytes, "gt_f16_absfloat") == 1 # Float16 <: AbstractFloat
                @test run_wasm(bytes, "gt_f16_real") == 1     # Float16 <: Real
                @test run_wasm(bytes, "gt_f16_f64") == 0      # Float16 !<: Float64
                # Cross-category false
                @test run_wasm(bytes, "gt_i64_str") == 0      # Int64 !<: String
                @test run_wasm(bytes, "gt_str_i64") == 0      # String !<: Int64
                @test run_wasm(bytes, "gt_f64_str") == 0      # Float64 !<: String
                @test run_wasm(bytes, "gt_bool_str") == 0     # Bool !<: String
                @test run_wasm(bytes, "gt_num_str") == 0      # Number !<: String
                # Abstract hierarchy
                @test run_wasm(bytes, "gt_signed_int") == 1   # Signed <: Integer
                @test run_wasm(bytes, "gt_int_real") == 1     # Integer <: Real
                @test run_wasm(bytes, "gt_real_num") == 1     # Real <: Number — FOUND-5003: fixed Union{Type{T}} phi local allocation
                @test run_wasm(bytes, "gt_num_any") == 1      # Number <: Any
                @test run_wasm(bytes, "gt_unsigned_int") == 1 # Unsigned <: Integer
                @test run_wasm(bytes, "gt_absfloat_real") == 1 # AbstractFloat <: Real
                @test run_wasm(bytes, "gt_signed_unsigned") == 0 # Signed !<: Unsigned
                @test run_wasm(bytes, "gt_unsigned_signed") == 0 # Unsigned !<: Signed
                @test run_wasm(bytes, "gt_absfloat_int") == 0 # AbstractFloat !<: Integer
                @test run_wasm(bytes, "gt_int_absfloat") == 0 # Integer !<: AbstractFloat
                # Nothing
                @test run_wasm(bytes, "gt_nothing_nothing") == 1 # Nothing <: Nothing
                @test run_wasm(bytes, "gt_nothing_any") == 1    # Nothing <: Any
                @test run_wasm(bytes, "gt_nothing_i64") == 0    # Nothing !<: Int64
                @test run_wasm(bytes, "gt_i64_nothing") == 0    # Int64 !<: Nothing
                # Type{T}
                @test run_wasm(bytes, "gt_typei_typei") == 1  # Type{Int64} <: Type{Int64}
                @test run_wasm(bytes, "gt_typei_typen") == 0  # Type{Int64} !<: Type{Number}
                @test run_wasm(bytes, "gt_typei_dt") == 1     # Type{Int64} <: DataType
                # Char
                @test run_wasm(bytes, "gt_char_char") == 1    # Char <: Char
                @test run_wasm(bytes, "gt_char_any") == 1     # Char <: Any
                @test run_wasm(bytes, "gt_char_num") == 0     # Char !<: Number
                # More cross-type
                @test run_wasm(bytes, "gt_absstr_any") == 1   # AbstractString <: Any
                @test run_wasm(bytes, "gt_absstr_num") == 0   # AbstractString !<: Number
                @test run_wasm(bytes, "gt_i64_bool") == 0     # Int64 !<: Bool
                @test run_wasm(bytes, "gt_bool_i64") == 0     # Bool !<: Int64
                @test run_wasm(bytes, "gt_f64_i64") == 0      # Float64 !<: Int64
                @test run_wasm(bytes, "gt_i64_f64") == 0      # Int64 !<: Float64
            end
        end

    end

    # ========================================================================
    # Phase 38: Dict/Set from Base (PURE-9065)
    # ========================================================================
    @pphase "Phase 38: Dict/Set from Base (PURE-9065)" begin

        @testset "Dict{Int64,Int64} basic operations" begin
            function dict_int_create()::Int64
                d = Dict{Int64, Int64}()
                d[1] = 10
                d[2] = 20
                d[3] = 30
                return d[1] + d[2] + d[3]
            end
            bytes = compile(dict_int_create, ())
            @test bytes !== nothing
            @test run_wasm(bytes, "dict_int_create") == 60

            function dict_int_haskey()::Int64
                d = Dict{Int64, Int64}()
                d[1] = 10
                d[2] = 20
                has1 = haskey(d, 1)
                has3 = haskey(d, 3)
                len = length(d)
                return Int64(has1) * 100 + Int64(has3) * 10 + len
            end
            bytes2 = compile(dict_int_haskey, ())
            @test bytes2 !== nothing
            @test run_wasm(bytes2, "dict_int_haskey") == 102
        end

        @testset "Dict{String,Int64} operations" begin
            function dict_str_create()::Int64
                d = Dict{String, Int64}()
                d["a"] = Int64(1)
                d["b"] = Int64(2)
                return d["a"] + d["b"]
            end
            bytes = compile(dict_str_create, ())
            @test bytes !== nothing
            @test run_wasm(bytes, "dict_str_create") == 3
        end

        @testset "Dict delete!" begin
            function dict_delete_test()::Int64
                d = Dict{Int64, Int64}()
                d[1] = 10
                d[2] = 20
                d[3] = 30
                delete!(d, 2)
                len = length(d)
                has2 = haskey(d, 2)
                return len * 10 + Int64(has2)
            end
            bytes = compile(dict_delete_test, ())
            @test bytes !== nothing
            @test run_wasm(bytes, "dict_delete_test") == 20
        end

        @testset "Set{Int64} operations" begin
            function set_create_test()::Int64
                s = Set{Int64}([1, 2, 3])
                return Int64(length(s)) * 100 + Int64(2 in s) * 10 + Int64(5 in s)
            end
            bytes = compile(set_create_test, ())
            @test bytes !== nothing
            @test run_wasm(bytes, "set_create_test") == 310
        end

    end

    # Phase 39: Broadcasting (PURE-9066)
    # Tests .+, .*, .-, ./ operators on arrays
    # NOTE: previously marked broken on 1.13 — the "broadcasting IR change" was
    # actually the i32.const-32-immediate byte-misparse (gap a1b2c32const);
    # fixed in P3-batch1, green on both 1.12 and 1.13.
    @pphase "Phase 39: Broadcasting (PURE-9066)" begin

        @testset "Int32 .+ vector" begin
            function bc_add_i32()::Int32
                a = Int32[1, 2, 3]; b = Int32[4, 5, 6]; c = a .+ b
                return c[1] + c[2] + c[3]  # 5+7+9 = 21
            end
            @test compare_julia_wasm(bc_add_i32).pass
        end

        @testset "Int32 .* scalar" begin
            function bc_mul_scalar_i32()::Int32
                a = Int32[1, 2, 3]; c = a .* Int32(2)
                return c[1] + c[2] + c[3]  # 2+4+6 = 12
            end
            @test compare_julia_wasm(bc_mul_scalar_i32).pass
        end

        @testset "Int32 .- vector" begin
            function bc_sub_i32()::Int32
                a = Int32[10, 20, 30]; b = Int32[1, 2, 3]; c = a .- b
                return c[1] + c[2] + c[3]  # 9+18+27 = 54
            end
            @test compare_julia_wasm(bc_sub_i32).pass
        end

        @testset "Float64 .+ vector" begin
            function bc_add_f64()::Float64
                a = Float64[1.0, 2.0, 3.0]; b = Float64[0.5, 1.5, 2.5]; c = a .+ b
                return c[1] + c[2] + c[3]  # 1.5+3.5+5.5 = 10.5
            end
            @test compare_julia_wasm(bc_add_f64).pass
        end

        @testset "Float64 ./ scalar" begin
            function bc_div_f64()::Float64
                a = Float64[10.0, 20.0, 30.0]; c = a ./ 2.0
                return c[2]  # 10.0
            end
            @test compare_julia_wasm(bc_div_f64).pass
        end

        @testset "Int64 .+ vector" begin
            function bc_add_i64()::Int64
                a = Int64[10, 20, 30]; b = Int64[1, 2, 3]; c = a .+ b
                return c[1] + c[2] + c[3]  # 11+22+33 = 66
            end
            @test compare_julia_wasm(bc_add_i64).pass
        end

    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phases 40-45 (Self-Hosting) moved to test/selfhost/runtests.jl
    # Run separately: julia +1.12 --project=. test/selfhost/runtests.jl
    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 46: D-002 — compile_value dispatch via ref.test + field access
    # ═══════════════════════════════════════════════════════════════════════════
    @pphase "Phase 46: compile_value dispatch (D-002)" begin
        # Compile all D-002 functions together
        d002_bytes = compile_multi([
            (cv_field_dispatch, (Any,)),
            (cv_type_tag, (Any,)),
            (test_cv_ssa_field, ()),
            (test_cv_arg_field, ()),
            (test_cv_goto_field, ()),
            (test_cv_unknown_field, ()),
            (test_cv_tag_ssa, ()),
            (test_cv_tag_arg, ()),
            (test_cv_tag_goto, ()),
            (test_cv_tag_return, ()),
            (test_cv_combined_tags, ()),
        ])
        @test length(d002_bytes) > 0

        # 46a: Field access after isa-narrowing (PiNode → ref.cast → struct.get)
        @testset "Field access: SSAValue.id" begin
            result = run_wasm(d002_bytes, "test_cv_ssa_field")
            @test result == 42
        end
        @testset "Field access: Argument.n" begin
            result = run_wasm(d002_bytes, "test_cv_arg_field")
            @test result == 7
        end
        @testset "Field access: GotoNode.label" begin
            result = run_wasm(d002_bytes, "test_cv_goto_field")
            @test result == 99
        end
        @testset "Field access: unknown type fallback" begin
            result = run_wasm(d002_bytes, "test_cv_unknown_field")
            @test result == -1
        end

        # 46b: Type tag dispatch — ref.test on 7 IR node types
        @testset "Type tag: SSAValue → 1" begin
            @test run_wasm(d002_bytes, "test_cv_tag_ssa") == 1
        end
        @testset "Type tag: Argument → 2" begin
            @test run_wasm(d002_bytes, "test_cv_tag_arg") == 2
        end
        @testset "Type tag: GotoNode → 3" begin
            @test run_wasm(d002_bytes, "test_cv_tag_goto") == 3
        end
        @testset "Type tag: ReturnNode → 4" begin
            @test run_wasm(d002_bytes, "test_cv_tag_return") == 4
        end

        # 46c: Combined — cross-function dispatch with accumulation
        @testset "Combined tags: 1+2+3+4 = 10" begin
            @test run_wasm(d002_bytes, "test_cv_combined_tags") == 10
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 47: D-003 — compile_statement dispatch (ReturnNode + Expr head)
    # ═══════════════════════════════════════════════════════════════════════════
    @pphase "Phase 47: compile_statement dispatch (D-003)" begin
        d003_bytes = compile_multi([
            (cs_dispatch, (Any,)),
            (test_cs_return, ()),
            (test_cs_goto, ()),
            (test_cs_gotoifnot, ()),
            (test_cs_call_expr, ()),
            (test_cs_invoke_expr, ()),
            (test_cs_new_expr, ()),
            (test_cs_other_expr, ()),
            (test_cs_combined, ()),
        ])
        @test length(d003_bytes) > 0

        # 47a: IR node type dispatch
        @testset "ReturnNode → 1" begin
            @test run_wasm(d003_bytes, "test_cs_return") == 1
        end
        @testset "GotoNode → 2" begin
            @test run_wasm(d003_bytes, "test_cs_goto") == 2
        end
        @testset "GotoIfNot → 3" begin
            @test run_wasm(d003_bytes, "test_cs_gotoifnot") == 3
        end

        # 47b: Expr head symbol dispatch (stmt.head === :call etc.)
        @testset "Expr(:call) → 10" begin
            @test run_wasm(d003_bytes, "test_cs_call_expr") == 10
        end
        @testset "Expr(:invoke) → 11" begin
            @test run_wasm(d003_bytes, "test_cs_invoke_expr") == 11
        end
        @testset "Expr(:new) → 12" begin
            @test run_wasm(d003_bytes, "test_cs_new_expr") == 12
        end
        @testset "Expr(:boundscheck) → 19 (other)" begin
            @test run_wasm(d003_bytes, "test_cs_other_expr") == 19
        end

        # 47c: Combined statement dispatch
        @testset "Combined: 1+10+2+3 = 16" begin
            @test run_wasm(d003_bytes, "test_cs_combined") == 16
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 48: D-004 — Intrinsic dispatch (symbol name → opcode selection)
    # ═══════════════════════════════════════════════════════════════════════════
    @pphase "Phase 48: intrinsic dispatch (D-004)" begin
        d004_bytes = compile_multi([
            (intrinsic_tag, (Symbol,)),
            (test_intr_add, ()),
            (test_intr_mul, ()),
            (test_intr_sub, ()),
            (test_intr_slt, ()),
            (test_intr_unknown, ()),
            (test_combined_intrinsic, (Int64, Int64)),
        ])
        @test length(d004_bytes) > 0

        # 48a: Intrinsic name dispatch via symbol comparison
        @testset "add_int → 1" begin
            @test run_wasm(d004_bytes, "test_intr_add") == 1
        end
        @testset "mul_int → 3" begin
            @test run_wasm(d004_bytes, "test_intr_mul") == 3
        end
        @testset "sub_int → 2" begin
            @test run_wasm(d004_bytes, "test_intr_sub") == 2
        end
        @testset "slt_int → 4" begin
            @test run_wasm(d004_bytes, "test_intr_slt") == 4
        end
        @testset "unknown → 0" begin
            @test run_wasm(d004_bytes, "test_intr_unknown") == 0
        end

        # 48b: Real arithmetic intrinsics produce correct opcodes
        @testset "(5+3)*(5-3) = 16" begin
            @test run_wasm(d004_bytes, "test_combined_intrinsic", Int64(5), Int64(3)) == 16
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 49: D-005 — SSA local allocation (multi-use values)
    # ═══════════════════════════════════════════════════════════════════════════
    @pphase "Phase 49: SSA local allocation (D-005)" begin
        d005_bytes = compile_multi([
            (test_ssa_multi_use, (Int64,)),
            (test_ssa_chain, (Int64, Int64)),
            (test_ssa_nested, (Int64,)),
        ])
        @test length(d005_bytes) > 0

        @testset "multi-use: x*x + x*x, x=5 → 50" begin
            @test run_wasm(d005_bytes, "test_ssa_multi_use", Int64(5)) == 50
        end
        @testset "multi-use: x*x + x*x, x=7 → 98" begin
            @test run_wasm(d005_bytes, "test_ssa_multi_use", Int64(7)) == 98
        end
        @testset "chain: s² + d², (5,3) → 68" begin
            @test run_wasm(d005_bytes, "test_ssa_chain", Int64(5), Int64(3)) == 68
        end
        @testset "nested: (x+1)*2 + (x+1), x=5 → 18" begin
            @test run_wasm(d005_bytes, "test_ssa_nested", Int64(5)) == 18
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 50: D-006 — Control flow (if/else, loops, phi nodes)
    # ═══════════════════════════════════════════════════════════════════════════
    @pphase "Phase 50: control flow (D-006)" begin
        d006_bytes = compile_multi([
            (test_cf_if_else, (Int64,)),
            (test_cf_loop, (Int64,)),
            (test_cf_phi, (Int64,)),
            (test_cf_nested, (Int64, Int64)),
        ])
        @test length(d006_bytes) > 0

        @testset "if/else: 5 → 10 (positive branch)" begin
            @test run_wasm(d006_bytes, "test_cf_if_else", Int64(5)) == 10
        end
        @testset "if/else: -3 → 3 (negative branch)" begin
            @test run_wasm(d006_bytes, "test_cf_if_else", Int64(-3)) == 3
        end
        @testset "loop: sum(1..10) = 55" begin
            @test run_wasm(d006_bytes, "test_cf_loop", Int64(10)) == 55
        end
        @testset "loop: sum(1..0) = 0" begin
            @test run_wasm(d006_bytes, "test_cf_loop", Int64(0)) == 0
        end
        @testset "phi: 15 → 115 (>10 branch)" begin
            @test run_wasm(d006_bytes, "test_cf_phi", Int64(15)) == 115
        end
        @testset "phi: 5 → 6 (≤10 branch)" begin
            @test run_wasm(d006_bytes, "test_cf_phi", Int64(5)) == 6
        end
        @testset "nested: (3,4) → 7" begin
            @test run_wasm(d006_bytes, "test_cf_nested", Int64(3), Int64(4)) == 7
        end
        @testset "nested: (3,-4) → 7" begin
            @test run_wasm(d006_bytes, "test_cf_nested", Int64(3), Int64(-4)) == 7
        end
        @testset "nested: (-1,5) → 0" begin
            @test run_wasm(d006_bytes, "test_cf_nested", Int64(-1), Int64(5)) == 0
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 51: D-007 — WASM module assembly (multi-function, multi-type)
    # ═══════════════════════════════════════════════════════════════════════════
    @pphase "Phase 51: WASM module assembly (D-007)" begin
        d007_bytes = compile_multi([
            (d007_helper, (Int64,)),
            (d007_square_double, (Int64,)),
            (d007_sum_loop, (Int64,)),
            (d007_i32_add, (Int32, Int32)),
            (d007_f64_mul, (Float64, Float64)),
        ])
        @test length(d007_bytes) > 0
        # Valid WASM magic number
        @test d007_bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]

        @testset "cross-call: helper(5) = 10" begin
            @test run_wasm(d007_bytes, "d007_helper", Int64(5)) == 10
        end
        @testset "cross-call: square_double(4) = 32" begin
            @test run_wasm(d007_bytes, "d007_square_double", Int64(4)) == 32
        end
        @testset "cross-call in loop: sum_loop(5) = 30" begin
            @test run_wasm(d007_bytes, "d007_sum_loop", Int64(5)) == 30
        end
        @testset "i32 type: add(10,20) = 30" begin
            @test run_wasm(d007_bytes, "d007_i32_add", Int32(10), Int32(20)) == 30
        end
        @testset "f64 type: mul(2.5,4.0) = 10.0" begin
            @test run_wasm(d007_bytes, "d007_f64_mul", 2.5, 4.0) == 10.0
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 56: Playground regression suite — REMOVED
    # playground/codegen.wasm build artifact does not exist; tests were always skipped.

    # Phase 23: TF-005 Cross-function type-sharing regression tests
    @pphase "Phase 23: Cross-function Type Sharing (TF-005)" begin

        # Test 1: Simple struct create + isa across compile_multi
        @testset "TF5-1: Struct create + isa dispatch" begin
            bytes = WasmTarget.compile_multi([
                (tf5_make_alpha, (Int32,)),
                (tf5_dispatch_ab, (Union{TF5_Alpha, TF5_Beta},)),
            ])
            @test length(bytes) > 0

            # Cross-function test: make Alpha, then dispatch on it
            dir = mktempdir()
            wasm_path = joinpath(dir, "test.wasm")
            js_path = joinpath(dir, "test.mjs")
            write(wasm_path, bytes)
            write(js_path, """
import fs from 'fs';
const buf = fs.readFileSync('$(escape_string(wasm_path))');
const { instance } = await WebAssembly.instantiate(buf, { Math: { pow: Math.pow } });
const e = instance.exports;
const a = e.tf5_make_alpha(42);
const r = e.tf5_dispatch_ab(a);
console.log(JSON.stringify({result: Number(r)}));
""")
            node_cmd = NODE_CMD
            if node_cmd !== nothing
                output = strip(read(`$node_cmd $js_path`, String))
                result = JSON.parse(output)
                @test result["result"] == 142  # 42 + 100
            end
        end

        # Test 2: Struct with multiple fields + field access across functions
        @testset "TF5-2: Multi-field struct cross-function access" begin
            bytes = WasmTarget.compile_multi([
                (tf5_make_gamma, (Int32, Int64)),
                (tf5_get_gamma_x, (TF5_Gamma,)),
            ])
            @test length(bytes) > 0
        end

        # Test 3: Union{Nothing, T} pattern across functions
        @testset "TF5-3: Union{Nothing, T} cross-function" begin
            bytes = WasmTarget.compile_multi([
                (tf5_make_alpha_for_nothing, (Int32,)),
                (tf5_check_nothing, (Union{Nothing, TF5_Alpha},)),
            ])
            @test length(bytes) > 0
        end

        # Test 4: 3-type Union dispatch (THE bug that was fixed)
        @testset "TF5-4: 3-type Union dispatch (TF-004 fix)" begin
            bytes = WasmTarget.compile_multi([
                (tf5_make_alpha, (Int32,)),
                (tf5_make_beta, (Int64,)),
                (tf5_make_gamma, (Int32, Int64)),
                (tf5_dispatch_3way, (Union{TF5_Alpha, TF5_Beta, TF5_Gamma},)),
            ])
            @test length(bytes) > 0

            # Cross-function runtime test: create each type and dispatch
            dir = mktempdir()
            wasm_path = joinpath(dir, "test.wasm")
            js_path = joinpath(dir, "test.mjs")
            write(wasm_path, bytes)
            write(js_path, """
import fs from 'fs';
const buf = fs.readFileSync('$(escape_string(wasm_path))');
const { instance } = await WebAssembly.instantiate(buf, { Math: { pow: Math.pow } });
const e = instance.exports;
const a = e.tf5_make_alpha(42);
const b = e.tf5_make_beta(10n);
const g = e.tf5_make_gamma(1, 2n);
const ca = e.tf5_dispatch_3way(a);
const cb = e.tf5_dispatch_3way(b);
const cg = e.tf5_dispatch_3way(g);
const ok = Number(ca)===1 && Number(cb)===2 && Number(cg)===3;
console.log(JSON.stringify({ca:Number(ca),cb:Number(cb),cg:Number(cg),ok}));
""")
            node_cmd = NODE_CMD
            if node_cmd !== nothing
                output = strip(read(`$node_cmd $js_path`, String))
                result = JSON.parse(output)
                @test result["ok"] == true
                @test result["ca"] == 1
                @test result["cb"] == 2
                @test result["cg"] == 3
            end
        end

        # Test 5: Structurally-identical types (typeId disambiguation)
        @testset "TF5-5: Same-layout structs + typeId dispatch" begin
            bytes = WasmTarget.compile_multi([
                (tf5_make_cat, (Int32,)),
                (tf5_make_dog, (Int32,)),
                (tf5_classify_pet, (Union{TF5_Cat, TF5_Dog},)),
            ])
            @test length(bytes) > 0

            # Cross-function runtime test
            dir = mktempdir()
            wasm_path = joinpath(dir, "test.wasm")
            js_path = joinpath(dir, "test.mjs")
            write(wasm_path, bytes)
            write(js_path, """
import fs from 'fs';
const buf = fs.readFileSync('$(escape_string(wasm_path))');
const { instance } = await WebAssembly.instantiate(buf, { Math: { pow: Math.pow } });
const e = instance.exports;
const cat = e.tf5_make_cat(10);
const dog = e.tf5_make_dog(20);
const cc = e.tf5_classify_pet(cat);
const cd = e.tf5_classify_pet(dog);
const ok = Number(cc)===1 && Number(cd)===2;
console.log(JSON.stringify({cc:Number(cc),cd:Number(cd),ok}));
""")
            node_cmd = NODE_CMD
            if node_cmd !== nothing
                output = strip(read(`$node_cmd $js_path`, String))
                result = JSON.parse(output)
                @test result["ok"] == true
                @test result["cc"] == 1
                @test result["cd"] == 2
            end
        end
    end

    # Phase 24: Core IR Type Registration & Dispatch (JIB-IR001)
    # Register Core IR types (ReturnNode, GotoNode, etc.) as WasmGC structs
    # and verify isa dispatch via ref.test at runtime.

    # Maker functions for Core IR types
    function ir001_make_ssaval(id::Int64)::Core.SSAValue
        return Core.SSAValue(id)
    end
    function ir001_make_gotonode(label::Int64)::Core.GotoNode
        return Core.GotoNode(label)
    end
    function ir001_make_gotoifnot(dest::Int64)::Core.GotoIfNot
        return Core.GotoIfNot(true, dest)
    end
    function ir001_make_returnnode(v::Int64)::Core.ReturnNode
        return Core.ReturnNode(v)
    end

    # Dispatch function: isa checks on Core IR types
    function ir001_dispatch(x::Union{Core.ReturnNode, Core.GotoNode, Core.GotoIfNot, Core.SSAValue})::Int32
        if x isa Core.ReturnNode
            return Int32(1)
        elseif x isa Core.GotoNode
            return Int32(2)
        elseif x isa Core.GotoIfNot
            return Int32(3)
        elseif x isa Core.SSAValue
            return Int32(4)
        end
        return Int32(0)
    end

    @pphase "Phase 24: Core IR Type Registration (IR-001)" begin

        # Test 1: Compile Core IR maker + dispatch functions
        @testset "IR001-1: Core IR types compile and validate" begin
            bytes = WasmTarget.compile_multi([
                (ir001_make_ssaval, (Int64,)),
                (ir001_make_gotonode, (Int64,)),
                (ir001_make_gotoifnot, (Int64,)),
                (ir001_make_returnnode, (Int64,)),
                (ir001_dispatch, (Union{Core.ReturnNode, Core.GotoNode, Core.GotoIfNot, Core.SSAValue},)),
            ])
            @test length(bytes) > 0
        end

        # Test 2: WAT contains ref.test for dispatch
        @testset "IR001-2: WAT contains ref.test for IR types" begin
            bytes = WasmTarget.compile_multi([
                (ir001_make_ssaval, (Int64,)),
                (ir001_make_gotonode, (Int64,)),
                (ir001_make_gotoifnot, (Int64,)),
                (ir001_make_returnnode, (Int64,)),
                (ir001_dispatch, (Union{Core.ReturnNode, Core.GotoNode, Core.GotoIfNot, Core.SSAValue},)),
            ])
            dir = mktempdir()
            wasm_path = joinpath(dir, "ir001.wasm")
            write(wasm_path, bytes)
            wat = read(`wasm-tools print $wasm_path`, String)
            # Dispatch on 4 types produces 3 ref.test (last type is fallthrough)
            @test count("ref.test", wat) >= 3
        end

        # Test 3: Runtime dispatch via Node.js
        @testset "IR001-3: Runtime isa dispatch on Core IR types" begin
            bytes = WasmTarget.compile_multi([
                (ir001_make_ssaval, (Int64,)),
                (ir001_make_gotonode, (Int64,)),
                (ir001_make_gotoifnot, (Int64,)),
                (ir001_make_returnnode, (Int64,)),
                (ir001_dispatch, (Union{Core.ReturnNode, Core.GotoNode, Core.GotoIfNot, Core.SSAValue},)),
            ])
            dir = mktempdir()
            wasm_path = joinpath(dir, "test.wasm")
            js_path = joinpath(dir, "test.mjs")
            write(wasm_path, bytes)
            write(js_path, """
import fs from 'fs';
const buf = fs.readFileSync('$(escape_string(wasm_path))');
const { instance } = await WebAssembly.instantiate(buf, { Math: { pow: Math.pow } });
const e = instance.exports;
const rn = e.ir001_make_returnnode(99n);
const gn = e.ir001_make_gotonode(10n);
const gif = e.ir001_make_gotoifnot(5n);
const ssa = e.ir001_make_ssaval(42n);
const d_rn = e.ir001_dispatch(rn);
const d_gn = e.ir001_dispatch(gn);
const d_gif = e.ir001_dispatch(gif);
const d_ssa = e.ir001_dispatch(ssa);
console.log(JSON.stringify({
    rn: Number(d_rn), gn: Number(d_gn),
    gif: Number(d_gif), ssa: Number(d_ssa),
    ok: Number(d_rn)===1 && Number(d_gn)===2 && Number(d_gif)===3 && Number(d_ssa)===4
}));
""")
            node_cmd = NODE_CMD
            if node_cmd !== nothing
                output = strip(read(`$node_cmd $js_path`, String))
                result = JSON.parse(output)
                @test result["ok"] == true
                @test result["rn"] == 1   # ReturnNode → 1
                @test result["gn"] == 2   # GotoNode → 2
                @test result["gif"] == 3  # GotoIfNot → 3
                @test result["ssa"] == 4  # SSAValue → 4
            end
        end

        # Test 4: register_ir_types=true pre-registers all 13 Core IR types
        @testset "IR001-4: register_ir_types kwarg" begin
            bytes = WasmTarget.compile_multi([
                (ir001_make_ssaval, (Int64,)),
                (ir001_dispatch, (Union{Core.ReturnNode, Core.GotoNode, Core.GotoIfNot, Core.SSAValue},)),
            ]; register_ir_types=true)
            @test length(bytes) > 0
            # Validate the module
            dir = mktempdir()
            wasm_path = joinpath(dir, "ir001_reg.wasm")
            write(wasm_path, bytes)
            validate_output = read(`wasm-tools validate $wasm_path`, String)
            @test isempty(validate_output)
        end

        # Test 5: IR-002 — dispatch + PiNode narrowing + struct.get field access
        @testset "IR002: compile_value dispatch + field access" begin
            function ir002_make_ssaval(id::Int64)::Core.SSAValue
                return Core.SSAValue(id)
            end
            function ir002_make_argument(n::Int64)::Core.Argument
                return Core.Argument(n)
            end
            function ir002_make_gotonode(label::Int64)::Core.GotoNode
                return Core.GotoNode(label)
            end
            function ir002_dispatch_field(x::Union{Core.SSAValue, Core.Argument, Core.GotoNode})::Int64
                if x isa Core.SSAValue
                    return x.id
                elseif x isa Core.Argument
                    return x.n
                elseif x isa Core.GotoNode
                    return x.label
                end
                return Int64(0)
            end
            bytes = WasmTarget.compile_multi([
                (ir002_make_ssaval, (Int64,)),
                (ir002_make_argument, (Int64,)),
                (ir002_make_gotonode, (Int64,)),
                (ir002_dispatch_field, (Union{Core.SSAValue, Core.Argument, Core.GotoNode},)),
            ])
            @test length(bytes) > 0

            dir = mktempdir()
            wasm_path = joinpath(dir, "test.wasm")
            js_path = joinpath(dir, "test.mjs")
            write(wasm_path, bytes)
            write(js_path, """
import fs from 'fs';
const buf = fs.readFileSync('$(escape_string(wasm_path))');
const { instance } = await WebAssembly.instantiate(buf, { Math: { pow: Math.pow } });
const e = instance.exports;
const ssa = e.ir002_make_ssaval(42n);
const arg = e.ir002_make_argument(7n);
const gn = e.ir002_make_gotonode(99n);
const v_ssa = e.ir002_dispatch_field(ssa);
const v_arg = e.ir002_dispatch_field(arg);
const v_gn = e.ir002_dispatch_field(gn);
console.log(JSON.stringify({
    ssa: Number(v_ssa), arg: Number(v_arg), gn: Number(v_gn),
    ok: v_ssa===42n && v_arg===7n && v_gn===99n
}));
""")
            node_cmd = NODE_CMD
            if node_cmd !== nothing
                output = strip(read(`$node_cmd $js_path`, String))
                result = JSON.parse(output)
                @test result["ok"] == true
                @test result["ssa"] == 42  # SSAValue(42).id
                @test result["arg"] == 7   # Argument(7).n
                @test result["gn"] == 99   # GotoNode(99).label
            end
        end

        # Test 6: WAT ref.test for Expr type (5-type dispatch including Expr)
        @testset "IR001-5: Expr in isa dispatch produces ref.test" begin
            function ir001_dispatch_with_expr(x::Union{Core.ReturnNode, Core.GotoNode, Core.GotoIfNot, Core.SSAValue, Expr})::Int32
                if x isa Core.ReturnNode; return Int32(1)
                elseif x isa Core.GotoNode; return Int32(2)
                elseif x isa Core.GotoIfNot; return Int32(3)
                elseif x isa Expr; return Int32(5)
                elseif x isa Core.SSAValue; return Int32(4)
                end
                return Int32(0)
            end
            bytes = WasmTarget.compile_multi([
                (ir001_dispatch_with_expr, (Union{Core.ReturnNode, Core.GotoNode, Core.GotoIfNot, Core.SSAValue, Expr},)),
            ]; register_ir_types=true)
            @test length(bytes) > 0
            dir = mktempdir()
            wasm_path = joinpath(dir, "ir001_expr.wasm")
            write(wasm_path, bytes)
            wat = read(`wasm-tools print $wasm_path`, String)
            # 5-type dispatch produces 4 ref.test (last type is fallthrough)
            @test count("ref.test", wat) >= 4
        end

        # Test 7: IR-003 — Expr.head symbol dispatch via ===
        @testset "IR003: Expr.head symbol dispatch" begin
            function ir003_make_call_expr()::Expr
                return Expr(:call)
            end
            function ir003_make_invoke_expr()::Expr
                return Expr(:invoke)
            end
            function ir003_make_new_expr()::Expr
                return Expr(:new)
            end
            function ir003_head_dispatch(e::Expr)::Int32
                if e.head === :call
                    return Int32(10)
                elseif e.head === :invoke
                    return Int32(11)
                elseif e.head === :new
                    return Int32(12)
                end
                return Int32(0)
            end

            # Compile
            bytes = WasmTarget.compile_multi([
                (ir003_make_call_expr, ()),
                (ir003_make_invoke_expr, ()),
                (ir003_make_new_expr, ()),
                (ir003_head_dispatch, (Expr,)),
            ]; register_ir_types=true)
            @test length(bytes) > 0

            # Validate
            dir = mktempdir()
            wasm_path = joinpath(dir, "ir003.wasm")
            write(wasm_path, bytes)
            validate_output = read(`wasm-tools validate $wasm_path`, String)
            @test isempty(validate_output)

            # Runtime dispatch via Node.js
            js_path = joinpath(dir, "test.mjs")
            write(js_path, """
import fs from 'fs';
const buf = fs.readFileSync('$(escape_string(wasm_path))');
const { instance } = await WebAssembly.instantiate(buf, { Math: { pow: Math.pow } });
const e = instance.exports;
const call_expr = e.ir003_make_call_expr();
const invoke_expr = e.ir003_make_invoke_expr();
const new_expr = e.ir003_make_new_expr();
const d_call = e.ir003_head_dispatch(call_expr);
const d_invoke = e.ir003_head_dispatch(invoke_expr);
const d_new = e.ir003_head_dispatch(new_expr);
console.log(JSON.stringify({
    call: d_call, invoke: d_invoke, new_: d_new,
    ok: d_call===10 && d_invoke===11 && d_new===12
}));
""")
            node_cmd = NODE_CMD
            if node_cmd !== nothing
                output = strip(read(`$node_cmd $js_path`, String))
                result = JSON.parse(output)
                @test result["ok"] == true
                @test result["call"] == 10    # Expr(:call) → 10
                @test result["invoke"] == 11  # Expr(:invoke) → 11
                @test result["new_"] == 12    # Expr(:new) → 12
            end
        end
    end

    # ========================================================================
    # Phase 57: Stackifier / Int128 — WBUILD-1010
    # ========================================================================
    # Phases 57-59(stub): Stackifier/Int128, Transcendental Math, Extended Math — REMOVED
    # These were placeholder @test_broken false stubs with no actual tests.
    # Real math tests are in Phase 59 cont'd and Phase 60 below.

    # ========================================================================
    # Phase 59 cont'd: Power/Hypot/Cbrt — WBUILD-1021
    # ========================================================================
    @pphase "Phase 59 cont'd: Power/Hypot/Cbrt (WBUILD-1021)" begin
        @testset "Float64^Float64 (WBUILD-1021)" begin
            _t59_pow(x::Float64, y::Float64)::Float64 = x^y
            @test compare_julia_wasm(_t59_pow, 2.0, 3.0).pass
            @test compare_julia_wasm(_t59_pow, 2.0, 0.5).pass
            @test compare_julia_wasm(_t59_pow, 3.0, 2.0).pass
            @test compare_julia_wasm(_t59_pow, 10.0, 0.0).pass
            @test compare_julia_wasm(_t59_pow, 2.5, 3.5).pass
            @test compare_julia_wasm(_t59_pow, 0.5, 2.0).pass
            @test compare_julia_wasm(_t59_pow, 100.0, 0.5).pass
        end

        @testset "Float64^Int (WBUILD-1021)" begin
            _t59_powi(x::Float64, n::Int64)::Float64 = x^n
            @test compare_julia_wasm(_t59_powi, 2.0, Int64(3)).pass
            @test compare_julia_wasm(_t59_powi, 3.0, Int64(2)).pass
            @test compare_julia_wasm(_t59_powi, 0.5, Int64(4)).pass
            @test compare_julia_wasm(_t59_powi, 2.0, Int64(10)).pass
            @test compare_julia_wasm(_t59_powi, 10.0, Int64(0)).pass
        end

        @testset "hypot(Float64, Float64) (WBUILD-1021)" begin
            _t59_hypot(x::Float64, y::Float64)::Float64 = hypot(x, y)
            @test compare_julia_wasm(_t59_hypot, 3.0, 4.0).pass
            @test compare_julia_wasm(_t59_hypot, 1.0, 1.0).pass
            @test compare_julia_wasm(_t59_hypot, 0.0, 5.0).pass
            @test compare_julia_wasm(_t59_hypot, -3.0, 4.0).pass
            @test compare_julia_wasm(_t59_hypot, 1e10, 1e10).pass
        end

        @testset "cbrt(Float64) (WBUILD-1021)" begin
            _t59_cbrt(x::Float64)::Float64 = cbrt(x)
            @test compare_julia_wasm(_t59_cbrt, 8.0).pass
            @test compare_julia_wasm(_t59_cbrt, 27.0).pass
            @test compare_julia_wasm(_t59_cbrt, -8.0).pass
            @test compare_julia_wasm(_t59_cbrt, 1.0).pass
            @test compare_julia_wasm(_t59_cbrt, 0.001).pass
        end
    end

    # ========================================================================
    # Phase 59 cont'd: Utility Math — WBUILD-1022
    # ========================================================================
    @pphase "Phase 59 cont'd: Utility Math (WBUILD-1022)" begin
        @testset "sign(Float64) (WBUILD-1022)" begin
            _t59_sign(x::Float64)::Float64 = sign(x)
            @test compare_julia_wasm(_t59_sign, 1.0).pass
            @test compare_julia_wasm(_t59_sign, -1.0).pass
            @test compare_julia_wasm(_t59_sign, 0.0).pass
            @test compare_julia_wasm(_t59_sign, 100.0).pass
            @test compare_julia_wasm(_t59_sign, -0.5).pass
        end

        @testset "signbit(Float64) (WBUILD-1022)" begin
            _t59_signbit(x::Float64)::Int32 = Int32(signbit(x))
            @test compare_julia_wasm(_t59_signbit, 1.0).pass
            @test compare_julia_wasm(_t59_signbit, -1.0).pass
            @test compare_julia_wasm(_t59_signbit, 0.0).pass
            @test compare_julia_wasm(_t59_signbit, -0.0).pass
            @test compare_julia_wasm(_t59_signbit, 100.0).pass
        end

        @testset "copysign(Float64) (WBUILD-1022)" begin
            _t59_copysign(x::Float64, y::Float64)::Float64 = copysign(x, y)
            @test compare_julia_wasm(_t59_copysign, 1.0, -1.0).pass
            @test compare_julia_wasm(_t59_copysign, -1.0, 1.0).pass
            @test compare_julia_wasm(_t59_copysign, 3.0, -2.0).pass
            @test compare_julia_wasm(_t59_copysign, 0.0, -1.0).pass
            @test compare_julia_wasm(_t59_copysign, 5.0, 5.0).pass
        end

        @testset "mod(Float64) (WBUILD-1022)" begin
            _t59_mod(x::Float64, y::Float64)::Float64 = mod(x, y)
            @test compare_julia_wasm(_t59_mod, 7.0, 3.0).pass
            @test compare_julia_wasm(_t59_mod, -7.0, 3.0).pass
            @test compare_julia_wasm(_t59_mod, 7.0, -3.0).pass
            @test compare_julia_wasm(_t59_mod, 10.0, 2.5).pass
            @test compare_julia_wasm(_t59_mod, 1.5, 0.7).pass
        end

        @testset "rem(Float64) (WBUILD-1022)" begin
            _t59_rem(x::Float64, y::Float64)::Float64 = rem(x, y)
            @test compare_julia_wasm(_t59_rem, 7.0, 3.0).pass
            @test compare_julia_wasm(_t59_rem, -7.0, 3.0).pass
            @test compare_julia_wasm(_t59_rem, 7.0, -3.0).pass
            @test compare_julia_wasm(_t59_rem, 10.0, 2.5).pass
            @test compare_julia_wasm(_t59_rem, 1.5, 0.7).pass
        end

        @testset "clamp(Float64) (WBUILD-1022)" begin
            _t59_clamp(x::Float64)::Float64 = clamp(x, -1.0, 1.0)
            @test compare_julia_wasm(_t59_clamp, -2.0).pass
            @test compare_julia_wasm(_t59_clamp, -0.5).pass
            @test compare_julia_wasm(_t59_clamp, 0.0).pass
            @test compare_julia_wasm(_t59_clamp, 0.5).pass
            @test compare_julia_wasm(_t59_clamp, 2.0).pass
        end
    end

    # ========================================================================
    # Phase 59 cont'd: NaN/Inf/Subnormal Edge Cases — WBUILD-1023
    # ========================================================================
    @pphase "Phase 59 cont'd: NaN/Inf/Subnormal (WBUILD-1023)" begin
        @testset "NaN propagation (WBUILD-1023)" begin
            # NaN == NaN is false in IEEE 754, so wrap with isnan check
            _t59_isnan_sin(x::Float64)::Int32 = Int32(isnan(sin(x)))
            @test compare_julia_wasm(_t59_isnan_sin, NaN).pass

            _t59_isnan_exp(x::Float64)::Int32 = Int32(isnan(exp(x)))
            @test compare_julia_wasm(_t59_isnan_exp, NaN).pass

            _t59_isnan_log(x::Float64)::Int32 = Int32(isnan(log(x)))
            @test compare_julia_wasm(_t59_isnan_log, NaN).pass

            _t59_isnan_sqrt(x::Float64)::Int32 = Int32(isnan(sqrt(x)))
            @test compare_julia_wasm(_t59_isnan_sqrt, NaN).pass
            # sqrt(-1.0) throws DomainError in Julia (not NaN), so not testable via compare_julia_wasm

            _t59_isnan_pow(x::Float64, y::Float64)::Int32 = Int32(isnan(x^y))
            @test compare_julia_wasm(_t59_isnan_pow, NaN, 2.0).pass
            @test compare_julia_wasm(_t59_isnan_pow, 2.0, NaN).pass
        end

        @testset "Inf handling (WBUILD-1023)" begin
            # JSON can't serialize Infinity, so use isinf/sign wrappers
            _t59_isinf_div(x::Float64, y::Float64)::Int32 = Int32(isinf(x / y))
            @test compare_julia_wasm(_t59_isinf_div, 1.0, 0.0).pass   # 1/0 = Inf
            @test compare_julia_wasm(_t59_isinf_div, -1.0, 0.0).pass  # -1/0 = -Inf

            _t59_isnan_div(x::Float64, y::Float64)::Int32 = Int32(isnan(x / y))
            @test compare_julia_wasm(_t59_isnan_div, 0.0, 0.0).pass   # 0/0 = NaN

            # Sign of Inf: 1/0 should be positive, -1/0 should be negative
            _t59_sign_div(x::Float64, y::Float64)::Float64 = sign(x / y)
            @test compare_julia_wasm(_t59_sign_div, 1.0, 0.0).pass
            @test compare_julia_wasm(_t59_sign_div, -1.0, 0.0).pass

            # exp(large) = Inf, exp(-large) ≈ 0, log(0) = -Inf
            # Note: sin(Inf) throws DomainError in Julia, not testable via compare_julia_wasm
            _t59_isinf_exp(x::Float64)::Int32 = Int32(isinf(exp(x)))
            @test compare_julia_wasm(_t59_isinf_exp, 1000.0).pass    # exp(1000) = Inf

            _t59_exp_neginf(x::Float64)::Float64 = exp(-x * x)
            @test compare_julia_wasm(_t59_exp_neginf, 100.0).pass    # exp(-10000) ≈ 0

            _t59_isinf_log(x::Float64)::Int32 = Int32(isinf(log(x)))
            @test compare_julia_wasm(_t59_isinf_log, 0.0).pass       # log(0) = -Inf (doesn't throw in Julia for 0.0)
        end

        @testset "Subnormal inputs (WBUILD-1023)" begin
            # Smallest subnormal: 5e-324
            sub = 5.0e-324

            _t59_sin(x::Float64)::Float64 = sin(x)
            @test compare_julia_wasm(_t59_sin, sub).pass

            _t59_exp(x::Float64)::Float64 = exp(x)
            @test compare_julia_wasm(_t59_exp, sub).pass

            _t59_sqrt(x::Float64)::Float64 = sqrt(x)
            @test compare_julia_wasm(_t59_sqrt, sub).pass

            _t59_abs(x::Float64)::Float64 = abs(x)
            @test compare_julia_wasm(_t59_abs, sub).pass

            _t59_cos(x::Float64)::Float64 = cos(x)
            @test compare_julia_wasm(_t59_cos, sub).pass

            # Small but not subnormal
            _t59_log(x::Float64)::Float64 = log(x)
            @test compare_julia_wasm(_t59_log, 1e-300).pass
        end

        @testset "Zero edge cases (WBUILD-1023)" begin
            _t59_sin(x::Float64)::Float64 = sin(x)
            @test compare_julia_wasm(_t59_sin, 0.0).pass
            @test compare_julia_wasm(_t59_sin, -0.0).pass

            _t59_cos(x::Float64)::Float64 = cos(x)
            @test compare_julia_wasm(_t59_cos, 0.0).pass

            _t59_exp(x::Float64)::Float64 = exp(x)
            @test compare_julia_wasm(_t59_exp, 0.0).pass

            _t59_sqrt(x::Float64)::Float64 = sqrt(x)
            @test compare_julia_wasm(_t59_sqrt, 0.0).pass
        end
    end

    # ========================================================================
    # Phase 60: Full Base.Math Coverage — WBUILD-1024
    # ========================================================================
    @pphase "Phase 60: Base.Math Coverage (WBUILD-1024)" begin

        # Degree-based trig (WBUILD-1024) — REMOVED (placeholder @test_broken false stub)

        @testset "Pi-based trig (WBUILD-1024)" begin
            _t60_sinpi(x::Float64)::Float64 = sinpi(x)
            @test compare_julia_wasm(_t60_sinpi, 0.0).pass
            @test compare_julia_wasm(_t60_sinpi, 0.25).pass
            @test compare_julia_wasm(_t60_sinpi, 0.5).pass
            @test compare_julia_wasm(_t60_sinpi, 1.0).pass
            @test compare_julia_wasm(_t60_sinpi, -0.5).pass

            _t60_cospi(x::Float64)::Float64 = cospi(x)
            @test compare_julia_wasm(_t60_cospi, 0.0).pass
            @test compare_julia_wasm(_t60_cospi, 0.25).pass
            @test compare_julia_wasm(_t60_cospi, 0.5).pass
            @test compare_julia_wasm(_t60_cospi, 1.0).pass
            @test compare_julia_wasm(_t60_cospi, -0.5).pass

            _t60_tanpi(x::Float64)::Float64 = tanpi(x)
            @test compare_julia_wasm(_t60_tanpi, 0.0).pass
            @test compare_julia_wasm(_t60_tanpi, 0.25).pass
            @test compare_julia_wasm(_t60_tanpi, -0.25).pass
            @test compare_julia_wasm(_t60_tanpi, 0.125).pass
        end

        @testset "Hyperbolic sinh/cosh/tanh (WASMTARGET-FUZZ)" begin
            # Base sinh/cosh/tanh were value-stubs (no codegen) — hypot(Inf, sinh(x))
            # failed to validate. Overlays: cosh exact; sinh Taylor (|x|<0.35) else
            # exp-based with an overflow-safe eᵃ/2 for |x|>20; tanh = sinh/cosh (±1 for |x|>20).
            # These use a *different* algorithm than Base (exp-based), so compare within
            # the differential tolerance (rtol=1e-9) rather than bit-exact `==`.
            _t60_sinh(x::Float64)::Float64 = sinh(x)
            _t60_cosh(x::Float64)::Float64 = cosh(x)
            _t60_tanh(x::Float64)::Float64 = tanh(x)
            _hyp_close(f, x) = (r = compare_julia_wasm(f, x);
                !r.skipped && isapprox(r.expected, r.actual; rtol=1e-9, atol=1e-12))
            for x in (0.0, 0.34, 0.35, 0.5, 1.0, -1.0, 2.0, -2.0, 5.0, 20.0, 21.0,
                      30.0, 710.0, 1e-8, 1e-300)
                @test _hyp_close(_t60_sinh, x)
                @test _hyp_close(_t60_cosh, x)
                @test _hyp_close(_t60_tanh, x)
            end
            # saturation / specials via Bool wrappers (bit-exact ⇒ plain `.pass`)
            _t60_sinh_pinf(x::Float64)::Bool = isinf(sinh(x)) && sinh(x) > 0.0
            _t60_cosh_inf(x::Float64)::Bool  = isinf(cosh(x))
            _t60_tanh_one(x::Float64)::Bool  = tanh(x) == 1.0
            _t60_tanh_nan(x::Float64)::Bool  = isnan(tanh(x))
            @test compare_julia_wasm(_t60_sinh_pinf, Inf).pass
            @test compare_julia_wasm(_t60_cosh_inf, -Inf).pass
            @test compare_julia_wasm(_t60_tanh_one, Inf).pass
            @test compare_julia_wasm(_t60_tanh_nan, NaN).pass
            # Float32 redirect
            _t60_sinh32(x::Float32)::Float32 = sinh(x)
            @test _hyp_close(_t60_sinh32, 1.0f0)
        end

        @testset "Numeric-struct field struct.new/struct.get (WASMTARGET-FUZZ)" begin
            # `<: Number` STRUCTS (Complex, Rational, RGB{N0f8}) are classified
            # non-struct by is_struct_type, so get_concrete_wasm_type types them
            # `structref` as params / bridge-ctor args — while the struct registry
            # uses the concrete type. Without ref.cast bridges this mismatches at
            #   struct.new[k] expected (ref null T) found local.get of type structref
            # (PI bridge ctors: RGB{N0f8} pixels, fractals Complex labels) and at
            #   struct.get expected (ref null T) found structref
            # (Base `show(::Complex)` reads z.re/z.im off a structref param).
            # Base-only repro: Complex{Rational{Int64}} — its fields are themselves
            # `<: Real` structs, so the ctor arg / field type is a concrete struct ref.
            _mk_crat(re::Rational{Int64}, im::Rational{Int64}) = Complex{Rational{Int64}}(re, im)
            @test (WasmTarget.compile_multi(
                Any[(_mk_crat, (Rational{Int64}, Rational{Int64}), "_mk_crat")];
                validate=true, optimize=false); true)            # struct.new field cast
            _re_num(z::Complex{Rational{Int64}})::Int64 = numerator(real(z))
            @test (WasmTarget.compile_multi(
                Any[(_re_num, (Complex{Rational{Int64}},), "_re_num")];
                validate=true, optimize=false); true)            # struct.get on structref param
        end

        @testset "Int128/UInt128 struct field registration (WASMTARGET-FUZZ)" begin
            # _register_struct_type_impl! lacked the Int128/UInt128 → int128 struct
            # ref branch that register_tuple_type! has, so a struct holding a 128-bit
            # field hit the isprimitivetype size check and errored ("Primitive type
            # too large for Wasm field: Int128"). Surfaced by WasmMakie canvas render
            # structs (turtles/conv1d/conv2d/newton figures carry a 128-bit field).
            # Guard validates registration + struct.new/struct.get of the field's
            # sibling; Int128 *arithmetic* on the field is a separate op gap.
            _mk_i128(a::Int64)::Int64 = _WTI128Box(Int128(a), a).n
            @test (WasmTarget.compile_multi(Any[(_mk_i128, (Int64,), "_mk_i128")];
                validate=true, optimize=false); true)
            _mk_u128(a::Int64)::Int64 = _WTU128Box(UInt128(a), a).n
            @test (WasmTarget.compile_multi(Any[(_mk_u128, (Int64,), "_mk_u128")];
                validate=true, optimize=false); true)
        end

        @testset "Tagged-union Float member round-trip (WASMTARGET-FUZZ)" begin
            # emit_wrap_union_value used to DROP a Float member and store null (silent
            # data loss); emit_unwrap_union_value had no F64/F32 branch (validation
            # failure: anyref value field → f64 consumer). Both now box/unbox the float
            # via a {typeId,value} numeric box. Surfaced by Base.print_to_string's
            # Union formatting state (WasmMakie canvas axis ticks).
            @test compare_julia_wasm(_wt_uf, Int64(5)).pass     # Float64 member: 11
            @test compare_julia_wasm(_wt_uf, Int64(-3)).pass    # String member: -1
            @test compare_julia_wasm(_wt_uf32, Int64(4)).pass   # Float32 member: 6
            @test compare_julia_wasm(_wt_uf32, Int64(-1)).pass  # Int64 member: -7
        end

        @testset "string(::Complex) runs byte-exact (overlay, WASMTARGET-FUZZ)" begin
            # gap cfd419793b0d (fractals "0.9 + 0.4im" label): the string(::Complex)
            # OVERLAY byte-assembles string(real) + " + "/" - " + string(|imag|) +
            # ["*"] + "im", mirroring Base.show(::Complex) EXACTLY but bypassing the
            # unsupported Base IOBuffer string-building path (empty IOBuffer() → null
            # .data array → trap; jl_string_ptr/jl_string_to_genericmemory memmove +
            # take! stubs). Scalars (len / codeunit) so the default harness execs
            # WITHOUT js-string; the full byte-exact differential across edge cases
            # (negative imag, Inf/NaN → "*im", integer-valued) is in the fuzz bridge.
            _wt_scplx_len(x::Int64)::Int64 = Int64(ncodeunits(string(complex(0.9, 0.4 + Float64(x)))))
            _wt_scplx_cu(x::Int64)::Int64  = Int64(codeunit(string(complex(0.9, 0.4 + Float64(x))), 1 + x))
            @test compare_julia_wasm(_wt_scplx_len, Int64(0)).pass   # len("0.9 + 0.4im") = 11
            @test compare_julia_wasm(_wt_scplx_cu,  Int64(0)).pass   # byte 1 = '0'
            @test compare_julia_wasm(_wt_scplx_cu,  Int64(4)).pass   # byte 5 = '+'
            @test compare_julia_wasm(_wt_scplx_cu,  Int64(9)).pass   # byte 10 = 'i'
            @test (WasmTarget.compile_multi(Any[(_wt_scplx_len, (Int64,), "_wt_scplx_len")];
                validate=true, optimize=false); true)
        end

        @testset "Snapshot.jl fractals island — full String via bridge (WASMTARGET-INTEGRATION)" begin
            # Robust in-WT integration fixture for the Snapshot.jl fractals island
            # (@bind c ComplexNumberPicker(default=.9+.4im)): the island reactively
            # computes c = t(point.x) - im*t(point.y), t(x)=(x-150)/120, and renders
            # string(c) — the "0.9 + 0.4im" label the island survey flagged as wasm "".
            # Uses compare_julia_wasm_bridge (the in-package bit-exact WasmTarget.Bridge,
            # the SAME transport PI uses) so the FULL String return is decoded + compared
            # byte-for-byte — not a scalar proxy. Previously impossible in WT's unit suite:
            # the plain harness JSON.stringifies a WasmGC array ref to "undefined". This is
            # the real fractals cell, exercising Float64 arith + complex() + string(::Complex).
            _wt_pi_fractals_clabel(px::Float64, py::Float64)::String =
                string(complex((px - 150.0) / 120.0, -((py - 150.0) / 120.0)))
            @test compare_julia_wasm_bridge(_wt_pi_fractals_clabel, 258.0, 102.0; rettype=String).pass  # default → "0.9 + 0.4im"
            @test compare_julia_wasm_bridge(_wt_pi_fractals_clabel, 270.0,  30.0; rettype=String).pass  # "1.0 + 1.0im"
            @test compare_julia_wasm_bridge(_wt_pi_fractals_clabel, 150.0, 270.0; rettype=String).pass  # negative imag → " - "
        end

        @testset "Snapshot.jl island fixtures — status-locked corpus (WASMTARGET-INTEGRATION)" begin
            # Real PI featured-corpus island cells (harvested by Snapshot.jl/tools/
            # harvest_wt_fixtures.jl → test/integration/snapshot_island_fixtures.json), each
            # tested DIRECTLY against WT codegen via the in-package bridge. A per-piece
            # status LOCK (snapshot_island_status.json) makes BOTH regressions (green→fail) and
            # newly-fixed pieces (fail→green) trip the suite — so every PI binding is
            # tracked, passing or failing. The loop's product KPI is "PI pieces green:
            # N/total". To update after a (re-)harvest or codegen fix that flips a piece:
            # `julia --project=. test/integration/regen_snapshot_lock.jl` and commit the lock.
            # Node-gated (skips cleanly when the wasm runner is unavailable).
            if WasmRunner.runner_available() && isfile(SNAP_FIX)
                statuses = pi_all_statuses()
                @test !isempty(statuses)
                lock = isfile(SNAP_LOCK) ? JSON.parsefile(SNAP_LOCK) : Dict{String,Any}()
                @info "Snapshot.jl island fixtures" total=length(statuses) green=count(s -> s.status == "green", statuses)
                for s in statuses
                    rec = get(lock, s.key, nothing)
                    if rec === nothing
                        @warn "PI island piece missing from lock — run test/integration/regen_snapshot_lock.jl" key = s.key status = s.status
                        @test false
                    else
                        _ok = s.status == rec["status"]
                        _ok || @warn "PI island piece status FLIP" key = s.key live = s.status locked = rec["status"] detail = s.detail
                        # The lock (snapshot_island_status.json) is generated on the stable
                        # release Julia (1.12). On a moving prerelease (~1.13.0-rc) a few
                        # pieces legitimately classify differently; that shouldn't redden
                        # CI on the unstable target. Enforce strictly on stable, tolerate
                        # flips on prerelease (regen the lock once 1.13 ships stable).
                        if _ok || VERSION < v"1.13-"
                            @test _ok
                        else
                            @test_broken _ok
                        end
                    end
                end
            end
        end

        @testset "Int128 arithmetic right shift (WASMTARGET-FUZZ)" begin
            # emit_int128_ashr: ashr_int gained the is_128bit branch (was missing,
            # unlike shl_int/lshr_int) → signed Int128 >> now sign-fills correctly
            # instead of i64.shr_s on the struct ref. (WasmMakie TwicePrecision
            # range/tick widemul path; canvas figures now validate.)
            @test compare_julia_wasm(_wt_i128ashr_big, Int64(123456789)).pass
            @test compare_julia_wasm(_wt_i128ashr_big, Int64(-987654321)).pass
            @test compare_julia_wasm(_wt_i128ashr_neg, Int64(123456789)).pass
            @test compare_julia_wasm(_wt_i128ashr_neg, Int64(-987654321)).pass
        end

        @testset "Heterogeneous tuple runtime-index → tagged union (WASMTARGET-FUZZ)" begin
            # getfield(::Tuple{A,B,…}, i::Int) with a runtime i → Union{A,B,…} tagged
            # union (only homogeneous tuples were supported; heterogeneous emitted
            # `unreachable`). Plus get_concrete_wasm_type ↔ julia_to_wasm_type_concrete
            # union-rep agreement — else the final SSA store sees a false type mismatch,
            # DROPs the value and substitutes ref.null → null deref. Underlies `Any[…]`
            # construction and md"…$x…$y…" interpolation (Basic-mathematics `:n` cell).
            @test compare_julia_wasm(_wt_htup, Int64(7)).pass        # 7+12+17 = 36
            @test compare_julia_wasm(_wt_htup, Int64(0)).pass        # 0+5+10 = 15
            @test compare_julia_wasm(_wt_anyvec_len, Int64(3)).pass  # length(Any[3,"x",3]) = 3
            # all-struct element union → StructRef canonical rep (not tagged union)
            @test compare_julia_wasm(_wt_anystruct, Int64(5)).pass   # 6+7+16 = 29
            @test compare_julia_wasm(_wt_anystruct, Int64(2)).pass
            # Loop B/B1: an AnyRef-union (Union{Int64,Float64}) Int64 field ≥ 2^40 was
            # i31-TRUNCATED → returned -1; now full-width numeric box → 2^40+7 exactly.
            @test compare_julia_wasm(_wt_htup_i64f64_big, Int64(1)).pass  # = (1<<40)+7
            # Loop B/F-ii: same-wasm-rep Union (Bool/Int8/Int32 all i32) — collapsed local
            # made every isa match the first branch; now boxed w/ real classId + classId-read.
            @test compare_julia_wasm(_wt_htup_disc, Int64(1)).pass  # Bool  → 1
            @test compare_julia_wasm(_wt_htup_disc, Int64(2)).pass  # Int8  → 2
            @test compare_julia_wasm(_wt_htup_disc, Int64(3)).pass  # Int32 → 3
            # Loop B/B4: same-wasm-rep Vector{Any} — Bool/Int8 were i31'd (no classId) so isa
            # → 0; i31 removed, now they box w/ real classId + distinguish.
            @test compare_julia_wasm(_wt_vany_disc, Int64(1)).pass  # Bool  → 1
            @test compare_julia_wasm(_wt_vany_disc, Int64(2)).pass  # Int8  → 2
            @test compare_julia_wasm(_wt_vany_disc, Int64(3)).pass  # Int32 → 3
            # Loop B/B4c: Char (i32-rep, NOT <:Number) — boxing + isa now key on the numeric
            # wasm rep, so Char boxes w/ its classId + distinguishes from Int32.
            @test compare_julia_wasm(_wt_char_disc, Int64(1)).pass  # Char  → 1
            @test compare_julia_wasm(_wt_char_disc, Int64(2)).pass  # Int32 → 2
            # Loop B/B4e: mixed-WIDTH numeric union (Int64 i64 vs Bool i32) was INVALID WASM
            # (if/else read different-width fields under one block result); now boxed → compiles.
            @test compare_julia_wasm(_wt_htup_mixwidth, Int64(1)).pass  # Int64 → 99
            @test compare_julia_wasm(_wt_htup_mixwidth, Int64(2)).pass  # Bool  → -1
            # Loop B/B4b: boxed-=== was a SILENT WRONG ANSWER (Any[true][1] === true → false);
            # now classId+value compare → correct, incl. different-type === false.
            @test compare_julia_wasm(_wt_egal_boxed, Int64(5)).pass      # a[1]=true === true → 1
            @test compare_julia_wasm(_wt_egal_boxed, Int64(-5)).pass     # a[1]=false === false → 2
            @test compare_julia_wasm(_wt_egal_difftype, Int64(5)).pass   # boxed Bool === Int32 → 0
        end

        @testset "packed i8/i16 array representation" begin
            @test compare_julia_wasm(_wt_packed_i8).pass
            @test compare_julia_wasm(_wt_packed_u8).pass
            @test compare_julia_wasm(_wt_packed_i16).pass
            @test compare_julia_wasm(_wt_packed_u16).pass
        end

        @testset "runtime-length flat function composition" begin
            for opt in (false, true)
                @test compare_julia_wasm(_wt_runtime_compose, Int64(2), Int64(1); optimize=opt).pass
                @test compare_julia_wasm(_wt_runtime_compose, Int64(2), Int64(2); optimize=opt).pass
                @test compare_julia_wasm(_wt_runtime_compose, Int64(2), Int64(4); optimize=opt).pass
                @test compare_julia_wasm(_wt_runtime_compose_escape, Int64(2), Int64(4); optimize=opt).pass
                @test compare_julia_wasm(_wt_runtime_compose_mixed, Int64(2), Int64(4), Int64(1); optimize=opt).pass
                @test compare_julia_wasm(_wt_runtime_compose_mixed, Int64(2), Int64(4), Int64(2); optimize=opt).pass
            end
        end

        @testset "Inline typeId dynamic dispatch (WASMTARGET-FUZZ)" begin
            # `dynamic` call over >4 methods: trim collection discovers the
            # concrete-struct specializations, call site emits a typeId switch.
            # GATED: the discovery is off by default (perturbs base inference); enable
            # it for this self-contained struct-only case (no string deps to perturb).
            _prev_dd = get(ENV, "WT_DYNDISPATCH", nothing)
            ENV["WT_DYNDISPATCH"] = "1"
            try
                @test compare_julia_wasm(_wt_dyndispatch, Int64(5)).pass   # 6+8+10 = 24
                @test compare_julia_wasm(_wt_dyndispatch, Int64(0)).pass   # 1+3+5 = 9
            finally
                _prev_dd === nothing ? delete!(ENV, "WT_DYNDISPATCH") : (ENV["WT_DYNDISPATCH"] = _prev_dd)
            end
        end

        @testset "Abstract ::Vector struct field (WASMTARGET-FUZZ)" begin
            # An abstract/UnionAll `::Vector` field (Markdown.Admonition.content) maps to
            # AnyRef — a Vector{T} value is a vector-STRUCT with no shared supertype, so
            # the old raw-array field type mismatched at struct.new (`expected (ref
            # $rawarray), found (ref $Vector{T}-struct)`).
            @test compare_julia_wasm(_wt_absvecfield, Int64(5)).pass   # length = 3
            @test compare_julia_wasm(_wt_absvecfield, Int64(0)).pass
        end

        # Cofunctions, Hyperbolic inverse, Other inverse trig, Hyperbolic cofunctions
        # — REMOVED (placeholder @test_broken false stubs)

        @testset "Special functions (WBUILD-1024)" begin
            _t60_sinc(x::Float64)::Float64 = sinc(x)
            @test compare_julia_wasm(_t60_sinc, 0.0).pass
            @test compare_julia_wasm(_t60_sinc, 0.5).pass
            @test compare_julia_wasm(_t60_sinc, 1.0).pass
            @test compare_julia_wasm(_t60_sinc, -1.0).pass
            @test compare_julia_wasm(_t60_sinc, 3.14).pass

            _t60_cosc(x::Float64)::Float64 = cosc(x)
            @test compare_julia_wasm(_t60_cosc, 0.5).pass
            @test compare_julia_wasm(_t60_cosc, 1.0).pass
            @test compare_julia_wasm(_t60_cosc, -1.0).pass
            @test compare_julia_wasm(_t60_cosc, 3.14).pass

            _t60_sincos_s(x::Float64)::Float64 = sincos(x)[1]
            @test compare_julia_wasm(_t60_sincos_s, 0.0).pass  # WASM execution error
            @test compare_julia_wasm(_t60_sincos_s, 1.0).pass
            @test compare_julia_wasm(_t60_sincos_s, Float64(pi)/4).pass

            _t60_sincos_c(x::Float64)::Float64 = sincos(x)[2]
            @test compare_julia_wasm(_t60_sincos_c, 0.0).pass  # WASM execution error
            @test compare_julia_wasm(_t60_sincos_c, 1.0).pass
            @test compare_julia_wasm(_t60_sincos_c, Float64(pi)/4).pass

            _t60_modf_f(x::Float64)::Float64 = modf(x)[1]
            @test compare_julia_wasm(_t60_modf_f, 3.7).pass
            @test compare_julia_wasm(_t60_modf_f, -2.3).pass
            @test compare_julia_wasm(_t60_modf_f, 0.0).pass

            _t60_modf_i(x::Float64)::Float64 = modf(x)[2]
            @test compare_julia_wasm(_t60_modf_i, 3.7).pass
            @test compare_julia_wasm(_t60_modf_i, -2.3).pass
            @test compare_julia_wasm(_t60_modf_i, 0.0).pass
        end

        @testset "Conversions and utility (WBUILD-1024)" begin
            _t60_deg2rad(x::Float64)::Float64 = deg2rad(x)
            @test compare_julia_wasm(_t60_deg2rad, 0.0).pass
            @test compare_julia_wasm(_t60_deg2rad, 90.0).pass
            @test compare_julia_wasm(_t60_deg2rad, 180.0).pass
            @test compare_julia_wasm(_t60_deg2rad, 360.0).pass
            @test compare_julia_wasm(_t60_deg2rad, -45.0).pass

            _t60_rad2deg(x::Float64)::Float64 = rad2deg(x)
            @test compare_julia_wasm(_t60_rad2deg, 0.0).pass
            @test compare_julia_wasm(_t60_rad2deg, 1.5708).pass
            @test compare_julia_wasm(_t60_rad2deg, 3.14159).pass
            @test compare_julia_wasm(_t60_rad2deg, 6.28318).pass
            @test compare_julia_wasm(_t60_rad2deg, -0.7854).pass

            _t60_fourthroot(x::Float64)::Float64 = fourthroot(x)
            @test compare_julia_wasm(_t60_fourthroot, 0.0).pass
            @test compare_julia_wasm(_t60_fourthroot, 1.0).pass
            @test compare_julia_wasm(_t60_fourthroot, 16.0).pass
            @test compare_julia_wasm(_t60_fourthroot, 81.0).pass
            @test compare_julia_wasm(_t60_fourthroot, 256.0).pass

            _t60_mod2pi(x::Float64)::Float64 = mod2pi(x)
            @test compare_julia_wasm(_t60_mod2pi, 0.0).pass
            @test compare_julia_wasm(_t60_mod2pi, 3.14).pass
            @test compare_julia_wasm(_t60_mod2pi, 6.28).pass
            @test compare_julia_wasm(_t60_mod2pi, 10.0).pass
            @test compare_julia_wasm(_t60_mod2pi, -1.0).pass
        end

        @testset "Two-arg functions (WBUILD-1024)" begin
            _t60_max(x::Float64, y::Float64)::Float64 = max(x, y)
            @test compare_julia_wasm(_t60_max, 1.0, 2.0).pass
            @test compare_julia_wasm(_t60_max, -1.0, 1.0).pass
            @test compare_julia_wasm(_t60_max, 3.0, 3.0).pass
            @test compare_julia_wasm(_t60_max, -5.0, -3.0).pass

            _t60_min(x::Float64, y::Float64)::Float64 = min(x, y)
            @test compare_julia_wasm(_t60_min, 1.0, 2.0).pass
            @test compare_julia_wasm(_t60_min, -1.0, 1.0).pass
            @test compare_julia_wasm(_t60_min, 3.0, 3.0).pass
            @test compare_julia_wasm(_t60_min, -5.0, -3.0).pass

            _t60_minmax_lo(x::Float64, y::Float64)::Float64 = minmax(x, y)[1]
            @test compare_julia_wasm(_t60_minmax_lo, 3.0, 1.0).pass
            @test compare_julia_wasm(_t60_minmax_lo, -1.0, 5.0).pass

            _t60_minmax_hi(x::Float64, y::Float64)::Float64 = minmax(x, y)[2]
            @test compare_julia_wasm(_t60_minmax_hi, 3.0, 1.0).pass
            @test compare_julia_wasm(_t60_minmax_hi, -1.0, 5.0).pass

            _t60_ldexp(x::Float64, n::Int64)::Float64 = ldexp(x, Int(n))
            @test compare_julia_wasm(_t60_ldexp, 0.5, Int64(3)).pass
            @test compare_julia_wasm(_t60_ldexp, 1.0, Int64(0)).pass
            @test compare_julia_wasm(_t60_ldexp, 1.0, Int64(-2)).pass
            @test compare_julia_wasm(_t60_ldexp, 3.14, Int64(5)).pass
        end

        # Floating-point inspection (WBUILD-1024) — REMOVED (placeholder @test_broken false stub)
    end

    # ========================================================================
    # Phase 62: JS↔WasmGC Bridge Tests (WBUILD-2013)
    # ========================================================================
    # Tests the bridge infrastructure itself — Vector round-trips, edge cases.
    # Uses compare_julia_wasm_vec which compiles bridge functions alongside user code.
    @pphase "Phase 62: Bridge Tests (WBUILD-2013)" begin

        @testset "Vector{Int64} round-trip" begin
            @test compare_julia_wasm_vec(_p63_identity_i64, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p63_identity_i64, Int64[]).pass
            @test compare_julia_wasm_vec(_p63_identity_i64, Int64[42]).pass
            @test compare_julia_wasm_vec(_p63_identity_i64, Int64[-1, 0, 1]).pass
            # Large vector
            @test compare_julia_wasm_vec(_p63_identity_i64, collect(Int64, 1:100)).pass
        end

        @testset "Vector{Float64} round-trip" begin
            @test compare_julia_wasm_vec(_p63_identity_f64, Float64[1.5, 2.5, 3.5]).pass
            @test compare_julia_wasm_vec(_p63_identity_f64, Float64[]).pass
            @test compare_julia_wasm_vec(_p63_identity_f64, Float64[42.0]).pass
            @test compare_julia_wasm_vec(_p63_identity_f64, Float64[-1.1, 0.0, 1.1]).pass
            @test compare_julia_wasm_vec(_p63_identity_f64, collect(Float64, 1.0:100.0)).pass
        end
    end

    # ========================================================================
    # Phase 63: Real Base Collections (WBUILD-2020+)
    # ========================================================================
    # Tests REAL Base functions via the bridge. NO reimplementations.
    # Every function here calls the actual Base.sort/filter/map/etc.
    @pphase "Phase 63: Real Base Collections (WBUILD-2020)" begin

        # ──────────────────────────────────────────────────────────────────
        # WBUILD-2020: map (CLEAN — no stubs, works for any size)
        # ──────────────────────────────────────────────────────────────────
        @testset "Base.map (WBUILD-2020)" begin
            @testset "map(double, Vector{Int64})" begin
                @test compare_julia_wasm_vec(_p63_map_double, Int64[1, 2, 3]).pass
                @test compare_julia_wasm_vec(_p63_map_double, Int64[]).pass
                @test compare_julia_wasm_vec(_p63_map_double, Int64[-5, 0, 5]).pass
                @test compare_julia_wasm_vec(_p63_map_double, collect(Int64, 1:50)).pass
            end
            @testset "map(square, Vector{Int64})" begin
                @test compare_julia_wasm_vec(_p63_map_square, Int64[1, 2, 3, 4]).pass
                @test compare_julia_wasm_vec(_p63_map_square, Int64[-3, -2, -1, 0]).pass
            end
            @testset "map(double, Vector{Float64})" begin
                @test compare_julia_wasm_vec(_p63_map_double_f64, Float64[1.5, 2.5]).pass
                @test compare_julia_wasm_vec(_p63_map_double_f64, Float64[-1.0, 0.0, 1.0]).pass
            end
        end

        # ──────────────────────────────────────────────────────────────────
        # WBUILD-2021: any/all/count (CLEAN — no stubs)
        # ──────────────────────────────────────────────────────────────────
        @testset "Base.any/all/count (WBUILD-2021)" begin
            @testset "any(ispositive)" begin
                @test compare_julia_wasm_vec(_p63_any_positive, Int64[-1, -2, 3]).pass
                @test compare_julia_wasm_vec(_p63_any_positive, Int64[-1, -2, -3]).pass
                @test compare_julia_wasm_vec(_p63_any_positive, Int64[1, 2, 3]).pass
            end
            @testset "all(ispositive)" begin
                @test compare_julia_wasm_vec(_p63_all_positive, Int64[1, 2, 3]).pass
                @test compare_julia_wasm_vec(_p63_all_positive, Int64[1, -1, 3]).pass
                @test compare_julia_wasm_vec(_p63_all_positive, Int64[-1, -2, -3]).pass
            end
            @testset "count(iseven)" begin
                @test compare_julia_wasm_vec(_p63_count_even, Int64[1, 2, 3, 4, 5, 6]).pass
                @test compare_julia_wasm_vec(_p63_count_even, Int64[1, 3, 5]).pass
                @test compare_julia_wasm_vec(_p63_count_even, Int64[2, 4, 6]).pass
            end
        end

        # ──────────────────────────────────────────────────────────────────
        # WBUILD-2022: sum/reduce/prod/minimum/maximum (≤15 elements)
        # ──────────────────────────────────────────────────────────────────
        @testset "Base.sum/reduce/prod (WBUILD-2022)" begin
            @testset "sum(Vector{Int64})" begin
                @test compare_julia_wasm_vec(_p63_sum_i64, Int64[1, 2, 3, 4, 5]).pass
                @test compare_julia_wasm_vec(_p63_sum_i64, Int64[-10, 10]).pass
                @test compare_julia_wasm_vec(_p63_sum_i64, Int64[0, 0, 0]).pass
                @test compare_julia_wasm_vec(_p63_sum_i64, collect(Int64, 1:15)).pass
                # Large arrays (>15 elements — uses mapreduce_impl, fixed by WBUILD-2014)
                @test compare_julia_wasm_vec(_p63_sum_i64, collect(Int64, 1:16)).pass
                @test compare_julia_wasm_vec(_p63_sum_i64, collect(Int64, 1:100)).pass
            end
            @testset "sum(Vector{Float64})" begin
                @test compare_julia_wasm_vec(_p63_sum_f64, Float64[1.5, 2.5, 3.5]).pass
                @test compare_julia_wasm_vec(_p63_sum_f64, Float64[-1.0, 1.0]).pass
            end
            @testset "reduce(+)" begin
                @test compare_julia_wasm_vec(_p63_reduce_plus, Int64[1, 2, 3, 4, 5]).pass
                @test compare_julia_wasm_vec(_p63_reduce_plus, Int64[10, 20, 30]).pass
            end
            @testset "reduce/foldl(min/max) (WASMTARGET-FUZZ)" begin
                # min/max reducer: native kept an invalid mapreduce_impl block ⇒ trap;
                # the overlay's left-fold returns the correct end (not the opposite).
                for v in (Int64[5, 3, 8, 1, 4], Int64[-10, -5, -20], Int64[7], Int64[0, 0, 0])
                    @test compare_julia_wasm_vec(_p63_reduce_min_i64, v).pass
                    @test compare_julia_wasm_vec(_p63_reduce_max_i64, v).pass
                    @test compare_julia_wasm_vec(_p63_foldl_min_i64, v).pass
                    @test compare_julia_wasm_vec(_p63_foldl_max_i64, v).pass
                end
                @test compare_julia_wasm_vec(_p63_reduce_min_f64, Float64[5.5, 1.1, 3.3]).pass
                @test compare_julia_wasm_vec(_p63_foldl_max_f64, Float64[5.5, 1.1, 3.3]).pass
            end
            @testset "prod" begin
                @test compare_julia_wasm_vec(_p63_prod_i64, Int64[2, 3, 4, 5]).pass
                @test compare_julia_wasm_vec(_p63_prod_i64, Int64[1, 1, 1]).pass
            end
            @testset "minimum/maximum Int64" begin
                @test compare_julia_wasm_vec(_p63_minimum_i64, Int64[5, 3, 8, 1, 4]).pass
                @test compare_julia_wasm_vec(_p63_maximum_i64, Int64[5, 3, 8, 1, 4]).pass
                @test compare_julia_wasm_vec(_p63_minimum_i64, Int64[-10, -5, -20]).pass
                @test compare_julia_wasm_vec(_p63_maximum_i64, Int64[-10, -5, -20]).pass
            end
            @testset "minimum/maximum Float64" begin
                @test compare_julia_wasm_vec(_p63_minimum_f64, Float64[5.5, 1.1, 3.3]).pass
                @test compare_julia_wasm_vec(_p63_maximum_f64, Float64[5.5, 1.1, 3.3]).pass
            end
        end

        # ──────────────────────────────────────────────────────────────────
        # WBUILD-2023: reverse (works for any size)
        # ──────────────────────────────────────────────────────────────────
        @testset "Base.reverse (WBUILD-2023)" begin
            @test compare_julia_wasm_vec(_p63_reverse_i64, Int64[1, 2, 3, 4]).pass
            @test compare_julia_wasm_vec(_p63_reverse_i64, Int64[42]).pass
            @test compare_julia_wasm_vec(_p63_reverse_i64, Int64[-1, 0, 1]).pass
            @test compare_julia_wasm_vec(_p63_reverse_f64, Float64[1.1, 2.2, 3.3]).pass
            @test compare_julia_wasm_vec(_p63_reverse_f64, Float64[42.0]).pass
        end

        # ──────────────────────────────────────────────────────────────────
        # WBUILD-3002: sort — REAL Base.sort works for Int64 at any size
        # InsertionSort (n≤40), full sort chain (n>40) all pass
        # Float64 sort still broken (radix sort ReinterpretArray stubs)
        # ──────────────────────────────────────────────────────────────────
        @testset "Base.sort (WBUILD-3002)" begin
            # Int64 sort — small arrays (InsertionSort path, n≤40)
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[]).pass
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[1]).pass
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[3, 1, 2]).pass
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[5, 3, 1, 4, 2]).pass
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[10, 9, 8, 7, 6, 5, 4, 3, 2, 1]).pass
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[3, 1, 2, 1, 3, 2]).pass  # duplicates
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[-3, -1, -2, 0, 1]).pass   # negative
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[5, 5, 5, 5]).pass         # all same
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[typemax(Int64), typemin(Int64), 0]).pass
            # Large sorted/reverse-sorted arrays (CheckSorted fast path)
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[i for i in 1:100]).pass       # already sorted
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[i for i in 100:-1:1]).pass    # reverse sorted
            # Large shuffled arrays (full sort chain: n>40)
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[37, 12, 49, 3, 28, 41, 15, 8, 44, 22, 31, 5, 47, 19, 36, 2, 43, 10, 25, 48, 7, 33, 16, 39, 1, 45, 21, 34, 14, 46, 6, 30, 17, 42, 9, 26, 50, 11, 38, 4, 29, 20, 35, 13, 40, 24, 32, 18, 27, 23]).pass  # n=50 shuffled
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[67, 12, 89, 3, 45, 78, 23, 91, 34, 56, 1, 100, 42, 88, 15, 73, 9, 61, 37, 84, 27, 50, 6, 95, 18, 70, 43, 82, 31, 54, 14, 99, 8, 63, 29, 76, 47, 92, 21, 58, 4, 85, 36, 71, 16, 97, 52, 11, 66, 39, 80, 25, 93, 48, 7, 60, 33, 75, 19, 87, 2, 55, 41, 96, 13, 68, 30, 79, 22, 51, 5, 90, 38, 72, 17, 83, 46, 10, 64, 28, 77, 44, 98, 20, 57, 35, 81, 26, 94, 49, 69, 32, 86, 24, 59, 40, 74, 53, 62, 65]).pass  # n=100 shuffled
            # Duplicate-heavy large arrays
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[3,1,4,1,5,9,2,6,5,3,5,8,9,7,9,3,2,3,8,4,6,2,6,4,3,3,8,3,2,7,9,5,0,2,8,8,4,1,9,7,1,6,9,3,9,5,1,0,5,8]).pass  # n=50 duplicates
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[i % 7 for i in 1:100]).pass  # n=100 mod-7 pattern
            # Negative and mixed-sign large arrays
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[50 - i for i in 1:100]).pass  # n=100 negative to positive
            # WBUILD-3003: Edge cases — stability, alternating, boundary values
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[2, 1]).pass                    # two elements
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2]).pass  # n=50 alternating (triggers full sort)
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[i for i in 200:-1:1]).pass     # n=200 descending
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[0 for _ in 1:100]).pass        # n=100 all zeros
            @test compare_julia_wasm_vec(_p63_sort_i64, Int64[typemax(Int64), typemin(Int64), typemax(Int64), typemin(Int64), 0, 0, typemax(Int64)]).pass  # boundary values repeated
            # Float64 sort (WBUILD-4001) — fixed via ref.cast for return type + autodiscovery
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[3.0, 1.0, 2.0]).pass
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[5.5, 1.1, 3.3, 2.2, 4.4]).pass
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[1.0]).pass                    # single element
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[1.0, 2.0, 3.0]).pass          # already sorted
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[3.0, 2.0, 1.0]).pass          # reverse sorted
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[-3.5, -1.1, -2.2, 0.0, 1.5]).pass  # negatives + zero
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[-100.0, 50.5, -0.1, 0.1, 99.9, -99.9]).pass  # mixed
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[10.0, 9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0]).pass  # 10 desc
            # Large arrays (trigger full sort chain, not just InsertionSort)
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[50.0 - i for i in 1:50]).pass   # n=50 descending
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[sin(Float64(i)) for i in 1:100]).pass  # n=100 sin wave
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[Float64(i % 7) + 0.1*i for i in 1:100]).pass  # n=100 mixed
            # WBUILD-4002: NaN, Inf, -0.0 edge cases
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[3.0, NaN, 1.0, 2.0]).pass         # NaN sorted to end
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[NaN, 3.0, NaN, 1.0]).pass          # multiple NaN
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[Inf, 3.0, -Inf, 1.0, 0.0]).pass    # Inf/-Inf
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[-0.0, 0.0, -1.0, 1.0]).pass        # -0.0 and 0.0
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[NaN, Inf, -Inf, 0.0, -0.0]).pass   # all special values
            @test compare_julia_wasm_vec(_p63_sort_f64, Float64[5.0, NaN, -3.0, Inf, -Inf, 2.0, NaN, 0.0]).pass  # mixed
        end

        # ──────────────────────────────────────────────────────────────────
        # WBUILD-3012: filter — FIXED (sizehint! handler moved above # closure check)
        # ──────────────────────────────────────────────────────────────────
        @testset "Base.filter (WBUILD-3012)" begin
            @test compare_julia_wasm_vec(_p63_filter_even, Int64[1, 2, 3, 4, 5, 6]).pass
            @test compare_julia_wasm_vec(_p63_filter_even, Int64[2, 4, 6]).pass           # all match
            @test compare_julia_wasm_vec(_p63_filter_even, Int64[1, 3, 5]).pass           # none match
            @test compare_julia_wasm_vec(_p63_filter_even, Int64[]).pass                  # empty
            @test compare_julia_wasm_vec(_p63_filter_even, Int64[2]).pass                 # single match
            @test compare_julia_wasm_vec(_p63_filter_even, Int64[1]).pass                 # single no match
            @test compare_julia_wasm_vec(_p63_filter_positive, Int64[-3, -1, 0, 1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p63_filter_even, Int64[i for i in 1:20]).pass   # larger array
        end
    end

    # ========================================================================
    # Phase 64: Dict{Int64,Int64} and Set{Int64} — WBUILD-5200/5201/5204
    # Real Base Dict/Set operations compiled to WasmGC. Dict uses Memory{T}
    # for slots/keys/vals, hash inlining, open addressing with linear probing.
    # ========================================================================
    # Phase 64: Dict and Set — REMOVED (placeholder @test_broken false stub)
    # Real Dict/Set tests are in Phase 38.

    # ========================================================================
    # Phase 65: Vector Splatting (_apply_iterate) — WBUILD-5301
    # ========================================================================
    @pphase "Phase 65: Vector Splatting (WBUILD-5301)" begin
        @testset "+(vec...) Int64 — reduce via _apply_iterate" begin
            @test compare_julia_wasm_vec(_p65_splat_sum_i64, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p65_splat_sum_i64, Int64[10, 20, 30, 40]).pass
            @test compare_julia_wasm_vec(_p65_splat_sum_i64, Int64[42]).pass  # single element
            @test compare_julia_wasm_vec(_p65_splat_sum_i64, Int64[-5, 5, -10, 10]).pass  # negatives
            @test compare_julia_wasm_vec(_p65_splat_sum_i64, collect(Int64, 1:100)).pass  # large (sum=5050)
        end
        @testset "*(vec...) Int64 — reduce via _apply_iterate" begin
            @test compare_julia_wasm_vec(_p65_splat_prod_i64, Int64[2, 3, 4]).pass  # 24
            @test compare_julia_wasm_vec(_p65_splat_prod_i64, Int64[1, 2, 3, 4, 5]).pass  # 120
            @test compare_julia_wasm_vec(_p65_splat_prod_i64, Int64[7]).pass  # single
        end
        @testset "+(vec...) Float64 — reduce via _apply_iterate" begin
            @test compare_julia_wasm_vec(_p65_splat_sum_f64, Float64[1.5, 2.5, 3.0]).pass
            @test compare_julia_wasm_vec(_p65_splat_sum_f64, Float64[0.1, 0.2, 0.3, 0.4]).pass
        end
        @testset "*(vec...) Float64 — reduce via _apply_iterate" begin
            @test compare_julia_wasm_vec(_p65_splat_prod_f64, Float64[2.0, 3.0, 4.0]).pass
            @test compare_julia_wasm_vec(_p65_splat_prod_f64, Float64[0.5, 0.5, 0.5]).pass  # 0.125
        end

        @testset "Base.vect(prefix, vec...) — heterogeneous SimpleVector prefix" begin
            @test compare_julia_wasm_vec(_p65_prefix_splat_sum, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p65_prefix_splat_sum, Int64[]).pass
        end
    end

    # ========================================================================
    # Phase 66: Base.string() — Real Base function compilation (WBUILD-5401)
    # Tests string(Bool), string(Int32), string(Int64) via WASM-internal
    # equality since String is a WasmGC i8 array opaque to JS.
    # ========================================================================

    # Phase 66 helper functions — test string conversion inside WASM
    # string(Bool) — 3 stmts, trivial
    _p66_string_true()::Bool = string(true) == "true"
    _p66_string_false()::Bool = string(false) == "false"

    # string(Int32) — inlined dec → ndigits0zpb + append_c_digits_fast (real Base)
    _p66_string_i32_42()::Bool = string(Int32(42)) == "42"
    _p66_string_i32_neg()::Bool = string(Int32(-7)) == "-7"
    _p66_string_i32_zero()::Bool = string(Int32(0)) == "0"
    _p66_string_i32_large()::Bool = string(Int32(12345)) == "12345"
    _p66_string_i32_min()::Bool = string(Int32(-2147483648)) == "-2147483648"

    # string(Int64) — same inlined path as Int32
    _p66_string_i64_42()::Bool = string(Int64(42)) == "42"
    _p66_string_i64_big()::Bool = string(Int64(9876543210)) == "9876543210"
    _p66_string_i64_neg()::Bool = string(Int64(-999)) == "-999"

    # string(Float64) — real Base Ryu.writeshortest path (WBUILD-5401)
    _p66_string_f64_1_5()::Bool = string(1.5) == "1.5"
    _p66_string_f64_3_14()::Bool = string(3.14) == "3.14"
    _p66_string_f64_0()::Bool = string(0.0) == "0.0"
    _p66_string_f64_neg()::Bool = string(-2.5) == "-2.5"
    _p66_string_f64_int()::Bool = string(42.0) == "42.0"
    _p66_string_f64_small()::Bool = string(0.001) == "0.001"
    _p66_string_f64_large()::Bool = string(1.0e10) == "1.0e10"
    _p66_string_f64_neg_zero()::Bool = string(-0.0) == "-0.0"

    # Phase 66: Base.string() — REMOVED (placeholder @test_broken false stub)
    # Helper functions above retained for future use.

    # ========================================================================
    # Phase 67: Base.contains() / Base.occursin() (BF3-FIX)
    # Tests real Base.contains/occursin via _searchindex → str_find dispatch.
    # Uses Bool return inside WASM (no String crossing to JS).
    # ========================================================================

    # Phase 67 helper functions — contains/occursin with constant strings
    _p67_contains_found()::Bool = contains("hello world", "world")
    _p67_contains_not_found()::Bool = contains("hello world", "xyz")
    _p67_contains_empty_needle()::Bool = contains("hello", "")
    _p67_contains_at_start()::Bool = contains("hello world", "hello")
    _p67_contains_single_char()::Bool = contains("abcdef", "d")
    _p67_contains_full_match()::Bool = contains("hello", "hello")
    _p67_occursin_found()::Bool = occursin("world", "hello world")
    _p67_occursin_not_found()::Bool = occursin("xyz", "hello world")

    # Phase 67: Base.contains/occursin (BF3-FIX) — REMOVED (placeholder @test_broken false stub)
    # Helper functions above retained for future use.

    # ========================================================================
    # Phase 69: BF3 contains/occursin
    # Tests that Julia's Base.contains and Base.occursin compile and execute
    # correctly via the _searchindex → str_find early dispatch.
    # ========================================================================

    # Phase 69: contains/occursin (BF3) — REMOVED (placeholder @test_broken false stub)

    # ========================================================================
    # Phase 70: BF4 String interpolation / string(x) with variable args
    # Tests that string(x::Int64) works when x is a runtime argument
    # (goes through #string#403 → dec early dispatch, not constant inlining).
    # ========================================================================

    _bf4_str_pos(x::Int64)::Bool = string(x) == "42"
    _bf4_str_neg(x::Int64)::Bool = string(x) == "-999"
    _bf4_str_zero(x::Int64)::Bool = string(x) == "0"
    _bf4_str_large(x::Int64)::Bool = string(x) == "1234567890"
    _bf4_str_max(x::Int64)::Bool = string(x) == "9223372036854775807"

    # Phase 70: String Interpolation (BF4) — REMOVED (placeholder @test_broken false stub)
    # Helper functions above retained for future use.

    # ========================================================================
    # Phase 71: BF2 Trivial String Dispatch (repeat, lpad, rpad, prevind)
    # Tests that Base string functions compile and execute correctly.
    # NOTE: Test functions call Base functions directly to avoid @testset
    # closure capture (functions inside @testset that reference other local
    # functions become closures, which the compiler can't export to JS).
    # ========================================================================

    # Self-contained test functions — no local function capture
    _bf2_test_repeat_basic()::Int32 = repeat("abc", Int64(3)) == "abcabcabc" ? Int32(1) : Int32(0)
    _bf2_test_repeat_char()::Int32 = repeat("x", Int64(5)) == "xxxxx" ? Int32(1) : Int32(0)
    _bf2_test_repeat_once()::Int32 = repeat("hello", Int64(1)) == "hello" ? Int32(1) : Int32(0)
    _bf2_test_lpad_basic()::Int32 = lpad("hi", Int64(5)) == "   hi" ? Int32(1) : Int32(0)
    _bf2_test_lpad_nopad()::Int32 = lpad("hello", Int64(3)) == "hello" ? Int32(1) : Int32(0)
    _bf2_test_lpad_exact()::Int32 = lpad("abc", Int64(3)) == "abc" ? Int32(1) : Int32(0)
    _bf2_test_rpad_basic()::Int32 = rpad("hi", Int64(5)) == "hi   " ? Int32(1) : Int32(0)
    _bf2_test_rpad_nopad()::Int32 = rpad("hello", Int64(3)) == "hello" ? Int32(1) : Int32(0)
    _bf2_test_rpad_exact()::Int32 = rpad("abc", Int64(3)) == "abc" ? Int32(1) : Int32(0)
    _bf2_test_prevind()::Int64 = prevind("hello", Int64(5))
    _bf2_test_prevind_start()::Int64 = prevind("hello", Int64(1))
    _bf2_test_prevind_mid()::Int64 = prevind("abcdef", Int64(3))

    @pphase "Phase 71: String Dispatch (BF2)" begin
        @testset "repeat - basic" begin
            @test compare_julia_wasm(_bf2_test_repeat_basic).pass
        end

        @testset "repeat - single char" begin
            @test compare_julia_wasm(_bf2_test_repeat_char).pass
        end

        @testset "repeat - once" begin
            @test compare_julia_wasm(_bf2_test_repeat_once).pass
        end

        @testset "lpad - basic" begin
            @test compare_julia_wasm(_bf2_test_lpad_basic).pass
        end

        @testset "lpad - no padding needed" begin
            @test compare_julia_wasm(_bf2_test_lpad_nopad).pass
        end

        @testset "lpad - exact length" begin
            @test compare_julia_wasm(_bf2_test_lpad_exact).pass
        end

        @testset "rpad - basic" begin
            @test compare_julia_wasm(_bf2_test_rpad_basic).pass
        end

        @testset "rpad - no padding needed" begin
            @test compare_julia_wasm(_bf2_test_rpad_nopad).pass
        end

        @testset "rpad - exact length" begin
            @test compare_julia_wasm(_bf2_test_rpad_exact).pass
        end

        # prevind tests now pass — promote from @test_broken to @test
        @testset "prevind - basic" begin
            r = compare_julia_wasm_manual(_bf2_test_prevind, (), prevind("hello", 5))
            @test r.pass
        end

        @testset "prevind - at start" begin
            r = compare_julia_wasm_manual(_bf2_test_prevind_start, (), prevind("hello", 1))
            @test r.pass
        end

        @testset "prevind - middle" begin
            r = compare_julia_wasm_manual(_bf2_test_prevind_mid, (), prevind("abcdef", 3))
            @test r.pass
        end
    end

    # ========================================================================
    # Phase 72: CF-1003 Numeric Functions Full E2E
    # ========================================================================
    @pphase "Phase 72: Numeric Functions (CF-1003)" begin

        # --- abs ---
        @testset "abs" begin
            r = compare_julia_wasm(abs, Int64(5))
            @test r.pass
            r = compare_julia_wasm(abs, Int64(-5))
            @test r.pass
            r = compare_julia_wasm(abs, Int64(0))
            @test r.pass
            r = compare_julia_wasm(abs, -3.14)
            @test r.pass
            r = compare_julia_wasm(abs, 0.0)
            @test r.pass
        end

        # --- sign ---
        @testset "sign" begin
            r = compare_julia_wasm(sign, Int64(42))
            @test r.pass
            r = compare_julia_wasm(sign, Int64(-42))
            @test r.pass
            r = compare_julia_wasm(sign, Int64(0))
            @test r.pass
            r = compare_julia_wasm(sign, -3.14)
            @test r.pass
            r = compare_julia_wasm(sign, 0.0)
            @test r.pass
        end

        # --- signbit ---
        @testset "signbit" begin
            r = compare_julia_wasm(signbit, 3.14)
            @test r.pass
            r = compare_julia_wasm(signbit, -3.14)
            @test r.pass
            r = compare_julia_wasm(signbit, 0.0)
            @test r.pass
        end

        # --- clamp ---
        @testset "clamp" begin
            r = compare_julia_wasm(clamp, Int64(5), Int64(1), Int64(10))
            @test r.pass
            r = compare_julia_wasm(clamp, Int64(-5), Int64(1), Int64(10))
            @test r.pass
            r = compare_julia_wasm(clamp, Int64(15), Int64(1), Int64(10))
            @test r.pass
            r = compare_julia_wasm(clamp, 3.14, 0.0, 1.0)
            @test r.pass
        end

        # --- min/max ---
        @testset "min/max" begin
            r = compare_julia_wasm(min, Int64(3), Int64(7))
            @test r.pass
            r = compare_julia_wasm(max, Int64(3), Int64(7))
            @test r.pass
            r = compare_julia_wasm(min, 3.14, 2.71)
            @test r.pass
            r = compare_julia_wasm(max, 3.14, 2.71)
            @test r.pass
        end

        # --- div/mod/rem ---
        @testset "div/mod/rem" begin
            r = compare_julia_wasm(div, Int64(17), Int64(5))
            @test r.pass
            r = compare_julia_wasm(div, Int64(-17), Int64(5))
            @test r.pass
            r = compare_julia_wasm(mod, Int64(17), Int64(5))
            @test r.pass
            r = compare_julia_wasm(mod, Int64(-17), Int64(5))
            @test r.pass
            r = compare_julia_wasm(rem, Int64(17), Int64(5))
            @test r.pass
            r = compare_julia_wasm(rem, Int64(-17), Int64(5))
            @test r.pass
        end

        # --- gcd/lcm ---
        @testset "gcd/lcm" begin
            @test compare_julia_wasm(gcd, Int64(12), Int64(8)).pass
            @test compare_julia_wasm(gcd, Int64(17), Int64(13)).pass
            @test compare_julia_wasm(gcd, Int64(0), Int64(5)).pass
            @test compare_julia_wasm(lcm, Int64(4), Int64(6)).pass
            @test compare_julia_wasm(lcm, Int64(3), Int64(7)).pass
        end

        # --- iseven/isodd ---
        @testset "iseven/isodd" begin
            r = compare_julia_wasm(iseven, Int64(4))
            @test r.pass
            r = compare_julia_wasm(iseven, Int64(3))
            @test r.pass
            r = compare_julia_wasm(iseven, Int64(0))
            @test r.pass
            r = compare_julia_wasm(isodd, Int64(3))
            @test r.pass
            r = compare_julia_wasm(isodd, Int64(4))
            @test r.pass
            r = compare_julia_wasm(isodd, Int64(-7))
            @test r.pass
        end

        # --- isnan/isinf/isfinite ---
        @testset "isnan/isinf/isfinite" begin
            r = compare_julia_wasm(isnan, 3.14)
            @test r.pass
            r = compare_julia_wasm(isnan, NaN)
            @test r.pass
            r = compare_julia_wasm(isinf, 3.14)
            @test r.pass
            r = compare_julia_wasm(isfinite, 3.14)
            @test r.pass
            r = compare_julia_wasm(isfinite, NaN)
            @test r.pass
        end

        # --- iszero/isone ---
        @testset "iszero/isone" begin
            r = compare_julia_wasm(iszero, Int64(0))
            @test r.pass
            r = compare_julia_wasm(iszero, Int64(5))
            @test r.pass
            r = compare_julia_wasm(isone, Int64(1))
            @test r.pass
            r = compare_julia_wasm(isone, Int64(5))
            @test r.pass
        end

        # --- zero/one ---
        @testset "zero/one" begin
            r = compare_julia_wasm(zero, Int64(42))
            @test r.pass
            r = compare_julia_wasm(one, Int64(42))
            @test r.pass
            r = compare_julia_wasm(zero, 3.14)
            @test r.pass
            r = compare_julia_wasm(one, 3.14)
            @test r.pass
        end
    end

    # ========================================================================
    # Phase 73: CF-2002 String Functions Build — Overlay E2E Tests
    # ========================================================================
    @pphase "Phase 73: String Functions (CF-2002)" begin

        # --- chop ---
        @testset "chop" begin
            chop_default()::Int64 = length(chop("hello"))
            r = compare_julia_wasm(chop_default)
            @test r.pass  # "hell" → 4

            # kwargs tests — blocked by _apply_iterate(iterate, tuple, vec) codegen
            # chop with explicit head/tail kwargs hits unreachable in kwargs validation IR
            # TODO: fix _apply_iterate for Core.tuple target to enable overlay kwargs

            chop_empty()::Int64 = length(chop(""))
            r = compare_julia_wasm(chop_empty)
            @test r.pass  # "" → 0

            chop_single()::Int64 = length(chop("x"))
            r = compare_julia_wasm(chop_single)
            @test r.pass  # "" → 0

            # Content verification via string equality
            chop_content()::Int32 = chop("hello") == "hell" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(chop_content)
            @test r.pass
        end

        # --- last(String, Int) ---
        @testset "last(String, Int)" begin
            last_3()::Int64 = length(last("hello", 3))
            r = compare_julia_wasm(last_3)
            @test r.pass  # "llo" → 3

            last_all()::Int64 = length(last("hello", 10))
            r = compare_julia_wasm(last_all)
            @test r.pass  # "hello" → 5

            last_1()::Int64 = length(last("hello", 1))
            r = compare_julia_wasm(last_1)
            @test r.pass  # "o" → 1

            last_0()::Int64 = length(last("hello", 0))
            r = compare_julia_wasm(last_0)
            @test r.pass  # "" → 0

            last_content()::Int32 = last("hello", 3) == "llo" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(last_content)
            @test r.pass
        end

        # --- reverse(String) ---
        @testset "reverse(String)" begin
            rev_len()::Int64 = length(reverse("hello"))
            r = compare_julia_wasm(rev_len)
            @test r.pass  # 5

            rev_single()::Int64 = length(reverse("x"))
            r = compare_julia_wasm(rev_single)
            @test r.pass  # 1

            rev_empty()::Int64 = length(reverse(""))
            r = compare_julia_wasm(rev_empty)
            @test r.pass  # 0

            # Verify reversal correctness via string equality
            rev_content()::Int32 = reverse("hello") == "olleh" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(rev_content)
            @test r.pass
        end

        # --- titlecase ---
        @testset "titlecase" begin
            tc_len()::Int64 = length(titlecase("hello world"))
            r = compare_julia_wasm(tc_len)
            @test r.pass  # 11

            tc_first()::Int64 = Int64(str_char(titlecase("hello world"), Int32(1)))
            r = compare_julia_wasm(tc_first)
            @test r.pass  # 'H' = 72

            tc_strict()::Int64 = Int64(str_char(titlecase("hELLO"), Int32(2)))
            r = compare_julia_wasm(tc_strict)
            @test r.pass

            tc_empty()::Int64 = length(titlecase(""))
            r = compare_julia_wasm(tc_empty)
            @test r.pass  # 0

            tc_content()::Int32 = titlecase("hello world") == "Hello World" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(tc_content)
            @test r.pass

            tc_allcaps()::Int32 = titlecase("HELLO WORLD") == "Hello World" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(tc_allcaps)
            @test r.pass
        end

        # --- lowercasefirst ---
        @testset "lowercasefirst" begin
            lcf_len()::Int64 = length(lowercasefirst("HELLO"))
            r = compare_julia_wasm(lcf_len)
            @test r.pass  # 5

            lcf_first()::Int64 = Int64(str_char(lowercasefirst("HELLO"), Int32(1)))
            r = compare_julia_wasm(lcf_first)
            @test r.pass  # 'h' = 104

            lcf_second()::Int64 = Int64(str_char(lowercasefirst("HELLO"), Int32(2)))
            r = compare_julia_wasm(lcf_second)
            @test r.pass  # 'E' = 69

            lcf_empty()::Int64 = length(lowercasefirst(""))
            r = compare_julia_wasm(lcf_empty)
            @test r.pass  # 0

            lcf_content()::Int32 = lowercasefirst("Hello") == "hello" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(lcf_content)
            @test r.pass

            lcf_noop()::Int32 = lowercasefirst("hello") == "hello" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(lcf_noop)
            @test r.pass
        end

        # --- uppercasefirst ---
        @testset "uppercasefirst" begin
            ucf_len()::Int64 = length(uppercasefirst("hello"))
            r = compare_julia_wasm(ucf_len)
            @test r.pass  # 5

            ucf_first()::Int64 = Int64(str_char(uppercasefirst("hello"), Int32(1)))
            r = compare_julia_wasm(ucf_first)
            @test r.pass  # 'H' = 72

            ucf_second()::Int64 = Int64(str_char(uppercasefirst("hello"), Int32(2)))
            r = compare_julia_wasm(ucf_second)
            @test r.pass  # 'e' = 101

            ucf_empty()::Int64 = length(uppercasefirst(""))
            r = compare_julia_wasm(ucf_empty)
            @test r.pass  # 0

            ucf_content()::Int32 = uppercasefirst("hello") == "Hello" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(ucf_content)
            @test r.pass

            ucf_noop()::Int32 = uppercasefirst("Hello") == "Hello" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(ucf_noop)
            @test r.pass
        end

        # --- strip ---
        @testset "strip" begin
            strip_basic()::Int64 = length(strip("  hello  "))
            r = compare_julia_wasm(strip_basic)
            @test r.pass  # 5

            strip_tabs()::Int64 = length(strip("\thello\t"))
            r = compare_julia_wasm(strip_tabs)
            @test r.pass  # 5

            strip_none()::Int64 = length(strip("hello"))
            r = compare_julia_wasm(strip_none)
            @test r.pass  # 5

            strip_all()::Int64 = length(strip("   "))
            r = compare_julia_wasm(strip_all)
            @test r.pass  # 0

            strip_content()::Int32 = strip("  hello  ") == "hello" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(strip_content)
            @test r.pass

            strip_empty()::Int64 = length(strip(""))
            r = compare_julia_wasm(strip_empty)
            @test r.pass  # 0
        end

        # --- lstrip ---
        @testset "lstrip" begin
            lstrip_basic()::Int64 = length(lstrip("  hello  "))
            r = compare_julia_wasm(lstrip_basic)
            @test r.pass  # 7

            lstrip_none()::Int64 = length(lstrip("hello"))
            r = compare_julia_wasm(lstrip_none)
            @test r.pass  # 5

            lstrip_content()::Int32 = lstrip("  hello  ") == "hello  " ? Int32(1) : Int32(0)
            r = compare_julia_wasm(lstrip_content)
            @test r.pass
        end

        # --- rstrip ---
        @testset "rstrip" begin
            rstrip_basic()::Int64 = length(rstrip("  hello  "))
            r = compare_julia_wasm(rstrip_basic)
            @test r.pass  # 7

            rstrip_none()::Int64 = length(rstrip("hello"))
            r = compare_julia_wasm(rstrip_none)
            @test r.pass  # 5

            rstrip_content()::Int32 = rstrip("  hello  ") == "  hello" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(rstrip_content)
            @test r.pass
        end

        # --- replace ---
        @testset "replace" begin
            repl_match()::Int64 = length(replace("hello world", "world" => "julia"))
            r = compare_julia_wasm(repl_match)
            @test r.pass  # 11

            repl_nomatch()::Int64 = length(replace("hello", "xyz" => "abc"))
            r = compare_julia_wasm(repl_nomatch)
            @test r.pass  # 5

            repl_start()::Int64 = length(replace("hello", "hel" => "X"))
            r = compare_julia_wasm(repl_start)
            @test r.pass  # 3

            repl_multi()::Int64 = length(replace("aXbXc", "X" => "YY"))
            r = compare_julia_wasm(repl_multi)
            @test r.pass  # 7

            repl_to_empty()::Int64 = length(replace("hello", "ll" => ""))
            r = compare_julia_wasm(repl_to_empty)
            @test r.pass  # 3

            repl_empty_input()::Int64 = length(replace("", "x" => "y"))
            r = compare_julia_wasm(repl_empty_input)
            @test r.pass  # 0

            repl_content()::Int32 = replace("hello", "l" => "r") == "herro" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(repl_content)
            @test r.pass

            repl_grow()::Int32 = replace("ab", "a" => "xyz") == "xyzb" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(repl_grow)
            @test r.pass

            repl_delete()::Int32 = replace("hello", "l" => "") == "heo" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(repl_delete)
            @test r.pass
        end

        # --- split ---
        @testset "split" begin
            split_basic()::Int64 = length(split("a,b,c", ","))
            r = compare_julia_wasm(split_basic)
            @test r.pass  # 3

            split_spaces()::Int64 = length(split("hello world foo", " "))
            r = compare_julia_wasm(split_spaces)
            @test r.pass  # 3

            split_no_delim()::Int64 = length(split("hello", ","))
            r = compare_julia_wasm(split_no_delim)
            @test r.pass  # 1

            split_empty()::Int64 = length(split("", ","))
            r = compare_julia_wasm(split_empty)
            @test r.pass  # 1

            split_content1()::Int32 = split("hello world", " ")[1] == "hello" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(split_content1)
            @test r.pass

            split_content2()::Int32 = split("hello world", " ")[2] == "world" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(split_content2)
            @test r.pass
        end

        # --- join ---
        @testset "join" begin
            join_len()::Int64 = length(join(["hello", "world"], " "))
            r = compare_julia_wasm(join_len)
            @test r.pass  # 11

            join_no_delim()::Int64 = length(join(["a", "b", "c"]))
            r = compare_julia_wasm(join_no_delim)
            @test r.pass  # 3

            join_comma()::Int64 = length(join(["x", "y", "z"], ", "))
            r = compare_julia_wasm(join_comma)
            @test r.pass  # 8 ("x, y, z")

            join_content()::Int32 = join(split("a,b,c", ","), "-") == "a-b-c" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(join_content)
            @test r.pass

            join_no_delim_content()::Int32 = join(split("a b c", " ")) == "abc" ? Int32(1) : Int32(0)
            r = compare_julia_wasm(join_no_delim_content)
            @test r.pass
        end
    end

    # ========================================================================
    # Phase 74: Array Mutation Functions (CF-4002)
    # Tests for push!, pop!, pushfirst!, popfirst!, insert!, deleteat!,
    # append!, prepend!, splice! — all via overlays using similar+setfield!
    # ========================================================================
    @pphase "Phase 74: Array Mutation Functions" begin

        # --- push! ---
        @testset "push!" begin
            _p74_push42(v::Vector{Int64})::Vector{Int64} = (push!(v, Int64(42)); v)
            @test compare_julia_wasm_vec(_p74_push42, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p74_push42, Int64[]).pass
            @test compare_julia_wasm_vec(_p74_push42, Int64[10]).pass
            @test compare_julia_wasm_vec(_p74_push42, Int64[-1, 0, 1]).pass
            @test compare_julia_wasm_vec(_p74_push42, collect(Int64, 1:20)).pass

            _p74_push0(v::Vector{Int64})::Vector{Int64} = (push!(v, Int64(0)); v)
            @test compare_julia_wasm_vec(_p74_push0, Int64[typemax(Int64), typemin(Int64)]).pass
        end

        # --- pop! ---
        @testset "pop!" begin
            _p74_pop(v::Vector{Int64})::Int64 = pop!(v)
            @test compare_julia_wasm_vec(_p74_pop, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p74_pop, Int64[42]).pass
            @test compare_julia_wasm_vec(_p74_pop, Int64[-100, 200, -300]).pass
            @test compare_julia_wasm_vec(_p74_pop, collect(Int64, 1:20)).pass

            # Verify remaining vector after pop
            _p74_pop_rest(v::Vector{Int64})::Vector{Int64} = (pop!(v); v)
            @test compare_julia_wasm_vec(_p74_pop_rest, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p74_pop_rest, Int64[10, 20]).pass
        end

        # --- pushfirst! ---
        @testset "pushfirst!" begin
            _p74_pushfirst0(v::Vector{Int64})::Vector{Int64} = (pushfirst!(v, Int64(0)); v)
            @test compare_julia_wasm_vec(_p74_pushfirst0, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p74_pushfirst0, Int64[]).pass
            @test compare_julia_wasm_vec(_p74_pushfirst0, Int64[42]).pass
            @test compare_julia_wasm_vec(_p74_pushfirst0, collect(Int64, 1:20)).pass

            _p74_pushfirst99(v::Vector{Int64})::Vector{Int64} = (pushfirst!(v, Int64(99)); v)
            @test compare_julia_wasm_vec(_p74_pushfirst99, Int64[-1, 0, 1]).pass
        end

        # --- popfirst! ---
        @testset "popfirst!" begin
            _p74_popfirst(v::Vector{Int64})::Int64 = popfirst!(v)
            @test compare_julia_wasm_vec(_p74_popfirst, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p74_popfirst, Int64[42]).pass
            @test compare_julia_wasm_vec(_p74_popfirst, Int64[-100, 200]).pass
            @test compare_julia_wasm_vec(_p74_popfirst, collect(Int64, 1:20)).pass

            _p74_popfirst_rest(v::Vector{Int64})::Vector{Int64} = (popfirst!(v); v)
            @test compare_julia_wasm_vec(_p74_popfirst_rest, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p74_popfirst_rest, Int64[10, 20, 30]).pass
        end

        # --- insert! ---
        @testset "insert!" begin
            _p74_insert2(v::Vector{Int64})::Vector{Int64} = (insert!(v, 2, Int64(99)); v)
            @test compare_julia_wasm_vec(_p74_insert2, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p74_insert2, Int64[10, 20, 30, 40]).pass

            _p74_insert1(v::Vector{Int64})::Vector{Int64} = (insert!(v, 1, Int64(0)); v)
            @test compare_julia_wasm_vec(_p74_insert1, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p74_insert1, Int64[42]).pass

            # Insert at end
            _p74_insert_end(v::Vector{Int64})::Vector{Int64} = (insert!(v, length(v) + 1, Int64(99)); v)
            @test compare_julia_wasm_vec(_p74_insert_end, Int64[1, 2, 3]).pass
        end

        # --- deleteat! ---
        @testset "deleteat!" begin
            _p74_del2(v::Vector{Int64})::Vector{Int64} = (deleteat!(v, 2); v)
            @test compare_julia_wasm_vec(_p74_del2, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p74_del2, Int64[10, 20, 30, 40]).pass

            _p74_del1(v::Vector{Int64})::Vector{Int64} = (deleteat!(v, 1); v)
            @test compare_julia_wasm_vec(_p74_del1, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p74_del1, Int64[42, 99]).pass

            _p74_del_last(v::Vector{Int64})::Vector{Int64} = (deleteat!(v, length(v)); v)
            @test compare_julia_wasm_vec(_p74_del_last, Int64[1, 2, 3]).pass
        end

        # --- append! ---
        @testset "append!" begin
            _p74_append(v::Vector{Int64})::Vector{Int64} = (append!(v, Int64[10, 20]); v)
            @test compare_julia_wasm_vec(_p74_append, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p74_append, Int64[]).pass
            @test compare_julia_wasm_vec(_p74_append, Int64[42]).pass

            _p74_append_large(v::Vector{Int64})::Vector{Int64} = (append!(v, collect(Int64, 100:110)); v)
            @test compare_julia_wasm_vec(_p74_append_large, Int64[1, 2, 3]).pass
        end

        # --- prepend! ---
        @testset "prepend!" begin
            _p74_prepend(v::Vector{Int64})::Vector{Int64} = (prepend!(v, Int64[10, 20]); v)
            @test compare_julia_wasm_vec(_p74_prepend, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p74_prepend, Int64[]).pass
            @test compare_julia_wasm_vec(_p74_prepend, Int64[42]).pass

            _p74_prepend_large(v::Vector{Int64})::Vector{Int64} = (prepend!(v, collect(Int64, 100:110)); v)
            @test compare_julia_wasm_vec(_p74_prepend_large, Int64[1, 2, 3]).pass
        end

        # --- splice! ---
        @testset "splice!" begin
            _p74_splice2(v::Vector{Int64})::Int64 = splice!(v, 2)
            @test compare_julia_wasm_vec(_p74_splice2, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p74_splice2, Int64[10, 20, 30]).pass

            _p74_splice1(v::Vector{Int64})::Int64 = splice!(v, 1)
            @test compare_julia_wasm_vec(_p74_splice1, Int64[42, 99, 7]).pass

            # Verify remaining vector after splice
            _p74_splice_rest(v::Vector{Int64})::Vector{Int64} = (splice!(v, 2); v)
            @test compare_julia_wasm_vec(_p74_splice_rest, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p74_splice_rest, Int64[10, 20, 30, 40]).pass
        end

        # --- fill (harness fix verification) ---
        @testset "fill" begin
            _p74_fill(v::Vector{Int64})::Vector{Int64} = fill!(v, Int64(7))
            @test compare_julia_wasm_vec(_p74_fill, Int64[1, 2, 3]).pass
            @test compare_julia_wasm_vec(_p74_fill, Int64[0, 0, 0, 0, 0]).pass
        end
    end

    # ========================================================================
    # Phase 75: Comprehensive FULLTEST — All 7 Categories
    # CF-1003 (Numeric), CF-2003 (Strings), CF-3003 (Collections),
    # CF-4003 (Array), CF-5003 (Type Conv), CF-6003 (Iterators), CF-7003 (Dict/Set)
    # ========================================================================
    @pphase "Phase 75: Comprehensive FULLTEST" begin

        # ================================================================
        # CF-1003: Numeric FULLTEST — missing functions + edge cases
        # ================================================================
        @testset "CF-1003 Numeric FULLTEST" begin

            # minmax via tuple element wrappers
            _ft_minmax_lo(a::Int64, b::Int64)::Int64 = minmax(a, b)[1]
            _ft_minmax_hi(a::Int64, b::Int64)::Int64 = minmax(a, b)[2]
            @testset "minmax" begin
                @test compare_julia_wasm(_ft_minmax_lo, Int64(3), Int64(7)).pass
                @test compare_julia_wasm(_ft_minmax_hi, Int64(3), Int64(7)).pass
                @test compare_julia_wasm(_ft_minmax_lo, Int64(7), Int64(3)).pass
                @test compare_julia_wasm(_ft_minmax_hi, Int64(7), Int64(3)).pass
                @test compare_julia_wasm(_ft_minmax_lo, Int64(-5), Int64(5)).pass
                @test compare_julia_wasm(_ft_minmax_hi, Int64(-5), Int64(5)).pass
                @test compare_julia_wasm(_ft_minmax_lo, Int64(0), Int64(0)).pass
            end

            # divrem via tuple element wrappers
            _ft_divrem_q(a::Int64, b::Int64)::Int64 = divrem(a, b)[1]
            _ft_divrem_r(a::Int64, b::Int64)::Int64 = divrem(a, b)[2]
            @testset "divrem" begin
                @test compare_julia_wasm(_ft_divrem_q, Int64(17), Int64(5)).pass
                @test compare_julia_wasm(_ft_divrem_r, Int64(17), Int64(5)).pass
                @test compare_julia_wasm(_ft_divrem_q, Int64(-17), Int64(5)).pass
                @test compare_julia_wasm(_ft_divrem_r, Int64(-17), Int64(5)).pass
                @test compare_julia_wasm(_ft_divrem_q, Int64(100), Int64(10)).pass
                @test compare_julia_wasm(_ft_divrem_r, Int64(100), Int64(10)).pass
            end

            # typemin/typemax via wrappers
            _ft_typemin_i32()::Int32 = typemin(Int32)
            _ft_typemax_i32()::Int32 = typemax(Int32)
            _ft_typemin_i64()::Int64 = typemin(Int64)
            _ft_typemax_i64()::Int64 = typemax(Int64)
            @testset "typemin/typemax" begin
                @test compare_julia_wasm(_ft_typemin_i32).pass
                @test compare_julia_wasm(_ft_typemax_i32).pass
                @test compare_julia_wasm(_ft_typemin_i64).pass
                @test compare_julia_wasm(_ft_typemax_i64).pass
            end

            # isinf/isfinite with Inf/NaN wrappers
            _ft_isinf_pos()::Bool = isinf(Inf)
            _ft_isinf_neg()::Bool = isinf(-Inf)
            _ft_isinf_nan()::Bool = isinf(NaN)
            _ft_isfinite_inf()::Bool = isfinite(Inf)
            _ft_isfinite_neginf()::Bool = isfinite(-Inf)
            @testset "isinf/isfinite edge cases" begin
                @test compare_julia_wasm(_ft_isinf_pos).pass
                @test compare_julia_wasm(_ft_isinf_neg).pass
                @test compare_julia_wasm(_ft_isinf_nan).pass
                @test compare_julia_wasm(_ft_isfinite_inf).pass
                @test compare_julia_wasm(_ft_isfinite_neginf).pass
            end

            # Numeric edge cases
            @testset "numeric edge cases" begin
                @test compare_julia_wasm(abs, Int64(-9223372036854775807)).pass  # near typemin
                @test compare_julia_wasm(sign, Int64(-1)).pass
                @test compare_julia_wasm(sign, 0.0).pass
                @test compare_julia_wasm(div, Int64(0), Int64(5)).pass
                @test compare_julia_wasm(mod, Int64(0), Int64(5)).pass
                @test compare_julia_wasm(rem, Int64(0), Int64(5)).pass
                @test compare_julia_wasm(gcd, Int64(0), Int64(0)).pass
                @test compare_julia_wasm(iseven, Int64(-4)).pass
                @test compare_julia_wasm(isodd, Int64(-3)).pass
                @test compare_julia_wasm(iszero, 0.0).pass
                @test compare_julia_wasm(isone, 1.0).pass
            end

            # ============================================
            # Extended abs edge cases
            # ============================================
            @testset "abs extended" begin
                @test compare_julia_wasm(abs, Int64(1)).pass
                @test compare_julia_wasm(abs, Int64(-1)).pass
                @test compare_julia_wasm(abs, Int64(9223372036854775807)).pass  # typemax
                @test compare_julia_wasm(abs, 1.0e300).pass
                @test compare_julia_wasm(abs, -1.0e300).pass
                @test compare_julia_wasm(abs, 1.0e-300).pass
                @test compare_julia_wasm(abs, -1.0e-300).pass
                @test compare_julia_wasm(abs, -0.0).pass
                _cf1_abs_inf()::Float64 = abs(Inf)
                _cf1_abs_neginf()::Float64 = abs(-Inf)
                @test compare_julia_wasm(_cf1_abs_inf).pass
                @test compare_julia_wasm(_cf1_abs_neginf).pass
            end

            # ============================================
            # Extended sign edge cases
            # ============================================
            @testset "sign extended" begin
                @test compare_julia_wasm(sign, Int64(1)).pass
                @test compare_julia_wasm(sign, Int64(-1)).pass
                @test compare_julia_wasm(sign, Int64(100)).pass
                @test compare_julia_wasm(sign, Int64(-100)).pass
                @test compare_julia_wasm(sign, 100.0).pass
                @test compare_julia_wasm(sign, -100.0).pass
                _cf1_sign_inf()::Float64 = sign(Inf)
                _cf1_sign_neginf()::Float64 = sign(-Inf)
                @test compare_julia_wasm(_cf1_sign_inf).pass
                @test compare_julia_wasm(_cf1_sign_neginf).pass
            end

            # ============================================
            # Extended signbit edge cases
            # ============================================
            @testset "signbit extended" begin
                @test compare_julia_wasm(signbit, -0.0).pass   # true — key edge case
                @test compare_julia_wasm(signbit, 1.0).pass
                @test compare_julia_wasm(signbit, -1.0).pass
                @test compare_julia_wasm(signbit, 1.0e300).pass
                @test compare_julia_wasm(signbit, -1.0e300).pass
                _cf1_signbit_inf()::Bool = signbit(Inf)
                _cf1_signbit_neginf()::Bool = signbit(-Inf)
                @test compare_julia_wasm(_cf1_signbit_inf).pass
                @test compare_julia_wasm(_cf1_signbit_neginf).pass
            end

            # ============================================
            # Extended clamp edge cases
            # ============================================
            @testset "clamp extended" begin
                # Value at bounds
                @test compare_julia_wasm(clamp, Int64(1), Int64(1), Int64(10)).pass
                @test compare_julia_wasm(clamp, Int64(10), Int64(1), Int64(10)).pass
                # Equal bounds
                @test compare_julia_wasm(clamp, Int64(5), Int64(3), Int64(3)).pass
                @test compare_julia_wasm(clamp, Int64(1), Int64(3), Int64(3)).pass
                # Negative range
                @test compare_julia_wasm(clamp, Int64(-5), Int64(-10), Int64(-1)).pass
                @test compare_julia_wasm(clamp, Int64(0), Int64(-10), Int64(-1)).pass
                # Float64
                @test compare_julia_wasm(clamp, 0.5, 0.0, 1.0).pass
                @test compare_julia_wasm(clamp, -0.5, 0.0, 1.0).pass
                @test compare_julia_wasm(clamp, 1.5, 0.0, 1.0).pass
            end

            # ============================================
            # Extended min/max edge cases
            # ============================================
            @testset "min extended" begin
                @test compare_julia_wasm(min, Int64(5), Int64(5)).pass
                @test compare_julia_wasm(min, Int64(-3), Int64(-7)).pass
                @test compare_julia_wasm(min, Int64(0), Int64(-1)).pass
                @test compare_julia_wasm(min, Int64(0), Int64(1)).pass
                @test compare_julia_wasm(min, -1.5, 2.5).pass
                @test compare_julia_wasm(min, 0.0, 1.0e300).pass
            end

            @testset "max extended" begin
                @test compare_julia_wasm(max, Int64(5), Int64(5)).pass
                @test compare_julia_wasm(max, Int64(-3), Int64(-7)).pass
                @test compare_julia_wasm(max, Int64(0), Int64(-1)).pass
                @test compare_julia_wasm(max, Int64(0), Int64(1)).pass
                @test compare_julia_wasm(max, -1.5, 2.5).pass
                @test compare_julia_wasm(max, 0.0, 1.0e300).pass
            end

            # ============================================
            # Extended div/mod/rem edge cases
            # ============================================
            @testset "div extended" begin
                @test compare_julia_wasm(div, Int64(-17), Int64(-5)).pass
                @test compare_julia_wasm(div, Int64(1), Int64(1)).pass
                @test compare_julia_wasm(div, Int64(100), Int64(3)).pass
                @test compare_julia_wasm(div, Int64(7), Int64(7)).pass
                @test compare_julia_wasm(div, Int64(1000000), Int64(7)).pass
            end

            @testset "mod extended" begin
                @test compare_julia_wasm(mod, Int64(-17), Int64(-5)).pass
                @test compare_julia_wasm(mod, Int64(10), Int64(10)).pass
                @test compare_julia_wasm(mod, Int64(100), Int64(3)).pass
                @test compare_julia_wasm(mod, Int64(7), Int64(3)).pass
                @test compare_julia_wasm(mod, Int64(1), Int64(1000000)).pass
            end

            @testset "rem extended" begin
                @test compare_julia_wasm(rem, Int64(-17), Int64(-5)).pass
                @test compare_julia_wasm(rem, Int64(10), Int64(10)).pass
                @test compare_julia_wasm(rem, Int64(100), Int64(3)).pass
                @test compare_julia_wasm(rem, Int64(7), Int64(3)).pass
                @test compare_julia_wasm(rem, Int64(1), Int64(1000000)).pass
            end

            # ============================================
            # Extended gcd/lcm edge cases
            # ============================================
            @testset "gcd extended" begin
                @test compare_julia_wasm(gcd, Int64(100), Int64(100)).pass
                @test compare_julia_wasm(gcd, Int64(-12), Int64(8)).pass
                @test compare_julia_wasm(gcd, Int64(12), Int64(-8)).pass
                @test compare_julia_wasm(gcd, Int64(-12), Int64(-8)).pass
                @test compare_julia_wasm(gcd, Int64(1), Int64(1000000)).pass
                @test compare_julia_wasm(gcd, Int64(1000000), Int64(1)).pass
            end

            @testset "lcm extended" begin
                @test compare_julia_wasm(lcm, Int64(1), Int64(1)).pass
                @test compare_julia_wasm(lcm, Int64(5), Int64(5)).pass
                @test compare_julia_wasm(lcm, Int64(12), Int64(8)).pass
                @test compare_julia_wasm(lcm, Int64(7), Int64(11)).pass
            end

            # ============================================
            # Extended iseven/isodd edge cases
            # ============================================
            @testset "iseven/isodd extended" begin
                @test compare_julia_wasm(iseven, Int64(100)).pass
                @test compare_julia_wasm(iseven, Int64(-100)).pass
                @test compare_julia_wasm(iseven, Int64(1)).pass
                @test compare_julia_wasm(iseven, Int64(-1)).pass
                @test compare_julia_wasm(isodd, Int64(99)).pass
                @test compare_julia_wasm(isodd, Int64(-99)).pass
                @test compare_julia_wasm(isodd, Int64(100)).pass
                @test compare_julia_wasm(isodd, Int64(0)).pass
            end

            # ============================================
            # Extended isnan edge cases
            # ============================================
            @testset "isnan extended" begin
                @test compare_julia_wasm(isnan, 0.0).pass
                @test compare_julia_wasm(isnan, -0.0).pass
                @test compare_julia_wasm(isnan, 1.0e300).pass
                @test compare_julia_wasm(isnan, -1.0e300).pass
                _cf1_isnan_inf()::Bool = isnan(Inf)
                _cf1_isnan_neginf()::Bool = isnan(-Inf)
                @test compare_julia_wasm(_cf1_isnan_inf).pass
                @test compare_julia_wasm(_cf1_isnan_neginf).pass
            end

            # ============================================
            # Extended isfinite edge cases
            # ============================================
            @testset "isfinite extended" begin
                @test compare_julia_wasm(isfinite, 0.0).pass
                @test compare_julia_wasm(isfinite, -0.0).pass
                @test compare_julia_wasm(isfinite, 1.0e-300).pass
                @test compare_julia_wasm(isfinite, -1.0).pass
            end

            # ============================================
            # Extended iszero/isone edge cases
            # ============================================
            @testset "iszero extended" begin
                @test compare_julia_wasm(iszero, Int64(-1)).pass
                @test compare_julia_wasm(iszero, Int64(1)).pass
                @test compare_julia_wasm(iszero, 0.0).pass
                @test compare_julia_wasm(iszero, -0.0).pass
                @test compare_julia_wasm(iszero, 1.0e-300).pass
                @test compare_julia_wasm(iszero, 1.0).pass
            end

            @testset "isone extended" begin
                @test compare_julia_wasm(isone, Int64(0)).pass
                @test compare_julia_wasm(isone, Int64(-1)).pass
                @test compare_julia_wasm(isone, Int64(2)).pass
                @test compare_julia_wasm(isone, 0.0).pass
                @test compare_julia_wasm(isone, 1.0).pass
                @test compare_julia_wasm(isone, -1.0).pass
            end

            # ============================================
            # Extended zero/one edge cases
            # ============================================
            @testset "zero/one extended" begin
                @test compare_julia_wasm(zero, Int64(0)).pass
                @test compare_julia_wasm(zero, Int64(-5)).pass
                @test compare_julia_wasm(zero, -3.14).pass
                @test compare_julia_wasm(one, Int64(0)).pass
                @test compare_julia_wasm(one, Int64(-5)).pass
                @test compare_julia_wasm(one, -3.14).pass
            end

            # ============================================
            # Extended minmax edge cases
            # ============================================
            @testset "minmax extended" begin
                _cf1_minmax_lo_f(a::Float64, b::Float64)::Float64 = minmax(a, b)[1]
                _cf1_minmax_hi_f(a::Float64, b::Float64)::Float64 = minmax(a, b)[2]
                @test compare_julia_wasm(_cf1_minmax_lo_f, 1.5, 3.7).pass
                @test compare_julia_wasm(_cf1_minmax_hi_f, 1.5, 3.7).pass
                @test compare_julia_wasm(_cf1_minmax_lo_f, -2.0, -5.0).pass
                @test compare_julia_wasm(_cf1_minmax_hi_f, -2.0, -5.0).pass
            end

            # ============================================
            # Extended divrem edge cases
            # ============================================
            @testset "divrem extended" begin
                _cf1_divrem_q_neg(a::Int64, b::Int64)::Int64 = divrem(a, b)[1]
                _cf1_divrem_r_neg(a::Int64, b::Int64)::Int64 = divrem(a, b)[2]
                @test compare_julia_wasm(_cf1_divrem_q_neg, Int64(-17), Int64(-5)).pass
                @test compare_julia_wasm(_cf1_divrem_r_neg, Int64(-17), Int64(-5)).pass
                @test compare_julia_wasm(_cf1_divrem_q_neg, Int64(1), Int64(1)).pass
                @test compare_julia_wasm(_cf1_divrem_r_neg, Int64(1), Int64(1)).pass
            end
        end

        # ================================================================
        # CF-2003: String FULLTEST — edge cases + more coverage
        # ================================================================
        # CF-2003 String FULLTEST — REMOVED (placeholder @test_broken false stub)

        # ================================================================
        # CF-3003: Collections FULLTEST — closures, kwargs, edge cases
        # ================================================================

        # Named wrapper functions for collections (avoid invalid anonymous syntax)
        _ft_sum(v::Vector{Int64})::Int64 = sum(v)
        _ft_prod(v::Vector{Int64})::Int64 = prod(v)
        _ft_reduce_plus(v::Vector{Int64})::Int64 = reduce(+, v)
        _ft_foldl_minus(v::Vector{Int64})::Int64 = foldl(-, v)
        _ft_foldr_minus(v::Vector{Int64})::Int64 = foldr(-, v)
        _ft_mapreduce_abs(v::Vector{Int64})::Int64 = mapreduce(abs, +, v)
        _ft_mapreduce_sq(v::Vector{Int64})::Int64 = mapreduce(x -> x * x, +, v)
        _ft_minimum(v::Vector{Int64})::Int64 = minimum(v)
        _ft_maximum(v::Vector{Int64})::Int64 = maximum(v)
        _ft_extrema_lo(v::Vector{Int64})::Int64 = extrema(v)[1]
        _ft_extrema_hi(v::Vector{Int64})::Int64 = extrema(v)[2]
        _ft_findmin_val(v::Vector{Int64})::Int64 = findmin(v)[1]
        _ft_findmin_idx(v::Vector{Int64})::Int64 = Int64(findmin(v)[2])
        _ft_findmax_val(v::Vector{Int64})::Int64 = findmax(v)[1]
        _ft_findmax_idx(v::Vector{Int64})::Int64 = Int64(findmax(v)[2])
        _ft_argmin(v::Vector{Int64})::Int64 = Int64(argmin(v))
        _ft_argmax(v::Vector{Int64})::Int64 = Int64(argmax(v))
        _ft_any_even(v::Vector{Int64})::Bool = any(iseven, v)
        _ft_all_pos(v::Vector{Int64})::Bool = all(x -> x > Int64(0), v)
        _ft_count_even(v::Vector{Int64})::Int64 = Int64(count(iseven, v))
        _ft_count_gt3(v::Vector{Int64})::Int64 = Int64(count(x -> x > Int64(3), v))
        _ft_filter_even(v::Vector{Int64})::Vector{Int64} = filter(iseven, v)
        _ft_filter_gt3(v::Vector{Int64})::Vector{Int64} = filter(x -> x > Int64(3), v)
        _ft_map_double(v::Vector{Int64})::Vector{Int64} = map(x -> x * Int64(2), v)
        _ft_map_abs(v::Vector{Int64})::Vector{Int64} = map(abs, v)
        _ft_map_sq(v::Vector{Int64})::Vector{Int64} = map(x -> x * x, v)
        _ft_sort_asc(v::Vector{Int64})::Vector{Int64} = sort(v)
        _ft_sort_rev(v::Vector{Int64})::Vector{Int64} = sort(v, rev=true)
        _ft_reverse_v(v::Vector{Int64})::Vector{Int64} = reverse(v)
        _ft_accum_plus(v::Vector{Int64})::Vector{Int64} = accumulate(+, v)
        _ft_accum_mul(v::Vector{Int64})::Vector{Int64} = accumulate(*, v)
        _ft_unique_v(v::Vector{Int64})::Vector{Int64} = unique(v)
        _ft_foreach(v::Vector{Int64})::Int64 = begin
            s = Ref(Int64(0))
            foreach(x -> s[] += x, v)
            s[]
        end

        @testset "CF-3003 Collections FULLTEST" begin

            @testset "sum" begin
                @test compare_julia_wasm_vec(_ft_sum, Int64[]).pass
                @test compare_julia_wasm_vec(_ft_sum, Int64[42]).pass
                @test compare_julia_wasm_vec(_ft_sum, collect(Int64, 1:100)).pass
                @test compare_julia_wasm_vec(_ft_sum, Int64[-1, -2, -3]).pass
                @test compare_julia_wasm_vec(_ft_sum, Int64[typemax(Int64) - Int64(1), Int64(1)]).pass
            end

            @testset "prod" begin
                @test compare_julia_wasm_vec(_ft_prod, Int64[1, 2, 3, 4]).pass
                @test compare_julia_wasm_vec(_ft_prod, Int64[2, 3, 5]).pass
                @test compare_julia_wasm_vec(_ft_prod, Int64[1]).pass
                @test compare_julia_wasm_vec(_ft_prod, Int64[-1, -2, -3]).pass
            end

            @testset "reduce/foldl/foldr" begin
                @test compare_julia_wasm_vec(_ft_reduce_plus, Int64[1, 2, 3]).pass
                @test compare_julia_wasm_vec(_ft_foldl_minus, Int64[10, 3, 2]).pass
                @test compare_julia_wasm_vec(_ft_foldr_minus, Int64[10, 3, 2]).pass
                @test compare_julia_wasm_vec(_ft_foldl_minus, Int64[100]).pass
            end

            @testset "mapreduce" begin
                @test compare_julia_wasm_vec(_ft_mapreduce_abs, Int64[-1, -2, 3]).pass
                @test compare_julia_wasm_vec(_ft_mapreduce_sq, Int64[1, 2, 3]).pass
                @test compare_julia_wasm_vec(_ft_mapreduce_abs, Int64[0, 0, 0]).pass
            end

            @testset "minimum/maximum" begin
                @test compare_julia_wasm_vec(_ft_minimum, Int64[5, 1, 3, 2, 4]).pass
                @test compare_julia_wasm_vec(_ft_maximum, Int64[5, 1, 3, 2, 4]).pass
                @test compare_julia_wasm_vec(_ft_minimum, Int64[42]).pass
                @test compare_julia_wasm_vec(_ft_maximum, Int64[-10, -20, -5]).pass
                @test compare_julia_wasm_vec(_ft_minimum, Int64[-100, 0, 100]).pass
            end

            @testset "extrema" begin
                @test compare_julia_wasm_vec(_ft_extrema_lo, Int64[3, 1, 5, 2]).pass
                @test compare_julia_wasm_vec(_ft_extrema_hi, Int64[3, 1, 5, 2]).pass
                @test compare_julia_wasm_vec(_ft_extrema_lo, Int64[7]).pass
                @test compare_julia_wasm_vec(_ft_extrema_hi, Int64[7]).pass
            end

            @testset "findmin/findmax" begin
                @test compare_julia_wasm_vec(_ft_findmin_val, Int64[3, 1, 5, 2]).pass
                @test compare_julia_wasm_vec(_ft_findmin_idx, Int64[3, 1, 5, 2]).pass
                @test compare_julia_wasm_vec(_ft_findmax_val, Int64[3, 1, 5, 2]).pass
                @test compare_julia_wasm_vec(_ft_findmax_idx, Int64[3, 1, 5, 2]).pass
                @test compare_julia_wasm_vec(_ft_findmin_val, Int64[10]).pass
                @test compare_julia_wasm_vec(_ft_findmax_idx, Int64[10]).pass
            end

            @testset "argmin/argmax" begin
                @test compare_julia_wasm_vec(_ft_argmin, Int64[3, 1, 5, 2]).pass
                @test compare_julia_wasm_vec(_ft_argmax, Int64[3, 1, 5, 2]).pass
                @test compare_julia_wasm_vec(_ft_argmin, Int64[10, 20, 30]).pass
                @test compare_julia_wasm_vec(_ft_argmax, Int64[10, 20, 30]).pass
            end

            @testset "any/all/count closures" begin
                @test compare_julia_wasm_vec(_ft_any_even, Int64[1, 3, 5]).pass
                @test compare_julia_wasm_vec(_ft_any_even, Int64[1, 2, 3]).pass
                @test compare_julia_wasm_vec(_ft_any_even, Int64[]).pass
                @test compare_julia_wasm_vec(_ft_all_pos, Int64[1, 2, 3]).pass
                @test compare_julia_wasm_vec(_ft_all_pos, Int64[-1, 2, 3]).pass
                @test compare_julia_wasm_vec(_ft_all_pos, Int64[]).pass
                @test compare_julia_wasm_vec(_ft_count_even, Int64[1, 2, 3, 4, 5, 6]).pass
                @test compare_julia_wasm_vec(_ft_count_gt3, Int64[1, 2, 3, 4, 5]).pass
                @test compare_julia_wasm_vec(_ft_count_even, Int64[]).pass
            end

            @testset "filter closures" begin
                @test compare_julia_wasm_vec(_ft_filter_even, Int64[1, 2, 3, 4, 5, 6]).pass
                @test compare_julia_wasm_vec(_ft_filter_gt3, Int64[1, 2, 3, 4, 5]).pass
                @test compare_julia_wasm_vec(_ft_filter_even, Int64[1, 3, 5]).pass
                @test compare_julia_wasm_vec(_ft_filter_even, Int64[]).pass
                @test compare_julia_wasm_vec(_ft_filter_gt3, Int64[10, 20, 30]).pass
            end

            @testset "map closures" begin
                @test compare_julia_wasm_vec(_ft_map_double, Int64[1, 2, 3]).pass
                @test compare_julia_wasm_vec(_ft_map_abs, Int64[-1, -2, 3]).pass
                @test compare_julia_wasm_vec(_ft_map_sq, Int64[1, 2, 3, 4]).pass
                @test compare_julia_wasm_vec(_ft_map_double, Int64[]).pass
                @test compare_julia_wasm_vec(_ft_map_abs, Int64[0, -5, 5]).pass
            end

            @testset "sort kwargs" begin
                @test compare_julia_wasm_vec(_ft_sort_asc, Int64[3, 1, 4, 1, 5]).pass
                @test compare_julia_wasm_vec(_ft_sort_rev, Int64[3, 1, 4, 1, 5]).pass
                @test compare_julia_wasm_vec(_ft_sort_asc, Int64[]).pass
                @test compare_julia_wasm_vec(_ft_sort_asc, Int64[42]).pass
                @test compare_julia_wasm_vec(_ft_sort_asc, collect(Int64, 10:-1:1)).pass
                @test compare_julia_wasm_vec(_ft_sort_rev, Int64[-3, -1, -4]).pass
            end

            @testset "reverse" begin
                @test compare_julia_wasm_vec(_ft_reverse_v, Int64[1, 2, 3, 4, 5]).pass
                @test compare_julia_wasm_vec(_ft_reverse_v, Int64[42]).pass
                @test compare_julia_wasm_vec(_ft_reverse_v, Int64[]).pass
            end

            @testset "accumulate" begin
                @test compare_julia_wasm_vec(_ft_accum_plus, Int64[1, 2, 3, 4]).pass
                @test compare_julia_wasm_vec(_ft_accum_mul, Int64[1, 2, 3, 4]).pass
                @test compare_julia_wasm_vec(_ft_accum_plus, Int64[10]).pass
            end

            @testset "unique" begin
                @test compare_julia_wasm_vec(_ft_unique_v, Int64[1, 2, 2, 3, 1, 3]).pass
                @test compare_julia_wasm_vec(_ft_unique_v, Int64[1, 1, 1]).pass
                @test compare_julia_wasm_vec(_ft_unique_v, Int64[1, 2, 3]).pass
                @test compare_julia_wasm_vec(_ft_unique_v, Int64[]).pass
            end

            @testset "foreach" begin
                @test compare_julia_wasm_vec(_ft_foreach, Int64[1, 2, 3]).pass
                @test compare_julia_wasm_vec(_ft_foreach, Int64[10, 20]).pass
                @test compare_julia_wasm_vec(_ft_foreach, Int64[]).pass
            end
        end

        # ================================================================
        # CF-4003: Array Mutation FULLTEST — more edge cases
        # ================================================================

        # Named wrappers for array mutation
        _ft_arr_len(v::Vector{Int64})::Int64 = Int64(length(v))
        _ft_arr_copy(v::Vector{Int64})::Vector{Int64} = copy(v)
        _ft_arr_rev(v::Vector{Int64})::Vector{Int64} = reverse(v)
        _ft_arr_vec(v::Vector{Int64})::Vector{Int64} = vec(v)
        _ft_arr_fill(v::Vector{Int64})::Vector{Int64} = fill!(v, Int64(0))
        _ft_arr_empty_len(v::Vector{Int64})::Int64 = begin empty!(v); Int64(length(v)) end
        _ft_arr_resize_len(v::Vector{Int64})::Int64 = begin resize!(v, 5); Int64(length(v)) end

        _ft_push_chain(v::Vector{Int64})::Vector{Int64} = begin
            push!(v, Int64(10))
            push!(v, Int64(20))
            push!(v, Int64(30))
            v
        end
        _ft_pop_push(v::Vector{Int64})::Vector{Int64} = begin
            x = pop!(v)
            push!(v, x + Int64(100))
            v
        end
        _ft_ins_mid(v::Vector{Int64})::Vector{Int64} = (insert!(v, 3, Int64(99)); v)
        _ft_del_len(v::Vector{Int64})::Int64 = begin
            deleteat!(v, 1)
            Int64(length(v))
        end
        _ft_spl_ret(v::Vector{Int64})::Int64 = splice!(v, 3)

        @testset "CF-4003 Array Mutation FULLTEST" begin

            @testset "push! chaining" begin
                @test compare_julia_wasm_vec(_ft_push_chain, Int64[1]).pass
                @test compare_julia_wasm_vec(_ft_push_chain, Int64[]).pass
            end

            @testset "pop+push round trip" begin
                @test compare_julia_wasm_vec(_ft_pop_push, Int64[1, 2, 3]).pass
            end

            @testset "insert! positions" begin
                @test compare_julia_wasm_vec(_ft_ins_mid, Int64[1, 2, 3, 4, 5]).pass
            end

            @testset "deleteat! length" begin
                @test compare_julia_wasm_vec(_ft_del_len, Int64[1, 2, 3]).pass
            end

            @testset "splice! return" begin
                @test compare_julia_wasm_vec(_ft_spl_ret, Int64[10, 20, 30, 40]).pass
            end

            @testset "non-mutating ops" begin
                @test compare_julia_wasm_vec(_ft_arr_len, Int64[1, 2, 3]).pass
                @test compare_julia_wasm_vec(_ft_arr_copy, Int64[1, 2, 3]).pass  # returns wrong result
                @test compare_julia_wasm_vec(_ft_arr_rev, Int64[1, 2, 3]).pass
                @test compare_julia_wasm_vec(_ft_arr_vec, Int64[1, 2, 3]).pass
            end

            @testset "fill!/empty!/resize!" begin
                @test compare_julia_wasm_vec(_ft_arr_fill, Int64[1, 2, 3]).pass
                @test compare_julia_wasm_vec(_ft_arr_empty_len, Int64[1, 2, 3]).pass  # returns wrong result
                @test compare_julia_wasm_vec(_ft_arr_resize_len, Int64[1, 2, 3]).pass
            end
        end

        # ================================================================
        # CF-5003: Type Conversion FULLTEST
        # ================================================================
        @testset "CF-5003 Type Conversion FULLTEST" begin

            # convert between types
            _ft_i2f(x::Int64)::Float64 = convert(Float64, x)
            _ft_f2i(x::Float64)::Int64 = convert(Int64, x)
            _ft_i64_i32(x::Int64)::Int32 = convert(Int32, x)
            @testset "convert" begin
                @test compare_julia_wasm(_ft_i2f, Int64(42)).pass
                @test compare_julia_wasm(_ft_i2f, Int64(-7)).pass
                @test compare_julia_wasm(_ft_i2f, Int64(0)).pass
                @test compare_julia_wasm(_ft_f2i, 42.0).pass
                @test compare_julia_wasm(_ft_f2i, -7.0).pass
                @test compare_julia_wasm(_ft_i64_i32, Int64(100)).pass
            end

            # sizeof
            @testset "sizeof" begin
                @test compare_julia_wasm(sizeof, Int32(0)).pass
                @test compare_julia_wasm(sizeof, Int64(0)).pass
                @test compare_julia_wasm(sizeof, 0.0).pass
            end

            # isless
            @testset "isless" begin
                @test compare_julia_wasm(isless, Int64(1), Int64(2)).pass
                @test compare_julia_wasm(isless, Int64(2), Int64(1)).pass
                @test compare_julia_wasm(isless, Int64(1), Int64(1)).pass
                @test compare_julia_wasm(isless, 1.0, 2.0).pass
                @test compare_julia_wasm(isless, 2.0, 1.0).pass
            end

            # string(x) length verification
            _ft_str_len(x::Int64)::Int = length(string(x))
            @testset "string(x)" begin
                @test compare_julia_wasm(_ft_str_len, Int64(42)).pass
                @test compare_julia_wasm(_ft_str_len, Int64(0)).pass
                @test compare_julia_wasm(_ft_str_len, Int64(-123)).pass
                @test compare_julia_wasm(_ft_str_len, Int64(1000000)).pass
            end
        end

        # ================================================================
        # CF-6003: Iterator FULLTEST
        # ================================================================
        @testset "CF-6003 Iterator FULLTEST" begin

            # eachindex
            @testset "eachindex" begin
                _ft_eachidx(v::Vector{Int64})::Int64 = begin
                    s = Int64(0)
                    for i in eachindex(v)
                        s += v[i]
                    end
                    s
                end
                @test compare_julia_wasm_vec(_ft_eachidx, Int64[10, 20, 30]).pass
                @test compare_julia_wasm_vec(_ft_eachidx, Int64[42]).pass
                @test compare_julia_wasm_vec(_ft_eachidx, Int64[]).pass
            end

            # enumerate
            @testset "enumerate" begin
                _ft_enum(v::Vector{Int64})::Int64 = begin
                    s = Int64(0)
                    for (i, x) in enumerate(v)
                        s += i * x
                    end
                    s
                end
                @test compare_julia_wasm_vec(_ft_enum, Int64[10, 20, 30]).pass
                @test compare_julia_wasm_vec(_ft_enum, Int64[5]).pass
            end

            # zip
            @testset "zip" begin
                _ft_zip(v::Vector{Int64})::Int64 = begin
                    # zip with itself reversed
                    s = Int64(0)
                    rv = reverse(v)
                    for (a, b) in zip(v, rv)
                        s += a * b
                    end
                    s
                end
                @test compare_julia_wasm_vec(_ft_zip, Int64[1, 2, 3]).pass
                @test compare_julia_wasm_vec(_ft_zip, Int64[10]).pass
            end

            # collect
            @testset "collect" begin
                _ft_collect(n::Int64)::Vector{Int64} = collect(Int64(1):n)
                @test compare_julia_wasm_vec(_ft_collect, Int64(5)).pass
                @test compare_julia_wasm_vec(_ft_collect, Int64(1)).pass
                @test compare_julia_wasm_vec(_ft_collect, Int64(10)).pass
            end

            # pairs
            @testset "pairs" begin
                _ft_pairs(v::Vector{Int64})::Int64 = begin
                    s = Int64(0)
                    for (i, x) in pairs(v)
                        s += i * x
                    end
                    s
                end
                @test compare_julia_wasm_vec(_ft_pairs, Int64[10, 20, 30]).pass
                @test compare_julia_wasm_vec(_ft_pairs, Int64[7]).pass
            end

            # Iterators.filter
            @testset "Iterators.filter" begin
                _ft_ifilt(v::Vector{Int64})::Int64 = begin
                    s = Int64(0)
                    for x in Iterators.filter(iseven, v)
                        s += x
                    end
                    s
                end
                @test compare_julia_wasm_vec(_ft_ifilt, Int64[1, 2, 3, 4, 5, 6]).pass
                @test compare_julia_wasm_vec(_ft_ifilt, Int64[1, 3, 5]).pass
                @test compare_julia_wasm_vec(_ft_ifilt, Int64[]).pass
            end

            # Iterators.map
            @testset "Iterators.map" begin
                _ft_imap(v::Vector{Int64})::Int64 = begin
                    s = Int64(0)
                    for x in Iterators.map(abs, v)
                        s += x
                    end
                    s
                end
                @test compare_julia_wasm_vec(_ft_imap, Int64[-1, -2, 3, -4]).pass
                @test compare_julia_wasm_vec(_ft_imap, Int64[1, 2, 3]).pass
            end

            # Iterators.take
            @testset "Iterators.take" begin
                _ft_itake(v::Vector{Int64})::Int64 = begin
                    s = Int64(0)
                    for x in Iterators.take(v, 3)
                        s += x
                    end
                    s
                end
                @test compare_julia_wasm_vec(_ft_itake, Int64[10, 20, 30, 40, 50]).pass
                @test compare_julia_wasm_vec(_ft_itake, Int64[10, 20]).pass
            end

            # Iterators.drop
            @testset "Iterators.drop" begin
                _ft_idrop(v::Vector{Int64})::Int64 = begin
                    s = Int64(0)
                    for x in Iterators.drop(v, 2)
                        s += x
                    end
                    s
                end
                @test compare_julia_wasm_vec(_ft_idrop, Int64[10, 20, 30, 40, 50]).pass
                @test compare_julia_wasm_vec(_ft_idrop, Int64[10, 20]).pass
            end

            # Iterators.takewhile
            @testset "Iterators.takewhile" begin
                _ft_itw(v::Vector{Int64})::Int64 = begin
                    s = Int64(0)
                    for x in Iterators.takewhile(x -> x < Int64(30), v)
                        s += x
                    end
                    s
                end
                @test compare_julia_wasm_vec(_ft_itw, Int64[10, 20, 30, 40]).pass
                @test compare_julia_wasm_vec(_ft_itw, Int64[50, 60]).pass
            end

            # Iterators.dropwhile
            @testset "Iterators.dropwhile" begin
                _ft_idw(v::Vector{Int64})::Int64 = begin
                    s = Int64(0)
                    for x in Iterators.dropwhile(x -> x < Int64(30), v)
                        s += x
                    end
                    s
                end
                @test compare_julia_wasm_vec(_ft_idw, Int64[10, 20, 30, 40]).pass
                @test compare_julia_wasm_vec(_ft_idw, Int64[30, 40]).pass
            end

            # Iterators.flatten
            @testset "Iterators.flatten" begin
                _ft_iflat(n::Int64)::Int64 = begin
                    s = Int64(0)
                    for x in Iterators.flatten((Int64(1):n, Int64(10):Int64(10)+n))
                        s += x
                    end
                    s
                end
                @test compare_julia_wasm(_ft_iflat, Int64(3)).pass
                @test compare_julia_wasm(_ft_iflat, Int64(1)).pass
            end

            # CartesianIndices
            @testset "CartesianIndices" begin
                _ft_ci(v::Vector{Int64})::Int64 = begin
                    s = Int64(0)
                    for i in CartesianIndices(v)
                        s += v[i[1]]
                    end
                    s
                end
                @test compare_julia_wasm_vec(_ft_ci, Int64[10, 20, 30]).pass
                @test compare_julia_wasm_vec(_ft_ci, Int64[42]).pass
            end
        end

        # ================================================================
        # CF-7003: Dict/Set FULLTEST
        # ================================================================
        # CF-7003 Dict/Set FULLTEST — REMOVED (placeholder @test_broken false stub)

    end

    # ================================================================
    # STRESS-1000: Numeric Functions Type Matrix
    # ================================================================
    # Every numeric function × every applicable type, raw + binaryen.
    # Fixes: lcm(Int32) checked_smul tuple type, Inf/NaN JS bridge.

    @pphase "STRESS-1000: Numeric Type Matrix" begin

        # --- Single-arg: abs ---
        @testset "abs type matrix" begin
            @test compare_julia_wasm(abs, Int32(-5)).pass
            @test compare_julia_wasm(abs, Int32(-5); optimize=true).pass
            @test compare_julia_wasm(abs, Int64(-5)).pass
            @test compare_julia_wasm(abs, Int64(-5); optimize=true).pass
            @test compare_julia_wasm(abs, Float32(-3.14f0)).pass
            @test compare_julia_wasm(abs, Float32(-3.14f0); optimize=true).pass
            @test compare_julia_wasm(abs, Float64(-3.14)).pass
            @test compare_julia_wasm(abs, Float64(-3.14); optimize=true).pass
        end

        # --- Single-arg: sign ---
        @testset "sign type matrix" begin
            @test compare_julia_wasm(sign, Int32(-5)).pass
            @test compare_julia_wasm(sign, Int32(-5); optimize=true).pass
            @test compare_julia_wasm(sign, Int64(-5)).pass
            @test compare_julia_wasm(sign, Int64(-5); optimize=true).pass
            @test compare_julia_wasm(sign, Float32(-3.14f0)).pass
            @test compare_julia_wasm(sign, Float32(-3.14f0); optimize=true).pass
            @test compare_julia_wasm(sign, Float64(-3.14)).pass
            @test compare_julia_wasm(sign, Float64(-3.14); optimize=true).pass
        end

        # --- Single-arg: signbit ---
        @testset "signbit type matrix" begin
            @test compare_julia_wasm(signbit, Int32(-5)).pass
            @test compare_julia_wasm(signbit, Int32(-5); optimize=true).pass
            @test compare_julia_wasm(signbit, Int64(-5)).pass
            @test compare_julia_wasm(signbit, Int64(-5); optimize=true).pass
            @test compare_julia_wasm(signbit, UInt32(5)).pass
            @test compare_julia_wasm(signbit, UInt32(5); optimize=true).pass
            @test compare_julia_wasm(signbit, UInt64(5)).pass
            @test compare_julia_wasm(signbit, UInt64(5); optimize=true).pass
            @test compare_julia_wasm(signbit, Float32(-3.14f0)).pass
            @test compare_julia_wasm(signbit, Float32(-3.14f0); optimize=true).pass
            @test compare_julia_wasm(signbit, Float64(-3.14)).pass
            @test compare_julia_wasm(signbit, Float64(-3.14); optimize=true).pass
        end

        # --- Single-arg: iseven/isodd ---
        @testset "iseven/isodd type matrix" begin
            for f in [iseven, isodd]
                for T in [Int32, Int64, UInt32, UInt64]
                    @test compare_julia_wasm(f, T(6)).pass
                    @test compare_julia_wasm(f, T(6); optimize=true).pass
                end
            end
        end

        # --- Float predicates: isnan/isinf/isfinite ---
        @testset "float predicates type matrix" begin
            @test compare_julia_wasm(isnan, Float32(NaN32)).pass
            @test compare_julia_wasm(isnan, Float32(NaN32); optimize=true).pass
            @test compare_julia_wasm(isnan, Float64(NaN)).pass
            @test compare_julia_wasm(isnan, Float64(NaN); optimize=true).pass
            @test compare_julia_wasm(isinf, Float32(Inf32)).pass
            @test compare_julia_wasm(isinf, Float32(Inf32); optimize=true).pass
            @test compare_julia_wasm(isinf, Float64(Inf)).pass
            @test compare_julia_wasm(isinf, Float64(Inf); optimize=true).pass
            @test compare_julia_wasm(isfinite, Float32(1.0f0)).pass
            @test compare_julia_wasm(isfinite, Float32(1.0f0); optimize=true).pass
            @test compare_julia_wasm(isfinite, Float64(1.0)).pass
            @test compare_julia_wasm(isfinite, Float64(1.0); optimize=true).pass
        end

        # --- Single-arg: iszero/isone/zero/one ---
        @testset "iszero/isone/zero/one type matrix" begin
            for f in [iszero, isone, zero, one]
                for T in [Int32, Int64, UInt32, UInt64, Float32, Float64]
                    val = f in [iszero, zero] ? T(0) : T(1)
                    @test compare_julia_wasm(f, val).pass
                    @test compare_julia_wasm(f, val; optimize=true).pass
                end
            end
        end

        # --- Single-arg: typemin/typemax (signed only — unsigned max is bridge limitation) ---
        @testset "typemin/typemax type matrix" begin
            for f in [typemin, typemax]
                for T in [Int32, Int64]
                    @test compare_julia_wasm(f, T(0)).pass
                    @test compare_julia_wasm(f, T(0); optimize=true).pass
                end
            end
        end

        # --- Two-arg: min/max ---
        @testset "min/max type matrix" begin
            for f in [min, max]
                for T in [Int32, Int64, UInt32, UInt64, Float32, Float64]
                    @test compare_julia_wasm(f, T(3), T(7)).pass
                    @test compare_julia_wasm(f, T(3), T(7); optimize=true).pass
                end
            end
        end

        # --- Two-arg: div/mod/rem ---
        @testset "div/mod/rem type matrix" begin
            for f in [div, mod, rem]
                for T in [Int32, Int64]
                    @test compare_julia_wasm(f, T(7), T(3)).pass
                    @test compare_julia_wasm(f, T(7), T(3); optimize=true).pass
                end
            end
        end

        # --- Two-arg: gcd/lcm ---
        @testset "gcd/lcm type matrix" begin
            for f in [gcd, lcm]
                for T in [Int32, Int64]
                    @test compare_julia_wasm(f, T(12), T(8)).pass
                    @test compare_julia_wasm(f, T(12), T(8); optimize=true).pass
                end
            end
        end

        # --- Three-arg: clamp ---
        @testset "clamp type matrix" begin
            for T in [Int32, Int64, Float32, Float64]
                @test compare_julia_wasm(clamp, T(5), T(1), T(10)).pass
                @test compare_julia_wasm(clamp, T(5), T(1), T(10); optimize=true).pass
            end
        end
    end

    # ================================================================
    # STRESS-1001: Math Functions Type Matrix
    # ================================================================
    # Float32 + Float64 for all math functions, raw + binaryen.

    @pphase "STRESS-1001: Math Type Matrix" begin

        # --- WASM-native math (Float32 + Float64) ---
        @testset "WASM-native math Float32/Float64" begin
            for f in [sqrt, abs, floor, ceil, round, trunc]
                @test compare_julia_wasm(f, Float32(4.0f0)).pass
                @test compare_julia_wasm(f, Float32(4.0f0); optimize=true).pass
                @test compare_julia_wasm(f, Float64(4.0)).pass
                @test compare_julia_wasm(f, Float64(4.0); optimize=true).pass
            end
        end

        # --- Float operations ---
        @testset "copysign/flipsign/hypot Float32/Float64" begin
            for f in [copysign, flipsign]
                @test compare_julia_wasm(f, Float32(1.0f0), Float32(-1.0f0)).pass
                @test compare_julia_wasm(f, Float32(1.0f0), Float32(-1.0f0); optimize=true).pass
                @test compare_julia_wasm(f, Float64(1.0), Float64(-1.0)).pass
                @test compare_julia_wasm(f, Float64(1.0), Float64(-1.0); optimize=true).pass
            end
            @test compare_julia_wasm(hypot, Float32(3.0f0), Float32(4.0f0)).pass
            @test compare_julia_wasm(hypot, Float32(3.0f0), Float32(4.0f0); optimize=true).pass
            @test compare_julia_wasm(hypot, Float64(3.0), Float64(4.0)).pass
            @test compare_julia_wasm(hypot, Float64(3.0), Float64(4.0); optimize=true).pass
        end

        # --- fma/muladd ---
        @testset "fma/muladd Float32/Float64" begin
            for f in [fma, muladd]
                @test compare_julia_wasm(f, Float32(2.0f0), Float32(3.0f0), Float32(1.0f0)).pass
                @test compare_julia_wasm(f, Float32(2.0f0), Float32(3.0f0), Float32(1.0f0); optimize=true).pass
                @test compare_julia_wasm(f, Float64(2.0), Float64(3.0), Float64(1.0)).pass
                @test compare_julia_wasm(f, Float64(2.0), Float64(3.0), Float64(1.0); optimize=true).pass
            end
        end

        # --- Type conversions ---
        @testset "type conversions" begin
            @test compare_julia_wasm(Float64, Int32(5)).pass
            @test compare_julia_wasm(Float64, Int32(5); optimize=true).pass
            @test compare_julia_wasm(Float64, Int64(5)).pass
            @test compare_julia_wasm(Float64, Int64(5); optimize=true).pass
            @test compare_julia_wasm(Float64, Float32(3.14f0)).pass
            @test compare_julia_wasm(Float64, Float32(3.14f0); optimize=true).pass
            @test compare_julia_wasm(Float32, Int32(5)).pass
            @test compare_julia_wasm(Float32, Int32(5); optimize=true).pass
            @test compare_julia_wasm(Int32, Int64(42)).pass
            @test compare_julia_wasm(Int32, Int64(42); optimize=true).pass
            @test compare_julia_wasm(Int64, Int32(42)).pass
            @test compare_julia_wasm(Int64, Int32(42); optimize=true).pass
        end

        # --- Complex math (stackifier) ---
        @testset "trig/exp/log Float64" begin
            for f in [sin, cos, tan, exp, log, log2, log10, asin, acos, atan]
                @test compare_julia_wasm(f, Float64(1.0)).pass
                @test compare_julia_wasm(f, Float64(1.0); optimize=true).pass
            end
        end

        @testset "trig/log Float32" begin
            for f in [sin, cos, tan, log, log2, log10, asin, acos, atan]
                @test compare_julia_wasm(f, Float32(1.0f0)).pass
                @test compare_julia_wasm(f, Float32(1.0f0); optimize=true).pass
            end
        end

        # exp(Float32): the native Float32 kernel emitted invalid wasm (i64 vs anyref
        # in a local); fixed by redirecting through the Float64 kernel (≤1 ULP).
        @testset "exp(Float32)" begin
            @test compare_julia_wasm(exp, Float32(1.0f0)).pass
        end

        # isless(Float32): Base's Float32 isless emitted invalid wasm (i64 vs anyref),
        # so any Float32 ordering failed to compile. Surfaced by the fuzzer as
        # length(sort([0f0,0f0,0f0])); fixed with an isless(::Float32,::Float32) overlay.
        @testset "sort/isless(Float32)" begin
            f32_sort_len()::Int64 = length(sort([0.0f0, 0.0f0, 0.0f0]))
            @test compare_julia_wasm(f32_sort_len).pass  # 3
            f32_sort_min()::Float32 = sort(Float32[3, 1, 2])[1]
            @test compare_julia_wasm(f32_sort_min).pass  # 1.0f0
            f32_sort_max()::Float32 = sort(Float32[3, 1, 2])[3]
            @test compare_julia_wasm(f32_sort_max).pass  # 3.0f0
        end
    end

    # ================================================================
    # STRESS-1002: Collection Functions Type Matrix
    # ================================================================
    # Vector{Int64} and Vector{Float64} for all collection functions, raw + binaryen.

    @pphase "STRESS-1002: Collection Type Matrix" begin

        # --- Vector-returning functions ---
        _s1002_sort_i64(v::Vector{Int64})::Vector{Int64} = sort(v)
        _s1002_sort_f64(v::Vector{Float64})::Vector{Float64} = sort(v)
        _s1002_rev_i64(v::Vector{Int64})::Vector{Int64} = reverse(v)
        _s1002_rev_f64(v::Vector{Float64})::Vector{Float64} = reverse(v)
        _s1002_uniq_i64(v::Vector{Int64})::Vector{Int64} = unique(v)
        _s1002_uniq_f64(v::Vector{Float64})::Vector{Float64} = unique(v)
        _s1002_filt_i64(v::Vector{Int64})::Vector{Int64} = filter(iseven, v)
        _s1002_filt_f64(v::Vector{Float64})::Vector{Float64} = filter(x -> x > 0.0, v)
        _s1002_map_i64(v::Vector{Int64})::Vector{Int64} = map(abs, v)
        _s1002_map_f64(v::Vector{Float64})::Vector{Float64} = map(abs, v)
        _s1002_acc_i64(v::Vector{Int64})::Vector{Int64} = accumulate(+, v)
        _s1002_acc_f64(v::Vector{Float64})::Vector{Float64} = accumulate(+, v)

        @testset "sort" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s1002_sort_i64, Int64[3,1,2]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_sort_f64, Float64[3.0,1.0,2.0]; optimize=opt).pass
            end
        end

        @testset "reverse" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s1002_rev_i64, Int64[3,1,2]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_rev_f64, Float64[3.0,1.0,2.0]; optimize=opt).pass
            end
        end

        @testset "unique" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s1002_uniq_i64, Int64[1,2,2,3,1]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_uniq_f64, Float64[1.0,2.0,2.0,3.0,1.0]; optimize=opt).pass
            end
        end

        @testset "filter" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s1002_filt_i64, Int64[1,2,3,4,5,6]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_filt_f64, Float64[-1.0,2.0,-3.0,4.0]; optimize=opt).pass
            end
        end

        @testset "map" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s1002_map_i64, Int64[-3,1,-2]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_map_f64, Float64[-3.0,1.0,-2.0]; optimize=opt).pass
            end
        end

        @testset "accumulate" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s1002_acc_i64, Int64[1,2,3,4]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_acc_f64, Float64[1.0,2.0,3.0,4.0]; optimize=opt).pass
            end
        end

        # --- Scalar-returning vector functions ---
        _s1002_sum_i64(v::Vector{Int64})::Int64 = sum(v)
        _s1002_sum_f64(v::Vector{Float64})::Float64 = sum(v)
        _s1002_prod_i64(v::Vector{Int64})::Int64 = prod(v)
        _s1002_prod_f64(v::Vector{Float64})::Float64 = prod(v)
        _s1002_min_i64(v::Vector{Int64})::Int64 = minimum(v)
        _s1002_max_i64(v::Vector{Int64})::Int64 = maximum(v)
        _s1002_min_f64(v::Vector{Float64})::Float64 = minimum(v)
        _s1002_max_f64(v::Vector{Float64})::Float64 = maximum(v)
        _s1002_len_i64(v::Vector{Int64})::Int64 = Int64(length(v))
        _s1002_count_i64(v::Vector{Int64})::Int64 = Int64(count(iseven, v))
        _s1002_any_i64(v::Vector{Int64})::Int64 = any(iseven, v) ? Int64(1) : Int64(0)
        _s1002_all_i64(v::Vector{Int64})::Int64 = all(iseven, v) ? Int64(1) : Int64(0)
        _s1002_reduce_i64(v::Vector{Int64})::Int64 = reduce(+, v)

        @testset "sum/prod" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s1002_sum_i64, Int64[1,2,3,4]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_sum_f64, Float64[1.0,2.0,3.0,4.0]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_prod_i64, Int64[1,2,3,4]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_prod_f64, Float64[1.0,2.0,3.0,4.0]; optimize=opt).pass
            end
        end

        @testset "minimum/maximum" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s1002_min_i64, Int64[3,1,2]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_max_i64, Int64[3,1,2]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_min_f64, Float64[3.0,1.0,2.0]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_max_f64, Float64[3.0,1.0,2.0]; optimize=opt).pass
            end
        end

        @testset "length/count/any/all/reduce" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s1002_len_i64, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_count_i64, Int64[1,2,3,4,5,6]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_any_i64, Int64[1,3,4]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_all_i64, Int64[2,4,6]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_reduce_i64, Int64[1,2,3,4]; optimize=opt).pass
            end
        end

        # --- Compositions ---
        _s1002_fms(v::Vector{Int64})::Int64 = sum(map(abs, filter(isodd, v)))
        _s1002_usr(v::Vector{Int64})::Vector{Int64} = reverse(sort(unique(v)))
        _s1002_af(v::Vector{Int64})::Vector{Int64} = filter(x -> x > Int64(5), accumulate(+, v))

        @testset "compositions" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s1002_fms, Int64[-3, 2, -5, 4, 7]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_usr, Int64[3, 1, 2, 1, 3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1002_af, Int64[1, 2, 3, 4]; optimize=opt).pass
            end
        end
    end

    # ================================================================
    # STRESS-1003: Array Mutation Type Matrix
    # ================================================================

    @pphase "STRESS-1003: Array Mutation Type Matrix" begin

        # --- Int64 variants ---
        _s1003_push_i64(v::Vector{Int64})::Vector{Int64} = (push!(v, Int64(99)); v)
        _s1003_pop_i64(v::Vector{Int64})::Int64 = pop!(v)
        _s1003_pushf_i64(v::Vector{Int64})::Vector{Int64} = (pushfirst!(v, Int64(0)); v)
        _s1003_popf_i64(v::Vector{Int64})::Int64 = popfirst!(v)
        _s1003_ins_i64(v::Vector{Int64})::Vector{Int64} = (insert!(v, Int64(2), Int64(99)); v)
        _s1003_del_i64(v::Vector{Int64})::Vector{Int64} = (deleteat!(v, Int64(2)); v)
        _s1003_empty_i64(v::Vector{Int64})::Int64 = (empty!(v); Int64(length(v)))
        _s1003_sorti_i64(v::Vector{Int64})::Vector{Int64} = (sort!(v); v)
        _s1003_revi_i64(v::Vector{Int64})::Vector{Int64} = (reverse!(v); v)
        _s1003_resize_i64(v::Vector{Int64})::Int64 = (resize!(v, Int64(5)); Int64(length(v)))
        _s1003_splice_i64(v::Vector{Int64})::Int64 = splice!(v, Int64(2))
        _s1003_append_i64(v::Vector{Int64})::Vector{Int64} = (append!(v, Int64[10,20]); v)
        _s1003_prepend_i64(v::Vector{Int64})::Vector{Int64} = (prepend!(v, Int64[10,20]); v)
        _s1003_fill_i64(v::Vector{Int64})::Vector{Int64} = fill!(v, Int64(7))

        # --- Float64 variants ---
        _s1003_push_f64(v::Vector{Float64})::Vector{Float64} = (push!(v, 99.0); v)
        _s1003_pop_f64(v::Vector{Float64})::Float64 = pop!(v)
        _s1003_pushf_f64(v::Vector{Float64})::Vector{Float64} = (pushfirst!(v, 0.0); v)
        _s1003_popf_f64(v::Vector{Float64})::Float64 = popfirst!(v)
        _s1003_ins_f64(v::Vector{Float64})::Vector{Float64} = (insert!(v, Int64(2), 99.0); v)
        _s1003_del_f64(v::Vector{Float64})::Vector{Float64} = (deleteat!(v, Int64(2)); v)
        _s1003_empty_f64(v::Vector{Float64})::Int64 = (empty!(v); Int64(length(v)))
        _s1003_sorti_f64(v::Vector{Float64})::Vector{Float64} = (sort!(v); v)
        _s1003_revi_f64(v::Vector{Float64})::Vector{Float64} = (reverse!(v); v)
        _s1003_resize_f64(v::Vector{Float64})::Int64 = (resize!(v, Int64(5)); Int64(length(v)))
        _s1003_splice_f64(v::Vector{Float64})::Float64 = splice!(v, Int64(2))
        _s1003_append_f64(v::Vector{Float64})::Vector{Float64} = (append!(v, Float64[10.0,20.0]); v)
        _s1003_prepend_f64(v::Vector{Float64})::Vector{Float64} = (prepend!(v, Float64[10.0,20.0]); v)
        _s1003_fill_f64(v::Vector{Float64})::Vector{Float64} = fill!(v, 7.0)

        @testset "push!/pop! (Int64 + Float64)" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s1003_push_i64, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_push_f64, Float64[1.0,2.0,3.0]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_pop_i64, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_pop_f64, Float64[1.0,2.0,3.0]; optimize=opt).pass
            end
        end

        @testset "pushfirst!/popfirst! (Int64 + Float64)" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s1003_pushf_i64, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_pushf_f64, Float64[1.0,2.0,3.0]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_popf_i64, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_popf_f64, Float64[1.0,2.0,3.0]; optimize=opt).pass
            end
        end

        @testset "insert!/deleteat!/empty! (Int64 + Float64)" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s1003_ins_i64, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_ins_f64, Float64[1.0,2.0,3.0]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_del_i64, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_del_f64, Float64[1.0,2.0,3.0]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_empty_i64, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_empty_f64, Float64[1.0,2.0,3.0]; optimize=opt).pass
            end
        end

        @testset "sort!/reverse!/resize!/splice! (Int64 + Float64)" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s1003_sorti_i64, Int64[3,1,2]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_sorti_f64, Float64[3.0,1.0,2.0]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_revi_i64, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_revi_f64, Float64[1.0,2.0,3.0]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_resize_i64, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_resize_f64, Float64[1.0,2.0,3.0]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_splice_i64, Int64[10,20,30]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_splice_f64, Float64[10.0,20.0,30.0]; optimize=opt).pass
            end
        end

        @testset "append!/prepend!/fill! (Int64 + Float64)" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s1003_append_i64, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_append_f64, Float64[1.0,2.0,3.0]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_prepend_i64, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_prepend_f64, Float64[1.0,2.0,3.0]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_fill_i64, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s1003_fill_f64, Float64[1.0,2.0,3.0]; optimize=opt).pass
            end
        end
    end

    # ================================================================
    # STRESS-1004: String Functions Binaryen Verification
    # ================================================================
    # All 37 string functions already work — verify each with optimize=true.
    # String functions use zero-arg wrappers (hardcode constants internally),
    # so compare_julia_wasm works directly.

    @pphase "STRESS-1004: String Functions Binaryen" begin

        # --- Basic string ops ---
        _s1004_sizeof()::Int64 = sizeof("hello")
        _s1004_length()::Int64 = length("hello")
        _s1004_concat_len()::Int64 = length("hello" * " world")
        _s1004_hash()::Int32 = str_hash("hello")
        _s1004_char()::Int64 = Int64(str_char("hello", Int32(1)))

        @testset "basic (sizeof/length/concat/hash/char)" begin
            for opt in [false, true]
                @test compare_julia_wasm(_s1004_sizeof; optimize=opt).pass
                @test compare_julia_wasm(_s1004_length; optimize=opt).pass
                @test compare_julia_wasm(_s1004_concat_len; optimize=opt).pass
                @test compare_julia_wasm(_s1004_hash; optimize=opt).pass
                @test compare_julia_wasm(_s1004_char; optimize=opt).pass
            end
        end

        # --- Search ops ---
        _s1004_contains_y()::Int32 = contains("hello world", "world") ? Int32(1) : Int32(0)
        _s1004_contains_n()::Int32 = contains("hello", "xyz") ? Int32(1) : Int32(0)
        _s1004_starts_y()::Int32 = startswith("hello", "hel") ? Int32(1) : Int32(0)
        _s1004_ends_y()::Int32 = endswith("hello", "llo") ? Int32(1) : Int32(0)
        _s1004_find()::Int64 = Int64(findfirst("world", "hello world").start)

        @testset "search (contains/startswith/endswith/find)" begin
            for opt in [false, true]
                @test compare_julia_wasm(_s1004_contains_y; optimize=opt).pass
                @test compare_julia_wasm(_s1004_contains_n; optimize=opt).pass
                @test compare_julia_wasm(_s1004_starts_y; optimize=opt).pass
                @test compare_julia_wasm(_s1004_ends_y; optimize=opt).pass
                @test compare_julia_wasm(_s1004_find; optimize=opt).pass
            end
        end

        # --- Case conversion ---
        _s1004_upper()::Int64 = length(uppercase("hello"))
        _s1004_lower()::Int64 = length(lowercase("HELLO"))
        _s1004_tc()::Int32 = titlecase("hello world") == "Hello World" ? Int32(1) : Int32(0)
        _s1004_lcf()::Int32 = lowercasefirst("Hello") == "hello" ? Int32(1) : Int32(0)
        _s1004_ucf()::Int32 = uppercasefirst("hello") == "Hello" ? Int32(1) : Int32(0)

        @testset "case (upper/lower/titlecase/lcf/ucf)" begin
            for opt in [false, true]
                @test compare_julia_wasm(_s1004_upper; optimize=opt).pass
                @test compare_julia_wasm(_s1004_lower; optimize=opt).pass
                @test compare_julia_wasm(_s1004_tc; optimize=opt).pass
                @test compare_julia_wasm(_s1004_lcf; optimize=opt).pass
                @test compare_julia_wasm(_s1004_ucf; optimize=opt).pass
            end
        end

        # --- Trim ops ---
        _s1004_strip()::Int32 = strip("  hello  ") == "hello" ? Int32(1) : Int32(0)
        _s1004_lstrip()::Int64 = length(lstrip("  hello  "))
        _s1004_rstrip()::Int64 = length(rstrip("  hello  "))

        @testset "trim (strip/lstrip/rstrip)" begin
            for opt in [false, true]
                @test compare_julia_wasm(_s1004_strip; optimize=opt).pass
                @test compare_julia_wasm(_s1004_lstrip; optimize=opt).pass
                @test compare_julia_wasm(_s1004_rstrip; optimize=opt).pass
            end
        end

        # --- Transform ops ---
        _s1004_chop_len()::Int64 = length(chop("hello"))
        _s1004_chop_eq()::Int32 = chop("hello") == "hell" ? Int32(1) : Int32(0)
        _s1004_rev()::Int32 = reverse("hello") == "olleh" ? Int32(1) : Int32(0)
        _s1004_last()::Int64 = length(last("hello", 3))
        _s1004_repeat()::Int32 = repeat("ha", 3) == "hahaha" ? Int32(1) : Int32(0)
        _s1004_lpad()::Int64 = length(lpad("hi", 5))
        _s1004_rpad()::Int64 = length(rpad("hi", 5))

        @testset "transform (chop/reverse/last/repeat/lpad/rpad)" begin
            for opt in [false, true]
                @test compare_julia_wasm(_s1004_chop_len; optimize=opt).pass
                @test compare_julia_wasm(_s1004_chop_eq; optimize=opt).pass
                @test compare_julia_wasm(_s1004_rev; optimize=opt).pass
                @test compare_julia_wasm(_s1004_last; optimize=opt).pass
                @test compare_julia_wasm(_s1004_repeat; optimize=opt).pass
                @test compare_julia_wasm(_s1004_lpad; optimize=opt).pass
                @test compare_julia_wasm(_s1004_rpad; optimize=opt).pass
            end
        end

        # --- Replace/split/join ---
        _s1004_replace()::Int32 = replace("hello", "l" => "r") == "herro" ? Int32(1) : Int32(0)
        _s1004_split()::Int64 = length(split("a,b,c", ","))
        _s1004_join()::Int32 = join(split("a,b,c", ","), "-") == "a-b-c" ? Int32(1) : Int32(0)

        @testset "replace/split/join" begin
            for opt in [false, true]
                @test compare_julia_wasm(_s1004_replace; optimize=opt).pass
                @test compare_julia_wasm(_s1004_split; optimize=opt).pass
                @test compare_julia_wasm(_s1004_join; optimize=opt).pass
            end
        end
    end

    # ================================================================
    # STRESS-2004: Closure Passed as Argument Through Multiple Layers
    # ================================================================
    # Tests closure GC struct passing through call chains, nested maps,
    # reduce with closures, and multi-capture filter compositions.

    @pphase "STRESS-2004: Closure Argument Passing" begin

        # Closure applied via map
        _s2004_apply_add1(v::Vector{Int64})::Vector{Int64} = map(x -> x + Int64(1), v)

        # Closure with capture passed to filter
        _s2004_filter_cap(v::Vector{Int64})::Vector{Int64} = (t = Int64(3); filter(x -> x > t, v))

        # Composed closures via nested map
        _s2004_composed(v::Vector{Int64})::Vector{Int64} = begin
            dbl = (x::Int64) -> x * Int64(2)
            add1 = (x::Int64) -> x + Int64(1)
            map(x -> add1(dbl(x)), v)
        end

        # Same closure applied twice (chained maps)
        _s2004_twice(v::Vector{Int64})::Vector{Int64} = begin
            triple = (x::Int64) -> x * Int64(3)
            map(triple, map(triple, v))
        end

        # Nested map with different closures
        _s2004_nested(v::Vector{Int64})::Vector{Int64} = begin
            sq = (x::Int64) -> x * x
            neg = (x::Int64) -> -x
            map(neg, map(sq, v))
        end

        # Closure in reduce
        _s2004_reduce(v::Vector{Int64})::Int64 =
            reduce((a::Int64, x::Int64) -> a + x * Int64(2), v; init=Int64(0))

        # Multi-capture filter (two captured variables)
        _s2004_multi_cap(v::Vector{Int64})::Vector{Int64} = begin
            lo = Int64(2); hi = Int64(8)
            filter(x -> x >= lo && x <= hi, v)
        end

        # Capture chain: closure captures threshold for count
        _s2004_cap_chain(v::Vector{Int64})::Int64 = begin
            threshold = Int64(5)
            Int64(length(filter(x -> x > threshold, v)))
        end

        # A runtime index into Vector{Any} prevents inference from devirtualizing
        # either capturing closure. This exercises allocation of the shared closure
        # Object, its real RTI field, vtable selection, call_ref, and result unboxing.
        _s2004_dynamic(x::Int64, i::Int64)::Int64 = begin
            offset = Int64(3)
            factor = Int64(4)
            add = (y::Int64) -> y + offset
            mul = (y::Int64) -> y * factor
            fs = Any[add, mul]
            (fs[i](x))::Int64
        end

        @testset "basic closure passing" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s2004_apply_add1, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s2004_filter_cap, Int64[1,2,3,4,5,6]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s2004_composed, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s2004_twice, Int64[1,2,3]; optimize=opt).pass
            end
        end

        @testset "advanced closure chains" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s2004_nested, Int64[1,2,3]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s2004_reduce, Int64[1,2,3,4,5]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s2004_multi_cap, Int64[1,3,5,7,9]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s2004_cap_chain, Int64[1,3,5,7,9]; optimize=opt).pass
                @test compare_julia_wasm(_s2004_dynamic, Int64(9), Int64(1); optimize=opt).pass
                @test compare_julia_wasm(_s2004_dynamic, Int64(9), Int64(2); optimize=opt).pass
                @test compare_julia_wasm(_wt_dynamic_tearoff, Int64(9), Int64(1); optimize=opt).pass
                @test compare_julia_wasm(_wt_dynamic_tearoff, Int64(9), Int64(2); optimize=opt).pass
            end
        end
    end

    # ================================================================
    # STRESS-3000: 8-Deep Collection Chain
    # ================================================================
    # Tests: reverse → accumulate → map(abs) → filter(>0) → sort → unique → sum
    # Verifies deep native+overlay composition with closures, both types.

    @pphase "STRESS-3000: 8-Deep Collection Chain" begin
        # 8-deep: reverse → accumulate(+) → map(abs) → filter(>0) → sort → unique → sum
        _s3000_deep_i64(v::Vector{Int64})::Int64 =
            sum(unique(sort(filter(x -> x > Int64(0), map(abs, accumulate(+, reverse(v)))))))

        _s3000_deep_f64(v::Vector{Float64})::Float64 =
            sum(unique(sort(filter(x -> x > 0.0, map(abs, accumulate(+, reverse(v)))))))

        # 5-deep: reverse → sort → unique → map(abs) → sum
        _s3000_five_i64(v::Vector{Int64})::Int64 =
            sum(map(abs, unique(sort(reverse(v)))))

        # 6-deep Float64: reverse → sort → filter(>0) → map(*2) → sum
        _s3000_six_f64(v::Vector{Float64})::Float64 =
            sum(map(x -> x * 2.0, filter(x -> x > 0.0, sort(reverse(v)))))

        @testset "Int64 chains" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s3000_deep_i64, Int64[3, -1, 4, -1, 5]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s3000_five_i64, Int64[-3, 1, -4, 1, -5, 9]; optimize=opt).pass
            end
        end

        @testset "Float64 chains" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s3000_deep_f64, Float64[3.0, -1.0, 4.0, -1.0, 5.0]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s3000_six_f64, Float64[5.0, -3.0, 1.0, -7.0, 4.0]; optimize=opt).pass
            end
        end
    end

    # ================================================================
    # STRESS-3001: String Operation Chain
    # ================================================================
    # Deep string chains mixing native + overlay. No vector args.

    @pphase "STRESS-3001: String Operation Chain" begin
        # 5-deep: uppercase → strip → split(",") → join("-") → length
        _s3001_chain1()::Int64 =
            Int64(length(join(split(strip(uppercase("  hello,world,test  ")), ","), "-")))

        # 3-deep: strip → uppercase → replace
        _s3001_chain2()::Int32 =
            replace(uppercase(strip("  hello  ")), "ELLO" => "I") == "HI" ? Int32(1) : Int32(0)

        # 3-deep: lowercase → repeat → reverse → length
        _s3001_chain3()::Int64 =
            Int64(length(reverse(repeat(lowercase("ABC"), 3))))

        # 4-deep: strip → uppercase → replace → startswith+contains
        _s3001_chain4()::Int32 = begin
            s = strip("  Hello World  ")
            u = uppercase(s)
            r = replace(u, " " => "_")
            startswith(r, "HELLO") && contains(r, "_") ? Int32(1) : Int32(0)
        end

        for opt in [false, true]
            @test compare_julia_wasm(_s3001_chain1; optimize=opt).pass
            @test compare_julia_wasm(_s3001_chain2; optimize=opt).pass
            @test compare_julia_wasm(_s3001_chain3; optimize=opt).pass
            @test compare_julia_wasm(_s3001_chain4; optimize=opt).pass
        end
    end

    # ================================================================
    # STRESS-3002: Math × Collection Chain
    # ================================================================
    # Math functions applied over filtered vectors. Native + stackifier.

    @pphase "STRESS-3002: Math × Collection Chain" begin
        # sqrt chain (WASM-native math)
        _s3002_sqrt_chain(v::Vector{Float64})::Float64 =
            sum(map(sqrt, filter(x -> x > 0.0, v)))

        # floor+abs chain (WASM-native math)
        _s3002_floor_chain(v::Vector{Float64})::Float64 =
            sum(map(x -> floor(abs(x)), filter(x -> x > -10.0, v)))

        # sin*cos chain (stackifier trig)
        _s3002_trig_chain(v::Vector{Float64})::Float64 =
            sum(map(x -> sin(x) * cos(x), filter(x -> x > 0.0, v)))

        @testset "WASM-native math chains" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s3002_sqrt_chain, Float64[4.0, -1.0, 9.0, -4.0, 16.0]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s3002_floor_chain, Float64[3.7, -2.3, 4.1, -5.9]; optimize=opt).pass
            end
        end

        @testset "trig math chain" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s3002_trig_chain, Float64[1.0, -2.0, 3.0, -4.0, 0.5]; optimize=opt).pass
            end
        end
    end

    # ================================================================
    # STRESS-3003: Cross-Type Promotion Chain
    # ================================================================
    # Input Int64, intermediate/output Float64. Tests type conversion in chains.

    @pphase "STRESS-3003: Cross-Type Promotion Chain" begin
        # Int64 → filter → map(abs) → sum → Float64 → sqrt
        _s3003_cross(v::Vector{Int64})::Float64 =
            sqrt(Float64(sum(map(abs, filter(x -> x > Int64(0), v)))))

        # Int64 → filter → map(Float64 * 0.5) → sum → Float64
        _s3003_conv(v::Vector{Int64})::Float64 =
            sum(map(x -> Float64(x) * 0.5, filter(x -> x > Int64(0), v)))

        for opt in [false, true]
            @test compare_julia_wasm_vec(_s3003_cross, Int64[3, -1, 4, -1, 5]; optimize=opt).pass
            @test compare_julia_wasm_vec(_s3003_conv, Int64[1, -2, 3, -4, 5]; optimize=opt).pass
        end
    end

    # ================================================================
    # STRESS-3004: Closure + Composition Chain
    # ================================================================
    # 3 named closures composed into a pipeline. Captures local variables.

    @pphase "STRESS-3004: Closure + Composition Chain" begin
        # Named closures: transform + predicate + reducer
        _s3004_pipeline(v::Vector{Int64})::Int64 = begin
            transform = (x::Int64) -> x * Int64(2) + Int64(1)
            predicate = (x::Int64) -> x > Int64(5)
            reducer = (a::Int64, x::Int64) -> a + x
            reduce(reducer, map(transform, filter(predicate, v)); init=Int64(0))
        end

        # Multi-capture: threshold + scale + offset all captured
        _s3004_captures(v::Vector{Int64})::Int64 = begin
            threshold = Int64(3)
            scale = Int64(10)
            offset = Int64(100)
            reduce((a::Int64, x::Int64) -> a + x + offset, map(x -> x * scale, filter(x -> x > threshold, v)); init=Int64(0))
        end

        # Float64 closures with captures: accumulate → filter(>threshold) → map(*scale) → sum
        _s3004_f64_cap(v::Vector{Float64})::Float64 = begin
            threshold = 2.0
            scale = 3.0
            sum(map(x -> x * scale, filter(x -> x > threshold, accumulate(+, v))))
        end

        @testset "Int64 closure pipelines" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s3004_pipeline, Int64[1, 3, 5, 7, 9]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s3004_captures, Int64[1, 2, 3, 4, 5]; optimize=opt).pass
            end
        end

        @testset "Float64 closure pipeline" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s3004_f64_cap, Float64[0.5, 1.5, 2.5, 3.5]; optimize=opt).pass
            end
        end
    end

    # ================================================================
    # STRESS-5001: 20-Function Module Stress Test
    # ================================================================
    # 20 diverse functions (Int64 + Float64, 1-arg + 2-arg) in one compile_multi.

    @pphase "STRESS-5001: 20-Function Module" begin
        _s5001_abs_i64(x::Int64)::Int64 = abs(x)
        _s5001_sign_i64(x::Int64)::Int64 = sign(x)
        _s5001_iseven_i64(x::Int64)::Int32 = iseven(x) ? Int32(1) : Int32(0)
        _s5001_isodd_i64(x::Int64)::Int32 = isodd(x) ? Int32(1) : Int32(0)
        _s5001_zero_i64(x::Int64)::Int64 = zero(x)
        _s5001_one_i64(x::Int64)::Int64 = one(x)
        _s5001_neg_i64(x::Int64)::Int64 = -x
        _s5001_dbl_i64(x::Int64)::Int64 = x * Int64(2)
        _s5001_sq_i64(x::Int64)::Int64 = x * x
        _s5001_min_i64(x::Int64, y::Int64)::Int64 = min(x, y)
        _s5001_max_i64(x::Int64, y::Int64)::Int64 = max(x, y)
        _s5001_add_i64(x::Int64, y::Int64)::Int64 = x + y
        _s5001_sub_i64(x::Int64, y::Int64)::Int64 = x - y
        _s5001_mul_i64(x::Int64, y::Int64)::Int64 = x * y
        _s5001_abs_f64(x::Float64)::Float64 = abs(x)
        _s5001_sqrt_f64(x::Float64)::Float64 = sqrt(x)
        _s5001_floor_f64(x::Float64)::Float64 = floor(x)
        _s5001_ceil_f64(x::Float64)::Float64 = ceil(x)
        _s5001_min_f64(x::Float64, y::Float64)::Float64 = min(x, y)
        _s5001_max_f64(x::Float64, y::Float64)::Float64 = max(x, y)

        funcs = [
            (_s5001_abs_i64, (Int64,)), (_s5001_sign_i64, (Int64,)),
            (_s5001_iseven_i64, (Int64,)), (_s5001_isodd_i64, (Int64,)),
            (_s5001_zero_i64, (Int64,)), (_s5001_one_i64, (Int64,)),
            (_s5001_neg_i64, (Int64,)), (_s5001_dbl_i64, (Int64,)),
            (_s5001_sq_i64, (Int64,)), (_s5001_min_i64, (Int64, Int64)),
            (_s5001_max_i64, (Int64, Int64)), (_s5001_add_i64, (Int64, Int64)),
            (_s5001_sub_i64, (Int64, Int64)), (_s5001_mul_i64, (Int64, Int64)),
            (_s5001_abs_f64, (Float64,)), (_s5001_sqrt_f64, (Float64,)),
            (_s5001_floor_f64, (Float64,)), (_s5001_ceil_f64, (Float64,)),
            (_s5001_min_f64, (Float64, Float64)), (_s5001_max_f64, (Float64, Float64)),
        ]

        for opt in [false, true]
            @testset "20-func compile_multi (optimize=$opt)" begin
                bytes = WasmTarget.compile_multi(funcs; optimize=opt)
                @test length(bytes) > 0

                # Single-arg Int64 functions
                for (name, f, arg) in [
                    ("_s5001_abs_i64", _s5001_abs_i64, Int64(-5)),
                    ("_s5001_sign_i64", _s5001_sign_i64, Int64(-5)),
                    ("_s5001_iseven_i64", _s5001_iseven_i64, Int64(4)),
                    ("_s5001_isodd_i64", _s5001_isodd_i64, Int64(3)),
                    ("_s5001_zero_i64", _s5001_zero_i64, Int64(7)),
                    ("_s5001_one_i64", _s5001_one_i64, Int64(7)),
                    ("_s5001_neg_i64", _s5001_neg_i64, Int64(-5)),
                    ("_s5001_dbl_i64", _s5001_dbl_i64, Int64(6)),
                    ("_s5001_sq_i64", _s5001_sq_i64, Int64(4)),
                ]
                    @test run_wasm(bytes, name, arg) == f(arg)
                end

                # Two-arg Int64 functions
                for (name, f) in [
                    ("_s5001_min_i64", _s5001_min_i64),
                    ("_s5001_max_i64", _s5001_max_i64),
                    ("_s5001_add_i64", _s5001_add_i64),
                    ("_s5001_sub_i64", _s5001_sub_i64),
                    ("_s5001_mul_i64", _s5001_mul_i64),
                ]
                    @test run_wasm(bytes, name, Int64(7), Int64(3)) == f(Int64(7), Int64(3))
                end

                # Float64 functions
                @test run_wasm(bytes, "_s5001_abs_f64", -3.7) == _s5001_abs_f64(-3.7)
                @test run_wasm(bytes, "_s5001_sqrt_f64", 9.0) == _s5001_sqrt_f64(9.0)
                @test run_wasm(bytes, "_s5001_floor_f64", -3.7) == _s5001_floor_f64(-3.7)
                @test run_wasm(bytes, "_s5001_ceil_f64", -3.7) == _s5001_ceil_f64(-3.7)
                @test run_wasm(bytes, "_s5001_min_f64", 3.14, 2.71) == _s5001_min_f64(3.14, 2.71)
                @test run_wasm(bytes, "_s5001_max_f64", 3.14, 2.71) == _s5001_max_f64(3.14, 2.71)
            end
        end
    end

    # ================================================================
    # STRESS-6000: sort kwargs
    # ================================================================
    # sort(rev=true) works. sort(by=...) not supported in overlay.

    @pphase "STRESS-6000: sort kwargs" begin
        _s6000_sort_rev_i64(v::Vector{Int64})::Vector{Int64} = sort(v; rev=true)
        _s6000_sort_rev_f64(v::Vector{Float64})::Vector{Float64} = sort(v; rev=true)

        @testset "sort(rev=true)" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s6000_sort_rev_i64, Int64[3, 1, 4, 1, 5]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s6000_sort_rev_f64, Float64[3.0, 1.0, 4.0, 1.0, 5.0]; optimize=opt).pass
            end
        end
    end

    # ================================================================
    # STRESS-6001: round/clamp/div kwargs
    # ================================================================
    # clamp, fld, cld work. round(digits=N) fails at runtime.

    @pphase "STRESS-6001: clamp/fld/cld" begin
        _s6001_clamp_lo(x::Float64)::Float64 = clamp(x, 0.0, 10.0)
        _s6001_clamp_hi(x::Float64)::Float64 = clamp(x, 0.0, 10.0)
        _s6001_clamp_mid(x::Float64)::Float64 = clamp(x, 0.0, 10.0)
        _s6001_fld(x::Int64, y::Int64)::Int64 = fld(x, y)
        _s6001_cld(x::Int64, y::Int64)::Int64 = cld(x, y)

        for opt in [false, true]
            @test compare_julia_wasm(_s6001_clamp_lo, -5.0; optimize=opt).pass
            @test compare_julia_wasm(_s6001_clamp_hi, 15.0; optimize=opt).pass
            @test compare_julia_wasm(_s6001_clamp_mid, 5.0; optimize=opt).pass
            @test compare_julia_wasm(_s6001_fld, Int64(-7), Int64(3); optimize=opt).pass
            @test compare_julia_wasm(_s6001_cld, Int64(7), Int64(3); optimize=opt).pass
        end
    end

    # ================================================================
    # STRESS-6002: String function kwargs
    # ================================================================
    # split(limit=N), split(keepempty=false) work.

    @pphase "STRESS-6002: String kwargs" begin
        _s6002_split_limit()::Int64 = Int64(length(split("a,b,c,d", ","; limit=2)))
        _s6002_split_keepempty()::Int64 = Int64(length(split("a,,b,,c", ","; keepempty=false)))

        for opt in [false, true]
            @test compare_julia_wasm(_s6002_split_limit; optimize=opt).pass
            @test compare_julia_wasm(_s6002_split_keepempty; optimize=opt).pass
        end
    end

    # ================================================================
    # STRESS-7000: Empty and Single-Element Inputs
    # ================================================================

    @pphase "STRESS-7000: Empty/Single Inputs" begin
        _s7000_sort_i64(v::Vector{Int64})::Vector{Int64} = sort(v)
        _s7000_sum_i64(v::Vector{Int64})::Int64 = sum(v)
        _s7000_reverse_i64(v::Vector{Int64})::Vector{Int64} = reverse(v)
        _s7000_unique_i64(v::Vector{Int64})::Vector{Int64} = unique(v)
        _s7000_filter_i64(v::Vector{Int64})::Vector{Int64} = filter(iseven, v)
        _s7000_length_i64(v::Vector{Int64})::Int64 = Int64(length(v))
        _s7000_min_i64(v::Vector{Int64})::Int64 = minimum(v)
        _s7000_sort_f64(v::Vector{Float64})::Vector{Float64} = sort(v)
        _s7000_sum_f64(v::Vector{Float64})::Float64 = sum(v)
        _s7000_reverse_f64(v::Vector{Float64})::Vector{Float64} = reverse(v)

        @testset "empty Int64" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s7000_sort_i64, Int64[]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s7000_sum_i64, Int64[]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s7000_reverse_i64, Int64[]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s7000_unique_i64, Int64[]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s7000_filter_i64, Int64[]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s7000_length_i64, Int64[]; optimize=opt).pass
            end
        end

        @testset "empty Float64" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s7000_sort_f64, Float64[]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s7000_sum_f64, Float64[]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s7000_reverse_f64, Float64[]; optimize=opt).pass
            end
        end

        @testset "single element" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s7000_sort_i64, Int64[42]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s7000_sum_i64, Int64[42]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s7000_min_i64, Int64[42]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s7000_sort_f64, Float64[42.0]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s7000_sum_f64, Float64[42.0]; optimize=opt).pass
            end
        end
    end

    # ================================================================
    # STRESS-7001: NaN/Inf/-0.0 Propagation
    # ================================================================
    # IEEE 754 special values through math operations.

    @pphase "STRESS-7001: NaN/Inf/-0.0" begin
        _s7001_copysign_neg0(x::Float64, y::Float64)::Float64 = copysign(x, y)
        _s7001_signbit(x::Float64)::Int32 = signbit(x) ? Int32(1) : Int32(0)
        _s7001_abs_f64(x::Float64)::Float64 = abs(x)
        _s7001_isinf(x::Float64)::Int32 = isinf(x) ? Int32(1) : Int32(0)
        _s7001_isnan(x::Float64)::Int32 = isnan(x) ? Int32(1) : Int32(0)

        @testset "-0.0 handling" begin
            for opt in [false, true]
                @test compare_julia_wasm(_s7001_copysign_neg0, 1.0, -0.0; optimize=opt).pass
                @test compare_julia_wasm(_s7001_signbit, -0.0; optimize=opt).pass
                @test compare_julia_wasm(_s7001_signbit, 0.0; optimize=opt).pass
            end
        end

        @testset "Inf propagation" begin
            for opt in [false, true]
                @test compare_julia_wasm(_s7001_abs_f64, -Inf; optimize=opt).pass
                @test compare_julia_wasm(_s7001_isinf, Inf; optimize=opt).pass
                @test compare_julia_wasm(_s7001_isinf, -Inf; optimize=opt).pass
            end
        end

        @testset "NaN propagation" begin
            for opt in [false, true]
                @test compare_julia_wasm(_s7001_isnan, NaN; optimize=opt).pass
            end
        end
    end

    # ================================================================
    # STRESS-7002: Overflow Boundaries and Large Vectors
    # ================================================================

    @pphase "STRESS-7002: Overflow/Large" begin
        _s7002_abs_near_min(x::Int32)::Int32 = abs(x)
        _s7002_div_tmax(x::Int64, y::Int64)::Int64 = div(x, y)
        _s7002_sum_large(v::Vector{Int64})::Int64 = sum(v)
        _s7002_sort_large(v::Vector{Int64})::Vector{Int64} = sort(v)

        @testset "boundary arithmetic" begin
            for opt in [false, true]
                @test compare_julia_wasm(_s7002_abs_near_min, typemin(Int32) + Int32(1); optimize=opt).pass
                @test compare_julia_wasm(_s7002_div_tmax, typemax(Int64), Int64(2); optimize=opt).pass
            end
        end

        @testset "large vectors" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s7002_sum_large, collect(Int64, 1:100); optimize=opt).pass
                @test compare_julia_wasm_vec(_s7002_sort_large, Int64[mod(i * 37, 100) for i in 1:100]; optimize=opt).pass
            end
        end
    end

    # ================================================================
    # STRESS-8000: Binaryen Size and Correctness Survey
    # ================================================================
    # Comprehensive binaryen survey across representative function categories.

    @pphase "STRESS-8000: Binaryen Survey" begin
        # Simple scalar functions
        _s8000_abs(x::Int64)::Int64 = abs(x)
        _s8000_sign(x::Int64)::Int64 = sign(x)
        _s8000_iseven(x::Int64)::Int32 = iseven(x) ? Int32(1) : Int32(0)
        _s8000_clamp(x::Float64)::Float64 = clamp(x, 0.0, 10.0)
        _s8000_sqrt(x::Float64)::Float64 = sqrt(x)
        _s8000_floor(x::Float64)::Float64 = floor(x)
        _s8000_min(x::Int64, y::Int64)::Int64 = min(x, y)
        _s8000_gcd(x::Int64, y::Int64)::Int64 = gcd(x, y)

        @testset "scalar functions" begin
            for opt in [false, true]
                @test compare_julia_wasm(_s8000_abs, Int64(-5); optimize=opt).pass
                @test compare_julia_wasm(_s8000_sign, Int64(-3); optimize=opt).pass
                @test compare_julia_wasm(_s8000_iseven, Int64(4); optimize=opt).pass
                @test compare_julia_wasm(_s8000_clamp, 15.0; optimize=opt).pass
                @test compare_julia_wasm(_s8000_sqrt, 9.0; optimize=opt).pass
                @test compare_julia_wasm(_s8000_floor, 3.7; optimize=opt).pass
                @test compare_julia_wasm(_s8000_min, Int64(3), Int64(7); optimize=opt).pass
                @test compare_julia_wasm(_s8000_gcd, Int64(12), Int64(8); optimize=opt).pass
            end
        end

        # Vector functions
        _s8000_sort(v::Vector{Int64})::Vector{Int64} = sort(v)
        _s8000_sum(v::Vector{Int64})::Int64 = sum(v)
        _s8000_filter_map(v::Vector{Int64})::Int64 = sum(map(abs, filter(x -> x > Int64(0), v)))

        @testset "vector functions" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s8000_sort, Int64[5, 3, 1, 4, 2]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s8000_sum, Int64[1, 2, 3, 4, 5]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s8000_filter_map, Int64[-3, 1, -4, 2, 5]; optimize=opt).pass
            end
        end

        # String functions
        _s8000_strlen()::Int64 = Int64(length(uppercase("hello")))
        _s8000_strcat()::Int32 = "hello" * " world" == "hello world" ? Int32(1) : Int32(0)

        @testset "string functions" begin
            for opt in [false, true]
                @test compare_julia_wasm(_s8000_strlen; optimize=opt).pass
                @test compare_julia_wasm(_s8000_strcat; optimize=opt).pass
            end
        end
    end

    # ================================================================
    # STRESS-8001: Binaryen with Overlays and Compositions
    # ================================================================
    # Complex compositions and multi-function modules through binaryen.
    # These are most likely to expose GUFA/type-narrowing bugs.

    @pphase "STRESS-8001: Binaryen Deep Validation" begin
        # 8-deep chain through binaryen (reuse STRESS-3000 pattern)
        _s8001_deep(v::Vector{Int64})::Int64 =
            sum(unique(sort(filter(x -> x > Int64(0), map(abs, accumulate(+, reverse(v)))))))

        # Math composition through binaryen
        _s8001_math(v::Vector{Float64})::Float64 =
            sum(map(x -> sin(x) * cos(x), filter(x -> x > 0.0, v)))

        # Closure pipeline through binaryen
        _s8001_closure(v::Vector{Int64})::Int64 = begin
            scale = Int64(3)
            threshold = Int64(2)
            sum(map(x -> x * scale, filter(x -> x > threshold, v)))
        end

        @testset "compositions + binaryen" begin
            for opt in [false, true]
                @test compare_julia_wasm_vec(_s8001_deep, Int64[3, -1, 4, -1, 5]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s8001_math, Float64[1.0, -2.0, 3.0, 0.5]; optimize=opt).pass
                @test compare_julia_wasm_vec(_s8001_closure, Int64[1, 2, 3, 4, 5]; optimize=opt).pass
            end
        end
    end

    # ── P4-stdlib: Statistics (stdlib integration pilot) ──────────────────
    # All seven functions compile from their REAL Statistics implementations
    # (no overlays, no extension code): mean/var/cor/middle out of the box;
    # std via generic Core.kwcall compile; median via the union-of-Vectors
    # representation fix + typed pointerref/pointerset/memmove/copyto and
    # jl_value_ptr/jl_stored_inline folds; quantile via the :sort! whitelist.
    _stats_mean_f(v::Vector{Float64})::Float64 = Statistics.mean(v)
    _stats_mean_i(v::Vector{Int64})::Float64 = Statistics.mean(v)
    _stats_var(v::Vector{Float64})::Float64 = Statistics.var(v)
    _stats_std(v::Vector{Float64})::Float64 = Statistics.std(v)
    _stats_median(v::Vector{Float64})::Float64 = Statistics.median(v)
    _stats_quantile(v::Vector{Float64})::Float64 = Statistics.quantile(v, 0.75)
    _stats_middle(v::Vector{Float64})::Float64 = Statistics.middle(v)

    @pphase "Statistics stdlib" begin
        @test compare_julia_wasm_vec(_stats_mean_f, Float64[3.0, 1.5, 2.5, 4.0]).pass
        @test compare_julia_wasm_vec(_stats_mean_i, Int64[1, 2, 4]).pass
        @test compare_julia_wasm_vec(_stats_var, Float64[3.0, 1.5, 2.5, 4.0]).pass
        @test compare_julia_wasm_vec(_stats_std, Float64[3.0, 1.5, 2.5, 4.0]).pass
        # median/quantile: native shapes on 1.12; on 1.13 the
        # WasmTargetStatisticsExt overlays reroute the wrapper
        # specializations through their literal definitions.
        @test compare_julia_wasm_vec(_stats_median, Float64[3.0, 1.5, 2.5, 4.0]).pass
        @test compare_julia_wasm_vec(_stats_median, Float64[9.0, -2.0, 7.5, 0.0, 1.0, 3.25, -8.0]).pass
        @test compare_julia_wasm_vec(_stats_quantile, Float64[1.0, 2.0, 3.0, 4.0]).pass
        @test compare_julia_wasm_vec(_stats_middle, Float64[1.0, 9.0, 2.0]).pass
    end

    # ── P4-stdlib: Dates (stdlib #2) ───────────────────────────────────────
    # Value layer compiles from the real Dates implementations; rendering
    # (string(::Date)/(::DateTime)) via WasmTargetDatesExt overlays (the
    # native path needs IOBuffer growth machinery). now()/today() need a
    # host-time import wired by the embedding pipeline — not covered here.
    _dates_year(x::Int64)::Int64 = Dates.year(Dates.Date(2020, 1, 1) + Dates.Day(x))
    _dates_dow(x::Int64)::Int64 = Dates.dayofweek(Dates.Date(2024, 1, 1) + Dates.Day(x))
    _dates_diff(x::Int64)::Int64 = Dates.value(Dates.Date(2024, 3, 1) - Dates.Date(2024, 2, x % 28 + 1))
    _dates_dim(x::Int64)::Int64 = Dates.daysinmonth(Dates.Date(2024, x % 12 + 1, 1))
    _dates_leap(x::Int64)::Bool = Dates.isleapyear(2000 + x)
    _dates_conv(x::Int64)::Int64 = Dates.value(convert(Dates.Millisecond, Dates.Second(x)))
    _dates_parse(x::Int64)::Int64 = Dates.day(Dates.Date("2024-03-15", dateformat"yyyy-mm-dd")) + x
    # Rendering checks return an in-wasm content checksum (the scalar JS
    # harness can't marshal String returns; the polynomial hash makes the
    # comparison content-exact anyway — bridge probes verified the actual
    # strings bit-exact during integration).
    function _dates_strsum(x::Int64)::Int64
        s = string(Dates.Date(2024, 1, 1) + Dates.Day(x))
        h = Int64(0)
        for b in codeunits(s)
            h = h * 31 + Int64(b)
        end
        return h
    end
    function _dates_strdtsum(x::Int64)::Int64
        s = string(Dates.DateTime(2023, 6, 15, 12, 0, 0) + Dates.Millisecond(x))
        h = Int64(0)
        for b in codeunits(s)
            h = h * 31 + Int64(b)
        end
        return h
    end

    @pphase "Dates stdlib" begin
        @test compare_julia_wasm(_dates_year, 5).pass
        @test compare_julia_wasm(_dates_dow, 5).pass
        @test compare_julia_wasm(_dates_diff, 5).pass
        @test compare_julia_wasm(_dates_dim, 5).pass
        @test compare_julia_wasm(_dates_leap, 5).pass
        @test compare_julia_wasm(_dates_leap, 0).pass
        @test compare_julia_wasm(_dates_conv, 5).pass
        @test compare_julia_wasm(_dates_parse, 5).pass
        @test compare_julia_wasm(_dates_strsum, 5).pass
        @test compare_julia_wasm(_dates_strdtsum, 123).pass
        @test compare_julia_wasm(_dates_strdtsum, 0).pass
    end

    # ── P4-stdlib: Random (stdlib #3) ──────────────────────────────────────
    # Seeded Xoshiro streams compile from the real implementations and match
    # native bit-exactly; WasmTargetRandomExt reroutes hash_seed through
    # SHA's type-stable byte-vector path (identical digests). Unseeded RNGs
    # (TaskLocalRNG, OS entropy) defer to embedding-side imports.
    _rand_i64(x::Int64)::Int64 = rand(Random.Xoshiro(x), Int64)
    _rand_f64(x::Int64)::Float64 = rand(Random.Xoshiro(x))
    _rand_range(x::Int64)::Int64 = rand(Random.Xoshiro(x), 1:100)
    _rand_randn(x::Int64)::Float64 = randn(Random.Xoshiro(x))
    function _rand_stream(x::Int64)::Int64
        rng = Random.Xoshiro(x)
        a = rand(rng, Int64)
        b = rand(rng, Int64)
        return a ⊻ b
    end
    _rand_bool(x::Int64)::Bool = rand(Random.Xoshiro(x), Bool)

    @pphase "Random stdlib" begin
        # 1.13's Random IR shapes hit the ledgered memoryrefnew pair-to-local
        # family (a517b4c8372d) across the board — the whole phase is gated
        # until pair-locals land. 1.12: all seeded streams bit-exact.
        @static if VERSION < v"1.13-"
            @test compare_julia_wasm(_rand_i64, 42).pass
            @test compare_julia_wasm(_rand_i64, -3).pass
            @test compare_julia_wasm(_rand_f64, 42).pass
            @test compare_julia_wasm(_rand_range, 7).pass
            @test compare_julia_wasm(_rand_randn, 42).pass
            @test compare_julia_wasm(_rand_stream, 7).pass
            @test compare_julia_wasm(_rand_bool, 42).pass
            @test compare_julia_wasm(_rand_bool, -3).pass
        else
            @test_skip false
        end
    end

    # top-level so they're singleton functions, not capturing closures —
    # a closure-typed ENTRY can't cross the JS arg boundary in run_wasm
    _wt_apply_twice(g, x::Float64) = g(g(x))
    _wt_ho_entry(n::Int64) = _wt_apply_twice(x -> 0.2 * x^3 - 4.0 * x + 1.0, Float64(n))

    @pphase "Float-range colon (a8c00917b1b0)" begin
        # Singleton callable structs bound to their own type name (Base.Colon):
        # discovery extracted the TYPE, probed a nonexistent constructor, and the
        # un-inlined 3-arg colon invoke silently compiled to `unreachable`
        # (validates-then-traps — Snapshot.jl newton canvas groups). Pins the
        # instance-extraction fix + the :Colon allowlist entry.
        _range_fls(n::Int64) = begin
            r = -10:0.01:10
            Float64(first(r)) + Float64(last(r)) + Float64(step(r)) + Float64(n)
        end
        _range_arg(n::Int64) = begin
            inner(rng) = Float64(first(rng)) + Float64(last(rng)) + Float64(step(rng))
            inner(-10:0.01:10) + Float64(n)
        end
        @test compare_julia_wasm(_range_fls, 3).pass
        @test compare_julia_wasm(_range_fls, -7).pass
        @test compare_julia_wasm(_range_arg, 3).pass

        # follow-up: user-defined higher-order fns (function-typed args) were
        # skipped by the singleton-arg heuristic — userland modules are exempt now
        @test compare_julia_wasm(_wt_ho_entry, 5).pass
    end

    # (Phase 76 removed in cleanup Loop 1, 2026-06-28: it unit-tested the byte-fixer
    # fix_i32_wrap_after_i32_ops, which has been DELETED — the typed InstrBuilder now emits
    # correct wrap placement up front, so no post-emission rewrite exists to corrupt a
    # select_t/if ref operand. The downstream-regression INTENT is preserved end-to-end by
    # the Loop-1 backfills, e.g. _no_wrap_after_i32_op in test/cleanup_loop1_backfills.jl.)

    @pphase "Phase 77: ordinary Object identity" begin
        @testset "Phase 77: discovered ordinary-object identity is real and stable" begin
            result = compare_julia_wasm(_g1_entry, Int64(7))
            @test result.pass
            @test result.actual == 1
        end
    end

end  # end of phase-registration block

# The dedicated fuzz pass (WT_FUZZ=1) skips the codegen phases entirely — it exists
# only to run the differential fuzz alone, contention-free.
if !_wt_fuzz()
    @testset "WasmTarget.jl" begin
        _run_phases()   # runs only this process's shard of the 80 registered phases
    end
end

# Bounded differential fuzz (native-vs-wasm over generated compositions) + corpus replay.
# Runs in its own contention-free pass (WT_FUZZ=1), or inline in the serial fallback.
_wt_run_fuzz() && include("fuzz_suite.jl")
