# dart2wasm's intrinsics.dart, the remainder ported (src/intrinsics.jl, dev/MARCH.md 1.D): the literal
# extractors, the lane index, the lookups and the call-site intrinsics, Julia's operations the answer.
using Test
using WasmTarget

const DI = WasmTarget.Dart2Wasm
const WI = WasmTarget
const IRI = WI.WasmBuilder.IR

module IntrinsicCases
eq64(x::Int64) = x + 1
eqf(x::Float64) = x * 2.0
end

intr_translator_of(f, argtypes) = DI.Translator(WasmTarget.build_nir(WI.check_subset(f, argtypes, "intrinsics", Base.get_world_counter()), "test"),
    DI.build_module_output_data(DI.DefaultModuleStrategy(DI.WasmCompilerOptions_default_options())), DI.TranslatorOptions())
function intr_codegen_of(f, argtypes, ins, outs)
    local t = intr_translator_of(f, argtypes)
    local mi = only(nb.ci.def for nb in t.component if nb.ci.def.def.name === nameof(f))
    return DI.get_inlinable_member_code_generator(t, IRI.FunctionType(IRI.ValueType[ins...], IRI.ValueType[outs...]), mi)
end
intr_rejection(f) = try; f(); nothing; catch e; e isa WI.RejectionError ? e : rethrow(); end

# the code generator of `f` ready to emit, as `generate` leaves it before the body: translate()'s
# steps before code, its builder a function of `f`'s parameter types and the results `outs`, its
# parameters set up
function intr_ready_codegen_of(f, argtypes, outs)
    local B = WI.WasmBuilder
    local t = intr_translator_of(f, argtypes)
    DI._init_modules(t, nothing)
    collect(DI.ClassInfoCollector(t))
    t.constants[] = DI.Constants(t)
    local mi = only(nb.ci.def for nb in t.component if nb.ci.def.def.name === nameof(f))
    local mb = DI.main_module(t)
    local fb = B.define(mb.functions[], B.define_function(mb.types[], IRI.ValueType[DI.translate_type(t, T) for T in argtypes], IRI.ValueType[outs...]), "f")
    local g = DI.get_inlinable_member_code_generator(t, fb.type, mi)
    g.b[] = B.body(fb)
    g.param_locals[] = B.locals(fb)
    g.return_label[] = nothing
    DI.setup_parameters_for_normal_entry(g, g.member)
    return g
end

# the instructions `thunk` emits into the builder of `g`, by name
function intr_emitted_by(thunk, g)
    local n0 = length(g.b[]._instructions)
    thunk()
    return String[WI.WasmBuilder.name(i) for i in g.b[]._instructions[n0+1:end]]
end

@testset "intrinsics.dart: literals, lanes and lookups" begin
    local lit(v) = WI.NirConst(Core.Const(v))
    # an integer literal is dart's int, Julia's Int64; a float literal Float64; anything else none
    @test DI.extract_int_value(lit(3)) == 3 && DI.extract_int_value(lit(Int32(3))) === nothing && DI.extract_int_value(WI.NirSSA(1)) === nothing
    @test DI._extract_double_value(lit(2.5)) == 2.5 && DI._extract_double_value(lit(2.5f0)) === nothing
    @test DI._extract_lane_indices(lit((1, 2, 3))) == [1, 2, 3] && DI._extract_lane_indices(lit((1, 2.0))) === nothing
    @test DI._extract_lane_indices(lit(1)) === nothing
    # the Julia methods that are dart library members are the runtime's ports: Runtime.Error__throw is
    # dart:core's Error._throw, the errorThrow intrinsic, filed under it; Runtime.ClassID_get_id is
    # dart:_internal's ClassID.getID, the getID static intrinsic (class_id.dart:10), and Runtime's
    # _is_record_class_id dart:core's top-level _isRecordClassId (type.dart:2060, filed at
    # intrinsics.dart:287 `isRecordClassId('dart:core', null, '_isRecordClassId')`); no method is a
    # dart:_wasm member
    # getIdentityHashField and setIdentityHashField, filed at intrinsics.dart:288-289 under
    # dart:_object_helper's top level
    @test DI.MemberIntrinsic__lookup[] == Dict("dart:core" => Dict("Error" => Dict("_throw" => DI.MemberIntrinsic_errorThrow))) &&
          DI.StaticIntrinsic__lookup[] == Dict("dart:_internal" => Dict("ClassID" => Dict("getID" => DI.StaticIntrinsic_getID),
                                                                         nothing => Dict("unsafeCast" => DI.StaticIntrinsic_unsafeCast)),
                                               "dart:core" => Dict(nothing => Dict("_isRecordClassId" => DI.StaticIntrinsic_isRecordClassId)),
                                               "dart:_object_helper" => Dict(nothing => Dict("getIdentityHashField" => DI.StaticIntrinsic_getIdentityHashField,
                                                                                             "setIdentityHashField" => DI.StaticIntrinsic_setIdentityHashField)))
    local get_hash_mi = Core.Compiler.specialize_method(only(methods(WI.Runtime.get_identity_hash_field)), Tuple{typeof(WI.Runtime.get_identity_hash_field),Any}, Core.svec())
    @test DI.StaticIntrinsic_from_procedure(get_hash_mi) === DI.StaticIntrinsic_getIdentityHashField
    local set_hash_mi = Core.Compiler.specialize_method(only(methods(WI.Runtime.set_identity_hash_field)), Tuple{typeof(WI.Runtime.set_identity_hash_field),Any,Int64}, Core.svec())
    @test DI.StaticIntrinsic_from_procedure(set_hash_mi) === DI.StaticIntrinsic_setIdentityHashField
    local get_id_mi = Core.Compiler.specialize_method(only(methods(WI.Runtime.ClassID_get_id)), Tuple{typeof(WI.Runtime.ClassID_get_id),Any}, Core.svec())
    @test DI.StaticIntrinsic_from_procedure(get_id_mi) === DI.StaticIntrinsic_getID
    local record_mi = Core.Compiler.specialize_method(only(methods(WI.Runtime._is_record_class_id)), Tuple{typeof(WI.Runtime._is_record_class_id),Int32}, Core.svec())
    @test DI.StaticIntrinsic_from_procedure(record_mi) === DI.StaticIntrinsic_isRecordClassId
    # unsafeCast, filed at intrinsics.dart:290 `unsafeCast('dart:_internal', null, 'unsafeCast')`
    local cast_mi = Core.Compiler.specialize_method(only(methods(WI.Runtime.unsafe_cast)), Tuple{typeof(WI.Runtime.unsafe_cast),Type{DataType},Any}, Core.svec(DataType))
    @test DI.StaticIntrinsic_from_procedure(cast_mi) === DI.StaticIntrinsic_unsafeCast
    local throw_mi = Core.Compiler.specialize_method(only(methods(WI.Runtime.Error__throw)), Tuple{typeof(WI.Runtime.Error__throw),Exception}, Core.svec())
    @test DI.MemberIntrinsic_from_procedure(throw_mi) === DI.MemberIntrinsic_errorThrow
    local other_mi = Core.Compiler.specialize_method(only(methods(WI.Runtime.Error__throw_with_current_stack_trace)),
                                                     Tuple{typeof(WI.Runtime.Error__throw_with_current_stack_trace),Exception}, Core.svec())
    @test DI.MemberIntrinsic_from_procedure(other_mi) === nothing
    local e = intr_rejection(() -> DI.MemberIntrinsic("dart:core", "Object", "=="))
    @test e.rejection isa WI.Internal
    local g = intr_codegen_of(IntrinsicCases.eq64, (Int64,), [IRI.NumType_i64], [IRI.NumType_i64])
    local ii = g.intrinsifier[]
    # a lane index: a literal within the lanes; another, a located rejection
    local st = WI.NirNothing()
    @test DI._get_simd_lane_index(ii, lit(1), 4, st) == 1
    for bad in (lit(4), lit(-1), WI.NirSSA(1))
        @test intr_rejection(() -> DI._get_simd_lane_index(ii, bad, 4, st)).rejection isa WI.Internal
    end
    # the folded unary operators are Julia's intrinsics, rounding a float to its own type
    @test haskey(DI.Intrinsifier__inline_unary_operator_map[][IRI.NumType_i64], Core.Intrinsics.neg_int)
    @test Set(keys(DI.Intrinsifier__inline_unary_operator_map[][IRI.NumType_f64])) ==
          Set([Core.Intrinsics.neg_float, Core.Intrinsics.floor_llvm, Core.Intrinsics.ceil_llvm, Core.Intrinsics.trunc_llvm])
    @test DI.Intrinsifier__unary_result_map[][Core.Intrinsics.floor_llvm] == IRI.NumType_f64
    @test DI.types(ii) === DI.translator(ii).types[]
end

@testset "intrinsics.dart: the call-site intrinsics over Julia's calls" begin
    local lit(v) = WI.NirConst(Core.Const(v))
    local g = intr_codegen_of(IntrinsicCases.eq64, (Int64,), [IRI.NumType_i64], [IRI.NumType_i64])
    local ii = g.intrinsifier[]
    local x = WI.NirArgument(2)
    local mi(f, T) = Core.Compiler.specialize_method(Base._which(Base.signature_type(f, T)))
    local inv(m, args...) = WI.NirInvoke(m, WI.NirValue[lit(m.def.name === :(==) ? (==) : (+)), args...])
    # Base's == on two Int64s is their bit equality, which i64.eq computes: the operands, then i64.eq;
    # Julia's own answer stands beside it
    @test (typemin(Int64) == typemin(Int64)) && !(1 == 2) && !(NaN == NaN) && (0.0 == -0.0)
    local r = intr_ready_codegen_of(IntrinsicCases.eq64, (Int64,), [IRI.NumType_i64])
    @test intr_emitted_by(() -> DI.generate_equals_intrinsic(r.intrinsifier[], inv(mi(==, (Int64, Int64)), x, lit(3))), r) ==
          ["local.get", "i64.const 3", "i64.eq"]
    # two types, or another method, is no equality intrinsic
    @test DI.generate_equals_intrinsic(ii, inv(mi(==, (Int64, Float64)), x, lit(3.0))) === nothing
    @test DI.generate_equals_intrinsic(ii, inv(mi(+, (Int64, Int64)), x, lit(3))) === nothing
    # a resolved call, a field read, a global read and a function value's call are no intrinsics
    @test DI.generate_instance_intrinsic(ii, inv(mi(+, (Int64, Int64)), x, lit(3))) === nothing
    @test DI.generate_instance_getter_intrinsic(ii, WI.NirCall(WI.NirValue[lit(getfield), x, lit(:a)])) === nothing
    @test DI.generate_static_getter_intrinsic(ii, WI.NirGlobalRead(WI.nir_binding!(WI.NirBindings(DI.translator(ii).component.world), GlobalRef(Base, :pi)))) === nothing
    @test DI.generate_function_call_intrinsic(ii, inv(mi(+, (Int64, Int64)), x, lit(3))) === nothing
end

module SvecLenCases
nparams(T::DataType, n::Int) = Core._svec_len(T.parameters) + n
end

@testset "intrinsics.dart: a SimpleVector's length, its wasm array's" begin
    local lit(v) = WI.NirConst(Core.Const(v))
    local t = intr_translator_of(SvecLenCases.nparams, (DataType, Int))
    DI._init_modules(t, nothing)
    collect(DI.ClassInfoCollector(t))
    local mi = only(nb.ci.def for nb in t.component if nb.ci.def.def.name === :nparams)
    local g = DI.get_inlinable_member_code_generator(t, IRI.FunctionType(IRI.ValueType[DI.translate_type(t, DataType), IRI.NumType_i64], IRI.ValueType[IRI.NumType_i64]), mi)
    local ii = g.intrinsifier[]
    # Julia's answer the arm computes: the parameters' count
    @test Core._svec_len(Tuple{Int,Float64,Bool}.parameters) == 3
    # the NIR's statement: the arm takes it, its operand the field read before it (translated first,
    # its local set), then the vector's array and its length, widened to Int
    local body = only(nb for nb in t.component if nb.ci.def === mi)
    local k = findfirst(st -> st isa WI.NirCall && WI.nir_callee(st) === Core._svec_len, body.stmts)
    @test k !== nothing
    local r = intr_ready_codegen_of(SvecLenCases.nparams, (DataType, Int), [IRI.NumType_i64])
    for j in 1:k-1
        DI.translate_statement(r, r.body.stmts[j], j in r.used ? WI.NirSSA(j) : nothing)
    end
    @test intr_emitted_by(() -> DI.generate_static_intrinsic(r.intrinsifier[], r.body.stmts[k]), r) ==
          ["local.get", "struct.get", "array.len", "i64.extend_i32_u"]
end

isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module DivCases
# each checked division at each width, by `k`: one module per signedness
sops(a::Int64, b::Int64, k::Int64) = k == 0 ? div(a, b) : k == 1 ? rem(a, b) :
                                     k == 2 ? Int64(div(a % Int32, b % Int32)) : Int64(div(a % Int8, b % Int8))
uops(a::UInt64, b::UInt64, k::Int64) = k == 0 ? div(a, b) : k == 1 ? rem(a, b) :
                                       k == 2 ? UInt64(div(a % UInt32, b % UInt32)) : UInt64(rem(a % UInt16, b % UInt16))
end

@testset "intrinsics.cpp: a checked division raises DivideError through the runtime's thrower, as Julia's does" begin
    # Julia's checked_sdiv_int and kin raise DivideError at a zero divisor, and checked_sdiv_int at
    # typemin ÷ -1 too, its type's own typemin for a 32- or 8-bit operand: the module raises a wasm
    # exception where native Julia throws (Error._throw's tag), never a trap, and answers as native
    # elsewhere
    local C = DivCases
    local s(a, b, k) = (Int64(a), Int64(b), Int64(k))
    local u(a, b, k) = (UInt64(a), UInt64(b), Int64(k))
    local cases = WTChild.RunCase[]
    for (f, argsets) in ((C.sops, [s(7, 2, 0), s(7, 0, 0), (typemin(Int64), Int64(-1), Int64(0)), s(-7, 2, 0),
                                   s(7, 2, 1), s(7, 0, 1), (typemin(Int64), Int64(-1), Int64(1)),
                                   s(typemin(Int32), -1, 2), s(9, -2, 2), s(9, 0, 2),
                                   s(-128, -1, 3), s(5, 0, 3), s(-7, 2, 3), s(200, 3, 3)]),
                         (C.uops, [u(7, 2, 0), u(7, 0, 0), u(typemax(UInt64), 3, 0), u(7, 2, 1), u(7, 0, 1),
                                   u(typemax(UInt32), 3, 2), u(7, 0, 2), u(65535, 7, 3), u(70000, 0, 3), u(9, 65540, 3)]))
        local bytes = WI.compile(f, map(typeof, first(argsets)))
        append!(cases, [WTChild.RunCase("$(nameof(f))$(a)", bytes, a, WTChild.native_answer(f, a)) for a in argsets])
    end
    @test count(c -> c.native isa WTChild.Throws, cases) == 11
    for r in WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

module StringDataCases
using WasmTarget: wasm_string_length, wasm_string_alloc, wasm_string_codeunit, wasm_string_copy!, wasm_string_write!
# a String's length and a fresh String's (src/julia/wasm_array.jl), === on two Strings, a code unit,
# a code unit written into a fresh String, and a code unit of two Strings copied into a fresh one, by `k`
function strops(k::Int64, b::Bool)
    k == 0 && return wasm_string_length(b ? "héllo" : "日本")
    k == 1 && return Int64((b ? "abc" : "abd") === "abc")
    k == 2 && return Int64((b ? "abc" : "abcd") === "abc")
    k == 3 && return wasm_string_length(wasm_string_alloc(b ? 7 : 0))
    k == 4 && return Int64(wasm_string_codeunit("héllo", b ? 2 : 0))
    if k == 5
        local w = wasm_string_alloc(2)
        wasm_string_write!(w, 0, 0xc3)
        wasm_string_write!(w, 1, b ? 0xa9 : 0x80)
        return Int64(wasm_string_codeunit(w, 1)) + Int64(w === "é")
    end
    local x = b ? "hé" : "x"
    local y = "llo"
    local s = wasm_string_alloc(wasm_string_length(x) + wasm_string_length(y))
    wasm_string_copy!(s, 0, x, 0, wasm_string_length(x))
    wasm_string_copy!(s, wasm_string_length(x), y, 0, wasm_string_length(y))
    return Int64(wasm_string_codeunit(s, 3))
end
end

@testset "intrinsics.dart: a String's data operations and Julia's egal on two Strings, against native" begin
    # wasm_string_length is `struct.get _data; array.len`, wasm_string_alloc a String struct over a
    # fresh array (WasmArrayRef.length, the WasmArray constructor); === compares lengths, then bytes,
    # as jl_egal does: non-ASCII text's bytes, equal and unequal contents of equal and unequal lengths
    local args = [(Int64(k), b) for k in 0:6 for b in (true, false)]
    local bytes = WI.compile(StringDataCases.strops, (Int64, Bool))
    for r in WTChild.run_cases([WTChild.RunCase("strops$a", bytes, a, StringDataCases.strops(a...)) for a in args])
        @test r.ok || (@info r.label r.why; false)
    end    # each data operation is dart's external member: the closed world records its call and never
    # collects its body (Julia's native evaluation through pointers); a call the intrinsifier declines
    # (here, the body asked for directly) finds none and rejects, located
    local t = intr_translator_of(StringDataCases.strops, (Int64, Bool))
    local cu = Core.Compiler.specialize_method(only(methods(WI.wasm_string_codeunit)), Tuple{typeof(WI.wasm_string_codeunit),String,Int}, Core.svec())
    @test WI.nir_intrinsified(cu) && !any(nb -> nb.ci.def === cu, t.component)
    local r = intr_rejection(() -> WI.nir_body_of(t.component, cu))
    @test r.rejection isa WI.Internal && occursin("a call it did not lower", r.rejection.site)
end

module IdentityFieldCases
using WasmTarget: Runtime
mutable struct Cell; x::Int64; end
# the identity hash field of a fresh object (k = 0), and the field after `h` is stored (k = 1): a
# mutable struct's, a Memory's (k = 2, 3) and a String's (k = 4, 5), every object under Any carrying it
function idfield(k::Int64, h::Int64)
    local o = k < 2 ? Cell(h) : k < 4 ? Memory{Int64}(undef, 2) : string("ab", h)
    iseven(k) && return Runtime.get_identity_hash_field(o)
    Runtime.set_identity_hash_field(o, h)
    return Runtime.get_identity_hash_field(o)
end
end

@testset "intrinsics.dart: the identity hash field read and written in the object's header" begin
    # getIdentityHashField is `struct.get identityHash; i64.extend_i32_u` on the Object struct,
    # setIdentityHashField `i32.wrap_i64; struct.set identityHash` (intrinsics.dart:1498-1514): a fresh
    # object's field is dart's initialIdentityHash, 0 (class_info.dart:193); a stored value reads back
    # as its low 32 bits, unsigned. Natively no object carries the field, so the answer is dart's
    # definition, written here: 0 fresh, else `h & 0xffffffff`
    local want(k, h) = iseven(k) ? Int64(0) : Int64(h & 0xffffffff)
    local args = [(Int64(k), h) for k in 0:5 for h in (Int64(5), Int64(-1), Int64(2)^32 + 7, Int64(0x7fffffff))]
    local bytes = WI.compile(IdentityFieldCases.idfield, (Int64, Int64))
    for r in WTChild.run_cases([WTChild.RunCase("idfield$a", bytes, a, want(a...)) for a in args])
        @test r.ok || (@info r.label r.why; false)
    end
    # natively the body raises: the field exists only in a module
    @test_throws ErrorException WI.Runtime.get_identity_hash_field(IdentityFieldCases.Cell(1))
    @test_throws ErrorException WI.Runtime.set_identity_hash_field(IdentityFieldCases.Cell(1), 3)
end

module SvecRefCases
const ELEMENTS = Core.svec(Int64(7), "x", Int64(9))
# a SimpleVector's element by its index from 1, read by its class
sref(i::Int64) = (x = ELEMENTS[i]; x isa Int64 ? Int64(1) : x isa String ? Int64(2) : Int64(3))
end

@testset "intrinsics.dart: a SimpleVector's element, Julia's bounds check raising BoundsError" begin
    # _svec_ref reads the data array at i - 1 behind Julia's check: an index outside 1..length
    # raises BoundsError through the runtime's thrower, a wasm exception, never a trap
    local args = [(Int64(k),) for k in (-1, 0, 1, 2, 3, 4)]
    local bytes = WI.compile(SvecRefCases.sref, (Int64,))
    local cases = [WTChild.RunCase("sref$a", bytes, a, WTChild.native_answer(SvecRefCases.sref, a)) for a in args]
    @test count(c -> c.native isa WTChild.Throws, cases) == 3
    for r in WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

module SvecNewCases
# a SimpleVector made at run time of an Int, a String and an Int, its element by index; its length
made(i::Int64, k::Int64) = (v = Core.svec(i, "x", i + 1); x = v[k]; x isa Int64 ? Int64(1) : x isa String ? Int64(2) : Int64(3))
made_len(b::Bool) = Core._svec_len(b ? Core.svec("a", "b", "c") : Core.svec("z"))
end

@testset "intrinsics.dart: a SimpleVector made at run time, WasmArray.literal's array.new_fixed in its struct" begin
    # Core.svec builds its data array from its operands, each boxed to the element type, as dart's
    # WasmArray.literal does, under the SimpleVector's header; read back by index and by length, and
    # past its length raising BoundsError
    local native(f, a) = try; f(a...); catch e; WTChild.Throws(typeof(e)); end
    local cases = WTChild.RunCase[]
    for (f, argsets) in ((SvecNewCases.made, [(Int64(5), Int64(k)) for k in 0:4]), (SvecNewCases.made_len, [(true,), (false,)]))
        local bytes = WI.compile(f, map(typeof, first(argsets)))
        append!(cases, [WTChild.RunCase("$(nameof(f))$(a)", bytes, a, native(f, a)) for a in argsets])
    end
    @test count(c -> c.native isa WTChild.Throws, cases) == 2
    for r in WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

module ExprNewCases
# an Expr made at run time: its head, its arguments' count, an argument read back by index and its
# class, an argument written into its vector, and an Expr of no argument (the empty memory)
made(x::Int64, k::Int64) = (e = Expr(:call, :+, x, "s"); a = e.args[k]; a isa Int64 ? a : a isa Symbol ? Int64(-1) : a isa String ? Int64(-2) : Int64(-3))
heads(b::Bool) = (e = b ? Expr(:block) : Expr(:call, :f, 1); Int64(length(e.args)) + (e.head === :block ? Int64(10) : Int64(20)))
pushed(x::Int64) = (e = Expr(:tuple, x); push!(e.args, x + 1); e.args[1]::Int64 + e.args[end]::Int64 + length(e.args))
end

@testset "builtins.c: Julia's _expr, a fresh Vector{Any} of its operands under the Expr of its head" begin
    # jl_f__expr allocates the Vector{Any} of its operands (jl_alloc_vec_any, the empty memory for none)
    # and the Expr of the head and that vector; read back by index past its length raising BoundsError
    local native(f, a) = try; f(a...); catch e; WTChild.Throws(typeof(e)); end
    local cases = WTChild.RunCase[]
    for (f, argsets) in ((ExprNewCases.made, [(Int64(5), Int64(k)) for k in 0:4]), (ExprNewCases.heads, [(true,), (false,)]),
                         (ExprNewCases.pushed, [(Int64(3),)]))
        local bytes = WI.compile(f, map(typeof, first(argsets)))
        append!(cases, [WTChild.RunCase("$(nameof(f))$(a)", bytes, a, native(f, a)) for a in argsets])
    end
    @test count(c -> c.native isa WTChild.Throws, cases) == 2
    for r in WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

module IdenticalCases
mutable struct Cell
    x::Int64
end
# (boxed: an isbits Memory a constant reaches bare is refused, located, spec v17 Y6)
const PRIMES = let m = Memory{Any}(undef, 2); m .= (2, 3); m end
const OTHER = let m = Memory{Any}(undef, 2); m .= (2, 3); m end
# a mutable object is === only itself, whatever its contents
cells(b::Bool) = (c = Cell(1); d = b ? c : Cell(1); Int64(c === d))
# a memory constant against another of the same contents, and an Any against a mutable object
mems(b::Bool) = Int64((b ? PRIMES : OTHER) === PRIMES)
anys(b::Bool) = (c = Cell(1); x = b ? (c::Any) : (Int64(1)::Any); Int64(x === c))
# a pair of types (Tuple{DataType,DataType}) and a type, picked at run time
pair(k::Int64) = k == 1 ? (Int64, String) : k == 2 ? (Int64, Float64) : k == 3 ? (Vector{Int64}, String) : (AbstractVector{Int64}, String)
kind(k::Int64) = k == 1 ? Int64 : k == 2 ? String : AbstractVector{Int64}
# every case in one program, case c on (a, b), so the family costs one program's two compiles
identical(c::Int64, a::Int64, b::Int64) =
    c == 1 ? cells(a == 1) : c == 2 ? mems(a == 1) : c == 3 ? anys(a == 1) :
    c == 4 ? Int64(pair(a) === pair(b)) : Int64(kind(a) === kind(b))
end

@testset "intrinsics.dart: identical's ref.eq where Julia's egal compares by identity, on DataTypes and on tuples of them" begin
    # jl_egal_ answers a mutable class's === by the pointers alone: the same object, else false. A DataType
    # is egal by its pointer (concrete) or its name and parameters (abstract); WasmTarget holds each type
    # as one constant canonical by ===, so ref.eq, field by field for a tuple of them
    local f = IdenticalCases.identical
    @test only(Base.return_types(IdenticalCases.pair, (Int64,))) === Tuple{DataType,DataType}
    local argsets = [(1, 1, 0), (1, 0, 0), (2, 1, 0), (2, 0, 0), (3, 1, 0), (3, 0, 0),
                     (4, 1, 1), (4, 1, 2), (4, 2, 2), (4, 3, 4), (4, 4, 4), (5, 1, 1), (5, 1, 2), (5, 3, 3)]
    local own = WI.compile(f, (Int64, Int64, Int64))
    local plain = WI.compile(f, (Int64, Int64, Int64); optimize = false)
    local cases = [WTChild.RunCase("identical$a", plain, Int64.(a), WTChild.native_answer(f, Int64.(a)); optimized = own) for a in argsets]
    @test count(c -> c.native == 1, cases) == 8
    for r in WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

module MemoryCases
# a Vector{Int} of n elements, x written at i and read back: memorynew, memoryrefnew, memoryrefset!
# and memoryrefget under Julia's own bounds check (Base.throw_boundserror)
vec(n::Int64, i::Int64, x::Int64) = (v = Vector{Int64}(undef, n); v[i] = x; v[i])
# a Vector{String}'s unassigned element read: UndefRefError
unset(n::Int64, i::Int64) = (v = Vector{String}(undef, n); ncodeunits(v[i]))
# isassigned of each kind, and a negative size: ArgumentError
assigned(n::Int64, i::Int64) = (v = Vector{String}(undef, n); i > 1 && (v[1] = "a"); Int64(isassigned(v, 1)) + Int64(isassigned(Vector{Int64}(undef, n), 1)))
# the builtins directly on a Memory of n elements: set then get (an empty memory's BoundsError(m, 1)
# under the bounds check), and isassigned of an empty or unassigned String element
direct(n::Int64) = (r = Core.memoryrefnew(Memory{Int64}(undef, n)); Core.memoryrefset!(r, Int64(5), :not_atomic, true); Core.memoryrefget(r, :not_atomic, true))
direct_assigned(n::Int64) = Int64(Core.memoryref_isassigned(Core.memoryrefnew(Memory{String}(undef, n)), :not_atomic, true))
# a Memory past what can be allocated: OutOfMemoryError. The memory escapes to a global: one read only
# for its length is an allocation Julia's optimizer may drop (AllocOpt), answering n natively
const SINK = Ref{Any}(nothing)
huge(n::Int64) = (m = Memory{UInt8}(undef, n); SINK[] = m; Int64(length(m)))
# an element admitting nothing: #undef by its set flag, apart from a written nothing
maybe(i::Int64) = (v = Vector{Union{Nothing,String}}(undef, 2); i > 1 && (v[1] = nothing); (v[1] === nothing ? Int64(10) : Int64(20)) + Int64(isassigned(v, 2)))
# a signed 8-bit element read back sign-extended (readIntArray's array.get_s), an unsigned one not
signed8(i::Int64) = (v = Vector{Int8}(undef, 2); v[1] = Int8(-1); Int64(v[i]))
unsigned8(i::Int64) = (v = Vector{UInt8}(undef, 2); v[1] = 0xff; Int64(v[i]))
# a constant Memory read by index (its class struct, the constant's data array), and the one empty
# instance memorynew answers for 0, identical each time
# (boxed: an isbits Memory a constant reaches bare is refused, located, spec v17 Y6)
const PRIMES = let m = Memory{Any}(undef, 4); m .= (2, 3, 5, 7); m end
prime(i::Int64) = PRIMES[i]::Int64
empties(n::Int64) = Int64(Memory{Int64}(undef, n) === Memory{Int64}(undef, n))
# an inline element holding a reference, #undef until written (UndefRefError), an inline bits union
# never #undef (its unwritten element nothing), and isassigned of an empty memory of bits false
inline_ref(i::Int64) = (v = Vector{Some{String}}(undef, 2); v[1] = Some("ab"); Int64(isassigned(v, i)) + Int64(ncodeunits(something(v[i]))))
bits_union(i::Int64) = (v = Vector{Union{Nothing,Int64}}(undef, 2); v[1] = Int64(5); Int64(v[i] === nothing))
bits_assigned(n::Int64) = Int64(Core.memoryref_isassigned(Core.memoryrefnew(Memory{Int64}(undef, n)), :not_atomic, true))
# memoryrefnew(r, i) without its flag, which checks
ref2(i::Int64) = (r = Core.memoryrefnew(Core.memoryrefnew(Memory{Int64}(undef, 2)), i); Core.memoryrefset!(r, Int64(9), :not_atomic, true); Core.memoryrefget(r, :not_atomic, true))
# every case above in one program, case k on (a, b), so the cases cost one compile
const CASES = (vec, unset, assigned, direct, direct_assigned, huge, maybe, signed8, unsigned8, prime, empties, inline_ref, bits_union, bits_assigned, ref2)
memory(k::Int64, a::Int64, b::Int64) =
    k == 1 ? vec(a, b, Int64(7)) : k == 2 ? unset(a, b) : k == 3 ? assigned(a, b) : k == 4 ? direct(a) :
    k == 5 ? direct_assigned(a) : k == 6 ? huge(a) : k == 7 ? maybe(a) : k == 8 ? signed8(a) :
    k == 9 ? unsigned8(a) : k == 10 ? prime(a) : k == 11 ? empties(a) : k == 12 ? inline_ref(a) :
    k == 13 ? bits_union(a) : k == 14 ? bits_assigned(a) : ref2(a)
end

@testset "builtins.c: Memory's builtins over its data array, Julia's errors raised" begin
    # memorynew's negative size raises ArgumentError, an out-of-range index BoundsError (Julia's
    # array code), an empty memory's get or set BoundsError(m, 1) under the bounds check, an
    # unassigned reference element UndefRefError, a size past what can be allocated OutOfMemoryError:
    # each a wasm exception where native Julia throws, never a trap; every other call answers as native
    local M = MemoryCases
    # (case, a, b): vec's n and i, unset's and assigned's n and i, every other case's one argument
    local argsets = [(1, 3, 1), (1, 3, 3), (1, 3, 4), (1, 3, 0), (1, -1, 1), (2, 2, 1), (2, 2, 3), (3, 2, 1), (3, 2, 2),
                     (4, 0, 0), (4, 1, 0), (5, 0, 0), (5, 1, 0), (6, 3, 0), (6, 2^50, 0), (7, 1, 0), (7, 2, 0), (8, 1, 0),
                     (8, 3, 0), (9, 1, 0), (9, 0, 0), (10, 1, 0), (10, 4, 0), (10, 5, 0), (11, 0, 0), (11, 2, 0),
                     (12, 1, 0), (12, 2, 0), (13, 1, 0), (13, 2, 0), (14, 0, 0), (14, 1, 0), (15, 2, 0), (15, 3, 0)]
    local own = WI.compile(M.memory, (Int64, Int64, Int64))
    local plain = WI.compile(M.memory, (Int64, Int64, Int64); optimize = false)
    local cases = [WTChild.RunCase("$(nameof(M.CASES[k]))$((k, a, b))", plain, Int64.((k, a, b)), WTChild.native_answer(M.memory, Int64.((k, a, b))); optimized = own)
                   for (k, a, b) in argsets]
    @test count(c -> c.native isa WTChild.Throws, cases) == 13
    for r in WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

module AllocationCases
using WasmTarget: wasm_string_length, wasm_string_alloc, wasm_string_memory, wasm_memory_string
# each a struct one arm of the intrinsics alone builds: a fresh String (wasm_string_alloc), a byte
# Memory over a String's data (jl_string_to_genericmemory), a String over a byte Memory
# (jl_genericmemory_to_string), a SimpleVector made at run time, and an Int128 of two Int64s
salloc(n::Int64) = wasm_string_length(wasm_string_alloc(n))
smemory(s::String) = length(wasm_string_memory(s))
mstring(m::Memory{UInt8}, n::Int64) = wasm_string_length(wasm_memory_string(m, n))
svec(i::Int64) = Core._svec_len(Core.svec(i, i + 1))
wide(n::Int64) = Int64((Int128(n) + Int128(n)) % Int64)
end

@testset "functions.dart: every struct the intrinsics build records its class allocated (recordClassAllocation)" begin
    # the one new_struct of src/intrinsics.jl records the class of each struct an arm builds, as every
    # allocation site does (FunctionCollector.recordClassAllocation, functions.dart:446): a class no
    # constant and no other arm makes is allocated in the closed world only through its arm
    for (f, argtypes, cls) in ((AllocationCases.salloc, (Int64,), String), (AllocationCases.smemory, (String,), Memory{UInt8}),
                               (AllocationCases.mstring, (Memory{UInt8}, Int64), String), (AllocationCases.svec, (Int64,), Core.SimpleVector),
                               (AllocationCases.wide, (Int64,), Int128))
        # standalone, as WasmTarget's compile translates (src/julia/entry.jl compile_world)
        @testset "$(nameof(f)): $cls" begin
            local t = DI.Translator(WasmTarget.build_nir(WI.check_subset(f, argtypes, "intrinsics", Base.get_world_counter()), "test"),
                DI.build_module_output_data(DI.DefaultModuleStrategy(DI.WasmCompilerOptions_default_options())), DI.TranslatorOptions(; standalone = true))
            DI.translate(t, nothing)
            @test DI.class_id(t.class_info[cls]) in t.functions[]._allocated_classes
        end
    end
end

module FieldTypeCases
struct P; a::Int64; b::String; c::Float64; end
mutable struct E end
# a field name only run time knows (Base.inferencebarrier), so Julia leaves fieldtype the runtime's
# jl_f_fieldtype: each name P has, a NamedTuple's names, a name neither has, and a type with no field at
# all, by `k` and `j`
_name(k::Int64) = Base.inferencebarrier(k == 1 ? :a : k == 2 ? :b : k == 3 ? :c : k == 4 ? :x : :y)::Symbol
_code(@nospecialize(T)) = T === Int64 ? 1 : T === String ? 2 : T === Float64 ? 3 : T === Bool ? 4 : 5
field_type(k::Int64, j::Int64) = j == 1 ? _code(fieldtype(P, _name(k))) :
                                 j == 2 ? _code(fieldtype(@NamedTuple{x::Bool, y::Int64}, _name(k))) :
                                 _code(fieldtype(E, _name(k)))
end

@testset "builtins.c: fieldtype of a constant type and a name run time knows, jl_field_index's comparisons, FieldError where none matches" begin
    # get_fieldtype (builtins.c:1179): the field's type at the first name that is the symbol, the
    # NamedTuple's at its names parameter, and jl_has_no_field_error's FieldError where no name is: a
    # wasm exception where native Julia throws, never a trap
    local F = FieldTypeCases
    local argsets = [(Int64(k), Int64(j)) for j in 1:3 for k in 1:5]
    local bytes = WI.compile(F.field_type, (Int64, Int64))
    local cases = [WTChild.RunCase("field_type$(a)", bytes, a, WTChild.native_answer(F.field_type, a)) for a in argsets]
    @test count(c -> c.native isa WTChild.Throws, cases) == 2 + 3 + 5
    for r in WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end
