#!/bin/bash
#SBATCH --job-name=yambo-bench-gpu-a100
#SBATCH --partition=gpu-a100
#SBATCH --time=02:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --gpus-per-task=1
#SBATCH --mem-per-cpu=7500M
#SBATCH --account=research-as-cheme
#SBATCH --output=%x-%j.out

# Optional: the same test on one full 80 GB A100, as production jobs will run.
# For 4 GPUs with real GPU-to-GPU CUDA-aware MPI use --ntasks=4 and a different label.
bash "$SLURM_SUBMIT_DIR/run_tests.sh" gpu gpu_a100_1gpu
