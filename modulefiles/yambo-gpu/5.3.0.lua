help([[
Yambo 5.3.0, GPU build (CUDA Fortran, cc80, OpenMP, CUDA-aware MPI, SLEPc).
Built with nvhpc/25.7 for the gpu-a100 and gpu-a100-small partitions.
Launch with: srun --mpi=pmix yambo ...   (one MPI task per GPU, --gpus-per-task=1)
]])
whatis("Name: yambo (GPU)")
whatis("Version: 5.3.0")

conflict("yambo-cpu")
load("2026")
-- GCC provides libatomic.so.1, needed by nvhpc's HPC-X MPI; load it before nvhpc.
load("compilers")
load("gcc")
load("nvhpc/25.7")

local root = "/projects/electronic_structure/yambo_gpu_2026/build/gpu/yambo-5.3.0"
prepend_path("PATH", pathJoin(root, "bin"))
setenv("YAMBO_ROOT", root)
