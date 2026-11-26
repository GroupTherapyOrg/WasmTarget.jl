---------------------------- MODULE TaskExcStack ----------------------------
(***************************************************************************)
(* A TLA+ model of WT2's port of Julia's task exception stack (src/julia/  *)
(* runtime/rtutils.jl jl_excstack_t and its functions; src/intrinsics.jl's *)
(* Error._throw push; src/code_generator.jl's enter, pop_exception,        *)
(* the_exception and rethrow; src/functions.jl's export entry) against     *)
(* Julia's own (task.c throw_internal, jl_rethrow, jl_rethrow_other;       *)
(* rtutils.c jl_push_excstack, jl_excstack_state, jl_restore_excstack;     *)
(* jlapi.c jl_current_exception; codegen.cpp's enter and pop_exception;    *)
(* julia.h JL_TRY/JL_CATCH at the host's call).                            *)
(*                                                                         *)
(* JULIA. Each task has a stack of exceptions. A throw pushes its          *)
(* exception and jumps to the innermost handler; one object thrown twice   *)
(* is two entries. An `enter` records the stack's depth; `pop_exception`   *)
(* restores that depth. `the_exception` reads the top, `nothing` when the  *)
(* stack is empty. `rethrow()` raises the top without pushing;             *)
(* `rethrow(e)` overwrites the top with `e` and raises it without pushing; *)
(* either at depth 0 throws ErrorException ("rethrow() not allowed outside *)
(* a catch block", or "rethrow(exc) ..."), which pushes as every throw     *)
(* does. Leaving a try body normally, and landing in a catch, leave the    *)
(* stack as it is. The stack belongs to the task, so it outlives a call:   *)
(* a function called from inside its caller's catch reads the caller's    *)
(* exception. The host is the catching frame of the call it makes: its    *)
(* JL_TRY records the depth at the call's entry and its JL_CATCH restores  *)
(* it, so a call the host makes after an escape starts with the stack the  *)
(* escaped call started with.                                              *)
(*                                                                         *)
(* WT2. The stack is Julia's own representation: an array of entries and   *)
(* the index of its top (jl_excstack_t's raw buffer and `top`); an entry   *)
(* is a slot here (its exception; the backtrace beside it is outside the   *)
(* claim). A push writes the slot above the top and raises the top; a slot *)
(* above the top keeps its last value until a push writes it again. An     *)
(* enter saves the top index (jl_excstack_state), a pop_exception sets the *)
(* top back to it (jl_restore_excstack), the_exception reads the top slot, *)
(* `rethrow(e)` writes it. The exception tag's payload is dart's (the      *)
(* exception and its stack trace) and a landing reads none of it: a       *)
(* landing leaves the stack as the unwind left it. Each export is an     *)
(* entry, a function of its own that records the top on entry and calls   *)
(* the exported function inside a try_table catching every exception; on  *)
(* an escape it sets the top back to the recorded index and throws the     *)
(* exception on (Entry = "saves": JL_TRY's jl_excstack_state and          *)
(* JL_CATCH's jl_restore_excstack, julia.h:2548 and :2555), right for a   *)
(* call the host makes from inside an import as for a top-level one. The  *)
(* module's own calls call the exported function directly. The other      *)
(* entries: none (Entry = "none") and one that sets the top to 0          *)
(* (Entry = "reset", right only while no host call re-enters).            *)
(*                                                                         *)
(* ESCAPES. Two kinds: the tag (a Julia throw) and a trap. A Julia region  *)
(* catches only the tag, so a trap unwinds every frame of the call to the  *)
(* host. Wasm's try_table catches no trap, so a saving entry restores      *)
(* nothing after one: a call after a trap is outside the saving entry's    *)
(* claim (a trap is already a departure from Julia, whose runtime raises   *)
(* a catchable exception where wasm traps). Stack exhaustion, which Julia  *)
(* raises as a StackOverflowError a Julia catch catches, is outside the    *)
(* model, as in ExceptionStack.tla.                                        *)
(*                                                                         *)
(* THE CLAIM. On every run of top-level host calls, each a program of      *)
(* nested try, catch, rethrow and calls of the exported function itself    *)
(* (bounded by MaxFrames and MaxSteps), every `the_exception` read and     *)
(* every raised value is Julia's (Agrees).                                 *)
(*                                                                         *)
(* The Broken instances, each a realistic mistake: no entry, the export    *)
(* the function itself (NoEntryReset: an escape's stale top read by the    *)
(* next call); a resetting entry's reset in the exported function's own   *)
(* prologue, so a                                                          *)
(* call of it from inside the module empties the stack (InnerReset); a     *)
(* pop_exception that emits nothing, the top read where the lexical catch  *)
(* left it (NoPopRestore).                                                 *)
(*                                                                         *)
(* parity(quarantine: Julia's per-task exception stack outlives a call;    *)
(* dart's catch state is lexical, code_generator.dart:2966 visitRethrow,   *)
(* and its tag carries (exception, stackTrace), tags.dart.)                *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Vals, MaxFrames, MaxSteps,
          Entry,        \* the export's entry: "saves" (records the top, restores it on an escape), "reset" (sets it to 0), "none"
          InnerReset,   \* the exported function itself sets the top to 0, so its calls from inside the module do too
          PopRestores   \* pop_exception sets the top back to its enter's saved index

Nothing == "nothing"
ErrR == "errR"   \* ErrorException("rethrow() not allowed outside a catch block")
ErrO == "errO"   \* ErrorException("rethrow(exc) not allowed outside a catch block")
AllVals == Vals \cup {Nothing, ErrR, ErrO}

VARIABLES frames,   \* the open try and catch frames of the open call, innermost last
          inCall,   \* a host call is open
          cdepth,   \* Julia's depth at the open call's entry (the host's jl_excstack_state)
          csaved,   \* WT2's top at the open call's entry, which a saving entry records
          trapped,  \* a call escaped by a trap
          spec,     \* Julia's exception stack
          raw,      \* WT2's slots: raw[i] the entry at index i, a slot above the top stale
          top,      \* WT2's top index, 0 for the empty stack
          obsS, obsI,  \* the last observation, Julia's and WT2's
          steps
vars == <<frames, inCall, cdepth, csaved, trapped, spec, raw, top, obsS, obsI, steps>>

\* a try or catch body: Julia's depth at its enter, WT2's top index there
Frame == [kind : {"try", "catch"}, depth : Nat, ptr : Nat]

TypeOK == /\ frames \in Seq(Frame) /\ inCall \in BOOLEAN /\ cdepth \in Nat /\ csaved \in Nat /\ trapped \in BOOLEAN
          /\ spec \in Seq(AllVals) /\ raw \in Seq(AllVals) /\ top \in Nat /\ top <= Len(raw)
          /\ steps \in Nat

Init == /\ frames = <<>> /\ inCall = FALSE /\ cdepth = 0 /\ csaved = 0 /\ trapped = FALSE
        /\ spec = <<>> /\ raw = <<>> /\ top = 0
        /\ obsS = <<"start">> /\ obsI = <<"start">> /\ steps = 0

JuliaTop == IF spec = <<>> THEN Nothing ELSE spec[Len(spec)]
WTTop == IF top = 0 THEN Nothing ELSE raw[top]
Last == frames[Len(frames)]

\* WT2's push: the slot above the top written (the array grown to hold it), the top raised
PushRaw(v) == IF top < Len(raw) THEN [raw EXCEPT ![top + 1] = v] ELSE Append(raw, v)

\* the innermost open try body, 0 when there is none
Handler == LET ks == {k \in 1..Len(frames) : frames[k].kind = "try"} IN
           IF ks = {} THEN 0 ELSE CHOOSE k \in ks : \A j \in ks : j <= k

\* Unwind an exception of kind `kind`: Julia's stack is already spec2, WT2's slots and top r2,
\* t2; sv and iv are the values each raises. Only the tag lands, and the landing leaves both
\* stacks as they are. With no handler the escape leaves the call: the host's JL_CATCH restores
\* Julia's stack to the call's entry depth; a saving entry restores WT2's top to the index it
\* recorded where its try_table catches the escape (the tag, never a trap); no other entry restores.
Unwind(kind, sv, iv, spec2, r2, t2) ==
    LET k == IF kind = "tag" THEN Handler ELSE 0 IN
    /\ raw' = r2 /\ csaved' = csaved
    /\ IF k # 0 THEN
          /\ obsS' = <<"land", sv>> /\ obsI' = <<"land", iv>>
          /\ spec' = spec2 /\ inCall' = TRUE /\ cdepth' = cdepth /\ top' = t2 /\ trapped' = trapped
          /\ frames' = [j \in 1..k |-> IF j = k THEN [frames[k] EXCEPT !.kind = "catch"] ELSE frames[j]]
       ELSE
          /\ obsS' = <<"escape", kind, sv>> /\ obsI' = <<"escape", kind, iv>>
          /\ spec' = SubSeq(spec2, 1, cdepth) /\ inCall' = FALSE /\ cdepth' = cdepth
          /\ top' = IF Entry = "saves" /\ kind = "tag" THEN csaved ELSE t2
          /\ trapped' = (trapped \/ kind = "trap")
          /\ frames' = <<>>

\* The host calls an export: Julia records the depth; WT2's entry records the top (saves), sets it
\* to 0 (reset) or does nothing (none). A call after a trap is outside a saving entry's claim.
HostCall == /\ ~inCall /\ ~(Entry = "saves" /\ trapped)
            /\ inCall' = TRUE /\ cdepth' = Len(spec) /\ csaved' = top
            /\ top' = IF Entry = "reset" \/ InnerReset THEN 0 ELSE top
            /\ UNCHANGED <<frames, spec, raw, trapped>>
            /\ obsS' = <<"call">> /\ obsI' = <<"call">>

\* The call returns normally once every region it entered is closed.
Return == /\ inCall /\ frames = <<>>
          /\ inCall' = FALSE
          /\ UNCHANGED <<frames, cdepth, csaved, trapped, spec, raw, top>>
          /\ obsS' = <<"return">> /\ obsI' = <<"return">>

\* A call of the exported function from inside the module: a direct call, which shares the
\* frames and touches neither stack (InnerReset: its own prologue sets the top to 0).
InnerCall == /\ inCall
             /\ top' = IF InnerReset THEN 0 ELSE top
             /\ UNCHANGED <<frames, inCall, cdepth, csaved, trapped, spec, raw>>
             /\ obsS' = <<"inner">> /\ obsI' = <<"inner">>

Enter == /\ inCall /\ Len(frames) < MaxFrames
         /\ frames' = Append(frames, [kind |-> "try", depth |-> Len(spec), ptr |-> top])
         /\ UNCHANGED <<inCall, cdepth, csaved, trapped, spec, raw, top>>
         /\ obsS' = <<"enter">> /\ obsI' = <<"enter">>

Leave == /\ inCall /\ frames # <<>> /\ Last.kind = "try"
         /\ frames' = SubSeq(frames, 1, Len(frames) - 1)
         /\ UNCHANGED <<inCall, cdepth, csaved, trapped, spec, raw, top>>
         /\ obsS' = <<"leave">> /\ obsI' = <<"leave">>

PopException ==
    /\ inCall /\ frames # <<>> /\ Last.kind = "catch"
    /\ spec' = SubSeq(spec, 1, Last.depth)
    /\ top' = IF PopRestores THEN Last.ptr ELSE top
    /\ frames' = SubSeq(frames, 1, Len(frames) - 1)
    /\ UNCHANGED <<inCall, cdepth, csaved, trapped, raw>>
    /\ obsS' = <<"pop">> /\ obsI' = <<"pop">>

Read == /\ inCall
        /\ obsS' = <<"read", JuliaTop>> /\ obsI' = <<"read", WTTop>>
        /\ UNCHANGED <<frames, inCall, cdepth, csaved, trapped, spec, raw, top>>

Trap == /\ inCall /\ Unwind("trap", Nothing, Nothing, spec, raw, top)

Throw(v) == /\ inCall /\ Unwind("tag", v, v, Append(spec, v), PushRaw(v), top + 1)

Rethrow ==
    LET sv == IF spec = <<>> THEN ErrR ELSE JuliaTop
        spec2 == IF spec = <<>> THEN Append(spec, ErrR) ELSE spec
        iv == IF top = 0 THEN ErrR ELSE WTTop
    IN /\ inCall
       /\ Unwind("tag", sv, iv, spec2, IF top = 0 THEN PushRaw(ErrR) ELSE raw, IF top = 0 THEN 1 ELSE top)

RethrowOther(v) ==
    LET sv == IF spec = <<>> THEN ErrO ELSE v
        spec2 == IF spec = <<>> THEN Append(spec, ErrO) ELSE [spec EXCEPT ![Len(spec)] = v]
        iv == IF top = 0 THEN ErrO ELSE v
    IN /\ inCall
       /\ Unwind("tag", sv, iv, spec2, IF top = 0 THEN PushRaw(ErrO) ELSE [raw EXCEPT ![top] = v],
                 IF top = 0 THEN 1 ELSE top)

Step == /\ steps < MaxSteps /\ steps' = steps + 1
        /\ (Rethrow \/ Enter \/ Leave \/ PopException \/ Read \/ HostCall \/ Return \/ InnerCall
            \/ Trap \/ \E v \in Vals : Throw(v) \/ RethrowOther(v))

\* the bound, not a deadlock; and the end of a saving entry's claim, after a call that trapped
Stop == (steps = MaxSteps \/ (Entry = "saves" /\ trapped /\ ~inCall)) /\ UNCHANGED vars

Spec == Init /\ [][Step \/ Stop]_vars

Agrees == obsS = obsI
=============================================================================
