#!/bin/bash
# Configure and compile Yambo inside a Slurm job.  Usage: build_yambo.sh gpu|cpu
# Safe to resubmit after a timeout: configure is skipped once it has succeeded
# and make picks up where it stopped.
set -euo pipefail
source "${SLURM_SUBMIT_DIR:?submit from the scripts directory}/common.sh"

flavour=${1:?usage: build_yambo.sh gpu|cpu}
tree=$(yambo_tree "$flavour")
nproc=${SLURM_CPUS_PER_TASK:-4}

load_toolchain
ensure_autotools     # libxc is autoreconf'ed by Yambo (common.sh)
module list 2>&1

echo "== Toolchain"
which nvfortran mpif90 mpicc
nvfortran --version | head -2
mpif90 --showme 2>/dev/null || true
NVROOT=$(cd "$(dirname "$(which nvfortran)")/../.." && pwd)   # .../hpc_sdk/Linux_x86_64/25.7
echo "NVHPC root: $NVROOT"

# The bundled MPI must be CUDA-aware for the GPU build; ompi_info is not on PATH.
# The SDK ships several Open MPIs (HPC-X, openmpi4), so take the ompi_info that
# belongs to the library mpif90 actually links: next to mpif90, or next to its lib dir.
mpi_libdir=$(mpif90 --showme:libdirs 2>/dev/null | awk '{print $1}' || true)
ompi_info=
for c in "$(dirname "$(readlink -f "$(which mpif90)")")/ompi_info" "${mpi_libdir:+$mpi_libdir/../bin/ompi_info}"; do
    if [ -n "$c" ] && [ -x "$c" ]; then ompi_info=$c; break; fi
done
if [ -n "$ompi_info" ]; then
    echo "ompi_info: $ompi_info"
    "$ompi_info" --parsable --all | grep mpi_built_with_cuda_support || true
else
    echo "WARNING: no ompi_info found for mpif90 (lib dir: ${mpi_libdir:-unknown}); CUDA-awareness of MPI not verified"
fi

# FRESH=1 starts the build tree over (needed once after the libatomic fix: the
# earlier attempts left libraries and objects stamped as built that are not).
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
    echo "== GPU"
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
    echo "Driver supports CUDA $driver_cuda; nvhpc ships: $(ls "$NVROOT/cuda" | tr '\n' ' ')"
    [ -n "$CUDA_RUNTIME" ] || die "no nvhpc CUDA version <= driver CUDA $driver_cuda; set CUDA_RUNTIME"
    echo "Using --with-cuda-runtime=$CUDA_RUNTIME"
    # A100 = compute capability 8.0, for both full GPUs and MIG slices.
    conf+=(--enable-cuda-fortran --with-cuda-cc=80 --with-cuda-runtime="$CUDA_RUNTIME")
fi

if [ ! -f config/setup ] || [ ! -f .configure_done ]; then
    echo "== Configure: ${conf[*]}"
    ./configure "${conf[@]}" 2>&1 | tee configure.out || die "configure failed, see $tree/config.log"
    touch .configure_done
fi
cat config/report 2>/dev/null || true

# External libraries. Yambo's ext-libs loop ignores failures, and each library's
# Makefile.loc touches its configured/compiled/installed stamps even when that step
# failed, so a broken library is never retried and the build only fails later
# (e.g. "Unable to open MODULE file netcdf.mod"). So: build them as a separate
# step, check that each enabled library installed its files, and reset the ones
# that did not, so that a resubmit retries them.
#   defs.mk switch : build dir under lib/ : log name prefix : files that must exist
EXT_CHECKS=(
    "do_yaml:yaml:yaml-:libyaml*.a"
    "do_futile:futile:futile:libfutile*.a"
    "do_iotk:iotk:iotk:libiotk.a iotk_module.mod"
    "do_hdf5:hdf5:hdf5:libhdf5.a"
    "do_netcdf:netcdf:netcdf-c:libnetcdf.a"
    "do_netcdf:netcdff:netcdf-fortran:libnetcdff.a netcdf.mod"
    "do_etsf:etsf_io:etsf_io:libetsf_io.a"
    "do_libxc:libxc:libxc:libxc*.a"
    "do_lapack:lapack:lapack:liblapack.a"
    "do_slk:scalapack:scalapack:libscalapack.a"
    "do_fftw:fftw:fftw:libfftw3*.a"
    "do_petsc:petsc:petsc:libpetsc.*"
    "do_slepc:slepc:slepc:libslepc.*"
    "do_devxlib:devxlib:devicexlib:libdevxlib*.a"
)

# check_ext_libs report|quiet: prints/handles libraries whose files are missing and
# resets them. Returns 1 if any were missing.
check_ext_libs() {
    local mode=$1 entry sw dir logp files f missing bad=0
    local -a pats
    for entry in "${EXT_CHECKS[@]}"; do
        IFS=: read -r sw dir logp files <<< "$entry"
        grep -q "^$sw *= *yes" config/mk/global/defs.mk 2>/dev/null || continue
        read -ra pats <<< "$files"      # no glob expansion of the patterns
        missing=
        for f in "${pats[@]}"; do
            [ -n "$(find lib/external -iname "$f" -print -quit 2>/dev/null)" ] || missing="$missing $f"
        done
        [ -z "$missing" ] && continue
        bad=1
        if [ "$mode" = report ]; then
            echo "---- external library '$dir' did not install:$missing"
            for f in log/*_"$logp"*.log; do
                [ -f "$f" ] || continue
                echo "  -- $tree/$f (last 15 lines)"
                tail -15 "$f" | cut -c1-300 | sed 's/^/     /'
            done
            # The package's own configure log usually holds the real reason.
            for f in $(find "lib/$dir" -maxdepth 3 \( -name config.log -o -name configure.log \) 2>/dev/null); do
                echo "  -- $tree/$f (error lines)"
                grep -n -i -E 'error|cannot|not found|fatal' "$f" | tail -15 | cut -c1-300 | sed 's/^/     /'
            done
        fi
        # Only reset trees that were started; a library never attempted has no stamps.
        if ls "lib/$dir"/*.stamp > /dev/null 2>&1; then
            echo "== resetting lib/$dir so that it is rebuilt"
            rm -f "lib/$dir"/*.stamp
            find "lib/$dir" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -exec rm -rf {} +
        fi
    done
    return $bad
}

# Libraries left half-built by an earlier attempt are retried now.
check_ext_libs quiet || true

# Yambo writes each compiler's messages to files under log/, not to make.out.
# On failure, print the errors from make.out and from every log written by this make.
show_compile_errors() {
    # \b keeps file names such as qe_errore.F out; compile command lines are
    # skipped and long lines cut, since each one is several kB of -I flags.
    local pat='NVFORTRAN-[SFW]-|\b[Ee]rror\b|\b[Ss]evere\b|[Uu]nable to open|undefined reference'
    local cmd='^(mpif90|mpicc|nvfortran|nvc|cpp) '
    echo "== Compiler errors in make.out"
    grep -n -E "$pat" make.out | grep -v -E 'Waiting for unfinished|\*\*\* \[' | cut -c1-300 | head -40 || true
    echo "== Logs written by this make, with errors"
    local f n=0
    while IFS= read -r f; do
        grep -v -E "$cmd" "$f" | grep -q -E "$pat" || continue
        echo "---- $tree/$f"
        grep -n -E -v "$cmd" "$f" | grep -E -B3 -A8 "$pat" | cut -c1-300 | head -60
        n=$((n + 1)); [ "$n" -ge 5 ] && { echo "(more logs with errors not shown)"; break; }
    done < <(find log -type f -newer .make_start 2>/dev/null | sort)
    [ "$n" -gt 0 ] || echo "(no log under $tree/log written by this make contains an error line)"
}

echo "== make -j $nproc ext-libs  ($(date))"
touch .make_start
set +e
make -j "$nproc" ext-libs > make_ext.out 2>&1
status=$?
set -e
tail -20 make_ext.out
echo "make ext-libs exit status $status ($(date))"
echo "== Checking external libraries"
if ! check_ext_libs report; then
    die "external libraries missing (see above); they were reset, so fix the cause and resubmit"
fi
echo "all enabled external libraries are installed"

echo "== make -j $nproc core  ($(date))"
set +e
make -j "$nproc" core > make.out 2>&1
status=$?
set -e
tail -40 make.out
echo "make exit status $status ($(date))"
if [ "$status" != 0 ]; then
    show_compile_errors || true
    die "make failed, see $tree/make.out and $tree/log/"
fi

echo "== Binaries"
ls -l bin/
for exe in yambo p2y ypp; do [ -x "bin/$exe" ] || die "bin/$exe missing"; done
if ldd bin/yambo | grep -i 'not found'; then die "unresolved shared libraries in bin/yambo"; fi

mkdir -p "$MODULE_DIR/yambo-$flavour"
cp "$SCRIPT_DIR/modulefiles/yambo-$flavour/$YAMBO_VERSION.lua" "$MODULE_DIR/yambo-$flavour/"
# The binaries need the same libatomic at run time (see ensure_libatomic in common.sh).
if [ -n "$LIBATOMIC_ADDED" ]; then
    echo "prepend_path(\"LD_LIBRARY_PATH\", \"$LIBATOMIC_ADDED\")" >> "$MODULE_DIR/yambo-$flavour/$YAMBO_VERSION.lua"
fi
echo "Installed modulefile $MODULE_DIR/yambo-$flavour/$YAMBO_VERSION.lua"
echo "BUILD OK"
