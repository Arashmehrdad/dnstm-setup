#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
LOCAL_ENTRY="${SCRIPT_DIR}/bin/dnstm-setup"
INSTALLED_ENTRY="/usr/local/bin/dnstm-setup"
BOOTSTRAP_URL="https://codeload.github.com/SamNet-dev/dnstm-setup/tar.gz/master"

if [[ -x "$LOCAL_ENTRY" ]]; then
    exec "$LOCAL_ENTRY" "$@"
fi

if [[ -x "$INSTALLED_ENTRY" ]] && [[ "$INSTALLED_ENTRY" != "$(readlink -f "$0" 2>/dev/null || echo "$0")" ]]; then
    exec "$INSTALLED_ENTRY" "$@"
fi

if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    echo "bootstrap error: curl and tar are required to run the standalone wrapper" >&2
    exit 1
fi

BOOTSTRAP_TMP="$(mktemp -d /tmp/dnstm-setup-bootstrap.XXXXXX)"
cleanup() {
    rm -rf -- "$BOOTSTRAP_TMP"
}
trap cleanup EXIT

curl -fsSL --connect-timeout 10 --max-time 120 -o "${BOOTSTRAP_TMP}/repo.tar.gz" "$BOOTSTRAP_URL"
tar -xzf "${BOOTSTRAP_TMP}/repo.tar.gz" -C "$BOOTSTRAP_TMP"
BOOTSTRAP_ROOT="$(find "$BOOTSTRAP_TMP" -mindepth 1 -maxdepth 1 -type d | head -n1)"

if [[ -z "$BOOTSTRAP_ROOT" || ! -x "${BOOTSTRAP_ROOT}/bin/dnstm-setup" ]]; then
    echo "bootstrap error: extracted repository is missing bin/dnstm-setup" >&2
    exit 1
fi

exec "${BOOTSTRAP_ROOT}/bin/dnstm-setup" "$@"
