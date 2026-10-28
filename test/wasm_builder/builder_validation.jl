# The WebAssembly (3.0, with GC) validation rules and the builder check that refuses each where the
# invalid thing is emitted or defined (dev/LEDGER.md D10). dart's builder checks the operand stack and
# the labels, inside asserts, and leaves the rest to the engine. The port makes dart's checks on every
# emission (test/wasm_builder/builder_refusals.jl has one case per dart check) and adds the spec's
# other rules here, each a located InvalidModule rejection, each with one case below. wasm-tools
# validate stays the alarm on the golden modules (test/wasm_builder/builder_modules.jl).
#
# The inventory, by the spec's Validation chapter. "dart" is dart's check, ported; "spec" is a check
# the port adds, citing the rule; "construction" is a rule the builder's API cannot break. 22 rules
# had no check before (the rows marked "was missing"); every one is refused now.
#
#   Instructions
#   - operand typing of every instruction ........... dart  _verify_types / _check_stack_types
#   - block, loop, if: block types, end heights ..... dart  _verify_end_of_block
#   - label typing of br, br_if, br_on_*, catches ... dart  _verify_branch_types, _label_index
#   - br_table: every label of one arity ............ spec  br_table                       (was missing)
#   - select: untyped for numbers, typed for refs ... construction  select picks Select or SelectWithType
#   - local index and type, initialization ......... dart  local_get/set/tee, _local_is_initialized
#   - global index (this module's), set mutability .. dart  global_get/global_set
#   - func index (this module's) ................... dart  call, ref_func
#   - ref.func: the function is in C.refs ........... spec  ModuleBuilder.forceBuild       (was missing)
#   - table index (this module's) .................. dart  table_get/set/fill/size, call_indirect
#   - call_indirect: table 0 exists, holds funcrefs . spec  call_indirect                  (was missing)
#   - memory index (this module's), alignment ....... dart  _add_memory_instruction, each load/store
#   - memarg offset is a u32 ........................ spec  _add_memory_instruction        (was missing)
#   - type index: a type of the module .............. construction  TypesBuilder collects every used type
#   - data index: a segment of this module .......... spec  ModuleBuilder.forceBuild       (was missing)
#   - struct field index; packed get_s/get_u ........ dart  struct_get/get_s/get_u (index located)
#   - struct.set: the field is mutable .............. spec  struct_set                     (was missing)
#   - array packed get_s/get_u, new_data numeric .... dart  array_get/get_s/get_u, array_new_data
#   - array.set, array.fill: element mutable ........ spec  array_set, array_fill          (was missing: 2)
#   - array.copy: dest mutable, source element <: ... spec  array_copy                     (was missing: 2)
#   - casts: target within the input's hierarchy .... dart  _verify_cast
#   - throw, catch: the tag's types ................. dart  throw_, catch_legacy, try_table
#   - throw_ref takes an exnref ..................... spec  throw_ref (dart checks nothing, A45S1) (was missing)
#   - lane immediates below the shape's lanes ....... spec  each *_extract_lane, *_replace_lane (was missing)
#   - i8x16.shuffle: 16 lanes, each below 32 ........ spec  i8x16_shuffle (count: port; index: was missing)
#   - v128.const: 16 bytes .......................... spec  v128_const (added with the refusal cases)
#   - i32.const in i32's range ...................... dart  i32_const
#   - constant expressions: constant instructions ... dart  _add
#   - constant expressions: global.get immutable .... spec  global_get                     (was missing)
#   - a body or constant expression ends ............ spec  InstructionsBuilder.forceBuild (was missing)
#   Types
#   - a declared supertype is a structural one ...... dart  DefType.serializeDefinition (field mutability,
#                                                            storage-type covariance, func contravariance)
#   - a supertype is not final ...................... construction  defining a subtype opens its supertype
#   - supertype and references in this or an earlier rec group .... dart  TypeSection.serializeContents
#   - a rec group is not empty ...................... dart  TypeSection.serializeContents
#   - a tag's function type has no results .......... spec  TagsBuilder.define/import      (was missing)
#   - table limits min <= max ....................... spec  TablesBuilder.define/import    (was missing)
#   - a table's element type is defaultable ......... spec  TablesBuilder.define/import    (was missing)
#   - memory limits min <= max <= 65536 pages ....... spec  MemoriesBuilder.define/import  (was missing)
#   - a shared memory has a maximum ................. dart  Memory's constructor
#   Module
#   - export names are unique ....................... dart  ExportsBuilder.export
#   - import and export names are UTF-8 ............. spec  each import, ExportsBuilder.export (was missing)
#   - the start function is [] -> [] ................ construction  ModuleBuilder.startFunction defines it so
#   - import and export kinds ....................... construction  one builder per kind
#   - a data count section when data is indexed ..... construction  dart writes one with any data segment
#   - data segments: offset in range, memory with offset ...... dart  DataSegmentsBuilder.define
#   - active function segments: a funcref table, index below max ... dart  ElementsBuilder, setFunctionAt
#   - element expressions are constant expressions .. spec  setExpressionAt (flag)         (was missing)
#   - element expressions have the table's type ..... spec  setExpressionAt (its result <: the table's)
#                                                                                        (was missing)
#
# Count: 22 rules missing before; 0 after.

module BuilderValidationTest

using Test
using WasmTarget

const W = WasmTarget.WasmBuilder
const I = W.IR
const i32, i64 = I.NumType_i32, I.NumType_i64

function refusal(f)::String
    try
        f()
        return ""
    catch e
        e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.InvalidModule || rethrow()
        return e.rejection.site
    end
end
accepts(f) = (f(); true)
new_module() = W.ModuleBuilder("m", nothing)
function body_of(mb, inputs = I.ValueType[], outputs = I.ValueType[])
    local f = W.define(mb.functions[], W.define_function(mb.types[], inputs, outputs))
    return W.body(f), f
end
module_bytes(mb) = (s = W.Serializer(); W.serialize(s, W.build(mb)); W.data(s))

@testset "the spec's validation rules the builder refuses beyond dart's checks" begin
    @testset "br_table arity" begin
        local b, _ = body_of(new_module())
        local l0 = W.block(b)
        local l1 = W.block(b, I.ValueType[], I.ValueType[i32])
        W.i32_const(b, 7); W.i32_const(b, 0)
        @test occursin("labels of different arities", refusal(() -> W.br_table(b, W.Label[l0], l1)))
        local ok, _ = body_of(new_module())
        local m0 = W.block(ok); local m1 = W.block(ok)
        W.i32_const(ok, 0)
        @test accepts(() -> W.br_table(ok, W.Label[m0], m1))
    end

    @testset "mutability of struct and array writes" begin
        local mb = new_module()
        local s = W.define_struct(mb.types[], "S"; fields = [I.FieldType(i32; mutable = false), I.FieldType(i32)], brand = false)
        local ro = W.define_array(mb.types[], "RO"; element_type = I.FieldType(i32; mutable = false))
        local rw = W.define_array(mb.types[], "RW"; element_type = I.FieldType(i32))
        local w8 = W.define_array(mb.types[], "W8"; element_type = I.FieldType_i8())
        local b, _ = body_of(mb)
        W.ref_null(b, I.HeapType_none); W.i32_const(b, 1)
        @test occursin("'struct.set' of the immutable field 0", refusal(() -> W.struct_set(b, s, 0)))
        @test accepts(() -> W.struct_set(b, s, 1))
        local b2, _ = body_of(mb)
        W.ref_null(b2, I.HeapType_none); W.i32_const(b2, 0); W.i32_const(b2, 1)
        @test occursin("'array.set' of the immutable array", refusal(() -> W.array_set(b2, ro)))
        local b3, _ = body_of(mb)
        W.ref_null(b3, I.HeapType_none); W.i32_const(b3, 0); W.i32_const(b3, 1); W.i32_const(b3, 2)
        @test occursin("'array.fill' of the immutable array", refusal(() -> W.array_fill(b3, ro)))
        local b4, _ = body_of(mb)
        W.ref_null(b4, I.HeapType_none); W.i32_const(b4, 0); W.ref_null(b4, I.HeapType_none); W.i32_const(b4, 0); W.i32_const(b4, 1)
        @test occursin("'array.copy' into the immutable array", refusal(() -> W.array_copy(b4, ro, rw)))
        @test occursin("whose element is no subtype", refusal(() -> W.array_copy(b4, rw, w8)))
        @test accepts(() -> W.array_copy(b4, rw, ro))
    end

    @testset "call_indirect's table" begin
        local mb = new_module()
        local ft = W.define_function(mb.types[], I.ValueType[], I.ValueType[])
        local b, _ = body_of(mb)
        W.i32_const(b, 0)
        @test occursin("table 0 of a module with no table", refusal(() -> W.call_indirect(b, ft)))
        local xt = W.define(mb.tables[], I.RefType_extern(nullable = true), 1)
        @test occursin("which holds no function references", refusal(() -> W.call_indirect(b, ft, xt)))
        local fnt = W.define(mb.tables[], I.RefType_func(nullable = true), 1)
        @test accepts(() -> W.call_indirect(b, ft, fnt))
    end

    @testset "ref.func names a declared function; array.new_data a segment of this module" begin
        local mb = new_module()
        local b, f = body_of(mb)
        W.ref_func(b, f); W.drop(b); W.var"end"(b)
        @test occursin("which no export, element segment or global initializer declares", refusal(() -> W.build(mb)))
        local ok = new_module()
        local ob, of = body_of(ok)
        W.ref_func(ob, of); W.drop(ob); W.var"end"(ob)
        W.declare(ok.elements[].declarative_segment_builder, of)
        @test !isempty(module_bytes(ok))
        local m2, other = new_module(), new_module()
        local arr = W.define_array(m2.types[], "A"; element_type = I.FieldType_i8())
        local seg = W.define(other.data_segments, UInt8[1])
        local b2, _ = body_of(m2)
        W.i32_const(b2, 0); W.i32_const(b2, 1); W.array_new_data(b2, arr, seg); W.drop(b2); W.var"end"(b2)
        @test occursin("of a data segment of another module", refusal(() -> W.build(m2)))
    end

    @testset "immediates: lanes, shuffle indices, memarg offsets" begin
        local mb = new_module()
        local b, _ = body_of(mb)
        W.v128_const(b, zeros(UInt8, 16))
        @test occursin("of the lane 4, not one of 4", refusal(() -> W.i32x4_extract_lane(b, 4)))
        @test accepts(() -> (W.i32x4_extract_lane(b, 3); W.drop(b)))
        local b2, _ = body_of(mb)
        W.v128_const(b2, zeros(UInt8, 16)); W.v128_const(b2, zeros(UInt8, 16))
        @test occursin("lane index outside 0..31", refusal(() -> W.i8x16_shuffle(b2, [0:14; 32])))
        local mem = W.define(mb.memories[], false, 1)
        local b3, _ = body_of(mb)
        W.i32_const(b3, 0)
        @test occursin("memory offset 4294967296 outside", refusal(() -> W.i32_load(b3, mem, 2^32)))
        @test accepts(() -> (W.i32_load(b3, mem, 2^32 - 1); W.drop(b3)))
    end

    @testset "constant expressions" begin
        local mb = new_module()
        local mutable_g = W.define(mb.globals[], I.GlobalType(i32))
        local fixed_g = W.define(mb.globals[], I.GlobalType(i32; mutable = false))
        local g = W.define(mb.globals[], I.GlobalType(i32))
        @test occursin("of the mutable global", refusal(() -> W.global_get(g.initializer, mutable_g)))
        local g2 = W.define(mb.globals[], I.GlobalType(i32))
        @test accepts(() -> (W.global_get(g2.initializer, fixed_g); W.var"end"(g2.initializer)))
        local b, _ = body_of(new_module())
        W.nop(b)
        @test occursin("built before their final 'end'", refusal(() -> W.build(b)))
        local tab_m = new_module()
        local tab = W.define(tab_m.tables[], I.RefType_func(nullable = true), 1)
        local init, _ = body_of(tab_m)              # a function body, not a constant expression
        local seg = W.active_expression_segment_builder_for(tab_m.elements[], tab)
        @test occursin("is not a constant expression", refusal(() -> W.set_expression_at(seg, 0, init)))
    end

    @testset "tags, tables and memories as they are defined or imported" begin
        local mb = new_module()
        local returns = W.define_function(mb.types[], I.ValueType[], I.ValueType[i32])
        @test occursin("whose results are not empty", refusal(() -> W.define(mb.tags[], returns)))
        @test occursin("whose results are not empty", refusal(() -> W.var"import"(mb.tags[], "env", "t", returns)))
        @test occursin("table limits 2..1", refusal(() -> W.define(mb.tables[], I.RefType_func(nullable = true), 2, 1)))
        @test occursin("non-defaultable", refusal(() -> W.define(mb.tables[], I.RefType_func(nullable = false), 1)))
        @test occursin("memory limits 65537", refusal(() -> W.define(mb.memories[], false, 65537)))
        @test occursin("memory limits 2..1", refusal(() -> W.var"import"(mb.memories[], "env", "m", false, 2, 1)))
        @test accepts(() -> W.define(mb.memories[], false, 1, 65536))
    end

    @testset "names are UTF-8" begin
        local mb = new_module()
        local ft = W.define_function(mb.types[], I.ValueType[], I.ValueType[])
        local bad = String(UInt8[0x66, 0xff])
        @test occursin("is not valid UTF-8", refusal(() -> W.var"import"(mb.functions[], "env", bad, ft)))
        local _, f = body_of(mb)
        @test occursin("is not valid UTF-8", refusal(() -> W.var"export"(mb.exports, bad, f)))
        @test accepts(() -> W.var"export"(mb.exports, "f", f))
    end

    @testset "throw_ref takes an exnref" begin
        local b, _ = body_of(new_module())
        @test occursin("Underflowing base stack", refusal(() -> W.throw_ref(b)))
        local b2, _ = body_of(new_module())
        W.i32_const(b2, 0)
        @test occursin("Expected [exnref]", refusal(() -> W.throw_ref(b2)))
        local ok, _ = body_of(new_module())
        local e = W.add_local(ok, I.RefType_exn(nullable = true))
        @test accepts(() -> (W.local_get(ok, e); W.throw_ref(ok); W.var"end"(ok)))
    end

    @testset "an element expression yields the table's element type" begin
        local mb = new_module()
        local tab = W.define(mb.tables[], I.RefType_func(nullable = true), 2)
        local seg = W.active_expression_segment_builder_for(mb.elements[], tab)
        local wrong = W.InstructionsBuilder(mb, I.ValueType[], I.ValueType[I.RefType_i31(nullable = true)]; constant_expression = true)
        @test occursin("yields [i31ref], not one funcref", refusal(() -> W.set_expression_at(seg, 0, wrong)))   # still open
        W.ref_null(wrong, I.HeapType_none); W.var"end"(wrong)
        @test occursin("yields [i31ref], not one funcref", refusal(() -> W.set_expression_at(seg, 0, wrong)))   # complete
        local right = W.InstructionsBuilder(mb, I.ValueType[], I.ValueType[I.RefType_func(nullable = true)]; constant_expression = true)
        W.ref_null(right, I.HeapType_nofunc); W.var"end"(right)
        @test accepts(() -> W.set_expression_at(seg, 1, right))
    end
end

# A45S3: a forward declaration's one subtype, a parametric subtype elsewhere included
module ForwardEscape
using WasmTarget
struct Elsewhere{T} <: WasmTarget.AbstractModuleBuilder end
end
@testset "a forward declaration's one subtype, read in every loaded module" begin
    local why = try
        WasmTarget.check_forward(WasmTarget.AbstractModuleBuilder, W.ModuleBuilder, WasmTarget); ""
    catch e
        e isa WasmTarget.ConstructionViolation ? e.what : rethrow()
    end
    @test occursin("Elsewhere subtypes it", why)
end

end # module BuilderValidationTest
