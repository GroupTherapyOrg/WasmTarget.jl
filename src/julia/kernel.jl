# The Kernel table (dev/MARCH.md 1.A4): every type an in-scope dart file names that no in-scope file
# declares, Kernel's and the other libraries' dart2wasm imports, with its Julia counterpart. Julia's
# compiler is dart's Kernel here (ledger D3): its types, its MethodInstances and its optimized IR, read
# as the NIR (src/julia/nir.jl), answer what a Kernel node answers for dart2wasm. dev/skeleton.jl
# types every stub through this table, the one source, and refuses a type with no row, so each row is
# a decision. A counterpart `NoCounterpart` says Julia has none: no value of it exists, so a stub
# taking one can never be called, and its port drops or quarantines the parameter; as a supertype it
# gives none. A counterpart `planned: <row>` names the dev/MARCH.md row whose types will answer it; until
# they exist a stub leaves the parameter unannotated. The platform's types (dart:core, dart:typed_data) are the generator's DART_TYPES.

"""
    NoCounterpart

The Julia type of a Kernel type Julia has no counterpart for (KERNEL_TYPES): a struct with one field of
type `Union{}`, the type of no value, so no value of it exists and a method taking one can never be
called. Julia refuses `Union{}` itself as a parameter's type, so this type stands where it would.
"""
@quarantine "Julia refuses Union{} as a parameter's type; an uninhabited struct is the type of no value there" Core.Union struct NoCounterpart
    _never::Union{}
    NoCounterpart(args...) = reject!(Internal("src/julia/kernel.jl: NoCounterpart has no value: the Kernel type it stands for has no Julia counterpart"), "NoCounterpart")
end

"""
    KERNEL_TYPES

`(library, name) => (Julia type, why)`: the dart type `name` the library (a path under the sdk's
pkg/) declares, its Julia counterpart as Dart2Wasm spells it, and the reason. dev/skeleton.jl reads it.

precedent(rust: a crate's `use` of an external crate's type, one path naming it; dart: an import).
Julia's differs: dart2wasm's Kernel is Julia's own compiler, so each Kernel type is a Julia type,
a NIR kind, or none.
"""
@quarantine "Julia's compiler is dart's Kernel: each Kernel type dart2wasm names has one Julia counterpart, or none" Base.Pair const KERNEL_TYPES = (
    ("kernel/lib/ast.dart", "Class") => ("DataType", "a class is a Julia type, by identity (the lead's ruling)"),
    ("kernel/lib/ast.dart", "Library") => ("Module", "a library is a Julia module, its namespace"),
    ("kernel/lib/ast.dart", "Component") => ("NirWorld", "the program is the closed world in NIR, which build_nir alone makes from a ClosedWorld (the lead's ruling)"),
    ("kernel/lib/ast.dart", "Member") => ("Core.MethodInstance", "Julia compiles one function per specialization, the MethodInstance, where dart compiles one per member"),
    ("kernel/lib/ast.dart", "Procedure") => ("Core.MethodInstance", "Julia compiles one function per specialization, the MethodInstance, where dart compiles one per member"),
    ("kernel/lib/ast.dart", "Constructor") => ("Core.MethodInstance", "Julia compiles one function per specialization, the MethodInstance, where dart compiles one per member"),
    ("kernel/lib/canonical_name.dart", "Reference") => ("Core.MethodInstance", "a MethodInstance names one callable, where dart's Reference names a member or its getter, setter or tear-off"),
    ("kernel/lib/ast.dart", "Field") => ("ClassField", "a field is a struct's field, Julia's fieldname and fieldtype (src/julia/classes.jl); a static field is a Julia global, read by GlobalRef"),
    ("kernel/lib/ast.dart", "FunctionNode") => ("NirBody", "a function's parameters and body are its CodeInstance and optimized IR"),
    ("kernel/lib/ast.dart", "Name") => ("Symbol", "a member's name is a Julia Symbol"),
    ("kernel/lib/ast.dart", "TypeParameter") => ("TypeVar", "a type parameter is Julia's TypeVar"),
    ("kernel/lib/ast.dart", "StructuralParameter") => ("TypeVar", "a type parameter is Julia's TypeVar"),
    ("kernel/lib/ast.dart", "Variable") => ("Union{NirSSA,NirArgument}", "Julia's optimized IR has no variables: a local is a statement's value or an argument"),
    ("kernel/lib/ast.dart", "VariableDeclaration") => ("Union{NirSSA,NirArgument}", "Julia's optimized IR has no variables: a local is a statement's value or an argument"),
    ("kernel/lib/ast.dart", "FunctionParameter") => ("NirArgument", "a parameter is an argument by position; Julia's keyword body takes keywords positionally"),
    ("kernel/lib/ast.dart", "NamedParameter") => ("NirArgument", "a parameter is an argument by position; Julia's keyword body takes keywords positionally"),
    ("kernel/lib/ast.dart", "Arguments") => ("Vector{NirValue}", "a call's arguments are its operands"),
    ("kernel/lib/ast.dart", "NamedExpression") => ("NoCounterpart", "no counterpart: Julia's lowering passes keywords positionally to the keyword body"),
    ("kernel/lib/ast.dart", "Location") => ("LineNumberNode", "a location is Julia's file and line, its debuginfo's"),
    ("kernel/lib/ast.dart", "Source") => ("Symbol", "a source is the file Julia's debuginfo names; Julia needs no line-start table"),
    ("kernel/lib/ast.dart", "TreeNode") => ("NirStmt", "a node a location hangs on is a statement of Julia's optimized IR"),
    ("kernel/lib/ast.dart", "Node") => ("NirStmt", "a node a location hangs on is a statement of Julia's optimized IR"),
    ("kernel/lib/ast.dart", "Statement") => ("NirStmt", "a node a location hangs on is a statement of Julia's optimized IR"),
    ("kernel/lib/ast.dart", "Expression") => ("NirValue", "an expression is an operand of Julia's optimized IR (a value statement is reached by its NirSSA)"),
    ("kernel/lib/ast.dart", "Annotatable") => ("NoCounterpart", "no counterpart: a Julia method carries no pragma annotations"),
    ("kernel/lib/ast.dart", "Nullability") => ("NoCounterpart", "no counterpart: a Julia type has no nullability; T? is Union{Nothing,T}"),
    ("kernel/lib/ast.dart", "MetadataRepository") => ("NoCounterpart", "no counterpart: Kernel's serialization and side tables; Julia's inference results are the program"),
    ("kernel/lib/ast.dart", "BinarySink") => ("NoCounterpart", "no counterpart: Kernel's serialization and side tables; Julia's inference results are the program"),
    ("kernel/lib/ast.dart", "BinarySource") => ("NoCounterpart", "no counterpart: Kernel's serialization and side tables; Julia's inference results are the program"),
    ("kernel/lib/ast.dart", "AsyncMarker") => ("NoCounterpart", "no counterpart: tasks are out of scope, Julia's verifier rejects them (1.F)"),
    ("kernel/lib/ast.dart", "AwaitExpression") => ("NoCounterpart", "no counterpart: tasks are out of scope, Julia's verifier rejects them (1.F)"),
    ("kernel/lib/ast.dart", "YieldStatement") => ("NoCounterpart", "no counterpart: tasks are out of scope, Julia's verifier rejects them (1.F)"),
    ("kernel/lib/ast.dart", "FutureOrType") => ("NoCounterpart", "no counterpart: tasks are out of scope, Julia's verifier rejects them (1.F)"),
    ("kernel/lib/ast.dart", "LoadLibrary") => ("NoCounterpart", "no counterpart: deferred loading is out of scope (dev/PARITY_MASTER.md)"),
    ("kernel/lib/ast.dart", "CheckLibraryIsLoaded") => ("NoCounterpart", "no counterpart: deferred loading is out of scope (dev/PARITY_MASTER.md)"),
    ("kernel/lib/ast.dart", "DartType") => ("Type", "a dart type is a Julia type (the lead's ruling)"),
    ("kernel/lib/ast.dart", "InterfaceType") => ("Type", "a dart type is a Julia type (the lead's ruling)"),
    ("kernel/lib/ast.dart", "FunctionType") => ("Type", "a function type is a method signature, a Julia Tuple type"),
    ("kernel/lib/ast.dart", "RecordType") => ("Type", "a record type is a Julia Tuple or NamedTuple type"),
    ("kernel/lib/ast.dart", "TypeParameterType") => ("TypeVar", "a type parameter's use is Julia's TypeVar"),
    ("kernel/lib/ast.dart", "StructuralParameterType") => ("TypeVar", "a type parameter's use is Julia's TypeVar"),
    ("kernel/lib/ast.dart", "ClassTypeParameterType") => ("TypeVar", "a type parameter's use is Julia's TypeVar"),
    ("kernel/lib/ast.dart", "NamedType") => ("Pair{Symbol,Type}", "a record's named field type is a NamedTuple type's name and field type"),
    ("kernel/lib/ast.dart", "Constant") => ("NirConst", "a constant is Julia's Core.Const of the value, which NirConst holds (the lead's ruling)"),
    ("kernel/lib/ast.dart", "InstanceConstant") => ("NirConst", "a constant is Julia's Core.Const of the value, which NirConst holds (the lead's ruling)"),
    ("kernel/lib/ast.dart", "ListConstant") => ("NirConst", "a constant is Julia's Core.Const of the value, which NirConst holds (the lead's ruling)"),
    ("kernel/lib/ast.dart", "IntConstant") => ("Int64", "the constant is the Julia value itself, dispatched on its type"),
    ("kernel/lib/ast.dart", "DoubleConstant") => ("Float64", "the constant is the Julia value itself, dispatched on its type"),
    ("kernel/lib/ast.dart", "BoolConstant") => ("Bool", "the constant is the Julia value itself, dispatched on its type"),
    ("kernel/lib/ast.dart", "StringConstant") => ("String", "the constant is the Julia value itself, dispatched on its type"),
    ("kernel/lib/ast.dart", "NullConstant") => ("Nothing", "the constant is the Julia value itself, dispatched on its type"),
    ("kernel/lib/ast.dart", "SymbolConstant") => ("Symbol", "the constant is the Julia value itself, dispatched on its type"),
    ("kernel/lib/ast.dart", "TypeLiteralConstant") => ("Type", "a type as a value is the Julia type itself"),
    ("kernel/lib/ast.dart", "RecordConstant") => ("Tuple", "a record value is a Julia Tuple or NamedTuple"),
    ("kernel/lib/ast.dart", "TearOffConstant") => ("Function", "a function as a value is Julia's function singleton"),
    ("kernel/lib/ast.dart", "StaticTearOffConstant") => ("Function", "a function as a value is Julia's function singleton"),
    ("kernel/lib/ast.dart", "ConstructorTearOffConstant") => ("Function", "a function as a value is Julia's function singleton"),
    ("kernel/lib/ast.dart", "RedirectingFactoryTearOffConstant") => ("Function", "a function as a value is Julia's function singleton"),
    ("kernel/lib/ast.dart", "MapConstant") => ("NoCounterpart", "no counterpart: Julia has no constant Dict or Set; one is built by calls"),
    ("kernel/lib/ast.dart", "SetConstant") => ("NoCounterpart", "no counterpart: Julia has no constant Dict or Set; one is built by calls"),
    ("kernel/lib/ast.dart", "InstantiationConstant") => ("NoCounterpart", "no counterpart: Julia instantiates no generic function value; a specialization is a MethodInstance"),
    ("kernel/lib/ast.dart", "Instantiation") => ("NoCounterpart", "no counterpart: Julia instantiates no generic function value; a specialization is a MethodInstance"),
    ("kernel/lib/ast.dart", "UnevaluatedConstant") => ("NoCounterpart", "no counterpart: Julia's inference evaluates every constant it folds"),
    ("kernel/lib/ast.dart", "AuxiliaryConstant") => ("NoCounterpart", "no counterpart: Julia's inference evaluates every constant it folds"),
    ("kernel/lib/ast.dart", "StaticInvocation") => ("NirInvoke", "a call Julia's inference resolved to its MethodInstance, Expr(:invoke)"),
    ("kernel/lib/ast.dart", "InstanceInvocation") => ("NirInvoke", "a call Julia's inference resolved to its MethodInstance, Expr(:invoke)"),
    ("kernel/lib/ast.dart", "FunctionInvocation") => ("NirInvoke", "a call Julia's inference resolved to its MethodInstance, Expr(:invoke)"),
    ("kernel/lib/ast.dart", "LocalFunctionInvocation") => ("NirInvoke", "a call Julia's inference resolved to its MethodInstance, Expr(:invoke)"),
    ("kernel/lib/ast.dart", "EqualsCall") => ("NirInvoke", "a call Julia's inference resolved to its MethodInstance, Expr(:invoke)"),
    ("kernel/lib/ast.dart", "SuperMethodInvocation") => ("NirInvoke", "a call Julia's inference resolved to its MethodInstance, Expr(:invoke)"),
    ("kernel/lib/ast.dart", "SuperPropertyGet") => ("NirInvoke", "a call Julia's inference resolved to its MethodInstance, Expr(:invoke)"),
    ("kernel/lib/ast.dart", "SuperPropertySet") => ("NirInvoke", "a call Julia's inference resolved to its MethodInstance, Expr(:invoke)"),
    ("kernel/lib/ast.dart", "StringConcatenation") => ("NirInvoke", "a call Julia's inference resolved to its MethodInstance, Expr(:invoke)"),
    ("kernel/lib/ast.dart", "ListLiteral") => ("NirInvoke", "a call Julia's inference resolved to its MethodInstance, Expr(:invoke)"),
    ("kernel/lib/ast.dart", "MapLiteral") => ("NirInvoke", "a call Julia's inference resolved to its MethodInstance, Expr(:invoke)"),
    ("kernel/lib/ast.dart", "SetLiteral") => ("NirInvoke", "a call Julia's inference resolved to its MethodInstance, Expr(:invoke)"),
    ("kernel/lib/ast.dart", "Rethrow") => ("NirInvoke", "a call Julia's inference resolved to its MethodInstance, Expr(:invoke)"),
    ("kernel/lib/ast.dart", "EqualsNull") => ("NirCall", "a builtin or intrinsic call Julia's IR keeps as Expr(:call): ===, getfield, setfield!, setglobal!, tuple, isa, typeassert, not_int, throw"),
    ("kernel/lib/ast.dart", "InstanceGet") => ("NirCall", "a builtin or intrinsic call Julia's IR keeps as Expr(:call): ===, getfield, setfield!, setglobal!, tuple, isa, typeassert, not_int, throw"),
    ("kernel/lib/ast.dart", "InstanceSet") => ("NirCall", "a builtin or intrinsic call Julia's IR keeps as Expr(:call): ===, getfield, setfield!, setglobal!, tuple, isa, typeassert, not_int, throw"),
    ("kernel/lib/ast.dart", "StaticSet") => ("NirCall", "a builtin or intrinsic call Julia's IR keeps as Expr(:call): ===, getfield, setfield!, setglobal!, tuple, isa, typeassert, not_int, throw"),
    ("kernel/lib/ast.dart", "RecordLiteral") => ("NirCall", "a builtin or intrinsic call Julia's IR keeps as Expr(:call): ===, getfield, setfield!, setglobal!, tuple, isa, typeassert, not_int, throw"),
    ("kernel/lib/ast.dart", "RecordIndexGet") => ("NirCall", "a builtin or intrinsic call Julia's IR keeps as Expr(:call): ===, getfield, setfield!, setglobal!, tuple, isa, typeassert, not_int, throw"),
    ("kernel/lib/ast.dart", "RecordNameGet") => ("NirCall", "a builtin or intrinsic call Julia's IR keeps as Expr(:call): ===, getfield, setfield!, setglobal!, tuple, isa, typeassert, not_int, throw"),
    ("kernel/lib/ast.dart", "IsExpression") => ("NirCall", "a builtin or intrinsic call Julia's IR keeps as Expr(:call): ===, getfield, setfield!, setglobal!, tuple, isa, typeassert, not_int, throw"),
    ("kernel/lib/ast.dart", "AsExpression") => ("NirCall", "a builtin or intrinsic call Julia's IR keeps as Expr(:call): ===, getfield, setfield!, setglobal!, tuple, isa, typeassert, not_int, throw"),
    ("kernel/lib/ast.dart", "NullCheck") => ("NirCall", "a builtin or intrinsic call Julia's IR keeps as Expr(:call): ===, getfield, setfield!, setglobal!, tuple, isa, typeassert, not_int, throw"),
    ("kernel/lib/ast.dart", "Not") => ("NirCall", "a builtin or intrinsic call Julia's IR keeps as Expr(:call): ===, getfield, setfield!, setglobal!, tuple, isa, typeassert, not_int, throw"),
    ("kernel/lib/ast.dart", "Throw") => ("NirCall", "a builtin or intrinsic call Julia's IR keeps as Expr(:call): ===, getfield, setfield!, setglobal!, tuple, isa, typeassert, not_int, throw"),
    ("kernel/lib/ast.dart", "ConstructorInvocation") => ("NirNew", "an allocation, Expr(:new): a struct, or a closure's struct of its captures"),
    ("kernel/lib/ast.dart", "FunctionExpression") => ("NirNew", "an allocation, Expr(:new): a struct, or a closure's struct of its captures"),
    ("kernel/lib/ast.dart", "FunctionDeclaration") => ("NirNew", "an allocation, Expr(:new): a struct, or a closure's struct of its captures"),
    ("kernel/lib/ast.dart", "StaticGet") => ("NirGlobalRead", "a read of a module binding"),
    ("kernel/lib/ast.dart", "StaticTearOff") => ("NirGlobal", "a function's binding as an operand, its GlobalRef"),
    ("kernel/lib/ast.dart", "VariableGet") => ("Union{NirSSA,NirArgument}", "a local's read is a statement's value or an argument"),
    ("kernel/lib/ast.dart", "ThisExpression") => ("NirArgument", "the receiver is the method's first argument"),
    ("kernel/lib/ast.dart", "IntLiteral") => ("NirConst", "a literal is a constant operand"),
    ("kernel/lib/ast.dart", "DoubleLiteral") => ("NirConst", "a literal is a constant operand"),
    ("kernel/lib/ast.dart", "BoolLiteral") => ("NirConst", "a literal is a constant operand"),
    ("kernel/lib/ast.dart", "StringLiteral") => ("NirConst", "a literal is a constant operand"),
    ("kernel/lib/ast.dart", "NullLiteral") => ("NirConst", "a literal is a constant operand"),
    ("kernel/lib/ast.dart", "ConstantExpression") => ("NirConst", "a literal is a constant operand"),
    ("kernel/lib/ast.dart", "TypeLiteral") => ("NirConst", "a literal is a constant operand"),
    ("kernel/lib/ast.dart", "DynamicInvocation") => ("NoCounterpart", "no counterpart: outside the strict subset, Julia's trim verifier rejects a dynamic call (D32)"),
    ("kernel/lib/ast.dart", "DynamicGet") => ("NoCounterpart", "no counterpart: outside the strict subset, Julia's trim verifier rejects a dynamic call (D32)"),
    ("kernel/lib/ast.dart", "DynamicSet") => ("NoCounterpart", "no counterpart: outside the strict subset, Julia's trim verifier rejects a dynamic call (D32)"),
    ("kernel/lib/ast.dart", "VariableSet") => ("NoCounterpart", "no counterpart: Julia's optimized IR is SSA, a variable is never assigned"),
    ("kernel/lib/ast.dart", "InstanceTearOff") => ("NoCounterpart", "no counterpart: a Julia method is bound to no instance"),
    ("kernel/lib/ast.dart", "Let") => ("NoCounterpart", "no counterpart: Julia's lowering flattens it into statements, branches and phis"),
    ("kernel/lib/ast.dart", "BlockExpression") => ("NoCounterpart", "no counterpart: Julia's lowering flattens it into statements, branches and phis"),
    ("kernel/lib/ast.dart", "LogicalExpression") => ("NoCounterpart", "no counterpart: Julia's lowering flattens it into statements, branches and phis"),
    ("kernel/lib/ast.dart", "ConditionalExpression") => ("NoCounterpart", "no counterpart: Julia's lowering flattens it into statements, branches and phis"),
    ("kernel/lib/ast.dart", "FileUriExpression") => ("NoCounterpart", "no counterpart: Julia's lowering flattens it into statements, branches and phis"),
    ("kernel/lib/ast.dart", "IfStatement") => ("planned: 1.D stackifier regions", "a structured statement is a structured region of the stackifier (LLVM CFGStackify's port, wt3-stackify) over Julia's CFG, dart's visitor ported over it 1:1; the region types are to come (the lead's ruling, A46S1)"),
    ("kernel/lib/ast.dart", "ReturnStatement") => ("NirReturn", "a return is Julia's ReturnNode"),
    ("kernel/lib/ast.dart", "BreakStatement") => ("planned: 1.D stackifier regions", "a structured statement is a structured region of the stackifier (LLVM CFGStackify's port, wt3-stackify) over Julia's CFG, dart's visitor ported over it 1:1; the region types are to come (the lead's ruling, A46S1)"),
    ("kernel/lib/ast.dart", "ContinueSwitchStatement") => ("planned: 1.D stackifier regions", "a structured statement is a structured region of the stackifier (LLVM CFGStackify's port, wt3-stackify) over Julia's CFG, dart's visitor ported over it 1:1; the region types are to come (the lead's ruling, A46S1)"),
    ("kernel/lib/ast.dart", "TryCatch") => ("planned: 1.D stackifier regions", "a structured statement is a structured region of the stackifier (LLVM CFGStackify's port, wt3-stackify) over Julia's CFG, dart's visitor ported over it 1:1; the region types are to come (the lead's ruling, A46S1)"),
    ("kernel/lib/ast.dart", "TryFinally") => ("planned: 1.D stackifier regions", "a structured statement is a structured region of the stackifier (LLVM CFGStackify's port, wt3-stackify) over Julia's CFG, dart's visitor ported over it 1:1; the region types are to come (the lead's ruling, A46S1)"),
    ("kernel/lib/ast.dart", "Block") => ("planned: 1.D stackifier regions", "a structured statement is a structured region of the stackifier (LLVM CFGStackify's port, wt3-stackify) over Julia's CFG, dart's visitor ported over it 1:1; the region types are to come (the lead's ruling, A46S1)"),
    ("kernel/lib/ast.dart", "EmptyStatement") => ("NirNothing", "an empty statement is the statement Julia's optimizer left as nothing"),
    ("kernel/lib/ast.dart", "ExpressionStatement") => ("NirStmt", "an expression evaluated for its effect is a statement of Julia's optimized IR"),
    ("kernel/lib/ast.dart", "LabeledStatement") => ("planned: 1.D stackifier regions", "a structured statement is a structured region of the stackifier (LLVM CFGStackify's port, wt3-stackify) over Julia's CFG, dart's visitor ported over it 1:1; the region types are to come (the lead's ruling, A46S1)"),
    ("kernel/lib/ast.dart", "WhileStatement") => ("planned: 1.D stackifier regions", "a structured statement is a structured region of the stackifier (LLVM CFGStackify's port, wt3-stackify) over Julia's CFG, dart's visitor ported over it 1:1; the region types are to come (the lead's ruling, A46S1)"),
    ("kernel/lib/ast.dart", "DoStatement") => ("planned: 1.D stackifier regions", "a structured statement is a structured region of the stackifier (LLVM CFGStackify's port, wt3-stackify) over Julia's CFG, dart's visitor ported over it 1:1; the region types are to come (the lead's ruling, A46S1)"),
    ("kernel/lib/ast.dart", "ForStatement") => ("planned: 1.D stackifier regions", "a structured statement is a structured region of the stackifier (LLVM CFGStackify's port, wt3-stackify) over Julia's CFG, dart's visitor ported over it 1:1; the region types are to come (the lead's ruling, A46S1)"),
    ("kernel/lib/ast.dart", "ForInStatement") => ("NoCounterpart", "no counterpart: Julia's IR is a flat statement list, structured control flow its GotoNode and GotoIfNot"),
    ("kernel/lib/ast.dart", "SwitchStatement") => ("planned: 1.D stackifier regions", "a structured statement is a structured region of the stackifier (LLVM CFGStackify's port, wt3-stackify) over Julia's CFG, dart's visitor ported over it 1:1; the region types are to come (the lead's ruling, A46S1)"),
    ("kernel/lib/ast.dart", "SwitchCase") => ("NoCounterpart", "no counterpart: Julia's IR is a flat statement list, structured control flow its GotoNode and GotoIfNot"),
    ("kernel/lib/ast.dart", "PatternSwitchStatement") => ("NoCounterpart", "no counterpart: Julia's IR is a flat statement list, structured control flow its GotoNode and GotoIfNot"),
    ("kernel/lib/ast.dart", "PatternVariableDeclaration") => ("NoCounterpart", "no counterpart: Julia's IR is a flat statement list, structured control flow its GotoNode and GotoIfNot"),
    ("kernel/lib/ast.dart", "IfCaseStatement") => ("NoCounterpart", "no counterpart: Julia's IR is a flat statement list, structured control flow its GotoNode and GotoIfNot"),
    ("kernel/lib/ast.dart", "AssertStatement") => ("NoCounterpart", "no counterpart: Julia's IR is a flat statement list, structured control flow its GotoNode and GotoIfNot"),
    ("kernel/lib/ast.dart", "AssertBlock") => ("NoCounterpart", "no counterpart: Julia's IR is a flat statement list, structured control flow its GotoNode and GotoIfNot"),
    ("kernel/lib/ast.dart", "AuxiliaryStatement") => ("NoCounterpart", "no counterpart: Julia's IR is a flat statement list, structured control flow its GotoNode and GotoIfNot"),
    ("kernel/lib/ast.dart", "FieldInitializer") => ("NoCounterpart", "no counterpart: a Julia inner constructor has no initializer list; its new() is NirNew"),
    ("kernel/lib/ast.dart", "SuperInitializer") => ("NoCounterpart", "no counterpart: a Julia inner constructor has no initializer list; its new() is NirNew"),
    ("kernel/lib/ast.dart", "RedirectingInitializer") => ("NoCounterpart", "no counterpart: a Julia inner constructor has no initializer list; its new() is NirNew"),
    ("kernel/lib/ast.dart", "LocalInitializer") => ("NoCounterpart", "no counterpart: a Julia inner constructor has no initializer list; its new() is NirNew"),
    ("kernel/lib/ast.dart", "AssertInitializer") => ("NoCounterpart", "no counterpart: a Julia inner constructor has no initializer list; its new() is NirNew"),
    ("kernel/lib/ast.dart", "InvalidInitializer") => ("NoCounterpart", "no counterpart: a Julia inner constructor has no initializer list; its new() is NirNew"),
    ("kernel/lib/ast.dart", "AuxiliaryInitializer") => ("NoCounterpart", "no counterpart: a Julia inner constructor has no initializer list; its new() is NirNew"),
    ("kernel/lib/core_types.dart", "CoreTypes") => ("NoCounterpart", "no counterpart: a port names Julia's types directly (the lead's ruling)"),
    ("kernel/lib/class_hierarchy.dart", "ClassHierarchy") => ("NoCounterpart", "no counterpart: Julia's supertype and subtyping answer it"),
    ("kernel/lib/type_environment.dart", "StaticTypeContext") => ("NoCounterpart", "no counterpart: Julia's inference typed every statement"),
    ("kernel/lib/target/targets.dart", "Target") => ("NoCounterpart", "no counterpart: the front end's plumbing; WT is a library and rejects with reject!"),
    ("kernel/lib/target/targets.dart", "ConstantsBackend") => ("NoCounterpart", "no counterpart: the front end's plumbing; WT is a library and rejects with reject!"),
    ("kernel/lib/verifier.dart", "Verification") => ("NoCounterpart", "no counterpart: Julia's trim verifier is the verifier (src/julia/subset.jl)"),
    ("kernel/lib/src/printer.dart", "AstPrinter") => ("NoCounterpart", "no counterpart: Kernel's printer"),
    ("kernel/lib/visitor.dart", "Visitor") => ("NoCounterpart", "no counterpart: Julia dispatches on the node's type, so a visitor is a function's methods and a supertype of none"),
    ("kernel/lib/visitor.dart", "VisitorDefault") => ("NoCounterpart", "no counterpart: Julia dispatches on the node's type, so a visitor is a function's methods and a supertype of none"),
    ("kernel/lib/visitor.dart", "RecursiveVisitor") => ("NoCounterpart", "no counterpart: Julia dispatches on the node's type, so a visitor is a function's methods and a supertype of none"),
    ("kernel/lib/visitor.dart", "ConstantVisitor") => ("NoCounterpart", "no counterpart: Julia dispatches on the node's type, so a visitor is a function's methods and a supertype of none"),
    ("kernel/lib/visitor.dart", "MemberVisitor1") => ("NoCounterpart", "no counterpart: Julia dispatches on the node's type, so a visitor is a function's methods and a supertype of none"),
    ("kernel/lib/visitor.dart", "ExpressionVisitor1") => ("NoCounterpart", "no counterpart: Julia dispatches on the node's type, so a visitor is a function's methods and a supertype of none"),
    ("vm/lib/metadata/inferred_type.dart", "InferredType") => ("Type", "the global type flow analysis' type is Julia's inferred type"),
    ("vm/lib/metadata/unreachable.dart", "UnreachableNodeMetadataRepository") => ("NoCounterpart", "no counterpart: Julia's IR marks unreachable code itself (NirUnreachable)"),
    ("front_end/lib/src/api_prototype/file_system.dart", "FileSystem") => ("NoCounterpart", "no counterpart: the front end's input"),
    ("dart2wasm/lib/io_util.dart", "CompilerPhaseInputOutputManager") => ("NoCounterpart", "no counterpart: the command-line driver's files; WT is a library"),

)

# Two rows a port spells by their Kernel names (param_info.dart's default values, types.dart's
# substitution tables), bound here, the table's file, so the table is the one place they are named.

"""Kernel's `Constant`: the NIR's literal, `NirConst` (KERNEL_TYPES' row)."""
@quarantine "Kernel's Constant is the NIR's literal; the Kernel table's row, by its Kernel name" WasmTarget.NirConst const Constant = NirConst

"""Kernel's `InstanceConstant`: a `NirConst` of an object that is no other kind's value (KERNEL_TYPES' row)."""
@quarantine "Kernel's InstanceConstant is the NIR's literal of an object; the Kernel table's row, by its Kernel name" WasmTarget.NirConst const InstanceConstant = NirConst
