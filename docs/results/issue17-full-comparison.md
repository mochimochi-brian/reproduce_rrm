# Issue #17: full labeled-graph comparison with `generate_rrm_v11.g`

Issue: https://github.com/mochimochi-brian/reproduce_rrm/issues/17
Parent: https://github.com/mochimochi-brian/reproduce_rrm/issues/14

## What was added

* `tests/compare_rrm_dat.py` — labeled-graph comparison of two dat pairs.
  `exact` compares every field in file order (the `cmp` contract, with a
  diagnostic). `normalized` drops the order requirement and identifies vertices
  by (EQ label, permutation) and edges by (TS label, permutation, endpoint
  pair), preserving self-loops and multiplicities. `structure` ignores labels
  and compares vertex ids, clusters and endpoints, which is how a labels-off run
  is checked against the labeled run that carries the meaning of those ids.
* `tests/mutate_rrm_dat.py` — the mutations a full comparison must catch.
* `tests/fixtures/small_labels.g` — 15 vertices, 30 edges, `S_3`: self-loops, a
  same-EQ TS with multiplicity 2, parallel edges from two TS numbers, an
  inversion-isomer EQ (`1*`) and TS (`2*`), three EQs. Every `urt` is trivial,
  so the input violates no Pechukas condition and the default fail-closed policy
  is exercised on a clean input.
* `tests/fixtures/zero_ts.g` — one EQ, no transition states.
* `tests/test_compare_rrm_dat.py` — 16 unit tests for the comparison itself.
* `tests/test_rrm_full_comparison.sh` — the integration comparison.
* README section "Equivalence with the reference implementation", and a
  docstring note in `check_number_of_edges_dat.py`.

## Environment and source

2026-09-10, qc4 (Ubuntu 24.04, glibc 2.39). GAP 4.13.0
(`/home5/Brian/bin/gap-4.13.0/gap`), Python 3.11.3, `MEM=2g`. The source
checkout is on NFS; test outputs are on local storage under `/tmp/rrm-issue17`.
Branch `claude/issue-17-be95bd`, based on `ced849a` (merge of issue #16).

Tested working-tree files:

```text
a61bf68fd8253306561c283559dc2c484ec27ee76c6e6770301eba0eda7f10d5  generate_rrm_v11.g
8de0e02f1c7a82be64a2a36a5de3ac56b4523363dd3f621101748639a8fa6278  generate_rrm_v11_fast.g
c22224549d3f983ad3cb5597ddf036c548a4d784429bdb90d8ab6875d35cb93a  generate_rrm_v11_parallel.sh
1b40a8f004e807f4c04c91eb97536c839b70527c2afc4710ac7a4a8a19f3efed  check_number_of_edges_dat.py
67a6db1e38881f6fcfd641e9c969c9e35b5a6addedd039679ad731ced8ac0aca  tests/compare_rrm_dat.py
2c86fe7774604ba99824d1e9d623a601caef5c8bd6e5269d318b942bffd93c88  tests/mutate_rrm_dat.py
28b61ac298829497aec0f730613272441a5aeb49437ac991a3111c7b17c30f24  tests/test_rrm_full_comparison.sh
1e1ba8c550444d9984ae8647756f9e656cd877f83b9ed04d44b3353dc7e5a5cc  tests/test_compare_rrm_dat.py
c1fbd4ff310c640029fc797d914c5697ca5a3e69fa0ac33a93cb0c1fef301872  tests/fixtures/small_labels.g
24a8224996095802f9e47deab5b1380eeb7b9010756cb907dce13e12e05f4e9f  tests/fixtures/zero_ts.g
```

`generate_rrm_v11.g`, `generate_rrm_v11_fast.g`, `generate_rrm_v11_parallel.sh`
and `check_rrm_vertex_map.py` are unchanged by this work; only the docstring of
`check_number_of_edges_dat.py` and the README changed outside `tests/`.

## Commands

```bash
export GAP=/home5/Brian/bin/gap-4.13.0/gap MEM=2g
L=/tmp/rrm-issue17/verified
OUT=$L/full     /bin/bash tests/test_rrm_full_comparison.sh
OUT=$L/fast     /bin/bash tests/test_generate_rrm_v11_fast.sh
OUT=$L/parallel /bin/bash tests/test_generate_rrm_parallel.sh
OUT=$L/pechukas /bin/bash tests/test_pechukas_policy.sh
OUT=$L/dat      /bin/bash tests/test_check_number_of_edges_dat.sh
python3 tests/test_compare_rrm_dat.py
bash -n tests/test_rrm_full_comparison.sh
```

## Results

All seven runs PASS. `tests/test_rrm_full_comparison.sh` reports 57 individual
checks.

* `tests/test_rrm_full_comparison.sh`
  * **Au5Ag**: `generate_rrm_v11.g`, `generate_rrm_v11_fast.g` and the driver at
    `GAP_WORKERS=1,2,3` produce byte-identical vertex and edge files. Degree
    check passes.
  * **AuCu4, continue mode**: with `RRM_CONTINUE_ON_PECHUKAS=1`, the fast script
    and the driver at `GAP_WORKERS=1,2,3` are byte-identical to `v11`, which
    reports the two violations (TS8, TS16) and continues.
  * **AuCu4, default policy**: sequential GAP exits 1 and writes no dat files;
    the driver exits 1 and creates no `current` reference. This is the stated
    exception to the equivalence claim, verified here and, in more detail, in
    `tests/test_pechukas_policy.sh` and `tests/test_generate_rrm_parallel.sh`.
  * **Label settings**: all seven ways of passing labels to `generate_rrm`
    (omitted, `true`, `false`, and the four two-argument combinations) agree
    byte for byte between `v11` and the fast script, and the omitted and
    single-argument forms match their documented defaults. The driver only ever
    requests labeled output, so the four `vlabel`/`elabel` combinations are also
    compared through the GAP entry points the driver calls
    (`generate_rrm_vertices` and two `generate_rrm_edge_shard` slices
    concatenated in TS-index order); each matches `v11` byte for byte.
  * **Labels off**: the `false,false` output equals the `true,true` output with
    the labels removed (`--mode structure`), so the vertex ids in the unlabeled
    files keep the meaning recorded by the labeled run. `--mode normalized
    --key label` refuses unlabeled input rather than inventing a key; the
    unlabeled pair is compared on its id contract.
  * **Worker counts**: 1, 2, 3, 5 (equal to the TS count) and 8 (above it) all
    match `v11` byte for byte and under the normalized comparison. `TS=0`
    matches at `GAP_WORKERS=1,2,3`, with an empty edge file.
  * **Order**: reversing the edge file breaks `cmp` and passes the normalized
    comparison, which is the intended split between the two.
  * **Mutation detection on real output**: a degree-preserving endpoint swap, a
    changed TS number and a changed edge permutation all still pass
    `check_number_of_edges_dat.py`, and all three are rejected by the full
    comparison. A dropped edge, a duplicated edge and an opened self-loop are
    also rejected.
* `tests/test_compare_rrm_dat.py`: 16 tests. K3,3 and the triangular prism, both
  3-regular on six vertices of one EQ, pass the degree check and are rejected by
  the comparison. Renumbered vertex ids and reordered edges are accepted only by
  the normalized mode. Malformed input and an edge endpoint with no vertex exit
  2 rather than reporting equality.
* `tests/test_generate_rrm_v11_fast.sh`, `tests/test_generate_rrm_parallel.sh`
  (13 publication tests and 4 correspondence tests included),
  `tests/test_pechukas_policy.sh`, `tests/test_check_number_of_edges_dat.sh`:
  PASS, unchanged by this work.

## Not executed, and why

* **GAP 4.11.1.** The README lists 4.11 as a tested version. The 4.11.1 build
  available here (`/home5/Brian/bin/gap-4.11.1/gap`) was built for the qc3
  cluster nodes and fails to start on qc4 with
  `error while loading shared libraries: libreadline.so.6`. Everything above is
  GAP 4.13.0 only. Re-running `tests/test_rrm_full_comparison.sh` on a host with
  a working 4.11 would close this.
* **Scale.** The comparison uses Au5Ag, AuCu4 and small fixtures. Wall-clock and
  memory at larger sizes are issue #18, not this issue.
* **Network filesystems.** Bundle publication was exercised on local storage.
  NFS and distributed-filesystem rename/lock semantics remain unverified, as
  stated in the README.
* **Physical validity.** Nothing here checks whether a GRRM input describes a
  sensible reaction network. Byte equality is equality with the reference
  implementation.

## PR #21 review corrections

The review of `5dad009` reproduced two false matches in the normalized
comparison: removing one vertex label selected id keys for both inputs, and
replacing vertex id 2 with 1 in the zero-TS output silently overwrote the id
mapping. Both returned exit status 0.

Automatic key selection now requires every vertex to be labeled if any vertex
label is present in either input. Id keys are selected automatically only when
both inputs have no vertex labels. The vertex parser also rejects duplicate
ids in every comparison mode, including for an empty edge file. These invalid
inputs return exit status 2.

Regression tests cover partial and complete label loss on either side, the
same invalid input on both sides, duplicate ids with empty edges in all three
modes, and successful automatic comparison of two unlabeled inputs. The new
tests failed before the fix; all 19 unit tests pass after it.

Validation commands on qc4 (GAP 4.13.0, Python 3.11.3, `MEM=2g`):

```bash
PYTHONDONTWRITEBYTECODE=1 python3 tests/test_compare_rrm_dat.py
GAP=/home5/Brian/bin/gap-4.13.0/gap MEM=2g \
  OUT=/tmp/rrm-pr21-fix-full-20260910 bash tests/test_rrm_full_comparison.sh
bash -n tests/test_rrm_full_comparison.sh
git diff --check
```

All four commands passed. The full comparison retained byte equality for the
fixtures, Au5Ag, and AuCu4 continue mode, and confirmed nonzero exit with no
publication for the default AuCu4 policy. The separate legacy fast, parallel,
Pechukas and degree-check suites were not rerun for these comparator-only
corrections; their original results are recorded above.

Corrected files verified in this run:

```text
c221aa0fbbdc39ebed42063b40b4fa292d710c859d1ea4e294a0f7f074e4ca14  tests/compare_rrm_dat.py
877b3c3f269b502763afb82da363eeab47e599161f238b0ea9d489e003a8abbe  tests/test_compare_rrm_dat.py
```
