# Yambo 5.3.0 GPU build on DelftBlue

Scripts that build Yambo 5.3.0 for the A100 GPU nodes of DelftBlue, plus a CPU-only reference build, and validate both with a GW + BSE run on bulk hBN.

Building a newer Yambo version? Start with [UPGRADING.md](UPGRADING.md): a checklist, the DelftBlue problems we hit and their fixes, and the 5.3.0 reference results.

| | GPU build | CPU build |
|---|---|---|
| Compiler / MPI | `nvhpc/25.7` (nvfortran + bundled HPC-X Open MPI), plus the 2026 `gcc` module for `libatomic.so.1` | same |
| GPU | CUDA Fortran, `--with-cuda-cc=80`, CUDA runtime auto-detected from the driver | – |
| Parallelism | MPI + OpenMP | MPI + OpenMP |
| Libraries | built by Yambo: HDF5 (parallel I/O), netCDF, LibXC, FFTW, ScaLAPACK, PETSc + SLEPc | same |
| Built on | `gpu-a100-small` | `compute-p2` |
| Runs on | `gpu-a100`, `gpu-a100-small` | `compute-p2`, GPU nodes (not `compute-p1`: built for Sapphire Rapids) |

Each Yambo version gets its own directory, `/projects/electronic_structure/yambo_gpu_<version>_<stack>`, where `<stack>` is the DelftBlue software stack (`2026`). Both are set in `common.sh` (`YAMBO_VERSION`, `STACK`). A new version is built next to the old one, which stays usable. For 5.3.0:

```
/projects/electronic_structure/yambo_gpu_5.3.0_2026/
  scripts/                 this repository
  src/                     Yambo + library tarballs, hBN tutorial (from 00_fetch_sources.sh)
  build/gpu/yambo-5.3.0/   GPU build tree = installation (bin/), do not delete
  build/cpu/yambo-5.3.0/   CPU build tree = installation
  modulefiles/             yambo-gpu/5.3.0.lua, yambo-cpu/5.3.0.lua
  reference/cpu_p2_5.3.0/  validated test results, to compare the next version with (step 6)
```

5.3.0 was first installed as `yambo_gpu_2026`. To move it to the new name, run on a login node:

```bash
cd /projects/electronic_structure && mv yambo_gpu_2026 yambo_gpu_5.3.0_2026 && ln -s yambo_gpu_5.3.0_2026 yambo_gpu_2026
```

The link keeps the old path working, which the installed binaries and libraries may still refer to. Then copy the updated `modulefiles/*/5.3.0.lua` to the new `modulefiles/`.

Test runs go to `/scratch/$USER/yambo_5.3.0_tests`.

## Run order

Copy this directory to DelftBlue, for example to `/projects/electronic_structure/yambo_gpu_5.3.0_2026/scripts`, and submit everything **from that directory**: the jobs find `common.sh` through `$SLURM_SUBMIT_DIR`.

1. **On a login node** (the compute and GPU nodes have no internet):
   ```bash
   bash 00_fetch_sources.sh
   ```
2. **Builds.** These two can run at the same time (different partitions):
   ```bash
   sbatch 01_build_gpu.slurm
   sbatch 02_build_cpu.slurm
   ```
   Each ends with `BUILD OK`. If the GPU build hits the 4 h limit of `gpu-a100-small`, resubmit it; it carries on where it stopped. To start a build tree over, submit with `--export=ALL,FRESH=1` (see [Options](#options)). Yambo's own build skips external libraries that fail, so the job builds them first and checks that each one installed. If one did not, the job prints its logs, resets it so a resubmit retries it, and stops. Check the `config/report` printed in the job output: it lists which libraries were found or built internally, and that CUDA, MPI, OpenMP and SLEPc are enabled.
3. **QE + p2y**, after the CPU build:
   ```bash
   sbatch 03_qe_prep.slurm
   ```
   This runs `pw.x` (CPU) for scf + nscf with 200 bands, converts the result with `p2y`, and runs the Yambo setup. QE is the project's module, loaded with `module use --append /projects/electronic_structure/.modulefiles` and `module load qe` (the job prints the QE version it used). If `p2y` cannot read that QE's output, fall back to the tutorial's ready-made SAVE (100 bands):
   ```bash
   sbatch --export=ALL,USE_TUTORIAL_SAVE=1 03_qe_prep.slurm
   ```
   Then add `--export=ALL,NB=100` to the test submissions below.
4. **Tests.** Only one job at a time is allowed on `gpu-a100-small`, so start it after the GPU build has finished:
   ```bash
   sbatch 04_test_gpu_small.slurm
   sbatch 05_test_cpu_p2.slurm
   sbatch 07_bench_gpu_a100.slurm
   sbatch 08_bench_gpu_a100_4gpu.slurm
   ```
   The last two are optional: `07` runs one task on one full A100, `08` runs 4 tasks on a whole `gpu-a100` node (4 A100s, 16 threads each), as in production.
5. **Compare** (login node). The first run is the reference; leave out runs you did not do:
   ```bash
   python3 -I 06_compare.py /scratch/$USER/yambo_5.3.0_tests/{cpu_p2,gpu_small,gpu_a100_1gpu,gpu_a100_4gpu}
   ```
   It checks that every output file agrees between the runs (QP corrections within 5 meV, spectra within 1 %, Haydock spectra within 2 %: Haydock stops at 2 % accuracy, `BSHayTrs`), and prints the wall time of each step with speed-ups relative to the CPU node.
6. **Keep the reference** (login node), once validation has passed. The output files, reports and timings of the CPU run are all `06_compare.py` needs; the SAVE is left out:
   ```bash
   ref=/projects/electronic_structure/yambo_gpu_5.3.0_2026/reference/cpu_p2_5.3.0
   mkdir -p $ref && cp /scratch/$USER/yambo_5.3.0_tests/cpu_p2/{o-*,r-*,timings.tsv} $ref/
   ```
   When the next version is validated, compare it with this one too. The physics should not change between versions:
   ```bash
   python3 -I 06_compare.py /projects/electronic_structure/yambo_gpu_5.3.0_2026/reference/cpu_p2_5.3.0 /scratch/$USER/yambo_<new version>_tests/cpu_p2
   ```

## Options

Set these as environment variables when submitting, for example `sbatch --export=ALL,FRESH=1 01_build_gpu.slurm`. Several go in one list: `--export=ALL,NB=100,LABEL=trial`. Always keep `ALL`, or the job loses your environment.

| Variable | Jobs | Default | What it does |
|---|---|---|---|
| `FRESH=1` | `01`, `02` | off | Deletes the build tree (`build/gpu/` or `build/cpu/`) and builds from scratch. Use it when an earlier attempt left broken state behind, for example after a toolchain change. A fresh build takes several hours, so the GPU build will need resubmitting; leave `FRESH` out of those resubmits, or each one starts over. |
| `CUDA_RUNTIME=X.Y` | `01` | newest nvhpc CUDA the driver supports | CUDA version passed to `--with-cuda-runtime`. Only takes effect before configure has run, so combine it with `FRESH=1` on an existing tree. |
| `NBND=N` | `03` | 200 | Number of bands in the QE nscf run. |
| `USE_TUTORIAL_SAVE=1` | `03` | off | Skips QE + `p2y` and uses the tutorial's ready-made SAVE (100 bands). Then run the tests with `NB=100`. |
| `NB=N` | `04`, `05`, `07`, `08` | 200 | Bands used in the GW and BSE runs. Must not exceed the bands in the SAVE. |
| `LABEL=name` | `04`, `05`, `07`, `08` | `gpu_small`, `cpu_p2`, `gpu_a100_1gpu`, `gpu_a100_4gpu` | Name of the run directory under `/scratch/$USER/yambo_5.3.0_tests`, so a trial run does not overwrite an earlier one. |

## The test

Bulk hBN from the Yambo tutorials ([tutorial page](https://wiki.yambo-code.eu/wiki/index.php?title=Bulk_material:_h-BN), [input files](https://media.yambo-code.eu/educational/tutorials/files/hBN.tar.gz), downloaded by `00_fetch_sources.sh`), with more bands and our own GW and BSE parameters: 4 atoms, 6×6×2 k-grid (14 k-points), 40 Ry cutoff, 200 bands.

| Step | What | Main parameters |
|---|---|---|
| `gw` | G0W0, plasmon-pole, Newton solver | 200 bands in χ and G, 8 Ry χ block, 40 Ry exchange; QP for bands 7–10 at all k |
| `bse_h` | static screening + SEX kernel + Haydock | bands 5–12, 30 Ry exchange, 6 Ry W block, GW energies from `gw` |
| `bse_s` | SLEPc diagonalisation (20 lowest excitons) | reuses the screening and kernel of `bse_h` |

To make the benchmark heavier, raise `NB` (and `NBND` in `03_qe_prep.slurm`) or the cutoffs in `example/yambo_hBN_gpu.slurm`. A 10 GB MIG slice limits how far you can go on `gpu-a100-small`.

## Using the installation

```bash
module use /projects/electronic_structure/yambo_gpu_5.3.0_2026/modulefiles
module load yambo-gpu/5.3.0
```

In a GPU job use one MPI task per GPU (`--gpus-per-task=1`), several OpenMP threads per task, and launch with `srun --mpi=pmix yambo ...`. On `gpu-a100` that means up to 4 tasks per node with up to 16 cores each.

### Example job for users

`example/yambo_hBN_gpu.slurm` is a standalone version of the hBN test for users who just want to run Yambo. It does not need these scripts. It loads the `yambo-gpu/5.3.0` module, copies the user's SAVE to `/scratch/$USER/yambo_hBN_example/<job id>`, runs Yambo's setup if the SAVE has not had it, and then runs GW, BSE Haydock and BSE SLEPc on one full `gpu-a100` node (4 tasks, one A100 each). A comment in the script shows how to run it on `gpu-a100-small` instead.

Users make their own SAVE for bulk hBN: Quantum ESPRESSO scf + nscf with the tutorial's inputs, converted with `p2y`. For how to do that, see [01_scf.sh in MoS2-QE-Yambo-pnas](https://github.com/sebranchett/MoS2-QE-Yambo-pnas/blob/main/01_scf.sh) or the [Simulation Suite](https://simulationsuite.streamlit.app/). They then copy `yambo_hBN_gpu.slurm` to their own directory, set `SAVE_SRC` and `--account` in it, and submit it with `sbatch`. By default `SAVE_SRC` points at the SAVE that step 03 makes, so you can run the example yourself without changing it.

The test jobs (`04`, `05`, `07`, `08`) run this same script through `run_tests.sh`, which sets the module (`yambo-gpu` or `yambo-cpu`), the SAVE and the run directory. So the test is defined in one place, every test run also checks the user example, and the tests use exactly the environment users get from the modulefile. To change the test, edit `example/yambo_hBN_gpu.slurm`.

Inside a Slurm job, always start `yambo`, `p2y` and `ypp` with `srun --mpi=pmix`, even for a single process: started directly, HPC-X's Open MPI fails in `MPI_Init`. The modulefiles set `OPAL_PREFIX` and add HPC-X's libraries to `LD_LIBRARY_PATH`, which the `nvhpc` module does not do.

## Checking for open-source code in these scripts

`check_license_infringements.sh` scans this directory with [SCANOSS](https://github.com/scanoss/scanoss.py) to find code that matches known open-source projects, whether or not we declared it. It runs on your own machine, not on DelftBlue, and needs the `scanoss` Python package ([installation](https://docs.scanoss.com/en/latest/cli/scanoss-py/installation)):

```bash
conda activate scanoss        # or any environment with: python -m pip install scanoss
bash check_license_infringements.sh
```

The full scan result goes to `dependencies.json`. The script then prints every entry whose `"id"` is not `"none"`, with a few lines of context: each one is a file or snippet that SCANOSS matched to an open-source component, and its licence should be checked. If nothing is printed before `Search Complete`, no matches were found.

## Known limitations and things to check

- **CUDA-aware MPI.** The build job prints `mpi_built_with_cuda_support` from the `ompi_info` it finds in the nvhpc SDK. If it says `false`, or no `ompi_info` is found, the GPU build still works, but MPI buffers are copied through host memory.
- **MIG slices** (`gpu-a100-small`) cannot exchange data GPU-to-GPU, so the 2-task test exercises the multi-GPU code path but says nothing about multi-GPU performance. `08_bench_gpu_a100_4gpu.slurm` (4 A100s on one `gpu-a100` node) measures that.
- **Screening is slow on the GPU.** Computing the screening (`Xo (procedure)` in the `r-*` reports) takes about 25 s on 2 MIG slices against about 5 s on a full compute-p2 node, in both GW and BSE. Yambo's GPU build runs that step with one OpenMP thread whatever `X_Threads` says. GW is still about 1.7× faster on the GPU because its self-energy part is much faster there, but the BSE Haydock step, where the screening is most of the work, is about 2.4× slower. A full 80 GB A100 does not help: with one MPI task it spends about 60 s in the screening, the same total work as the two MIG slices (which split it between two tasks), so this step is limited by the single host thread, not by the GPU. As a result, one task on a full A100 is no faster than the CPU node for GW and about 4.5× slower for BSE Haydock. Running more MPI tasks splits the screening between them (`08` tests 4 tasks on 4 A100s). We use Yambo as released and have not looked into this further.
- **QE version and p2y.** Yambo 5.3.0's `p2y` reads the output of the project's QE 7.6 (tested). A different QE version might write output `p2y` cannot read; in that case see step 3.
