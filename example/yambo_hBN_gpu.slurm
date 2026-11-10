#!/bin/bash
#SBATCH --job-name=yambo-hBN-example
#SBATCH --partition=gpu-a100
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --cpus-per-task=16
#SBATCH --gpus-per-task=1
#SBATCH --mem-per-cpu=3500M
#SBATCH --account=research-as-cheme
#SBATCH --output=%x-%j.out

# Example: GW + BSE for bulk hBN with the GPU build of Yambo 5.3.0 on DelftBlue.
#
# Based on the Yambo tutorial https://wiki.yambo-code.eu/wiki/index.php?title=Bulk_material:_h-BN
# (14 k-points, 200 bands). It runs three steps:
#   1. GW: plasmon-pole G0W0 quasiparticle corrections for bands 7-10
#   2. BSE with the Haydock solver, using the GW energies (optical spectrum)
#   3. BSE with SLEPc (the 20 lowest excitons), reusing the screening and kernel of step 2
#
# How to use it:
#   1. Make a Yambo SAVE for bulk hBN: a Quantum ESPRESSO scf + nscf run (inputs in the
#      tutorial's hBN.tar.gz), converted with p2y. Examples of how to do that:
#        https://github.com/sebranchett/MoS2-QE-Yambo-pnas/blob/main/01_scf.sh
#        https://simulationsuite.streamlit.app/
#   2. Copy this file to a directory of your own, and set SAVE_SRC below to your SAVE.
#   3. Change --account above to your own project account.
#   4. sbatch yambo_hBN_gpu.slurm
# The results go to /scratch/$USER/yambo_hBN_example/<job id>.
#
# Layout: one full gpu-a100 node, 4 MPI tasks with one A100 each and 16 OpenMP
# threads per task. Use one MPI task per GPU. To try it on gpu-a100-small instead
# (2 MIG slices: quicker through the queue, but not representative of performance),
# override the layout when submitting:
#   sbatch --partition=gpu-a100-small --ntasks=2 --cpus-per-task=2 --mem-per-cpu=7500M yambo_hBN_gpu.slurm
#
# This script is also the test of the installation (run_tests.sh in the build scripts),
# which sets the variables below that end in ':-...' to its own values.

set -eo pipefail    # stop at the first error
trap 'echo "ERROR: the last command failed; see the log_*.txt and gen_*.log files in ${RUN:-the run directory}"' ERR

# Your SAVE directory (made by p2y; see step 1 above). It is copied, not changed.
SAVE_SRC=${SAVE_SRC:-/scratch/$USER/yambo_5.3.0_tests/hBN_SAVE/SAVE}
NB=${NB:-200}       # bands used in GW and BSE; at most the number of bands in your SAVE
# The band ranges below (7-10 for GW, 5-12 for BSE) are for hBN, which has 8 occupied
# bands. For another material, choose them around its own band gap.
# Each run gets its own directory.
RUN=${RUN:-/scratch/$USER/yambo_hBN_example/$SLURM_JOB_ID}

[ -d "$SAVE_SRC" ] || { echo "ERROR: no SAVE directory at $SAVE_SRC; set SAVE_SRC in this script"; exit 1; }

# Software. The module loads nvhpc and sets up its MPI.
type module > /dev/null 2>&1 || source /etc/profile
module purge
module use "${YAMBO_MODULES:-/projects/electronic_structure/yambo_gpu_5.3.0_2026/modulefiles}"
module load "${YAMBO_MODULE:-yambo-gpu/5.3.0}"

# OpenMP threads per MPI task, each thread on its own core.
export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
export SRUN_CPUS_PER_TASK=$SLURM_CPUS_PER_TASK    # srun does not inherit --cpus-per-task
export OMP_PLACES=cores OMP_PROC_BIND=close

# Always start yambo with srun, even for one process: started directly, MPI fails.
YAMBO="srun --mpi=pmix yambo"                          # all tasks
YAMBO1="srun --nodes=1 --ntasks=1 --mpi=pmix yambo"    # one task, to write input files

echo "Yambo: $(which yambo)"
echo "Layout: $SLURM_NTASKS MPI tasks x $OMP_NUM_THREADS OpenMP threads on $(hostname)"
# Each task should have its own CPUs (and, on GPU nodes, its own GPU).
srun --mpi=pmix bash -c 'echo "task $SLURM_PROCID: CPUs $(taskset -cp $$ | sed "s/.*: //") GPU ${CUDA_VISIBLE_DEVICES:-none}"' | sort -V | awk 'NR <= 8'
if command -v nvidia-smi > /dev/null; then nvidia-smi -L; fi

mkdir -p "$RUN"
cp -r "$SAVE_SRC" "$RUN/"
cd "$RUN"
echo "Run directory: $RUN"

# Yambo's setup (initialisation) run, if SAVE has not had one yet: plain 'yambo'
# with no options writes the symmetry and k-point databases into SAVE.
if [ ! -f SAVE/ndb.gops ]; then
    echo "== Setup"
    $YAMBO1 > log_setup.txt 2>&1
fi

# Yambo writes a default input file with all variables (-F name, -Q: do not open an
# editor); these two functions then change the values we need.
# set_var FILE VAR VALUE : change the line 'VAR= ...'
set_var() {
    grep -qE "^ *$2 *=" "$1" || { echo "ERROR: $2 not found in $1"; exit 1; }
    sed -i -E "s|^ *$2 *=.*|$2= $3|" "$1"
}
# set_block FILE VAR VALUES : change the line after '% VAR'
set_block() {
    grep -qE "^ *% *$2([ #].*)?$" "$1" || { echo "ERROR: block $2 not found in $1"; exit 1; }
    sed -i -E "/^ *% *$2([ #].*)?$/{n;s/.*/ $3/}" "$1"
}

# run_step NAME INPUT : run yambo on all tasks, check it finished, record the wall time.
# NAME is Yambo's job name (-J): its output files are o-NAME.*, its report r-NAME_*.
printf "label\tstep\tseconds\n" > timings.tsv
run_step() {
    local step=${1%%,*} t0 secs
    t0=$(date +%s.%N)
    $YAMBO -F "$2" -J "$1" > "log_$step.txt" 2>&1
    secs=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')
    grep -qs "Game Over" r-"$step"_* || { echo "ERROR: yambo $step did not finish (no 'Game Over' in its report)"; exit 1; }
    printf "%s\t%s\t%s\n" "$(basename "$RUN")" "$step" "$secs" >> timings.tsv
    echo "$step took $secs s"
}

# --- 1. GW --------------------------------------------------------------------
# -p p: plasmon-pole screening, -g n: Newton solver, -V qp: show the QP variables
echo "== GW"
$YAMBO1 -F gw.in -p p -g n -V qp -Q > gen_gw.log 2>&1
set_var   gw.in EXXRLvcs "40 Ry"         # exchange cutoff
set_block gw.in BndsRnXp "1 | $NB |"     # bands in the screening
set_var   gw.in NGsBlkXp "8 Ry"          # size of the screening matrix
set_block gw.in GbndRnge "1 | $NB |"     # bands in the self-energy
# QP corrections for bands 7-10 (top two valence, bottom two conduction) at all k-points
sed -i -E "/^ *% *QPkrange([ #].*)?$/{n;s/^( *[0-9]+ *\| *[0-9]+ *\|).*/\1 7 | 10 |/}" gw.in
run_step gw gw.in

# --- 2. BSE, Haydock solver ---------------------------------------------------
# -X s: static screening, -o b: BSE optics, -k sex: screened exchange kernel, -y h: Haydock
echo "== BSE (Haydock)"
$YAMBO1 -F bse_h.in -X s -o b -k sex -y h -V qp -Q > gen_bse_h.log 2>&1
set_block bse_h.in BndsRnXs "1 | $NB |"           # bands in the static screening
set_var   bse_h.in NGsBlkXs "6 Ry"                # size of the screening matrix
set_block bse_h.in BSEBands "5 | 12 |"            # bands in the BSE (4 valence, 4 conduction)
set_var   bse_h.in BSENGexx "30 Ry"               # exchange part of the kernel
set_var   bse_h.in BSENGBlk "6 Ry"                # screened part of the kernel
set_block bse_h.in BEnRange "2.0 | 10.0 | eV"     # spectrum energy range
set_var   bse_h.in BEnSteps "500"
set_var   bse_h.in KfnQPdb '"E < ./gw/ndb.QP"'    # use the GW energies from step 1
run_step bse_h bse_h.in

# --- 3. BSE, SLEPc solver -----------------------------------------------------
# -y s: SLEPc. '-J bse_s,bse_h' also reads the screening and kernel from step 2.
echo "== BSE (SLEPc)"
$YAMBO1 -F bse_s.in -o b -k sex -y s -V qp -Q > gen_bse_s.log 2>&1
set_block bse_s.in BSEBands "5 | 12 |"
set_var   bse_s.in BSENGexx "30 Ry"
set_var   bse_s.in BSENGBlk "6 Ry"
set_block bse_s.in BEnRange "2.0 | 10.0 | eV"
set_var   bse_s.in BEnSteps "500"
set_var   bse_s.in BSSNEig "20"                   # number of excitons
set_var   bse_s.in KfnQPdb '"E < ./gw/ndb.QP"'
run_step bse_s,bse_h bse_s.in

# --- Results ------------------------------------------------------------------
# o-*: output data (QP corrections, spectra, excitons); r-*: reports with timings.
echo "== Results in $RUN"
ls o-* r-*
cat timings.tsv
echo "== QP corrections (o-gw.qp), first lines"
grep -m1 -E '^# *K-point' o-gw.qp || true
awk '!/^#/ && n++ < 8' o-gw.qp
echo "DONE"
