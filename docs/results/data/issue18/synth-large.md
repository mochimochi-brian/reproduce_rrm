### synth-large

input `data/bench/synth_n7_eq10_ts40.g` (sha256 `9cef7594f04ec968`)  
|sym| = 5040, 10 EQs, 40 TSs, 41160 vertices, 147000 edges  
MEM=2g, reps=3, timeout=3600.0s, GAP 4.12.1, 4 CPUs, commit 79a63f08b382 (dirty)

| config | wall median (s) | wall min-max (s) | stdev (s) | CPU total (s) | max single peak RSS (MiB) | sum of peaks (MiB) | concurrent peak RSS (MiB) | speedup vs v11 | bytes identical |
|---|---|---|---|---|---|---|---|---|---|
| v11 | 157.63 | 157.63-157.63 | 0.00 | 157.6 | 1816 | 1816 | 1816 | 1.00x | reference |
| fast | 2.94 | 2.90-3.04 | 0.07 | 2.9 | 654 | 654 | 654 | 53.59x | yes |
| par:1 | 2.88 | 2.79-2.90 | 0.06 | 2.9 | 654 | 657 | 657 | 54.74x | yes |
| par:2 | 6.37 | 6.16-6.37 | 0.12 | 8.9 | 610 | 1835 | 1173 | 24.76x | yes |
| par:4 | 7.19 | 6.95-7.21 | 0.15 | 13.6 | 610 | 2919 | 2211 | 21.93x | yes |

