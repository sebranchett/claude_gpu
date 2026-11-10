#!/bin/bash
#SBATCH --job-name=yambo-test-cpu-p1
#SBATCH --partition=compute-p1
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=24
#SBATCH --cpus-per-task=2
#SBATCH --mem-per-cpu=3900M
#SBATCH --account=research-as-cheme
#SBATCH --output=%x-%j.out

# CPU build on compute-p1 (Cascade Lake, the CPU it is built for): 24 MPI tasks x 2
# OpenMP threads, the usual layout for jobs that may run on compute-p1 or compute-p2,
# so the timings compare directly with 06 on compute-p2.
bash "$SLURM_SUBMIT_DIR/run_tests.sh" cpu cpu_p1
