### Au5Ag

input `data/Au5Ag_AFIR.g` (sha256 `d79133bfd2794a51`)  
|sym| = 120, 17 EQs, 86 TSs, 1704 vertices, 10020 edges  
MEM=2g, reps=3, timeout=0s, GAP 4.12.1, 4 CPUs, commit 79a63f08b382 (dirty)

| config | wall median (s) | wall min-max (s) | stdev (s) | CPU total (s) | max single peak RSS (MiB) | sum of peaks (MiB) | concurrent peak RSS (MiB) | speedup vs v11 | bytes identical |
|---|---|---|---|---|---|---|---|---|---|
| v11 | 6.58 | 6.14-7.19 | 0.53 | 6.6 | 1100 | 1099 | 1099 | 1.00x | reference |
| fast | 1.34 | 1.31-1.37 | 0.03 | 1.3 | 478 | 477 | 477 | 4.90x | yes |
| par:1 | 1.32 | 1.28-1.37 | 0.05 | 1.3 | 478 | 480 | 480 | 4.99x | yes |
| par:2 | 2.59 | 2.43-2.61 | 0.10 | 3.6 | 473 | 1407 | 888 | 2.54x | yes |
| par:4 | 2.72 | 2.68-2.79 | 0.05 | 5.8 | 473 | 2313 | 1747 | 2.42x | yes |

