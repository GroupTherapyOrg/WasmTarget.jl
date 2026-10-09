# Every function is named where it is defined (L157), so a trap in code the compiler generated
# names its function and its construct, as a trap in compiled code names its statement
# (dev/MARCH.md 13.15; dart2wasm names the functions it defines, functions.dart:171, and the
# name section carries the names, sections.dart:844; dev/CHARTER.md C10).
using Test
using WasmTarget
isdefined(@__MODULE__, :WasmRunner) || include(joinpath(@__DIR__, "wasm_runner.jl"))
using .WasmRunner

const _GN = WasmTarget

# a subject for each construct that takes one (each the kind of subject its site passes)
const _GN_SUBJECTS = Dict{Symbol,String}(
    :closure_trampoline => "var\"#gn##0#gn##1\"",
    :closure_dispatching_trampoline => "typeof(string)",
    :dispatch_wrapper => "f2_1",
    :polymorphic_dispatcher => "f3, axis 2",
    :lazy_initializer => _GN.constant_name("a string constant\nsecond line"),
    :field_initializer => "Main.COUNTER",
    :foreigncall_table => "utf8proc_toupper/utf8proc_tolower/utf8proc_totitle/utf8proc_isupper/utf8proc_islower",
    :export_entry => "gf2",
)

_gn_name(kind::Symbol) = _GN.generated_function_name(kind, get(_GN_SUBJECTS, kind, ""))

# a module whose export `planted_entry` calls one function named `name` that traps at once; the
# export is built here, not compiled from Julia IR, so it is named by the construct it plays
function _gn_planted(name::String)
    mod = _GN.WasmModule(; source_map_url="planted.wasm.map")
    p = _GN.InstrBuilder(; mod=mod)
    _GN.unreachable!(p)
    _GN.finish_function!(p)
    planted = _GN.add_function!(mod, p; name=name)
    b = _GN.InstrBuilder(; mod=mod)
    _GN.call!(b, planted)
    _GN.finish_function!(b)
    entry = _GN.add_function!(mod, b; name=_GN.generated_function_name(:export_entry, "planted_entry"))
    _GN.add_export!(mod, "planted_entry", 0, entry)
    bytes, json = _GN.to_bytes_with_source_map(mod)
    return WasmRunner.run_wasm_single(bytes, "planted_entry", ""; source_map=json)
end

@testset "generated names: one vocabulary, read back" begin
    constructs = [c.construct for c in _GN.GENERATED_CONSTRUCTS]
    @test allunique(constructs)
    for kind in keys(_GN.GENERATED_CONSTRUCTS)
        c = _GN.GENERATED_CONSTRUCTS[kind]
        name = _gn_name(kind)
        @test !isempty(name)
        @test _GN.generated_function_construct(name) == c.construct
        # a fixed name takes no subject; a format needs one
        if c.takes_subject
            @test_throws ArgumentError _GN.generated_function_name(kind)
        else
            @test_throws ArgumentError _GN.generated_function_name(kind, "x")
        end
    end
    @test_throws Exception _GN.generated_function_name(:no_such_construct, "x")
    # dart's texts, where dart has the construct
    @test _GN.generated_function_name(:closure_trampoline, "C") == "C trampoline"
    @test _GN.generated_function_name(:polymorphic_dispatcher, "s") == "s (polymorphic dispatcher)"
    @test _GN.generated_function_name(:lazy_initializer, "\"x\"") == "\"x\" (lazy initializer)"
    @test _GN.generated_function_name(:field_initializer, "M.g") == "M.g field initializer"
    @test _GN.generated_function_name(:start_function) == "#init"
    # dart's constant name: the first line, quoted, cut after 30 characters
    @test _GN.constant_name("ab\ncd") == "\"ab\""
    @test _GN.constant_name(repeat("x", 31)) == "\"" * repeat("x", 30) * "<...>\""
    # the most specific format wins; a function compiled from Julia IR is no construct
    @test _GN.generated_function_construct("C trampoline (dispatching)") ==
          _GN.GENERATED_CONSTRUCTS.closure_dispatching_trampoline.construct
    for ordinary in ("f", "f2_1", "gf2", "trampoline", "#init_1", "_smt_boom")
        @test _GN.generated_function_construct(ordinary) === nothing
    end
    # every construct in the vocabulary is one a site in src names a function by, and every
    # site's construct is in the vocabulary
    used = Set{Symbol}()
    for (dir, _, fs) in walkdir(joinpath(@__DIR__, "..", "src")), f in fs
        endswith(f, ".jl") || continue
        for m in eachmatch(r"generated_function_name\(:(\w+)", read(joinpath(dir, f), String))
            push!(used, Symbol(m.captures[1]))
        end
    end
    @test used == Set(keys(_GN.GENERATED_CONSTRUCTS))
end

# A planted trap inside a function of each construct: the located message names the function
# and its construct, where an unnamed one printed "wasm-function[i] at 0x…: no statement (the
# function's entry, or code the compiler generated)".
@testset "generated names: a trap in generated code names its function and construct" begin
    for kind in keys(_GN.GENERATED_CONSTRUCTS)
        name = _gn_name(kind)
        construct = _GN.GENERATED_CONSTRUCTS[kind].construct
        status, msg = _gn_planted(name)
        @test status === :trap
        @test occursin("at `$(name)`: $(construct)", msg)
        # the export that called it is named by the construct it plays
        @test occursin("at `planted_entry (export)`: export entry", msg)
        @test !occursin("no statement", msg)
    end
    # an empty name is refused where the function is defined, naming the call
    err = try; _gn_planted(""); nothing; catch e; e; end
    @test err isa ArgumentError && occursin("define_function!(…; name=\"\")", err.msg)
    err = try; _GN.WasmFunction(UInt32(0), _GN.WasmValType[], nothing, _GN.SourceMapping[], ""); nothing; catch e; e; end
    @test err isa ArgumentError && occursin("WasmFunction(type 0; name=\"\")", err.msg)
    # a frame with no name is a defect: the runner raises rather than print a fallback
    @test_throws ErrorException WasmRunner.located_frames(
        "Error\n    at wasm://wasm/0123abcd:wasm-function[3]:0x10", "{\"version\":3,\"sources\":[],\"names\":[],\"mappings\":\"\"}",
        UInt8[])
    # a function the host built, never compiled from Julia IR, says so, not "no source location"
    status, msg = _gn_planted("host_fn")
    @test status === :trap && occursin("at `host_fn`: a function not compiled from Julia IR", msg)
end

# The traps reachable from Julia programs in two of the constructs: a selector call with no row
# (dev/AUDIT.md A3S1's remainder: the selector table's and the dispatch wrapper's no-row paths,
# test/dispatch_method_error.jl). Native raises MethodError; the module traps, located.
module GeneratedNamesE2E
struct A x::Int32 end; struct B x::Int32 end; struct C x::Int32 end; struct D x::Int32 end
struct H x::Int32 end
# the second argument never varies: the wrapper of the row the first selects checks it
f2(::A, ::A) = Int32(11); f2(::B, ::A) = Int32(21); f2(::C, ::A) = Int32(31); f2(::D, ::A) = Int32(41)
# both vary, each first-argument group told apart by the second: the cascade's second hop
f3(::A, ::A) = Int32(1); f3(::A, ::B) = Int32(2); f3(::B, ::A) = Int32(3); f3(::B, ::B) = Int32(4)
gf2(x::Any, y::Any)::Int32 = f2(x, y)
gf3(x::Any, y::Any)::Int32 = f3(x, y)
mkA(v::Int32) = A(v); mkB(v::Int32) = B(v); mkC(v::Int32) = C(v); mkD(v::Int32) = D(v)
mkH(v::Int32) = H(v)
end

@testset "generated names: a no-row selector call names the wrapper or dispatcher it traps in" begin
    M = GeneratedNamesE2E
    fns = [(M.f2, (M.A, M.A)), (M.f2, (M.B, M.A)), (M.f2, (M.C, M.A)), (M.f2, (M.D, M.A)),
           (M.f3, (M.A, M.A)), (M.f3, (M.A, M.B)), (M.f3, (M.B, M.A)), (M.f3, (M.B, M.B)),
           (M.gf2, (Any, Any)), (M.gf3, (Any, Any)),
           (M.mkA, (Int32,)), (M.mkB, (Int32,)), (M.mkC, (Int32,)), (M.mkD, (Int32,)), (M.mkH, (Int32,))]
    # every function the module defines is named
    mod = _GN.compile_module(fns)
    @test all(f -> !isempty(f.name), mod.functions)
    @test any(f -> endswith(f.name, " (dispatch wrapper)"), mod.functions)
    @test any(f -> endswith(f.name, " (polymorphic dispatcher)"), mod.functions)

    bytes, json = _GN.compile_multi_with_sourcemap(fns)
    v = Int32(0)
    native(fn, args...) = try; (:ok, fn(args...)); catch e; (:err, typeof(e)); end
    # f2(::A, ::B): the A row's wrapper finds a B at the slot it checks
    @test native(M.gf2, M.A(v), M.B(v)) == (:err, MethodError)
    status, msg = WasmRunner.run_wasm_single(bytes, "gf2", "instance.exports.mkA(0), instance.exports.mkB(0)";
                                             source_map=json)
    @test status === :trap
    @test occursin(r"at `f2[^`]* \(dispatch wrapper\)`: dispatch wrapper", msg)
    # its caller, the selector caller compiled for gf2, maps whole to gf2's definition
    @test occursin(r"\bGeneratedNamesE2E\.gf2 @ .*generated_names\.jl:\d+", msg)
    @test !occursin("no source location", msg)
    # f3(::A, ::H): the A group's second hop has no row for H
    @test native(M.gf3, M.A(v), M.H(v)) == (:err, MethodError)
    status, msg = WasmRunner.run_wasm_single(bytes, "gf3", "instance.exports.mkA(0), instance.exports.mkH(0)";
                                             source_map=json)
    @test status === :trap
    # the selector as Julia prints the function (qualified when Main does not see it)
    @test occursin(r"at `(?:[\w.]+\.)?f3, axis 2 \(polymorphic dispatcher\)`: polymorphic dispatcher", msg)
end

# A closure trampoline is named "$name trampoline" by the closure type's short name, as dart's
# makeTrampoline (translator.dart:1468), never its full printed type: a closure capturing a
# solver's problem type would otherwise put that type's text into the name section and every frame
struct _GNWide{A,B,C} x::Int64 end
function _gn_wide(x::Int64)::Int64
    p = _GNWide{NTuple{8,Tuple{Int64,Float64}},Vector{Dict{Symbol,Int64}},Val{:a_long_type_parameter}}(x)
    fs = Any[y -> y + p.x]
    return (fs[1])(x)::Int64
end

@testset "generated names: a closure trampoline is named by the closure's short name" begin
    mod = _GN.compile_module([(_gn_wide, (Int64,))])
    tramps = [f.name for f in mod.functions if endswith(f.name, " trampoline")]
    @test !isempty(tramps)
    @test all(n -> length(n) <= 64 && !occursin("_GNWide", n), tramps)
end
