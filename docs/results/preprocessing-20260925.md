# GRRM preprocessing corrections

Validated on 2026-09-25 from fork `main` at `c46c62f`.

## Behavior

`rrm_reconstruction_v18.py` now treats the linear point group `C*v` as achiral
for EQ and TS. In pymatgen 2024.8.9, its finite symmetry-operation list omits
mirror planes. The previous determinant-only check therefore created extra
inverted structures. These copies could disconnect the graph or inflate CNPI
counts even when the existing output consistency checks passed. The issue also
affects structures with repeated elements and can affect TS alone.

`extract_largest_component.py` prepares disconnected original GRRM inputs by
explicitly selecting the unique largest connected component by EQ count.
It renumbers EQ and TS independently in ascending original-ID order, updates
connections, preserves loops and parallel edges, copies retained TS logs byte
for byte, and records the old IDs and excluded components in `mapping.json`.
A tie for largest component, invalid connections or IDs, missing retained TS
logs, and existing output paths cause errors. Source files remain intact.

See the [README](../../README.md#extracting-the-largest-connected-component)
for the extraction and preprocessing commands.

## Regression checks

Both checks passed on the PR worktree in PBS job `652144.qc-cluster3.local`,
node `compute-47-3.local`, using one CPU and Python 3.10.12:

```sh
python3 tests/test_extract_largest_component.py
python3 tests/test_chirality.py
```

- Extraction: gapped/unsorted IDs, mapping, byte preservation, loops, parallel
  edges, malformed input, ties, missing logs, output protection, EOF handling,
  connected input and the single-EQ/zero-TS extraction case.
- Chirality: HCN and CCO (`C*v`, without/with repeated elements), OCO (`D*h`),
  bent water (`C2v`), and chiral CHFClBr (`C1`), including each inversion.

Chirality checks use the existing NumPy/pymatgen preprocessing environment;
extraction requires only the Python standard library.

## Pt5 extraction validation

The same extractor was tested on Pt5 on 2026-09-21 in PBS job `651721`,
node `compute-46-0.local`, using one CPU:

- 43 EQ / 76 TS in six components became 38 EQ / 75 TS in one component.
- The excluded isolated EQs were 0, 12, 29, 41 and 42; the self-loop TS7 at
  EQ12 was excluded with its component.
- Renumbering and connections matched expectations; list contents other than
  IDs/connections and all 75 retained TS logs matched the source bytes.
- All source list and individual TS log hashes were unchanged.

This check covered extraction. The subsequent production CNPI expansions of
the six disconnected metal inputs remain pending.

## Corrected CNPI outputs

Saved preprocessing logs for the earlier 29-input batch identified 14 inputs
with `C*v` EQ or TS. All 14 were rerun on PBS in jobs `652126`–`652139` with
fast, `GAP_WORKERS=1`, one CPU and 16 GB per job. Previous outputs were retained.
The preprocessor and fast dependency hashes match the PR worktree.

| Input under the calculation directory | PBS job | Previous vertices / edges | Corrected vertices / edges |
|---|---:|---:|---:|
| `Catalyst/AgCO/AgCO_ADDF` | 652126 | Preprocessing disconnected | 2 / 1 |
| `Catalyst/AgH2/AgH2_ADDF` | 652127 | 1 / 4 | 1 / 2 |
| `Catalyst/AgOH/AgOH_ADDF` | 652128 | Preprocessing disconnected | 1 / 1 |
| `Catalyst/AuCO/AuCO_ADDF` | 652129 | Preprocessing disconnected | 2 / 1 |
| `Organic/C2O/AFIR/B3LYP_6-31Gdp/C2O_AFIR` | 652130 | 5 / 4 | 3 / 2 |
| `Organic/CNH/ADDF/wB97XD_6-31G*/CNH_ADDF` | 652131 | Preprocessing disconnected | 2 / 1 |
| `Organic/CO2/ADDF/B3LYP_6-31Gdp/CO2_ADDF` | 652132 | 7 / 6 | 5 / 4 |
| `Organic/CO2/ADDF/PBEPBE_6-31Gdp/CO2_ADDF` | 652133 | 7 / 6 | 5 / 4 |
| `Organic/COS/ADDF/B3LYP_6-31Gdp/COS_ADDF` | 652134 | 6 / 5 | 4 / 3 |
| `Organic/CS2/ADDF/B3LYP_6-31G2dp/CS2_ADDF` | 652135 | 7 / 6 | 5 / 4 |
| `Organic/CS2/ADDF/B3LYP_6-31Gdp/CS2_ADDF` | 652136 | 7 / 6 | 5 / 4 |
| `Organic/OCS/ADDF/B3LYP_6-31G2dp/OCS_ADDF` | 652137 | 7 / 6 | 4 / 3 |
| `Organic/OCS/ADDF/B3LYP_6-31Gdp/OCS_ADDF` | 652138 | 6 / 5 | 4 / 3 |
| `Organic/OCS/ADDF/UB3LYP_6-31Gdp/OCS_ADDF` | 652139 | 4 / 5 | 3 / 3 |

Every rerun passed checks for absence of unwanted EQ/TS inversion copies,
preprocessing connectivity, vertex correspondence, group-index vertex/edge
counts, output checksums, and degree consistency for equal EQ labels. No
Pechukas violation was reported. The chiral control remained chiral.

Thirteen reruns used the existing input-level normalization of `Group([])` to
`Group([()])`; the unnormalized GAP input and both hashes were retained.
This normalization was already part of the calculation workflow and is not
a change to the preprocessor in this PR.

## Source provenance and raw artifacts

| Source | SHA-256 |
|---|---|
| `rrm_reconstruction_v18.py` | `0a2b9d6b667aa2b219a9e9aca3d93f6a97be399033ee4ab8833ea931c18e7c83` |
| `extract_largest_component.py` | `34c06d27549eeda65a276b8bee263c04dd2e053291510b39200a6573217b8a8a` |

Raw artifacts remain outside Git in the calculation directories:

- Corrected CNPI: each input directory's `CNPI/retry_chirality_20260925/`
  (`case.json`, source patch, inputs, logs, and `current/` output bundle).
- Pt5 extraction: `Metal/Pt5/CNPI/extractor_validation_20260921/`.
- PR regression checks: `Catalyst/AgCO/CNPI/pr_preprocessing_validation_20260925/`.

The PBS server does not retain completed-job history; success is recorded in
compute-node status files and validation logs. The source snapshots and input
hashes are retained with those artifacts.
