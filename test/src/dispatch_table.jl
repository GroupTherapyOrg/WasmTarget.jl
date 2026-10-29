# dart2wasm's dispatch_table.dart, ported (src/dispatch_table.jl, dev/MARCH.md 1.E): the
# row-displacement table on fixed rows, its invariants those of dev/formal/ClassIdDispatch.tla.
using Test
using WasmTarget

const DD = WasmTarget.Dart2Wasm

module DispatchCases
f(x::Int) = x + 1
g(x::Float64) = x * 2
h(x::Int32) = x - Int32(1)
end

# a member: Julia's MethodInstance of `f` at `T`, as Julia's own dispatch answers it
_mi(f, T) = Core.Compiler.specialize_method(Base._which(Base.signature_type(f, T)))

@testset "dispatch_table.dart: Row and buildRowDisplacementTable" begin
    local MI = Core.MethodInstance
    local a, b, c = _mi(DispatchCases.f, (Int,)), _mi(DispatchCases.g, (Float64,)), _mi(DispatchCases.h, (Int32,))
    @test a.def === which(DispatchCases.f, (Int,)) && b.def === which(DispatchCases.g, (Float64,))
    local row(pairs) = DD.Row([(index = i, value = v) for (i, v) in pairs])
    local r1 = row([(1, a), (2, a), (5, a)])
    @test DD.width(r1) == 5 && DD.holes(r1) == 2 && DD.density(r1) == 60 && DD.sparsity(r1) == 40
    local rows = [r1, row([(2, b), (3, b)]), row([(1, c), (4, c)]), row([(3, a)])]
    local table = DD.build_row_displacement_table(rows)
    # every value lands at its row's offset plus its index; no slot holds two values (the model's
    # SlotUnique); every taken slot is some row's value
    local placed = Dict{Int,Tuple{Int,MI}}()
    for (k, r) in enumerate(rows), (i, v) in r.values
        local slot = r.offset[] + i
        @test !haskey(placed, slot)
        placed[slot] = (k, v)
        @test table[slot + 1] === v
    end
    @test count(!isnothing, table) == length(placed) == sum(length(r.values) for r in rows)
    # the first row fits from the first free slot, 0
    @test r1.offset[] == -1
    # unique offsets: no two rows share an offset
    local urows = [row([(1, a)]), row([(2, b)]), row([(3, c)])]
    DD.build_row_displacement_table(urows; unique_offsets = true)
    @test allunique([r.offset[] for r in urows])
    # a stride: the entries from `start` the predicate accepts, the first included
    local t2 = Union{MI,Nothing}[a, a, nothing, a, b]
    @test DD.calculate_stride_with(0, a, t2, x -> x === a) == 2
    @test DD.calculate_stride_with(0, a, t2, x -> x === a || x === nothing) == 4
    @test DD.calculate_stride_with(4, b, t2, x -> true) == 1
    @test DD.stride_element_table_limit() == 100
    # a row asserts its values are present and sorted: located rejections
    for bad in (NamedTuple{(:index, :value),Tuple{Int,MI}}[], [(index = 2, value = a), (index = 1, value = a)])
        local e = try; DD.Row(bad); nothing; catch x; x; end
        @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Internal
    end
end

module EmptyTableCases
abstract type S end
struct A <: S; x::Int; end
struct B <: S; y::Float64; end
area(a::A) = Float64(a.x)
area(b::B) = b.y
# an entry typed S has no compileable specialization (Julia's subset check rejects it), so the entry is
# concrete and the abstract receiver is a field of it
struct Holder; s::S; end
k(h::Holder) = area(h.s)
end

@testset "dispatch_table.dart, dynamic_dispatch_table.dart: empty by the trim verifier's subset (D32)" begin
    local W = WasmTarget
    local data = DD.build_module_output_data(DD.DefaultModuleStrategy(DD.WasmCompilerOptions_default_options()))
    # an abstract receiver: Julia union-splits the call into isa tests and invokes, so no NIR
    # statement is a dynamic call
    local t = DD.Translator(WasmTarget.build_nir(W.check_subset(EmptyTableCases.k, (EmptyTableCases.Holder,), "dispatch_table"), "test"), data, DD.TranslatorOptions())
    DD._init_modules(t, nothing)
    collect(DD.ClassInfoCollector(t))
    @test isempty(DD.DynamicCallSiteCollector_collect(t.component))
    local dt = t.dispatch_table[]
    DD.build(dt)
    # no class has an instance member: no selector, an empty table, defined in the main module
    @test isempty(dt._selector_info) && isempty(dt._table[]) && isempty(dt._table_index_for_reference[])
    @test dt._defined_wasm_table[].min_size == 0 && DD.get_wasm_table(dt, DD.main_module(t)) === dt._defined_wasm_table[]
    @test DD.index_for_target(dt, first(b.ci.def for b in t.component)) === nothing
    local ddt = t.dynamic_dispatch_table[]
    DD.build(ddt, DD.DynamicCallSiteCollector_collect(t.component))
    @test isempty(ddt._table[]) && ddt._defined_targets_table[].min_size == 0 && ddt._defined_class_ids_table[].min_size == 0
    DD.output(dt); DD.output(ddt)
    # a member asks for no selector: a located rejection
    local e = try; DD.selector_for_target(dt, first(b.ci.def for b in t.component)); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
end

@testset "dispatch_table.dart: SelectorInfo over Julia members; dynamic_dispatch_table.dart's integer expression" begin
    local W = WasmTarget
    local IR = W.WasmBuilder.IR
    local data = DD.build_module_output_data(DD.DefaultModuleStrategy(DD.WasmCompilerOptions_default_options()))
    local t = DD.Translator(WasmTarget.build_nir(W.check_subset(DispatchCases.f, (Int,), "dispatch_table"), "test"), data, DD.TranslatorOptions())
    DD._init_modules(t, nothing)
    collect(DD.ClassInfoCollector(t))
    local dt = t.dispatch_table[]
    local s = DD.SelectorInfo__(dt, 0, "f", 1; is_setter = false, is_index_setter = false)
    @test DD.translator(s) === t
    # one entry point: the name alone; checked and unchecked ones each say which
    s.use_multiple_entry_points[] = false
    @test DD.entry_point_name(s, true) == "f"
    local mi = _mi(DispatchCases.f, (Int,))
    s._normal = DD.SelectorTargets([(range = DD.Range(1, 1), target = mi)], [(range = DD.Range(1, 1), target = mi)], NamedTuple{(:range, :target),Tuple{DD.Range,Core.MethodInstance}}[])
    @test DD.targets(s; unchecked = false) === s._normal && DD.contains_target(s, mi) && !DD.contains_target(s, _mi(DispatchCases.g, (Float64,)))
    local s2 = DD.SelectorInfo__(dt, 1, "g", 0; is_setter = false, is_index_setter = false)
    s2.use_multiple_entry_points[] = true
    @test DD.entry_point_name(s2, true) == "g (unchecked)" && DD.entry_point_name(s2, false) == "g (checked)"
    local e = try; DD.targets(s2; unchecked = true); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
    # the upper bound: an unboxed primitive alone; else the nearest common struct, nullable if any is
    @test DD._upper_bound(s, Set{IR.ValueType}([IR.NumType_i64]); ensure_boxed = false) === IR.NumType_i64
    local a = IR.StructType("A"); local b = IR.StructType("B"; super_type = a); local c = IR.StructType("C"; super_type = a)
    local d = IR.StructType("D"; super_type = b)
    local ub = DD._upper_bound(s, Set{IR.ValueType}([IR.RefType_def(d; nullable = false), IR.RefType_def(c; nullable = true)]); ensure_boxed = false)
    @test ub.heap_type === a && ub.nullable
    @test DD._upper_bound(s, Set{IR.ValueType}([IR.RefType_def(b; nullable = false), IR.RefType_def(d; nullable = false)]); ensure_boxed = false).heap_type === b
    @test DD._upper_bound(s, Set{IR.ValueType}(); ensure_boxed = false) == t.top_type[]
    # a primitive to box: several Julia classes share its wasm type, a located rejection
    local e2 = try; DD._upper_bound(s, Set{IR.ValueType}([IR.NumType_i32]); ensure_boxed = true); nothing; catch x; x; end
    @test e2 isa W.RejectionError && e2.rejection isa W.Unquarantined
    # an entry of the class ids table: the constant i31 reference of the class id
    local ce = DD.build_integer_expression(DD.main_module(t), 7)
    @test ce isa W.WasmBuilder.InstructionsBuilder
end
