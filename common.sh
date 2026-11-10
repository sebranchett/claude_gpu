# Shared settings for the Yambo build and test scripts. Sourced, not executed.

YAMBO_VERSION=5.3.0
STACK=2026                              # DelftBlue software stack: 'module load 2026'
QE_MODULE_PATH=/projects/electronic_structure/.modulefiles   # project QE modules (module use --append)
QE_MODULE=qe

PROJ=/projects/electronic_structure/yambo_${YAMBO_VERSION}_$STACK   # one directory per version and stack
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

# install_modulefile gpu|cpu : install modulefiles/yambo.lua as yambo-<flavour>/<version>.lua
# in $MODULE_DIR; the modulefile takes the flavour and version from that name.
install_modulefile() {
    mkdir -p "$MODULE_DIR/yambo-$1"
    cp "$SCRIPT_DIR/modulefiles/yambo.lua" "$MODULE_DIR/yambo-$1/$YAMBO_VERSION.lua"
}

# load_toolchain gpu|cpu : compilers, MPI and Yambo from our modulefile (the stack, gcc
# for libatomic, nvhpc, and HPC-X's MPI settings; see UPGRADING.md), installed first,
# so the builds get the same environment as the tests and users.
load_toolchain() {
    install_modulefile "$1"
    set +u      # Lmod and /etc/profile are not written for 'set -u'
    type -t module > /dev/null || source /etc/profile   # child shells may lack 'module'
    module purge
    module use "$MODULE_DIR"
    module load "yambo-$1/$YAMBO_VERSION"
    set -u
    echo "Toolchain: $(command -v nvfortran mpif90 | tr '\n' ' ')OPAL_PREFIX=$OPAL_PREFIX"
}

# load_autotools gpu|cpu : Yambo runs 'autoreconf' on libxc, which needs libtool; the
# nodes have none, the stack's autotools modules (under the gpu/cpu module) do.
load_autotools() {
    if ! command -v libtoolize > /dev/null; then
        set +u
        module load "$1" autoconf automake libtool
        set -u
    fi
    # Make sure aclocal finds libtool.m4 next to libtoolize.
    export ACLOCAL_PATH="$(dirname "$(command -v libtoolize)")/../share/aclocal${ACLOCAL_PATH:+:$ACLOCAL_PATH}"
    echo "autotools: $(autoconf --version | head -1); $(libtoolize --version | head -1)"
}

die() { echo "ERROR: $*" >&2; exit 1; }
