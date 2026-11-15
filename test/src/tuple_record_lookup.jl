# The review of the lookup (typeof of a tuple record its operand does not pin, src/record_class_generator.jl
# _generateRecordRuntimeTypeHelper): its programs, each consumer answering an Int code of the type typeof answered, run
# natively and in both modules (test/run_child.jl). The rows that reach a gap other than this one (an outside call, a
# toMostSpecificInterfaceType of a UnionAll, a foreign call) are left out; the two that reach the lookup's miss are
# unported at run time, the jl_inst_arg_tuple_type row.

module TupleRecordLookupTest

using Test
using WasmTarget

const W = WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild

# Review programs for f1bc1790 (typeof of a tuple record looked up from its fields). Each consumer returns an Int code
# of the type typeof answered (0 = none of the listed types); native and both modules must agree.
module Q
macro code_of(T, types...)
    local ex = :(0)
    local Ts = collect(types)
    push!(Ts, :(Memory{UInt8}))  # the Memory constant every typeof of an Any needs
    for i in length(Ts):-1:1
        ex = :($(esc(T)) === $(esc(Ts[i])) ? $(i == length(Ts) ? 99 : i) : $ex)
    end
    ex
end
mutable struct AnySlot; x::Any; end
struct S; a::Int64; end
mutable struct M; a::Int64; end
@noinline mkclos(n::Int64) = () -> n
const CLT = typeof(mkclos(1))

# A1 primitives (each a concrete 1-tuple: each is a row)
@noinline prims(n::Int64) = AnySlot(n == 1 ? (n,) : n == 2 ? (UInt64(n),) : n == 3 ? (n > 0,) : n == 4 ? (Int8(n),) :
                                    n == 5 ? (NaN,) : n == 6 ? (Float32(n),) : n == 7 ? (Char(n),) : n == 8 ? (nothing,) :
                                    n == 9 ? (UInt8(n),) : n == 10 ? (Int32(n),) : n)
c_prims(n::Int64) = (T = typeof(prims(n).x); @code_of T Tuple{Int64} Tuple{UInt64} Tuple{Bool} Tuple{Int8} Tuple{Float64} Tuple{Float32} Tuple{Char} Tuple{Nothing} Tuple{UInt8} Tuple{Int32} Int64)
# A1 references
@noinline refs(n::Int64) = AnySlot(n == 1 ? ("s",) : n == 2 ? (:s,) : n == 3 ? (S(n),) : n == 4 ? (M(n),) :
                                   n == 5 ? ([n],) : n == 6 ? ([1.0],) : n == 7 ? (sin,) : n == 8 ? (mkclos(n),) : n)
c_refs(n::Int64) = (T = typeof(refs(n).x); @code_of T Tuple{String} Tuple{Symbol} Tuple{S} Tuple{M} Tuple{Vector{Int64}} Tuple{Vector{Float64}} Tuple{typeof(sin)} Tuple{CLT} Int64)
# A1 type values as elements
@noinline tvals(n::Int64) = AnySlot(n == 1 ? (Int64, n) : n == 2 ? (Union{Int64,Nothing}, n) : n == 3 ? (Vector, n) :
                                    n == 4 ? (Union{}, n) : n == 5 ? (Tuple{Int64}, n) : n)
c_tvals(n::Int64) = (T = typeof(tvals(n).x); @code_of T Tuple{DataType,Int64} Tuple{Union,Int64} Tuple{UnionAll,Int64} Tuple{Core.TypeofBottom,Int64} Int64)
# A1 a Union value as an element where the world has Tuple{DataType,Int64} but builds no Tuple{Union,Int64} concretely
@noinline uval(n::Int64) = (v = Vector{Any}(undef, 2); v[1] = n > 1 ? Union{Int64,Nothing} : Int64; v[2] = n; v)
@noinline mk_any(v::Vector{Any}) = Core.tuple(v...)
c_uval(n::Int64) = (s = AnySlot(n > 5 ? (Int64, n) : mk_any(uval(n))); T = typeof(s.x); @code_of T Tuple{DataType,Int64} Tuple{Union,Int64})
# A1 nested
@noinline nests(n::Int64) = AnySlot(n == 1 ? ((n,),) : n == 2 ? ((Float64(n),),) : n == 3 ? (((n,),),) : n == 4 ? ((((n,),),),) :
                                    n == 5 ? ((),) : n == 6 ? ((n, n),) : n == 7 ? ((n,), (1.0,)) : n == 8 ? ((1.0,), (n,)) : n)
c_nests(n::Int64) = (T = typeof(nests(n).x); @code_of T Tuple{Tuple{Int64}} Tuple{Tuple{Float64}} Tuple{Tuple{Tuple{Int64}}} Tuple{Tuple{Tuple{Tuple{Int64}}}} Tuple{Tuple{}} Tuple{Tuple{Int64,Int64}} Tuple{Tuple{Int64},Tuple{Float64}} Tuple{Tuple{Float64},Tuple{Int64}} Int64)
# A1 partial: the inner (String,) is never a row; the outer Tuple{Tuple{Int64},Int64} is: must be fatal, never a match
@noinline one_string(n::Int64) = (v = Vector{Any}(undef, 1); v[1] = "s"; v)
@noinline partial(n::Int64) = AnySlot(n > 5 ? ((n,), n) : (mk_any(n > 0 ? one_string(n) : Any[n]), n))
c_partial(n::Int64) = (T = typeof(partial(n).x); @code_of T Tuple{Tuple{Int64},Int64} Int64)
# A1 partial, inner a row (Tuple{Int64}) whose outer type Tuple{Tuple{Int64},String} is no row: fatal
@noinline partial2(n::Int64) = AnySlot(n > 5 ? ((n,), n) : (v = Vector{Any}(undef, 2); v[1] = (n,); v[2] = "s"; mk_any(v)))
c_partial2(n::Int64) = (T = typeof(partial2(n).x); @code_of T Tuple{Tuple{Int64},Int64} Tuple{Tuple{Int64},String})

# A2 a type named only as a type value: Tuple{Int64,String} never built concretely; the value made by a splat
@noinline int_and_string(n::Int64) = (v = Vector{Any}(undef, 2); v[1] = n; v[2] = "s"; v)
@noinline pair(n::Int64) = AnySlot(n > 5 ? (n, n) : mk_any(int_and_string(n)))
c_named_only(n::Int64) = (T = typeof(pair(n).x); @code_of T Tuple{Int64,Int64} Tuple{Int64,String})
c_isa_only(n::Int64) = (x = pair(n).x; x isa Tuple{Int64,String} ? 7 : (T = typeof(x); @code_of T Tuple{Int64,Int64} Tuple{Int64,String}))
# A2 a type present only as a struct's field type
struct H; t::Tuple{Int64,String}; end
@noinline hh(n::Int64) = H((n, "s"))
c_field_only(n::Int64) = (h = hh(n); s = pair(n); T = typeof(s.x); (@code_of T Tuple{Int64,Int64} Tuple{Int64,String}) + 100 * h.t[1])
# A2 a type present only as a function's return type
@noinline ret(n::Int64)::Tuple{Int64,String} = (n, "s")
c_ret_only(n::Int64) = (r = ret(n); s = pair(n); T = typeof(s.x); (@code_of T Tuple{Int64,Int64} Tuple{Int64,String}) + 100 * r[1])

# A3 relations on the answer
@noinline any_pair(k::Int64) = AnySlot(k > 3 ? (k, k) : (k, 1.0))
r_egal(n::Int64) = (a = any_pair(n).x; b = any_pair(n + 3).x; typeof(a) === typeof(b) ? 1 : typeof(a) === Memory{UInt8} ? 3 : 2)
r_eq(n::Int64) = (a = any_pair(n).x; typeof(a) == Tuple{Int64,Float64} ? 1 : typeof(a) == Memory{UInt8} ? 3 : 2)
r_subtuple(n::Int64) = (a = any_pair(n).x; T = typeof(a); T === Memory{UInt8} ? 3 : T <: Tuple{Int64,Float64} ? 1 : 2)
r_isa(n::Int64) = (a = any_pair(n).x; b = any_pair(5).x; T = typeof(b); T === Memory{UInt8} ? 3 : a isa T ? 1 : 2)
r_param(n::Int64) = (a = any_pair(n).x; T = typeof(a); T === Memory{UInt8} ? 3 : T.parameters[2] === Float64 ? 1 : 2)
r_fieldtype(n::Int64) = (a = any_pair(n).x; T = typeof(a); T === Memory{UInt8} ? 3 : fieldtype(T, 2) === Float64 ? 1 : 2)
r_typeoftype(n::Int64) = (a = any_pair(n).x; T = typeof(a); T === Memory{UInt8} ? 3 : typeof(T) === DataType ? 1 : 2)
r_dict(n::Int64) = (d = Dict{DataType,Int}(Tuple{Int64,Int64} => 1, Tuple{Int64,Float64} => 2); a = any_pair(n).x; T = typeof(a); T === Memory{UInt8} ? 3 : get(d, T, 0))
r_string(n::Int64) = (a = any_pair(n).x; T = typeof(a); T === Memory{UInt8} ? 3 : length(string(T)))

# A4 operands
@noinline u_tn(n::Int64) = n > 2 ? (n,) : nothing
o_union_nothing(n::Int64) = (T = typeof(u_tn(n)); @code_of T Tuple{Int64} Nothing)
@noinline ints(n::Int64) = Integer[n > 2 ? Int8(n) : n]
@noinline tup_integer(n::Int64) = (ints(n)[1],)                       # inferred Tuple{Integer}
o_integer(n::Int64) = (T = typeof(tup_integer(n)); @code_of T Tuple{Int8} Tuple{Int64} Tuple{Integer})
@noinline tup_integer_w(n::Int64) = n > 100 ? AnySlot((Int8(n),)) : AnySlot(tup_integer(n))   # the world has Tuple{Int8}
o_integer_w(n::Int64) = (T = typeof(tup_integer_w(n).x); @code_of T Tuple{Int8} Tuple{Int64} Tuple{Integer})
@noinline tup_any(n::Int64) = (Any[n > 2 ? "s" : n][1],)              # inferred Tuple{Any}
o_any_string(n::Int64) = (w = AnySlot(("t",)); T = typeof(tup_any(n)); (@code_of T Tuple{String} Tuple{Int64} Tuple{Any}) + 0 * length(w.x[1]))

# A5 Tuple{Vararg{Int64}} operand; the world holds Tuple{Int64,Float64} (no 2-tuple of Int64)
@noinline mk_int(v::Vector{Int64}) = Core.tuple(v...)
o_vararg(n::Int64) = (w = any_pair(1); s = AnySlot(mk_int(collect(1:n))); T = typeof(s.x); (@code_of T Tuple{Int64,Float64} Tuple{Int64,Int64}) + 0 * (w.x[1]::Int64))

# B a lookup miss inside the program's own try
@noinline mayfail(n::Int64) = n > 100 ? error("x") : 0
b_try(n::Int64) = (try; s = pair(n); T = typeof(s.x); w = mayfail(n); (T === Int64 ? 1 : T === Memory{UInt8} ? 3 : 2) + w; catch; 5; end)

# C size: a chain T_k = Tuple{T_{k-1},T_{k-1}}, every level a concrete tuple the world holds; each consumer answers the
# code of the exact type: the chain of depth d over Int64 (n = 1), over Float64 (2), the one of depth d - 1 (3), Int64
nest_value(x, d::Int) = (for _ in 1:d; x = :(($x, $x)); end; x)
nest_type(t, d::Int) = (for _ in 1:d; t = :(Tuple{$t,$t}); end; t)
for d in (2, 4, 6, 8)
    local build = Symbol(:chain, d)
    local cons = Symbol(:c_chain, d)
    @eval @noinline $build(n::Int64) = AnySlot(n == 1 ? $(nest_value(:n, d)) : n == 2 ? $(nest_value(:(Float64(n)), d)) :
                                               n == 3 ? $(nest_value(:n, d - 1)) : n)
    @eval $cons(n::Int64) = (T = typeof($build(n).x); @code_of T $(nest_type(:Int64, d)) $(nest_type(:Float64, d)) $(nest_type(:Int64, d - 1)) Int64)
end
# two typeof sites of the chain in one function: each calls the one _recordRuntimeType of its record class
for d in (4, 8)
    local build = Symbol(:chain, d)
    local types = (nest_type(:Int64, d), nest_type(:Float64, d), nest_type(:Int64, d - 1), :Int64)
    @eval $(Symbol(:c_chain, d, :_twice))(n::Int64) = (A = typeof($build(n).x); B = typeof($build(n + 1).x);
                                                       (@code_of A $(types...)) + 10 * (@code_of B $(types...)))
end
# C size: 20 two-tuple types, nesting three deep
const TWENTY = [:(Int64(n)), :(Float64(n)), :(UInt8(n)), :(Int8(n)), :(Int32(n))]
@eval @noinline function twenty(n::Int64)
    $(Expr(:block, [:(n == $(5 * (i - 1) + j) && return AnySlot(($(TWENTY[i]), $(TWENTY[j])))) for i in 1:4 for j in 1:5]...))
    n == 21 && return AnySlot((((n,), n), n))
    n == 22 && return AnySlot(((((n,), n), n), 1.0))
    return AnySlot(n)
end
# the code of each of its 22 tuple types (n = 1..22, the 20 pairs in the order twenty builds them) and of Int64 (23)
const TWENTY_T = [:Int64, :Float64, :UInt8, :Int8, :Int32]
@eval c_twenty(n::Int64) = (T = typeof(twenty(n).x);
                            @code_of T $([:(Tuple{$(TWENTY_T[i]),$(TWENTY_T[j])}) for i in 1:4 for j in 1:5]...) Tuple{Tuple{Tuple{Int64},Int64},Int64} Tuple{Tuple{Tuple{Tuple{Int64},Int64},Int64},Float64} Int64)
end

const RUNS = [(Q.c_prims, 1:11), (Q.c_refs, 1:9), (Q.c_tvals, 1:6), (Q.c_uval, (1, 2, 6)), (Q.c_nests, 1:9), (Q.c_partial, (6,)),
              (Q.c_partial2, (1, 6)), (Q.c_named_only, (1, 6)), (Q.c_isa_only, (1, 6)), (Q.c_field_only, (1, 6)), (Q.c_ret_only, (1, 6)),
              (Q.r_egal, (1, 4)), (Q.r_isa, (1, 4)), (Q.r_param, (1, 4)), (Q.r_typeoftype, (1, 4)), (Q.o_union_nothing, (1, 3)),
              (Q.o_integer_w, (1, 3)), (Q.b_try, (6,)), (Q.c_twenty, (1, 7, 13, 20, 21, 22, 23)), (Q.c_chain2, 1:4), (Q.c_chain4, 1:4),
              (Q.c_chain6, 1:4), (Q.c_chain8, 1:4), (Q.c_chain4_twice, (1, 2)), (Q.c_chain8_twice, (1, 2))]

@testset "the review's programs: typeof of a tuple record answered from its fields, as native" begin
    local cases = WTChild.RunCase[]
    for (f, ns) in RUNS, n in ns
        push!(cases, WTChild.compiled_case("$(nameof(f))($n)", W.compile, f, (Int64(n),)))
    end
    for r in WTChild.run_cases(cases)
        @test (r.label => r.why) == (r.label => "")
    end
    # the lookup's miss: a nested String record no row holds, and a splat of an Int64 and a String no row is
    for (f, n) in ((Q.c_partial, 1), (Q.b_try, 1))
        local r = only(WTChild.run_cases([WTChild.compiled_case("$(nameof(f))($n)", W.compile, f, (Int64(n),))]))
        @test r.outcome === :unported
        local m = match(r"unported: the (dart|Julia-only) definition (.*)", r.why)
        @test m !== nothing && startswith(m.captures[2], "julia/src/jltypes.c:2477 jl_inst_arg_tuple_type: ")
    end
end

# the size the lookup's port exists for (e49812ea, dart's record_class_generator.dart:653 _generateRecordRuntimeType, one
# generated member per record class compiled once through FunctionCollector.getFunction): a typeof of a record its
# operand does not pin is one call of its record class's _recordRuntimeType, so the module defines that function once
# however deep the nesting and however many sites, the site's code is the same at depth 8 as at depth 4, and the
# member's grows with the rows it tests, never with 2^depth. Read from the defined functions of codegen's module, the
# phases compile runs (src/compile.jl: cfe, tfa, then codegen's translate, whose modules it serializes)
@testset "C size: one _recordRuntimeType function per record class, a typeof site's code the same at every depth" begin
    local D = W.Dart2Wasm
    local function defined(f)
        local options = D.WasmCompilerOptions(; main_uri = "", output_file = "main.wasm")
        options.translator_options.standalone = true
        options.translator_options.generate_source_maps = false
        local tfa = D._run_tfa_phase(D._run_cfe_phase(options, W.check_subset(f, (Int64,), "tuple_record_lookup", Base.get_world_counter())), options)
        local t = D.Translator(tfa.component, D.build_module_output_data(tfa.module_strategy), options.translator_options)
        return [(fn.function_name, length(fn.body[].instructions)) for (_, m) in D.translate(t, nothing) for fn in m._functions[].defined]
    end
    local member = "WasmTarget.TupleRecord{2}._recordRuntimeType"
    local size_of(fs, name) = only(n for (s, n) in fs if s == name)
    local site(f) = "$(parentmodule(f)).$(nameof(f))(::Int64)"
    local f4, f8, f4x2, f8x2 = defined(Q.c_chain4), defined(Q.c_chain8), defined(Q.c_chain4_twice), defined(Q.c_chain8_twice)
    for fs in (f4, f8, f4x2, f8x2)
        @test count(((s, _),) -> s == member, fs) == 1
    end
    @test size_of(f8, site(Q.c_chain8)) == size_of(f4, site(Q.c_chain4))
    @test size_of(f8, member) <= 2 * size_of(f4, member)
    # two sites call the same member, which the second site does not make larger, and are the same code at either depth
    @test size_of(f8x2, member) == size_of(f8, member) && size_of(f4x2, member) == size_of(f4, member)
    @test size_of(f8x2, site(Q.c_chain8_twice)) == size_of(f4x2, site(Q.c_chain4_twice))
    # each consumer answers the code of its exact type natively: the cases above read these in both modules
    @test [f(n) for f in (Q.c_chain2, Q.c_chain4, Q.c_chain6, Q.c_chain8) for n in 1:4] == repeat(1:4, 4)
    @test [f(n) for f in (Q.c_chain4_twice, Q.c_chain8_twice) for n in 1:2] == [21, 32, 21, 32]
    @test [Q.c_twenty(n) for n in 1:23] == 1:23
end

# the reference of a member the record class generator generates (src/julia/kernel.jl RecordMemberReference): a record
# class's alone; its name dart's member name; _recordRuntimeType's code the helper's generator, every other member the
# generator's located rejection, reached through the one match, and so is its function type
@testset "a record class's generated member: its reference, its name, its code generator, each other member refused" begin
    local D = W.Dart2Wasm
    local e = try; W.RecordMemberReference(Int64, W.RecordRuntimeType()); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
    local t = D.Translator(W.build_nir(W.check_subset(Q.r_egal, (Int64,), "tuple_record_lookup", Base.get_world_counter()), "test"),
                           D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local fc = D.FunctionCollector(t)
    local ft = W.WasmBuilder.IR.FunctionType(W.WasmBuilder.IR.ValueType[], W.WasmBuilder.IR.ValueType[])
    local members = (W.RecordConstructor(), W.RecordHashCode(), W.RecordToString(), W.RecordEquals(), W.RecordCheckRecordType(),
                     W.RecordRuntimeType(), W.RecordMasqueradedRuntimeType())
    @test [D.get_function_name(fc, W.RecordMemberReference(W.TupleRecord{2}, m)) for m in members] ==
          ["WasmTarget.TupleRecord{2}.$n" for n in ("constructor", "hashCode", "toString", "==", "_checkRecordType", "_recordRuntimeType", "_masqueradedRecordRuntimeType")]
    @test D.get_inlinable_member_code_generator(t, ft, W.RecordMemberReference(W.TupleRecord{2}, W.RecordRuntimeType())) isa D._RecordClassGenerator__generate_record_runtime_type_helper
    for m in members
        m isa W.RecordRuntimeType && continue
        local r = W.RecordMemberReference(W.TupleRecord{2}, m)
        local g = try; D.get_inlinable_member_code_generator(t, ft, r); nothing; catch x; x; end
        @test g isa W.RejectionError && g.rejection isa W.Internal && occursin("record_class_generator.dart", sprint(showerror, g))
        local ty = try; D.visit_procedure(D._FunctionTypeGenerator(t, false, false), r, r); nothing; catch x; x; end
        @test ty isa W.RejectionError && ty.rejection isa W.Internal
        @test D.get_export_name(fc, r) === nothing && !D.synthesize_null_return_value(fc, r) && !D.synthesize_no_return(fc, r)
    end
end

end
