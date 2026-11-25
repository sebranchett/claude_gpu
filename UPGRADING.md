# Upgrading to a new Yambo version

What we learned building Yambo 5.3.0 on DelftBlue (November 2026), so the next version starts from the answers instead of the debugging.

## Checklist for a new version

1. **Version.** Set `YAMBO_VERSION` in `common.sh` (and `STACK` for a newer DelftBlue software stack). This gives a new project directory, `yambo_<version>_<stack>`, next to the old one. The modulefile needs no change: it reads the version from its installed name. Find other hard-coded versions with `git grep -n 5.3.0`.
2. **Toolchain.** For a newer stack or `nvhpc`, update the three settings at the top of `modulefiles/yambo.lua`: `stack` (= `STACK`), `nvhpc`, and the HPC-X path (`comm_libs/<cuda>/hpcx/hpcx-<version>` in the new nvhpc; see [MPI](#mpi-and-slurm)). The builds load the toolchain from this modulefile too. Check the Yambo wiki's NVfortran page for changed configure flags.
3. **Downloads** (`00`, login node). Check every library downloaded. In 5.3.0, `yaml-0.2.2` was missing from Yambo's mirror and comes from pyyaml.org; that may no longer be needed, or another library may need the same.
4. **Builds** (`01`, `02`), fresh for a new version. Check:
   - `config/report`: CUDA Fortran, MPI, OpenMP, parallel HDF5 I/O, SLEPc and ScaLAPACK on;
   - GPU output: `mpi_built_with_cuda_support:true`, and the `Toolchain:` line with `OPAL_PREFIX` ending in `hpcx-*/ompi`;
   - CPU output: `-tp cascadelake` (see [Building](#building));
   - `EXT_CHECKS` in `build_yambo.sh` against the `do_*` switches in the new `config/mk/global/defs.mk`: a library Yambo added or renamed needs a line, or its failure goes unnoticed.
5. **SAVE** (`03`). Check the new `p2y` reads the project QE's output.
6. **Tests** (`04`–`07`). "X not found in Y.in" means Yambo renamed an input variable: write an input by hand (`yambo -F test.in <options>`) to find the new name, and fix it in `example/yambo_hBN_gpu.slurm`. Also update the module and SAVE defaults at its top.
7. **Compare** (`08`) with the new CPU run, and with the previous version's reference, `/projects/electronic_structure/yambo_5.3.0_2026/reference/cpu_p1_5.3.0`: the physics should not change. Then keep the new reference (README step 6).
8. **Known limitations.** Check whether the GPU screening and BSE kernel are still slow (see [Yambo behaviour](#yambo-behaviour-worth-knowing)); update README if not.

## DelftBlue lessons

Also: compute and GPU nodes have no internet (download on a login node); the login node has a different software stack (compile only in jobs); `OMPI_MCA_btl=^openib` and `OMPI_MCA_plm_slurm_args=--external-launcher` are set system-wide and survive `module purge`.

### MPI and Slurm

- **Every MPI Fortran program fails to start: `libatomic.so.1` not found.** First seen as IOTK's configure failing at "checking whether the Fortran compiler works".
  *Cause:* HPC-X's `libmpi_usempif08.so` needs it; the nodes do not have it.
  *Fix:* load `compilers gcc` from the 2026 stack before `nvhpc` (modulefile).
- **`MPI_Init` fails; Open MPI looks for its help files under `comm_libs/mpi`.** Then: "No components were able to be opened in the pml framework".
  *Cause:* nvhpc's `mpif90` links HPC-X's Open MPI, but the nvhpc module points `OPAL_PREFIX` elsewhere and leaves HPC-X's libraries off `LD_LIBRARY_PATH`.
  *Fix:* set `OPAL_PREFIX` to `hpcx-*/ompi`; prepend `ompi/lib` (first) and HPC-X's `ucx`, `ucc`, `hcoll`, `sharp` lib dirs (modulefile).
- **The same `MPI_Init` error in a job using the module, while the build and test jobs worked.**
  *Cause:* the installed modulefile was an old hand copy without the `OPAL_PREFIX` lines; the 5.3.0 build and test jobs set up MPI themselves, so they did not notice.
  *Fix:* jobs `01`, `02` and `03` now install `modulefiles/yambo.lua` and load it. Check with `module show yambo-gpu/<version> 2>&1 | grep OPAL`.
- **`yambo` or `p2y` started directly inside a job fails in PMIx** ("OMPI was not built with SLURM's PMI support").
  *Cause:* HPC-X treats any process in a Slurm job as an srun launch.
  *Fix:* always `srun --mpi=pmix`, also for one process (`srun --nodes=1 --ntasks=1 --mpi=pmix`), including to write input files.
- **All OpenMP threads pinned to one CPU.**
  *Cause:* since Slurm 22.05, `srun` does not inherit `--cpus-per-task`.
  *Fix:* `export SRUN_CPUS_PER_TASK=$SLURM_CPUS_PER_TASK OMP_PLACES=cores OMP_PROC_BIND=close`.
- **`sbatch` rejects `--gres` or `--gpus`.** DelftBlue GPU partitions only accept `--gpus-per-task=1`.
- **`CUDA_VISIBLE_DEVICES` is `0` in every task.** Normal: each task sees only its own GPU. To check they differ, compare UUIDs (the example prints one per task).

### Building

- **A library looks built, but later "Unable to open MODULE file netcdf.mod".**
  *Cause:* Yambo's `ext-libs` loop ignores failures and marks each step done anyway, so a failed library is never retried; its `log/` file is overwritten by the next step.
  *Fix:* `build_yambo.sh` builds `ext-libs` separately, checks each library's files (`EXT_CHECKS`) and resets failed ones (deletes `lib/<lib>/*.stamp` and the unpacked tree). The real error is in the library's own `config.log`.
- **libxc: `possibly undefined macro: AC_DISABLE_SHARED`, then `cannot find install-sh`.**
  *Cause:* Yambo runs `autoreconf` on libxc, and the nodes have no libtool.
  *Fix:* `module load gpu autoconf automake libtool` (`cpu ...` on CPU nodes); `load_autotools` in `common.sh`.
- **A CPU build made on compute-p2 may crash on compute-p1** (illegal instruction).
  *Cause:* nvfortran and the libraries' configure scripts target the build node's CPU: Sapphire Rapids on compute-p2 and the GPU nodes, Cascade Lake (Xeon Gold 6248R) on compute-p1.
  *Fix:* build the CPU version on compute-p1 (`02`); its `-tp cascadelake` also runs on Sapphire Rapids. Test on both partitions (`05`, `06`): `yambo -h` starting proves nothing, it even started on compute-p1 from the Sapphire Rapids build.
- **GPU build stops at 4 h.** `gpu-a100-small` allows 2 CPUs per task, 4 h, one job per user. Hence `make -j 2`; resubmit and the build resumes (about 13 min for ext-libs, 1 h for the core).
- **Driver CUDA version not parsed.** New `nvidia-smi` prints `CUDA UMD Version: X.Y`; handled in `build_yambo.sh`.

## Yambo behaviour worth knowing

Two steps are slow in the GPU build. They split over MPI tasks, so use one task per GPU on all the GPUs: one task on one big GPU is the worst layout. We decided not to modify or investigate Yambo's source.

| Step (name in the `r-*` reports) | Why | 1 task, 1 A100 | 4 tasks, 4 A100s |
|---|---|---|---|
| Screening, `Xo (procedure)` (GW and BSE) | Host code on one OpenMP thread: the GPU build sets `n_threads_X=1` (`src/pol_function/X_irredux.F`, around line 191) whatever `X_Threads` says, so GPU size does not matter | 60.8 s (gw) | 13.5 s |
| BSE kernel, `X T_space Kernel`, mostly its `Kernel sum` (`src/bse/K_kernel.F`) | Not known; a separate step from `Xo` despite the similar name. On 2 MIG slices 22.5 s, against 6.4 s on a compute-p2 node | 35.1 s (sum) | 10.0 s |

- **Haydock accuracy.** The solver stops at about 2 % (`BSHayTrs=-0.02`), so eps from different parallel layouts differs by about that much; `08_compare.py` judges `haydock` files at 2 %. EEL can differ more: Yambo extends eps beyond the computed energy window for it ("Possible inaccuracy in the EPS prolungation"). The 4-GPU run's EEL was 5 % off the CPU run's, although it had converged further (0.69 % in 64 iterations, against 1.44 % in 59). So an occasional EEL DIFF is expected: compare `Accuracy (reached)` in the two `r-bse_h_*` reports.
- **Haydock can converge to a wrong spectrum, depending on the layout.** On compute-p2 with 24 tasks × 2 threads (a part-filled node), two runs on different nodes took 110 and 113 Haydock iterations instead of the usual 59. Each still reported reaching the 2 % threshold, but its spectrum was wrong at 6.0–6.3 eV: 15–25 % off the exact (diagonalized) spectrum, against 0.6–0.8 % for the runs that took 59 iterations. The two runs also differed from each other. Every other layout tried gave 59 iterations (64 on 4 A100s) and the right spectrum: 24 × 2 on compute-p1, 32 × 2 on compute-p2 (both CPU builds), and all the GPU layouts. Cause not investigated. Haydock's stopping test compares one iteration with the next, so "accuracy reached" does not prove the spectrum is right. To check a run, compare its `Iterations` line in `r-bse_h_*` with a known-good run: about twice as many means distrust it. `08_compare.py` flags it as a Haydock DIFF while GW and SLEPc agree; `09_bse_diag_check.slurm` scores Haydock runs against the exact spectrum.
- **Build defaults.** nvfortran flags `-O1 -gopt`, single precision; kept. In 5.3.0 OpenACC switches OpenMP off, hence CUDA Fortran.

## Decisions

| Topic | Decision |
|---|---|
| Install location | `/projects/electronic_structure/yambo_<version>_<stack>`, one per version. 5.3.0 was first installed as `yambo_gpu_2026`, now a link to `yambo_5.3.0_2026`. The build tree is the installation. |
| Account | `research-as-cheme` |
| Toolchain | `module load 2026; module load compilers gcc; module load nvhpc/25.7` |
| GPU mode | `--enable-cuda-fortran --with-cuda-cc=80`; CUDA runtime = newest nvhpc CUDA the driver supports (12.9 with driver CUDA 13.4). |
| Libraries | All built by Yambo (HDF5, netCDF, LibXC, FFTW, ScaLAPACK, PETSc, SLEPc); BLAS/LAPACK from nvhpc. |
| DFT | Project QE module (`module use --append /projects/electronic_structure/.modulefiles; module load qe`, QE 7.6), CPU only. |
| Test system | Bulk hBN from the Yambo tutorial, 200 bands. |
| CPU build | Built on compute-p1, runs on compute-p1 and compute-p2. Tested on a full node of each: 24 MPI × 2 OpenMP on compute-p1, 32 × 2 on compute-p2 (24 × 2 there broke Haydock, see [Haydock](#yambo-behaviour-worth-knowing)). Replaced a first CPU build made on compute-p2. |
| Yambo source | Used as released. |

## Yambo 5.3.0 reference results

Reference: the first CPU build (made on compute-p2, run on a full compute-p2 node). Every run agrees within tolerance (QP within 0.56 meV), except the 4-GPU run's Haydock EEL (5 %; see [Haydock accuracy](#yambo-behaviour-worth-knowing)). Valence QP corrections −0.66 to −0.86 eV, conduction +0.71 to +1.43 eV. Results of the portable CPU build (`cpu_p1`; `cpu_p2` at 32 × 2) were pending when this was written.

| Step | cpu_p2, first build (32 × 2) | gpu_small (2 MIG × 2) | gpu_a100_1gpu (1 × 16) | gpu_a100_4gpu (4 × 16) |
|---|---|---|---|---|
| gw | 149.8 s | 88.3 s | 148.9 s | 46.0 s |
| bse_h | 29.3 s | 70.0 s | 131.6 s | 40.7 s |
| bse_s | 12.1 s | 8.0 s | 8.0 s | 7.8 s |

Wall times vary about 8 % between identical runs. `gpu_a100_1gpu` came from a benchmark job since dropped. `gpu_a100_4gpu` has the layout of `07`, run with the scripts before this clean-up.
