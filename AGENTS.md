# publi.sh

Single bash script; see `README.md` for behavior and `./publi.sh --help` for options. Runtime deps: `bash`, `git`, `jq`, and the selected provider CLI.

## Commands

- Tests: `bats test/publi.bats` (or `npx --yes bats test/publi.bats` when bats is not installed).

## Invariants

- The `EXIT` trap restores the index snapshot in `index_before` while it is set, so any exit before the change commit (`die`, a `set -e` failure, a signal, a rejected commit) leaves staging exactly as it was; clear `index_before` only after the change commit exists.
- `package.json` is rewritten with `awk`, not `jq`, because only the version string may change; formatting and key order must survive (a test asserts the exact file).
- The change commit holds the diff and the bump commit holds only `package.json`. Without a `package.json`, the version comes from the highest `vX.Y.Z` tag (`1.0.0` when none exists), there is no bump commit, and the tag goes on the change commit.
- Tests stub provider CLIs on `PATH` and record their stdin in `$BATS_TEST_TMPDIR/<provider>-stdin`; assert on that file to check what is sent to the model.
