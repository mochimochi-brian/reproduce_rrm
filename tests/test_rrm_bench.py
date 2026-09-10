#!/usr/bin/env python3
"""Harness comparison regressions; no GAP installation required."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("rrm_bench", ROOT / "tools/rrm_bench.py")
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)


class ComparisonTests(unittest.TestCase):
    def run_bench(self, configs, reference, outputs, reps=1):
        observed = []

        def measured(cmd, env, stdin_text, log_path, timeout, interval):
            kind = "fast" if "generate_rrm_v11_fast.g" in stdin_text else "v11"
            observed.append(kind)
            content = outputs[len(observed) - 1]
            for name in ("vertices.dat", "edges.dat"):
                Path(log_path).with_name(name).write_text(content)
            return {
                "exit_code": 0, "timed_out": False, "wall_s": 1.0,
                "cpu_total_s": 1.0, "max_single_peak_rss_kb": 1,
                "sampled_max_single_peak_rss_kb": 1,
                "sum_peak_rss_kb": 1, "concurrent_peak_rss_kb": 1,
            }

        with tempfile.TemporaryDirectory(prefix="rrm-bench-unit-") as outdir:
            report_path = Path(outdir) / "report.json"
            args = ["--gfile", str(ROOT / "tests/fixtures/small_labels.g"),
                    "--outdir", outdir, "--reference", reference,
                    "--reps", str(reps), "--json", str(report_path),
                    "--markdown", str(Path(outdir) / "report.md")]
            for config in configs:
                args.extend(["--config", config])
            with mock.patch.object(bench, "input_stats", return_value={"nts": 0}), \
                    mock.patch.object(bench, "gap_version", return_value="test"), \
                    mock.patch.object(bench, "run_measured", side_effect=measured), \
                    contextlib.redirect_stderr(io.StringIO()):
                rc = bench.main(args)
            report = json.loads(report_path.read_text())
        return rc, report, observed

    def test_late_reference_detects_mismatch(self):
        rc, report, observed = self.run_bench(
            ["fast", "v11"], "v11", ["reference\n", "different\n"])
        self.assertEqual(observed, ["v11", "fast"])
        self.assertEqual(report["order"], ["fast", "v11"])
        self.assertEqual(rc, 2)
        self.assertFalse(report["configs"]["fast"]["comparison"]["byte_identical"])

    def test_late_reference_accepts_matching_outputs(self):
        rc, report, _ = self.run_bench(
            ["fast", "v11"], "v11", ["same\n", "same\n"])
        self.assertEqual(rc, 0)
        self.assertTrue(report["configs"]["fast"]["comparison"]["byte_identical"])

    def test_reference_mismatch_survives_later_matching_repetition(self):
        rc, report, _ = self.run_bench(
            ["fast"], "fast", ["first\n", "different\n", "first\n"], reps=3)
        self.assertEqual(rc, 2)
        self.assertFalse(report["configs"]["fast"]["comparison"]["byte_identical"])

    def test_matching_reference_repetitions_succeed(self):
        rc, report, _ = self.run_bench(
            ["fast"], "fast", ["same\n", "same\n"], reps=2)
        self.assertEqual(rc, 0)
        self.assertTrue(report["configs"]["fast"]["comparison"]["byte_identical"])

    def test_driver_rejects_disabled_labels_before_running(self):
        for config in ("par:1", "par:2"):
            for flag in ("--no-vlabel", "--no-elabel"):
                with self.subTest(config=config, flag=flag), \
                        mock.patch.object(bench, "input_stats") as stats, \
                        contextlib.redirect_stderr(io.StringIO()) as stderr:
                    with self.assertRaises(SystemExit) as exc:
                        bench.main([
                            "--gfile", str(ROOT / "tests/fixtures/small_labels.g"),
                            "--config", "fast", "--config", config, flag,
                            "--outdir", tempfile.gettempdir(),
                        ])
                    self.assertEqual(exc.exception.code, 2)
                    self.assertIn("always writes labels", stderr.getvalue())
                    stats.assert_not_called()


if __name__ == "__main__":
    unittest.main()
