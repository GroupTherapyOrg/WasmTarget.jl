# type_data_store.jl — Pre-extracted type metadata for WasmGC
#
# DataType, TypeName, TypeVar, UnionAll, Union are C structs in native Julia.
# They can't be compiled to WasmGC via getfield. Instead, we pre-extract
# all fields that typeinf reads at build time and store them in flat records
# keyed by TypeID.
#
# Phase 2A-007: Handle DataType/TypeName WasmGC representation for typeinf.
#
# Usage:
#   store = build_type_data_store(registry::TypeIDRegistry)
#   td = get_type_data(store, type_id)
#   td.tag          # TYPE_TAG_DATATYPE, TYPE_TAG_UNION, etc.
#   td.n_parameters # number of type parameters (DataType)
#   td.parameter_ids # TypeIDs of parameters

# ─── Type Tags ────────────────────────────────────────────────────────────────

const TYPE_TAG_DATATYPE  = Int32(0)  # DataType (includes Tuple types)
const TYPE_TAG_UNION     = Int32(1)  # Union{A, B}
const TYPE_TAG_UNIONALL  = Int32(2)  # UnionAll (e.g., Vector{T} where T)
const TYPE_TAG_TYPEVAR   = Int32(3)  # TypeVar (e.g., T in where T)
const TYPE_TAG_VARARG    = Int32(4)  # Core.TypeofVararg
const TYPE_TAG_BOTTOM    = Int32(5)  # Union{} (Bottom type)
const TYPE_TAG_OTHER     = Int32(6)  # Unrecognized / opaque

# ─── TypeData ─────────────────────────────────────────────────────────────────
# Flat record holding pre-extracted type metadata for a single type.
# Uses TypeIDs instead of Type objects for all cross-references.

struct TypeData
    tag::Int32                    # TYPE_TAG_* discriminator
    type_id::Int32                # This type's own TypeID

    # ── DataType fields (tag == TYPE_TAG_DATATYPE) ──
    name_hash::UInt32             # Hash of TypeName for identity comparison
    name_str::String              # TypeName as string (for debug/display)
    n_parameters::Int32           # length(T.parameters)
    parameter_ids::Vector{Int32}  # TypeIDs of T.parameters[i]
    super_id::Int32               # TypeID of T.super (-1 if not in registry)
    n_fields::Int32               # fieldcount(T)
    field_type_ids::Vector{Int32} # TypeIDs of fieldtype(T, i)
    is_abstract::Int32            # isabstracttype(T) ? 1 : 0
    is_mutable::Int32             # ismutabletype(T) ? 1 : 0
    wrapper_id::Int32             # TypeID of T.name.wrapper (-1 if N/A)

    # ── UnionAll fields (tag == TYPE_TAG_UNIONALL) ──
    ua_var_lb_id::Int32           # TypeID of T.var.lb
    ua_var_ub_id::Int32           # TypeID of T.var.ub
    ua_body_id::Int32             # TypeID of T.body

    # ── Union fields (tag == TYPE_TAG_UNION) ──
    union_a_id::Int32             # TypeID of T.a
    union_b_id::Int32             # TypeID of T.b

    # ── Vararg fields (tag == TYPE_TAG_VARARG) ──
    vararg_t_id::Int32            # TypeID of T.T (element type)
    vararg_n_id::Int32            # TypeID of T.N (-1 if unbounded)
end

# Default constructor for a given tag
function TypeData(tag::Int32, type_id::Int32)
    TypeData(
        tag, type_id,
        UInt32(0), "",                 # name_hash, name_str
        Int32(0), Int32[],             # n_parameters, parameter_ids
        Int32(-1),                     # super_id
        Int32(0), Int32[],             # n_fields, field_type_ids
        Int32(0), Int32(0),            # is_abstract, is_mutable
        Int32(-1),                     # wrapper_id
        Int32(-1), Int32(-1), Int32(-1), # ua_var_lb_id, ua_var_ub_id, ua_body_id
        Int32(-1), Int32(-1),          # union_a_id, union_b_id
        Int32(-1), Int32(-1),          # vararg_t_id, vararg_n_id
    )
end

# ─── TypeDataStore ────────────────────────────────────────────────────────────

struct TypeDataStore
    data::Vector{TypeData}       # Indexed by TypeID + 1 (0-based IDs)
    registry::TypeIDRegistry     # Reference to the TypeID registry
end

"""
    get_type_data(store, type_id) → TypeData

Look up pre-extracted type metadata by TypeID.
"""
function get_type_data(store::TypeDataStore, type_id::Int32)
    idx = type_id + 1  # 0-based → 1-based
    if idx < 1 || idx > length(store.data)
        error("TypeID $type_id out of range (store has $(length(store.data)) entries)")
    end
    return store.data[idx]
end

# ─── Build Functions ──────────────────────────────────────────────────────────

"""
    safe_get_type_id(registry, t) → Int32

Get TypeID for a type, assigning a new one if not present.
Returns -1 only for truly unrepresentable types.
"""
function safe_get_type_id(registry, @nospecialize(t))
    id = get_type_id(registry, t)
    if id < 0
        # Type not in registry — assign it
        id = assign_type!(registry, t)
    end
    return id
end

"""
    extract_type_data(registry, t, type_id) → TypeData

Pre-extract metadata for a single type.
"""
function extract_type_data(registry, @nospecialize(t), type_id::Int32)
    if t === Union{}
        return TypeData(TYPE_TAG_BOTTOM, type_id)
    elseif t isa DataType
        return _extract_datatype(registry, t, type_id)
    elseif t isa Union
        return _extract_union(registry, t, type_id)
    elseif t isa UnionAll
        return _extract_unionall(registry, t, type_id)
    elseif t isa TypeVar
        return _extract_typevar(registry, t, type_id)
    elseif t isa Core.TypeofVararg
        return _extract_vararg(registry, t, type_id)
    else
        return TypeData(TYPE_TAG_OTHER, type_id)
    end
end

function _extract_datatype(registry, t::DataType, type_id::Int32)
    tn = t.name
    name_str = string(tn.name)
    name_hash = hash(tn) % UInt32

    # Parameters
    params = t.parameters
    n_params = Int32(length(params))
    param_ids = Int32[safe_get_type_id(registry, p) for p in params]

    # Supertype
    sup = t.super
    super_id = (sup === t) ? Int32(-1) : safe_get_type_id(registry, sup)

    # Field types — only for concrete structs
    n_flds = Int32(0)
    fld_ids = Int32[]
    try
        ftypes = t.types
        if ftypes !== nothing
            n_flds = Int32(length(ftypes))
            fld_ids = Int32[]
            for i in 1:length(ftypes)
                ft = ftypes[i]
                push!(fld_ids, safe_get_type_id(registry, ft))
            end
        end
    catch
        # Some types don't support .types access
    end

    # Flags
    is_abs = Int32(isabstracttype(t) ? 1 : 0)
    is_mut = Int32(ismutabletype(t) ? 1 : 0)

    # Wrapper
    wrapper_id = safe_get_type_id(registry, tn.wrapper)

    TypeData(
        TYPE_TAG_DATATYPE, type_id,
        name_hash, name_str,
        n_params, param_ids,
        super_id,
        n_flds, fld_ids,
        is_abs, is_mut,
        wrapper_id,
        Int32(-1), Int32(-1), Int32(-1),  # ua fields
        Int32(-1), Int32(-1),              # union fields
        Int32(-1), Int32(-1),              # vararg fields
    )
end

function _extract_union(registry, t::Union, type_id::Int32)
    a_id = safe_get_type_id(registry, t.a)
    b_id = safe_get_type_id(registry, t.b)

    TypeData(
        TYPE_TAG_UNION, type_id,
        UInt32(0), "",
        Int32(0), Int32[],
        Int32(-1),
        Int32(0), Int32[],
        Int32(0), Int32(0),
        Int32(-1),
        Int32(-1), Int32(-1), Int32(-1),
        a_id, b_id,
        Int32(-1), Int32(-1),
    )
end

function _extract_unionall(registry, t::UnionAll, type_id::Int32)
    var = t.var
    lb_id = safe_get_type_id(registry, var.lb)
    ub_id = safe_get_type_id(registry, var.ub)
    body_id = safe_get_type_id(registry, t.body)

    TypeData(
        TYPE_TAG_UNIONALL, type_id,
        UInt32(0), "",
        Int32(0), Int32[],
        Int32(-1),
        Int32(0), Int32[],
        Int32(0), Int32(0),
        Int32(-1),
        lb_id, ub_id, body_id,
        Int32(-1), Int32(-1),
        Int32(-1), Int32(-1),
    )
end

function _extract_typevar(registry, t::TypeVar, type_id::Int32)
    lb_id = safe_get_type_id(registry, t.lb)
    ub_id = safe_get_type_id(registry, t.ub)

    TypeData(
        TYPE_TAG_TYPEVAR, type_id,
        UInt32(0), string(t.name),
        Int32(0), Int32[],
        Int32(-1),
        Int32(0), Int32[],
        Int32(0), Int32(0),
        Int32(-1),
        lb_id, ub_id, Int32(-1),
        Int32(-1), Int32(-1),
        Int32(-1), Int32(-1),
    )
end

function _extract_vararg(registry, t::Core.TypeofVararg, type_id::Int32)
    t_id = safe_get_type_id(registry, t.T)
    n_id = isdefined(t, :N) ? safe_get_type_id(registry, t.N) : Int32(-1)

    TypeData(
        TYPE_TAG_VARARG, type_id,
        UInt32(0), "",
        Int32(0), Int32[],
        Int32(-1),
        Int32(0), Int32[],
        Int32(0), Int32(0),
        Int32(-1),
        Int32(-1), Int32(-1), Int32(-1),
        Int32(-1), Int32(-1),
        t_id, n_id,
    )
end

# ─── Build Store ──────────────────────────────────────────────────────────────

"""
    build_type_data_store(registry::TypeIDRegistry) → TypeDataStore

Build a complete TypeDataStore from a TypeIDRegistry.
Pre-extracts metadata for EVERY type in the registry.
"""
function build_type_data_store(registry::TypeIDRegistry)
    n = length(registry.id_to_type)
    data = Vector{TypeData}(undef, n)

    for i in 1:n
        type_id = Int32(i - 1)
        t = registry.id_to_type[i]
        data[i] = extract_type_data(registry, t, type_id)
    end

    return TypeDataStore(data, registry)
end

# ─── Verification ─────────────────────────────────────────────────────────────

"""
    verify_type_data(td::TypeData, t, registry) → (ok::Bool, errors::Vector{String})

Verify that pre-extracted TypeData matches the native type's fields.
"""
function verify_type_data(td::TypeData, @nospecialize(t), registry)
    errors = String[]

    if t === Union{}
        td.tag != TYPE_TAG_BOTTOM && push!(errors, "tag: expected BOTTOM, got $(td.tag)")
    elseif t isa DataType
        td.tag != TYPE_TAG_DATATYPE && push!(errors, "tag: expected DATATYPE, got $(td.tag)")
        if td.tag == TYPE_TAG_DATATYPE
            # Check parameters
            params = t.parameters
            td.n_parameters != Int32(length(params)) && push!(errors, "n_parameters: expected $(length(params)), got $(td.n_parameters)")
            for (i, p) in enumerate(params)
                if i <= length(td.parameter_ids)
                    expected_id = safe_get_type_id(registry, p)
                    td.parameter_ids[i] != expected_id && push!(errors, "parameter[$i]: expected id=$expected_id, got $(td.parameter_ids[i])")
                end
            end
            # Check abstract/mutable flags
            td.is_abstract != Int32(isabstracttype(t) ? 1 : 0) && push!(errors, "is_abstract mismatch")
            td.is_mutable != Int32(ismutabletype(t) ? 1 : 0) && push!(errors, "is_mutable mismatch")
            # Check supertype
            sup = t.super
            if sup !== t
                expected_super = safe_get_type_id(registry, sup)
                td.super_id != expected_super && push!(errors, "super_id: expected $expected_super, got $(td.super_id)")
            end
            # Check name
            expected_name = string(t.name.name)
            td.name_str != expected_name && push!(errors, "name_str: expected '$expected_name', got '$(td.name_str)'")
        end
    elseif t isa Union
        td.tag != TYPE_TAG_UNION && push!(errors, "tag: expected UNION, got $(td.tag)")
        if td.tag == TYPE_TAG_UNION
            expected_a = safe_get_type_id(registry, t.a)
            expected_b = safe_get_type_id(registry, t.b)
            td.union_a_id != expected_a && push!(errors, "union_a: expected $expected_a, got $(td.union_a_id)")
            td.union_b_id != expected_b && push!(errors, "union_b: expected $expected_b, got $(td.union_b_id)")
        end
    elseif t isa UnionAll
        td.tag != TYPE_TAG_UNIONALL && push!(errors, "tag: expected UNIONALL, got $(td.tag)")
        if td.tag == TYPE_TAG_UNIONALL
            expected_lb = safe_get_type_id(registry, t.var.lb)
            expected_ub = safe_get_type_id(registry, t.var.ub)
            expected_body = safe_get_type_id(registry, t.body)
            td.ua_var_lb_id != expected_lb && push!(errors, "var.lb: expected $expected_lb, got $(td.ua_var_lb_id)")
            td.ua_var_ub_id != expected_ub && push!(errors, "var.ub: expected $expected_ub, got $(td.ua_var_ub_id)")
            td.ua_body_id != expected_body && push!(errors, "body: expected $expected_body, got $(td.ua_body_id)")
        end
    elseif t isa TypeVar
        td.tag != TYPE_TAG_TYPEVAR && push!(errors, "tag: expected TYPEVAR, got $(td.tag)")
    elseif t isa Core.TypeofVararg
        td.tag != TYPE_TAG_VARARG && push!(errors, "tag: expected VARARG, got $(td.tag)")
    end

    return (ok=isempty(errors), errors=errors)
end

"""
    verify_store(store::TypeDataStore) → (n_ok, n_fail, failures)

Verify ALL entries in the store against their native types.
"""
function verify_store(store::TypeDataStore)
    n_ok = 0
    n_fail = 0
    failures = String[]

    for i in 1:length(store.data)
        td = store.data[i]
        t = store.registry.id_to_type[i]
        ok, errs = verify_type_data(td, t, store.registry)
        if ok
            n_ok += 1
        else
            n_fail += 1
            push!(failures, "TypeID=$(i-1) ($(typeof(t))): $(join(errs, "; "))")
        end
    end

    return (n_ok=n_ok, n_fail=n_fail, failures=failures)
end

# ─── Statistics ───────────────────────────────────────────────────────────────

function store_stats(store::TypeDataStore)
    tags = Dict{Int32, Int}()
    for td in store.data
        tags[td.tag] = get(tags, td.tag, 0) + 1
    end
    tag_names = Dict(
        TYPE_TAG_DATATYPE => "DataType",
        TYPE_TAG_UNION => "Union",
        TYPE_TAG_UNIONALL => "UnionAll",
        TYPE_TAG_TYPEVAR => "TypeVar",
        TYPE_TAG_VARARG => "Vararg",
        TYPE_TAG_BOTTOM => "Bottom",
        TYPE_TAG_OTHER => "Other",
    )
    return (
        total = length(store.data),
        by_tag = Dict(get(tag_names, k, "?") => v for (k, v) in tags),
    )
end
