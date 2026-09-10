### synth-large

input `data/bench/synth_n7_eq10_ts40.g` (sha256 `9cef7594f04ec968`)  
|sym| = 5040, 10 EQs, 40 TSs, 41160 vertices, 147000 edges  
MEM=2g, reps=3, timeout=3600.0s, GAP 4.12.1, 4 CPUs, commit da1618f8ac64 (dirty)

| config | wall median (s) | wall min-max (s) | stdev (s) | CPU total (s) | max single peak RSS (MiB) | sum of peaks (MiB) | concurrent peak RSS (MiB) | speedup vs v11 | bytes identical |
|---|---|---|---|---|---|---|---|---|---|
| v11 | 157.24 | 156.84-158.29 | 0.74 | 157.2 | 1816 | 1816 | 1816 | 1.00x | reference |
| fast | 2.79 | 2.72-2.82 | 0.05 | 2.8 | 654 | 654 | 654 | 56.43x | yes |
| par:1 | 2.81 | 2.79-2.84 | 0.03 | 2.8 | 654 | 657 | 657 | 56.00x | yes |
| par:2 | 6.21 | 6.18-6.33 | 0.08 | 8.7 | 610 | 1836 | 1171 | 25.31x | yes |
| par:4 | 6.96 | 6.92-7.53 | 0.34 | 13.5 | 610 | 2918 | 2202 | 22.58x | yes |

