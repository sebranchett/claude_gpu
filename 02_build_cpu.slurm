#!/bin/bash
#SBATCH --job-name=yambo-build-cpu
#SBATCH --partition=compute-p1
#SBATCH --time=04:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem-per-cpu=3900M
#SBATCH --account=research-as-cheme
#SBATCH --output=%x-%j.out

# Submit from the scripts directory: sbatch 02_build_cpu.slurm
# Built on compute-p1 on purpose: nvfortran (and the libraries' own configure scripts)
# target the CPU they run on, here Cascade Lake ('-tp cascadelake' in the job output).
# The newer Sapphire Rapids CPUs of compute-p2 and the GPU nodes can run that code too;
# a build on compute-p2 would not run on compute-p1.
bash "$SLURM_SUBMIT_DIR/build_yambo.sh" cpu
