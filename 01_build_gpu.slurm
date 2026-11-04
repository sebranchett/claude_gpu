#!/bin/bash
#SBATCH --job-name=yambo-build-gpu
#SBATCH --partition=gpu-a100-small
#SBATCH --time=04:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --gpus-per-task=1
#SBATCH --mem-per-cpu=7500M
#SBATCH --account=research-as-cheme
#SBATCH --output=%x-%j.out

# Submit from the scripts directory: sbatch 01_build_gpu.slurm
# If it hits the 4 h limit, just resubmit; the build resumes.
bash "$SLURM_SUBMIT_DIR/build_yambo.sh" gpu
