### Au5Ag-mem2g

input `data/Au5Ag_AFIR.g` (sha256 `d79133bfd2794a51`)  
|sym| = 120, 17 EQs, 86 TSs, 1704 vertices, 10020 edges  
MEM=2g, reps=3, timeout=0s, GAP 4.12.1, 4 CPUs, commit 79a63f08b382 (dirty)

| config | wall median (s) | wall min-max (s) | stdev (s) | CPU total (s) | max single peak RSS (MiB) | sum of peaks (MiB) | concurrent peak RSS (MiB) | speedup vs fast | bytes identical |
|---|---|---|---|---|---|---|---|---|---|
| fast | 1.32 | 1.32-1.42 | 0.06 | 1.3 | 478 | 477 | 477 | 1.00x | reference |
| par:2 | 2.64 | 2.45-2.69 | 0.13 | 3.7 | 473 | 1405 | 886 | 0.50x | yes |
| par:4 | 2.67 | 2.66-2.68 | 0.01 | 5.7 | 473 | 2311 | 1756 | 0.49x | yes |

