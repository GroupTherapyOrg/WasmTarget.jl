# parity(sdk/lib/_internal/wasm/common/object_patch.dart): dart:core's Object patch at the pin, the
# identity hash an object is given the first time it is read, its ports Julia methods of the module
# Runtime (src/julia/parity.jl RUNTIME_FILES).

"""
The last identity serial given (dart's `static final _hashCodeRnd = Random()`, the generator of the
identity hashes `_objectHashCode` stores): a final binding holding a mutable object, as dart's static
final holds its Random. Julia differs: a counter, never dart's random draw. dart's maps resolve two
equal hashes by `==`, so thirty random bits serve it; Julia's HAMT, under PersistentDict and every
ScopedValue scope, has no collision node and raises on two keys of one id (julia/base/hamt.jl:14-17,
:205-207 "Perfect hash collision"), which natively never happens: an object's id is inthash, a
bijection, of its address (julia/src/builtins.c:484), and two live objects never share an address. A
counter gives every object its own serial; it needs no seed, so no host import, the standalone and JS
modules alike (dev/formal/ObjectIdentity.tla: RandomIds is dart's draw, refuted by Unique). Natively
it is never written: the native Object__object_hash_code raises at its first read, before any write.
"""
@parity "sdk/lib/_internal/wasm/common/object_patch.dart:14 Object._hashCodeRnd" const Object__hash_code_rnd = Ref{Int32}(Int32(0))

"""
The identity hash of `obj` (dart's `static int _objectHashCode(Object obj)`): the header's identity
hash field (getIdentityHashField); 0, dart's initialIdentityHash, means none was given, so the next
serial is stored in it (setIdentityHashField) and returned; any other value is returned as it is, an
image constant's slot -k (zero-extended, src/julia/runtime/hashing.jl image_slot!) among them. Julia
differs: the value is the next serial (Object__hash_code_rnd), never a random draw, and once the
2^31 - 1 serials an i32 field holds positive are given the module stops, fatal, naming the gap
(identity_serials_spent: native Julia, whose id is an address's, cannot raise there, so no catch of the
program may see it), and never wraps: a wrapped serial would give a live object's id to another
(dev/formal/ObjectIdentity.tla NoWrap).
Specialized on the object's type, as Julia specializes a method on its arguments' types unless told
not to (no @nospecialize), so the field's read and write see its class (src/intrinsics.jl refuses a
class Julia boxes fresh). Natively no object carries the field and the read raises: natively
Base's own objectid is the answer, and this exists only in a module.

Reshaped: `set`, the field's writer, names the write's arm (src/julia/runtime/hashing.jl
identity_hash_field_holder): objectid's, set_identity_hash_field, which admits the identities alone, or a
data id's, set_owner_identity_hash_field, which also admits a String, whose field holds its data's id
(dataids(::Memory), src/patch/genericmemory.jl). Object ids and data ids are one counter's serials given
by this one function, so no two objects ever hold one serial; objectid's caller (jl_object_id_identity) names
set_identity_hash_field, dataids names the other.
"""
@parity "sdk/lib/_internal/wasm/common/object_patch.dart:16 Object._objectHashCode" function Object__object_hash_code(obj::Any,
        set::Union{typeof(set_identity_hash_field),typeof(set_owner_identity_hash_field)})::Int64
    local result = get_identity_hash_field(obj)
    if result == 0
        local last = Object__hash_code_rnd[]
        last == typemax(Int32) && identity_serials_spent()
        result = Int64(last) + 1
        Object__hash_code_rnd[] = Int32(result)
        set(obj, result)
        return result
    end
    return result
end
