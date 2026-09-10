# reproduce_rrm
This project is to construct a Reaction Route Map (RRM) in the shape space (the space of molecular geometries modulo rotations and translations) from an output of Global Reaction Route Mapping (GRRM) program. GRRM finds reaction pathways but identifies CNPI (Complete Nuclear Permutation Inversion) isomers as one; this tool reconstructs the full reaction network in the shape space accounting for all permutations of identical atoms. This code also can be used to verify your GRRM outputs. For more details, refer to our paper (Hiroshi Teramoto et al., J. Chem. Theory Comput. 2023, 19, 17, 5886–5896), [Reproducing RRM on the Shape Space from its Quotient by CNPI group](https://pubs.acs.org/doi/full/10.1021/acs.jctc.3c00500) by Hiroshi Teramoto, Takuya Saito, Masamitsu Aoki, Burai Murayama, Masato Kobayashi, Takenobu Nakamura, and Tetsuya Taketsugu. Hereafter, we refer to this publication as ‘the paper.’ The appendix of the paper provides a detailed description of this code.

## To run the code, you need to install (Tested with Ubuntu 22.04.5 LTS)
* GAP - Groups, Algorithms, Programming (https://www.gap-system.org/) (Tested with GAP 4.11 (or 4.13))
* The Python script `rrm_reconstruction_v18.py` depends on the following packages:
  - pymatgen (Tested with 2024.8.9)
  - numpy (Tested with 1.26.4)
  - networkx (Tested with 3.3)
  - some features (*-operator) for Python 3.5 or later (Tested with 3.10.12).
* Graphviz (https://graphviz.org/) (Tested with 2.43.0 (0))

## To run the code, download zip file and in the directory
* Edit the script `reproduce_rrm_demo.sh`
  - The Python command supposed to be `python3`. If that is not the case, modify the command appropriately.
  - The path for GAP is supposed to be `/usr/local/gap-4.13.0/gap`. Modify the path to match your environment path. 
* Type `./reproduce_rrm_demo.sh` and press the enter key.

This command computes the RRM of Au5Ag in the shape space from the sample output files in the directory `Metal/Au5Ag` and outputs `rrm_Au5Ag_AFIR.dot` (a Graphviz DOT file) and `rrm_Au5Ag_AFIR.png` (the rendered graph image). For the detail of the Graphviz DOT format, refer to graphviz (https://graphviz.org/). If the code ran correctly, you should see the output messages like
```
Metal/Au5Ag//Au5Ag_AFIR_EQ_list.log
Metal/Au5Ag//Au5Ag_AFIR_TS_list.log
Metal/Au5Ag//Au5Ag_AFIR_TS
241 lines read
---with several warnings indicating discripancy between point-group identifications of GRRM and pymatgen)
ur computation finished!!!
urt computation finished!!!
connections computation finished!!!
output GRRM graph as a dot file!!
symc computation finished!!!
the index of symc in sym : 1
GAP computation done.
All vertices with the same number have consistent degrees.
DONE
```
the figure like: ![RRM of Au5Ag cluster](./rrm_Au5Ag_AFIR.png) Sometimes it may be too complicated to visualize the resulting RRM in shape space. In that case, you should edit the corresponding Graphviz DOT file or extract some of the characteristics to quantify some of the graph properties. The line
```
the index of symc in sym : 1
```
indicates that the resulting RRM in shape space is connected. In general, if the output contains the line,
```
the index of symc in sym : n
```
it indicates that the resulting RRM in shape space has `n` connected components (that are mutually graph-isomorphic with each other. See the paper and its supplimentary material for details.). If the latter is the case, this codes output one of the connected components.

## Constitution of the code
* Core Python script `rrm_reconstruction_v18.py` that handles parsing GRRM output and preparing data
* GAP script `generate_rrm_v11.g` that performs group-theoretic computations (original)
* Faster sequential GAP script `generate_rrm_v11_fast.g` (same `generate_rrm` API as v11: O(1) vertex index, streamed writes, fail-closed Pechukas; not a later Teramoto version)
* Optional driver `generate_rrm_v11_parallel.sh` for process-parallel edge writes (`GAP_WORKERS`, default 1). It calls entry points in `generate_rrm_v11_fast.g`; there is no second GAP algorithm file.
* Helper Python script for validation `check_number_of_edges_v3.py` (DOT; used by the demo)
* Streaming helper `check_number_of_edges_dat.py` for `vertices_*.dat` / `edges_*.dat` (same EQ-number degree check; use this for n=8+ maps that skip Graphviz)
* Shell script to tie it all together `reproduce_rrm_demo.sh`. It calls the original `generate_rrm_v11.g`, not the faster script or the parallel driver.
* Tests under `tests/`, including `tests/test_rrm_full_comparison.sh` (labeled-graph comparison of all three producers), `tests/compare_rrm_dat.py` (the comparison itself) and `tests/test_rrm_bench.sh` (the measurement tools below)
* Measurement tools under `tools/`: `tools/rrm_bench.py` (wall time, GAP CPU time and the three peak-memory figures for `v11` / `fast` / `par:k`, with a byte comparison of the produced maps), `tools/rrm_input_stats.g` (vertex, edge and per-TS expansion counts of an input), `tools/make_synthetic_input.py` (reproducible synthetic inputs, `data/bench/*.g`) and `tools/bench_campaign.sh` (the campaign behind [docs/results/issue18-performance.md](docs/results/issue18-performance.md)). None of them is needed to produce a map; see [Cost of the GAP step](#cost-of-the-gap-step-and-when-gap_workers-pays)

The intended product of the GAP step is the labeled files `vertices_*.dat` and `edges_*.dat`: each vertex is an EQ (or its inversion isomer) plus a CNPI permutation, and each edge is a TS plus a permutation. The Graphviz DOT/PNG is a convenience for small maps, not the reconstruction itself. See [Scale of the labeled map](#scale-of-the-labeled-map) for when those dat files stop being a practical artifact.

## Advanced Usage
1. Run the Python preprocessing: python3 rrm_reconstruction_v18.py <EQ_list.log> <TS_list.log> <TS_file_prefix> <output.g> – this generates a GAP script with symmetry information (stored as <output.g>).
2. Run GAP on the generated script to compute the RRM graph data: `gap -b -q -m 12g generate_rrm_v11_fast.g` (or `generate_rrm_v11.g`; use the appropriate memory flag). This will produce vertices_*.dat and edges_*.dat files. For larger maps you can instead run `GAP_WORKERS=2 ./generate_rrm_v11_parallel.sh --bundle output/MOL data/MOL_AFIR.g` (`k>1` splits TS edge writes across processes; see [Parallel output bundles](#parallel-output-bundles) for reading the result). The demo script still runs a single GAP process. After GAP, `python3 check_number_of_edges_dat.py vertices.dat edges.dat` checks that vertices with the same EQ number have the same degree; it does not need a DOT file. That check is a necessary condition only — see [Equivalence with the reference implementation](#equivalence-with-the-reference-implementation).
3. Combine the output into a Graphviz file and render it: The demo script automates this using cat and calling `dot`. If doing manually, you would take the contents of the .dat files and format them into a DOT file (see the script for the exact steps) and then run Graphviz’s `dot -Tpng` to get an image. Skip this step when the labeled graph is large; `dot` is optional and will fail or take prohibitive time well before GAP itself does. The demo still runs `check_number_of_edges_v3.py` on the DOT file.

## Equivalence with the reference implementation

`generate_rrm_v11.g` is the reference. `generate_rrm_v11_fast.g` and
`generate_rrm_v11_parallel.sh` are expected to reproduce it, and there is no
second algorithm: the driver calls entry points in `generate_rrm_v11_fast.g`.

**What is claimed.** For an input that violates no Pechukas condition, all three
produce byte-identical `vertices_*.dat` and `edges_*.dat`. The enumeration order
is part of that contract, so `cmp` is the comparison; shards are concatenated in
TS-index order. This holds for every `vlabel`/`elabel` combination and for any
`GAP_WORKERS`, including worker counts above the TS count and a zero-TS input.

**What is not claimed.**

* **Pechukas violations.** The behaviour differs by design: `generate_rrm_v11.g`
  prints and continues, `generate_rrm_v11_fast.g` exits non-zero and writes no
  dat files, and the driver publishes nothing. With
  `RRM_CONTINUE_ON_PECHUKAS=1` the fast and parallel outputs match `v11` byte
  for byte again; the bundled AuCu4 sample is the worked example.
* **A failed vertex lookup.** `generate_rrm_v11.g` writes the string `fail` into
  the dat file and still exits 0; `generate_rrm_v11_fast.g` exits non-zero.
* **Physical validity.** Byte equality says the reconstruction reproduces the
  reference, not that the GRRM input describes a physically sensible network.
  A Pechukas violation is exactly such an input problem, and it is reported
  rather than repaired.

**The degree check is not a correctness check.**
`check_number_of_edges_dat.py` verifies a necessary condition: vertices carrying
the same EQ number must have the same degree. Different graphs satisfy it. With
every vertex in one EQ, K3,3 and the triangular prism (six vertices, nine edges,
degree three) both pass, as does a file with no edges. An empty edge file is
legitimate for an input with no transition states; it is not evidence that a map
is right. To compare labeled graphs, run `tests/compare_rrm_dat.py` against a
reference run:

```bash
python3 tests/compare_rrm_dat.py ref_v.dat ref_e.dat new_v.dat new_e.dat --mode normalized
```

`--mode exact` compares every field in file order and `cmp` is the contract that
matches it. `--mode normalized` drops the order requirement and identifies
vertices by (EQ label, permutation) and edges by (TS label, permutation,
endpoint pair), keeping self-loops and multiplicities. `--mode structure`
ignores labels and compares vertex ids, clusters and endpoints, which is how a
`vlabel=false`/`elabel=false` run is checked against the labeled run that
carries the meaning of those ids.

In normalized mode, the default `--key auto` requires labels on every vertex
if either input contains any vertex labels. It uses ids only when both inputs
have no vertex labels. Mixed labeled/unlabeled vertices are rejected with exit
status 2; use `--mode structure` for an intentional labels-on/labels-off
comparison. Duplicate vertex ids are rejected with exit status 2 in every mode,
including when the edge files are empty.

**Verification.** `tests/test_rrm_full_comparison.sh` runs the comparison over
Au5Ag, AuCu4 in continue mode, and small fixtures in `tests/fixtures/` covering
self-loops, parallel edges, inversion isomers, a TS between vertices of the same
EQ, several EQs and a zero-TS input. It also mutates real output — a
degree-preserving rewiring, a changed TS or permutation label, a dropped edge, a
changed multiplicity, an opened self-loop — and requires the comparison to
reject each one while the degree check still passes on the first three. See
[docs/results/issue17-full-comparison.md](docs/results/issue17-full-comparison.md).

## Options
* `vlabel = true or false`, if it is set to true, the vertex labels are included in the file `rrm_Au5Ag_AFIR.dot`. Each vertex label comprises the corresponding EQ number n (EQn in the input file \*EQ_list.log) or n\* if it is an inversion isomer of EQn, and the permutation from the reference structure (EQn or EQn*). 
* `elabel = true or false`, if it is set to true, the edge labels are included in the file `rrm_Au5Ag_AFIR.dot`. Each edge label comprises the corresponding TS number n (TSn in the input file \*TS_list.log) or n\* if it is an inversion isomer of TSn, and the permutation from the reference structures (TSn or TSn*).
* `RRM_CONTINUE_ON_PECHUKAS`: `generate_rrm_v11_fast.g` stops with a non-zero GAP exit and does not write dat files if a path violates Pechukas's theorem. Set the environment variable `RRM_CONTINUE_ON_PECHUKAS=1`, or in GAP `RRM_CONTINUE_ON_PECHUKAS:=true;;` before `generate_rrm`, to restore the v11 print-and-continue behavior (needed for the AuCu4 demonstration below).
* `GAP_WORKERS`: default `1` runs sequential `generate_rrm` with the existing `VFILE EFILE GFILE` arguments and writes those files directly. `k>1` requires `--bundle OUTPUT_DIR GFILE`. The master writes vertices and checks Pechukas; workers write contiguous TS slices, concatenated in TS-index order. `MEM` (default `12g`) is per GAP process. Before publication, each worker's vertex count and SHA-256 of its validated, ordered vertex ID → EQ / inversion / canonical permutation table must match the master's. This check runs independently of display labels; even a zero-TS run validates its master table.
* `RRM_KEEP_SHARDS`: after successful parallel publication, numeric edge shards and worker correspondence tables are deleted by default. `1`, `true`, or `TRUE` retains them; other non-empty values are errors. Master tables and all logs are retained. Failed preparation retains available tables and shards for diagnosis. Runs do not remove another generation's shards.

## Parallel output bundles

For `GAP_WORKERS>1`, results are stored as a pair in a unique generation directory:

```text
output/MOL/
  .writer.lock
  current -> runs/run.XXXXXXXX
  runs/run.XXXXXXXX/
    vertices.dat
    vertices.dat.vertex-map
    edges.dat
    manifest.txt
    vertices.dat.master.log
    edges.dat.part.0.log
    ...
```

`manifest.txt` records the format version, vertex count, TS count, active worker count, and SHA-256 hashes of both data files. `vertex_map_format=1` and `vertex_map_sha256` identify the retained master table and the correspondence validated against every active worker. Invalid, missing, duplicate or inconsistent metadata prevents publication. The guarantee relies on SHA-256 collision resistance and checks vertex correspondence, not physical validity or the full input/TS semantics. See the [vertex correspondence contract](docs/specs/parallel-vertex-map.md).

Run and read a result as follows. Resolve `current` **once**, then use that generation path for both files:

```bash
GAP_WORKERS=2 ./generate_rrm_v11_parallel.sh --bundle output/Au5Ag data/Au5Ag_AFIR.g
run=$(readlink -f -- output/Au5Ag/current)
test -n "$run" && test -f "$run/manifest.txt" || exit 1
python3 check_number_of_edges_dat.py "$run/vertices.dat" "$run/edges.dat"
(cd "$run" && tail -n 2 manifest.txt | sha256sum -c -)
```

Do not open `current/vertices.dat` and `current/edges.dat` separately: a publication between those opens could select different generations. Once resolved, the generation remains available across subsequent runs. Published data files, master table and manifest are immutable to the driver and retained indefinitely; temporary shard/table cleanup may finish after publication. Reclaim disk space only when no readers or writers use the bundle; preserve the directory selected by `current` and any snapshots still needed. Failed runs can leave unpublished generation directories containing diagnostics, shards, or a completed pair; directory presence or a manifest alone is not a publication marker. Only `current` selects the latest published result.

The driver prepares both files and the manifest before switching the single `current` symlink with a same-filesystem rename. Any failure before that switch leaves the old reference and pair intact; a failed first run has no `current`. Errors and INT/TERM return nonzero. If interruption or temporary-file cleanup failure occurs after the switch, the complete new generation may already be published; cleanup never deletes its data files or older generations. This is an atomic visibility guarantee for the supported reader procedure, not a power-loss durability guarantee. No `fsync` protocol is implemented.

Supported environments are Linux with Bash, Python 3.9+ (standard library only for parallel table validation), GNU coreutils (`mv -T`, `readlink -f`, `stat`, `sha256sum`, `mktemp`) and util-linux `flock`, on a filesystem providing atomic same-filesystem rename and functioning advisory locks. Keep `runs` as an ordinary directory on the bundle filesystem. Network/distributed filesystems require verification of those semantics; they are not covered by the local tests. Writers to the same bundle fail immediately if its lock is held. Do not externally modify a bundle while it is in use.

### Migration from VFILE/EFILE

The old parallel invocation `GAP_WORKERS=2 ... VFILE EFILE GFILE` now fails with a migration message before changing those files. Replace it with `--bundle OUTPUT_DIR GFILE` and update readers as above. Existing standalone files are left in place. To export a resolved generation for tools requiring standalone paths, copy it to a fresh directory while those tools are stopped:

```bash
set -e
run=$(readlink -f -- output/Au5Ag/current)
test -n "$run" && test -f "$run/manifest.txt" || exit 1
mkdir exported-Au5Ag
cp -- "$run/vertices.dat" exported-Au5Ag/vertices_Au5Ag_AFIR.dat
cp -- "$run/edges.dat" exported-Au5Ag/edges_Au5Ag_AFIR.dat
# Start the consuming tool only after both copies succeed.
```

These two copies are not atomic publication. For concurrent readers, use the bundle procedure. `GAP_WORKERS=1` retains the original direct-file interface and does not provide the bundle's pair publication guarantee.

## Scale of the labeled map
The number of labeled vertices is on the order of (number of EQs) times |CNPI| / |point group of the EQ|. For a monometallic cluster the CNPI group contains S_n (and S_n x Z_2 when inversion copies are distinct), so the files grow as n!. Mixed-element maps are much cheaper: they use a Young subgroup of S_n. The bundled Au5Ag example has six atoms but only five identical gold atoms, and the labeled files are small (~1.7e3 vertices, ~1.0e4 edges, a few hundred kB).

The table is an order of magnitude for **monometallic** maps with a GRRM catalogue similar to Au7–Au8 AFIR (tens of EQs, about 10^2 TSs). It is the scale at which the dat files stop being a practical artifact, not a guarantee that every map of size n will fit.

| identical atoms n | order of S_n | typical labeled graph | usable as `vertices_*.dat` / `edges_*.dat`? |
|---|---|---|---|
| 7 (measured Au7 AFIR; not bundled here) | 5e3 | ~1e5 vertices, ~7e5 edges, tens of MB of text | yes |
| 8 | 4e4 | ~1e6 vertices, ~1e7 edges, hundreds of MB | intended, with `generate_rrm_v11_fast.g` (and optional `GAP_WORKERS`) |
| 9 | 4e5 | ~1e7–1e8 edges, a few GB | maybe: streamed writes, raise GAP `-m`, do not run `dot` |
| 10 | 4e6 | ~1e9 edges, tens of GB of text | not a practical artifact |
| 12 | 5e8 | cannot materialize | no |

That Au7 expansion is about 3 MB of vertices and 26 MB of edges; the rendered PNG is hundreds of MB. Skip Graphviz `dot` for maps in that range and above. For maps that still fit on disk, increase the memory available to GAP with `-m` (the examples use `-m 12g`). Details: [GAP documentation](https://www.gap-system.org/). The paper (see [How to Cite](#how-to-cite)) describes the reconstruction; this table is only about file size.

The demo helper `check_number_of_edges_v3.py` reads the whole DOT file into memory. For n=8+ maps, skip `dot` and run `python3 check_number_of_edges_dat.py vertices_*.dat edges_*.dat` instead: it streams the labeled files and keeps only an O(number of vertices) degree table. The check is not required for writing the dat files.

## Cost of the GAP step, and when `GAP_WORKERS` pays

Measured numbers, the method behind them and their limits are in
[docs/results/issue18-performance.md](docs/results/issue18-performance.md);
reproduce them with `tools/bench_campaign.sh`, or measure your own input with
`tools/rrm_bench.py` (see [Measuring your own input](#measuring-your-own-input)).
The figures quoted here are medians of three runs on a 4-core container with
GAP 4.12.1 and `MEM=2g`, not on a cluster. **Re-measure before relying on
them.**

**`generate_rrm_v11_fast.g` versus `generate_rrm_v11.g`.** The fast script
replaces `v11`'s `Position(vertices, ...)` linear scan by a hash lookup and
streams its writes, so what it removes grows with the number of vertices. It
was never slower in any measured case, but the size of the win depends entirely
on the input: 1704 vertices (Au5Ag) gave 4.9x end-to-end, 41160 vertices gave
56x, and an input with only 168 vertices but 341k edges gave 1.3x. On the GAP
computation alone (`Runtime()` around `generate_rrm`, i.e. excluding startup and
parsing) the same runs are 16x, 98x and 1.2x. Expect a large win for maps with
many vertices, and little for maps whose vertex count is small.

**`GAP_WORKERS=k>1` is not a general speedup.** The driver starts one master
GAP process (vertex enumeration, Pechukas check, vertex file, vertex map) and
*k* worker processes, and every one of them independently pays GAP startup and
rebuilds the full coset transversal and index before writing its TS slice. Only
the edge writes are divided. So, roughly,

* sequential: startup + index build + vertices + **all** edges
* `k` workers: startup + (index build + vertices + map) + (index build + edges/`k`) + concatenation and validation

and `k>1` wins only when the edge work is large enough to pay for the repeated
build, the extra startups and the publication step. In the measurements:

| input | vertices | edges | fastest sequential | `par:2` | `par:4` |
|---|---|---|---|---|---|
| Au5Ag | 1704 | 10020 | 1.34 s | 2.59 s | 2.72 s |
| synthetic, realistic shape | 41160 | 147000 | 2.79 s | 6.21 s | 6.96 s |
| synthetic, edge-dominated | 168 | 341292 | 4.97 s | 4.58 s | 3.72 s |

`par:4` beat the sequential script only in the edge-dominated case, and then by
1.3x on four workers. For every map in this repository's own sample data,
`gap -b -q -r -m <MEM> generate_rrm_v11_fast.g` sequentially is the faster
choice. Reach for `GAP_WORKERS>1` when the edge count dwarfs the vertex count,
or when a single process would not finish in the time available — and measure
your input rather than assuming, because `--bundle` also buys the atomic
publication guarantee described above, which `GAP_WORKERS=1` does not provide.

**`MEM` is per process, and it is not free.** `MEM` is GAP's `-m`, the initial
workspace of *each* GAP process, so a `GAP_WORKERS=k` run holds `k+1` of them
at once. On Au5Ag, raising `MEM` from `512m` to `12g` slowed the sequential run
from 1.17 s to 3.02 s and `par:4` from 2.47 s to 9.98 s, and it raised the
memory the whole job needs at one time from 985 MiB to 6.6 GiB — for a map
whose files are a few hundred kB. Use the smallest `-m` that completes; raise it
only when GAP actually runs out (see [Scale of the labeled
map](#scale-of-the-labeled-map)).

**Which memory number to compare against a job limit.** Three different figures
are easy to confuse, and only one of them sizes a parallel job: the peak of a
single process, the sum of the per-process peaks (which over-counts, since the
peaks are not simultaneous), and the largest total of *simultaneously* resident
memory. For `par:4` on Au5Ag at `MEM=2g` these were 473 MiB, 2313 MiB and
1747 MiB respectively. A batch-system memory limit has to cover the third one;
`tools/rrm_bench.py` reports all three separately and never mixes them.

### Measuring your own input

```bash
python3 rrm_reconstruction_v18.py Metal/MOL/MOL_AFIR_EQ_list.log \
    Metal/MOL/MOL_AFIR_TS_list.log Metal/MOL/MOL_AFIR_TS data/MOL_AFIR.g
python3 tools/rrm_bench.py --label MOL --gfile data/MOL_AFIR.g \
    --config v11 --config fast --config par:2 --config par:4 \
    --reps 3 --mem 2g --outdir /var/tmp/rrm-bench --deep-compare \
    --json /var/tmp/rrm-bench/MOL.json --markdown -
```

Every configuration's map is compared byte for byte against the first one
listed, so a run that both times a change and disagrees with the reference
fails (exit 2) instead of reporting a speedup. `--timeout SECONDS` bounds a run
that is too slow to wait for; a cut-off run is reported as such and is left out
of the ratios. Raw output goes under `--outdir`, which must be outside the
repository. The structural size of an input alone, without producing anything:

```bash
gap -b -q -r -m 2g <<'EOF'
Read("tools/rrm_input_stats.g");
Read("data/MOL_AFIR.g");
rrm_input_stats(symc, ur, urt, ss);
QUIT;
EOF
```

This prints the vertex count, the edge count and the per-TS expansion
`Index(sym, urt[i])` — the last of which is what a `GAP_WORKERS>1` run splits by
TS *count*, so a map with a few very heavy transition states will not balance
across workers.

## Limitations
* Sample data of GRRM output is in the directory Metal. The files required are `***EQ_list.log`, `***TS_list.log`, and `***TSn.log` (`n` is the indices of the transition states.).
* As mentioned in the paper, the code does not support RRMs that include DC (dissociation channel) states or saddle connections.
* The current version of the code only accept the connected RRMs as inputs (otherwise the assertion error `assert nx.is_connected(G)` occurs in rrm_reconstruction_v18.py.
* If GAP stops because the input molecule is large but the map is still in the materializable range above, increase `-m`. If the labeled graph is past that range, do not expect dat files; see [Scale of the labeled map](#scale-of-the-labeled-map).
* If the resulting RRM in shape space is too big, skip Graphviz rather than waiting on `dot`. Edit the DOT file, extract graph properties, or use other software. The demo’s `dot` step is optional.
* If the GRRM output contains reaction paths that violate [Pechukas's theorem](https://pubs.aip.org/aip/jcp/article-abstract/64/4/1516/786979/On-simple-saddle-points-of-a-potential-surface-the) (and [its extension (Hiroshi Teramoto, Pontential Energy Function, symmetry and its consequences, in Japanese)](https://www.jstc.org/frontier15/)), `generate_rrm_v11_fast.g` prints the diagnostic and exits non-zero **without writing** `vertices_*.dat` / `edges_*.dat`. `generate_rrm_v11.g` still prints and continues. For example, in the provided AuCu4 sample, TS8 and TS16 produce such errors. With `RRM_CONTINUE_ON_PECHUKAS=1` the messages look like:

```
Violation of Pechukus theorem:
TS8:
the reactant and product are permutation isomers
EQ2
in what follows, minus 1 to convert to the atom labels
U(r) (for reactant):
Group( [ () ] )
U(r) (for product):
Group( [ () ] )
stabEQs:
Group( [ (2,4) ] )
U(r) (for transition state):
Group( [ (2,4)(3,5), () ] )
Violation of Pechukus theorem:
TS16:
reactant:
EQ3
product:
EQ5
in what follows, minus 1 to convert to the atom labels
U(r) (for reactant):
Group( [ (2,5)(3,4), () ] )
U(r) (for product):
Group( [ (2,3)(4,5), (2,4)(3,5), (2,5)(3,4), () ] )
U(r) (for transition state):
Group( [ (2,3)(4,5), (2,4)(3,5), (2,5)(3,4), () ] )
GAP computation done.
```
This is expected for that dataset (it indicates a certain kind of symmetry issue in the reaction network). If this occurs, the results are not guaranteed to be correct – you should carefully examine your GRRM output in such cases. Without the continue flag, GAP stops at the first violation (TS8 for AuCu4) and does not present the dat files as success.

## Important Parameters
* tolerance - Distance tolerance to consider sites as symmetrically equivalent in rrm_reconstruction_v18.py
  - default value is set to `0.1`
  - Note: the assigned point group can depend on the tolerance value. The algorithm will output a warning if the point group it finds differs from the one reported by the GRRM program.

## Using your own GRRM outputs
* Create a directory with the name of your molecule (e.g. Au5Ag). In what follows, we suppose it is ${MOL}.
* Put all the output files of GRRM, `${MOL}_AFIR_EQ_list.log`, `${MOL}_AFIR_TS_list.log`, `${MOL}_AFIR_TSn.log` (`n` is supposed to be the indices of the transition states.) under the directory.
* Modify `MOL=${MOL}` in the `reproduce_rrm_demo.sh`.
* Run `./reproduce_rrm_demo.sh`.
* Watch out warnings and errors. If Assertion error occurred, it indicates there is a bug in this code (in that case, kindly report the bug to us!) or there is a problem in your GRRM output (like the case AuCu4 mentioned above, we observed the violation of Pechukas theorem occurred in case if Vallay-Ridge transitions occur in the middle of a reaction path or other possibly more primitive error.). With `generate_rrm_v11_fast.g` that Pechukas case is a non-zero GAP exit unless `RRM_CONTINUE_ON_PECHUKAS=1`. This code can also used to verify your GRRM output.
* If the code ran successfuly, it will output `vertices_${MOL}_AFIR.dat` and `edges_${MOL}_AFIR.dat` (the labeled reconstruction), plus `rrm_${MOL}_AFIR.dot` and `rrm_${MOL}_AFIR.png` if you keep the demo’s `dot` step (and `data/${MOL}_AFIR.g` for an intermediate file). Skip `dot` when the labeled graph is large; see [Scale of the labeled map](#scale-of-the-labeled-map). If the png figure is too complicated to show, consider extracting some features of the graph from the Graphviz DOT file. For example, we use persistent homology to extract some features of output graphs.

## How to Cite: 
If you use this code, please cite the following publication: Hiroshi Teramoto et al., J. Chem. Theory Comput. 2023, 19, 17, 5886–5896.
