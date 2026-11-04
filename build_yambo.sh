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

echo "== make -j $nproc core  ($(date))"
set +e
make -j "$nproc" core > make.out 2>&1
status=$?
set -e
tail -40 make.out
echo "make exit status $status ($(date))"
[ "$status" = 0 ] || die "make failed, see $tree/make.out and $tree/log/"

echo "== Binaries"
ls -l bin/
for exe in yambo p2y ypp; do [ -x "bin/$exe" ] || die "bin/$exe missing"; done
if ldd bin/yambo | grep -i 'not found'; then die "unresolved shared libraries in bin/yambo"; fi

mkdir -p "$MODULE_DIR/yambo-$flavour"
cp "$SCRIPT_DIR/modulefiles/yambo-$flavour/$YAMBO_VERSION.lua" "$MODULE_DIR/yambo-$flavour/"
echo "Installed modulefile $MODULE_DIR/yambo-$flavour/$YAMBO_VERSION.lua"
echo "BUILD OK"
