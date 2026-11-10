#!/bin/bash
#SBATCH --job-name=yambo-test-cpu-p2
#SBATCH --partition=compute-p2
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=24
#SBATCH --cpus-per-task=2
#SBATCH --mem-per-cpu=3900M
#SBATCH --account=research-as-cheme
#SBATCH --output=%x-%j.out

# CPU build on compute-p2 (Sapphire Rapids): 24 MPI tasks x 2 OpenMP threads, the
# usual layout for jobs that may run on compute-p1 or compute-p2 (fits both node types),
# so the timings compare directly with 05 on compute-p1.
bash "$SLURM_SUBMIT_DIR/run_tests.sh" cpu cpu_p2
