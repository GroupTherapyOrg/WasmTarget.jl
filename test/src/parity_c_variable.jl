# The C anchor reader (src/julia/parity.jl _cpp_declares) reads a file-scope variable declared at column 0 as the
# declaration of its name, as it reads a function or a table of C data: its specifiers, then the name, initialized or
# not (julia/src/symbol.c:19 `static _Atomic(jl_sym_t*) symtab = NULL;`, which src/julia/runtime/rtutils.jl's
# symbol table pins). A use of the name, another name it prefixes, a local declaration and a statement are none.
module ParityCVariableTest
using Test, WasmTarget
const W = WasmTarget

const C = """
    uv_mutex_t symtab_lock;
    static _Atomic(jl_sym_t*) symtab = NULL;
    static jl_value_t *const root;
    static jl_sym_t *first = symtab;
        jl_sym_t *node = symtab;
    symtab = NULL;
    return symtab;
    static jl_sym_t *symtab_lookup(_Atomic(jl_sym_t*) *ptree, const char *str, size_t len)
    int seen = symtab == NULL;
    // static _Atomic(jl_sym_t*) symtab = NULL;
    p->symtab = NULL;
    """
const LINES = split(chomp(C), '\n'; keepempty = true) .|> String
declares(ln, x) = W._cpp_declares(LINES, ln, x) === nothing

@testset "a C file-scope variable is the declaration of its name" begin
    @test declares(1, "symtab_lock")      # uninitialized
    @test declares(2, "symtab")           # _Atomic(T), initialized
    @test declares(3, "root")             # a pointer's `*` and a qualifier before the name
    @test declares(4, "first")
    @test declares(8, "symtab_lookup")    # the function form is unchanged
end

@testset "a use, a prefix, a local, a statement or a comment declares no variable" begin
    @test !declares(1, "symtab")          # a name the declared one begins with
    @test !declares(2, "symtab_lock")     # another variable's line
    @test !declares(4, "symtab")          # a use in another's initializer
    @test !declares(5, "symtab")          # a local, at column 4
    @test !declares(5, "node")
    @test !declares(6, "symtab")          # an assignment, no specifiers
    @test !declares(7, "symtab")          # a return
    @test !declares(8, "symtab")          # a function whose name it prefixes
    @test !declares(8, "ptree")           # a parameter
    @test !declares(9, "symtab")          # a comparison in an initializer
    @test !declares(10, "symtab")         # a comment
    @test !declares(11, "symtab")         # a member through a pointer
    @test !declares(40, "symtab")         # past the file's end
end

# the pin's own line at the julia checkout, where the checkout is there (the load resolves every pin against it)
const SYMBOL_C = joinpath(homedir(), ".cache", "wasmtarget", "julia", "src", "symbol.c")
isfile(SYMBOL_C) && @testset "julia/src/symbol.c:19 declares symtab" begin
    local lines = readlines(SYMBOL_C)
    @test W._cpp_declares(lines, 19, "symtab") === nothing
    @test W._cpp_declares(lines, 18, "symtab") !== nothing
    @test W._cpp_declares(lines, 51, "symtab") !== nothing
end
end
