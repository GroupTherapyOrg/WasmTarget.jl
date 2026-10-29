# String's operations against native Julia (the String ruling, src/julia/classes.jl
# _string_instance_fields; its operations by overlay over dart:_wasm's array operations,
# src/julia/wasm_array.jl): code unit reads, length against ncodeunits on non-ASCII text, == and
# concatenation. Each case either compiles and answers as native Julia, both modules, or rejects at
# a definition not yet written, Unported or Unquarantined, located: it flips to the differential when
# the code generator's lowerings and the overlays land, and never passes on a wrong answer.
using Test, WasmTarget
isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))

module StringOpCases
cu(i::Int64) = UInt32(codeunit("héllo", i))                          # the code unit at a byte index
lens(b::Bool) = (s = b ? "héllo" : "日本"; Int64(length(s)) * 100 + ncodeunits(s))   # characters against bytes
eq(b::Bool) = (b ? "abc" : "abd") == "abc"                            # ==, Julia's egal on two Strings
cat3(b::Bool) = UInt32(codeunit((b ? "hé" : "x") * "llo", 4))       # a code unit of a concatenation
end

const STRING_OP_CASES = (
    ("cu", StringOpCases.cu, (Int64(3),)), ("cu", StringOpCases.cu, (Int64(1),)),
    ("lens", StringOpCases.lens, (true,)), ("lens", StringOpCases.lens, (false,)),
    ("eq", StringOpCases.eq, (true,)), ("eq", StringOpCases.eq, (false,)),
    ("cat3", StringOpCases.cat3, (true,)), ("cat3", StringOpCases.cat3, (false,)))

@testset "String's operations against native Julia" begin
    local runs = Main.WTRunner.RunCase[]
    for (name, f, args) in STRING_OP_CASES
        local label = "string_ops/$name$args"
        local cases = try
            Main.WTRunner.answer_cases(label, WasmTarget.compile, f, args, f(args...))
        catch e
            e isa WasmTarget.RejectionError || rethrow()
            # not yet compiling: a located rejection at a definition not yet written
            @test e.rejection isa Union{WasmTarget.Unported,WasmTarget.Unquarantined}
            nothing
        end
        cases === nothing || append!(runs, cases)
    end
    for r in (isempty(runs) ? Main.WTRunner.RunResult[] : Main.WTRunner.run_cases(runs))
        @test (r.label => r.why) == (r.label => "")
    end
end

# each String operation reaches dart:_wasm's array operations through src/patch/string.jl's overlays,
# never Base's pointer forms: its closed world calls the operation on the String's data
@testset "String's operations reach its data through the overlays" begin
    local reached(f, T) = Set{Symbol}(Core.Compiler.get_ci_mi(x).def.name for x in WasmTarget.check_subset(f, T, "string_ops").codeinfos
                                      if x isa Core.CodeInstance)
    @test :wasm_string_codeunit in reached(StringOpCases.cu, (Int64,))
    @test :wasm_string_length in reached(StringOpCases.lens, (Bool,))
    @test [:wasm_string_alloc, :wasm_string_copy!] ⊆ reached(StringOpCases.cat3, (Bool,))
end
