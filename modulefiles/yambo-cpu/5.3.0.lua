help([[
Yambo 5.3.0, CPU build (OpenMP, MPI, SLEPc), reference build for comparison with the GPU build.
Built with nvhpc/25.7 for Sapphire Rapids: use on compute-p2 or the GPU nodes, NOT compute-p1.
]])
whatis("Name: yambo (CPU)")
whatis("Version: 5.3.0")

conflict("yambo-gpu")
load("2026")
-- GCC provides libatomic.so.1, needed by nvhpc's HPC-X MPI; load it before nvhpc.
load("compilers")
load("gcc")
load("nvhpc/25.7")

local root = "/projects/electronic_structure/yambo_gpu_2026/build/cpu/yambo-5.3.0"
prepend_path("PATH", pathJoin(root, "bin"))
setenv("YAMBO_ROOT", root)
