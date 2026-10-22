# NIR, the IR codegen consumes (dev/MARCH.md 1.A10): Julia's own optimized statement forms, read once
# from the ClosedWorld Julia's trim verifier accepted (src/julia/subset.jl), each statement a kind of
# one closed sum and each operand a kind of another, with the type Julia inferred for every statement.
# Nothing here guesses a type or re-derives an answer Julia gave: a statement keeps Julia's form and its
# operands, a literal is Julia's own `Core.Const`, and a statement's type is its `ssavaluetypes` entry,
# or, for a body Julia stored without them (a constant return), its CodeInstance's `rettype`. A form
# outside the census is a located rejection, never a guess. WT1's NIR (legacy/src/frontend/nir.jl) is
# not carried: an open abstract node type, `Any` fields and comment anchors fail WT2's load-time checks.

"""An operand that is a statement's value, Julia's `Core.SSAValue`; `id` its statement."""
@quarantine "Julia's optimized IR names a statement's value by SSAValue; dart's Kernel nests the subexpression" Core.SSAValue struct NirSSA
    id::Int
end

"""An operand that is an argument, Julia's `Core.Argument`; `n` its position, 1 the callee itself."""
@quarantine "Julia's optimized IR names an argument by its position, Core.Argument" Core.Argument struct NirArgument
    n::Int
end

"""An operand that is a module binding, Julia's `GlobalRef`, as Julia wrote it."""
@quarantine "Julia's optimized IR reads a module binding through a GlobalRef" Core.GlobalRef struct NirGlobal
    ref::GlobalRef
end

"""An operand that is a literal (a `QuoteNode`'s payload or any other constant), as Julia's own
`Core.Const` lattice element holds it."""
@quarantine "Julia's literal operands are any value; Julia's Const lattice element holds one" Core.QuoteNode struct NirConst
    c::Core.Const
end

"""
    NirValue

An operand of a NIR statement: `NirSSA`, `NirArgument`, `NirGlobal` or `NirConst`, the four forms an
operand of Julia's optimized IR takes. A closed sum by construction: a `Union` of concrete structs that
subtype nothing, `@closed`, and `value_form` its `@exhaustive` match, checked when the package loads
(`construction_check(::Val{:NirValue})`).

precedent(rust: enum + exhaustive match; dart: sealed class + exhaustive switch). Julia's differs: a
`Union` of concrete types, its exhaustiveness checked when the package loads.
"""
@quarantine "a closed sum is a Union in Julia, which has no sealed classes or enums" Core.Union @closed const NirValue = Union{NirSSA, NirArgument, NirGlobal, NirConst}

# an operand's form, one arm per kind (dart's switch over a sealed class)
@quarantine "the operand sum's one match, an exhaustive switch where dart switches over a sealed class" Core.String function value_form(v::NirValue)::String
    @exhaustive v::NirValue begin
        NirSSA => "ssa"
        NirArgument => "argument"
        NirGlobal => "global"
        NirConst => "literal"
    end
end

# ---- the statement kinds, one per form of Julia's optimized IR ----------------------------------
"""`Expr(:call, f, args...)`: a call Julia's optimizer left; `args` its operands, the callee first."""
@quarantine "Julia's optimized IR keeps a call as Expr(:call)" Core.Expr struct NirCall
    args::Vector{NirValue}
end
"""`Expr(:invoke, target, f, args...)`: a call Julia resolved; `target` the instance it calls."""
@quarantine "Julia's optimized IR resolves a call to its MethodInstance or CodeInstance, Expr(:invoke)" Core.Expr struct NirInvoke
    target::Union{Core.MethodInstance, Core.CodeInstance}
    args::Vector{NirValue}
end
"""`Expr(:new, T, fields...)`: an allocation; `args` its type operand and fields."""
@quarantine "Julia's optimized IR allocates with Expr(:new)" Core.Expr struct NirNew
    args::Vector{NirValue}
end
"""`Expr(:foreigncall, name, rt, argtypes, nreq, cc, args...)`: a foreign call, its operands as Julia wrote them."""
@quarantine "Julia's optimized IR calls a foreign function with Expr(:foreigncall)" Core.Expr struct NirForeignCall
    args::Vector{NirValue}
end
"""`Expr(:boundscheck[, flag])`: whether bounds are checked here."""
@quarantine "Julia's bounds-check elision, Expr(:boundscheck); dart has none" Core.Expr struct NirBoundscheck
    args::Vector{NirValue}
end
"""`Expr(:gc_preserve_begin, values...)`: the values kept alive until its end."""
@quarantine "Julia's GC preservation regions, Expr(:gc_preserve_begin); WasmGC needs none but the IR holds them" Core.Expr struct NirGCPreserveBegin
    args::Vector{NirValue}
end
"""`Expr(:gc_preserve_end, token)`: the end of a preservation region."""
@quarantine "Julia's GC preservation regions, Expr(:gc_preserve_end)" Core.Expr struct NirGCPreserveEnd
    args::Vector{NirValue}
end
"""`Expr(:leave, tokens...)`: leaving try regions."""
@quarantine "Julia's try regions are left with Expr(:leave)" Core.Expr struct NirLeave
    args::Vector{NirValue}
end
"""`Expr(:pop_exception, token)`: restoring the exception stack after a catch."""
@quarantine "Julia's exception stack, Expr(:pop_exception)" Core.Expr struct NirPopException
    args::Vector{NirValue}
end
"""`Expr(:the_exception)`: the exception a catch region received."""
@quarantine "Julia's caught exception, Expr(:the_exception)" Core.Expr struct NirTheException
    args::Vector{NirValue}
end
"""`Expr(:loopinfo, hints...)`: loop hints, with no effect on a value."""
@quarantine "Julia's loop hints, Expr(:loopinfo)" Core.Expr struct NirLoopInfo
    args::Vector{NirValue}
end
"""`Expr(:throw_undef_if_not, name, cond)`: an UndefVarError unless `cond`."""
@quarantine "Julia's undefined-variable check, Expr(:throw_undef_if_not)" Core.Expr struct NirThrowUndefIfNot
    args::Vector{NirValue}
end
"""`Expr(:cfunction, ...)`: a C function pointer to a Julia function, its operands as Julia wrote them."""
@quarantine "Julia's @cfunction, Expr(:cfunction)" Core.Expr struct NirCFunction
    args::Vector{NirValue}
end
"""`Expr(:invoke_modify, ...)`: a resolved modifyfield!-style call, its operands as Julia wrote them."""
@quarantine "Julia's resolved atomic modify, Expr(:invoke_modify)" Core.Expr struct NirInvokeModify
    args::Vector{NirValue}
end
"""`Core.GotoNode`: a jump to statement `label`."""
@quarantine "Julia's IR is a flat statement list with GotoNode jumps; dart's Kernel is structured" Core.GotoNode struct NirGoto
    label::Int
end
"""`Core.GotoIfNot`: a jump to statement `dest` unless `cond`."""
@quarantine "Julia's conditional jump, GotoIfNot" Core.GotoIfNot struct NirGotoIfNot
    cond::NirValue
    dest::Int
end
"""`Core.ReturnNode` with a value: the body returns `val`."""
@quarantine "Julia's return, ReturnNode" Core.ReturnNode struct NirReturn
    val::NirValue
end
"""`Core.ReturnNode` with no value: a statement Julia proved unreachable."""
@quarantine "Julia marks unreachable code with a ReturnNode of no value" Core.ReturnNode struct NirUnreachable
end
"""`Core.PhiNode`: the value from the predecessor statement `edges[k]` is `values[k]`, `nothing` where unassigned."""
@quarantine "Julia's optimized IR is in SSA form, PhiNode; dart's Kernel merges through variables" Core.PhiNode struct NirPhi
    edges::Vector{Int32}
    values::Vector{Union{Nothing, NirValue}}
end
"""`Core.PiNode`: `val` narrowed to `typ` on this path, as Julia's inference proved."""
@quarantine "Julia's PiNode narrows a value to a type on one path" Core.PiNode struct NirPi
    val::NirValue
    typ::Type
end
"""`Core.EnterNode`: a try region whose catch begins at statement `catch_dest`; `scope` its scope, if any."""
@quarantine "Julia's try regions, EnterNode" Core.EnterNode struct NirEnter
    catch_dest::Int
    scope::Union{Nothing, NirValue}
end
"""`Core.UpsilonNode`: a value a PhiC of a catch region receives, `nothing` where unassigned."""
@quarantine "Julia's exception phis, UpsilonNode" Core.UpsilonNode struct NirUpsilon
    val::Union{Nothing, NirValue}
end
"""`Core.PhiCNode`: the value a catch region receives from its Upsilons."""
@quarantine "Julia's exception phis, PhiCNode" Core.PhiCNode struct NirPhiC
    values::Vector{NirValue}
end
"""A `nothing` statement: a statement the optimizer emptied."""
@quarantine "Julia's optimizer leaves an emptied statement as nothing" Core.Nothing struct NirNothing
end
"""A statement that is a `GlobalRef`: a read of a module binding."""
@quarantine "Julia's optimized IR can read a binding as a statement of its own" Core.GlobalRef struct NirGlobalRead
    ref::GlobalRef
end

"""
    NirStmt

A NIR statement: one kind per form of Julia's optimized IR, holding Julia's own operands. A closed sum
by construction: a `@closed` `Union` of concrete structs that subtype nothing, `stmt_form` its
`@exhaustive` match, checked when the package loads (`construction_check(::Val{:NirStmt})`); a form
Julia adds is an edit of this line, and every match over it then owes its arm at load.

precedent(rust: enum + exhaustive match; dart: sealed class + exhaustive switch, kernel_nodes.dart's
node kinds). Julia's differs: a `Union` of concrete types, its exhaustiveness checked when the package
loads.
"""
@quarantine "a closed sum is a Union in Julia, which has no sealed classes or enums" Core.Union @closed const NirStmt = Union{
    NirCall, NirInvoke, NirNew, NirForeignCall, NirBoundscheck, NirGCPreserveBegin, NirGCPreserveEnd,
    NirLeave, NirPopException, NirTheException, NirLoopInfo, NirThrowUndefIfNot, NirCFunction,
    NirInvokeModify, NirGoto, NirGotoIfNot, NirReturn, NirUnreachable, NirPhi, NirPi, NirEnter,
    NirUpsilon, NirPhiC, NirNothing, NirGlobalRead}

# a statement's form, one arm per kind (dart's switch over a sealed class)
@quarantine "the statement sum's one match, an exhaustive switch where dart switches over a sealed class" Core.String function stmt_form(st::NirStmt)::String
    @exhaustive st::NirStmt begin
        NirCall => "call"
        NirInvoke => "invoke"
        NirNew => "new"
        NirForeignCall => "foreigncall"
        NirBoundscheck => "boundscheck"
        NirGCPreserveBegin => "gc_preserve_begin"
        NirGCPreserveEnd => "gc_preserve_end"
        NirLeave => "leave"
        NirPopException => "pop_exception"
        NirTheException => "the_exception"
        NirLoopInfo => "loopinfo"
        NirThrowUndefIfNot => "throw_undef_if_not"
        NirCFunction => "cfunction"
        NirInvokeModify => "invoke_modify"
        NirGoto => "goto"
        NirGotoIfNot => "gotoifnot"
        NirReturn => "return"
        NirUnreachable => "unreachable"
        NirPhi => "phi"
        NirPi => "pi"
        NirEnter => "enter"
        NirUpsilon => "upsilon"
        NirPhiC => "phic"
        NirNothing => "nothing"
        NirGlobalRead => "global"
    end
end

"""
    NirBody

One function of the closed world in NIR: `ci`, the CodeInstance Julia inferred; `stmts`, its statements
in Julia's order; `types`, the type Julia inferred for each statement.
"""
@quarantine "a function of the closed world is a CodeInstance and its optimized CodeInfo, Julia's own" Core.CodeInstance struct NirBody
    ci::Core.CodeInstance
    stmts::Vector{NirStmt}
    types::Vector{Type}
end

# ---- building --------------------------------------------------------------------------------------
# an operand of Julia's optimized IR as a NirValue; an IR node where a value belongs rejects, located
@quarantine "Julia's optimized IR operands: SSAValue, Argument, GlobalRef, or a literal Julia quotes or not" Core.SSAValue function _nir_operand(x, at::String)::NirValue
    x isa Core.SSAValue && return NirSSA(x.id)
    x isa Core.Argument && return NirArgument(x.n)
    x isa GlobalRef && return NirGlobal(x)
    x isa QuoteNode && return NirConst(Core.Const(x.value))
    x isa Union{Expr, Core.SlotNumber, Core.NewvarNode, Core.PhiNode, Core.PiNode, Core.GotoNode, Core.GotoIfNot,
                Core.ReturnNode, Core.EnterNode, Core.UpsilonNode, Core.PhiCNode} &&
        reject!(Unquarantined("src/julia/nir.jl: an operand of Julia's form $(typeof(x)), outside NirValue"), at)
    return NirConst(Core.Const(x))
end

# a foreigncall's name operand: Julia 1.13 writes a constant name tuple as tuple syntax,
# Expr(:tuple, :memmove) for (:memmove,), which Julia's own codegen reads as that tuple; a literal
# otherwise (1.12), and a name computed at run time rejects, located
@quarantine "Julia 1.13 writes a foreigncall's constant name as tuple syntax, which its codegen reads as the tuple" Core.Expr function _nir_ccall_name(x, at::String)::NirValue
    x isa Expr && x.head === :tuple || return _nir_operand(x, at)
    local vals = Any[a isa QuoteNode ? a.value : a for a in x.args]
    any(v -> v isa Union{Expr, Core.SSAValue, Core.Argument, GlobalRef, Core.SlotNumber}, vals) &&
        reject!(Unquarantined("src/julia/nir.jl: a foreigncall whose name is computed at run time"), at)
    return NirConst(Core.Const(Tuple(vals)))
end

# a statement of Julia's optimized IR as its NirStmt kind; a form outside the census rejects, located
@quarantine "Julia's optimized statement forms, read as they are" Core.Expr function _nir_stmt(st, at::String)::NirStmt
    if st isa Expr
        local h = st.head
        local ops(xs) = NirValue[_nir_operand(a, at) for a in xs]
        h === :call && return NirCall(ops(st.args))
        if h === :invoke
            local t = st.args[1]
            t isa Union{Core.MethodInstance, Core.CodeInstance} ||
                reject!(Unquarantined("src/julia/nir.jl: an invoke of a $(typeof(t)), not a MethodInstance or CodeInstance"), at)
            return NirInvoke(t, ops(st.args[2:end]))
        end
        h === :new && return NirNew(ops(st.args))
        h === :foreigncall && return NirForeignCall(NirValue[_nir_ccall_name(st.args[1], at); ops(st.args[2:end])])
        h === :boundscheck && return NirBoundscheck(ops(st.args))
        h === :gc_preserve_begin && return NirGCPreserveBegin(ops(st.args))
        h === :gc_preserve_end && return NirGCPreserveEnd(ops(st.args))
        h === :leave && return NirLeave(ops(st.args))
        h === :pop_exception && return NirPopException(ops(st.args))
        h === :the_exception && return NirTheException(ops(st.args))
        h === :loopinfo && return NirLoopInfo(ops(st.args))
        h === :throw_undef_if_not && return NirThrowUndefIfNot(ops(st.args))
        h === :cfunction && return NirCFunction(ops(st.args))
        h === :invoke_modify && return NirInvokeModify(ops(st.args))
        reject!(Unquarantined("src/julia/nir.jl: Julia's statement form Expr(:$h), outside NirStmt"), at)
    end
    st isa Core.GotoNode && return NirGoto(st.label)
    st isa Core.GotoIfNot && return NirGotoIfNot(_nir_operand(st.cond, at), st.dest)
    st isa Core.ReturnNode && return isdefined(st, :val) ? NirReturn(_nir_operand(st.val, at)) : NirUnreachable()
    st isa Core.PhiNode && return NirPhi(copy(st.edges),
        Union{Nothing, NirValue}[isassigned(st.values, k) ? _nir_operand(st.values[k], at) : nothing for k in eachindex(st.values)])
    if st isa Core.PiNode
        st.typ isa Type || reject!(Unquarantined("src/julia/nir.jl: a PiNode narrowing to $(typeof(st.typ)), not a Type"), at)
        return NirPi(_nir_operand(st.val, at), st.typ)
    end
    st isa Core.EnterNode && return NirEnter(st.catch_dest, isdefined(st, :scope) ? _nir_operand(st.scope, at) : nothing)
    st isa Core.UpsilonNode && return NirUpsilon(isdefined(st, :val) ? _nir_operand(st.val, at) : nothing)
    st isa Core.PhiCNode && return NirPhiC(NirValue[_nir_operand(v, at) for v in st.values])
    st === nothing && return NirNothing()
    st isa GlobalRef && return NirGlobalRead(st)
    reject!(Unquarantined("src/julia/nir.jl: Julia's statement form $(typeof(st)), outside NirStmt"), at)
end

# a sample of each mirror's Julia form, built by Julia's own constructors: converted at load, each must
# come back as the mirror that names its form (check_mirrors, src/julia/parity.jl; A39S1)
mirror_samples!(_nir_operand, :NirValue,
    NirSSA => Core.SSAValue(1), NirArgument => Core.Argument(2), NirGlobal => GlobalRef(Base, :sin),
    NirConst => QuoteNode(1))
mirror_samples!(_nir_stmt, :NirStmt,
    NirCall => Expr(:call, GlobalRef(Base, :+), Core.SSAValue(1), 1),
    NirInvoke => Expr(:invoke, Core.Compiler.specialize_method(only(methods(+, (Int, Int))), Tuple{typeof(+), Int, Int}, Core.svec()),
                      GlobalRef(Base, :+), Core.SSAValue(1), 1),
    NirNew => Expr(:new, GlobalRef(Core, :Int), 1),
    NirForeignCall => Expr(:foreigncall, QuoteNode(:jl_gc_safepoint), Nothing, Core.svec(), 0, QuoteNode(:ccall)),
    NirBoundscheck => Expr(:boundscheck, true), NirGCPreserveBegin => Expr(:gc_preserve_begin, Core.SSAValue(1)),
    NirGCPreserveEnd => Expr(:gc_preserve_end, Core.SSAValue(1)), NirLeave => Expr(:leave, Core.SSAValue(1)),
    NirPopException => Expr(:pop_exception, Core.SSAValue(1)), NirTheException => Expr(:the_exception),
    NirLoopInfo => Expr(:loopinfo), NirThrowUndefIfNot => Expr(:throw_undef_if_not, QuoteNode(:x), true),
    NirCFunction => Expr(:cfunction, Ptr{Cvoid}, QuoteNode(:f), Int, Core.svec(), QuoteNode(:ccall)),
    NirInvokeModify => Expr(:invoke_modify, Core.SSAValue(1)),
    NirGoto => Core.GotoNode(2), NirGotoIfNot => Core.GotoIfNot(Core.SSAValue(1), 3),
    NirReturn => Core.ReturnNode(Core.SSAValue(1)), NirUnreachable => Core.ReturnNode(),
    NirPhi => Core.PhiNode(Int32[1], Any[Core.SSAValue(1)]), NirPi => Core.PiNode(Core.SSAValue(1), Int),
    NirEnter => Core.EnterNode(3), NirUpsilon => Core.UpsilonNode(Core.SSAValue(1)),
    NirPhiC => Core.PhiCNode(Any[Core.SSAValue(1)]), NirNothing => nothing, NirGlobalRead => GlobalRef(Base, :sin))

# each statement's type, Julia's: its ssavaluetypes entry; a body Julia stored without them (a constant
# return, ssavaluetypes a count) has the one statement, typed by its CodeInstance's rettype
@quarantine "Julia's inferred statement types, CodeInfo.ssavaluetypes, or the CodeInstance's rettype where Julia stored none" Core.CodeInfo function _nir_types(ci::Core.CodeInstance, src::Core.CodeInfo, at::String)::Vector{Type}
    local ts = src.ssavaluetypes
    if ts isa Vector
        length(ts) == length(src.code) || reject!(Internal("src/julia/nir.jl: $(length(ts)) statement types for $(length(src.code)) statements"), at)
        return Type[t isa Type ? t : reject!(Unquarantined("src/julia/nir.jl: a statement type $(typeof(t)), not a Type"), at) for t in ts]
    end
    length(src.code) == 1 && src.code[1] isa Core.ReturnNode ||
        reject!(Unquarantined("src/julia/nir.jl: a body of $(length(src.code)) statements with no statement types"), at)
    return Type[ci.rettype]
end

"""
    build_nir(world::ClosedWorld, at::String) -> Vector{NirBody}

Every function of the closed world Julia's trim verifier accepted, in NIR, in Julia's order: each
statement its kind of `NirStmt`, each operand of `NirValue`, each type Julia's. A form outside the
census rejects with `Unquarantined`, located at the compile `at` names.
"""
@quarantine "the closed world Julia inferred comes as CodeInstance and CodeInfo pairs, read once" Core.CodeInfo function build_nir(world::ClosedWorld, at::String)::Vector{NirBody}
    local xs = world.codeinfos
    iseven(length(xs)) || reject!(Internal("src/julia/nir.jl: the closed world holds $(length(xs)) entries, not CodeInstance and CodeInfo pairs"), at)
    local bodies = NirBody[]
    for k in 1:2:length(xs)
        local ci = xs[k]; local src = xs[k + 1]
        ci isa Core.CodeInstance && src isa Core.CodeInfo ||
            reject!(Internal("src/julia/nir.jl: the closed world's entry $k is a $(typeof(ci)) and $(typeof(src)), not a CodeInstance and its CodeInfo"), at)
        push!(bodies, NirBody(ci, NirStmt[_nir_stmt(st, at) for st in src.code], _nir_types(ci, src, at)))
    end
    return bodies
end

# the two closed sums' assertions, run when the package loads
@quarantine "the operand sum's assertion, run when the package loads" Base.Val construction_check(::Val{:NirValue})::Int = check_sum_matched(@__MODULE__, :NirValue)
@quarantine "the statement sum's assertion, run when the package loads" Base.Val construction_check(::Val{:NirStmt})::Int = check_sum_matched(@__MODULE__, :NirStmt)
