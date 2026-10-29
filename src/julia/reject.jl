# The rejections: every construct WasmTarget cannot compile ends here, located, never in a plausible
# value (dev/CHARTER.md C6). A closed sum of kinds; the compile's caller receives it as a
# RejectionError. Dart throws at the site, an exception the driver reports (compile.dart:216
# compile); Julia has no checked exceptions, so the kinds are one closed sum carried by one exception
# type, Rust's Result<_, E> over a sealed E.

"""A path reached a dart definition not yet ported; `anchor` is `<file>.dart:<line> <Symbol>`."""
@quarantine "Julia has no checked exceptions; a rejection's kind is a struct of the closed sum" Core.String struct Unported
    anchor::String
end

"""A path reached a Julia-only definition (src/julia/) not yet written; `row` names it."""
@quarantine "Julia has no checked exceptions; a rejection's kind is a struct of the closed sum" Core.String struct Unquarantined
    row::String
end

"""
    TrimErrorKind

What Julia's trim verifier found at a statement: one member per description its `CallMissing` and
`CCallableMissing` carry (Compiler/src/verifytrim.jl, Julia 1.12 and 1.13), and the two ways an
entry has nothing to verify, no unique method or no compileable specialization.

precedent(rust: a fieldless enum; dart: enum). Julia's differs: an @enum is closed by its type, and
the verifier states each kind only as text, which `TRIM_ERROR_KINDS` (src/julia/subset.jl) reads
into a member; a text with no member is an Internal rejection, never a guess.
"""
@quarantine "Julia's verifier states each error's kind as text; an @enum closes the set of kinds" Base.var"@enum" @enum TrimErrorKind begin
    unresolved_invoke
    unresolved_builtin_call
    unresolved_function_call
    unresolved_call_argument
    unresolved_finalizer
    unimplemented_apply
    unimplemented_call_in_world_total
    unimplemented_invoke
    unimplemented_invoke_in_world
    unimplemented_invokelatest
    unimplemented_modifyfield
    unimplemented_modifyglobal
    unimplemented_memoryrefmodify
    unresolved_call
    unresolved_cfunction
    runtime_ccall
    nonconstant_ccall
    unresolved_opaque_closure
    unresolved_ccallable
    ccallable_return_mismatch
    no_unique_method
    no_compileable_specialization
end

"""A verifier error at a statement: Julia's own `CallMissing` record, its CodeInstance, CodeInfo and
sptypes, the statement index and the description."""
@quarantine "the verifier's CallMissing, kept as Julia gives it" Core.Compiler.TrimVerifier.CallMissing struct TrimCallMissing
    record::Core.Compiler.TrimVerifier.CallMissing
end

"""A verifier error at a ccallable: Julia's own `CCallableMissing` record, its types and description."""
@quarantine "the verifier's CCallableMissing, kept as Julia gives it" Core.Compiler.TrimVerifier.CCallableMissing struct TrimCCallableMissing
    record::Core.Compiler.TrimVerifier.CCallableMissing
end

"""An entry with nothing to verify: Julia's own text for it (its `which` error, or that it names no
compileable specialization)."""
@quarantine "an entry the verifier never sees is described by Julia's own text" Core.String struct TrimEntryText
    text::String
end

"""The cause of a TrimError, one of the verifier's two records or the entry's text: a closed sum."""
@quarantine "a closed sum is a Union in Julia, which has no sealed classes or enums" Core.Union @closed const TrimCause = Union{TrimCallMissing, TrimCCallableMissing, TrimEntryText}

"""
    TrimError(kind, codeinst, stmtidx, frames, cause)

One error Julia's trim verifier reports, as Julia gives it: `kind`; `cause`, Julia's own record
(TrimCause: a TrimVerifier `CallMissing`, a `CCallableMissing`, or, for an entry with nothing to
verify, Julia's text); `codeinst` and `stmtidx` the statement, nothing and 0 where there is none; and
`frames`, Julia's stack frames for it, the inline chain innermost first and then each caller
(TrimVerifier.verify_create_stackframes), empty where there is no statement.
"""
@quarantine "the verifier's own records, its CallMissing and the stack frames it builds, kept as Julia gives them" Base.StackTraces.StackFrame struct TrimError
    kind::TrimErrorKind
    codeinst::Union{Nothing,Core.CodeInstance}
    stmtidx::Int
    frames::Vector{Base.StackTraces.StackFrame}
    cause::TrimCause
end

"""Julia's trim verifier rejects the program: `errors`, each it reports, in its order."""
@quarantine "Julia has no checked exceptions; a rejection's kind is a struct of the closed sum" Base.Vector struct OutsideSubset
    errors::Vector{TrimError}
end

# one verifier error in Julia's own words, as juliac prints it (verify_print_error): its description,
# the statement and the stack frames, from the records the error keeps
@quarantine "the verifier's text is Julia's, printed by its own printers from its own records" Core.Compiler.TrimVerifier.verify_print_stmt function _trim_text(e::TrimError)::String
    return sprint() do io
        @exhaustive e.cause::TrimCause begin
            (c::TrimCallMissing) => begin
                print(io, c.record.desc, " from statement ")
                Core.Compiler.TrimVerifier.verify_print_stmt(IOContext{IO}(io), c.record.codeinfo, c.record.sptypes, c.record.stmtidx)
                Base.show_backtrace(io, e.frames)
            end
            (c::TrimCCallableMissing) => Core.Compiler.TrimVerifier.verify_print_error(IOContext{IO}(io), c.record, Core.Compiler.TrimVerifier.ParentMap())
            (c::TrimEntryText) => print(io, c.text)
        end
    end
end

# the errors' text, each the verifier reports numbered as juliac numbers them; an entry with nothing to
# verify, Julia's own text alone
@quarantine "the verifier's errors numbered as juliac prints them" Base.join _trim_texts(errors::Vector{TrimError})::String =
    rstrip(join(((e.cause isa TrimEntryText ? "" : "Verifier error #$i: ") * _trim_text(e) for (i, e) in enumerate(errors)), "\n\n"))

"""The module WasmTarget built is not valid wasm; `site` names where it was found."""
@quarantine "Julia has no checked exceptions; a rejection's kind is a struct of the closed sum" Core.String struct InvalidModule
    site::String
end

"""WasmTarget broke its own invariant; `site` names where."""
@quarantine "Julia has no checked exceptions; a rejection's kind is a struct of the closed sum" Core.String struct Internal
    site::String
end

"""
    Rejection

Why a compile stops: `Unported` and `Unquarantined` (a path that reaches a definition not yet
written: the dart definition it mirrors, or the Julia-only row it implements), `OutsideSubset`
(Julia's own trim verifier rejects the program), `InvalidModule` and `Internal` (a defect of
WasmTarget itself).

A closed sum by construction: a `@closed` `Union` of five concrete structs that subtype nothing,
so no other module can add a kind; a sixth kind is an edit of this line, and every `@exhaustive`
match over it, `_reason` first, then refuses the load until it has the sixth arm.

precedent(rust: enum + exhaustive match; dart: sealed class + exhaustive switch). Julia's differs:
a `Union` of concrete types where Rust declares an enum and dart a sealed hierarchy, and its
exhaustiveness checked when the package loads, since Julia checks no match at compile time.
"""
@quarantine "a closed sum is a Union in Julia, which has no sealed classes or enums" Core.Union @closed const Rejection = Union{Unported, Unquarantined, OutsideSubset, InvalidModule, Internal}

"""
    RejectionError(rejection, at)

The one exception a compile raises: its `Rejection` and `at`, the compile it stopped (the function
and argument types; the statement and its inline chain once code is generated, dev/MARCH.md 1.D).
"""
@quarantine "Julia has no checked exceptions; one exception type carries the sum" Core.Exception struct RejectionError <: Exception
    rejection::Rejection
    at::String
end

# why a rejection stops the compile: one arm per kind (dart's switch over a sealed class)
@quarantine "the sum's one match, an exhaustive switch where dart switches over a sealed class" Base.string function _reason(r::Rejection)::String
    @exhaustive r::Rejection begin
        (u::Unported) => "unported: the dart definition $(u.anchor)"
        (q::Unquarantined) => "unported: the Julia-only definition $(q.row)"
        (o::OutsideSubset) => "outside the strict subset: $(_trim_texts(o.errors))"
        (i::InvalidModule) => "invalid module at $(i.site)"
        (n::Internal) => "internal error at $(n.site)"
    end
end

@quarantine "the rejection's text, Julia's error display" Base.showerror Base.showerror(io::IO, e::RejectionError) = print(io, "WasmTarget rejects ", e.at, ": ", _reason(e.rejection))

"""
    reject!(rejection, at) -> Union{}

Stop the compile `at` names with `rejection`.
"""
@quarantine "a rejection stops the compile by throwing, where dart throws at the site" Core.throw reject!(r::Rejection, at::String)::Union{} = throw(RejectionError(r, at))

# The sum's load-time check: Rejection is a @closed sum (its kinds concrete, subtyping nothing),
# `_reason` an @exhaustive match over it, and every match over it names every kind (check_closed).
# A violation refuses the package's load.
@quarantine "the closed sum's assertion, run when the package loads" Base.Val construction_check(::Val{:Rejection})::Int = check_sum_matched(@__MODULE__, :Rejection)
@quarantine "the closed sum's assertion, run when the package loads" Base.Val construction_check(::Val{:TrimCause})::Int = check_sum_matched(@__MODULE__, :TrimCause)
construction_check(Val(:Rejection))
