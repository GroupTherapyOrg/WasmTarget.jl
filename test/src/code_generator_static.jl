# dart2wasm's code_generator.dart, ported (src/code_generator.jl): the third of test/src/code_generator.jl over
# isdefined's orders and typeof, convertType's unboxing, the switch info, the members Julia never has, type
# literals, static and instance fields' generators, and Base's fallback == (split with code_generator_nir.jl and
# code_generator_rows.jl, each testset moved verbatim).

module CodeGeneratorStaticTest

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "codegen_helpers.jl"))

# repeated verbatim from code_generator_nir.jl, which the implicit getter and setter testset reads
module SetGenCases
mutable struct M; a::Int32; const c::Int32; end
seta(m::M, v::Int32) = (m.a = v; nothing)
end

# isdefined given an order: one that does not fit the field raises Julia's ConcurrencyViolationError
# (codegen.cpp's emit_atomic_error), :not_atomic on a plain field reads as without; and a type made at run
# time is one of the program's canonical constants, the ground of === on DataTypes as ref.eq (A68S3):
# typeof reads its tag's entry, apply_type finds its type in the statement's cache (jltypes.c lookup_type),
# and apply_type on an operand whose values the cache cannot key rejects at its statement
module AtomicOrderCases
mutable struct Plain
    x::Any
    Plain() = new()
end
mutable struct Atom
    @atomic x::Any
    Atom() = new()
end
function orders(k::Int64)
    k == 1 && return Int64(isdefined(Plain(), :x, :not_atomic))
    k == 2 && return Int64(isdefined(Plain(), :x, :acquire))                # non-atomic field, atomically
    k == 3 && return Int64(isdefined(Atom(), :x, :not_atomic))              # atomic field, non-atomically
    k == 4 && return Int64(isdefined(Plain(), :y, :acquire))                # an order on no field
    return Int64(isdefined(Plain(), :x, :release))                          # a store's order
end
# typeof of a value only run time knows, an element of a Vector of a Union: Julia's jl_typeof, run
# against native; and of an Any, a value that may be a Memory{Any}, whose type value is made: its
# Core.AddrSpace{Core}(0x00) parameter's class is met by the walk (src/julia/classes.jl closed_world_classes)
kind_of(n::Int64) = (v = Union{Int64,Float64,Int32}[Int64(1), 2.0, Int32(3)]; t = typeof(v[n]); Int64(t === Int64) + 2Int64(t === Float64) + 4Int64(t === Int32))
any_kind_of(n::Int64) = (v = Any[n, 1.0]; t = typeof(v[n > 0 ? 1 : 2]); Int64(t === Int64) + 2Int64(t === Float64))
apply_of(v::Vector{Any}) = Int64(Core.apply_type(v[1], v[2]) === Vector{Int64})
# apply_type on an operand of two values, run against native: a DataType (its === the ref.eq of the
# cache's constant) and a Union (jl_type_union's, its === Julia's egal)
@noinline made_param(n::Int64) = n > 0 ? Int64 : Float64
made_of(n::Int64) = (T = made_param(n); Int64(Vector{T} === Vector{Int64}) + 2Int64(Union{T,Nothing} === Union{Float64,Nothing}))
end
@testset "codegen.cpp: isdefined's order checks raise ConcurrencyViolationError; typeof is jl_typeof; apply_type finds its type in its cache (A68S3)" begin
    local f = AtomicOrderCases.orders
    local bytes = W.compile(f, (Int64,); optimize = false)
    local cases = [WTChild.RunCase("orders$a", bytes, a, WTChild.native_answer(f, a)) for a in ((Int64(k),) for k in 1:5)]
    @test count(c -> c.native == WTChild.Throws(ConcurrencyViolationError), cases) == 4
    append!(NATIVE_RUNS, cases)
    local kbytes = W.compile(AtomicOrderCases.kind_of, (Int64,); optimize = false)
    append!(NATIVE_RUNS, [WTChild.RunCase("kind_of($n)", kbytes, (n,), AtomicOrderCases.kind_of(n)) for n in Int64[1, 2, 3]])
    local akbytes = W.compile(AtomicOrderCases.any_kind_of, (Int64,); optimize = false)
    append!(NATIVE_RUNS, [WTChild.RunCase("any_kind_of($n)", akbytes, (n,), AtomicOrderCases.any_kind_of(n)) for n in Int64[1, -1]])
    local e = rejection(() -> W.compile(AtomicOrderCases.apply_of, (Vector{Any},); optimize = false))
    @test e !== nothing && e.rejection isa W.Unquarantined && !isempty(e.at) &&
          startswith(e.rejection.row, "src/julia/classes.jl apply_type_cache: an operand of Julia's apply_type typed Any")
    local mbytes = W.compile(AtomicOrderCases.made_of, (Int64,); optimize = false)
    append!(NATIVE_RUNS, [WTChild.RunCase("made_of($n)", mbytes, (n,), AtomicOrderCases.made_of(n)) for n in Int64[1, -1]])
end

# a value held as a reference narrowed to a primitive class (a PiNode): convertType's unboxing, the box
# of the PiNode's class, cast where the reference is wider; case k at i
module UnboxCases
function unbox(k::Int64, i::Int64)
    local v = Vector{Union{Nothing,Int64}}(undef, 2)
    v[1] = i
    if k <= 2
        local x = v[k]                      # Union{Nothing,Int64}, an inline bits union held boxed
        return x === nothing ? Int64(-1) : x
    end
    local a = Vector{Any}(undef, 2)
    a[1] = i
    a[2] = "s"
    local y = a[k - 2]                      # Any
    return y isa Int64 ? y + Int64(1) : Int64(0)
end
end
@testset "translator.dart: convertType unboxes a reference to its PiNode's primitive class" begin
    local f = UnboxCases.unbox
    local bytes = W.compile(f, (Int64, Int64); optimize = false)
    append!(NATIVE_RUNS, [WTChild.RunCase("unbox$a", bytes, a, WTChild.native_answer(f, a)) for a in ((Int64(k), Int64(7)) for k in 1:4)])
end

@testset "code_generator.dart: the switch statement's info, whose constructors no NIR reaches" begin
    # dart's fields, each by the one rule's name: the backward jump's local and labels, the jump table's
    # range, value pusher and cases, and the switch's types, comparisons, special cases and table
    @test fieldnames(D.SwitchBackwardJumpInfo) == (:switch_value_local, :loop_label, :default_loop_label)
    @test fieldnames(D.BrTableInfo) == (:min_value, :max_value, :_br_table_expr, :case_map)
    @test fieldnames(D.SwitchInfo) == (:nullable_type, :non_nullable_type, :dynamic_type_guard, :compare, :default_case, :null_case, :br_table)
    # a late field read before dart's constructor assigns it names the field
    local si = D.SwitchInfo(Val(:_))
    @test si.br_table === nothing && si.dynamic_type_guard === nothing
    @test occursin("SwitchInfo.compare", rejection(() -> si.compare[]).rejection.anchor)
    # Julia's IR has no switch statement: SwitchInfo's constructor and its special cases take the Kernel
    # table's NoCounterpart, which no value inhabits, so no NIR reaches either
    @test only(m for m in methods(D.SwitchInfo) if length(m.sig.parameters) == 3).sig.parameters[3] === W.NoCounterpart
    @test only(methods(D._initialize_special_cases)).sig.parameters[3] === W.NoCounterpart
    @test rejection(() -> W.NoCounterpart()).rejection isa W.Internal
end

@testset "code_generator.dart: the code generators of members Julia never has are types of no value" begin
    # each holds AstCodeGenerator's fields and dart's own, and its one inner constructor rejects Internal,
    # as dart's constructor, its outer function, does
    for (G, own) in ((D.TearOffCodeGenerator, (:member,)), (D.DynamicForwarderCodeGenerator, (:reference, :call_shape)),
                     (D.ConstructorInitializerCodeGenerator, (:member, :field_locals)), (D.ConstructorAllocatorCodeGenerator, (:member,)),
                     (D.ConstructorBodyCodeGenerator, (:member,)),
                     (D.SynchronousLambdaCodeGenerator, (:lambda,)), (D.UnreachableCodeGenerator, ()))
        @test G <: D.AstCodeGenerator
        @test fieldnames(G) == (fieldnames(D.SynchronousProcedureCodeGenerator)[1:18]..., own...)
        local e = rejection(() -> G(Val(:_)))
        @test e.rejection isa W.Internal && occursin("$(nameof(G)): no value", e.rejection.site)
    end
end

module TypeLiteralCases
struct Bx; t::DataType; n::Int; end
# Julia keeps the type literal Int64 as the allocation's operand, the field the callee does not read
@noinline getn(b::Bx) = b.n
mkb(x::Int) = getn(Bx(Int64, x)) + 1
end
@testset "code_generator.dart: a type as a value is makeType's, Kernel's TypeLiteral" begin
    local g = ready_codegen_of(TypeLiteralCases.mkb, (Int,), [IR.NumType_i64], [IR.NumType_i64])
    g.translator.globals[] = D.Globals(g.translator); g.translator.dart_globals[] = D.DartGlobals(g.translator)
    local tt = D.non_nullable_type_type(D.types(g))
    # a type with no free type variable is a constant: its global read, the type's wasm type
    @test emitted_by(() -> @test(D.translate_expression(g, W.NirConst(Core.Const(Int64)), tt) == tt), g) == ["global.get"]
    # the allocation's type operand compiles, and the module answers as native Julia
    queue_native!("mkb ", W.compile(TypeLiteralCases.mkb, (Int,); optimize = false), TypeLiteralCases.mkb, [(3,), (-1,)])
end

module StaticFieldCases
struct BoxCell; x::Int; end
global counter::Int = 7
global box::Base.RefValue{Int} = Ref(1)
bump(x::Int) = counter + box[] + x
end
# the translator of StaticFieldCases.bump as translate() leaves it before code, its DartGlobals assigned
function static_field_translator()
    local t = translator_of(StaticFieldCases.bump, (Int,))
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    t.globals[] = D.Globals(t)
    t.dart_globals[] = D.DartGlobals(t)
    return t
end
# a code generator of the binding, `G(t, type, binding, extra...)`, its builder a function of `type`
function static_field_codegen(G, t, ftype, extra...)
    local B = W.WasmBuilder
    local fb = B.define(D.main_module(t).functions[], ftype, "f")
    local g = G(t, ftype, GlobalRef(StaticFieldCases, :counter), extra...)
    g.b[] = B.body(fb)
    g.param_locals[] = B.locals(fb)
    g.return_label[] = nothing
    return g
end

@testset "code_generator.dart: unimplemented is never reached, every NIR form has its visitor" begin
    local t = static_field_translator()
    local counter = GlobalRef(StaticFieldCases, :counter)
    local g = static_field_codegen(D.StaticFieldInitializerCodeGenerator, t, D.get_function_type(t.functions[], D.FieldReference(counter, D.FieldReferenceKind_initializer)))
    # the closed NIR sums are matched @exhaustive by the code generator, so no form falls to a default
    @test any(m -> m[1] === D && m[2] === :NirValue, WasmTarget.MATCHES) && any(m -> m[1] === D && m[2] === :NirStmt, WasmTarget.MATCHES)
    # reaching dart's default is WasmTarget's defect, Internal and located, never a trap in the module
    local e = rejection(() -> D.default_expression(g, WasmTarget.NirConst(Core.Const(1)), W.WasmBuilder.IR.NumType_i64))
    @test e.rejection isa W.Internal && occursin("AstCodeGenerator.unimplemented", e.rejection.site) && occursin("@exhaustive", e.rejection.site)
end

@testset "code_generator.dart: a static field's initializer function" begin
    local t = static_field_translator()
    local counter = GlobalRef(StaticFieldCases, :counter)
    local init_ref = D.FieldReference(counter, D.FieldReferenceKind_initializer)
    local ftype = D.get_function_type(t.functions[], init_ref)
    # the field's initializer reference: getMemberCodeGenerator gives its generator
    local mb = D.main_module(t)
    local gm = D.get_member_code_generator(t, W.WasmBuilder.define(mb.functions[], ftype, "init"), init_ref)
    @test gm isa D.StaticFieldInitializerCodeGenerator && gm.field === counter && gm.enclosing_member === init_ref
    # the lazy arm's definition (a mutable global and its flag, made through FunctionCollector.getFunction):
    # the body writes the binding's session value, tees it, sets the flag and returns the value
    local g = static_field_codegen(D.StaticFieldInitializerCodeGenerator, t, ftype)
    @test emitted_by(() -> D.generate_internal(g), g) ==
          ["i64.const 7", "local.tee", "global.set", "local.get", "i32.const 1", "global.set", "end"]
    @test D.get_existing_function(t.functions[], init_ref) !== nothing
end

@testset "code_generator.dart: a static field's eager initializer, a type of no value" begin
    # dart makes it only for a field the startup pragma marks, which no Julia binding carries
    # (DartGlobals._initializeAtStartup answers no): the constructor and the struct reject Internal
    local t = static_field_translator()
    local counter = GlobalRef(StaticFieldCases, :counter)
    local gl = W.WasmBuilder.define(D.main_module(t).globals[], IR.GlobalType(D.translate_type_of_field(t, counter); mutable = true), "counter")
    @test !D._initialize_at_startup(t.dart_globals[], counter)
    local e = rejection(() -> D.EagerStaticFieldInitializerCodeGenerator(t, counter, gl))
    @test e.rejection isa W.Internal && occursin("startup pragma", e.rejection.site)
    @test rejection(() -> D.EagerStaticFieldInitializerCodeGenerator(Val(:_))).rejection isa W.Internal
end

@testset "code_generator.dart: a static field's implicit getter and setter" begin
    local B = W.WasmBuilder
    local t = static_field_translator()
    local mb = D.main_module(t)
    local dg = t.dart_globals[]
    local fc = t.functions[]
    local counter = GlobalRef(StaticFieldCases, :counter)
    local box = GlobalRef(StaticFieldCases, :box)
    local ty = D.translate_type_of_field(t, counter)
    local getter = IR.FunctionType(IR.ValueType[], IR.ValueType[ty])
    local acc(f, ftype, is_getter) = begin
        local fb = B.define(mb.functions[], ftype, "acc")
        local g = D.StaticFieldImplicitAccessorCodeGenerator(t, ftype, f, is_getter)
        g.b[] = B.body(fb); g.param_locals[] = B.locals(fb); g.return_label[] = nothing
        g
    end
    local g0 = acc(counter, getter, true)
    @test g0.enclosing_member === D.FieldReference(counter, D.FieldReferenceKind_getter) && g0.is_implicit_getter
    # the lazy arm's definition, made through getFunction in a translator of its own: an explicit flag
    # picks the global or the initializer's call
    let t0 = static_field_translator(), fb = B.define(D.main_module(t0).functions[], getter, "acc0"),
        g = D.StaticFieldImplicitAccessorCodeGenerator(t0, getter, counter, true)
        g.b[] = B.body(fb); g.param_locals[] = B.locals(fb); g.return_label[] = nothing
        @test emitted_by(() -> D.generate_internal(g), g) == ["global.get", "if", "global.get", "else", "call", "end", "end"]
        @test D.get_existing_function(t0.functions[], D.FieldReference(counter, D.FieldReferenceKind_initializer)) !== nothing
    end
    # a field with no initializer function is read and returned
    dg._definitions[counter] = D._define_global_based_field(dg, counter, ty, mb, true, nothing, nothing)
    local g1 = acc(counter, getter, true)
    @test emitted_by(() -> D.generate_internal(g1), g1) == ["global.get", "end"]
    # with its initializer function and an explicit flag: the flag picks the global or the initializer
    local flag = D._define_initializer_flag(dg, counter, mb)
    dg._definitions[counter] = D._define_global_based_field(dg, counter, ty, mb, true, nothing, flag)
    fc._functions[D.FieldReference(counter, D.FieldReferenceKind_initializer)] = B.define(mb.functions[], getter, "counter field initializer")
    local g2 = acc(counter, getter, true)
    @test emitted_by(() -> D.generate_internal(g2), g2) == ["global.get", "if", "global.get", "else", "call", "end", "end"]
    # the setter writes its parameter and sets the flag
    local g3 = acc(counter, IR.FunctionType(IR.ValueType[ty], IR.ValueType[]), false)
    @test emitted_by(() -> D.generate_internal(g3), g3) == ["local.get", "global.set", "i32.const 1", "global.set", "end"]
    # a reference field null when uninitialized: the read, branched past the initializer's call when
    # non-null
    local rty = D.translate_type_of_field(t, box)
    @test rty isa IR.RefType && !rty.nullable
    dg._definitions[box] = D._define_global_based_field(dg, box, B.with_nullability(rty, true), mb, true, nothing, nothing)
    local rgetter = IR.FunctionType(IR.ValueType[], IR.ValueType[rty])
    fc._functions[D.FieldReference(box, D.FieldReferenceKind_initializer)] = B.define(mb.functions[], rgetter, "box field initializer")
    local g4 = acc(box, rgetter, true)
    @test emitted_by(() -> D.generate_internal(g4), g4) == ["block", "global.get", "br_on_non_null", "call", "end", "end"]
end

@testset "the Kernel table's Reference: a member's MethodInstance or a field's accessor" begin
    local B = W.WasmBuilder
    local t = static_field_translator()
    local fc = t.functions[]
    local counter = GlobalRef(StaticFieldCases, :counter)
    local ty = D.translate_type_of_field(t, counter)
    local getter = D.FieldReference(counter, D.FieldReferenceKind_getter)
    local setter = D.FieldReference(counter, D.FieldReferenceKind_setter)
    # a field's reference compares by its field and kind, as dart's Reference by identity
    @test getter == D.FieldReference(counter, D.FieldReferenceKind_getter) && getter != setter
    # an instance field has no initializer reference: the pair cannot be made
    local cf = W.ClassField(StaticFieldCases.BoxCell, 0, "x", Int, false)
    @test rejection(() -> D.FieldReference(cf, D.FieldReferenceKind_initializer)).rejection isa W.Internal
    # a static field's getter takes nothing and returns the field; its setter takes it and returns nothing
    local fg = D.get_function_type(fc, getter); local fs = D.get_function_type(fc, setter)
    @test isempty(fg.inputs) && fg.outputs == [ty] && fs.inputs == [ty] && isempty(fs.outputs)
    @test D.get_function_name(fc, getter) == "$counter implicit getter" && D.get_function_name(fc, setter) == "$counter= implicit setter"
    @test D.synthesize_null_return_value(fc, setter) && !D.synthesize_null_return_value(fc, getter) && !D.synthesize_no_return(fc, getter)
    # getMemberCodeGenerator gives each accessor its generator
    local mb = D.main_module(t)
    local gg = D.get_member_code_generator(t, B.define(mb.functions[], D.get_function_type(fc, getter), "g"), getter)
    @test gg isa D.StaticFieldImplicitAccessorCodeGenerator && gg.is_implicit_getter
    local gs = D.get_member_code_generator(t, B.define(mb.functions[], D.get_function_type(fc, setter), "s"), setter)
    @test gs isa D.StaticFieldImplicitAccessorCodeGenerator && !gs.is_implicit_getter
end

@testset "code_generator.dart: an instance field's implicit getter and setter, a field selector's target" begin
    local B = W.WasmBuilder
    local t = translator_of(SetGenCases.seta, (SetGenCases.M, Int32))
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    local fc = t.functions[]
    local mb = D.main_module(t)
    local cf = W.class_instance_fields(SetGenCases.M, "test")[1]
    @test cf.name == "a" && cf.type === Int32
    local getter = D.FieldReference(cf, D.FieldReferenceKind_getter)
    local setter = D.FieldReference(cf, D.FieldReferenceKind_setter)
    local this_type = D.translate_type(t, SetGenCases.M)
    # the getter takes its class's reference and returns the field; the setter takes the value too
    local fg = D.get_function_type(fc, getter); local fs = D.get_function_type(fc, setter)
    @test fg.inputs == [this_type] && fg.outputs == [IR.NumType_i32]
    @test fs.inputs == [this_type, IR.NumType_i32] && isempty(fs.outputs)
    @test D.get_function_name(fc, getter) == "$(SetGenCases.M).a implicit getter"
    local acc(r, ftype) = begin
        local fb = B.define(mb.functions[], ftype, "acc")
        local g = D.get_member_code_generator(t, fb, r)
        g.b[] = B.body(fb); g.param_locals[] = B.locals(fb); g.return_label[] = nothing
        g
    end
    local gg = acc(getter, fg)
    @test gg isa D.ImplicitFieldAccessorCodeGenerator && gg.is_implicit_getter && !gg.use_unchecked_entry && gg.enclosing_member === getter
    @test emitted_by(() -> D.generate_internal(gg), gg) == ["local.get", "struct.get", "end"]
    local gs = acc(setter, fs)
    @test emitted_by(() -> D.generate_internal(gs), gs) == ["local.get", "local.get", "struct.set", "end"]
    @test gs.this_local === gs.param_locals[][1]
end

@testset "code_generator.dart: guardCanMatchJSException" begin
    # outside standalone mode a guard catches JS exceptions only when every value passes it, Julia's Any
    local t = translator_of(CodegenCases.f_add, (Int32,))
    @test !t.options.standalone
    @test D.guard_can_match_js_exception(t, Any)
    @test !D.guard_can_match_js_exception(t, Exception) && !D.guard_can_match_js_exception(t, TypeVar(:T))
    # standalone mode has no JS exceptions: no guard catches one
    local ts = D.Translator(WasmTarget.build_nir(W.check_subset(CodegenCases.f_add, (Int32,), "code_generator", Base.get_world_counter()), "test"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions(; standalone = true))
    @test !D.guard_can_match_js_exception(ts, Any)
end

# Base's fallback == is Julia's egal: identity for two mutable objects, content for immutable values (audit #56)
module FallbackEqualsCases
struct Q; x::Int; end
mutable struct M; x::Int; end
@noinline same_q(a::Int) = Q(a) == Q(a)
@noinline same_m(a::Int) = M(a) == M(a)
@noinline self_m(a::Int) = (m = M(a); m == m)
end
@testset "Base's fallback == over immutable and mutable operands, never a wrong answer" begin
    for f in (FallbackEqualsCases.same_q, FallbackEqualsCases.same_m, FallbackEqualsCases.self_m)
        local bytes = try
            W.compile(f, (Int,); optimize = false)
        catch e
            e isa W.RejectionError || rethrow()
            # a rejection is admitted, located; a compiled module must answer as native does
            @test !isempty(e.at)
            nothing
        end
        bytes === nothing || queue_native!("$(nameof(f)) ", bytes, f, [(3,), (-1,)])
    end
end

# a constructor's callee is a type object, Type{C}: Julia passes it as a constant (isconstType), so it is no
# parameter and no `this` (src/julia/nir.jl nir_carries_data), as a function's singleton callee is none
module CtorThisCases
struct Plain; x::Int; end
struct Para{T}; x::Int; end
end
@testset "a constructor's Type{C} callee carries no data" begin
    @test !WasmTarget.nir_carries_data(Type{CtorThisCases.Plain})
    @test !WasmTarget.nir_carries_data(Type{CtorThisCases.Para{String}})
    @test !WasmTarget.nir_carries_data(typeof(sin))
    @test WasmTarget.nir_carries_data(CtorThisCases.Plain)
    @test WasmTarget.nir_carries_data(Type)   # an unknown type object is a value at run time
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTChild.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end

end
