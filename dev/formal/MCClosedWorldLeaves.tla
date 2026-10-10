------------------------ MODULE MCClosedWorldLeaves -----------------------
(* Declared imports (ExternalLeaves), cut at every merge: the code.        *)
(*                                                                         *)
(* Instance shape (8 methods, 1 root; I1 and I2 are imports, `import_stubs`*)
(* entries, whose native fallback bodies Julia's queue infers with their   *)
(* callers):                                                               *)
(*   R --invoke--> A --:new T-->[observed]                                 *)
(*   R --invoke--> I1 --invoke--> Q1   (I1's native body's callee)         *)
(*   R --dyn T--> B                    (a dynamic candidate: a late round) *)
(*   B --invoke--> I2 --invoke--> Q2, K                                    *)
(*   B --invoke--> K                   (K is the program's too)            *)
(*                                                                         *)
(* The first collection's compile! of R infers I1 and Q1, and its cut      *)
(* leaves them out. B is enrolled one round later; that round's compile!   *)
(* of B infers I2, Q2 and K, and its cut (LeafCut, `collect_new_pairs!`)   *)
(* keeps K, which B names, and leaves I2 and Q2 out. Reachable = {R, A, B, *)
(* K}. MCClosedWorldLeavesLateLeafUncutBroken.cfg cuts only the first      *)
(* collection (LateCut = FALSE): B's round merges I2's native body.        *)
EXTENDS ClosedWorld

MCMethods == {"R", "A", "B", "I1", "Q1", "I2", "Q2", "K"}
MCRoots   == {"R"}
MCTypes   == {"T"}

MCInvokeEdges == [m \in MCMethods |->
    IF   m = "R"  THEN {"A", "I1"}
    ELSE IF m = "I1" THEN {"Q1"}
    ELSE IF m = "B"  THEN {"I2", "K"}
    ELSE IF m = "I2" THEN {"Q2", "K"}
    ELSE {}]

MCRetargets  == [m \in MCMethods |-> {}]
MCTypeSites  == [m \in MCMethods |-> IF m = "A" THEN {"T"} ELSE {}]
MCDynSites   == [m \in MCMethods |-> IF m = "R" THEN {"T"} ELSE {}]
MCDynTargets == [t \in MCTypes |-> {"B"}]

MCSpecializeFails == {}
MCRoundCeiling    == 0
MCSwallowFailures == FALSE
MCHiddenEdges     == [m \in MCMethods |-> {}]
MCWidened         == {}
MCUnmaterialized  == {}
MCCollectorKinds  == HiddenKinds
MCTrim            == FALSE
MCFmaEdges        == [m \in MCMethods |-> {}]
MCExternalLeaves  == {"I1", "I2"}
MCLateCut         == TRUE

(* the late import is reached only from the dynamic candidate *)
ASSUME /\ "I2" \notin JuliaClosure(MCRoots, {})
       /\ "I2" \in JuliaClosure({"B"}, {})
=============================================================================
