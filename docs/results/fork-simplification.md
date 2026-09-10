# Simplification of fork additions

Based on fork commit `a6a9dc4`; verified on qc4 on 2026-09-11.

## Scope and behavior

Only files added by the fork are changed. The 104 paths tracked by Teramoto
commit `d64568d` are excluded, including README, `rrm_reconstruction_v18.py`,
`generate_rrm_v11.g`, `check_number_of_edges_v3.py`, and the demo.
The three production files have 132 fewer lines in total.

- The parallel driver uses direct TS partition arithmetic, one path for zero
  and nonzero TS counts, and cleanup of only the current run's known shards.
- Each generation is already isolated, so vertices, the master map, and edges
  use their final names from the start. Only the `current` rename publishes
  them. Failed generations retain partial files for diagnosis; consumers must
  continue to resolve `current` once. See the [contract](../specs/parallel-vertex-map.md).
- The test-only `--assert-nvert`, `--gap-string`, `--kill-pids`, and
  `--rm-numeric-shards` modes are removed; tests source the driver helpers.
  `--active-workers` and `--ts-slice` remain for the benchmark harness.
- Fast GAP output shares inversion suffix formatting and opens each EQ cluster
  in the outer EQ loop. The dat checker reports parsing errors at its CLI boundary.

## Verification

All six shell suites passed with GAP 4.13.0 at
`/home5/Brian/bin/gap-4.13.0/gap`, `BASH_ENV=/dev/null`, and output under `/tmp`:
`test_check_number_of_edges_dat.sh`, `test_generate_rrm_v11_fast.sh`,
`test_pechukas_policy.sh`, `test_generate_rrm_parallel.sh`,
`test_rrm_full_comparison.sh`, and `test_rrm_bench.sh` (all under `tests/`).
GAP memory was `1g`, except `512m` for the benchmark harness tests.

Coverage includes 77 vertex-index assertions, 13 publication tests, four
vertex-map tests, all seven label argument combinations, zero TS, worker caps,
and exact reference comparisons for Au5Ag and AuCu4 continue mode. Write failures,
interrupted publication, retained readers, worker cancellation, and malformed
metadata preserve the publication contract. Degree errors retain their CLI
diagnostics without a traceback. Benchmark tests still consume the driver helpers.

Shell syntax, Python compilation, whitespace, and the protected-path check passed.
Detailed parallel, full-comparison, and benchmark logs are respectively
`/tmp/rrm-simplify-parallel.log`, `/tmp/rrm-simplify-full.log`, and
`/tmp/rrm-simplify-bench.log`. These are validation runs, not speedup measurements.
