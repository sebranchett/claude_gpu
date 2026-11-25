#!/bin/bash
#SBATCH --job-name=yambo-test-cpu-p2
#SBATCH --partition=compute-p2
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=32
#SBATCH --cpus-per-task=2
#SBATCH --mem-per-cpu=3000M
#SBATCH --account=research-as-cheme
#SBATCH --output=%x-%j.out

# CPU build on compute-p2 (Sapphire Rapids): a full 64-core node, 32 MPI tasks x 2 OpenMP
# threads. Not 24 x 2 (the compute-p1 layout): with that layout on compute-p2 the BSE
# Haydock solver twice took ~110 iterations instead of 59 and gave a wrong spectrum
# (see UPGRADING.md, "Haydock accuracy").
bash "$SLURM_SUBMIT_DIR/run_tests.sh" cpu cpu_p2
