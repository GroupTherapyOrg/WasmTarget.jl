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
statement of the world; and `world`, the world age the closed world was inferred in, the one source of
the world a compiled program's task runs at: an embedded or juliac image's task runs at the world its
code was inferred in (julia/src/jlapi.c:316 jl_call sets ct->world_age to jl_get_world_counter(), the
image's; a juliac image's @ccallable wrapper stores jl_world_counter into the task's world age,
julia/src/codegen.cpp:7190 emit_abi_call).

A typestate by construction: its one constructor takes the token `_SubsetToken`, which only this
file holds, and `check_subset` is its only caller, so every stage after the subset check takes a
`ClosedWorld` and none can be reached by a program Julia's verifier did not accept.

precedent(rust: typestate with a private constructor, the value made by one function of its module).
Julia's differs: it has no private constructors, so the sole constructor and the token's are checked
by reflection when the package loads (check_sole_constructor).
"""
@quarantine pin"precedent(dart: pkg/kernel/lib/src/ast/components.dart:12 Component)" "the front end's program, dart's CfeResult.component (src/compile.jl CfeResult); Julia differs: its trim inference returns the closed world as an untyped list of CodeInstance and CodeInfo pairs, inferred at the one world it is given (julia/Compiler/src/typeinfer.jl:1534 typeinf_ext_toplevel)" Core.Any struct ClosedWorld
    entry::Core.MethodInstance
    codeinfos::Vector{Any}
    notes::Vector{TrimError}
    parents::IdDict{Core.CodeInstance,Tuple{Core.CodeInstance,Int}}
    world::UInt
    ClosedWorld(::_SubsetToken, entry::Core.MethodInstance, codeinfos::Vector{Any}, notes::Vector{TrimError},
                parents::IdDict{Core.CodeInstance,Tuple{Core.CodeInstance,Int}}, world::UInt) = new(entry, codeinfos, notes, parents, world)
end

# Julia's closed-world inference for trimming at `world`, of its queue: the entry's MethodInstance and
# each @ccallable as `svec(rettype, signature)`, the item juliac queues for one
# (juliac-buildscript.jl's jl_add_ccallable_entrypoints), whose specialization the inference compiles
# and whose record it keeps for the verifier. It is typeinf_ext_toplevel's trim entry over
# WasmInterpreter (lib/WasmInterpreter), so the closed world is inferred over WasmTarget's overlays,
# walked by Julia's own Compiler.compile!; the walk lives in that package, whose image holds its
# compiled code apart from WasmTarget's.
@quarantine "the closed world is inferred by Julia's trim entry over WasmTarget's interpreter, a package of its own" WasmTarget.infer_closed_world _trim_infer(queue::Vector{Any}, world::UInt)::Vector{Any} =
    infer_closed_world(queue, world)

# Julia's trim verifier over the closed world: TrimVerifier.get_verify_typeinf_trim (Julia's
# Compiler/src/verifytrim.jl) with one change. Julia's takes as a resolved callee only a native
# CodeInstance (owner nothing), where every one the closed world holds is WasmTarget's
# (`WasmCacheOwner`, src/julia/interpreter.jl); each body is judged by Julia's own verify_codeinstance!, and each queued
# ccallable's svec by Julia's check of its declared return against inference (CCallableMissing), as
# 1.12 and 1.13 write it.
@quarantine pin"precedent(julia: Compiler/src/verifytrim.jl:300 get_verify_typeinf_trim)" "Julia's trim verifier resolves a callee among native CodeInstances alone; the closed world's are WasmTarget's" Core.Compiler.TrimVerifier.verify_codeinstance! function _verify_trim(codeinfos::Vector{Any}, this_world::UInt, at::String)
    local interp = Core.Compiler.NativeInterpreter(this_world)
    local inspected = Base.IdSet{Core.CodeInstance}()
    local caches = IdDict{Core.MethodInstance,Core.CodeInstance}()
    local errors = Core.Compiler.TrimVerifier.ErrorList()
    local parents = Core.Compiler.TrimVerifier.ParentMap()
    for item in codeinfos
        item isa Core.CodeInstance || continue
        push!(inspected, item)
        if item.owner === WasmCacheOwner() && item.min_world <= this_world <= item.max_world
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
# symbol, the user's to rename, a ProgramError naming both methods, located at `at` (WasmTarget's
# judgment, not Julia's verifier's)
@quarantine "a C name names one symbol of juliac's image; two methods sharing one are the program's error" Core.MethodInstance function _check_export_names(entry::Core.MethodInstance, codeinfos::Vector{Any}, at::String)::Nothing
    local by_name = Dict{String,Core.MethodInstance}()
    for x in codeinfos
        x isa Core.CodeInstance && x.def isa Core.MethodInstance || continue
        local mi = x.def
        local name = program_export_name(mi, entry)
        name === nothing && continue
        local other = get!(by_name, name, mi)
        other === mi && continue
        reject!(ProgramError("$(other.def) and $(mi.def) both export the name \"$name\": one symbol for two methods; give one a name of its own (Base.@ccallable \"name\" f(...))"), at)
    end
    return nothing
end

# The runtime's roots, RUNTIME_ROOTS (src/julia/packages.jl), dev/skeleton.jl's generated block: each
# `(module path, name)`, every Runtime port whose anchored dart declaration carries
# @pragma('wasm:entry-point') and every function of Julia's own runtime (src/julia/runtime/rtutils.jl's
# section of it: the raisers, jl_egal, a type tag's type), rooted in every closed world as dart's tree
# shaker roots every entry point in every program
# (pkg/vm/lib/transformations/type_flow/native_code.dart:144 PragmaEntryPointsVisitor.visitProcedure),
# so the code generator finds each one's method wherever it lowers a call of it. Julia differs: libjulia
# is linked whole, no demand keeping one of its functions out, and the code generator emits a root only
# where its code calls it.

# a root's function, resolved in `mod` along its module path, or nothing
@quarantine "a root names its function by module path and name, resolved where the package loaded, as dart's visitor reads each annotated procedure (pkg/vm/lib/transformations/type_flow/native_code.dart:144 PragmaEntryPointsVisitor.visitProcedure)" Core.getglobal function _runtime_entry_function(mod::Module, path::Tuple{Vararg{Symbol}}, name::Symbol)::Union{Function,Nothing}
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
    check_runtime_roots(mod, roots) -> Int

The runtime roots' check: each of `roots` (RUNTIME_ROOTS' form) names a function of `mod` with exactly
one method, its signature the root `check_subset` queues; throws a `ConstructionViolation` naming the
first that does not.

precedent(juliac: an entrypoint with no matching method fails the build, jl_add_ccallable_entrypoints
and Base.Experimental.entrypoint). Julia's differs: the roots are data, so the load resolves them.
"""
@quarantine "the runtime roots are resolved when the package loads, by Julia's method table, as dart's visitor resolves each annotated procedure (pkg/vm/lib/transformations/type_flow/native_code.dart:144 PragmaEntryPointsVisitor.visitProcedure)" Base.methods function check_runtime_roots(mod::Module, roots)::Int
    for (path, name) in roots
        local f = _runtime_entry_function(mod, path, name)
        f === nothing && throw(ConstructionViolation("RUNTIME_ROOTS", "$(join((path..., name), '.')) names no function"))
        local n = length(methods(f))
        n == 1 || throw(ConstructionViolation("RUNTIME_ROOTS", "$(join((path..., name), '.')) has $n methods, not one"))
    end
    return 0
end

# the MethodInstance of each runtime root at `world`, its one method's compileable specialization, as
# the entry's
@quarantine "a runtime root is the specialization Julia compiles for it, as juliac's entrypoint takes it, and every one is a root, as dart's visitor roots each (pkg/vm/lib/transformations/type_flow/native_code.dart:144 PragmaEntryPointsVisitor.visitProcedure)" Base.methods function _runtime_roots(world::UInt)::Vector{Any}
    local out = Any[]
    for (path, name) in RUNTIME_ROOTS
        local f = something(_runtime_entry_function(@__MODULE__, path, name))
        push!(out, something(_entry_specialization(only(methods(f)).sig, world)))
    end
    return out
end

# The closed world Julia infers for `queue` and its verifier's verdict: the inferred items, the
# warnings and the parents; an error rejects as OutsideSubset, located at `at`
@quarantine pin"precedent(julia: Compiler/src/verifytrim.jl:361 verify_typeinf_trim)" "the verifier judges what Julia's trim inference returned, errors fatal and warnings notes, as juliac" Base.push! function _infer_verified(queue::Vector{Any}, world::UInt, at::String)
    local codeinfos = _trim_infer(queue, world)
    local errors, parents = _verify_trim(codeinfos, world, at)
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
@quarantine "the verifier's error and the stack frames Julia builds for it (julia/Compiler/src/verifytrim.jl:125 verify_create_stackframes), kept as Julia gives them" Core.Compiler.TrimVerifier.verify_create_stackframes function _trim_error(@nospecialize(cause), parents, at::String)::TrimError
    local kind = get(TRIM_ERROR_KINDS, string(cause.desc), nothing)
    kind === nothing && reject!(Internal("src/julia/subset.jl TRIM_ERROR_KINDS: Julia $VERSION's trim verifier reports \"$(cause.desc)\", a description it has no kind for"), at)
    cause isa Core.Compiler.TrimVerifier.CCallableMissing && return TrimError(kind, nothing, 0, Base.StackTraces.StackFrame[], TrimCCallableMissing(cause))
    cause isa Core.Compiler.TrimVerifier.CallMissing ||
        reject!(Internal("src/julia/subset.jl _trim_error: Julia $VERSION's trim verifier reports a $(typeof(cause)), a record it has no kind for (TrimCause)"), at)
    # the chain of parents from the error's CodeInstance, cut where it meets one already on it: a
    # departure from Julia's, which has no repeat guard. verify_codeinstance! (verifytrim.jl:182) records a
    # parent for every invoke edge, inspected or not, so a recursion back to a root (the entry or a
    # runtime root, one calling another) gives the root a parent and the map a cycle, and
    # verify_create_stackframes (verifytrim.jl:125) follows the map until it ends, which a cycle never
    # does: juliac's walk would not end either. Here the frames end at the first repeat.
    local chain = Core.Compiler.TrimVerifier.ParentMap()
    local seen = Base.IdSet{Core.CodeInstance}((cause.codeinst,))
    local ci = cause.codeinst
    while true
        local p = get(parents, ci, nothing)
        (p === nothing || p[1] in seen) && break
        chain[ci] = p
        push!(seen, p[1])
        ci = p[1]
    end
    return TrimError(kind, cause.codeinst, cause.stmtidx, Core.Compiler.TrimVerifier.verify_create_stackframes(cause.codeinst, cause.stmtidx, chain),
                     TrimCallMissing(cause))
end

"""
    check_subset(f, argtypes::Tuple, at::String, world::UInt) -> ClosedWorld

Infer the program `f(argtypes...)` once, at `world` (compile's, the one world of a compile: the verifier and every
later stage read it from here and from the ClosedWorld), as Julia's trimming does, from the specialization Julia
compiles for that call (`_entry_specialization`), and let Julia's trim verifier judge it. Returns the
closed world it accepts; rejects with `OutsideSubset` when the entry has no unique method (Julia's
`which` text) or no compileable specialization, or the verifier reports errors, each a `TrimError`
holding Julia's own record, its statement and its stack frames.

formal(dev/formal/NirHandoff.tla): every reached ccallable's record queued and judged, none the entry never reaches
"""
@quarantine "the strict subset is the one Julia's trim verifier accepts over unmodified Base, never re-guessed (julia/Compiler/src/verifytrim.jl:300 get_verify_typeinf_trim), its roots the entry and the runtime's, as juliac adds each entrypoint (julia/src/gf.c:3910 jl_add_entrypoint)" Base.signature_type function check_subset(@nospecialize(f), argtypes::Tuple, at::String, world::UInt)::ClosedWorld
    local sig = Base.signature_type(f, argtypes)
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
    # the runtime's roots, every one queued beside the entry (RUNTIME_ROOTS), before it, so Julia's
    # inference returns the program's bodies first and the closed world keeps program order (its classes
    # met from the entry's callable on)
    local roots = _runtime_roots(world)
    local codeinfos, notes, parents = _infer_verified(Any[roots; entry], world, at)
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
    return ClosedWorld(_SubsetToken(), entry, codeinfos, notes, parents, world)
end

# the typestate's assertion, run when the package loads: ClosedWorld and its token each have one
# constructor method, both in this file, ClosedWorld's taking the token (a construction, L220); and
# its next state, src/julia/nir.jl's NirWorld, which build_nir makes from a ClosedWorld, the same
@quarantine "the typestate's assertion, run when the package loads, its runtime roots each resolved to one method as juliac resolves an entrypoint (julia/src/gf.c:3910 jl_add_entrypoint)" Base.Val construction_check(::Val{:ClosedWorld})::Int =
    check_sole_constructor(ClosedWorld, _SubsetToken, @__FILE__) +
    check_sole_constructor(NirWorld, _NirToken, joinpath(@__DIR__, "nir.jl")) +
    # a ClosedWorld holds every runtime root: each one names one method
    check_runtime_roots(@__MODULE__, RUNTIME_ROOTS)

# no method of WasmTarget but check_subset names the token or makes either: read in every method's
# lowered code when the package loads. A stopgap, not a construction (L224): Julia has no module
# privacy, so the wrong choice stays writable and this read finds it (A36S3, A37S1, A38)
@quarantine "Julia has no module privacy; WasmTarget's own lowered code is read when the package loads" Base.moduleroot check_closed_world_makers()::Int =
    check_sole_maker(Base.moduleroot(@__MODULE__), ClosedWorld, _SubsetToken, (only(methods(check_subset)),),
                     (which(check_closed_world_makers, Tuple{}), which(construction_check, Tuple{Val{:ClosedWorld}})),
                     (joinpath(@__DIR__, "parity.jl"), joinpath(@__DIR__, "construction.jl")))
