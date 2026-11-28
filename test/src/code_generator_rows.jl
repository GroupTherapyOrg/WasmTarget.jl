# dart2wasm's code_generator.dart, ported (src/code_generator.jl): the third of test/src/code_generator.jl that
# rejects at its rows and raises Julia's errors (split with code_generator_nir.jl and code_generator_static.jl, each
# testset moved verbatim): a field named at run time (jl_f_getfield's switch), an unresolved call, a field outside
# the layout, a variable captured before it is assigned, a field an allocation leaves undefined, UndefVarError, a
# set flag.

module CodeGeneratorRowsTest

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "codegen_helpers.jl"))

# repeated verbatim from code_generator_nir.jl, which the :489 testset reads
module FieldGenCases
struct P; a::Int32; b::Float64; end
struct N; x::Int8; y::UInt8; end
getb(p::P) = p.b
mk(x::Int32) = P(x, 2.0)
mkn(x::Int8) = N(x, 0x01)
end

# a field Julia names at run time: jl_f_getfield's get_checked_fieldindex (julia/src/builtins.c:994),
# a Symbol compared with each field name by identity (jl_field_index), an Int against the field count;
# its misses FieldError(T, name) and BoundsError(x, i), an undefined field UndefRefError
module RunTimeFieldCases
struct Mix; a::Int64; b::Float64; s::String; end
mutable struct Part; a::Int64; b; Part() = new(1); end
@noinline pick(x::Int) = x > 2 ? :a : x > 0 ? :b : x > -5 ? :s : :z
# each field's value at the type inference gives the read, Union{Float64, Int64, String}
code(v) = v isa Int64 ? v : v isa Float64 ? 1000 : v isa String ? 2000 + ncodeunits(v) : -1
by_name(x::Int) = try
        code(getfield(Mix(x, 1.5, "qq"), pick(x)))
    catch e
        e isa FieldError && e.type === Mix && e.field === :z ? -7 : -8
    end
by_index(x::Int) = try
        code(getfield(Mix(x, 2.5, "q"), x))
    catch e
        e isa BoundsError && e.a isa Mix && e.i === x ? -9 : -10
    end
undef_read(x::Int) = (m = Part(); try; code(getfield(m, x > 0 ? :b : :a)); catch e; e isa UndefRefError ? -1 : -2; end)
no_fields(x::Int) = try; getfield(UInt64(x), pick(x)); 0; catch e; e isa FieldError && e.type === UInt64 ? 7 : 8; end
# a tuple's field names are its positions: a Symbol is none of them
tuple_name(x::Int) = try; getfield((x, 2), pick(x)); 0; catch e; e isa FieldError && e.type === Tuple{Int64,Int64} && e.field === :a ? 5 : 6; end
@noinline dt(T::DataType, s::Symbol) = getfield(T, s)
of_dt(x::Int) = (v = dt(x > 0 ? Int64 : Float64, x > 2 ? :hash : :flags); v isa Int32 ? Int64(v::Int32) : -1)
of_module(x::Int) = getfield(x > 0 ? Base : Core, x > 2 ? :pi : :nothing) === nothing ? 1 : 2
end

@testset "builtins.c: a field named at run time is jl_f_getfield's switch over the names (visitInstanceGet)" begin
    local R = RunTimeFieldCases
    # the name is no constant in Julia's IR: getfield(::Mix, ::Symbol), its type the union of the fields'
    local ir = only(Base.code_ircode(R.by_name, (Int,)))[1]
    local i = findfirst(st -> Meta.isexpr(st, :call) && (local g = st.args[1]; g isa GlobalRef && getglobal(g.mod, g.name) === Core.getfield) && st.args[3] isa Core.SSAValue, ir.stmts.stmt)
    @test i !== nothing && ir.stmts.type[i] == Union{Int64, Float64, String}
    # native Julia's own answers: each field, FieldError, BoundsError, UndefRefError
    @test R.by_name(3) == 3 && R.by_name(1) == 1000 && R.by_name(0) == 2002 && R.by_name(-6) == -7
    @test R.by_index(1) == 1 && R.by_index(2) == 1000 && R.by_index(3) == 2001 && R.by_index(4) == -9 && R.by_index(0) == -9
    @test R.undef_read(3) == -1 && R.undef_read(-3) == 1 && R.no_fields(1) == 7 && R.tuple_name(3) == 5
    # run by node, each arm and each raise answers as native Julia
    # a DataType's fields its type value's layout does not hold are read from their tables by class id
    # (src/julia/classes.jl kind_field_table): `hash` and `flags` answer as native (test/src/kind_field_table.jl reads the rest)
    for (f, xs) in ((R.by_name, Int64[3, 1, 0, -6]), (R.by_index, Int64[1, 2, 3, 4, 0, -1]), (R.undef_read, Int64[3, -3]), (R.no_fields, Int64[1]), (R.tuple_name, Int64[3]),
                    (R.of_dt, Int64[3, 1]))
        queue_native!("$(nameof(f)) ", W.compile(f, (Int,); optimize = false), f, [(x,) for x in xs])
    end
    # a Module's getfield is jl_f_getglobal, a binding: located
    local m = rejection(() -> W.compile(R.of_module, (Int,)))
    @test m !== nothing && m.rejection isa W.Unquarantined && occursin("a field of Module named at run time, which Julia reads as the module's global binding", m.rejection.row)
end
module ThrowCases
struct E; v::Int64; end
thr(x::Int64) = x < 0 ? throw(E(x)) : x
# Julia throws any value, an Int too
thr_int(x::Int64) = x < 0 ? throw(x) : x
# Base's conversion throws InexactError through Base's own throw_inexacterror, a Core.throw
to_u8(x::Int64) = Int64(UInt8(x))
end

@testset "code_generator.dart: an unresolved call and a field outside the layout reject at their rows" begin
    local g = codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    # a generic call Julia left unresolved (the trim verifier's must-throw warning) is Julia's
    # MethodError throw, never dart's dynamic invocation: rejected at the throw's port, not at the
    # intrinsifier's
    local e = rejection(() -> D.visit_static_invocation(g, W.NirCall(W.NirValue[W.NirConst(Core.Const(sin)), W.NirArgument(2)]), IR.NumType_f64))
    @test e.rejection isa W.Unquarantined && occursin("src/julia/runtime/rtutils.jl", e.rejection.row) && occursin("proved throws", e.at)
    # a definition only a node Julia has no counterpart for reaches rejects by its Kernel row: Internal at
    # the definition, naming the row and its reason, the one source of that text
    local k = rejection(() -> W.no_counterpart_rejection("Let", "dart2wasm/lib/code_generator.dart:1603 AstCodeGenerator.visitLet", "at"))
    @test k.rejection isa W.Internal && occursin("AstCodeGenerator.visitLet: the Kernel table's Let row, no counterpart", k.rejection.site) &&
          occursin("visit_block", k.rejection.site)
    @test rejection(() -> W.no_counterpart_rejection("ReturnStatement", "a", "b")).rejection isa W.Internal
    # Julia's throw(x), Kernel's Throw: the exception, then the runtime's thrower, which throws it with
    # the program's tag: a wasm exception, never a trap, and native's answer where nothing is thrown
    for (f, x, T) in ((ThrowCases.thr, -1, ThrowCases.E), (ThrowCases.thr_int, -2, Int))
        @test (try; f(x); nothing; catch err; err; end) isa T
        local bytes = W.compile(f, (Int64,); optimize = false)
        push!(NATIVE_RUNS, WTChild.RunCase("$(nameof(f))($x) throws ", bytes, (x,), WTChild.Throws(T)))
        queue_native!("$(nameof(f)) ", bytes, f, [(7,)])
    end
    # Base's InexactError is built by its varargs constructor of an open count, InexactError(f, args...),
    # whose call packs (T, val) into a tuple: T's class, a Type, only run time knows (Julia's jl_f_tuple
    # reads the value's), so the call builds the record of its arity (TupleRecord), T boxed in it:
    # InexactError raised where native raises it
    @test (try; ThrowCases.to_u8(300); nothing; catch err; err; end) isa InexactError
    local iv_bytes = W.compile(ThrowCases.to_u8, (Int64,); optimize = false)
    push!(NATIVE_RUNS, WTChild.RunCase("to_u8(300) throws ", iv_bytes, (300,), WTChild.Throws(InexactError)))
    queue_native!("to_u8 ", iv_bytes, ThrowCases.to_u8, [(7,)])
    # dart's dynamic invocation has no Julia input: the verifier resolves every call it admits but a
    # must-throw one, so reaching it is WasmTarget's own defect, naming Julia's replacement
    local d = rejection(() -> D._handle_dynamic_invocation(g, W.NirArgument(2), W.NirValue[], :f))
    @test d.rejection isa W.Internal && occursin("trim verifier", d.rejection.site) && occursin("visitStaticInvocation", d.rejection.site)
    # Julia's IR is a CFG, which visit_block structures by LLVM's CFGStackify port: each structured
    # statement's visitor takes the Kernel table's NoCounterpart, which no value inhabits, so no NIR
    # reaches one; a try region too, Julia's EnterNode, which visit_block structures as a try_table
    for v in (D.visit_labeled_statement, D.visit_break_statement, D.visit_if_statement, D.visit_do_statement, D.visit_while_statement,
              D.visit_for_statement, D.emit_for_statement_update, D.visit_switch_statement, D.visit_continue_switch_statement,
              D.visit_try_catch, D.visit_try_finally)
        @test only(m for m in methods(v) if m.sig.parameters[2] === D.AstCodeGenerator).sig.parameters[3] === W.NoCounterpart
    end
    # a constant name none of P's fields: Julia's codegen leaves the read to jl_f_getfield (julia/src/codegen.cpp:4533),
    # whose FieldError is raised at run time (test/src/absent_field.jl runs it against native), so the read takes the
    # run-time name's switch, never the layout's "does not hold" rejection (A44S1's, now Julia's answer): this bare
    # generator reaches the switch's first instruction, its builder, which no body's generation has assigned
    local t = translator_of(FieldGenCases.getb, (FieldGenCases.P,))
    local body = entry_body(t.component)
    local gb = D.SynchronousProcedureCodeGenerator(Val(:_), t, IR.FunctionType(IR.ValueType[], IR.ValueType[]), body.ci.def, body)
    local gf = body.stmts[findfirst(s -> s isa W.NirCall, body.stmts)]::W.NirCall
    local nofield = W.NirCall(W.NirValue[gf.args[1], gf.args[2], W.NirConst(Core.Const(:nope))])
    local r = rejection(() -> D.visit_instance_get(gb, nofield, IR.NumType_f64))
    @test r.rejection isa W.Unported && occursin("AstCodeGenerator.b, read before its assignment", sprint(showerror, r)) &&
          !occursin("does not hold", sprint(showerror, r))
end

# a variable a closure captures before it is assigned: Julia's closure conversion allocates Core.Box() with
# its contents undefined; until the runtime's throw is ported, a located Unported rejection, never a null
module BoxCases
@noinline function counter(n::Int)
    local f
    f = () -> n + 1
    return f()
end
@noinline function recur(n::Int)
    local g
    g = k -> k <= 0 ? 0 : k + g(k - 1)
    return g(n)
end
end
@testset "an allocation leaving a field undefined: Core.Box of a variable captured before it is assigned" begin
    for f in (BoxCases.counter, BoxCases.recur)
        local bytes = try
            W.compile(f, (Int,); optimize = false)
        catch e
            e isa W.RejectionError || rethrow()
            # located; a Core.Box's contents::Any admits `nothing`, so it keeps its set flag
            # (class_is_set_field) and compiles, its run compared with native's
            @test !isempty(e.at)
            nothing
        end
        bytes === nothing || queue_native!("$(nameof(f)) ", bytes, f, [(3,), (0,)])
    end
end

# a struct whose constructor leaves a reference field undefined: Julia's NULL, read as UndefRefError
module UndefFieldCases
mutable struct Node
    v::Int
    next::Node
    Node(v::Int) = new(v)
end
linked(x::Int) = (n = Node(x); n.next = Node(x + 1); n.next.v)
unlinked(x::Int) = Node(x).next.v
end
@testset "code_generator.dart: a field an allocation leaves undefined, null until set, its read Julia's UndefRefError" begin
    @test Core.Compiler.datatype_min_ninitialized(UndefFieldCases.Node) == 1
    # set before it is read: the value; read while undefined: UndefRefError, a wasm exception, never a trap
    queue_native!("linked ", W.compile(UndefFieldCases.linked, (Int,); optimize = false), UndefFieldCases.linked, [(4,), (-1,)])
    @test (try; UndefFieldCases.unlinked(4); nothing; catch err; err; end) isa UndefRefError
    push!(NATIVE_RUNS, WTChild.RunCase("unlinked(4) throws ", W.compile(UndefFieldCases.unlinked, (Int,); optimize = false), (4,), WTChild.Throws(UndefRefError)))
end

# a local read where it may be unassigned: Julia's lowering checks it by name (`throw_undef_if_not`), its
# codegen raising UndefVarError of the variable in the :local scope (julia/src/cgutils.cpp:1596
# undef_var_error_ifnot) through the runtime's jl_undefined_var_error (julia/src/rtutils.c:142)
module UndefVarCases
function maybe(c::Bool)
    if c
        x = 1
    end
    return x
end
# the error the read raises, its variable and scope read where it is caught
caught(c::Bool) = try; maybe(c); catch e; e isa UndefVarError ? (e.var === :x ? 10 : 20) + (e.scope === :local ? 1 : 2) : -1; end
end
@testset "Julia's undefined-variable check of a local raises UndefVarError through jl_undefined_var_error" begin
    local native = try; UndefVarCases.maybe(false); nothing; catch err; err; end
    @test native isa UndefVarError && native.var === :x && native.scope === :local
    @test any(s -> Meta.isexpr(s, :throw_undef_if_not) && s.args[1] === :x, Base.code_typed(UndefVarCases.maybe, (Bool,))[1][1].code)
    # the check calls jl_undefined_var_error, whose UndefVarError reads the task's world age by a call of
    # libjulia's jl_get_tls_world_age, lowered inline (julia/src/ccall.cpp:1717): the world the closed
    # world was inferred in, never a host import
    @test any(s -> Meta.isexpr(s, :foreigncall) && s.args[1] == QuoteNode(:jl_get_tls_world_age), Base.code_typed(UndefVarError, (Symbol, Symbol))[1][1].code)
    queue_native!("maybe ", W.compile(UndefVarCases.maybe, (Bool,); optimize = false), UndefVarCases.maybe, [(true,)])
    push!(NATIVE_RUNS, WTChild.RunCase("maybe(false) throws ", W.compile(UndefVarCases.maybe, (Bool,); optimize = false), (false,), WTChild.Throws(UndefVarError)))
    queue_native!("caught ", W.compile(UndefVarCases.caught, (Bool,); optimize = false), UndefVarCases.caught, [(true,), (false,)])
end

# a field that may be left undefined and may hold nothing keeps dart's late lowering's set flag
# (class_is_set_field): its #undef read raises UndefRefError, a written nothing reads nothing, and
# isdefined reads the flag; a reference field excluding nothing keeps the null for #undef
module IsSetFieldCases
mutable struct Part
    a::Int64
    s::String
    c::Any
    d::Union{Nothing,String}
    Part(a) = new(a)
    Part(a, s, c, d) = new(a, s, c, d)
end
struct Frozen
    x::Any
    Frozen() = new()
    Frozen(x) = new(x)
end
const PART = Part(5)
# every case in one program, case k on x, so the cases cost one compile
function undef_case(k::Int64, x::Int64)
    k == 1 && return Int64(Part(x).d === nothing)                           # #undef: UndefRefError
    k == 2 && return (p = Part(x); p.d = nothing; Int64(p.d === nothing))   # a written nothing
    k == 3 && return Int64(Part(x, "s", x, nothing).d === nothing)          # a given nothing
    k == 4 && return (p = Part(x); Int64(isdefined(p, :d)) + 2 * Int64(isdefined(p, :s)) + 4 * Int64(isdefined(p, :a)))
    k == 5 && return (p = Part(x); p.d = "d"; p.s = "s"; Int64(isdefined(p, :d)) + 2 * Int64(isdefined(p, :s)))
    k == 6 && return Int64(Part(x).c === nothing)                           # an Any left undefined
    k == 7 && return (p = Part(x); p.c = nothing; Int64(p.c === nothing))
    k == 8 && return Int64(isdefined(Frozen(), :x)) + 2 * Int64(isdefined(Frozen(nothing), :x))
    k == 9 && return Int64(getfield(Frozen(nothing), :x) === nothing)
    k == 10 && return Int64(getfield(Frozen(), :x) === nothing)             # UndefRefError
    k == 11 && return Int64(isdefined(PART, :d))                            # a constant's flag
    return Int64(PART.d === nothing)                                        # its #undef: UndefRefError
end
end
@testset "late_lowering.dart: a field admitting nothing keeps its set flag, its #undef apart from nothing" begin
    local f = IsSetFieldCases.undef_case
    @test [f.name for f in W.class_instance_fields(IsSetFieldCases.Part, "code_generator")] == ["a", "s", "c", "d", "c#isSet", "d#isSet"]
    @test W.class_instance_fields(IsSetFieldCases.Frozen, "code_generator")[2] == W.ClassField(IsSetFieldCases.Frozen, 0, "x#isSet", Bool, false)
    local bytes = W.compile(f, (Int64, Int64); optimize = false)
    local cases = [WTChild.RunCase("undef_case$a", bytes, a, WTChild.native_answer(f, a)) for a in ((Int64(k), Int64(3)) for k in 1:12)]
    @test count(c -> c.native isa WTChild.Throws, cases) == 4
    append!(NATIVE_RUNS, cases)
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTChild.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end

end
