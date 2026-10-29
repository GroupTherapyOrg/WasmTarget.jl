# The strict subset (dev/MARCH.md 1.A7; ledger D32): WasmTarget compiles exactly what Julia's own trim
# verifier accepts over Julia's unmodified Base, and never re-guesses it; outside it, a located
# rejection. It is strictly smaller than what `juliac --trim=safe` compiles: juliac verifies after
# patching Base and the stdlibs (juliac/juliac-trim-base.jl, juliac-trim-stdlib.jl: depwarn, stdio and
# the active project stubbed out), which WasmTarget does not do. A compile
# infers its program once, here, as trimming does: Core.Compiler's typeinf_ext_toplevel in TRIM_UNSAFE
# mode over the closed world one entry reaches. Julia's TrimVerifier then judges what it inferred: an
# error rejects the program as OutsideSubset, keeping Julia's own record of it with its statement and
# stack frames (shown in Julia's text); a warning is a note, as juliac treats it ("errors are fatal, warnings are not",
# verify_typeinf_trim). Nothing else in src infers or asks Julia for typed code.

# The token only this file holds: ClosedWorld's sole constructor takes it, so no code outside this file
# makes a ClosedWorld (construction_check(::Val{:ClosedWorld}), below).
@quarantine "Julia has no private constructors; an unexported token held by this file alone stands in for one" Core.DataType struct _SubsetToken
    _SubsetToken() = new()
end

"""
    ClosedWorld

The program a compile has once Julia's trim verifier accepts it: `entry`, the MethodInstance the
trim inference was asked for (dart's Component.mainMethod; Julia's compile-hint specialization of the
call); `codeinfos`, what `typeinf_ext_toplevel` returned, a `Core.CodeInstance` followed by its
`Core.CodeInfo` for every function the entry reaches, inferred once, and the `svec(rettype, signature)`
record of each ccallable queued beside it; `notes`, the verifier's warnings,
each a `TrimError`; and `parents`, the verifier's map from each CodeInstance to the caller and
statement that first reached it, from which TrimVerifier.verify_create_stackframes locates any
statement of the world.

A typestate by construction: its one constructor takes the token `_SubsetToken`, which only this
file holds, and `check_subset` is its only caller, so every stage after the subset check takes a
`ClosedWorld` and none can be reached by a program Julia's verifier did not accept.

precedent(rust: typestate with a private constructor, the value made by one function of its module).
Julia's differs: it has no private constructors, so the sole constructor and the token's are checked
by reflection when the package loads (check_sole_constructor).
"""
@quarantine "Julia's trim inference returns the closed world as an untyped list of CodeInstance and CodeInfo pairs" Core.Any struct ClosedWorld
    entry::Core.MethodInstance
    codeinfos::Vector{Any}
    notes::Vector{TrimError}
    parents::IdDict{Core.CodeInstance,Tuple{Core.CodeInstance,Int}}
    ClosedWorld(::_SubsetToken, entry::Core.MethodInstance, codeinfos::Vector{Any}, notes::Vector{TrimError},
                parents::IdDict{Core.CodeInstance,Tuple{Core.CodeInstance,Int}}) = new(entry, codeinfos, notes, parents)
end

# Julia's closed-world inference for trimming at `world`, of its queue: the entry's MethodInstance and
# each @ccallable as `svec(rettype, signature)`, the item juliac queues for one
# (juliac-buildscript.jl's jl_add_ccallable_entrypoints), whose specialization the inference compiles
# and whose record it keeps for the verifier. Julia 1.13 adds external_linkage: false, so every body
# the queue reaches is inferred and none is taken as already compiled into a package image
# (WasmTarget compiles every body to wasm).
@quarantine "the closed world is inferred by Julia's trim mode, whose entry point changed arity in 1.13" Core.Compiler.typeinf_ext_toplevel function _trim_infer(queue::Vector{Any}, world::UInt)::Vector{Any}
    @static if VERSION >= v"1.13-"
        return Core.Compiler.typeinf_ext_toplevel(queue, UInt[world], Core.Compiler.TRIM_UNSAFE, false)
    else
        return Core.Compiler.typeinf_ext_toplevel(queue, UInt[world], Core.Compiler.TRIM_UNSAFE)
    end
end

# The program's @ccallable members among an inferred closed world, each as juliac queues it,
# `svec(rettype, signature)` (Method.ccallable): a ccallable the entry reaches is exported
# (functions.jl's getExportName), so Julia's verifier judges its declared signature and return
@quarantine "a ccallable is queued for Julia's trim inference as its Method's svec(rettype, signature)" Core.Method function _reached_ccallables(codeinfos::Vector{Any})::Vector{Any}
    local out = Any[]
    local seen = Base.IdSet{Method}()
    for x in codeinfos
        x isa Core.CodeInstance && x.def isa Core.MethodInstance || continue
        local m = x.def.def
        m isa Method && isdefined(m, :ccallable) && !(m in seen) || continue
        push!(seen, m)
        push!(out, m.ccallable)
    end
    return out
end

# The closed world Julia infers for `queue` and its verifier's verdict: the inferred items, the
# warnings and the parents; an error rejects as OutsideSubset, located at `at`
@quarantine "the verifier judges what Julia's trim inference returned, errors fatal and warnings notes, as juliac" Core.Compiler.TrimVerifier.get_verify_typeinf_trim function _infer_verified(queue::Vector{Any}, world::UInt, at::String)
    local codeinfos = _trim_infer(queue, world)
    local errors, parents = Core.Compiler.TrimVerifier.get_verify_typeinf_trim(codeinfos)
    local fatal = TrimError[]; local notes = TrimError[]
    for (warn, cause) in errors
        push!(warn ? notes : fatal, _trim_error(cause, parents, at))
    end
    isempty(fatal) || reject!(OutsideSubset(fatal), at)
    return codeinfos, notes, parents
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

# Each description Julia's trim verifier gives (Compiler/src/verifytrim.jl's CallMissing and
# CCallableMissing, 1.12 and 1.13), read into its TrimErrorKind
@quarantine "Julia's verifier states each error's kind as text, read here into the closed set of kinds" Base.Dict const TRIM_ERROR_KINDS = Dict{String,TrimErrorKind}(
    "unresolved invoke" => unresolved_invoke,
    "unresolved call to (unknown) builtin" => unresolved_builtin_call,
    "unresolved call to function" => unresolved_function_call,
    "unresolved argument to call" => unresolved_call_argument,
    "unresolved finalizer registered" => unresolved_finalizer,
    "trim verification not yet implemented for builtin `Core._apply`" => unimplemented_apply,
    "trim verification not yet implemented for builtin `Core._call_in_world_total`" => unimplemented_call_in_world_total,
    "trim verification not yet implemented for builtin `Core.invoke`" => unimplemented_invoke,
    "trim verification not yet implemented for builtin `Core.invoke_in_world`" => unimplemented_invoke_in_world,
    "trim verification not yet implemented for builtin `Core.invokelatest`" => unimplemented_invokelatest,
    "trim verification not yet implemented for builtin `Core.modifyfield!`" => unimplemented_modifyfield,
    "trim verification not yet implemented for builtin `Core.modifyglobal!`" => unimplemented_modifyglobal,
    "trim verification not yet implemented for builtin `Core.memoryrefmodify!`" => unimplemented_memoryrefmodify,
    "unresolved call" => unresolved_call,
    "unresolved cfunction" => unresolved_cfunction,
    "disallowed ccall into a runtime function" => runtime_ccall,
    "disallowed ccall with non-constant name and no library" => nonconstant_ccall,
    "unresolved opaque closure" => unresolved_opaque_closure,
    "unresolved ccallable" => unresolved_ccallable,
    "ccallable declared return type does not match inference" => ccallable_return_mismatch,
)

# One error the verifier reports, kept as Julia gives it: its kind, its statement and Julia's stack
# frames for it (verify_create_stackframes over the verifier's parents); a description with no kind
# in TRIM_ERROR_KINDS is an Internal rejection, the table behind this Julia's verifier
@quarantine "the verifier's error and the stack frames Julia builds for it, kept as Julia gives them" Core.Compiler.TrimVerifier.verify_create_stackframes function _trim_error(@nospecialize(cause), parents, at::String)::TrimError
    local kind = get(TRIM_ERROR_KINDS, string(cause.desc), nothing)
    kind === nothing && reject!(Internal("src/julia/subset.jl TRIM_ERROR_KINDS: Julia $VERSION's trim verifier reports \"$(cause.desc)\", a description it has no kind for"), at)
    cause isa Core.Compiler.TrimVerifier.CCallableMissing && return TrimError(kind, nothing, 0, Base.StackTraces.StackFrame[], TrimCCallableMissing(cause))
    return TrimError(kind, cause.codeinst, cause.stmtidx, Core.Compiler.TrimVerifier.verify_create_stackframes(cause.codeinst, cause.stmtidx, parents),
                     TrimCallMissing(cause::Core.Compiler.TrimVerifier.CallMissing))
end

"""
    check_subset(f, argtypes::Tuple, at::String) -> ClosedWorld

Infer the program `f(argtypes...)` once, as Julia's trimming does, from the specialization Julia
compiles for that call (`_entry_specialization`), and let Julia's trim verifier judge it. Returns the
closed world it accepts; rejects with `OutsideSubset` when the entry has no unique method (Julia's
`which` text) or no compileable specialization, or the verifier reports errors, each a `TrimError`
holding Julia's own record, its statement and its stack frames.
"""
@quarantine "the strict subset is the one Julia's trim verifier accepts over unmodified Base, never re-guessed" Base.signature_type function check_subset(@nospecialize(f), argtypes::Tuple, at::String)::ClosedWorld
    local sig = Base.signature_type(f, argtypes)
    local world = Base.get_world_counter()
    local mi = _entry_specialization(sig, world)
    if mi === nothing
        # Julia's own words when the call has no unique method; otherwise it has one Julia compiles none for
        try
            Base._which(sig; world = world)
        catch e
            e isa ErrorException || rethrow()
            reject!(OutsideSubset([TrimError(no_unique_method, nothing, 0, Base.StackTraces.StackFrame[], TrimEntryText(sprint(showerror, e)))]), at)
        end
        reject!(OutsideSubset([TrimError(no_compileable_specialization, nothing, 0, Base.StackTraces.StackFrame[],
                                         TrimEntryText("$sig: Julia gives the call no compileable specialization"))]), at)
    end
    local entry = mi
    local codeinfos, notes, parents = _infer_verified(Any[entry], world, at)
    # the ccallables the entry reaches, queued beside it as juliac queues each, so the verifier judges
    # each declared signature and return (CCallableMissing); the inference's cache answers the rest
    local ccallables = _reached_ccallables(codeinfos)
    isempty(ccallables) || ((codeinfos, notes, parents) = _infer_verified(Any[entry; ccallables], world, at))
    return ClosedWorld(_SubsetToken(), entry, codeinfos, notes, parents)
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
