### Au5Ag-mem12g

input `data/Au5Ag_AFIR.g` (sha256 `d79133bfd2794a51`)  
|sym| = 120, 17 EQs, 86 TSs, 1704 vertices, 10020 edges  
MEM=12g, reps=3, timeout=0s, GAP 4.12.1, 4 CPUs, commit 79a63f08b382 (dirty)

| config | wall median (s) | wall min-max (s) | stdev (s) | CPU total (s) | max single peak RSS (MiB) | sum of peaks (MiB) | concurrent peak RSS (MiB) | speedup vs fast | bytes identical |
|---|---|---|---|---|---|---|---|---|---|
| fast | 3.02 | 2.14-3.05 | 0.52 | 3.0 | 1758 | 1758 | 1758 | 1.00x | reference |
| par:2 | 7.13 | 7.01-10.30 | 1.87 | 11.8 | 1753 | 5244 | 3442 | 0.42x | yes |
| par:4 | 9.98 | 9.68-11.83 | 1.17 | 29.6 | 1753 | 8713 | 6764 | 0.30x | yes |

