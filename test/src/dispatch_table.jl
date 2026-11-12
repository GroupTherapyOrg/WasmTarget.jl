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
    local t = DD.Translator(WasmTarget.build_nir(W.check_subset(EmptyTableCases.k, (EmptyTableCases.Holder,), "dispatch_table", Base.get_world_counter()), "test"), data, DD.TranslatorOptions())
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
    # a collected shape or a placed entry: none in Julia's subset, so the collector's or builder's error.
    # No admitted program can collect a dynamic call shape: check_subset (src/julia/subset.jl) admits only
    # what Julia's trim verifier accepts (_verify_trim over Compiler/src/verifytrim.jl), which rejects
    # every call it cannot resolve statically before WasmTarget compiles anything, so the shapes and
    # entries planted here are reachable only by hand
    local internal(f) = (e = try; f(); nothing; catch x; x; end; e isa W.RejectionError && e.rejection isa W.Internal)
    @test internal(() -> DD.build(DD.DynamicDispatchTable(t), Set{DD.CallShape}([DD.GetterCallShape(:f)])))
    local entry = DD.TableEntry(first(b.ci.def for b in t.component), 0, DD.GetterCallShape(:f))
    local ddt2 = DD.DynamicDispatchTable(t)
    ddt2._table[] = Union{DD.TableEntry,Nothing}[entry]
    @test internal(() -> DD.output_target_table(ddt2)) && internal(() -> DD.output_class_id_table(ddt2))
    # a member asks for no selector: a located rejection
    local e = try; DD.selector_for_target(dt, first(b.ci.def for b in t.component)); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
end

@testset "dispatch_table.dart: SelectorInfo over Julia members; dynamic_dispatch_table.dart's integer expression" begin
    local W = WasmTarget
    local IR = W.WasmBuilder.IR
    local data = DD.build_module_output_data(DD.DefaultModuleStrategy(DD.WasmCompilerOptions_default_options()))
    local t = DD.Translator(WasmTarget.build_nir(W.check_subset(DispatchCases.f, (Int,), "dispatch_table", Base.get_world_counter()), "test"), data, DD.TranslatorOptions())
    DD._init_modules(t, nothing)
    collect(DD.ClassInfoCollector(t))
    local dt = t.dispatch_table[]
    local s = DD.SelectorInfo__(dt, 0, "f", 1; is_setter = false, is_index_setter = false)
    @test DD.translator(s) === t
    # one entry point: the name alone; checked and unchecked ones each say which
    s.use_multiple_entry_points[] = false
    @test DD.entry_point_name(s, true) == "f"
    local mi = _mi(DispatchCases.f, (Int,))
    local RT = NamedTuple{(:range, :target),Tuple{DD.Range,W.Reference}}
    s._normal = DD.SelectorTargets(RT[(range = DD.Range(1, 1), target = mi)], RT[(range = DD.Range(1, 1), target = mi)], RT[])
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
    # _lookupTarget: build makes no DynamicSelector (it rejects any dynamic call shape, none of which a
    # Julia program has), so a lookup is WasmTarget's own defect, Internal
    local ddt = DD.DynamicDispatchTable(t)
    local ds = DD.DynamicSelector(Val(:_), DD.GetterCallShape(:x), W.WasmBuilder.define_function(DD.main_module(t).types[], IR.ValueType[], IR.ValueType[]))
    local el = try; DD._lookup_target(ddt, ds, 0); nothing; catch x; x; end
    @test el isa W.RejectionError && el.rejection isa W.Internal && occursin("no DynamicSelector", el.rejection.site)
end

# a numbered translator of `f`'s world (modules, closures and classes collected), whose admitted classes
# getConcreteClassIdRange reads, as DispatchTable.build passes them (concrete_classes)
numbered(f) = (t = DD.Translator(WasmTarget.build_nir(WasmTarget.check_subset(f, (Int,), "dispatch_table", Base.get_world_counter()), "test"),
        DD.build_module_output_data(DD.DefaultModuleStrategy(DD.WasmCompilerOptions_default_options())), DD.TranslatorOptions());
    DD._init_modules(t, nothing); collect(t.closure_layouter[]); collect(t.class_info_collector[]); t)
admitted(t) = r -> WasmTarget.concrete_classes(t, r)

module FieldSelectorCases
abstract type S end
struct A <: S; side::Int; tag::Int; end
struct B <: S; side::Int; tag::Int; end
struct C <: S; tag::Int; end
struct Holder; s::S; end
# a field read on a receiver Julia left abstract (S): a call of the field's getter selector
@noinline read_side(h::Holder) = h.s.side
@noinline read_tag(h::Holder) = h.s.tag
two(n::Int) = (read_side(Holder(n > 0 ? A(n, 1) : B(n, 2))), read_tag(Holder(n > 1 ? A(n, 3) : B(n, 4))))
# C, which a read of `side` on an S may reach, has no field `side`: Julia's FieldError
missing_side(n::Int) = read_side(Holder(n > 0 ? A(n, 1) : C(n)))
# a field read by position on an S: Julia's getfield reads each class's field there, `side` in A and B
@noinline read_first(h::Holder) = getfield(h.s, 1)
@noinline read_second(h::Holder) = getfield(h.s, 2)
first_of(n::Int) = read_first(Holder(n > 0 ? A(n, 1) : B(n + 7, 2)))
# its value narrowed back to Int, an answer the runner reads
first_int(n::Int) = (r = first_of(n); r isa Int ? r : -1)
# position 1 is `tag` in C, `side` in A; position 2 is past C's one field
first_mixed(n::Int) = read_first(Holder(n > 0 ? A(n, 1) : C(n)))
second_short(n::Int) = read_second(Holder(n > 0 ? A(n, 1) : C(n)))
# a MemoryRef's ptr_or_offset read through a Union receiver: Julia's element address, which the index
# WasmTarget holds is not, for an Int64 and a Float64 memory alike; a union element's is the offset
union_ref_ptr(n::Int) = (x = n > 0 ? Core.memoryref(Memory{Int64}(undef, 1)) : Core.memoryref(Memory{Float64}(undef, 1)); Int(UInt(getfield(x, :ptr_or_offset))))
union_ref_offset(n::Int) = (x = n > 0 ? Core.memoryref(Memory{Union{Nothing,Int64}}(undef, 1)) : Core.memoryref(Memory{Union{Nothing,Float64}}(undef, 1)); Int(UInt(getfield(x, :ptr_or_offset))))
end

@testset "dispatch_table.dart: field selectors, each class's accessor by class id (dev/formal/FieldSelectorTable.tla)" begin
    local W = WasmTarget
    local F = FieldSelectorCases
    local data = DD.build_module_output_data(DD.DefaultModuleStrategy(DD.WasmCompilerOptions_default_options()))
    local t = DD.Translator(W.build_nir(W.check_subset(F.two, (Int,), "dispatch_table", Base.get_world_counter()), "test"), data, DD.TranslatorOptions())
    DD._init_modules(t, nothing)
    collect(t.closure_layouter[]); collect(t.class_info_collector[])
    # Julia's IR reads both fields on an S, each one call of its getter selector
    local calls = W.field_selector_calls(t.component, admitted(t))
    @test Set((c.name, c.is_setter, c.call_count, Set(c.classes)) for c in calls) == Set([("side", false, 1, Set([F.A, F.B])), ("tag", false, 1, Set([F.A, F.B]))])
    local dt = t.dispatch_table[]
    DD.build(dt)
    local ids = t.class_id_numbering[].class_ids
    local getter(cls, name) = W.FieldReference(only(f for f in W.class_instance_fields(cls, "test") if f.name == name), W.FieldReferenceKind_getter)
    local seen_slots = Set{Int}()
    for name in ("side", "tag")
        local s = DD.selector_for_target(dt, getter(F.A, name))
        @test s.name == name && !s.is_setter && s.call_count == 1
        local tg = DD.targets(s; unchecked = false)
        # two classes, two accessors: two ranges, called through the table
        @test length(tg.all_target_ranges) == 2 && isempty(tg.static_dispatch_ranges) && tg.offset !== nothing
        for cls in (F.A, F.B)
            # DispatchExact: the slot at the class id plus the selector's offset is the class's own accessor
            local slot = ids[cls] + tg.offset
            @test dt._table[][slot + 1] === getter(cls, name)
            # SlotUnique: no slot serves two selectors
            @test !(slot in seen_slots)
            push!(seen_slots, slot)
        end
    end
    @test count(!isnothing, dt._table[]) == 4
    # callDispatchTable: the receiver's class id plus the offset indexes the table, its entry called
    # at the selector's signature; a direct call of an accessor the selector holds takes that signature
    local side = DD.selector_for_target(dt, getter(F.A, "side"))
    local sig = side.signature[]
    @test DD.signature_for_direct_call(t, getter(F.B, "side")) === sig
    local b = W.WasmBuilder.InstructionsBuilder(DD.main_module(t), sig.inputs, sig.outputs)
    # the call's receiver, then the receiver again, whose class id loadClassId reads
    W.WasmBuilder.local_get(b, b.locals[1]); W.WasmBuilder.local_get(b, b.locals[1])
    @test DD.call_dispatch_table(t, b, side; use_unchecked_entry = false) === nothing
    local ops = [nameof(typeof(i)) for i in b._instructions]
    @test :CallIndirect in ops
    # an interface target, a SelectorReference, names its call site, whose selector build recorded once
    # (procedureAttributeMetadata); a site build never met has none, located; an initializer's cannot
    # be made
    local rs = only(nb for nb in t.component if nb.ci.def.def.name === :read_side)
    local site_stmt = only(st for st in rs.stmts if st isa W.NirCall && W.nir_callee(st) === Core.getfield && st.args[3] isa W.NirConst && st.args[3].c.val === :side)
    local site = W.FieldAccessSite(rs.ci.def, findfirst(st -> st === site_stmt, rs.stmts))
    @test DD.selector_for_target(dt, W.SelectorReference(site, W.FieldReferenceKind_getter)) === side
    @test dt.procedure_attribute_metadata[site] == side.id
    local other = only(st for st in rs.stmts if st isa W.NirCall && W.nir_callee(st) === Core.getfield && st.args[3] isa W.NirConst && st.args[3].c.val === :s)
    local en = try; DD.selector_for_target(dt, W.SelectorReference(W.FieldAccessSite(rs.ci.def, findfirst(st -> st === other, rs.stmts)), W.FieldReferenceKind_getter)); nothing; catch x; x; end
    @test en isa W.RejectionError && en.rejection isa W.Internal
    local ei = try; W.SelectorReference(site, W.FieldReferenceKind_initializer); nothing; catch x; x; end
    @test ei isa W.RejectionError && ei.rejection isa W.Internal
    # a method is no instance member: no selector
    local e = try; DD.selector_for_target(dt, t.component.entry); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
    # MissingFieldTraps: a class the receiver admits without the field reaches Julia's FieldError, a
    # target not yet written, so the build rejects there, located, never leaving the slot empty
    local t2 = DD.Translator(W.build_nir(W.check_subset(F.missing_side, (Int,), "dispatch_table", Base.get_world_counter()), "test"), data, DD.TranslatorOptions())
    DD._init_modules(t2, nothing)
    collect(DD.ClassInfoCollector(t2))
    local e2 = try; DD.build(t2.dispatch_table[]); nothing; catch x; x; end
    @test e2 isa W.RejectionError && e2.rejection isa W.Unquarantined && occursin("FieldError", e2.rejection.row)
    # a read by position is the selector of the field each admitted class holds there (Julia's
    # get_checked_fieldindex), never a selector named "1" that every class lacks (A69S2)
    local world(f) = W.build_nir(W.check_subset(f, (Int,), "dispatch_table", Base.get_world_counter()), "test")
    local tf = numbered(F.first_of)
    local pc = W.field_selector_calls(tf.component, admitted(tf))
    @test [(c.name, c.is_setter, c.call_count, Set(c.classes)) for c in pc] == [("side", false, 1, Set([F.A, F.B]))]
    local t3 = DD.Translator(world(F.first_of), data, DD.TranslatorOptions())
    DD._init_modules(t3, nothing)
    collect(t3.closure_layouter[]); collect(t3.class_info_collector[])
    DD.build(t3.dispatch_table[])
    local s3 = DD.selector_for_target(t3.dispatch_table[], getter(F.B, "side"))
    @test s3.name == "side" && t3.dispatch_table[]._table[][t3.class_id_numbering[].class_ids[F.B] + DD.targets(s3; unchecked = false).offset + 1] === getter(F.B, "side")
    # a position naming different fields in different classes, or past a class's fields: located
    local em = try; (tm = numbered(F.first_mixed); W.field_selector_calls(tm.component, admitted(tm))); nothing; catch x; x; end
    @test em isa W.RejectionError && em.rejection isa W.Unquarantined && occursin("side, tag", em.rejection.row)
    local eb = try; (ts = numbered(F.second_short); W.field_selector_calls(ts.component, admitted(ts))); nothing; catch x; x; end
    @test eb isa W.RejectionError && eb.rejection isa W.Unquarantined && occursin("BoundsError", eb.rejection.row)
    # a getter selector's read of a field held in another form than Julia's rejects at its site, as
    # _directGet's does (memoryref_address_unread); the offset form, Julia's own, is a selector
    local ep = try; (tp = numbered(F.union_ref_ptr); W.field_selector_calls(tp.component, admitted(tp))); nothing; catch x; x; end
    @test ep isa W.RejectionError && ep.rejection isa W.Unquarantined && occursin("Julia's element address", ep.rejection.row)
    local to = numbered(F.union_ref_offset)
    @test [c.name for c in W.field_selector_calls(to.component, admitted(to))] == ["ptr_or_offset"]
    # the compile calls through the table (_virtualCall): first_of's read by position, run by node,
    # answers as native Julia
    isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
    local fb = W.compile(F.first_int, (Int,); optimize = false)
    for r in Main.WTChild.run_cases([Main.WTChild.RunCase("first_int($n)", fb, (n,), Main.WTChild.native_answer(F.first_int, (n,))) for n in (3, -2)])
        @test r.ok || (@info r.label r.why; false)
    end
end

@testset "translator.dart: PolymorphicDispatchers, a class-id search over the static dispatch ranges (polymorphic specialization)" begin
    local W = WasmTarget
    local F = FieldSelectorCases
    local data = DD.build_module_output_data(DD.DefaultModuleStrategy(DD.WasmCompilerOptions_default_options()))
    local t = DD.Translator(W.build_nir(W.check_subset(F.two, (Int,), "dispatch_table", Base.get_world_counter()), "test"), data, DD.TranslatorOptions(polymorphic_specialization = true))
    DD._init_modules(t, nothing)
    collect(t.closure_layouter[]); collect(t.class_info_collector[])
    local dt = t.dispatch_table[]
    DD.build(dt)
    local getter(cls) = W.FieldReference(only(f for f in W.class_instance_fields(cls, "test") if f.name == "side"), W.FieldReferenceKind_getter)
    local side = DD.selector_for_target(dt, getter(F.A))
    # dispatch_table.dart:694: under polymorphic specialization each of the two ranges is static
    local tg = DD.targets(side; unchecked = false)
    @test length(tg.all_target_ranges) == 2 && length(tg.static_dispatch_ranges) == 2
    # one dispatcher per module and selector, its signature the class id then the selector's inputs
    local pd = DD.get_polymorphic_dispatchers_for_module(t, DD.main_module(t))
    @test DD.get_polymorphic_dispatchers_for_module(t, DD.main_module(t)) === pd
    local ct = DD.get_polymorphic_dispatcher(pd, side; use_unchecked_entry = false)
    @test DD.get_polymorphic_dispatcher(pd, side; use_unchecked_entry = false) === ct
    @test DD.name(ct) == "side (polymorphic dispatcher)" && DD.supports_inlining(ct)
    @test ct.signature.inputs == W.WasmBuilder.IR.ValueType[W.WasmBuilder.IR.NumType_i32; side.signature[].inputs] && ct.signature.outputs == side.signature[].outputs
    # two static ranges: not inlined
    @test !DD.should_inline(ct).should_inline
    # the body: the class id searched, each range's own accessor called directly (an implicit getter,
    # inlined: its struct.get), no table fallback
    local b = W.WasmBuilder.InstructionsBuilder(DD.main_module(t), ct.signature.inputs, ct.signature.outputs)
    @test DD.generate(DD.inlining_code_gen(ct), b, b.locals, nothing) === nothing
    local ops = [nameof(typeof(i)) for i in b._instructions]
    @test count(==(:StructGet), ops) == 2 && !(:CallIndirect in ops) && :Return in ops
    # its function, defined in the calling module on first read, queued once
    local f = DD.var"function"(ct)
    @test f isa W.WasmBuilder.IR.BaseFunction && DD.var"function"(ct) === f
    # a selector of one range is a direct call, no dispatcher
    local t1 = DD.Translator(W.build_nir(W.check_subset(F.two, (Int,), "dispatch_table", Base.get_world_counter()), "test"), data, DD.TranslatorOptions())
    DD._init_modules(t1, nothing)
    collect(t1.closure_layouter[]); collect(t1.class_info_collector[])
    DD.build(t1.dispatch_table[])
    local side1 = DD.selector_for_target(t1.dispatch_table[], getter(F.A))
    @test isempty(DD.targets(side1; unchecked = false).static_dispatch_ranges)
end
