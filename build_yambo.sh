#!/bin/bash
# Configure and compile Yambo inside a Slurm job.  Usage: build_yambo.sh gpu|cpu
# Safe to resubmit after a timeout: configure is skipped once it has succeeded
# and make picks up where it stopped.
set -euo pipefail
source "${SLURM_SUBMIT_DIR:?submit from the scripts directory}/common.sh"

flavour=${1:?usage: build_yambo.sh gpu|cpu}
tree=$(yambo_tree "$flavour")
nproc=${SLURM_CPUS_PER_TASK:-4}

load_toolchain "$flavour"
load_autotools "$flavour"
module list 2>&1
nvfortran --version | head -2
# The GPU build needs a CUDA-aware MPI: this should say 'true'.
"$OPAL_PREFIX/bin/ompi_info" --parsable --all | grep mpi_built_with_cuda_support ||
    echo "WARNING: could not check whether MPI is CUDA-aware"
NVROOT=$(cd "$(dirname "$(which nvfortran)")/../.." && pwd)   # .../hpc_sdk/Linux_x86_64/<nvhpc version>

# FRESH=1 starts the build tree over.
if [ "${FRESH:-0}" = 1 ] && [ -d "$tree" ]; then
    echo "== FRESH=1: removing $tree"
    rm -rf "$tree"
fi
if [ ! -d "$tree" ]; then
    mkdir -p "$BUILD_ROOT/$flavour"
    tar -xzf "$SRC_DIR/yambo-$YAMBO_VERSION.tar.gz" -C "$BUILD_ROOT/$flavour"
    cp "$SRC_DIR"/extlibs/*.tar.gz "$tree/lib/archive/"
fi
cd "$tree"

# Same flags as the Yambo NVfortran wiki page, plus MPI and the GPU options.
conf=(MPIFC=mpif90 MPICC=mpicc FC=nvfortran F77=nvfortran
      CPP="cpp -E" FPP="nvfortran -Mpreprocess -E" F90SUFFIX=".f90"
      --enable-mpi --enable-open-mp
      --enable-memory-profile --enable-time-profile
      --enable-par-linalg --enable-hdf5-par-io --enable-slepc-linalg)

if [ "$flavour" = gpu ]; then
    nvidia-smi || die "no GPU visible; the GPU build must run on a GPU node"
    # Newer drivers print "CUDA UMD Version: X.Y" instead of "CUDA Version: X.Y".
    driver_cuda=$(nvidia-smi | grep -oP 'CUDA (UMD )?Version: \K[0-9.]+' | head -1) || die "cannot read driver CUDA version"
    # Highest CUDA bundled with nvhpc that the driver supports, unless overridden.
    if [ -z "${CUDA_RUNTIME:-}" ]; then
        CUDA_RUNTIME=$(ls "$NVROOT/cuda" | grep -E '^[0-9]+\.[0-9]+$' |
                       awk -v d="$driver_cuda" '{ split($0,a,"."); split(d,b,".");
                            if (a[1]<b[1] || (a[1]==b[1] && a[2]<=b[2])) print }' |
                       sort -V | tail -1) || true
    fi
    [ -n "$CUDA_RUNTIME" ] || die "no nvhpc CUDA version <= driver CUDA $driver_cuda; set CUDA_RUNTIME"
    echo "Driver supports CUDA $driver_cuda; using --with-cuda-runtime=$CUDA_RUNTIME"
    # A100 = compute capability 8.0, for both full GPUs and MIG slices.
    conf+=(--enable-cuda-fortran --with-cuda-cc=80 --with-cuda-runtime="$CUDA_RUNTIME")
fi

if [ ! -f config/setup ] || [ ! -f .configure_done ]; then
    echo "== Configure: ${conf[*]}"
    ./configure "${conf[@]}" 2>&1 | tee configure.out || die "configure failed, see $tree/config.log"
    touch .configure_done
fi
cat config/report 2>/dev/null || true

# Yambo builds these libraries itself, but its ext-libs step ignores failures and marks
# each step done even when it failed: a broken library is never retried, and the build
# only fails much later ("Unable to open MODULE file netcdf.mod"). So build them as a
# separate step, check that each enabled one installed its files, and reset any that
# did not (delete its stamps and unpacked tree), so that a resubmit retries it.
#   switch in config/mk/global/defs.mk : directory under lib/ : files under lib/external
EXT_CHECKS=(
    "do_yaml:yaml:libyaml*.a"
    "do_futile:futile:libfutile*.a"
    "do_iotk:iotk:libiotk.a iotk_module.mod"
    "do_hdf5:hdf5:libhdf5.a"
    "do_netcdf:netcdf:libnetcdf.a"
    "do_netcdf:netcdff:libnetcdff.a netcdf.mod"
    "do_etsf:etsf_io:libetsf_io.a"
    "do_libxc:libxc:libxc*.a"
    "do_lapack:lapack:liblapack.a"
    "do_slk:scalapack:libscalapack.a"
    "do_fftw:fftw:libfftw3*.a"
    "do_petsc:petsc:libpetsc.*"
    "do_slepc:slepc:libslepc.*"
    "do_devxlib:devxlib:libdevxlib*.a"
)
check_ext_libs() {     # returns 1 if any enabled library is missing files
    local entry sw dir files f bad=0
    local -a pats
    for entry in "${EXT_CHECKS[@]}"; do
        IFS=: read -r sw dir files <<< "$entry"
        grep -q "^$sw *= *yes" config/mk/global/defs.mk 2>/dev/null || continue
        read -ra pats <<< "$files"      # no glob expansion of the patterns
        for f in "${pats[@]}"; do
            [ -z "$(find lib/external -iname "$f" -print -quit 2>/dev/null)" ] || continue
            echo "library '$dir' did not install $f; see $tree/log/ and the config.log under $tree/lib/$dir/"
            bad=1
            if ls "lib/$dir"/*.stamp > /dev/null 2>&1; then     # it was attempted: reset it
                rm -f "lib/$dir"/*.stamp
                find "lib/$dir" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -exec rm -rf {} +
            fi
            break
        done
    done
    return $bad
}

# Yambo's sub-makes print a harmless jobserver warning each; leave those out.
nonoise() { grep -v -E 'make\[[0-9]+\]: warning: (-j[0-9]* forced in submake|jobserver unavailable)' || true; }

check_ext_libs > /dev/null || true     # reset libraries left broken by an earlier attempt
echo "== make -j $nproc ext-libs  ($(date))"
make -j "$nproc" ext-libs > make_ext.out 2>&1 || true    # failures are caught by the check
nonoise < make_ext.out | tail -20
check_ext_libs || die "external libraries missing (see above); they were reset, so fix the cause and resubmit"
echo "all enabled external libraries are installed"

echo "== make -j $nproc core  ($(date))"
status=0
make -j "$nproc" core > make.out 2>&1 || status=$?
nonoise < make.out | tail -40
# Yambo writes each compiler's messages to files under log/, not to make.out.
[ "$status" = 0 ] || die "make failed ($(date)); find the compiler errors with: grep -il -E 'error|severe' $tree/log/*"

ls -l bin/
for exe in yambo p2y ypp; do [ -x "bin/$exe" ] || die "bin/$exe missing"; done
if ldd bin/yambo | grep -i 'not found'; then die "unresolved shared libraries in bin/yambo"; fi
echo "Modulefile: $MODULE_DIR/yambo-$flavour/$YAMBO_VERSION.lua"
echo "BUILD OK"
