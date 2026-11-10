# Yambo 5.3.0 GPU build on DelftBlue

Scripts that build Yambo 5.3.0 for the A100 GPU nodes of DelftBlue, plus a CPU-only reference build, and validate both with a GW + BSE run on bulk hBN.

**Building a newer Yambo version?** Start with [UPGRADING.md](UPGRADING.md): a checklist, the DelftBlue problems we hit and their fixes, and the 5.3.0 reference results.

| | GPU build | CPU build |
|---|---|---|
| Compiler / MPI | `nvhpc/25.7` (nvfortran + bundled HPC-X Open MPI), plus the 2026 `gcc` module for `libatomic.so.1` | same |
| GPU | CUDA Fortran, `--with-cuda-cc=80`, CUDA runtime auto-detected from the driver | – |
| Parallelism | MPI + OpenMP | MPI + OpenMP |
| Libraries | built by Yambo: HDF5 (parallel I/O), netCDF, LibXC, FFTW, ScaLAPACK, PETSc + SLEPc | same |
| Built on | `gpu-a100-small` | `compute-p1` (Cascade Lake, so the code also runs on the newer CPUs) |
| Runs on | `gpu-a100`, `gpu-a100-small` | `compute-p1`, `compute-p2`, GPU nodes: use `--partition=compute-p1,compute-p2` |

## Layout

Each Yambo version gets its own directory, `/projects/electronic_structure/yambo_gpu_<version>_<stack>`, set in `common.sh` (`YAMBO_VERSION`, and `STACK` for the DelftBlue software stack). A new version is built next to the old one, which stays usable. For 5.3.0:

```
/projects/electronic_structure/yambo_gpu_5.3.0_2026/
  scripts/                 this repository
  src/                     Yambo + library tarballs, hBN tutorial (from 00_fetch_sources.sh)
  build/gpu/yambo-5.3.0/   GPU build tree = installation (bin/), do not delete
  build/cpu/yambo-5.3.0/   CPU build tree = installation
  modulefiles/             yambo-gpu/5.3.0.lua, yambo-cpu/5.3.0.lua
  reference/cpu_p1_5.3.0/  validated test results, to compare the next version with (step 6)
```

Test runs go to `/scratch/$USER/yambo_5.3.0_tests`.

There is one modulefile, `modulefiles/yambo.lua`, for both builds and every version: installed as `yambo-gpu/<version>.lua` or `yambo-cpu/<version>.lua`, it takes the flavour and version from that name. The jobs that load the toolchain (`01`, `02`, `03`) install it and then load it, so builds, tests and users all get the same environment.

## Run order

Copy this directory to DelftBlue as `scripts/` in the project directory and submit everything **from there**: the jobs find `common.sh` through `$SLURM_SUBMIT_DIR`.

1. **Downloads**, on a login node (the compute and GPU nodes have no internet):
   ```bash
   bash 00_fetch_sources.sh
   ```
2. **Builds.** These two can run at the same time (different partitions):
   ```bash
   sbatch 01_build_gpu.slurm
   sbatch 02_build_cpu.slurm
   ```
   Each ends with `BUILD OK`. If the GPU build hits the 4 h limit of `gpu-a100-small`, resubmit it; it carries on where it stopped. Check the `config/report` in the job output: CUDA, MPI, OpenMP and SLEPc enabled, and which libraries were built internally. If a library Yambo builds itself fails, the job says which, resets it so a resubmit retries it, and stops; the reason is in that library's `config.log` under `lib/<library>/`. If Yambo itself fails to compile, the job prints a `grep` command that finds the compiler errors in the build tree's `log/`.
3. **QE + p2y**, after the CPU build:
   ```bash
   sbatch 03_qe_prep.slurm
   ```
   Runs `pw.x` (the project's QE module, CPU) for scf + nscf with 200 bands, converts the result with `p2y`, and runs the Yambo setup.
4. **Tests.** Only one job at a time is allowed on `gpu-a100-small`, so start `04` after the GPU build has finished:
   ```bash
   sbatch 04_test_gpu_small.slurm
   sbatch 05_test_cpu_p1.slurm
   sbatch 06_test_cpu_p2.slurm
   sbatch 07_bench_gpu_a100.slurm
   ```
   `05` and `06` run the CPU build on each CPU partition, with the same layout (24 tasks × 2 threads, which fits both node types). The last one is an optional benchmark: 4 tasks on a whole `gpu-a100` node (4 A100s, 16 threads each), as in production.
5. **Compare**, on a login node. The first run is the reference; leave out runs you did not do:
   ```bash
   python3 -I 08_compare.py /scratch/$USER/yambo_5.3.0_tests/{cpu_p1,cpu_p2,gpu_small,gpu_a100_4gpu}
   ```
   It checks that every output file agrees (QP corrections within 5 meV, spectra within 1 %, Haydock spectra within 2 %, the solver's own accuracy) and prints each step's wall time with speed-ups relative to the compute-p1 run.
6. **Keep the reference**, once validation has passed. The CPU run's outputs, reports and timings are all `08_compare.py` needs:
   ```bash
   ref=/projects/electronic_structure/yambo_gpu_5.3.0_2026/reference/cpu_p1_5.3.0
   mkdir -p $ref && cp /scratch/$USER/yambo_5.3.0_tests/cpu_p1/{o-*,r-*,timings.tsv} $ref/
   ```
   The next version is then also compared with this one (see [UPGRADING.md](UPGRADING.md)).

## Options

Set these when submitting, for example `sbatch --export=ALL,FRESH=1 01_build_gpu.slurm`; several go in one list, `--export=ALL,NB=150,LABEL=trial`. Always keep `ALL`, or the job loses your environment.

| Variable | Jobs | Default | What it does |
|---|---|---|---|
| `FRESH=1` | `01`, `02` | off | Deletes the build tree and builds from scratch. Leave it out when resubmitting a build that timed out, or it starts over again. |
| `CUDA_RUNTIME=X.Y` | `01` | newest nvhpc CUDA the driver supports | CUDA version for `--with-cuda-runtime`. Only used by configure, so combine it with `FRESH=1` on an existing tree. |
| `NBND=N` | `03` | 200 | Bands in the QE nscf run. |
| `NB=N` | `04`–`07` | 200 | Bands used in GW and BSE; at most the bands in the SAVE. |
| `LABEL=name` | `04`–`07` | `gpu_small`, `cpu_p1`, `cpu_p2`, `gpu_a100_4gpu` | Run directory under `/scratch/$USER/yambo_5.3.0_tests`, so a trial run does not overwrite an earlier one. |

## The test

Bulk hBN from the Yambo tutorials ([tutorial page](https://wiki.yambo-code.eu/wiki/index.php?title=Bulk_material:_h-BN), [input files](https://media.yambo-code.eu/educational/tutorials/files/hBN.tar.gz)), with more bands and our own GW and BSE parameters: 4 atoms, 6×6×2 k-grid (14 k-points), 40 Ry cutoff, 200 bands.

| Step | What | Main parameters |
|---|---|---|
| `gw` | G0W0, plasmon-pole, Newton solver | 200 bands in χ and G, 8 Ry χ block, 40 Ry exchange; QP for bands 7–10 at all k |
| `bse_h` | static screening + SEX kernel + Haydock | bands 5–12, 30 Ry exchange, 6 Ry W block, GW energies from `gw` |
| `bse_s` | SLEPc diagonalisation (20 lowest excitons) | reuses the screening and kernel of `bse_h` |

The test is defined in one place, `example/yambo_hBN_gpu.slurm`, which is also the example for users (below). The test jobs run it through `run_tests.sh`, which only sets the module (`yambo-gpu` or `yambo-cpu`), the SAVE and the run directory. To change the test or make it heavier, edit that script (or raise `NB`, and `NBND` in `03`). A 10 GB MIG slice limits how far you can go on `gpu-a100-small`.

## Using the installation

```bash
module use /projects/electronic_structure/yambo_gpu_5.3.0_2026/modulefiles
module load yambo-gpu/5.3.0
```

For the CPU build, load `yambo-cpu/5.3.0` instead; it runs on both CPU partitions, so let Slurm choose with `--partition=compute-p1,compute-p2` and a layout that fits a 48-core compute-p1 node (for example 24 tasks × 2 threads, `--mem-per-cpu=3900M`). In a GPU job use one MPI task per GPU (`--gpus-per-task=1`) and several OpenMP threads per task; on `gpu-a100` that is up to 4 tasks per node with up to 16 cores each. Inside a Slurm job, always start `yambo`, `p2y` and `ypp` with `srun --mpi=pmix`, even for a single process: started directly, HPC-X's Open MPI fails in `MPI_Init`.

**Example job.** `example/yambo_hBN_gpu.slurm` runs the hBN test as a standalone job, without these scripts: it loads the module, copies the user's SAVE to `/scratch/$USER/yambo_hBN_example/<job id>`, runs Yambo's setup if needed, and runs GW, BSE Haydock and BSE SLEPc on one full `gpu-a100` node (a comment shows how to use `gpu-a100-small` instead). Users make their own hBN SAVE (QE scf + nscf with the tutorial's inputs, converted with `p2y`; see [01_scf.sh in MoS2-QE-Yambo-pnas](https://github.com/sebranchett/MoS2-QE-Yambo-pnas/blob/main/01_scf.sh) or the [Simulation Suite](https://simulationsuite.streamlit.app/)), copy the script, set `SAVE_SRC` and `--account` in it, and submit it with `sbatch`. By default `SAVE_SRC` is the SAVE from step 3.

## Known limitations

- **Screening is slow on the GPU.** Yambo's GPU build computes the screening (`Xo (procedure)` in the `r-*` reports) with a single host thread, whatever `X_Threads` says, and a bigger GPU does not help. With 2 tasks on 2 MIG slices GW is still about 1.7× faster than a full compute-p2 node (earlier CPU build, 32 tasks × 2 threads), but BSE Haydock is about 2.4× slower; with one task on a full A100, GW is no faster and BSE Haydock about 4.5× slower. More MPI tasks split the screening. Details in [UPGRADING.md](UPGRADING.md). We use Yambo as released.
- **MIG slices** (`gpu-a100-small`) cannot exchange data GPU-to-GPU, so `04` exercises the multi-GPU code path but says nothing about multi-GPU performance; `07` measures that.
- **CUDA-aware MPI.** The GPU build prints `mpi_built_with_cuda_support` (`true` for nvhpc 25.7's HPC-X). If it says `false`, the build still works, but MPI buffers are copied through host memory.
- **QE version and p2y.** Yambo 5.3.0's `p2y` reads the output of the project's QE 7.6. Another QE version might write output `p2y` cannot read; `03` then stops with `p2y`'s error.

## Checking for open-source code in these scripts

`check_license_infringements.sh` scans this directory with [SCANOSS](https://github.com/scanoss/scanoss.py) to find code that matches known open-source projects, declared or not. It runs on your own machine, not on DelftBlue, and needs the `scanoss` Python package ([installation](https://docs.scanoss.com/en/latest/cli/scanoss-py/installation)):

```bash
conda activate scanoss        # or any environment with: python -m pip install scanoss
bash check_license_infringements.sh
```

The full result goes to `dependencies.json`. The script prints every entry whose `"id"` is not `"none"`, with some context: each is a file or snippet that SCANOSS matched to an open-source component, whose licence should be checked. If nothing is printed before `Search Complete`, there were no matches.

## Acknowledgements

These scripts were developed by @sebranchett in collaboration with Claude (Anthropic's AI model), working in Claude Code. Claude wrote and revised the scripts and documentation and analysed the job output; @sebranchett ran every job on DelftBlue, brought back the results, and made the decisions about scope, design and what to keep. The DelftBlue lessons in [UPGRADING.md](UPGRADING.md) came out of that back-and-forth.
