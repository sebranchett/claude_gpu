-- Modulefile for Yambo on DelftBlue, one file for both builds and every version.
-- The build scripts install it as <project>/modulefiles/yambo-gpu/<version>.lua and
-- yambo-cpu/<version>.lua (install_modulefile in common.sh); the flavour (gpu/cpu) and
-- the version come from the name it is installed under.
--
-- When DelftBlue's software stack or nvhpc changes, update these three lines:
local stack = "2026"       -- 'module load 2026'; same as STACK in common.sh
local nvhpc = "25.7"
local hpcx  = "/apps/generic/hpc_sdk/Linux_x86_64/" .. nvhpc .. "/comm_libs/12.9/hpcx/hpcx-2.22.1"

local version = myModuleVersion()                          -- e.g. "5.3.0"
local flavour = myModuleName():match("yambo%-(%a+)")       -- "gpu" or "cpu"
-- Same as PROJ in common.sh.
local root = "/projects/electronic_structure/yambo_gpu_" .. version .. "_" .. stack ..
             "/build/" .. flavour .. "/yambo-" .. version

local about
if flavour == "gpu" then
    about = "Yambo " .. version .. ", GPU build (CUDA Fortran, cc80, OpenMP, CUDA-aware MPI, SLEPc).\n" ..
            "Built with nvhpc/" .. nvhpc .. " for the gpu-a100 and gpu-a100-small partitions.\n" ..
            "Launch with: srun --mpi=pmix yambo ...   (one MPI task per GPU, --gpus-per-task=1)\n"
else
    about = "Yambo " .. version .. ", CPU build (OpenMP, MPI, SLEPc).\n" ..
            "Built with nvhpc/" .. nvhpc .. " for Cascade Lake: runs on compute-p1, compute-p2 and the GPU nodes,\n" ..
            "e.g. with #SBATCH --partition=compute-p1,compute-p2\n"
end
help(about .. "Inside a Slurm job always start yambo/p2y/ypp with srun --mpi=pmix, even for one\n" ..
     "process: started directly, MPI_Init fails.")
whatis("Name: yambo (" .. flavour:upper() .. ")")
whatis("Version: " .. version)

conflict(flavour == "gpu" and "yambo-cpu" or "yambo-gpu")
load(stack)
-- GCC provides libatomic.so.1, needed by nvhpc's HPC-X MPI; load it before nvhpc.
load("compilers")
load("gcc")
load("nvhpc/" .. nvhpc)

-- nvhpc's mpif90 links HPC-X's Open MPI, but the nvhpc module points OPAL_PREFIX at
-- comm_libs/mpi and does not put HPC-X's libraries on LD_LIBRARY_PATH; without this
-- MPI_Init fails ("No components were able to be opened in the pml framework").
setenv("OPAL_PREFIX", pathJoin(hpcx, "ompi"))
-- prepend_path puts each one first, so this list is in reverse: ompi/lib ends up first.
for _, d in ipairs({"nccl_rdma_sharp_plugin/lib", "sharp/lib", "hcoll/lib", "ucc/lib/ucc",
                    "ucc/lib", "ucx/lib/ucx", "ucx/lib", "ompi/lib"}) do
    prepend_path("LD_LIBRARY_PATH", pathJoin(hpcx, d))
end

prepend_path("PATH", pathJoin(root, "bin"))
setenv("YAMBO_ROOT", root)
