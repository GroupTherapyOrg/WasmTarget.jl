"""
Check if a type is a user-defined struct (not a primitive or special type).
"""
function is_struct_type(T::Type)::Bool
    # Primitive types are not structs
    T <: Number && return false
    T === Bool && return false
    T === Nothing && return false
    T === Char && return false

    # Arrays, strings, and symbols have special handling - not user structs
    T <: AbstractArray && return false
    T === String && return false
    T === Symbol && return false

    # Internal Julia types that have pointer fields - not user structs
    # MemoryRef and GenericMemoryRef are used for array element access
    if T isa DataType && T.name.name in (:MemoryRef, :GenericMemoryRef, :Memory, :GenericMemory)
        return false
    end

    # Check if it's a concrete struct type
    return isconcretetype(T) && isstructtype(T) && !(T <: Tuple)
end

is_struct_type(::Any) = false

"""
Check if type is a closure (subtype of Function with captured fields).
"""
function is_closure_type(T::Type)::Bool
    # Union{} is bottom type - not a closure
    T === Union{} && return false
    # Must be a subtype of Function
    !(T <: Function) && return false
    # Must be a concrete struct type (fieldcount throws for abstract types)
    isconcretetype(T) && isstructtype(T) || return false
    # Must have fields (captured variables)
    fieldcount(T) == 0 && return false
    return true
end

is_closure_type(::Any) = false

"""
Register a closure type as a WasmGC struct.
"""
function register_closure_type!(mod::WasmModule, registry::TypeRegistry, T::DataType)
    # Already registered?
    haskey(registry.structs, T) && return registry.structs[T]

    # Get field information
    field_names = [fieldname(T, i) for i in 1:fieldcount(T)]
    field_types = [fieldtype(T, i) for i in 1:fieldcount(T)]

    # Create WasmGC field types (same logic as register_struct_type)
    wasm_fields = FieldType[]
    for ft in field_types
        if ft <: Vector
            # Vector{T} is represented as a struct with (array_ref, size_tuple)
            # Use register_vector_type! to get the struct type
            vec_info = register_vector_type!(mod, registry, ft)
            wasm_vt = ConcreteRef(vec_info.wasm_type_idx, true)
        elseif ft <: AbstractVector
            # Other AbstractVector types - use raw array
            elem_type = eltype(ft)
            array_type_idx = get_array_type!(mod, registry, elem_type)
            wasm_vt = ConcreteRef(array_type_idx, true)
        elseif ft isa DataType && (ft.name.name === :MemoryRef || ft.name.name === :GenericMemoryRef)
            # MemoryRef{T} / GenericMemoryRef maps to array type for element T
            elem_type = ft.name.name === :GenericMemoryRef ? ft.parameters[2] : ft.parameters[1]
            array_type_idx = get_array_type!(mod, registry, elem_type)
            wasm_vt = ConcreteRef(array_type_idx, true)
        elseif ft isa DataType && (ft.name.name === :Memory || ft.name.name === :GenericMemory)
            # Memory{T} / GenericMemory maps to array type for element T
            elem_type = eltype(ft)
            array_type_idx = get_array_type!(mod, registry, elem_type)
            wasm_vt = ConcreteRef(array_type_idx, true)
        elseif ft === String || ft === Symbol
            str_type_idx = get_string_array_type!(mod, registry)
            wasm_vt = ConcreteRef(str_type_idx, true)
        else
            wasm_vt = julia_to_wasm_type(ft)
        end
        push!(wasm_fields, FieldType(wasm_vt, false))  # immutable for closures
    end

    # Add struct type to module
    type_idx = add_struct_type!(mod, wasm_fields)

    # Record mapping
    info = StructInfo(T, type_idx, field_names, field_types)
    registry.structs[T] = info

    return info
end

# Track types currently being registered to prevent infinite recursion
# Maps type -> reserved type index for self-referential types, or -1 for normal types
const _registering_types = Dict{DataType, Int}()

"""
Check if a type is self-referential (has fields that reference itself).
"""
function is_self_referential_type(T::DataType)::Bool
    for i in 1:fieldcount(T)
        ft = fieldtype(T, i)
        # Check nullable fields (Union{Nothing, T})
        if ft isa Union
            inner = get_nullable_inner_type(ft)
            if inner !== nothing && inner === T
                return true
            end
        end
        # Check array fields (Vector{T})
        if ft <: AbstractVector && eltype(ft) === T
            return true
        end
    end
    return false
end

"""
Register a Julia struct type in the Wasm module.
"""
function register_struct_type!(mod::WasmModule, registry::TypeRegistry, T::DataType)
    # Already registered?
    haskey(registry.structs, T) && return registry.structs[T]

    # PURE-049: MemoryRef/Memory should NOT be registered as struct types.
    # They map to array types in WasmGC. Guard against callers that use
    # Julia's isstructtype() (true for MemoryRef) instead of our is_struct_type().
    if T isa DataType && T.name.name in (:MemoryRef, :GenericMemoryRef, :Memory, :GenericMemory)
        return nothing
    end

    # PURE-4149: SimpleVector is a variable-length container in Julia (fieldcount=0).
    # Register it as an externref array type so _svec_len and _svec_ref work.
    # SimpleVector elements are Any-typed, mapping to externref in WasmGC.
    if T === Core.SimpleVector
        # Create an externref array type
        arr_idx = add_array_type!(mod, ExternRef, true)
        # Register as a "struct" with 0 Julia fields but backed by an array type
        info = StructInfo(T, arr_idx, Symbol[], DataType[])
        registry.structs[T] = info
        return info
    end

    # Redirect Tuple types to their specialized registration function
    # Tuples have integer field names (1, 2, ...) not symbols
    if T <: Tuple
        return register_tuple_type!(mod, registry, T)
    end

    # Prevent infinite recursion for self-referential types
    if haskey(_registering_types, T)
        # Type is being registered - return nothing so caller handles it
        return nothing
    end

    # Check if this is a self-referential type
    if is_self_referential_type(T)
        # For self-referential types with Vector{T} fields, we use rec groups
        # to allow concrete type references between struct and array types.

        # Step 0: Pre-register non-self-referential field types BEFORE allocating
        # the reserved struct index. This ensures they get lower type indices,
        # so the struct's references to them are backward-looking (valid in Wasm).
        # Without this, fields like Vector{OtherType} or SyntaxData get allocated
        # AFTER the struct, creating forward references outside the rec group.
        _registering_types[T] = -1  # Mark as being registered to prevent recursion
        for i in 1:fieldcount(T)
            ft = fieldtype(T, i)
            # Skip self-referential fields (handled by rec group)
            if ft === T || (ft <: AbstractVector && eltype(ft) === T)
                continue
            end
            # Handle Union fields: pre-register the inner type
            if ft isa Union
                inner = get_nullable_inner_type(ft)
                if inner !== nothing
                    if inner === T || (inner <: AbstractVector && eltype(inner) === T)
                        continue  # Self-referential
                    end
                    if inner <: Array && inner isa DataType
                        elem = eltype(inner)
                        if elem !== T && isconcretetype(elem) && isstructtype(elem) && !haskey(registry.structs, elem) && !haskey(_registering_types, elem)
                            register_struct_type!(mod, registry, elem)
                        end
                        if !haskey(registry.vectors, inner)
                            register_vector_type!(mod, registry, inner)
                        end
                    elseif isconcretetype(inner) && isstructtype(inner) && !haskey(registry.structs, inner) && !haskey(_registering_types, inner)
                        register_struct_type!(mod, registry, inner)
                    end
                end
            elseif ft <: Array && ft isa DataType
                elem = eltype(ft)
                if elem !== T && isconcretetype(elem) && isstructtype(elem) && !haskey(registry.structs, elem) && !haskey(_registering_types, elem)
                    register_struct_type!(mod, registry, elem)
                end
                if !haskey(registry.vectors, ft)
                    register_vector_type!(mod, registry, ft)
                end
            elseif ft <: AbstractVector && ft isa DataType && !(ft <: Array)
                # Non-Array AbstractVector types (BitVector, etc.) - register as regular struct
                if !haskey(registry.structs, ft) && !haskey(_registering_types, ft)
                    register_struct_type!(mod, registry, ft)
                end
            elseif isconcretetype(ft) && isstructtype(ft) && !haskey(registry.structs, ft) && !haskey(_registering_types, ft)
                register_struct_type!(mod, registry, ft)
            end
        end
        delete!(_registering_types, T)

        # Step 1: Add struct placeholder first (with placeholder fields)
        # We need the struct index before creating array types that reference it
        temp_fields = FieldType[]
        for i in 1:fieldcount(T)
            ft = fieldtype(T, i)
            if ft === Int32 || ft === UInt32 || ft === Bool || ft === Char ||
               ft === Int8 || ft === UInt8 || ft === Int16 || ft === UInt16
                push!(temp_fields, FieldType(I32, true))
            elseif ft === Int64 || ft === UInt64 || ft === Int
                push!(temp_fields, FieldType(I64, true))
            elseif ft === Float32
                push!(temp_fields, FieldType(F32, true))
            elseif ft === Float64
                push!(temp_fields, FieldType(F64, true))
            elseif ft <: AbstractVector || ft === String || ft === Symbol
                push!(temp_fields, FieldType(ArrayRef, true))  # Placeholder
            else
                push!(temp_fields, FieldType(StructRef, true))  # Placeholder
            end
        end
        reserved_idx = add_struct_type!(mod, temp_fields)
        _registering_types[T] = Int(reserved_idx)

        # Step 2: Create array types for Vector{T} fields with concrete element type
        # Now that we have reserved_idx, array types can reference it
        # Also create Vector wrapper structs and include them in the rec group.
        array_type_indices = Dict{Int, UInt32}()
        vector_wrapper_indices = UInt32[]
        for i in 1:fieldcount(T)
            ft = fieldtype(T, i)
            vec_type = nothing  # The Vector type to create a wrapper for
            if ft <: AbstractVector && eltype(ft) === T
                vec_type = ft
            elseif ft isa Union
                inner = get_nullable_inner_type(ft)
                if inner !== nothing && inner <: AbstractVector && eltype(inner) === T
                    vec_type = inner
                end
            end
            if vec_type !== nothing
                # Create array type with concrete element reference
                arr_idx = add_array_type!(mod, ConcreteRef(reserved_idx, true), true)
                array_type_indices[i] = arr_idx
                registry.arrays[T] = arr_idx
                # Also create the Vector wrapper struct now (within rec group scope)
                # so it gets a type index adjacent to the array type
                if vec_type isa DataType && !haskey(registry.structs, vec_type)
                    size_tuple_type = Tuple{Int64}
                    if !haskey(registry.structs, size_tuple_type)
                        register_tuple_type!(mod, registry, size_tuple_type)
                    end
                    size_struct_info = registry.structs[size_tuple_type]
                    vec_fields = [
                        FieldType(ConcreteRef(arr_idx, true), true),
                        FieldType(ConcreteRef(size_struct_info.wasm_type_idx, true), true)
                    ]
                    vec_type_idx = add_struct_type!(mod, vec_fields)
                    vec_info = StructInfo(vec_type, vec_type_idx, [:ref, :size], DataType[Array{T, 1}, size_tuple_type])
                    registry.structs[vec_type] = vec_info
                    push!(vector_wrapper_indices, vec_type_idx)
                end
            end
        end

        # Step 3: Add rec group for the struct, its array types, and Vector wrappers
        rec_group_types = UInt32[reserved_idx]
        for arr_idx in values(array_type_indices)
            push!(rec_group_types, arr_idx)
        end
        append!(rec_group_types, vector_wrapper_indices)
        if length(rec_group_types) > 1
            add_rec_group!(mod, rec_group_types)
        end

        try
            return _register_struct_type_impl_with_reserved!(mod, registry, T, reserved_idx)
        finally
            delete!(_registering_types, T)
        end
    else
        # Non-self-referential type - standard registration
        _registering_types[T] = -1
        try
            return _register_struct_type_impl!(mod, registry, T)
        finally
            delete!(_registering_types, T)
        end
    end
end

"""
Register a self-referential struct type using a pre-reserved type index.
The placeholder struct was already added; we update it with the correct fields.
"""
function _register_struct_type_impl_with_reserved!(mod::WasmModule, registry::TypeRegistry, T::DataType, reserved_idx::UInt32)
    field_names = [fieldname(T, i) for i in 1:fieldcount(T)]
    field_types = [fieldtype(T, i) for i in 1:fieldcount(T)]

    # Build the proper fields with correct self-references
    # Note: rec groups are already set up by register_struct_type!
    #
    # IMPORTANT: Check Memory/MemoryRef BEFORE AbstractVector because
    # Memory <: AbstractVector but should map to raw array, not Vector struct
    wasm_fields = FieldType[]
    for ft in field_types
        if ft isa DataType && (ft.name.name === :MemoryRef || ft.name.name === :GenericMemoryRef)
            # MemoryRef{T} / GenericMemoryRef maps to array type for element T
            elem_type = ft.name.name === :GenericMemoryRef ? ft.parameters[2] : ft.parameters[1]
            array_type_idx = get_array_type!(mod, registry, elem_type)
            wasm_vt = ConcreteRef(array_type_idx, true)
        elseif ft isa DataType && (ft.name.name === :Memory || ft.name.name === :GenericMemory)
            # Memory{T} / GenericMemory maps to array type for element T
            elem_type = eltype(ft)
            array_type_idx = get_array_type!(mod, registry, elem_type)
            wasm_vt = ConcreteRef(array_type_idx, true)
        elseif ft === Vector{String}
            # Vector{String} is a struct with (array-of-string-refs, size tuple)
            info = register_vector_type!(mod, registry, ft)
            wasm_vt = ConcreteRef(info.wasm_type_idx, true)
        elseif ft <: Array && ft isa DataType
            # Array{T}/Vector{T} is a struct with (ref, size) fields
            elem_type = eltype(ft)
            if !haskey(_registering_types, elem_type) && isconcretetype(elem_type) && isstructtype(elem_type)
                register_struct_type!(mod, registry, elem_type)
            end
            info = register_vector_type!(mod, registry, ft)
            wasm_vt = ConcreteRef(info.wasm_type_idx, true)
        elseif ft <: AbstractVector && ft isa DataType
            # Non-Array AbstractVector types (BitVector, etc.) — register as regular struct
            info = register_struct_type!(mod, registry, ft)
            if info !== nothing
                wasm_vt = ConcreteRef(info.wasm_type_idx, true)
            else
                wasm_vt = ExternRef  # fallback
            end
        elseif ft <: AbstractVector
            # Generic AbstractVector - use raw array
            elem_type = eltype(ft)
            if !haskey(_registering_types, elem_type) && isconcretetype(elem_type) && isstructtype(elem_type)
                register_struct_type!(mod, registry, elem_type)
            end
            array_type_idx = get_array_type!(mod, registry, elem_type)
            wasm_vt = ConcreteRef(array_type_idx, true)
        elseif ft === String || ft === Symbol
            # Strings and Symbols are WasmGC byte arrays
            str_type_idx = get_string_array_type!(mod, registry)
            wasm_vt = ConcreteRef(str_type_idx, true)
        elseif ft === Any
            wasm_vt = ExternRef
        elseif ft === Int32 || ft === UInt32 || ft === Bool || ft === Char ||
               ft === Int8 || ft === UInt8 || ft === Int16 || ft === UInt16
            wasm_vt = I32
        elseif ft === Int64 || ft === UInt64 || ft === Int
            wasm_vt = I64
        elseif ft === Float32
            wasm_vt = F32
        elseif ft === Float64
            wasm_vt = F64
        elseif ft === Nothing
            # Nothing is a singleton type — no data, represent as i32 placeholder
            wasm_vt = I32
        elseif isprimitivetype(ft)
            sz = sizeof(ft)
            wasm_vt = sz <= 4 ? I32 : I64
        elseif ft isa Union
            inner_type = get_nullable_inner_type(ft)
            if inner_type !== nothing
                if inner_type <: Array && inner_type isa DataType
                    # Union{Nothing, Vector{T}} - use Vector struct type
                    elem_type = eltype(inner_type)
                    if !haskey(_registering_types, elem_type) && isconcretetype(elem_type) && isstructtype(elem_type)
                        register_struct_type!(mod, registry, elem_type)
                    end
                    info = register_vector_type!(mod, registry, inner_type)
                    wasm_vt = ConcreteRef(info.wasm_type_idx, true)
                elseif inner_type <: AbstractVector && inner_type isa DataType
                    # Non-Array AbstractVector (BitVector, etc.) — register as struct
                    info_av = register_struct_type!(mod, registry, inner_type)
                    if info_av !== nothing
                        wasm_vt = ConcreteRef(info_av.wasm_type_idx, true)
                    else
                        wasm_vt = ExternRef
                    end
                elseif inner_type <: AbstractVector
                    # Generic AbstractVector - use raw array
                    elem_type = eltype(inner_type)
                    if !haskey(_registering_types, elem_type) && isconcretetype(elem_type) && isstructtype(elem_type)
                        register_struct_type!(mod, registry, elem_type)
                    end
                    array_type_idx = get_array_type!(mod, registry, elem_type)
                    wasm_vt = ConcreteRef(array_type_idx, true)
                elseif inner_type === String || inner_type === Symbol
                    # Union{Nothing, String/Symbol} — nullable string array ref
                    str_type_idx = get_string_array_type!(mod, registry)
                    wasm_vt = ConcreteRef(str_type_idx, true)
                elseif isconcretetype(inner_type) && isstructtype(inner_type)
                    if haskey(_registering_types, inner_type)
                        r_idx = _registering_types[inner_type]
                        if r_idx >= 0
                            wasm_vt = ConcreteRef(UInt32(r_idx), true)
                        else
                            wasm_vt = StructRef
                        end
                    else
                        register_struct_type!(mod, registry, inner_type)
                        info = registry.structs[inner_type]
                        wasm_vt = ConcreteRef(info.wasm_type_idx, true)
                    end
                else
                    wasm_vt = julia_to_wasm_type(ft)
                end
            elseif needs_tagged_union(ft)
                union_info = register_union_type!(mod, registry, ft)
                wasm_vt = ConcreteRef(union_info.wasm_type_idx, true)
            else
                wasm_vt = julia_to_wasm_type(ft)
            end
        elseif isconcretetype(ft) && isstructtype(ft)
            if haskey(_registering_types, ft)
                r_idx = _registering_types[ft]
                if r_idx >= 0
                    wasm_vt = ConcreteRef(UInt32(r_idx), true)
                else
                    wasm_vt = StructRef
                end
            else
                nested_info = register_struct_type!(mod, registry, ft)
                if nested_info !== nothing
                    wasm_vt = ConcreteRef(nested_info.wasm_type_idx, true)
                else
                    wasm_vt = StructRef
                end
            end
        else
            wasm_vt = julia_to_wasm_type(ft)
        end
        push!(wasm_fields, FieldType(wasm_vt, true))
    end

    # Update the placeholder struct with the correct fields
    mod.types[reserved_idx + 1] = StructType(wasm_fields)

    # Record mapping (rec groups already set up by register_struct_type!)
    info = StructInfo(T, reserved_idx, field_names, field_types)
    registry.structs[T] = info

    return info
end

function _register_struct_type_impl!(mod::WasmModule, registry::TypeRegistry, T::DataType)
    # Get field information
    field_names = [fieldname(T, i) for i in 1:fieldcount(T)]
    field_types = [fieldtype(T, i) for i in 1:fieldcount(T)]

    # Create WasmGC field types
    wasm_fields = FieldType[]
    for ft in field_types
        # For array fields, use concrete reference to registered array type
        # But for Vector{T}, use the Vector struct type (with ref and size fields)
        # since Vector in Julia 1.11+ is a struct, not a raw array
        #
        # IMPORTANT: Check Memory/MemoryRef BEFORE AbstractVector because
        # Memory <: AbstractVector but should map to raw array, not Vector struct
        if ft isa DataType && (ft.name.name === :MemoryRef || ft.name.name === :GenericMemoryRef)
            # MemoryRef{T} / GenericMemoryRef maps to array type for element T
            # GenericMemoryRef parameters: (atomicity, element_type, addrspace)
            elem_type = ft.name.name === :GenericMemoryRef ? ft.parameters[2] : ft.parameters[1]
            array_type_idx = get_array_type!(mod, registry, elem_type)
            wasm_vt = ConcreteRef(array_type_idx, true)  # nullable reference
        elseif ft isa DataType && (ft.name.name === :Memory || ft.name.name === :GenericMemory)
            # Memory{T} / GenericMemory maps to array type for element T
            elem_type = eltype(ft)
            array_type_idx = get_array_type!(mod, registry, elem_type)
            wasm_vt = ConcreteRef(array_type_idx, true)  # nullable reference
        elseif ft === Vector{String}
            # Special case: Vector{String} is a struct with array-of-string-refs + size tuple
            # Register as Vector struct type
            info = register_vector_type!(mod, registry, ft)
            wasm_vt = ConcreteRef(info.wasm_type_idx, true)
        elseif ft <: Array && ft isa DataType
            # Array{T}/Vector{T} is a struct with (ref, size) fields
            # Register it as a Vector struct type, not a raw array
            info = register_vector_type!(mod, registry, ft)
            wasm_vt = ConcreteRef(info.wasm_type_idx, true)
        elseif ft <: AbstractVector && ft isa DataType
            # Non-Array AbstractVector types (BitVector, etc.) — register as regular struct
            info_av = register_struct_type!(mod, registry, ft)
            if info_av !== nothing
                wasm_vt = ConcreteRef(info_av.wasm_type_idx, true)
            else
                wasm_vt = ExternRef  # fallback
            end
        elseif ft <: AbstractVector && !(ft isa Union)
            # Generic AbstractVector without concrete type - use raw array
            # PURE-046: Check !(ft isa Union) because Union{Memory{UInt8}, Memory{UInt16}, ...}
            # would match ft <: AbstractVector but should be handled as a tagged union instead.
            elem_type = eltype(ft)
            array_type_idx = get_array_type!(mod, registry, elem_type)
            wasm_vt = ConcreteRef(array_type_idx, true)  # nullable reference
        elseif ft === String || ft === Symbol
            # Strings and Symbols are WasmGC byte arrays
            str_type_idx = get_string_array_type!(mod, registry)
            wasm_vt = ConcreteRef(str_type_idx, true)
        elseif ft === Any
            # Any type - map to externref (Julia 1.12 closures have Any fields)
            wasm_vt = ExternRef
        elseif ft === Int32 || ft === UInt32 || ft === Bool || ft === Char ||
               ft === Int8 || ft === UInt8 || ft === Int16 || ft === UInt16
            # Standard 32-bit or smaller types
            wasm_vt = I32
        elseif ft === Int64 || ft === UInt64 || ft === Int
            # Standard 64-bit integer types
            wasm_vt = I64
        elseif ft === Float32
            wasm_vt = F32
        elseif ft === Float64
            wasm_vt = F64
        elseif ft === Nothing
            # Nothing is a singleton type — no data, represent as i32 placeholder
            wasm_vt = I32
        elseif isprimitivetype(ft)
            # Custom primitive types (e.g., JuliaSyntax.Kind) - map by size
            sz = sizeof(ft)
            if sz <= 4
                wasm_vt = I32
            elseif sz <= 8
                wasm_vt = I64
            else
                error("Primitive type too large for Wasm field: $ft ($sz bytes)")
            end
        elseif ft isa Union
            # Handle Union types for struct fields
            inner_type = get_nullable_inner_type(ft)
            if inner_type !== nothing
                # Union{Nothing, T} as nullable reference to T
                if inner_type <: Array && inner_type isa DataType
                    # Union{Nothing, Vector{T}} - use Vector struct type
                    elem_type = eltype(inner_type)
                    # For non-recursive types, register the element type first
                    if !haskey(_registering_types, elem_type) && isconcretetype(elem_type) && isstructtype(elem_type)
                        register_struct_type!(mod, registry, elem_type)
                    end
                    info = register_vector_type!(mod, registry, inner_type)
                    wasm_vt = ConcreteRef(info.wasm_type_idx, true)  # nullable
                elseif inner_type <: AbstractVector && inner_type isa DataType
                    # Non-Array AbstractVector (BitVector, etc.) — register as struct
                    info_av = register_struct_type!(mod, registry, inner_type)
                    if info_av !== nothing
                        wasm_vt = ConcreteRef(info_av.wasm_type_idx, true)  # nullable
                    else
                        wasm_vt = ExternRef
                    end
                elseif inner_type <: AbstractVector
                    # Union{Nothing, generic AbstractVector} - use raw array
                    elem_type = eltype(inner_type)
                    # For non-recursive types, register the element type first
                    if !haskey(_registering_types, elem_type) && isconcretetype(elem_type) && isstructtype(elem_type)
                        register_struct_type!(mod, registry, elem_type)
                    end
                    # get_array_type! handles self-referential types
                    array_type_idx = get_array_type!(mod, registry, elem_type)
                    wasm_vt = ConcreteRef(array_type_idx, true)  # nullable
                elseif inner_type === String || inner_type === Symbol
                    # Union{Nothing, String/Symbol} — nullable string array ref
                    str_type_idx = get_string_array_type!(mod, registry)
                    wasm_vt = ConcreteRef(str_type_idx, true)
                elseif isconcretetype(inner_type) && isstructtype(inner_type)
                    # Union{Nothing, SomeStruct} - nullable struct ref
                    if haskey(_registering_types, inner_type)
                        reserved_idx = _registering_types[inner_type]
                        if reserved_idx >= 0
                            wasm_vt = ConcreteRef(UInt32(reserved_idx), true)  # nullable
                        else
                            wasm_vt = StructRef  # Not a self-referential type being registered
                        end
                    else
                        register_struct_type!(mod, registry, inner_type)
                        info = registry.structs[inner_type]
                        wasm_vt = ConcreteRef(info.wasm_type_idx, true)  # nullable
                    end
                else
                    wasm_vt = julia_to_wasm_type(ft)
                end
            elseif needs_tagged_union(ft)
                # Multi-variant union - use tagged union struct
                union_info = register_union_type!(mod, registry, ft)
                wasm_vt = ConcreteRef(union_info.wasm_type_idx, true)
            else
                wasm_vt = julia_to_wasm_type(ft)
            end
        elseif isconcretetype(ft) && isstructtype(ft)
            # Nested struct type - recursively register it
            if haskey(_registering_types, ft)
                reserved_idx = _registering_types[ft]
                if reserved_idx >= 0
                    wasm_vt = ConcreteRef(UInt32(reserved_idx), true)
                else
                    wasm_vt = StructRef  # Non-self-referential type being registered
                end
            else
                nested_info = register_struct_type!(mod, registry, ft)
                if nested_info !== nothing
                    wasm_vt = ConcreteRef(nested_info.wasm_type_idx, true)
                else
                    wasm_vt = StructRef  # Forward reference
                end
            end
        elseif ft isa UnionAll && isstructtype(ft)
            # Parametric struct type without concrete parameters (e.g., SyntaxGraph)
            # Use AnyRef since we can't know the specific type parameter at compile time
            wasm_vt = AnyRef
        else
            wasm_vt = julia_to_wasm_type(ft)
        end
        push!(wasm_fields, FieldType(wasm_vt, true))  # mutable by default
    end

    # Add struct type to module
    type_idx = add_struct_type!(mod, wasm_fields)

    # Record mapping
    info = StructInfo(T, type_idx, field_names, field_types)
    registry.structs[T] = info

    return info
end

"""
Register a Julia tuple type in the Wasm module.
Tuples are represented as WasmGC structs with numbered fields.
"""
function register_tuple_type!(mod::WasmModule, registry::TypeRegistry, T::Type{<:Tuple})
    # Already registered?
    haskey(registry.structs, T) && return registry.structs[T]

    # PURE-6026: Union of Tuples (e.g., Union{Tuple{Vararg{Int64}}, Tuple{Vararg{Symbol}}})
    # passes `T <: Tuple` but doesn't have `.parameters`. Return nothing so the caller
    # falls through to the StructRef fallback.
    if T isa Union
        return nothing
    end

    # PURE-8001: UnionAll tuples (e.g., Tuple{T,T} where T<:Type) don't have
    # .parameters — only DataType does. Return nothing for non-concrete tuples.
    if T isa UnionAll
        return nothing
    end

    # Get element types
    elem_types = T.parameters

    # Create WasmGC field types
    wasm_fields = FieldType[]
    field_names = Symbol[]
    field_types_vec = DataType[]

    for (i, ft) in enumerate(elem_types)
        # Skip Vararg types (used in variadic tuples like Tuple{Int, Vararg{Any}})
        # Note: Vararg is NOT a Type, so we check typeof instead of isa
        if typeof(ft) == Core.TypeofVararg
            # Vararg can't be represented as a fixed struct field - skip
            continue
        end

        # Use concrete types for fields that need specific WASM types
        # This ensures consistency between struct field types and local variable types
        wasm_vt = if ft === String || ft === Symbol
            # String/Symbol fields need concrete string array type (array<i32>)
            type_idx = get_string_array_type!(mod, registry)
            ConcreteRef(type_idx, true)
        elseif ft isa Type && ft <: Array
            # Vector/Array fields are wrapper structs with (data, size) layout
            # Use register_vector_type! to match how get_concrete_wasm_type maps Arrays
            info = register_vector_type!(mod, registry, ft)
            ConcreteRef(info.wasm_type_idx, true)
        elseif ft isa DataType && (ft.name.name === :MemoryRef || ft.name.name === :GenericMemoryRef)
            # MemoryRef{T} / GenericMemoryRef maps to array type for element T
            elem_type = ft.name.name === :GenericMemoryRef ? ft.parameters[2] : ft.parameters[1]
            type_idx = get_array_type!(mod, registry, elem_type)
            ConcreteRef(type_idx, true)
        elseif ft isa DataType && (ft.name.name === :Memory || ft.name.name === :GenericMemory)
            # Memory{T} / GenericMemory maps to array type for element T
            elem_type = eltype(ft)
            type_idx = get_array_type!(mod, registry, elem_type)
            ConcreteRef(type_idx, true)
        elseif isconcretetype(ft) && isstructtype(ft) && !(ft <: Tuple)
            # Nested struct - register and use concrete ref
            nested_info = register_struct_type!(mod, registry, ft)
            if nested_info !== nothing
                ConcreteRef(nested_info.wasm_type_idx, true)
            else
                julia_to_wasm_type(ft)
            end
        else
            # For primitives and other types, use generic mapping
            julia_to_wasm_type(ft)
        end
        push!(wasm_fields, FieldType(wasm_vt, false))  # Tuples are immutable
        push!(field_names, Symbol(i))  # Use numeric names
        push!(field_types_vec, ft isa DataType ? ft : Any)
    end

    # Add struct type to module
    type_idx = add_struct_type!(mod, wasm_fields)

    # Record mapping (use T as DataType)
    info = StructInfo(T, type_idx, field_names, field_types_vec)
    registry.structs[T] = info

    return info
end

"""
Register a multi-dimensional array type (Matrix, Array{T,3}, etc.) as a WasmGC struct.

Multi-dim arrays are stored as WasmGC structs with two fields:
- Field 0: data (reference to flat WasmGC array of element type)
- Field 1: size (tuple of dimensions)

This matches Julia's internal representation where Matrix{T} has :ref and :size fields.
"""
function register_matrix_type!(mod::WasmModule, registry::TypeRegistry, T::Type)
    # Already registered?
    haskey(registry.structs, T) && return registry.structs[T]

    # Guard against Union{} (bottom type) - can't create a matrix of it
    if T === Union{}
        error("Cannot register matrix type for Union{} (bottom type)")
    end

    # Get element type and dimensionality
    elem_type = eltype(T)
    N = ndims(T)

    # Create size tuple type
    size_tuple_type = NTuple{N, Int64}
    if !haskey(registry.structs, size_tuple_type)
        register_tuple_type!(mod, registry, size_tuple_type)
    end
    size_struct_info = registry.structs[size_tuple_type]

    # Create/get the data array type
    data_array_idx = get_array_type!(mod, registry, elem_type)

    # Create WasmGC struct with two fields:
    # - Field 0: ref (nullable reference to data array)
    # - Field 1: size (nullable reference to size tuple struct)
    wasm_fields = [
        FieldType(ConcreteRef(data_array_idx, true), true),  # data array, mutable
        FieldType(ConcreteRef(size_struct_info.wasm_type_idx, true), false)  # size, immutable
    ]

    # Add struct type to module
    type_idx = add_struct_type!(mod, wasm_fields)

    # Record mapping with field info
    field_names = [:ref, :size]  # Julia field names
    field_types_vec = DataType[Array{elem_type, 1}, size_tuple_type]  # Use Vector for ref field type

    info = StructInfo(T, type_idx, field_names, field_types_vec)
    registry.structs[T] = info

    return info
end

"""
Register a Vector{T} type as a WasmGC struct with mutable size.

Vectors are stored as WasmGC structs with two fields:
- Field 0: ref (reference to WasmGC array of element type)
- Field 1: size (mutable Tuple{Int64} tracking logical size)

This matches Julia's internal representation where Vector{T} has :ref and :size fields.
The size field is mutable to support setfield!(v, :size, (n,)) for push!/resize! operations.
"""
function register_vector_type!(mod::WasmModule, registry::TypeRegistry, T::Type)
    # Already registered?
    haskey(registry.structs, T) && return registry.structs[T]

    # Guard against Union{} (bottom type) - can't create a vector of it
    if T === Union{}
        error("Cannot register vector type for Union{} (bottom type)")
    end


    # Get element type
    elem_type = eltype(T)

    # Create size tuple type (Tuple{Int64} for 1D)
    size_tuple_type = Tuple{Int64}
    if !haskey(registry.structs, size_tuple_type)
        register_tuple_type!(mod, registry, size_tuple_type)
    end
    size_struct_info = registry.structs[size_tuple_type]

    # Create/get the data array type
    data_array_idx = get_array_type!(mod, registry, elem_type)

    # Create WasmGC struct with two fields:
    # - Field 0: ref (reference to data array)
    # - Field 1: size (MUTABLE reference to size tuple struct)
    wasm_fields = [
        FieldType(ConcreteRef(data_array_idx, true), true),  # data array, mutable
        FieldType(ConcreteRef(size_struct_info.wasm_type_idx, true), true)  # size, MUTABLE for setfield!
    ]

    # Add struct type to module
    type_idx = add_struct_type!(mod, wasm_fields)

    # Record mapping with field info
    field_names = [:ref, :size]  # Julia field names
    field_types_vec = DataType[Array{elem_type, 1}, size_tuple_type]

    info = StructInfo(T, type_idx, field_names, field_types_vec)
    registry.structs[T] = info

    return info
end

"""
Register a 128-bit integer type (Int128 or UInt128) as a WasmGC struct.

128-bit integers are stored as WasmGC structs with two i64 fields:
- Field 0: lo (low 64 bits)
- Field 1: hi (high 64 bits)

This is the standard representation used by most WASM compilers for 128-bit integers.
"""
function register_int128_type!(mod::WasmModule, registry::TypeRegistry, T::Type)
    # Already registered?
    haskey(registry.structs, T) && return registry.structs[T]

    # Create WasmGC struct with two i64 fields (lo, hi)
    wasm_fields = [
        FieldType(I64, true),   # lo (low 64 bits), mutable for potential in-place ops
        FieldType(I64, true)    # hi (high 64 bits)
    ]

    # Add struct type to module
    type_idx = add_struct_type!(mod, wasm_fields)

    # Record mapping with field info
    field_names = [:lo, :hi]
    field_types_vec = DataType[UInt64, UInt64]  # Both fields are 64-bit

    info = StructInfo(T, type_idx, field_names, field_types_vec)
    registry.structs[T] = info

    return info
end

"""
Get or create the 128-bit integer struct type.
"""
function get_int128_type!(mod::WasmModule, registry::TypeRegistry, T::Type)
    if haskey(registry.structs, T)
        return registry.structs[T].wasm_type_idx
    else
        info = register_int128_type!(mod, registry, T)
        return info.wasm_type_idx
    end
end

