# dart2wasm's constants.dart, ported (src/constants.jl): the constants Julia's objects force, each module run against
# native Julia: a Module constant, a Dict's and an Array's memory as their owners define it, arrays past
# maxArrayNewFixedLength (split from test/src/constants.jl, every testset verbatim; its other half is
# test/src/constants_values.jl).

# a Module constant: an instance constant of its class (src/julia/classes.jl _module_instance_fields),
# its one field the module's name, the Symbol Julia's `nameof` reads (jl_module_t's name); two modules
# through a phi, so Julia folds no `===`, each its own canonical constant, run against native
module ModuleConstants
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
which_module(x::Int64) = (x > 0 ? Base : Core) === Base ? Int64(1) : Int64(2)
@testset "constants.dart: a Module constant is its class's struct, its name its one field" begin
    @test Base.code_typed(which_module, (Int64,))[1][2] === Int64
    # each module a constant, its name, the Symbol, a sub-constant of it
    local D = WasmTarget.Dart2Wasm
    local t = D.Translator(WasmTarget.build_nir(WasmTarget.check_subset(which_module, (Int64,), "constants", Base.get_world_counter()), "constants"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    D.translate(t, nothing)
    local made = t.constants[].constant_info
    @test all(m -> haskey(made, WasmTarget.NirConst(Core.Const(m))), (Base, Core, :Base, :Core))
    local cases = reduce(vcat, [first(WTChild.answer_cases("module constant $x", WasmTarget.compile, which_module, (x,))) for x in (Int64(1), Int64(-1))])
    local results = WTChild.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test !isempty(results) && all(r -> r.ok, results)
end

# spec v15 W3: a Dict constant's unfilled slots hold no defined element, so its module is a function of its live pairs
# alone: one function over one Dict constant compiled, then the bytes in the Dict's unfilled `vals` slots changed (as a
# process's heap leaves them, addresses among them: v14/v7/dictvals2.out), then compiled again: byte-identical modules
const _DICT_CONST = Dict("a" => 1, "bb" => 2, "ccc" => 3)
_dict_const_bb() = _DICT_CONST["bb"]
@testset "a Dict constant's unfilled slots: its live elements alone (spec v15 W3)" begin
    local before = WasmTarget.compile(_dict_const_bb, ())
    local before_plain = WasmTarget.compile(_dict_const_bb, (); optimize = false)
    local dead = [i for i in eachindex(_DICT_CONST.vals) if !Base.isslotfilled(_DICT_CONST, i)]
    @test !isempty(dead)
    for i in dead
        _DICT_CONST.vals[i] = 4_650_992_688 + i   # heap bytes, an address among them
    end
    @test WasmTarget.compile(_dict_const_bb, ()) == before
    @test WasmTarget.compile(_dict_const_bb, (); optimize = false) == before_plain
    local results = Main.WTChild.run_cases([Main.WTChild.RunCase("dict_const_bb", before, (), _dict_const_bb())])
    @test all(r -> r.ok, results)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
end

# an isbits union's memory Julia always allocates zeroed (datatype.c:551 zi = 1, genericmemory.c:71 memset), so a Dict
# constant's unfilled slots of an isbits-union key type hold the value a zeroed allocation reads: its module is a
# function of its live pairs alone, the dead keys rewritten (as a delete! leaves the deleted key) byte-identical
const _DICT_UNION_CONST = Dict{Union{Int64,Float64},String}(1 => "a", 2 => "b", 3 => "c")
_dict_union_const(x::Int64) = Int64(_DICT_UNION_CONST == Dict{Union{Int64,Float64},String}(x => "a", 2 => "b", 3 => "c"))
@testset "a Dict constant of an isbits-union key: its unfilled slots are a zeroed allocation's" begin
    @test (Memory{Union{Int64,Float64}}.flags & 0x0010) == 0x0010   # julia.h:619 zeroinit
    local before = WasmTarget.compile(_dict_union_const, (Int64,))
    local dead = [i for i in eachindex(_DICT_UNION_CONST.keys) if !Base.isslotfilled(_DICT_UNION_CONST, i)]
    @test !isempty(dead)
    for i in dead
        _DICT_UNION_CONST.keys[i] = isodd(i) ? 7.5 : Int64(4_650_992_688 + i)
    end
    @test WasmTarget.compile(_dict_union_const, (Int64,)) == before
    local results = Main.WTChild.run_cases([Main.WTChild.RunCase("dict_union_const $x", before, (x,), _dict_union_const(x)) for x in (Int64(1), Int64(5))])
    @test all(r -> r.ok, results)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
end

# spec v16 X5: the constants' `C<id>` names are the compile's (a Translator field), so a module's bytes, its name section
# among them, are the same whatever the process compiled before it
_counter_g(x::Int64) = string(x) * "!"
@testset "a module's bytes are its own compile's: the constants' counter is the translator's" begin
    local first_ = WasmTarget.compile(_dict_const_bb, ())
    WasmTarget.compile(_counter_g, (Int64,))   # another program, its own constants named
    @test WasmTarget.compile(_dict_const_bb, ()) == first_
end

# spec v17 Y6: a constant's memory is its owner's to define (src/julia/classes.jl MEMORY_OWNERS: an Array's size, a Dict's
# filled slots); an isbits memory reached through no owner (a bare Memory, IOBuffer's data) is refused, located, never
# emitted with every element's bytes; an empty one, and a boxed one (#undef the null), are held whole
const _BARE_BITS = let m = Memory{Int64}(undef, 3); m[1] = 1; m[3] = 3; m end   # its second element: whatever bytes
_bare_bits(i::Int64) = _BARE_BITS[i]
const _BUFFER = IOBuffer(UInt8[0x61, 0x62])
_buffer(i::Int64) = Int64(_BUFFER.data[i])
const _BARE_EMPTY = Memory{Int64}(undef, 0)
_bare_empty(i::Int64) = Int64(length(_BARE_EMPTY)) + i
@testset "a constant's isbits memory is its owner's to define, else refused, located (spec v17 Y6)" begin
    local refusal(f) = try; WasmTarget.compile(f, (Int64,)); nothing; catch x; x isa WasmTarget.RejectionError ? x.rejection : rethrow(); end
    for f in (_bare_bits, _buffer)
        local r = refusal(f)
        @test r isa WasmTarget.ProgramError && occursin("reached through no owner MEMORY_OWNERS lists", r.text)
    end
    @test refusal(_bare_empty) === nothing
    @test WasmTarget.MEMORY_OWNERS isa Tuple && all(o -> o[1] isa Type && o[2] isa String, WasmTarget.MEMORY_OWNERS)
end

# spec v16 X5: an Array constant's memory past its size (a capacity tail sizehint! reserved, the bytes pop! left for an
# isbits element) holds no defined element: the module carries its size's elements alone, whatever the tail holds
const _VEC_TAIL = let v = UInt64[11, 22, 33]; sizehint!(v, 16); push!(v, 0x0123456789abcdef); pop!(v); v end
_vec_tail(i::Int64) = _VEC_TAIL[i] + UInt64(length(_VEC_TAIL))
const _VEC_SHARED = UInt64[1, 2, 3, 4]
const _VEC_PART = Base.wrap(Array, getfield(_VEC_SHARED, :ref).mem, (2,))   # its first two elements, the same memory
_vec_shared(i::Int64) = _VEC_SHARED[i] + _VEC_PART[1]
const _VEC_TAIL2 = let v = UInt64[5, 6]; sizehint!(v, 8); v end
const _VEC_ALIAS = Base.wrap(Array, getfield(_VEC_TAIL2, :ref).mem, (2,))   # the same memory, the same size
_vec_alias(i::Int64) = (_VEC_ALIAS[1] = UInt64(i); _VEC_TAIL2[1])
@testset "an Array constant's memory past its size: its size's elements alone (spec v16 X5)" begin
    local mem = getfield(_VEC_TAIL, :ref).mem
    @test length(mem) >= 16 && mem[4] == 0x0123456789abcdef   # the popped element's bytes, in the tail
    local before = WasmTarget.compile(_vec_tail, (Int64,))
    for k in 4:length(mem)
        mem[k] = 0x5a5a5a5a00000000 + UInt64(k)   # the tail as another process's heap leaves it
    end
    @test WasmTarget.compile(_vec_tail, (Int64,)) == before
    @test all(r -> r.ok, Main.WTChild.run_cases([Main.WTChild.RunCase("vec_tail$i", before, (Int64(i),), _vec_tail(Int64(i))) for i in 1:3]))
    # two Arrays of one Memory and different sizes: one constant cannot hold each one's elements, refused, located
    local refused = try; WasmTarget.compile(_vec_shared, (Int64,)); nothing; catch x; x isa WasmTarget.RejectionError ? x.rejection : rethrow(); end
    @test refused isa WasmTarget.ProgramError && occursin("one constant cannot hold", refused.text)
    # two of one Memory and one size share its one copy: a write through one is read through the other, as natively
    local alias = WasmTarget.compile(_vec_alias, (Int64,))
    @test all(r -> r.ok, Main.WTChild.run_cases([Main.WTChild.RunCase("vec_alias", alias, (Int64(9),), Int64(9))]))
end
end

# dart's _makeWasmArrayLiteral past maxArrayNewFixedLength (10,000 entries): an i16 or i32 array is initialised from the
# passive data segment, each entry its integer's bits, little-endian (dart's Uint16List and Uint32List); any other
# storage (an i8, i64 or f64 array) is dart's array.new of its commonest entry and array.set or array.fill of the
# rest; at 10,000 or fewer, array.new_fixed. Each constant Vector read at its first, a middle and its last index
# against native, at 10,000 and 10,001 entries alike, and each data segment's bytes the elements' own.
module LargeConstantArrays
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
const D = WasmTarget.Dart2Wasm
const U16 = UInt16[(k * 40503) % 65536 for k in 1:46592]              # utf8proc's stage-2 length
const I16 = Int16[(k * 40503) % 65536 - 32768 for k in 1:12000]       # negative entries among them
const I32 = Int32[(k * 2654435761) % 4294967296 - 2147483648 for k in 1:12000]
const U32 = UInt32[(k * 2654435761) % 4294967296 for k in 1:12000]
const CHR = Char[Char(k % 0xd800) for k in 1:12000]                   # a Char's bits, its UTF-8 encoding
const U8 = UInt8[k % 251 for k in 1:12000]                            # i8: dart's array.new and array.set path
const I64 = Int64[k * 1_000_003 - 6_000_000_000 for k in 1:12000]      # i64: the same
const F64 = Float64[k / 7 for k in 1:12000]                           # f64: the same
const AT = UInt16[(k * 7919) % 65536 for k in 1:10000]                 # array.new_fixed, the limit itself
const PAST = UInt16[(k * 7919) % 65536 for k in 1:10001]               # the data segment, one past it
# entry i of array k as an Int64 (a Float64's bits)
function rd(k::Int64, i::Int64)::Int64
    k == 1 && return Int64(U16[i])
    k == 2 && return Int64(I16[i])
    k == 3 && return Int64(I32[i])
    k == 4 && return Int64(U32[i])
    k == 5 && return Int64(reinterpret(UInt32, CHR[i]))
    k == 6 && return Int64(U8[i])
    k == 7 && return I64[i]
    k == 8 && return reinterpret(Int64, F64[i])
    k == 9 && return Int64(AT[i])
    return Int64(PAST[i])
end
const LENGTHS = (46592, 12000, 12000, 12000, 12000, 12000, 12000, 12000, 10000, 10001)
# the first, a middle and the last entry, summed
sum3(k::Int64, n::Int64) = rd(k, Int64(1)) + rd(k, n ÷ 2) + rd(k, n)
u16(i::Int64) = Int64(U16[i])
# translated standalone, as WasmTarget.compile translates: a read that can throw BoundsError needs its stack trace class
translated(f) = (o = D.TranslatorOptions(; standalone = true);
    t = D.Translator(WasmTarget.build_nir(WasmTarget.check_subset(f, (Int64,), "constants", Base.get_world_counter()), "constants"),
    D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), o); D.translate(t, nothing); t)
@testset "constants.dart: a constant array past maxArrayNewFixedLength, each element kind, run against native" begin
    @test any(<(0), I16) && any(<(0), I32) && length(AT) == D.max_array_new_fixed_length()
    # each function one program, its two modules; sum3 at each array's length, rd at each index it sums
    local cases = WTChild.RunCase[]
    for (f, argsets) in ((sum3, [(k, n) for (k, n) in enumerate(LENGTHS)]),
                         (rd, [(k, i) for (k, n) in enumerate(LENGTHS) for i in (1, n ÷ 2, n)]))
        local own = WasmTarget.compile(f, (Int64, Int64))
        local plain = WasmTarget.compile(f, (Int64, Int64); optimize = false)
        for a in argsets
            push!(cases, WTChild.RunCase("$(nameof(f))$a", plain, Int64.(a), WTChild.native_answer(f, Int64.(a)); optimized = own))
        end
    end
    @test I16[12000 ÷ 2] < 0   # a negative Int16 among the entries read
    local results = WTChild.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == length(cases) && all(r -> r.ok, results)
    # the 46,592-entry UInt16 table is one data segment of its 93,184 bytes, little-endian, read by array.new_data
    local t = translated(u16)
    local seg = only(values(t.constants[]._byte_segments))
    local bytes = Vector{UInt8}(reinterpret(UInt8, htol.(U16)))
    @test length(bytes) == 93184 && seg.content == bytes
end
end
