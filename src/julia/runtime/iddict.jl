# Julia's identity table (julia/src/iddict.c), the C under Base's IdDict (julia/base/iddict.jl), whose
# methods call it through ccalls no host supplies, so each is replaced in WasmTarget's overlay method
# table by Base's own body calling the C ported here (src/patch/iddict.jl). Ported line by line over
# the table's Memory{Any} of 2*sz slots, a key at each even C index and its value after it: the C's
# 0-based index `i` is the Memory's element i + 1, a NULL slot an element never assigned (isassigned),
# a store of NULL Base's _unsetindex!. A key's hash is the runtime's jl_object_id (iddict.c keyhash,
# jl_object_id_ on the key's type tag), the one port of it (src/julia/runtime/hashing.jl jl_object_id),
# so a table an image constant holds, laid out by the compiling process's ids, is read by the same ids:
# an identity's id is the one the image keeps (julia/src/staticdata.c:1512 object_id_expected,
# image_slot!), every other key's a function of its content. Keys are compared by egal (`===`).
# How Julia differs (D7): the C's jl_object_id_ switches on the key's type tag at run time, where the port's
# jl_object_id is specialized on the key's type when the module is compiled, so a key carries its type: a key
# looked up, its caller's, and a key assigned (put, or read back by a rehash) the IdDict's key type K, which every
# key the table holds is (Base's setindex! throws KeyTypeError for any other), asserted where it is hashed; over a
# Union K the assert splits the hash by the key's type tag, as the C's switch does. A key whose type is only known
# at run time (K = Any) needs objectid of a value only run time types, a located rejection.
# formal(dev/formal/IdTable.tla): LookupAgrees, OneSlotPerKey, NextindVisitsMap, CountAgrees

# htable.h's inline size, the slot count of a table jl_table_assign_bp makes from an empty one
@quarantine pin"julia/src/support/htable.h:6 HT_N_INLINE" "the C's inline table size, a macro, is a constant of the port" Core.Int64 const HT_N_INLINE::Int = 32

# iddict.c's macros: a table's pair count, its empirical probe bound, a key's hash and its home index
@quarantine pin"julia/src/iddict.c:3 hash_size" "the C's macro hash_size(h), the pair count of a table of 2*sz slots, is a function of the port" Base.length iddict_hash_size(h::Memory{Any})::Int = length(h) ÷ 2
@quarantine pin"julia/src/iddict.c:6 max_probe" "the C's macro max_probe(size), the walk's bound, is a function of the port" Base.:>> iddict_max_probe(size::Int)::Int = size <= 1024 ? 16 : size >> 6
@quarantine pin"julia/src/iddict.c:8 keyhash" "the C's macro keyhash(k) is the runtime's jl_object_id_ of the key, here its one port, specialized on the key's type" Core.UInt64 iddict_keyhash(k)::UInt64 = jl_object_id(k)
@quarantine pin"julia/src/iddict.c:9 h2index" "the C's macro h2index(hv, sz), the home index of a hash in a table of sz pairs, is a function of the port" Base.:& iddict_h2index(hv::UInt64, sz::Int)::Int = Int((hv & UInt64(sz - 1)) * 0x0000000000000002)

"""
    jl_idtable_rehash(a, newsz, K) -> Memory{Any}

A new table of `newsz` slots holding each live pair of `a`, assigned in slot order
(julia/src/iddict.c:13), its Memory Julia's jl_alloc_memory_any, `Memory{Any}(undef, Int(newsz))`; each key
passed to jl_table_assign_bp as the C passes it, untyped, hashed there as the IdDict's key type `K`.
"""
@quarantine pin"julia/src/iddict.c:13 jl_idtable_rehash" "Julia's runtime rehashes an identity table in C, hashing each key by its type tag; WasmGC has no C, so the port runs over the table's Memory{Any}, each key read as the IdDict's key type its hash is specialized on" Core.Memory function jl_idtable_rehash(a::Memory{Any}, newsz::UInt, ::Type{K})::Memory{Any} where {K}
    local sz = length(a)
    local newa = Memory{Any}(undef, Int(newsz))
    local i = 0
    while i < sz
        if isassigned(a, i + 2)
            newa = jl_table_assign_bp(newa, a[i + 1], a[i + 2], K)[1]
        end
        i += 2
    end
    return newa
end

"""
    jl_table_assign_bp(a, key, val, K) -> Tuple{Memory{Any},Cint}

Stores `val` under `key` (julia/src/iddict.c:32), the table it leaves (the C's `*pa`, a new one where
`a` held no room within the probe bound) and whether the key was new (1) or its value overwritten (0):
the walk from the key's home index overwrites a live egal key's value, else takes the first deleted
or never-assigned slot it met; with neither, the table grows (jl_idtable_rehash) and the insert is
retried.

The key is untyped, the C's `jl_value_t *key`, and hashed as the IdDict's key type `K` (iddict.c:8
keyhash, the type tag's switch): the C's recursion through the growth (this → jl_idtable_rehash →
this) is then one specialization per `K` (@nospecializeinfer), where a key specialized on its caller's
type gave a Union `K` one per member, each a different signature of this method in the one inference
cycle, which Julia's recursion limit leaves as an unresolved call (Compiler/src/abstractinterpretation.jl:609
get_nospecializeinfer_sig, the signature inferred).
"""
@quarantine pin"julia/src/iddict.c:32 jl_table_assign_bp" "Julia's runtime assigns into an identity table in C through a pointer to the table; WasmGC has no C, so the port returns the table it leaves beside `inserted`" Core.Memory @nospecializeinfer function jl_table_assign_bp(a::Memory{Any}, @nospecialize(key), @nospecialize(val), ::Type{K})::Tuple{Memory{Any},Cint} where {K}
    local sz = iddict_hash_size(a)
    if sz == 0
        a = Memory{Any}(undef, HT_N_INLINE)
        sz = iddict_hash_size(a)
    end
    local maxprobe = iddict_max_probe(sz)
    local hv = iddict_keyhash(key::K)
    while true
        local iter = 0
        local index = iddict_h2index(hv, sz)
        sz *= 2
        local orig = index
        local empty_slot = -1
        while true
            if !isassigned(a, index + 1)
                empty_slot == -1 && (empty_slot = index)
                break
            end
            local k2 = a[index + 1]
            if key === k2
                if isassigned(a, index + 2)
                    a[index + 2] = val
                    return (a, Cint(0))
                end
                # `nothing` is the deletion sentinel, so a deleted slot is egal only to the key `nothing`
                empty_slot == -1 && (empty_slot = index)
            end
            if empty_slot == -1 && !isassigned(a, index + 2)
                empty_slot = index
            end
            index = (index + 2) & (sz - 1)
            iter += 1
            (iter <= maxprobe && index != orig) || break
        end
        if empty_slot != -1
            a[empty_slot + 1] = key
            a[empty_slot + 2] = val
            return (a, Cint(1))
        end
        # the table is full: quadruple or double its size, rehash, retry the insert
        sz = length(a)
        local newsz = sz < HT_N_INLINE ? HT_N_INLINE :
            (sz >= (1 << 19) || sz <= (1 << 8)) ? sz << 1 : sz << 2
        a = jl_idtable_rehash(a, UInt(newsz), K)
        sz = iddict_hash_size(a)
        maxprobe = iddict_max_probe(sz)
    end
end

"""
    jl_table_peek_bp(a, key) -> Int

The C index of the value slot holding `key` live (julia/src/iddict.c:111, the C's pointer to it), or
-1 for the C's NULL: the walk from the key's home index ends at a never-assigned key, at its bound or
back at the home; a deleted slot (key `nothing`, value never assigned) ends it unless the key is
`nothing` itself.
"""
@quarantine pin"julia/src/iddict.c:111 jl_table_peek_bp" "Julia's runtime finds a key's value slot in C and answers a pointer to it; WasmGC has no pointer, so the port answers its index" Core.Memory function jl_table_peek_bp(a::Memory{Any}, key)::Int
    local sz = iddict_hash_size(a)
    sz == 0 && return -1
    local maxprobe = iddict_max_probe(sz)
    local hv = iddict_keyhash(key)
    local index = iddict_h2index(hv, sz)
    sz *= 2
    local orig = index
    local iter = 0
    while true
        isassigned(a, index + 1) || return -1
        local k2 = a[index + 1]
        if key === k2
            isassigned(a, index + 2) && return index + 1
            # `nothing` is the deletion sentinel, so the search for it goes on past a deleted slot
            key === nothing || return -1
        end
        index = (index + 2) & (sz - 1)
        iter += 1
        (iter <= maxprobe && index != orig) || break
    end
    return -1
end

@quarantine pin"julia/src/iddict.c:144 jl_eqtable_put" "Julia's runtime puts into an identity table in C and writes `inserted` through a pointer; WasmGC has none, so the port writes Base's RefValue" Core.Memory function jl_eqtable_put(h::Memory{Any}, key, @nospecialize(val), p_inserted::Base.RefValue{Cint}, ::Type{K})::Memory{Any} where {K}
    local (t, inserted) = jl_table_assign_bp(h, key, val, K)
    p_inserted[] = inserted
    return t
end

@quarantine pin"julia/src/iddict.c:155 jl_eqtable_get" "Julia's runtime reads an identity table in C; WasmGC has no C, so the port reads the table's Memory{Any}" Core.Memory function jl_eqtable_get(h::Memory{Any}, key, @nospecialize(deflt))::Any
    local bp = jl_table_peek_bp(h, key)
    return bp == -1 ? deflt : h[bp + 1]
end

# the key a slot keeps is never read by Base's IdDict, so jl_eqtable_getkey (iddict.c:161) has no port

@quarantine pin"julia/src/iddict.c:168 jl_eqtable_pop" "Julia's runtime deletes from an identity table in C and writes `found` through a pointer; WasmGC has none, so the port writes Base's RefValue" Core.Memory function jl_eqtable_pop(h::Memory{Any}, key, @nospecialize(deflt), found::Base.RefValue{Cint})::Any
    local bp = jl_table_peek_bp(h, key)
    found[] = Cint(bp != -1)
    bp == -1 && return deflt
    local val = h[bp + 1]
    h[bp] = nothing
    Base._unsetindex!(h, bp + 1)
    return val
end

@quarantine pin"julia/src/iddict.c:182 jl_eqtable_nextind" "Julia's runtime walks an identity table in C; WasmGC has no C, so the port walks the table's Memory{Any}" Core.Memory function jl_eqtable_nextind(t::Memory{Any}, i::UInt)::UInt
    if i & 0x0000000000000001 != 0
        i += 0x0000000000000001
    end
    local alen = length(t) % UInt
    while i < alen && !isassigned(t, Int(i) + 2)
        i += 0x0000000000000002
    end
    i >= alen && return typemax(UInt)
    return i
end
