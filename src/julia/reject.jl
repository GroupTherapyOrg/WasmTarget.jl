# The rejections: every construct WasmTarget cannot compile ends here, located, never in a plausible
# value (dev/CHARTER.md C6). A closed sum of kinds; the compile's caller receives it as a
# RejectionError. Dart throws at the site, an exception the driver reports (compile.dart:216
# compile); Julia has no checked exceptions, so the kinds are one closed sum carried by one exception
# type, Rust's Result<_, E> over a sealed E.

"""A path reached a dart definition not yet ported; `anchor` is `<file>.dart:<line> <Symbol>`."""
@quarantine unpinned "Julia has no checked exceptions; a rejection's kind is a struct of the closed sum" Core.String struct Unported
    anchor::String
end

"""A path reached a Julia-only definition (src/julia/) not yet written; `row` names it."""
@quarantine unpinned "Julia has no checked exceptions; a rejection's kind is a struct of the closed sum" Core.String struct Unquarantined
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
@quarantine unpinned "Julia's verifier states each error's kind as text; an @enum closes the set of kinds" Base.var"@enum" @enum TrimErrorKind begin
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
@quarantine unpinned "the verifier's CallMissing, kept as Julia gives it" Core.Compiler.TrimVerifier.CallMissing struct TrimCallMissing
    record::Core.Compiler.TrimVerifier.CallMissing
end

"""A verifier error at a ccallable: Julia's own `CCallableMissing` record, its types and description."""
@quarantine unpinned "the verifier's CCallableMissing, kept as Julia gives it" Core.Compiler.TrimVerifier.CCallableMissing struct TrimCCallableMissing
    record::Core.Compiler.TrimVerifier.CCallableMissing
end

"""An entry with nothing to verify: Julia's own text for it (its `which` error, or that it names no
compileable specialization)."""
@quarantine unpinned "an entry the verifier never sees is described by Julia's own text" Core.String struct TrimEntryText
    text::String
end

"""The cause of a TrimError, one of the verifier's two records or the entry's text: a closed sum."""
@quarantine unpinned "a closed sum is a Union in Julia, which has no sealed classes or enums" Core.Union @closed const TrimCause = Union{TrimCallMissing, TrimCCallableMissing, TrimEntryText}

"""
    TrimError(kind, codeinst, stmtidx, frames, cause)

One error Julia's trim verifier reports, as Julia gives it: `kind`; `cause`, Julia's own record
(TrimCause: a TrimVerifier `CallMissing`, a `CCallableMissing`, or, for an entry with nothing to
verify, Julia's text); `codeinst` and `stmtidx` the statement, nothing and 0 where there is none; and
`frames`, Julia's stack frames for it, the inline chain innermost first and then each caller
(TrimVerifier.verify_create_stackframes), empty where there is no statement.
"""
@quarantine unpinned "the verifier's own records, its CallMissing and the stack frames it builds, kept as Julia gives them" Base.StackTraces.StackFrame struct TrimError
    kind::TrimErrorKind
    codeinst::Union{Nothing,Core.CodeInstance}
    stmtidx::Int
    frames::Vector{Base.StackTraces.StackFrame}
    cause::TrimCause
end

"""Julia's trim verifier rejects the program: `errors`, each it reports, in its order."""
@quarantine unpinned "Julia has no checked exceptions; a rejection's kind is a struct of the closed sum" Base.Vector struct OutsideSubset
    errors::Vector{TrimError}
end

# A value of a verifier record as text, built with no read of a program binding and no program `show` (spec v14 V7: the
# verifier's statement and frames printed by Base at the program's world ran a unit's `show` inside the compiler, and
# read program bindings): a type, a type variable, a Vararg or a module by julia_text; a generic function by its name
# (show.jl's show_signature_function port); a value Base prints by itself (a number, a string, a symbol); any other by
# its type's text. precedent(julia: Compiler/src/verifytrim.jl:103 verify_print_stmt prints Julia's statement): Julia
# differs in that its printer is Base's show at the current world, which a program's methods extend
@quarantine pin"precedent(julia: base/show.jl:2552 show_signature_function)" "a record's value prints by its kind's text: a type's julia_text, a function's name, Base's own value" Core.MethodInstance function _trim_value_text(@nospecialize(x))::String
    x isa Union{Type,TypeVar,Core.TypeofVararg,Module} && return julia_text(x)
    x isa Core.MethodInstance && return replace(julia_text(x), r"^MethodInstance for " => "")
    x isa Function && Base.issingletontype(typeof(x)) && return sprint(_jt_show_signature_function, typeof(x))
    x isa GlobalRef && return string(julia_text(x.mod), ".", x.name)
    _trim_base_value(x) && return repr(x)
    # a program's own immutable Number (its show a program method): its type and its fields, as Base's show_default
    # prints a struct (base/show.jl:487), each field Base's own value or its type's text (spec v16 X5); a mutable one, as
    # any other value, by its type's text
    x isa Number && !ismutabletype(typeof(x)) && return julia_text(typeof(x)) * "(" * join((isdefined(x, i) ? (y = getfield(x, i); _trim_base_value(y) ? repr(y) :
        "::" * julia_text(typeof(y))) : "#undef" for i in 1:nfields(x)), ", ") * ")"
    return "::" * julia_text(typeof(x))
end
# a value Base prints by itself: a number, a string, a symbol, a char or nothing of a type of Core's or Base's, never a
# mutable Number (BigInt, BigFloat: their digits lie behind a pointer, their show reads MPFR's process-global
# precision): the corpus loader's _plain rule (test/corpus_loader.jl _plain_type), which a program's own subtype of
# Number fails, so no show of a program's runs where a record is printed (spec v16 X5)
@quarantine pin"precedent(julia: base/runtime_internals.jl:32 moduleroot)" "a value's type is Base's own when its module's root is Core or Base" Base.moduleroot function _trim_base_value(@nospecialize(x))::Bool
    x isa Union{Number,String,Symbol,Char,Nothing} || return false
    local T = typeof(x)
    return T isa DataType && Base.moduleroot(T.name.module) in (Core, Base) && !(x isa Number && ismutabletype(T))
end
# a statement's text holder: printed as its text, so Base's statement printer prints a program's value through it
@quarantine pin"precedent(julia: base/docs/utils.jl:87 Text)" "a text that prints as itself, Julia's Docs.Text, where Base's statement printer prints a value" Core.String struct _TrimText
    text::String
end
@quarantine pin"precedent(julia: base/docs/utils.jl:93 show)" "a text prints as itself, as Julia's Docs.Text shows" Base.show Base.show(io::IO, t::_TrimText) = print(io, t.text)
# the statement verify_print_stmt prints (its Expr of the SSA values' types, Julia's mapssavaluetypes), each value not
# itself syntax replaced by its text
@quarantine pin"precedent(julia: Compiler/src/verifytrim.jl:72 mapssavalues)" "a statement's values print by their text, its syntax as Julia's" Core.Expr function _trim_stmt(@nospecialize(x))
    x isa Expr && return Expr(x.head, Any[_trim_stmt(a) for a in x.args]...)
    x isa QuoteNode && return QuoteNode(_trim_stmt(x.value))
    x isa Union{Symbol,Core.SSAValue,Core.SlotNumber,Core.Argument,LineNumberNode,Core.PhiNode} && return x
    # a name of Julia's own modules prints as Base prints it; a program module's by its bare name (an operator infix)
    x isa GlobalRef && return Base.moduleroot(x.mod) === Core || Base.moduleroot(x.mod) === Base ? x : x.name
    return _TrimText(_trim_value_text(x))
end
# Julia's stack frames, as show_backtrace prints them (its numbered frames, each the call and its file and line), each
# frame's call by julia_text
@quarantine pin"precedent(julia: base/errorshow.jl:815 show_backtrace)" "a stack trace prints each frame numbered, its call and where" Base.StackTraces.StackFrame function _trim_frames(io::IO, frames::Vector{Base.StackTraces.StackFrame})::Nothing
    isempty(frames) && return nothing
    print(io, "\nStacktrace:")
    for (i, f) in enumerate(frames)
        local li = f.linfo
        li isa Core.CodeInstance && (li = li.def)
        local call = li isa Core.MethodInstance ? _trim_value_text(li) :
            li isa Method ? sprint(_jt_show_tuple_as_call, li.name, li.sig) : string(f.func)
        print(io, "\n [", i, "] ", call, f.inlined ? " [inlined]" : "", "\n   @ ", f.file, ":", f.line)
    end
    return nothing
end

# one verifier error in Julia's own words, as juliac prints it (verify_print_error): its description, the statement
# and the stack frames, from the records the error keeps, each value by its text (_trim_value_text)
@quarantine pin"precedent(julia: Compiler/src/verifytrim.jl:110 verify_print_error)" "the verifier's text, from its own records" Core.Compiler.TrimVerifier.mapssavaluetypes function _trim_text(e::TrimError)::String
    return sprint() do io
        @exhaustive e.cause::TrimCause begin
            (c::TrimCallMissing) => begin
                print(io, c.record.desc, " from statement ")
                local ci = c.record.codeinfo
                local ctx = ci.slotnames === nothing ? io :
                    IOContext(io, :SOURCE_SLOTNAMES => Core.Compiler.TrimVerifier.sourceinfo_slotnames(ci))
                print(ctx, _trim_stmt(Core.Compiler.TrimVerifier.mapssavaluetypes(ci, c.record.sptypes, Core.SSAValue(c.record.stmtidx))))
                _trim_frames(io, e.frames)
            end
            (c::TrimCCallableMissing) => print(io, c.record.desc, " for ", _trim_value_text(c.record.sig), " => ", _trim_value_text(c.record.rt))
            (c::TrimEntryText) => print(io, c.text)
        end
    end
end

# the errors' text, each the verifier reports numbered as juliac numbers them; an entry with nothing to
# verify, Julia's own text alone
@quarantine unpinned "the verifier's errors numbered as juliac prints them" Base.join function _trim_texts(errors::Vector{TrimError})::String
    local numbered(i, e) = @exhaustive e.cause::TrimCause begin
        TrimCallMissing => "Verifier error #$i: "
        TrimCCallableMissing => "Verifier error #$i: "
        TrimEntryText => ""
    end
    return rstrip(join((numbered(i, e) * _trim_text(e) for (i, e) in enumerate(errors)), "\n\n"))
end

"""
The program is Julia's, and Julia's verifier accepts it, but it cannot be built as written: a
judgment of WasmTarget's about the program, never Julia's verifier's, the user's to fix. `text` says
what and how (two exports sharing one name: rename one).

precedent(c: a linker refusing two definitions of one symbol, the program's error, not the
compiler's). Julia's differs: Julia accepts both definitions, and only the image they are compiled
into holds one name once.
"""
@quarantine unpinned "Julia has no checked exceptions; a rejection's kind is a struct of the closed sum" Core.String struct ProgramError
    text::String
end

"""The module WasmTarget built is not valid wasm; `site` names where it was found."""
@quarantine unpinned "Julia has no checked exceptions; a rejection's kind is a struct of the closed sum" Core.String struct InvalidModule
    site::String
end

"""WasmTarget broke its own invariant; `site` names where."""
@quarantine unpinned "Julia has no checked exceptions; a rejection's kind is a struct of the closed sum" Core.String struct Internal
    site::String
end

"""
    Rejection

Why a compile stops: `Unported` and `Unquarantined` (a path that reaches a definition not yet
written: the dart definition it mirrors, or the Julia-only row it implements), `OutsideSubset`
(Julia's own trim verifier rejects the program), `ProgramError` (WasmTarget's judgment that the
program, which Julia accepts, cannot be built as written, the user's to fix), `InvalidModule` and
`Internal` (a defect of WasmTarget itself).

A closed sum by construction: a `@closed` `Union` of six concrete structs that subtype nothing,
so no other module can add a kind; a seventh kind is an edit of this line, and every `@exhaustive`
match over it, `_reason` first, then refuses the load until it has the seventh arm.

precedent(rust: enum + exhaustive match; dart: sealed class + exhaustive switch). Julia's differs:
a `Union` of concrete types where Rust declares an enum and dart a sealed hierarchy, and its
exhaustiveness checked when the package loads, since Julia checks no match at compile time.
"""
@quarantine unpinned "a closed sum is a Union in Julia, which has no sealed classes or enums" Core.Union @closed const Rejection = Union{Unported, Unquarantined, OutsideSubset, ProgramError, InvalidModule, Internal}

"""
    RejectionError(rejection, at)

The one exception a compile raises: its `Rejection` and `at`, the compile it stopped (the function
and argument types; the statement and its inline chain once code is generated, dev/MARCH.md 1.D).
"""
@quarantine unpinned "Julia has no checked exceptions; one exception type carries the sum" Core.Exception struct RejectionError <: Exception
    rejection::Rejection
    at::String
end

# why a rejection stops the compile: one arm per kind (dart's switch over a sealed class)
@quarantine unpinned "the sum's one match, an exhaustive switch where dart switches over a sealed class" Base.string function _reason(r::Rejection)::String
    @exhaustive r::Rejection begin
        (u::Unported) => "unported: the dart definition $(u.anchor)"
        (q::Unquarantined) => "unported: the Julia-only definition $(q.row)"
        (o::OutsideSubset) => "outside the strict subset: $(_trim_texts(o.errors))"
        (p::ProgramError) => "the program's error: $(p.text)"
        (i::InvalidModule) => "invalid module at $(i.site)"
        (n::Internal) => "internal error at $(n.site)"
    end
end

@quarantine unpinned "the rejection's text, Julia's error display" Base.showerror Base.showerror(io::IO, e::RejectionError) = print(io, "WasmTarget rejects ", e.at, ": ", _reason(e.rejection))

"""
    reject!(rejection, at) -> Union{}

Stop the compile `at` names with `rejection`.
"""
@quarantine unpinned "a rejection stops the compile by throwing, where dart throws at the site" Core.throw reject!(r::Rejection, at::String)::Union{} = throw(RejectionError(r, at))

"""
    rejection_text(x) -> String

`x`'s text in a rejection, Julia's own text of it (src/julia/show.jl julia_text: `string(x)`, a program's binding never
read), inferred once over every value: a site that
interpolates a MethodInstance compiles Base's show of it (show_mi, and in it Compiler's
IRShow.debuginfo_firstline with its `linetable != nothing` on an untyped value), so a package's new
`==` method invalidated that site, and every compiled caller of it, though the text is built only on
the rejection's path (a `==(::T, ::Any)` re-compiled 1196 MethodInstances through nir_body_of and
nir_argument_type alone).

precedent(julia: src/rtutils.c:1496 jl_static_show, the runtime's printing of a value on an error
path, which no method's inference sees). Julia's differs: the text is Julia's own `string(x)`, its
call made where the caller's inference cannot specialize it.
"""
@quarantine pin"julia/src/rtutils.c:1496 jl_static_show" "a rejection's text of a value, printed where no caller infers its printing, as julia/src/rtutils.c:1496 jl_static_show prints one on an error path" Core.String @nospecializeinfer rejection_text(@nospecialize(x))::String = julia_text(x)

# The sum's load-time check: Rejection is a @closed sum (its kinds concrete, subtyping nothing),
# `_reason` an @exhaustive match over it, and every match over it names every kind (check_closed).
# A violation refuses the package's load.
@quarantine unpinned "the closed sum's assertion, run when the package loads" Base.Val construction_check(::Val{:Rejection})::Int = check_sum_matched(@__MODULE__, :Rejection)
@quarantine unpinned "the closed sum's assertion, run when the package loads" Base.Val construction_check(::Val{:TrimCause})::Int = check_sum_matched(@__MODULE__, :TrimCause)
construction_check(Val(:Rejection))
