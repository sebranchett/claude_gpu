# Upgrading to a new Yambo version

What we learned building Yambo 5.3.0 on DelftBlue (November 2026), so the next version starts from the answers rather than the debugging. The full diary of build attempts is in the git history of `HANDOFF.md`.

## Checklist for a new version

1. **Version number.** Set `YAMBO_VERSION` in `common.sh` (and `STACK`, if DelftBlue has a newer software stack). That gives a new project directory, `yambo_gpu_<version>_<stack>`, next to the old one; copy the scripts there. The modulefile (`modulefiles/yambo.lua`) needs no change for a new Yambo version: it takes the version from the name it is installed under. Find any other hard-coded version with `git grep -n 5.3.0`.
2. **Toolchain.** If DelftBlue has a newer software stack or `nvhpc`, update the three settings at the top of `modulefiles/yambo.lua`: `stack` (same as `STACK` in `common.sh`), `nvhpc`, and the HPC-X path (`comm_libs/<cuda>/hpcx/hpcx-<version>`; look it up in the new nvhpc, see [MPI](#delftblue-lessons)). The builds load the toolchain from this modulefile too. Check the Yambo wiki's NVfortran page for changed configure flags.
3. **Downloads** (`00_fetch_sources.sh`, login node). Check that every library downloaded. In 5.3.0, `yaml-0.2.2` was missing from Yambo's mirror and is fetched from pyyaml.org instead; that workaround may no longer be needed, or another library may need one.
4. **Builds** (`01`, `02`). A new version gets a new build tree, so it starts fresh. Check:
   - `config/report`: CUDA Fortran, MPI, OpenMP, parallel HDF5 I/O, SLEPc and ScaLAPACK on.
   - `mpi_built_with_cuda_support:true` in the GPU build output.
   - `EXT_CHECKS` in `build_yambo.sh` against the `do_*` switches in the new `config/mk/global/defs.mk`: a library Yambo added or renamed needs a line there, or a silent failure goes unnoticed.
5. **SAVE** (`03`). Check that the new `p2y` reads the project QE's output.
6. **Tests** (`04`–`07`). "X not found in Y.in" means Yambo renamed an input variable: generate an input by hand (`yambo -F test.in <options>`) to find the new name, and fix it in `example/yambo_hBN_gpu.slurm` (the tests run that script). Also update the module and SAVE defaults at its top.
7. **Compare** (`08`). Against the CPU run of the new version, and against the previous version's kept reference, `/projects/electronic_structure/yambo_gpu_5.3.0_2026/reference/cpu_p1_5.3.0` (README step 6): the physics should not change between versions. Then keep the new version's reference the same way.
8. **Known limitation.** Check whether the GPU screening is still single-threaded (see [Yambo behaviour](#yambo-behaviour-worth-knowing)); if the new version fixes it, update README.

## DelftBlue lessons

| Symptom | Cause | Fix (where) |
|---|---|---|
| Every MPI Fortran program fails to start: `libatomic.so.1` not found. First seen as IOTK's configure failing at "checking whether the Fortran compiler works". | HPC-X's `libmpi_usempif08.so` needs `libatomic.so.1`; the nodes do not have it. | Load `compilers gcc` from the 2026 stack before `nvhpc` (modulefiles). |
| `MPI_Init` fails; Open MPI looks for its help files under `comm_libs/mpi`. Then: "No components were able to be opened in the pml framework". | `nvhpc`'s `mpif90` links HPC-X's Open MPI, but the module points `OPAL_PREFIX` elsewhere and does not put HPC-X's libraries on `LD_LIBRARY_PATH`. | Set `OPAL_PREFIX` to `hpcx-*/ompi` and prepend `ompi/lib` (first) plus HPC-X's `ucx`, `ucc`, `hcoll`, `sharp` lib dirs (modulefiles). |
| `yambo` or `p2y` started directly inside a job fails in PMIx ("OMPI was not built with SLURM's PMI support"). | HPC-X treats any process in a Slurm job as an srun launch. | Always `srun --mpi=pmix`, also for one process (`srun --nodes=1 --ntasks=1 --mpi=pmix`), including when generating input files. |
| OpenMP threads all pinned to one CPU. | Since Slurm 22.05, `srun` does not inherit `--cpus-per-task`. | `export SRUN_CPUS_PER_TASK=$SLURM_CPUS_PER_TASK`, plus `OMP_PLACES=cores OMP_PROC_BIND=close`. |
| A library seems built but later "Unable to open MODULE file netcdf.mod". | Yambo's `ext-libs` loop ignores failures and stamps each step as done anyway, so a failed library is never retried. Its `log/` file is overwritten by the next step. | `build_yambo.sh` builds `ext-libs` separately, checks each library's files (`EXT_CHECKS`), and resets failed ones (delete `lib/<lib>/*.stamp` and the unpacked tree). The real error is in the library's own `config.log`. |
| libxc: `possibly undefined macro: AC_DISABLE_SHARED`, then `cannot find install-sh`. | Yambo runs `autoreconf` on libxc; the nodes have no libtool. | `module load gpu autoconf automake libtool` (`cpu ...` on CPU nodes) (`load_autotools` in `common.sh`). |
| Driver CUDA version not parsed. | New `nvidia-smi` prints `CUDA UMD Version: X.Y`. | Handled in `build_yambo.sh`. |
| `sbatch` rejects `--gres` or `--gpus`. | DelftBlue GPU partitions only accept `--gpus-per-task`. | Use `--gpus-per-task=1`. |
| GPU build stops at 4 h. | `gpu-a100-small`: at most 2 CPUs per task, 4 h, one job per user. | `make -j 2`; resubmit, the build resumes (13 min for ext-libs plus about 1 h for core once it works). |
| A CPU build made on compute-p2 may crash on compute-p1 (illegal instruction). | nvfortran, and the libraries' own configure scripts, target the build node's CPU: Sapphire Rapids on compute-p2 and the GPU nodes, Cascade Lake (Xeon Gold 6248R, AVX-512 without FP16/BF16/AMX) on compute-p1. | Build the CPU version on compute-p1 (`02`): its default target, `-tp cascadelake`, also runs on Sapphire Rapids. Then test on both partitions (`05`, `06`). A program that only starts (`yambo -h`) proves nothing: it ran on compute-p1 even from the Sapphire Rapids build. |

Also: compute and GPU nodes have no internet (downloads on a login node); the login node has a different software stack (compile only in jobs); `OMPI_MCA_btl=^openib` and `OMPI_MCA_plm_slurm_args=--external-launcher` are set system-wide and survive `module purge`.

## Yambo behaviour worth knowing

- **GPU screening runs on one host thread.** The independent-particle response `Xo`, in both GW and the BSE static screening, is computed by host code with one OpenMP thread: the GPU build forces `n_threads_X=1` (`src/pol_function/X_irredux.F`, around line 191) whatever `X_Threads` says. Its inner `X T_space Kernel sum` took 35 s of work in total on 2 MIG slices (2 tasks × 17.5 s) and on a full A100 (1 task × 35.1 s): the GPU size makes no difference, only the number of MPI tasks splitting it does. So use several MPI tasks; one task on one big GPU is the worst layout. We decided not to modify or investigate Yambo's source.
- **Haydock accuracy.** The Haydock solver stops at about 2 % accuracy (`BSHayTrs=-0.02`), and runs with different parallel layouts differ by up to that much, most in the EEL spectrum. `08_compare.py` judges `haydock` files at 2 % for that reason.
- **Build defaults.** Yambo's nvfortran flags are `-O1 -gopt`, in single precision; we kept them. In 5.3.0, OpenACC force-disables OpenMP, which is why we use CUDA Fortran.

## Decisions

| Topic | Decision |
|---|---|
| Install location | `/projects/electronic_structure/yambo_gpu_<version>_<stack>`, one per version (5.3.0: `yambo_gpu_5.3.0_2026`, first installed as `yambo_gpu_2026`, now a link); the build tree is the installation (never delete `build/`). |
| Account | `research-as-cheme` |
| Toolchain | `module load 2026; module load compilers gcc; module load nvhpc/25.7` |
| GPU mode | `--enable-cuda-fortran --with-cuda-cc=80`, CUDA runtime = newest nvhpc CUDA the driver supports (12.9 with driver CUDA 13.4). |
| Libraries | All built internally by Yambo (HDF5, netCDF, LibXC, FFTW, ScaLAPACK, PETSc, SLEPc); BLAS/LAPACK from nvhpc. |
| DFT | Project QE module (`module use --append /projects/electronic_structure/.modulefiles; module load qe`, QE 7.6), CPU only. |
| Test system | Bulk hBN from the Yambo tutorial, 200 bands. |
| CPU build | Same nvhpc, built on compute-p1 so it runs on compute-p1 and compute-p2 (users submit with `--partition=compute-p1,compute-p2`). Tested on each partition with 24 MPI × 2 OpenMP, the usual layout that fits both node types (48 and 64 cores). Replaced the first CPU build, which was made on compute-p2. |
| Yambo source | Used as released, not modified. |

## Yambo 5.3.0 reference results

From the first CPU build (made on compute-p2, run on one full compute-p2 node). All runs agree with `cpu_p2` within tolerance (QP within 0.56 meV). Valence QP corrections are −0.66 to −0.86 eV, conduction +0.71 to +1.43 eV. The portable CPU build's results (`cpu_p1`, `cpu_p2` at 24 × 2) were pending when this was written.

| Step | cpu_p2, first build (32 × 2) | gpu_small (2 MIG × 2) | gpu_a100_1gpu (1 × 16) |
|---|---|---|---|
| gw | 149.8 s | 88.3 s | 148.9 s |
| bse_h | 29.3 s | 70.0 s | 131.6 s |
| bse_s | 12.1 s | 8.0 s | 8.0 s |

Wall times vary about 8 % between identical runs. `gpu_a100_1gpu` came from a benchmark job that has since been dropped: its finding (with a single MPI task, one host thread does all of the screening) is under [Yambo behaviour](#yambo-behaviour-worth-knowing). The 4-GPU run (`07_bench_gpu_a100.slurm`, label `gpu_a100_4gpu`) was pending when this was written.

## One-off: renaming the 5.3.0 installation

5.3.0 was first installed as `yambo_gpu_2026`, before the `yambo_gpu_<version>_<stack>` naming. To move it, on a login node:

```bash
cd /projects/electronic_structure && mv yambo_gpu_2026 yambo_gpu_5.3.0_2026 && ln -s yambo_gpu_5.3.0_2026 yambo_gpu_2026
```

The link keeps the old path working, which the installed binaries and libraries may still refer to. Then install the new modulefiles, from the new `scripts/` directory (the next `01`, `02` or `03` job would also do this):

```bash
for f in gpu cpu; do cp modulefiles/yambo.lua ../modulefiles/yambo-$f/5.3.0.lua; done
```

## One-off: replacing the 5.3.0 CPU build with the portable one

The first CPU build was made on compute-p2 and may not run on compute-p1. To replace it:

1. Keep its test results first, as the reference for the new build (the new `06` overwrites `cpu_p2`):
   ```bash
   ref=/projects/electronic_structure/yambo_gpu_5.3.0_2026/reference/cpu_p2_5.3.0_first_build
   mkdir -p $ref && cp /scratch/$USER/yambo_5.3.0_tests/cpu_p2/{o-*,r-*,timings.tsv} $ref/
   ```
2. Rebuild on compute-p1 from scratch, `sbatch --export=ALL,FRESH=1 02_build_cpu.slurm`; `yambo-cpu/5.3.0` is unusable until it ends with `BUILD OK`. Check that the job output says `-tp cascadelake`. The SAVE from `03` is plain data and can stay.
3. `sbatch 05_test_cpu_p1.slurm` and `sbatch 06_test_cpu_p2.slurm`, then compare with the first build and the GPU runs:
   ```bash
   python3 -I 08_compare.py /scratch/$USER/yambo_5.3.0_tests/{cpu_p1,cpu_p2,gpu_small,gpu_a100_4gpu} /projects/electronic_structure/yambo_gpu_5.3.0_2026/reference/cpu_p2_5.3.0_first_build
   ```
4. Keep `cpu_p1` as the 5.3.0 reference (README step 6).
