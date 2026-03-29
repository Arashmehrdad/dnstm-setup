# Contributing

## Development Flow

1. Create a feature branch.
2. Keep behavioral changes scoped and preserve the existing TUI wording/style unless the change explicitly targets UX text.
3. Prefer extending the shared helpers in `lib/common.sh` and `lib/deps.sh` instead of adding new one-off shell fragments.
4. Add or update BATS coverage for helper-level behavior whenever practical.

## Project Standards

- Use `set -euo pipefail`.
- Quote expansions unless the code intentionally relies on word splitting.
- Prefer `write_file_atomic`, `sync_file`, and rollback-aware helpers for filesystem changes.
- Prefer pinned and checksum-verified downloads for all external binaries.
- Keep root-required mutations behind the dry-run aware command helpers.

## Local Checks

Run these from a Linux shell or Git Bash with the required tools installed:

```bash
bash -n dnstm-setup.sh bin/dnstm-setup lib/*.sh
shellcheck -x dnstm-setup.sh bin/dnstm-setup lib/*.sh tests/*.bash tests/*.bats
shfmt -d -i 4 -ci dnstm-setup.sh bin/dnstm-setup lib/*.sh tests/*.bash tests/*.bats
bats --recursive tests
```

## CI

GitHub Actions runs:

- ShellCheck
- shfmt
- bash syntax validation
- BATS tests

If a change adds new files under `bin/`, `lib/`, or `tests/`, update the CI globs if needed.
