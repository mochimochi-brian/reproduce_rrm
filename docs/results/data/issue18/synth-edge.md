### synth-edge

input `data/bench/synth_n7_eq4_ts200_edge.g` (sha256 `9feda9cc1715fe17`)  
|sym| = 5040, 4 EQs, 200 TSs, 168 vertices, 341292 edges  
MEM=2g, reps=3, timeout=0s, GAP 4.12.1, 4 CPUs, commit 79a63f08b382 (dirty)

| config | wall median (s) | wall min-max (s) | stdev (s) | CPU total (s) | max single peak RSS (MiB) | sum of peaks (MiB) | concurrent peak RSS (MiB) | speedup vs v11 | bytes identical |
|---|---|---|---|---|---|---|---|---|---|
| v11 | 6.24 | 6.18-6.27 | 0.04 | 6.2 | 1207 | 1207 | 1207 | 1.00x | reference |
| fast | 4.97 | 4.88-5.08 | 0.10 | 5.0 | 975 | 974 | 974 | 1.26x | yes |
| par:1 | 5.03 | 5.01-5.21 | 0.11 | 5.0 | 975 | 978 | 978 | 1.24x | yes |
| par:2 | 4.58 | 4.47-4.62 | 0.08 | 7.4 | 723 | 1926 | 1369 | 1.36x | yes |
| par:4 | 3.72 | 3.61-3.81 | 0.10 | 9.8 | 602 | 2871 | 2260 | 1.68x | yes |

