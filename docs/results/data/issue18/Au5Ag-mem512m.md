### Au5Ag-mem512m

input `data/Au5Ag_AFIR.g` (sha256 `d79133bfd2794a51`)  
|sym| = 120, 17 EQs, 86 TSs, 1704 vertices, 10020 edges  
MEM=512m, reps=3, timeout=0s, GAP 4.12.1, 4 CPUs, commit 79a63f08b382 (dirty)

| config | wall median (s) | wall min-max (s) | stdev (s) | CPU total (s) | max single peak RSS (MiB) | sum of peaks (MiB) | concurrent peak RSS (MiB) | speedup vs fast | bytes identical |
|---|---|---|---|---|---|---|---|---|---|
| fast | 1.17 | 1.16-1.22 | 0.03 | 1.2 | 286 | 286 | 286 | 1.00x | reference |
| par:2 | 2.36 | 2.30-2.38 | 0.04 | 3.3 | 281 | 829 | 503 | 0.50x | yes |
| par:4 | 2.47 | 2.42-2.52 | 0.05 | 5.2 | 281 | 1352 | 985 | 0.48x | yes |

