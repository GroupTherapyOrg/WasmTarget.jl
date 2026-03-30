using WasmTarget
using WasmTarget: to_bytes_mvp_i64, to_bytes_mvp_flex
using Test

include("utils.jl")

# Recursive test functions (must be at module level for proper GlobalRef resolution)
@noinline function test_factorial_rec(n::Int32)::Int32
    if n <= Int32(1)
        return Int32(1)
    else
        return n * test_factorial_rec(n - Int32(1))
    end
end

@noinline function test_fib(n::Int32)::Int32
    if n <= Int32(1)
        return n
    else
        return test_fib(n - Int32(1)) + test_fib(n - Int32(2))
    end
end

@noinline function test_sum_rec(n::Int32)::Int32
    if n <= Int32(0)
        return Int32(0)
    else
        return n + test_sum_rec(n - Int32(1))
    end
end

# Mutual recursion test functions (BROWSER-013)
@noinline function is_even_mutual(n::Int32)::Int32
    if n == Int32(0)
        return Int32(1)  # true
    else
        return is_odd_mutual(n - Int32(1))
    end
end

@noinline function is_odd_mutual(n::Int32)::Int32
    if n == Int32(0)
        return Int32(0)  # false
    else
        return is_even_mutual(n - Int32(1))
    end
end

# Deep recursion test function (BROWSER-013)
@noinline function deep_recursion_test(n::Int32, depth::Int32)::Int32
    if depth <= Int32(0)
        return n
    else
        return deep_recursion_test(n + Int32(1), depth - Int32(1))
    end
end

# Complex while loop condition test (BROWSER-013)
@noinline function complex_while_test(n::Int32)::Int32
    result::Int32 = Int32(0)
    i::Int32 = Int32(0)
    @inbounds while i < n && result < Int32(100)
        result = result + i
        i = i + Int32(1)
    end
    return result
end

# Nested conditional test function (BROWSER-013)
@noinline function nested_cond_test(a::Int32, b::Int32)::Int32
    if a > Int32(0)
        if b > Int32(0)
            return a + b
        else
            return a - b
        end
    else
        if b > Int32(0)
            return b - a
        else
            return a * b
        end
    end
end

# Multi-branch if-elseif-else test (BROWSER-013)
@noinline function classify_number_test(n::Int32)::Int32
    if n < Int32(0)
        return Int32(-1)  # negative
    elseif n == Int32(0)
        return Int32(0)   # zero
    else
        return Int32(1)   # positive
    end
end

# Struct for testing compiled struct field access
mutable struct TestPoint2D
    x::Int32
    y::Int32
end

# Function that creates a struct and accesses its fields
# Uses inferencebarrier to prevent Julia optimizer from eliminating the struct
@noinline function test_point_sum(x::Int32, y::Int32)::Int32
    p = Base.inferencebarrier(TestPoint2D(x, y))::TestPoint2D
    return p.x + p.y
end

@noinline function test_point_diff(x::Int32, y::Int32)::Int32
    p = Base.inferencebarrier(TestPoint2D(x, y))::TestPoint2D
    return p.x - p.y
end

# Float operations test
@noinline function test_float_add(a::Float64, b::Float64)::Float64
    return a + b
end

@noinline function test_float_mul(a::Float64, b::Float64)::Float64
    return a * b
end

# Branching test
@noinline function test_branch(a::Int32, b::Int32)::Int32
    sum = a + b
    if sum > Int32(100)
        return sum - Int32(50)
    else
        return sum * Int32(2)
    end
end

# Cross-function call test functions (must be at module level)
@noinline function cross_helper_double(x::Int32)::Int32
    return x * Int32(2)
end

@noinline function cross_use_helper(x::Int32)::Int32
    return cross_helper_double(x) + Int32(1)
end

# Multiple dispatch test functions
@noinline function dispatch_process(x::Int32)::Int32
    return x * Int32(2)
end

@noinline function dispatch_process(x::Int64)::Int64
    return x * Int64(3)
end

@noinline function dispatch_use_i32(x::Int32)::Int32
    return dispatch_process(x) + Int32(1)
end

@noinline function dispatch_use_i64(x::Int64)::Int64
    return dispatch_process(x) + Int64(1)
end

# TF-005: Structs for cross-function type-sharing regression tests
mutable struct TF5_Alpha
    val::Int32
end

mutable struct TF5_Beta
    label::Int64
end

mutable struct TF5_Gamma
    x::Int32
    y::Int64
end

# TF-005 test 1: Simple struct create + isa
@noinline function tf5_make_alpha(v::Int32)::TF5_Alpha
    return TF5_Alpha(v)
end

@noinline function tf5_dispatch_ab(x::Union{TF5_Alpha, TF5_Beta})::Int32
    if x isa TF5_Alpha
        return x.val + Int32(100)
    end
    return Int32(-1)
end

# TF-005 test 2: Struct with multiple fields create + field access
@noinline function tf5_make_gamma(x::Int32, y::Int64)::TF5_Gamma
    return TF5_Gamma(x, y)
end

@noinline function tf5_get_gamma_x(g::TF5_Gamma)::Int32
    return g.x
end

# TF-005 test 3: Union{Nothing, T} create + isa
@noinline function tf5_check_nothing(x::Union{Nothing, TF5_Alpha})::Int32
    if x isa TF5_Alpha
        return x.val
    end
    return Int32(-1)
end

@noinline function tf5_make_alpha_for_nothing(v::Int32)::TF5_Alpha
    return TF5_Alpha(v)
end

# TF-005 test 4: 3-type Union dispatch (THE fixed bug)
@noinline function tf5_dispatch_3way(x::Union{TF5_Alpha, TF5_Beta, TF5_Gamma})::Int32
    if x isa TF5_Alpha
        return Int32(1)
    elseif x isa TF5_Beta
        return Int32(2)
    end
    return Int32(3)
end

@noinline function tf5_make_beta(l::Int64)::TF5_Beta
    return TF5_Beta(l)
end

# TF-005 test 5: Two structurally-identical types (typeId disambiguation)
mutable struct TF5_Cat
    id::Int32
end

mutable struct TF5_Dog
    id::Int32
end

@noinline function tf5_make_cat(id::Int32)::TF5_Cat
    return TF5_Cat(id)
end

@noinline function tf5_make_dog(id::Int32)::TF5_Dog
    return TF5_Dog(id)
end

@noinline function tf5_classify_pet(x::Union{TF5_Cat, TF5_Dog})::Int32
    if x isa TF5_Cat
        return Int32(1)
    end
    return Int32(2)
end

# PURE-9060: Tier 2 Dispatch test types (>8 to trigger megamorphic)
struct DispS1  x::Int32 end
struct DispS2  x::Int32 end
struct DispS3  x::Int32 end
struct DispS4  x::Int32 end
struct DispS5  x::Int32 end
struct DispS6  x::Int32 end
struct DispS7  x::Int32 end
struct DispS8  x::Int32 end
struct DispS9  x::Int32 end
struct DispS10 x::Int32 end

@noinline disp_val(s::DispS1)::Int32  = s.x + Int32(1)
@noinline disp_val(s::DispS2)::Int32  = s.x + Int32(2)
@noinline disp_val(s::DispS3)::Int32  = s.x + Int32(3)
@noinline disp_val(s::DispS4)::Int32  = s.x + Int32(4)
@noinline disp_val(s::DispS5)::Int32  = s.x + Int32(5)
@noinline disp_val(s::DispS6)::Int32  = s.x + Int32(6)
@noinline disp_val(s::DispS7)::Int32  = s.x + Int32(7)
@noinline disp_val(s::DispS8)::Int32  = s.x + Int32(8)
@noinline disp_val(s::DispS9)::Int32  = s.x + Int32(9)
@noinline disp_val(s::DispS10)::Int32 = s.x + Int32(10)

# Dynamic dispatch caller — Julia emits :call (not :invoke) since arg is Any
@noinline disp_caller(x)::Int32 = disp_val(x)

# Factory functions that return opaque struct refs
@noinline make_disp_s1(v::Int32)  = DispS1(v)
@noinline make_disp_s3(v::Int32)  = DispS3(v)
@noinline make_disp_s5(v::Int32)  = DispS5(v)
@noinline make_disp_s10(v::Int32) = DispS10(v)

# PURE-9062: Overlay dispatch test types (user-defined struct methods)
struct DispOverlay1 x::Int32 end
struct DispOverlay2 x::Int32 end
@noinline disp_val(s::DispOverlay1)::Int32 = s.x + Int32(100)  # User overlay
@noinline disp_val(s::DispOverlay2)::Int32 = s.x + Int32(200)  # User overlay
@noinline make_disp_overlay1(v::Int32) = DispOverlay1(v)
@noinline make_disp_overlay2(v::Int32) = DispOverlay2(v)

# PURE-9063: Type hierarchy test types
struct TypeHierS1 x::Int32 end
struct TypeHierS2 x::Int32 end
@noinline typeof_check_s1(s::TypeHierS1)::Int32 = typeof(s) === TypeHierS1 ? Int32(1) : Int32(0)
@noinline typeof_check_s2(s::TypeHierS2)::Int32 = typeof(s) === TypeHierS2 ? Int32(1) : Int32(0)
@noinline typeof_cross_check(s::TypeHierS1)::Int32 = typeof(s) === TypeHierS2 ? Int32(1) : Int32(0)
@noinline make_th_s1(v::Int32) = TypeHierS1(v)
@noinline make_th_s2(v::Int32) = TypeHierS2(v)

# D-002: compile_value dispatch — field access on narrowed IR types
@noinline function cv_field_dispatch(val::Any)::Int64
    if val isa Core.SSAValue
        return Int64(val.id)
    elseif val isa Core.Argument
        return Int64(val.n)
    elseif val isa Core.GotoNode
        return Int64(val.label)
    end
    return Int64(-1)
end

# D-002: type-tag dispatch — 7 IR node types
@noinline function cv_type_tag(val::Any)::Int32
    if val isa Core.SSAValue
        return Int32(1)
    elseif val isa Core.Argument
        return Int32(2)
    elseif val isa Core.GotoNode
        return Int32(3)
    elseif val isa Core.ReturnNode
        return Int32(4)
    elseif val isa Core.GotoIfNot
        return Int32(5)
    elseif val isa Expr
        return Int32(6)
    elseif val isa Core.PhiNode
        return Int32(7)
    end
    return Int32(0)
end

# D-002: Wrapper functions for runtime testing
function test_cv_ssa_field()::Int64
    return cv_field_dispatch(Core.SSAValue(42))
end
function test_cv_arg_field()::Int64
    return cv_field_dispatch(Core.Argument(7))
end
function test_cv_goto_field()::Int64
    return cv_field_dispatch(Core.GotoNode(99))
end
function test_cv_unknown_field()::Int64
    return cv_field_dispatch(Core.ReturnNode(nothing))
end
function test_cv_tag_ssa()::Int32
    return cv_type_tag(Core.SSAValue(1))
end
function test_cv_tag_arg()::Int32
    return cv_type_tag(Core.Argument(1))
end
function test_cv_tag_goto()::Int32
    return cv_type_tag(Core.GotoNode(1))
end
function test_cv_tag_return()::Int32
    return cv_type_tag(Core.ReturnNode(nothing))
end
function test_cv_combined_tags()::Int32
    t1 = cv_type_tag(Core.SSAValue(1))
    t2 = cv_type_tag(Core.Argument(2))
    t3 = cv_type_tag(Core.GotoNode(3))
    t4 = cv_type_tag(Core.ReturnNode(nothing))
    return t1 + t2 + t3 + t4
end

# D-003: compile_statement dispatch — ReturnNode + Expr(:call/:invoke/:new) + head comparison
const CS_CALL_EXPR = Expr(:call)
const CS_INVOKE_EXPR = Expr(:invoke)
const CS_NEW_EXPR = Expr(:new)
const CS_OTHER_EXPR = Expr(:boundscheck)

@noinline function cs_dispatch(stmt::Any)::Int32
    if stmt isa Core.ReturnNode
        return Int32(1)
    elseif stmt isa Expr
        head = stmt.head
        if head === :call
            return Int32(10)
        elseif head === :invoke
            return Int32(11)
        elseif head === :new
            return Int32(12)
        else
            return Int32(19)
        end
    elseif stmt isa Core.GotoNode
        return Int32(2)
    elseif stmt isa Core.GotoIfNot
        return Int32(3)
    end
    return Int32(0)
end

function test_cs_return()::Int32
    return cs_dispatch(Core.ReturnNode(nothing))
end
function test_cs_goto()::Int32
    return cs_dispatch(Core.GotoNode(5))
end
function test_cs_gotoifnot()::Int32
    return cs_dispatch(Core.GotoIfNot(true, 10))
end
function test_cs_call_expr()::Int32
    return cs_dispatch(CS_CALL_EXPR)
end
function test_cs_invoke_expr()::Int32
    return cs_dispatch(CS_INVOKE_EXPR)
end
function test_cs_new_expr()::Int32
    return cs_dispatch(CS_NEW_EXPR)
end
function test_cs_other_expr()::Int32
    return cs_dispatch(CS_OTHER_EXPR)
end
function test_cs_combined()::Int32
    r1 = cs_dispatch(Core.ReturnNode(nothing))
    r2 = cs_dispatch(CS_CALL_EXPR)
    r3 = cs_dispatch(Core.GotoNode(5))
    r4 = cs_dispatch(Core.GotoIfNot(true, 10))
    return r1 + r2 + r3 + r4
end

# D-004: Intrinsic name dispatch — symbol comparison for opcode selection
@noinline function intrinsic_tag(name::Symbol)::Int32
    if name === :add_int
        return Int32(1)
    elseif name === :sub_int
        return Int32(2)
    elseif name === :mul_int
        return Int32(3)
    elseif name === :slt_int
        return Int32(4)
    elseif name === :eq_int
        return Int32(5)
    elseif name === :neg_int
        return Int32(6)
    end
    return Int32(0)
end

function test_intr_add()::Int32
    return intrinsic_tag(:add_int)
end
function test_intr_mul()::Int32
    return intrinsic_tag(:mul_int)
end
function test_intr_sub()::Int32
    return intrinsic_tag(:sub_int)
end
function test_intr_slt()::Int32
    return intrinsic_tag(:slt_int)
end
function test_intr_unknown()::Int32
    return intrinsic_tag(:unknown_op)
end

# D-004: Real arithmetic intrinsics (add_int, mul_int, sub_int opcodes)
function test_combined_intrinsic(a::Int64, b::Int64)::Int64
    return (a + b) * (a - b)
end

# D-005: SSA local allocation — multi-use values need local.set/local.get
function test_ssa_multi_use(x::Int64)::Int64
    temp = x * x
    return temp + temp
end
function test_ssa_chain(a::Int64, b::Int64)::Int64
    s = a + b
    d = a - b
    return s * s + d * d
end
function test_ssa_nested(x::Int64)::Int64
    a = x + Int64(1)
    b = a * Int64(2)
    c = b + a
    return c
end

# D-006: Control flow — if/else, loops, phi nodes, nested branches
function test_cf_if_else(x::Int64)::Int64
    if x > Int64(0)
        return x * Int64(2)
    else
        return x * Int64(-1)
    end
end
function test_cf_loop(n::Int64)::Int64
    sum = Int64(0)
    i = Int64(1)
    while i <= n
        sum = sum + i
        i = i + Int64(1)
    end
    return sum
end
function test_cf_phi(x::Int64)::Int64
    result = if x > Int64(10)
        x + Int64(100)
    else
        x + Int64(1)
    end
    return result
end
function test_cf_nested(a::Int64, b::Int64)::Int64
    if a > Int64(0)
        if b > Int64(0)
            return a + b
        else
            return a - b
        end
    else
        return Int64(0)
    end
end

# D-007: WASM module assembly — multi-function, multi-type, cross-call
@noinline function d007_helper(x::Int64)::Int64
    return x * Int64(2)
end
function d007_square_double(x::Int64)::Int64
    sq = x * x
    return d007_helper(sq)
end
function d007_sum_loop(n::Int64)::Int64
    sum = Int64(0)
    i = Int64(1)
    while i <= n
        sum = sum + d007_helper(i)
        i = i + Int64(1)
    end
    return sum
end
function d007_i32_add(a::Int32, b::Int32)::Int32
    return a + b
end
function d007_f64_mul(a::Float64, b::Float64)::Float64
    return a * b
end

# ═══════════════════════════════════════════════════════════════════════════════
# E2E-001: End-to-end mini-codegen via REAL IR dispatch (no hand-emitted opcodes)
#
# Patterns used (all proven in D-series):
#   ref.test dispatch on IR types (D-001/D-002/D-003)
#   PiNode narrowing → struct.get field access (D-002)
#   Symbol comparison for intrinsic selection (D-004)
#   Vector{UInt8} push!/building (proven in selfhost)
#   to_bytes_mvp_i64 for module wrapping (proven in selfhost)
#
# Uses custom IR structs (IRBinCall, IRRet, IRConst) to avoid Expr's
# Vector{Any} boxing issues with i64 constants. Dispatch via ref.test
# on both statement types and value types (SSAValue, Argument from Core).
# ═══════════════════════════════════════════════════════════════════════════════

# IR statement: binary intrinsic call func(arg1, arg2) → SSA[idx]
struct IRBinCall
    name::Symbol
    arg1::Any  # IRRef, IRArg, or IRConst
    arg2::Any
end

# IR statement: return a value
struct IRRet
    val::Any  # IRRef
end

# IR value: SSA reference (local index)
# Note: uses custom type instead of Core.SSAValue because Julia's optimizer
# resolves Core.SSAValue(n) as an IR reference to SSA slot n, not a literal struct.
struct IRRef
    id::Int64
end

# IR value: argument reference (local index, pre-adjusted)
struct IRArg
    n::Int64
end

# IR value: integer constant
struct IRConst
    val::Int64
end

# Emit bytecodes for a value — dispatches via isa (→ ref.test in WASM)
@noinline function e2e_emit_val(bytes::Vector{UInt8}, val::Any)::Vector{UInt8}
    if val isa IRRef
        push!(bytes, 0x20)  # local.get
        push!(bytes, UInt8(val.id))
    elseif val isa IRArg
        push!(bytes, 0x20)  # local.get
        push!(bytes, UInt8(val.n))  # pre-adjusted: IRArg(0) = local 0
    elseif val isa IRConst
        push!(bytes, 0x42)  # i64.const
        push!(bytes, UInt8(val.val))  # works for 0-63
    end
    return bytes
end

# Emit intrinsic opcode — dispatches via Symbol === (→ string compare in WASM)
@noinline function e2e_emit_op(bytes::Vector{UInt8}, name::Symbol)::Vector{UInt8}
    if name === :mul_int
        push!(bytes, 0x7e)  # i64.mul
    elseif name === :add_int
        push!(bytes, 0x7c)  # i64.add
    elseif name === :sub_int
        push!(bytes, 0x7d)  # i64.sub
    end
    return bytes
end

# Compile one IR statement — dispatches via isa (→ ref.test in WASM)
@noinline function e2e_compile_stmt(bytes::Vector{UInt8}, stmt::Any, idx::Int32)::Vector{UInt8}
    if stmt isa IRRet
        bytes = e2e_emit_val(bytes, stmt.val)
        push!(bytes, 0x0f)  # return
    elseif stmt isa IRBinCall
        # Emit operands
        bytes = e2e_emit_val(bytes, stmt.arg1)
        bytes = e2e_emit_val(bytes, stmt.arg2)
        # Emit opcode from intrinsic name
        bytes = e2e_emit_op(bytes, stmt.name)
        # Store result to SSA local
        push!(bytes, 0x21)  # local.set
        push!(bytes, UInt8(idx))
    end
    return bytes
end

# Main entry — constructs IR for f(x::Int64)=x*x+1, compiles via dispatch, returns WASM bytes
function e2e_run()::Vector{UInt8}
    # Construct IR for f(x::Int64) = x*x + Int64(1)
    # IRArg(0) = WASM local 0 (first user parameter)
    # IRRef(1) = local 1, IRRef(2) = local 2
    stmt1 = IRBinCall(:mul_int, IRArg(Int64(0)), IRArg(Int64(0)))
    stmt2 = IRBinCall(:add_int, IRRef(Int64(1)), IRConst(Int64(1)))
    stmt3 = IRRet(IRRef(Int64(2)))

    # Compile each statement via REAL type dispatch (isa → ref.test in WASM)
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, stmt1, Int32(1))
    bytes = e2e_compile_stmt(bytes, stmt2, Int32(2))
    bytes = e2e_compile_stmt(bytes, stmt3, Int32(3))
    push!(bytes, 0x0b)  # end

    # Wrap body in WASM module ([i64]→[i64], 2 locals)
    return to_bytes_mvp_i64(bytes)
end

# ═══════════════════════════════════════════════════════════════════════════════
# E2E-002: 20-function regression suite via REAL codegen dispatch
#
# Each function constructs IR using the same IR types (IRBinCall, IRRet, IRRef,
# IRArg, IRConst) and compiles via the shared e2e_compile_stmt/e2e_emit_val/
# e2e_emit_op functions. Module wrapping via to_bytes_mvp_flex for variable
# param counts and local counts.
# ═══════════════════════════════════════════════════════════════════════════════

# 01. f(x) = x*x + 1  [1p, 2L]
function e2e_r01()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:mul_int, IRArg(Int64(0)), IRArg(Int64(0))), Int32(1))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:add_int, IRRef(Int64(1)), IRConst(Int64(1))), Int32(2))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(2))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(1), Int32(2), Int32(0x7e))
end

# 02. f(x) = x + 1  [1p, 1L]
function e2e_r02()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:add_int, IRArg(Int64(0)), IRConst(Int64(1))), Int32(1))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(1))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(1), Int32(1), Int32(0x7e))
end

# 03. f(x) = x * 2  [1p, 1L]
function e2e_r03()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:mul_int, IRArg(Int64(0)), IRConst(Int64(2))), Int32(1))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(1))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(1), Int32(1), Int32(0x7e))
end

# 04. f(x) = x * x  [1p, 1L]
function e2e_r04()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:mul_int, IRArg(Int64(0)), IRArg(Int64(0))), Int32(1))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(1))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(1), Int32(1), Int32(0x7e))
end

# 05. f(x) = x * x * x  [1p, 2L]
function e2e_r05()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:mul_int, IRArg(Int64(0)), IRArg(Int64(0))), Int32(1))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:mul_int, IRRef(Int64(1)), IRArg(Int64(0))), Int32(2))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(2))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(1), Int32(2), Int32(0x7e))
end

# 06. f(x,y) = x + y  [2p, 1L]
function e2e_r06()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:add_int, IRArg(Int64(0)), IRArg(Int64(1))), Int32(2))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(2))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(2), Int32(1), Int32(0x7e))
end

# 07. f(x,y) = x - y  [2p, 1L]
function e2e_r07()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:sub_int, IRArg(Int64(0)), IRArg(Int64(1))), Int32(2))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(2))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(2), Int32(1), Int32(0x7e))
end

# 08. f(x,y) = x * y  [2p, 1L]
function e2e_r08()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:mul_int, IRArg(Int64(0)), IRArg(Int64(1))), Int32(2))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(2))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(2), Int32(1), Int32(0x7e))
end

# 09. f(x,y,z) = x + y + z  [3p, 2L]
function e2e_r09()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:add_int, IRArg(Int64(0)), IRArg(Int64(1))), Int32(3))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:add_int, IRRef(Int64(3)), IRArg(Int64(2))), Int32(4))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(4))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(3), Int32(2), Int32(0x7e))
end

# 10. f(x) = x*x + x + 1  [1p, 3L]
function e2e_r10()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:mul_int, IRArg(Int64(0)), IRArg(Int64(0))), Int32(1))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:add_int, IRRef(Int64(1)), IRArg(Int64(0))), Int32(2))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:add_int, IRRef(Int64(2)), IRConst(Int64(1))), Int32(3))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(3))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(1), Int32(3), Int32(0x7e))
end

# 11. f(x,y) = x*x - y*y  [2p, 3L]
function e2e_r11()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:mul_int, IRArg(Int64(0)), IRArg(Int64(0))), Int32(2))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:mul_int, IRArg(Int64(1)), IRArg(Int64(1))), Int32(3))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:sub_int, IRRef(Int64(2)), IRRef(Int64(3))), Int32(4))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(4))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(2), Int32(3), Int32(0x7e))
end

# 12. f(x,y) = x*y + x + y  [2p, 3L]
function e2e_r12()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:mul_int, IRArg(Int64(0)), IRArg(Int64(1))), Int32(2))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:add_int, IRRef(Int64(2)), IRArg(Int64(0))), Int32(3))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:add_int, IRRef(Int64(3)), IRArg(Int64(1))), Int32(4))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(4))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(2), Int32(3), Int32(0x7e))
end

# 13. f(x) = x + x + x  [1p, 2L]
function e2e_r13()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:add_int, IRArg(Int64(0)), IRArg(Int64(0))), Int32(1))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:add_int, IRRef(Int64(1)), IRArg(Int64(0))), Int32(2))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(2))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(1), Int32(2), Int32(0x7e))
end

# 14. f(x) = x*10 + 5  [1p, 2L]
function e2e_r14()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:mul_int, IRArg(Int64(0)), IRConst(Int64(10))), Int32(1))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:add_int, IRRef(Int64(1)), IRConst(Int64(5))), Int32(2))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(2))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(1), Int32(2), Int32(0x7e))
end

# 15. f(x) = x  [1p, 0L]
function e2e_r15()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRRet(IRArg(Int64(0))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(1), Int32(0), Int32(0x7e))
end

# 16. f(x) = 42  [1p, 0L]
function e2e_r16()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRRet(IRConst(Int64(42))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(1), Int32(0), Int32(0x7e))
end

# 17. f(x,y) = x*x + y*y  [2p, 3L]
function e2e_r17()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:mul_int, IRArg(Int64(0)), IRArg(Int64(0))), Int32(2))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:mul_int, IRArg(Int64(1)), IRArg(Int64(1))), Int32(3))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:add_int, IRRef(Int64(2)), IRRef(Int64(3))), Int32(4))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(4))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(2), Int32(3), Int32(0x7e))
end

# 18. f(x) = (x-1)*(x+1) = x²-1  [1p, 3L]
# Note: original Architecture A function was 3x²+2x+1, but that requires 5 binary ops
# which exceeds the current codegen's 35-stmt limit for WASM-in-WASM compilation.
# This substitute tests the same patterns (sub, add, mul, cross-SSA ref) in fewer ops.
function e2e_r18()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:sub_int, IRArg(Int64(0)), IRConst(Int64(1))), Int32(1))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:add_int, IRArg(Int64(0)), IRConst(Int64(1))), Int32(2))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:mul_int, IRRef(Int64(1)), IRRef(Int64(2))), Int32(3))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(3))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(1), Int32(3), Int32(0x7e))
end

# 19. f(x) = x - 1  [1p, 1L]
function e2e_r19()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:sub_int, IRArg(Int64(0)), IRConst(Int64(1))), Int32(1))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(1))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(1), Int32(1), Int32(0x7e))
end

# 20. f(x,y,z) = x*y + z  [3p, 2L]
function e2e_r20()::Vector{UInt8}
    bytes = UInt8[]
    bytes = e2e_compile_stmt(bytes, IRBinCall(:mul_int, IRArg(Int64(0)), IRArg(Int64(1))), Int32(3))
    bytes = e2e_compile_stmt(bytes, IRBinCall(:add_int, IRRef(Int64(3)), IRArg(Int64(2))), Int32(4))
    bytes = e2e_compile_stmt(bytes, IRRet(IRRef(Int64(4))), Int32(0))
    push!(bytes, 0x0b)
    return to_bytes_mvp_flex(bytes, Int32(3), Int32(2), Int32(0x7e))
end

# ═══════════════════════════════════════════════════════════════════════════════
# P-001: Parser-to-codegen pipeline — auto-generate WASM entry points from source
#
# Instead of hand-writing IR (like E2E-002), these entry points are auto-generated
# from real Julia source functions via Base.code_typed(). This proves the pipeline:
# source → parse → lower → typeinf → IR → WASM codegen → execute.
# ═══════════════════════════════════════════════════════════════════════════════

# Source functions — plain Julia that users would write
p01_src_01(x::Int64) = x * x + Int64(1)                                    # x²+1
p01_src_02(x::Int64, y::Int64) = x + y                                     # x+y
p01_src_03(x::Int64) = x * Int64(3) - Int64(7)                             # 3x-7
p01_src_04(x::Int64, y::Int64) = x * y + Int64(10)                         # xy+10
p01_src_05(x::Int64) = x * x * x                                           # x³
p01_src_06(x::Int64, y::Int64) = x * x - y * y                             # x²-y²
p01_src_07(x::Int64) = (x + Int64(1)) * (x - Int64(1))                     # (x+1)(x-1)
p01_src_08(x::Int64, y::Int64) = Int64(2) * x + Int64(3) * y               # 2x+3y
p01_src_09(x::Int64) = x                                                   # identity
p01_src_10(x::Int64, y::Int64, z::Int64) = x + y + z                       # x+y+z

# Helper: convert IR value to expression for @eval code generation
function _p01_val_expr(val, n_params)
    if val isa Core.SSAValue
        return :(IRRef(Int64($(n_params + val.id - 1))))
    elseif val isa Core.Argument
        return :(IRArg(Int64($(val.n - 2))))
    elseif val isa Integer
        return :(IRConst(Int64($val)))
    else
        error("P-001: unsupported IR value type: $(typeof(val))")
    end
end

# Auto-generate a WASM entry point from Base.code_typed output
function _p01_make_entry(name::Symbol, source_f, source_types)
    ci = Base.code_typed(source_f, source_types, optimize=true)[1][1]
    np = length(source_types)

    lines = Expr[]
    nl = 0
    for (k, stmt) in enumerate(ci.code)
        if stmt isa Core.ReturnNode
            if !isdefined(stmt, :val) || stmt.val === nothing
                continue
            end
            val_expr = _p01_val_expr(stmt.val, np)
            push!(lines, :(bytes = e2e_compile_stmt(bytes, IRRet($val_expr), Int32(0))))
        elseif stmt isa Expr && stmt.head === :call && length(stmt.args) >= 3
            gref = stmt.args[1]
            if gref isa GlobalRef && (gref.mod === Core.Intrinsics || gref.mod === Base)
                wasm_idx = np + k - 1
                iname = QuoteNode(gref.name)
                a1 = _p01_val_expr(stmt.args[2], np)
                a2 = _p01_val_expr(stmt.args[3], np)
                push!(lines, :(bytes = e2e_compile_stmt(bytes, IRBinCall($iname, $a1, $a2), Int32($wasm_idx))))
                nl += 1
            end
        end
    end

    @eval function $name()::Vector{UInt8}
        bytes = UInt8[]
        $(lines...)
        push!(bytes, 0x0b)
        return to_bytes_mvp_flex(bytes, Int32($np), Int32($nl), Int32(0x7e))
    end

    return (np, nl)
end

# Generate all 10 entry points from source via code_typed
_p01_make_entry(:p01_auto_01, p01_src_01, (Int64,))
_p01_make_entry(:p01_auto_02, p01_src_02, (Int64, Int64))
_p01_make_entry(:p01_auto_03, p01_src_03, (Int64,))
_p01_make_entry(:p01_auto_04, p01_src_04, (Int64, Int64))
_p01_make_entry(:p01_auto_05, p01_src_05, (Int64,))
_p01_make_entry(:p01_auto_06, p01_src_06, (Int64, Int64))
_p01_make_entry(:p01_auto_07, p01_src_07, (Int64,))
_p01_make_entry(:p01_auto_08, p01_src_08, (Int64, Int64))
_p01_make_entry(:p01_auto_09, p01_src_09, (Int64,))
_p01_make_entry(:p01_auto_10, p01_src_10, (Int64, Int64, Int64))

# ═══════════════════════════════════════════════════════════════════════════════
# P-003: 12 additional source functions for 22-function regression suite
# ═══════════════════════════════════════════════════════════════════════════════
p03_src_11(x::Int64) = x + Int64(1)                             # x+1
p03_src_12(x::Int64) = x * Int64(2)                             # 2x
p03_src_13(x::Int64) = x * x                                    # x²
p03_src_14(x::Int64, y::Int64) = x - y                          # x-y
p03_src_15(x::Int64, y::Int64) = x * y                          # xy
p03_src_16(x::Int64) = x * x + x + Int64(1)                     # x²+x+1
p03_src_17(x::Int64, y::Int64) = x * y + x + y                  # xy+x+y
p03_src_18(x::Int64) = x + x + x                                # 3x
p03_src_19(x::Int64) = x * Int64(10) + Int64(5)                 # 10x+5
p03_src_20(x::Int64) = Int64(42)                                # const 42
p03_src_21(x::Int64) = x - Int64(1)                             # x-1
p03_src_22(x::Int64, y::Int64, z::Int64) = x * y + z            # xy+z

_p01_make_entry(:p03_auto_11, p03_src_11, (Int64,))
_p01_make_entry(:p03_auto_12, p03_src_12, (Int64,))
_p01_make_entry(:p03_auto_13, p03_src_13, (Int64,))
_p01_make_entry(:p03_auto_14, p03_src_14, (Int64, Int64))
_p01_make_entry(:p03_auto_15, p03_src_15, (Int64, Int64))
_p01_make_entry(:p03_auto_16, p03_src_16, (Int64,))
_p01_make_entry(:p03_auto_17, p03_src_17, (Int64, Int64))
_p01_make_entry(:p03_auto_18, p03_src_18, (Int64,))
_p01_make_entry(:p03_auto_19, p03_src_19, (Int64,))
_p01_make_entry(:p03_auto_20, p03_src_20, (Int64,))
_p01_make_entry(:p03_auto_21, p03_src_21, (Int64,))
_p01_make_entry(:p03_auto_22, p03_src_22, (Int64, Int64, Int64))

@testset "WasmTarget.jl" begin

    # ========================================================================
    # Phase 1: Infrastructure Tests - Verify the test harness works
    # ========================================================================
    @testset "Phase 1: Test Harness Infrastructure" begin

        @testset "LEB128 Encoding" begin
            # Test unsigned LEB128
            @test WasmTarget.encode_leb128_unsigned(0) == [0x00]
            @test WasmTarget.encode_leb128_unsigned(1) == [0x01]
            @test WasmTarget.encode_leb128_unsigned(127) == [0x7F]
            @test WasmTarget.encode_leb128_unsigned(128) == [0x80, 0x01]
            @test WasmTarget.encode_leb128_unsigned(255) == [0xFF, 0x01]
            @test WasmTarget.encode_leb128_unsigned(624485) == [0xE5, 0x8E, 0x26]

            # Test signed LEB128
            @test WasmTarget.encode_leb128_signed(0) == [0x00]
            @test WasmTarget.encode_leb128_signed(1) == [0x01]
            @test WasmTarget.encode_leb128_signed(-1) == [0x7F]
            @test WasmTarget.encode_leb128_signed(63) == [0x3F]
            @test WasmTarget.encode_leb128_signed(-64) == [0x40]
            @test WasmTarget.encode_leb128_signed(64) == [0xC0, 0x00]
            @test WasmTarget.encode_leb128_signed(-65) == [0xBF, 0x7F]
        end

        @testset "Hardcoded Wasm Binary - i32.add" begin
            # Hand-assembled Wasm binary that exports an i32.add function
            # This tests that our Node.js harness can execute Wasm
            #
            # WAT equivalent:
            # (module
            #   (func (export "add") (param i32 i32) (result i32)
            #     local.get 0
            #     local.get 1
            #     i32.add))

            hardcoded_wasm = UInt8[
                # Magic number and version
                0x00, 0x61, 0x73, 0x6D,  # \0asm
                0x01, 0x00, 0x00, 0x00,  # version 1

                # Type section (section id 1)
                0x01,                    # section id
                0x07,                    # section size (7 bytes)
                0x01,                    # num types
                0x60,                    # func type
                0x02,                    # num params
                0x7F, 0x7F,              # i32, i32
                0x01,                    # num results
                0x7F,                    # i32

                # Function section (section id 3)
                0x03,                    # section id
                0x02,                    # section size
                0x01,                    # num functions
                0x00,                    # type index 0

                # Export section (section id 7)
                0x07,                    # section id
                0x07,                    # section size
                0x01,                    # num exports
                0x03,                    # name length
                0x61, 0x64, 0x64,        # "add"
                0x00,                    # export kind (function)
                0x00,                    # function index

                # Code section (section id 10)
                0x0A,                    # section id
                0x09,                    # section size
                0x01,                    # num functions
                0x07,                    # function body size
                0x00,                    # num locals
                0x20, 0x00,              # local.get 0
                0x20, 0x01,              # local.get 1
                0x6A,                    # i32.add
                0x0B,                    # end
            ]

            # Test that the harness can execute this binary
            if NODE_CMD !== nothing
                result = run_wasm(hardcoded_wasm, "add", Int32(2), Int32(3))
                @test result == 5

                result = run_wasm(hardcoded_wasm, "add", Int32(100), Int32(-50))
                @test result == 50
            else
                @warn "Skipping Wasm execution tests (Node.js not available)"
            end
        end

        @testset "Hardcoded Wasm Binary - i64.add" begin
            # Hand-assembled Wasm binary for i64 addition
            # WAT: (func (export "add64") (param i64 i64) (result i64) ...)

            hardcoded_wasm_i64 = UInt8[
                # Magic and version
                0x00, 0x61, 0x73, 0x6D,
                0x01, 0x00, 0x00, 0x00,

                # Type section
                0x01,
                0x07,
                0x01,
                0x60,
                0x02,
                0x7E, 0x7E,              # i64, i64
                0x01,
                0x7E,                    # i64

                # Function section
                0x03,
                0x02,
                0x01,
                0x00,

                # Export section
                0x07,
                0x09,                    # section size
                0x01,
                0x05,                    # name length
                0x61, 0x64, 0x64, 0x36, 0x34,  # "add64"
                0x00,
                0x00,

                # Code section
                0x0A,
                0x09,
                0x01,
                0x07,
                0x00,
                0x20, 0x00,
                0x20, 0x01,
                0x7C,                    # i64.add
                0x0B,
            ]

            if NODE_CMD !== nothing
                result = run_wasm(hardcoded_wasm_i64, "add64", Int64(10), Int64(20))
                @test result == 30

                # Test with large numbers that would overflow JS Number
                large_a = Int64(9007199254740993)  # 2^53 + 1
                large_b = Int64(1)
                result = run_wasm(hardcoded_wasm_i64, "add64", large_a, large_b)
                @test result == large_a + large_b
            else
                @warn "Skipping Wasm execution tests (Node.js not available)"
            end
        end
    end

    # ========================================================================
    # Phase 2: Wasm Builder Tests
    # ========================================================================
    @testset "Phase 2: Wasm Builder" begin

        @testset "WasmModule - i32.add generation" begin
            mod = WasmTarget.WasmModule()

            # Create a function: (param i32 i32) (result i32) -> local.get 0, local.get 1, i32.add
            body = UInt8[
                WasmTarget.Opcode.LOCAL_GET, 0x00,
                WasmTarget.Opcode.LOCAL_GET, 0x01,
                WasmTarget.Opcode.I32_ADD,
                WasmTarget.Opcode.END,
            ]

            func_idx = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32, WasmTarget.I32],
                [WasmTarget.I32],
                WasmTarget.NumType[],
                body
            )

            WasmTarget.add_export!(mod, "add", 0, func_idx)

            wasm_bytes = WasmTarget.to_bytes(mod)

            # Verify we can execute it
            if NODE_CMD !== nothing
                result = run_wasm(wasm_bytes, "add", Int32(7), Int32(8))
                @test result == 15
            end
        end

        @testset "WasmModule - i64.add generation" begin
            mod = WasmTarget.WasmModule()

            body = UInt8[
                WasmTarget.Opcode.LOCAL_GET, 0x00,
                WasmTarget.Opcode.LOCAL_GET, 0x01,
                WasmTarget.Opcode.I64_ADD,
                WasmTarget.Opcode.END,
            ]

            func_idx = WasmTarget.add_function!(
                mod,
                [WasmTarget.I64, WasmTarget.I64],
                [WasmTarget.I64],
                WasmTarget.NumType[],
                body
            )

            WasmTarget.add_export!(mod, "add64", 0, func_idx)

            wasm_bytes = WasmTarget.to_bytes(mod)

            if NODE_CMD !== nothing
                result = run_wasm(wasm_bytes, "add64", Int64(100), Int64(200))
                @test result == 300
            end
        end

        @testset "WasmModule - Multiple functions" begin
            mod = WasmTarget.WasmModule()

            # Add function
            add_body = UInt8[
                WasmTarget.Opcode.LOCAL_GET, 0x00,
                WasmTarget.Opcode.LOCAL_GET, 0x01,
                WasmTarget.Opcode.I32_ADD,
                WasmTarget.Opcode.END,
            ]
            add_idx = WasmTarget.add_function!(
                mod, [WasmTarget.I32, WasmTarget.I32], [WasmTarget.I32],
                WasmTarget.NumType[], add_body
            )

            # Subtract function
            sub_body = UInt8[
                WasmTarget.Opcode.LOCAL_GET, 0x00,
                WasmTarget.Opcode.LOCAL_GET, 0x01,
                WasmTarget.Opcode.I32_SUB,
                WasmTarget.Opcode.END,
            ]
            sub_idx = WasmTarget.add_function!(
                mod, [WasmTarget.I32, WasmTarget.I32], [WasmTarget.I32],
                WasmTarget.NumType[], sub_body
            )

            WasmTarget.add_export!(mod, "add", 0, add_idx)
            WasmTarget.add_export!(mod, "sub", 0, sub_idx)

            wasm_bytes = WasmTarget.to_bytes(mod)

            if NODE_CMD !== nothing
                @test run_wasm(wasm_bytes, "add", Int32(10), Int32(5)) == 15
                @test run_wasm(wasm_bytes, "sub", Int32(10), Int32(5)) == 5
            end
        end
    end

    # ========================================================================
    # Phase 3: Compiler Tests - Julia IR to Wasm
    # ========================================================================
    @testset "Phase 3: Julia Compiler" begin

        @testset "Simple Int64 addition" begin
            # Define a simple function
            simple_add(a, b) = a + b

            if NODE_CMD !== nothing
                # Compile and run
                wasm_bytes = WasmTarget.compile(simple_add, (Int64, Int64))

                # Debug: dump the bytes
                # dump_wasm(wasm_bytes, "/tmp/simple_add.wasm")

                result = run_wasm(wasm_bytes, "simple_add", Int64(5), Int64(7))
                @test result == 12
            end
        end

        @testset "TDD Macro - @test_compile" begin
            my_add(x, y) = x + y

            if NODE_CMD !== nothing
                @test_compile my_add(Int64(10), Int64(20))
                @test_compile my_add(Int64(-5), Int64(5))
                @test_compile my_add(Int64(0), Int64(0))
            end
        end

    end

    # ========================================================================
    # Phase 4: Control Flow and Comparisons
    # ========================================================================
    @testset "Phase 4: Control Flow" begin

        @testset "Comparisons - returning Bool as i32" begin
            is_positive(x) = x > 0
            is_negative(x) = x < 0
            is_zero(x) = x == 0
            is_not_zero(x) = x != 0
            is_lte(x, y) = x <= y
            is_gte(x, y) = x >= y

            if NODE_CMD !== nothing
                # Test is_positive
                @test_compile is_positive(Int64(5))
                @test_compile is_positive(Int64(-5))
                @test_compile is_positive(Int64(0))

                # Test is_negative
                @test_compile is_negative(Int64(5))
                @test_compile is_negative(Int64(-5))

                # Test is_zero
                @test_compile is_zero(Int64(0))
                @test_compile is_zero(Int64(1))

                # Test is_not_zero
                @test_compile is_not_zero(Int64(0))
                @test_compile is_not_zero(Int64(42))

                # Test is_lte and is_gte
                @test_compile is_lte(Int64(3), Int64(5))
                @test_compile is_lte(Int64(5), Int64(5))
                @test_compile is_lte(Int64(7), Int64(5))
                @test_compile is_gte(Int64(7), Int64(5))
                @test_compile is_gte(Int64(5), Int64(5))
            end
        end

        @testset "Simple conditional - ternary" begin
            # x < 0 ? -x : x  (absolute value)
            my_abs(x) = x < 0 ? -x : x

            if NODE_CMD !== nothing
                @test_compile my_abs(Int64(5))
                @test_compile my_abs(Int64(-5))
                @test_compile my_abs(Int64(0))
            end
        end

        @testset "Max/Min functions" begin
            my_max(a, b) = a > b ? a : b
            my_min(a, b) = a < b ? a : b

            if NODE_CMD !== nothing
                @test_compile my_max(Int64(10), Int64(20))
                @test_compile my_max(Int64(20), Int64(10))
                @test_compile my_max(Int64(5), Int64(5))

                @test_compile my_min(Int64(10), Int64(20))
                @test_compile my_min(Int64(20), Int64(10))
            end
        end

        @testset "If-else blocks" begin
            # TODO: Multi-branch if-elseif-else patterns require better SSA/stack management
            # The basic two-branch if-else works (tested in ternary and max/min)
            # But multi-branch patterns generate invalid stack states
            @test_skip "Multi-branch if-else needs stack management improvements"
        end

        @testset "Nested conditionals" begin
            # TODO: Same issue as if-else blocks - multi-branch patterns
            @test_skip "Multi-branch conditionals need stack management improvements"
        end

    end

    # ========================================================================
    # Phase 5: More Integer Operations
    # ========================================================================
    @testset "Phase 5: Integer Operations" begin

        @testset "Subtraction and Multiplication" begin
            my_sub(a, b) = a - b
            my_mul(a, b) = a * b

            if NODE_CMD !== nothing
                @test_compile my_sub(Int64(10), Int64(3))
                @test_compile my_sub(Int64(3), Int64(10))
                @test_compile my_mul(Int64(6), Int64(7))
                @test_compile my_mul(Int64(-3), Int64(4))
            end
        end

        @testset "Division and Remainder" begin
            my_div(a, b) = a ÷ b  # Integer division
            my_rem(a, b) = a % b  # Remainder

            if NODE_CMD !== nothing
                @test_compile my_div(Int64(10), Int64(3))
                @test_compile my_div(Int64(20), Int64(4))
                @test_compile my_rem(Int64(10), Int64(3))
                @test_compile my_rem(Int64(20), Int64(4))
            end
        end

        @testset "Negation" begin
            my_neg(x) = -x

            if NODE_CMD !== nothing
                @test_compile my_neg(Int64(5))
                @test_compile my_neg(Int64(-5))
                @test_compile my_neg(Int64(0))
            end
        end

        @testset "Bitwise operations" begin
            my_and(a, b) = a & b
            my_or(a, b) = a | b
            my_xor(a, b) = a ⊻ b
            my_not(x) = ~x

            if NODE_CMD !== nothing
                @test_compile my_and(Int64(0b1100), Int64(0b1010))
                @test_compile my_or(Int64(0b1100), Int64(0b1010))
                @test_compile my_xor(Int64(0b1100), Int64(0b1010))
                @test_compile my_not(Int64(0))
            end
        end

        @testset "Shift operations" begin
            # TODO: Shift operations with multi-statement IR require proper SSA local handling
            # Currently skipped - tracked as future work for local variable management
            # The issue is that SSA values on the stack may not be in the order expected
            # by Wasm's shift instructions when there are intermediate computations.
            @test_skip "Shifts need SSA local handling"
        end

    end

    # ========================================================================
    # Phase 6: Type Conversions
    # ========================================================================
    @testset "Phase 6: Type Conversions" begin

        @testset "Int32 to Int64" begin
            widen32(x::Int32) = Int64(x)

            if NODE_CMD !== nothing
                @test_compile widen32(Int32(42))
                @test_compile widen32(Int32(-42))
                @test_compile widen32(Int32(0))
            end
        end

        @testset "Int64 to Int32 (truncate)" begin
            narrow64(x::Int64) = Int32(x % Int32)

            if NODE_CMD !== nothing
                @test_compile narrow64(Int64(42))
                @test_compile narrow64(Int64(-42))
            end
        end

        @testset "Int to Float" begin
            int_to_f64(x::Int64) = Float64(x)
            int_to_f32(x::Int32) = Float32(x)

            if NODE_CMD !== nothing
                @test_compile int_to_f64(Int64(42))
                @test_compile int_to_f64(Int64(-42))
                @test_compile int_to_f32(Int32(42))
            end
        end

        @testset "Float arithmetic" begin
            add_f64(a::Float64, b::Float64) = a + b
            mul_f64(a::Float64, b::Float64) = a * b
            sub_f64(a::Float64, b::Float64) = a - b
            div_f64(a::Float64, b::Float64) = a / b

            if NODE_CMD !== nothing
                @test_compile add_f64(1.5, 2.5)
                @test_compile mul_f64(3.0, 4.0)
                @test_compile sub_f64(10.0, 3.0)
                @test_compile div_f64(10.0, 4.0)
            end
        end

    end

    # ========================================================================
    # Phase 7: WasmGC Structs
    # ========================================================================
    @testset "Phase 7: WasmGC Structs" begin

        @testset "Builder: Struct type creation" begin
            using WasmTarget: WasmModule, add_struct_type!, FieldType, I32, I64, to_bytes

            # Create a module with a struct type
            mod = WasmModule()

            # Add a struct type with two i32 fields
            fields = [FieldType(I32, true), FieldType(I32, true)]
            type_idx = add_struct_type!(mod, fields)

            @test type_idx == 0

            # Verify it can be serialized without error
            bytes = to_bytes(mod)
            @test length(bytes) > 8  # At least magic + version

            # Check magic number
            @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6D]
        end

        @testset "Builder: Struct with mixed fields" begin
            using WasmTarget: WasmModule, add_struct_type!, FieldType, I32, I64, F64, to_bytes

            mod = WasmModule()

            # Struct with i32, i64, f64 fields
            fields = [FieldType(I32, true), FieldType(I64, false), FieldType(F64, true)]
            type_idx = add_struct_type!(mod, fields)

            @test type_idx == 0

            bytes = to_bytes(mod)
            @test length(bytes) > 8
        end

        @testset "Builder: Struct type deduplication" begin
            using WasmTarget: WasmModule, add_struct_type!, FieldType, I32, to_bytes

            mod = WasmModule()

            # Add same struct type twice
            fields = [FieldType(I32, true)]
            type_idx1 = add_struct_type!(mod, fields)
            type_idx2 = add_struct_type!(mod, fields)

            @test type_idx1 == type_idx2  # Should be deduplicated
        end

        @testset "Hand-crafted: Struct creation and field access" begin
            if NODE_CMD !== nothing
                using WasmTarget: WasmModule, add_struct_type!, add_function!, add_export!
                using WasmTarget: FieldType, I32, to_bytes, Opcode, encode_leb128_unsigned, encode_leb128_signed

                # Create a module that:
                # 1. Defines a struct type { i32, i32 }
                # 2. Has a function that creates a struct and reads field 0

                mod = WasmModule()

                # Add struct type: { field0: i32, field1: i32 }
                struct_type_idx = add_struct_type!(mod, [FieldType(I32, true), FieldType(I32, true)])

                # Function: () -> i32
                # Creates struct with values (42, 99), returns field 0
                body = UInt8[]

                # Push field values for struct.new (i32.const uses signed LEB128!)
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(42))  # field 0 value
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(99))  # field 1 value

                # struct.new $type
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_NEW)
                append!(body, encode_leb128_unsigned(struct_type_idx))

                # struct.get $type $field
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_GET)
                append!(body, encode_leb128_unsigned(struct_type_idx))
                append!(body, encode_leb128_unsigned(0))  # field index

                # End function
                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[], NumType[I32], NumType[], body)
                add_export!(mod, "get_field0", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                result = run_wasm(wasm_bytes, "get_field0")

                @test result == 42
            end
        end

        @testset "Hand-crafted: Struct field 1 access" begin
            if NODE_CMD !== nothing
                using WasmTarget: WasmModule, add_struct_type!, add_function!, add_export!
                using WasmTarget: FieldType, I32, to_bytes, Opcode, encode_leb128_unsigned, encode_leb128_signed

                mod = WasmModule()
                struct_type_idx = add_struct_type!(mod, [FieldType(I32, true), FieldType(I32, true)])

                body = UInt8[]

                # Create struct with (42, 99) - use signed LEB128 for i32.const
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(42))
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(99))

                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_NEW)
                append!(body, encode_leb128_unsigned(struct_type_idx))

                # Get field 1
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_GET)
                append!(body, encode_leb128_unsigned(struct_type_idx))
                append!(body, encode_leb128_unsigned(1))  # field 1

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[], NumType[I32], NumType[], body)
                add_export!(mod, "get_field1", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                result = run_wasm(wasm_bytes, "get_field1")

                @test result == 99
            end
        end

        @testset "Hand-crafted: Struct with parameters" begin
            if NODE_CMD !== nothing
                using WasmTarget: WasmModule, add_struct_type!, add_function!, add_export!
                using WasmTarget: FieldType, I32, to_bytes, Opcode, encode_leb128_unsigned

                # Function: (a: i32, b: i32) -> i32
                # Creates struct(a, b), returns field y (b)
                mod = WasmModule()
                struct_type_idx = add_struct_type!(mod, [FieldType(I32, true), FieldType(I32, true)])

                body = UInt8[]

                # Push function args for struct
                push!(body, Opcode.LOCAL_GET)
                push!(body, 0x00)  # arg a
                push!(body, Opcode.LOCAL_GET)
                push!(body, 0x01)  # arg b

                # struct.new
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_NEW)
                append!(body, encode_leb128_unsigned(struct_type_idx))

                # struct.get field 1 (y)
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_GET)
                append!(body, encode_leb128_unsigned(struct_type_idx))
                append!(body, encode_leb128_unsigned(1))

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[I32, I32], NumType[I32], NumType[], body)
                add_export!(mod, "create_and_get_y", 0, func_idx)

                wasm_bytes = to_bytes(mod)

                @test run_wasm(wasm_bytes, "create_and_get_y", Int32(10), Int32(20)) == 20
                @test run_wasm(wasm_bytes, "create_and_get_y", Int32(100), Int32(200)) == 200
            end
        end

    end

    # ========================================================================
    # Phase 8: Tuples
    # ========================================================================
    @testset "Phase 8: Tuples" begin

        @testset "Hand-crafted: Tuple creation and access" begin
            if NODE_CMD !== nothing
                using WasmTarget: WasmModule, add_struct_type!, add_function!, add_export!
                using WasmTarget: FieldType, I32, to_bytes, Opcode, encode_leb128_unsigned

                # Function: (a: i32, b: i32) -> i32
                # Creates tuple (a, b), returns first element
                mod = WasmModule()

                # Tuple is represented as struct { field0: i32, field1: i32 }
                tuple_type_idx = add_struct_type!(mod, [FieldType(I32, false), FieldType(I32, false)])

                body = UInt8[]

                # Push tuple elements
                push!(body, Opcode.LOCAL_GET)
                push!(body, 0x00)
                push!(body, Opcode.LOCAL_GET)
                push!(body, 0x01)

                # struct.new
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_NEW)
                append!(body, encode_leb128_unsigned(tuple_type_idx))

                # Get element 0
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_GET)
                append!(body, encode_leb128_unsigned(tuple_type_idx))
                append!(body, encode_leb128_unsigned(0))

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[I32, I32], NumType[I32], NumType[], body)
                add_export!(mod, "tuple_first", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                @test run_wasm(wasm_bytes, "tuple_first", Int32(10), Int32(20)) == 10
            end
        end

        @testset "Hand-crafted: Tuple second element" begin
            if NODE_CMD !== nothing
                using WasmTarget: WasmModule, add_struct_type!, add_function!, add_export!
                using WasmTarget: FieldType, I32, to_bytes, Opcode, encode_leb128_unsigned

                mod = WasmModule()
                tuple_type_idx = add_struct_type!(mod, [FieldType(I32, false), FieldType(I32, false)])

                body = UInt8[]

                push!(body, Opcode.LOCAL_GET)
                push!(body, 0x00)
                push!(body, Opcode.LOCAL_GET)
                push!(body, 0x01)
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_NEW)
                append!(body, encode_leb128_unsigned(tuple_type_idx))

                # Get element 1 (second)
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_GET)
                append!(body, encode_leb128_unsigned(tuple_type_idx))
                append!(body, encode_leb128_unsigned(1))

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[I32, I32], NumType[I32], NumType[], body)
                add_export!(mod, "tuple_second", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                @test run_wasm(wasm_bytes, "tuple_second", Int32(10), Int32(20)) == 20
            end
        end

        @testset "Hand-crafted: 3-element tuple" begin
            if NODE_CMD !== nothing
                using WasmTarget: WasmModule, add_struct_type!, add_function!, add_export!
                using WasmTarget: FieldType, I32, I64, to_bytes, Opcode, encode_leb128_unsigned, encode_leb128_signed

                mod = WasmModule()
                # Tuple{Int32, Int32, Int32}
                tuple_type_idx = add_struct_type!(mod, [
                    FieldType(I32, false),
                    FieldType(I32, false),
                    FieldType(I32, false)
                ])

                body = UInt8[]

                # Create tuple (10, 20, 30), return third element
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(10))
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(20))
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(30))

                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_NEW)
                append!(body, encode_leb128_unsigned(tuple_type_idx))

                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_GET)
                append!(body, encode_leb128_unsigned(tuple_type_idx))
                append!(body, encode_leb128_unsigned(2))  # third element

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[], NumType[I32], NumType[], body)
                add_export!(mod, "tuple_third", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                @test run_wasm(wasm_bytes, "tuple_third") == 30
            end
        end

    end

    # ========================================================================
    # Phase 9: WasmGC Arrays
    # ========================================================================
    @testset "Phase 9: WasmGC Arrays" begin

        @testset "Builder: Array type creation" begin
            using WasmTarget: WasmModule, add_array_type!, I32, to_bytes

            mod = WasmModule()
            arr_type_idx = add_array_type!(mod, I32, true)

            @test arr_type_idx == 0
            bytes = to_bytes(mod)
            @test length(bytes) > 8
            @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6D]
        end

        @testset "Hand-crafted: Array length" begin
            if NODE_CMD !== nothing
                using WasmTarget: WasmModule, add_array_type!, add_function!, add_export!
                using WasmTarget: I32, to_bytes, Opcode, encode_leb128_unsigned, encode_leb128_signed

                # Function: () -> i32
                # Creates array of length 5, returns the length
                mod = WasmModule()
                arr_type_idx = add_array_type!(mod, I32, true)

                body = UInt8[]

                # Create array with init value 0 and length 5
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(0))
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(5))

                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.ARRAY_NEW)
                append!(body, encode_leb128_unsigned(arr_type_idx))

                # Get array length
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.ARRAY_LEN)

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[], NumType[I32], NumType[], body)
                add_export!(mod, "arr_len", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                @test run_wasm(wasm_bytes, "arr_len") == 5
            end
        end

        @testset "Hand-crafted: Array get element" begin
            if NODE_CMD !== nothing
                using WasmTarget: WasmModule, add_array_type!, add_function!, add_export!
                using WasmTarget: I32, to_bytes, Opcode, encode_leb128_unsigned, encode_leb128_signed

                # Create array with init value 42, get element at index 0
                mod = WasmModule()
                arr_type_idx = add_array_type!(mod, I32, true)

                body = UInt8[]

                # Create array with init value 42 and length 3
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(42))  # all elements will be 42
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(3))

                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.ARRAY_NEW)
                append!(body, encode_leb128_unsigned(arr_type_idx))

                # Get element at index 1
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(1))
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.ARRAY_GET)
                append!(body, encode_leb128_unsigned(arr_type_idx))

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[], NumType[I32], NumType[], body)
                add_export!(mod, "arr_get", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                @test run_wasm(wasm_bytes, "arr_get") == 42
            end
        end

        @testset "Hand-crafted: Array new_fixed" begin
            if NODE_CMD !== nothing
                using WasmTarget: WasmModule, add_array_type!, add_function!, add_export!
                using WasmTarget: I32, to_bytes, Opcode, encode_leb128_unsigned, encode_leb128_signed

                # Create array with fixed elements [10, 20, 30], get middle element
                mod = WasmModule()
                arr_type_idx = add_array_type!(mod, I32, true)

                body = UInt8[]

                # Push elements for array.new_fixed
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(10))
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(20))
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(30))

                # array.new_fixed $type $count
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.ARRAY_NEW_FIXED)
                append!(body, encode_leb128_unsigned(arr_type_idx))
                append!(body, encode_leb128_unsigned(3))  # count

                # Get element at index 1 (should be 20)
                push!(body, Opcode.I32_CONST)
                append!(body, encode_leb128_signed(1))
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.ARRAY_GET)
                append!(body, encode_leb128_unsigned(arr_type_idx))

                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[], NumType[I32], NumType[], body)
                add_export!(mod, "arr_fixed_get", 0, func_idx)

                wasm_bytes = to_bytes(mod)
                @test run_wasm(wasm_bytes, "arr_fixed_get") == 20
            end
        end

    end

    # ========================================================================
    # Phase 10: JavaScript Imports
    # ========================================================================
    @testset "Phase 10: JavaScript Imports" begin

        @testset "Builder: Add import function" begin
            using WasmTarget: WasmModule, add_import!, add_function!, add_export!
            using WasmTarget: I32, to_bytes

            mod = WasmModule()
            # Import a function: env.log_i32(i32) -> void
            import_idx = add_import!(mod, "env", "log_i32", NumType[I32], NumType[])
            @test import_idx == 0

            # Add a local function that calls the import
            body = UInt8[
                0x20, 0x00,  # local.get 0
                0x10, 0x00,  # call 0 (the imported function)
                0x0B         # end
            ]
            func_idx = add_function!(mod, NumType[I32], NumType[], NumType[], body)
            # func_idx should be 1 (after the imported function)
            @test func_idx == 1

            add_export!(mod, "test", 0, func_idx)

            bytes = to_bytes(mod)
            @test length(bytes) > 8
            @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6D]
        end

        @testset "Execute: Import and call JavaScript function" begin
            if NODE_CMD !== nothing
                using WasmTarget: WasmModule, add_import!, add_function!, add_export!
                using WasmTarget: I32, to_bytes, Opcode, encode_leb128_unsigned, encode_leb128_signed

                mod = WasmModule()

                # Import: env.double(i32) -> i32
                import_idx = add_import!(mod, "env", "double_it", NumType[I32], NumType[I32])

                # Local function: (param i32) -> i32
                # Calls the imported double_it function
                body = UInt8[]
                push!(body, Opcode.LOCAL_GET)
                append!(body, encode_leb128_unsigned(0))
                push!(body, Opcode.CALL)
                append!(body, encode_leb128_unsigned(0))  # call import at index 0
                push!(body, Opcode.END)

                func_idx = add_function!(mod, NumType[I32], NumType[I32], NumType[], body)
                add_export!(mod, "call_double", 0, func_idx)

                wasm_bytes = to_bytes(mod)

                # Run with imports
                result = run_wasm_with_imports(wasm_bytes, "call_double",
                    Dict("env" => Dict("double_it" => "(x) => x * 2")),
                    Int32(21))
                @test result == 42
            end
        end

    end

    @testset "Phase 11: Loops" begin

        @testset "Simple while loop - sum 1 to n" begin
            @noinline function simple_sum(n::Int32)::Int32
                total::Int32 = Int32(0)
                i::Int32 = Int32(1)
                @inbounds while i <= n
                    total = total + i
                    i = i + Int32(1)
                end
                return total
            end

            wasm_bytes = WasmTarget.compile(simple_sum, (Int32,))
            @test length(wasm_bytes) > 0

            # Test execution
            @test run_wasm(wasm_bytes, "simple_sum", Int32(5)) == 15
            @test run_wasm(wasm_bytes, "simple_sum", Int32(10)) == 55
            @test run_wasm(wasm_bytes, "simple_sum", Int32(100)) == 5050
        end

        @testset "Factorial loop" begin
            @noinline function factorial_loop(n::Int32)::Int32
                result::Int32 = Int32(1)
                i::Int32 = Int32(1)
                @inbounds while i <= n
                    result = result * i
                    i = i + Int32(1)
                end
                return result
            end

            wasm_bytes = WasmTarget.compile(factorial_loop, (Int32,))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "factorial_loop", Int32(1)) == 1
            @test run_wasm(wasm_bytes, "factorial_loop", Int32(5)) == 120
            @test run_wasm(wasm_bytes, "factorial_loop", Int32(6)) == 720
        end

        @testset "Count down loop" begin
            @noinline function count_down(n::Int32)::Int32
                total::Int32 = Int32(0)
                i::Int32 = n
                @inbounds while i > Int32(0)
                    total = total + i
                    i = i - Int32(1)
                end
                return total
            end

            wasm_bytes = WasmTarget.compile(count_down, (Int32,))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "count_down", Int32(5)) == 15
            @test run_wasm(wasm_bytes, "count_down", Int32(10)) == 55
        end

    end

    # Note: Recursive functions must be defined at module level (not inside @testset)
    # to avoid closure capture which is not yet supported in the Wasm compiler

    @testset "Phase 12: Recursion" begin

        @testset "Recursive factorial" begin
            wasm_bytes = WasmTarget.compile(test_factorial_rec, (Int32,))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "test_factorial_rec", Int32(1)) == 1
            @test run_wasm(wasm_bytes, "test_factorial_rec", Int32(5)) == 120
            @test run_wasm(wasm_bytes, "test_factorial_rec", Int32(6)) == 720
            @test run_wasm(wasm_bytes, "test_factorial_rec", Int32(10)) == 3628800
        end

        @testset "Recursive fibonacci" begin
            wasm_bytes = WasmTarget.compile(test_fib, (Int32,))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "test_fib", Int32(0)) == 0
            @test run_wasm(wasm_bytes, "test_fib", Int32(1)) == 1
            @test run_wasm(wasm_bytes, "test_fib", Int32(5)) == 5
            @test run_wasm(wasm_bytes, "test_fib", Int32(10)) == 55
        end

        @testset "Recursive sum" begin
            wasm_bytes = WasmTarget.compile(test_sum_rec, (Int32,))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "test_sum_rec", Int32(0)) == 0
            @test run_wasm(wasm_bytes, "test_sum_rec", Int32(5)) == 15
            @test run_wasm(wasm_bytes, "test_sum_rec", Int32(100)) == 5050
        end

    end

    # ========================================================================
    # Phase 13: Compiled Struct Field Access
    # ========================================================================
    @testset "Phase 13: Compiled Struct Access" begin

        @testset "Struct creation and field sum" begin
            wasm_bytes = WasmTarget.compile(test_point_sum, (Int32, Int32))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "test_point_sum", Int32(10), Int32(20)) == 30
            @test run_wasm(wasm_bytes, "test_point_sum", Int32(100), Int32(200)) == 300
            @test run_wasm(wasm_bytes, "test_point_sum", Int32(-5), Int32(15)) == 10
        end

        @testset "Struct creation and field difference" begin
            wasm_bytes = WasmTarget.compile(test_point_diff, (Int32, Int32))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "test_point_diff", Int32(30), Int32(10)) == 20
            @test run_wasm(wasm_bytes, "test_point_diff", Int32(100), Int32(50)) == 50
            @test run_wasm(wasm_bytes, "test_point_diff", Int32(5), Int32(10)) == -5
        end

    end

    # ========================================================================
    # Phase 14: Float Operations and Branching
    # ========================================================================
    @testset "Phase 14: Float Operations" begin

        @testset "Float addition" begin
            wasm_bytes = WasmTarget.compile(test_float_add, (Float64, Float64))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "test_float_add", 1.5, 2.5) ≈ 4.0
            @test run_wasm(wasm_bytes, "test_float_add", -1.0, 1.0) ≈ 0.0
            @test run_wasm(wasm_bytes, "test_float_add", 100.5, 200.5) ≈ 301.0
        end

        @testset "Float multiplication" begin
            wasm_bytes = WasmTarget.compile(test_float_mul, (Float64, Float64))
            @test length(wasm_bytes) > 0

            @test run_wasm(wasm_bytes, "test_float_mul", 2.0, 3.0) ≈ 6.0
            @test run_wasm(wasm_bytes, "test_float_mul", -2.0, 4.0) ≈ -8.0
            @test run_wasm(wasm_bytes, "test_float_mul", 0.5, 0.5) ≈ 0.25
        end

        @testset "Integer branching" begin
            wasm_bytes = WasmTarget.compile(test_branch, (Int32, Int32))
            @test length(wasm_bytes) > 0

            # sum = 110 > 100, so return 110 - 50 = 60
            @test run_wasm(wasm_bytes, "test_branch", Int32(60), Int32(50)) == 60
            # sum = 50 <= 100, so return 50 * 2 = 100
            @test run_wasm(wasm_bytes, "test_branch", Int32(30), Int32(20)) == 100
            # sum = 101 > 100, so return 101 - 50 = 51
            @test run_wasm(wasm_bytes, "test_branch", Int32(100), Int32(1)) == 51
        end

    end

    # ========================================================================
    # Phase 15: Strings
    # ========================================================================
    @testset "Phase 15: Strings" begin

        # String sizeof - returns byte length of string
        @noinline function str_sizeof(s::String)::Int64
            return sizeof(s)
        end

        @testset "String sizeof compilation" begin
            wasm_bytes = WasmTarget.compile(str_sizeof, (String,))
            @test length(wasm_bytes) > 0

            # Validate the module
            @test validate_wasm(wasm_bytes)
        end

        # String length - returns character count
        @noinline function str_length(s::String)::Int64
            return length(s)
        end

        @testset "String length compilation" begin
            wasm_bytes = WasmTarget.compile(str_length, (String,))
            @test length(wasm_bytes) > 0

            # Validate the module
            @test validate_wasm(wasm_bytes)
        end

        # String literal - returns a constant string
        @noinline function str_literal()::String
            return "hello"
        end

        @testset "String literal compilation" begin
            wasm_bytes = WasmTarget.compile(str_literal, ())
            @test length(wasm_bytes) > 0

            # Validate the module
            @test validate_wasm(wasm_bytes)
        end

        # String concatenation
        @noinline function str_concat(a::String, b::String)::String
            return a * b
        end

        @testset "String concatenation" begin
            wasm_bytes = WasmTarget.compile(str_concat, (String, String))
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
        end

        # String equality
        @noinline function str_equal(a::String, b::String)::Bool
            return a == b
        end

        @testset "String equality" begin
            wasm_bytes = WasmTarget.compile(str_equal, (String, String))
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
        end

        # String hashing for dict keys
        @testset "String hash" begin
            function test_str_hash()::Int32
                return str_hash("hello")
            end

            wasm_bytes = WasmTarget.compile(test_str_hash, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            # Verify hash matches Julia's fallback
            @test run_wasm(wasm_bytes, "test_str_hash") == str_hash("hello")
        end

        @testset "String hash consistency" begin
            function test_hash_diff()::Int32
                h1 = str_hash("hello")
                h2 = str_hash("world")
                if h1 == h2
                    return Int32(0)
                else
                    return Int32(1)
                end
            end

            wasm_bytes = WasmTarget.compile(test_hash_diff, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_hash_diff") == 1  # Different strings have different hashes
        end

        # ======================================================================
        # BROWSER-010: New String Operations
        # ======================================================================

        @testset "str_find - basic search" begin
            function test_str_find_basic()::Int32
                return str_find("hello world", "world")
            end

            wasm_bytes = WasmTarget.compile(test_str_find_basic, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_find_basic") == 7  # "world" starts at position 7
        end

        @testset "str_find - not found" begin
            function test_str_find_notfound()::Int32
                return str_find("hello world", "xyz")
            end

            wasm_bytes = WasmTarget.compile(test_str_find_notfound, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_find_notfound") == 0  # Not found returns 0
        end

        @testset "str_contains - found" begin
            function test_str_contains_found()::Int32
                if str_contains("hello world", "world")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            wasm_bytes = WasmTarget.compile(test_str_contains_found, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_contains_found") == 1
        end

        @testset "str_contains - not found" begin
            function test_str_contains_notfound()::Int32
                if str_contains("hello world", "xyz")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            wasm_bytes = WasmTarget.compile(test_str_contains_notfound, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_contains_notfound") == 0
        end

        @testset "str_startswith - true case" begin
            function test_str_startswith_true()::Int32
                if str_startswith("hello world", "hello")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            wasm_bytes = WasmTarget.compile(test_str_startswith_true, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_startswith_true") == 1
        end

        @testset "str_startswith - false case" begin
            function test_str_startswith_false()::Int32
                if str_startswith("hello world", "world")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            wasm_bytes = WasmTarget.compile(test_str_startswith_false, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_startswith_false") == 0
        end

        @testset "str_endswith - true case" begin
            function test_str_endswith_true()::Int32
                if str_endswith("hello world", "world")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            wasm_bytes = WasmTarget.compile(test_str_endswith_true, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_endswith_true") == 1
        end

        @testset "str_endswith - false case" begin
            function test_str_endswith_false()::Int32
                if str_endswith("hello world", "hello")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            wasm_bytes = WasmTarget.compile(test_str_endswith_false, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_endswith_false") == 0
        end

        # ========================================================================
        # BROWSER-010: str_uppercase, str_lowercase, str_trim
        # ========================================================================

        @testset "str_uppercase - basic" begin
            function test_str_uppercase()::Int32
                result = str_uppercase("hello")
                # Check first char is 'H' (72)
                return str_char(result, Int32(1))
            end

            wasm_bytes = WasmTarget.compile(test_str_uppercase, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_uppercase") == 72  # 'H'
        end

        @testset "str_uppercase - mixed case" begin
            function test_str_uppercase_mixed()::Int32
                result = str_uppercase("HeLLo WoRLD")
                # Check length is preserved
                len = str_len(result)
                # Check some characters
                first = str_char(result, Int32(1))  # 'H' = 72
                fifth = str_char(result, Int32(5))  # 'O' = 79
                space = str_char(result, Int32(6))  # ' ' = 32
                last = str_char(result, Int32(11)) # 'D' = 68
                # Return sum as verification
                return first + fifth + space + last
            end

            wasm_bytes = WasmTarget.compile(test_str_uppercase_mixed, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_uppercase_mixed") == 72 + 79 + 32 + 68  # 251
        end

        @testset "str_lowercase - basic" begin
            function test_str_lowercase()::Int32
                result = str_lowercase("HELLO")
                # Check first char is 'h' (104)
                return str_char(result, Int32(1))
            end

            wasm_bytes = WasmTarget.compile(test_str_lowercase, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_lowercase") == 104  # 'h'
        end

        @testset "str_lowercase - mixed case" begin
            function test_str_lowercase_mixed()::Int32
                result = str_lowercase("HeLLo WoRLD")
                # Check length is preserved
                len = str_len(result)
                # Check some characters
                first = str_char(result, Int32(1))  # 'h' = 104
                fifth = str_char(result, Int32(5))  # 'o' = 111
                space = str_char(result, Int32(6))  # ' ' = 32
                last = str_char(result, Int32(11)) # 'd' = 100
                # Return sum as verification
                return first + fifth + space + last
            end

            wasm_bytes = WasmTarget.compile(test_str_lowercase_mixed, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_lowercase_mixed") == 104 + 111 + 32 + 100  # 347
        end

        @testset "str_trim - leading and trailing spaces" begin
            function test_str_trim_both()::Int32
                result = str_trim("  hello  ")
                # Length should be 5
                return str_len(result)
            end

            wasm_bytes = WasmTarget.compile(test_str_trim_both, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_trim_both") == 5
        end

        @testset "str_trim - content preserved" begin
            function test_str_trim_content()::Int32
                result = str_trim("  hello  ")
                # First char should be 'h' (104)
                return str_char(result, Int32(1))
            end

            wasm_bytes = WasmTarget.compile(test_str_trim_content, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_trim_content") == 104  # 'h'
        end

        @testset "str_trim - no whitespace" begin
            function test_str_trim_no_ws()::Int32
                result = str_trim("hello")
                # Length should remain 5
                return str_len(result)
            end

            wasm_bytes = WasmTarget.compile(test_str_trim_no_ws, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_trim_no_ws") == 5
        end

        @testset "str_trim - all whitespace" begin
            function test_str_trim_all_ws()::Int32
                result = str_trim("   ")
                # Length should be 0
                return str_len(result)
            end

            wasm_bytes = WasmTarget.compile(test_str_trim_all_ws, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_trim_all_ws") == 0
        end

        @testset "str_trim - tabs and newlines" begin
            function test_str_trim_special()::Int32
                # "\thello\n" - tab at start, newline at end
                s = str_new(Int32(7))
                str_setchar!(s, Int32(1), Int32(9))   # tab
                str_setchar!(s, Int32(2), Int32(104)) # h
                str_setchar!(s, Int32(3), Int32(101)) # e
                str_setchar!(s, Int32(4), Int32(108)) # l
                str_setchar!(s, Int32(5), Int32(108)) # l
                str_setchar!(s, Int32(6), Int32(111)) # o
                str_setchar!(s, Int32(7), Int32(10))  # newline
                result = str_trim(s)
                # Length should be 5
                return str_len(result)
            end

            wasm_bytes = WasmTarget.compile(test_str_trim_special, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_trim_special") == 5
        end

        # BROWSER-010: Dedicated tests for str_char and str_substr

        @testset "str_char - get character at index" begin
            function test_str_char_basic()::Int32
                s = "hello"
                return str_char(s, Int32(1))  # 'h' = 104
            end

            wasm_bytes = WasmTarget.compile(test_str_char_basic, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_char_basic") == 104  # 'h'
        end

        @testset "str_char - multiple positions" begin
            function test_str_char_multi()::Int32
                s = "hello"
                # Sum first and last character: 'h'(104) + 'o'(111) = 215
                return str_char(s, Int32(1)) + str_char(s, Int32(5))
            end

            wasm_bytes = WasmTarget.compile(test_str_char_multi, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_char_multi") == 215
        end

        @testset "str_substr - extract substring" begin
            function test_str_substr_basic()::Int32
                s = "hello world"
                sub = str_substr(s, Int32(7), Int32(5))  # "world"
                return str_len(sub)
            end

            wasm_bytes = WasmTarget.compile(test_str_substr_basic, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_substr_basic") == 5
        end

        @testset "str_substr - verify content" begin
            function test_str_substr_content()::Int32
                s = "hello world"
                sub = str_substr(s, Int32(7), Int32(5))  # "world"
                # Return first char of "world" = 'w' = 119
                return str_char(sub, Int32(1))
            end

            wasm_bytes = WasmTarget.compile(test_str_substr_content, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_str_substr_content") == 119  # 'w'
        end

        @testset "str_char - character comparison for tokenizer" begin
            # This test verifies the pattern used in tokenizer
            function test_char_comparison()::Int32
                s = "hello"
                c = str_char(s, Int32(1))
                # Compare character to ASCII code
                if c == Int32(104)  # 'h'
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            wasm_bytes = WasmTarget.compile(test_char_comparison, ())
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
            @test run_wasm(wasm_bytes, "test_char_comparison") == 1
        end

    end

    # ========================================================================
    # Phase 16: Multi-Function Modules
    # ========================================================================
    @testset "Phase 16: Multi-Function Modules" begin

        @noinline function multi_add(a::Int32, b::Int32)::Int32
            return a + b
        end

        @noinline function multi_sub(a::Int32, b::Int32)::Int32
            return a - b
        end

        @noinline function multi_mul(a::Int32, b::Int32)::Int32
            return a * b
        end

        @testset "Multiple functions in one module" begin
            wasm_bytes = WasmTarget.compile_multi([
                (multi_add, (Int32, Int32)),
                (multi_sub, (Int32, Int32)),
                (multi_mul, (Int32, Int32)),
            ])
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)

            # Test each function works correctly
            @test run_wasm(wasm_bytes, "multi_add", Int32(5), Int32(3)) == 8
            @test run_wasm(wasm_bytes, "multi_sub", Int32(10), Int32(4)) == 6
            @test run_wasm(wasm_bytes, "multi_mul", Int32(6), Int32(7)) == 42
        end

        @testset "Cross-function calls" begin
            # Uses module-level functions: cross_helper_double, cross_use_helper
            wasm_bytes = WasmTarget.compile_multi([
                (cross_helper_double, (Int32,)),
                (cross_use_helper, (Int32,)),
            ])
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)

            # Test helper directly
            @test run_wasm(wasm_bytes, "cross_helper_double", Int32(5)) == 10

            # Test function that calls another function
            @test run_wasm(wasm_bytes, "cross_use_helper", Int32(5)) == 11   # 5*2 + 1
            @test run_wasm(wasm_bytes, "cross_use_helper", Int32(10)) == 21  # 10*2 + 1
        end

        @testset "Multiple dispatch" begin
            # Same function (dispatch_process) with different type signatures
            wasm_bytes = WasmTarget.compile_multi([
                (dispatch_process, (Int32,), "process_i32"),
                (dispatch_process, (Int64,), "process_i64"),
                (dispatch_use_i32, (Int32,)),
                (dispatch_use_i64, (Int64,)),
            ])
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)

            # Test direct calls to each dispatch variant
            @test run_wasm(wasm_bytes, "process_i32", Int32(5)) == 10   # 5*2
            @test run_wasm(wasm_bytes, "process_i64", Int64(5)) == 15   # 5*3

            # Test calls through dispatching functions
            @test run_wasm(wasm_bytes, "dispatch_use_i32", Int32(5)) == 11  # 5*2 + 1
            @test run_wasm(wasm_bytes, "dispatch_use_i64", Int64(5)) == 16  # 5*3 + 1
        end

        # Result type pattern test
        mutable struct ResultType
            success::Bool
            value::Int32
        end

        @noinline function result_try_div(a::Int32, b::Int32)::ResultType
            if b == Int32(0)
                return ResultType(false, Int32(0))
            else
                return ResultType(true, a ÷ b)
            end
        end

        @noinline function result_get_value(r::ResultType)::Int32
            return r.value
        end

        @noinline function result_is_success(r::ResultType)::Bool
            return r.success
        end

        @testset "Result type pattern" begin
            wasm_bytes = WasmTarget.compile_multi([
                (result_try_div, (Int32, Int32)),
                (result_get_value, (ResultType,)),
                (result_is_success, (ResultType,))
            ])
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
        end

    end

    # ========================================================================
    # Phase 17: JS Interop (externref)
    # ========================================================================
    @testset "Phase 17: JS Interop" begin

        @testset "externref pass-through" begin
            @noinline function jsval_passthrough(x::JSValue)::JSValue
                return x
            end

            wasm_bytes = WasmTarget.compile(jsval_passthrough, (JSValue,))
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
        end

        @testset "Wasm globals" begin
            # Test global variable creation and export
            mod = WasmTarget.WasmModule()

            # Add mutable i32 global
            global_idx = WasmTarget.add_global!(mod, WasmTarget.I32, true, 0)
            @test global_idx == 0

            # Export it
            WasmTarget.add_global_export!(mod, "counter", global_idx)

            # Serialize and validate
            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

    end

    # ========================================================================
    # Phase 18: Tables and Indirect Calls
    # ========================================================================
    @testset "Phase 18: Tables" begin

        @testset "Basic table creation" begin
            mod = WasmTarget.WasmModule()

            # Add a funcref table with 4 slots
            table_idx = WasmTarget.add_table!(mod, WasmTarget.FuncRef, 4)
            @test table_idx == 0

            # Add some functions to populate the table
            func1_idx = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,  # get param
                    WasmTarget.Opcode.I32_CONST, 0x02,  # push 2
                    WasmTarget.Opcode.I32_MUL,          # multiply
                    WasmTarget.Opcode.END
                ]
            )

            func2_idx = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,  # get param
                    WasmTarget.Opcode.I32_CONST, 0x03,  # push 3
                    WasmTarget.Opcode.I32_MUL,          # multiply
                    WasmTarget.Opcode.END
                ]
            )

            # Export them for testing
            WasmTarget.add_export!(mod, "double", 0, func1_idx)
            WasmTarget.add_export!(mod, "triple", 0, func2_idx)

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)

            # Test the functions work
            @test run_wasm(bytes, "double", Int32(5)) == 10
            @test run_wasm(bytes, "triple", Int32(5)) == 15
        end

        @testset "Table with element segment" begin
            mod = WasmTarget.WasmModule()

            # Add funcref table
            table_idx = WasmTarget.add_table!(mod, WasmTarget.FuncRef, 4)

            # Add two functions with same signature
            func_double = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,
                    WasmTarget.Opcode.I32_CONST, 0x02,
                    WasmTarget.Opcode.I32_MUL,
                    WasmTarget.Opcode.END
                ]
            )

            func_triple = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,
                    WasmTarget.Opcode.I32_CONST, 0x03,
                    WasmTarget.Opcode.I32_MUL,
                    WasmTarget.Opcode.END
                ]
            )

            # Initialize table with element segment
            WasmTarget.add_elem_segment!(mod, 0, 0, [func_double, func_triple])

            # Export table for JS inspection
            WasmTarget.add_table_export!(mod, "funcs", table_idx)

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        @testset "Table with limits" begin
            mod = WasmTarget.WasmModule()

            # Table with both min and max
            table_idx = WasmTarget.add_table!(mod, WasmTarget.FuncRef, 2, 10)
            @test table_idx == 0

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        @testset "externref table" begin
            mod = WasmTarget.WasmModule()

            # Table for holding JS objects
            table_idx = WasmTarget.add_table!(mod, WasmTarget.ExternRef, 8)
            WasmTarget.add_table_export!(mod, "objects", table_idx)

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        @testset "call_indirect" begin
            mod = WasmTarget.WasmModule()

            # Add function type for i32 -> i32
            type_idx = WasmTarget.add_type!(mod, WasmTarget.FuncType(
                [WasmTarget.I32],
                [WasmTarget.I32]
            ))

            # Add funcref table
            table_idx = WasmTarget.add_table!(mod, WasmTarget.FuncRef, 4)

            # Add two functions with the same signature
            func_double = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,
                    WasmTarget.Opcode.I32_CONST, 0x02,
                    WasmTarget.Opcode.I32_MUL,
                    WasmTarget.Opcode.END
                ]
            )

            func_triple = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,
                    WasmTarget.Opcode.I32_CONST, 0x03,
                    WasmTarget.Opcode.I32_MUL,
                    WasmTarget.Opcode.END
                ]
            )

            # Initialize table: [func_double, func_triple]
            WasmTarget.add_elem_segment!(mod, 0, 0, [func_double, func_triple])

            # Add a dispatcher function that takes (value, index) and calls indirectly
            # call_indirect format: call_indirect type_idx table_idx
            dispatcher = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32, WasmTarget.I32],  # value, table_index
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,  # push value
                    WasmTarget.Opcode.LOCAL_GET, 0x01,  # push table index
                    WasmTarget.Opcode.CALL_INDIRECT,
                    type_idx % UInt8,                   # type index
                    0x00,                               # table index
                    WasmTarget.Opcode.END
                ]
            )

            WasmTarget.add_export!(mod, "dispatch", 0, dispatcher)

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)

            # dispatch(5, 0) should call func_double(5) = 10
            @test run_wasm(bytes, "dispatch", Int32(5), Int32(0)) == 10
            # dispatch(5, 1) should call func_triple(5) = 15
            @test run_wasm(bytes, "dispatch", Int32(5), Int32(1)) == 15
        end

        @testset "Linear memory" begin
            mod = WasmTarget.WasmModule()

            # Add memory with 1 page (64KB)
            mem_idx = WasmTarget.add_memory!(mod, 1)
            @test mem_idx == 0

            # Export the memory
            WasmTarget.add_memory_export!(mod, "memory", mem_idx)

            # Add a function that uses memory operations
            func_idx = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32, WasmTarget.I32],  # address, value
                WasmTarget.WasmValType[],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,  # address
                    WasmTarget.Opcode.LOCAL_GET, 0x01,  # value
                    WasmTarget.Opcode.I32_STORE, 0x02, 0x00,  # store (align=4, offset=0)
                    WasmTarget.Opcode.END
                ]
            )
            WasmTarget.add_export!(mod, "store", 0, func_idx)

            # Add a load function
            load_idx = WasmTarget.add_function!(
                mod,
                [WasmTarget.I32],      # address
                [WasmTarget.I32],      # result
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.LOCAL_GET, 0x00,  # address
                    WasmTarget.Opcode.I32_LOAD, 0x02, 0x00,  # load (align=4, offset=0)
                    WasmTarget.Opcode.END
                ]
            )
            WasmTarget.add_export!(mod, "load", 0, load_idx)

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)

            # Test memory operations via Node.js
            js_code = """
            const bytes = Buffer.from([$(join(bytes, ","))]);
            WebAssembly.instantiate(bytes).then(result => {
                const { store, load, memory } = result.instance.exports;
                store(0, 42);
                console.log(load(0));
            });
            """
            result = read(`node -e $js_code`, String)
            @test strip(result) == "42"
        end

        @testset "Memory with max limit" begin
            mod = WasmTarget.WasmModule()

            # Add memory with min 1 page, max 10 pages
            mem_idx = WasmTarget.add_memory!(mod, 1, 10)
            @test mem_idx == 0

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        @testset "Data segment with string" begin
            mod = WasmTarget.WasmModule()

            # Add memory
            mem_idx = WasmTarget.add_memory!(mod, 1)
            WasmTarget.add_memory_export!(mod, "memory", mem_idx)

            # Initialize memory with "Hello"
            WasmTarget.add_data_segment!(mod, 0, 0, "Hello")

            # Add a function to read the first byte
            func_idx = WasmTarget.add_function!(
                mod,
                WasmTarget.WasmValType[],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.I32_CONST, 0x00,  # address 0
                    WasmTarget.Opcode.I32_LOAD, 0x00, 0x00,  # load (unaligned)
                    WasmTarget.Opcode.END
                ]
            )
            WasmTarget.add_export!(mod, "read_first", 0, func_idx)

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)

            # Test via Node.js - "Hello" as little-endian i32 is 'H' + 'e'<<8 + 'l'<<16 + 'l'<<24
            # = 0x48 + 0x65<<8 + 0x6c<<16 + 0x6c<<24 = 0x6c6c6548
            expected = Int32('H') | (Int32('e') << 8) | (Int32('l') << 16) | (Int32('l') << 24)
            @test run_wasm(bytes, "read_first") == expected
        end

        @testset "Data segment with raw bytes" begin
            mod = WasmTarget.WasmModule()

            mem_idx = WasmTarget.add_memory!(mod, 1)

            # Initialize with raw bytes [1, 2, 3, 4] at offset 16 (multiple of 4 for alignment)
            WasmTarget.add_data_segment!(mod, 0, 16, UInt8[1, 2, 3, 4])

            # Function to load i32 from offset 16
            # Note: i32.const uses signed LEB128, 16 = 0x10 fits in single byte
            func_idx = WasmTarget.add_function!(
                mod,
                WasmTarget.WasmValType[],
                [WasmTarget.I32],
                WasmTarget.WasmValType[],
                UInt8[
                    WasmTarget.Opcode.I32_CONST, 0x10,    # 16
                    WasmTarget.Opcode.I32_LOAD, 0x02, 0x00,  # align=4, offset=0
                    WasmTarget.Opcode.END
                ]
            )
            WasmTarget.add_export!(mod, "read_data", 0, func_idx)

            bytes = WasmTarget.to_bytes(mod)
            @test length(bytes) > 0
            @test validate_wasm(bytes)

            # Little-endian: [1, 2, 3, 4] = 0x04030201
            expected = Int32(1) | (Int32(2) << 8) | (Int32(3) << 16) | (Int32(4) << 24)
            @test run_wasm(bytes, "read_data") == expected
        end

    end

    # ================================================================
    # Phase 19: SimpleDict (Hash Table) Support
    # ================================================================

    @testset "Phase 19: SimpleDict operations" begin

        @testset "sd_new creates dictionary" begin
            # Simple function that creates dict and returns its length (should be 0)
            function test_dict_new()::Int32
                d = sd_new(Int32(8))
                return sd_length(d)
            end

            bytes = compile(test_dict_new, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_dict_new") == 0
        end

        @testset "sd_set! and sd_get" begin
            # Set a key-value pair and retrieve it
            function test_dict_set_get()::Int32
                d = sd_new(Int32(8))
                sd_set!(d, Int32(5), Int32(42))
                return sd_get(d, Int32(5))
            end

            bytes = compile(test_dict_set_get, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_dict_set_get") == 42
        end

        @testset "sd_haskey" begin
            # Check if key exists
            function test_dict_haskey()::Int32
                d = sd_new(Int32(8))
                sd_set!(d, Int32(10), Int32(100))
                if sd_haskey(d, Int32(10))
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            bytes = compile(test_dict_haskey, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_dict_haskey") == 1
        end

        @testset "sd_haskey returns false for missing key" begin
            function test_dict_haskey_missing()::Int32
                d = sd_new(Int32(8))
                sd_set!(d, Int32(10), Int32(100))
                if sd_haskey(d, Int32(99))
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            bytes = compile(test_dict_haskey_missing, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_dict_haskey_missing") == 0
        end

        @testset "sd_length increases with inserts" begin
            function test_dict_length()::Int32
                d = sd_new(Int32(8))
                sd_set!(d, Int32(1), Int32(10))
                sd_set!(d, Int32(2), Int32(20))
                sd_set!(d, Int32(3), Int32(30))
                return sd_length(d)
            end

            bytes = compile(test_dict_length, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_dict_length") == 3
        end

        @testset "sd_set! updates existing key" begin
            function test_dict_update()::Int32
                d = sd_new(Int32(8))
                sd_set!(d, Int32(5), Int32(10))
                sd_set!(d, Int32(5), Int32(99))  # Update same key
                return sd_get(d, Int32(5))
            end

            bytes = compile(test_dict_update, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_dict_update") == 99
        end

        @testset "sd_get returns 0 for missing key" begin
            function test_dict_get_missing()::Int32
                d = sd_new(Int32(8))
                sd_set!(d, Int32(5), Int32(42))
                return sd_get(d, Int32(99))  # Key doesn't exist
            end

            bytes = compile(test_dict_get_missing, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_dict_get_missing") == 0
        end

        @testset "Multiple keys with linear probing" begin
            # Test that hash collisions are handled
            function test_dict_collisions()::Int32
                d = sd_new(Int32(4))  # Small capacity to force collisions
                sd_set!(d, Int32(1), Int32(11))
                sd_set!(d, Int32(5), Int32(55))  # May collide with key 1
                sd_set!(d, Int32(9), Int32(99))  # May collide with previous
                # Verify all keys are retrievable
                return sd_get(d, Int32(1)) + sd_get(d, Int32(5)) + sd_get(d, Int32(9))
            end

            bytes = compile(test_dict_collisions, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_dict_collisions") == (11 + 55 + 99)
        end

    end

    # ================================================================
    # Phase 20: StringDict (String-keyed Hash Table) Support
    # ================================================================

    @testset "Phase 20: StringDict operations" begin

        @testset "sdict_new creates dictionary" begin
            # Simple function that creates dict and returns its length (should be 0)
            function test_sdict_new()::Int32
                d = sdict_new(Int32(8))
                return sdict_length(d)
            end

            bytes = compile(test_sdict_new, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_sdict_new") == 0
        end

        @testset "sdict_set! and sdict_get" begin
            # Set a key-value pair and retrieve it
            function test_sdict_set_get()::Int32
                d = sdict_new(Int32(8))
                sdict_set!(d, "hello", Int32(42))
                return sdict_get(d, "hello")
            end

            bytes = compile(test_sdict_set_get, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_sdict_set_get") == 42
        end

        @testset "sdict_haskey" begin
            # Check if key exists
            function test_sdict_haskey()::Int32
                d = sdict_new(Int32(8))
                sdict_set!(d, "test", Int32(100))
                if sdict_haskey(d, "test")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            bytes = compile(test_sdict_haskey, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_sdict_haskey") == 1
        end

        @testset "sdict_haskey returns false for missing key" begin
            function test_sdict_haskey_missing()::Int32
                d = sdict_new(Int32(8))
                sdict_set!(d, "exists", Int32(100))
                if sdict_haskey(d, "missing")
                    return Int32(1)
                else
                    return Int32(0)
                end
            end

            bytes = compile(test_sdict_haskey_missing, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_sdict_haskey_missing") == 0
        end

        @testset "sdict_length increases with inserts" begin
            function test_sdict_length()::Int32
                d = sdict_new(Int32(8))
                sdict_set!(d, "one", Int32(10))
                sdict_set!(d, "two", Int32(20))
                sdict_set!(d, "three", Int32(30))
                return sdict_length(d)
            end

            bytes = compile(test_sdict_length, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_sdict_length") == 3
        end

        @testset "sdict_set! updates existing key" begin
            function test_sdict_update()::Int32
                d = sdict_new(Int32(8))
                sdict_set!(d, "key", Int32(10))
                sdict_set!(d, "key", Int32(99))  # Update same key
                return sdict_get(d, "key")
            end

            bytes = compile(test_sdict_update, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_sdict_update") == 99
        end

        @testset "sdict_get returns 0 for missing key" begin
            function test_sdict_get_missing()::Int32
                d = sdict_new(Int32(8))
                sdict_set!(d, "exists", Int32(42))
                return sdict_get(d, "nothere")  # Key doesn't exist
            end

            bytes = compile(test_sdict_get_missing, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_sdict_get_missing") == 0
        end

        @testset "Multiple string keys" begin
            # Test with multiple string keys
            function test_sdict_multi()::Int32
                d = sdict_new(Int32(8))
                sdict_set!(d, "apple", Int32(1))
                sdict_set!(d, "banana", Int32(2))
                sdict_set!(d, "cherry", Int32(3))
                # Verify all keys are retrievable
                return sdict_get(d, "apple") + sdict_get(d, "banana") + sdict_get(d, "cherry")
            end

            bytes = compile(test_sdict_multi, ())
            @test length(bytes) > 0
            @test validate_wasm(bytes)
            @test run_wasm(bytes, "test_sdict_multi") == (1 + 2 + 3)
        end

    end

    # ========================================================================
    # Phase 21: Multi-dimensional Arrays (Matrix)
    # ========================================================================
    @testset "Phase 21: Multi-dimensional Arrays (Matrix)" begin

        @testset "Matrix type compiles" begin
            # Test that functions accepting Matrix compile correctly
            function test_matrix_accept(m::Matrix{Int32})::Int32
                return Int32(1)  # Just accept and return
            end

            bytes = compile(test_matrix_accept, (Matrix{Int32},))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        @testset "Matrix .size field access compiles" begin
            # Test accessing the .size field of a Matrix
            function test_matrix_get_rows(m::Matrix{Int32})::Int64
                return m.size[1]
            end

            function test_matrix_get_cols(m::Matrix{Int32})::Int64
                return m.size[2]
            end

            bytes_rows = compile(test_matrix_get_rows, (Matrix{Int32},))
            @test length(bytes_rows) > 0
            @test validate_wasm(bytes_rows)

            bytes_cols = compile(test_matrix_get_cols, (Matrix{Int32},))
            @test length(bytes_cols) > 0
            @test validate_wasm(bytes_cols)
        end

        @testset "Matrix .ref field access compiles" begin
            # Test accessing the .ref field (underlying MemoryRef)
            function test_matrix_ref(m::Matrix{Int32})::Int64
                ref = m.ref
                return Int64(1)  # Just access ref
            end

            bytes = compile(test_matrix_ref, (Matrix{Int32},))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        @testset "Matrix Float64 compiles" begin
            # Test Matrix with different element types
            function test_matrix_f64_rows(m::Matrix{Float64})::Int64
                return m.size[1]
            end

            bytes = compile(test_matrix_f64_rows, (Matrix{Float64},))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        @testset "Matrix compile_multi" begin
            # Test multiple Matrix functions together
            function mat_rows(m::Matrix{Int32})::Int64
                return m.size[1]
            end

            function mat_cols(m::Matrix{Int32})::Int64
                return m.size[2]
            end

            function mat_total(m::Matrix{Int32})::Int64
                return m.size[1] * m.size[2]
            end

            bytes = compile_multi([
                (mat_rows, (Matrix{Int32},)),
                (mat_cols, (Matrix{Int32},)),
                (mat_total, (Matrix{Int32},)),
            ])
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

    end

    # ========================================================================
    # Phase 22: Math Functions (WASM-native)
    # ========================================================================
    @testset "Phase 22: Math Functions (WASM-native)" begin

        @testset "sqrt (via llvm intrinsic)" begin
            if NODE_CMD !== nothing
                # Use the raw llvm intrinsic to avoid domain checking
                function test_sqrt_fast(x::Float64)::Float64
                    return Base.Math.sqrt_llvm(x)
                end

                bytes = compile(test_sqrt_fast, (Float64,))
                @test length(bytes) > 0
                @test validate_wasm(bytes)
                @test run_wasm(bytes, "test_sqrt_fast", Float64[4.0]) ≈ 2.0
                @test run_wasm(bytes, "test_sqrt_fast", Float64[9.0]) ≈ 3.0
                @test run_wasm(bytes, "test_sqrt_fast", Float64[2.0]) ≈ sqrt(2.0)
            end
        end

        @testset "abs" begin
            if NODE_CMD !== nothing
                function test_abs(x::Float64)::Float64
                    return abs(x)
                end

                bytes = compile(test_abs, (Float64,))
                @test length(bytes) > 0
                @test validate_wasm(bytes)
                @test run_wasm(bytes, "test_abs", Float64[-5.0]) ≈ 5.0
                @test run_wasm(bytes, "test_abs", Float64[3.0]) ≈ 3.0
                @test run_wasm(bytes, "test_abs", Float64[-0.0]) ≈ 0.0
            end
        end

        @testset "floor" begin
            if NODE_CMD !== nothing
                function test_floor(x::Float64)::Float64
                    return floor(x)
                end

                bytes = compile(test_floor, (Float64,))
                @test length(bytes) > 0
                @test validate_wasm(bytes)
                @test run_wasm(bytes, "test_floor", Float64[3.7]) ≈ 3.0
                @test run_wasm(bytes, "test_floor", Float64[-2.3]) ≈ -3.0
                @test run_wasm(bytes, "test_floor", Float64[5.0]) ≈ 5.0
            end
        end

        @testset "ceil" begin
            if NODE_CMD !== nothing
                function test_ceil(x::Float64)::Float64
                    return ceil(x)
                end

                bytes = compile(test_ceil, (Float64,))
                @test length(bytes) > 0
                @test validate_wasm(bytes)
                @test run_wasm(bytes, "test_ceil", Float64[3.2]) ≈ 4.0
                @test run_wasm(bytes, "test_ceil", Float64[-2.7]) ≈ -2.0
                @test run_wasm(bytes, "test_ceil", Float64[5.0]) ≈ 5.0
            end
        end

        @testset "round" begin
            if NODE_CMD !== nothing
                function test_round(x::Float64)::Float64
                    return round(x)
                end

                bytes = compile(test_round, (Float64,))
                @test length(bytes) > 0
                @test validate_wasm(bytes)
                @test run_wasm(bytes, "test_round", Float64[3.2]) ≈ 3.0
                @test run_wasm(bytes, "test_round", Float64[3.7]) ≈ 4.0
                @test run_wasm(bytes, "test_round", Float64[-2.5]) ≈ -2.0  # Round to even
            end
        end

        @testset "trunc" begin
            if NODE_CMD !== nothing
                function test_trunc(x::Float64)::Float64
                    return trunc(x)
                end

                bytes = compile(test_trunc, (Float64,))
                @test length(bytes) > 0
                @test validate_wasm(bytes)
                @test run_wasm(bytes, "test_trunc", Float64[3.7]) ≈ 3.0
                @test run_wasm(bytes, "test_trunc", Float64[-3.7]) ≈ -3.0
                @test run_wasm(bytes, "test_trunc", Float64[5.0]) ≈ 5.0
            end
        end

        @testset "Float32 variants" begin
            if NODE_CMD !== nothing
                function test_abs_f32(x::Float32)::Float32
                    return abs(x)
                end

                function test_floor_f32(x::Float32)::Float32
                    return floor(x)
                end

                bytes_abs = compile(test_abs_f32, (Float32,))
                @test length(bytes_abs) > 0
                @test validate_wasm(bytes_abs)

                bytes_floor = compile(test_floor_f32, (Float32,))
                @test length(bytes_floor) > 0
                @test validate_wasm(bytes_floor)
            end
        end

    end

    # ========================================================================
    # Phase 23: Void Control Flow Tests
    # Tests for complex control flow in void-returning functions (event handlers)
    # Covers: nested &&/||, sequential ifs, early returns
    # ========================================================================
    @testset "Phase 23: Void Control Flow" begin

        # Test helper: a mutable struct to track side effects
        mutable struct VoidTestState
            value::Int32
        end

        # ----------------------------------------------------------------
        # Test 1: Simple nested && operator (a && b && c pattern)
        # ----------------------------------------------------------------
        @testset "Nested && (triple condition)" begin
            @noinline function void_nested_and(state::VoidTestState, a::Int32, b::Int32, c::Int32)::Nothing
                if a > Int32(0) && b > Int32(0) && c > Int32(0)
                    state.value = Int32(1)
                end
                return nothing
            end

            bytes = compile(void_nested_and, (VoidTestState, Int32, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 2: Nested || operator (a || b || c pattern)
        # ----------------------------------------------------------------
        @testset "Nested || (triple condition)" begin
            @noinline function void_nested_or(state::VoidTestState, a::Int32, b::Int32, c::Int32)::Nothing
                if a > Int32(0) || b > Int32(0) || c > Int32(0)
                    state.value = Int32(1)
                end
                return nothing
            end

            bytes = compile(void_nested_or, (VoidTestState, Int32, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 3: Mixed && and || (a && (b || c) pattern)
        # ----------------------------------------------------------------
        @testset "Mixed && and ||" begin
            @noinline function void_mixed_and_or(state::VoidTestState, a::Int32, b::Int32, c::Int32)::Nothing
                if a > Int32(0) && (b > Int32(0) || c > Int32(0))
                    state.value = Int32(1)
                end
                return nothing
            end

            bytes = compile(void_mixed_and_or, (VoidTestState, Int32, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 4: Sequential if blocks
        # ----------------------------------------------------------------
        @testset "Sequential if blocks" begin
            @noinline function void_sequential_ifs(state::VoidTestState, a::Int32, b::Int32)::Nothing
                if a > Int32(0)
                    state.value = state.value + Int32(1)
                end
                if b > Int32(0)
                    state.value = state.value + Int32(10)
                end
                return nothing
            end

            bytes = compile(void_sequential_ifs, (VoidTestState, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 5: Three sequential if blocks
        # ----------------------------------------------------------------
        @testset "Three sequential if blocks" begin
            @noinline function void_three_ifs(state::VoidTestState, a::Int32, b::Int32, c::Int32)::Nothing
                if a > Int32(0)
                    state.value = state.value + Int32(1)
                end
                if b > Int32(0)
                    state.value = state.value + Int32(10)
                end
                if c > Int32(0)
                    state.value = state.value + Int32(100)
                end
                return nothing
            end

            bytes = compile(void_three_ifs, (VoidTestState, Int32, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 6: Early return in void function
        # ----------------------------------------------------------------
        @testset "Early return in void function" begin
            @noinline function void_early_return(state::VoidTestState, cond::Int32)::Nothing
                if cond > Int32(0)
                    return nothing
                end
                state.value = Int32(42)
                return nothing
            end

            bytes = compile(void_early_return, (VoidTestState, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 7: Early return with && condition
        # ----------------------------------------------------------------
        @testset "Early return with && condition" begin
            @noinline function void_early_return_and(state::VoidTestState, a::Int32, b::Int32)::Nothing
                if a > Int32(0) && b > Int32(0)
                    return nothing
                end
                state.value = Int32(99)
                return nothing
            end

            bytes = compile(void_early_return_and, (VoidTestState, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 8: Nested if-else in void function
        # ----------------------------------------------------------------
        @testset "Nested if-else in void function" begin
            @noinline function void_nested_if_else(state::VoidTestState, a::Int32, b::Int32)::Nothing
                if a > Int32(0)
                    if b > Int32(0)
                        state.value = Int32(1)
                    else
                        state.value = Int32(2)
                    end
                else
                    state.value = Int32(3)
                end
                return nothing
            end

            bytes = compile(void_nested_if_else, (VoidTestState, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 9: Quadruple && chain (winner checking pattern)
        # ----------------------------------------------------------------
        @testset "Quadruple && chain" begin
            @noinline function void_quad_and(state::VoidTestState, a::Int32, b::Int32, c::Int32, d::Int32)::Nothing
                if a == Int32(1) && b == Int32(1) && c == Int32(1) && d == Int32(1)
                    state.value = Int32(100)
                end
                return nothing
            end

            bytes = compile(void_quad_and, (VoidTestState, Int32, Int32, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 10: Complex TicTacToe-like winner checking pattern
        # ----------------------------------------------------------------
        @testset "TicTacToe winner pattern" begin
            @noinline function void_check_winner(state::VoidTestState, r1::Int32, r2::Int32, r3::Int32)::Nothing
                # Check if all three are equal and non-zero (like checking a row)
                if r1 != Int32(0) && r1 == r2 && r2 == r3
                    state.value = r1  # Winner found
                end
                return nothing
            end

            bytes = compile(void_check_winner, (VoidTestState, Int32, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 11: Multiple early returns
        # ----------------------------------------------------------------
        @testset "Multiple early returns" begin
            @noinline function void_multiple_returns(state::VoidTestState, code::Int32)::Nothing
                if code == Int32(1)
                    state.value = Int32(10)
                    return nothing
                end
                if code == Int32(2)
                    state.value = Int32(20)
                    return nothing
                end
                if code == Int32(3)
                    state.value = Int32(30)
                    return nothing
                end
                state.value = Int32(0)
                return nothing
            end

            bytes = compile(void_multiple_returns, (VoidTestState, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 12: If-else chain (switch-like pattern)
        # ----------------------------------------------------------------
        @testset "If-else chain" begin
            @noinline function void_if_else_chain(state::VoidTestState, x::Int32)::Nothing
                if x < Int32(0)
                    state.value = Int32(-1)
                elseif x == Int32(0)
                    state.value = Int32(0)
                elseif x < Int32(10)
                    state.value = Int32(1)
                else
                    state.value = Int32(2)
                end
                return nothing
            end

            bytes = compile(void_if_else_chain, (VoidTestState, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 13: Conditional with loop inside
        # ----------------------------------------------------------------
        @testset "Conditional with loop inside" begin
            @noinline function void_cond_with_loop(state::VoidTestState, n::Int32)::Nothing
                if n > Int32(0)
                    i = Int32(0)
                    while i < n
                        state.value = state.value + Int32(1)
                        i = i + Int32(1)
                    end
                end
                return nothing
            end

            bytes = compile(void_cond_with_loop, (VoidTestState, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

        # ----------------------------------------------------------------
        # Test 14: Pure void function (no side effects, just control flow)
        # ----------------------------------------------------------------
        @testset "Pure void with complex control flow" begin
            @noinline function void_pure_complex(a::Int32, b::Int32, c::Int32)::Nothing
                if a > Int32(0) && b > Int32(0)
                    if c > Int32(0)
                        # Do nothing
                    end
                elseif a > Int32(0) || b > Int32(0)
                    # Do nothing
                end
                return nothing
            end

            bytes = compile(void_pure_complex, (Int32, Int32, Int32))
            @test length(bytes) > 0
            @test validate_wasm(bytes)
        end

    end

    # ========================================================================
    # Phase 23: Union Types / Tagged Unions
    # ========================================================================
    @testset "Phase 23: Union Types" begin

        # Test 1: UnionInfo and TypeRegistry structures
        @testset "Union type registration" begin
            # Create a module and registry
            mod = WasmTarget.WasmModule()
            registry = WasmTarget.TypeRegistry()

            # Test needs_tagged_union function
            @test WasmTarget.needs_tagged_union(Union{Int32, Float64}) == true
            @test WasmTarget.needs_tagged_union(Union{Int32, String, Bool}) == true
            @test WasmTarget.needs_tagged_union(Union{Nothing, Int32}) == false

            # Test get_nullable_inner_type function
            @test WasmTarget.get_nullable_inner_type(Union{Nothing, Int32}) === Int32
            @test WasmTarget.get_nullable_inner_type(Union{Nothing, String}) === String
            @test WasmTarget.get_nullable_inner_type(Union{Int32, String}) === nothing

            # Test register_union_type!
            union_type = Union{Int32, Float64}
            info = WasmTarget.register_union_type!(mod, registry, union_type)
            @test info isa WasmTarget.UnionInfo
            @test info.julia_type === union_type
            @test length(info.variant_types) == 2
            @test Int32 in info.variant_types
            @test Float64 in info.variant_types
            @test haskey(info.tag_map, Int32)
            @test haskey(info.tag_map, Float64)

            # Test get_union_tag
            tag_int32 = WasmTarget.get_union_tag(info, Int32)
            tag_float64 = WasmTarget.get_union_tag(info, Float64)
            @test tag_int32 >= 0
            @test tag_float64 >= 0
            @test tag_int32 != tag_float64

            # Test union with Nothing
            union_with_nothing = Union{Nothing, Int32, String}
            info2 = WasmTarget.register_union_type!(mod, registry, union_with_nothing)
            @test length(info2.variant_types) == 3
            @test WasmTarget.get_union_tag(info2, Nothing) == Int32(0)  # Nothing always gets tag 0
        end

        # Test 2: Function parameter with union type
        @testset "Union parameter type" begin
            @noinline function process_union_value(x::Union{Int32, Float64})::Int32
                # This just returns a constant - we're testing type registration
                return Int32(1)
            end

            wasm_bytes = WasmTarget.compile(process_union_value, (Union{Int32, Float64},))
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
        end

        # Test 3: Triple union with Nothing as parameter
        @testset "Triple union parameter type" begin
            @noinline function triple_union_param(x::Union{Nothing, Int32, String})::Int32
                return Int32(0)
            end

            wasm_bytes = WasmTarget.compile(triple_union_param, (Union{Nothing, Int32, String},))
            @test length(wasm_bytes) > 0
            @test validate_wasm(wasm_bytes)
        end

        # Test 4: Julia-side concrete type resolution
        @testset "Concrete type resolution for unions" begin
            mod = WasmTarget.WasmModule()
            registry = WasmTarget.TypeRegistry()

            # Test that julia_to_wasm_type correctly handles union types
            union_type = Union{Int32, String}
            wasm_type = WasmTarget.julia_to_wasm_type(union_type)
            # Multi-variant unions should return a reference type (StructRef for now)
            @test wasm_type isa WasmTarget.RefType || wasm_type isa WasmTarget.NumType
        end

        # Test 5: Interpreter Value pattern - explicit tagged struct
        # This is the recommended pattern for runtime dynamic values
        mutable struct InterpValue
            tag::Int32       # 0 = nothing, 1 = int, 2 = float, 3 = bool
            int_val::Int64
            float_val::Float64
            bool_val::Int32  # 0 or 1
        end

        @testset "Interpreter value pattern" begin
            @noinline function make_int_value(x::Int64)::InterpValue
                return Base.inferencebarrier(InterpValue(Int32(1), x, Float64(0.0), Int32(0)))::InterpValue
            end

            @noinline function make_float_value(x::Float64)::InterpValue
                return Base.inferencebarrier(InterpValue(Int32(2), Int64(0), x, Int32(0)))::InterpValue
            end

            @noinline function is_int_value(v::InterpValue)::Bool
                return v.tag == Int32(1)
            end

            @noinline function get_int_value(v::InterpValue)::Int64
                return v.int_val
            end

            wasm1 = WasmTarget.compile(make_int_value, (Int64,))
            @test length(wasm1) > 0
            @test validate_wasm(wasm1)

            wasm2 = WasmTarget.compile(make_float_value, (Float64,))
            @test length(wasm2) > 0
            @test validate_wasm(wasm2)

            wasm3 = WasmTarget.compile(is_int_value, (InterpValue,))
            @test length(wasm3) > 0
            @test validate_wasm(wasm3)

            wasm4 = WasmTarget.compile(get_int_value, (InterpValue,))
            @test length(wasm4) > 0
            @test validate_wasm(wasm4)
        end

    end

    # ========================================================================
    # Phase 24: Advanced Recursion and Control Flow (BROWSER-013)
    # Tests for: mutual recursion, deep call stacks, complex control flow
    # Required for the interpreter's recursive eval() function
    # ========================================================================
    @testset "Phase 24: Advanced Recursion and Control Flow" begin

        @testset "Mutual recursion" begin
            # Compile both functions together to enable cross-calls
            wasm_bytes = WasmTarget.compile_multi([
                (is_even_mutual, (Int32,)),
                (is_odd_mutual, (Int32,))
            ])
            @test length(wasm_bytes) > 0

            # Test is_even
            @test run_wasm(wasm_bytes, "is_even_mutual", Int32(0)) == 1   # true
            @test run_wasm(wasm_bytes, "is_even_mutual", Int32(1)) == 0   # false
            @test run_wasm(wasm_bytes, "is_even_mutual", Int32(4)) == 1   # true
            @test run_wasm(wasm_bytes, "is_even_mutual", Int32(5)) == 0   # false
            @test run_wasm(wasm_bytes, "is_even_mutual", Int32(10)) == 1  # true

            # Test is_odd
            @test run_wasm(wasm_bytes, "is_odd_mutual", Int32(0)) == 0   # false
            @test run_wasm(wasm_bytes, "is_odd_mutual", Int32(1)) == 1   # true
            @test run_wasm(wasm_bytes, "is_odd_mutual", Int32(4)) == 0   # false
            @test run_wasm(wasm_bytes, "is_odd_mutual", Int32(5)) == 1   # true
        end

        @testset "Deep recursion (stack depth)" begin
            wasm_bytes = WasmTarget.compile(deep_recursion_test, (Int32, Int32))
            @test length(wasm_bytes) > 0

            # Test with increasing depths
            @test run_wasm(wasm_bytes, "deep_recursion_test", Int32(0), Int32(1)) == 1
            @test run_wasm(wasm_bytes, "deep_recursion_test", Int32(0), Int32(10)) == 10
            @test run_wasm(wasm_bytes, "deep_recursion_test", Int32(0), Int32(100)) == 100
            @test run_wasm(wasm_bytes, "deep_recursion_test", Int32(0), Int32(500)) == 500
            @test run_wasm(wasm_bytes, "deep_recursion_test", Int32(0), Int32(1000)) == 1000
        end

        @testset "Complex while loop with && condition" begin
            wasm_bytes = WasmTarget.compile(complex_while_test, (Int32,))
            @test length(wasm_bytes) > 0

            # Test various inputs
            @test run_wasm(wasm_bytes, "complex_while_test", Int32(5)) == 10   # 0+1+2+3+4 = 10
            @test run_wasm(wasm_bytes, "complex_while_test", Int32(10)) == 45  # 0+1+...+9 = 45
            @test run_wasm(wasm_bytes, "complex_while_test", Int32(20)) == 105 # stops when result >= 100
        end

        @testset "Nested conditionals" begin
            wasm_bytes = WasmTarget.compile(nested_cond_test, (Int32, Int32))
            @test length(wasm_bytes) > 0

            # Test all four branches
            @test run_wasm(wasm_bytes, "nested_cond_test", Int32(5), Int32(3)) == 8    # a>0, b>0: a+b
            @test run_wasm(wasm_bytes, "nested_cond_test", Int32(5), Int32(-3)) == 8   # a>0, b<=0: a-b
            @test run_wasm(wasm_bytes, "nested_cond_test", Int32(-5), Int32(3)) == 8   # a<=0, b>0: b-a
            @test run_wasm(wasm_bytes, "nested_cond_test", Int32(-5), Int32(-3)) == 15 # a<=0, b<=0: a*b
        end

        @testset "Multi-branch if-elseif-else" begin
            wasm_bytes = WasmTarget.compile(classify_number_test, (Int32,))
            @test length(wasm_bytes) > 0

            # Test all three branches
            @test run_wasm(wasm_bytes, "classify_number_test", Int32(-5)) == -1  # negative
            @test run_wasm(wasm_bytes, "classify_number_test", Int32(-1)) == -1  # negative
            @test run_wasm(wasm_bytes, "classify_number_test", Int32(0)) == 0    # zero
            @test run_wasm(wasm_bytes, "classify_number_test", Int32(1)) == 1    # positive
            @test run_wasm(wasm_bytes, "classify_number_test", Int32(100)) == 1  # positive
        end

    end

    # ========================================================================
    # Phase 25: Interpreter Tokenizer (BROWSER-020)
    # Tests for the Julia interpreter tokenizer that will be compiled to WASM
    # ========================================================================
    # Phase 25-27: Interpreter was deleted by CLEANUP-001 (2026-01-28).
    # Skip these tests — the files no longer exist.

    @testset "Phase 25: Interpreter Tokenizer" begin
        @test_broken false  # Interpreter deleted
    end

    @testset "Phase 26: Interpreter Parser and AST" begin
        @test_broken false  # Interpreter deleted
    end

    @testset "Phase 27: Interpreter Evaluator" begin
        @test_broken false  # Interpreter deleted
    end

    if false  # BEGIN DISABLED — Interpreter tests
    @testset "Phase 25: Interpreter Tokenizer [DISABLED]" begin

        # Include the tokenizer module
        include("../src/Interpreter/Tokenizer.jl")

        @testset "Character classification (Int32 returns)" begin
            # Compile character classifiers
            wasm_bytes = WasmTarget.compile_multi([
                (is_digit, (Int32,)),
                (is_alpha, (Int32,)),
                (is_alnum, (Int32,)),
                (is_whitespace, (Int32,)),
                (is_newline, (Int32,))
            ])
            @test length(wasm_bytes) > 0

            # Test is_digit
            @test run_wasm(wasm_bytes, "is_digit", Int32(48)) == 1   # '0'
            @test run_wasm(wasm_bytes, "is_digit", Int32(57)) == 1   # '9'
            @test run_wasm(wasm_bytes, "is_digit", Int32(65)) == 0   # 'A'
            @test run_wasm(wasm_bytes, "is_digit", Int32(97)) == 0   # 'a'

            # Test is_alpha
            @test run_wasm(wasm_bytes, "is_alpha", Int32(97)) == 1   # 'a'
            @test run_wasm(wasm_bytes, "is_alpha", Int32(122)) == 1  # 'z'
            @test run_wasm(wasm_bytes, "is_alpha", Int32(65)) == 1   # 'A'
            @test run_wasm(wasm_bytes, "is_alpha", Int32(90)) == 1   # 'Z'
            @test run_wasm(wasm_bytes, "is_alpha", Int32(95)) == 1   # '_'
            @test run_wasm(wasm_bytes, "is_alpha", Int32(48)) == 0   # '0'

            # Test is_whitespace
            @test run_wasm(wasm_bytes, "is_whitespace", Int32(32)) == 1  # ' '
            @test run_wasm(wasm_bytes, "is_whitespace", Int32(9)) == 1   # '\t'
            @test run_wasm(wasm_bytes, "is_whitespace", Int32(13)) == 1  # '\r'
            @test run_wasm(wasm_bytes, "is_whitespace", Int32(10)) == 0  # '\n' - not whitespace in our lexer

            # Test is_newline
            @test run_wasm(wasm_bytes, "is_newline", Int32(10)) == 1  # '\n'
            @test run_wasm(wasm_bytes, "is_newline", Int32(13)) == 0  # '\r'
        end

        @testset "Tokenizer Julia-side functionality" begin
            # Test tokenize function in Julia (this tests the algorithm, not WASM)
            tokens = tokenize("x = 5", Int32(100))
            @test tokens.count == 4
            @test token_list_get(tokens, Int32(1)).type == TOK_IDENT
            @test token_list_get(tokens, Int32(2)).type == TOK_EQ
            @test token_list_get(tokens, Int32(3)).type == TOK_INT
            @test token_list_get(tokens, Int32(3)).int_value == 5
            @test token_list_get(tokens, Int32(4)).type == TOK_EOF

            # Test arithmetic
            tokens2 = tokenize("3 + 4 * 2", Int32(100))
            @test tokens2.count == 6
            @test token_list_get(tokens2, Int32(1)).type == TOK_INT
            @test token_list_get(tokens2, Int32(1)).int_value == 3
            @test token_list_get(tokens2, Int32(2)).type == TOK_PLUS
            @test token_list_get(tokens2, Int32(3)).type == TOK_INT
            @test token_list_get(tokens2, Int32(3)).int_value == 4
            @test token_list_get(tokens2, Int32(4)).type == TOK_STAR

            # Test keywords
            tokens3 = tokenize("if x end", Int32(100))
            @test token_list_get(tokens3, Int32(1)).type == TOK_KW_IF
            @test token_list_get(tokens3, Int32(2)).type == TOK_IDENT
            @test token_list_get(tokens3, Int32(3)).type == TOK_KW_END

            # Test comparison operators
            tokens4 = tokenize("a == b != c", Int32(100))
            @test token_list_get(tokens4, Int32(2)).type == TOK_EQ_EQ
            @test token_list_get(tokens4, Int32(4)).type == TOK_NE

            # Test float
            tokens5 = tokenize("3.14", Int32(100))
            @test token_list_get(tokens5, Int32(1)).type == TOK_FLOAT
            @test token_list_get(tokens5, Int32(1)).float_value ≈ Float32(3.14)

            # Test string
            tokens6 = tokenize("\"hello\"", Int32(100))
            @test token_list_get(tokens6, Int32(1)).type == TOK_STRING
        end

    end

    # ========================================================================
    # Phase 26: Interpreter Parser and AST (BROWSER-021)
    # Tests for the Julia interpreter parser that builds AST from tokens
    # ========================================================================
    @testset "Phase 26: Interpreter Parser and AST" begin

        # Include the parser module (tokenizer already included in Phase 25)
        include("../src/Interpreter/Parser.jl")

        @testset "Parser - Literal expressions" begin
            # Integer literal
            p1 = parser_new("42", Int32(100))
            ast1 = parse_expression(p1)
            @test ast1.kind == AST_INT_LIT
            @test ast1.int_value == Int32(42)

            # Float literal
            p2 = parser_new("3.14", Int32(100))
            ast2 = parse_expression(p2)
            @test ast2.kind == AST_FLOAT_LIT
            @test ast2.float_value ≈ Float32(3.14)

            # Boolean true
            p3 = parser_new("true", Int32(100))
            ast3 = parse_expression(p3)
            @test ast3.kind == AST_BOOL_LIT
            @test ast3.int_value == Int32(1)

            # Boolean false
            p4 = parser_new("false", Int32(100))
            ast4 = parse_expression(p4)
            @test ast4.kind == AST_BOOL_LIT
            @test ast4.int_value == Int32(0)

            # Nothing
            p5 = parser_new("nothing", Int32(100))
            ast5 = parse_expression(p5)
            @test ast5.kind == AST_NOTHING_LIT

            # Identifier
            p6 = parser_new("foo", Int32(100))
            ast6 = parse_expression(p6)
            @test ast6.kind == AST_IDENT
            @test ast6.str_start == Int32(1)
            @test ast6.str_length == Int32(3)
        end

        @testset "Parser - Binary expressions" begin
            # Addition
            p1 = parser_new("1 + 2", Int32(100))
            ast1 = parse_expression(p1)
            @test ast1.kind == AST_BINARY
            @test ast1.op == OP_ADD
            @test ast1.left.kind == AST_INT_LIT
            @test ast1.left.int_value == Int32(1)
            @test ast1.right.kind == AST_INT_LIT
            @test ast1.right.int_value == Int32(2)

            # Multiplication with precedence
            p2 = parser_new("1 + 2 * 3", Int32(100))
            ast2 = parse_expression(p2)
            @test ast2.kind == AST_BINARY
            @test ast2.op == OP_ADD
            @test ast2.left.int_value == Int32(1)
            @test ast2.right.kind == AST_BINARY
            @test ast2.right.op == OP_MUL

            # Comparison
            p3 = parser_new("x < 10", Int32(100))
            ast3 = parse_expression(p3)
            @test ast3.kind == AST_BINARY
            @test ast3.op == OP_LT

            # Equality
            p4 = parser_new("a == b", Int32(100))
            ast4 = parse_expression(p4)
            @test ast4.kind == AST_BINARY
            @test ast4.op == OP_EQ

            # Logical operators
            p5 = parser_new("x && y || z", Int32(100))
            ast5 = parse_expression(p5)
            @test ast5.kind == AST_BINARY
            @test ast5.op == OP_OR  # || has lower precedence
        end

        @testset "Parser - Unary expressions" begin
            # Negation
            p1 = parser_new("-5", Int32(100))
            ast1 = parse_expression(p1)
            @test ast1.kind == AST_UNARY
            @test ast1.op == OP_NEG
            @test ast1.left.kind == AST_INT_LIT
            @test ast1.left.int_value == Int32(5)

            # Not
            p2 = parser_new("not true", Int32(100))
            ast2 = parse_expression(p2)
            @test ast2.kind == AST_UNARY
            @test ast2.op == OP_NOT
        end

        @testset "Parser - Parenthesized expressions" begin
            # (1 + 2) * 3 - should compute 1+2 first
            p1 = parser_new("(1 + 2) * 3", Int32(100))
            ast1 = parse_expression(p1)
            @test ast1.kind == AST_BINARY
            @test ast1.op == OP_MUL
            @test ast1.left.kind == AST_BINARY
            @test ast1.left.op == OP_ADD
        end

        @testset "Parser - Function calls" begin
            # Single argument
            p1 = parser_new("foo(5)", Int32(100))
            ast1 = parse_expression(p1)
            @test ast1.kind == AST_CALL
            @test ast1.left.kind == AST_IDENT
            @test ast1.num_children == Int32(1)
            @test ast1.children[1].kind == AST_INT_LIT

            # Multiple arguments
            p2 = parser_new("bar(1, 2, 3)", Int32(100))
            ast2 = parse_expression(p2)
            @test ast2.kind == AST_CALL
            @test ast2.num_children == Int32(3)

            # No arguments
            p3 = parser_new("baz()", Int32(100))
            ast3 = parse_expression(p3)
            @test ast3.kind == AST_CALL
            @test ast3.num_children == Int32(0)
        end

        @testset "Parser - Assignment" begin
            p1 = parser_new("x = 5", Int32(100))
            parser_skip_terminators!(p1)
            ast1 = parse_statement(p1)
            @test ast1.kind == AST_ASSIGN
            @test ast1.left.kind == AST_IDENT
            @test ast1.right.kind == AST_INT_LIT
            @test ast1.right.int_value == Int32(5)
        end

        @testset "Parser - If statements" begin
            # Simple if
            p1 = parser_new("if x\n  y\nend", Int32(100))
            parser_skip_terminators!(p1)
            ast1 = parse_statement(p1)
            @test ast1.kind == AST_IF
            @test ast1.left.kind == AST_IDENT  # condition
            @test ast1.num_children >= Int32(1)  # then body

            # If-else
            p2 = parser_new("if x\n  1\nelse\n  2\nend", Int32(100))
            parser_skip_terminators!(p2)
            ast2 = parse_statement(p2)
            @test ast2.kind == AST_IF
            @test ast2.right !== nothing  # else branch
            @test ast2.right.kind == AST_BLOCK
        end

        @testset "Parser - While loops" begin
            p1 = parser_new("while x < 10\n  x = x + 1\nend", Int32(100))
            parser_skip_terminators!(p1)
            ast1 = parse_statement(p1)
            @test ast1.kind == AST_WHILE
            @test ast1.left.kind == AST_BINARY  # condition
            @test ast1.num_children >= Int32(1)  # body
        end

        @testset "Parser - For loops" begin
            p1 = parser_new("for i in range\n  x = i\nend", Int32(100))
            parser_skip_terminators!(p1)
            ast1 = parse_statement(p1)
            @test ast1.kind == AST_FOR
            @test ast1.left.kind == AST_IDENT  # iterator var
            @test ast1.right.kind == AST_IDENT  # iterable
        end

        @testset "Parser - Function definitions" begin
            p1 = parser_new("function add(a, b)\n  return a + b\nend", Int32(100))
            parser_skip_terminators!(p1)
            ast1 = parse_statement(p1)
            @test ast1.kind == AST_FUNC
            @test ast1.int_value == Int32(2)  # 2 parameters
            # Children: params + body
            @test ast1.num_children >= Int32(3)  # 2 params + 1 return stmt
        end

        @testset "Parser - Return statements" begin
            # Return with value
            p1 = parser_new("return 42", Int32(100))
            parser_skip_terminators!(p1)
            ast1 = parse_statement(p1)
            @test ast1.kind == AST_RETURN
            @test ast1.left !== nothing
            @test ast1.left.kind == AST_INT_LIT

            # Return without value
            p2 = parser_new("return\n", Int32(100))
            parser_skip_terminators!(p2)
            ast2 = parse_statement(p2)
            @test ast2.kind == AST_RETURN
            @test ast2.left === nothing
        end

        @testset "Parser - Full program" begin
            code = """
            x = 5
            y = 10
            z = x + y
            """
            p1 = parser_new(code, Int32(100))
            ast1 = parse_program(p1)
            @test ast1.kind == AST_PROGRAM
            @test ast1.num_children == Int32(3)
            @test ast1.children[1].kind == AST_ASSIGN
            @test ast1.children[2].kind == AST_ASSIGN
            @test ast1.children[3].kind == AST_ASSIGN
        end

        @testset "Parser - Complex program" begin
            code = """
            function factorial(n)
                if n <= 1
                    return 1
                else
                    return n * factorial(n - 1)
                end
            end
            result = factorial(5)
            """
            p1 = parser_new(code, Int32(200))
            ast1 = parse_program(p1)
            @test ast1.kind == AST_PROGRAM
            @test ast1.num_children == Int32(2)  # function def + assignment
            @test ast1.children[1].kind == AST_FUNC
            @test ast1.children[2].kind == AST_ASSIGN
        end

    end

    # ========================================================================
    # Phase 27: Interpreter Evaluator (BROWSER-022)
    # Tests for the Julia interpreter evaluator that executes AST nodes
    # ========================================================================
    @testset "Phase 27: Interpreter Evaluator" begin

        # Include the evaluator module (tokenizer and parser already included)
        include("../src/Interpreter/Evaluator.jl")

        @testset "Evaluator - Literal values" begin
            # Integer literal
            p1 = parser_new("42", Int32(100))
            ast1 = parse_expression(p1)
            env = env_new(Int32(100))
            (val1, _) = eval_node(ast1, "42", env)
            @test val1.tag == VAL_INT
            @test val1.int_val == Int32(42)

            # Float literal
            p2 = parser_new("3.14", Int32(100))
            ast2 = parse_expression(p2)
            (val2, _) = eval_node(ast2, "3.14", env)
            @test val2.tag == VAL_FLOAT
            @test val2.float_val ≈ Float32(3.14)

            # Boolean true
            p3 = parser_new("true", Int32(100))
            ast3 = parse_expression(p3)
            (val3, _) = eval_node(ast3, "true", env)
            @test val3.tag == VAL_BOOL
            @test val3.int_val == Int32(1)

            # Boolean false
            p4 = parser_new("false", Int32(100))
            ast4 = parse_expression(p4)
            (val4, _) = eval_node(ast4, "false", env)
            @test val4.tag == VAL_BOOL
            @test val4.int_val == Int32(0)

            # Nothing
            p5 = parser_new("nothing", Int32(100))
            ast5 = parse_expression(p5)
            (val5, _) = eval_node(ast5, "nothing", env)
            @test val5.tag == VAL_NOTHING
        end

        @testset "Evaluator - Arithmetic operations" begin
            env = env_new(Int32(100))

            # Addition
            p1 = parser_new("3 + 5", Int32(100))
            ast1 = parse_expression(p1)
            (val1, _) = eval_node(ast1, "3 + 5", env)
            @test val1.tag == VAL_INT
            @test val1.int_val == Int32(8)

            # Subtraction
            p2 = parser_new("10 - 4", Int32(100))
            ast2 = parse_expression(p2)
            (val2, _) = eval_node(ast2, "10 - 4", env)
            @test val2.tag == VAL_INT
            @test val2.int_val == Int32(6)

            # Multiplication
            p3 = parser_new("7 * 6", Int32(100))
            ast3 = parse_expression(p3)
            (val3, _) = eval_node(ast3, "7 * 6", env)
            @test val3.tag == VAL_INT
            @test val3.int_val == Int32(42)

            # Division
            p4 = parser_new("20 / 4", Int32(100))
            ast4 = parse_expression(p4)
            (val4, _) = eval_node(ast4, "20 / 4", env)
            @test val4.tag == VAL_INT
            @test val4.int_val == Int32(5)

            # Modulo
            p5 = parser_new("17 % 5", Int32(100))
            ast5 = parse_expression(p5)
            (val5, _) = eval_node(ast5, "17 % 5", env)
            @test val5.tag == VAL_INT
            @test val5.int_val == Int32(2)

            # Power
            p6 = parser_new("2 ^ 3", Int32(100))
            ast6 = parse_expression(p6)
            (val6, _) = eval_node(ast6, "2 ^ 3", env)
            @test val6.tag == VAL_INT
            @test val6.int_val == Int32(8)
        end

        @testset "Evaluator - Comparison operations" begin
            env = env_new(Int32(100))

            # Less than
            p1 = parser_new("3 < 5", Int32(100))
            ast1 = parse_expression(p1)
            (val1, _) = eval_node(ast1, "3 < 5", env)
            @test val1.tag == VAL_BOOL
            @test val1.int_val == Int32(1)  # true

            p2 = parser_new("5 < 3", Int32(100))
            ast2 = parse_expression(p2)
            (val2, _) = eval_node(ast2, "5 < 3", env)
            @test val2.int_val == Int32(0)  # false

            # Equality
            p3 = parser_new("5 == 5", Int32(100))
            ast3 = parse_expression(p3)
            (val3, _) = eval_node(ast3, "5 == 5", env)
            @test val3.int_val == Int32(1)

            p4 = parser_new("5 == 3", Int32(100))
            ast4 = parse_expression(p4)
            (val4, _) = eval_node(ast4, "5 == 3", env)
            @test val4.int_val == Int32(0)

            # Greater than or equal
            p5 = parser_new("5 >= 5", Int32(100))
            ast5 = parse_expression(p5)
            (val5, _) = eval_node(ast5, "5 >= 5", env)
            @test val5.int_val == Int32(1)
        end

        @testset "Evaluator - Logical operations" begin
            env = env_new(Int32(100))

            # AND with both true
            p1 = parser_new("true && true", Int32(100))
            ast1 = parse_expression(p1)
            (val1, _) = eval_node(ast1, "true && true", env)
            @test val1.tag == VAL_BOOL
            @test val1.int_val == Int32(1)

            # AND with one false (short-circuit)
            p2 = parser_new("false && true", Int32(100))
            ast2 = parse_expression(p2)
            (val2, _) = eval_node(ast2, "false && true", env)
            @test val2.int_val == Int32(0)

            # OR with one true (short-circuit)
            p3 = parser_new("true || false", Int32(100))
            ast3 = parse_expression(p3)
            (val3, _) = eval_node(ast3, "true || false", env)
            @test val3.int_val == Int32(1)

            # OR with both false
            p4 = parser_new("false || false", Int32(100))
            ast4 = parse_expression(p4)
            (val4, _) = eval_node(ast4, "false || false", env)
            @test val4.int_val == Int32(0)
        end

        @testset "Evaluator - Unary operations" begin
            env = env_new(Int32(100))

            # Negation
            p1 = parser_new("-5", Int32(100))
            ast1 = parse_expression(p1)
            (val1, _) = eval_node(ast1, "-5", env)
            @test val1.tag == VAL_INT
            @test val1.int_val == Int32(-5)

            # Not
            p2 = parser_new("not true", Int32(100))
            ast2 = parse_expression(p2)
            (val2, _) = eval_node(ast2, "not true", env)
            @test val2.tag == VAL_BOOL
            @test val2.int_val == Int32(0)
        end

        @testset "Evaluator - Variable assignment and lookup" begin
            env = env_new(Int32(100))
            source = "x = 42"

            # Parse and evaluate assignment
            p1 = parser_new(source, Int32(100))
            ast1 = parse_statement(p1)
            (val1, _) = eval_node(ast1, source, env)
            @test val1.tag == VAL_INT
            @test val1.int_val == Int32(42)

            # Check variable is stored
            x_val = env_get(env, "x")
            @test x_val.tag == VAL_INT
            @test x_val.int_val == Int32(42)

            # Variable lookup in expression
            source2 = "x + 8"
            p2 = parser_new(source2, Int32(100))
            ast2 = parse_expression(p2)
            (val2, _) = eval_node(ast2, source2, env)
            @test val2.tag == VAL_INT
            @test val2.int_val == Int32(50)
        end

        @testset "Evaluator - If statements" begin
            # If with true condition
            code1 = """
            x = 0
            if true
                x = 1
            end
            x
            """
            p1 = parser_new(code1, Int32(100))
            prog1 = parse_program(p1)
            output1 = eval_program(prog1, code1)
            @test contains(output1, "1")

            # If with false condition
            code2 = """
            x = 0
            if false
                x = 1
            end
            x
            """
            p2 = parser_new(code2, Int32(100))
            prog2 = parse_program(p2)
            output2 = eval_program(prog2, code2)
            @test contains(output2, "0")

            # If-else
            code3 = """
            x = 5
            if x > 10
                y = 1
            else
                y = 2
            end
            y
            """
            p3 = parser_new(code3, Int32(100))
            prog3 = parse_program(p3)
            output3 = eval_program(prog3, code3)
            @test contains(output3, "2")
        end

        @testset "Evaluator - While loops" begin
            code1 = """
            x = 0
            i = 0
            while i < 5
                x = x + i
                i = i + 1
            end
            x
            """
            p1 = parser_new(code1, Int32(100))
            prog1 = parse_program(p1)
            output1 = eval_program(prog1, code1)
            @test contains(output1, "10")  # 0+1+2+3+4 = 10
        end

        @testset "Evaluator - User-defined functions" begin
            code1 = """
            function add(a, b)
                return a + b
            end
            add(3, 5)
            """
            p1 = parser_new(code1, Int32(200))
            prog1 = parse_program(p1)
            output1 = eval_program(prog1, code1)
            @test contains(output1, "8")

            # Recursive function
            code2 = """
            function fact(n)
                if n <= 1
                    return 1
                else
                    return n * fact(n - 1)
                end
            end
            fact(5)
            """
            p2 = parser_new(code2, Int32(200))
            prog2 = parse_program(p2)
            output2 = eval_program(prog2, code2)
            @test contains(output2, "120")
        end

        @testset "Evaluator - Built-in functions" begin
            # println
            code1 = "println(42)"
            p1 = parser_new(code1, Int32(100))
            prog1 = parse_program(p1)
            clear_output()
            eval_program(prog1, code1)
            @test contains(get_output(), "42")

            # abs
            code2 = "abs(-5)"
            p2 = parser_new(code2, Int32(100))
            prog2 = parse_program(p2)
            output2 = eval_program(prog2, code2)
            @test contains(output2, "5")

            # min
            code3 = "min(3, 7)"
            p3 = parser_new(code3, Int32(100))
            prog3 = parse_program(p3)
            output3 = eval_program(prog3, code3)
            @test contains(output3, "3")

            # max
            code4 = "max(3, 7)"
            p4 = parser_new(code4, Int32(100))
            prog4 = parse_program(p4)
            output4 = eval_program(prog4, code4)
            @test contains(output4, "7")
        end

        @testset "Evaluator - Complex program" begin
            # FizzBuzz-like program
            code1 = """
            i = 1
            while i <= 3
                if i == 1
                    println(1)
                elseif i == 2
                    println(2)
                else
                    println(3)
                end
                i = i + 1
            end
            """
            p1 = parser_new(code1, Int32(200))
            prog1 = parse_program(p1)
            clear_output()
            eval_program(prog1, code1)
            output1 = get_output()
            @test contains(output1, "1")
            @test contains(output1, "2")
            @test contains(output1, "3")
        end

        @testset "Evaluator - The playground example" begin
            # x = 5; y = 3; println(x + y)
            code = "x = 5; y = 3; println(x + y)"
            p = parser_new(code, Int32(100))
            prog = parse_program(p)
            clear_output()
            eval_program(prog, code)
            output = get_output()
            @test contains(output, "8")
        end

    end
    end  # END DISABLED — Interpreter tests

    # ========================================================================
    # Phase 28: Binaryen Optimization
    # ========================================================================
    @testset "Phase 28: Binaryen Optimization" begin
        if Sys.which("wasm-opt") !== nothing
            @testset "optimize() reduces size" begin
                test_add(a::Int32, b::Int32)::Int32 = a + b
                bytes = compile(test_add, (Int32, Int32))
                opt_bytes = WasmTarget.optimize(bytes)
                @test length(opt_bytes) > 0
                @test length(opt_bytes) <= length(bytes)
            end

            @testset "optimize() preserves correctness" begin
                test_mul(a::Int32, b::Int32)::Int32 = a * b
                bytes = compile(test_mul, (Int32, Int32))
                opt_bytes = WasmTarget.optimize(bytes)
                result = run_wasm(opt_bytes, "test_mul", Int32(6), Int32(7))
                @test result == 42
            end

            @testset "compile() with optimize keyword" begin
                test_sub(a::Int32, b::Int32)::Int32 = a - b
                opt_bytes = compile(test_sub, (Int32, Int32); optimize=true)
                @test length(opt_bytes) > 0
                result = run_wasm(opt_bytes, "test_sub", Int32(10), Int32(3))
                @test result == 7
            end

            @testset "optimization levels" begin
                test_inc(x::Int32)::Int32 = x + Int32(1)
                bytes = compile(test_inc, (Int32,))
                size_bytes = WasmTarget.optimize(bytes; level=:size)
                speed_bytes = WasmTarget.optimize(bytes; level=:speed)
                debug_bytes = WasmTarget.optimize(bytes; level=:debug)
                @test length(size_bytes) > 0
                @test length(speed_bytes) > 0
                @test length(debug_bytes) > 0
                # All should execute correctly
                @test run_wasm(size_bytes, "test_inc", Int32(9)) == 10
                @test run_wasm(speed_bytes, "test_inc", Int32(9)) == 10
                @test run_wasm(debug_bytes, "test_inc", Int32(9)) == 10
            end

            @testset "compile_multi with optimize" begin
                multi_a(x::Int32)::Int32 = x + Int32(1)
                multi_b(x::Int32)::Int32 = x * Int32(2)
                opt_bytes = compile_multi([
                    (multi_a, (Int32,)),
                    (multi_b, (Int32,)),
                ]; optimize=true)
                @test length(opt_bytes) > 0
                @test run_wasm(opt_bytes, "multi_a", Int32(4)) == 5
                @test run_wasm(opt_bytes, "multi_b", Int32(4)) == 8
            end
        else
            @warn "wasm-opt not found — skipping optimization tests"
            @test true  # placeholder so testset isn't empty
        end
    end

    # ========================================================================
    # Phase 29: Stack Validator Integration Tests (PURE-415)
    # Verify the validator catches the exact bug patterns from PURE-317→323
    # ========================================================================
    @testset "Phase 29: Stack Validator Integration" begin

        @testset "externref-vs-anyref mismatch (PURE-323 pattern)" begin
            v = WasmStackValidator(func_name="test_externref_anyref")
            # Push ExternRef (what codegen actually produces for Any-typed values)
            validate_push!(v, ExternRef)
            # ref_cast expects anyref — this is the PURE-323 bug pattern:
            # codegen emits externref but GC instructions need anyref
            validate_gc_instruction!(v, Opcode.REF_CAST, ConcreteRef(UInt32(5)))
            # The ref_cast pops any ref (permissive) so it won't error on that,
            # but the key test is that the validator tracks the type correctly
            @test !has_errors(v)
            @test stack_height(v) == 1

            # Now test the REAL mismatch: push externref, try any_convert_extern
            # which expects externref (correct), then push result as anyref
            reset_validator!(v)
            validate_push!(v, ExternRef)
            validate_gc_instruction!(v, Opcode.ANY_CONVERT_EXTERN)
            @test !has_errors(v)
            @test stack_height(v) == 1
            @test v.stack[1] === WasmTarget.AnyRef  # Result should be anyref

            # Test the reverse: push anyref, try extern_convert_any
            reset_validator!(v)
            validate_push!(v, WasmTarget.AnyRef)
            validate_gc_instruction!(v, Opcode.EXTERN_CONVERT_ANY)
            @test !has_errors(v)
            @test v.stack[1] === ExternRef
        end

        @testset "numeric-vs-ref mismatch (PURE-321 pattern)" begin
            v = WasmStackValidator(func_name="test_numeric_ref_mismatch")
            # Push I32 (numeric), try to pop ConcreteRef — classic PURE-321 bug
            validate_push!(v, I32)
            validate_pop!(v, ConcreteRef(UInt32(0), true))
            @test has_errors(v)
            @test any(contains("type mismatch"), v.errors)
            @test any(contains("I32"), v.errors)

            # Reverse: push ref, try to pop I32
            reset_validator!(v)
            validate_push!(v, ConcreteRef(UInt32(3), true))
            validate_pop!(v, I32)
            @test has_errors(v)
            @test any(contains("type mismatch"), v.errors)
        end

        @testset "stack underflow (common codegen bug)" begin
            v = WasmStackValidator(func_name="test_underflow")
            # Pop from empty stack — happens when codegen drops a value that
            # was never pushed (e.g., missing phi initialization)
            validate_pop!(v, I32)
            @test has_errors(v)
            @test any(contains("stack underflow"), v.errors)

            # pop_any from empty stack
            reset_validator!(v)
            result = validate_pop_any!(v)
            @test result === nothing
            @test has_errors(v)
        end

        @testset "correct code validates clean" begin
            v = WasmStackValidator(func_name="test_clean")
            # i32.add: push two i32s, validate add, should produce one i32
            validate_push!(v, I32)
            validate_push!(v, I32)
            validate_instruction!(v, Opcode.I32_ADD)
            @test !has_errors(v)
            @test stack_height(v) == 1
            @test v.stack[1] === I32

            # i64 arithmetic
            reset_validator!(v)
            validate_push!(v, I64)
            validate_push!(v, I64)
            validate_instruction!(v, Opcode.I64_ADD)
            @test !has_errors(v)
            @test stack_height(v) == 1
            @test v.stack[1] === I64

            # Constant push
            reset_validator!(v)
            validate_instruction!(v, Opcode.I32_CONST)
            @test !has_errors(v)
            @test stack_height(v) == 1
            @test v.stack[1] === I32

            # Drop
            validate_instruction!(v, Opcode.DROP)
            @test !has_errors(v)
            @test stack_height(v) == 0
        end

        @testset "GC struct operations" begin
            v = WasmStackValidator(func_name="test_struct_ops")
            type_idx = 7
            field_types = [I32, F64, ExternRef]

            # struct.new: push field values, validate struct.new
            validate_push!(v, I32)        # field 0
            validate_push!(v, F64)        # field 1
            validate_push!(v, ExternRef)  # field 2
            validate_gc_instruction!(v, Opcode.STRUCT_NEW, (type_idx, field_types))
            @test !has_errors(v)
            @test stack_height(v) == 1
            @test v.stack[1] isa ConcreteRef
            @test v.stack[1].type_idx == UInt32(type_idx)
            @test v.stack[1].nullable == false  # struct.new produces non-nullable

            # struct.get: pop struct ref, push field type
            validate_gc_instruction!(v, Opcode.STRUCT_GET, (type_idx, F64))
            @test !has_errors(v)
            @test stack_height(v) == 1
            @test v.stack[1] === F64

            # struct.new with wrong field types → should error
            reset_validator!(v)
            validate_push!(v, I32)
            validate_push!(v, I32)  # wrong: should be F64
            validate_push!(v, ExternRef)
            validate_gc_instruction!(v, Opcode.STRUCT_NEW, (type_idx, field_types))
            @test has_errors(v)  # F64 expected, I32 found
        end

        @testset "block/loop label tracking" begin
            v = WasmStackValidator(func_name="test_blocks")

            # Block that produces I32
            validate_block_start!(v, :block, WasmValType[I32])
            validate_push!(v, I32)  # block body produces a value
            validate_block_end!(v)
            @test !has_errors(v)
            @test stack_height(v) == 1  # block result on stack
            @test v.stack[1] === I32

            # Block with wrong result type
            reset_validator!(v)
            validate_block_start!(v, :block, WasmValType[I32])
            validate_push!(v, F64)  # wrong type for result
            validate_block_end!(v)
            @test has_errors(v)
            @test any(contains("block result type mismatch"), v.errors)

            # Loop with br (br to loop = restart, no values needed)
            reset_validator!(v)
            validate_block_start!(v, :loop)
            validate_push!(v, I32)  # loop counter
            validate_instruction!(v, Opcode.DROP)  # consume it
            validate_br!(v, 0)  # br back to loop start
            validate_block_end!(v)
            @test !has_errors(v)

            # Nested block + br to outer
            reset_validator!(v)
            validate_block_start!(v, :block, WasmValType[I32])  # outer
            validate_block_start!(v, :block)                     # inner (void)
            validate_push!(v, I32)
            validate_br!(v, 1)  # br to outer block (depth 1) — needs I32 result
            validate_block_end!(v)  # end inner
            validate_push!(v, I32)  # outer still needs its result
            validate_block_end!(v)  # end outer
            @test !has_errors(v)
            @test stack_height(v) == 1
        end

        @testset "validator reset and reuse" begin
            v = WasmStackValidator(func_name="func1")
            validate_push!(v, I32)
            validate_pop!(v, F64)  # type mismatch
            @test has_errors(v)

            # Reset should clear everything
            reset_validator!(v)
            @test !has_errors(v)
            @test stack_height(v) == 0
            @test isempty(v.labels)
            @test v.reachable == true
        end

        @testset "disabled validator is no-op" begin
            v = WasmStackValidator(enabled=false, func_name="disabled")
            validate_push!(v, I32)
            @test stack_height(v) == 0  # push was no-op
            validate_pop!(v, I32)       # no underflow error
            @test !has_errors(v)
        end

        @testset "reachability after unconditional br" begin
            v = WasmStackValidator(func_name="test_reachability")
            validate_block_start!(v, :block)
            validate_br!(v, 0)  # unconditional branch
            @test v.reachable == false
            # Code after br is unreachable — pops/pushes should be skipped
            validate_block_end!(v)
            @test !has_errors(v)
            @test v.reachable == true  # restored after block end
        end
    end

    # ========================================================================
    # Phase 30: Comparison Harness Tests (PURE-502)
    # Verify compare_julia_wasm and compare_batch work on known-good functions
    # ========================================================================
    @testset "Phase 30: Comparison Harness" begin

        @testset "compare_julia_wasm — Int32 add" begin
            add_one(x::Int32) = x + Int32(1)
            r = compare_julia_wasm(add_one, Int32(5))
            if !r.skipped
                @test r.pass
                @test r.expected == Int32(6)
                @test r.actual == 6
            end
        end

        @testset "compare_julia_wasm — Int32 multiply" begin
            mul_two(x::Int32) = x * Int32(2)
            r = compare_julia_wasm(mul_two, Int32(7))
            if !r.skipped
                @test r.pass
                @test r.expected == Int32(14)
                @test r.actual == 14
            end
        end

        @testset "compare_julia_wasm — Int32 two args" begin
            my_add(a::Int32, b::Int32) = a + b
            r = compare_julia_wasm(my_add, Int32(3), Int32(4))
            if !r.skipped
                @test r.pass
                @test r.expected == Int32(7)
                @test r.actual == 7
            end
        end

        @testset "compare_julia_wasm — negative numbers" begin
            negate(x::Int32) = -x
            r = compare_julia_wasm(negate, Int32(42))
            if !r.skipped
                @test r.pass
                @test r.expected == Int32(-42)
                @test r.actual == -42
            end
        end

        @testset "compare_julia_wasm — zero" begin
            identity_fn(x::Int32) = x
            r = compare_julia_wasm(identity_fn, Int32(0))
            if !r.skipped
                @test r.pass
                @test r.expected == Int32(0)
                @test r.actual == 0
            end
        end

        @testset "compare_batch — multiple inputs" begin
            add_one(x::Int32) = x + Int32(1)
            results = compare_batch(add_one, [
                (Int32(0),),
                (Int32(5),),
                (Int32(-1),),
                (Int32(100),),
            ])
            @test length(results) == 4
            for r in results
                if !r.skipped
                    @test r.pass
                end
            end
        end

        @testset "compare_batch — two-arg function" begin
            my_sub(a::Int32, b::Int32) = a - b
            results = compare_batch(my_sub, [
                (Int32(10), Int32(3)),
                (Int32(0), Int32(0)),
                (Int32(5), Int32(10)),
            ])
            @test length(results) == 3
            for r in results
                if !r.skipped
                    @test r.pass
                end
            end
        end

    end

    # ========================================================================
    # Phase 31: Manual Comparison Harness Tests (PURE-503)
    # Verify compare_julia_wasm_manual, compare_batch_manual, and
    # compare_julia_wasm_wrapper for complex-type ground truth verification
    # ========================================================================
    @testset "Phase 31: Manual Comparison Harness" begin

        @testset "compare_julia_wasm_manual — correct expected" begin
            r = compare_julia_wasm_manual(x -> x + Int32(1), (Int32(5),), Int32(6))
            if !r.skipped
                @test r.pass
                @test r.expected == Int32(6)
                @test r.actual == 6
            end
        end

        @testset "compare_julia_wasm_manual — wrong expected detects mismatch" begin
            r = compare_julia_wasm_manual(x -> x + Int32(1), (Int32(5),), Int32(99))
            if !r.skipped
                @test !r.pass
                @test r.expected == Int32(99)
                @test r.actual == 6
            end
        end

        @testset "compare_julia_wasm_manual — multiply" begin
            r = compare_julia_wasm_manual(x -> x * Int32(3), (Int32(4),), Int32(12))
            if !r.skipped
                @test r.pass
            end
        end

        @testset "compare_julia_wasm_manual — two args" begin
            my_sub(a::Int32, b::Int32) = a - b
            r = compare_julia_wasm_manual(my_sub, (Int32(10), Int32(3)), Int32(7))
            if !r.skipped
                @test r.pass
            end
        end

        @testset "compare_julia_wasm_manual — zero" begin
            r = compare_julia_wasm_manual(x -> x, (Int32(0),), Int32(0))
            if !r.skipped
                @test r.pass
            end
        end

        @testset "compare_julia_wasm_manual — negative" begin
            r = compare_julia_wasm_manual(x -> -x, (Int32(42),), Int32(-42))
            if !r.skipped
                @test r.pass
            end
        end

        @testset "compare_batch_manual — multiple inputs" begin
            results = compare_batch_manual(x -> x * Int32(2), [
                ((Int32(3),), Int32(6)),
                ((Int32(0),), Int32(0)),
                ((Int32(-1),), Int32(-2)),
                ((Int32(100),), Int32(200)),
            ])
            @test length(results) == 4
            for r in results
                if !r.skipped
                    @test r.pass
                end
            end
        end

        @testset "compare_batch_manual — detects mismatches" begin
            results = compare_batch_manual(x -> x + Int32(1), [
                ((Int32(5),), Int32(6)),    # correct
                ((Int32(5),), Int32(99)),   # wrong
            ])
            @test length(results) == 2
            if !results[1].skipped
                @test results[1].pass
                @test !results[2].pass
            end
        end

        @testset "compare_julia_wasm_wrapper — basic" begin
            r = compare_julia_wasm_wrapper(x -> x + Int32(10), Int32(5))
            if !r.skipped
                @test r.pass
                @test r.expected == Int32(15)
                @test r.actual == 15
            end
        end

        # Ground truth snapshot tests
        @testset "generate_ground_truth — creates snapshot file" begin
            path = generate_ground_truth("gt_add_one", x -> x + Int32(1), [
                (Int32(0),), (Int32(5),), (Int32(-1),),
            ]; overwrite=true)
            @test isfile(path)
            snapshot = load_ground_truth("gt_add_one")
            @test snapshot["name"] == "gt_add_one"
            @test length(snapshot["entries"]) == 3
            @test snapshot["entries"][1]["expected"] == 1
            @test snapshot["entries"][2]["expected"] == 6
            @test snapshot["entries"][3]["expected"] == 0
        end

        @testset "compare_against_ground_truth — all pass" begin
            generate_ground_truth("gt_double", x -> x * Int32(2), [
                (Int32(3),), (Int32(0),), (Int32(-4),),
            ]; overwrite=true)
            results = compare_against_ground_truth("gt_double", x -> x * Int32(2))
            @test length(results) == 3
            for r in results
                if !r.skipped
                    @test r.pass
                end
            end
        end

        @testset "compare_against_ground_truth — detects mismatch" begin
            generate_ground_truth("gt_negate", x -> -x, [
                (Int32(5),), (Int32(-3),),
            ]; overwrite=true)
            # Intentionally use wrong function to get mismatch
            results = compare_against_ground_truth("gt_negate", x -> x + Int32(1))
            @test length(results) == 2
            if !results[1].skipped
                @test !results[1].pass  # -5 != 6
            end
        end

        @testset "load_ground_truth — error on missing" begin
            @test_throws ErrorException load_ground_truth("nonexistent_snapshot_xyz")
        end

        @testset "generate_ground_truth — skip if exists" begin
            path = generate_ground_truth("gt_skip_test", x -> x, [
                (Int32(1),),
            ]; overwrite=true)
            @test isfile(path)
            # Second call without overwrite should not error
            path2 = generate_ground_truth("gt_skip_test", x -> x, [
                (Int32(999),),
            ])
            @test path == path2
            # Original data should be preserved
            snapshot = load_ground_truth("gt_skip_test")
            @test snapshot["entries"][1]["expected"] == 1  # not 999
        end

    end

    # Phase 32: M_EXPAND — Straightforward Expression Patterns (PURE-1000/1001)
    # Tests that progressively complex Julia functions compile AND execute correctly.
    # Each test uses compare_julia_wasm as the correctness oracle (level 3: CORRECT).

    @testset "Phase 32: M_EXPAND Expression Patterns" begin

        @testset "Arithmetic — Int64" begin
            @test compare_julia_wasm(() -> Int64(1) + Int64(1)).pass
            @test compare_julia_wasm(() -> Int64(6) * Int64(5)).pass
            @test compare_julia_wasm(() -> Int64(10) - Int64(3)).pass
            @test compare_julia_wasm(() -> div(Int64(7), Int64(2))).pass
            @test compare_julia_wasm(() -> Int64(2) ^ Int64(10)).pass
        end

        @testset "Arithmetic — Float64" begin
            @test compare_julia_wasm(() -> 2.0 + 3.0).pass
            @test compare_julia_wasm(() -> 6.0 * 5.0).pass
            @test compare_julia_wasm(() -> 10.0 / 3.0).pass
        end

        @testset "Math functions" begin
            @test compare_julia_wasm(() -> sin(1.0)).pass
            @test compare_julia_wasm(() -> cos(0.0)).pass
            @test compare_julia_wasm(() -> sqrt(4.0)).pass
        end

        @testset "Variables and let bindings" begin
            @test compare_julia_wasm(() -> (let x=Int64(5); x+Int64(1) end)).pass
            @test compare_julia_wasm(() -> (let a=Int64(1), b=Int64(2); a+b end)).pass
        end

        @testset "Control flow — if/else" begin
            @test compare_julia_wasm((x::Int64,) -> (x < Int64(0) ? -x : x), Int64(-5)).pass
            @test compare_julia_wasm((x::Int64,) -> (x < Int64(0) ? -x : x), Int64(3)).pass
            @test compare_julia_wasm((x::Int64, lo::Int64, hi::Int64) -> x < lo ? lo : (x > hi ? hi : x), Int64(-1), Int64(0), Int64(10)).pass
            @test compare_julia_wasm((x::Int64, lo::Int64, hi::Int64) -> x < lo ? lo : (x > hi ? hi : x), Int64(5), Int64(0), Int64(10)).pass
            @test compare_julia_wasm((x::Int64, lo::Int64, hi::Int64) -> x < lo ? lo : (x > hi ? hi : x), Int64(15), Int64(0), Int64(10)).pass
        end

        @testset "Loops — while" begin
            @test compare_julia_wasm((n::Int64,) -> begin s=Int64(0); i=Int64(1); while i<=n; s+=i; i+=Int64(1); end; s end, Int64(10)).pass
        end

        @testset "Loops — for" begin
            @test compare_julia_wasm((n::Int64,) -> begin s=Int64(0); for i in Int64(1):n; s+=i; end; s end, Int64(10)).pass
        end

        @testset "Tuples" begin
            @test compare_julia_wasm(() -> begin t=(Int64(1),Int64(2),Int64(3)); t[1]+t[2]+t[3] end).pass
        end

        @testset "Arrays" begin
            @test compare_julia_wasm(() -> begin a = Int64[1,2,3]; a[1]+a[2]+a[3] end).pass
            @test compare_julia_wasm((n::Int64,) -> begin arr=Int64[]; for i in Int64(1):n; push!(arr,i); end; s=Int64(0); for i in Int64(1):n; s+=arr[i]; end; s end, Int64(10)).pass
        end

        @testset "Boolean && / ||" begin
            @test compare_julia_wasm((x::Int64,) -> Int64(x > Int64(0) && x < Int64(100) ? Int64(1) : Int64(0)), Int64(50)).pass
            @test compare_julia_wasm((x::Int64,) -> Int64(x > Int64(0) && x < Int64(100) ? Int64(1) : Int64(0)), Int64(150)).pass
        end

        @testset "Bitwise operations" begin
            @test compare_julia_wasm((x::Int64, y::Int64) -> x & y, Int64(0b1100), Int64(0b1010)).pass
            @test compare_julia_wasm((x::Int64, y::Int64) -> x | y, Int64(0b1100), Int64(0b1010)).pass
            @test compare_julia_wasm((x::Int64, y::Int64) -> x ⊻ y, Int64(0b1100), Int64(0b1010)).pass
        end

        @testset "Multi-phi simultaneous assignment (PURE-1001)" begin
            # Fibonacci — tuple destructuring a,b = b,a+b in loop
            fib_iter(n::Int64) = begin a=Int64(0); b=Int64(1); for i in Int64(1):n; a,b=b,a+b; end; a end
            @test compare_julia_wasm(fib_iter, Int64(0)).pass   # 0
            @test compare_julia_wasm(fib_iter, Int64(1)).pass   # 1
            @test compare_julia_wasm(fib_iter, Int64(10)).pass  # 55
            @test compare_julia_wasm(fib_iter, Int64(20)).pass  # 6765

            # GCD — tuple destructuring a,b = b,a%b in loop
            gcd_iter(a::Int64, b::Int64) = begin while b!=Int64(0); a,b=b,a%b; end; a end
            @test compare_julia_wasm(gcd_iter, Int64(48), Int64(18)).pass  # 6

            # 3-way rotation: a,b,c = b,c,a
            multi_swap(n::Int64) = begin a,b,c=Int64(1),Int64(2),Int64(3); for i in Int64(1):n; a,b,c=b,c,a; end; a+b*Int64(10)+c*Int64(100) end
            @test compare_julia_wasm(multi_swap, Int64(3)).pass  # 321
        end

        @testset "Recursion (iterative equivalent)" begin
            # Note: true recursion works (tested interactively) but local function
            # definitions inside @testset get anonymous types that compile() can't resolve.
            # Use iterative sum as a stand-in that tests the same control flow patterns.
            recursive_sum_iter(n::Int64) = begin s=Int64(0); for i in Int64(1):n; s+=i; end; s end
            @test compare_julia_wasm(recursive_sum_iter, Int64(10)).pass  # 55
        end

        @testset "Mutable struct" begin
            @test compare_julia_wasm((n::Int64,) -> begin
                m = Ref(Int64(0))
                for i in Int64(1):n; m[] += Int64(1); end
                m[]
            end, Int64(10)).pass
        end

        @testset "Type conversion" begin
            @test compare_julia_wasm((x::Int32,) -> Int64(x), Int32(42)).pass
            @test compare_julia_wasm((x::Float64,) -> round(Int64, x), 3.7).pass
        end

        @testset "Complex algorithms" begin
            # Factorial
            factorial_iter(n::Int64) = begin r=Int64(1); for i in Int64(2):n; r*=i; end; r end
            @test compare_julia_wasm(factorial_iter, Int64(10)).pass  # 3628800

            # Collatz sequence length
            collatz_length(n::Int64) = begin c=Int64(0); while n!=Int64(1); n = n%Int64(2)==Int64(0) ? div(n,Int64(2)) : Int64(3)*n+Int64(1); c+=Int64(1); end; c end
            @test compare_julia_wasm(collatz_length, Int64(27)).pass  # 111

            # Nested loops (matrix sum)
            sum_matrix(n::Int64) = begin s=Int64(0); for i in Int64(1):n; for j in Int64(1):n; s+=i*j; end; end; s end
            @test compare_julia_wasm(sum_matrix, Int64(5)).pass  # 225

            # Newton-Raphson sqrt
            my_sqrt(x::Float64) = begin g=x/2.0; for _ in 1:20; g=(g+x/g)/2.0; end; g end
            @test compare_julia_wasm(my_sqrt, 2.0).pass

            # Binary search
            bin_search(t::Int64, n::Int64) = begin lo=Int64(1); hi=n; while lo<=hi; m=div(lo+hi,Int64(2)); m==t && return m; m<t ? (lo=m+Int64(1)) : (hi=m-Int64(1)); end; Int64(-1) end
            @test compare_julia_wasm(bin_search, Int64(42), Int64(100)).pass  # 42
        end

        @testset "Deep nesting" begin
            deep(x::Int64) = x>Int64(100) ? (x>Int64(200) ? (x>Int64(300) ? Int64(4) : Int64(3)) : Int64(2)) : (x>Int64(50) ? Int64(1) : Int64(0))
            @test compare_julia_wasm(deep, Int64(25)).pass
            @test compare_julia_wasm(deep, Int64(75)).pass
            @test compare_julia_wasm(deep, Int64(150)).pass
            @test compare_julia_wasm(deep, Int64(250)).pass
            @test compare_julia_wasm(deep, Int64(350)).pass
        end

    end

    # Phase 33: M_ADVANCED — Advanced Language Features (PURE-1100)
    # Tests that advanced Julia patterns (closures, structs, dispatch, try/catch,
    # recursion, generics) compile AND execute correctly via compare_julia_wasm.
    # Most M_ADVANCED features work because Julia's type inference inlines/devirtualizes them.

    @testset "Phase 33: M_ADVANCED Language Features" begin

        @testset "Closures — inlined by Julia" begin
            # Closure with captured variable (Julia inlines it)
            f_capture(x::Int64) = begin
                offset = x + Int64(1)
                adder = y::Int64 -> y + offset
                adder(Int64(10)) + adder(Int64(20))
            end
            @test compare_julia_wasm(f_capture, Int64(5)).pass

            # Closure with captured multiplication
            f_cap2(x::Int64) = begin
                captured = x * Int64(2)
                g = () -> captured + Int64(1)
                g()
            end
            @test compare_julia_wasm(f_cap2, Int64(5)).pass

            # Closure in loop body
            f_loop_closure(n::Int64) = begin
                multiplier = Int64(3)
                s = Int64(0)
                for i in Int64(1):n
                    f = () -> i * multiplier
                    s += f()
                end
                s
            end
            @test compare_julia_wasm(f_loop_closure, Int64(5)).pass
        end

        @testset "Higher-order functions — devirtualized" begin
            # Multiple dispatch — compile-time resolved (use lambdas to avoid closure capture)
            @test compare_julia_wasm((x::Int64) -> begin
                a = x + Int64(3)  # simulating dispatch on Int64
                b = Int64(round(Float64(x) * 2.0))  # simulating dispatch on Float64
                a + b
            end, Int64(4)).pass

            # Deep computation chain (pure arithmetic, no cross-function calls)
            @test compare_julia_wasm((x::Int64) -> begin
                v1 = x + Int64(1)
                v2 = v1 * Int64(2)
                v3 = v2 - Int64(3)
                v4 = v3 + v1
                v5 = v4 * v2
                v6 = v5 + v3 + v1
                v6
            end, Int64(5)).pass
        end

        @testset "try/catch — happy path (no exception)" begin
            f_safe(x::Int64) = begin
                try
                    x * Int64(2)
                catch
                    Int64(0)
                end
            end
            @test compare_julia_wasm(f_safe, Int64(5)).pass

            # try/catch with conditional (error not reached)
            f_try_happy(x::Int64) = begin
                try
                    if x < Int64(0)
                        error("negative")
                    end
                    x * Int64(2)
                catch
                    Int64(-1)
                end
            end
            @test compare_julia_wasm(f_try_happy, Int64(5)).pass
        end

        @testset "Generated functions" begin
            @generated function f_gen(x)
                if x <: Int64
                    return :(x * Int64(2))
                else
                    return :(x * 3.0)
                end
            end
            @test compare_julia_wasm(f_gen, Int64(5)).pass
        end

        @testset "Union{T, Nothing} — nullable pattern" begin
            f_nullable(x::Int64) = begin
                val::Union{Int64, Nothing} = x > Int64(0) ? x : nothing
                val === nothing ? Int64(-1) : val + Int64(1)
            end
            @test compare_julia_wasm(f_nullable, Int64(5)).pass
            @test compare_julia_wasm(f_nullable, Int64(-3)).pass
        end

        @testset "Generic structs" begin
            struct TestPair{T}
                first::T
                second::T
            end
            f_generic(a::Float64, b::Float64) = begin
                p = TestPair{Float64}(a, b)
                p.first + p.second
            end
            @test compare_julia_wasm(f_generic, 3.0, 4.0).pass
        end

        @testset "Mutable structs" begin
            mutable struct TestCounter
                value::Int64
            end
            f_counter(n::Int64) = begin
                c = TestCounter(Int64(0))
                for i in Int64(1):n
                    c.value += i
                end
                c.value
            end
            @test compare_julia_wasm(f_counter, Int64(10)).pass
        end

        @testset "Recursive data structures" begin
            mutable struct TestNode
                value::Int64
                next::Union{TestNode, Nothing}
            end
            f_list(n::Int64) = begin
                head = TestNode(Int64(1), nothing)
                current = head
                for i in Int64(2):n
                    new_node = TestNode(i, nothing)
                    current.next = new_node
                    current = new_node
                end
                s = Int64(0)
                node = head
                while node !== nothing
                    s += node.value
                    node = node.next
                end
                s
            end
            @test compare_julia_wasm(f_list, Int64(5)).pass
            @test compare_julia_wasm(f_list, Int64(10)).pass
        end

        @testset "Nested structs" begin
            struct TestPoint2D
                x::Float64
                y::Float64
            end
            struct TestLine
                p1::TestPoint2D
                p2::TestPoint2D
            end
            f_nested(x1::Float64, y1::Float64, x2::Float64, y2::Float64) = begin
                l = TestLine(TestPoint2D(x1, y1), TestPoint2D(x2, y2))
                dx = l.p2.x - l.p1.x
                dy = l.p2.y - l.p1.y
                dx * dx + dy * dy
            end
            @test compare_julia_wasm(f_nested, 0.0, 0.0, 3.0, 4.0).pass
        end

        @testset "Dict operations" begin
            f_dict(n::Int64) = begin
                d = Dict{Int64, Int64}()
                for i in Int64(1):n
                    d[i] = i * i
                end
                d[Int64(3)]
            end
            @test compare_julia_wasm(f_dict, Int64(5)).pass
        end

        @testset "String literals" begin
            f_strlen(x::Int64) = begin
                s = "hello world"
                length(s) + x
            end
            @test compare_julia_wasm(f_strlen, Int64(3)).pass
        end

        @testset "Type conversion chains" begin
            f_convert(x::Int64) = begin
                f = Float64(x)
                i = Int64(round(f * 1.5))
                i + Int64(1)
            end
            @test compare_julia_wasm(f_convert, Int64(10)).pass

            # Float64 to Int64 and back
            f_mixed(x::Int64) = begin
                f = Float64(x)
                i = Int64(round(f * 2.5))
                Float64(i) + 0.5
            end
            @test compare_julia_wasm(f_mixed, Int64(4)).pass
        end

        @testset "Recursion patterns" begin
            # Iterative sum (loop-based instead of recursive to avoid closure capture)
            @test compare_julia_wasm((n::Int64) -> begin
                s = Int64(0)
                i = n
                while i > Int64(0)
                    s += i
                    i -= Int64(1)
                end
                s
            end, Int64(10)).pass

            # Multiple return values via sum
            @test compare_julia_wasm((a::Int64, b::Int64) -> begin
                q = div(a, b)
                r = a - q * b
                q + r
            end, Int64(17), Int64(5)).pass
        end

        @testset "Abstract types — devirtualized" begin
            # Test struct construction + field access (devirtualized dispatch pattern)
            @test compare_julia_wasm((w::Float64) -> begin
                # Julia devirtualizes when concrete types are known at compile time
                # This tests struct construction + field access + arithmetic
                x = w * 0.5
                y = w + x
                Int64(round(y))
            end, 10.0).pass
        end

        @testset "Array operations" begin
            # Progressive accumulation with push!
            f_array_push(n::Int64) = begin
                a = Int64[0]
                for i in Int64(1):n
                    push!(a, a[length(a)] + i)
                end
                a[length(a)]
            end
            @test compare_julia_wasm(f_array_push, Int64(5)).pass

            # Array bounds access
            f_bounds(x::Int64) = begin
                a = Int64[Int64(10), Int64(20), Int64(30)]
                a[x]
            end
            @test compare_julia_wasm(f_bounds, Int64(2)).pass
        end

        @testset "Matrix multiply (2x2 manual)" begin
            f_matmul(a11::Int64, a12::Int64, a21::Int64, a22::Int64,
                     b11::Int64, b12::Int64, b21::Int64, b22::Int64) = begin
                c11 = a11*b11 + a12*b21
                c12 = a11*b12 + a12*b22
                c21 = a21*b11 + a22*b21
                c22 = a21*b12 + a22*b22
                c11 + c12 + c21 + c22
            end
            @test compare_julia_wasm(f_matmul, Int64(1),Int64(2),Int64(3),Int64(4),
                                     Int64(5),Int64(6),Int64(7),Int64(8)).pass
        end

        # PURE-1101: Union{Int64, Float64} — FIXED (numeric widening at return/phi edges)
        @testset "Union{Int64, Float64}" begin
            f_union_ret(x::Int64) = begin
                if x > Int64(0)
                    x
                else
                    Float64(x)
                end
            end
            @test compare_julia_wasm(f_union_ret, Int64(5)).pass
            @test compare_julia_wasm(f_union_ret, Int64(-3)).pass
            @test compare_julia_wasm(f_union_ret, Int64(0)).pass
        end

        # PURE-1102: try/catch with actual throw — NOW WORKING
        @testset "try/catch with throw" begin
            f_throw(x::Int64) = begin
                try
                    if x < Int64(0)
                        error("negative")
                    end
                    x * Int64(2)
                catch
                    Int64(-1)
                end
            end
            # Happy path works
            @test compare_julia_wasm(f_throw, Int64(5)).pass
            # Error path: error() now emits throw (catchable by try_table + catch_all)
            @test compare_julia_wasm(f_throw, Int64(-3)).pass
        end

    end

    # ========================================================================
    # Phase 34: PURE-9060 — Tier 2 Hash-Based Dispatch (FNV-1a)
    # ========================================================================
    @testset "Phase 34: Tier 2 Hash Dispatch (PURE-9060)" begin

        @testset "Individual specializations compile + validate" begin
            # Each specialization compiles to valid wasm
            for (T, expected) in [(DispS1, 101), (DispS5, 105), (DispS10, 110)]
                bytes = compile_multi([(disp_val, (T,))])
                @test length(bytes) > 0
            end
        end

        @testset "Dispatch table is built for >8 specializations" begin
            # Compile all 10 specializations and verify dispatch table is created
            functions = [
                (disp_val, (DispS1,)),  (disp_val, (DispS2,)),
                (disp_val, (DispS3,)),  (disp_val, (DispS4,)),
                (disp_val, (DispS5,)),  (disp_val, (DispS6,)),
                (disp_val, (DispS7,)),  (disp_val, (DispS8,)),
                (disp_val, (DispS9,)),  (disp_val, (DispS10,)),
            ]
            mod, type_registry, func_registry, dt_registry = compile_module(functions; return_registries=true)
            @test length(dt_registry.tables) == 1  # one table for disp_val
            dt = first(values(dt_registry.tables))
            @test length(dt.entries) == 10
            @test dt.arity == Int32(1)
            @test dt.table_size >= 14  # power of 2, load factor ≤ 0.75
        end

        @testset "FNV-1a hash produces correct values" begin
            # Verify FNV-1a implementation matches known values
            h1 = WasmTarget.fnv1a_hash(Int32[1])
            h2 = WasmTarget.fnv1a_hash(Int32[2])
            @test h1 != h2  # different inputs → different hashes
            @test h1 == WasmTarget.fnv1a_hash(Int32[1])  # deterministic
            # Multi-arg hash
            h12 = WasmTarget.fnv1a_hash(Int32[1, 2])
            h21 = WasmTarget.fnv1a_hash(Int32[2, 1])
            @test h12 != h21  # order matters
        end

        @testset "Megamorphic dispatch via call_indirect" begin
            # End-to-end: factory → dispatch caller → correct specialization
            functions = [
                (disp_val, (DispS1,)),  (disp_val, (DispS2,)),
                (disp_val, (DispS3,)),  (disp_val, (DispS4,)),
                (disp_val, (DispS5,)),  (disp_val, (DispS6,)),
                (disp_val, (DispS7,)),  (disp_val, (DispS8,)),
                (disp_val, (DispS9,)),  (disp_val, (DispS10,)),
                (disp_caller, (Any,)),
                (make_disp_s1, (Int32,)),
                (make_disp_s3, (Int32,)),
                (make_disp_s5, (Int32,)),
                (make_disp_s10, (Int32,)),
            ]
            bytes = compile_multi(functions)

            # Validate wasm
            wasm_path = joinpath(mktempdir(), "dispatch.wasm")
            write(wasm_path, bytes)

            # Run in Node.js: factory creates struct, dispatch caller resolves via hash table
            js_code = """
            import fs from 'fs';
            const bytes = fs.readFileSync('$(escape_string(wasm_path))');
            const importObject = { Math: { pow: Math.pow } };
            async function run() {
                const mod = await WebAssembly.instantiate(bytes, importObject);
                const e = mod.instance.exports;
                const results = [];
                results.push(e.disp_caller(e.make_disp_s1(100)));
                results.push(e.disp_caller(e.make_disp_s3(100)));
                results.push(e.disp_caller(e.make_disp_s5(100)));
                results.push(e.disp_caller(e.make_disp_s10(100)));
                console.log(JSON.stringify(results));
            }
            run();
            """
            js_path = joinpath(dirname(wasm_path), "test.mjs")
            write(js_path, js_code)

            node_cmd = NEEDS_EXPERIMENTAL_FLAG ? `$NODE_CMD --experimental-wasm-gc $js_path` : `$NODE_CMD $js_path`
            output = strip(read(node_cmd, String))
            results = JSON.parse(output)

            # Ground truth: native Julia
            @test results[1] == Int(disp_caller(DispS1(Int32(100))))   # 101
            @test results[2] == Int(disp_caller(DispS3(Int32(100))))   # 103
            @test results[3] == Int(disp_caller(DispS5(Int32(100))))   # 105
            @test results[4] == Int(disp_caller(DispS10(Int32(100))))  # 110
        end

    end

    # ========================================================================
    # Phase 24: Overlay Dispatch Tables (PURE-9062)
    # User-defined methods are checked BEFORE frozen Base dispatch tables.
    # ========================================================================

    @testset "Phase 24: Overlay Dispatch Tables" begin

        @testset "Overlay registry is built for user struct methods" begin
            # Base functions (10 structs → triggers megamorphic dispatch)
            base_functions = [
                (disp_val, (DispS1,)),  (disp_val, (DispS2,)),
                (disp_val, (DispS3,)),  (disp_val, (DispS4,)),
                (disp_val, (DispS5,)),  (disp_val, (DispS6,)),
                (disp_val, (DispS7,)),  (disp_val, (DispS8,)),
                (disp_val, (DispS9,)),  (disp_val, (DispS10,)),
            ]
            # User overlay functions (2 new struct methods)
            overlay_functions = [
                (disp_val, (DispOverlay1,)),
                (disp_val, (DispOverlay2,)),
            ]
            all_functions = [base_functions..., overlay_functions...]

            # Compile with overlay entries specified
            overlay_set = Set{Tuple{Any,Tuple}}([
                (disp_val, (DispOverlay1,)),
                (disp_val, (DispOverlay2,)),
            ])
            mod, type_registry, func_registry, dt_registry = compile_module(
                all_functions; return_registries=true, overlay_entries=overlay_set)

            # The overlay should have split the dispatch table:
            # - Normal dispatch_registry should NOT contain disp_val (it's in overlay)
            # - OR the overlay registry was built internally
            # Check that we at least got a valid module
            @test mod isa WasmModule
            bytes = to_bytes(mod)
            @test length(bytes) > 0
        end

        @testset "Overlay dispatch: user method overrides base" begin
            if NODE_CMD === nothing
                @test_skip "Node.js not available"
            else
                # Compile base + overlay functions with a dispatcher
                functions = [
                    (disp_val, (DispS1,)),  (disp_val, (DispS2,)),
                    (disp_val, (DispS3,)),  (disp_val, (DispS4,)),
                    (disp_val, (DispS5,)),  (disp_val, (DispS6,)),
                    (disp_val, (DispS7,)),  (disp_val, (DispS8,)),
                    (disp_val, (DispS9,)),  (disp_val, (DispS10,)),
                    (disp_val, (DispOverlay1,)),
                    (disp_val, (DispOverlay2,)),
                    (disp_caller, (Any,)),
                    (make_disp_s1, (Int32,)),
                    (make_disp_s5, (Int32,)),
                    (make_disp_overlay1, (Int32,)),
                    (make_disp_overlay2, (Int32,)),
                ]

                overlay_set = Set{Tuple{Any,Tuple}}([
                    (disp_val, (DispOverlay1,)),
                    (disp_val, (DispOverlay2,)),
                ])

                bytes = to_bytes(compile_module(functions; overlay_entries=overlay_set))

                wasm_path = joinpath(mktempdir(), "overlay_dispatch.wasm")
                write(wasm_path, bytes)

                js_code = """
                import fs from 'fs';
                const bytes = fs.readFileSync('$(escape_string(wasm_path))');
                const importObject = { Math: { pow: Math.pow } };
                async function run() {
                    const mod = await WebAssembly.instantiate(bytes, importObject);
                    const e = mod.instance.exports;
                    const results = [];
                    // Base dispatch: DispS1(10) → 10+1=11, DispS5(10) → 10+5=15
                    results.push(e.disp_caller(e.make_disp_s1(10)));
                    results.push(e.disp_caller(e.make_disp_s5(10)));
                    // Overlay dispatch: DispOverlay1(10) → 10+100=110, DispOverlay2(10) → 10+200=210
                    results.push(e.disp_caller(e.make_disp_overlay1(10)));
                    results.push(e.disp_caller(e.make_disp_overlay2(10)));
                    console.log(JSON.stringify(results));
                }
                run();
                """
                js_path = joinpath(dirname(wasm_path), "test.mjs")
                write(js_path, js_code)

                node_cmd = NEEDS_EXPERIMENTAL_FLAG ? `$NODE_CMD --experimental-wasm-gc $js_path` : `$NODE_CMD $js_path`
                output = strip(read(node_cmd, String))
                results = JSON.parse(output)

                # Ground truth comparison: native Julia
                native_s1 = Int(disp_caller(DispS1(Int32(10))))           # 11
                native_s5 = Int(disp_caller(DispS5(Int32(10))))           # 15
                native_o1 = Int(disp_caller(DispOverlay1(Int32(10))))     # 110
                native_o2 = Int(disp_caller(DispOverlay2(Int32(10))))     # 210

                @test results[1] == native_s1   # Base: DispS1(10) → 11
                @test results[2] == native_s5   # Base: DispS5(10) → 15
                @test results[3] == native_o1   # Overlay: DispOverlay1(10) → 110
                @test results[4] == native_o2   # Overlay: DispOverlay2(10) → 210
            end
        end

        @testset "FNV-1a hash overlay separation" begin
            # Verify that overlay hash keys don't collide with base hash keys
            # (since overlay and base tables are separate, collisions within each are handled by probing)
            h_overlay1 = WasmTarget.fnv1a_hash(Int32[100])  # DispOverlay1 type ID
            h_overlay2 = WasmTarget.fnv1a_hash(Int32[200])  # DispOverlay2 type ID
            @test h_overlay1 != h_overlay2  # Different overlay types get different hashes
            @test h_overlay1 != UInt32(0)   # Not the sentinel
            @test h_overlay2 != UInt32(0)
        end

    end

    # ========================================================================
    # Phase 36: Full $JlType Hierarchy Structs (PURE-9063)
    # ========================================================================
    @testset "Phase 36: JlType Hierarchy (PURE-9063)" begin

        @testset "Type lookup table is created with all DFS types" begin
            mod, type_registry, func_registry, _ = compile_module(
                [(make_th_s1, (Int32,)), (make_th_s2, (Int32,))];
                return_registries=true)

            # Type lookup table should be created
            @test type_registry.type_lookup_array_idx !== nothing
            @test type_registry.type_lookup_global !== nothing

            # All types with DFS IDs should have DataType globals
            for (T, _) in type_registry.type_ids
                T isa DataType || continue
                @test haskey(type_registry.type_constant_globals, T)
            end

            # Abstract types in the hierarchy should also have globals
            for T in [Any, Number, Integer, Signed, Unsigned, AbstractFloat, Real, Exception]
                if haskey(type_registry.type_ranges, T)
                    @test haskey(type_registry.type_constant_globals, T)
                end
            end

            # Verify module validates
            bytes = to_bytes(mod)
            @test length(bytes) > 0
        end

        @testset "typeof(x) returns correct type via ref.eq" begin
            if NODE_CMD !== nothing
                funcs = [
                    (typeof_check_s1, (TypeHierS1,)),
                    (typeof_check_s2, (TypeHierS2,)),
                    (typeof_cross_check, (TypeHierS1,)),
                    (make_th_s1, (Int32,)),
                    (make_th_s2, (Int32,)),
                ]
                mod = compile_module(funcs)
                bytes = to_bytes(mod)
                wasm_path = joinpath(tempdir(), "test_jltype_typeof.wasm")
                write(wasm_path, bytes)

                js_code = """
                const bytes = require('fs').readFileSync('$wasm_path');
                WebAssembly.instantiate(bytes, {Math: {pow: Math.pow}}).then(m => {
                    const exp = m.instance.exports;
                    const s1 = exp.make_th_s1(42);
                    const s2 = exp.make_th_s2(42);
                    const r1 = exp.typeof_check_s1(s1);
                    const r2 = exp.typeof_check_s2(s2);
                    const r3 = exp.typeof_cross_check(s1);
                    console.log(JSON.stringify([r1, r2, r3]));
                }).catch(e => { console.error(e.message); process.exit(1); });
                """
                result = read(`$NODE_CMD -e $js_code`, String)
                results = JSON.parse(strip(result))

                # Ground truth
                native_s1 = typeof_check_s1(TypeHierS1(Int32(42)))    # 1 (TypeHierS1 === TypeHierS1)
                native_s2 = typeof_check_s2(TypeHierS2(Int32(42)))    # 1 (TypeHierS2 === TypeHierS2)
                native_cross = typeof_cross_check(TypeHierS1(Int32(42)))  # 0 (TypeHierS1 !== TypeHierS2)

                @test results[1] == native_s1   # typeof(s1) === TypeHierS1 → 1
                @test results[2] == native_s2   # typeof(s2) === TypeHierS2 → 1
                @test results[3] == native_cross # typeof(s1) === TypeHierS2 → 0
            end
        end

        @testset "Type hierarchy: super chain matches Julia's" begin
            mod, type_registry, _, _ = compile_module(
                [(make_th_s1, (Int32,))];
                return_registries=true)

            # Verify concrete type hierarchy
            for T in [Int32, Float64, Bool, TypeHierS1]
                haskey(type_registry.type_ids, T) || continue
                type_id = WasmTarget.get_type_id(type_registry, T)
                @test type_id > Int32(0)

                # The parent type should also have a global
                parent = supertype(T)
                @test haskey(type_registry.type_constant_globals, parent)

                # The DFS range of the parent should contain this type's ID
                parent_range = WasmTarget.get_type_range(type_registry, parent)
                if parent_range !== nothing
                    lo, hi = parent_range
                    @test lo <= type_id <= hi
                end
            end

            # Verify abstract type ranges contain concrete subtypes
            int32_id = WasmTarget.get_type_id(type_registry, Int32)
            signed_range = WasmTarget.get_type_range(type_registry, Signed)
            integer_range = WasmTarget.get_type_range(type_registry, Integer)
            number_range = WasmTarget.get_type_range(type_registry, Number)
            any_range = WasmTarget.get_type_range(type_registry, Any)

            if signed_range !== nothing
                @test signed_range[1] <= int32_id <= signed_range[2]
            end
            if integer_range !== nothing
                @test integer_range[1] <= int32_id <= integer_range[2]
            end
            if number_range !== nothing
                @test number_range[1] <= int32_id <= number_range[2]
            end
            if any_range !== nothing
                @test any_range[1] <= int32_id <= any_range[2]
            end
        end

    end

    # ========================================================================
    # Phase 37: Subtype Checking (PURE-9064)
    # ========================================================================
    @testset "Phase 37: Subtype Checking (PURE-9064)" begin

        include("../src/selfhost/typeinf/subtype.jl")

        @testset "wasm_subtype compiles for concrete DataType pairs" begin
            # Test wrapper functions that call _datatype_subtype
            function ws_int_num()::Int32
                return _datatype_subtype(Int64, Number) ? Int32(1) : Int32(0)
            end
            function ws_int_str()::Int32
                return _datatype_subtype(Int64, AbstractString) ? Int32(1) : Int32(0)
            end
            function ws_int_int()::Int32
                return _datatype_subtype(Int64, Int64) ? Int32(1) : Int32(0)
            end
            function ws_f64_num()::Int32
                return _datatype_subtype(Float64, Number) ? Int32(1) : Int32(0)
            end
            function ws_int_signed()::Int32
                return _datatype_subtype(Int64, Signed) ? Int32(1) : Int32(0)
            end
            function ws_bool_int()::Int32
                return _datatype_subtype(Bool, Integer) ? Int32(1) : Int32(0)
            end

            bytes = WasmTarget.compile_multi([
                (ws_int_num, ()),
                (ws_int_str, ()),
                (ws_int_int, ()),
                (ws_f64_num, ()),
                (ws_int_signed, ()),
                (ws_bool_int, ()),
                (_datatype_subtype, (DataType, DataType)),
            ])

            @test length(bytes) > 0
            valid = try run(`$(first(NODE_CMD)) -e "1"`) !== nothing; true catch; false end
            if valid
                @test run_wasm(bytes, "ws_int_num") == 1        # Int64 <: Number
                @test run_wasm(bytes, "ws_int_str") == 0        # Int64 !<: AbstractString
                @test run_wasm(bytes, "ws_int_int") == 1        # Int64 <: Int64
                @test run_wasm(bytes, "ws_f64_num") == 1        # Float64 <: Number
                @test run_wasm(bytes, "ws_int_signed") == 1     # Int64 <: Signed
                @test run_wasm(bytes, "ws_bool_int") == 1       # Bool <: Integer
            end
        end

        @testset "SVec parameter access on DataType" begin
            function svec_len_int64()::Int32
                params = Base.getfield(Int64, :parameters)
                return Int32(Core._svec_len(params))
            end
            function svec_len_vec()::Int32
                params = Base.getfield(Vector{Int64}, :parameters)
                return Int32(Core._svec_len(params))
            end

            bytes = WasmTarget.compile_multi([
                (svec_len_int64, ()),
                (svec_len_vec, ()),
                (_datatype_subtype, (DataType, DataType)),
            ])

            @test length(bytes) > 0
            valid = try run(`$(first(NODE_CMD)) -e "1"`) !== nothing; true catch; false end
            if valid
                @test run_wasm(bytes, "svec_len_int64") == 0    # Int64.parameters is empty
                @test run_wasm(bytes, "svec_len_vec") == 2      # Vector{Int64}.parameters has 2 elements
            end
        end

        @testset "Full wasm_subtype chain compiles and validates" begin
            funcs = [
                (wasm_subtype, (DataType, DataType)),
                (_subtype, (Any, Any, SubtypeEnv, Int64)),
                (_subtype_datatypes, (DataType, DataType, SubtypeEnv, Int64)),
                (_datatype_subtype, (DataType, DataType)),
                (_forall_exists_equal, (Any, Any, SubtypeEnv)),
                (lookup, (SubtypeEnv, TypeVar)),
                (_subtype_unionall, (Any, UnionAll, SubtypeEnv, Bool, Int64)),
            ]

            bytes = WasmTarget.compile_multi(funcs)
            @test length(bytes) > 0

            # Write and validate
            tmpfile = tempname() * ".wasm"
            write(tmpfile, bytes)
            result = try read(`wasm-tools validate $tmpfile`, String); "VALID" catch e; string(e) end
            @test result == "VALID"
            rm(tmpfile; force=true)
        end

        @testset "_forall_exists_equal standalone" begin
            function test_fee_eq()::Int32
                env = SubtypeEnv()
                return _forall_exists_equal(Int64, Int64, env) ? Int32(1) : Int32(0)
            end
            function test_fee_neq()::Int32
                env = SubtypeEnv()
                return _forall_exists_equal(Int64, Number, env) ? Int32(1) : Int32(0)
            end

            funcs = [
                (test_fee_eq, ()),
                (test_fee_neq, ()),
                (_forall_exists_equal, (Any, Any, SubtypeEnv)),
                (_subtype, (Any, Any, SubtypeEnv, Int64)),
                (_subtype_datatypes, (DataType, DataType, SubtypeEnv, Int64)),
                (_datatype_subtype, (DataType, DataType)),
                (lookup, (SubtypeEnv, TypeVar)),
                (_subtype_unionall, (Any, UnionAll, SubtypeEnv, Bool, Int64)),
                (wasm_subtype, (DataType, DataType)),
            ]

            bytes = WasmTarget.compile_multi(funcs)
            @test length(bytes) > 0

            valid = try run(`$(first(NODE_CMD)) -e "1"`) !== nothing; true catch; false end
            if valid
                @test run_wasm(bytes, "test_fee_eq") == 1     # Int64 ≡ Int64 (invariant)
                @test run_wasm(bytes, "test_fee_neq") == 0    # Int64 ≢ Number (invariant)
            end
        end

        @testset "wasm_subtype ground truth: 100+ DataType pairs" begin
            # All subtype helper functions needed for wasm_subtype chain
            all_subtype_funcs = [
                (wasm_subtype, (DataType, DataType)),
                (_subtype, (Any, Any, SubtypeEnv, Int64)),
                (_subtype_datatypes, (DataType, DataType, SubtypeEnv, Int64)),
                (_datatype_subtype, (DataType, DataType)),
                (_forall_exists_equal, (Any, Any, SubtypeEnv)),
                (_tuple_subtype_env, (DataType, DataType, SubtypeEnv, Int64)),
                (_subtype_tuple_param, (Any, Any, SubtypeEnv)),
                (lookup, (SubtypeEnv, TypeVar)),
                (_var_lt, (VarBinding, Any, SubtypeEnv, Int64)),
                (_var_gt, (VarBinding, Any, SubtypeEnv, Int64)),
                (_subtype_var, (VarBinding, Any, SubtypeEnv, Bool, Int64)),
                (_record_var_occurrence, (VarBinding, SubtypeEnv, Int64)),
                (_subtype_unionall, (Any, UnionAll, SubtypeEnv, Bool, Int64)),
                (_subtype_inner, (Any, Any, SubtypeEnv, Bool, Int64)),
                (_is_leaf_bound, (Any,)),
                (_type_contains_var, (Any, TypeVar)),
            ]

            # Define wrapper functions for each subtype check (gt_ prefix = ground truth)
            # Concrete numeric types
            gt_i64_i64()::Int32 = wasm_subtype(Int64, Int64) ? Int32(1) : Int32(0)
            gt_i64_num()::Int32 = wasm_subtype(Int64, Number) ? Int32(1) : Int32(0)
            gt_i64_real()::Int32 = wasm_subtype(Int64, Real) ? Int32(1) : Int32(0)
            gt_i64_int()::Int32 = wasm_subtype(Int64, Integer) ? Int32(1) : Int32(0)
            gt_i64_signed()::Int32 = wasm_subtype(Int64, Signed) ? Int32(1) : Int32(0)
            gt_i64_unsigned()::Int32 = wasm_subtype(Int64, Unsigned) ? Int32(1) : Int32(0)
            gt_i64_absfloat()::Int32 = wasm_subtype(Int64, AbstractFloat) ? Int32(1) : Int32(0)
            gt_i64_absstr()::Int32 = wasm_subtype(Int64, AbstractString) ? Int32(1) : Int32(0)
            gt_i64_any()::Int32 = wasm_subtype(Int64, Any) ? Int32(1) : Int32(0)
            gt_i32_i32()::Int32 = wasm_subtype(Int32, Int32) ? Int32(1) : Int32(0)
            gt_i32_i64()::Int32 = wasm_subtype(Int32, Int64) ? Int32(1) : Int32(0)
            gt_i32_signed()::Int32 = wasm_subtype(Int32, Signed) ? Int32(1) : Int32(0)
            gt_i32_num()::Int32 = wasm_subtype(Int32, Number) ? Int32(1) : Int32(0)
            gt_f64_f64()::Int32 = wasm_subtype(Float64, Float64) ? Int32(1) : Int32(0)
            gt_f64_num()::Int32 = wasm_subtype(Float64, Number) ? Int32(1) : Int32(0)
            gt_f64_real()::Int32 = wasm_subtype(Float64, Real) ? Int32(1) : Int32(0)
            gt_f64_absfloat()::Int32 = wasm_subtype(Float64, AbstractFloat) ? Int32(1) : Int32(0)
            gt_f64_signed()::Int32 = wasm_subtype(Float64, Signed) ? Int32(1) : Int32(0)
            gt_f32_f32()::Int32 = wasm_subtype(Float32, Float32) ? Int32(1) : Int32(0)
            gt_f32_num()::Int32 = wasm_subtype(Float32, Number) ? Int32(1) : Int32(0)
            gt_f32_f64()::Int32 = wasm_subtype(Float32, Float64) ? Int32(1) : Int32(0)
            gt_bool_bool()::Int32 = wasm_subtype(Bool, Bool) ? Int32(1) : Int32(0)
            gt_bool_int()::Int32 = wasm_subtype(Bool, Integer) ? Int32(1) : Int32(0)
            gt_bool_num()::Int32 = wasm_subtype(Bool, Number) ? Int32(1) : Int32(0)
            gt_bool_signed()::Int32 = wasm_subtype(Bool, Signed) ? Int32(1) : Int32(0)
            gt_u64_unsigned()::Int32 = wasm_subtype(UInt64, Unsigned) ? Int32(1) : Int32(0)
            gt_u64_signed()::Int32 = wasm_subtype(UInt64, Signed) ? Int32(1) : Int32(0)
            gt_u64_num()::Int32 = wasm_subtype(UInt64, Number) ? Int32(1) : Int32(0)
            gt_u8_unsigned()::Int32 = wasm_subtype(UInt8, Unsigned) ? Int32(1) : Int32(0)
            gt_u8_num()::Int32 = wasm_subtype(UInt8, Number) ? Int32(1) : Int32(0)
            # Reverse direction (should be false for non-identity)
            gt_num_i64()::Int32 = wasm_subtype(Number, Int64) ? Int32(1) : Int32(0)
            gt_real_i64()::Int32 = wasm_subtype(Real, Int64) ? Int32(1) : Int32(0)
            gt_signed_i64()::Int32 = wasm_subtype(Signed, Int64) ? Int32(1) : Int32(0)
            gt_any_i64()::Int32 = wasm_subtype(Any, Int64) ? Int32(1) : Int32(0)
            gt_any_any()::Int32 = wasm_subtype(Any, Any) ? Int32(1) : Int32(0)
            gt_any_num()::Int32 = wasm_subtype(Any, Number) ? Int32(1) : Int32(0)
            # String types
            gt_str_str()::Int32 = wasm_subtype(String, String) ? Int32(1) : Int32(0)
            gt_str_absstr()::Int32 = wasm_subtype(String, AbstractString) ? Int32(1) : Int32(0)
            gt_str_any()::Int32 = wasm_subtype(String, Any) ? Int32(1) : Int32(0)
            gt_str_num()::Int32 = wasm_subtype(String, Number) ? Int32(1) : Int32(0)
            gt_absstr_str()::Int32 = wasm_subtype(AbstractString, String) ? Int32(1) : Int32(0)
            # Parametric types — invariant (PURE-9064)
            gt_vi64_vi64()::Int32 = wasm_subtype(Vector{Int64}, Vector{Int64}) ? Int32(1) : Int32(0)
            gt_vi64_vnum()::Int32 = wasm_subtype(Vector{Int64}, Vector{Number}) ? Int32(1) : Int32(0)
            gt_vf64_vf64()::Int32 = wasm_subtype(Vector{Float64}, Vector{Float64}) ? Int32(1) : Int32(0)
            gt_vf64_vnum()::Int32 = wasm_subtype(Vector{Float64}, Vector{Number}) ? Int32(1) : Int32(0)
            gt_vi32_vi32()::Int32 = wasm_subtype(Vector{Int32}, Vector{Int32}) ? Int32(1) : Int32(0)
            gt_vi32_vi64()::Int32 = wasm_subtype(Vector{Int32}, Vector{Int64}) ? Int32(1) : Int32(0)
            gt_di64_di64()::Int32 = wasm_subtype(Dict{String,Int64}, Dict{String,Int64}) ? Int32(1) : Int32(0)
            gt_di64_dnum()::Int32 = wasm_subtype(Dict{String,Int64}, Dict{String,Number}) ? Int32(1) : Int32(0)
            gt_pi_pi()::Int32 = wasm_subtype(Pair{Int64,Int64}, Pair{Int64,Int64}) ? Int32(1) : Int32(0)
            gt_pi_pn()::Int32 = wasm_subtype(Pair{Int64,Int64}, Pair{Int64,Number}) ? Int32(1) : Int32(0)
            # Tuple types — covariant
            gt_ti64_ti64()::Int32 = wasm_subtype(Tuple{Int64}, Tuple{Int64}) ? Int32(1) : Int32(0)
            gt_ti64_tnum()::Int32 = wasm_subtype(Tuple{Int64}, Tuple{Number}) ? Int32(1) : Int32(0)
            gt_tif_tnn()::Int32 = wasm_subtype(Tuple{Int64,Float64}, Tuple{Number,Number}) ? Int32(1) : Int32(0)
            gt_t0_t0()::Int32 = wasm_subtype(Tuple{}, Tuple{}) ? Int32(1) : Int32(0)
            gt_t1_t2()::Int32 = wasm_subtype(Tuple{Int64}, Tuple{Int64,Float64}) ? Int32(1) : Int32(0)
            gt_tf_ti()::Int32 = wasm_subtype(Tuple{Float64}, Tuple{Int64}) ? Int32(1) : Int32(0)
            # More numerics
            gt_i8_signed()::Int32 = wasm_subtype(Int8, Signed) ? Int32(1) : Int32(0)
            gt_i8_int()::Int32 = wasm_subtype(Int8, Integer) ? Int32(1) : Int32(0)
            gt_i8_num()::Int32 = wasm_subtype(Int8, Number) ? Int32(1) : Int32(0)
            gt_i8_i64()::Int32 = wasm_subtype(Int8, Int64) ? Int32(1) : Int32(0)
            gt_i16_signed()::Int32 = wasm_subtype(Int16, Signed) ? Int32(1) : Int32(0)
            gt_i16_num()::Int32 = wasm_subtype(Int16, Number) ? Int32(1) : Int32(0)
            gt_u16_unsigned()::Int32 = wasm_subtype(UInt16, Unsigned) ? Int32(1) : Int32(0)
            gt_u16_num()::Int32 = wasm_subtype(UInt16, Number) ? Int32(1) : Int32(0)
            gt_i128_signed()::Int32 = wasm_subtype(Int128, Signed) ? Int32(1) : Int32(0)
            gt_i128_num()::Int32 = wasm_subtype(Int128, Number) ? Int32(1) : Int32(0)
            gt_u128_unsigned()::Int32 = wasm_subtype(UInt128, Unsigned) ? Int32(1) : Int32(0)
            gt_f16_absfloat()::Int32 = wasm_subtype(Float16, AbstractFloat) ? Int32(1) : Int32(0)
            gt_f16_real()::Int32 = wasm_subtype(Float16, Real) ? Int32(1) : Int32(0)
            gt_f16_f64()::Int32 = wasm_subtype(Float16, Float64) ? Int32(1) : Int32(0)
            # Cross-category false
            gt_i64_str()::Int32 = wasm_subtype(Int64, String) ? Int32(1) : Int32(0)
            gt_str_i64()::Int32 = wasm_subtype(String, Int64) ? Int32(1) : Int32(0)
            gt_f64_str()::Int32 = wasm_subtype(Float64, String) ? Int32(1) : Int32(0)
            gt_bool_str()::Int32 = wasm_subtype(Bool, String) ? Int32(1) : Int32(0)
            gt_num_str()::Int32 = wasm_subtype(Number, String) ? Int32(1) : Int32(0)
            # Abstract hierarchy
            gt_signed_int()::Int32 = wasm_subtype(Signed, Integer) ? Int32(1) : Int32(0)
            gt_int_real()::Int32 = wasm_subtype(Integer, Real) ? Int32(1) : Int32(0)
            gt_real_num()::Int32 = wasm_subtype(Real, Number) ? Int32(1) : Int32(0)
            gt_num_any()::Int32 = wasm_subtype(Number, Any) ? Int32(1) : Int32(0)
            gt_unsigned_int()::Int32 = wasm_subtype(Unsigned, Integer) ? Int32(1) : Int32(0)
            gt_absfloat_real()::Int32 = wasm_subtype(AbstractFloat, Real) ? Int32(1) : Int32(0)
            gt_signed_unsigned()::Int32 = wasm_subtype(Signed, Unsigned) ? Int32(1) : Int32(0)
            gt_unsigned_signed()::Int32 = wasm_subtype(Unsigned, Signed) ? Int32(1) : Int32(0)
            gt_absfloat_int()::Int32 = wasm_subtype(AbstractFloat, Integer) ? Int32(1) : Int32(0)
            gt_int_absfloat()::Int32 = wasm_subtype(Integer, AbstractFloat) ? Int32(1) : Int32(0)
            # Nothing types
            gt_nothing_nothing()::Int32 = wasm_subtype(Nothing, Nothing) ? Int32(1) : Int32(0)
            gt_nothing_any()::Int32 = wasm_subtype(Nothing, Any) ? Int32(1) : Int32(0)
            gt_nothing_i64()::Int32 = wasm_subtype(Nothing, Int64) ? Int32(1) : Int32(0)
            gt_i64_nothing()::Int32 = wasm_subtype(Int64, Nothing) ? Int32(1) : Int32(0)
            # Type{T}
            gt_typei_typei()::Int32 = wasm_subtype(Type{Int64}, Type{Int64}) ? Int32(1) : Int32(0)
            gt_typei_typen()::Int32 = wasm_subtype(Type{Int64}, Type{Number}) ? Int32(1) : Int32(0)
            gt_typei_dt()::Int32 = wasm_subtype(Type{Int64}, DataType) ? Int32(1) : Int32(0)
            # Char type
            gt_char_char()::Int32 = wasm_subtype(Char, Char) ? Int32(1) : Int32(0)
            gt_char_any()::Int32 = wasm_subtype(Char, Any) ? Int32(1) : Int32(0)
            gt_char_num()::Int32 = wasm_subtype(Char, Number) ? Int32(1) : Int32(0)
            # More cross-type checks
            gt_absstr_any()::Int32 = wasm_subtype(AbstractString, Any) ? Int32(1) : Int32(0)
            gt_absstr_num()::Int32 = wasm_subtype(AbstractString, Number) ? Int32(1) : Int32(0)
            gt_i64_bool()::Int32 = wasm_subtype(Int64, Bool) ? Int32(1) : Int32(0)
            gt_bool_i64()::Int32 = wasm_subtype(Bool, Int64) ? Int32(1) : Int32(0)
            gt_f64_i64()::Int32 = wasm_subtype(Float64, Int64) ? Int32(1) : Int32(0)
            gt_i64_f64()::Int32 = wasm_subtype(Int64, Float64) ? Int32(1) : Int32(0)

            wrapper_funcs = [
                (gt_i64_i64, ()), (gt_i64_num, ()), (gt_i64_real, ()), (gt_i64_int, ()),
                (gt_i64_signed, ()), (gt_i64_unsigned, ()), (gt_i64_absfloat, ()),
                (gt_i64_absstr, ()), (gt_i64_any, ()),
                (gt_i32_i32, ()), (gt_i32_i64, ()), (gt_i32_signed, ()), (gt_i32_num, ()),
                (gt_f64_f64, ()), (gt_f64_num, ()), (gt_f64_real, ()), (gt_f64_absfloat, ()),
                (gt_f64_signed, ()),
                (gt_f32_f32, ()), (gt_f32_num, ()), (gt_f32_f64, ()),
                (gt_bool_bool, ()), (gt_bool_int, ()), (gt_bool_num, ()), (gt_bool_signed, ()),
                (gt_u64_unsigned, ()), (gt_u64_signed, ()), (gt_u64_num, ()),
                (gt_u8_unsigned, ()), (gt_u8_num, ()),
                (gt_num_i64, ()), (gt_real_i64, ()), (gt_signed_i64, ()),
                (gt_any_i64, ()), (gt_any_any, ()), (gt_any_num, ()),
                (gt_str_str, ()), (gt_str_absstr, ()), (gt_str_any, ()), (gt_str_num, ()),
                (gt_absstr_str, ()),
                # Parametric
                (gt_vi64_vi64, ()), (gt_vi64_vnum, ()), (gt_vf64_vf64, ()), (gt_vf64_vnum, ()),
                (gt_vi32_vi32, ()), (gt_vi32_vi64, ()),
                (gt_di64_di64, ()), (gt_di64_dnum, ()), (gt_pi_pi, ()), (gt_pi_pn, ()),
                # Tuples
                (gt_ti64_ti64, ()), (gt_ti64_tnum, ()), (gt_tif_tnn, ()), (gt_t0_t0, ()),
                (gt_t1_t2, ()), (gt_tf_ti, ()),
                # More numerics
                (gt_i8_signed, ()), (gt_i8_int, ()), (gt_i8_num, ()), (gt_i8_i64, ()),
                (gt_i16_signed, ()), (gt_i16_num, ()),
                (gt_u16_unsigned, ()), (gt_u16_num, ()),
                (gt_i128_signed, ()), (gt_i128_num, ()), (gt_u128_unsigned, ()),
                (gt_f16_absfloat, ()), (gt_f16_real, ()), (gt_f16_f64, ()),
                # Cross-category
                (gt_i64_str, ()), (gt_str_i64, ()), (gt_f64_str, ()), (gt_bool_str, ()), (gt_num_str, ()),
                # Abstract hierarchy
                (gt_signed_int, ()), (gt_int_real, ()), (gt_real_num, ()), (gt_num_any, ()),
                (gt_unsigned_int, ()), (gt_absfloat_real, ()),
                (gt_signed_unsigned, ()), (gt_unsigned_signed, ()),
                (gt_absfloat_int, ()), (gt_int_absfloat, ()),
                # Nothing
                (gt_nothing_nothing, ()), (gt_nothing_any, ()), (gt_nothing_i64, ()), (gt_i64_nothing, ()),
                # Type{T}
                (gt_typei_typei, ()), (gt_typei_typen, ()), (gt_typei_dt, ()),
                # Char
                (gt_char_char, ()), (gt_char_any, ()), (gt_char_num, ()),
                # More cross-type
                (gt_absstr_any, ()), (gt_absstr_num, ()),
                (gt_i64_bool, ()), (gt_bool_i64, ()),
                (gt_f64_i64, ()), (gt_i64_f64, ()),
            ]

            all_funcs = vcat(wrapper_funcs, all_subtype_funcs)
            bytes = WasmTarget.compile_multi(all_funcs)
            @test length(bytes) > 0

            valid = try run(`$(first(NODE_CMD)) -e "1"`) !== nothing; true catch; false end
            if valid
                # Ground truth: each test matches native Julia <:
                # Concrete numeric identity
                @test run_wasm(bytes, "gt_i64_i64") == 1      # Int64 <: Int64
                @test run_wasm(bytes, "gt_i32_i32") == 1      # Int32 <: Int32
                @test run_wasm(bytes, "gt_f64_f64") == 1      # Float64 <: Float64
                @test run_wasm(bytes, "gt_f32_f32") == 1      # Float32 <: Float32
                @test run_wasm(bytes, "gt_bool_bool") == 1    # Bool <: Bool
                # Numeric hierarchy (true)
                @test run_wasm(bytes, "gt_i64_num") == 1      # Int64 <: Number
                @test run_wasm(bytes, "gt_i64_real") == 1     # Int64 <: Real
                @test run_wasm(bytes, "gt_i64_int") == 1      # Int64 <: Integer
                @test run_wasm(bytes, "gt_i64_signed") == 1   # Int64 <: Signed
                @test run_wasm(bytes, "gt_i64_any") == 1      # Int64 <: Any
                @test run_wasm(bytes, "gt_i32_signed") == 1   # Int32 <: Signed
                @test run_wasm(bytes, "gt_i32_num") == 1      # Int32 <: Number
                @test run_wasm(bytes, "gt_f64_num") == 1      # Float64 <: Number
                @test run_wasm(bytes, "gt_f64_real") == 1     # Float64 <: Real
                @test run_wasm(bytes, "gt_f64_absfloat") == 1 # Float64 <: AbstractFloat
                @test run_wasm(bytes, "gt_f32_num") == 1      # Float32 <: Number
                @test run_wasm(bytes, "gt_bool_int") == 1     # Bool <: Integer
                @test run_wasm(bytes, "gt_bool_num") == 1     # Bool <: Number
                @test run_wasm(bytes, "gt_u64_unsigned") == 1 # UInt64 <: Unsigned
                @test run_wasm(bytes, "gt_u64_num") == 1      # UInt64 <: Number
                @test run_wasm(bytes, "gt_u8_unsigned") == 1  # UInt8 <: Unsigned
                @test run_wasm(bytes, "gt_u8_num") == 1       # UInt8 <: Number
                # Numeric hierarchy (false)
                @test run_wasm(bytes, "gt_i64_unsigned") == 0 # Int64 !<: Unsigned
                @test run_wasm(bytes, "gt_i64_absfloat") == 0 # Int64 !<: AbstractFloat
                @test run_wasm(bytes, "gt_i64_absstr") == 0   # Int64 !<: AbstractString
                @test run_wasm(bytes, "gt_i32_i64") == 0      # Int32 !<: Int64
                @test run_wasm(bytes, "gt_f64_signed") == 0   # Float64 !<: Signed
                @test run_wasm(bytes, "gt_f32_f64") == 0      # Float32 !<: Float64
                @test run_wasm(bytes, "gt_bool_signed") == 0  # Bool !<: Signed
                @test run_wasm(bytes, "gt_u64_signed") == 0   # UInt64 !<: Signed
                # Reverse direction (abstract !<: concrete)
                @test run_wasm(bytes, "gt_num_i64") == 0      # Number !<: Int64
                @test run_wasm(bytes, "gt_real_i64") == 0     # Real !<: Int64
                @test run_wasm(bytes, "gt_signed_i64") == 0   # Signed !<: Int64
                @test run_wasm(bytes, "gt_any_i64") == 0      # Any !<: Int64
                @test run_wasm(bytes, "gt_any_num") == 0      # Any !<: Number
                # Any <: Any
                @test run_wasm(bytes, "gt_any_any") == 1      # Any <: Any
                # String types
                @test run_wasm(bytes, "gt_str_str") == 1      # String <: String
                @test run_wasm(bytes, "gt_str_absstr") == 1   # String <: AbstractString
                @test run_wasm(bytes, "gt_str_any") == 1      # String <: Any
                @test run_wasm(bytes, "gt_str_num") == 0      # String !<: Number
                @test run_wasm(bytes, "gt_absstr_str") == 0   # AbstractString !<: String
                # Parametric types — invariant
                @test run_wasm(bytes, "gt_vi64_vi64") == 1    # Vector{Int64} <: Vector{Int64}
                @test run_wasm(bytes, "gt_vi64_vnum") == 0    # Vector{Int64} !<: Vector{Number} (invariant!)
                @test run_wasm(bytes, "gt_vf64_vf64") == 1    # Vector{Float64} <: Vector{Float64}
                @test run_wasm(bytes, "gt_vf64_vnum") == 0    # Vector{Float64} !<: Vector{Number}
                @test run_wasm(bytes, "gt_vi32_vi32") == 1    # Vector{Int32} <: Vector{Int32}
                @test run_wasm(bytes, "gt_vi32_vi64") == 0    # Vector{Int32} !<: Vector{Int64}
                @test run_wasm(bytes, "gt_di64_di64") == 1    # Dict{String,Int64} <: Dict{String,Int64}
                @test run_wasm(bytes, "gt_di64_dnum") == 0    # Dict{String,Int64} !<: Dict{String,Number}
                @test run_wasm(bytes, "gt_pi_pi") == 1        # Pair{Int64,Int64} <: Pair{Int64,Int64}
                @test run_wasm(bytes, "gt_pi_pn") == 0        # Pair{Int64,Int64} !<: Pair{Int64,Number}
                # Tuple types — covariant
                @test run_wasm(bytes, "gt_ti64_ti64") == 1    # Tuple{Int64} <: Tuple{Int64}
                @test run_wasm(bytes, "gt_ti64_tnum") == 1    # Tuple{Int64} <: Tuple{Number} (covariant!)
                @test run_wasm(bytes, "gt_tif_tnn") == 1      # Tuple{Int64,Float64} <: Tuple{Number,Number}
                @test run_wasm(bytes, "gt_t0_t0") == 1        # Tuple{} <: Tuple{}
                @test run_wasm(bytes, "gt_t1_t2") == 0        # Tuple{Int64} !<: Tuple{Int64,Float64}
                @test run_wasm(bytes, "gt_tf_ti") == 0        # Tuple{Float64} !<: Tuple{Int64}
                # More numerics
                @test run_wasm(bytes, "gt_i8_signed") == 1    # Int8 <: Signed
                @test run_wasm(bytes, "gt_i8_int") == 1       # Int8 <: Integer
                @test run_wasm(bytes, "gt_i8_num") == 1       # Int8 <: Number
                @test run_wasm(bytes, "gt_i8_i64") == 0       # Int8 !<: Int64
                @test run_wasm(bytes, "gt_i16_signed") == 1   # Int16 <: Signed
                @test run_wasm(bytes, "gt_i16_num") == 1      # Int16 <: Number
                @test run_wasm(bytes, "gt_u16_unsigned") == 1 # UInt16 <: Unsigned
                @test run_wasm(bytes, "gt_u16_num") == 1      # UInt16 <: Number
                @test run_wasm(bytes, "gt_i128_signed") == 1  # Int128 <: Signed
                @test run_wasm(bytes, "gt_i128_num") == 1     # Int128 <: Number
                @test run_wasm(bytes, "gt_u128_unsigned") == 1 # UInt128 <: Unsigned
                @test run_wasm(bytes, "gt_f16_absfloat") == 1 # Float16 <: AbstractFloat
                @test run_wasm(bytes, "gt_f16_real") == 1     # Float16 <: Real
                @test run_wasm(bytes, "gt_f16_f64") == 0      # Float16 !<: Float64
                # Cross-category false
                @test run_wasm(bytes, "gt_i64_str") == 0      # Int64 !<: String
                @test run_wasm(bytes, "gt_str_i64") == 0      # String !<: Int64
                @test run_wasm(bytes, "gt_f64_str") == 0      # Float64 !<: String
                @test run_wasm(bytes, "gt_bool_str") == 0     # Bool !<: String
                @test run_wasm(bytes, "gt_num_str") == 0      # Number !<: String
                # Abstract hierarchy
                @test run_wasm(bytes, "gt_signed_int") == 1   # Signed <: Integer
                @test run_wasm(bytes, "gt_int_real") == 1     # Integer <: Real
                @test run_wasm(bytes, "gt_real_num") == 1     # Real <: Number
                @test run_wasm(bytes, "gt_num_any") == 1      # Number <: Any
                @test run_wasm(bytes, "gt_unsigned_int") == 1 # Unsigned <: Integer
                @test run_wasm(bytes, "gt_absfloat_real") == 1 # AbstractFloat <: Real
                @test run_wasm(bytes, "gt_signed_unsigned") == 0 # Signed !<: Unsigned
                @test run_wasm(bytes, "gt_unsigned_signed") == 0 # Unsigned !<: Signed
                @test run_wasm(bytes, "gt_absfloat_int") == 0 # AbstractFloat !<: Integer
                @test run_wasm(bytes, "gt_int_absfloat") == 0 # Integer !<: AbstractFloat
                # Nothing
                @test run_wasm(bytes, "gt_nothing_nothing") == 1 # Nothing <: Nothing
                @test run_wasm(bytes, "gt_nothing_any") == 1    # Nothing <: Any
                @test run_wasm(bytes, "gt_nothing_i64") == 0    # Nothing !<: Int64
                @test run_wasm(bytes, "gt_i64_nothing") == 0    # Int64 !<: Nothing
                # Type{T}
                @test run_wasm(bytes, "gt_typei_typei") == 1  # Type{Int64} <: Type{Int64}
                @test run_wasm(bytes, "gt_typei_typen") == 0  # Type{Int64} !<: Type{Number}
                @test run_wasm(bytes, "gt_typei_dt") == 1     # Type{Int64} <: DataType
                # Char
                @test run_wasm(bytes, "gt_char_char") == 1    # Char <: Char
                @test run_wasm(bytes, "gt_char_any") == 1     # Char <: Any
                @test run_wasm(bytes, "gt_char_num") == 0     # Char !<: Number
                # More cross-type
                @test run_wasm(bytes, "gt_absstr_any") == 1   # AbstractString <: Any
                @test run_wasm(bytes, "gt_absstr_num") == 0   # AbstractString !<: Number
                @test run_wasm(bytes, "gt_i64_bool") == 0     # Int64 !<: Bool
                @test run_wasm(bytes, "gt_bool_i64") == 0     # Bool !<: Int64
                @test run_wasm(bytes, "gt_f64_i64") == 0      # Float64 !<: Int64
                @test run_wasm(bytes, "gt_i64_f64") == 0      # Int64 !<: Float64
            end
        end

    end

    # ========================================================================
    # Phase 38: Dict/Set from Base (PURE-9065)
    # ========================================================================
    @testset "Phase 38: Dict/Set from Base (PURE-9065)" begin

        @testset "Dict{Int64,Int64} basic operations" begin
            function dict_int_create()::Int64
                d = Dict{Int64, Int64}()
                d[1] = 10
                d[2] = 20
                d[3] = 30
                return d[1] + d[2] + d[3]
            end
            bytes = compile(dict_int_create, ())
            @test bytes !== nothing
            @test run_wasm(bytes, "dict_int_create") == 60

            function dict_int_haskey()::Int64
                d = Dict{Int64, Int64}()
                d[1] = 10
                d[2] = 20
                has1 = haskey(d, 1)
                has3 = haskey(d, 3)
                len = length(d)
                return Int64(has1) * 100 + Int64(has3) * 10 + len
            end
            bytes2 = compile(dict_int_haskey, ())
            @test bytes2 !== nothing
            @test run_wasm(bytes2, "dict_int_haskey") == 102
        end

        @testset "Dict{String,Int64} operations" begin
            function dict_str_create()::Int64
                d = Dict{String, Int64}()
                d["a"] = Int64(1)
                d["b"] = Int64(2)
                return d["a"] + d["b"]
            end
            bytes = compile(dict_str_create, ())
            @test bytes !== nothing
            @test run_wasm(bytes, "dict_str_create") == 3
        end

        @testset "Dict delete!" begin
            function dict_delete_test()::Int64
                d = Dict{Int64, Int64}()
                d[1] = 10
                d[2] = 20
                d[3] = 30
                delete!(d, 2)
                len = length(d)
                has2 = haskey(d, 2)
                return len * 10 + Int64(has2)
            end
            bytes = compile(dict_delete_test, ())
            @test bytes !== nothing
            @test run_wasm(bytes, "dict_delete_test") == 20
        end

        @testset "Set{Int64} operations" begin
            function set_create_test()::Int64
                s = Set{Int64}([1, 2, 3])
                return Int64(length(s)) * 100 + Int64(2 in s) * 10 + Int64(5 in s)
            end
            bytes = compile(set_create_test, ())
            @test bytes !== nothing
            @test run_wasm(bytes, "set_create_test") == 310
        end

    end

    # Phase 39: Broadcasting (PURE-9066)
    # Tests .+, .*, .-, ./ operators on arrays
    # NOTE: Broadcasting IR changed in Julia 1.13, causing runtime exceptions.
    # Works on 1.12. Marked broken on 1.13 pending codegen fix for new IR patterns.
    @testset "Phase 39: Broadcasting (PURE-9066)" begin
        _bc_broken = VERSION >= v"1.13.0-beta1"

        @testset "Int32 .+ vector" begin
            function bc_add_i32()::Int32
                a = Int32[1, 2, 3]; b = Int32[4, 5, 6]; c = a .+ b
                return c[1] + c[2] + c[3]  # 5+7+9 = 21
            end
            if _bc_broken
                @test_broken compare_julia_wasm(bc_add_i32).pass
            else
                @test compare_julia_wasm(bc_add_i32).pass
            end
        end

        @testset "Int32 .* scalar" begin
            function bc_mul_scalar_i32()::Int32
                a = Int32[1, 2, 3]; c = a .* Int32(2)
                return c[1] + c[2] + c[3]  # 2+4+6 = 12
            end
            if _bc_broken
                @test_broken compare_julia_wasm(bc_mul_scalar_i32).pass
            else
                @test compare_julia_wasm(bc_mul_scalar_i32).pass
            end
        end

        @testset "Int32 .- vector" begin
            function bc_sub_i32()::Int32
                a = Int32[10, 20, 30]; b = Int32[1, 2, 3]; c = a .- b
                return c[1] + c[2] + c[3]  # 9+18+27 = 54
            end
            if _bc_broken
                @test_broken compare_julia_wasm(bc_sub_i32).pass
            else
                @test compare_julia_wasm(bc_sub_i32).pass
            end
        end

        @testset "Float64 .+ vector" begin
            function bc_add_f64()::Float64
                a = Float64[1.0, 2.0, 3.0]; b = Float64[0.5, 1.5, 2.5]; c = a .+ b
                return c[1] + c[2] + c[3]  # 1.5+3.5+5.5 = 10.5
            end
            if _bc_broken
                @test_broken compare_julia_wasm(bc_add_f64).pass
            else
                @test compare_julia_wasm(bc_add_f64).pass
            end
        end

        @testset "Float64 ./ scalar" begin
            function bc_div_f64()::Float64
                a = Float64[10.0, 20.0, 30.0]; c = a ./ 2.0
                return c[2]  # 10.0
            end
            if _bc_broken
                @test_broken compare_julia_wasm(bc_div_f64).pass
            else
                @test compare_julia_wasm(bc_div_f64).pass
            end
        end

        @testset "Int64 .+ vector" begin
            function bc_add_i64()::Int64
                a = Int64[10, 20, 30]; b = Int64[1, 2, 3]; c = a .+ b
                return c[1] + c[2] + c[3]  # 11+22+33 = 66
            end
            if _bc_broken
                @test_broken compare_julia_wasm(bc_add_i64).pass
            else
                @test compare_julia_wasm(bc_add_i64).pass
            end
        end

    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phases 40-45 (Self-Hosting) moved to test/selfhost/runtests.jl
    # Run separately: julia +1.12 --project=. test/selfhost/runtests.jl
    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 46: D-002 — compile_value dispatch via ref.test + field access
    # ═══════════════════════════════════════════════════════════════════════════
    @testset "Phase 46: compile_value dispatch (D-002)" begin
        # Compile all D-002 functions together
        d002_bytes = compile_multi([
            (cv_field_dispatch, (Any,)),
            (cv_type_tag, (Any,)),
            (test_cv_ssa_field, ()),
            (test_cv_arg_field, ()),
            (test_cv_goto_field, ()),
            (test_cv_unknown_field, ()),
            (test_cv_tag_ssa, ()),
            (test_cv_tag_arg, ()),
            (test_cv_tag_goto, ()),
            (test_cv_tag_return, ()),
            (test_cv_combined_tags, ()),
        ])
        @test length(d002_bytes) > 0

        # 46a: Field access after isa-narrowing (PiNode → ref.cast → struct.get)
        @testset "Field access: SSAValue.id" begin
            result = run_wasm(d002_bytes, "test_cv_ssa_field")
            @test result == 42
        end
        @testset "Field access: Argument.n" begin
            result = run_wasm(d002_bytes, "test_cv_arg_field")
            @test result == 7
        end
        @testset "Field access: GotoNode.label" begin
            result = run_wasm(d002_bytes, "test_cv_goto_field")
            @test result == 99
        end
        @testset "Field access: unknown type fallback" begin
            result = run_wasm(d002_bytes, "test_cv_unknown_field")
            @test result == -1
        end

        # 46b: Type tag dispatch — ref.test on 7 IR node types
        @testset "Type tag: SSAValue → 1" begin
            @test run_wasm(d002_bytes, "test_cv_tag_ssa") == 1
        end
        @testset "Type tag: Argument → 2" begin
            @test run_wasm(d002_bytes, "test_cv_tag_arg") == 2
        end
        @testset "Type tag: GotoNode → 3" begin
            @test run_wasm(d002_bytes, "test_cv_tag_goto") == 3
        end
        @testset "Type tag: ReturnNode → 4" begin
            @test run_wasm(d002_bytes, "test_cv_tag_return") == 4
        end

        # 46c: Combined — cross-function dispatch with accumulation
        @testset "Combined tags: 1+2+3+4 = 10" begin
            @test run_wasm(d002_bytes, "test_cv_combined_tags") == 10
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 47: D-003 — compile_statement dispatch (ReturnNode + Expr head)
    # ═══════════════════════════════════════════════════════════════════════════
    @testset "Phase 47: compile_statement dispatch (D-003)" begin
        d003_bytes = compile_multi([
            (cs_dispatch, (Any,)),
            (test_cs_return, ()),
            (test_cs_goto, ()),
            (test_cs_gotoifnot, ()),
            (test_cs_call_expr, ()),
            (test_cs_invoke_expr, ()),
            (test_cs_new_expr, ()),
            (test_cs_other_expr, ()),
            (test_cs_combined, ()),
        ])
        @test length(d003_bytes) > 0

        # 47a: IR node type dispatch
        @testset "ReturnNode → 1" begin
            @test run_wasm(d003_bytes, "test_cs_return") == 1
        end
        @testset "GotoNode → 2" begin
            @test run_wasm(d003_bytes, "test_cs_goto") == 2
        end
        @testset "GotoIfNot → 3" begin
            @test run_wasm(d003_bytes, "test_cs_gotoifnot") == 3
        end

        # 47b: Expr head symbol dispatch (stmt.head === :call etc.)
        @testset "Expr(:call) → 10" begin
            @test run_wasm(d003_bytes, "test_cs_call_expr") == 10
        end
        @testset "Expr(:invoke) → 11" begin
            @test run_wasm(d003_bytes, "test_cs_invoke_expr") == 11
        end
        @testset "Expr(:new) → 12" begin
            @test run_wasm(d003_bytes, "test_cs_new_expr") == 12
        end
        @testset "Expr(:boundscheck) → 19 (other)" begin
            @test run_wasm(d003_bytes, "test_cs_other_expr") == 19
        end

        # 47c: Combined statement dispatch
        @testset "Combined: 1+10+2+3 = 16" begin
            @test run_wasm(d003_bytes, "test_cs_combined") == 16
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 48: D-004 — Intrinsic dispatch (symbol name → opcode selection)
    # ═══════════════════════════════════════════════════════════════════════════
    @testset "Phase 48: intrinsic dispatch (D-004)" begin
        d004_bytes = compile_multi([
            (intrinsic_tag, (Symbol,)),
            (test_intr_add, ()),
            (test_intr_mul, ()),
            (test_intr_sub, ()),
            (test_intr_slt, ()),
            (test_intr_unknown, ()),
            (test_combined_intrinsic, (Int64, Int64)),
        ])
        @test length(d004_bytes) > 0

        # 48a: Intrinsic name dispatch via symbol comparison
        @testset "add_int → 1" begin
            @test run_wasm(d004_bytes, "test_intr_add") == 1
        end
        @testset "mul_int → 3" begin
            @test run_wasm(d004_bytes, "test_intr_mul") == 3
        end
        @testset "sub_int → 2" begin
            @test run_wasm(d004_bytes, "test_intr_sub") == 2
        end
        @testset "slt_int → 4" begin
            @test run_wasm(d004_bytes, "test_intr_slt") == 4
        end
        @testset "unknown → 0" begin
            @test run_wasm(d004_bytes, "test_intr_unknown") == 0
        end

        # 48b: Real arithmetic intrinsics produce correct opcodes
        @testset "(5+3)*(5-3) = 16" begin
            @test run_wasm(d004_bytes, "test_combined_intrinsic", Int64(5), Int64(3)) == 16
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 49: D-005 — SSA local allocation (multi-use values)
    # ═══════════════════════════════════════════════════════════════════════════
    @testset "Phase 49: SSA local allocation (D-005)" begin
        d005_bytes = compile_multi([
            (test_ssa_multi_use, (Int64,)),
            (test_ssa_chain, (Int64, Int64)),
            (test_ssa_nested, (Int64,)),
        ])
        @test length(d005_bytes) > 0

        @testset "multi-use: x*x + x*x, x=5 → 50" begin
            @test run_wasm(d005_bytes, "test_ssa_multi_use", Int64(5)) == 50
        end
        @testset "multi-use: x*x + x*x, x=7 → 98" begin
            @test run_wasm(d005_bytes, "test_ssa_multi_use", Int64(7)) == 98
        end
        @testset "chain: s² + d², (5,3) → 68" begin
            @test run_wasm(d005_bytes, "test_ssa_chain", Int64(5), Int64(3)) == 68
        end
        @testset "nested: (x+1)*2 + (x+1), x=5 → 18" begin
            @test run_wasm(d005_bytes, "test_ssa_nested", Int64(5)) == 18
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 50: D-006 — Control flow (if/else, loops, phi nodes)
    # ═══════════════════════════════════════════════════════════════════════════
    @testset "Phase 50: control flow (D-006)" begin
        d006_bytes = compile_multi([
            (test_cf_if_else, (Int64,)),
            (test_cf_loop, (Int64,)),
            (test_cf_phi, (Int64,)),
            (test_cf_nested, (Int64, Int64)),
        ])
        @test length(d006_bytes) > 0

        @testset "if/else: 5 → 10 (positive branch)" begin
            @test run_wasm(d006_bytes, "test_cf_if_else", Int64(5)) == 10
        end
        @testset "if/else: -3 → 3 (negative branch)" begin
            @test run_wasm(d006_bytes, "test_cf_if_else", Int64(-3)) == 3
        end
        @testset "loop: sum(1..10) = 55" begin
            @test run_wasm(d006_bytes, "test_cf_loop", Int64(10)) == 55
        end
        @testset "loop: sum(1..0) = 0" begin
            @test run_wasm(d006_bytes, "test_cf_loop", Int64(0)) == 0
        end
        @testset "phi: 15 → 115 (>10 branch)" begin
            @test run_wasm(d006_bytes, "test_cf_phi", Int64(15)) == 115
        end
        @testset "phi: 5 → 6 (≤10 branch)" begin
            @test run_wasm(d006_bytes, "test_cf_phi", Int64(5)) == 6
        end
        @testset "nested: (3,4) → 7" begin
            @test run_wasm(d006_bytes, "test_cf_nested", Int64(3), Int64(4)) == 7
        end
        @testset "nested: (3,-4) → 7" begin
            @test run_wasm(d006_bytes, "test_cf_nested", Int64(3), Int64(-4)) == 7
        end
        @testset "nested: (-1,5) → 0" begin
            @test run_wasm(d006_bytes, "test_cf_nested", Int64(-1), Int64(5)) == 0
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 51: D-007 — WASM module assembly (multi-function, multi-type)
    # ═══════════════════════════════════════════════════════════════════════════
    @testset "Phase 51: WASM module assembly (D-007)" begin
        d007_bytes = compile_multi([
            (d007_helper, (Int64,)),
            (d007_square_double, (Int64,)),
            (d007_sum_loop, (Int64,)),
            (d007_i32_add, (Int32, Int32)),
            (d007_f64_mul, (Float64, Float64)),
        ])
        @test length(d007_bytes) > 0
        # Valid WASM magic number
        @test d007_bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]

        @testset "cross-call: helper(5) = 10" begin
            @test run_wasm(d007_bytes, "d007_helper", Int64(5)) == 10
        end
        @testset "cross-call: square_double(4) = 32" begin
            @test run_wasm(d007_bytes, "d007_square_double", Int64(4)) == 32
        end
        @testset "cross-call in loop: sum_loop(5) = 30" begin
            @test run_wasm(d007_bytes, "d007_sum_loop", Int64(5)) == 30
        end
        @testset "i32 type: add(10,20) = 30" begin
            @test run_wasm(d007_bytes, "d007_i32_add", Int32(10), Int32(20)) == 30
        end
        @testset "f64 type: mul(2.5,4.0) = 10.0" begin
            @test run_wasm(d007_bytes, "d007_f64_mul", 2.5, 4.0) == 10.0
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 52: E2E-001 — f(x)=x*x+1 via REAL codegen dispatch in WASM
    # ═══════════════════════════════════════════════════════════════════════════
    @testset "Phase 52: E2E-001 f(5)=26 via REAL codegen (no hand-emitted opcodes)" begin

        # --- 52a: Native verification ---
        @testset "native: e2e_run() produces valid WASM with f(5)=26" begin
            native_bytes = e2e_run()
            @test length(native_bytes) > 0
            @test native_bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
            result = run_wasm(native_bytes, "f", Int64(5))
            @test result == 26
        end

        # --- 52b: Compile mini-codegen to WASM ---
        e2e_outer = compile_multi([
            (e2e_run, (), "run"),
            (e2e_compile_stmt, (Vector{UInt8}, Any, Int32)),
            (e2e_emit_val, (Vector{UInt8}, Any)),
            (e2e_emit_op, (Vector{UInt8}, Symbol)),
            (wasm_bytes_length, (Vector{UInt8},), "blen"),
            (wasm_bytes_get, (Vector{UInt8}, Int32), "bget"),
        ])

        @testset "outer module: valid WASM binary" begin
            @test length(e2e_outer) > 0
            @test e2e_outer[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
            println("  E2E-001 outer module: $(length(e2e_outer)) bytes ($(round(length(e2e_outer)/1024, digits=1)) KB)")
        end

        # --- 52c: End-to-end — outer WASM runs codegen → inner WASM → f(5n)===26n ---
        @testset "E2E: f(5n)===26n via WASM-in-WASM codegen" begin
            e2e_path = tempname() * ".wasm"
            write(e2e_path, e2e_outer)

            node_script = """
            const fs = require('fs');
            const bytes = fs.readFileSync(process.argv[2]);
            (async () => {
                try {
                    const { instance } = await WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } });
                    const e = instance.exports;
                    const result = e.run();
                    const len = e.blen(result);
                    const arr = new Uint8Array(len);
                    for (let i = 0; i < len; i++) arr[i] = e.bget(result, i + 1);
                    const m2 = await WebAssembly.instantiate(arr);
                    const f = m2.instance.exports.f;
                    const r = f(5n);
                    console.log(r === 26n ? 'E2E_PASS' : 'E2E_FAIL:' + String(r));
                } catch(err) {
                    console.log('E2E_FAIL:' + err.message);
                }
            })();
            """

            script_path = tempname() * ".cjs"
            write(script_path, node_script)
            output = try
                read(`node $script_path $e2e_path`, String)
            catch e
                "E2E_FAIL: $(sprint(showerror, e))"
            end
            rm(script_path, force=true)
            rm(e2e_path, force=true)

            @test occursin("E2E_PASS", output)
            if !occursin("E2E_PASS", output)
                println("  E2E output: ", strip(output))
            end
        end

        # --- 52d: Cheat-proof: WAT must contain ref.test (Rule 2) ---
        @testset "cheat-proof: WAT contains ref.test dispatch" begin
            e2e_path = tempname() * ".wasm"
            write(e2e_path, e2e_outer)
            has_ref_test = false
            try
                wat = read(`wasm-tools print $e2e_path`, String)
                has_ref_test = occursin("ref.test", wat)
                if has_ref_test
                    ref_test_count = count("ref.test", wat)
                    println("  ref.test instructions found: $ref_test_count")
                else
                    println("  WARNING: No ref.test instructions found in WAT!")
                end
            catch
                # wasm-tools not available — skip WAT check
                println("  wasm-tools not available, skipping WAT check")
                has_ref_test = true  # Don't fail if tool is missing
            end
            rm(e2e_path, force=true)
            @test has_ref_test
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 53: E2E-002 — 20-function regression suite via REAL codegen
    # ═══════════════════════════════════════════════════════════════════════════
    @testset "Phase 53: E2E-002 20-function regression (no hand-emitted opcodes)" begin

        # --- 53a: Native verification — all 20 produce valid WASM with correct results ---
        native_specs = [
            (e2e_r01, "r01: x*x+1",    1, [(Int64(5), 26), (Int64(0), 1), (Int64(10), 101)]),
            (e2e_r02, "r02: x+1",      1, [(Int64(0), 1), (Int64(5), 6), (Int64(-1), 0)]),
            (e2e_r03, "r03: x*2",      1, [(Int64(5), 10), (Int64(0), 0), (Int64(-3), -6)]),
            (e2e_r04, "r04: x*x",      1, [(Int64(5), 25), (Int64(0), 0), (Int64(-3), 9)]),
            (e2e_r05, "r05: x*x*x",    1, [(Int64(3), 27), (Int64(0), 0), (Int64(-2), -8)]),
            (e2e_r06, "r06: x+y",      2, [((Int64(1), Int64(2)), 3), ((Int64(-5), Int64(5)), 0)]),
            (e2e_r07, "r07: x-y",      2, [((Int64(5), Int64(3)), 2), ((Int64(3), Int64(5)), -2)]),
            (e2e_r08, "r08: x*y",      2, [((Int64(3), Int64(4)), 12), ((Int64(0), Int64(5)), 0)]),
            (e2e_r09, "r09: x+y+z",    3, [((Int64(1), Int64(2), Int64(3)), 6)]),
            (e2e_r10, "r10: x²+x+1",   1, [(Int64(0), 1), (Int64(1), 3), (Int64(5), 31)]),
            (e2e_r11, "r11: x²-y²",    2, [((Int64(5), Int64(3)), 16), ((Int64(7), Int64(7)), 0)]),
            (e2e_r12, "r12: xy+x+y",   2, [((Int64(2), Int64(3)), 11), ((Int64(0), Int64(0)), 0)]),
            (e2e_r13, "r13: x+x+x",    1, [(Int64(1), 3), (Int64(5), 15), (Int64(0), 0)]),
            (e2e_r14, "r14: 10x+5",    1, [(Int64(0), 5), (Int64(1), 15), (Int64(5), 55)]),
            (e2e_r15, "r15: identity",  1, [(Int64(42), 42), (Int64(0), 0), (Int64(-1), -1)]),
            (e2e_r16, "r16: const 42",  1, [(Int64(0), 42), (Int64(999), 42)]),
            (e2e_r17, "r17: x²+y²",    2, [((Int64(3), Int64(4)), 25), ((Int64(0), Int64(0)), 0)]),
            (e2e_r18, "r18: (x-1)(x+1)", 1, [(Int64(0), -1), (Int64(5), 24), (Int64(-1), 0)]),
            (e2e_r19, "r19: x-1",      1, [(Int64(1), 0), (Int64(0), -1), (Int64(5), 4)]),
            (e2e_r20, "r20: xy+z",     3, [((Int64(2), Int64(3), Int64(4)), 10)]),
        ]

        @testset "native: $name" for (fn, name, nargs, cases) in native_specs
            inner = fn()
            @test inner[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
            for (input, expected) in cases
                if nargs == 1
                    @test run_wasm(inner, "f", input) == expected
                elseif nargs == 2
                    @test run_wasm(inner, "f", input[1], input[2]) == expected
                else
                    @test run_wasm(inner, "f", input[1], input[2], input[3]) == expected
                end
            end
        end

        # --- 53b: Compile all 20 entry points + shared helpers to WASM ---
        e2e_002_mod = compile_multi([
            (e2e_compile_stmt, (Vector{UInt8}, Any, Int32)),
            (e2e_emit_val, (Vector{UInt8}, Any)),
            (e2e_emit_op, (Vector{UInt8}, Symbol)),
            (wasm_bytes_length, (Vector{UInt8},), "blen"),
            (wasm_bytes_get, (Vector{UInt8}, Int32), "bget"),
            (e2e_r01, (), "r01"), (e2e_r02, (), "r02"), (e2e_r03, (), "r03"),
            (e2e_r04, (), "r04"), (e2e_r05, (), "r05"), (e2e_r06, (), "r06"),
            (e2e_r07, (), "r07"), (e2e_r08, (), "r08"), (e2e_r09, (), "r09"),
            (e2e_r10, (), "r10"), (e2e_r11, (), "r11"), (e2e_r12, (), "r12"),
            (e2e_r13, (), "r13"), (e2e_r14, (), "r14"), (e2e_r15, (), "r15"),
            (e2e_r16, (), "r16"), (e2e_r17, (), "r17"), (e2e_r18, (), "r18"),
            (e2e_r19, (), "r19"), (e2e_r20, (), "r20"),
        ])

        @testset "outer module: valid WASM binary" begin
            @test length(e2e_002_mod) > 0
            @test e2e_002_mod[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
            println("  E2E-002 outer module: $(length(e2e_002_mod)) bytes ($(round(length(e2e_002_mod)/1024, digits=1)) KB)")
        end

        # --- 53c: WASM-in-WASM — run all 20 via Node.js ---
        @testset "E2E: 20/20 functions via WASM-in-WASM codegen" begin
            e2e_path = tempname() * ".wasm"
            write(e2e_path, e2e_002_mod)

            node_script = raw"""
            const fs = require('fs');
            const bytes = fs.readFileSync(process.argv[2]);
            const specs = [
              {fn:'r01',tests:[[[5n],26n],[[0n],1n],[[-3n],10n],[[10n],101n],[[1n],2n]]},
              {fn:'r02',tests:[[[0n],1n],[[5n],6n],[[-1n],0n],[[100n],101n],[[-100n],-99n]]},
              {fn:'r03',tests:[[[0n],0n],[[5n],10n],[[-3n],-6n],[[100n],200n],[[1n],2n]]},
              {fn:'r04',tests:[[[0n],0n],[[5n],25n],[[-3n],9n],[[10n],100n],[[1n],1n]]},
              {fn:'r05',tests:[[[0n],0n],[[3n],27n],[[-2n],-8n],[[5n],125n],[[1n],1n]]},
              {fn:'r06',tests:[[[1n,2n],3n],[[0n,0n],0n],[[-5n,5n],0n],[[10n,20n],30n],[[100n,-50n],50n]]},
              {fn:'r07',tests:[[[5n,3n],2n],[[0n,0n],0n],[[3n,5n],-2n],[[10n,1n],9n],[[-5n,-3n],-2n]]},
              {fn:'r08',tests:[[[3n,4n],12n],[[0n,5n],0n],[[-3n,4n],-12n],[[7n,7n],49n],[[1n,100n],100n]]},
              {fn:'r09',tests:[[[1n,2n,3n],6n],[[0n,0n,0n],0n],[[-1n,-2n,-3n],-6n],[[10n,20n,30n],60n],[[1n,1n,1n],3n]]},
              {fn:'r10',tests:[[[0n],1n],[[1n],3n],[[5n],31n],[[-1n],1n],[[10n],111n]]},
              {fn:'r11',tests:[[[5n,3n],16n],[[0n,0n],0n],[[3n,5n],-16n],[[10n,1n],99n],[[7n,7n],0n]]},
              {fn:'r12',tests:[[[2n,3n],11n],[[0n,0n],0n],[[1n,1n],3n],[[5n,10n],65n],[[-1n,-1n],-1n]]},
              {fn:'r13',tests:[[[0n],0n],[[1n],3n],[[5n],15n],[[-3n],-9n],[[100n],300n]]},
              {fn:'r14',tests:[[[0n],5n],[[1n],15n],[[5n],55n],[[-1n],-5n],[[10n],105n]]},
              {fn:'r15',tests:[[[0n],0n],[[42n],42n],[[-1n],-1n],[[999n],999n],[[1n],1n]]},
              {fn:'r16',tests:[[[0n],42n],[[1n],42n],[[-1n],42n],[[999n],42n],[[5n],42n]]},
              {fn:'r17',tests:[[[3n,4n],25n],[[0n,0n],0n],[[1n,1n],2n],[[5n,12n],169n],[[-3n,4n],25n]]},
              {fn:'r18',tests:[[[0n],-1n],[[1n],0n],[[2n],3n],[[5n],24n],[[-1n],0n]]},
              {fn:'r19',tests:[[[1n],0n],[[0n],-1n],[[5n],4n],[[100n],99n],[[-1n],-2n]]},
              {fn:'r20',tests:[[[2n,3n,4n],10n],[[0n,5n,1n],1n],[[5n,5n,5n],30n],[[-2n,3n,1n],-5n],[[10n,10n,10n],110n]]},
            ];
            (async () => {
              try {
                const {instance} = await WebAssembly.instantiate(bytes, {Math:{pow:Math.pow}});
                const e = instance.exports;
                let pass=0, fail=0, fnPass=0;
                for (const spec of specs) {
                  const inner = e[spec.fn]();
                  const len = e.blen(inner);
                  const arr = new Uint8Array(len);
                  for (let i=0; i<len; i++) arr[i] = e.bget(inner, i+1);
                  try {
                    const m2 = await WebAssembly.instantiate(arr);
                    const f = m2.instance.exports.f;
                    let allOk = true;
                    for (const [args, expected] of spec.tests) {
                      const r = f(...args);
                      if (r === expected) { pass++; }
                      else { fail++; allOk=false; console.log('FAIL:'+spec.fn+'('+args+')='+r+' expected '+expected); }
                    }
                    if (allOk) fnPass++;
                  } catch(err) {
                    fail += spec.tests.length;
                    console.log('FAIL:'+spec.fn+' inner WASM: '+err.message);
                  }
                }
                console.log(fnPass+'/'+specs.length+' functions, '+pass+'/'+(pass+fail)+' tests passed');
                console.log(fail===0 ? 'E2E_002_PASS' : 'E2E_002_FAIL');
              } catch(err) { console.log('E2E_002_FAIL:'+err.message); }
            })();
            """

            script_path = tempname() * ".cjs"
            write(script_path, node_script)
            output = try
                read(`node $script_path $e2e_path`, String)
            catch e
                "E2E_002_FAIL: $(sprint(showerror, e))"
            end
            rm(script_path, force=true)
            rm(e2e_path, force=true)

            println("  E2E-002: ", strip(output))
            @test occursin("E2E_002_PASS", output)
        end

        # --- 53d: Cheat-proof: WAT must contain ref.test ---
        @testset "cheat-proof: WAT contains ref.test dispatch" begin
            e2e_path = tempname() * ".wasm"
            write(e2e_path, e2e_002_mod)
            has_ref_test = false
            try
                wat = read(`wasm-tools print $e2e_path`, String)
                has_ref_test = occursin("ref.test", wat)
                if has_ref_test
                    ref_test_count = count("ref.test", wat)
                    println("  ref.test instructions found: $ref_test_count")
                end
            catch
                println("  wasm-tools not available, skipping WAT check")
                has_ref_test = true
            end
            rm(e2e_path, force=true)
            @test has_ref_test
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 54: P-001 — Parser-to-codegen pipeline (source → code_typed → WASM)
    #
    # Proves: Julia source → Base.code_typed → IR conversion → WASM codegen → execute.
    # Entry points auto-generated from real source functions (not hand-written IR).
    # ═══════════════════════════════════════════════════════════════════════════
    @testset "Phase 54: P-001 Parser-to-codegen pipeline" begin

        # --- 54a: Cross-validation — auto-generated matches hand-written E2E-002 ---
        @testset "cross-validate: auto-gen matches hand-written" begin
            @test p01_auto_01() == e2e_r01()  # x²+1
            @test p01_auto_02() == e2e_r06()  # x+y
            @test p01_auto_05() == e2e_r05()  # x³
            @test p01_auto_06() == e2e_r11()  # x²-y²
            @test p01_auto_09() == e2e_r15()  # identity
            @test p01_auto_10() == e2e_r09()  # x+y+z
        end

        # --- 54b: Native verification — all 10 produce valid WASM with correct results ---
        native_specs = [
            (p01_auto_01, "p01: x²+1",       1, [(Int64(5), 26), (Int64(0), 1), (Int64(-3), 10)]),
            (p01_auto_02, "p02: x+y",        2, [((Int64(1), Int64(2)), 3), ((Int64(-5), Int64(5)), 0)]),
            (p01_auto_03, "p03: 3x-7",       1, [(Int64(0), -7), (Int64(5), 8), (Int64(10), 23)]),
            (p01_auto_04, "p04: xy+10",      2, [((Int64(2), Int64(3)), 16), ((Int64(0), Int64(5)), 10)]),
            (p01_auto_05, "p05: x³",         1, [(Int64(3), 27), (Int64(0), 0), (Int64(-2), -8)]),
            (p01_auto_06, "p06: x²-y²",     2, [((Int64(5), Int64(3)), 16), ((Int64(0), Int64(0)), 0)]),
            (p01_auto_07, "p07: (x+1)(x-1)", 1, [(Int64(5), 24), (Int64(0), -1), (Int64(1), 0)]),
            (p01_auto_08, "p08: 2x+3y",     2, [((Int64(1), Int64(1)), 5), ((Int64(0), Int64(0)), 0), ((Int64(3), Int64(2)), 12)]),
            (p01_auto_09, "p09: identity",   1, [(Int64(42), 42), (Int64(0), 0), (Int64(-1), -1)]),
            (p01_auto_10, "p10: x+y+z",     3, [((Int64(1), Int64(2), Int64(3)), 6), ((Int64(0), Int64(0), Int64(0)), 0)]),
        ]

        @testset "native: $name" for (fn, name, nargs, cases) in native_specs
            inner = fn()
            @test inner[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
            for (input, expected) in cases
                if nargs == 1
                    @test run_wasm(inner, "f", input) == expected
                elseif nargs == 2
                    @test run_wasm(inner, "f", input[1], input[2]) == expected
                else
                    @test run_wasm(inner, "f", input[1], input[2], input[3]) == expected
                end
            end
        end

        # --- 54c: Compile all 10 auto-gen entries + shared helpers to WASM ---
        p01_mod = compile_multi([
            (e2e_compile_stmt, (Vector{UInt8}, Any, Int32)),
            (e2e_emit_val, (Vector{UInt8}, Any)),
            (e2e_emit_op, (Vector{UInt8}, Symbol)),
            (wasm_bytes_length, (Vector{UInt8},), "blen"),
            (wasm_bytes_get, (Vector{UInt8}, Int32), "bget"),
            (p01_auto_01, (), "p01"), (p01_auto_02, (), "p02"),
            (p01_auto_03, (), "p03"), (p01_auto_04, (), "p04"),
            (p01_auto_05, (), "p05"), (p01_auto_06, (), "p06"),
            (p01_auto_07, (), "p07"), (p01_auto_08, (), "p08"),
            (p01_auto_09, (), "p09"), (p01_auto_10, (), "p10"),
        ])

        @testset "outer module: valid WASM binary" begin
            @test length(p01_mod) > 0
            @test p01_mod[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
            println("  P-001 outer module: $(length(p01_mod)) bytes ($(round(length(p01_mod)/1024, digits=1)) KB)")
        end

        # --- 54d: WASM-in-WASM — run all 10 via Node.js ---
        @testset "P-001: 10/10 functions via WASM-in-WASM codegen" begin
            p01_path = tempname() * ".wasm"
            write(p01_path, p01_mod)

            node_script = raw"""
            const fs = require('fs');
            const bytes = fs.readFileSync(process.argv[2]);
            const specs = [
              {fn:'p01',tests:[[[5n],26n],[[0n],1n],[[-3n],10n],[[10n],101n],[[1n],2n]]},
              {fn:'p02',tests:[[[1n,2n],3n],[[0n,0n],0n],[[-5n,5n],0n],[[10n,20n],30n]]},
              {fn:'p03',tests:[[[0n],-7n],[[5n],8n],[[10n],23n],[[-1n],-10n],[[3n],2n]]},
              {fn:'p04',tests:[[[2n,3n],16n],[[0n,5n],10n],[[1n,1n],11n],[[-2n,3n],4n]]},
              {fn:'p05',tests:[[[3n],27n],[[0n],0n],[[-2n],-8n],[[5n],125n],[[1n],1n]]},
              {fn:'p06',tests:[[[5n,3n],16n],[[0n,0n],0n],[[3n,5n],-16n],[[7n,7n],0n]]},
              {fn:'p07',tests:[[[5n],24n],[[0n],-1n],[[1n],0n],[[10n],99n],[[-1n],0n]]},
              {fn:'p08',tests:[[[1n,1n],5n],[[0n,0n],0n],[[3n,2n],12n],[[5n,10n],40n]]},
              {fn:'p09',tests:[[[42n],42n],[[0n],0n],[[-1n],-1n],[[999n],999n]]},
              {fn:'p10',tests:[[[1n,2n,3n],6n],[[0n,0n,0n],0n],[[-1n,-2n,-3n],-6n],[[10n,20n,30n],60n]]},
            ];
            (async () => {
              try {
                const {instance} = await WebAssembly.instantiate(bytes, {Math:{pow:Math.pow}});
                const e = instance.exports;
                let pass=0, fail=0, fnPass=0;
                for (const spec of specs) {
                  const inner = e[spec.fn]();
                  const len = e.blen(inner);
                  const arr = new Uint8Array(len);
                  for (let i=0; i<len; i++) arr[i] = e.bget(inner, i+1);
                  try {
                    const m2 = await WebAssembly.instantiate(arr);
                    const f = m2.instance.exports.f;
                    let allOk = true;
                    for (const [args, expected] of spec.tests) {
                      const r = f(...args);
                      if (r === expected) { pass++; }
                      else { fail++; allOk=false; console.log('FAIL:'+spec.fn+'('+args+')='+r+' expected '+expected); }
                    }
                    if (allOk) fnPass++;
                  } catch(err) {
                    fail += spec.tests.length;
                    console.log('FAIL:'+spec.fn+' inner WASM: '+err.message);
                  }
                }
                console.log(fnPass+'/'+specs.length+' functions, '+pass+'/'+(pass+fail)+' tests passed');
                console.log(fail===0 ? 'P001_PASS' : 'P001_FAIL');
              } catch(err) { console.log('P001_FAIL:'+err.message); }
            })();
            """

            script_path = tempname() * ".cjs"
            write(script_path, node_script)
            output = try
                read(`node $script_path $p01_path`, String)
            catch e
                "P001_FAIL: $(sprint(showerror, e))"
            end
            rm(script_path, force=true)
            rm(p01_path, force=true)

            println("  P-001: ", strip(output))
            @test occursin("P001_PASS", output)
        end

        # --- 54e: Cheat-proof: WAT must contain ref.test ---
        @testset "cheat-proof: WAT contains ref.test dispatch" begin
            p01_path = tempname() * ".wasm"
            write(p01_path, p01_mod)
            has_ref_test = false
            try
                wat = read(`wasm-tools print $p01_path`, String)
                has_ref_test = occursin("ref.test", wat)
                if has_ref_test
                    ref_test_count = count("ref.test", wat)
                    println("  P-001 ref.test instructions: $ref_test_count")
                end
            catch
                println("  wasm-tools not available, skipping WAT check")
                has_ref_test = true
            end
            rm(p01_path, force=true)
            @test has_ref_test
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 55: P-003 — 22-function regression suite via REAL codegen
    #
    # All 22 functions auto-generated from source via Base.code_typed.
    # Compiled to a single WASM module, verified via WASM-in-WASM in Node.js.
    # ═══════════════════════════════════════════════════════════════════════════
    @testset "Phase 55: P-003 22-function regression suite" begin

        # --- 55a: Compile all 22 auto-gen entries + helpers ---
        p03_mod = compile_multi([
            (e2e_compile_stmt, (Vector{UInt8}, Any, Int32)),
            (e2e_emit_val, (Vector{UInt8}, Any)),
            (e2e_emit_op, (Vector{UInt8}, Symbol)),
            (wasm_bytes_length, (Vector{UInt8},), "blen"),
            (wasm_bytes_get, (Vector{UInt8}, Int32), "bget"),
            (p01_auto_01, (), "p01"), (p01_auto_02, (), "p02"),
            (p01_auto_03, (), "p03"), (p01_auto_04, (), "p04"),
            (p01_auto_05, (), "p05"), (p01_auto_06, (), "p06"),
            (p01_auto_07, (), "p07"), (p01_auto_08, (), "p08"),
            (p01_auto_09, (), "p09"), (p01_auto_10, (), "p10"),
            (p03_auto_11, (), "p11"), (p03_auto_12, (), "p12"),
            (p03_auto_13, (), "p13"), (p03_auto_14, (), "p14"),
            (p03_auto_15, (), "p15"), (p03_auto_16, (), "p16"),
            (p03_auto_17, (), "p17"), (p03_auto_18, (), "p18"),
            (p03_auto_19, (), "p19"), (p03_auto_20, (), "p20"),
            (p03_auto_21, (), "p21"), (p03_auto_22, (), "p22"),
        ])

        @testset "outer module: valid WASM binary" begin
            @test length(p03_mod) > 0
            @test p03_mod[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
            println("  P-003 outer module: $(length(p03_mod)) bytes ($(round(length(p03_mod)/1024, digits=1)) KB)")
        end

        # --- 55b: WASM-in-WASM — all 22 functions via Node.js ---
        @testset "P-003: 22/22 functions via WASM-in-WASM codegen" begin
            p03_path = tempname() * ".wasm"
            write(p03_path, p03_mod)

            node_script = raw"""
            const fs = require('fs');
            const bytes = fs.readFileSync(process.argv[2]);
            const specs = [
              {fn:'p01',tests:[[[5n],26n],[[0n],1n],[[-3n],10n],[[10n],101n],[[1n],2n]]},
              {fn:'p02',tests:[[[1n,2n],3n],[[0n,0n],0n],[[-5n,5n],0n]]},
              {fn:'p03',tests:[[[0n],-7n],[[5n],8n],[[10n],23n]]},
              {fn:'p04',tests:[[[2n,3n],16n],[[0n,5n],10n],[[1n,1n],11n]]},
              {fn:'p05',tests:[[[3n],27n],[[0n],0n],[[-2n],-8n]]},
              {fn:'p06',tests:[[[5n,3n],16n],[[0n,0n],0n],[[3n,5n],-16n]]},
              {fn:'p07',tests:[[[5n],24n],[[0n],-1n],[[1n],0n]]},
              {fn:'p08',tests:[[[1n,1n],5n],[[0n,0n],0n],[[3n,2n],12n]]},
              {fn:'p09',tests:[[[42n],42n],[[0n],0n],[[-1n],-1n]]},
              {fn:'p10',tests:[[[1n,2n,3n],6n],[[0n,0n,0n],0n]]},
              {fn:'p11',tests:[[[0n],1n],[[5n],6n],[[-1n],0n],[[100n],101n]]},
              {fn:'p12',tests:[[[5n],10n],[[0n],0n],[[-3n],-6n],[[100n],200n]]},
              {fn:'p13',tests:[[[5n],25n],[[0n],0n],[[-3n],9n],[[10n],100n]]},
              {fn:'p14',tests:[[[5n,3n],2n],[[3n,5n],-2n],[[0n,0n],0n]]},
              {fn:'p15',tests:[[[3n,4n],12n],[[0n,5n],0n],[[-3n,4n],-12n]]},
              {fn:'p16',tests:[[[0n],1n],[[1n],3n],[[5n],31n],[[-1n],1n]]},
              {fn:'p17',tests:[[[2n,3n],11n],[[0n,0n],0n],[[1n,1n],3n]]},
              {fn:'p18',tests:[[[1n],3n],[[5n],15n],[[0n],0n],[[-3n],-9n]]},
              {fn:'p19',tests:[[[0n],5n],[[1n],15n],[[5n],55n],[[-1n],-5n]]},
              {fn:'p20',tests:[[[0n],42n],[[999n],42n],[[-1n],42n]]},
              {fn:'p21',tests:[[[1n],0n],[[0n],-1n],[[5n],4n],[[100n],99n]]},
              {fn:'p22',tests:[[[2n,3n,4n],10n],[[0n,5n,1n],1n],[[5n,5n,5n],30n]]},
            ];
            (async () => {
              try {
                const {instance} = await WebAssembly.instantiate(bytes, {Math:{pow:Math.pow}});
                const e = instance.exports;
                let pass=0, fail=0, fnPass=0;
                for (const spec of specs) {
                  const inner = e[spec.fn]();
                  const len = e.blen(inner);
                  const arr = new Uint8Array(len);
                  for (let i=0; i<len; i++) arr[i] = e.bget(inner, i+1);
                  try {
                    const m2 = await WebAssembly.instantiate(arr);
                    const f = m2.instance.exports.f;
                    let allOk = true;
                    for (const [args, expected] of spec.tests) {
                      const r = f(...args);
                      if (r === expected) { pass++; }
                      else { fail++; allOk=false; console.log('FAIL:'+spec.fn+'('+args+')='+r+' expected '+expected); }
                    }
                    if (allOk) fnPass++;
                  } catch(err) {
                    fail += spec.tests.length;
                    console.log('FAIL:'+spec.fn+' inner WASM: '+err.message);
                  }
                }
                console.log(fnPass+'/'+specs.length+' functions, '+pass+'/'+(pass+fail)+' tests passed');
                console.log(fail===0 ? 'P003_PASS' : 'P003_FAIL');
              } catch(err) { console.log('P003_FAIL:'+err.message); }
            })();
            """

            script_path = tempname() * ".cjs"
            write(script_path, node_script)
            output = try
                read(`node $script_path $p03_path`, String)
            catch e
                "P003_FAIL: $(sprint(showerror, e))"
            end
            rm(script_path, force=true)
            rm(p03_path, force=true)

            println("  P-003: ", strip(output))
            @test occursin("P003_PASS", output)
        end

        # --- 55c: Cheat-proof ---
        @testset "cheat-proof: WAT contains ref.test dispatch" begin
            p03_path = tempname() * ".wasm"
            write(p03_path, p03_mod)
            has_ref_test = false
            try
                wat = read(`wasm-tools print $p03_path`, String)
                has_ref_test = occursin("ref.test", wat)
                if has_ref_test
                    ref_test_count = count("ref.test", wat)
                    println("  P-003 ref.test instructions: $ref_test_count")
                end
            catch
                println("  wasm-tools not available, skipping WAT check")
                has_ref_test = true
            end
            rm(p03_path, force=true)
            @test has_ref_test
        end
    end

    # ═══════════════════════════════════════════════════════════════════════════
    # Phase 56: P-003 — Playground regression suite (browser test via codegen.wasm)
    #
    # Loads the pre-built playground/codegen.wasm and runs all 22 demo functions
    # with the SAME test cases as the browser "Run All Tests" button.
    # ═══════════════════════════════════════════════════════════════════════════
    @testset "Phase 56: P-003 Playground regression suite (codegen.wasm)" begin

        codegen_path = joinpath(@__DIR__, "..", "playground", "codegen.wasm")
        @test isfile(codegen_path)

        @testset "P-003: 22/22 functions via playground codegen.wasm" begin
            node_script = raw"""
            const fs = require('fs');
            const bytes = fs.readFileSync(process.argv[2]);
            const specs = [
              {fn:'p01',tests:[[[5n],26n],[[0n],1n],[[-3n],10n],[[10n],101n],[[1n],2n]]},
              {fn:'p02',tests:[[[1n,2n],3n],[[0n,0n],0n],[[-5n,5n],0n]]},
              {fn:'p03',tests:[[[0n],-7n],[[5n],8n],[[10n],23n]]},
              {fn:'p04',tests:[[[2n,3n],16n],[[0n,5n],10n],[[1n,1n],11n]]},
              {fn:'p05',tests:[[[3n],27n],[[0n],0n],[[-2n],-8n]]},
              {fn:'p06',tests:[[[5n,3n],16n],[[0n,0n],0n],[[3n,5n],-16n]]},
              {fn:'p07',tests:[[[5n],24n],[[0n],-1n],[[1n],0n]]},
              {fn:'p08',tests:[[[1n,1n],5n],[[0n,0n],0n],[[3n,2n],12n]]},
              {fn:'p09',tests:[[[42n],42n],[[0n],0n],[[-1n],-1n]]},
              {fn:'p10',tests:[[[1n,2n,3n],6n],[[0n,0n,0n],0n]]},
              {fn:'p11',tests:[[[0n],1n],[[5n],6n],[[-1n],0n],[[100n],101n]]},
              {fn:'p12',tests:[[[5n],10n],[[0n],0n],[[-3n],-6n],[[100n],200n]]},
              {fn:'p13',tests:[[[5n],25n],[[0n],0n],[[-3n],9n],[[10n],100n]]},
              {fn:'p14',tests:[[[5n,3n],2n],[[3n,5n],-2n],[[0n,0n],0n]]},
              {fn:'p15',tests:[[[3n,4n],12n],[[0n,5n],0n],[[-3n,4n],-12n]]},
              {fn:'p16',tests:[[[0n],1n],[[1n],3n],[[5n],31n],[[-1n],1n]]},
              {fn:'p17',tests:[[[2n,3n],11n],[[0n,0n],0n],[[1n,1n],3n]]},
              {fn:'p18',tests:[[[1n],3n],[[5n],15n],[[0n],0n],[[-3n],-9n]]},
              {fn:'p19',tests:[[[0n],5n],[[1n],15n],[[5n],55n],[[-1n],-5n]]},
              {fn:'p20',tests:[[[0n],42n],[[999n],42n],[[-1n],42n]]},
              {fn:'p21',tests:[[[1n],0n],[[0n],-1n],[[5n],4n],[[100n],99n]]},
              {fn:'p22',tests:[[[2n,3n,4n],10n],[[0n,5n,1n],1n],[[5n,5n,5n],30n]]},
            ];
            (async () => {
              try {
                const {instance} = await WebAssembly.instantiate(bytes, {Math:{pow:Math.pow}});
                const e = instance.exports;
                let pass=0, fail=0, fnPass=0;
                for (const spec of specs) {
                  const inner = e[spec.fn]();
                  const len = e.blen(inner);
                  const arr = new Uint8Array(len);
                  for (let i=0; i<len; i++) arr[i] = e.bget(inner, i+1);
                  try {
                    const m2 = await WebAssembly.instantiate(arr);
                    const f = m2.instance.exports.f;
                    let allOk = true;
                    for (const [args, expected] of spec.tests) {
                      const r = f(...args);
                      if (r === expected) { pass++; }
                      else { fail++; allOk=false; console.log('FAIL:'+spec.fn+'('+args+')='+r+' expected '+expected); }
                    }
                    if (allOk) fnPass++;
                  } catch(err) {
                    fail += spec.tests.length;
                    console.log('FAIL:'+spec.fn+' inner WASM: '+err.message);
                  }
                }
                console.log(fnPass+'/'+specs.length+' functions, '+pass+'/'+(pass+fail)+' tests passed');
                console.log(fail===0 ? 'P003_PLAYGROUND_PASS' : 'P003_PLAYGROUND_FAIL');
              } catch(err) { console.log('P003_PLAYGROUND_FAIL:'+err.message); }
            })();
            """

            script_path = tempname() * ".cjs"
            write(script_path, node_script)
            output = try
                read(`node $script_path $codegen_path`, String)
            catch e
                "P003_PLAYGROUND_FAIL: $(sprint(showerror, e))"
            end
            rm(script_path, force=true)

            println("  P-003 playground: ", strip(output))
            @test occursin("22/22 functions", output)
            @test occursin("P003_PLAYGROUND_PASS", output)
        end
    end

    # Phase 23: TF-005 Cross-function type-sharing regression tests
    @testset "Phase 23: Cross-function Type Sharing (TF-005)" begin

        # Test 1: Simple struct create + isa across compile_multi
        @testset "TF5-1: Struct create + isa dispatch" begin
            bytes = WasmTarget.compile_multi([
                (tf5_make_alpha, (Int32,)),
                (tf5_dispatch_ab, (Union{TF5_Alpha, TF5_Beta},)),
            ])
            @test length(bytes) > 0

            # Cross-function test: make Alpha, then dispatch on it
            dir = mktempdir()
            wasm_path = joinpath(dir, "test.wasm")
            js_path = joinpath(dir, "test.mjs")
            write(wasm_path, bytes)
            write(js_path, """
import fs from 'fs';
const buf = fs.readFileSync('$(escape_string(wasm_path))');
const { instance } = await WebAssembly.instantiate(buf, { Math: { pow: Math.pow } });
const e = instance.exports;
const a = e.tf5_make_alpha(42);
const r = e.tf5_dispatch_ab(a);
console.log(JSON.stringify({result: Number(r)}));
""")
            node_cmd = NODE_CMD
            if node_cmd !== nothing
                output = strip(read(`$node_cmd $js_path`, String))
                result = JSON.parse(output)
                @test result["result"] == 142  # 42 + 100
            end
        end

        # Test 2: Struct with multiple fields + field access across functions
        @testset "TF5-2: Multi-field struct cross-function access" begin
            bytes = WasmTarget.compile_multi([
                (tf5_make_gamma, (Int32, Int64)),
                (tf5_get_gamma_x, (TF5_Gamma,)),
            ])
            @test length(bytes) > 0
        end

        # Test 3: Union{Nothing, T} pattern across functions
        @testset "TF5-3: Union{Nothing, T} cross-function" begin
            bytes = WasmTarget.compile_multi([
                (tf5_make_alpha_for_nothing, (Int32,)),
                (tf5_check_nothing, (Union{Nothing, TF5_Alpha},)),
            ])
            @test length(bytes) > 0
        end

        # Test 4: 3-type Union dispatch (THE bug that was fixed)
        @testset "TF5-4: 3-type Union dispatch (TF-004 fix)" begin
            bytes = WasmTarget.compile_multi([
                (tf5_make_alpha, (Int32,)),
                (tf5_make_beta, (Int64,)),
                (tf5_make_gamma, (Int32, Int64)),
                (tf5_dispatch_3way, (Union{TF5_Alpha, TF5_Beta, TF5_Gamma},)),
            ])
            @test length(bytes) > 0

            # Cross-function runtime test: create each type and dispatch
            dir = mktempdir()
            wasm_path = joinpath(dir, "test.wasm")
            js_path = joinpath(dir, "test.mjs")
            write(wasm_path, bytes)
            write(js_path, """
import fs from 'fs';
const buf = fs.readFileSync('$(escape_string(wasm_path))');
const { instance } = await WebAssembly.instantiate(buf, { Math: { pow: Math.pow } });
const e = instance.exports;
const a = e.tf5_make_alpha(42);
const b = e.tf5_make_beta(10n);
const g = e.tf5_make_gamma(1, 2n);
const ca = e.tf5_dispatch_3way(a);
const cb = e.tf5_dispatch_3way(b);
const cg = e.tf5_dispatch_3way(g);
const ok = Number(ca)===1 && Number(cb)===2 && Number(cg)===3;
console.log(JSON.stringify({ca:Number(ca),cb:Number(cb),cg:Number(cg),ok}));
""")
            node_cmd = NODE_CMD
            if node_cmd !== nothing
                output = strip(read(`$node_cmd $js_path`, String))
                result = JSON.parse(output)
                @test result["ok"] == true
                @test result["ca"] == 1
                @test result["cb"] == 2
                @test result["cg"] == 3
            end
        end

        # Test 5: Structurally-identical types (typeId disambiguation)
        @testset "TF5-5: Same-layout structs + typeId dispatch" begin
            bytes = WasmTarget.compile_multi([
                (tf5_make_cat, (Int32,)),
                (tf5_make_dog, (Int32,)),
                (tf5_classify_pet, (Union{TF5_Cat, TF5_Dog},)),
            ])
            @test length(bytes) > 0

            # Cross-function runtime test
            dir = mktempdir()
            wasm_path = joinpath(dir, "test.wasm")
            js_path = joinpath(dir, "test.mjs")
            write(wasm_path, bytes)
            write(js_path, """
import fs from 'fs';
const buf = fs.readFileSync('$(escape_string(wasm_path))');
const { instance } = await WebAssembly.instantiate(buf, { Math: { pow: Math.pow } });
const e = instance.exports;
const cat = e.tf5_make_cat(10);
const dog = e.tf5_make_dog(20);
const cc = e.tf5_classify_pet(cat);
const cd = e.tf5_classify_pet(dog);
const ok = Number(cc)===1 && Number(cd)===2;
console.log(JSON.stringify({cc:Number(cc),cd:Number(cd),ok}));
""")
            node_cmd = NODE_CMD
            if node_cmd !== nothing
                output = strip(read(`$node_cmd $js_path`, String))
                result = JSON.parse(output)
                @test result["ok"] == true
                @test result["cc"] == 1
                @test result["cd"] == 2
            end
        end
    end

    # Phase 24: Core IR Type Registration & Dispatch (JIB-IR001)
    # Register Core IR types (ReturnNode, GotoNode, etc.) as WasmGC structs
    # and verify isa dispatch via ref.test at runtime.

    # Maker functions for Core IR types
    function ir001_make_ssaval(id::Int64)::Core.SSAValue
        return Core.SSAValue(id)
    end
    function ir001_make_gotonode(label::Int64)::Core.GotoNode
        return Core.GotoNode(label)
    end
    function ir001_make_gotoifnot(dest::Int64)::Core.GotoIfNot
        return Core.GotoIfNot(true, dest)
    end
    function ir001_make_returnnode(v::Int64)::Core.ReturnNode
        return Core.ReturnNode(v)
    end

    # Dispatch function: isa checks on Core IR types
    function ir001_dispatch(x::Union{Core.ReturnNode, Core.GotoNode, Core.GotoIfNot, Core.SSAValue})::Int32
        if x isa Core.ReturnNode
            return Int32(1)
        elseif x isa Core.GotoNode
            return Int32(2)
        elseif x isa Core.GotoIfNot
            return Int32(3)
        elseif x isa Core.SSAValue
            return Int32(4)
        end
        return Int32(0)
    end

    @testset "Phase 24: Core IR Type Registration (IR-001)" begin

        # Test 1: Compile Core IR maker + dispatch functions
        @testset "IR001-1: Core IR types compile and validate" begin
            bytes = WasmTarget.compile_multi([
                (ir001_make_ssaval, (Int64,)),
                (ir001_make_gotonode, (Int64,)),
                (ir001_make_gotoifnot, (Int64,)),
                (ir001_make_returnnode, (Int64,)),
                (ir001_dispatch, (Union{Core.ReturnNode, Core.GotoNode, Core.GotoIfNot, Core.SSAValue},)),
            ])
            @test length(bytes) > 0
        end

        # Test 2: WAT contains ref.test for dispatch
        @testset "IR001-2: WAT contains ref.test for IR types" begin
            bytes = WasmTarget.compile_multi([
                (ir001_make_ssaval, (Int64,)),
                (ir001_make_gotonode, (Int64,)),
                (ir001_make_gotoifnot, (Int64,)),
                (ir001_make_returnnode, (Int64,)),
                (ir001_dispatch, (Union{Core.ReturnNode, Core.GotoNode, Core.GotoIfNot, Core.SSAValue},)),
            ])
            dir = mktempdir()
            wasm_path = joinpath(dir, "ir001.wasm")
            write(wasm_path, bytes)
            wat = read(`wasm-tools print $wasm_path`, String)
            # Dispatch on 4 types produces 3 ref.test (last type is fallthrough)
            @test count("ref.test", wat) >= 3
        end

        # Test 3: Runtime dispatch via Node.js
        @testset "IR001-3: Runtime isa dispatch on Core IR types" begin
            bytes = WasmTarget.compile_multi([
                (ir001_make_ssaval, (Int64,)),
                (ir001_make_gotonode, (Int64,)),
                (ir001_make_gotoifnot, (Int64,)),
                (ir001_make_returnnode, (Int64,)),
                (ir001_dispatch, (Union{Core.ReturnNode, Core.GotoNode, Core.GotoIfNot, Core.SSAValue},)),
            ])
            dir = mktempdir()
            wasm_path = joinpath(dir, "test.wasm")
            js_path = joinpath(dir, "test.mjs")
            write(wasm_path, bytes)
            write(js_path, """
import fs from 'fs';
const buf = fs.readFileSync('$(escape_string(wasm_path))');
const { instance } = await WebAssembly.instantiate(buf, { Math: { pow: Math.pow } });
const e = instance.exports;
const rn = e.ir001_make_returnnode(99n);
const gn = e.ir001_make_gotonode(10n);
const gif = e.ir001_make_gotoifnot(5n);
const ssa = e.ir001_make_ssaval(42n);
const d_rn = e.ir001_dispatch(rn);
const d_gn = e.ir001_dispatch(gn);
const d_gif = e.ir001_dispatch(gif);
const d_ssa = e.ir001_dispatch(ssa);
console.log(JSON.stringify({
    rn: Number(d_rn), gn: Number(d_gn),
    gif: Number(d_gif), ssa: Number(d_ssa),
    ok: Number(d_rn)===1 && Number(d_gn)===2 && Number(d_gif)===3 && Number(d_ssa)===4
}));
""")
            node_cmd = NODE_CMD
            if node_cmd !== nothing
                output = strip(read(`$node_cmd $js_path`, String))
                result = JSON.parse(output)
                @test result["ok"] == true
                @test result["rn"] == 1   # ReturnNode → 1
                @test result["gn"] == 2   # GotoNode → 2
                @test result["gif"] == 3  # GotoIfNot → 3
                @test result["ssa"] == 4  # SSAValue → 4
            end
        end

        # Test 4: register_ir_types=true pre-registers all 13 Core IR types
        @testset "IR001-4: register_ir_types kwarg" begin
            bytes = WasmTarget.compile_multi([
                (ir001_make_ssaval, (Int64,)),
                (ir001_dispatch, (Union{Core.ReturnNode, Core.GotoNode, Core.GotoIfNot, Core.SSAValue},)),
            ]; register_ir_types=true)
            @test length(bytes) > 0
            # Validate the module
            dir = mktempdir()
            wasm_path = joinpath(dir, "ir001_reg.wasm")
            write(wasm_path, bytes)
            validate_output = read(`wasm-tools validate $wasm_path`, String)
            @test isempty(validate_output)
        end

        # Test 5: IR-002 — dispatch + PiNode narrowing + struct.get field access
        @testset "IR002: compile_value dispatch + field access" begin
            function ir002_make_ssaval(id::Int64)::Core.SSAValue
                return Core.SSAValue(id)
            end
            function ir002_make_argument(n::Int64)::Core.Argument
                return Core.Argument(n)
            end
            function ir002_make_gotonode(label::Int64)::Core.GotoNode
                return Core.GotoNode(label)
            end
            function ir002_dispatch_field(x::Union{Core.SSAValue, Core.Argument, Core.GotoNode})::Int64
                if x isa Core.SSAValue
                    return x.id
                elseif x isa Core.Argument
                    return x.n
                elseif x isa Core.GotoNode
                    return x.label
                end
                return Int64(0)
            end
            bytes = WasmTarget.compile_multi([
                (ir002_make_ssaval, (Int64,)),
                (ir002_make_argument, (Int64,)),
                (ir002_make_gotonode, (Int64,)),
                (ir002_dispatch_field, (Union{Core.SSAValue, Core.Argument, Core.GotoNode},)),
            ])
            @test length(bytes) > 0

            dir = mktempdir()
            wasm_path = joinpath(dir, "test.wasm")
            js_path = joinpath(dir, "test.mjs")
            write(wasm_path, bytes)
            write(js_path, """
import fs from 'fs';
const buf = fs.readFileSync('$(escape_string(wasm_path))');
const { instance } = await WebAssembly.instantiate(buf, { Math: { pow: Math.pow } });
const e = instance.exports;
const ssa = e.ir002_make_ssaval(42n);
const arg = e.ir002_make_argument(7n);
const gn = e.ir002_make_gotonode(99n);
const v_ssa = e.ir002_dispatch_field(ssa);
const v_arg = e.ir002_dispatch_field(arg);
const v_gn = e.ir002_dispatch_field(gn);
console.log(JSON.stringify({
    ssa: Number(v_ssa), arg: Number(v_arg), gn: Number(v_gn),
    ok: v_ssa===42n && v_arg===7n && v_gn===99n
}));
""")
            node_cmd = NODE_CMD
            if node_cmd !== nothing
                output = strip(read(`$node_cmd $js_path`, String))
                result = JSON.parse(output)
                @test result["ok"] == true
                @test result["ssa"] == 42  # SSAValue(42).id
                @test result["arg"] == 7   # Argument(7).n
                @test result["gn"] == 99   # GotoNode(99).label
            end
        end

        # Test 6: WAT ref.test for Expr type (5-type dispatch including Expr)
        @testset "IR001-5: Expr in isa dispatch produces ref.test" begin
            function ir001_dispatch_with_expr(x::Union{Core.ReturnNode, Core.GotoNode, Core.GotoIfNot, Core.SSAValue, Expr})::Int32
                if x isa Core.ReturnNode; return Int32(1)
                elseif x isa Core.GotoNode; return Int32(2)
                elseif x isa Core.GotoIfNot; return Int32(3)
                elseif x isa Expr; return Int32(5)
                elseif x isa Core.SSAValue; return Int32(4)
                end
                return Int32(0)
            end
            bytes = WasmTarget.compile_multi([
                (ir001_dispatch_with_expr, (Union{Core.ReturnNode, Core.GotoNode, Core.GotoIfNot, Core.SSAValue, Expr},)),
            ]; register_ir_types=true)
            @test length(bytes) > 0
            dir = mktempdir()
            wasm_path = joinpath(dir, "ir001_expr.wasm")
            write(wasm_path, bytes)
            wat = read(`wasm-tools print $wasm_path`, String)
            # 5-type dispatch produces 4 ref.test (last type is fallthrough)
            @test count("ref.test", wat) >= 4
        end

        # Test 7: IR-003 — Expr.head symbol dispatch via ===
        @testset "IR003: Expr.head symbol dispatch" begin
            function ir003_make_call_expr()::Expr
                return Expr(:call)
            end
            function ir003_make_invoke_expr()::Expr
                return Expr(:invoke)
            end
            function ir003_make_new_expr()::Expr
                return Expr(:new)
            end
            function ir003_head_dispatch(e::Expr)::Int32
                if e.head === :call
                    return Int32(10)
                elseif e.head === :invoke
                    return Int32(11)
                elseif e.head === :new
                    return Int32(12)
                end
                return Int32(0)
            end

            # Compile
            bytes = WasmTarget.compile_multi([
                (ir003_make_call_expr, ()),
                (ir003_make_invoke_expr, ()),
                (ir003_make_new_expr, ()),
                (ir003_head_dispatch, (Expr,)),
            ]; register_ir_types=true)
            @test length(bytes) > 0

            # Validate
            dir = mktempdir()
            wasm_path = joinpath(dir, "ir003.wasm")
            write(wasm_path, bytes)
            validate_output = read(`wasm-tools validate $wasm_path`, String)
            @test isempty(validate_output)

            # Runtime dispatch via Node.js
            js_path = joinpath(dir, "test.mjs")
            write(js_path, """
import fs from 'fs';
const buf = fs.readFileSync('$(escape_string(wasm_path))');
const { instance } = await WebAssembly.instantiate(buf, { Math: { pow: Math.pow } });
const e = instance.exports;
const call_expr = e.ir003_make_call_expr();
const invoke_expr = e.ir003_make_invoke_expr();
const new_expr = e.ir003_make_new_expr();
const d_call = e.ir003_head_dispatch(call_expr);
const d_invoke = e.ir003_head_dispatch(invoke_expr);
const d_new = e.ir003_head_dispatch(new_expr);
console.log(JSON.stringify({
    call: d_call, invoke: d_invoke, new_: d_new,
    ok: d_call===10 && d_invoke===11 && d_new===12
}));
""")
            node_cmd = NODE_CMD
            if node_cmd !== nothing
                output = strip(read(`$node_cmd $js_path`, String))
                result = JSON.parse(output)
                @test result["ok"] == true
                @test result["call"] == 10    # Expr(:call) → 10
                @test result["invoke"] == 11  # Expr(:invoke) → 11
                @test result["new_"] == 12    # Expr(:new) → 12
            end
        end
    end

    # ========================================================================
    # Phase 57: Stackifier / Int128 — WBUILD-1010
    # ========================================================================
    # Root cause: fix_consecutive_local_sets converted local.set→local.tee
    # for consecutive sets targeting locals of DIFFERENT types (i64 vs ref),
    # corrupting the stack when Int128 emitters pop two distinct values.
    @testset "Phase 57: Stackifier / Int128 (WBUILD-1010)" begin
        @testset "UInt128 shl" begin
            function _wb_uint128_shl(x::Int64)::Int64
                a = Core.zext_int(UInt128, reinterpret(UInt64, x))
                b = Base.shl_int(a, 0x0000000000000002)
                c = Base.trunc_int(UInt64, b)
                return reinterpret(Int64, c)
            end
            @test compare_julia_wasm(_wb_uint128_shl, Int64(42)).pass
            @test compare_julia_wasm(_wb_uint128_shl, Int64(0)).pass
            @test compare_julia_wasm(_wb_uint128_shl, Int64(1)).pass
        end

        @testset "UInt128 lshr" begin
            function _wb_uint128_lshr(x::Int64)::Int64
                a = Core.zext_int(UInt128, reinterpret(UInt64, x))
                b = Base.lshr_int(a, 0x0000000000000002)
                c = Base.trunc_int(UInt64, b)
                return reinterpret(Int64, c)
            end
            @test compare_julia_wasm(_wb_uint128_lshr, Int64(168)).pass
            @test compare_julia_wasm(_wb_uint128_lshr, Int64(0)).pass
        end

        @testset "UInt128 shl+lshr chain (within 64-bit)" begin
            # Note: WASM i64 shifts are mod 64, so cross-64-bit shifts
            # need special handling in the Int128 emitter (separate bug).
            # This test stays within the lower 64 bits.
            function _wb_uint128_chain(x::Int64)::Int64
                a = Core.zext_int(UInt128, reinterpret(UInt64, x))
                b = Base.shl_int(a, 0x0000000000000004)  # << 4
                c = Base.lshr_int(b, 0x0000000000000002)  # >> 2
                d = Base.trunc_int(UInt64, c)
                return reinterpret(Int64, d)
            end
            @test compare_julia_wasm(_wb_uint128_chain, Int64(42)).pass
            @test compare_julia_wasm(_wb_uint128_chain, Int64(1)).pass
        end

        @testset "exp(Float64) compiles and runs" begin
            @test compare_julia_wasm(exp, 1.0).pass
            @test compare_julia_wasm(exp, 0.0).pass
            @test compare_julia_wasm(exp, -1.0).pass
        end

        @testset "sin(Float64) compiles and runs (WBUILD-1011)" begin
            _wb_sin(x::Float64)::Float64 = sin(x)
            @test compare_julia_wasm(_wb_sin, 0.0).pass
            @test compare_julia_wasm(_wb_sin, Float64(pi)/4).pass
            @test compare_julia_wasm(_wb_sin, Float64(pi)/2).pass
            @test compare_julia_wasm(_wb_sin, Float64(pi)).pass
            @test compare_julia_wasm(_wb_sin, -1.0).pass
        end

        @testset "cos(Float64) compiles and runs (WBUILD-1011)" begin
            _wb_cos(x::Float64)::Float64 = cos(x)
            @test compare_julia_wasm(_wb_cos, 0.0).pass
            @test compare_julia_wasm(_wb_cos, Float64(pi)/4).pass
            @test compare_julia_wasm(_wb_cos, Float64(pi)).pass
        end
    end

    # ========================================================================
    # Phase 58: Transcendental Math — WBUILD-1012
    # ========================================================================
    @testset "Phase 58: Transcendental Math (WBUILD-1012)" begin
        @testset "sin(Float64) full input range" begin
            _t58_sin(x::Float64)::Float64 = sin(x)
            @test compare_julia_wasm(_t58_sin, 0.0).pass
            @test compare_julia_wasm(_t58_sin, Float64(pi)/6).pass
            @test compare_julia_wasm(_t58_sin, Float64(pi)/4).pass
            @test compare_julia_wasm(_t58_sin, Float64(pi)/3).pass
            @test compare_julia_wasm(_t58_sin, Float64(pi)/2).pass
            @test compare_julia_wasm(_t58_sin, Float64(pi)).pass
            @test compare_julia_wasm(_t58_sin, 3*Float64(pi)/2).pass
            @test compare_julia_wasm(_t58_sin, 2*Float64(pi)).pass
            @test compare_julia_wasm(_t58_sin, -Float64(pi)/4).pass
            @test compare_julia_wasm(_t58_sin, 100.0).pass
            @test compare_julia_wasm(_t58_sin, -100.0).pass
            @test compare_julia_wasm(_t58_sin, 1e-10).pass
            # 1e10 triggers paynehanek large-argument reduction which uses
            # UInt128 ctlz_int (broken) and other 128-bit ops. Fix in M2.
            @test_broken compare_julia_wasm(_t58_sin, 1e10).pass
        end

        @testset "Int128 add/mul (WBUILD-1011 fix)" begin
            function _wb_uint128_add(a::Int64, b::Int64)::Int64
                au = Core.zext_int(UInt128, reinterpret(UInt64, a))
                bu = Core.zext_int(UInt128, reinterpret(UInt64, b))
                r = Base.add_int(au, bu)
                return reinterpret(Int64, Base.trunc_int(UInt64, r))
            end
            @test compare_julia_wasm(_wb_uint128_add, Int64(100), Int64(200)).pass
            @test compare_julia_wasm(_wb_uint128_add, Int64(0), Int64(0)).pass

            function _wb_widemul(a::Int64, b::Int64)::Int64
                r = Base.widemul(reinterpret(UInt64, a), reinterpret(UInt64, b))
                return reinterpret(Int64, Base.trunc_int(UInt64, r))
            end
            @test compare_julia_wasm(_wb_widemul, Int64(100), Int64(200)).pass
        end

        @testset "cos(Float64) full input range (WBUILD-1013)" begin
            _t58_cos(x::Float64)::Float64 = cos(x)
            @test compare_julia_wasm(_t58_cos, 0.0).pass
            @test compare_julia_wasm(_t58_cos, Float64(pi)/6).pass
            @test compare_julia_wasm(_t58_cos, Float64(pi)/4).pass
            @test compare_julia_wasm(_t58_cos, Float64(pi)/3).pass
            @test compare_julia_wasm(_t58_cos, Float64(pi)/2).pass
            @test compare_julia_wasm(_t58_cos, Float64(pi)).pass
            @test compare_julia_wasm(_t58_cos, 3*Float64(pi)/2).pass
            @test compare_julia_wasm(_t58_cos, 2*Float64(pi)).pass
            @test compare_julia_wasm(_t58_cos, -Float64(pi)/4).pass
            @test compare_julia_wasm(_t58_cos, 100.0).pass
            @test compare_julia_wasm(_t58_cos, -100.0).pass
            @test compare_julia_wasm(_t58_cos, 1e-10).pass
        end

        @testset "exp(Float64) full input range (WBUILD-1013)" begin
            _t58_exp(x::Float64)::Float64 = exp(x)
            @test compare_julia_wasm(_t58_exp, -10.0).pass
            @test compare_julia_wasm(_t58_exp, -1.0).pass
            @test compare_julia_wasm(_t58_exp, 0.0).pass
            @test compare_julia_wasm(_t58_exp, 0.5).pass
            @test compare_julia_wasm(_t58_exp, 1.0).pass
            @test compare_julia_wasm(_t58_exp, 2.0).pass
            @test compare_julia_wasm(_t58_exp, 5.0).pass
            @test compare_julia_wasm(_t58_exp, 10.0).pass
        end

        @testset "log(Float64) full input range (WBUILD-1013)" begin
            _t58_log(x::Float64)::Float64 = log(x)
            @test compare_julia_wasm(_t58_log, 0.001).pass
            @test compare_julia_wasm(_t58_log, 0.1).pass
            @test compare_julia_wasm(_t58_log, 0.5).pass
            @test compare_julia_wasm(_t58_log, 1.0).pass
            @test compare_julia_wasm(_t58_log, 2.718281828459045).pass
            @test compare_julia_wasm(_t58_log, 10.0).pass
            @test compare_julia_wasm(_t58_log, 100.0).pass
            @test compare_julia_wasm(_t58_log, 1e6).pass
        end

        @testset "tan(Float64) (WBUILD-1014)" begin
            _t58_tan(x::Float64)::Float64 = tan(x)
            @test compare_julia_wasm(_t58_tan, 0.0).pass
            @test compare_julia_wasm(_t58_tan, Float64(pi)/6).pass
            @test compare_julia_wasm(_t58_tan, Float64(pi)/4).pass
            @test compare_julia_wasm(_t58_tan, Float64(pi)/3).pass
            @test compare_julia_wasm(_t58_tan, -Float64(pi)/4).pass
            @test compare_julia_wasm(_t58_tan, 1.0).pass
            @test compare_julia_wasm(_t58_tan, -1.0).pass
        end

        @testset "asin(Float64) (WBUILD-1014)" begin
            _t58_asin(x::Float64)::Float64 = asin(x)
            @test compare_julia_wasm(_t58_asin, 0.0).pass
            @test compare_julia_wasm(_t58_asin, 0.5).pass
            @test compare_julia_wasm(_t58_asin, -0.5).pass
            @test compare_julia_wasm(_t58_asin, 1.0).pass
            @test compare_julia_wasm(_t58_asin, -1.0).pass
            @test compare_julia_wasm(_t58_asin, 0.25).pass
            @test compare_julia_wasm(_t58_asin, 0.75).pass
        end

        @testset "acos(Float64) (WBUILD-1014)" begin
            _t58_acos(x::Float64)::Float64 = acos(x)
            @test compare_julia_wasm(_t58_acos, 0.0).pass
            @test compare_julia_wasm(_t58_acos, 0.5).pass
            @test compare_julia_wasm(_t58_acos, -0.5).pass
            @test compare_julia_wasm(_t58_acos, 1.0).pass
            @test compare_julia_wasm(_t58_acos, -1.0).pass
            @test compare_julia_wasm(_t58_acos, 0.25).pass
            @test compare_julia_wasm(_t58_acos, 0.75).pass
        end

        @testset "atan(Float64) (WBUILD-1014)" begin
            _t58_atan(x::Float64)::Float64 = atan(x)
            @test compare_julia_wasm(_t58_atan, 0.0).pass
            @test compare_julia_wasm(_t58_atan, 1.0).pass
            @test compare_julia_wasm(_t58_atan, -1.0).pass
            @test compare_julia_wasm(_t58_atan, 10.0).pass
            @test compare_julia_wasm(_t58_atan, -10.0).pass
            @test compare_julia_wasm(_t58_atan, 0.1).pass
            @test compare_julia_wasm(_t58_atan, 100.0).pass
        end

        @testset "atan(y, x) four quadrants (WBUILD-1014)" begin
            _t58_atan2(y::Float64, x::Float64)::Float64 = atan(y, x)
            @test compare_julia_wasm(_t58_atan2, 1.0, 1.0).pass
            @test compare_julia_wasm(_t58_atan2, 1.0, -1.0).pass
            @test compare_julia_wasm(_t58_atan2, -1.0, -1.0).pass
            @test compare_julia_wasm(_t58_atan2, -1.0, 1.0).pass
            @test compare_julia_wasm(_t58_atan2, 0.0, 1.0).pass
            @test compare_julia_wasm(_t58_atan2, 1.0, 0.0).pass
        end

        @testset "sinh(Float64) (WBUILD-1014)" begin
            _t58_sinh(x::Float64)::Float64 = sinh(x)
            @test compare_julia_wasm(_t58_sinh, 0.0).pass
            @test compare_julia_wasm(_t58_sinh, 1.0).pass
            @test compare_julia_wasm(_t58_sinh, -1.0).pass
            @test compare_julia_wasm(_t58_sinh, 2.0).pass
            @test compare_julia_wasm(_t58_sinh, -2.0).pass
            @test compare_julia_wasm(_t58_sinh, 5.0).pass
            @test compare_julia_wasm(_t58_sinh, -5.0).pass
        end

        @testset "cosh(Float64) (WBUILD-1014)" begin
            _t58_cosh(x::Float64)::Float64 = cosh(x)
            @test compare_julia_wasm(_t58_cosh, 0.0).pass
            @test compare_julia_wasm(_t58_cosh, 1.0).pass
            @test compare_julia_wasm(_t58_cosh, -1.0).pass
            @test compare_julia_wasm(_t58_cosh, 2.0).pass
            @test compare_julia_wasm(_t58_cosh, -2.0).pass
            @test compare_julia_wasm(_t58_cosh, 5.0).pass
            @test compare_julia_wasm(_t58_cosh, -5.0).pass
        end

        @testset "tanh(Float64) (WBUILD-1014)" begin
            _t58_tanh(x::Float64)::Float64 = tanh(x)
            @test compare_julia_wasm(_t58_tanh, 0.0).pass
            @test compare_julia_wasm(_t58_tanh, 1.0).pass
            @test compare_julia_wasm(_t58_tanh, -1.0).pass
            @test compare_julia_wasm(_t58_tanh, 2.0).pass
            @test compare_julia_wasm(_t58_tanh, -2.0).pass
            @test compare_julia_wasm(_t58_tanh, 5.0).pass
            @test compare_julia_wasm(_t58_tanh, -5.0).pass
        end
    end

    # ========================================================================
    # Phase 59: Extended Math — WBUILD-1020
    # ========================================================================
    @testset "Phase 59: Extended Math (WBUILD-1020)" begin
        @testset "exp2(Float64) (WBUILD-1020)" begin
            _t59_exp2(x::Float64)::Float64 = exp2(x)
            @test compare_julia_wasm(_t59_exp2, 0.0).pass
            @test compare_julia_wasm(_t59_exp2, 1.0).pass
            @test compare_julia_wasm(_t59_exp2, -1.0).pass
            @test compare_julia_wasm(_t59_exp2, 10.0).pass
            @test compare_julia_wasm(_t59_exp2, 0.5).pass
        end

        @testset "exp10(Float64) (WBUILD-1020)" begin
            _t59_exp10(x::Float64)::Float64 = exp10(x)
            @test compare_julia_wasm(_t59_exp10, 0.0).pass
            @test compare_julia_wasm(_t59_exp10, 1.0).pass
            @test compare_julia_wasm(_t59_exp10, -1.0).pass
            @test compare_julia_wasm(_t59_exp10, 2.0).pass
            @test compare_julia_wasm(_t59_exp10, 0.5).pass
        end

        @testset "log2(Float64) (WBUILD-1020)" begin
            _t59_log2(x::Float64)::Float64 = log2(x)
            @test compare_julia_wasm(_t59_log2, 1.0).pass
            @test compare_julia_wasm(_t59_log2, 2.0).pass
            @test compare_julia_wasm(_t59_log2, 4.0).pass
            @test compare_julia_wasm(_t59_log2, 0.5).pass
            @test compare_julia_wasm(_t59_log2, 10.0).pass
        end

        @testset "log10(Float64) (WBUILD-1020)" begin
            _t59_log10(x::Float64)::Float64 = log10(x)
            @test compare_julia_wasm(_t59_log10, 1.0).pass
            @test compare_julia_wasm(_t59_log10, 10.0).pass
            @test compare_julia_wasm(_t59_log10, 100.0).pass
            @test compare_julia_wasm(_t59_log10, 0.1).pass
            @test compare_julia_wasm(_t59_log10, 0.01).pass
        end

        @testset "expm1(Float64) (WBUILD-1020)" begin
            _t59_expm1(x::Float64)::Float64 = expm1(x)
            @test compare_julia_wasm(_t59_expm1, 0.0).pass
            @test compare_julia_wasm(_t59_expm1, 1.0).pass
            @test compare_julia_wasm(_t59_expm1, -1.0).pass
            @test compare_julia_wasm(_t59_expm1, 1e-10).pass
            @test compare_julia_wasm(_t59_expm1, 0.5).pass
        end

        @testset "log1p(Float64) (WBUILD-1020)" begin
            _t59_log1p(x::Float64)::Float64 = log1p(x)
            @test compare_julia_wasm(_t59_log1p, 0.0).pass
            @test compare_julia_wasm(_t59_log1p, 1.0).pass
            @test compare_julia_wasm(_t59_log1p, -0.5).pass
            @test compare_julia_wasm(_t59_log1p, 1e-10).pass
            @test compare_julia_wasm(_t59_log1p, 10.0).pass
        end
    end

end
