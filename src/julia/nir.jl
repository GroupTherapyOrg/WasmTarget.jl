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

# A literal keys the constant caches (constants.jl's constantInfo, dart's canonicalization by
# identity), so its hash must cost what === costs. Julia's objectid of an immutable value walks
# every path through its fields, which is exponential on a constant whose fields share heap objects:
# a 40-level DAG is 2^40 paths. === stops at a shared heap object, so it is linear there. The hash
# walks a structured immutable's fields depth first, in field order, over at most 64 values: equal (===) literals take the same walk, so the hash agrees with ===, its cost is bounded
# whatever the sharing, and same-type literals that differ in their first values hash apart (a hash
# by the type alone made N of them collide, the cache quadratic, A51S13). A value Julia stores flat
# (isbits), a String, Symbol or Type is hashed itself, and a mutable object by its address (objectid).
# formal(dev/formal/ConstantHash.tla): the hash agrees with ===, its walk bounded, a key's hash stable
@quarantine "a literal's hash agrees with === at a bounded cost: Julia's objectid recurses through every path of an immutable value" Base.hash Base.hash(c::NirConst, h::UInt)::UInt = _bounded_hash(c.c.val, h, Ref(64))

@quarantine "an immutable value's hash over its first values, depth first, at most a fixed count of them" Base.hash function _bounded_hash(@nospecialize(v), h::UInt, budget::Base.RefValue{Int})::UInt
    budget[] -= 1
    (isbits(v) || v isa Union{String,Symbol,Type}) && return hash(v, h)
    # a mutable object is told by its address, as === tells it, never its contents (which change, and
    # may contain the object itself)
    ismutable(v) && return hash(objectid(v), h)
    h = hash(typeof(v), h)
    for i in 1:nfields(v)
        budget[] <= 0 && break
        h = isdefined(v, i) ? _bounded_hash(getfield(v, i), h, budget) : hash(i, h)
    end
    return h
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
    NirHandlers

A body's try regions as Julia's compiler answers them: `handler_at[i]`, the statement of the
EnterNode whose catch handles statement `i`, 0 where none does (compute_trycatch's catch handler),
and `nothrow[i]`, whether statement `i` sends no exception to its handler as Julia's inference
decides it: a return or a :leave never does, every other statement unless it carries IR_FLAG_NOTHROW.
The stackifier reads them as LLVM reads an invoke's unwind edge (src/julia/machine.jl).
"""
@quarantine "Julia's compiler answers each statement's try handler and whether it can throw; the stackifier reads both" Base.BitVector struct NirHandlers
    handler_at::Vector{Int}
    nothrow::BitVector
end

"""
    NirBody

One function of the closed world in NIR: `ci`, the CodeInstance Julia inferred; `stmts`, its statements
in Julia's order; `types`, the type Julia inferred for each statement; `cfg`, Julia's CFG of the
statements (compute_basic_blocks), and `handlers`, its try regions (NirHandlers), which the
stackifier reads beside them (src/julia/machine.jl).
"""
@quarantine "a function of the closed world is a CodeInstance and its optimized CodeInfo, Julia's own" Core.CodeInstance struct NirBody
    ci::Core.CodeInstance
    stmts::Vector{NirStmt}
    types::Vector{Type}
    cfg::Core.Compiler.CFG
    handlers::NirHandlers
end

# ---- building --------------------------------------------------------------------------------------
"""
    nir_code(code, ssaflags, at) -> (Vector{NirStmt}, Core.Compiler.CFG, NirHandlers)

The statements of an optimized CodeInfo's `code` in NIR, Julia's CFG of them (compute_basic_blocks,
whose blocks and edges name statements by their position, the same in both), and its try regions:
each statement's catch handler (compute_trycatch, over the CodeInfo's statements, whose catch
destinations are statements) and whether it sends no exception to that handler. The one reader of a
body's raw statements, so every later stage, the stackifier's included, reads the closed sums.

Whether a statement sends an exception to its handler is inference's rule (typeinf_local,
Compiler/src/abstractinterpretation.jl): a block's GotoNode, GotoIfNot and EnterNode carry
IR_FLAG_NOTHROW where they cannot throw; a ReturnNode and a :leave end their block without reaching
propagate_to_error_handler!, so neither throws whatever its flag (the optimizer's stmt_effect_flags
flags a :leave as it does any unknown head, not nothrow); every other statement throws unless
flagged.
"""
@quarantine "Julia's IR is a CFG compute_basic_blocks reads from its optimized statements, read here once" Core.Compiler.compute_basic_blocks function nir_code(code::Vector{Any}, ssaflags::Vector{UInt32}, at::String)::Tuple{Vector{NirStmt},Core.Compiler.CFG,NirHandlers}
    length(ssaflags) == length(code) || reject!(Internal("src/julia/nir.jl nir_code: $(length(ssaflags)) flags for $(length(code)) statements"), at)
    local info = Core.Compiler.compute_trycatch(code)
    local handler_at = info === nothing ? zeros(Int, length(code)) :
        Int[h == 0 ? 0 : info.handlers[h].enter_idx for (h, _) in info.handler_at]
    local nothrow = BitVector([code[i] isa Core.ReturnNode || Meta.isexpr(code[i], :leave) || ssaflags[i] & Core.Compiler.IR_FLAG_NOTHROW != 0
                               for i in eachindex(code)])
    return NirStmt[_nir_stmt(st, at) for st in code], Core.Compiler.compute_basic_blocks(code), NirHandlers(handler_at, nothrow)
end

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
# Expr(:tuple, :memmove) for (:memmove,), and Julia 1.12 a `(name, library)` tuple as a call of
# Core.tuple, Expr(:call, Core.tuple, :sin, "Math"), each of which Julia's own codegen reads as that
# tuple (ccall.cpp's static_eval); a literal otherwise, and a name computed at run time rejects, located
@quarantine "Julia writes a foreigncall's constant name as tuple syntax or a call of Core.tuple, which its codegen reads as the tuple" Core.Expr function _nir_ccall_name(x, at::String)::NirValue
    local elems = x isa Expr && x.head === :tuple ? x.args :
        x isa Expr && x.head === :call && x.args[1] == GlobalRef(Core, :tuple) ? x.args[2:end] : nothing
    elems === nothing && return _nir_operand(x, at)
    local vals = Any[a isa QuoteNode ? a.value : a for a in elems]
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

# The token only this file holds: NirWorld's sole constructor takes it, so no code outside this file
# makes a NirWorld (construction_check(::Val{:ClosedWorld}), src/julia/subset.jl).
@quarantine "Julia has no private constructors; an unexported token held by this file alone stands in for one" Core.DataType struct _NirToken
    _NirToken() = new()
end

"""
    NirWorld

The closed world in NIR, dart's Kernel `Component`: `entry`, the ClosedWorld's entry MethodInstance
(dart's Component.mainMethod), and `bodies`, every function of the ClosedWorld Julia's trim verifier
accepted, in Julia's order. Read as a list (iterate, index, length), never built as one.

A typestate by construction: its one constructor takes the token `_NirToken`, which only this file
holds, and `build_nir`, which takes a `ClosedWorld`, is its only caller, so a stage that takes a
`NirWorld` (the Translator's component) is reached by a program Julia's verifier accepted alone; a
`Vector{NirBody}` anyone can build would reopen that road (A41-M2).

precedent(rust: typestate with a private constructor, the value made by one function of its module).
Julia's differs: it has no private constructors, so the sole constructor and the token's are checked
by reflection when the package loads (check_sole_constructor), with ClosedWorld's: the next state of the
same typestate (construction_check(::Val{:ClosedWorld}), src/julia/subset.jl; L220).
"""
@quarantine "Julia has no private constructors; the NIR of a closed world is a typestate a token guards" Base.Vector struct NirWorld
    entry::Core.MethodInstance
    bodies::Vector{NirBody}
    NirWorld(::_NirToken, entry::Core.MethodInstance, bodies::Vector{NirBody}) = new(entry, bodies)
end

# the bodies read as a list: iterated, indexed and counted in Julia's order
@quarantine "Julia's iteration protocol reads a NirWorld's bodies as a list" Base.iterate Base.iterate(w::NirWorld, i::Int = 1) = iterate(w.bodies, i)
@quarantine "Julia's collection protocol counts a NirWorld's bodies" Base.length Base.length(w::NirWorld)::Int = length(w.bodies)
@quarantine "Julia's collection protocol names a NirWorld's element type" Base.eltype Base.eltype(::Type{NirWorld}) = NirBody
@quarantine "Julia's indexing reads a NirWorld's bodies by position" Base.getindex Base.getindex(w::NirWorld, i::Int)::NirBody = w.bodies[i]

"""
    nir_intrinsified(mi) -> Bool

Whether `mi` is a member the code generator's intrinsifier lowers at its call (src/intrinsics.jl,
read from the intrinsifier's own decision, generateStaticIntrinsic's): dart's `external` member,
whose call the intrinsifier meets and which has no body of its own. Julia's native body of one (a
String's data operations read and write its bytes through pointers, src/julia/wasm_array.jl) is
Julia's evaluation of it, not the program's, so the closed world's NIR never collects it; a call the
intrinsifier then declines finds no body and rejects, located (nir_body_of).

precedent(dart: an external member, which TFA records at its call and compiles no body for; LLVM: an
intrinsic declaration, a call with no definition). Julia's differs: every callee Julia infers has a
body, so the one the intrinsifier lowers is left out here.
"""
@quarantine "an intrinsified member has no body of its own, as dart's external member: its call is recorded, its body never collected" Core.MethodInstance nir_intrinsified(mi::Core.MethodInstance)::Bool =
    Dart2Wasm.generate_static_intrinsic(Val(:string_data_op), mi) !== nothing

"""
    build_nir(world::ClosedWorld, at::String) -> NirWorld

Every function of the closed world Julia's trim verifier accepted, in NIR, in Julia's order, but a
member the intrinsifier lowers at its call, whose body is never collected (nir_intrinsified): each
statement its kind of `NirStmt`, each operand of `NirValue`, each type Julia's. A form outside the
census rejects with `Unquarantined`, located at the compile `at` names.

formal(dev/formal/NirHandoff.tla): a record no body, one body per CodeInstance, a repeat asserted, each statement at its position
"""
@quarantine "the closed world Julia inferred comes as CodeInstance and CodeInfo pairs, read once" Core.CodeInfo function build_nir(world::ClosedWorld, at::String)::NirWorld
    # a queued ccallable's svec(rettype, signature) is the verifier's record, no body: its
    # specialization is a CodeInstance of the world like any other, which Julia's inference lists a
    # second time when its invokelatest queue compiles it (typeinfer.jl's compile!): one body here, the
    # repeat's CodeInfo asserted the first's (its statements and their types), never dropped unread
    local xs = Any[x for x in world.codeinfos if !(x isa Core.SimpleVector)]
    iseven(length(xs)) || reject!(Internal("src/julia/nir.jl: the closed world holds $(length(xs)) entries, not CodeInstance and CodeInfo pairs"), at)
    local bodies = NirBody[]
    local seen = IdDict{Core.CodeInstance,Core.CodeInfo}()
    for k in 1:2:length(xs)
        local ci = xs[k]; local src = xs[k + 1]
        ci isa Core.CodeInstance && src isa Core.CodeInfo ||
            reject!(Internal("src/julia/nir.jl: the closed world's entry $k is a $(typeof(ci)) and $(typeof(src)), not a CodeInstance and its CodeInfo"), at)
        local first_src = get(seen, ci, nothing)
        if first_src !== nothing
            (isequal(src.code, first_src.code) && isequal(src.ssavaluetypes, first_src.ssavaluetypes)) ||
                reject!(Internal("src/julia/nir.jl: the closed world lists $(ci.def) twice with different code"), at)
            continue
        end
        seen[ci] = src
        # an intrinsified member is dart's external member: its call stays in its caller's body, its own
        # body is never collected (nir_intrinsified)
        nir_intrinsified(ci.def) && ci.def !== world.entry && continue
        local stmts, cfg, handlers = nir_code(src.code, src.ssaflags, at)
        push!(bodies, NirBody(ci, stmts, _nir_types(ci, src, at), cfg, handlers))
    end
    any(b -> b.ci.def === world.entry, bodies) ||
        reject!(Internal("src/julia/nir.jl: the closed world's entry $(world.entry) has no body"), at)
    return NirWorld(_NirToken(), world.entry, bodies)
end

# the two closed sums' assertions, run when the package loads
@quarantine "the operand sum's assertion, run when the package loads" Base.Val construction_check(::Val{:NirValue})::Int = check_sum_matched(@__MODULE__, :NirValue)
@quarantine "the statement sum's assertion, run when the package loads" Base.Val construction_check(::Val{:NirStmt})::Int = check_sum_matched(@__MODULE__, :NirStmt)

# ---- what the code generator reads from a body (code_generator.jl), Julia's answers ----------------
"""
    TreeNode_no_offset

A NIR statement's file offset: dart's Kernel `TreeNode.noOffset` (-1), the offset of a node with no
position, which stops the source mapping; NIR carries no statement position until it reads Julia's
debuginfo.
"""
@quarantine "dart's Kernel TreeNode.noOffset; a NIR statement has no position until NIR reads Julia's debuginfo" Core.Int const TreeNode_no_offset = Int(-1)

"""
    nir_used_statements(body) -> BitSet

The statements of `body` whose value some operand reads, by SSAValue: Julia's SSA form names a value
where dart's Kernel nests it in its one use, so the code generator declares a used statement's value
as a variable and translates an unused one as an expression statement.
"""
@quarantine "Julia's SSA form names a statement's value by SSAValue; dart's Kernel nests an expression in its use" Base.BitSet function nir_used_statements(body::NirBody)::BitSet
    local used = BitSet()
    local use!(v) = v isa NirSSA && push!(used, v.id)
    for st in body.stmts
        if st isa Union{NirCall, NirInvoke, NirNew, NirForeignCall, NirBoundscheck, NirGCPreserveBegin, NirGCPreserveEnd,
                        NirLeave, NirPopException, NirTheException, NirLoopInfo, NirThrowUndefIfNot, NirCFunction, NirInvokeModify}
            foreach(use!, st.args)
        elseif st isa NirGotoIfNot
            use!(st.cond)
        elseif st isa NirReturn
            use!(st.val)
        elseif st isa NirPhi
            foreach(use!, st.values)
        elseif st isa NirPi
            use!(st.val)
        elseif st isa NirEnter
            use!(st.scope)
        elseif st isa NirUpsilon
            use!(st.val)
        elseif st isa NirPhiC
            foreach(use!, st.values)
        end
    end
    return used
end

"""
    nir_argument_type(mi, a) -> Type

The type of argument `a` of `mi`: its MethodInstance's signature, the type Julia specialized it for
(`Argument(1)` the callee itself).
"""
@quarantine "a Julia argument's type is its MethodInstance's specialization, specTypes" Core.MethodInstance function nir_argument_type(mi::Core.MethodInstance, a::NirArgument)::Type
    local ps = Base.unwrap_unionall(mi.specTypes).parameters
    1 <= a.n <= length(ps) && ps[a.n] isa Type && !(ps[a.n] isa Core.TypeofVararg) ||
        reject!(Unquarantined("src/julia/nir.jl: argument $(a.n) of $mi, outside its signature $(mi.specTypes)"), "$mi")
    return ps[a.n]
end

"""
    nir_carries_data(T) -> Bool

Whether a value of type `T` exists at run time, so a callee of that type is a parameter, dart's `this`:
Julia's codegen passes no value for a singleton type (a function's type, `isdefined(T, :instance)`) nor for
`Type{X}` with `X` free of type variables, the type of one type object (a constructor's callee), which it
treats as a constant (`Core.Compiler.isconstType`). The one source every receiver test reads.
"""
@quarantine "Julia's codegen passes no value for a singleton type or a constant Type{X}, isconstType" Core.Compiler.isconstType nir_carries_data(@nospecialize(T))::Bool =
    !(Base.issingletontype(T) || Core.Compiler.isconstType(T))

"""
    nir_binding_is_constant(ref) -> Bool

Whether the module binding `ref` names is defined and constant, so a read of it is its one value:
Julia's `isdefinedglobal` and `isconst`. The one test of a binding's constancy, which the operand's
type (nir_value_type), the callee's value and globals.dart's constant initializer each read.
"""
@quarantine "a binding is constant when Julia defines it const" Base.isconst nir_binding_is_constant(ref::GlobalRef)::Bool =
    isdefinedglobal(ref.mod, ref.name) && isconst(ref.mod, ref.name)

"""
    runtime_module(m) -> Bool

Whether the module `m` is the runtime's: its parentmodule chain reaches Core or Base, whose
`__init__` set up the host process (stdio, the depot and load paths, the logger; base/Base.jl:368 at
Julia v1.12.7), the setup dart's embedder does outside the compiled program (dev/MODULE_INIT.md).
"""
@quarantine "Core's and Base's __init__ are the host's setup, as dart's runtime is set up by its embedder" Base.parentmodule function runtime_module(m::Module)::Bool
    while !(m === Core || m === Base)
        local p = parentmodule(m)
        p === m && return false
        m = p
    end
    return true
end

"""
    nir_binding_value(ref, at) -> NirConst

The value a binding starts the program with, the one source: its value in this session, which has
run every module's `__init__` (src/toplevel.c:215-240 when a definition finishes, base/loading.jl:1443
when a package loads, at Julia v1.12.7), juliac's heap after its startup has run them, so WasmTarget
compiles no `__init__` (dev/MODULE_INIT.md). A binding of a runtime module (`runtime_module`) that is
not const, or holds a mutable value, is host state Base's `__init__` set (stdout, DEPOT_PATH, the
logger): a located rejection naming it.
"""
@quarantine "a binding starts at its session value, past every __init__; a value an __init__ derived from the host (a dlopen handle, a time, Random's seed) is baked at compile time, where juliac computes it at startup (dev/MODULE_INIT.md)" Core.getglobal function nir_binding_value(ref::GlobalRef, at::String)::NirConst
    isdefinedglobal(ref.mod, ref.name) ||
        reject!(Unquarantined("src/julia/nir.jl nir_binding_value: the binding $ref has no value, whose read Julia answers with an UndefVarError"), at)
    local value = getglobal(ref.mod, ref.name)
    runtime_module(ref.mod) && !(isconst(ref.mod, ref.name) && Base.ismutationfree(typeof(value))) &&
        reject!(Unquarantined("src/julia/nir.jl nir_binding_value: the binding $ref, host state set by Base.__init__ (the runtime's)"), at)
    return NirConst(Core.Const(value))
end

"""
    nir_value_type(body, v) -> Type

The type Julia inferred for the operand `v` of `body`: a statement's its `ssavaluetypes` entry, an
argument's its MethodInstance's signature (nir_argument_type), a literal's its value's type, and a
constant binding's its value's (a binding no assignment can rebind). Any other binding's read is the
static field's getter, not ported: it rejects there, Unported, the kind and site visitStaticGet
rejects the read itself at (globals.dart's getConstantInitializer decides that read). The one source of an operand's type: the code generator's static type of an
expression (dartTypeOf) and the closed world's classes (closed_world_classes) both read it.
"""
# a literal's type is its value's own, read with no body (a static field's initializer, a constant)
@quarantine "a Julia literal's type is its value's type, Core.Typeof" Core.Typeof nir_const_type(c::NirConst)::Type = Core.Typeof(c.c.val)

@quarantine "a Julia operand's type is its statement's inferred type, its argument's specialization or its value's type" Core.Typeof function nir_value_type(body::NirBody, v::NirValue)::Type
    @exhaustive v::NirValue begin
        (s::NirSSA) => body.types[s.id]
        (a::NirArgument) => nir_argument_type(body.ci.def, a)
        (c::NirConst) => nir_const_type(c)
        (g::NirGlobal) => nir_binding_is_constant(g.ref) ? Core.Typeof(getglobal(g.ref.mod, g.ref.name)) :
            reject!(Unported("dart2wasm/lib/code_generator.dart:4937 StaticFieldImplicitAccessorCodeGenerator._generateGetter"),
                    "src/julia/nir.jl nir_value_type: a read of the binding $(g.ref), which an assignment can rebind (its getter)")
    end
end

"""
    nir_tuple_type(body, st) -> Type

The class of the tuple `st`, a call of `Core.tuple`, builds: Julia's own answer, its tuple inference
of the operands' types (`Core.Compiler.tuple_tfunc`, widened), so `tuple(Int, 1)` is a
`Tuple{DataType, Int64}`. A statement's inferred type can be wider than the tuple it builds (Julia
widens `tuple(x, y)` to `Tuple{Any, Any}` where the result flows to a wider place), while the
object's class is always its operands' runtime types: the one source of that class, read by the
closed world's classes and by the code generator's record literal.
"""
@quarantine "a tuple's class is Julia's tuple inference of its operands' types, which a statement's widened type may hide" Core.Compiler.tuple_tfunc function nir_tuple_type(body::NirBody, st::NirCall)::Type
    return Core.Compiler.widenconst(Core.Compiler.tuple_tfunc(Core.Compiler.fallback_lattice, Any[nir_value_type(body, a) for a in st.args[2:end]]))
end

"""
    nir_method_nargs(mi) -> Int

How many arguments `mi`'s method takes, the callee `Argument(1)` among them; a varargs method rejects,
located, its trailing tuple not yet read.
"""
@quarantine "a Julia method's arity is its Method's nargs, with isva for a varargs tail" Core.Method function nir_method_nargs(mi::Core.MethodInstance)::Int
    local m = mi.def
    m isa Method || reject!(Unquarantined("src/julia/nir.jl: $mi instantiates no method"), "$mi")
    m.isva && reject!(Unquarantined("src/julia/nir.jl: the varargs method $m"), "$mi")
    return Int(m.nargs)
end

"""
    nir_body_of(world, mi) -> NirBody

The body in `world` (the closed world's NIR) Julia inferred for `mi`: dart's member's
`function.body`; a method the closed world lacks rejects, located.
"""
@quarantine "a MethodInstance's body is the CodeInstance Julia inferred for it in the closed world" Core.MethodInstance function nir_body_of(world::NirWorld, mi::Core.MethodInstance)::NirBody
    for nb in world
        nb.ci.def === mi && return nb
    end
    nir_intrinsified(mi) &&
        reject!(Internal("src/julia/nir.jl nir_body_of: $mi, a member the intrinsifier lowers at its call, reached by a call it did not lower (its body is never collected, nir_intrinsified)"), "$mi")
    reject!(Internal("src/julia/nir.jl: the closed world holds no body for $mi"), "$mi")
end

"""
    nir_invoke_target(node) -> MethodInstance

The MethodInstance an invoke calls: its target, or the MethodInstance its CodeInstance instantiates.
"""
@quarantine "Julia's invoke names its target by MethodInstance or by a CodeInstance of one" Core.MethodInstance function nir_invoke_target(node::NirInvoke)::Core.MethodInstance
    local t = node.target
    t isa Core.MethodInstance && return t
    local d = t.def
    d isa Core.MethodInstance && return d
    reject!(Unquarantined("src/julia/nir.jl: an invoke of a CodeInstance of a $(typeof(d))"), "$t")
end

"""
    nir_callee(node) -> Any

The value a call's callee operand names: a binding's value, or a literal; a callee Julia computes at
run time rejects, located.
"""
@quarantine "a call's callee is Julia's value of its operand, a constant binding or a literal of any type" Core.getglobal function nir_callee(node::NirCall)
    local f = node.args[1]
    f isa NirConst && return f.c.val
    f isa NirGlobal && nir_binding_is_constant(f.ref) && return getglobal(f.ref.mod, f.ref.name)
    reject!(Unquarantined("src/julia/nir.jl: a call whose callee $(f) is computed at run time"), "nir_callee")
end

"""
    nir_operands(st) -> Vector{NirValue}

The operands a NIR statement reads, in Julia's order: a call's, an allocation's and every other
Expr form's arguments, a branch's condition, a return's value, a phi's incoming values (the ones
assigned), a pi's value, a try region's scope, an upsilon's value; a jump, an unreachable, an emptied
statement and a binding read (whose GlobalRef is no operand) read none. One @exhaustive match, the
one place a pass over every operand of the NIR reads them.
"""
@quarantine "Julia's optimized IR holds each form's operands in its own place; one match reads them all" Base.isnothing function nir_operands(st::NirStmt)::Vector{NirValue}
    local some(xs) = NirValue[x for x in xs if !isnothing(x)]   # the assigned ones
    @exhaustive st::NirStmt begin
        (x::NirCall) => x.args
        (x::NirInvoke) => x.args
        (x::NirNew) => x.args
        (x::NirForeignCall) => x.args
        (x::NirBoundscheck) => x.args
        (x::NirGCPreserveBegin) => x.args
        (x::NirGCPreserveEnd) => x.args
        (x::NirLeave) => x.args
        (x::NirPopException) => x.args
        (x::NirTheException) => x.args
        (x::NirLoopInfo) => x.args
        (x::NirThrowUndefIfNot) => x.args
        (x::NirCFunction) => x.args
        (x::NirInvokeModify) => x.args
        NirGoto => NirValue[]
        (x::NirGotoIfNot) => NirValue[x.cond]
        (x::NirReturn) => NirValue[x.val]
        NirUnreachable => NirValue[]
        (x::NirPhi) => some(x.values)
        (x::NirPi) => NirValue[x.val]
        (x::NirEnter) => some((x.scope,))
        (x::NirUpsilon) => some((x.val,))
        (x::NirPhiC) => x.values
        NirNothing => NirValue[]
        NirGlobalRead => NirValue[]
    end
end

"""
    _builtin_name_operands(f) -> Tuple{Vararg{Int}}

The positions, counted after the callee, at which the Core builtin `f` takes a name rather than data:
a field's (its name or index), a module binding's (the module and the name together) or a memory
ordering's, each the parameter of that name in the
builtin's tfunc (Compiler/src/tfuncs.jl: `getfield_tfunc(𝕃, s00, name, order, boundscheck)`,
`setfield!_tfunc(𝕃, o, f, v, order)`, `memoryrefget_tfunc(𝕃, mem, order, boundscheck)`,
`atomic_pointerreplace_tfunc(𝕃, ptr, x, v, success_order, failure_order)`, ...; the global
builtins' arities at its add_tfunc calls, `getglobal(module, name, order)`, and
`get_binding_type(module, name)`). Every other builtin takes data alone, and a call of a generic
function (Base's getproperty among them, left unresolved) passes each argument as a value.
"""
@quarantine "Julia's builtins take a field's, a binding's or an ordering's name as an operand, each at its tfunc's parameter" Core.getfield function _builtin_name_operands(@nospecialize(f))::Tuple{Vararg{Int}}
    f === Core.getfield && return (2, 3)
    f === Core.setfield! && return (2, 4)
    f === Core.isdefined && return (2, 3)
    f === Core.fieldtype && return (2,)
    f === Core.swapfield! && return (2, 4)
    f === Core.modifyfield! && return (2, 5)
    f === Core.replacefield! && return (2, 5, 6)
    f === Core.setfieldonce! && return (2, 4, 5)
    f === Core.getglobal && return (1, 2, 3)
    f === Core.setglobal! && return (1, 2, 4)
    f === Core.isdefinedglobal && return (1, 2, 4)
    f === Core.swapglobal! && return (1, 2, 4)
    f === Core.modifyglobal! && return (1, 2, 5)
    f === Core.replaceglobal! && return (1, 2, 5, 6)
    f === Core.setglobalonce! && return (1, 2, 4, 5)
    f === Core.get_binding_type && return (1, 2)
    f === Core.memoryrefget && return (2,)
    f === Core.memoryrefset! && return (3,)
    f === Core.memoryref_isassigned && return (2,)
    f === Core.memoryrefswap! && return (3,)
    f === Core.memoryrefmodify! && return (4,)
    f === Core.memoryrefreplace! && return (4, 5)
    f === Core.memoryrefsetonce! && return (3, 4)
    f === Core.Intrinsics.atomic_fence && return (1,)
    f === Core.Intrinsics.atomic_pointerref && return (2,)
    f === Core.Intrinsics.atomic_pointerset && return (3,)
    f === Core.Intrinsics.atomic_pointerswap && return (3,)
    f === Core.Intrinsics.atomic_pointermodify && return (4,)
    f === Core.Intrinsics.atomic_pointerreplace && return (4, 5)
    return ()
end

"""
    nir_value_operands(st) -> Vector{NirValue}

The operands of a NIR statement that are values of the program, dart's expressions: its operands
(nir_operands) less those that name what the statement acts on or only annotate it, as Kernel names a
node's target rather than evaluating it. A call's callee and an invoke's are its target (dart's
Member); an allocation's type is its class (a ConstructorInvocation's target); a foreigncall's name,
return type, argument types, required count and calling convention precede its arguments, and a
cfunction's operands are all such (Julia's Expr(:foreigncall) and Expr(:cfunction) forms); a literal a
builtin takes where it names a field, a module binding or a memory ordering (_builtin_name_operands)
is that name, as an InstanceGet names its Field and a StaticSet its static Field, and a literal
anywhere else is data (`x === :a`, `tuple(:k, x)`); an undefined
variable check names the variable before its condition; and a loop hint, a bounds-check flag, a try
region's leave and an exception pop hold no value.
"""
@quarantine "Julia's IR passes a call's target, a builtin's names and a statement's annotations as operands; dart's Kernel names them in the node" Core.getglobal function nir_value_operands(st::NirStmt)::Vector{NirValue}
    local ops = nir_operands(st)
    @exhaustive st::NirStmt begin
        (x::NirCall) => let f = x.args[1],
                callee = f isa NirConst ? f.c.val : f isa NirGlobal && nir_binding_is_constant(f.ref) ? getglobal(f.ref.mod, f.ref.name) : nothing
            names = callee isa Core.Builtin ? _builtin_name_operands(callee) : ()
            NirValue[ops[i] for i in 2:length(ops) if !(i - 1 in names && ops[i] isa NirConst)]
        end
        NirInvoke => ops[2:end]
        NirNew => ops[2:end]
        NirForeignCall => ops[6:end]
        NirCFunction => NirValue[]
        NirThrowUndefIfNot => ops[2:end]
        NirLoopInfo => NirValue[]
        NirBoundscheck => NirValue[]
        NirLeave => NirValue[]
        NirPopException => NirValue[]
        NirGCPreserveBegin => ops
        NirGCPreserveEnd => ops
        NirTheException => ops
        NirInvokeModify => ops
        NirGoto => ops
        NirGotoIfNot => ops
        NirReturn => ops
        NirUnreachable => ops
        NirPhi => ops
        NirPi => ops
        NirEnter => ops
        NirUpsilon => ops
        NirPhiC => ops
        NirNothing => ops
        NirGlobalRead => ops
    end
end
