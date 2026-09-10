# Parallel vertex correspondence, version 1

Issue: https://github.com/mochimochi-brian/reproduce_rrm/issues/16
Parent: https://github.com/mochimochi-brian/reproduce_rrm/issues/14

## Contract and integration

The master and each active worker serialize the ordered correspondence from
the same `built` record used for their vertices/edges. They also check that the
hash lookup returns the serialized vertex ID. No second transversal is built.
Each validated worker table must have the master's count and SHA-256 digest
before concatenation or `rrm_publish_pair`. SHA-256 covers every byte, including
the header, row ordering, and completion record. Counts alone are insufficient.

This detects equal-size numbering permutations without changing the current
enumeration or requiring workers to deserialize a master table. The guarantee
assumes SHA-256 collision resistance and unmodified input/output during a run.
It does not prove full TS/input equivalence, physical validity, or a graph's
equivalence to another algorithm. The original canonical representative is
serialized, not its inverse used in display labels.

`generate_rrm_vertices` and `generate_rrm_edge_shard` keep their arguments and
return values and additionally write `<output-path>.vertex-map`. Labels do not
affect these files. `generate_rrm` and the `GAP_WORKERS=1` driver path do not
create correspondence tables or invoke the validator.

## Exact byte format

All records are ASCII, separated by LF, with exactly one final LF and no blank
lines, CR, spaces, BOM, or trailing data. Fields are separated by single tabs.
Integers are unsigned decimal with no leading zeroes except the value `0`.
Indices below are 1-based, as in the internal GAP lists.

Header (five fields):

```text
RRM_VERTEX_MAP<TAB>1<TAB>NVERT<TAB>NEQ<TAB>DEGREE<LF>
```

`NEQ = Length(ur)`; `DEGREE = LargestMovedPoint(sym)`, including fixed points
below that maximum and equal to zero for the trivial group. `NVERT` must match
the unique `RRM_NVERT` log record, be at least `NEQ`, and be zero if `NEQ=0`.

One row for each vertex, in increasing ID order (four plus DEGREE fields):

```text
ID<TAB>EQ<TAB>ORIGINAL_EQ<TAB>INVERTED<TAB>1^canon<TAB>...<TAB>DEGREE^canon<LF>
```

`ID = built.offset[EQ] + position` and `canon` is
`CanonicalRightCosetElement(ur[EQ], built.rt[EQ][position])`.
`ORIGINAL_EQ = org_eq[EQ]`, in `1..EQ`; `INVERTED` is 0 when
`ORIGINAL_EQ=EQ`, and 1 otherwise. Internal EQ numbers distinguish inversion
copies even when original EQ numbers coincide. Each EQ block is nonempty;
blocks occur consecutively from 1 through NEQ, with a consistent original EQ
and inversion flag within each block. Point images must be a permutation of
`1..DEGREE`. For degree zero, rows contain exactly four fields.

Completion record (two fields):

```text
END<TAB>NVERT<LF>
```

## Validation and publication

`python3 check_rrm_vertex_map.py NVERT PATH [--expected-sha256 DIGEST]` validates
the format and prints a lowercase SHA-256 on success. It exits nonzero with a
path-specific diagnostic for missing/unreadable files, malformed or truncated
records, count mismatch, or digest mismatch. It reads one row at a time and
keeps O(DEGREE) data, not the full map. Python 3.9+ is required; no packages are
needed beyond its standard library.

The driver requires exactly one canonical nonnegative integer `RRM_NVERT` from
each GAP process, and exactly one `RRM_NTS` from the master. It validates the
master before starting workers. For TS=0, it still validates the master, then
publishes an empty edge file with zero active workers. Requested worker counts
above the TS count are capped at that count.

The retained master table is `vertices.dat.vertex-map`. The existing manifest
format 1 gains `vertex_map_format=1` and `vertex_map_sha256=<digest>` before its
existing two data-file checksum lines. Older manifests lack this guarantee.
Tables are never derived by parsing the DOT-like vertex display file.

Failures before the `current` rename retain available diagnostic tables/logs
and preserve the old published generation (or leave no `current` on the first
run). The master table may retain its staging name if preparation failed early.
After successful publication, worker tables and numeric edge shards are removed
unless `RRM_KEEP_SHARDS=1/true/TRUE`; master tables and logs remain. Cleanup failure
or interruption after the rename can leave these temporary files and return
nonzero even though the complete validated generation has been published.

## Cost

Each of the master and K active workers makes an additional pass over N vertices
to canonicalize, check the lookup, and write D point images per vertex. Beyond
these group operations, serialization and validation cost O((K+1)ND) work and
O((K+1)ND log D) bytes for typical integer widths, plus ID/EQ fields. Each table
is written once and read once; only the master table is retained by default.
Peak additional serialization/validation memory is O(D) per process. Existing
transversal/index memory remains unchanged. See the Issue #16 result document
for measured overhead on Au5Ag; it is not a large-map scaling benchmark.
