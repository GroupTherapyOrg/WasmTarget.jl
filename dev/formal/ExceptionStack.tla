---------------------------- MODULE ExceptionStack ----------------------------
(***************************************************************************)
(* A TLA+ model of WT's lowering of Julia's exception stack (try regions,  *)
(* catch, the_exception, pop_exception, rethrow; src/codegen/statements.jl, *)
(* generate.jl, compile.jl) against Julia's own (task.c throw_internal,    *)
(* jl_rethrow, jl_rethrow_other; rtutils.c jl_excstack_state,              *)
(* jl_restore_excstack; codegen.cpp's enter and pop_exception).            *)
(*                                                                         *)
(* JULIA. Each task has a stack of exceptions. A throw pushes its          *)
(* exception and jumps to the innermost handler. An `enter` records the    *)
(* stack's depth; `pop_exception` restores that depth. `the_exception`     *)
(* reads the top, `nothing` when the stack is empty. `rethrow()` raises    *)
(* the top without pushing; `rethrow(e)` overwrites the top with `e` and    *)
(* raises it without pushing; either at depth 0 throws ErrorException      *)
(* ("rethrow() not allowed outside a catch block", or "rethrow(exc) …"),   *)
(* which pushes as every throw does. Leaving a try body normally, and       *)
(* landing in a catch, leave the stack as it is.                            *)
(*                                                                         *)
(* WT (Impl = "cells"). The stack is a linked list of cells {exn, prev}    *)
(* whose top is one global: a throw pushes a cell and raises the tag with  *)
(* (exn, stack); a rethrow raises the top cell's without pushing; an enter  *)
(* saves the top pointer; a pop_exception restores it; the_exception reads  *)
(* the top cell; `rethrow(e)` writes the top cell's exn. A cell is an entry *)
(* of Julia's stack and a pointer its depth.                                *)
(*                                                                         *)
(* THE CLAIM. On every program of nested try, catch and rethrow (bounded   *)
(* by MaxFrames and MaxSteps) within one top-level call, every             *)
(* `the_exception` read and every raised value is Julia's (Agrees). Across *)
(* calls, an exception that escapes one leaves its entry for the next      *)
(* (dev/MARCH.md 13.17: the export boundary). The Broken instances: the value-save          *)
(* lowering (Impl = "values": an enter saves `$current_exn`, a catch sets   *)
(* it, a pop restores it, a rethrow throws it: `rethrow(e)` inside a region *)
(* nested in a catch is undone by that region's pop); a rethrow at depth 0  *)
(* that throws the top instead of Julia's ErrorException; a push at the     *)
(* catch's landing instead of at the throw (TLC's counterexample to the     *)
(* first design: a rethrow's landing pushes a second cell, which a later    *)
(* `rethrow(e)` overwrites instead of the entry Julia overwrites, visible  *)
(* after the enclosing pop).                                               *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. Two exception values; a stack trace is the   *)
(* value's companion and is carried wherever the value is, so it is left   *)
(* out. Control flow is the frame stack the lowering sees: an open try      *)
(* body, an open catch body; `return`/`break` out of a catch is its        *)
(* pop_exception (Julia's lowering emits one), a finally is a catch that   *)
(* ends in rethrow().                                                      *)
(*                                                                         *)
(* formal(src/codegen/statements.jl compile_statement!): a try region's    *)
(* enter, catch, pop_exception, the_exception and rethrow answer as        *)
(* Julia's exception stack.                                                *)
(*                                                                         *)
(* parity(quarantine: Julia's per-task exception stack is dynamic state    *)
(* that rethrow() and callees read; dart's catch binds its exception and   *)
(* stack to locals and rethrows them lexically, code_generator.dart:2966   *)
(* visitRethrow.)                                                          *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Vals, MaxFrames, MaxSteps,
          Impl,             \* "cells" (the port) or "values" (the value-save lowering)
          RethrowChecksDepth,  \* FALSE = a rethrow at depth 0 throws the top
          PushAtLanding     \* TRUE = a catch's landing pushes, not the throw

Nothing == "nothing"
ErrR == "errR"   \* ErrorException("rethrow() not allowed outside a catch block")
ErrO == "errO"   \* ErrorException("rethrow(exc) not allowed outside a catch block")
AllVals == Vals \cup {Nothing, ErrR, ErrO}

VARIABLES frames,   \* the open try and catch bodies, innermost last
          spec,     \* Julia's exception stack
          cells,    \* WT's cells: a sequence of [exn, prev]; a pointer is an index, 0 is null
          top,      \* WT's top pointer
          cur,      \* Impl = "values": the one `$current_exn`
          obsS, obsI,  \* the last observation, Julia's and WT's
          steps, done
vars == <<frames, spec, cells, top, cur, obsS, obsI, steps, done>>

Frame == [kind : {"try", "catch"}, depth : Nat, ptr : Nat, val : AllVals]

TypeOK == /\ frames \in Seq(Frame) /\ spec \in Seq(AllVals)
          /\ cells \in Seq([exn : AllVals, prev : Nat]) /\ top \in Nat /\ cur \in AllVals
          /\ steps \in Nat /\ done \in BOOLEAN

Init == /\ frames = <<>> /\ spec = <<>> /\ cells = <<>> /\ top = 0 /\ cur = Nothing
        /\ obsS = <<"start">> /\ obsI = <<"start">> /\ steps = 0 /\ done = FALSE

JuliaTop == IF spec = <<>> THEN Nothing ELSE spec[Len(spec)]
WTTop == IF Impl = "values" THEN cur ELSE IF top = 0 THEN Nothing ELSE cells[top].exn

\* the innermost open try body, 0 when there is none
Handler == LET ks == {k \in 1..Len(frames) : frames[k].kind = "try"} IN
           IF ks = {} THEN 0 ELSE CHOOSE k \in ks : \A j \in ks : j <= k

\* Raise: Julia's stack is already spec2, WT's cells and top are c2, t2 (before the landing);
\* sv and iv are the values each raises. It unwinds to the handler, whose try body becomes its
\* catch body; WT's landing pushes a cell (or sets `$current_exn`).
Raise(sv, iv, spec2, c2, t2) ==
    LET k == Handler IN
    IF k = 0 THEN
        /\ obsS' = <<"escape", sv>> /\ obsI' = <<"escape", iv>>
        /\ done' = TRUE /\ frames' = <<>> /\ spec' = spec2
        /\ cells' = c2 /\ top' = t2 /\ cur' = cur
    ELSE
        /\ obsS' = <<"land", sv>> /\ obsI' = <<"land", iv>>
        /\ done' = FALSE
        /\ frames' = [j \in 1..k |-> IF j = k THEN [frames[k] EXCEPT !.kind = "catch"] ELSE frames[j]]
        /\ spec' = spec2
        /\ IF Impl = "values"
           THEN /\ cur' = iv /\ cells' = c2 /\ top' = t2
           ELSE IF PushAtLanding
           THEN /\ cells' = Append(c2, [exn |-> iv, prev |-> t2]) /\ top' = Len(c2) + 1
                /\ cur' = cur
           ELSE /\ cells' = c2 /\ top' = t2 /\ cur' = cur

Enter == /\ Len(frames) < MaxFrames
         /\ frames' = Append(frames, [kind |-> "try", depth |-> Len(spec), ptr |-> top, val |-> cur])
         /\ UNCHANGED <<spec, cells, top, cur, done>> /\ obsS' = <<"enter">> /\ obsI' = <<"enter">>

Leave == /\ frames # <<>> /\ frames[Len(frames)].kind = "try"
         /\ frames' = SubSeq(frames, 1, Len(frames) - 1)
         /\ UNCHANGED <<spec, cells, top, cur, done>> /\ obsS' = <<"leave">> /\ obsI' = <<"leave">>

PopException ==
    /\ frames # <<>> /\ frames[Len(frames)].kind = "catch"
    /\ LET f == frames[Len(frames)] IN
       /\ spec' = SubSeq(spec, 1, f.depth)
       /\ top' = f.ptr
       /\ cur' = f.val
    /\ frames' = SubSeq(frames, 1, Len(frames) - 1)
    /\ UNCHANGED <<cells, done>> /\ obsS' = <<"pop">> /\ obsI' = <<"pop">>

Read == /\ obsS' = <<"read", JuliaTop>> /\ obsI' = <<"read", WTTop>>
        /\ UNCHANGED <<frames, spec, cells, top, cur, done>>

\* a throw's push (Impl = "cells", unless the landing pushes)
Pushed(v) == IF Impl = "cells" /\ ~PushAtLanding THEN Append(cells, [exn |-> v, prev |-> top]) ELSE cells
PushedTop == IF Impl = "cells" /\ ~PushAtLanding THEN Len(cells) + 1 ELSE top

Throw(v) == Raise(v, v, Append(spec, v), Pushed(v), PushedTop)

Rethrow ==
    LET sv == IF spec = <<>> THEN ErrR ELSE JuliaTop
        spec2 == IF spec = <<>> THEN Append(spec, ErrR) ELSE spec
        empty == IF Impl = "values" THEN cur = Nothing ELSE top = 0   \* the value-save at its best
        err == empty /\ RethrowChecksDepth   \* WT throws Julia's ErrorException, a throw
        iv == IF err THEN ErrR ELSE WTTop
    IN Raise(sv, iv, spec2, IF err THEN Pushed(ErrR) ELSE cells, IF err THEN PushedTop ELSE top)

RethrowOther(v) ==
    LET sv == IF spec = <<>> THEN ErrO ELSE v
        spec2 == IF spec = <<>> THEN Append(spec, ErrO) ELSE [spec EXCEPT ![Len(spec)] = v]
        empty == IF Impl = "values" THEN cur = Nothing ELSE top = 0   \* the value-save at its best
        err == empty /\ RethrowChecksDepth
        iv == IF err THEN ErrO ELSE v
        c2 == IF err THEN Pushed(ErrO)
              ELSE IF Impl = "values" \/ empty THEN cells ELSE [cells EXCEPT ![top].exn = v]
    IN Raise(sv, iv, spec2, c2, IF err THEN PushedTop ELSE top)

Step == /\ steps < MaxSteps /\ steps' = steps + 1
        /\ ~done
        /\ (Enter \/ Leave \/ PopException \/ Read \/ Rethrow \/ \E v \in Vals : Throw(v) \/ RethrowOther(v))

Stop == (steps = MaxSteps \/ done) /\ UNCHANGED vars   \* the bound or the escape, not a deadlock

Spec == Init /\ [][Step \/ Stop]_vars

Agrees == obsS = obsI
=============================================================================
