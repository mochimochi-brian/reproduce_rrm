# Sequential output bundles

Implemented from fork `main` at `f429141` on qc4, 2026-09-15, following the
request to support other programs reading completed RRM results.

## Change

`generate_rrm_v11_parallel.sh --bundle OUTPUT_DIR GFILE` now supports the
default `GAP_WORKERS=1`. One GAP process builds one index and writes both dat
files and the vertex correspondence table. Completion counts are emitted after
all writes; the existing validator, manifest, writer lock, and single `current`
rename publish the generation. The direct-file interface remains available.

The reader procedure and manifest semantics are documented in the
[README](../../README.md#output-bundles) and
[contract](../specs/parallel-vertex-map.md#sequential-bundles).

## Verification

Environment: GAP 4.13.0 at `/home5/Brian/bin/gap-4.13.0/gap`, `MEM=1g`,
`BASH_ENV=/dev/null`. Source files were on NFS; all test output was on local
XFS under `/tmp`. These runs do not validate publication to NFS.

- `python3 tests/test_parallel_publication.py`: 22 tests passed. Shared checks
  exercise sequential and parallel publication, failed first runs, retention
  of old generations across updates, incomplete or invalid metadata, missing
  output, write/checksum/rename failures, INT/TERM before and after publication,
  child cancellation, and writer locking. The sequential success check confirms
  that only one GAP process runs.
- `bash tests/test_rrm_full_comparison.sh`: passed with 59 reported checks.
  The driver comparisons now use bundles for workers 1, 2, and higher counts.
  Au5Ag, AuCu4 continue mode, inversion isomers, self-loops, multiple edges,
  label variants and zero TS agree with the reference. Actual GAP Pechukas
  failures and an injected GAP error after partial edge output preserve the
  previous published pair.
- `python3 tests/test_rrm_vertex_map.py`: all 4 tests passed, including actual
  GAP worker correspondence mutation.
- Shell syntax, Python compilation and `git diff --check` passed.

Raw logs: `/tmp/rrm-sequential-bundle-publication.log`,
`/tmp/rrm-sequential-bundle-full.log`, and
`/tmp/rrm-sequential-bundle-vertex-map.log`.

## Small-input overhead check

Au5Ag, three alternating runs of each interface with `GAP_WORKERS` unset
(therefore defaulting to 1), including process startup, validation and
publication. Every pair was byte-identical to the reference from the full
comparison suite; bundle manifest checksums also verified successfully.

| Output interface | Wall time, seconds | Median |
|---|---|---|
| Direct files | 1.668, 1.618, 1.567 | 1.618 s |
| Sequential bundle | 1.818, 1.818, 1.818 | 1.818 s |

The added cost was about 0.20 s for this input and environment. This is a
small-input check, not a scaling claim. Raw measurements are in
`/tmp/rrm-sequential-bundle-timing.json`; generated files and logs are under
`/tmp/rrm-sequential-bundle-timing-vykiw1oj/`.
