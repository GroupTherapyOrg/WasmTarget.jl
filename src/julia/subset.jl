# The strict subset (dev/MARCH.md 1.A7; ledger D32): WasmTarget compiles exactly what Julia's own trim
# verifier accepts over Julia's unmodified Base, and never re-guesses it; outside it, a located
# rejection. It is strictly smaller than what `juliac --trim=safe` compiles: juliac verifies after
# patching Base and the stdlibs (juliac/juliac-trim-base.jl, juliac-trim-stdlib.jl: depwarn, stdio and
# the active project stubbed out), which WasmTarget does not do. A compile
# infers its program once, here, as trimming does: Core.Compiler's typeinf_ext_toplevel in TRIM_UNSAFE
# mode over the closed world one entry reaches. Julia's TrimVerifier then judges what it inferred: an
# error rejects the program as OutsideSubset with Julia's own text, which names the statement and its
# stacktrace; a warning is a note, as juliac treats it ("errors are fatal, warnings are not",
# verify_typeinf_trim). Nothing else in src infers or asks Julia for typed code.

# The token only this file holds: ClosedWorld's sole constructor takes it, so no code outside this file
# makes a ClosedWorld (construction_check(::Val{:ClosedWorld}), below).
@quarantine "Julia has no private constructors; an unexported token held by this file alone stands in for one" Core.DataType struct _SubsetToken
    _SubsetToken() = new()
end

"""
    ClosedWorld

The program a compile has once Julia's trim verifier accepts it: `codeinfos`, what
`typeinf_ext_toplevel` returned, a `Core.CodeInstance` followed by its `Core.CodeInfo` for every
function the entry reaches, inferred once; `notes`, the verifier's warnings in Julia's text.

A typestate by construction: its one constructor takes the token `_SubsetToken`, which only this
file holds, and `check_subset` is its only caller, so every stage after the subset check takes a
`ClosedWorld` and none can be reached by a program Julia's verifier did not accept.

precedent(rust: typestate with a private constructor, the value made by one function of its module).
Julia's differs: it has no private constructors, so the sole constructor and the token's are checked
by reflection when the package loads (check_sole_constructor).
"""
@quarantine "Julia's trim inference returns the closed world as an untyped list of CodeInstance and CodeInfo pairs" Core.Any struct ClosedWorld
    codeinfos::Vector{Any}
    notes::Vector{String}
    ClosedWorld(::_SubsetToken, codeinfos::Vector{Any}, notes::Vector{String}) = new(codeinfos, notes)
end

# Julia's closed-world inference for trimming, from the entry's MethodInstance at `world`. Julia 1.13
# adds external_linkage: false, so every body the entry reaches is inferred and none is taken as
# already compiled into a package image (WasmTarget compiles every body to wasm).
@quarantine "the closed world is inferred by Julia's trim mode, whose entry point changed arity in 1.13" Core.Compiler.typeinf_ext_toplevel function _trim_infer(mi::Core.MethodInstance, world::UInt)::Vector{Any}
    @static if VERSION >= v"1.13-"
        return Core.Compiler.typeinf_ext_toplevel(Any[mi], UInt[world], Core.Compiler.TRIM_UNSAFE, false)
    else
        return Core.Compiler.typeinf_ext_toplevel(Any[mi], UInt[world], Core.Compiler.TRIM_UNSAFE)
    end
end

# The MethodInstance Julia compiles for the entry `sig` at `world`: its compileable specialization, the
# signature Julia generates code for (an argument marked @nospecialize widened to its declared type, a
# Vararg's count dropped), as juliac takes an entrypoint (Base.Experimental.entrypoint: 1.13's
# jl_get_compile_hint_specialization, the call Compiler/src/precompile.jl's add_entrypoint makes; 1.12's
# compileable_specialization_for_call, which its trim inference and verifier use); nothing when Julia
# names none.
@quarantine "the entry is the specialization Julia compiles for it, its compileable signature, as juliac's entrypoint takes it" Core.Compiler.compileable_specialization_for_call function _entry_specialization(@nospecialize(sig::Type), world::UInt)::Union{Nothing,Core.MethodInstance}
    @static if VERSION >= v"1.13-"
        return ccall(:jl_get_compile_hint_specialization, Any, (Any, Csize_t, Cint), sig, world, 1)
    else
        return Core.Compiler.compileable_specialization_for_call(Core.Compiler.NativeInterpreter(world), sig)
    end
end

# One verifier error or warning in Julia's own words: its statement and stacktrace, as
# `juliac --trim` prints it (verify_print_error writes to an IOContext{IO}).
@quarantine "the verifier's text is Julia's, printed by its own verify_print_error" Core.Compiler.TrimVerifier.verify_print_error function _verifier_text(desc, parents)::String
    return sprint(io -> Core.Compiler.TrimVerifier.verify_print_error(IOContext{IO}(io), desc, parents))
end

"""
    check_subset(f, argtypes::Tuple, at::String) -> ClosedWorld

Infer the program `f(argtypes...)` once, as Julia's trimming does, from the specialization Julia
compiles for that call (`_entry_specialization`), and let Julia's trim verifier judge it. Returns the
closed world it accepts; rejects with `OutsideSubset`, Julia's text, when the entry has no unique method
(Julia's `which` text) or no compileable specialization, or the verifier reports an error, each
numbered as juliac numbers them.
"""
@quarantine "the strict subset is the one Julia's trim verifier accepts over unmodified Base, never re-guessed" Core.Compiler.TrimVerifier.get_verify_typeinf_trim function check_subset(@nospecialize(f), argtypes::Tuple, at::String)::ClosedWorld
    local sig = Base.signature_type(f, argtypes)
    local world = Base.get_world_counter()
    local mi = _entry_specialization(sig, world)
    if mi === nothing
        # Julia's own words when the call has no unique method; otherwise it has one Julia compiles none for
        try
            Base._which(sig; world = world)
        catch e
            e isa ErrorException || rethrow()
            reject!(OutsideSubset(sprint(showerror, e)), at)
        end
        reject!(OutsideSubset("$sig: Julia gives the call no compileable specialization"), at)
    end
    local codeinfos = _trim_infer(mi, world)
    local errors, parents = Core.Compiler.TrimVerifier.get_verify_typeinf_trim(codeinfos)
    local fatal = String[]; local notes = String[]
    for (warn, desc) in errors
        warn ? push!(notes, "Verifier warning #$(length(notes) + 1): " * _verifier_text(desc, parents)) :
               push!(fatal, "Verifier error #$(length(fatal) + 1): " * _verifier_text(desc, parents))
    end
    isempty(fatal) || reject!(OutsideSubset(rstrip(join(fatal))), at)
    return ClosedWorld(_SubsetToken(), codeinfos, notes)
end

# the typestate's assertion, run when the package loads: ClosedWorld and its token each have one
# constructor method, both in this file, ClosedWorld's taking the token (a construction, L220); and
# its next state, src/julia/nir.jl's NirWorld, which build_nir makes from a ClosedWorld, the same
@quarantine "the typestate's assertion, run when the package loads" Base.Val construction_check(::Val{:ClosedWorld})::Int =
    check_sole_constructor(ClosedWorld, _SubsetToken, @__FILE__) +
    check_sole_constructor(NirWorld, _NirToken, joinpath(@__DIR__, "nir.jl"))

# no method of WasmTarget but check_subset names the token or makes either: read in every method's
# lowered code when the package loads. A stopgap, not a construction (L224): Julia has no module
# privacy, so the wrong choice stays writable and this read finds it (A36S3, A37S1, A38)
@quarantine "Julia has no module privacy; WasmTarget's own lowered code is read when the package loads" Base.moduleroot check_closed_world_makers()::Int =
    check_sole_maker(Base.moduleroot(@__MODULE__), ClosedWorld, _SubsetToken, (only(methods(check_subset)),),
                     (which(check_closed_world_makers, Tuple{}), which(construction_check, Tuple{Val{:ClosedWorld}})),
                     (joinpath(@__DIR__, "parity.jl"), joinpath(@__DIR__, "construction.jl")))
