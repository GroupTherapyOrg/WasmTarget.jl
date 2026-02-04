# SimpleDict - A hash table implementation using WasmTarget.jl array intrinsics
# This serves as a stepping stone toward compiling Julia's Dict type.
#
# Design:
# - Open addressing with linear probing
# - Keys and values stored in parallel arrays
# - Slots array tracks occupancy (0=empty, 1=occupied, 2=deleted)
# - Simple hash function for Int32 keys (extensible)

export SimpleDict, sd_new, sd_get, sd_set!, sd_haskey, sd_length
export StringDict, sdict_new, sdict_get, sdict_set!, sdict_haskey, sdict_length

# Slot states
const SLOT_EMPTY = Int32(0)
const SLOT_OCCUPIED = Int32(1)
const SLOT_DELETED = Int32(2)

# Global sink to prevent optimization
const _SD_SINK = Ref{Int32}(0)

"""
SimpleDict - A simple hash table for use in WASM.

For now, supports Int32 keys and Int32 values.
Will be extended to support other types as WasmTarget.jl grows.
"""
mutable struct SimpleDict
    keys::Vector{Int32}      # Key storage
    values::Vector{Int32}    # Value storage
    slots::Vector{Int32}     # Slot states: 0=empty, 1=occupied, 2=deleted
    count::Int32             # Number of occupied slots
    capacity::Int32          # Size of arrays
end

"""
    sd_new(capacity::Int32)::SimpleDict

Create a new SimpleDict with the given initial capacity.
"""
@noinline function sd_new(capacity::Int32)::SimpleDict
    keys = arr_new(Int32, capacity)
    values = arr_new(Int32, capacity)
    slots = arr_new(Int32, capacity)

    # Initialize slots to empty (arrays are already zero-filled by arr_new)
    # No loop needed since SLOT_EMPTY = 0

    return SimpleDict(keys, values, slots, Int32(0), capacity)
end

"""
Simple hash function for Int32 keys.
Uses multiplication - simple version to avoid complex shift IR.
"""
@noinline function sd_hash(key::Int32, capacity::Int32)::Int32
    # Simple multiplicative hash using a prime that fits in Int32
    h = Base.inferencebarrier(key * Int32(31))::Int32  # Simple prime multiplier
    # Ensure positive and within bounds
    h = h & Int32(0x7FFFFFFF)  # Clear sign bit
    result = (h % capacity) + Int32(1)  # 1-based index
    return result
end

"""
    sd_find_slot(d::SimpleDict, key::Int32)::Int32

Find the slot for a key. Returns slot_index if found (positive),
or -slot_index if not found (negative indicates where to insert).

Simplified implementation that avoids complex nested control flow.
"""
@noinline function sd_find_slot(d::SimpleDict, key::Int32)::Int32
    start = sd_hash(key, d.capacity)
    return sd_probe(d, key, start, Int32(0))  # Start at iteration 0
end

# Helper for probing - check one slot and recurse
@noinline function sd_probe(d::SimpleDict, key::Int32, start::Int32, iter::Int32)::Int32
    # Base case: too many iterations
    if iter >= d.capacity
        return Int32(0)  # Table full
    end

    # Calculate current slot
    i = ((start + iter - Int32(1)) % d.capacity) + Int32(1)
    slot_state = arr_get(d.slots, i)

    # Check slot state
    result = sd_check_slot(d, key, i, start, iter, slot_state)
    return result
end

# Check a single slot
@noinline function sd_check_slot(d::SimpleDict, key::Int32, i::Int32, start::Int32, iter::Int32, slot_state::Int32)::Int32
    if slot_state == SLOT_EMPTY
        return -i  # Insert here
    end
    if slot_state == SLOT_OCCUPIED
        return sd_check_key(d, key, i, start, iter)
    end
    # Deleted slot - continue probing
    return sd_probe(d, key, start, iter + Int32(1))
end

# Check if key matches at slot
@noinline function sd_check_key(d::SimpleDict, key::Int32, i::Int32, start::Int32, iter::Int32)::Int32
    if arr_get(d.keys, i) == key
        return i  # Found
    end
    # Key doesn't match - continue probing
    return sd_probe(d, key, start, iter + Int32(1))
end

"""
    sd_get(d::SimpleDict, key::Int32)::Int32

Get value for key. Returns 0 if not found.
"""
@noinline function sd_get(d::SimpleDict, key::Int32)::Int32
    slot = sd_find_slot(d, key)
    if slot > Int32(0)
        return arr_get(d.values, slot)
    else
        return Int32(0)  # Not found
    end
end

"""
    sd_get_default(d::SimpleDict, key::Int32, default::Int32)::Int32

Get value for key, returning default if not found.
"""
@noinline function sd_get_default(d::SimpleDict, key::Int32, default::Int32)::Int32
    slot = sd_find_slot(d, key)
    if slot > Int32(0)
        return arr_get(d.values, slot)
    else
        return default
    end
end

"""
    sd_haskey(d::SimpleDict, key::Int32)::Bool

Check if key exists in dictionary.
"""
@noinline function sd_haskey(d::SimpleDict, key::Int32)::Bool
    slot = sd_find_slot(d, key)
    return slot > Int32(0)
end

"""
    sd_set!(d::SimpleDict, key::Int32, value::Int32)::Nothing

Set key to value. Overwrites if key exists.
"""
@noinline function sd_set!(d::SimpleDict, key::Int32, value::Int32)::Nothing
    slot = sd_find_slot(d, key)

    if slot > Int32(0)
        # Key exists - update value
        arr_set!(d.values, slot, value)
    elseif slot < Int32(0)
        # Key doesn't exist - insert at returned slot
        insert_slot = -slot
        arr_set!(d.keys, insert_slot, key)
        arr_set!(d.values, insert_slot, value)
        arr_set!(d.slots, insert_slot, SLOT_OCCUPIED)
        d.count = d.count + Int32(1)
    end
    # slot == 0 means table full - silently fail for now

    _SD_SINK[] = value  # Prevent optimization
    return nothing
end

"""
    sd_delete!(d::SimpleDict, key::Int32)::Bool

Delete key from dictionary. Returns true if key was found and deleted.
"""
@noinline function sd_delete!(d::SimpleDict, key::Int32)::Bool
    slot = sd_find_slot(d, key)

    if slot > Int32(0)
        arr_set!(d.slots, slot, SLOT_DELETED)
        d.count = d.count - Int32(1)
        _SD_SINK[] = key
        return true
    else
        return false
    end
end

"""
    sd_length(d::SimpleDict)::Int32

Return number of entries in dictionary.
"""
@noinline function sd_length(d::SimpleDict)::Int32
    return d.count
end

# ============================================================================
# StringDict - Hash table with String keys, Int32 values
# ============================================================================

"""
StringDict - A hash table for String → Int32 mappings.

Used for symbol tables, keyword lookups, etc.
"""
mutable struct StringDict
    keys::Vector{String}     # Key storage (strings)
    values::Vector{Int32}    # Value storage
    slots::Vector{Int32}     # Slot states: 0=empty, 1=occupied, 2=deleted
    count::Int32             # Number of occupied slots
    capacity::Int32          # Size of arrays
end

# Global sink to prevent optimization
const _SDICT_SINK = Ref{Int32}(0)

"""
    sdict_new(capacity::Int32)::StringDict

Create a new StringDict with the given initial capacity.
"""
@noinline function sdict_new(capacity::Int32)::StringDict
    keys = Vector{String}(undef, capacity)
    values = arr_new(Int32, capacity)
    slots = arr_new(Int32, capacity)

    # Initialize keys with empty strings (placeholders)
    for i in 1:capacity
        keys[i] = ""
    end

    return StringDict(keys, values, slots, Int32(0), capacity)
end

"""
Hash function for StringDict - delegates to str_hash.
"""
@noinline function sdict_hash(key::String, capacity::Int32)::Int32
    h = str_hash(key)
    result = (h % capacity) + Int32(1)  # 1-based index
    return result
end

"""
    sdict_find_slot(d::StringDict, key::String)::Int32

Find the slot for a key. Returns slot_index if found (positive),
or -slot_index if not found (negative indicates where to insert).
"""
@noinline function sdict_find_slot(d::StringDict, key::String)::Int32
    start = sdict_hash(key, d.capacity)
    return sdict_probe(d, key, start, Int32(0))
end

# Helper for probing
@noinline function sdict_probe(d::StringDict, key::String, start::Int32, iter::Int32)::Int32
    if iter >= d.capacity
        return Int32(0)  # Table full
    end

    i = ((start + iter - Int32(1)) % d.capacity) + Int32(1)
    slot_state = arr_get(d.slots, i)

    result = sdict_check_slot(d, key, i, start, iter, slot_state)
    return result
end

@noinline function sdict_check_slot(d::StringDict, key::String, i::Int32, start::Int32, iter::Int32, slot_state::Int32)::Int32
    if slot_state == SLOT_EMPTY
        return -i  # Insert here
    end
    if slot_state == SLOT_OCCUPIED
        return sdict_check_key(d, key, i, start, iter)
    end
    # Deleted slot - continue probing
    return sdict_probe(d, key, start, iter + Int32(1))
end

@noinline function sdict_check_key(d::StringDict, key::String, i::Int32, start::Int32, iter::Int32)::Int32
    # Compare strings using str_eq
    if d.keys[i] == key
        return i  # Found
    end
    return sdict_probe(d, key, start, iter + Int32(1))
end

"""
    sdict_get(d::StringDict, key::String)::Int32

Get value for key. Returns 0 if not found.
"""
@noinline function sdict_get(d::StringDict, key::String)::Int32
    slot = sdict_find_slot(d, key)
    if slot > Int32(0)
        return arr_get(d.values, slot)
    else
        return Int32(0)  # Not found
    end
end

"""
    sdict_haskey(d::StringDict, key::String)::Bool

Check if key exists in dictionary.
"""
@noinline function sdict_haskey(d::StringDict, key::String)::Bool
    slot = sdict_find_slot(d, key)
    return slot > Int32(0)
end

"""
    sdict_set!(d::StringDict, key::String, value::Int32)::Nothing

Set key to value. Overwrites if key exists.
"""
@noinline function sdict_set!(d::StringDict, key::String, value::Int32)::Nothing
    slot = sdict_find_slot(d, key)

    if slot > Int32(0)
        # Key exists - update value
        arr_set!(d.values, slot, value)
    elseif slot < Int32(0)
        # Key doesn't exist - insert at returned slot
        insert_slot = -slot
        d.keys[insert_slot] = key
        arr_set!(d.values, insert_slot, value)
        arr_set!(d.slots, insert_slot, SLOT_OCCUPIED)
        d.count = d.count + Int32(1)
    end
    # slot == 0 means table full - silently fail for now

    _SDICT_SINK[] = value
    return nothing
end

"""
    sdict_length(d::StringDict)::Int32

Return number of entries in dictionary.
"""
@noinline function sdict_length(d::StringDict)::Int32
    return d.count
end
