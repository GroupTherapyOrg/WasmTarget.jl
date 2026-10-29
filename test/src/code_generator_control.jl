# dart2wasm's code_generator.dart over control flow, ported (src/code_generator.jl, src/llvm/): the
# stackifier's structured control, a try/catch's try_table, MacroAssembler's class-id search, and
# the type tests types.dart emits through the code generator.
module CodeGeneratorControlTest

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "codegen_helpers.jl"))

@testset "code_generator.dart: MacroAssembler's class-id search, loops and tables" begin
    local B = W.WasmBuilder
    # f(classId) = whether it lies in `ranges`, through emitClassIdRangeCheck: a linear search for three
    # ranges or fewer, a bisection beyond; each module accepted by the builder at every instruction
    local range_module(ranges) = begin
        local mb = B.ModuleBuilder("m", nothing)
        local fb = B.define(mb.functions[], B.define_function(mb.types[], IR.ValueType[IR.NumType_i32], IR.ValueType[IR.NumType_i32]), "f")
        local b = B.body(fb)
        B.local_get(b, B.locals(fb)[1])
        D.emit_class_id_range_check(b, ranges)
        B.var"end"(b)
        B.var"export"(mb.exports, "f", fb)
        local s = B.Serializer(); B.serialize(s, B.build(mb)); B.data(s)
    end
    # run by node over class ids 0..45 each answers Julia's `any(r -> contains(r, id), ranges)`
    for ranges in ([D.Range(3, 3)], [D.Range(1, 2), D.Range(5, 9)],
                   [D.Range(0, 0), D.Range(2, 4), D.Range(7, 7), D.Range(10, 20), D.Range(30, 31)],
                   [D.Range(i, i + 1) for i in 0:4:40])
        local bytes = range_module(ranges)
        @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
        queue_native!("ranges $(length(ranges)) ", bytes, id -> Int32(any(r -> contains(r, Int64(id)), ranges)), [(Int32(id),) for id in 0:45])
    end
    # an empty search with no miss is WasmTarget's own defect
    local mb = B.ModuleBuilder("m", nothing)
    local fb = B.define(mb.functions[], B.define_function(mb.types[], IR.ValueType[IR.NumType_i32], IR.ValueType[IR.NumType_i32]), "f")
    @test rejection(() -> D._linear_class_id_search(B.body(fb), NamedTuple{(:range, :value), Tuple{D.Range, Nothing}}[], IR.ValueType[], _ -> nothing, nothing)).rejection isa W.Internal
    # incrementingLoop and emitDenseTableBranch build valid control: a sum of 0..n-1 and a three-way table
    local mb2 = B.ModuleBuilder("m", nothing)
    local fb2 = B.define(mb2.functions[], B.define_function(mb2.types[], IR.ValueType[IR.NumType_i32], IR.ValueType[IR.NumType_i32]), "g")
    local b2 = B.body(fb2)
    local acc = B.add_local(b2, IR.NumType_i32)
    D.incrementing_loop(b2; push_start = () -> B.i32_const(b2, 0), push_limit = () -> B.local_get(b2, B.locals(fb2)[1]),
        gen_body = v -> (B.local_get(b2, acc); B.local_get(b2, v); B.i32_add(b2); B.local_set(b2, acc)))
    D.emit_dense_table_branch(b2, IR.ValueType[IR.NumType_i32], 3, () -> B.local_get(b2, acc),
        i -> B.i32_const(b2, 10 * (i + 1)), () -> B.i32_const(b2, -1))
    B.var"end"(b2)
    local s2 = B.Serializer(); B.serialize(s2, B.build(mb2))
    @test B.data(s2)[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
end

module ControlCases
sumto(n::Int64) = (s = Int64(0); for i in Int64(1):n; s += i; end; s)
function fib(n::Int32)
    a, b = Int32(0), Int32(1)
    for _ in Int32(1):n
        a, b = b, a + b
    end
    a
end
sign3(x::Float64) = x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0)
absdiff(x::Int32, y::Int32) = x > y ? x - y : y - x
mergey(x::Int32) = (y = x > Int32(0) ? x * Int32(2) : x - Int32(5); y + Int32(1))
function early(x::Int64, y::Int64)
    x < 0 && return Int64(0)
    for i in Int64(1):y
        i > x && return i
    end
    y
end
end

@testset "code_generator.dart: control flow, structured by LLVM's stackifier" begin
    # loops, phis (fib's `a, b = b, a + b` a parallel move), nested branches, a merging diamond and
    # early returns from a loop: each body's machine code, sorted and stackified by LLVM's passes, is
    # lowered into a module the builder accepted at every instruction; run by node, each answers as
    # native Julia on its edge inputs
    local C = ControlCases
    local i32s = Int32[0, 41, -1, typemax(Int32), typemin(Int32)]
    for (f, at, argsets) in ((C.fib, (Int32,), [(Int32(n),) for n in (0, 1, 2, 10, 46, 47)]),
                             (C.sign3, (Float64,), [(x,) for x in [0.0, -0.0, 1.5, -2.5, 1e300, -Inf, NaN]]),
                             (C.mergey, (Int32,), [(x,) for x in i32s]),
                             (C.early, (Int64, Int64), [(Int64(-1), Int64(5)), (Int64(2), Int64(9)), (Int64(9), Int64(3)), (Int64(0), Int64(0))]),
                             (C.sumto, (Int64,), [(Int64(n),) for n in (0, 1, 10, 1000)]))
        local bytes = compile_one(f, at)
        @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
        queue_native!(string(nameof(f)), bytes, f, argsets)
    end
    # the loop's module holds a loop (0x03) and a conditional branch out of it
    local bytes = compile_one(C.sumto, (Int64,))
    @test 0x03 in bytes && 0x0d in bytes
end

module TryGenCases
struct E; v::Int64; end
@noinline thr(x::Int64) = x < 0 ? throw(E(x)) : x
tc(x::Int64) = try; thr(x) + 1; catch e; e isa E ? e.v * 2 : 0; end
tn(x::Int64) = try; (try; thr(x); catch; -1; end) + thr(x + 1); catch; -2; end
end

@testset "code_generator.dart: a try/catch, the stackifier's try_table around the call that unwinds to the catch" begin
    # tc's body alone (thr's, whose throw is not ported, is not generated), each instruction accepted
    # by the builder (D10): a BLOCK typed by the exception tag's payload, the try_table catching the tag
    # into it around the call, an unreachable after the try_table's end; after the block's end the
    # caught exception stashed (dart's visitTryCatch) and Julia's the_exception, narrowed to E, cast
    local names = generated_instructions(TryGenCases.tc, (Int64,))
    local t = findfirst(==("try_table"), names)
    @test names[t-2:t] == ["block", "block", "try_table"] && names[t+1:t+2] == ["local.get", "call"]
    local u = findfirst(==("unreachable"), names)
    @test names[u-1:u+5] == ["end", "unreachable", "end", "local.set", "local.get", "ref.cast", "local.set"]
    # nested try regions: the value the inner catch receives, x, through its Upsilon into the PhiC's
    # register, which the catch block reads
    local nn = generated_instructions(TryGenCases.tn, (Int64,))
    @test count(==("try_table"), nn) == 2 && count(==("unreachable"), nn) == 2
    # a try region's entry, exit and pop are the stackifier's structure and emit nothing; its catch's
    # exception and exception-edge values are read where visit_block translates them, never as statements
    local g = ready_codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    for st in (W.NirEnter(2, nothing), W.NirLeave(W.NirValue[W.NirSSA(1)]), W.NirPopException(W.NirValue[W.NirSSA(1)]))
        @test isempty(emitted_by(() -> D.translate_statement(g, st, nothing), g))
    end
    for st in (W.NirTheException(W.NirValue[]), W.NirUpsilon(W.NirArgument(2)), W.NirPhiC(W.NirValue[W.NirSSA(1)]))
        local r = rejection(() -> D.translate_statement(g, st, W.NirSSA(3)))
        @test r.rejection isa W.Internal && occursin("visit_block", r.rejection.site)
    end
end

@testset "types.dart's type tests read the code generator's late builder" begin
    # emitIsTest and emitAsCheck emit into AstCodeGenerator.b, dart's `late w.InstructionsBuilder b`,
    # a Late cell: read through it, a type test reaches its own rules (a located answer or rejection),
    # never a MethodError on the cell
    local B = W.WasmBuilder
    local t = translator_of(CodegenCases.f_add, (Int32,))
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    local mi = only(nb.ci.def for nb in t.component)
    local fb = B.define(D.main_module(t).functions[], B.define_function(D.main_module(t).types[], IR.ValueType[], IR.ValueType[]), "probe")
    local g = D.get_inlinable_member_code_generator(t, fb.type, mi)
    g.b[] = B.body(fb)
    for f in (() -> D.emit_is_test(t.types[], g, Int64, Any),
              () -> D.emit_as_check(t.types[], g, Int64, Any, t.top_type[]))
        local r = try; f(); nothing; catch e; e; end
        @test r === nothing || r isa W.RejectionError
    end
end

@testset "translator.dart: topTypeNonNullable" begin
    local t = translator_of(CodegenCases.f_add, (Int32,))
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    # dart's topType without null, read once from the top type
    @test t.top_type_non_nullable[] == W.WasmBuilder.with_nullability(t.top_type[], false) && !t.top_type_non_nullable[].nullable
end

module TypeTestCases
# each entry's signature is concrete (Julia compiles no specialization for a Union signature); the
# operand under test is the field read, whose inferred type is the Union
maybe(r::Base.RefValue{Union{Nothing,Int64}}) = r[] isa Int64
# the same isa over a reference the runner can build from an Int64 (an Int64 in the Union needs its
# box, not ported): the Ref built inside, nothing for a negative argument
mutable struct Cell; x::Int64; end
maybe_cell(r::Base.RefValue{Union{Nothing,Cell}}) = r[] isa Cell
maybe_of(x::Int64) = maybe_cell(Ref{Union{Nothing,Cell}}(x < 0 ? nothing : Cell(x)))
# Julia's `x === nothing` over the same field read, Kernel's EqualsNull
null_of(x::Int64) = Ref{Union{Nothing,Cell}}(x < 0 ? nothing : Cell(x))[] === nothing
as_int(r::Base.RefValue{Union{Nothing,Int64}}) = r[]::Int64
dyn(r::Base.RefValue{Union{Nothing,Int64}}, T::DataType) = r[] isa T
end

@testset "code_generator.dart: isa and typeassert through types.dart's tests" begin
    local R = Base.RefValue{Union{Nothing,Int64}}
    # Julia's isa of the field read, visitIsExpression over the body's own statement (the Union of
    # Nothing and Int64 a nullable reference, emitIsTest's null check): run by node it answers as
    # native Julia, nothing and every Int64
    local bytes = W.compile(TypeTestCases.maybe_of, (Int64,); optimize = false)
    queue_native!("maybe_of", bytes, TypeTestCases.maybe_of, [(x,) for x in Int64[-1, 0, 1, typemax(Int64), typemin(Int64)]])
    # `x === nothing`, visitEqualsNull: the field read's null check, run by node against native
    local nbytes = W.compile(TypeTestCases.null_of, (Int64,); optimize = false)
    queue_native!("null_of", nbytes, TypeTestCases.null_of, [(x,) for x in Int64[-1, 0, 5]])
    # Julia's typeassert, the checked AsExpression: emitAsCheck needs the runtime's _asSubtype, not
    # ported, a located rejection at the runtime library's definition
    local e = rejection(() -> generated_instructions(TypeTestCases.as_int, (R,)))
    @test e.rejection isa W.Unported && e.rejection.anchor == "sdk/lib/_internal/wasm/common/type.dart:1561 _asSubtype" &&
          startswith(e.at, "dart2wasm/lib/types.dart:527 Types.emitAsCheck")
    # a type computed at run time is no type test's constant: a value, which only the runtime's
    # subtype check takes, not ported
    local d = rejection(() -> generated_instructions(TypeTestCases.dyn, (R, DataType)))
    @test d.rejection isa W.Unported && d.rejection.anchor == "sdk/lib/_internal/wasm/common/type.dart:1484 _isSubtype" &&
          occursin("TypeTestCases.dyn", d.at)
    # Julia's type parameter is a static parameter of the MethodInstance, never a type local, a
    # capture or a field: no NIR reaches instantiateTypeParameter, an Internal naming nir.jl's rejection
    local g = codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    local p = rejection(() -> D.instantiate_type_parameter(g, TypeVar(:T)))
    @test p.rejection isa W.Internal && occursin("Expr(:static_parameter)", p.rejection.site)
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTRunner.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end

end
