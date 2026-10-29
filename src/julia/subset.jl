# The strict subset (dev/MARCH.md 1.A7; ledger D32): WasmTarget compiles exactly what Julia's own trim
# verifier accepts over Julia's unmodified Base, and never re-guesses it; outside it, a located
# rejection. It is strictly smaller than what `juliac --trim=safe` compiles: juliac verifies after
# patching Base and the stdlibs (juliac/juliac-trim-base.jl, juliac-trim-stdlib.jl: depwarn, stdio and
# the active project stubbed out), which WasmTarget does not do. A compile
# infers its program once, here, as trimming does: Core.Compiler's trim entry (typeinf_ext_toplevel,
# TRIM_UNSAFE) over the closed world one entry reaches, run with WasmTarget's interpreter, which reads
# its overlay method table (lib/WasmInterpreter). Julia's TrimVerifier then judges what it inferred: an
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
# and whose record it keeps for the verifier. It is typeinf_ext_toplevel's trim entry over
# WasmInterpreter (lib/WasmInterpreter), so the closed world is inferred over WasmTarget's overlays,
# walked by Julia's own Compiler.compile!; the walk lives in that package, whose image holds its
# compiled code apart from WasmTarget's.
@quarantine "the closed world is inferred by Julia's trim entry over WasmTarget's interpreter, a package of its own" WasmInterpreter.infer_closed_world _trim_infer(queue::Vector{Any}, world::UInt)::Vector{Any} =
    WasmInterpreter.infer_closed_world(queue, world)

# Julia's trim verifier over the closed world: TrimVerifier.get_verify_typeinf_trim (Julia's
# Compiler/src/verifytrim.jl) with one change. Julia's takes as a resolved callee only a native
# CodeInstance (owner nothing), where every one the closed world holds is WasmTarget's
# (`WasmInterpreter.WasmCacheOwner`); each body is judged by Julia's own verify_codeinstance!, and each queued
# ccallable's svec by Julia's check of its declared return against inference (CCallableMissing), as
# 1.12 and 1.13 write it.
@quarantine "Julia's trim verifier resolves a callee among native CodeInstances alone; the closed world's are WasmTarget's" Core.Compiler.TrimVerifier.verify_codeinstance! function _verify_trim(codeinfos::Vector{Any}, at::String)
    local this_world = Base.get_world_counter()
    local interp = Core.Compiler.NativeInterpreter(this_world)
    local inspected = Base.IdSet{Core.CodeInstance}()
    local caches = IdDict{Core.MethodInstance,Core.CodeInstance}()
    local errors = Core.Compiler.TrimVerifier.ErrorList()
    local parents = Core.Compiler.TrimVerifier.ParentMap()
    for item in codeinfos
        item isa Core.CodeInstance || continue
        push!(inspected, item)
        if item.owner === WasmInterpreter.WasmCacheOwner() && item.min_world <= this_world <= item.max_world
            local mi = Core.Compiler.get_ci_mi(item)
            mi === item.def && (caches[mi] = item)
        end
    end
    for i in 1:length(codeinfos)
        local item = codeinfos[i]
        if item isa Core.CodeInstance
            local src = codeinfos[i + 1]
            src isa Core.CodeInfo ||
                reject!(Internal("src/julia/subset.jl: the closed world's CodeInstance at $i is followed by a $(typeof(src)), not its CodeInfo"), at)
            Core.Compiler.TrimVerifier.verify_codeinstance!(interp, item, src, inspected, caches, parents, errors)
        elseif item isa Core.SimpleVector
            local rt = item[1]::Type
            local sig = item[2]::Type
            local asrt = Any
            local valid = @static if VERSION >= v"1.13-"
                local mi = ccall(:jl_get_specialization1, Any, (Any, Csize_t, Cint), sig, this_world, 0)
                if mi isa Core.MethodInstance && sig <: (mi.def::Method).sig
                    local ci = get(caches, mi, nothing)
                    ci isa Core.CodeInstance ? (asrt = ci.rettype; true) : false
                else
                    false
                end
            else
                local ptr = ccall(:jl_get_specialization1, Ptr{Cvoid}, (Any, Csize_t, Cint), sig, this_world, 0)
                if ptr !== C_NULL
                    local mi = unsafe_pointer_to_objref(ptr)::Core.MethodInstance
                    local ci = get(caches, mi, nothing)
                    ci isa Core.CodeInstance ? (asrt = ci.rettype; true) : false
                else
                    false
                end
            end
            if !valid
                push!(errors, false => Core.Compiler.TrimVerifier.CCallableMissing(rt, sig, "unresolved ccallable"))
            elseif !(asrt <: rt)
                push!(errors, Core.Compiler.hasintersect(asrt, rt) => Core.Compiler.TrimVerifier.CCallableMissing(asrt, sig, "ccallable declared return type does not match inference"))
            end
        end
    end
    return (errors, parents)
end

# The program's @ccallable members among an inferred closed world, each as juliac queues it,
# `svec(rettype, signature)` (Method.ccallable): a ccallable the entry reaches is exported
# (functions.jl's getExportName), so Julia's verifier judges its declared signature and return. juliac
# queues every ccallable of its image only when it builds a library (--compile-ccallable,
# juliac-buildscript.jl's jl_add_ccallable_entrypoints); an executable's one entry, main, queues none.
# WasmTarget compiles one entry as an executable does, and exports the ccallables that entry reaches,
# dart2wasm's precedent: TFA keeps a wasm:export member the program's libraries declare, and the
# program here is what the entry reaches (A54S2)
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

# A member's export name, or nothing: a @ccallable method's C name, the one Base.@ccallable records
# (Method.ccallable's third entry, `Base.@ccallable "name" f(...)`) else its function's name, as
# juliac's image exports it; the entry's, its function's name (dart's main). The one statement of the
# rule: util.jl's getWasmExportPragma reads it, and check_subset refuses two exports sharing a name
@quarantine "a ccallable's C name is the one Base.@ccallable records in Method.ccallable, else its function's" Core.Method function program_export_name(member::Core.MethodInstance, entry::Core.MethodInstance)::Union{String,Nothing}
    local method = member.def::Method
    isdefined(method, :ccallable) && return length(method.ccallable) == 3 ? method.ccallable[3]::String : string(method.name)
    member === entry || return nothing
    return string(method.name)
end

# Two members of the closed world exporting one name: a program juliac's image would export as one
# symbol, the user's to rename, rejected naming both methods, located at `at`
@quarantine "a C name names one symbol of juliac's image; two methods sharing one are the program's error" Core.MethodInstance function _check_export_names(entry::Core.MethodInstance, codeinfos::Vector{Any}, at::String)::Nothing
    local by_name = Dict{String,Core.MethodInstance}()
    for x in codeinfos
        x isa Core.CodeInstance && x.def isa Core.MethodInstance || continue
        local mi = x.def
        local name = program_export_name(mi, entry)
        name === nothing && continue
        local other = get!(by_name, name, mi)
        other === mi && continue
        reject!(OutsideSubset([TrimError(shared_export_name, nothing, 0, Base.StackTraces.StackFrame[],
                                         TrimEntryText("$(other.def) and $(mi.def) both export the name \"$name\": one symbol for two methods; give one a name of its own (Base.@ccallable \"name\" f(...))"))]), at)
    end
    return nothing
end

"""
    RUNTIME_ENTRY_POINTS

The runtime's entry points, each `(module path, name, argument types, demand)`: a method the code
generator calls where Julia raises, kept in the closed world beside the program whenever the program
holds the IR form `demand` names (`_demanded`): `:throw`, a call of Julia's throw (dart2wasm's
visitThrow calls errors_patch.dart's `_throwWithCurrentStackTrace`), and `:checked_division`, a
checked integer division or remainder, which raises DivideError at a zero divisor. Each demanded one
is queued for Julia's one trim inference beside the entry (`check_subset`), so its CodeInstance is in
the closed world and its NirBody in the NIR.

precedent(dart: `@pragma("wasm:entry-point")`, which TFA keeps; juliac: the ccallables the entry
reaches, queued as roots beside main, as check_subset queues them, `_reached_ccallables`). Julia's
differs: a method carries no pragma, so the roots are listed with the form that demands each, each
checked to name one method when the package loads (check_runtime_entry_points).
"""
@quarantine "a method carries no entry-point pragma; the runtime's roots of Julia's trim inference are listed with their argument types" Core.Type const RUNTIME_ENTRY_POINTS::Tuple{Vararg{Tuple{Tuple{Vararg{Symbol}},Symbol,Tuple{Vararg{Type}},Symbol}}} = (
    ((:Runtime,), :Error__throw_with_current_stack_trace, (Exception,), :throw),
    ((), :throw_divide_error, (), :checked_division),
)

# the IR forms a root's demand names, each a builtin or intrinsic a statement calls
@quarantine "a runtime root is demanded by the Julia builtin or intrinsic whose raise it lowers" Core.Intrinsics.checked_sdiv_int const RUNTIME_DEMANDS = Dict{Symbol,Tuple{Vararg{Core.Builtin}}}(
    :throw => (Core.throw,),
    :checked_division => (Core.Intrinsics.checked_sdiv_int, Core.Intrinsics.checked_srem_int,
                          Core.Intrinsics.checked_udiv_int, Core.Intrinsics.checked_urem_int),
)

# whether an inferred body of `codeinfos` calls one of `fs`: a statement `Expr(:call, f, ...)` whose
# callee is one of them, a GlobalRef or the value itself, as Julia's optimized IR writes a builtin call
@quarantine "a builtin call is read from the inferred CodeInfo's statements, as Julia writes them" Core.CodeInfo function _demanded(codeinfos::Vector{Any}, fs::Tuple{Vararg{Core.Builtin}})::Bool
    for x in codeinfos
        x isa Core.CodeInfo || continue
        for st in x.code
            Meta.isexpr(st, :call) && !isempty(st.args) || continue
            local c = st.args[1]
            local v = c isa GlobalRef ? (isdefined(c.mod, c.name) ? getglobal(c.mod, c.name) : nothing) : c
            any(f -> v === f, fs) && return true
        end
    end
    return false
end

# an entry point's function, resolved in `mod` along its module path, or nothing
@quarantine "an entry point names its function by module path and name, resolved where the package loaded" Core.getglobal function _runtime_entry_function(mod::Module, path::Tuple{Vararg{Symbol}}, name::Symbol)::Union{Function,Nothing}
    local m = mod
    for n in path
        isdefined(m, n) || return nothing
        m = getglobal(m, n)
        m isa Module || return nothing
    end
    isdefined(m, name) || return nothing
    local f = getglobal(m, name)
    return f isa Function ? f : nothing
end

"""
    check_runtime_entry_points(mod, entries) -> Int

The runtime roots' check: each of `entries` (RUNTIME_ENTRY_POINTS' form) names a function of `mod`
with exactly one method for its argument types, so `check_subset` can queue it; throws a
`ConstructionViolation` naming the first that does not.

precedent(juliac: an entrypoint with no matching method fails the build, jl_add_ccallable_entrypoints
and Base.Experimental.entrypoint). Julia's differs: the list is data, so the load resolves it.
"""
@quarantine "the runtime roots are resolved when the package loads, by Julia's method table" Base.methods function check_runtime_entry_points(mod::Module, entries)::Int
    for (path, name, argtypes, demand) in entries
        haskey(RUNTIME_DEMANDS, demand) || throw(ConstructionViolation("RUNTIME_ENTRY_POINTS", "$(join((path..., name), '.')) is demanded by $demand, no form RUNTIME_DEMANDS names"))
        local f = _runtime_entry_function(mod, path, name)
        f === nothing && throw(ConstructionViolation("RUNTIME_ENTRY_POINTS", "$(join((path..., name), '.')) names no function"))
        local n = length(methods(f, Tuple{argtypes...}))
        n == 1 || throw(ConstructionViolation("RUNTIME_ENTRY_POINTS", "$(join((path..., name), '.'))$argtypes matches $n methods, not one"))
    end
    return 0
end

# the MethodInstance of each runtime entry point `codeinfos` demands at `world`, its compileable
# specialization, as the entry's
@quarantine "a runtime root is the specialization Julia compiles for it, as juliac's entrypoint takes it" Core.Typeof function _runtime_roots(codeinfos::Vector{Any}, world::UInt)::Vector{Any}
    local out = Any[]
    for (path, name, argtypes, demand) in RUNTIME_ENTRY_POINTS
        _demanded(codeinfos, RUNTIME_DEMANDS[demand]) || continue
        local f = something(_runtime_entry_function(@__MODULE__, path, name))
        push!(out, something(_entry_specialization(Tuple{Core.Typeof(f), argtypes...}, world)))
    end
    return out
end

# The closed world Julia infers for `queue` and its verifier's verdict: the inferred items, the
# warnings and the parents; an error rejects as OutsideSubset, located at `at`
@quarantine "the verifier judges what Julia's trim inference returned, errors fatal and warnings notes, as juliac" Base.push! function _infer_verified(queue::Vector{Any}, world::UInt, at::String)
    local codeinfos = _trim_infer(queue, world)
    local errors, parents = _verify_trim(codeinfos, at)
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
    cause isa Core.Compiler.TrimVerifier.CallMissing ||
        reject!(Internal("src/julia/subset.jl _trim_error: Julia $VERSION's trim verifier reports a $(typeof(cause)), a record it has no kind for (TrimCause)"), at)
    return TrimError(kind, cause.codeinst, cause.stmtidx, Core.Compiler.TrimVerifier.verify_create_stackframes(cause.codeinst, cause.stmtidx, parents),
                     TrimCallMissing(cause))
end

"""
    check_subset(f, argtypes::Tuple, at::String) -> ClosedWorld

Infer the program `f(argtypes...)` once, as Julia's trimming does, from the specialization Julia
compiles for that call (`_entry_specialization`), and let Julia's trim verifier judge it. Returns the
closed world it accepts; rejects with `OutsideSubset` when the entry has no unique method (Julia's
`which` text) or no compileable specialization, or the verifier reports errors, each a `TrimError`
holding Julia's own record, its statement and its stack frames.

formal(dev/formal/NirHandoff.tla): every reached ccallable's record queued and judged, none the entry never reaches
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
    local roots = Any[]
    local codeinfos, notes, parents = _infer_verified(Any[entry], world, at)
    # the runtime's entry points the program demands, queued beside the entry, until a root's own body
    # demands no other (a thrower throws: each pass adds roots, of which there are finitely many)
    while true
        local demanded = _runtime_roots(codeinfos, world)
        length(demanded) == length(roots) && break
        roots = demanded
        # the roots queued before the entry, so Julia's inference returns the program's bodies first and
        # the closed world keeps program order (its classes met from the entry's callable on)
        (codeinfos, notes, parents) = _infer_verified(Any[roots; entry], world, at)
    end
    # the ccallables the entry reaches, queued beside it as juliac queues each, so the verifier judges
    # each declared signature and return (CCallableMissing); the inference's cache answers the rest
    local ccallables = _reached_ccallables(codeinfos)
    isempty(ccallables) || ((codeinfos, notes, parents) = _infer_verified(Any[roots; entry; ccallables], world, at))
    _check_export_names(entry, codeinfos, at)
    # each root queued is inferred into the closed world, Julia's answer for a queued item; one missing is
    # WasmTarget's own defect
    for r in roots
        any(x -> x isa Core.CodeInstance && x.def === r, codeinfos) ||
            reject!(Internal("src/julia/subset.jl check_subset: the runtime entry point $r is not in the closed world"), at)
    end
    return ClosedWorld(_SubsetToken(), entry, codeinfos, notes, parents)
end

# the typestate's assertion, run when the package loads: ClosedWorld and its token each have one
# constructor method, both in this file, ClosedWorld's taking the token (a construction, L220); and
# its next state, src/julia/nir.jl's NirWorld, which build_nir makes from a ClosedWorld, the same
@quarantine "the typestate's assertion, run when the package loads" Base.Val construction_check(::Val{:ClosedWorld})::Int =
    check_sole_constructor(ClosedWorld, _SubsetToken, @__FILE__) +
    check_sole_constructor(NirWorld, _NirToken, joinpath(@__DIR__, "nir.jl")) +
    # a ClosedWorld holds the runtime roots its program demands: each one names one method
    check_runtime_entry_points(@__MODULE__, RUNTIME_ENTRY_POINTS)

# no method of WasmTarget but check_subset names the token or makes either: read in every method's
# lowered code when the package loads. A stopgap, not a construction (L224): Julia has no module
# privacy, so the wrong choice stays writable and this read finds it (A36S3, A37S1, A38)
@quarantine "Julia has no module privacy; WasmTarget's own lowered code is read when the package loads" Base.moduleroot check_closed_world_makers()::Int =
    check_sole_maker(Base.moduleroot(@__MODULE__), ClosedWorld, _SubsetToken, (only(methods(check_subset)),),
                     (which(check_closed_world_makers, Tuple{}), which(construction_check, Tuple{Val{:ClosedWorld}})),
                     (joinpath(@__DIR__, "parity.jl"), joinpath(@__DIR__, "construction.jl")))
