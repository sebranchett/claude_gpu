#!/bin/bash
#SBATCH --job-name=yambo-test-gpu-small
#SBATCH --partition=gpu-a100-small
#SBATCH --time=02:00:00
#SBATCH --ntasks=2
#SBATCH --cpus-per-task=2
#SBATCH --gpus-per-task=1
#SBATCH --mem-per-cpu=7500M
#SBATCH --account=research-as-cheme
#SBATCH --output=%x-%j.out

# 2 MPI tasks x 2 OpenMP threads, one 10 GB MIG slice per task (the partition maximum).
# MIG slices cannot talk GPU-to-GPU, so MPI traffic is staged through host memory here;
# this checks the CUDA-aware MPI code path, not its performance.
bash "$SLURM_SUBMIT_DIR/run_tests.sh" gpu gpu_small
