#!/usr/bin/env bash

set -euo pipefail

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=../lib/common.sh
source "${TEST_ROOT}/lib/common.sh"
# shellcheck source=../lib/deps.sh
source "${TEST_ROOT}/lib/deps.sh"

reset_test_runtime() {
    DRY_RUN=false
    DEBUG_MODE=false
    LOG_INITIALIZED=false
    LOG_FILE="/tmp/dnstm-setup-test.log"
    clear_rollback_stack
    init_logging
}
