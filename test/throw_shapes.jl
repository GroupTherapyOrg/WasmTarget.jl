# The throw readers' shapes (spec v20 F1), a judge file (dev/climb/core.py JUDGE_READ): what a judge-built reader
# (test/verdict.jl Catches, IsA) reads, its own type T and what F does, and the values a miscompiled F could throw.
# One list for both of the readers' negatives: test/src/verdict.jl runs each reader's own IR with F's call replaced,
# test/src/runner.jl runs WasmTarget's module of each with the thrown object's class rewritten.
_f1_div(x::Int64) = throw(DivideError())                # always throws a singleton type
_f1_dom(x::Int64) = throw(DomainError(x))               # always throws a type with fields
_f1_arg(x::Int64) = throw(ArgumentError("always"))
_f1_err(x::Int64) = error("always")                     # an ErrorException, by error(...)
_f1_idiv(x::Int64) = div(Int64(1), x)                   # sometimes returns
_f1_bnd(x::Int64) = (v = [1, 2]; v[x])
_f1_zero() = throw(ArgumentError("no arguments"))       # zero arguments
_f1_one(x::Int64) = x > 0 ? throw(ArgumentError("+")) : throw(ArgumentError("-"))   # two branches of one type
_f1_two(x::Int64) = x > 0 ? throw(ArgumentError("+")) : throw(DomainError(x))       # two exception types
struct _F1S1 end; struct _F1S2 end
_f1_s2(x::Int64) = x > 0 ? _F1S1() : _F1S2()             # a singleton answer of two types
_f1_s1(x::Int64) = (x > 100 && println(x); _F1S1())      # one singleton type: its result a constant to inference
_f1_wrap(x::Int64) = throw(LoadError("f.jl", x, DivideError()))   # Core.WrappedException, abstract, Base's one below Exception
const _F1_SHAPES = ((_f1_div, DivideError, (Int64(1),)), (_f1_dom, DomainError, (Int64(1),)),
    (_f1_arg, ArgumentError, (Int64(1),)), (_f1_err, ErrorException, (Int64(1),)), (_f1_idiv, DivideError, (Int64(0),)),
    (_f1_bnd, BoundsError, (Int64(3),)), (_f1_zero, ArgumentError, ()), (_f1_one, ArgumentError, (Int64(1),)),
    (_f1_two, ArgumentError, (Int64(1),)), (_f1_two, DomainError, (Int64(-1),)),
    (_f1_wrap, Core.WrappedException, (Int64(1),)), (_f1_idiv, Exception, (Int64(0),)), (_f1_dom, Exception, (Int64(1),)),
    (_f1_two, Exception, (Int64(1),)))
# values a miscompiled F could throw; the first of T's is the right throw (Julia has no ArithmeticError: an abstract T
# is Exception or Core.WrappedException, and the right throw of the latter is another subtype than F's)
const _F1_THROWN = Any[OverflowError("w"), DivideError(), DomainError(0), ArgumentError("w"), ErrorException("w"),
                       KeyError(1), BoundsError(), InitError(:m, DivideError()), Int64(42), "not an exception"]
