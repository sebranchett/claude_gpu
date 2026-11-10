#!/bin/bash
#SBATCH --job-name=yambo-qe-prep
#SBATCH --partition=compute-p1,compute-p2
#SBATCH --time=01:00:00
#SBATCH --ntasks=16
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=3900M
#SBATCH --account=research-as-cheme
#SBATCH --output=%x-%j.out

# Bulk hBN (Yambo tutorial): QE scf + nscf on CPU, then p2y and Yambo setup with the
# CPU build.  The resulting SAVE is shared by the GPU and CPU test jobs.
# Needs 02_build_cpu to have finished.
set -euo pipefail
source "$SLURM_SUBMIT_DIR/common.sh"

NBND=${NBND:-200}          # tutorial uses 100; more bands make the timings meaningful
# Yambo programs must be started with srun, even for one task (see UPGRADING.md).
YRUN="srun --nodes=1 --ntasks=1 --mpi=pmix"
prep=$TEST_ROOT/prep

rm -rf "$prep"
mkdir -p "$prep"
tar -xzf "$SRC_DIR/hBN.tar.gz" -C "$prep"
cd "$prep/hBN/PWSCF"
sed -i "s/nbnd *= *100/nbnd = $NBND/" hBN_nscf.in
grep -q "nbnd = $NBND" hBN_nscf.in || die "could not set nbnd in hBN_nscf.in"

echo "== Quantum ESPRESSO"
set +u
module purge
module use --append "$QE_MODULE_PATH"
module load "$QE_MODULE" || die "cannot load $QE_MODULE from $QE_MODULE_PATH"
set -u
which pw.x
srun pw.x -nk 4 -in hBN_scf.in  > hBN_scf.out
srun pw.x -nk 4 -in hBN_nscf.in > hBN_nscf.out
grep -m1 -E "Program PWSCF v" hBN_scf.out || true    # QE version actually used
grep -E "JOB DONE|highest occupied|Fermi" hBN_scf.out hBN_nscf.out || true

echo "== p2y + setup (CPU Yambo)"
load_toolchain cpu
cd hBN.save
$YRUN p2y > p2y.log 2>&1 || { tail -30 p2y.log; die "p2y failed (see above)"; }
[ -d SAVE ] || { tail -30 p2y.log; die "p2y produced no SAVE"; }

mkdir -p "$TEST_ROOT/hBN_SAVE"
rm -rf "$TEST_ROOT/hBN_SAVE/SAVE"
mv SAVE "$TEST_ROOT/hBN_SAVE/"
cd "$TEST_ROOT/hBN_SAVE"
$YRUN yambo > setup.log 2>&1 || { tail -30 setup.log; die "yambo setup failed"; }
grep -iE "bands|k-points|Filled" r_setup | head -20 || true
echo "PREP OK: $TEST_ROOT/hBN_SAVE"
