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
    :dispatch_wrapper => "f2(::A, ::A)",
    :polymorphic_dispatcher => "f3, axis 2",
    :lazy_initializer => _GN.constant_name("a string constant\nsecond line"),
    :field_initializer => "Main.COUNTER",
    :foreigncall_table => "utf8proc_toupper/utf8proc_tolower/utf8proc_totitle/utf8proc_isupper/utf8proc_islower",
    :export_entry => "gf2",
    :as_checker => "Tuple{Any, Any}",
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
    for ordinary in ("f", "f2(::Int64) @ Main", "_gn_oc(::Int64) [_gn_oc(::Integer)] @ Main", "(::var\"#h#2\"{Int64})(::Int64) @ Main",
                     "gf2", "trampoline", "#init_1", "_smt_boom")
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
    mod = _GN.compile_module(fns; options=_GN.options_from_env())
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
    @test occursin(r"at `(?:[\w.]+\.)?f2[^`]* \(dispatch wrapper\)`: dispatch wrapper", msg)
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
    mod = _GN.compile_module([(_gn_wide, (Int64,))]; options=_GN.options_from_env())
    tramps = [f.name for f in mod.functions if endswith(f.name, " trampoline")]
    @test !isempty(tramps)
    @test all(n -> length(n) <= 64 && !occursin("_GNWide", n), tramps)
end

# A compiled function is named by its Julia identity, the specialization as Julia prints a
# MethodInstance (show_mi: argument types only, the function qualified unless its module exports it
# or it is Main's) and its method's module, as a stack frame prints it (` @ Main`), not a counter:
# two specializations of one generic function each carry their own signature, and the names do not
# depend on the order the plan lists them in (a counter named the second one `_gn_two_1` or
# `_gn_two` by order). A requested entry keeps its requested name. Where two methods cover one
# specialization, the one Julia's dispatch selects keeps the signature and the invoke-only one adds
# its method's own declared signature: smoke's invoke_names_its_method and closure_invoke_only_body,
# pinned here as smoke defines them. Two generic functions of one name in two modules are told apart
# by their qualification and their module (each compiles, dev/AUDIT.md A19C2); the name's one limit,
# two same-named functions printed unqualified whose methods of one signature one module defines,
# is refused at the plan naming both methods' lines.
@noinline _gn_two(x::Int64) = x + 1
@noinline _gn_two(x::Float64) = x * 2.0
_gn_both(n::Int64) = _gn_two(n) + Int64(round(_gn_two(Float64(n))))
_gn_both_rev(n::Int64) = Int64(round(_gn_two(Float64(n)))) + _gn_two(n)
module _GNA; @noinline f(x::Int64) = x + 1; end
module _GNB; @noinline f(x::Int64) = x + 2; end
_gn_alike(n::Int64) = _GNA.f(n) + _GNB.f(n)
# the limit: Main's own _gn_res and _GNX's exported _gn_res, each printed unqualified, with methods
# of one signature both defined here
module _GNX; export _gn_res; function _gn_res end; end
@noinline _gn_res(x::Int64) = x + 1
@noinline _GNX._gn_res(x::Int64) = x + 2
_gn_res_both(n::Int64) = _gn_res(n) + _GNX._gn_res(n)
# smoke's programs, as smoke.jl defines them (its main() runs only when it is the program)
module _GNSmoke; include(joinpath(@__DIR__, "smoke.jl")); end
_gn_smoke_case(name) = only(c for (_, cs) in _GNSmoke.GROUPS for c in cs if c[1] == name)
@testset "a compiled function is named by its signature" begin
    names(m) = Set(f.name for f in m.functions)
    run_i64(m, f) = (r = WasmRunner.run_wasm_single(_GN.to_bytes(m), f, "3n"); r[1] === :ok ? parse(Int, r[2]["__bigint__"]) : r)
    m1 = _GN.compile_module(Any[(_gn_both, (Int64,), "both")]; options=_GN.options_from_env())
    m2 = _GN.compile_module(Any[(_gn_both_rev, (Int64,), "both_rev")]; options=_GN.options_from_env())
    local here = string(@__MODULE__)
    for (m, entry) in ((m1, "both"), (m2, "both_rev"))
        @test "_gn_two(::Int64) @ $here" in names(m)
        @test "_gn_two(::Float64) @ $here" in names(m)
        @test entry in names(m)   # a requested entry keeps its name
        @test any(e -> e.name == "_gn_two(::Int64) @ $here", m.exports)
    end
    # two methods over one specialization: the dispatched one bare, the invoke-only one suffixed
    local (_, inv, inv_arg) = _gn_smoke_case("invoke_names_its_method")
    mi = _GN.compile_module(Any[(inv, (Int64,), "inv")]; options=_GN.options_from_env())
    local S = string(_GNSmoke)
    @test "$S._sm_oc(::Int64) @ $S" in names(mi)
    @test "$S._sm_oc(::Int64) [$S._sm_oc(::Integer)] @ $S" in names(mi)
    @test run_i64(mi, "inv") == inv(inv_arg) == 103004
    # a closure's two methods over Int64, one reached by `invoke`: Julia prints the closure type
    local (_, rows, rows_arg) = _gn_smoke_case("closure_invoke_only_body")
    mr = _GN.compile_module(Any[(rows, (Int64,), "rows")]; options=_GN.options_from_env())
    # (the closure type prints with its module where it is not Main's, as here: `_GNSmoke.var"#h#…"`)
    local hnames = sort!([f.name for f in mr.functions if occursin(r"^\(::(?:\w+\.)*var\"#h#", f.name) &&
                          occursin("(::Int64)", f.name) && !endswith(f.name, " (export)")])
    local T = only(unique(match(r"^\(::((?:\w+\.)*var\"[^\"]*\")", n).captures[1] for n in hnames))
    @test hnames == sort!(["(::$(T){Int64})(::Int64) @ $S", "(::$(T){Int64})(::Int64) [(::$(T))(::Integer)] @ $S"])
    @test run_i64(mr, "rows") == rows(rows_arg) == 12
    # two generic functions of one name in two modules: each named with its module, compiled, and
    # the program answers as native (refused as an internal error before, dev/AUDIT.md A19C2)
    ma = _GN.compile_module(Any[(_gn_alike, (Int64,), "alike")]; options=_GN.options_from_env())
    @test "$here._GNA.f(::Int64) @ $here._GNA" in names(ma) && "$here._GNB.f(::Int64) @ $here._GNB" in names(ma)
    @test run_i64(ma, "alike") == _gn_alike(3) == 9
    # the name's limit: refused at the plan, a WasmCompileError naming both methods' lines
    @test _gn_res_both(3) == 9
    err = try; _GN.compile_module(Any[(_gn_res_both, (Int64,), "res")]; options=_GN.options_from_env()); nothing; catch e; e; end
    @test err isa _GN.WasmCompileError
    local msg = sprint(showerror, err)
    @test occursin("two functions named _gn_res", msg) && occursin("generated_names.jl:", msg)
    # every other pair that prints alike is a defect: the same specialization planned twice
    local two = _GN.entry_method_instance(_GN.WasmInterpreter(Base.RefValue(0)), _gn_two, (Int64,))
    err = try
        _GN.plan_function_names!(Any[(_gn_two, (Int64,), "", two), (_gn_two, (Int64,), "", two)], Dict{Any,String}(),
                                 Set{Core.MethodInstance}(), IdDict{Core.MethodInstance,String}())
        nothing
    catch e
        e
    end
    @test err isa _GN.WasmInternalError && occursin("print alike", sprint(showerror, err))
end

# A name does not depend on Main's `using`s: Julia's type printer qualifies a type unless it is
# visible from the printing module, Main by default, so a `using` in Main once renamed every
# function whose signature names that module's type. The name is printed from a fixed module
# (JuliaNameContext): the same compile before and after `using` answers the same names. (A
# closure type's gensym, `var"#h#2"`, is Julia's identity of the type and follows the load order:
# code lowered earlier in a session renames it, and the bytes with it.)
Core.eval(Main, :(module _GNSession; struct GNPoint; x::Int64; end; export GNPoint; end))
@noinline _gn_session_x(p) = p.x + 1
_gn_session(n::Int64) = _gn_session_x(Main._GNSession.GNPoint(n))
# a type parameter Julia prints through a show defined outside Base and Core: refused, naming the
# type, never left to that code to decide a name
struct _GNShown; v::Int64; end
Base.show(io::IO, x::_GNShown) = print(io, "shown#", x.v)
@noinline _gn_shown_x(::Val{V}, n::Int64) where {V} = V.v + n
_gn_shown(n::Int64) = _gn_shown_x(Val(_GNShown(2)), n)
# a UnionAll parameter with its own show: the printer calls show(io, p) on it as on any parameter
struct _GNParamS{T}; x::T; end
const _GNParam = _GNParamS
Base.show(io::IO, ::Type{_GNParam}) = print(io, "param#")
@noinline _gn_param_x(::Type{_GNParam}, n::Int64) = n + 1
_gn_param(n::Int64) = _gn_param_x(_GNParam, n)
# what the printer runs, asked as it runs it (dev/AUDIT.md A19C3): a show for IOContext, the
# printer's stream, which a question asked as `IO` missed; a constructor's type written with `print`;
# a value Base shows by calling its own methods (`show(io, ::Signed)` calls its `string`)
struct _GNCtx; x::Int64; end
Base.show(io::IOContext, ::Type{_GNCtx}) = print(io, "ctx#")
@noinline _gn_ctx_x(p::_GNCtx) = p.x + 1
_gn_ctx(n::Int64) = _gn_ctx_x(_GNCtx(n))
struct _GNCall; k::Int64; end
@noinline _GNCall(k::Int64, j::Int64) = _GNCall(k + j)   # a constructor: its type is the function slot
Base.print(io::IO, ::Type{_GNCall}) = Base.write(io, "call#")
_gn_call(n::Int64) = _GNCall(2, n).k
primitive type _GNSigned <: Signed 64 end
Base.string(::_GNSigned) = "signed#"
Base.hash(x::_GNSigned, h::UInt) = hash(reinterpret(Int64, x), h)
const _GN_SIGNED_3 = reinterpret(_GNSigned, Int64(3))
@noinline _gn_signed_x(::Val{V}, n::Int64) where {V} = n + 1
_gn_signed(n::Int64) = _gn_signed_x(Val(_GN_SIGNED_3), n)
@testset "a compiled function's name does not depend on Main's `using`s" begin
    fnames(m) = sort!([f.name for f in m.functions])
    before = fnames(_GN.compile_module(Any[(_gn_session, (Int64,), "session")]; options=_GN.options_from_env()))
    @test "_gn_session_x(::Main._GNSession.GNPoint) @ $(@__MODULE__)" in before
    Core.eval(Main, :(using ._GNSession))
    @test isdefined(Main, :GNPoint)   # the type is now visible from Main
    after = fnames(_GN.compile_module(Any[(_gn_session, (Int64,), "session")]; options=_GN.options_from_env()))
    @test after == before
    err = try; _GN.compile_module(Any[(_gn_shown, (Int64,), "shown")]; options=_GN.options_from_env()); nothing; catch e; e; end
    @test err isa _GN.WasmCompileError
    local msg = sprint(showerror, err)
    @test occursin("which a `show` defined outside Base and Core prints", msg) && occursin("_GNShown", msg) && !occursin("shown#", msg)
    err = try; _GN.compile_module(Any[(_gn_param, (Int64,), "param")]; options=_GN.options_from_env()); nothing; catch e; e; end
    @test err isa _GN.WasmCompileError
    msg = sprint(showerror, err)
    @test occursin("which a `show` defined outside Base and Core prints", msg) && occursin("_GNParamS", msg) && !occursin("param#", msg)
    for (f, type_named, users) in ((_gn_ctx, "_GNCtx", "ctx#"), (_gn_call, "_GNCall", "call#"), (_gn_signed, "_GNSigned", "signed#"))
        @test f(1) == (f === _gn_call ? 3 : 2)
        err = try; _GN.compile_module(Any[(f, (Int64,), "f")]; options=_GN.options_from_env()); nothing; catch e; e; end
        @test err isa _GN.WasmCompileError
        msg = sprint(showerror, err)
        @test occursin("defined outside Base and Core prints", msg) && occursin(type_named, msg) && !occursin(users, msg)
    end
end
