# A cell assigned once, read only after: dart's `late final` field, which the ported wasm_builder
# and dart2wasm declare where an object's parts are built after it (a module and the functions that
# point back to it, the translator and the collaborators it builds with itself).

"""
    Late{T}(anchor)
    Late{T}(anchor, init)

A cell for a value of type `T`: dart's `late final` field, `anchor` the field's own
`"<file>.dart:<line> <Class.field>"`. `c[] = v` assigns it once; `c[]` reads it.

`Late{T}(anchor)` is dart's `late final T x;`: a read before the assignment rejects as
`Unported(anchor)`, since the code that assigns the field is the code not yet ported, and a second
assignment rejects as `Internal`, dart's LateInitializationError.

`Late{T}(anchor, init)` is dart's `late final T x = init;`: `init` runs on the first read, never
before (dart evaluates a late field's initializer lazily), its value the field's; an assignment
rejects as `Internal`, since dart refuses to assign a late final field that has an initializer, and
a read from inside `init` (the initializer reaching its own field) rejects as `Internal`, dart's
cyclic-initialization error.

precedent(rust: std::cell::OnceCell, set once and read through `get`, and LazyCell, its value
computed on the first read). Julia's differs: its structs have no late fields, so the field holds
this cell and the cell checks its one assignment, runs its initializer on first read and names
the field's dart anchor when it is read unassigned.

formal(dev/formal/LateCell.tla): a value kept once assigned, an init run to completion once, a cycle or misuse rejected
"""
@quarantine "dart's `late final` field, which Julia's structs lack: a cell set once or initialized on first read" Core.Function mutable struct Late{T}
    value::Any                       # T once assigned; held untyped so one compiled body serves every T
    state::UInt8                     # 0 unassigned, 1 its initializer running, 2 assigned
    anchor::String
    init::Union{Function,Nothing}
    Late{T}(anchor::String) where {T} = new{T}(nothing, 0x00, anchor, nothing)
    Late{T}(anchor::String, init::Function) where {T} = new{T}(nothing, 0x00, anchor, init)
end

# the read and the assignment are each one compiled body over every Late, `T` passed as a value
# (@nospecialize), the typed accessors below a typeassert and a convert per T: a cell is read in
# every collaborator, so a body per T multiplies its compile across the port's field types
@quarantine "the late field's read, Julia's dereference syntax c[]" Base.getindex Base.getindex(c::Late{T}) where {T} = _late_get(c, T)::T

@quarantine "the late field's read, one body for every T" Base.convert function _late_get(@nospecialize(c::Late), @nospecialize(T::Type))
    c.state == 0x02 && return c.value
    c.state == 0x01 && reject!(Internal("$(c.anchor): the late field's initializer read the field itself"), "Late")
    c.init === nothing && reject!(Unported(c.anchor), "the late field $(c.anchor), read before its assignment")
    c.state = 0x01
    local v = try
        convert(T, (c.init::Function)())
    catch
        c.state = 0x00   # dart leaves a field whose initializer threw uninitialized
        rethrow()
    end
    c.value = v
    c.state = 0x02
    return v
end

@quarantine "the late field's one assignment, Julia's c[] = v" Base.setindex! function Base.setindex!(c::Late{T}, v)::Nothing where {T}
    _late_set!(c, convert(T, v))
    return nothing
end

@quarantine "the late field's one assignment, one body for every T" Core.setfield! function _late_set!(@nospecialize(c::Late), @nospecialize(v))::Nothing
    c.init === nothing || reject!(Internal("$(c.anchor): a late final field with an initializer is assigned"), "Late")
    c.state == 0x02 && reject!(Internal("$(c.anchor): the late final field is assigned twice"), "Late")
    setfield!(c, :value, v)
    c.state = 0x02
    return nothing
end
