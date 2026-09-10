#!/usr/bin/env python3
"""Measure wall time, CPU time and peak memory of the RRM GAP producers.

Compares, on the same input and in the same environment:

  * ``v11``   -- ``generate_rrm_v11.g``, the reference implementation
  * ``fast``  -- ``generate_rrm_v11_fast.g`` run sequentially
  * ``par:k`` -- ``generate_rrm_v11_parallel.sh`` with ``GAP_WORKERS=k``
                 (``k=1`` is the driver's sequential path, ``k>1`` writes a
                 bundle: master vertices, TS-sliced edge shards, concatenation
                 and publication)

so that the sequential speedup and the *additional* effect of the process
parallelism can be reported separately.

What is measured, and how
-------------------------

Wall time is the full lifetime of the command this harness launches, i.e. GAP
startup (which depends on ``-m``), reading the input, the group theory, the
writes and -- for ``par:k>1`` -- shard concatenation, vertex-map validation and
publication. It is measured with ``time.monotonic()`` around the child.

CPU time is taken from ``os.wait4()``: ``ru_utime + ru_stime`` of the launched
process *and every descendant it reaped*, which for the driver includes the
master and all workers. This is process CPU time, so it contains GAP's own
startup and parsing. For ``v11``/``fast`` the harness also reads GAP's internal
clock (``Runtime()``) around ``Read`` and around ``generate_rrm`` and reports
those separately (``gap_read_ms`` / ``gap_generate_ms``); the driver's GAP input
is not written by this harness, so those two numbers are not available for
``par:k``.

Peak memory is reported as three explicitly different numbers, because for a
process group they are not interchangeable:

  ``max_single_peak_rss_kb``
      the largest peak RSS reached by any one process. Exact: ``ru_maxrss``
      from ``os.wait4()`` is the maximum over the child and its reaped
      descendants. The sampler's own maximum of ``VmHWM`` is reported next to
      it as ``sampled_max_single_peak_rss_kb`` for cross-checking.
  ``sum_peak_rss_kb``
      the sum over processes of each process's own peak (``VmHWM``). For the
      group as a whole this over-counts, because the peaks need not be
      simultaneous.
  ``concurrent_peak_rss_kb``
      the largest sum of the *simultaneously* resident RSS of all live
      processes, taken over samples. This is what a memory limit on the whole
      job has to accommodate.

Both sampled figures are lower bounds: a process that appears and peaks between
two samples is missed, and ``VmHWM`` is read at most one interval before the
process exits. ``sampled_max_single_peak_rss_kb`` is the sampler's version of
the exact ``max_single_peak_rss_kb``, so the difference between the two
quantifies what the sampling interval loses on the run at hand. Do not mix the
three: for ``par:4`` the single-process peak understates the job by roughly a
factor of four, while the sum of peaks overstates the simultaneous
requirement.

Per-process detail comes from a sampling thread that walks ``/proc`` for
processes in the child's process group (the child is started in a new session).
Each GAP process is labelled by the target of its ``/proc/<pid>/fd/1``, which
the driver points at ``vertices.dat.master.log`` or
``edges.dat.part.<w>.log`` -- that is how master and worker *w* are told apart
without modifying the driver. Per-process wall time is first-seen to last-seen
in the samples, so it is short by up to one sampling interval at each end.

Correctness of the compared outputs is checked, not assumed: the published
``vertices.dat`` / ``edges.dat`` of every run are compared byte for byte
against the reference configuration's output (``--reference``, default the
first configuration given), and optionally with
``tests/compare_rrm_dat.py --mode exact`` (``--deep-compare``). A run that hits
``--timeout`` is recorded as ``timed_out`` and is excluded from speedup ratios.

Example::

    python3 tools/rrm_bench.py --label Au5Ag --gfile data/Au5Ag_AFIR.g \\
        --config v11 --config fast --config par:1 --config par:2 --config par:4 \\
        --reps 3 --mem 2g --outdir /var/tmp/rrm-bench \\
        --json docs/results/data/issue18-Au5Ag.json --markdown -

Raw GAP output (dat files, logs, manifests) is written under ``--outdir``,
which must be outside the repository; only the JSON/Markdown summaries are
meant to be committed.
"""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import signal
import statistics
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLK_TCK = os.sysconf("SC_CLK_TCK")


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def gap_string(path):
    """Quote a path for GAP exactly as the driver's --gap-string does."""
    if "\n" in path:
        raise ValueError("path must not contain a newline: %r" % path)
    return '"%s"' % path.replace("\\", "\\\\").replace('"', '\\"')


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def count_lines(path):
    n = 0
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            n += chunk.count(b"\n")
    return n


def median(values):
    return statistics.median(values) if values else None


def spread(values):
    if len(values) < 2:
        return 0.0
    return statistics.stdev(values)


# --------------------------------------------------------------------------
# /proc sampling
# --------------------------------------------------------------------------

class ProcSampler(threading.Thread):
    """Sample RSS/CPU of every process in one process group.

    Collects, per pid: first/last time seen, peak RSS (``VmHWM``), last CPU
    time (``utime + stime``), command line and the target of fd 1, which is how
    driver master/worker processes are identified.
    """

    def __init__(self, pgid, interval=0.02):
        super().__init__(daemon=True)
        self.pgid = pgid
        self.interval = interval
        self.procs = {}
        self.concurrent_peak_kb = 0
        self.concurrent_peak_breakdown = {}
        self.samples = 0
        self._stopping = threading.Event()

    def stop(self):
        self._stopping.set()

    def run(self):
        while not self._stopping.is_set():
            self._sample()
            self._stopping.wait(self.interval)
        self._sample()

    # -- internals ---------------------------------------------------------

    def _pids(self):
        out = []
        try:
            entries = os.listdir("/proc")
        except OSError:
            return out
        for name in entries:
            if not name.isdigit():
                continue
            try:
                with open("/proc/%s/stat" % name, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            # comm may contain spaces and parentheses; fields after the last
            # ') ' are state ppid pgrp session ...
            try:
                tail = data.rsplit(b") ", 1)[1].split()
            except IndexError:
                continue
            if len(tail) < 13:
                continue
            try:
                if int(tail[2]) != self.pgid:
                    continue
                cpu = (int(tail[11]) + int(tail[12])) / CLK_TCK
            except ValueError:
                continue
            out.append((int(name), cpu))
        return out

    @staticmethod
    def _status(pid):
        rss = hwm = 0
        try:
            with open("/proc/%d/status" % pid, "r") as fh:
                for line in fh:
                    if line.startswith("VmRSS:"):
                        rss = int(line.split()[1])
                    elif line.startswith("VmHWM:"):
                        hwm = int(line.split()[1])
                    elif line.startswith("Threads:"):
                        break
        except (OSError, ValueError, IndexError):
            return None
        return rss, hwm

    @staticmethod
    def _label(pid):
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as fh:
                cmdline = fh.read().replace(b"\0", b" ").decode(
                    "utf-8", "replace").strip()
        except OSError:
            cmdline = ""
        try:
            stdout = os.readlink("/proc/%d/fd/1" % pid)
        except OSError:
            stdout = ""
        role = "other"
        base = os.path.basename(stdout)
        if "gap" in cmdline.split(" ")[0] or " gap " in cmdline:
            role = "gap"
        if base.endswith("vertices.dat.master.log"):
            role = "master"
        else:
            m = re.match(r"edges\.dat\.part\.(\d+)\.log$", base)
            if m:
                role = "worker:%d" % int(m.group(1))
        return cmdline, stdout, role

    def _sample(self):
        now = time.monotonic()
        live_total = 0
        breakdown = {}
        for pid, cpu in self._pids():
            st = self._status(pid)
            if st is None:
                continue
            rss, hwm = st
            rec = self.procs.get(pid)
            if rec is None:
                cmdline, stdout, role = self._label(pid)
                rec = {
                    "pid": pid,
                    "role": role,
                    "cmdline": cmdline,
                    "stdout": stdout,
                    "first_seen": now,
                    "last_seen": now,
                    "peak_rss_kb": 0,
                    "cpu_s": 0.0,
                }
                self.procs[pid] = rec
            elif rec["role"] == "other" or rec["role"] == "gap":
                # The first sample can catch a process before exec, or before
                # the driver has redirected fd 1, so keep refining the label
                # until it is specific (master / worker:<w>).
                cmdline, stdout, role = self._label(pid)
                if role != "other":
                    rec["role"] = role
                    rec["stdout"] = stdout
                    rec["cmdline"] = cmdline or rec["cmdline"]
            rec["last_seen"] = now
            rec["peak_rss_kb"] = max(rec["peak_rss_kb"], hwm, rss)
            rec["cpu_s"] = max(rec["cpu_s"], cpu)
            live_total += rss
            if rss:
                breakdown[rec["role"]] = breakdown.get(rec["role"], 0) + rss
        self.samples += 1
        if live_total > self.concurrent_peak_kb:
            self.concurrent_peak_kb = live_total
            self.concurrent_peak_breakdown = breakdown

    # -- results -----------------------------------------------------------

    def result(self):
        procs = sorted(self.procs.values(), key=lambda r: r["first_seen"])
        detail = []
        for rec in procs:
            detail.append({
                "role": rec["role"],
                "wall_s": round(rec["last_seen"] - rec["first_seen"], 4),
                "cpu_s": round(rec["cpu_s"], 3),
                "peak_rss_kb": rec["peak_rss_kb"],
            })
        return {
            "samples": self.samples,
            "sample_interval_s": self.interval,
            "processes": detail,
            "sum_peak_rss_kb": sum(r["peak_rss_kb"] for r in procs),
            "sampled_max_single_peak_rss_kb":
                max((r["peak_rss_kb"] for r in procs), default=0),
            "concurrent_peak_rss_kb": self.concurrent_peak_kb,
            "concurrent_peak_breakdown_kb": self.concurrent_peak_breakdown,
        }


# --------------------------------------------------------------------------
# running one measured command
# --------------------------------------------------------------------------

def run_measured(cmd, env, stdin_text, log_path, timeout, interval):
    """Run cmd, return a measurement dict. Never raises on child failure."""
    with open(log_path, "wb") as log:
        started_wall = time.monotonic()
        proc = subprocess.Popen(
            cmd, cwd=ROOT, env=env,
            stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
            stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True)
        if stdin_text is not None:
            try:
                proc.stdin.write(stdin_text.encode())
            except BrokenPipeError:
                pass
            finally:
                proc.stdin.close()

        sampler = ProcSampler(proc.pid, interval=interval)
        sampler.start()

        timed_out = threading.Event()

        def watchdog():
            if timeout and not finished.wait(timeout):
                timed_out.set()
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    try:
                        os.killpg(proc.pid, sig)
                    except ProcessLookupError:
                        return
                    if finished.wait(5):
                        return

        finished = threading.Event()
        wd = threading.Thread(target=watchdog, daemon=True)
        wd.start()

        pid, status, rusage = os.wait4(proc.pid, 0)
        finished.set()
        elapsed = time.monotonic() - started_wall
        proc.returncode = os.waitstatus_to_exitcode(status) \
            if os.WIFEXITED(status) else -os.WTERMSIG(status)
        sampler.stop()
        sampler.join(timeout=5)
        wd.join(timeout=6)

    result = {
        "cmd": cmd,
        "wall_s": round(elapsed, 4),
        "exit_code": proc.returncode,
        "timed_out": timed_out.is_set(),
        "cpu_user_s": round(rusage.ru_utime, 3),
        "cpu_sys_s": round(rusage.ru_stime, 3),
        "cpu_total_s": round(rusage.ru_utime + rusage.ru_stime, 3),
        "max_single_peak_rss_kb": rusage.ru_maxrss,
        "log": log_path,
    }
    result.update(sampler.result())
    return result


# --------------------------------------------------------------------------
# configurations
# --------------------------------------------------------------------------

SEQ_TEMPLATE = """\
Read({src});
_rrm_t0:=Runtime();;
Read({gfile});
_rrm_t1:=Runtime();;
generate_rrm({vfile},{efile},symc,ur,urt,ss,org_eq,org_ts,{vlabel},{elabel});
_rrm_t2:=Runtime();;
Print("RRM_BENCH_READ_MS=",_rrm_t1-_rrm_t0,"\\n");
Print("RRM_BENCH_GENERATE_MS=",_rrm_t2-_rrm_t1,"\\n");
Print("RRM_BENCH_GAP_RUNTIME_MS=",Runtime(),"\\n");
QUIT;
"""


def parse_config(spec):
    if spec in ("v11", "fast"):
        return {"name": spec, "kind": spec, "workers": 1}
    m = re.match(r"^par:(\d+)$", spec)
    if m and int(m.group(1)) >= 1:
        return {"name": spec, "kind": "par", "workers": int(m.group(1))}
    raise argparse.ArgumentTypeError(
        "config must be v11, fast or par:<k>, got %r" % spec)


def build_command(cfg, args, run_dir):
    """Return (cmd, env, stdin_text, published_pair_getter)."""
    env = dict(os.environ)
    env["GAP"] = args.gap
    env["MEM"] = args.mem
    vfile = os.path.join(run_dir, "vertices.dat")
    efile = os.path.join(run_dir, "edges.dat")

    if cfg["kind"] in ("v11", "fast"):
        src = os.path.join(ROOT, "generate_rrm_v11.g" if cfg["kind"] == "v11"
                           else "generate_rrm_v11_fast.g")
        stdin_text = SEQ_TEMPLATE.format(
            src=gap_string(src), gfile=gap_string(os.path.abspath(args.gfile)),
            vfile=gap_string(vfile), efile=gap_string(efile),
            vlabel="true" if args.vlabel else "false",
            elabel="true" if args.elabel else "false")
        cmd = [args.gap, "-b", "-q", "-r", "-m", args.mem]
        return cmd, env, stdin_text, (lambda: (vfile, efile))

    driver = os.path.join(ROOT, "generate_rrm_v11_parallel.sh")
    env["GAP_WORKERS"] = str(cfg["workers"])
    if cfg["workers"] == 1:
        cmd = [driver, vfile, efile, os.path.abspath(args.gfile)]
        return cmd, env, None, (lambda: (vfile, efile))

    bundle = os.path.join(run_dir, "bundle")
    cmd = [driver, "--bundle", bundle, os.path.abspath(args.gfile)]

    def published():
        # Resolve current exactly once, as the README requires.
        run = os.path.realpath(os.path.join(bundle, "current"))
        return os.path.join(run, "vertices.dat"), os.path.join(run, "edges.dat")

    return cmd, env, None, published


# --------------------------------------------------------------------------
# input statistics and environment
# --------------------------------------------------------------------------

def input_stats(args):
    stats_g = os.path.join(ROOT, "tools", "rrm_input_stats.g")
    stdin_text = (
        "Read(%s);\nRead(%s);\nrrm_input_stats(symc, ur, urt, ss);\nQUIT;\n"
        % (gap_string(stats_g), gap_string(os.path.abspath(args.gfile))))
    out = subprocess.run(
        [args.gap, "-b", "-q", "-r", "-m", args.mem], cwd=ROOT,
        input=stdin_text.encode(), stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT)
    text = out.stdout.decode("utf-8", "replace")
    stats = {"raw": text.strip()}
    for line in text.splitlines():
        m = re.match(r"^RRM_STAT_([A-Z_]+)=(.*)$", line.strip())
        if not m:
            continue
        key, value = m.group(1).lower(), m.group(2)
        if "," in value or key in ("eq_verts", "ts_edges"):
            stats[key] = [int(v) for v in value.split(",") if v != ""]
        else:
            stats[key] = int(value)
    if out.returncode != 0 or "nvert" not in stats:
        stats["error"] = "rrm_input_stats failed (exit %d)" % out.returncode
    return stats


def ts_slices(workers, nts):
    """Per-worker TS ranges, taken from the driver itself."""
    driver = os.path.join(ROOT, "generate_rrm_v11_parallel.sh")
    active = int(subprocess.run(
        [driver, "--active-workers", str(workers), str(nts)],
        stdout=subprocess.PIPE, check=True).stdout.split()[0])
    slices = []
    for w in range(active):
        lo, hi = subprocess.run(
            [driver, "--ts-slice", str(w), str(active), str(nts)],
            stdout=subprocess.PIPE, check=True).stdout.split()
        slices.append((int(lo), int(hi)))
    return active, slices


def gap_version(gap):
    out = subprocess.run([gap, "-b", "-q", "-r", "-m", "64m"],
                         input=b'Print(GAPInfo.Version,"\\n");QUIT;\n',
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return out.stdout.decode().strip().splitlines()[-1] if out.stdout else "unknown"


def cpu_model():
    try:
        with open("/proc/cpuinfo") as fh:
            for line in fh:
                if line.startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or "unknown"


def mem_total_kb():
    try:
        with open("/proc/meminfo") as fh:
            for line in fh:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1])
    except (OSError, ValueError):
        pass
    return None


def git_state():
    def git(*a):
        try:
            return subprocess.run(["git", "-C", ROOT] + list(a),
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL,
                                  check=True).stdout.decode().strip()
        except (OSError, subprocess.CalledProcessError):
            return None
    commit = git("rev-parse", "HEAD")
    dirty = git("status", "--porcelain")
    return {"commit": commit, "dirty": bool(dirty), "branch":
            git("rev-parse", "--abbrev-ref", "HEAD")}


# --------------------------------------------------------------------------
# comparison of produced maps
# --------------------------------------------------------------------------

def describe_output(vfile, efile):
    info = {}
    for tag, path in (("vertices", vfile), ("edges", efile)):
        if not os.path.isfile(path):
            info[tag] = None
            continue
        info[tag] = {
            "lines": count_lines(path),
            "bytes": os.path.getsize(path),
            "sha256": sha256_file(path),
        }
    return info


def compare_pair(ref, new, deep):
    """Byte comparison plus, optionally, tests/compare_rrm_dat.py."""
    result = {}
    ok = True
    for tag, (a, b) in (("vertices", (ref[0], new[0])),
                        ("edges", (ref[1], new[1]))):
        rc = subprocess.run(["cmp", "-s", a, b]).returncode
        result[tag] = "identical" if rc == 0 else "differs"
        ok = ok and rc == 0
    result["byte_identical"] = ok
    if deep:
        cmp_py = os.path.join(ROOT, "tests", "compare_rrm_dat.py")
        out = subprocess.run(
            [sys.executable, cmp_py, ref[0], ref[1], new[0], new[1],
             "--mode", "exact"], stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT)
        result["compare_rrm_dat_exit"] = out.returncode
        result["compare_rrm_dat"] = out.stdout.decode(
            "utf-8", "replace").strip()[-400:]
    return result


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------

def summarize(runs):
    """Aggregate the repetitions of one configuration."""
    good = [r for r in runs if r["exit_code"] == 0 and not r["timed_out"]]
    walls = [r["wall_s"] for r in good]
    summary = {
        "reps": len(runs),
        "ok_reps": len(good),
        "timed_out": any(r["timed_out"] for r in runs),
        "exit_codes": sorted({r["exit_code"] for r in runs}),
        "wall_median_s": median(walls),
        "wall_min_s": min(walls) if walls else None,
        "wall_max_s": max(walls) if walls else None,
        "wall_stdev_s": round(spread(walls), 4),
        "cpu_total_median_s": median([r["cpu_total_s"] for r in good]),
        "max_single_peak_rss_kb":
            max([r["max_single_peak_rss_kb"] for r in good], default=None),
        # Same quantity from the sampler. Comparing it with the exact figure
        # above measures how much the sampling interval loses.
        "sampled_max_single_peak_rss_kb":
            max([r["sampled_max_single_peak_rss_kb"] for r in good],
                default=None),
        "sum_peak_rss_kb":
            max([r["sum_peak_rss_kb"] for r in good], default=None),
        "concurrent_peak_rss_kb":
            max([r["concurrent_peak_rss_kb"] for r in good], default=None),
    }
    gen = [r["gap_generate_ms"] for r in good if r.get("gap_generate_ms")]
    if gen:
        summary["gap_generate_median_ms"] = median(gen)
        summary["gap_read_median_ms"] = median(
            [r["gap_read_ms"] for r in good if r.get("gap_read_ms")])
    return summary


def markdown_report(report):
    env = report["environment"]
    st = report["input"]["stats"]
    lines = []
    lines.append("### %s" % report["label"])
    lines.append("")
    lines.append("input `%s` (sha256 `%s`)  " % (
        report["input"]["path"], report["input"]["sha256"][:16]))
    if "nvert" in st:
        lines.append("|sym| = %s, %s EQs, %s TSs, %s vertices, %s edges  " % (
            st.get("sym_order"), st.get("neq"), st.get("nts"),
            st.get("nvert"), st.get("nedge")))
    if not report.get("comparison_reference_available", True):
        lines.append("**%s did not produce output, so the byte comparison "
                     "could not be run for this input.**  " % report["reference"])
    lines.append("MEM=%s, reps=%d, timeout=%ss, GAP %s, %d CPUs, commit %s%s"
                 % (report["mem"], report["reps"], report["timeout"],
                    env["gap_version"], env["cpus"],
                    (env["git"]["commit"] or "?")[:12],
                    " (dirty)" if env["git"]["dirty"] else ""))
    lines.append("")
    lines.append("| config | wall median (s) | wall min-max (s) | stdev (s) | "
                 "CPU total (s) | max single peak RSS (MiB) | sum of peaks "
                 "(MiB) | concurrent peak RSS (MiB) | speedup vs %s | bytes "
                 "identical |" % report["reference"])
    lines.append("|---|---|---|---|---|---|---|---|---|---|")
    ref = report["configs"].get(report["reference"], {}).get(
        "summary", {}).get("wall_median_s")
    for name in report["order"]:
        entry = report["configs"][name]
        s = entry["summary"]
        mib = lambda kb: "%.0f" % (kb / 1024.0) if kb else "-"  # noqa: E731
        if s["wall_median_s"] is None:
            row = [name, "n/a (timeout)" if s["timed_out"] else "n/a (failed)",
                   "-", "-", "-", "-", "-", "-", "-",
                   entry.get("comparison", {}).get("byte_identical", "-")]
        else:
            speed = ("%.2fx" % (ref / s["wall_median_s"])
                     if ref and s["wall_median_s"] else "-")
            row = [
                name,
                "%.2f" % s["wall_median_s"],
                "%.2f-%.2f" % (s["wall_min_s"], s["wall_max_s"]),
                "%.2f" % s["wall_stdev_s"],
                "%.1f" % s["cpu_total_median_s"],
                mib(s["max_single_peak_rss_kb"]),
                mib(s["sum_peak_rss_kb"]),
                mib(s["concurrent_peak_rss_kb"]),
                speed,
                {True: "yes", False: "NO"}.get(
                    entry.get("comparison", {}).get("byte_identical"),
                    "reference" if name == report["reference"] else "-"),
            ]
        lines.append("| " + " | ".join(str(c) for c in row) + " |")
    lines.append("")
    return "\n".join(lines)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--gfile", required=True,
                    help="GAP input produced by rrm_reconstruction_v18.py or "
                         "tools/make_synthetic_input.py")
    ap.add_argument("--label", help="name for this input in the report")
    ap.add_argument("--config", action="append", dest="configs",
                    type=parse_config, required=True,
                    help="v11 | fast | par:<k>; repeatable, report order "
                         "preserved (reference runs first)")
    ap.add_argument("--reps", type=int, default=3,
                    help="repetitions per configuration (default 3)")
    ap.add_argument("--reps-for", action="append", default=[],
                    metavar="CONFIG=N",
                    help="repetitions for one configuration, e.g. v11=1 for a "
                         "run too expensive to repeat; repeatable")
    ap.add_argument("--mem", default="2g", help="GAP -m per process")
    ap.add_argument("--gap", default=os.environ.get("GAP", "gap"))
    ap.add_argument("--outdir", required=True,
                    help="directory for raw output; keep it outside the repo")
    ap.add_argument("--timeout", type=float, default=0,
                    help="seconds per run, 0 = unlimited. A run that is cut "
                         "off is reported as timed out and excluded from "
                         "speedups")
    ap.add_argument("--interval", type=float, default=0.02,
                    help="/proc sampling interval in seconds")
    ap.add_argument("--reference", help="configuration to compare bytes "
                                       "against (default: the first one)")
    ap.add_argument("--deep-compare", action="store_true",
                    help="also run tests/compare_rrm_dat.py --mode exact")
    ap.add_argument("--keep-raw", action="store_true",
                    help="keep every run's dat files (default: keep the "
                         "reference run and delete the rest after comparing)")
    ap.add_argument("--no-vlabel", dest="vlabel", action="store_false")
    ap.add_argument("--no-elabel", dest="elabel", action="store_false")
    ap.add_argument("--json", help="write the full report as JSON ('-' stdout)")
    ap.add_argument("--markdown", help="write a Markdown table ('-' stdout)")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.gfile):
        ap.error("missing input %s" % args.gfile)
    if args.reps < 1:
        ap.error("--reps must be >= 1")
    label = args.label or os.path.basename(args.gfile)
    names = [c["name"] for c in args.configs]
    if len(set(names)) != len(names):
        ap.error("duplicate configurations: %s" % names)
    reps_for = {}
    for item in args.reps_for:
        name, _, value = item.partition("=")
        if name not in names or not value.isdigit() or int(value) < 1:
            ap.error("--reps-for takes CONFIG=N for a configuration in use, "
                     "got %r" % item)
        reps_for[name] = int(value)
    reference = args.reference or names[0]
    if reference not in names:
        ap.error("--reference %s is not among the configurations" % reference)
    if not args.vlabel or not args.elabel:
        # The driver always requests labels; comparing a labelled parallel run
        # against an unlabelled sequential one would be meaningless.
        for cfg in args.configs:
            if cfg["kind"] == "par":
                ap.error("--no-vlabel/--no-elabel cannot be compared with "
                         "par:k, which always writes labels")

    outdir = os.path.abspath(args.outdir)
    if outdir == ROOT or outdir.startswith(ROOT + os.sep):
        ap.error("--outdir must be outside the repository (%s)" % ROOT)
    os.makedirs(outdir, exist_ok=True)

    stats = input_stats(args)
    nts = stats.get("nts", 0)

    report = {
        "label": label,
        "reference": reference,
        "order": names,
        "reps": args.reps,
        "mem": args.mem,
        "timeout": args.timeout,
        "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "outdir": outdir,
        "input": {
            "path": os.path.relpath(os.path.abspath(args.gfile), ROOT),
            "sha256": sha256_file(args.gfile),
            "bytes": os.path.getsize(args.gfile),
            "stats": stats,
        },
        "environment": {
            "gap": args.gap,
            "gap_version": gap_version(args.gap),
            "uname": " ".join(platform.uname()),
            "cpu_model": cpu_model(),
            "cpus": os.cpu_count(),
            "mem_total_kb": mem_total_kb(),
            "python": sys.version.split()[0],
            "git": git_state(),
        },
        "configs": {},
    }

    ref_pair = None
    # Establish the reference before comparing (and deleting) other outputs.
    # Keep the requested order in report["order"] for presentation.
    execution_configs = sorted(args.configs,
                               key=lambda cfg: cfg["name"] != reference)
    for cfg in execution_configs:
        entry = {"workers": cfg["workers"], "runs": []}
        if cfg["kind"] == "par" and cfg["workers"] > 1 and nts:
            active, slices = ts_slices(cfg["workers"], nts)
            ts_edges = stats.get("ts_edges") or []
            load = []
            for w, (lo, hi) in enumerate(slices):
                edges = sum(ts_edges[lo - 1:hi]) if ts_edges else None
                load.append({"worker": w, "ts_lo": lo, "ts_hi": hi,
                             "ts_count": max(0, hi - lo + 1),
                             "assigned_edges": edges})
            entry["active_workers"] = active
            entry["planned_load"] = load
        report["configs"][cfg["name"]] = entry

        cfg_reps = reps_for.get(cfg["name"], args.reps)
        entry["reps_requested"] = cfg_reps
        for rep in range(1, cfg_reps + 1):
            run_dir = os.path.join(outdir, "%s.%s.rep%d" %
                                   (label, cfg["name"].replace(":", ""), rep))
            shutil.rmtree(run_dir, ignore_errors=True)
            os.makedirs(run_dir)
            cmd, env, stdin_text, published = build_command(cfg, args, run_dir)
            log_path = os.path.join(run_dir, "harness.log")
            sys.stderr.write("[%s] %s rep %d/%d ... " %
                             (label, cfg["name"], rep, cfg_reps))
            sys.stderr.flush()
            run = run_measured(cmd, env, stdin_text, log_path,
                               args.timeout, args.interval)
            run["rep"] = rep
            run["run_dir"] = run_dir

            # GAP's own clock, when this harness wrote the GAP input.
            if stdin_text is not None:
                try:
                    with open(log_path, "r", errors="replace") as fh:
                        text = fh.read()
                except OSError:
                    text = ""
                for key, tag in (("gap_read_ms", "READ_MS"),
                                 ("gap_generate_ms", "GENERATE_MS"),
                                 ("gap_runtime_ms", "GAP_RUNTIME_MS")):
                    m = re.search(r"RRM_BENCH_%s=(\d+)" % tag, text)
                    if m:
                        run[key] = int(m.group(1))

            pair = None
            if run["exit_code"] == 0 and not run["timed_out"]:
                pair = published()
                run["output"] = describe_output(*pair)
                if cfg["kind"] == "par" and cfg["workers"] > 1:
                    run["worker_logs"] = sorted(
                        os.path.basename(p) for p in
                        _glob_logs(os.path.dirname(pair[0])))
                    run.update(_phase_times(run))
            sys.stderr.write("%.2fs%s\n" % (
                run["wall_s"],
                "" if run["exit_code"] == 0 and not run["timed_out"]
                else " FAILED (exit %d%s)" % (run["exit_code"],
                                              ", timeout" if run["timed_out"]
                                              else "")))
            sys.stderr.flush()
            entry["runs"].append(run)
            stop_reps = run["timed_out"]

            if pair and cfg["name"] == reference and ref_pair is None:
                keep = os.path.join(outdir, "reference.%s" % label)
                shutil.rmtree(keep, ignore_errors=True)
                os.makedirs(keep)
                ref_pair = (os.path.join(keep, "vertices.dat"),
                            os.path.join(keep, "edges.dat"))
                shutil.copyfile(pair[0], ref_pair[0])
                shutil.copyfile(pair[1], ref_pair[1])
            elif pair and ref_pair is not None:
                cmpres = compare_pair(ref_pair, pair, args.deep_compare)
                run["comparison"] = cmpres
                prev = entry.get("comparison")
                if prev is None or (prev.get("byte_identical") and
                                    not cmpres.get("byte_identical")):
                    entry["comparison"] = cmpres

            if run["timed_out"] and rep < cfg_reps:
                # A configuration that cannot finish once is not repeated; the
                # limit is what gets reported, not a partial time.
                sys.stderr.write("[%s] %s: cut off at %.0fs, skipping the "
                                 "remaining %d repetition(s)\n"
                                 % (label, cfg["name"], args.timeout,
                                    cfg_reps - rep))
            if not args.keep_raw:
                # Raw dat files are large; the digests and sizes are recorded.
                shutil.rmtree(os.path.join(run_dir, "bundle"),
                              ignore_errors=True)
                for name in ("vertices.dat", "edges.dat"):
                    p = os.path.join(run_dir, name)
                    if os.path.exists(p):
                        os.remove(p)

            if stop_reps:
                break

        entry["summary"] = summarize(entry["runs"])
        if cfg["name"] == reference and "comparison" not in entry:
            entry["comparison"] = {"byte_identical": None,
                                   "note": "reference configuration"}

    # Without a successful reference run there is nothing to compare against;
    # say so rather than leaving the empty comparison to be read as agreement.
    report["comparison_reference_available"] = ref_pair is not None
    report["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")

    if args.json:
        text = json.dumps(report, indent=2, sort_keys=False)
        if args.json == "-":
            sys.stdout.write(text + "\n")
        else:
            os.makedirs(os.path.dirname(os.path.abspath(args.json)),
                        exist_ok=True)
            with open(args.json, "w") as fh:
                fh.write(text + "\n")
    md = markdown_report(report)
    if args.markdown == "-" or not args.markdown:
        sys.stdout.write(md + "\n")
    else:
        with open(args.markdown, "w") as fh:
            fh.write(md + "\n")

    failed = [n for n in names
              if report["configs"][n]["summary"]["ok_reps"] == 0]
    differing = [n for n in names
                 if report["configs"][n].get("comparison", {})
                 .get("byte_identical") is False]
    if differing:
        sys.stderr.write("output MISMATCH against %s: %s\n"
                         % (reference, ", ".join(differing)))
        return 2
    if failed:
        sys.stderr.write("configurations with no successful run: %s\n"
                         % ", ".join(failed))
        return 1
    return 0


def _glob_logs(run_dir):
    try:
        return [os.path.join(run_dir, n) for n in os.listdir(run_dir)
                if n.endswith(".log")]
    except OSError:
        return []


def _phase_times(run):
    """Split a parallel run into setup / master / workers / publish."""
    procs = run.get("processes", [])
    master = [p for p in procs if p["role"] == "master"]
    workers = [p for p in procs if p["role"].startswith("worker:")]
    out = {}
    if master:
        out["master_wall_s"] = master[0]["wall_s"]
        out["master_cpu_s"] = master[0]["cpu_s"]
    if workers:
        out["worker_wall_max_s"] = max(p["wall_s"] for p in workers)
        out["worker_wall_min_s"] = min(p["wall_s"] for p in workers)
        out["worker_cpu_total_s"] = round(
            sum(p["cpu_s"] for p in workers), 3)
        out["workers_observed"] = len(workers)
        # Wall time not attributable to a GAP process: driver startup, shard
        # concatenation, vertex-map validation, manifest and publication.
        gap_wall = out.get("master_wall_s", 0.0) + out["worker_wall_max_s"]
        out["driver_overhead_wall_s"] = round(
            max(0.0, run["wall_s"] - gap_wall), 4)
    return out


if __name__ == "__main__":
    sys.exit(main())
