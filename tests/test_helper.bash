#!/usr/bin/env bash

set -euo pipefail

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# shellcheck source=../lib/common.sh
source "${TEST_ROOT}/lib/common.sh"
# shellcheck source=../lib/ui.sh
source "${TEST_ROOT}/lib/ui.sh"
# shellcheck source=../lib/deps.sh
source "${TEST_ROOT}/lib/deps.sh"

reset_test_runtime() {
    local runtime_root

    runtime_root="/tmp/dnstm-setup-test-runtime-$$"
    rm -rf "$runtime_root"
    mkdir -p "$runtime_root"

    DRY_RUN=false
    DEBUG_MODE=false
    LOG_INITIALIZED=false
    LOG_FILE="${runtime_root}/dnstm-setup-test.log"
    STATE_DIR="${runtime_root}/state"
    DOMAIN=""
    SERVER_IP=""
    DNS_CLEANUP_REQUESTED=false
    unset DOMAIN_STATE_FILE
    clear_rollback_stack
    init_logging
}
