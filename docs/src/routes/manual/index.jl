() -> begin
    code_block = "bg-warm-900 dark:bg-warm-950 p-4 rounded text-sm font-mono overflow-x-auto"

    sections = [
        ("types", "Type Mappings"),
        ("math", "Math Functions"),
        ("collections", "Collections"),
        ("structs", "Structs & Tuples"),
        ("control-flow", "Control Flow"),
        ("js-interop", "JS Interop"),
    ]

    table_cls = "w-full text-sm border border-warm-200 dark:border-warm-800 rounded overflow-hidden"
    th_cls = "text-left px-3 py-2 bg-warm-200/50 dark:bg-warm-900/50 font-semibold text-warm-800 dark:text-warm-200"
    td_cls = "px-3 py-2 border-t border-warm-200 dark:border-warm-800 text-warm-700 dark:text-warm-300"
    code_inline = "text-accent-500 font-mono"

    PageWithTOC(sections, Div(:class => "space-y-10",
        H1(:class => "text-3xl font-serif font-bold text-warm-900 dark:text-warm-100", "Manual"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "WasmTarget.jl reads fully-inferred IR from ",
            Code(:class => code_inline, "Base.code_typed()"),
            " and translates each concrete Julia type to its WASM counterpart. ",
            "This page covers type mappings, control flow, the supported math + collections surfaces, and JS interop."),

        # ─────────────────────────── Type Mappings ───────────────────────────
        H2(:id => "types", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Type Mappings"),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Primitive Types"),
        Table(:class => table_cls,
            Thead(Tr(Th(:class => th_cls, "Julia Type"), Th(:class => th_cls, "WASM Type"), Th(:class => th_cls, "Notes"))),
            Tbody(
                Tr(Td(:class => td_cls, Code(:class => code_inline, "Int32"), ", ", Code(:class => code_inline, "UInt32")), Td(:class => td_cls, Code(:class => code_inline, "i32")), Td(:class => td_cls, "32-bit integer")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "Int64"), ", ", Code(:class => code_inline, "UInt64"), ", ", Code(:class => code_inline, "Int")), Td(:class => td_cls, Code(:class => code_inline, "i64")), Td(:class => td_cls, Code(:class => code_inline, "Int"), " is ", Code(:class => code_inline, "Int64"), " on 64-bit")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "Float32")), Td(:class => td_cls, Code(:class => code_inline, "f32")), Td(:class => td_cls, "32-bit float")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "Float64")), Td(:class => td_cls, Code(:class => code_inline, "f64")), Td(:class => td_cls, "64-bit float")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "Bool")), Td(:class => td_cls, Code(:class => code_inline, "i32")), Td(:class => td_cls, "0 or 1"))
            )
        ),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Reference Types"),
        Table(:class => table_cls,
            Thead(Tr(Th(:class => th_cls, "Julia Type"), Th(:class => th_cls, "WASM Type"), Th(:class => th_cls, "Notes"))),
            Tbody(
                Tr(Td(:class => td_cls, Code(:class => code_inline, "String")), Td(:class => td_cls, "WasmGC packed ", Code(:class => code_inline, "(array (mut i8))")), Td(:class => td_cls, "UTF-8 bytes; ", Code(:class => code_inline, "array.get_u"), " widens to i32 on the stack")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "struct Foo … end")), Td(:class => td_cls, "WasmGC ", Code(:class => code_inline, "struct")), Td(:class => td_cls, "Fields map directly")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "Tuple{A, B, …}")), Td(:class => td_cls, "WasmGC ", Code(:class => code_inline, "struct")), Td(:class => td_cls, "Immutable struct")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "Vector{T}")), Td(:class => td_cls, "WasmGC ", Code(:class => code_inline, "struct{array, length}")), Td(:class => td_cls, "Mutable array with length")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "Matrix{T}")), Td(:class => td_cls, "WasmGC ", Code(:class => code_inline, "struct{array, sizes}")), Td(:class => td_cls, "Data array + size tuple")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "JSValue")), Td(:class => td_cls, Code(:class => code_inline, "externref")), Td(:class => td_cls, "Opaque JS object reference"))
            )
        ),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Struct Mapping"),
        P(:class => "text-warm-600 dark:text-warm-400", "Julia structs become WasmGC struct types with fields in declaration order:"),
        Pre(:class => code_block, Code(:class => "language-julia", """struct Point
    x::Float64
    y::Float64
end""")),
        P(:class => "text-warm-600 dark:text-warm-400",
            "Becomes a WasmGC struct type with two ", Code(:class => code_inline, "f64"),
            " fields. Mutable structs (", Code(:class => code_inline, "mutable struct"),
            ") work the same way but allow field mutation via ",
            Code(:class => code_inline, "struct.set"), "."),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Vector Mapping"),
        P(:class => "text-warm-600 dark:text-warm-400",
            Code(:class => code_inline, "Vector{T}"),
            " is represented as a WasmGC struct containing a WasmGC array of the element type and a length field (",
            Code(:class => code_inline, "i32"),
            "). Mirrors Julia's internal representation; allows efficient element access and length queries."),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Strings: packed i8, not i32"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "WASM has no top-level ", Code(:class => code_inline, "i8"),
            " type — stack values are always ", Code(:class => code_inline, "i32 / i64 / f32 / f64"),
            ". The i8 form only exists (a) as a packed array element type and (b) as linear-memory load/store widths. ",
            "WasmTarget stores ", Code(:class => code_inline, "String"), " as ",
            Code(:class => code_inline, "(array (mut i8))"),
            " holding UTF-8 bytes; reads use ", Code(:class => code_inline, "array.get_u"),
            " which zero-extends each byte to ", Code(:class => code_inline, "i32"),
            " on the stack, so arithmetic (e.g. inside ",
            Code(:class => code_inline, "str_char(s, i)::Int32"),
            ") happens at i32 width with no truncation cost."),
        P(:class => "text-warm-600 dark:text-warm-400",
            "An ", Code(:class => code_inline, "(array (mut i16))"),
            " type also appears in compiled modules — it's purely the JS-boundary bridge. ",
            Code(:class => code_inline, "wasm:js-string.fromCharCodeArray"),
            " (Chrome 131+ / Node 23+) takes UTF-16 char codes, so an i8 → i16 widen happens once at the println / format-output boundary. Internal strings stay UTF-8 i8 throughout."),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "JSValue + WasmGlobal"),
        P(:class => "text-warm-600 dark:text-warm-400",
            Code(:class => code_inline, "JSValue"),
            " is a primitive type that maps to WASM ",
            Code(:class => code_inline, "externref"),
            " — an opaque handle to a JavaScript value (DOM element, JS object, function reference). ",
            Code(:class => code_inline, "WasmGlobal{T, IDX}"),
            " is a type-safe handle for WASM global variables; ",
            Code(:class => code_inline, "T"), " sets the value type and ",
            Code(:class => code_inline, "IDX"),
            " is the compile-time global index. See JS Interop below."),

        # ─────────────────────────── Math Functions ───────────────────────────
        H2(:id => "math", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Math Functions"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "All 43 tested math functions compile and produce correct results, verified with both ",
            Code(:class => code_inline, "Float32"), " and ", Code(:class => code_inline, "Float64"),
            " (except ", Code(:class => code_inline, "exp(Float32)"), " — one known codegen issue). ",
            "Julia 1.12 implements math in pure Julia (no ", Code(:class => code_inline, "foreigncall"),
            " to libm), so they compile directly to WASM without runtime dependencies."),

        Table(:class => table_cls,
            Thead(Tr(Th(:class => th_cls, "Category"), Th(:class => th_cls, "Functions"), Th(:class => th_cls, "Path"))),
            Tbody(
                Tr(Td(:class => td_cls, "Trigonometric"), Td(:class => td_cls, Code(:class => code_inline, "sin, cos, tan, asin, acos, atan")), Td(:class => td_cls, "Native")),
                Tr(Td(:class => td_cls, "Hyperbolic"),    Td(:class => td_cls, Code(:class => code_inline, "sinh, cosh, tanh")), Td(:class => td_cls, "Native")),
                Tr(Td(:class => td_cls, "Exponential"),   Td(:class => td_cls, Code(:class => code_inline, "exp, exp2, expm1")), Td(:class => td_cls, "Native")),
                Tr(Td(:class => td_cls, "Logarithmic"),   Td(:class => td_cls, Code(:class => code_inline, "log, log2, log10, log1p")), Td(:class => td_cls, "Native")),
                Tr(Td(:class => td_cls, "Rounding"),      Td(:class => td_cls, Code(:class => code_inline, "floor, ceil, round, trunc")), Td(:class => td_cls, "Native")),
                Tr(Td(:class => td_cls, "Roots/Powers"),  Td(:class => td_cls, Code(:class => code_inline, "sqrt, cbrt, hypot, fourthroot")), Td(:class => td_cls, "Native")),
                Tr(Td(:class => td_cls, "Special"),       Td(:class => td_cls, Code(:class => code_inline, "sincos, sinpi, cospi, tanpi, sinc, cosc, modf")), Td(:class => td_cls, "Native")),
                Tr(Td(:class => td_cls, "Utility"),       Td(:class => td_cls, Code(:class => code_inline, "copysign, deg2rad, rad2deg, ldexp, mod2pi")), Td(:class => td_cls, "Native")),
                Tr(Td(:class => td_cls, "Power"),         Td(:class => td_cls, Code(:class => code_inline, "Float64^Float64, Float64^Int")), Td(:class => td_cls, "Native")),
                Tr(Td(:class => td_cls, "Float mod/rem"), Td(:class => td_cls, Code(:class => code_inline, "mod(Float64), rem(Float64)")), Td(:class => td_cls, "Overlay"))
            )
        ),
        Pre(:class => code_block, Code(:class => "language-julia", """using WasmTarget
bytes = compile(sin, (Float64,))
write("sin.wasm", bytes)

# wasm-opt typically yields ~80-90% size reduction for math
opt = compile(sin, (Float64,); optimize=true)""")),

        # ─────────────────────────── Collections ───────────────────────────
        H2(:id => "collections", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Collections"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "All 26 tested collection functions compile and produce correct results, verified with ",
            Code(:class => code_inline, "Vector{Int64}"), " and ", Code(:class => code_inline, "Vector{Float64}"), "."),

        Table(:class => table_cls,
            Thead(Tr(Th(:class => th_cls, "Function"), Th(:class => th_cls, "Path"), Th(:class => th_cls, "Notes"))),
            Tbody(
                Tr(Td(:class => td_cls, Code(:class => code_inline, "sort, sort!")), Td(:class => td_cls, "Overlay"), Td(:class => td_cls, "Full kwarg support (", Code(:class => code_inline, "rev=true"), ")")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "filter")), Td(:class => td_cls, "Overlay"), Td(:class => td_cls, "Predicate closures")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "map")), Td(:class => td_cls, "Native"), Td(:class => td_cls, "Closures compile correctly")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "reduce, foldl, foldr")), Td(:class => td_cls, "Native"), Td(:class => td_cls, "")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "sum, prod")), Td(:class => td_cls, "Native"), Td(:class => td_cls, "")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "minimum, maximum, extrema")), Td(:class => td_cls, "Native"), Td(:class => td_cls, "")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "any, all")), Td(:class => td_cls, "Native"), Td(:class => td_cls, "Predicate closures")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "count")), Td(:class => td_cls, "Overlay"), Td(:class => td_cls, "")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "unique")), Td(:class => td_cls, "Overlay"), Td(:class => td_cls, "")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "accumulate")), Td(:class => td_cls, "Native"), Td(:class => td_cls, "")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "findmax, findmin")), Td(:class => td_cls, "Native"), Td(:class => td_cls, "")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "argmax, argmin")), Td(:class => td_cls, "Overlay"), Td(:class => td_cls, "")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "mapreduce")), Td(:class => td_cls, "Native"), Td(:class => td_cls, "")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "foreach")), Td(:class => td_cls, "Overlay"), Td(:class => td_cls, "Ref mutation pattern")),
                Tr(Td(:class => td_cls, Code(:class => code_inline, "reverse")), Td(:class => td_cls, "Native"), Td(:class => td_cls, "(Vector)"))
            )
        ),
        Pre(:class => code_block, Code(:class => "language-julia", """using WasmTarget

f_sort(v::Vector{Int64}) = sort(v, rev=true)
f_filter(v::Vector{Int64}) = filter(iseven, v)
f_map(v::Vector{Int64}) = map(x -> x * 2, v)

bytes = compile_multi([
    (f_sort, (Vector{Int64},)),
    (f_filter, (Vector{Int64},)),
    (f_map, (Vector{Int64},)),
])

# 8-deep chain — all verified E2E
f(v::Vector{Int64})::Int64 = sum(unique(sort(filter(x -> x > 0, map(abs, accumulate(+, reverse(v)))))))""")),
        P(:class => "text-warm-600 dark:text-warm-400",
            "All 16 mutation functions work via overlays: ",
            Code(:class => code_inline, "push!, pop!, pushfirst!, popfirst!, insert!, deleteat!, append!, prepend!, splice!, resize!, empty!, fill!, copy, reverse, length, vec"),
            "."),

        # ─────────────────────────── Structs & Tuples ───────────────────────────
        H2(:id => "structs", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Structs & Tuples"),
        P(:class => "text-warm-600 dark:text-warm-400", "User-defined structs and tuples compile to WasmGC struct types."),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Structs"),
        Pre(:class => code_block, Code(:class => "language-julia", """struct Point
    x::Float64
    y::Float64
end

function distance(p::Point)::Float64
    return sqrt(p.x * p.x + p.y * p.y)
end

bytes = compile(distance, (Point,))""")),
        P(:class => "text-warm-600 dark:text-warm-400",
            "The compiler automatically registers ", Code(:class => code_inline, "Point"),
            " as a WasmGC struct type with two ", Code(:class => code_inline, "f64"),
            " fields and generates ", Code(:class => code_inline, "struct.new / struct.get"), " instructions."),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Mutable Structs"),
        Pre(:class => code_block, Code(:class => "language-julia", """mutable struct Counter
    value::Int32
end

function increment!(c::Counter)::Int32
    c.value = c.value + Int32(1)
    return c.value
end

bytes = compile(increment!, (Counter,))""")),
        P(:class => "text-warm-600 dark:text-warm-400",
            "Mutable struct fields use ", Code(:class => code_inline, "struct.set"), " for assignment."),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Nested Structs"),
        P(:class => "text-warm-600 dark:text-warm-400", "Nested struct types are registered recursively:"),
        Pre(:class => code_block, Code(:class => "language-julia", """struct Color
    r::Int32; g::Int32; b::Int32
end

struct Pixel
    pos::Point
    color::Color
end

pixel_x(p::Pixel)::Float64 = p.pos.x
bytes = compile(pixel_x, (Pixel,))""")),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Tuples & NamedTuples"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "Tuples compile as immutable WasmGC structs. Each element becomes a struct field; index access (",
            Code(:class => code_inline, "t[1]"), ", ", Code(:class => code_inline, "t[2]"), ") compiles to ",
            Code(:class => code_inline, "struct.get"), " with the appropriate field index. Named tuples work like regular tuples — names are erased in the IR."),
        Pre(:class => code_block, Code(:class => "language-julia", """function swap(t::Tuple{Int32, Int32})::Tuple{Int32, Int32}
    return (t[2], t[1])
end

function get_name(nt::NamedTuple{(:x, :y), Tuple{Float64, Float64}})::Float64
    return nt.x + nt.y
end""")),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Recursive Structs"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "Self-referential types are supported — the compiler handles recursive type registration by creating forward references in the WasmGC type section."),
        Pre(:class => code_block, Code(:class => "language-julia", """mutable struct Node
    value::Int32
    next::Union{Node, Nothing}
end""")),

        # ─────────────────────────── Control Flow ───────────────────────────
        H2(:id => "control-flow", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Control Flow"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "WasmTarget handles all Julia control flow patterns by translating the compiler's IR (",
            Code(:class => code_inline, "GotoNode"), ", ", Code(:class => code_inline, "GotoIfNot"), ", ",
            Code(:class => code_inline, "PhiNode"),
            ") into WASM structured control flow (", Code(:class => code_inline, "block"),
            ", ", Code(:class => code_inline, "loop"), ", ", Code(:class => code_inline, "br"),
            ", ", Code(:class => code_inline, "br_if"), ")."),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "If / Else, While, For"),
        Pre(:class => code_block, Code(:class => "language-julia", """function clamp_positive(x::Int32)::Int32
    if x > Int32(0); return x; else; return Int32(0); end
end

function sum_to(n::Int32)::Int32
    total = Int32(0); i = Int32(1)
    while i <= n
        total += i; i += Int32(1)
    end
    return total
end

# For loops over ranges lower to while loops in the IR — compile identically.
function sum_range(n::Int32)::Int32
    total = Int32(0)
    for i in Int32(1):n
        total += i
    end
    return total
end""")),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Short-Circuit Operators"),
        P(:class => "text-warm-600 dark:text-warm-400",
            Code(:class => code_inline, "&&"), " and ", Code(:class => code_inline, "||"),
            " compile correctly, including complex chains. They use WASM ",
            Code(:class => code_inline, "block / br_if"), " patterns for short-circuit evaluation."),
        Pre(:class => code_block, Code(:class => "language-julia", """check(a::Int32, b::Int32, c::Int32)::Bool =
    a > Int32(0) && b > Int32(0) && c > Int32(0)

any_positive(a::Int32, b::Int32)::Bool =
    a > Int32(0) || b > Int32(0)""")),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Try / Catch / Throw"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "Exception handling uses WASM's ", Code(:class => code_inline, "try_table"),
            " and ", Code(:class => code_inline, "throw"), " instructions:"),
        Pre(:class => code_block, Code(:class => "language-julia", """function safe_div(a::Int32, b::Int32)::Int32
    try
        if b == Int32(0)
            throw(DivideError())
        end
        return div(a, b)
    catch
        return Int32(-1)
    end
end""")),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Recursion + Stackifier"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "Self-recursive functions compile with the function calling itself by index. ",
            "Functions with many conditional branches (e.g. Julia's ", Code(:class => code_inline, "sin"),
            " implementation with 15+ ", Code(:class => code_inline, "GotoIfNot"),
            ") use a stackifier algorithm that converts arbitrary CFG patterns to WASM structured control flow using nested ",
            Code(:class => code_inline, "block / loop / br"), " instructions."),
        Pre(:class => code_block, Code(:class => "language-julia", """function factorial(n::Int32)::Int32
    if n <= Int32(1); return Int32(1); end
    return n * factorial(n - Int32(1))
end""")),

        # ─────────────────────────── JS Interop ───────────────────────────
        H2(:id => "js-interop", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "JS Interop"),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "JSValue (externref)"),
        P(:class => "text-warm-600 dark:text-warm-400",
            Code(:class => code_inline, "JSValue"),
            " is a primitive type that maps to WASM's ", Code(:class => code_inline, "externref"),
            ". It represents an opaque handle to any JavaScript value:"),
        Pre(:class => code_block, Code(:class => "language-julia", """using WasmTarget

# JSValue appears in function signatures
function process(el::JSValue, count::Int32)::Int32
    # el is an opaque JS reference
    return count + Int32(1)
end""")),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Importing JS Functions"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "Use ", Code(:class => code_inline, "add_import!"),
            " on a ", Code(:class => code_inline, "WasmModule"),
            " to declare functions the host (JavaScript) must provide. Two overloads exist — pure-numeric (",
            Code(:class => code_inline, "NumType"),
            " only) and the generalized ", Code(:class => code_inline, "WasmValType"),
            " overload required when an ", Code(:class => code_inline, "ExternRef"),
            " (a ", Code(:class => code_inline, "RefType"), ") appears in the signature."),
        Pre(:class => code_block, Code(:class => "language-julia", """mod = WasmModule()

# ExternRef is a RefType — use WasmValType[…] to hit the right overload.
add_import!(mod, "dom", "set_text", WasmValType[ExternRef, I32], WasmValType[])
add_import!(mod, "dom", "get_value", WasmValType[ExternRef], WasmValType[I32])

# Pure numeric imports can use plain NumType vectors
add_import!(mod, "math", "add", [I32, I32], [I32])""")),
        P(:class => "text-warm-600 dark:text-warm-400", "Provide the imports when instantiating in JS:"),
        Pre(:class => code_block, Code(:class => "language-javascript", """const imports = {
  dom: {
    set_text: (el, text) => { el.textContent = String(text); },
    get_value: (el) => parseInt(el.value) || 0,
  },
};
const { instance } = await WebAssembly.instantiate(bytes, imports);""")),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Exporting Functions"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "Compiled functions are automatically exported by name. ",
            Code(:class => code_inline, "compile_multi"), " accepts an optional custom name:"),
        Pre(:class => code_block, Code(:class => "language-julia", """increment(x::Int32)::Int32 = x + Int32(1)
bytes = compile(increment, (Int32,))
# instance.exports.increment(5) => 6

bytes = compile_multi([
    (increment, (Int32,), "inc"),
])
# instance.exports.inc(5) => 6""")),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "WasmGlobal{T, IDX}"),
        P(:class => "text-warm-600 dark:text-warm-400",
            Code(:class => code_inline, "WasmGlobal{T, IDX}"),
            " provides type-safe mutable global variables. ", Code(:class => code_inline, "IDX"),
            " is the compile-time WASM global index:"),
        Pre(:class => code_block, Code(:class => "language-julia", """const Counter = WasmGlobal{Int32, 0}
const Threshold = WasmGlobal{Int32, 1}

function increment(g::Counter)::Int32
    g[] = g[] + Int32(1)
    return g[]
end

function check(g::Counter, t::Threshold)::Bool
    return g[] >= t[]
end

bytes = compile_multi([
    (increment, (Counter,)),
    (check, (Counter, Threshold)),
])""")),
        Ul(:class => "list-disc ml-5 space-y-1 text-sm text-warm-600 dark:text-warm-400",
            Li(Strong("Phantom parameters."), " ", Code(:class => code_inline, "WasmGlobal"),
               " arguments do not become WASM function parameters."),
            Li(Strong("Auto-created."), " The compiler adds globals to the module."),
            Li(Strong("Julia-testable."), " ", Code(:class => code_inline, "g[] = x"),
               " and ", Code(:class => code_inline, "g[]"), " work in Julia for testing."),
            Li(Strong("Shared state."), " Multiple functions in the same ",
               Code(:class => code_inline, "compile_multi"), " share globals.")
        ),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Manual Vector Bridge (not auto-generated)"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "When a function operates on ", Code(:class => code_inline, "Vector{T}"),
            ", JavaScript cannot directly create WasmGC array references. You must ",
            Strong("manually"), " compile bridge functions alongside your code using ",
            Code(:class => code_inline, "compile_multi"),
            ". The compiler does ", Strong("not"), " auto-export ",
            Code(:class => code_inline, "vec_new / vec_get / vec_set / vec_len"), "."),
        Pre(:class => code_block, Code(:class => "language-julia", """# Your actual function
my_sum(v::Vector{Float64})::Float64 = sum(v)

# Bridge functions — you write these yourself
bv_new(n::Int64)::Vector{Float64} = Vector{Float64}(undef, n)
bv_set!(v::Vector{Float64}, i::Int64, val::Float64)::Int64 = (v[i] = val; Int64(0))
bv_get(v::Vector{Float64}, i::Int64)::Float64 = v[i]
bv_len(v::Vector{Float64})::Int64 = Int64(length(v))

# Compile everything together so they share the same WasmGC type space
bytes = compile_multi([
    (my_sum,  (Vector{Float64},)),
    (bv_new,  (Int64,)),
    (bv_set!, (Vector{Float64}, Int64, Float64)),
    (bv_get,  (Vector{Float64}, Int64)),
    (bv_len,  (Vector{Float64},)),
])""")),
        Pre(:class => code_block, Code(:class => "language-javascript", """const e = instance.exports;
const v = e.bv_new(3n);          // BigInt for i64
e["bv_set!"](v, 1n, 1.0);        // 1-based indexing (Julia)
e["bv_set!"](v, 2n, 2.0);
e["bv_set!"](v, 3n, 3.0);
console.log(e.my_sum(v));        // 6.0""")),

        H3(:class => "text-base font-semibold text-warm-700 dark:text-warm-300", "Tables, Indirect Calls, Memory"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "WASM tables (", Code(:class => code_inline, "funcref"), " / ", Code(:class => code_inline, "externref"),
            ") enable dynamic dispatch. ", Code(:class => code_inline, "call_indirect"),
            " looks up a function in the table at runtime — the foundation for multiple dispatch in WASM."),
        Pre(:class => code_block, Code(:class => "language-julia", """mod = WasmModule()
add_table!(mod, FuncRef, 10)       # Table of 10 function references
add_table!(mod, ExternRef, 5)      # Table of 5 externref slots
add_table!(mod, FuncRef, 4, 16)    # min=4, max=16""")),
        P(:class => "text-warm-600 dark:text-warm-400",
            "For low-level control, linear memory + data segments are also available — but most use cases should prefer WasmGC types (structs, arrays):"),
        Pre(:class => code_block, Code(:class => "language-julia", """add_memory!(mod, 1)  # 1 page (64KB)
add_data_segment!(mod, 0, UInt8[0x48, 0x65, 0x6c, 0x6c, 0x6f])  # "Hello"
""")),
    ))
end
