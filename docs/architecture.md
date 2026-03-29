# dnstm-setup Architecture

## Layout

- `bin/dnstm-setup`: thin entrypoint that parses flags, initializes logging, enables rollback handling, and dispatches to the right workflow.
- `lib/common.sh`: shared runtime primitives for logging, dry-run behavior, rollback registration, validation helpers, atomic writes, and command wrappers.
- `lib/ui.sh`: user-facing TUI helpers, prompts, help text, and formatting. These are preserved as the single place for visible console output.
- `lib/deps.sh`: pinned dependency metadata, checksum-verified downloads, bootstrap/update/install layout helpers, and binary/source installation utilities.
- `lib/firewall.sh`: resolver management, systemd drop-ins, MTU overrides, and runtime hardening helpers.
- `lib/tunnels.sh`: setup flow, management commands, Cloudflare integration, tunnel lifecycle, and summary/status workflows.
- `lib/xray.sh`: optional backend integration, panel/Xray helpers, and service overrides.

## Runtime Guarantees

- `set -euo pipefail` is enabled in every shell entrypoint and library.
- Logging defaults to `/var/log/dnstm-setup.log` and can be overridden with `--log-file`.
- `--debug` turns on verbose command/event logging.
- `--dry-run` short-circuits mutating commands and skips follow-up verification that depends on changed system state.
- Rollback actions are registered before file replacements and install-tree updates so a failed run can unwind critical changes in reverse order.
- Atomic file writes go through `write_file_atomic`, which writes to a temporary file, verifies change deltas, and only then installs the final file.

## Dependency Policy

- Every downloaded binary is pinned to an explicit upstream version/tag.
- Every downloaded binary is verified against a known SHA256 digest before installation.
- Install/update helpers are idempotent: if the on-disk file already matches the pinned checksum, the download is skipped.
- Source-based fallbacks are pinned to explicit upstream commits to avoid floating builds.

## Installed Layout

- Managed tree: `/opt/dnstm-setup`
- Primary CLI wrapper: `/usr/local/bin/dnstm-setup`
- Compatibility wrapper: `/usr/local/bin/dnstm-setup.sh`

The repository root `dnstm-setup.sh` remains a bootstrap-compatible shim. If it is executed standalone after a raw download, it fetches the full repository archive and re-enters through `bin/dnstm-setup`.

## Testing

- BATS covers the reusable helper layer: validation, checksum helpers, atomic file writes, and dry-run wrappers.
- GitHub Actions enforces ShellCheck, shfmt, bash syntax checks, and the BATS suite on every change.

## Extending The Script

1. Add new shared behavior to `lib/common.sh` when multiple modules need it.
2. Keep user-visible wording inside `lib/ui.sh` unless the text belongs to a specific workflow.
3. Prefer `write_file_atomic`, `sync_file`, and checksum-verified dependency helpers over ad-hoc `cat >`, `cp`, or floating `curl` calls.
4. Add a BATS regression test whenever you introduce a new helper or fix a bug in the shared runtime.
