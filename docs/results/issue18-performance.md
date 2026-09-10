# Issue #18: wall time and peak memory of the fast sequential script and the parallel driver

Issue: https://github.com/mochimochi-brian/reproduce_rrm/issues/18
Parent: https://github.com/mochimochi-brian/reproduce_rrm/issues/14

The record in PR #11 (Au5Ag, v11 3268 ms vs fast 262 ms, about 12.5x) is a GAP
internal timing of one run, not an end-to-end measurement, and it says nothing
about memory or about the parallel driver. This is the re-measurement: four
inputs, five configurations, three repetitions each (one for `v11` on the
largest input, at 158 s a run), with the sequential speedup and the additional
effect of `GAP_WORKERS>1` reported separately.

## What was added

* `tools/rrm_bench.py` — the measurement harness. Runs `generate_rrm_v11.g`
  (`v11`), `generate_rrm_v11_fast.g` (`fast`) and
  `generate_rrm_v11_parallel.sh` with `GAP_WORKERS=k` (`par:k`) on one input,
  repeats each configuration, and reports wall time, CPU time, three distinct
  peak-memory figures, a per-process breakdown (master, each worker), the
  planned per-worker TS slice and edge load, output line counts, byte sizes and
  SHA-256, and a byte comparison of every produced map against a reference
  configuration. Writes JSON plus a Markdown table.
* `tools/rrm_input_stats.g` — exact structural size of an input without
  producing it: `Index(sym, ur[i])` vertices per EQ and `Index(sym, urt[i])`
  edges per TS, i.e. the per-TS expansion the parallel driver's TS-count split
  does not balance.
* `tools/make_synthetic_input.py` and `data/bench/*.g` — reproducible synthetic
  inputs, used because no larger real GRRM catalogue is bundled with the repo.
* `tools/bench_campaign.sh` — the exact campaign that produced the numbers
  below.
* `tests/test_rrm_bench.sh` — tests for the harness itself on the small
  fixtures: structural counts must match the produced files, the byte
  comparison must fire, the three memory figures must stay distinct, a timeout
  must be reported instead of a speedup, an `--outdir` inside the repository
  must be refused, and synthetic generation must be deterministic and free of
  Pechukas violations.
* `generate_rrm_v11_parallel.sh` — one addition: the internal flag
  `--ts-slice W K NTS`, alongside the existing `--active-workers` /
  `--gap-string` / `--assert-nvert` flags, so that the harness reports the
  per-worker load from the driver's own slicing code instead of a copy of it.
  Asserted in `tests/test_generate_rrm_parallel.sh`. No production path
  changed.

`generate_rrm_v11.g`, `generate_rrm_v11_fast.g` and the producing paths of
`generate_rrm_v11_parallel.sh` are unchanged, and no new speedup was added:
this issue measures, it does not optimize.

## Environment and source

2026-09-10, Claude Code remote container (not `qc-cluster`): Linux
6.18.44-fc-v24 x86_64, Intel Xeon @ 2.80 GHz, 4 CPUs, 16.5 GB RAM (`MemTotal`
16461028 kB), no swap. GAP 4.12.1 (Ubuntu `gap-core` 4.12.1-2build2, build
2024-03-31), Python 3.11.15, GNU coreutils, ext4 on local storage.
Branch `claude/issue-18-jmmn42`, based on `79a63f0`, which already carries the
correctness work of issues #15 (atomic pair publication), #16 (vertex
correspondence) and #17 (full labeled-graph comparison) — that is the
"measure on a commit whose correctness fixes and integration checks are done"
condition of this issue. The environment caveat below is separate and still
applies.

Raw GAP output (dat files, worker logs, bundles, manifests): `/var/tmp/rrm-bench`
on that container, which is outside the repository and not under git —
`tools/rrm_bench.py` refuses an `--outdir` inside the working tree. That raw
output is not preserved beyond the container; its digests and sizes are
recorded per run in the committed reports.

The harness's own reports *are* committed, in
[`docs/results/data/issue18/`](data/issue18/): one JSON and one Markdown
fragment per input, holding every repetition, the per-process breakdown, the
planned per-worker load, the per-TS expansion list and the SHA-256 of every
produced file. The tables below are read off those files.

Measured working-tree files:

```text
a61bf68fd8253306561c283559dc2c484ec27ee76c6e6770301eba0eda7f10d5  generate_rrm_v11.g
8de0e02f1c7a82be64a2a36a5de3ac56b4523363dd3f621101748639a8fa6278  generate_rrm_v11_fast.g
abec0fc716ad3ddb98062357b8c1268aea217a59143a878e8d272e0a2c3fd8b6  generate_rrm_v11_parallel.sh
d8a86b4ff78f5736e1b2dfbc88ac58bb9883e49ce81e0d20230f61fde3f3a174  tools/rrm_bench.py
8d282f55d21f0051e9edb3a258bd9f4de725ed24ecbf209dbe1963af2b578abd  tools/rrm_input_stats.g
58703529ab150f279b7f229a1ad6cf323b45c8c8859e8235460268d0f9b0b64d  tools/make_synthetic_input.py
78c23273b5b55fe7a3845a25314c959cfdb0d4a24431e3927305fddcaf75983c  tools/bench_campaign.sh
532c41c785b4d07116eb72e6ae8f4db5a3577cb0ba28b30fca999eb4ff997d0e  tests/test_rrm_bench.sh
6c1a40b4c992b2e527bdc7aba753de7e8ca57ea170fdb65b8c04480e0114a632  data/bench/synth_n6_eq8_ts30.g
9cef7594f04ec96800fe47f92e34478c065ef7daebadc9357f658b9714559a76  data/bench/synth_n7_eq10_ts40.g
9feda9cc1715fe1779a62764b534f41b05a1f728a2d485ff2cb6acdd7c019834  data/bench/synth_n7_eq4_ts200_edge.g
```

**This is not the adoption measurement for `qc-cluster`.** Four cores, GAP
4.12.1 and a container filesystem are not the production environment, and the
absolute numbers do not transfer. What does transfer is the method, the
harness, and the structure of the result (where time goes, and how the three
memory figures differ). Re-run `tools/bench_campaign.sh` on `qc-cluster` with
GAP 4.13.0 before deciding what the demo should call.

## Commands

The campaign, and the suites re-run to check that nothing else moved (all
passed on this branch; `MEM=1g` only to keep the container's startup cost down,
GNU `/usr/bin/time`, from the `time` package, is needed by the fast suite):

```bash
OUT=/var/tmp/rrm-bench ./tools/bench_campaign.sh       # the numbers below
./tests/test_rrm_bench.sh                              # the harness itself
MEM=1g ./tests/test_generate_rrm_parallel.sh           # driver, incl. --ts-slice
MEM=1g ./tests/test_generate_rrm_v11_fast.sh
MEM=1g ./tests/test_pechukas_policy.sh
MEM=1g ./tests/test_rrm_full_comparison.sh
./tests/test_check_number_of_edges_dat.sh
python3 tests/test_compare_rrm_dat.py                  # 19 unit tests
```

A single input, measured directly:

```bash
python3 tools/rrm_bench.py --label Au5Ag --gfile data/Au5Ag_AFIR.g \
    --config v11 --config fast --config par:1 --config par:2 --config par:4 \
    --reps 3 --mem 2g --outdir /var/tmp/rrm-bench --deep-compare \
    --json /var/tmp/rrm-bench/Au5Ag.json --markdown -
```

## Method

**Configurations.** `v11` and `fast` are one GAP process each, started by the
harness with the same `-m` and the same `vlabel`/`elabel` (both true).
`par:1` is the driver's sequential path, which calls the same `generate_rrm` in
`generate_rrm_v11_fast.g` and writes `VFILE`/`EFILE` directly; the difference
between `fast` and `par:1` is the driver's own overhead. `par:k>1` is the
bundle path: a master GAP process (vertex enumeration, Pechukas check, vertex
file, vertex map), *k* worker GAP processes each writing a contiguous TS slice
of edges, then shard concatenation, vertex-map validation, manifest and the
`current` symlink switch.

**Wall time** is the lifetime of the launched command, measured with
`time.monotonic()`. It contains everything a user waits for: GAP startup (which
depends on `-m`), reading the `.g` input, the group theory, the writes and, for
`par:k>1`, concatenation and publication.

**GAP internal CPU time** is reported two ways, and they are not the same
quantity:

* Process CPU time (`cpu_total_s`) is `ru_utime + ru_stime` from `os.wait4()`
  for the launched process and every descendant it reaped — for the driver this
  is master plus all workers plus the shell and the Python validators. It
  includes GAP's startup and parsing.
* GAP's own clock (`gap_read_ms`, `gap_generate_ms`) comes from `Runtime()`
  called around `Read` and around `generate_rrm` inside the GAP input the
  harness writes. It is available for `v11` and `fast` only; the driver writes
  its own GAP input, which this work deliberately did not modify. The
  difference between `gap_generate_ms` and the wall time of the same run is the
  fixed cost (startup, parse, exit) that no algorithmic change removes.

**Peak memory** is three separate numbers, never mixed:

| figure | meaning | how obtained |
|---|---|---|
| max single peak RSS | the largest peak reached by any one process | exact: `ru_maxrss` from `os.wait4()`, the maximum over the child and its reaped descendants |
| sum of peaks | Σ over processes of that process's own peak (`VmHWM`) | sampled; over-counts the group, because peaks need not coincide |
| concurrent peak RSS | the largest sum of *simultaneously* resident RSS over all live processes | sampled; this is what a whole-job memory limit must accommodate |

The two sampled figures come from a thread that walks `/proc` every 20 ms for
processes in the child's process group (the child is started in a new session)
and are therefore lower bounds: a peak reached between two samples is missed.
The harness also reports the sampler's own version of the single-process peak,
so the gap against the exact `ru_maxrss` measures what the sampling loses; the
worst gap in this campaign was 0.8% (Au5Ag, `MEM=512m`, `par:2`). For a `par:4` run the
single-process peak understates the job by about a factor of four while the sum
of peaks overstates the simultaneous requirement by roughly 30%, so a report
that gives only one number is not usable for sizing a job.

**Per-phase and per-worker attribution.** Each GAP process in a parallel run is
identified by the target of its `/proc/<pid>/fd/1`: the driver points the
master at `vertices.dat.master.log` and worker *w* at
`edges.dat.part.<w>.log`. Per-process wall time is first-seen to last-seen in
the samples (short by up to one interval at each end), per-process CPU is
`utime + stime` at the last sample. `driver_overhead_wall_s` is the run's wall
time minus (master wall + longest worker wall): shell startup, locking,
concatenation, vertex-map validation, manifest, publication.

**Load.** `tools/rrm_input_stats.g` gives the exact per-TS edge count
`Index(sym, urt[i])`. The harness asks the driver itself
(`--active-workers`, `--ts-slice`) which TSs each worker gets and sums those
counts, so the planned per-worker edge load is reported without duplicating the
driver's slicing rule.

**Repetitions.** Three runs per configuration; the tables give the median, the
min–max range and the sample standard deviation. Runs are strictly sequential —
never two benchmarks at once. The widest spread in the campaign is Au5Ag
`v11`, whose first repetition took 7.19 s against 6.14 s for the second; that
is why the tables give a median and a range rather than a single number.

**Output equality.** Every run's published `vertices.dat`/`edges.dat` is
compared byte for byte (`cmp`) against the reference configuration's output,
and with `tests/compare_rrm_dat.py --mode exact`. A configuration whose output
differs makes the harness exit 2. This is the same contract as issue #17, now
also checked on the synthetic inputs.

**Limits.** A run that exceeds `--timeout` is killed (process group, `SIGTERM`
then `SIGKILL`), recorded as `timed_out`, excluded from every median and every
ratio, and not repeated. The Markdown table prints `n/a (timeout)` for it.

## Inputs

| label | provenance | \|sym\| | EQs | TSs | vertices | edges | vertices.dat / edges.dat | edges per vertex | per-TS expansion |
|---|---|---|---|---|---|---|---|---|---|
| Au5Ag | bundled GRRM output, `data/Au5Ag_AFIR.g` | 120 | 17 | 86 | 1704 | 10020 | 45 kB / 310 kB | 5.9 | 120 or 60 |
| synth-medium | synthetic, `data/bench/synth_n6_eq8_ts30.g` | 720 | 8 | 30 | 4440 | 15600 | 125 kB / 532 kB | 3.5 | 720 or 120 |
| synth-large | synthetic, `data/bench/synth_n7_eq10_ts40.g` | 5040 | 10 | 40 | 41160 | 147000 | 1.3 MB / 5.7 MB | 3.6 | 5040 or 840 |
| synth-edge | synthetic, `data/bench/synth_n7_eq4_ts200_edge.g` | 5040 | 4 | 200 | 168 | 341292 | 4.7 kB / 11.8 MB | 2032 | 42 to 5040 (five distinct values) |

The three synthetic inputs are **fictitious, not GRRM outputs**, and prove
nothing about chemistry. Their generation conditions are recorded in the header
of each `.g` file and in the docstring of `tools/make_synthetic_input.py`, in
short: `sym = symc = S_n` on points `2..n+1` (an A B_n cluster's CNPI group
without the inversion extension, so `org_eq`/`org_ts` are identity maps and no
starred labels occur); EQ stabilizers from a fixed subgroup catalogue; and
`urt[i]` computed in GAP as the intersection of the four conjugates
`ur[a]^s1`, `ur[a]^(s1^-1)`, `ur[b]^s2`, `ur[b]^(s2^-1)`, which is a subgroup of
whichever conjugate each branch of the Pechukas check inspects — so no
generated input violates Pechukas's theorem and all three producers run to
completion. Every third TS is a *light* TS with both endpoints on the
large-stabilizer EQ and identity permutations, which is the documented source
of the per-TS expansion skew. Regenerate byte-identically with the command in
each file's header and compare with `sha256sum`.

`synth-medium` and `synth-large` keep the realistic ratio of about 3–6 edges
per vertex seen in Au5Ag; `synth-edge` deliberately breaks it (few, highly
symmetric EQs, many transition states) to locate the point where splitting the
TS loop across processes can pay for the extra GAP startups. It is a stress
shape, not a plausible reaction network.

## Results

MEM=2g per GAP process, three repetitions, `vlabel = elabel = true`.
Every configuration's map was byte-identical to `v11`'s on every input
(`cmp` plus `tests/compare_rrm_dat.py --mode exact`), including the
`synth-large` run where `v11` needed 158 s.

### Au5Ag — bundled GRRM output, 1704 vertices, 10020 edges

| config | wall median (s) | min-max (s) | stdev (s) | CPU total (s) | max single peak RSS (MiB) | sum of peaks (MiB) | concurrent peak RSS (MiB) | speedup vs v11 |
|---|---|---|---|---|---|---|---|---|
| v11 | 6.58 | 6.14-7.19 | 0.53 | 6.6 | 1100 | 1099 | 1099 | 1.00x |
| fast | 1.34 | 1.31-1.37 | 0.03 | 1.3 | 478 | 477 | 477 | 4.90x |
| par:1 | 1.32 | 1.28-1.37 | 0.05 | 1.3 | 478 | 480 | 480 | 4.99x |
| par:2 | 2.59 | 2.43-2.61 | 0.10 | 3.6 | 473 | 1407 | 888 | 2.54x |
| par:4 | 2.72 | 2.68-2.79 | 0.05 | 5.8 | 473 | 2313 | 1747 | 2.42x |

### synth-medium — 4440 vertices, 15600 edges

| config | wall median (s) | min-max (s) | stdev (s) | CPU total (s) | max single peak RSS (MiB) | sum of peaks (MiB) | concurrent peak RSS (MiB) | speedup vs v11 |
|---|---|---|---|---|---|---|---|---|
| v11 | 2.95 | 2.93-2.98 | 0.02 | 3.0 | 572 | 570 | 570 | 1.00x |
| fast | 1.15 | 1.14-1.15 | 0.01 | 1.1 | 461 | 461 | 461 | 2.58x |
| par:1 | 1.14 | 1.13-1.18 | 0.03 | 1.1 | 461 | 464 | 464 | 2.60x |
| par:2 | 2.49 | 2.47-2.54 | 0.04 | 3.6 | 454 | 1405 | 902 | 1.19x |
| par:4 | 2.71 | 2.70-2.71 | 0.01 | 5.9 | 454 | 2321 | 1781 | 1.09x |

### synth-large — 41160 vertices, 147000 edges

| config | wall median (s) | min-max (s) | stdev (s) | CPU total (s) | max single peak RSS (MiB) | sum of peaks (MiB) | concurrent peak RSS (MiB) | speedup vs v11 |
|---|---|---|---|---|---|---|---|---|
| v11 | 157.63 | one run only | - | 157.6 | 1816 | 1816 | 1816 | 1.00x |
| fast | 2.94 | 2.90-3.04 | 0.07 | 2.9 | 654 | 654 | 654 | 53.59x |
| par:1 | 2.88 | 2.79-2.90 | 0.06 | 2.9 | 654 | 657 | 657 | 54.74x |
| par:2 | 6.37 | 6.16-6.37 | 0.12 | 8.9 | 610 | 1835 | 1173 | 24.76x |
| par:4 | 7.19 | 6.95-7.21 | 0.15 | 13.6 | 610 | 2919 | 2211 | 21.93x |

`v11` was given one repetition and a 3600 s limit here (`--reps-for v11=1`);
it finished in 158 s, well inside the limit, so its speedup ratios are real
measurements and not a bound. Nothing in this campaign was cut off. Had it
been, the harness would have reported `n/a (timeout)` and excluded the run from
every median and ratio.

### synth-edge — 168 vertices, 341292 edges (edge-dominated stress shape)

| config | wall median (s) | min-max (s) | stdev (s) | CPU total (s) | max single peak RSS (MiB) | sum of peaks (MiB) | concurrent peak RSS (MiB) | speedup vs v11 |
|---|---|---|---|---|---|---|---|---|
| v11 | 6.24 | 6.18-6.27 | 0.04 | 6.2 | 1207 | 1207 | 1207 | 1.00x |
| fast | 4.97 | 4.88-5.08 | 0.10 | 5.0 | 975 | 974 | 974 | 1.26x |
| par:1 | 5.03 | 5.01-5.21 | 0.11 | 5.0 | 975 | 978 | 978 | 1.24x |
| par:2 | 4.58 | 4.47-4.62 | 0.08 | 7.4 | 723 | 1926 | 1369 | 1.36x |
| par:4 | 3.72 | 3.61-3.81 | 0.10 | 9.8 | 602 | 2871 | 2260 | 1.68x |

Run-to-run spread is small (stdev under 0.15 s everywhere except Au5Ag `v11`
at 0.53 s), so the medians carry the signal. An earlier identical
campaign, run before a cosmetic fix to the harness's process labelling,
reproduced every median in these four tables to within 13% (worst case Au5Ag
`par:2`, 2.97 s against 2.59 s) and every ordering without exception. The
`MEM=12g` cells below are the noisiest in the whole campaign: there the two
campaigns differ by up to 25%, since those runs are dominated by workspace
setup rather than by RRM work.

## Where the time goes

The distinction that matters is not v11-versus-fast but *fixed cost* versus
*work that scales with the map*. Medians of three runs, MEM=2g:

| input | fast wall (s) | of which GAP `generate` (s) | fast fixed cost (s) | par:4 wall (s) | master (s) | slowest worker (s) | publication residual (s) |
|---|---|---|---|---|---|---|---|
| Au5Ag | 1.34 | 0.31 | 1.03 | 2.72 | 1.23 | 1.10 | 0.38 |
| synth-medium | 1.15 | 0.18 | 0.97 | 2.71 | 1.07 | 1.13 | 0.50 |
| synth-large | 2.94 | 1.65 | 1.30 | 7.19 | 2.26 | 2.45 | 2.37 |
| synth-edge | 4.97 | 3.46 | 1.51 | 3.72 | 1.14 | 2.25 | 0.34 |

"fast fixed cost" is wall minus GAP's own `generate_rrm` time: GAP startup with
`-m 2g`, parsing the `.g` input and exiting. It is about 1 s here and it does
not shrink with a better algorithm. "Publication residual" is the parallel
run's wall time minus (master + slowest worker): shell startup, locking, shard
concatenation, the Python vertex-map validation of *k* tables of `nvert` rows
each, the manifest and the symlink switch.

Three things follow, and they explain every row of the result tables.

1. **The master is not overhead that parallelism removes.** It does the vertex
   enumeration, the coset index build, the Pechukas check, the vertex file and
   the vertex map — on Au5Ag and synth-medium that is already as much wall time
   as the entire sequential run (1.23 s vs 1.34 s; 1.07 s vs 1.15 s). Adding
   workers cannot beat a sequential run whose whole cost the master already
   pays.
2. **Each worker rebuilds what the master built.** `generate_rrm_edge_shard`
   calls `RrmBuildTransversals` itself — by design, since the correspondence is
   then validated across processes — so the index build is paid *k+1* times, and
   each worker also pays its own GAP startup. On synth-large the workers spend
   about 2.2 s of their 2.45 s on startup plus rebuild and only the remainder on
   the shard, which is why `par:4` (7.19 s) is 2.4x *slower* than sequential
   `fast` (2.94 s) on the same input.
3. **Publication scales with vertices times workers.** 2.37 s of the
   synth-large `par:4` run is after the last worker exits: concatenating 5.7 MB
   of shards and validating four 41160-row vertex maps in Python. On synth-edge,
   with 168 vertices, the same residual is 0.34 s.

Only when the edge writes dominate everything else does the split pay:
synth-edge has 2032 edges per vertex, its master costs 1.14 s against a 4.97 s
sequential run, and `par:4` reaches 3.72 s — 1.34x faster than sequential, on
four workers, i.e. about 33% parallel efficiency.

### Load balance

The driver splits by TS *count*, and the per-TS expansion is not uniform.
Planned edge load per worker for `par:4` (from `tools/rrm_input_stats.g` and the
driver's own `--ts-slice`), against the observed spread of worker wall times:

| input | planned edges per worker | max/min planned | observed max/min worker wall |
|---|---|---|---|
| Au5Ag | 2460 / 2640 / 2400 / 2520 | 1.10 | 1.11 |
| synth-medium | 4560 / 3960 / 3840 / 3240 | 1.41 | 1.10 |
| synth-large | 37800 / 37800 / 33600 / 37800 | 1.12 | 1.10 |
| synth-edge | 80892 / 77994 / 81564 / 100842 | 1.29 | 1.13 |

The per-worker fixed cost hides the imbalance: on synth-medium a 1.41 spread in
assigned edges shows up as only 1.10 in wall time, because roughly 1 s of each
worker's time is startup and rebuild. Where edges do dominate the ratio comes
back — on synth-edge, subtracting the 1.14 s the master shows for the same
startup-plus-build leaves 1.11 s against 0.83 s of edge work, a ratio of 1.34
against 1.29 planned. So the TS-count split is a reasonable proxy while
expansions are within a factor of a few of each other; an input with one very
heavy transition state (a nearly trivial `urt[i]` among otherwise symmetric
ones) would not balance, and the per-TS table is what shows that before a run.

## Sensitivity to `MEM`

`MEM` is GAP's `-m`, the initial workspace, and it is **per process**: a
`GAP_WORKERS=k` run holds *k+1* of them, and each one pays the cost of
establishing that workspace before any RRM work starts.

Au5Ag, three repetitions per cell, `fast` and the driver:

| MEM | fast wall (s) | fast GAP `generate` (s) | par:2 wall (s) | par:4 wall (s) | fast peak RSS (MiB) | par:4 concurrent peak (MiB) | par:4 sum of peaks (MiB) |
|---|---|---|---|---|---|---|---|
| 512m | 1.17 | 0.31 | 2.36 | 2.47 | 285 | 985 | 1351 |
| 2g | 1.32 | 0.29 | 2.64 | 2.67 | 477 | 1755 | 2310 |
| 12g | 3.02 | 0.36 | 7.13 | 9.98 | 1757 | 6764 | 8712 |

The work does not change: GAP's own `generate_rrm` time stays at 0.3 s across
all three. Everything else does. Between `512m` and `12g` the sequential run
gets 2.6x slower and the `par:4` run 4.0x slower, and the memory the job needs
at one time goes from 985 MiB to 6.6 GiB — for a map whose two files are
350 kB. The `par:4` CPU total at `12g` is 29.6 s against 5.2 s at `512m`, and
almost all of that is system time spent establishing five workspaces of 12 GB
each.

Peak RSS here is therefore a measurement of `-m`, not of the map: at `12g`,
every GAP process reports about 1.75 GiB of resident memory whatever the input.
That is why the README's advice is to use the smallest `-m` that completes, and
why the `12g` in the README examples is a ceiling for large maps rather than a
default worth copying for small ones.

## What this means for the two changes

**The sequential change (`v11` -> `fast`) is the one that pays, and its size
depends on the vertex count.** `v11` finds a vertex id with
`Position(vertices, ...)`, a linear scan of the vertex list, once per edge
endpoint, and it keeps the whole edge list in memory before writing it;
`generate_rrm_v11_fast.g` looks the id up in a hash table and streams the
writes. On the GAP computation alone the ratios measured were 15.8x (Au5Ag,
1704 vertices), 10.5x (synth-medium, 4440), 93.1x (synth-large, 41160) and 1.2x
(synth-edge, 168) — the win grows with the vertex count and nearly vanishes
when there are few vertices to scan. End to end the same runs are 4.90x, 2.58x,
53.59x and 1.26x, the difference being the ~1 s of GAP startup and parsing that
the fast script cannot remove. Peak memory also improves, and for the same
reason: 1100 -> 478 MiB on Au5Ag and 1816 -> 654 MiB on synth-large, since the
edge list is no longer materialized.

PR #11's 12.5x for Au5Ag is consistent with the 15.8x measured here for the
same quantity (GAP-internal `generate_rrm` time), on a different machine and
GAP version. The end-to-end figure a user experiences on that input is 4.9x.

**The parallel driver is not a speedup on any input measured here except the
edge-dominated one, and it costs memory.** `par:1` matches `fast` to within
2%, so the driver's own overhead on the sequential path is negligible. For
`k>1` the picture is the cost model above: master plus *k* rebuilds plus
publication. Au5Ag `par:4` is 2.0x slower than `fast`, synth-large `par:4` is
2.4x slower, and only synth-edge is faster (1.34x on four workers). At the same
time the memory the job needs simultaneously grows nearly linearly in *k*
(Au5Ag at MEM=2g: 477 MiB sequential, 888 MiB at `par:2`, 1747 MiB at `par:4`).

That does not make `GAP_WORKERS>1` useless: it is what makes `--bundle`
available, and with it the atomic pair publication and the cross-process vertex
correspondence check of issues #15 and #16, which `GAP_WORKERS=1` does not
provide. It is a throughput-versus-guarantee choice, not a speed choice, unless
the map's edge expansion dwarfs its vertex count.

**Recommendation for this repository.** Prefer sequential
`generate_rrm_v11_fast.g` (or `GAP_WORKERS=1` through the driver) as the
default producer, with the smallest `-m` that completes. Use `GAP_WORKERS=k>1`
when the edge count is orders of magnitude above the vertex count, when the
bundle's publication guarantee is wanted, or when a single process cannot
finish in the time available — and measure the specific input first with
`tools/rrm_bench.py`. Two obvious ways to make the parallel path pay on
ordinary inputs would be to let workers reuse the master's index instead of
rebuilding it, and to move the vertex-map validation out of the critical path;
both are changes to the producers, which this issue deliberately did not touch.

## What is not claimed

* **Not the production environment.** 4 cores, GAP 4.12.1, container
  filesystem. Absolute times and the parallel break-even both move with the
  core count, the storage and the GAP version. Re-run the campaign on
  `qc-cluster` for an adoption decision.
* **Not a chemistry statement.** The three synthetic inputs are load models.
  Byte equality of the produced maps says the producers agree, not that any of
  these inputs describes a physically sensible network (issue #17 and the
  README's "Equivalence with the reference implementation" state that contract
  precisely).
* **No claim about maps larger than `synth-large`.** Nothing here was measured
  at the n=8 or n=9 scale of the README's "Scale of the labeled map" table; the
  cost model in this document is a description of what was measured, not an
  extrapolation to those sizes.
* **Sampled memory figures are lower bounds** at a 20 ms interval, and
  `driver_overhead_wall_s` is a residual, not an independently timed phase.
* **I/O was not isolated.** The edge writes are streamed to the local
  filesystem with the page cache warm; a slow or networked filesystem would
  change the balance, and the campaign contains no cold-cache or NFS
  measurement. What can be read off the data is the byte volume per run and the
  CPU-vs-wall gap, not a filesystem comparison.
