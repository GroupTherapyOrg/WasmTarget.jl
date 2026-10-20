# The emission-diff check (dev/CHARTER.md C5; .github/workflows/gate-fast.yml and gate.yml,
# dev/emission_diff.sh): every function body a smoke case emits is fingerprinted from the module's
# bytes, and a body the head emits that the merge base does not must have been entered by a
# passing differential case.
#
# A body is keyed by its specialization: the MethodInstance's specTypes (test/utils.jl's
# _emission_compile reads them from the compile's function registry), a function no registry entry
# names by its name. Its fingerprint is its signature, locals and instructions with each operand
# that names another definition replaced by what it denotes: a function by its key, a type by its
# structure unfolded to a fixed depth, a global by its name, type and initializer, a tag by its type,
# a data segment by its bytes. So a body's fingerprint changes when its code does, and not when an
# unrelated definition renumbers the module. Its labeled fingerprint also maps each class-id
# constant to its class's type (the constant a class test compares with a class id read from an
# object's field 0, or an object's field 0 as it is built; a range check's span to its upper
# class), so one specialization compiled into two modules whose classes are numbered apart has one
# labeled fingerprint, while a mask or any other constant keeps its value.
# Entered means function entry, no finer: a copy of the module whose every defined function sets
# its own exported counter at its entry ran the case's inputs, and the counter was set. A changed
# branch inside an entered function counts as entered.
#
# Smoke writes the head's side (WT_EMISSION_DIR, set by `dev/lanes.sh --lane smoke`). The base's
# side is computed once per landed head and published (publish_main, the full gate's run of that
# commit; bootstrap_main for a base no gate published); the fast lane and the full gate fetch it
# and compile on the base only the cases it lacks or whose source changed (delta_main); merge_main
# gives the verdict.
module EmissionFingerprint

using SHA

# ------------------------------------------------------------------------- reading the binary
mutable struct Reader
    b::Vector{UInt8}
    p::Int   # the next byte, 1-based
end
@inline byte!(r::Reader)::UInt8 = (x = r.b[r.p]; r.p += 1; x)
function u32!(r::Reader)::Int
    local v, s = 0, 0
    while true
        local x = byte!(r)
        v |= Int(x & 0x7f) << s
        s += 7
        x & 0x80 == 0 && return v
    end
end
function sleb!(r::Reader)::Int64
    local v, s, x = Int64(0), 0, 0x00
    while true
        x = byte!(r)
        v |= Int64(x & 0x7f) << s
        s += 7
        x & 0x80 == 0 && break
    end
    (s < 64 && x & 0x40 != 0) && (v |= -(Int64(1) << s))
    return v
end
name!(r::Reader)::String = (n = u32!(r); s = String(r.b[r.p:r.p+n-1]); r.p += n; s)
leb(n::Integer)::Vector{UInt8} = (out = UInt8[]; n = UInt64(n);
    while true; x = UInt8(n & 0x7f); n >>= 7; n == 0 ? (push!(out, x); break) : push!(out, x | 0x80); end; out)

# the module's sections in order: (id, first byte, last byte) of each one's contents
function sections(b::Vector{UInt8})::Vector{Tuple{UInt8,Int,Int}}
    b[1:8] == UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00] || error("not a wasm module")
    local r = Reader(b, 9)
    local out = Tuple{UInt8,Int,Int}[]
    while r.p <= length(b)
        local id = byte!(r)
        local n = u32!(r)
        push!(out, (id, r.p, r.p + n - 1))
        r.p += n
    end
    return out
end

# A canonical stream: raw bytes, and tokens for what an operand denotes (kind byte, then text)
token!(out::IOBuffer, kind::UInt8, s::AbstractString) = (write(out, kind); write(out, leb(sizeof(s))); write(out, s))

const _SHORT_REFS = (0x70, 0x6F, 0x6E, 0x6D, 0x6C, 0x6B, 0x6A, 0x71, 0x72, 0x73, 0x69, 0x74)

# ------------------------------------------------------------------------- what a module's compile names
"""
    Meta(specs, classes, top)

What a compile names that its bytes do not: `specs`, each registered function's specialization by
its wasm function index (the MethodInstance's specTypes); `classes`, the type of each classId
(`classes[id + 1]`, `nothing` for an id no class has); `top`, the type index of the object root
whose field 0 is the class id (`-1` when the module has none).
"""
struct Meta
    specs::Dict{Int,String}
    classes::Vector{Union{Nothing,String}}
    top::Int
end
# the runners' answer (test/utils.jl _emission_compile, a NamedTuple of the same fields)
Meta(m::NamedTuple)::Meta = Meta(m.specs, m.classes, m.top)

# a specialization's text without Julia's gensym counters (they follow the order the process
# defined closures in, not the code)
_norm(s::AbstractString)::String = replace(String(s), r"#\d+" => "#")

# A name as the code knows it: Julia's gensym counters and WT's dedup suffix (before a role such as
# ` (export)`) dropped
normal_name(s::AbstractString)::String =
    replace(replace(String(s), r"#\d+" => "#"), r"_\d+(?=(?: \([^()]*\))?$)" => "_")

# ------------------------------------------------------------------------- the module's definitions
struct TypeInfo
    kind::UInt8          # 0x60 func, 0x5f struct, 0x5e array
    np::Int              # a function type's parameters
    nr::Int              # its results
    nfields::Int         # a struct's fields
    supers::Vector{Int}  # declared supertypes
end

struct Defs
    types::Vector{String}     # a type's structure, unfolded to a fixed depth
    info::Vector{TypeInfo}
    funcs::Vector{String}     # a function's key (imports first)
    func_types::Vector{Int}   # a function's type index (imports first)
    globals::Vector{String}   # a global's name, type and initializer (imports first)
    globals_lab::Vector{String}   # the same, its initializer's class ids labeled
    tags::Vector{String}      # a tag's type
    tag_types::Vector{Int}    # a tag's type index
    datas::Vector{String}     # a data segment's bytes
    body_types::Vector{Int}   # each defined function's type index
    is_top::BitSet            # the struct types whose field 0 is the class id (the root and its subtypes)
    meta::Meta
end

const TYPE_DEPTH = 8

# a value type in a type definition: its bytes, a type index as a placeholder recorded in `refs`
function _tvaltype!(r::Reader, out::IOBuffer, refs::Vector{Int})
    local x = byte!(r)
    write(out, x)
    if x == 0x63 || x == 0x64
        local st = r.p
        local v = sleb!(r)
        v < 0 ? write(out, r.b[st:r.p-1]) : (write(out, 0xfe); push!(refs, Int(v)))
    end
    return nothing
end
_tstorage!(r, out, refs) = (r.b[r.p] in (0x78, 0x77) ? write(out, byte!(r)) : _tvaltype!(r, out, refs); nothing)

function _types(b::Vector{UInt8}, lo::Int)::Tuple{Vector{String},Vector{TypeInfo}}
    local r = Reader(b, lo)
    local shapes = Tuple{Vector{UInt8},Vector{Int},Vector{Int}}[]
    local info = TypeInfo[]
    function subtype!()
        local x = r.b[r.p]
        local final, supers = true, Int[]
        if x == 0x50 || x == 0x4f
            r.p += 1; final = x == 0x4f
            for _ in 1:u32!(r); push!(supers, u32!(r)); end
        end
        local t, refs = IOBuffer(), Int[]
        write(t, final ? 0x01 : 0x00)
        local k = byte!(r)
        write(t, k)
        local np, nr, nf = 0, 0, 0
        if k == 0x60
            for j in 1:2
                local n = u32!(r); write(t, leb(n))
                j == 1 ? (np = n) : (nr = n)
                for _ in 1:n; _tvaltype!(r, t, refs); end
            end
        elseif k == 0x5f
            nf = u32!(r); write(t, leb(nf))
            for _ in 1:nf; _tstorage!(r, t, refs); write(t, byte!(r)); end
        elseif k == 0x5e
            _tstorage!(r, t, refs); write(t, byte!(r))
        else
            error("type section: composite type 0x$(string(k; base=16))")
        end
        push!(shapes, (take!(t), refs, supers))
        push!(info, TypeInfo(k, np, nr, nf, supers))
    end
    for _ in 1:u32!(r)
        if r.b[r.p] == 0x4e
            r.p += 1
            for _ in 1:u32!(r); subtype!(); end
        else
            subtype!()
        end
    end
    # depth-k unfolding: round 0 is each shape alone, round k hashes round k-1's labels in
    local labels = [bytes2hex(sha1(s[1])) for s in shapes]
    for _ in 1:TYPE_DEPTH
        labels = [bytes2hex(sha1(string(bytes2hex(s[1]), "|", join((labels[i+1] for i in s[2]), ","),
                                        "|", join((labels[i+1] for i in s[3]), ","))))[1:16] for s in shapes]
    end
    return labels, info
end

# each function's key: a registered function's specialization; a function that wraps or exports
# one (`<its name> (<role>)`) that specialization and the role; any other its normalised name
function _func_keys(names::Vector{String}, fnames::Dict{Int,String}, meta::Meta)::Vector{String}
    local spec_of = Dict{String,String}()
    for (i, s) in meta.specs
        local n = get(fnames, i, nothing)
        n === nothing || (spec_of[n] = s)
    end
    local out = String[]
    for (i0, n) in enumerate(names)
        local i = i0 - 1
        if haskey(meta.specs, i)
            push!(out, "spec " * _norm(meta.specs[i]))
            continue
        end
        local m = match(r"^(.*) \(([^()]*)\)$", n)
        if m !== nothing && haskey(spec_of, m[1])
            push!(out, "spec " * _norm(spec_of[m[1]]) * " (" * m[2] * ")")
        else
            push!(out, "name " * normal_name(n))
        end
    end
    return out
end

function definitions(b::Vector{UInt8}, meta::Meta)::Defs
    local secs = sections(b)
    local types, info = String[], TypeInfo[]
    for (id, lo, _) in secs; id == 0x01 && ((types, info) = _types(b, lo)); end
    local is_top = BitSet()
    if meta.top >= 0
        local memo = Dict{Int,Bool}()
        function top!(t)
            t == meta.top && return true
            haskey(memo, t) && return memo[t]
            memo[t] = false
            return memo[t] = any(top!, info[t+1].supers)
        end
        for t in 0:length(info)-1
            (info[t+1].kind == 0x5f && info[t+1].nfields >= 1 && top!(t)) && push!(is_top, t)
        end
    end
    local fnames = Dict{Int,String}(); local gnames = Dict{Int,String}()
    for (id, lo, hi) in secs
        id == 0x00 || continue
        local r = Reader(b, lo)
        name!(r) == "name" || continue
        while r.p <= hi
            local sub = byte!(r); local n = u32!(r); local stop = r.p + n
            if sub == 0x01 || sub == 0x07
                local d = sub == 0x01 ? fnames : gnames
                for _ in 1:u32!(r); local i = u32!(r); d[i] = name!(r); end
            end
            r.p = stop
        end
    end
    local defs = Defs(types, info, String[], Int[], String[], String[], String[], Int[], String[], Int[], is_top, meta)
    local fn_names = String[]
    vt(r) = (o = IOBuffer(); valtype!(r, o, defs); bytes2hex(take!(o)))
    for (id, lo, hi) in secs
        local r = Reader(b, lo)
        if id == 0x02
            for _ in 1:u32!(r)
                local m, f = name!(r), name!(r)
                local k = byte!(r)
                if k == 0x00
                    push!(defs.func_types, u32!(r))
                    push!(fn_names, get(fnames, length(fn_names), "$m.$f"))
                elseif k == 0x01
                    valtype!(r, IOBuffer(), defs); _limits!(r)
                elseif k == 0x02
                    _limits!(r)
                elseif k == 0x03
                    local v = vt(r); local mut = byte!(r)
                    push!(defs.globals, "import $m.$f $v $mut"); push!(defs.globals_lab, "import $m.$f $v $mut")
                elseif k == 0x04
                    byte!(r); local t = u32!(r); push!(defs.tags, types[t+1]); push!(defs.tag_types, t)
                else
                    error("import section: kind 0x$(string(k; base=16))")
                end
            end
        elseif id == 0x03
            for _ in 1:u32!(r); push!(defs.body_types, u32!(r)); end
            for t in defs.body_types
                push!(defs.func_types, t)
                push!(fn_names, get(fnames, length(fn_names), "function $(length(fn_names))"))
            end
            append!(defs.funcs, _func_keys(fn_names, fnames, meta))
        elseif id == 0x0d
            for _ in 1:u32!(r); byte!(r); local t = u32!(r); push!(defs.tags, types[t+1]); push!(defs.tag_types, t); end
        elseif id == 0x06
            for _ in 1:u32!(r)
                local gi = length(defs.globals)
                local v = vt(r); local mut = byte!(r)
                local at = r.p
                local roles = classify(r, defs, "the initializer of global $gi")
                r.p = at
                local o, ol = IOBuffer(), IOBuffer()
                expr!(r, o, defs, "the initializer of global $gi", nothing)
                r.p = at
                expr!(r, ol, defs, "the initializer of global $gi", roles)
                local gn = normal_name(get(gnames, gi, ""))
                push!(defs.globals, bytes2hex(sha1(string(gn, "|", v, "|", mut, "|", bytes2hex(take!(o))))))
                push!(defs.globals_lab, bytes2hex(sha1(string(gn, "|", v, "|", mut, "|", bytes2hex(take!(ol))))))
            end
        elseif id == 0x0b
            for _ in 1:u32!(r)
                local mode = u32!(r)
                mode == 0x02 && u32!(r)
                (mode == 0x00 || mode == 0x02) && expr!(r, IOBuffer(), defs, "a data segment's offset", nothing)
                local n = u32!(r)
                push!(defs.datas, bytes2hex(sha1(b[r.p:r.p+n-1])))
                r.p += n
            end
        end
    end
    # a module with no function section: its imported functions' keys
    isempty(defs.funcs) && append!(defs.funcs, _func_keys(fn_names, fnames, meta))
    return defs
end

_limits!(r::Reader) = (f = byte!(r); u32!(r); (f & 0x01) != 0 && u32!(r); nothing)

# ------------------------------------------------------------------------- instructions
function heaptype!(r::Reader, out::IOBuffer, d::Defs)
    local st = r.p
    local v = sleb!(r)
    v < 0 ? write(out, r.b[st:r.p-1]) : token!(out, 0xf1, d.types[v+1])
    return nothing
end
function valtype!(r::Reader, out::IOBuffer, d::Defs)
    local x = byte!(r)
    write(out, x)
    (x == 0x63 || x == 0x64) && heaptype!(r, out, d)
    return nothing
end
# a block type, and its (parameters, results)
function blocktype!(r::Reader, out::IOBuffer, d::Defs)::Tuple{Int,Int}
    local x = r.b[r.p]
    if x == 0x40
        write(out, byte!(r)); return (0, 0)
    elseif x in (0x7f, 0x7e, 0x7d, 0x7c, 0x7b) || x in _SHORT_REFS || x == 0x63 || x == 0x64
        valtype!(r, out, d); return (0, 1)
    else
        local t = sleb!(r)
        token!(out, 0xf1, d.types[t+1])
        return (d.info[t+1].np, d.info[t+1].nr)
    end
end
raw!(r::Reader, out::IOBuffer, f) = (st = r.p; v = f(r); write(out, r.b[st:r.p-1]); v)
func!(r, out, d) = (i = u32!(r); token!(out, 0xf2, d.funcs[i+1]); i)
type!(r, out, d) = (i = u32!(r); token!(out, 0xf1, d.types[i+1]); i)
glob!(r, out, d, lab::Bool) = (i = u32!(r); token!(out, 0xf3, (lab ? d.globals_lab : d.globals)[i+1]); i)
tag!(r, out, d) = (i = u32!(r); token!(out, 0xf4, d.tags[i+1]); i)
data!(r, out, d) = (i = u32!(r); token!(out, 0xf5, d.datas[i+1]); i)
memarg!(r) = (a = u32!(r); (a & 0x40) != 0 && u32!(r); u32!(r); nothing)

# One decoded instruction, what classify needs: its opcode, its 0xfb/0xfc sub-opcode (-1 if none),
# two immediates and the byte its opcode is at
const Instr = NTuple{5,Int}

"""
    expr!(r, out, defs, what, roles; trace)

One expression (a function's body after its locals, or a constant expression), up to and with the
`end` that closes it, written canonically to `out`. With `roles` (classify's answer), each class-id
constant is written as its class's type: the labeled stream. With `trace`, each instruction is
also pushed to it. An opcode this reader does not know raises, naming `what`: no instruction is
ever skipped.
"""
function expr!(r::Reader, out::IOBuffer, d::Defs, what::AbstractString,
               roles::Union{Nothing,Dict{Int,Tuple{Symbol,Int}}}; trace::Union{Nothing,Vector{Instr}}=nothing)
    local depth = 1
    local lab = roles !== nothing
    rec(op, sub, a, b, pos) = (trace === nothing || push!(trace, (Int(op), sub, a, b, pos)); nothing)
    while true
        local pos = r.p
        local op = byte!(r)
        write(out, op)
        if op in (0x02, 0x03, 0x04, 0x06)
            local (np, nr) = blocktype!(r, out, d); depth += 1
            rec(op, -1, np, nr, pos)
        elseif op == 0x1f   # try_table
            local (np, nr) = blocktype!(r, out, d); depth += 1
            local n = u32!(r); write(out, leb(n))
            for _ in 1:n
                local k = byte!(r); write(out, k)
                k <= 0x01 && tag!(r, out, d)
                raw!(r, out, u32!)
            end
            rec(op, -1, np, nr, pos)
        elseif op == 0x0b
            depth -= 1
            rec(op, -1, 0, 0, pos)
            depth == 0 && return nothing
        elseif op == 0x18   # delegate: ends its try
            raw!(r, out, u32!); depth -= 1
            rec(op, -1, 0, 0, pos)
        elseif op in (0x00, 0x01, 0x05, 0x0f, 0x19, 0x1a, 0x1b, 0x0a, 0xd1, 0xd3, 0xd4) ||
               0x45 <= op <= 0xc4 && op != 0x41
            rec(op, -1, 0, 0, pos)
        elseif op in (0x0c, 0x0d, 0x09, 0xd5, 0xd6, 0x25, 0x26, 0x3f, 0x40)
            raw!(r, out, u32!); rec(op, -1, 0, 0, pos)
        elseif op in (0x20, 0x21, 0x22)
            rec(op, -1, raw!(r, out, u32!), 0, pos)
        elseif op == 0x0e
            raw!(r, out, r -> (for _ in 1:u32!(r)+1; u32!(r); end))
            rec(op, -1, 0, 0, pos)
        elseif op in (0x10, 0x12, 0xd2)
            rec(op, -1, func!(r, out, d), 0, pos)
        elseif op in (0x11, 0x13)
            local t = type!(r, out, d); raw!(r, out, u32!)
            rec(op, -1, t, 0, pos)
        elseif op in (0x14, 0x15)
            rec(op, -1, type!(r, out, d), 0, pos)
        elseif op in (0x07, 0x08)
            rec(op, -1, tag!(r, out, d), 0, pos)
        elseif op == 0x1c
            local n = u32!(r); write(out, leb(n))
            for _ in 1:n; valtype!(r, out, d); end
            rec(op, -1, n, 0, pos)
        elseif op in (0x23, 0x24)
            glob!(r, out, d, lab); rec(op, -1, 0, 0, pos)
        elseif 0x28 <= op <= 0x3e
            raw!(r, out, memarg!); rec(op, -1, 0, 0, pos)
        elseif op == 0x41
            local st = r.p
            local v = sleb!(r)
            local role = lab ? get(roles, pos, nothing) : nothing
            local label = role === nothing ? nothing : _role_label(role, d.meta)
            label === nothing ? write(out, r.b[st:r.p-1]) : token!(out, 0xf6, label)
            rec(op, -1, Int(v), 0, pos)
        elseif op == 0x42
            raw!(r, out, sleb!); rec(op, -1, 0, 0, pos)
        elseif op == 0x43
            write(out, r.b[r.p:r.p+3]); r.p += 4; rec(op, -1, 0, 0, pos)
        elseif op == 0x44
            write(out, r.b[r.p:r.p+7]); r.p += 8; rec(op, -1, 0, 0, pos)
        elseif op == 0xd0
            heaptype!(r, out, d); rec(op, -1, 0, 0, pos)
        elseif op == 0xfb
            local s = u32!(r); write(out, leb(s))
            local a, bb = 0, 0
            if s in (0, 1, 6, 7, 11, 12, 13, 14, 15, 16)
                s == 15 || (a = type!(r, out, d))
            elseif s in (2, 3, 4, 5)
                a = type!(r, out, d); bb = raw!(r, out, u32!)
            elseif s == 8
                a = type!(r, out, d); bb = raw!(r, out, u32!)
            elseif s in (9, 18)
                a = type!(r, out, d); data!(r, out, d)
            elseif s in (10, 19)
                a = type!(r, out, d); raw!(r, out, u32!)
            elseif s == 17
                a = type!(r, out, d); type!(r, out, d)
            elseif s in (20, 21, 22, 23)
                heaptype!(r, out, d)
            elseif s in (24, 25)
                write(out, byte!(r)); raw!(r, out, u32!); heaptype!(r, out, d); heaptype!(r, out, d)
            elseif s in (26, 27, 28, 29, 30)
            else
                error("$what: opcode 0xfb $s")
            end
            rec(op, s, a, bb, pos)
        elseif op == 0xfc
            local s = u32!(r); write(out, leb(s))
            if s <= 7
            elseif s in (8,)
                data!(r, out, d); raw!(r, out, u32!)
            elseif s == 9
                data!(r, out, d)
            elseif s in (10, 12, 14)
                raw!(r, out, u32!); raw!(r, out, u32!)
            elseif s in (11, 13, 15, 16, 17)
                raw!(r, out, u32!)
            else
                error("$what: opcode 0xfc $s")
            end
            rec(op, s, 0, 0, pos)
        else
            error("$what: opcode 0x$(string(op; base=16))")
        end
    end
end

# a class-id constant's label: its class's type (a span, its upper class's)
function _role_label(role::Tuple{Symbol,Int}, m::Meta)::Union{Nothing,String}
    local kind, v = role
    kind === :offset && return "selector offset"
    (0 <= v < length(m.classes) && m.classes[v+1] !== nothing) || return nothing
    return (kind === :class ? "class " : "class span to ") * m.classes[v+1]
end

"""
    classify(r, defs, what) -> Dict{Int,Tuple{Symbol,Int}}

Which i32.const of the expression at `r` are class ids, by the byte its opcode is at, from a
walk of the operand stack (the validation algorithm's, values tagged by where they came from):
a class id is read by `struct.get` of field 0 of the object root or a subtype; a constant compared
with it (`i32.eq` … `i32.ge_u`) or subtracted from it is a class id (`(:class, id)`), a constant
compared with that difference a range check's span (`(:span, upper id)`), a constant added to it a
selector offset (`(:offset, 0)`); a constant built into field 0 of an object is its class id. A
local set from a class id reads as one. Any other constant is no class id.
"""
function classify(r::Reader, d::Defs, what::AbstractString)::Dict{Int,Tuple{Symbol,Int}}
    local trace = Instr[]
    expr!(r, IOBuffer(), d, what, nothing; trace)
    local roles = Dict{Int,Tuple{Symbol,Int}}()
    # a value's tag: 0 none, k > 0 the k-th constant, -1 a class id, -(k+1) a class id less constant k
    local CLS = -1
    local consts = Tuple{Int,Int}[]   # (byte, value) of each constant
    local stack = Int[]
    local frames = Tuple{Int,Int,Int}[]   # (stack base, params, results)
    local unreach = Bool[false]
    local locs = Set{Int}()   # locals set from a class id
    push!(frames, (0, 0, 0))
    pop1!() = length(stack) > frames[end][1] ? pop!(stack) :
              unreach[end] ? 0 : error("$what: the operand stack underflows")
    popn!(n) = (vs = Int[pop1!() for _ in 1:n]; reverse!(vs))
    pushn!(n) = (for _ in 1:n; push!(stack, 0); end)
    function stop!()
        resize!(stack, frames[end][1]); unreach[end] = true
    end
    function enter!(np, nr)
        popn!(np)
        push!(frames, (length(stack), np, nr)); push!(unreach, false)
        pushn!(np)
    end
    ftype(i) = d.info[d.func_types[i+1]+1]
    for (op, sub, a, bb, pos) in trace
        if op == 0x00
            stop!()
        elseif op == 0x01
        elseif op in (0x02, 0x03, 0x06, 0x1f)
            enter!(a, bb)
        elseif op == 0x04
            pop1!(); enter!(a, bb)
        elseif op == 0x05
            resize!(stack, frames[end][1]); unreach[end] = false; pushn!(frames[end][2])
        elseif op == 0x07
            resize!(stack, frames[end][1]); unreach[end] = false; pushn!(d.info[d.tag_types[a+1]+1].np)
        elseif op == 0x19
            resize!(stack, frames[end][1]); unreach[end] = false
        elseif op == 0x0b || op == 0x18
            length(frames) == 1 && break
            local (base, _, nr) = pop!(frames); pop!(unreach)
            resize!(stack, base); pushn!(nr)
        elseif op in (0x0c, 0x0f, 0x09, 0x0a)
            stop!()
        elseif op == 0x0e
            pop1!(); stop!()
        elseif op == 0x0d
            pop1!()
        elseif op == 0x08
            stop!()
        elseif op == 0x10 || op == 0x12
            local t = ftype(a); popn!(t.np)
            op == 0x12 ? stop!() : pushn!(t.nr)
        elseif op == 0x11 || op == 0x13 || op == 0x14 || op == 0x15
            local t = d.info[a+1]; pop1!(); popn!(t.np)
            op in (0x13, 0x15) ? stop!() : pushn!(t.nr)
        elseif op == 0x1a
            pop1!()
        elseif op in (0x1b, 0x1c)
            popn!(3); pushn!(1)
        elseif op == 0x20
            push!(stack, a in locs ? CLS : 0)
        elseif op == 0x21 || op == 0x22
            local v = pop1!()
            v == CLS && push!(locs, a)
            op == 0x22 && push!(stack, v)
        elseif op == 0x23 || op == 0x3f || op == 0xd0 || op == 0xd2
            pushn!(1)
        elseif op == 0x24
            pop1!()
        elseif op == 0x25 || op == 0x40 || 0x28 <= op <= 0x35 || op in (0x45, 0x50, 0xd1, 0xd4, 0xd5) ||
               0x67 <= op <= 0x69 || 0x79 <= op <= 0x7b || 0x8b <= op <= 0x91 || 0x99 <= op <= 0x9f || 0xa7 <= op <= 0xc4
            pop1!(); pushn!(1)
        elseif op == 0x26 || 0x36 <= op <= 0x3e
            popn!(2)
        elseif op == 0xd6
            pop1!()
        elseif op == 0x41
            push!(consts, (pos, a)); push!(stack, length(consts))
        elseif op in (0x42, 0x43, 0x44)
            pushn!(1)
        elseif 0x46 <= op <= 0x4f || op == 0x6a || op == 0x6b
            local x, y = popn!(2)
            local c, other = x > 0 ? (x, y) : (y, x)
            local out = 0
            if c > 0 && other == CLS
                local (cpos, cv) = consts[c]
                if op == 0x6a
                    roles[cpos] = (:offset, 0)
                else
                    roles[cpos] = (:class, cv)
                    op == 0x6b && x == CLS && (out = -(c + 1))
                end
            elseif op != 0x6a && op != 0x6b && x <= -2 && y > 0
                # a range check: (id - low) compared with the span (high - low)
                local low = consts[-x-1][2]
                local (cpos, cv) = consts[y]
                roles[cpos] = (:span, low + cv)
            end
            push!(stack, out)
        elseif 0x51 <= op <= 0x66 || 0x6c <= op <= 0x78 || 0x7c <= op <= 0x8a || 0x92 <= op <= 0x98 || 0xa0 <= op <= 0xa6
            popn!(2); pushn!(1)
        elseif op == 0xd3
            popn!(2); pushn!(1)
        elseif op == 0xfb
            if sub == 0
                local fs = popn!(d.info[a+1].nfields)
                (a in d.is_top && !isempty(fs) && fs[1] > 0) && (roles[consts[fs[1]][1]] = (:class, consts[fs[1]][2]))
                pushn!(1)
            elseif sub == 1
                pushn!(1)
            elseif sub in (2, 3, 4)
                pop1!(); push!(stack, (bb == 0 && a in d.is_top) ? CLS : 0)
            elseif sub == 5
                popn!(2)
            elseif sub in (6, 9, 10)
                popn!(2); pushn!(1)
            elseif sub == 7 || sub == 15 || 20 <= sub <= 30
                pop1!(); pushn!(1)
            elseif sub == 8
                popn!(bb); pushn!(1)
            elseif sub in (11, 12, 13)
                popn!(2); pushn!(1)
            elseif sub == 14
                popn!(3)
            elseif sub == 16
                popn!(4)
            elseif sub == 17
                popn!(5)
            elseif sub in (18, 19)
                popn!(4)
            else
                error("$what: classify has no stack effect for 0xfb $sub")
            end
        elseif op == 0xfc
            if sub <= 7
                pop1!(); pushn!(1)
            elseif sub in (8, 10, 11, 12, 14, 17)
                popn!(3)
            elseif sub in (9, 13)
            elseif sub == 15
                popn!(2); pushn!(1)
            elseif sub == 16
                pushn!(1)
            else
                error("$what: classify has no stack effect for 0xfc $sub")
            end
        else
            error("$what: classify has no stack effect for opcode 0x$(string(op; base=16))")
        end
    end
    return roles
end

"""
    fingerprints(bytes, meta) -> Vector{Tuple{String,String,String}}

Each defined function of the module, in order: its key (its specialization, or its name), its
body's fingerprint, and its labeled fingerprint: the same with each class-id constant written as
its class's type (classify), so one specialization compiled into two modules whose classes are
numbered apart has one labeled fingerprint, and a mask or any other constant keeps its value.
"""
function fingerprints(b::Vector{UInt8}, meta::Meta)::Vector{Tuple{String,String,String}}
    local d = definitions(b, meta)
    local nimp = length(d.funcs) - length(d.body_types)
    local out = Tuple{String,String,String}[]
    for (id, lo, _) in sections(b)
        id == 0x0a || continue
        local r = Reader(b, lo)
        local n = u32!(r)
        n == length(d.body_types) || error("the code section has $n bodies for $(length(d.body_types)) functions")
        for i in 1:n
            local size = u32!(r); local stop = r.p + size
            local key = d.funcs[nimp+i]
            local what = "function $(nimp+i-1) ($key)"
            local pre = IOBuffer()
            token!(pre, 0xf1, d.types[d.body_types[i]+1])
            local nl = u32!(r); write(pre, leb(nl))
            for _ in 1:nl; raw!(r, pre, u32!); valtype!(r, pre, d); end
            local head = take!(pre)
            local at = r.p
            local roles = classify(r, d, what)
            r.p = at
            local c, l = IOBuffer(), IOBuffer()
            write(c, head); write(l, head)
            expr!(r, c, d, what, nothing)
            r.p == stop || error("$what: its body ends at byte $(r.p), its size says $stop")
            r.p = at
            expr!(r, l, d, what, roles)
            push!(out, (key, bytes2hex(sha1(take!(c)))[1:16], bytes2hex(sha1(take!(l)))[1:16]))
        end
    end
    return out
end

# ------------------------------------------------------------------------- entered functions
"""
    instrument(bytes) -> (bytes′, n)

The module with one mutable i32 global per defined function, exported as `__wt_cov_<i>`, which
the function sets to 1 at its entry; `n` is the number of defined functions. Every existing index
is unchanged: the new globals follow every existing one.
"""
function instrument(b::Vector{UInt8})::Tuple{Vector{UInt8},Int}
    local secs = sections(b)
    local nimp_g = 0
    for (id, lo, _) in secs
        id == 0x02 || continue
        local r = Reader(b, lo)
        for _ in 1:u32!(r)
            name!(r); name!(r)
            local k = byte!(r)
            k == 0x00 ? u32!(r) : k == 0x01 ? (_skipvaltype!(r); _limits!(r)) : k == 0x02 ? _limits!(r) :
                k == 0x03 ? (_skipvaltype!(r); byte!(r); nimp_g += 1) : (byte!(r); u32!(r))
        end
    end
    local ndef_g = 0
    for (id, lo, _) in secs; id == 0x06 && (ndef_g = u32!(Reader(b, lo))); end
    local code = findfirst(s -> s[1] == 0x0a, secs)
    code === nothing && return (copy(b), 0)
    local nfun = u32!(Reader(b, secs[code][2]))
    local g0 = nimp_g + ndef_g
    local out = UInt8[b[1:8]...]
    emit(id, content) = (push!(out, id); append!(out, leb(length(content))); append!(out, content))
    function globals_section(old)
        local c = UInt8[]
        append!(c, leb(ndef_g + nfun))
        if old !== nothing
            local r = Reader(b, old[2]); u32!(r); append!(c, b[r.p:old[3]])
        end
        for _ in 1:nfun; append!(c, UInt8[0x7f, 0x01, 0x41, 0x00, 0x0b]); end
        return c
    end
    function exports_section(old)
        local c = UInt8[]
        local nold = old === nothing ? 0 : u32!(Reader(b, old[2]))
        append!(c, leb(nold + nfun))
        if old !== nothing
            local r = Reader(b, old[2]); u32!(r); append!(c, b[r.p:old[3]])
        end
        for i in 0:nfun-1
            local s = "__wt_cov_$i"
            append!(c, leb(sizeof(s))); append!(c, codeunits(s)); push!(c, 0x03); append!(c, leb(g0 + i))
        end
        return c
    end
    function code_section(sec)
        local r = Reader(b, sec[2])
        local c = UInt8[]
        append!(c, leb(u32!(r)))
        for i in 0:nfun-1
            local size = u32!(r); local stop = r.p + size
            local st = r.p
            for _ in 1:u32!(r); u32!(r); _skipvaltype!(r); end
            local body = UInt8[b[st:r.p-1]...]
            append!(body, UInt8[0x41, 0x01, 0x24]); append!(body, leb(g0 + i))
            append!(body, b[r.p:stop-1])
            append!(c, leb(length(body))); append!(c, body)
            r.p = stop
        end
        return c
    end
    # a section's place among the known ones (custom sections stay where they are)
    local order = Dict{UInt8,Int}(0x01 => 1, 0x02 => 2, 0x03 => 3, 0x04 => 4, 0x05 => 5, 0x0d => 6,
                                  0x06 => 7, 0x07 => 8, 0x08 => 9, 0x09 => 10, 0x0c => 11, 0x0a => 12, 0x0b => 13)
    local has_g = any(s -> s[1] == 0x06, secs); local has_e = any(s -> s[1] == 0x07, secs)
    for s in secs
        local id = s[1]
        local rank = get(order, id, 0)
        !has_g && rank > 7 && (emit(0x06, globals_section(nothing)); has_g = true)
        !has_e && rank > 8 && (emit(0x07, exports_section(nothing)); has_e = true)
        if id == 0x06
            emit(id, globals_section(s))
        elseif id == 0x07
            emit(id, exports_section(s))
        elseif id == 0x0a
            emit(id, code_section(s))
        else
            emit(id, b[s[2]:s[3]])
        end
    end
    return (out, nfun)
end
function _skipvaltype!(r::Reader)
    local x = byte!(r)
    (x == 0x63 || x == 0x64) && sleb!(r)
    return nothing
end

"""
    entered(bytes, fname, inputs; run_driver, merge_js) -> Set{Int}

The defined functions (0-based, in code-section order) a run of export `fname` over each JS
argument list in `inputs` entered, read from the instrumented module's counters. `run_driver` is
test/wasm_runner.jl's `run_driver_batch`, `merge_js` its host runtime merge.
"""
function entered(b::Vector{UInt8}, fname::AbstractString, inputs::Vector{String};
                 run_driver::Function, merge_js::AbstractString)::Set{Int}
    local ib, n = instrument(b)
    local src = """
    const importObject = {};
    $merge_js
    const { instance } = await WebAssembly.instantiate(bytes, importObject, { builtins: ['js-string'] });
    const f = instance.exports[$(repr(String(fname)))];
    for (const args of [$(join(("[" * a * "]" for a in inputs), ", "))]) { try { f(...args); } catch (e) {} }
    const hit = [];
    for (let i = 0; i < $n; i++) if (instance.exports['__wt_cov_' + i].value !== 0) hit.push(i);
    return [{ ok: hit }];
    """
    local status, res = run_driver(ib, src; ninputs = 1)
    (status === :ok && haskey(res[1], "ok")) ||
        error("the instrumented module of `$fname` did not run: $(status === :ok ? res[1] : res)")
    return Set{Int}(Int(i) for i in res[1]["ok"])
end

# ------------------------------------------------------------------------- a case's source
"""
    case_hash(f, argtypes) -> String

A hash of what a case compiles: its argument types and the lowered code of its function's method
for them (statements only: no line numbers), gensym counters left out. A cached base row is used
for a head case only when the two hashes agree. A closure the case builds is named, not hashed:
a change inside it alone leaves the hash, and the base rows it then reuses hold the old body,
which the head's new body differs from, so the change is checked, never hidden.
"""
function case_hash(@nospecialize(f), argtypes::Tuple)::String
    local io = IOBuffer()
    print(io, argtypes)
    for ci in Base.code_lowered(f, argtypes), st in ci.code
        print(io, "\n", st)
    end
    return bytes2hex(sha1(_norm(String(take!(io)))))[1:16]
end

# ------------------------------------------------------------------------- the head's side (smoke)
mutable struct Recorder
    io::IOStream
    run_driver::Function
    merge_js::String
end

"""
    recorder(dir, part, nparts; run_driver, merge_js) -> Recorder

Smoke's writer of part `part` of `nparts`: `<dir>/smoke-<part>-of-<nparts>.tsv`, its header naming
the Julia version that compiled it.
"""
function recorder(dir::AbstractString, part::Int, nparts::Int; run_driver::Function, merge_js::AbstractString)::Recorder
    mkpath(dir)
    local io = open(joinpath(dir, "smoke-$part-of-$nparts.tsv"), "w")
    println(io, "part\tsmoke\t", part, "\t", nparts, "\t", VERSION)
    return Recorder(io, run_driver, String(merge_js))
end

"""
    record!(rec, tag, pass, hash, modules)

One case: whether it passed and its source's hash (case_hash), and for each module its runner
compiled (`(bytes, export, inputs, meta)`, test/utils.jl's EMITTED_MODULES) each body's key,
fingerprint and labeled fingerprint and, for a passing case, whether a run of its inputs entered it.
"""
function record!(rec::Recorder, tag::AbstractString, pass::Bool, hash::AbstractString, modules::Vector{Any})
    println(rec.io, "C\t", tag, "\t", pass ? 1 : 0, "\t", hash)
    for (bytes, fname, inputs, meta) in modules
        local fps = fingerprints(bytes, Meta(meta))
        local hit = pass ? entered(bytes, fname, inputs; run_driver=rec.run_driver, merge_js=rec.merge_js) : Set{Int}()
        for (i, (k, h, l)) in enumerate(fps)
            println(rec.io, "B\t", tag, "\t", k, "\t", h, "\t", (i - 1) in hit ? 1 : 0, "\t", l)
        end
    end
    flush(rec.io)
    return nothing
end

# ------------------------------------------------------------------------- the base's side
# A base file: `base\t<sha>\t<julia version>` then, per case, `C\t<tag>\t<hash>` and its bodies `B\t<tag>\t<key>\t<fp>`
# (`F\t<tag>\t<error>` for a case the base did not compile).
function _read_base(path::AbstractString)::Tuple{String,String,Dict{String,String},Vector{Tuple{String,String}}}
    local ls = split.(readlines(path), '\t')
    (isempty(ls) || ls[1][1] != "base" || length(ls[1]) != 3) && error("emission: $path is no base file")
    local hashes = Dict{String,String}(); local bodies = Tuple{String,String}[]
    for l in ls[2:end]
        l[1] == "C" ? (hashes[String(l[2])] = String(l[3])) :
        l[1] == "B" ? push!(bodies, (String(l[3]), String(l[4]))) :
        l[1] == "F" ? nothing : error("emission: $path: a line `$(join(l, ' '))`")
    end
    return String(ls[1][2]), String(ls[1][3]), hashes, bodies
end

"""
    delta_main(out, base_sha, cached; groups, compile)

Run in a tree of the merge base's src with the head's test/: every smoke case whose source hash
the cached base file (`cached`, published for `base_sha`) does not hold for its tag is compiled
exactly as the head's runners compile it (`compile(f, argtypes) -> (bytes, source_map, meta)`,
test/utils.jl's _emission_compile),
and its bodies written to the base file `out`. A case the base cannot compile is listed (`F`), its
bodies then the head's alone.
"""
function delta_main(out::AbstractString, base_sha::AbstractString, cached::AbstractString;
                    groups::Vector, compile::Function)
    local t0 = time()
    local sha, ver, hashes, _ = _read_base(cached)
    sha == base_sha || error("emission: the cached base file is for $sha, not the merge base $base_sha")
    ver == string(VERSION) || error("emission: the cached base file was compiled by Julia $ver, this is $VERSION")
    local ncase = 0; local nnew = 0; local nfail = 0
    open(out, "w") do io
        println(io, "base\t", base_sha, "\t", VERSION)
        for (group, cases) in groups, case in cases
            local tag = "$group/$(case[1])"
            local ts = Tuple(map(typeof, case[3:end]))
            local h = case_hash(case[2], ts)
            ncase += 1
            get(hashes, tag, "") == h && continue
            nnew += 1
            local bytes, _, meta = try
                compile(case[2], ts)
            catch e
                nfail += 1
                println(io, "F\t", tag, "\t", replace(first(sprint(showerror, e), 200), r"\s+" => " "))
                continue
            end
            println(io, "C\t", tag, "\t", h)
            for (k, fp, _) in fingerprints(bytes, Meta(meta))
                println(io, "B\t", tag, "\t", k, "\t", fp)
            end
        end
    end
    println("emission base delta at $base_sha: $ncase cases, $(ncase - nnew) from the cached base, $nnew compiled on the base, " *
            "$nfail of them the base does not compile ($(round(time() - t0; digits=1)) s)")
    return nothing
end

"""
    bootstrap_main(part, dir, base_sha; groups, compile)

The whole base side for a base no full gate published: part `part` ("i/K") of every smoke case
(dealt one by one), compiled by the merge base's src, written to `<dir>/base-<i>-of-<K>.tsv`;
publish_main joins the parts.
"""
function bootstrap_main(part::AbstractString, dir::AbstractString, base_sha::AbstractString;
                        groups::Vector, compile::Function)
    local m = match(r"^([0-9]+)/([1-9][0-9]*)$", part)
    m === nothing && error("bootstrap_main: part $part: expected i/K")
    local i, k = parse(Int, m[1]), parse(Int, m[2])
    mkpath(dir)
    local t0 = time(); local ncase = 0; local nfail = 0
    open(joinpath(dir, "base-$i-of-$k.tsv"), "w") do io
        println(io, "bpart\t", base_sha, "\t", i, "\t", k, "\t", VERSION)
        local all = [(group, case) for (group, cases) in groups for case in cases]
        for (group, case) in all[i+1:k:end]
            local tag = "$group/$(case[1])"
            local ts = Tuple(map(typeof, case[3:end]))
            ncase += 1
            local bytes, _, meta = try
                compile(case[2], ts)
            catch e
                nfail += 1
                println(io, "F\t", tag, "\t", replace(first(sprint(showerror, e), 200), r"\s+" => " "))
                continue
            end
            println(io, "C\t", tag, "\t", case_hash(case[2], ts))
            for (key, fp, _) in fingerprints(bytes, Meta(meta))
                println(io, "B\t", tag, "\t", key, "\t", fp)
            end
        end
    end
    println("emission base $i/$k at $base_sha: $ncase cases, $nfail the base does not compile ($(round(time() - t0; digits=1)) s)")
    return nothing
end

"""
    publish_main(dir, out, sha)

One base file for `sha` from the part files in `dir`: smoke's parts 0..N-1 of one N (the full
gate's run of the commit: every case passed, its rows the commit's own emission) or bootstrap's
base parts 0..K-1 of one K. A missing part, or a smoke case that did not pass, raises.
"""
function publish_main(dir::AbstractString, out::AbstractString, sha::AbstractString)
    local files = sort!(filter(f -> endswith(f, ".tsv") && basename(f) != "base.tsv", readdir(dir; join=true)))
    local parts = Dict{Int,Int}(); local kinds = Set{String}(); local vers = Set{String}()
    local rows = String[]; local ncase = 0
    for f in files
        local ls = split.(readlines(f), '\t')
        isempty(ls) && error("emission: $f is empty")
        local h = ls[1]
        if h[1] == "part" && length(h) == 5 && h[2] == "smoke"
            push!(kinds, "smoke"); push!(vers, String(h[5]))
            parts[parse(Int, h[3])] = parse(Int, h[4])
            for l in ls[2:end]
                if l[1] == "C"
                    l[3] == "1" || error("emission: $(l[2]) did not pass: no base file is published from a red run")
                    push!(rows, "C\t$(l[2])\t$(l[4])"); ncase += 1
                elseif l[1] == "B"
                    push!(rows, "B\t$(l[2])\t$(l[3])\t$(l[4])")
                end
            end
        elseif h[1] == "bpart" && length(h) == 5
            push!(kinds, "bootstrap"); push!(vers, String(h[5]))
            h[2] == sha || error("emission: $f is a base part for $(h[2]), not $sha")
            parts[parse(Int, h[3])] = parse(Int, h[4])
            for l in ls[2:end]
                l[1] == "C" && (ncase += 1)
                l[1] in ("C", "B", "F") || error("emission: $f: a line `$(join(l, ' '))`")
                push!(rows, join(l, '\t'))
            end
        else
            error("emission: $f is no smoke or bootstrap part")
        end
    end
    length(kinds) == 1 || error("emission: $dir holds $(isempty(kinds) ? "no" : "both kinds of") part files")
    length(vers) == 1 || error("emission: the parts were compiled by Julia $(join(sort!(collect(vers)), " and "))")
    local n = isempty(parts) ? 0 : first(values(parts))
    (n > 0 && all(==(n), values(parts)) && sort!(collect(keys(parts))) == collect(0:n-1)) ||
        error("emission: the parts $(sort!(collect(keys(parts)))) are not parts 0..N-1 of one N")
    open(out, "w") do io
        println(io, "base\t", sha, "\t", only(vers))
        foreach(r -> println(io, r), rows)
    end
    println("emission: the base file of $sha (Julia $(only(vers))): $ncase cases from $n $(only(kinds)) parts")
    return nothing
end

# ------------------------------------------------------------------------- the verdict
"""
    verdict(dir, identical) -> (ok, lines)

The verdict over the files in `dir`: smoke's parts 0..N-1 of one N, and, unless the merge base's
emission-relevant tree is the head's (`identical`), the base file the full gate published for the
merge base (`base.tsv`) and the cases compiled on the base beside it (`delta.tsv`). It fails when
a body the head emits, as a (key, fingerprint) pair no base module holds, was entered by no
passing case, nor was a body of the same key and labeled fingerprint (one specialization compiled
into modules whose classes are numbered apart), naming each such body and its cases; and when a
part or the base side is missing or a case failed. Entered is function entry (instrument).
"""
function verdict(dir::AbstractString, identical::Bool)::Tuple{Bool,Vector{String}}
    local lines = String[]
    local parts = Dict{Int,Int}()
    local head = Dict{Tuple{String,String},Set{String}}()   # body => the cases whose modules hold it
    local ran = Set{Tuple{String,String}}()                 # bodies a passing case entered
    local ran_lab = Set{Tuple{String,String}}()             # (key, labeled fingerprint) a passing case entered
    local lab = Dict{Tuple{String,String},String}()         # body => its labeled fingerprint
    local failed = String[]; local ncases = 0; local vers = Set{String}()
    local smoke_files = sort!(filter(f -> startswith(basename(f), "smoke-") && endswith(f, ".tsv"), readdir(dir; join=true)))
    for f in smoke_files
        local ls = split.(readlines(f), '\t')
        (isempty(ls) || ls[1][1] != "part" || ls[1][2] != "smoke" || length(ls[1]) != 5) && error("emission: $f is no smoke part")
        local i, n = parse(Int, ls[1][3]), parse(Int, ls[1][4])
        push!(vers, String(ls[1][5]))
        haskey(parts, i) && error("emission: smoke part $i twice")
        parts[i] = n
        local passed = Set{String}()
        for l in ls
            if l[1] == "C"
                ncases += 1
                l[3] == "1" ? push!(passed, String(l[2])) : push!(failed, String(l[2]))
            elseif l[1] == "B"
                local key = (String(l[3]), String(l[4]))
                push!(get!(Set{String}, head, key), String(l[2]))
                lab[key] = String(l[6])
                if l[5] == "1" && String(l[2]) in passed
                    push!(ran, key); push!(ran_lab, (key[1], String(l[6])))
                end
            end
        end
    end
    local n = isempty(parts) ? 0 : first(values(parts))
    (n > 0 && all(==(n), values(parts)) && sort!(collect(keys(parts))) == collect(0:n-1)) ||
        (push!(lines, "emission: smoke's parts $(sort!(collect(keys(parts)))) are not parts 0..N-1 of one N"); return (false, lines))
    isempty(failed) || (push!(lines, "emission: $(length(failed)) case(s) did not pass: $(join(first(failed, 5), ", "))"); return (false, lines))
    if identical
        any(f -> basename(f) in ("base.tsv", "delta.tsv"), readdir(dir; join=true)) &&
            (push!(lines, "emission: a base side is present, but the tree is the merge base's"); return (false, lines))
        push!(lines, "emission: src, ext and Project.toml are the merge base's: no body changed ($(length(head)) bodies, $ncases cases)")
        return (true, lines)
    end
    local base = Set{Tuple{String,String}}()
    for f in ("base.tsv", "delta.tsv")
        isfile(joinpath(dir, f)) || (push!(lines, "emission: the base side's $f is missing"); return (false, lines))
        local _, ver, _, bodies = _read_base(joinpath(dir, f))
        push!(vers, ver)
        union!(base, bodies)
    end
    length(vers) == 1 || (push!(lines, "emission: the head and base sides were compiled by Julia $(join(sort!(collect(vers)), " and "))"); return (false, lines))
    local changed = sort!([key for key in keys(head) if !(key in base)])
    local unrun = [key for key in changed if !(key in ran) && !((key[1], lab[key]) in ran_lab)]
    for key in unrun
        local cs = sort!(collect(head[key]))
        push!(lines, "  NOT RUN  $(key[1])  [$(key[2])]  emitted by $(join(first(cs, 3), ", "))$(length(cs) > 3 ? " (+$(length(cs) - 3))" : "")")
    end
    push!(lines, "emission: $(length(head)) bodies on the head, $(length(base)) on the base, $(length(changed)) the base does not emit, " *
                 "$(length(changed) - length(unrun)) of them entered by a passing case (at function entry), $(length(unrun)) by none ($ncases cases)")
    return (isempty(unrun), lines)
end

function merge_main(dir::AbstractString, identical::Bool)
    local ok, lines = verdict(dir, identical)
    foreach(println, lines)
    exit(ok ? 0 : 1)
end

end # module
