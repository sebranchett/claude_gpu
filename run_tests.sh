#!/bin/bash
# GW + BSE test on bulk hBN, run inside a Slurm job.  Usage: run_tests.sh gpu|cpu <label>
# Steps (each timed separately):
#   gw    : PPA G0W0 quasiparticle corrections
#   bse_h : static screening + SEX kernel + Haydock solver, using the GW energies
#   bse_s : SLEPc partial diagonalisation, reusing the screening and kernel of bse_h
# Results go to $TEST_ROOT/<label>; compare two runs with compare.py.
set -euo pipefail
source "${SLURM_SUBMIT_DIR:?submit from the scripts directory}/common.sh"

flavour=${1:?usage: run_tests.sh gpu|cpu <label>}
label=${LABEL:-${2:?usage: run_tests.sh gpu|cpu <label>}}   # LABEL overrides, to keep earlier runs
run=$TEST_ROOT/$label
LAUNCH=${LAUNCH:-srun --mpi=pmix}
# Generating an input is a one-process yambo run, but HPC-X's MPI cannot start as a
# plain process inside a job, so it also needs the launcher (with one task).
case $LAUNCH in
    mpirun*|mpiexec*) LAUNCH1="${LAUNCH%% *} -np 1" ;;
    *)                LAUNCH1="srun --nodes=1 --ntasks=1 --mpi=pmix" ;;
esac

[ -d "$TEST_ROOT/hBN_SAVE/SAVE" ] || die "no SAVE in $TEST_ROOT/hBN_SAVE; run 03_qe_prep.slurm first"

load_toolchain
export PATH=$(yambo_tree "$flavour")/bin:$PATH
export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK:-1}
# Since Slurm 22.05, srun no longer inherits --cpus-per-task from sbatch: without this,
# each rank may be bound to one CPU while running OMP_NUM_THREADS threads on it.
export SRUN_CPUS_PER_TASK=$OMP_NUM_THREADS
export OMP_PLACES=${OMP_PLACES:-cores} OMP_PROC_BIND=${OMP_PROC_BIND:-close}
which yambo
echo "Layout: $SLURM_NTASKS MPI tasks x $OMP_NUM_THREADS OpenMP threads on $(hostname), launcher: $LAUNCH"
echo "Slurm $(sinfo -V 2>/dev/null | awk '{print $2}'), OMP_PLACES=$OMP_PLACES OMP_PROC_BIND=$OMP_PROC_BIND"
# The CPUs each rank may run on (should be OMP_NUM_THREADS cores, or twice that with hyperthreads).
$LAUNCH bash -c 'echo "rank $SLURM_PROCID: $(nproc) CPUs, affinity $(taskset -cp $$ | sed "s/.*: //")"' | sort -V | awk 'NR <= 4'

if [ "$flavour" = gpu ]; then
    nvidia-smi -L
    # Each rank must see its own GPU / MIG slice.
    $LAUNCH bash -c 'echo "rank $SLURM_PROCID: CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES $(nvidia-smi -L | grep -c MIG) MIG device(s) visible"'
fi

rm -rf "$run"
mkdir -p "$run"
cp -r "$TEST_ROOT/hBN_SAVE/SAVE" "$run/"
cd "$run"
printf "label\tstep\tseconds\n" > timings.tsv

# set_scalar FILE VAR VALUE : replace the 'VAR= ...' line of a generated input
set_scalar() {
    grep -qE "^ *$2 *=" "$1" || die "$2 not found in $1"
    sed -i -E "s|^ *$2 *=.*|$2= $3|" "$1"
}
# set_block FILE VAR VALUES : replace the value line of a '% VAR ... %' block
set_block() {
    grep -qE "^ *% *$2([ #].*)?$" "$1" || die "block $2 not found in $1"
    sed -i -E "/^ *% *$2([ #].*)?$/{n;s/.*/ $3/}" "$1"
}

# set_or_add FILE VAR VALUE : like set_scalar, but appends 'VAR= VALUE' if the input lacks it
set_or_add() {
    if grep -qE "^ *#? *$2 *=" "$1"; then
        sed -i -E "s|^ *#? *$2 *=.*|$2= $3|" "$1"
    else
        echo "$2= $3" >> "$1"
    fi
}

gen_input() {   # gen_input FILE yambo-options... : write a default input with one process
    local f=$1; shift
    $LAUNCH1 yambo -F "$f" "$@" -Q > "gen_$f.log" 2>&1 || { tail -30 "gen_$f.log"; die "generating $f failed"; }
    [ -s "$f" ] || { tail -30 "gen_$f.log"; die "yambo did not write $f"; }
    # Yambo picks X_Threads=1 by itself in the GPU build; X_THREADS=N overrides it.
    if [ -n "${X_THREADS:-}" ]; then
        set_or_add "$f" X_Threads "$X_THREADS"
        grep -E "^ *X_Threads" "$f"
    fi
}

run_yambo() {   # run_yambo JOBSTRING INPUT
    local t0 t1
    t0=$(date +%s.%N)
    $LAUNCH yambo -F "$2" -J "$1" > "log_$1.txt" 2>&1 || { tail -30 "log_$1.txt"; ls LOG 2>/dev/null; die "yambo $1 failed"; }
    t1=$(date +%s.%N)
    grep -qs "Game Over" r-"${1%%,*}"_* || die "yambo $1 did not finish (no 'Game Over' in its report)"
    awk -v l="$label" -v s="${1%%,*}" -v a="$t0" -v b="$t1" 'BEGIN { printf "%s\t%s\t%.1f\n", l, s, b - a }' | tee -a timings.tsv
}

# Bands 1-8 are occupied in hBN (16 valence electrons), so the gap is between bands 8 and 9.
NB=${NB:-200}   # must not exceed the bands in SAVE (100 for the tutorial SAVE)

echo "== GW"
gen_input gw.in -p p -g n -V qp
set_scalar gw.in EXXRLvcs "40 Ry"
set_block  gw.in BndsRnXp "1 | $NB |"
set_scalar gw.in NGsBlkXp "8 Ry"
set_block  gw.in GbndRnge "1 | $NB |"
grep -qE "^ *% *QPkrange([ #].*)?$" gw.in || die "block QPkrange not found in gw.in"
sed -i -E "/^ *% *QPkrange([ #].*)?$/{n;s/^( *[0-9]+ *\| *[0-9]+ *\|).*/\1 7 | 10 |/}" gw.in
grep -A1 QPkrange gw.in
run_yambo gw gw.in

echo "== BSE (Haydock)"
gen_input bse_h.in -X s -o b -k sex -y h -V qp
set_block  bse_h.in BndsRnXs "1 | $NB |"
set_scalar bse_h.in NGsBlkXs "6 Ry"
set_block  bse_h.in BSEBands "5 | 12 |"
set_scalar bse_h.in BSENGexx "30 Ry"
set_scalar bse_h.in BSENGBlk "6 Ry"
set_block  bse_h.in BEnRange "2.0 | 10.0 | eV"
set_scalar bse_h.in BEnSteps "500"
set_scalar bse_h.in KfnQPdb '"E < ./gw/ndb.QP"'
run_yambo bse_h bse_h.in

echo "== BSE (SLEPc)"
gen_input bse_s.in -o b -k sex -y s -V qp
set_block  bse_s.in BSEBands "5 | 12 |"
set_scalar bse_s.in BSENGexx "30 Ry"
set_scalar bse_s.in BSENGBlk "6 Ry"
set_block  bse_s.in BEnRange "2.0 | 10.0 | eV"
set_scalar bse_s.in BEnSteps "500"
set_scalar bse_s.in BSSNEig "20"
set_scalar bse_s.in KfnQPdb '"E < ./gw/ndb.QP"'
run_yambo bse_s,bse_h bse_s.in

echo "== Results"
cat timings.tsv
ls o-*
# The first ~30 lines are the logo and run parameters; show the column titles and data.
grep -m1 -E '^# *K-point' o-gw.qp || true
# awk reads the whole file: "grep | head" gets SIGPIPE, which pipefail turns into a job failure.
awk '!/^#/ && n++ < 20' o-gw.qp
echo "TESTS OK: $run"
