help([[
Yambo 5.3.0, CPU build (OpenMP, MPI, SLEPc), reference build for comparison with the GPU build.
Built with nvhpc/25.7 for Sapphire Rapids: use on compute-p2 or the GPU nodes, NOT compute-p1.
Inside a Slurm job always start yambo/p2y/ypp with srun --mpi=pmix, even for one
process: started directly, MPI_Init fails.
]])
whatis("Name: yambo (CPU)")
whatis("Version: 5.3.0")

conflict("yambo-gpu")
load("2026")
-- GCC provides libatomic.so.1, needed by nvhpc's HPC-X MPI; load it before nvhpc.
load("compilers")
load("gcc")
load("nvhpc/25.7")

-- nvhpc's mpif90 links HPC-X's Open MPI, but the nvhpc module points OPAL_PREFIX at
-- comm_libs/mpi and does not put HPC-X's libraries on LD_LIBRARY_PATH; without this
-- MPI_Init fails ("No components were able to be opened in the pml framework").
-- Same as set_mpi_prefix in the build scripts' common.sh.
local hpcx = "/apps/generic/hpc_sdk/Linux_x86_64/25.7/comm_libs/12.9/hpcx/hpcx-2.22.1"
setenv("OPAL_PREFIX", pathJoin(hpcx, "ompi"))
-- prepend_path puts each one first, so this list is in reverse: ompi/lib ends up first.
for _, d in ipairs({"nccl_rdma_sharp_plugin/lib", "sharp/lib", "hcoll/lib", "ucc/lib/ucc",
                    "ucc/lib", "ucx/lib/ucx", "ucx/lib", "ompi/lib"}) do
    prepend_path("LD_LIBRARY_PATH", pathJoin(hpcx, d))
end

local root = "/projects/electronic_structure/yambo_gpu_5.3.0_2026/build/cpu/yambo-5.3.0"
prepend_path("PATH", pathJoin(root, "bin"))
setenv("YAMBO_ROOT", root)
