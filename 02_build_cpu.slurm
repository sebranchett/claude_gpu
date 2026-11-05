#!/bin/bash
#SBATCH --job-name=yambo-build-cpu
#SBATCH --partition=compute-p2
#SBATCH --time=04:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem-per-cpu=3900M
#SBATCH --account=research-as-cheme
#SBATCH --output=%x-%j.out

# Submit from the scripts directory: sbatch 02_build_cpu.slurm
# compute-p2 has the same Sapphire Rapids CPUs as the GPU nodes, so -tp host is safe there.
bash "$SLURM_SUBMIT_DIR/build_yambo.sh" cpu
