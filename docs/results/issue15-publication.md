# Issue #15: atomic publication of parallel output

Issue: https://github.com/mochimochi-brian/reproduce_rrm/issues/15
Parent: https://github.com/mochimochi-brian/reproduce_rrm/issues/14

## Implementation

Parallel runs now require `--bundle OUTPUT_DIR GFILE`. Each run writes its own
vertices, edges, logs, and count/hash manifest. A single same-filesystem rename
replaces `current` only after preparation succeeds. Readers resolve `current`
once and read both files from that retained generation. Older generations are
not garbage-collected. Concurrent writers to one bundle are rejected by flock.

The old parallel VFILE/EFILE invocation fails without modifying those files.
The sequential (`GAP_WORKERS=1`) interface remains a direct-file operation.
See README's “Parallel output bundles” for migration, reading, retention, and
filesystem assumptions. Interruption after publication can return nonzero with
the complete new generation already selected. Cleanup preserves that generation.

This report describes the original #15 implementation, which checked counts
only. Issue #16 subsequently adds ordered vertex correspondence validation
before `rrm_publish_pair`, and records its digest in the manifest. See
[the correspondence contract](../specs/parallel-vertex-map.md) and
[Issue #16 results](issue16-vertex-map.md). It also postpones temporary shard
cleanup until successful publication so failed preparations retain diagnostics.

## Verification environment and commands

2026-09-10, qc4. GAP 4.13.0 at `/home5/Brian/bin/gap-4.13.0/gap`.
Tests write generated artifacts under `/tmp` (XFS). The source checkout is on
NFS; these tests do not establish publication guarantees for NFS output bundles.
Working tree based on commit `8eecbd1`.

```bash
GAP=/home5/Brian/bin/gap-4.13.0/gap MEM=1g OUT=/tmp/rrm-issue15-parallel \
  /bin/bash tests/test_generate_rrm_parallel.sh
GAP=/home5/Brian/bin/gap-4.13.0/gap MEM=1g OUT=/tmp/rrm-issue15-fast \
  /bin/bash tests/test_generate_rrm_v11_fast.sh
bash -n generate_rrm_v11_parallel.sh tests/test_generate_rrm_parallel.sh
git diff --check
```

The parallel suite runs `tests/test_parallel_publication.py`, which uses fake GAP
processes and I/O wrappers to exercise the complete driver. It covers historical
second-rename failure, first publication and replacement failures, manifest and
concatenation failures, missing shards, master/worker failure, count mismatch,
zero TS, pinned readers spanning repeated publications, retained shards,
INT/TERM during master/worker startup and PID registration, signals immediately
before/after the publication rename, and writer locking. Real GAP checks compare
sequential and parallel outputs and verify fail-closed Pechukas handling.

Raw test logs: `/tmp/rrm-issue15-parallel.log` and
`/tmp/rrm-issue15-fast.log` (not version controlled).

## Results

- Parallel suite: PASS, including all 11 publication regression tests.
- Au5Ag: parallel bundles with retained/default-deleted shards are byte-identical
  to the single-worker output; the single-worker driver matches the fast GAP API.
- Original v11 vs fast v11: PASS, vertex and edge files byte-identical on Au5Ag;
  the EQ-degree checker passes, and missing vertex lookup exits nonzero.
- AuCu4: parallel master exits nonzero on a Pechukas violation with no `current`.
- Shell syntax and whitespace checks: PASS.

An initial test run hit the harness's 15-second timeout while seeding an ordinary
successful generation, before signal injection. The harness now allows 60 seconds
and kills its entire process group on timeout; its artifacts use local `/tmp`.
The complete suite then passed. The frozen legacy reproduction also explicitly
bypasses shell startup customization so its injected `mv` is selected reliably.
