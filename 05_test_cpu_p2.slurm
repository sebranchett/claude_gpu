#!/bin/bash
#SBATCH --job-name=yambo-test-cpu-p2
#SBATCH --partition=compute-p2
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=32
#SBATCH --cpus-per-task=2
#SBATCH --mem-per-cpu=3900M
#SBATCH --account=research-as-cheme
#SBATCH --output=%x-%j.out

# CPU baseline: one full compute-p2 node (64 cores), 32 MPI tasks x 2 OpenMP threads.
bash "$SLURM_SUBMIT_DIR/run_tests.sh" cpu cpu_p2
