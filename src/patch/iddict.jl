# IdDict's methods by overlay: Base keeps an IdDict's pairs in one Memory{Any} that Julia's runtime reads
# and writes in C (julia/src/iddict.c) through ccalls no host supplies, so each Base method calling one is
# replaced in WasmTarget's overlay method table (METHOD_TABLE, src/julia/interpreter.jl) by Base's own
# body, word for word, its ccall a call of the C's port (src/julia/runtime/iddict.jl): the arguments the
# ccall converted (cconvert of a Csize_t) converted alike, a `Ptr{Cint}` out-argument the RefValue Base
# made for it, and the IdDict's key type beside a key the table may read back (src/julia/runtime/iddict.jl:
# the port's hash is specialized on a key's type). The overlays are consistent: natively each answers Base's
# answer.
# precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a device's
# overlays of Base in its method table).
# formal(dev/formal/IdTable.tla): LookupAgrees, CountAgrees

@quarantine pin"julia/base/iddict.jl:61 rehash!" "Base's rehash! of an IdDict calls the runtime's jl_idtable_rehash through a ccall; WasmGC calls its port" Base.rehash! @consistent_overlay METHOD_TABLE function Base.rehash!(d::IdDict, newsz = length(d.ht)%UInt)
    d.ht = jl_idtable_rehash(d.ht, Base.cconvert(Csize_t, newsz), keytype(d))
    d
end

@quarantine pin"julia/base/iddict.jl:76 setindex!" "Base's setindex! of an IdDict calls the runtime's jl_eqtable_put through a ccall, `inserted` written through a pointer; WasmGC calls its port, which writes the RefValue" Base.setindex! @consistent_overlay METHOD_TABLE function Base.setindex!(d::IdDict{K,V}, @nospecialize(val), @nospecialize(key)) where {K, V}
    !isa(key, K) && throw(Base.KeyTypeError(K, key))
    if !(val isa V) # avoid a dynamic call
        val = convert(V, val)::V
    end
    if d.ndel >= ((3*length(d.ht))>>2)
        Base.rehash!(d, max((length(d.ht)%UInt)>>1, 32))
        d.ndel = 0
    end
    inserted = Base.RefValue{Cint}(0)
    d.ht = jl_eqtable_put(d.ht, key, val, inserted, K)
    d.count += inserted[]
    return d
end

@quarantine pin"julia/base/iddict.jl:91 get" "Base's get of an IdDict calls the runtime's jl_eqtable_get through a ccall; WasmGC calls its port" Base.get @consistent_overlay METHOD_TABLE function Base.get(d::IdDict{K,V}, @nospecialize(key), @nospecialize(default)) where {K, V}
    val = jl_eqtable_get(d.ht, key, default)
    val === default ? default : val::V
end

@quarantine pin"julia/base/iddict.jl:96 getindex" "Base's getindex of an IdDict calls the runtime's jl_eqtable_get through a ccall; WasmGC calls its port" Base.getindex @consistent_overlay METHOD_TABLE function Base.getindex(d::IdDict{K,V}, @nospecialize(key)) where {K, V}
    val = jl_eqtable_get(d.ht, key, Base.secret_table_token)
    val === Base.secret_table_token && throw(KeyError(key))
    return val::V
end

@quarantine pin"julia/base/iddict.jl:102 pop!" "Base's pop! of an IdDict calls the runtime's jl_eqtable_pop through a ccall, `found` written through a pointer; WasmGC calls its port, which writes the RefValue" Base.pop! @consistent_overlay METHOD_TABLE function Base.pop!(d::IdDict{K,V}, @nospecialize(key), @nospecialize(default)) where {K, V}
    found = Base.RefValue{Cint}(0)
    val = jl_eqtable_pop(d.ht, key, default, found)
    if found[] === Cint(0)
        return default
    else
        d.count -= 1
        d.ndel += 1
        return val::V
    end
end

@quarantine pin"julia/base/iddict.jl:136 _oidd_nextind" "Base's _oidd_nextind calls the runtime's jl_eqtable_nextind through a ccall; WasmGC calls its port" Base._oidd_nextind @consistent_overlay METHOD_TABLE Base._oidd_nextind(a, i) = reinterpret(Int, jl_eqtable_nextind(a, Base.cconvert(Csize_t, i)))

@quarantine pin"julia/base/iddict.jl:148 get!" "Base's get! of an IdDict calls the runtime's jl_eqtable_get through a ccall; WasmGC calls its port" Base.get! @consistent_overlay METHOD_TABLE function Base.get!(d::IdDict{K,V}, @nospecialize(key), @nospecialize(default)) where {K, V}
    val = jl_eqtable_get(d.ht, key, Base.secret_table_token)
    if val === Base.secret_table_token
        val = isa(default, V) ? default : convert(V, default)::V
        setindex!(d, val, key)
        return val
    else
        return val::V
    end
end

@quarantine pin"julia/base/iddict.jl:159 get" "Base's get of an IdDict with a default function calls the runtime's jl_eqtable_get through a ccall; WasmGC calls its port" Base.get @consistent_overlay METHOD_TABLE function Base.get(default::Base.Callable, d::IdDict{K,V}, @nospecialize(key)) where {K, V}
    val = jl_eqtable_get(d.ht, key, Base.secret_table_token)
    if val === Base.secret_table_token
        return default()
    else
        return val::V
    end
end

@quarantine pin"julia/base/iddict.jl:168 get!" "Base's get! of an IdDict with a default function calls the runtime's jl_eqtable_get through a ccall; WasmGC calls its port" Base.get! @consistent_overlay METHOD_TABLE function Base.get!(default::Base.Callable, d::IdDict{K,V}, @nospecialize(key)) where {K, V}
    val = jl_eqtable_get(d.ht, key, Base.secret_table_token)
    if val === Base.secret_table_token
        val = default()
        if !isa(val, V)
            val = convert(V, val)::V
        end
        setindex!(d, val, key)
        return val
    else
        return val::V
    end
end
