#!/bin/bash
#SBATCH --job-name=yambo-bse-diag
#SBATCH --partition=compute-p1
#SBATCH --time=00:30:00
#SBATCH --nodes=1
#SBATCH --ntasks=24
#SBATCH --cpus-per-task=2
#SBATCH --mem-per-cpu=3900M
#SBATCH --account=research-as-cheme
#SBATCH --output=%x-%j.out

# Exact BSE spectrum by full diagonalization, to judge the Haydock spectra.
#
# The Haydock solver is iterative and stops at about 2 %; different runs of the same test
# can stop at different points (cpu_p2: 110 iterations, the others 59) and give different
# spectra. This BSE is small (bands 5-12: 4 x 4 x 72 k = 1152 transitions), so it can be
# diagonalized exactly. Like the SLEPc step of the test, it reuses the screening and kernel
# of a test run's bse_h step (-J bse_d,bse_h), so only the solver differs.
#
# Options (sbatch --export=ALL,...):
#   SRC=label    test run whose SAVE, gw and bse_h databases are used (default cpu_p1)
#   LABEL=name   run directory (default <SRC>_diag)
# Then it compares every Haydock spectrum it finds under $TEST_ROOT and the 5.3.0 reference
# directory with the exact one, the same way 08_compare.py does (relative to the largest value).
set -euo pipefail
source "${SLURM_SUBMIT_DIR:?submit from the scripts directory}/common.sh"

src=${SRC:-cpu_p1}
label=${LABEL:-${src}_diag}
SRC_RUN=$TEST_ROOT/$src
RUN=$TEST_ROOT/$label
for d in SAVE gw bse_h; do
    [ -d "$SRC_RUN/$d" ] || die "no $d in $SRC_RUN; run the test (05/06) for $src first"
done

type module > /dev/null 2>&1 || source /etc/profile
module purge
module use "$MODULE_DIR"
module load "yambo-cpu/$YAMBO_VERSION"
export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
export SRUN_CPUS_PER_TASK=$SLURM_CPUS_PER_TASK
export OMP_PLACES=cores OMP_PROC_BIND=close
YAMBO="srun --mpi=pmix yambo"
YAMBO1="srun --nodes=1 --ntasks=1 --mpi=pmix yambo"
echo "Yambo: $(which yambo); MPI: OPAL_PREFIX=${OPAL_PREFIX:-unset}"
echo "Layout: $SLURM_NTASKS MPI tasks x $OMP_NUM_THREADS OpenMP threads on $(hostname)"

rm -rf "${RUN:?}"
mkdir -p "$RUN"
cp -r "$SRC_RUN"/{SAVE,gw,bse_h} "$RUN/"
cd "$RUN"
echo "Run directory: $RUN (databases from $SRC_RUN)"

set_var() {
    grep -qE "^ *$2 *=" "$1" || die "$2 not found in $1"
    sed -i -E "s|^ *$2 *=.*|$2= $3|" "$1"
}
set_block() {
    grep -qE "^ *% *$2([ #].*)?$" "$1" || die "block $2 not found in $1"
    sed -i -E "/^ *% *$2([ #].*)?$/{n;s/.*/ $3/}" "$1"
}

# Same BSE parameters as the test's bse_h and bse_s steps (example/yambo_hBN_gpu.slurm);
# -y d: full diagonalization.
$YAMBO1 -F bse_d.in -o b -k sex -y d -V qp -Q > gen_bse_d.log 2>&1
set_block bse_d.in BSEBands "5 | 12 |"
set_var   bse_d.in BSENGexx "30 Ry"
set_var   bse_d.in BSENGBlk "6 Ry"
set_block bse_d.in BEnRange "2.0 | 10.0 | eV"
set_var   bse_d.in BEnSteps "500"
set_var   bse_d.in KfnQPdb '"E < ./gw/ndb.QP"'

t0=$(date +%s)
$YAMBO -F bse_d.in -J bse_d,bse_h > log_bse_d.txt 2>&1
grep -qs "Game Over" r-bse_d_* || die "yambo bse_d did not finish; see $RUN/log_bse_d.txt and r-bse_d_*"
echo "bse_d took $(( $(date +%s) - t0 )) s"
# The kernel must have been read, not recomputed: otherwise the parameters differ from bse_h.
grep -hiE 'BS_PAR|kernel' r-bse_d_* | head -5 || true

exact=$(ls o-bse_d.eps_q1_diago* 2> /dev/null | head -1 || true)
[ -n "$exact" ] || die "no o-bse_d.eps_q1_diago* file in $RUN"
echo "== Exact spectrum: $RUN/$exact"

# Worst |difference| in Im(eps) (column 2) and Re(eps) (column 3), relative to the exact
# spectrum's largest |value| in that column, and the energy where it occurs.
echo "== Haydock spectra against the exact one (Haydock tolerance in 08_compare.py: 2 %)"
printf "%-45s %12s %12s %s\n" "run" "Im(eps)" "Re(eps)" "worst at"
for f in "$TEST_ROOT"/*/o-bse_h.eps_q1_haydock_bse /scratch/$USER/yambo_${YAMBO_VERSION}_reference/*/o-bse_h.eps_q1_haydock_bse; do
    [ -f "$f" ] || continue
    it=$(grep -h 'Iterations' "$(dirname "$f")"/r-bse_h_* 2> /dev/null | awk '{print $NF; exit}' || true)
    # Data lines are matched by position (both files: 500 energies from 2 to 10 eV).
    awk -v name="$(basename "$(dirname "$f")") (${it:-?} it.)" '
        /^#/ || NF == 0 { next }
        FNR == NR { i++; E[i] = $1; X[i, 2] = $2; X[i, 3] = $3; next }
        { j++
          if (j > i || $1 - E[j] > 1e-3 || E[j] - $1 > 1e-3) { bad = 1; exit }
          for (c = 2; c <= 3; c++) {
              v = X[j, c] < 0 ? -X[j, c] : X[j, c]; if (v > m[c]) m[c] = v
              d = X[j, c] - $c; if (d < 0) d = -d
              if (d > w[c]) { w[c] = d; e[c] = $1 } } }
        END { if (bad || j != i) { printf "%-45s energy grids differ, skipped\n", name; exit }
              printf "%-45s %11.1f%% %11.1f%% %.2f / %.2f eV\n", name, 100 * w[2] / m[2], 100 * w[3] / m[3], e[2], e[3] }' "$exact" "$f"
done
echo "DIAG OK: $RUN"
