# API Reference page - Complete documentation for WasmTarget.jl
#
# Uses Suite.jl components: Card, CodeBlock, Badge, Table, Separator, Button.
# Organized into sections: High-Level API, Low-Level Builder, Types, Opcodes

import Suite

function Api()
    Div(
        # Header
        Div(:class => "py-12 text-center",
            H1(:class => "text-4xl font-serif font-semibold text-warm-800 dark:text-warm-100 mb-4",
                "API Reference"
            ),
            P(:class => "text-xl text-warm-500 dark:text-warm-400 max-w-2xl mx-auto",
                "Complete API documentation for WasmTarget.jl"
            )
        ),

        # Navigation (in-page anchor links)
        Div(:class => "flex flex-wrap justify-center gap-3 mb-12",
            _ApiAnchorLink("#compile", "compile()"),
            _ApiAnchorLink("#compile-multi", "compile_multi()"),
            _ApiAnchorLink("#builder", "Low-Level Builder"),
            _ApiAnchorLink("#types", "Type Mappings"),
            _ApiAnchorLink("#features", "Supported Features")
        ),

        # ========================================
        # High-Level API Section
        # ========================================
        Div(:class => "py-8",
            _SectionHeader("High-Level API"),
            P(:class => "text-warm-600 dark:text-warm-300 mb-8 max-w-3xl",
                "The high-level API provides simple functions to compile Julia code directly to WebAssembly bytes. This is the recommended way to use WasmTarget.jl."
            ),

            # compile()
            _ApiFunction(
                "compile",
                "compile(f, arg_types; export_name=nothing) -> Vector{UInt8}",
                "Compile a single Julia function to WebAssembly bytes.",
                [
                    ("f", "Function", "The Julia function to compile"),
                    ("arg_types", "Tuple", "Tuple of argument types, e.g., (Int32, Int32)"),
                    ("export_name", "String", "Optional custom export name (default: function name)")
                ],
                """using WasmTarget

# Simple function
add(a::Int32, b::Int32)::Int32 = a + b
wasm = compile(add, (Int32, Int32))

# With custom export name
wasm = compile(add, (Int32, Int32); export_name="add_numbers")

# Save and use
write("add.wasm", wasm)
# Run with: node -e 'WebAssembly.instantiate(fs.readFileSync("add.wasm")).then(m => console.log(m.instance.exports.add(3, 4)))'"""
            ),

            # compile_multi()
            _ApiFunction(
                "compile_multi",
                "compile_multi(functions; imports=[], globals=[]) -> Vector{UInt8}",
                "Compile multiple Julia functions into a single Wasm module. Functions can call each other.",
                [
                    ("functions", "Vector", "Array of (function, arg_types) or (function, arg_types, name) tuples"),
                    ("imports", "Vector", "Optional JS imports"),
                    ("globals", "Vector", "Optional Wasm globals")
                ],
                """using WasmTarget

# Multiple functions that call each other
square(x::Int32)::Int32 = x * x
sum_of_squares(a::Int32, b::Int32)::Int32 = square(a) + square(b)

wasm = compile_multi([
    (square, (Int32,)),
    (sum_of_squares, (Int32, Int32))
])

# With JS imports
wasm = compile_multi(
    [(my_func, (Int32,))],
    imports = [("console", "log", [I32], [])]
)"""
            )
        ),

        Suite.Separator(),

        # ========================================
        # Low-Level Builder Section
        # ========================================
        Div(:id => "builder", :class => "py-8",
            _SectionHeader("Low-Level Builder API"),
            P(:class => "text-warm-600 dark:text-warm-300 mb-8 max-w-3xl",
                "For advanced use cases, you can build Wasm modules manually using the builder API. This gives you full control over imports, exports, globals, tables, and memory."
            ),

            # WasmModule
            _ApiFunction(
                "WasmModule",
                "WasmModule() -> WasmModule",
                "Create an empty Wasm module for manual construction.",
                [],
                """using WasmTarget

mod = WasmModule()
# Add types, imports, functions, etc.
bytes = to_bytes(mod)"""
            ),

            # add_function!
            _ApiFunction(
                "add_function!",
                "add_function!(mod, param_types, result_types, locals, body) -> UInt32",
                "Add a function to the module. Returns the function index.",
                [
                    ("mod", "WasmModule", "The module to add to"),
                    ("param_types", "Vector{WasmValType}", "Parameter types"),
                    ("result_types", "Vector{WasmValType}", "Return types"),
                    ("locals", "Vector{WasmValType}", "Local variable types"),
                    ("body", "Vector{UInt8}", "Wasm bytecode for function body")
                ],
                """using WasmTarget

mod = WasmModule()

# Build function body manually
body = UInt8[
    Opcode.LOCAL_GET, 0x00,  # get first param
    Opcode.LOCAL_GET, 0x01,  # get second param
    Opcode.I32_ADD,          # add them
    Opcode.END               # end function
]

func_idx = add_function!(mod, [I32, I32], [I32], [], body)
add_export!(mod, "add", 0x00, func_idx)"""
            ),

            # add_import!
            _ApiFunction(
                "add_import!",
                "add_import!(mod, module_name, func_name, param_types, result_types) -> UInt32",
                "Import a function from JavaScript. Returns the import index.",
                [
                    ("mod", "WasmModule", "The module"),
                    ("module_name", "String", "JS module name (e.g., \"console\")"),
                    ("func_name", "String", "JS function name (e.g., \"log\")"),
                    ("param_types", "Vector", "Parameter types"),
                    ("result_types", "Vector", "Return types")
                ],
                """using WasmTarget

mod = WasmModule()
log_idx = add_import!(mod, "console", "log", [I32], [])

# Use in a function:
# Opcode.CALL, log_idx"""
            ),

            # add_export!
            _ApiFunction(
                "add_export!",
                "add_export!(mod, name, kind, idx)",
                "Export a function, global, table, or memory.",
                [
                    ("mod", "WasmModule", "The module"),
                    ("name", "String", "Export name visible to JS"),
                    ("kind", "UInt8", "Export kind (0x00=func, 0x01=table, 0x02=memory, 0x03=global)"),
                    ("idx", "UInt32", "Index of item to export")
                ],
                """add_export!(mod, "myFunc", 0x00, func_idx)  # Export function
add_export!(mod, "counter", 0x03, global_idx)  # Export global"""
            ),

            # add_global!
            _ApiFunction(
                "add_global!",
                "add_global!(mod, valtype, mutable, init_value) -> UInt32",
                "Add a global variable. Returns the global index.",
                [
                    ("mod", "WasmModule", "The module"),
                    ("valtype", "WasmValType", "Type (I32, I64, F32, F64)"),
                    ("mutable", "Bool", "Whether the global can be modified"),
                    ("init_value", "Number", "Initial value")
                ],
                """counter_idx = add_global!(mod, I32, true, 0)   # Mutable i32
constant_idx = add_global!(mod, F64, false, 3.14)  # Immutable f64"""
            ),

            # to_bytes
            _ApiFunction(
                "to_bytes",
                "to_bytes(mod) -> Vector{UInt8}",
                "Serialize a WasmModule to binary .wasm format.",
                [("mod", "WasmModule", "The module to serialize")],
                """bytes = to_bytes(mod)
write("output.wasm", bytes)"""
            )
        ),

        Suite.Separator(),

        # ========================================
        # Type Mappings Section
        # ========================================
        Div(:id => "types", :class => "py-8",
            _SectionHeader("Type Mappings"),
            P(:class => "text-warm-600 dark:text-warm-300 mb-8 max-w-3xl",
                "WasmTarget.jl automatically maps Julia types to WebAssembly types. Here's the complete mapping:"
            ),

            Suite.Table(
                Suite.TableHeader(
                    Suite.TableRow(
                        Suite.TableHead("Julia Type"),
                        Suite.TableHead("Wasm Type"),
                        Suite.TableHead("Notes")
                    )
                ),
                Suite.TableBody(
                    _TypeRow("Int32, UInt32", "i32", "Native 32-bit integer"),
                    _TypeRow("Int64, UInt64, Int", "i64", "Native 64-bit integer"),
                    _TypeRow("Float32", "f32", "32-bit IEEE float"),
                    _TypeRow("Float64", "f64", "64-bit IEEE float"),
                    _TypeRow("Bool", "i32", "0 or 1"),
                    _TypeRow("Char", "i32", "Unicode codepoint"),
                    _TypeRow("String", "WasmGC array (i32)", "Immutable, supports ==, length, *"),
                    _TypeRow("Vector{T}", "WasmGC array", "Mutable, T must be concrete"),
                    _TypeRow("struct Foo ... end", "WasmGC struct", "User-defined structs"),
                    _TypeRow("Tuple{A,B,...}", "WasmGC struct", "Immutable"),
                    _TypeRow("Union{Nothing,T}", "Tagged union", "Supports isa operator"),
                    _TypeRow("JSValue", "externref", "JavaScript object reference"),
                    _TypeRow("WasmGlobal{T,IDX}", "global", "Compile-time global access")
                )
            ),

            # Type constants
            Div(:class => "mt-12",
                H3(:class => "text-xl font-semibold text-warm-800 dark:text-warm-100 mb-4", "Type Constants"),
                P(:class => "text-warm-600 dark:text-warm-300 mb-4",
                    "Use these constants when building modules manually:"
                ),
                Div(:class => "flex flex-wrap gap-3",
                    Suite.Badge(variant="secondary", "I32"),
                    Suite.Badge(variant="secondary", "I64"),
                    Suite.Badge(variant="secondary", "F32"),
                    Suite.Badge(variant="secondary", "F64"),
                    Suite.Badge(variant="secondary", "ExternRef"),
                    Suite.Badge(variant="secondary", "FuncRef"),
                    Suite.Badge(variant="secondary", "AnyRef")
                )
            )
        ),

        Suite.Separator(),

        # ========================================
        # Supported Features Section
        # ========================================
        Div(:id => "features", :class => "py-8",
            _SectionHeader("Supported Features"),
            P(:class => "text-warm-600 dark:text-warm-300 mb-8 max-w-3xl",
                "WasmTarget.jl supports a significant subset of Julia. Here's what works today:"
            ),

            Div(:class => "grid md:grid-cols-2 lg:grid-cols-3 gap-6",
                _FeatureCategory("Control Flow", [
                    ("if/elseif/else", true),
                    ("while loops", true),
                    ("for loops (ranges)", true),
                    ("&& and || (short-circuit)", true),
                    ("try/catch/throw", true),
                    ("Recursion", true),
                    ("@goto/@label", false)
                ]),
                _FeatureCategory("Functions", [
                    ("Regular functions", true),
                    ("Multiple functions", true),
                    ("Closures", true),
                    ("Multiple dispatch", true),
                    ("Varargs", false),
                    ("Keyword args", false)
                ]),
                _FeatureCategory("Operators", [
                    ("Arithmetic (+, -, *, /, %)", true),
                    ("Comparison (==, <, >, etc)", true),
                    ("Logical (&&, ||, !)", true),
                    ("Bitwise (&, |, xor, <<, >>)", true),
                    ("Power (^)", true)
                ]),
                _FeatureCategory("Data Structures", [
                    ("Structs", true),
                    ("Tuples", true),
                    ("Vector{T}", true),
                    ("Matrix{T}", false),
                    ("String ops", true),
                    ("SimpleDict/StringDict", true),
                    ("Full Dict", false)
                ]),
                _FeatureCategory("JS Interop", [
                    ("externref (JSValue)", true),
                    ("Import JS functions", true),
                    ("Export Wasm functions", true),
                    ("Wasm globals", true),
                    ("Tables (funcref)", true),
                    ("Linear memory", true)
                ]),
                _FeatureCategory("Advanced", [
                    ("Union{Nothing,T}", true),
                    ("Type inference", true),
                    ("Exception handling", true),
                    ("Data segments", true),
                    ("Generated functions", false),
                    ("FFI/ccall", false)
                ])
            )
        ),

        Suite.Separator(),

        # Footer CTA
        Div(:class => "py-16 text-center",
            H2(:class => "text-2xl font-serif font-semibold text-warm-800 dark:text-warm-100 mb-4",
                "Ready to build?"
            ),
            P(:class => "text-warm-500 dark:text-warm-400 mb-8",
                "Check out the code examples or explore the source code on GitHub."
            ),
            Div(:class => "flex justify-center gap-4",
                A(:href => "./features/",
                    Suite.Button("Code Examples")
                ),
                A(:href => "https://github.com/GroupTherapyOrg/WasmTarget.jl",
                  :target => "_blank",
                    Suite.Button(variant="outline", "View Source")
                )
            )
        )
    )
end

# --- Helper: API anchor link ---
function _ApiAnchorLink(href, text)
    A(:href => href,
        Suite.Button(variant="outline", size="sm", text)
    )
end

# --- Helper: Section header ---
function _SectionHeader(title)
    H2(:class => "text-3xl font-serif font-semibold text-warm-800 dark:text-warm-100 mb-4", title)
end

# --- Helper: API function card with Suite.Card + Suite.CodeBlock ---
function _ApiFunction(name, signature, description, params, example)
    Suite.Card(id=lowercase(replace(name, "()" => "")), class="mb-12",
        Suite.CardHeader(
            Suite.CardTitle(class="font-mono text-accent-600 dark:text-accent-400", name * "()"),
            Suite.CardDescription(class="font-mono text-sm", signature)
        ),
        Suite.CardContent(
            P(:class => "text-warm-600 dark:text-warm-300 mb-4", description),

            # Parameters
            if !isempty(params)
                Div(:class => "mb-4",
                    H4(:class => "font-semibold text-warm-800 dark:text-warm-100 mb-2", "Parameters"),
                    Ul(:class => "space-y-2",
                        [Li(:class => "text-sm",
                            Span(:class => "font-mono text-accent-600 dark:text-accent-400", p[1]),
                            Span(:class => "text-warm-400 mx-2", ":"),
                            Span(:class => "text-warm-500 dark:text-warm-400 italic", p[2]),
                            Span(:class => "text-warm-400 mx-2", "-"),
                            Span(:class => "text-warm-600 dark:text-warm-300", p[3])
                        ) for p in params]...
                    )
                )
            end,

            # Example
            Div(
                H4(:class => "font-semibold text-warm-800 dark:text-warm-100 mb-2", "Example"),
                Suite.CodeBlock(example, language="julia")
            )
        )
    )
end

# --- Helper: Type mapping table row ---
function _TypeRow(julia, wasm, notes)
    Suite.TableRow(
        Suite.TableCell(class="font-mono text-sm text-accent-600 dark:text-accent-400", julia),
        Suite.TableCell(class="font-mono text-sm", wasm),
        Suite.TableCell(notes)
    )
end

# --- Helper: Feature category card ---
function _FeatureCategory(title, features)
    Suite.Card(
        Suite.CardHeader(Suite.CardTitle(title)),
        Suite.CardContent(
            Ul(:class => "space-y-2",
                [Li(:class => "flex items-center gap-2 text-sm",
                    Span(:class => f[2] ? "text-green-500" : "text-warm-400",
                        f[2] ? "✓" : "○"
                    ),
                    Span(:class => f[2] ? "text-warm-700 dark:text-warm-300" : "text-warm-400 dark:text-warm-500",
                        f[1]
                    )
                ) for f in features]...
            )
        )
    )
end

# Export the page component
Api
