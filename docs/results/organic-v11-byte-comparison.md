# 有機分子の元 Ver11 とのバイト一致検証

2026-09-17、qc4 で実施。`calc/Organic` の実際の GRRM 出力から RRM を
再構築した。メタン、ギ酸、C₃NH、n-ブタンは通常設定で元 Ver11 と
頂点・辺ファイルがバイト単位で一致した。CH₅⁺ は入力に Pechukas 条件の
違反があり、`RRM_CONTINUE_ON_PECHUKAS=1` の場合に一致した。

## 比較対象と方法

- 元実装：上流 `d64568d` の `generate_rrm_v11.g`。
  作業ツリーのファイルと上流コミット内のファイルの SHA-256 はともに
  `a61bf68fd8253306561c283559dc2c484ec27ee76c6e6770301eba0eda7f10d5`。
- 比較先：`codex/sequential-bundle` の
  `b3b898bfdd16d14d87187685185b27c119062c33` にある
  `generate_rrm_v11_fast.g` と `generate_rrm_v11_parallel.sh`。
- EQ/TS 一覧と各 TS の経路ログを `/tmp/rrm-organic-20260917/` にコピーし、
  元の `rrm_reconstruction_v18.py` で前処理した。
  上流の作業ツリーからも前処理を独立に実行し、5 ケースすべてで
  `input.g` と `GRRM_graph.dot` が `cmp` で一致した。
- 各入力で `vlabel` / `elabel` の 4 通りを元 Ver11 と高速版で比較。
  さらに `--bundle` の `GAP_WORKERS=1,2,3` をラベルありの元 Ver11 と比較。
  **35 組、計 70 ファイルの `cmp` がすべて終了コード 0**。
  並べ替え、空白除去、数値の許容誤差は使用していない。
- 各組について既存の `compare_rrm_dat.py --mode exact` も成功。
  全 15 bundle の manifest のデータファイルチェックサムも成功した。
  頂点・辺数は `rrm_input_stats.g` の群の指数から求めた値とも一致した。

## 入力と結果

以下の入力パスは `/home5/Brian/calc/Organic/` からの相対的な接頭辞。
各接頭辞に `_EQ_list.log`、`_TS_list.log`、`_TS0.log` などを付けた
ファイルを使用した。計算コード、座標、対称性の許容値は変更していない。

| 入力 | 接頭辞 | 元 EQ / TS 数 | 出力頂点 / 辺数 | 通常設定 | 継続設定 |
|---|---|---:|---:|---|---|
| CH₄ | `CH4/ADDF/wB97XD_cc-pVDZ/CH4_ADDF` | 1 / 1 | 2 / 24 | 全 7 組一致 | 使用せず |
| CH₅⁺ | `CH5_charge_1/AFIR/CH5_AFIR` | 1 / 2 | 120 / 180 | 高速版は TS0 で停止 | 全 7 組一致 |
| HCOOH | `HCOOH/AFIR/HCOOH_AFIR` | 2 / 2 | 4 / 5 | 全 7 組一致 | 使用せず |
| C₃NH | `C3NH/ADDF/wB97XD_6-31G*/C3NH_ADDF` | 12 / 39 | 102 / 450 | 全 7 組一致 | 使用せず |
| n-ブタン | `old3_n-butane/n-butane_AFIR` | 2 / 4 | 54 / 180 | 全 7 組一致 | 使用せず |

反転異性体の追加後、HCOOH は 2 EQ / 3 TS、C₃NH は 17 EQ / 75 TS、
n-ブタンは 3 EQ / 7 TS になる。反転ラベルや多重辺を含む実際の出力も
比較対象である。CH₄ は TS が 1 個なので、並列数を 2、3 に指定しても
実際の辺生成ワーカー数は 1。CH₅⁺ は最大 2、他の 3 入力は最大 3 だった。

Ver11 の通常の仕様に従い、出力は形状空間の連結成分のうち 1 成分。
成分数 `Index(sym,symc)` は HCOOH が 2、n-ブタンが 2,419,200、
他の 3 入力が 1。この検証で全成分を列挙したわけではない。
n-ブタンは保存済みの `old3_n-butane` データを検証しており、
解離チャネルを含む現在の `n-butane/` データ全体の検証ではない。

## CH₅⁺ の例外と入力由来の警告

CH₅⁺ の TS0 で、元 Ver11 も `Violation of Pechukus theorem` を出す。
元 Ver11 は出力を継続し、高速版は通常設定で非ゼロ終了して dat を作成しない。
通常設定の bundle もワーカー数 1、2、3 のすべてで非ゼロ終了し、
`current` が作られないことを実測した。

継続設定で生成した CH₅⁺ のファイルは元 Ver11 と完全一致するが、
`check_number_of_edges_dat.py` は同じ EQ の頂点に次数 2 と 3 が混在すると
報告して終了コード 1 になる。他の 4 入力は次数検査にも成功した。
したがって CH₅⁺ の結果は、参照実装との一致の確認に限られ、
妥当な反応ネットワークとしての検証成功には含めない。

前処理では C₃NH の EQ0、EQ2、EQ3、EQ9 と n-ブタンの TS0 に
GRRM と pymatgen の点群判定の相違が報告された。警告はログに保存した。
これらの入力の GAP 処理では Pechukas 違反は報告されなかった。

## 再実行

環境：GAP 4.13.0、前処理用 Python 3.10.12
(`/home5/Brian/anaconda3/envs/rrm-recon/bin/python`)、pymatgen 2024.8.9、
NumPy 1.26.4、NetworkX 3.3、pygraphviz 1.14。`tol=0.1 Å`、GAP の
`MEM=1g`、`BASH_ENV=/dev/null`、`PYTHONHASHSEED=0`、
`OMP_NUM_THREADS=OPENBLAS_NUM_THREADS=MKL_NUM_THREADS=1` を使用した。

ギ酸での再実行例（ほかの入力は上表の接頭辞に置き換える）：

```bash
repo=/home5/Brian/code/Repos/reproduce_rrm/.worktrees/sequential-bundle
prefix=/home5/Brian/calc/Organic/HCOOH/AFIR/HCOOH_AFIR
run=$(mktemp -d /tmp/rrm-organic-check.XXXXXXXX)
export BASH_ENV=/dev/null PYTHONHASHSEED=0
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
unset RRM_CONTINUE_ON_PECHUKAS
(
  cd "$run"
  /home5/Brian/anaconda3/envs/rrm-recon/bin/python \
    "$repo/rrm_reconstruction_v18.py" \
    "${prefix}_EQ_list.log" "${prefix}_TS_list.log" "${prefix}_TS" "$run/input.g"
)
GAP=/home5/Brian/bin/gap-4.13.0/gap MEM=1g OUT="$run/comparison" \
  bash "$repo/tests/test_rrm_real_input.sh" "$run/input.g"
```

CH₅⁺ の一致検証では最後のコマンドに `RRM_CONTINUE_ON_PECHUKAS=1` を指定する。
このテストは Pechukas 違反を自動的に無視しない。

入力ファイルすべての出所・サイズ・SHA-256、生成した GAP 入力のハッシュ、
ラベル設定別の出力ハッシュ、実際のワーカー数、比較結果は
[機械可読の検証記録](data/organic-v11-byte-comparison.json) に保存した。
生入力のコピー、生成ファイル、ログ、集計スクリプトは
`/tmp/rrm-organic-20260917/` に保存し、Git 管理には追加していない。
再利用可能な検証スクリプトは
[`tests/test_rrm_real_input.sh`](../../tests/test_rrm_real_input.sh)。

この結果は上記 5 入力と記載した実行環境での検証であり、任意の有機分子や
異なる GAP バージョン間でのバイト一致を証明するものではない。
