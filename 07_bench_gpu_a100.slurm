#!/bin/bash
#SBATCH --job-name=yambo-bench-gpu-a100-4gpu
#SBATCH --partition=gpu-a100
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --cpus-per-task=16
#SBATCH --gpus-per-task=1
#SBATCH --mem-per-cpu=3500M
#SBATCH --account=research-as-cheme
#SBATCH --output=%x-%j.out

# Optional benchmark, laid out as production jobs should be: a whole gpu-a100 node,
# 4 MPI tasks with one A100 each and 16 OpenMP threads per task. All 4 GPUs are on one
# node, so tasks exchange data GPU-to-GPU through CUDA-aware MPI. (One task on one
# A100 is the worst layout for Yambo 5.3.0's screening step: see UPGRADING.md.)
bash "$SLURM_SUBMIT_DIR/run_tests.sh" gpu gpu_a100_4gpu
