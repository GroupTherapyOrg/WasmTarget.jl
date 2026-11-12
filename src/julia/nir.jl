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

"""
    NirBinding

A module binding as the program's world holds it, Julia's answers there: `ref`, the binding; `world`, the world it
was read at, the ClosedWorld's (check_subset's, compile's `world`); `defined` (isdefinedglobal), `constant`
(jl_is_const), `value` (getglobal; `nothing` when it has no value) and `type`, its declared type
(`Core.get_binding_type`, `Any` when untyped), each run at that world (_binding_at). Read once, where
build_nir meets the binding in an operand or a statement of the closed world, and held by that node and by the
NirWorld's table (nir_binding): no reader of a binding's fact takes a world, so no reader can read one at another
(the fact's one source, D5; a wrong world cannot be written, D6). A binding's definedness, constancy and value are a
world's (Julia 1.12 partitions every binding by world age: `isconst` "is specific to a particular world age",
base/runtime_internals.jl:412), so a compiler whose own code runs in an earlier world than its program's
(test/smoke.jl's judge) reads the program's bindings where the program lives, never where the compiler runs.
Its fields are const and it is compared by identity: a closed world holds one per binding (NirBindings).

precedent(julia: src/julia.h:775 jl_binding_partition_t, a binding's kind and value over a range of worlds, which
Compiler/src/abstractinterpretation.jl:3736 abstract_eval_globalref resolves once, at inference's world, leaving its
Const in the IR the optimizer and codegen read;
GPUCompiler: CompilerJob.world, the one world a job's reads use). dart differs: its compiler reads no binding of the
program's world; a Kernel StaticGet names its Field, whose declaration the compiler holds.
"""
@quarantine pin"precedent(julia: src/julia.h:775 jl_binding_partition_t)" "a binding's facts are Julia's answers at the program's world, resolved once where the NIR meets the GlobalRef, as Julia's inference resolves a binding partition at its world (Compiler/src/abstractinterpretation.jl:3736 abstract_eval_globalref)" Core.GlobalRef mutable struct NirBinding
    const ref::GlobalRef
    const world::UInt
    const defined::Bool
    const constant::Bool
    const value::Any
    const type::Any
end

"""
    NirBindings(world)

The bindings a conversion to NIR meets, each read once at `world`, the world the converted code was inferred at (the
ClosedWorld's, in build_nir): `table`, one NirBinding per GlobalRef, made by nir_binding! the first time an operand
or a statement names it.
"""
@quarantine pin"precedent(julia: src/julia.h:799 jl_binding_t)" "a closed world's bindings, each read once at its world, as Julia's binding holds its partitions, each a range of worlds" Base.Dict struct NirBindings
    world::UInt
    table::Dict{GlobalRef,NirBinding}
    NirBindings(world::UInt) = new(world, Dict{GlobalRef,NirBinding}())
end

"""An operand that is a module binding, Julia's `GlobalRef`, as Julia wrote it: `ref`, and `binding`, its facts at
the program's world (NirBinding)."""
@quarantine pin"precedent(julia: src/julia.h:199 jl_globalref_t)" "Julia's optimized IR reads a module binding through a GlobalRef" Core.GlobalRef struct NirGlobal
    ref::GlobalRef
    binding::NirBinding
    NirGlobal(binding::NirBinding) = new(binding.ref, binding)
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
"""A statement that is a `GlobalRef`: a read of a module binding, `ref`, and `binding`, its facts at the program's
world (NirBinding)."""
@quarantine pin"precedent(julia: src/julia.h:199 jl_globalref_t)" "Julia's optimized IR can read a binding as a statement of its own" Core.GlobalRef struct NirGlobalRead
    ref::GlobalRef
    binding::NirBinding
    NirGlobalRead(binding::NirBinding) = new(binding.ref, binding)
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
`exception_at[i]`, the statement of the EnterNode whose caught exception is the top of Julia's
exception stack at statement `i`, the one `the_exception` and `rethrow()` read, 0 where none is
(compute_trycatch's exception stack, which a catch block pushes and a :pop_exception pops), and
`nothrow[i]`, whether statement `i` sends no exception to its handler as Julia's inference
decides it: a return or a :leave never does, every other statement unless it carries IR_FLAG_NOTHROW.
The stackifier reads them as LLVM reads an invoke's unwind edge (src/julia/machine.jl).
"""
@quarantine "Julia's compiler answers each statement's try handler and whether it can throw; the stackifier reads both" Base.BitVector struct NirHandlers
    handler_at::Vector{Int}
    exception_at::Vector{Int}
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
    nir_code(code, ssaflags, bindings, at) -> (Vector{NirStmt}, Core.Compiler.CFG, NirHandlers)

The statements of an optimized CodeInfo's `code` in NIR, Julia's CFG of them (compute_basic_blocks,
whose blocks and edges name statements by their position, the same in both), and its try regions:
each statement's catch handler and exception stack top (compute_trycatch, over the CodeInfo's
statements, whose catch destinations are statements) and whether it sends no exception to that handler. The one reader of a
body's raw statements, so every later stage, the stackifier's included, reads the closed sums. Each binding an
operand or a statement names is read once at `bindings`' world, the world the code was inferred at, into its node
(NirBinding, nir_binding!).

Whether a statement sends an exception to its handler is inference's rule (typeinf_local,
Compiler/src/abstractinterpretation.jl): a block's GotoNode, GotoIfNot and EnterNode carry
IR_FLAG_NOTHROW where they cannot throw; a ReturnNode and a :leave end their block without reaching
propagate_to_error_handler!, so neither throws whatever its flag (the optimizer's stmt_effect_flags
flags a :leave as it does any unknown head, not nothrow); every other statement throws unless
flagged.
"""
@quarantine pin"precedent(julia: Compiler/src/ssair/ir.jl:94 compute_basic_blocks)" "Julia's IR is a CFG compute_basic_blocks reads from its optimized statements, read here once" Core.Compiler.compute_basic_blocks function nir_code(code::Vector{Any}, ssaflags::Vector{UInt32}, bindings::NirBindings, at::String)::Tuple{Vector{NirStmt},Core.Compiler.CFG,NirHandlers}
    length(ssaflags) == length(code) || reject!(Internal("src/julia/nir.jl nir_code: $(length(ssaflags)) flags for $(length(code)) statements"), at)
    local info = Core.Compiler.compute_trycatch(code)
    local handler_at = info === nothing ? zeros(Int, length(code)) :
        Int[h == 0 ? 0 : info.handlers[h].enter_idx for (h, _) in info.handler_at]
    local exception_at = info === nothing ? zeros(Int, length(code)) :
        Int[e == 0 ? 0 : info.handlers[e].enter_idx for (_, e) in info.handler_at]
    local nothrow = BitVector([code[i] isa Core.ReturnNode || Meta.isexpr(code[i], :leave) || ssaflags[i] & Core.Compiler.IR_FLAG_NOTHROW != 0
                               for i in eachindex(code)])
    return NirStmt[_nir_stmt(st, bindings, at) for st in code], Core.Compiler.compute_basic_blocks(code), NirHandlers(handler_at, exception_at, nothrow)
end

# an operand of Julia's optimized IR as a NirValue; an IR node where a value belongs rejects, located
@quarantine pin"precedent(julia: Compiler/src/abstractinterpretation.jl:2969 abstract_eval_special_value)" "Julia's optimized IR operands: SSAValue, Argument, GlobalRef, or a literal Julia quotes or not, the forms Julia's inference reads as values" Core.SSAValue function _nir_operand(x, bindings::NirBindings, at::String)::NirValue
    x isa Core.SSAValue && return NirSSA(x.id)
    x isa Core.Argument && return NirArgument(x.n)
    x isa GlobalRef && return NirGlobal(nir_binding!(bindings, x))
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
@quarantine pin"precedent(julia: src/ccall.cpp:571 interpret_symbol_arg)" "Julia writes a foreigncall's constant name as tuple syntax or a call of Core.tuple, which its codegen reads as the tuple" Core.Expr function _nir_ccall_name(x, bindings::NirBindings, at::String)::NirValue
    local elems = x isa Expr && x.head === :tuple ? x.args :
        x isa Expr && x.head === :call && x.args[1] == GlobalRef(Core, :tuple) ? x.args[2:end] : nothing
    elems === nothing && return _nir_operand(x, bindings, at)
    local vals = Any[a isa QuoteNode ? a.value : a for a in elems]
    any(v -> v isa Union{Expr, Core.SSAValue, Core.Argument, GlobalRef, Core.SlotNumber}, vals) &&
        reject!(Unquarantined("src/julia/nir.jl: a foreigncall whose name is computed at run time"), at)
    return NirConst(Core.Const(Tuple(vals)))
end

# a statement of Julia's optimized IR as its NirStmt kind; a form outside the census rejects, located
@quarantine pin"precedent(julia: Compiler/src/abstractinterpretation.jl:3400 abstract_eval_statement_expr)" "Julia's optimized statement forms, read as they are, as Julia's inference reads each Expr head" Core.Expr function _nir_stmt(st, bindings::NirBindings, at::String)::NirStmt
    if st isa Expr
        local h = st.head
        local ops(xs) = NirValue[_nir_operand(a, bindings, at) for a in xs]
        h === :call && return NirCall(ops(st.args))
        if h === :invoke
            local t = st.args[1]
            t isa Union{Core.MethodInstance, Core.CodeInstance} ||
                reject!(Unquarantined("src/julia/nir.jl: an invoke of a $(typeof(t)), not a MethodInstance or CodeInstance"), at)
            return NirInvoke(t, ops(st.args[2:end]))
        end
        h === :new && return NirNew(ops(st.args))
        h === :foreigncall && return NirForeignCall(NirValue[_nir_ccall_name(st.args[1], bindings, at); ops(st.args[2:end])])
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
    st isa Core.GotoIfNot && return NirGotoIfNot(_nir_operand(st.cond, bindings, at), st.dest)
    st isa Core.ReturnNode && return isdefined(st, :val) ? NirReturn(_nir_operand(st.val, bindings, at)) : NirUnreachable()
    st isa Core.PhiNode && return NirPhi(copy(st.edges),
        Union{Nothing, NirValue}[isassigned(st.values, k) ? _nir_operand(st.values[k], bindings, at) : nothing for k in eachindex(st.values)])
    if st isa Core.PiNode
        st.typ isa Type || reject!(Unquarantined("src/julia/nir.jl: a PiNode narrowing to $(typeof(st.typ)), not a Type"), at)
        return NirPi(_nir_operand(st.val, bindings, at), st.typ)
    end
    st isa Core.EnterNode && return NirEnter(st.catch_dest, isdefined(st, :scope) ? _nir_operand(st.scope, bindings, at) : nothing)
    st isa Core.UpsilonNode && return NirUpsilon(isdefined(st, :val) ? _nir_operand(st.val, bindings, at) : nothing)
    st isa Core.PhiCNode && return NirPhiC(NirValue[_nir_operand(v, bindings, at) for v in st.values])
    st === nothing && return NirNothing()
    st isa GlobalRef && return NirGlobalRead(nir_binding!(bindings, st))
    reject!(Unquarantined("src/julia/nir.jl: Julia's statement form $(typeof(st)), outside NirStmt"), at)
end

# a sample of each mirror's Julia form, built by Julia's own constructors: converted at load, each must
# come back as the mirror that names its form (check_mirrors, src/julia/parity.jl; A39S1)
# the converters as the mirror check calls them: a sample's GlobalRef read at the world the package loads in, the
# compiler's own check of its converters, no program's
@quarantine pin"precedent(julia: base/runtime_internals.jl:1269 get_world_counter)" "the mirror check converts a sample at the world the package loads in, the compiler's own" Base.get_world_counter _nir_operand_sample(x, at::String)::NirValue =
    _nir_operand(x, NirBindings(Base.get_world_counter()), at)
@quarantine pin"precedent(julia: base/runtime_internals.jl:1269 get_world_counter)" "the mirror check converts a sample at the world the package loads in, the compiler's own" Base.get_world_counter _nir_stmt_sample(st, at::String)::NirStmt =
    _nir_stmt(st, NirBindings(Base.get_world_counter()), at)
mirror_samples!(_nir_operand_sample, :NirValue,
    NirSSA => Core.SSAValue(1), NirArgument => Core.Argument(2), NirGlobal => GlobalRef(Base, :sin),
    NirConst => QuoteNode(1))
mirror_samples!(_nir_stmt_sample, :NirStmt,
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
(dart's Component.mainMethod), `bodies`, every function of the ClosedWorld Julia's trim verifier
accepted, in Julia's order, `world`, the ClosedWorld's world, the one its code was inferred in and
the compiled program's task runs at (julia/src/jlapi.c:316), and `bindings`, every binding its bodies name, each
read once at that world (NirBinding). Read as a list (iterate, index, length), never built as one.

A typestate by construction: its one constructor takes the token `_NirToken`, which only this file
holds, and `build_nir`, which takes a `ClosedWorld`, is its only caller, so a stage that takes a
`NirWorld` (the Translator's component) is reached by a program Julia's verifier accepted alone; a
`Vector{NirBody}` anyone can build would reopen that road (A41-M2).

precedent(rust: typestate with a private constructor, the value made by one function of its module).
Julia's differs: it has no private constructors, so the sole constructor and the token's are checked
by reflection when the package loads (check_sole_constructor), with ClosedWorld's: the next state of the
same typestate (construction_check(::Val{:ClosedWorld}), src/julia/subset.jl; L220).
"""
@quarantine pin"precedent(dart: pkg/kernel/lib/src/ast/components.dart:12 Component)" "dart's Kernel Component, the program its TFA phase and translator read; Julia differs: it has no private constructors, so the NIR of a closed world, its bodies and the world they were inferred at (julia/Compiler/src/typeinfer.jl:1534 typeinf_ext_toplevel), is a typestate a token guards" Base.Vector struct NirWorld
    entry::Core.MethodInstance
    bodies::Vector{NirBody}
    world::UInt
    bindings::NirBindings
    NirWorld(::_NirToken, entry::Core.MethodInstance, bodies::Vector{NirBody}, bindings::NirBindings) =
        new(entry, bodies, bindings.world, bindings)
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
String's data operations read and write its bytes through pointers, a wasm array's operations raise,
src/julia/wasm_array.jl) is
Julia's evaluation of it, not the program's, so the closed world's NIR never collects it; a call the
intrinsifier then declines finds no body and rejects, located (nir_body_of).

precedent(dart: an external member, which TFA records at its call and compiles no body for; LLVM: an
intrinsic declaration, a call with no definition). Julia's differs: every callee Julia infers has a
body, so the one the intrinsifier lowers is left out here.
"""
@quarantine "an intrinsified member has no body of its own, as dart's external member: its call is recorded, its body never collected" Core.MethodInstance nir_intrinsified(mi::Core.MethodInstance)::Bool =
    Dart2Wasm.generate_static_intrinsic(Val(:string_data_op), mi) !== nothing ||
    Dart2Wasm.generate_static_intrinsic(Val(:wasm_array_op), mi) !== nothing ||
    Dart2Wasm.generate_static_intrinsic(Val(:memory_data_op), mi) !== nothing

"""
    build_nir(world::ClosedWorld, at::String) -> NirWorld

Every function of the closed world Julia's trim verifier accepted, in NIR, in Julia's order, but a
member the intrinsifier lowers at its call, whose body is never collected (nir_intrinsified): each
statement its kind of `NirStmt`, each operand of `NirValue`, each type Julia's. A form outside the
census rejects with `Unquarantined`, located at the compile `at` names.

formal(dev/formal/NirHandoff.tla): a record no body, one body per CodeInstance, a repeat asserted, each statement at its position
"""
@quarantine pin"julia/Compiler/src/typeinfer.jl:1534 typeinf_ext_toplevel" "the closed world Julia inferred comes as CodeInstance and CodeInfo pairs at one world, as julia/Compiler/src/typeinfer.jl:1534 typeinf_ext_toplevel returns them, read once" Core.CodeInfo function build_nir(world::ClosedWorld, at::String)::NirWorld
    # a queued ccallable's svec(rettype, signature) is the verifier's record, no body: its
    # specialization is a CodeInstance of the world like any other, which Julia's inference lists a
    # second time when its invokelatest queue compiles it (typeinfer.jl's compile!): one body here, the
    # repeat's CodeInfo asserted the first's (its statements and their types), never dropped unread
    local xs = Any[x for x in world.codeinfos if !(x isa Core.SimpleVector)]
    iseven(length(xs)) || reject!(Internal("src/julia/nir.jl: the closed world holds $(length(xs)) entries, not CodeInstance and CodeInfo pairs"), at)
    local bodies = NirBody[]
    # every binding the bodies name, each read once at the closed world's world
    local bindings = NirBindings(world.world)
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
        local stmts, cfg, handlers = nir_code(src.code, src.ssaflags, bindings, at)
        push!(bodies, NirBody(ci, stmts, _nir_types(ci, src, at), cfg, handlers))
    end
    any(b -> b.ci.def === world.entry, bodies) ||
        reject!(Internal("src/julia/nir.jl: the closed world's entry $(world.entry) has no body"), at)
    return NirWorld(_NirToken(), world.entry, bodies, bindings)
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
    NirVarargPacking

How a varargs method's trailing arguments reach its body, which always sees them as one tuple, its
argument `first` (the method's `nargs`), of type `packed` (Julia's own, Core.Compiler's
va_process_argtypes over the specialization). `at_entry`: the specialization fixes the argument count
(specTypes ends in no Vararg), so Julia's codegen passes each argument as a parameter of its own
(specsig) and the callee packs the trailing ones into the tuple at entry; otherwise (a trailing
Vararg, the count open) Julia passes the arguments in one array the callee packs from (jlcall), and a
wasm function, of a fixed arity, takes the tuple itself, which the caller packs.

precedent(julia: codegen.cpp's specsig, which passes a count-specialized varargs call's arguments one
by one and builds the vararg tuple in the callee, and its jlcall ABI for an open count). dart has no
varargs.
"""
@quarantine "Julia passes a varargs method's trailing arguments as one tuple its body reads, packed at entry by a specialized signature or from the call's arguments otherwise (julia/src/codegen.cpp:2792 uses_specsig)" Core.Type struct NirVarargPacking
    first::Int
    packed::Type
    at_entry::Bool
end

"""
    nir_vararg_packing(mi) -> Union{NirVarargPacking,Nothing}

The packing of `mi`'s trailing arguments (NirVarargPacking), or nothing for a method with no varargs.
"""
@quarantine "Julia's inference packs a varargs method's trailing argument types into one tuple type, va_process_argtypes, and its codegen packs at entry where the count is bound (julia/src/codegen.cpp:2792 uses_specsig)" Core.Compiler.va_process_argtypes function nir_vararg_packing(mi::Core.MethodInstance)::Union{NirVarargPacking,Nothing}
    local m = mi.def
    m isa Method && m.isva || return nothing
    local argtypes = Core.Compiler.va_process_argtypes(Core.Compiler.fallback_lattice,
        Core.Compiler.most_general_argtypes(m, mi.specTypes), UInt(m.nargs), true)
    local packed = Core.Compiler.widenconst(argtypes[m.nargs])
    local ps = Base.unwrap_unionall(mi.specTypes).parameters
    return NirVarargPacking(Int(m.nargs), packed, !(last(ps) isa Core.TypeofVararg))
end

"""
    nir_vararg_call_tuple(body, node) -> Union{Type,Nothing}

The tuple an invoke of a varargs specialization of an open count packs from its trailing operands
(NirVarargPacking): the tuple of their inferred types, the type Julia's jl_f_tuple gives the tuple of
those values (julia/src/codegen.cpp:2792 uses_specsig sends such a call through the argument array
it packs from); nothing for any other invoke.
"""
@quarantine "Julia packs an open count's trailing arguments into the tuple of their values' types, jl_f_tuple over the call's arguments (julia/src/codegen.cpp:2792 uses_specsig)" Core.Tuple function nir_vararg_call_tuple(body::NirBody, node::NirInvoke)::Union{Type,Nothing}
    local va = nir_vararg_packing(nir_invoke_target(node))
    (va === nothing || va.at_entry) && return nothing
    return Tuple{(nir_value_type(body, a) for a in node.args[va.first:end])...}
end

"""
    nir_parameter_types(mi) -> Vector{Type}

The types of the parameters `mi`'s function takes, the callee's first: its specialization's argument
types, each its own parameter (a varargs specialization of a fixed count among them, which packs at
entry), but for a varargs specialization of an open count, whose trailing arguments are one parameter,
the packed tuple (NirVarargPacking).
"""
@quarantine "a function's parameters are its specialization's argument types, a varargs tail of open count one packed tuple, as Julia's codegen passes each argument of a specialized signature (julia/src/codegen.cpp:2792 uses_specsig)" Core.MethodInstance function nir_parameter_types(mi::Core.MethodInstance)::Vector{Type}
    local ps = Type[p for p in Base.unwrap_unionall(mi.specTypes).parameters if !(p isa Core.TypeofVararg)]
    local va = nir_vararg_packing(mi)
    (va === nothing || va.at_entry) && return ps
    return Type[ps[1:va.first-1]..., va.packed]
end

"""
    nir_argument_type(mi, a) -> Type

The type of argument `a` of `mi`'s body: its MethodInstance's signature, the type Julia specialized it
for (`Argument(1)` the callee itself), a varargs method's last argument the packed tuple
(NirVarargPacking).
"""
@quarantine "a Julia argument's type is its MethodInstance's specialization, specTypes" Core.MethodInstance function nir_argument_type(mi::Core.MethodInstance, a::NirArgument)::Type
    local va = nir_vararg_packing(mi)
    va === nothing || a.n != va.first || return va.packed
    local ps = Base.unwrap_unionall(mi.specTypes).parameters
    1 <= a.n <= (va === nothing ? length(ps) : va.first - 1) && ps[a.n] isa Type && !(ps[a.n] isa Core.TypeofVararg) ||
        reject!(Unquarantined("src/julia/nir.jl: argument $(a.n) of $(rejection_text(mi)), outside its signature $(mi.specTypes)"), rejection_text(mi))
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

# a binding's facts at `world`, Julia's answers there by its builtins and jl_is_const alone (isdefinedglobal,
# getglobal, get_binding_type), run in that world: the one reader of a binding's facts (NirBinding)
@quarantine pin"precedent(julia: base/essentials.jl:1257 _resolve_in_world)" "a binding read at the program's world, as Base.@world reads one, by Julia's builtins and jl_is_const (base/runtime_internals.jl:421 isconst)" Base.invoke_in_world function _binding_at(world::UInt, ref::GlobalRef)::NirBinding
    local defined = Base.invoke_in_world(world, isdefinedglobal, ref.mod, ref.name)::Bool
    return NirBinding(ref, world, defined, Base.invoke_in_world(world, _binding_is_const, ref.mod, ref.name)::Bool,
                      defined ? Base.invoke_in_world(world, getglobal, ref.mod, ref.name) : nothing,
                      Base.invoke_in_world(world, Core.get_binding_type, ref.mod, ref.name))
end
@quarantine pin"precedent(julia: base/runtime_internals.jl:421 isconst)" "Base.isconst(::Module, ::Symbol) is this ccall (base/runtime_internals.jl:421), called here so no generic dispatch runs in the program's world" Base.Cint _binding_is_const(m::Module, s::Symbol)::Bool =
    ccall(:jl_is_const, Cint, (Any, Any), m, s) != 0

"""
    nir_binding!(bindings, ref) -> NirBinding

The binding `ref` at `bindings`' world: read the first time a conversion to NIR meets it (_binding_at), the same
NirBinding every later time.
"""
@quarantine pin"precedent(julia: Compiler/src/abstractinterpretation.jl:3736 abstract_eval_globalref)" "a binding's facts are read once per world, as Julia's inference resolves a GlobalRef's binding partition once at its world" Base.get! nir_binding!(bindings::NirBindings, ref::GlobalRef)::NirBinding =
    get!(() -> _binding_at(bindings.world, ref), bindings.table, ref)

"""
    nir_binding(world, ref) -> NirBinding

The binding `ref` as the closed world `world` read it, for a reader that holds the binding's name alone (a static
field, dart's Field reference: globals.dart, the static field initializer, typeOfField), never a world. A binding no
body of `world` names is WasmTarget's own defect, an Internal rejection located at it.
"""
@quarantine pin"precedent(julia: base/runtime_internals.jl:241 convert)" "a static field is named by its binding alone, dart's Field reference, whose facts its closed world read once and keeps by the name, as Julia finds the binding a GlobalRef names" Base.get function nir_binding(world::NirWorld, ref::GlobalRef)::NirBinding
    local b = get(world.bindings.table, ref, nothing)
    b === nothing && reject!(Internal("src/julia/nir.jl nir_binding: the binding $ref, which no body of the closed world names"), "the binding $ref")
    return b
end

"""
    nir_binding_is_constant(binding) -> Bool

Whether the module binding is defined and constant at the program's world, so a read of it is its one value: Julia's
`isdefinedglobal` and `isconst` there (NirBinding). The one test of a binding's constancy, which the operand's type
(nir_value_type), the callee's value and globals.dart's constant initializer each read.
"""
@quarantine pin"precedent(julia: base/runtime_internals.jl:421 isconst)" "a binding is constant when Julia defines it const, at the program's world (NirBinding)" Core.Bool nir_binding_is_constant(binding::NirBinding)::Bool =
    binding.defined && binding.constant

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
    nir_binding_value(binding, at) -> NirConst

The value a binding starts the program with, the one source: its value in this session at the program's world (NirBinding), which has
run every module's `__init__` (src/toplevel.c:215-240 when a definition finishes, base/loading.jl:1443
when a package loads, at Julia v1.12.7), juliac's heap after its startup has run them, so WasmTarget
compiles no `__init__` (dev/MODULE_INIT.md). A binding of a runtime module (`runtime_module`) that no
const holds is host state: one a runtime initializer's closed world touches (stdout, the logger), and
every other, since that closed world holds dynamic calls whose callees it does not follow, any of which
may set it (A77S1); a const object an initializer passes to a call Julia infers may write, directly or
through a field read, a PiNode or a PhiNode (DEPOT_PATH), or to any dynamic call, is host state too
(runtime_init_bindings, Julia's trim over juliac's init list and its effects analysis): each a located
rejection naming that `__init__`. A const free of mutation (a type, Sys.WORD_SIZE) is Julia's own value.
Every other binding, a const table such as base36digits among them, starts at its session value, as a
juliac image holds it.
"""
@quarantine "a binding starts at its session value, past every __init__, which julia/src/init.c:563 _finish_jl_init_ runs at a juliac executable's startup; a value an __init__ derived from the host (a dlopen handle, a time, Random's seed) is baked at compile time, where juliac computes it at startup (dev/MODULE_INIT.md)" Base.ismutationfree function nir_binding_value(binding::NirBinding, at::String)::NirConst
    local ref = binding.ref
    binding.defined ||
        reject!(Unquarantined("src/julia/nir.jl nir_binding_value: the binding $ref has no value, whose read Julia answers with an UndefVarError"), at)
    local value = binding.value
    local constant = binding.constant
    # a const of the runtime free of mutation (a type, Sys.WORD_SIZE) is Julia's own value, whatever reads it
    if runtime_module(ref.mod) && !(constant && Base.ismutationfree(typeof(value)))
        local host = runtime_init_bindings(binding.world)   # the program's world, the binding's
        # (a) a binding no const holds is what the runtime's initializer left in it; (b) a const object
        # is host state where an initializer passes it to a call Julia infers may write
        local init = constant ? get(host.mutated, ref, nothing) : get(host.touched, ref, nothing)
        init === nothing ||
            reject!(Unquarantined("src/julia/nir.jl nir_binding_value: the binding $ref, host state $(parentmodule(init)).__init__ (the runtime's) $(constant ? "mutates" : "sets or reads")"), at)
        # (a) untouched by the closed world, yet no binding is proved untouched while it holds dynamic
        # calls, whose callees juliac's verifier would enumerate (typeinfer.jl:1567 verify_typeinf_trim)
        local dynamic = filter(p -> last(p) > 0, host.dynamic)
        constant || isempty(dynamic) ||
            reject!(Unquarantined("src/julia/nir.jl nir_binding_value: the binding $ref, which no const holds, unproved host state: the runtime's initializers' closed world holds dynamic calls whose callees may set it ($(join(("$(parentmodule(f)).__init__ $n" for (f, n) in dynamic), ", ")))"), at)
    end
    return NirConst(Core.Const(value))
end

# One analysis of the runtime's initializers (runtime_init_bindings: the bindings they touch, the const objects among
# them they pass to a call that may write, each with the first initializer whose closed world does so) and what Julia
# says it rests on: the world it was inferred at, the initializers that world holds, every CodeInstance their closed
# worlds were inferred from, and every binding the analysis read with its partition at that world (spec v13 R8)
@quarantine pin"precedent(julia: src/julia.h:494 jl_code_instance_t)" "an inference result is Julia's to reuse at a world inside its CodeInstance's [min_world, max_world] (src/gf.c:3150 _jl_rettype_inferred), which a method that invalidates it narrows (base/invalidation.jl:81), and a binding read is the same at a world inside its partition (base/runtime_internals.jl:233 lookup_binding_partition); Julia keeps one result a MethodInstance, this one a whole analysis, valid where every CodeInstance and binding partition it rests on is" Core.CodeInstance struct RuntimeInitAnalysis
    world::UInt
    inits::Vector{Function}
    cis::Vector{Core.CodeInstance}
    bindings::Vector{Pair{GlobalRef,Core.BindingPartition}}
    result::@NamedTuple{touched::IdDict{GlobalRef,Function}, mutated::IdDict{GlobalRef,Function}, dynamic::Vector{Pair{Function,Int}}}
end
# every analysis this process made, the oldest first: one is reused at a world while it holds there (_analysis_holds),
# so a process compiling at many worlds (a unit's labels each at its own) recomputes only when a method or a binding a
# unit added invalidated what it rests on
@quarantine pin"precedent(julia: src/gf.c:3150 _jl_rettype_inferred)" "Julia's code cache keeps each inference result with its world range and serves it at a world inside it" Base.Vector const _RUNTIME_INIT_ANALYSES = Vector{RuntimeInitAnalysis}()
# each world's answer, once found (spec v14 V7): exact, since whether an analysis holds at a world that exists never
# changes (an invalidation narrows a CodeInstance's max_world to the invalidating world less one, at or above every
# world that exists then, base/invalidation.jl:81; a later binding partition starts past every existing world), and
# the runtime's module tree a world holds is Base's and Core's, which no program changes; so the walk of that tree and
# the search of the analyses run once a world, not once a call
@quarantine pin"precedent(julia: src/gf.c:3150 _jl_rettype_inferred)" "Julia's code cache serves a world the result it found for it, its range fixed for every world that exists" Base.Dict const _RUNTIME_INIT_AT = Dict{UInt,RuntimeInitAnalysis}()

"""
    _analysis_holds(a, world, inits) -> Bool

Julia's own answer to whether analysis `a` holds at `world`: the initializers `world` holds are `a`'s, every
CodeInstance `a` was inferred from serves `world` (`world in Core.Compiler.world_range(ci)`, Compiler/src/
abstractinterpretation.jl:3596, the range Julia's code cache serves a CodeInstance in, src/gf.c:3150
_jl_rettype_inferred: `min_world <= world <= max_world`; a method that invalidates it narrows its max_world,
base/invalidation.jl:81), and every binding `a` read is at `world` in the partition it read where `a` was inferred
(base/runtime_internals.jl:233 lookup_binding_partition finds a binding's partition by the same range: src/julia.h:771
jl_binding_partition_t's min_world and max_world, which a later partition of the binding narrows).
"""
@quarantine pin"precedent(julia: Compiler/src/abstractinterpretation.jl:3596 world_range)" "an inference result is reused at a world inside its CodeInstance's world range, Julia's own validity, and a binding read at a world inside its partition" Core.Compiler.world_range function _analysis_holds(a::RuntimeInitAnalysis, world::UInt, inits::Vector{Function})::Bool
    length(a.inits) == length(inits) && all(i -> a.inits[i] === inits[i], eachindex(inits)) || return false
    all(ci -> world in Core.Compiler.world_range(ci), a.cis) || return false
    # (a partition serves the worlds of its range, src/julia.h:771; a later one for the binding narrows its max_world)
    return all(p -> p.second.min_world <= world <= p.second.max_world, a.bindings)
end

"""
    runtime_init_bindings(world) -> (; touched, mutated)

The bindings the runtime's module initializers touch (runtime_initializers: Base.__init__ and its
submodules'), each mapped to the first initializer whose closed world does so: the closed world Julia's
own trim infers for an entrypoint (julia/Compiler/src/typeinfer.jl:1534 typeinf_ext_toplevel, as juliac
makes each module of the init list one, julia/src/precompile.c:98 jl_write_compiler_output), unverified
(TRIM_NO: Base's initializers are trimmed only once juliac stubs their host setup). `touched`: every
GlobalRef its statements name. `mutated`: each one whose value an initializer passes, directly or through
SSA values (the binding read, a field read of it, a PiNode or a PhiNode of one), to a call Julia's effects
analysis does not infer effect_free (julia/Compiler/src/effects.jl:119 Effects, the callee's ipo effects; a
builtin's or an intrinsic's by Julia's own builtin_effects and intrinsic_effects; a call Julia did not
resolve, a dynamic call, counted as one that may write). `dynamic`: each initializer's count of dynamic
calls (a call of no builtin, Julia's dispatch at run time, or a special builtin calling another function),
whose callees the closed world does not hold (compile! follows `:invoke` edges, typeinfer.jl:1451).
A juliac executable starts from the heap before any __init__ (julia/src/toplevel.c defers them, the image
saved by jl_write_compiler_output) and runs them at startup (julia/src/init.c:563 _finish_jl_init_), so a
binding no initializer sets, and a const object none mutates, holds the same value in the image, after
startup and in this session. Inferred at `world`, the compile's program world (as juliac infers them in the
program's world), and reused at a later world while Julia says it holds there (_analysis_holds: every CodeInstance
it rests on serves that world, every binding it read has the same partition), so a process recomputes it only after a
method or a binding invalidated it; measured 5.5 G of instructions cold, about 3 G recomputed in a warm process.
"""
@quarantine "julia/Compiler/src/typeinfer.jl:1534 typeinf_ext_toplevel infers each runtime initializer's closed world, as juliac's trim infers the init list's entrypoints (julia/src/precompile.c:98 jl_write_compiler_output); julia/Compiler/src/effects.jl:119 Effects judges each call; once per world" Core.GlobalRef function runtime_init_bindings(world::UInt)::@NamedTuple{touched::IdDict{GlobalRef,Function}, mutated::IdDict{GlobalRef,Function}, dynamic::Vector{Pair{Function,Int}}}
    # a world asked before: its analysis, with no walk and no search (_RUNTIME_INIT_AT)
    local seen = get(_RUNTIME_INIT_AT, world, nothing)
    seen === nothing || return seen.result
    # the runtime's module tree walked at `world` too, its initializers the ones that world holds
    local inits = Base.invoke_in_world(world, runtime_initializers)
    for a in _RUNTIME_INIT_ANALYSES
        _analysis_holds(a, world, inits) && return (_RUNTIME_INIT_AT[world] = a).result
    end
    local a = init_world_bindings(inits, world)
    push!(_RUNTIME_INIT_ANALYSES, a)
    _RUNTIME_INIT_AT[world] = a
    return a.result
end

# runtime_init_bindings' analysis over the closed worlds of `inits`, each a function of no argument, with what it rests
# on: the CodeInstances typeinf_ext_toplevel inferred them from (its result holds each beside its source,
# typeinfer.jl:1520) and each binding it read with its partition at `world`
@quarantine "julia/Compiler/src/typeinfer.jl:1534 typeinf_ext_toplevel infers each initializer's closed world; julia/Compiler/src/effects.jl:119 Effects judges each call it holds" Core.Compiler.typeinf_ext_toplevel function init_world_bindings(inits::Vector{Function}, world::UInt)::RuntimeInitAnalysis
    local touched = IdDict{GlobalRef,Function}()
    local mutated = IdDict{GlobalRef,Function}()
    local dynamic = Pair{Function,Int}[]
    local cis = Core.CodeInstance[]
    local read = IdDict{GlobalRef,Core.BindingPartition}()
    # a binding's value at `world`, the world the initializers are inferred at (_binding_at), or nothing; its partition
    # there kept, which the analysis then rests on
    local value_at(r::GlobalRef) = begin
        haskey(read, r) || (read[r] = Base.lookup_binding_partition(world, r))
        local b = _binding_at(world, r)
        b.defined ? b.value : nothing
    end
    local collect_refs!(x, init::Function) = begin
        if x isa GlobalRef
            haskey(touched, x) || (touched[x] = init)
        elseif x isa Expr
            # an assignment of a global is setglobal!(module, :name, value) in Julia's optimized IR, a read
            # by getglobal: the binding they name
            # (the callee and the module each a literal or a binding naming one, Base.setglobal! Core's)
            local value_of(v) = v isa GlobalRef ? value_at(v) : v
            if x.head === :call && length(x.args) >= 3 && (value_of(x.args[1]) === Core.setglobal! || value_of(x.args[1]) === Core.getglobal) &&
                    value_of(x.args[2]) isa Module && (x.args[3] isa QuoteNode || x.args[3] isa Symbol)
                local r = GlobalRef(value_of(x.args[2]), x.args[3] isa QuoteNode ? x.args[3].value : x.args[3])
                haskey(touched, r) || (touched[r] = init)
            end
            foreach(a -> collect_refs!(a, init), x.args)
        end
        nothing
    end
    # the callee of a `:call` statement, a builtin read through its binding
    local callee_of(st::Expr) = (local f = st.args[1]; f isa GlobalRef ? value_at(f) : f)
    # whether a call is dynamic: Julia dispatches it at run time, or a special builtin calls another function
    local is_dynamic(st::Expr)::Bool = st.head === :call &&
        (local f = callee_of(st); !(f isa Core.Builtin) || Core.Compiler.contains_is(Core.Compiler._SPECIAL_BUILTINS, f))
    # whether a call statement may write what it is passed, by Julia's effects
    local may_write(st::Expr, src::Core.CodeInfo)::Bool = begin
        if st.head === :invoke
            local callee = st.args[1]
            callee isa Core.CodeInstance || return true
            return !Core.Compiler.is_effect_free(Core.Compiler.decode_effects(callee.ipo_purity_bits))
        end
        local f = st.args[1]
        f isa GlobalRef && (f = value_at(f))
        # each operand's type as the verifier types one, an argument's by the body's slottypes
        local slottypes = src.slottypes === nothing ? Any[] : src.slottypes
        # (an operand that is itself an expression, in a body Julia left unoptimized, typed Any)
        local argtypes = Any[(a isa Expr || (a isa Core.Argument && a.n > length(slottypes))) ? Any :
            Core.Compiler.argextype(a, src, Core.Compiler.VarState[], slottypes) for a in st.args[2:end]]
        f isa Core.IntrinsicFunction && return !Core.Compiler.is_effect_free(Core.Compiler.intrinsic_effects(f, argtypes))
        # a special builtin (invoke, _apply_iterate, ...) calls another function: one that may write
        f isa Core.Builtin && Core.Compiler.contains_is(Core.Compiler._SPECIAL_BUILTINS, f) && return true
        f isa Core.Builtin && return !Core.Compiler.is_effect_free(Core.Compiler.builtin_effects(Core.Compiler.fallback_lattice, f, argtypes, Any))
        return true
    end
    for init in inits
        local mi = Core.Compiler.specialize_method(only(methods(init, ())), Tuple{typeof(init)}, Core.svec())
        local ndynamic = 0
        for x in Core.Compiler.typeinf_ext_toplevel(Any[mi], [world], Core.Compiler.TRIM_NO)
            x isa Core.CodeInstance && push!(cis, x)
            x isa Core.CodeInfo || continue
            foreach(st -> collect_refs!(st, init), x.code)
            ndynamic += count(st -> st isa Expr && is_dynamic(st), x.code)
            # the SSA values that may hold a binding's object or a part of it: the binding read, a field
            # read of one, a PiNode or a PhiNode of one, to a fixed point over the PhiNodes' back edges;
            # then each call passing one, or a binding itself
            local holds = Dict{Int,Base.IdSet{GlobalRef}}()
            local refs_of(a) = a isa GlobalRef ? Base.IdSet{GlobalRef}((a,)) :
                a isa Core.SSAValue ? get(holds, a.id, Base.IdSet{GlobalRef}()) : Base.IdSet{GlobalRef}()
            local changed = true
            while changed
                changed = false
                for (k, st) in enumerate(x.code)
                    local from = st isa GlobalRef ? refs_of(st) :
                        st isa Core.PiNode ? refs_of(st.val) :
                        st isa Core.PhiNode ? reduce(union, (refs_of(st.values[i]) for i in eachindex(st.values) if isassigned(st.values, i)); init = Base.IdSet{GlobalRef}()) :
                        Meta.isexpr(st, :call) && length(st.args) >= 2 && callee_of(st) === Core.getfield ? refs_of(st.args[2]) :
                        Base.IdSet{GlobalRef}()
                    isempty(from) && continue
                    local held = get!(() -> Base.IdSet{GlobalRef}(), holds, k)
                    issubset(from, held) && continue
                    union!(held, from)
                    changed = true
                end
            end
            for st in x.code
                Meta.isexpr(st, (:call, :invoke)) || continue
                local operands = st.head === :invoke ? st.args[3:end] : st.args[2:end]
                local refs = reduce(union, (refs_of(a) for a in operands); init = Base.IdSet{GlobalRef}())
                isempty(refs) && continue
                (is_dynamic(st) || may_write(st, x)) || continue
                foreach(r -> haskey(mutated, r) || (mutated[r] = init), refs)
            end
        end
        push!(dynamic, init => ndynamic)
    end
    return RuntimeInitAnalysis(world, inits, cis, collect(Pair{GlobalRef,Core.BindingPartition}, read), (; touched, mutated, dynamic))
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

@quarantine pin"precedent(julia: Compiler/src/abstractinterpretation.jl:3736 abstract_eval_globalref)" "a Julia operand's type is its statement's inferred type, its argument's specialization or its value's type, a constant binding's its value's at the program's world (NirBinding)" Core.Typeof function nir_value_type(body::NirBody, v::NirValue)::Type
    @exhaustive v::NirValue begin
        (s::NirSSA) => body.types[s.id]
        (a::NirArgument) => nir_argument_type(body.ci.def, a)
        (c::NirConst) => nir_const_type(c)
        (g::NirGlobal) => nir_binding_is_constant(g.binding) ? Core.Typeof(g.binding.value) :
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

How many arguments `mi`'s method's body takes, the callee `Argument(1)` among them, a varargs
method's trailing ones its one packed tuple (NirVarargPacking).
"""
@quarantine "a Julia method's arity is its Method's nargs, with isva for a varargs tail, the fields of julia/src/julia.h:396 jl_method_t" Core.Method function nir_method_nargs(mi::Core.MethodInstance)::Int
    local m = mi.def
    m isa Method || reject!(Unquarantined("src/julia/nir.jl: $(rejection_text(mi)) instantiates no method"), rejection_text(mi))
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
        reject!(Internal("src/julia/nir.jl nir_body_of: $(rejection_text(mi)), a member the intrinsifier lowers at its call, reached by a call it did not lower (its body is never collected, nir_intrinsified)"), rejection_text(mi))
    reject!(Internal("src/julia/nir.jl: the closed world holds no body for $(rejection_text(mi))"), rejection_text(mi))
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
    reject!(Unquarantined("src/julia/nir.jl: an invoke of a CodeInstance of a $(typeof(d))"), rejection_text(t))
end

"""
    nir_callee(node) -> Any

The value a call's callee operand names: a binding's value, or a literal; a callee Julia computes at
run time rejects, located.
"""
@quarantine pin"precedent(julia: Compiler/src/abstractinterpretation.jl:3736 abstract_eval_globalref)" "a call's callee is Julia's value of its operand, a constant binding's at the program's world (NirBinding) or a literal of any type" Core.isa function nir_callee(node::NirCall)
    local f = node.args[1]
    f isa NirConst && return f.c.val
    f isa NirGlobal && nir_binding_is_constant(f.binding) && return f.binding.value
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
a field's (its name or index), a module binding's (the module and the name together), a memory
ordering's, or the class an allocation makes (memorynew's memory type, as `%new`'s type is its class,
never a value: `memorynew_tfunc(𝕃, memtype, m)`), each the parameter of that name in the
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
    f === Core.memorynew && return (1,)
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
@quarantine pin"precedent(julia: Compiler/src/abstractinterpretation.jl:3736 abstract_eval_globalref)" "Julia's IR passes a call's target, a builtin's names and a statement's annotations as operands; dart's Kernel names them in the node" Core.Builtin function nir_value_operands(st::NirStmt)::Vector{NirValue}
    local ops = nir_operands(st)
    @exhaustive st::NirStmt begin
        (x::NirCall) => let f = x.args[1],
                callee = f isa NirConst ? f.c.val : f isa NirGlobal && nir_binding_is_constant(f.binding) ? f.binding.value : nothing
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
