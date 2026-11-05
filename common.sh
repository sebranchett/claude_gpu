# Shared settings for the Yambo 5.3.0 DelftBlue build. Sourced, not executed.

YAMBO_VERSION=5.3.0
NVHPC_MODULE=nvhpc/25.7
GCC_MODULES="compilers gcc"             # gcc 13.4.0 in the 2026 stack; supplies libatomic.so.1
QE_MODULE_PATH=/projects/electronic_structure/.modulefiles   # project QE modules (module use --append)
QE_MODULE=qe
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
    # GCC first, so nvhpc's compilers and MPI come first in the search paths.
    # It provides libatomic.so.1, which nvhpc's HPC-X MPI needs (see ensure_libatomic).
    module load $GCC_MODULES
    module load "$NVHPC_MODULE"
    if [ "$had_u" = 1 ]; then set -u; fi
    ensure_libatomic
}

# The HPC-X Open MPI in nvhpc 25.7 (libmpi_usempif08.so) needs libatomic.so.1,
# which the DelftBlue compute and GPU nodes do not have in the system paths.
# Without it every program linked with mpif90 fails to start (this broke IOTK's
# configure). Normally the GCC module provides it; this checks that, and otherwise
# searches for it. Set LIBATOMIC_DIR to override the search.
# Sets LIBATOMIC_ADDED to the directory added to LD_LIBRARY_PATH, or leaves it empty.
LIBATOMIC_ADDED=
ensure_libatomic() {
    if /sbin/ldconfig -p 2>/dev/null | grep -q 'libatomic\.so\.1 '; then return 0; fi
    local d= c
    local IFS=:
    for c in ${LD_LIBRARY_PATH:-}; do
        if [ -n "$c" ] && [ -e "$c/libatomic.so.1" ]; then echo "libatomic.so.1: found in $c"; return 0; fi
    done
    unset IFS
    for c in "${LIBATOMIC_DIR:-}" \
             "$(dirname "$(gcc -print-file-name=libatomic.so.1 2>/dev/null)" 2>/dev/null)"; do
        if [ -n "$c" ] && [ -e "$c/libatomic.so.1" ]; then d=$c; break; fi
    done
    if [ -z "$d" ]; then
        c=$(timeout 120 find /apps/generic -maxdepth 7 -name libatomic.so.1 -print -quit 2>/dev/null || true)
        [ -n "$c" ] && d=$(dirname "$c")
    fi
    [ -n "$d" ] || die "libatomic.so.1 not found (needed by nvhpc's HPC-X MPI); set LIBATOMIC_DIR in common.sh"
    d=$(cd "$d" && pwd -P)
    export LD_LIBRARY_PATH="$d${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    LIBATOMIC_ADDED=$d
    echo "libatomic.so.1: using $d"
}

# Yambo runs 'autoreconf -i --force' on some libraries (libxc) before configuring
# them. That needs libtoolize and libtool.m4 where aclocal looks; without them it
# fails with "possibly undefined macro: AC_DISABLE_SHARED" and the half-regenerated
# configure then cannot find install-sh. The nodes have /usr/bin/autoconf but not
# (necessarily) libtool, so: check, else try the stack's autotools modules, else die.
LIBTOOL_M4=
have_libtool() {
    LIBTOOL_M4=
    command -v libtoolize > /dev/null 2>&1 || return 1
    command -v aclocal > /dev/null 2>&1 || return 1
    local d lt_share
    lt_share=$(cd "$(dirname "$(command -v libtoolize)")/../share/aclocal" 2>/dev/null && pwd -P) || lt_share=
    local IFS=:
    for d in $(aclocal --print-ac-dir 2>/dev/null) ${ACLOCAL_PATH:-} $lt_share; do
        if [ -n "$d" ] && [ -f "$d/libtool.m4" ]; then LIBTOOL_M4=$d; break; fi
    done
    unset IFS
    [ -n "$LIBTOOL_M4" ] || return 1
    # libtool.m4 found only next to libtoolize: make sure aclocal searches there too.
    if [ "$LIBTOOL_M4" = "$lt_share" ] && [ "$(aclocal --print-ac-dir 2>/dev/null)" != "$lt_share" ]; then
        case ":${ACLOCAL_PATH:-}:" in *":$lt_share:"*) ;; *) export ACLOCAL_PATH="$lt_share${ACLOCAL_PATH:+:$ACLOCAL_PATH}" ;; esac
    fi
    return 0
}
ensure_autotools() {
    local had_u=0 m
    if ! have_libtool; then
        echo "libtoolize/libtool.m4 not available; trying the stack's autotools modules"
        case $- in *u*) had_u=1; set +u ;; esac
        # One at a time: Lmod refuses the whole list if one name does not exist.
        for m in ${AUTOTOOLS_MODULES:-autoconf automake libtool}; do
            module load "$m" 2>&1 || true
        done
        if [ "$had_u" = 1 ]; then set -u; fi
        if ! have_libtool; then
            echo "-- what the node has:"
            for m in autoconf automake aclocal libtoolize; do echo "   $m: $(command -v $m || echo MISSING) $($m --version 2>/dev/null | head -1)"; done
            ( set +u; module -t avail autoconf automake libtool 2>&1 | head -20 ) || true
            die "libtool (libtoolize + libtool.m4) not found; Yambo needs it to autoreconf libxc. Set AUTOTOOLS_MODULES to the module(s) that provide it"
        fi
    fi
    echo "autotools: $(autoconf --version | head -1); $(automake --version | head -1); $(libtoolize --version | head -1); libtool.m4 in $LIBTOOL_M4"
}

die() { echo "ERROR: $*" >&2; exit 1; }
