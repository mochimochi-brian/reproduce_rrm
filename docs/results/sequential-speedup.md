# Sequential v11 speedup: validation and measurements

Measured on qc4 on 2026-09-17 against upstream commit
`d64568d003788815e6d0ce501c643c1050e3f83c`.

## Implementation

`generate_rrm_v11_fast.g` is an optional implementation of the existing
`generate_rrm` function. For each EQ, a dictionary maps its canonical right-coset
representatives to their positions in the original `RightTransversal` order.
Adding the preceding EQs' vertex counts gives the same ID as v11's
`Position(vertices, [eq, representative])`. This avoids scanning the vertex list
for every edge endpoint and every vertex written.

The same-EQ Pechukas check acts on the cached transversal and reuses one action
homomorphism per EQ. Edges are written in the original TS/transversal order
through an open stream, without keeping the complete edge list in memory.
Vertex output also uses an open stream. The API, label defaults and Pechukas
diagnostic/continuation policy follow v11. Missing vertex lookups or failures to
open output files terminate with status 1 rather than producing invalid IDs.

## Reproduction

From the repository root, with GAP 4.13.0 and Python 3.8+:

```bash
python3 tests/test_generate_rrm_v11_fast.py --gap /path/to/gap --benchmark
```

The default initial GAP workspace is `512m`; override it with `--memory`.
The runner has no third-party Python dependencies. It writes GAP scripts, logs,
dat files and `timings.json` to a new directory under `/tmp`, printed at startup.
Each GAP invocation has a 300-second timeout; a failure or timeout fails the run.

## Correctness

The supplied suite passed 72 vertex-index comparisons and 35 byte comparisons
of vertex/edge file pairs: each of these five fixtures with all seven forms of
the optional label arguments (omitted, one Boolean, or two Booleans).

| Fixture | Vertices | Edges | Coverage |
|---|---:|---:|---|
| Au5Ag | 1,704 | 10,020 | Bundled GRRM sample |
| AuCu4 | 102 | 474 | TS8 and TS16 diagnostics followed by continued output |
| Small labeled graph | 15 | 30 | Inversion labels, self-loops and multiple edges |
| Zero TS | 6 | 0 | Empty edge output |
| Synthetic S6 | 4,440 | 15,600 | Larger vertex index; synthetic, not a chemical model |

The suite also verifies that an invalid vertex lookup exits with status 1.
Every timed output below passed another byte comparison against v11.

An additional local run used `--input` for five preprocessed organic inputs:
CH4, CH5+, HCOOH, C3NH and a saved n-butane dataset. All seven label forms matched
for each input, bringing the correctness run to **70 file pairs / 140 files**.
CH5+ emitted the same Pechukas diagnostic and continued in both implementations,
without a continuation flag. Agreement with v11 on a flagged input does not
establish the physical validity of its map. These additional organic inputs are
not distributed in this PR; their source and preprocessing are recorded in the
[development fork's report](https://github.com/mochimochi-brian/reproduce_rrm/blob/55d8cc6/docs/results/organic-v11-byte-comparison.md).

## Performance

Environment: AMD EPYC 9654 (96 available CPUs; one GAP process at a time),
Linux 6.8.0-139-generic, GAP 4.13.0, Python 3.11.3. Source on NFS; outputs on
local XFS under `/tmp`. Both labels enabled, GAP `-T -b -q -r -m 512m`.
Three fresh processes per implementation and input, with alternating order.
Wall time includes process startup, input loading, generation and exit, measured
by Python's monotonic `perf_counter`. Preprocessing and post-run comparisons are
outside the timed interval. Measurements follow the correctness suite, so this
is a warm-cache comparison.

| Input | v11 wall times (s) | Fast wall times (s) | Median v11 / fast (s) | Speedup |
|---|---|---|---|---:|
| Au5Ag | 4.424, 4.475, 4.474 | 1.618, 1.618, 1.618 | 4.474 / 1.618 | 2.77x |
| Synthetic S6 | 2.770, 2.720, 2.720 | 1.367, 1.367, 1.367 | 2.720 / 1.367 | 1.99x |

These are measurements for these inputs and this environment, not a scaling
guarantee. Peak memory was not measured in this extraction.

SHA-256 of the measured scripts:

```text
a61bf68fd8253306561c283559dc2c484ec27ee76c6e6770301eba0eda7f10d5  generate_rrm_v11.g
1abdfabe2c21faca76d55e022cd1d63db041c22e6280402556a4a87a2b294265  generate_rrm_v11_fast.g
```

Raw logs, outputs and timings on qc4: `/tmp/rrm-sequential-test-fo72id8s/`.
