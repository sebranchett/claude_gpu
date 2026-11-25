# Yambo 5.3.0 on DelftBlue: GPU and CPU builds

Scripts that build Yambo 5.3.0 on DelftBlue twice, for the A100 GPU nodes and for the CPU nodes, and check both builds with a GW + BSE run on bulk hBN.

**Building a newer Yambo version?** Start with [UPGRADING.md](UPGRADING.md).

| | GPU build | CPU build |
|---|---|---|
| Compiler / MPI | `nvhpc/25.7` (nvfortran + bundled HPC-X Open MPI), plus the 2026 `gcc` module for `libatomic.so.1` | same |
| GPU | CUDA Fortran, `--with-cuda-cc=80`, CUDA runtime auto-detected | – |
| Parallelism | MPI + OpenMP | MPI + OpenMP |
| Libraries | built by Yambo: HDF5 (parallel I/O), netCDF, LibXC, FFTW, ScaLAPACK, PETSc + SLEPc | same |
| Built on | `gpu-a100-small` | `compute-p1` (Cascade Lake, so it also runs on newer CPUs) |
| Runs on | `gpu-a100`, `gpu-a100-small` | `compute-p1`, `compute-p2` (and the GPU nodes) |

## Where things are

| What | Where |
|---|---|
| Installation, one per version | `/projects/electronic_structure/yambo_<version>_<stack>`, for 5.3.0 `yambo_5.3.0_2026` (`YAMBO_VERSION`, `STACK` in `common.sh`) |
| Sources | `src/` in the installation (from `00_fetch_sources.sh`) |
| Builds | `build/gpu/yambo-5.3.0/`, `build/cpu/yambo-5.3.0/`: the build tree *is* the installation, never delete it |
| Modulefiles | `modulefiles/yambo-gpu/5.3.0.lua`, `modulefiles/yambo-cpu/5.3.0.lua` |
| Validated results | `reference/cpu_p1_5.3.0/` (run order step 6) |
| Test runs | `/scratch/$USER/yambo_5.3.0_tests/<label>` |
| These scripts | a clone of this repository, anywhere (e.g. `/scratch/$USER/claude_gpu`) |

A new version is installed next to the old one, which stays usable.

There is **one modulefile**, `modulefiles/yambo.lua`. It is installed under both names above and reads the flavour (`gpu`/`cpu`) and the version from the name. Jobs `01`, `02` and `03` install it and then load it, so builds, tests and users all get the same environment.

## Run order

Submit every job **from the scripts directory**: the jobs find `common.sh` through `$SLURM_SUBMIT_DIR`.

1. **Downloads**, on a login node (compute and GPU nodes have no internet):
   ```bash
   bash 00_fetch_sources.sh
   ```
2. **Builds**, both at once (different partitions). Each ends with `BUILD OK`.
   ```bash
   sbatch 01_build_gpu.slurm
   sbatch 02_build_cpu.slurm
   ```
   - Check the `config/report` in the output: CUDA, MPI, OpenMP and SLEPc on.
   - GPU build stopped by the 4 h limit: resubmit, it carries on.
   - A library failed: the job names it, resets it and stops; the reason is in `lib/<library>/config.log`. Resubmit after fixing.
   - Yambo itself failed to compile: the job prints a `grep` command that finds the errors.
3. **QE + p2y**, after the CPU build. Ends with `PREP OK`.
   ```bash
   sbatch 03_qe_prep.slurm
   ```
   Runs the project's QE (CPU) for scf + nscf with 200 bands, converts with `p2y`, and runs the Yambo setup.
4. **Tests.** Each ends with `TESTS OK`. Only one job at a time may run on `gpu-a100-small`, so start `04` after the GPU build.

   | Job | Partition | Layout | Label |
   |---|---|---|---|
   | `sbatch 04_test_gpu_small.slurm` | `gpu-a100-small` | 2 tasks × 2 threads, one MIG slice each | `gpu_small` |
   | `sbatch 05_test_cpu_p1.slurm` | `compute-p1` | 24 tasks × 2 threads | `cpu_p1` |
   | `sbatch 06_test_cpu_p2.slurm` | `compute-p2` | 32 tasks × 2 threads | `cpu_p2` |
   | `sbatch 07_bench_gpu_a100.slurm` (optional) | `gpu-a100` | 4 tasks × 16 threads, one A100 each | `gpu_a100_4gpu` |

5. **Compare**, on a login node. The first run listed is the reference; leave out runs you did not do.
   ```bash
   python3 -I 08_compare.py /scratch/$USER/yambo_5.3.0_tests/{cpu_p1,cpu_p2,gpu_small,gpu_a100_4gpu}
   ```
   Tolerances: QP corrections 5 meV, spectra 1 %, Haydock spectra 2 % (the solver's own accuracy). It also prints each step's wall time and the speed-up against the reference.
6. **Keep the reference** once validation has passed, for comparing the next version:
   ```bash
   ref=/projects/electronic_structure/yambo_5.3.0_2026/reference/cpu_p1_5.3.0
   mkdir -p $ref && cp /scratch/$USER/yambo_5.3.0_tests/cpu_p1/{o-*,r-*,timings.tsv} $ref/
   ```

## Options

Pass them with `--export`, always keeping `ALL` (or the job loses your environment): `sbatch --export=ALL,FRESH=1 01_build_gpu.slurm`, or several at once, `--export=ALL,NB=150,LABEL=trial`.

| Variable | Jobs | Default | What it does |
|---|---|---|---|
| `FRESH=1` | `01`, `02` | off | Deletes the build tree and starts from scratch. Not when resubmitting a build that timed out. |
| `CUDA_RUNTIME=X.Y` | `01` | newest nvhpc CUDA the driver supports | CUDA version for configure; combine with `FRESH=1` on an existing tree. |
| `NBND=N` | `03` | 200 | Bands in the QE nscf run. |
| `NB=N` | `04`–`07` | 200 | Bands in GW and BSE; at most the bands in the SAVE. |
| `LABEL=name` | `04`–`07` | see the table above | Run directory name, so a trial does not overwrite an earlier run. |

## The test

Bulk hBN from the Yambo tutorials ([tutorial page](https://wiki.yambo-code.eu/wiki/index.php?title=Bulk_material:_h-BN), [input files](https://media.yambo-code.eu/educational/tutorials/files/hBN.tar.gz)), with more bands and our own GW and BSE parameters: 4 atoms, 6×6×2 k-grid (14 k-points), 40 Ry cutoff, 200 bands.

| Step | What | Main parameters |
|---|---|---|
| `gw` | G0W0, plasmon-pole, Newton solver | 200 bands in χ and G, 8 Ry χ block, 40 Ry exchange; QP for bands 7–10 at all k |
| `bse_h` | static screening + SEX kernel + Haydock | bands 5–12, 30 Ry exchange, 6 Ry W block, GW energies from `gw` |
| `bse_s` | SLEPc, 20 lowest excitons | reuses the screening and kernel of `bse_h` |

The test is defined once, in `example/yambo_hBN_gpu.slurm`, which is also the example for users (below). `run_tests.sh` runs it and only sets the module, the SAVE and the run directory. To change the test, edit the example (or raise `NB`, and `NBND` in `03`). A 10 GB MIG slice limits how big it can get on `gpu-a100-small`.

## Using the installation

```bash
module use /projects/electronic_structure/yambo_5.3.0_2026/modulefiles
module load yambo-gpu/5.3.0     # or yambo-cpu/5.3.0
```

- **Always start `yambo`, `p2y` and `ypp` with `srun --mpi=pmix`** inside a job, even for one process: started directly, HPC-X's Open MPI fails in `MPI_Init`.
- **GPU jobs:** one MPI task per GPU (`--gpus-per-task=1`), several OpenMP threads per task. On `gpu-a100`: up to 4 tasks per node, up to 16 cores each. Use all 4 GPUs (see the limitations below).
- **CPU jobs:** pick one partition and fill a node: on `compute-p1` 24 tasks × 2 threads (`--mem-per-cpu=3900M`), on `compute-p2` 32 tasks × 2 threads (`--mem-per-cpu=3000M`). Do not use the compute-p1 layout on compute-p2: with 24 × 2 there, the BSE Haydock solver gave a wrong spectrum (see [Haydock accuracy](UPGRADING.md#yambo-behaviour-worth-knowing)).

**Example job.** `example/yambo_hBN_gpu.slurm` runs the hBN test on one full `gpu-a100` node, without these scripts (a comment shows how to use `gpu-a100-small` instead). It loads the module, copies the SAVE to `/scratch/$USER/yambo_hBN_example/<job id>`, runs Yambo's setup if needed, then GW, BSE Haydock and BSE SLEPc. To use it:
1. Make an hBN SAVE: QE scf + nscf with the tutorial's inputs, converted with `p2y` (see [01_scf.sh in MoS2-QE-Yambo-pnas](https://github.com/sebranchett/MoS2-QE-Yambo-pnas/blob/main/01_scf.sh) or the [Simulation Suite](https://simulationsuite.streamlit.app/)). The default `SAVE_SRC` is the SAVE from step 3.
2. Copy the script, set `SAVE_SRC` and `--account` in it, and `sbatch` it.

## Known limitations

- **Screening and BSE kernel are slow on the GPU.** The GPU build computes the screening (`Xo (procedure)` in the `r-*` reports) on one host thread, whatever `X_Threads` says, so a bigger GPU does not help. The BSE kernel (`X T_space Kernel`) is also slower than on a CPU node. Both split over MPI tasks, so use one task per GPU on all 4 GPUs of a `gpu-a100` node. Compared with a full compute-p2 node (earlier CPU build, 32 × 2):

  | Layout | GW | BSE Haydock |
  |---|---|---|
  | 4 tasks on 4 A100s | 3.3× faster | 1.4× slower |
  | 1 task on 1 A100 | same | 4.5× slower |

  Details in [UPGRADING.md](UPGRADING.md#yambo-behaviour-worth-knowing). We use Yambo as released.
- **MIG slices** (`gpu-a100-small`) cannot exchange data GPU-to-GPU: `04` tests the multi-GPU code path, not multi-GPU speed. `07` measures that.
- **CUDA-aware MPI.** The GPU build prints `mpi_built_with_cuda_support` (`true` for nvhpc 25.7's HPC-X). If `false`, it still works, but MPI buffers go through host memory.
- **QE version.** Yambo 5.3.0's `p2y` reads output from the project's QE 7.6. Another QE version may not work; `03` then stops with `p2y`'s error.

## Checking for open-source code in these scripts

`check_license_infringements.sh` scans this directory with [SCANOSS](https://github.com/scanoss/scanoss.py) for code that matches known open-source projects. Run it on your own machine, with the `scanoss` Python package installed ([installation](https://docs.scanoss.com/en/latest/cli/scanoss-py/installation)):

```bash
conda activate scanoss        # or any environment with: python -m pip install scanoss
bash check_license_infringements.sh
```

The full result goes to `dependencies.json`. The script prints every match (`"id"` not `"none"`) with some context; check the licence of each. Nothing printed before `Search Complete` means no matches.

## Acknowledgements

These scripts were developed by @sebranchett in collaboration with Claude (Anthropic's AI model), working in Claude Code. Claude wrote and revised the scripts and documentation and analysed the job output; @sebranchett ran every job on DelftBlue, brought back the results, and made the decisions about scope, design and what to keep. The DelftBlue lessons in [UPGRADING.md](UPGRADING.md) came out of that back-and-forth.
