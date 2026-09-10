# Issue #16: ordered parallel vertex correspondence

Issue: https://github.com/mochimochi-brian/reproduce_rrm/issues/16
Parent: https://github.com/mochimochi-brian/reproduce_rrm/issues/14
Contract: [parallel vertex map, version 1](../specs/parallel-vertex-map.md)

## Implementation

Master and worker GAP functions now emit a label-independent correspondence
table from their actual transversal/index record. Each row binds the vertex ID
to its internal EQ, original EQ, inversion flag, and canonical permutation point
images. The writer verifies that its hash index resolves that same ID. Python
validates each table and hashes its exact ordered bytes with SHA-256.

The driver rejects missing, malformed, duplicate or mismatched metadata before
publication. It validates the master before starting workers, including TS=0,
and all workers before concatenation. The manifest records the validated digest
and format, and the master table is retained. Worker tables follow
`RRM_KEEP_SHARDS`; temporary cleanup occurs after the atomic publication so
failed preparations retain diagnostics. See the contract for the publication
boundary and guarantee limits.

## Environment and source

2026-09-10, qc4; GAP 4.13.0 (`/home5/Brian/bin/gap-4.13.0/gap`), Python 3.11.3,
`MEM=1g`. Source checkout is on NFS; test and measurement outputs are on local
XFS under `/tmp/rrm-issue16`. These results do not establish NFS publication
semantics. Branch: `codex/issue-16-vertex-map`, based on `57b8148` (Issue #15).

Implementation source SHA-256 values, identifying the tested working-tree files:

```text
8de0e02f1c7a82be64a2a36a5de3ac56b4523363dd3f621101748639a8fa6278  generate_rrm_v11_fast.g
c22224549d3f983ad3cb5597ddf036c548a4d784429bdb90d8ab6875d35cb93a  generate_rrm_v11_parallel.sh
ef1000dc1ffba7acf63467643b15d9a18c35d7c8f6227d46c4eba0e8dc44315f  check_rrm_vertex_map.py
```

## Verification

Commands, with logs in the corresponding `/tmp/rrm-issue16/*.log` files:

```bash
GAP=/home5/Brian/bin/gap-4.13.0/gap MEM=1g OUT=/tmp/rrm-issue16/parallel \
  /bin/bash tests/test_generate_rrm_parallel.sh
GAP=/home5/Brian/bin/gap-4.13.0/gap MEM=1g OUT=/tmp/rrm-issue16/fast \
  /bin/bash tests/test_generate_rrm_v11_fast.sh
python3 tests/test_parallel_publication.py \
  PublicationTests.test_vertex_map_failures_preserve_published_pair \
  PublicationTests.test_failures_preserve_old_pair_and_first_run_has_no_reference
bash -n generate_rrm_v11_parallel.sh tests/test_generate_rrm_parallel.sh
git diff --check
```

- Parallel suite: PASS, including 13 publication tests and 4 contract/real-GAP
  tests. The final focused run also passed after adding a master-table rename
  failure case and improving missing-count diagnostics.
- A real worker swaps its first two representatives and rebuilds the hash index
  to match. It still reports the same vertex count, but the driver rejects the
  SHA-256 mismatch. Both first publication and replacement of an existing
  generation are covered; old vertex/edge bytes and the reference are preserved.
- Fake GAP metadata cases cover master/worker absence, malformed permutations,
  truncation, count mismatch, duplicate/missing/invalid count records, and a
  worker digest mismatch. Failure on the master-table rename also preserves the
  old pair. Failed concatenation retains worker tables for diagnosis.
- Small real GAP fixtures cover multiple EQs, inversion copies, label on/off,
  degree-zero identity permutations, TS=0, and requested workers above TS count.
  Label settings produce byte-identical correspondence tables; parallel output
  matches sequential output for the boundary fixtures.
- Au5Ag fast sequential, driver with 1 worker, and bundles with 2 and 3 workers
  have byte-identical vertices and edges. The original v11/fast comparison and
  EQ-degree checks pass. Parallel AuCu4 still refuses publication on Pechukas
  failure. Existing signal, lock, failed-write and pinned-reader tests pass.
- Shell syntax and whitespace checks: PASS.

## Measured overhead

Three paired trials per worker count ran the `57b8148` driver/GAP sources from
`/tmp/rrm-issue16/baseline` and the updated implementation, with the same Au5Ag
input, GAP executable, memory setting, and local output filesystem. Each run
used a fresh bundle; all measured vertex/edge outputs were compared bytewise
with the baseline. Trials alternated before/after for K=2, then K=3. CPU/cache
state was not isolated. The final missing-count diagnostic change does not
alter these successful-run validation steps.

Timing wrapper (each variant and trial has its own output/log/time path):

```bash
/usr/bin/time -f '%e %M' -o /tmp/rrm-issue16/measure-VARIANT-K-TRIAL.time \
  env GAP=/home5/Brian/bin/gap-4.13.0/gap MEM=1g GAP_WORKERS=K \
  /bin/bash DRIVER --bundle /tmp/rrm-issue16/measure-VARIANT-K-TRIAL \
  /home5/Brian/code/Repos/reproduce_rrm/data/Au5Ag_AFIR.g
```

| Workers | Before seconds (3 trials) | After seconds (3 trials) | Median change | Before max RSS median, KiB | After max RSS median, KiB |
|---|---|---|---|---|---|
| 2 | 3.25, 3.18, 3.13 | 3.38, 3.41, 3.34 | 3.18 → 3.38 (+6.3%) | 522244 | 525332 |
| 3 | 3.16, 3.30, 3.16 | 3.50, 3.55, 3.44 | 3.16 → 3.50 (+10.8%) | 523008 | 525360 |

GNU time's maximum RSS reports the maximum individual-process high-water mark
in the command/children accounting; it is **not** summed simultaneous worker
memory. The observed changes are approximately 3.0 MiB and 2.3 MiB respectively.
They include GAP allocation effects, not just the streaming validator's buffers.

Au5Ag has 1704 vertices, 17 internal EQs, and 86 TS entries. Each correspondence
table is 39,921 bytes. With K=2, added table writes and validation reads are each
119,763 bytes per run; with K=3, each is 159,684 bytes. Default retained disk
growth is one 39,921-byte master table plus small manifest fields; retaining
shards also retains K worker tables. Filesystem metadata, caching and physical
disk traffic are not measured by these logical byte counts.

These small-input measurements establish the cost of this implementation on
Au5Ag. Larger-scale performance work remains under Issue #18. The verification
establishes vertex correspondence subject to SHA-256 collision resistance, not
physical input validity or full TS-semantic equivalence.
