### synth-medium

input `data/bench/synth_n6_eq8_ts30.g` (sha256 `6c1a40b4c992b2e5`)  
|sym| = 720, 8 EQs, 30 TSs, 4440 vertices, 15600 edges  
MEM=2g, reps=3, timeout=0s, GAP 4.12.1, 4 CPUs, commit 79a63f08b382 (dirty)

| config | wall median (s) | wall min-max (s) | stdev (s) | CPU total (s) | max single peak RSS (MiB) | sum of peaks (MiB) | concurrent peak RSS (MiB) | speedup vs v11 | bytes identical |
|---|---|---|---|---|---|---|---|---|---|
| v11 | 2.95 | 2.93-2.98 | 0.02 | 3.0 | 572 | 570 | 570 | 1.00x | reference |
| fast | 1.15 | 1.14-1.15 | 0.01 | 1.1 | 461 | 461 | 461 | 2.58x | yes |
| par:1 | 1.14 | 1.13-1.18 | 0.03 | 1.1 | 461 | 464 | 464 | 2.60x | yes |
| par:2 | 2.49 | 2.47-2.54 | 0.04 | 3.6 | 454 | 1405 | 902 | 1.19x | yes |
| par:4 | 2.71 | 2.70-2.71 | 0.01 | 5.9 | 454 | 2321 | 1781 | 1.09x | yes |

