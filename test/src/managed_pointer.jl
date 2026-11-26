# A Ptr is a managed pointer (src/julia/classes.jl managed_pointer): its base, the data array it points into, and
# its byte offset. A MemoryRef's ptr_or_offset and a Memory's ptr read as Julia's element address
# (src/code_generator.jl memoryref_address, memory_address; src/intrinsics.jl element_address), a bitcast keeps the
# base, add_ptr and sub_ptr move the offset, === compares base and offset, and Base's ==, < and - of two pointers
# answer over the parts (src/patch/pointer.jl). Each function against native Julia: equality of one array's
# addresses and of two arrays', the stride of an element's address (bits, boxed, union and inline elements), the
# null pointer against an element's address, an integer address's identity, a struct holding a Ptr and a boxed Ptr
# compared by === (jl_egal), and a based pointer read as an integer address, the fatal gap (audit A124E2).
module ManagedPointerTest

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "codegen_helpers.jl"))

module PointerCases
function same_and_distinct(n::Int64)::Int64
    local a = collect(1:n); local b = collect(1:n)
    return Int64(pointer(a) == pointer(b)) + 2 * Int64(pointer(a) == pointer(a)) + 4 * Int64(pointer(a, 2) == pointer(a) + 8)
end
function stride(v, n::Int64)::Int64
    GC.@preserve v begin
        local p = Base.unsafe_convert(Ptr{Nothing}, memoryref(v.ref, n))
        local q = Base.unsafe_convert(Ptr{Nothing}, memoryref(v.ref, 1))
        return Int64(p - q) * 10 + Int64(q < p) + 2 * Int64(p == q + (n - 1) * Base.elsize(v))
    end
end
i64_stride(n::Int64) = stride(collect(1:5), n)
any_stride(n::Int64) = stride(Any[1, 2, 3, 4, 5], n)
union_stride(n::Int64) = stride(Union{Int64,Nothing}[1, nothing, 3, 4, 5], n)
tuple_stride(n::Int64) = stride(Tuple{Int64,String}[(1, "a"), (2, "b"), (3, "c"), (4, "d"), (5, "e")], n)
function null_against(n::Int64)::Int64
    local v = collect(1:n)
    return Int64(pointer(v) == C_NULL) + 2 * Int64(C_NULL < pointer(v)) + 4 * Int64(pointer(v) < C_NULL)
end
# an integer address built at run time (a constant one other than C_NULL is a host address, refused: src/constants.jl)
integer_address(n::Int64) = Int64(Ptr{Nothing}(UInt64(n)) === Ptr{Nothing}(UInt64(n + 0))) + 2 * Int64(UInt(Ptr{Int64}(UInt64(n)) + 8)) + 4 * Int64(Ptr{Nothing}(UInt64(n)) === C_NULL)
empty_memories(n::Int64) = Int64(pointer(Memory{Int64}(undef, n)) == pointer(Memory{Int64}(undef, n)))
# a pointer into an array read as an integer address: natively its address, in a module the located gap that ends
# the program (src/intrinsics.jl, the fatal arm), its catch never run
address_of(n::Int64)::Int64 = Int64(UInt(pointer(collect(1:n))) % UInt(7)) + 1
address_of_try(n::Int64)::Int64 = (try; address_of(n); catch; Int64(-5); end)
# a Ptr held in a struct and in Any, compared by === through jl_egal: the class arm compares the Ptr field, a managed
# pointer's base by ref.eq and its offset
struct PtrBox
    p::Ptr{Int64}
end
function boxed_egal(n::Int64)::Int64
    local a = collect(1:n); local b = collect(1:n)
    GC.@preserve a b begin
        local xs = Any[PtrBox(pointer(a)), PtrBox(pointer(a)), PtrBox(pointer(b)), PtrBox(pointer(a, 2)), pointer(a), pointer(a), pointer(b)]
        return Int64(xs[1] === xs[2]) + 2 * Int64(xs[1] === xs[3]) + 4 * Int64(xs[1] === xs[4]) +
               8 * Int64(xs[5] === xs[6]) + 16 * Int64(xs[5] === xs[7]) + 32 * Int64(xs[1] === xs[5])
    end
end
end

@testset "a managed pointer: a MemoryRef's ptr_or_offset and a Memory's ptr, compared and strided, against native" begin
    local P = PointerCases
    for (name, f, xs) in (("same_and_distinct", P.same_and_distinct, [1, 3]), ("i64_stride", P.i64_stride, [1, 3, 5]),
                          ("any_stride", P.any_stride, [1, 4]), ("union_stride", P.union_stride, [1, 2, 5]),
                          ("tuple_stride", P.tuple_stride, [1, 3]), ("null_against", P.null_against, [2]),
                          ("integer_address", P.integer_address, [3, 4]), ("empty_memories", P.empty_memories, [0]))
        queue_native!(name, W.compile(f, (Int64,); optimize = false), f, [(x,) for x in xs])
    end
end

@testset "jl_egal of a struct holding a Ptr and of a boxed Ptr: base by ref.eq, then offset, both modules, against native" begin
    for x in (2, 3)
        push!(NATIVE_RUNS, WTChild.compiled_case("boxed_egal($x)", W.compile, PointerCases.boxed_egal, (Int64(x),)))
    end
end

# the located gap: a module reports the rejection's row through the standalone embedder's print, then traps, and the
# program's catch never runs, unoptimized and optimized; the row read as the climb reads a rejection
# (dev/climb/core.py UNPORTED_RE), the embedder's imports as test/runner.jl gives them (as test/src/js_string.jl does)
@testset "intrinsics.jl: a based pointer read as an integer address is the fatal gap, reported then trapped, both modules" begin
    local helper = match(r"Buffer\.from\(\s*'([A-Za-z0-9+/=]+)', 'base64'\)", read(joinpath(@__DIR__, "..", "runner.jl"), String)).captures[1]
    @test PointerCases.address_of(Int64(3)) isa Int64
    for f in (PointerCases.address_of, PointerCases.address_of_try), optimize in (false, true)
        local name = string(nameof(f))
        local path = tempname() * ".wasm"
        write(path, W.compile(f, (Int64,); optimize = optimize))
        local script = "(async () => { const m = await WebAssembly.compile(require('fs').readFileSync(process.argv[1]), {builtins: ['js-string'], importedStringConstants: ''}); " *
            "const h = new WebAssembly.Instance(new WebAssembly.Module(Buffer.from(process.argv[2], 'base64'), {builtins: ['js-string']}), {}); " *
            "const dart = {stackTraceGetCurrent: () => new Error().stack, stackTraceToString: (t) => String(t), " *
            "stringFromAsciiBytes: (a, s, l) => h.exports.stringFromAsciiBytes(a, s, l), print: (l) => console.log(String(l))}; " *
            "const i = await WebAssembly.instantiate(m, {dart}); try { console.log('answered ' + i.exports.$name(3n)); } catch (e) { console.log(e instanceof WebAssembly.RuntimeError ? 'trapped' : 'not a trap'); } })()"
        local lines = readlines(`perl -e 'alarm 60; exec @ARGV' node -e $script $path $helper`)
        @test length(lines) == 2 && lines[end] == "trapped"
        local row = isempty(lines) ? nothing : match(r"unported: the (dart|Julia-only) definition (.*)", lines[1])
        @test row !== nothing && row.captures[1] == "Julia-only" &&
              startswith(row.captures[2], "src/intrinsics.jl generateStaticIntrinsic: a pointer into a wasm array read as an integer address")
        (length(lines) == 2 && lines[end] == "trapped") || println(name, " optimize = ", optimize, ": ", lines)
        rm(path)
    end
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTChild.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end

end
