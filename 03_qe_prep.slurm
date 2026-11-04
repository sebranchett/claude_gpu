#!/bin/bash
#SBATCH --job-name=yambo-qe-prep
#SBATCH --partition=compute-p2
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
prep=$TEST_ROOT/prep

rm -rf "$prep"
mkdir -p "$prep"
tar -xzf "$SRC_DIR/hBN.tar.gz" -C "$prep"
cd "$prep/hBN/PWSCF"
sed -i "s/nbnd *= *100/nbnd = $NBND/" hBN_nscf.in
grep -q "nbnd = $NBND" hBN_nscf.in || die "could not set nbnd in hBN_nscf.in"

if [ "${USE_TUTORIAL_SAVE:-0}" = 1 ]; then
    # Fallback if p2y cannot read QE 7.6 output: the tutorial's ready-made SAVE (100 bands).
    echo "== Using the tutorial SAVE instead of QE + p2y"
    mkdir -p "$TEST_ROOT/hBN_SAVE"
    rm -rf "$TEST_ROOT/hBN_SAVE/SAVE"
    cp -r "$prep/hBN/YAMBO/SAVE" "$TEST_ROOT/hBN_SAVE/"
    rm -f "$TEST_ROOT"/hBN_SAVE/SAVE/ndb.gops "$TEST_ROOT"/hBN_SAVE/SAVE/ndb.kindx
    load_toolchain
    export PATH=$(yambo_tree cpu)/bin:$PATH
    cd "$TEST_ROOT/hBN_SAVE"
    yambo > setup.log 2>&1 || die "yambo setup failed"
    echo "PREP OK (tutorial SAVE: submit the tests with --export=ALL,NB=100): $TEST_ROOT/hBN_SAVE"
    exit 0
fi

echo "== Quantum ESPRESSO"
set +u
module purge
module load 2026
module load "$QE_MODULE" || die "cannot load $QE_MODULE; check 'module spider $QE_MODULE' on a compute node"
set -u
which pw.x
srun pw.x -nk 4 -in hBN_scf.in  > hBN_scf.out
srun pw.x -nk 4 -in hBN_nscf.in > hBN_nscf.out
grep -E "JOB DONE|highest occupied|Fermi" hBN_scf.out hBN_nscf.out || true

echo "== p2y + setup (CPU Yambo)"
load_toolchain
export PATH=$(yambo_tree cpu)/bin:$PATH
which p2y yambo
cd hBN.save
p2y > p2y.log 2>&1 || { tail -30 p2y.log; die "p2y failed (QE 7.6 output not readable?). Resubmit with: sbatch --export=ALL,USE_TUTORIAL_SAVE=1 03_qe_prep.slurm"; }
[ -d SAVE ] || { tail -30 p2y.log; die "p2y produced no SAVE"; }

mkdir -p "$TEST_ROOT/hBN_SAVE"
rm -rf "$TEST_ROOT/hBN_SAVE/SAVE"
mv SAVE "$TEST_ROOT/hBN_SAVE/"
cd "$TEST_ROOT/hBN_SAVE"
yambo > setup.log 2>&1 || die "yambo setup failed"
ls -l SAVE
grep -iE "bands|k-points|Filled" r_setup | head -20 || true
echo "PREP OK: $TEST_ROOT/hBN_SAVE"
