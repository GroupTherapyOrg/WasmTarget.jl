# ============================================================================
# Package Loading — Pre-compile curated Julia package functions to Wasm
# Per spec §7.7: packages must be pre-compiled at build time
# ============================================================================

"""
    PackageSpec

Specification for a pre-compilable Julia package.
Contains the functions that should be compiled to Wasm.
"""
struct PackageSpec
    name::Symbol
    functions::Vector{Tuple{Any, Tuple}}  # (func, arg_types)
end

"""
    CURATED_PACKAGES

Registry of curated packages available for playground compilation.
Each package maps to a list of (function, arg_types) entries.
Only pure Julia packages (no ccall/foreigncall deps) are eligible.
"""
const CURATED_PACKAGES = Dict{Symbol, Vector{Tuple{Any, Tuple}}}()

"""
    register_package!(name::Symbol, functions::Vector)

Register a package's functions for pre-compilation.
Each entry is (function, arg_types) or (function, arg_types, export_name).
"""
function register_package!(name::Symbol, functions::Vector)
    entries = Tuple{Any, Tuple}[]
    for entry in functions
        if length(entry) == 2
            push!(entries, (entry[1], entry[2]))
        elseif length(entry) >= 3
            push!(entries, (entry[1], entry[2]))  # name handled separately
        end
    end
    CURATED_PACKAGES[name] = entries
    return entries
end

"""
    list_packages() -> Vector{Symbol}

List all registered curated packages.
"""
list_packages() = collect(keys(CURATED_PACKAGES))

"""
    package_functions(name::Symbol) -> Vector{Tuple{Any, Tuple}}

Get the registered functions for a package.
"""
function package_functions(name::Symbol)
    return get(CURATED_PACKAGES, name, Tuple{Any, Tuple}[])
end

"""
    precompile_package(name::Symbol; optimize=false) -> Vector{UInt8}

Pre-compile all registered functions from a package to a single Wasm module.
Returns the compiled Wasm bytes.
"""
function precompile_package(name::Symbol; optimize=false)
    funcs = package_functions(name)
    isempty(funcs) && error("Package :$name not registered. Use register_package! first.")

    entries = []
    for (f, arg_types) in funcs
        fname = string(name, "_", nameof(f))
        push!(entries, (f, arg_types, fname))
    end

    return compile_multi(entries; optimize=optimize)
end

"""
    compile_with_packages(user_functions::Vector, packages::Vector{Symbol}; optimize=false)
        -> Vector{UInt8}

Compile user functions alongside pre-registered package functions in a single module.
Package functions are included alongside user functions so cross-calls resolve correctly.
"""
function compile_with_packages(user_functions::Vector, packages::Vector{Symbol};
                                optimize=false)
    all_functions = []

    # Add package functions
    for pkg_name in packages
        funcs = package_functions(pkg_name)
        if isempty(funcs)
            @warn "Package :$pkg_name not registered, skipping"
            continue
        end
        for (f, arg_types) in funcs
            fname = string(pkg_name, "_", nameof(f))
            push!(all_functions, (f, arg_types, fname))
        end
    end

    # Add user functions
    for entry in user_functions
        push!(all_functions, entry)
    end

    return compile_multi(all_functions; optimize=optimize)
end

"""
    detect_using_statements(code::String) -> Vector{Symbol}

Scan Julia source code for `using` statements and return package names.
"""
function detect_using_statements(code::String)
    packages = Symbol[]
    for m in eachmatch(r"using\s+(\w+)", code)
        pkg = Symbol(m.captures[1])
        if pkg in keys(CURATED_PACKAGES)
            push!(packages, pkg)
        end
    end
    return unique(packages)
end

# ============================================================================
# Built-in Package Registrations
# ============================================================================

"""
    register_builtin_packages!()

Register all built-in curated packages. Call during server startup.
"""
function register_builtin_packages!()
    registered = Symbol[]

    if register_statistics_package!()
        push!(registered, :Statistics)
    end

    return registered
end

"""
    is_package_feasible(pkg_name::Symbol) -> Bool

Check if a package is feasible for Wasm compilation by scanning for ccall/foreigncall.
A package is feasible if it (and all transitive deps) contain zero ccall to non-Julia libraries.
"""
function is_package_feasible(pkg_name::Symbol)
    try
        mod = Base.require(Base.PkgId(pkg_name))
        # Simple heuristic: check if any method uses foreigncall
        for name in names(mod; all=false)
            try
                f = getfield(mod, name)
                if f isa Function
                    for m in methods(f)
                        src = Base.uncompressed_ir(m)
                        for stmt in src.code
                            if stmt isa Expr && stmt.head === :foreigncall
                                return false
                            end
                        end
                    end
                end
            catch
                continue
            end
        end
        return true
    catch
        return false
    end
end
