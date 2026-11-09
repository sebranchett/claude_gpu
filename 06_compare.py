#!/usr/bin/env python3
"""Compare Yambo test runs: numerical agreement of the outputs and wall times.

Usage (on a login node):
    python3 -I 06_compare.py /scratch/$USER/yambo_5.3.0_tests/cpu_p2 \
                             /scratch/$USER/yambo_5.3.0_tests/gpu_small [more runs ...]
The first run is the reference; every o-* file it has is compared with the same file
in the other runs, and wall times are shown as speed-ups relative to the reference.
"""
import re
import sys
from pathlib import Path

QP_TOL_EV = 0.005   # max |difference| in QP corrections (E-Eo), eV
REL_TOL = 0.01      # max difference in other outputs, relative to the column's largest value


def read_table(path):
    rows = []
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        try:
            rows.append([float(x) for x in line.split()])
        except ValueError:
            pass
    return rows


def column_labels(path):
    """Column titles from Yambo's header line, e.g. '# E/ev[1] EEL/Im[2] ...' -> {1: 'E/ev', 2: 'EEL/Im'}."""
    labels = {}
    for line in path.read_text().splitlines():
        if line.lstrip().startswith("#") and "[1]" in line:
            labels = {int(n): name for name, n in re.findall(r"(\S+?)\s*\[(\d+)\]", line)}
    return labels


def compare_file(ref, other):
    a, b = read_table(ref), read_table(other)
    if len(a) != len(b) or not a:
        return False, f"row count differs ({len(a)} vs {len(b)})"
    worst, worst_col = 0.0, None
    for col in range(min(len(a[0]), len(b[0]))):
        scale = max(abs(r[col]) for r in a) or 1.0
        diff = max(abs(ra[col] - rb[col]) for ra, rb in zip(a, b))
        if ref.name.endswith(".qp"):
            rel = diff / QP_TOL_EV * REL_TOL   # judge QP columns on the absolute eV tolerance
        else:
            rel = diff / scale
        if rel > worst:
            worst, worst_col = rel, col
    ok = worst <= REL_TOL
    if worst_col is None:
        detail = "identical"
    else:
        label = column_labels(ref).get(worst_col + 1)
        name = f"{worst_col + 1} ({label})" if label else f"{worst_col + 1}"
        detail = f"worst column {name} at {worst / REL_TOL:.0%} of tolerance"
    if ref.name.endswith(".qp"):
        dmax = max(abs(ra[3] - rb[3]) for ra, rb in zip(a, b))
        detail = f"max |d(E-Eo)| = {dmax * 1000:.2f} meV (tol {QP_TOL_EV * 1000:.0f} meV); " + detail
    return ok, detail


def read_timings(run):
    t = {}
    f = run / "timings.tsv"
    if f.exists():
        for line in f.read_text().splitlines()[1:]:
            _, step, sec = line.split("\t")
            t[step] = float(sec)
    return t


def main(paths):
    runs = [Path(p) for p in paths]
    ref = runs[0]
    all_ok = True
    for run in runs[1:]:
        print(f"\n== {run.name} vs reference {ref.name}")
        for out in sorted(ref.glob("o-*")):
            other = run / out.name
            if not other.exists():
                print(f"  MISSING  {out.name}")
                all_ok = False
                continue
            ok, detail = compare_file(out, other)
            all_ok &= ok
            print(f"  {'OK  ' if ok else 'DIFF'}     {out.name}: {detail}")

    print("\n== Wall time [s] (speed-up vs reference)")
    timings = {r.name: read_timings(r) for r in runs}
    steps = list(timings[ref.name])
    print(f"  {'step':8s}" + "".join(f"{r.name:>24s}" for r in runs))
    for step in steps:
        base = timings[ref.name].get(step)
        cells = []
        for r in runs:
            t = timings[r.name].get(step)
            cells.append(f"{'-':>24s}" if t is None else f"{t:12.1f} ({base / t:5.2f}x)   ")
        print(f"  {step:8s}" + "".join(cells))

    print("\nVALIDATION", "PASSED" if all_ok else "FAILED (inspect the DIFF lines)")
    return 0 if all_ok else 1


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1:]))
