# A Symbol a program makes at run time is interned in the module's symbol table (julia/src/symbol.c:78
# _jl_symbol), which every symbol constant is interned in too (julia/src/staticdata.c:2044 jl_read_symbols):
# one name is one object, its stored hash Julia's (mk_symbol, hash_symbol), and a name holding a NUL is
# jl_symbol_n's ArgumentError.
_g("symbol_class", Any[
    # hash and objectid of a run-time Symbol, Julia's bits: the hash mk_symbol stored (jl_object_id_'s Symbol arm)
    ("intern_hash_bits", (x::Int64) -> reinterpret(Int64, hash(Symbol(string('a', Char(x))))), Int64(98)),
    ("intern_objectid_bits", (x::Int64) -> reinterpret(Int64, objectid(Symbol(string('q', Char(x))))), Int64(98)),
    ("intern_objectid_constant_bits", (x::Int64) -> reinterpret(Int64, objectid(x > 0 ? :qb : :zz)), Int64(1)),
    # two run-time Symbols of one name are one object, and the constant of that name
    ("intern_twice_egal", (x::Int64) -> (s1 = Symbol(string('z', Char(x))); s2 = Symbol(string('z', Char(x)));
                                         Int64(s1 === s2) + 2 * Int64(s1 === :zb) + 4 * Int64(s1 === :zc)), Int64(98)),
    # many names in the table's tree: each found again, and the constant among them
    ("intern_many_names", (n::Int64) -> (c = 0; for k in 1:n; c += Int64(Symbol(string("s", k)) === Symbol(string("s", k))); end;
                                         c + 100 * Int64(Symbol(string("s", 7)) === :s7) + 1000 * Int64(Symbol(string("s", 8)) === :s7)), Int64(40)),
    # a name holding a NUL: jl_symbol_n's ArgumentError, its message Julia's
    ("intern_nul_argument_error", (x::Int64) -> (try; Symbol(string('a', Char(x))); 1; catch e;
                                                 e isa ArgumentError && (e.msg::String) == "Symbol name may not contain \\0" ? 2 : 3; end), Int64(0)),
])
