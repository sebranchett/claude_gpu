#!/bin/bash
# Run the hBN GW + BSE test with this version's build, inside a Slurm job.
# Usage: run_tests.sh gpu|cpu <label>
# The test itself is example/yambo_hBN_gpu.slurm, the same script users run; this only
# points it at this version's module and SAVE, and at $TEST_ROOT/<label> for the results.
set -euo pipefail
source "${SLURM_SUBMIT_DIR:?submit from the scripts directory}/common.sh"

flavour=${1:?usage: run_tests.sh gpu|cpu <label>}
label=${LABEL:-${2:?usage: run_tests.sh gpu|cpu <label>}}   # LABEL overrides, to keep earlier runs
[ -d "$TEST_ROOT/hBN_SAVE/SAVE" ] || die "no SAVE in $TEST_ROOT/hBN_SAVE; run 03_qe_prep.slurm first"

rm -rf "${TEST_ROOT:?}/$label"
YAMBO_MODULES=$MODULE_DIR YAMBO_MODULE=yambo-$flavour/$YAMBO_VERSION \
SAVE_SRC=$TEST_ROOT/hBN_SAVE/SAVE RUN=$TEST_ROOT/$label \
    bash "$SCRIPT_DIR/example/yambo_hBN_gpu.slurm"
echo "TESTS OK: $TEST_ROOT/$label"
