---- MODULE MCStripWalk ----
EXTENDS StripWalk
\* bytes 1 (ASCII), 2 (a two-byte lead), 3 (a three-byte lead); the NUL's length is 1
MCSeqLen(b) == IF b = 2 THEN 2 ELSE IF b = 3 THEN 3 ELSE 1
\* candidate suffixes: whole characters and sequences cut off by the NUL, then by undefined bytes
MCCands == {<<1>>, <<2, 1>>, <<2, 0>>, <<3, 1, 1>>, <<3, 1, 0>>, <<3, 0, 0>>, <<3, 0, 1>>, <<2, 3>>}
====
