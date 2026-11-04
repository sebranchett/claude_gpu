# Shared settings for the Yambo 5.3.0 DelftBlue build. Sourced, not executed.

YAMBO_VERSION=5.3.0
NVHPC_MODULE=nvhpc/25.7
QE_MODULE=qe/7.6
ACCOUNT=research-as-cheme

PROJ=/projects/electronic_structure/yambo_gpu_2026
SRC_DIR=$PROJ/src                       # downloaded tarballs (filled on the login node)
BUILD_ROOT=$PROJ/build                  # build trees; also the install location, do not delete
MODULE_DIR=$PROJ/modulefiles
TEST_ROOT=/scratch/$USER/yambo_${YAMBO_VERSION}_tests

# Directory holding these scripts: the submit dir inside a Slurm job, else the script's own dir.
SCRIPT_DIR=${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}

# Group members may read and execute, only the owner writes.
umask 022

# flavour = gpu | cpu
yambo_tree() { echo "$BUILD_ROOT/$1/yambo-$YAMBO_VERSION"; }

# Lmod and /etc/profile are not written for 'set -u', so relax it around them.
load_toolchain() {
    local had_u=0
    case $- in *u*) had_u=1; set +u ;; esac
    # Child bash processes in a job do not always inherit the module function.
    type -t module > /dev/null || source /etc/profile
    module purge
    module load 2026
    module load "$NVHPC_MODULE"
    if [ "$had_u" = 1 ]; then set -u; fi
}

die() { echo "ERROR: $*" >&2; exit 1; }
