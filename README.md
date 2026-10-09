# publi.sh

Commit, version, tag, and push in one step. `publi.sh` sends your staged diff to an AI CLI, proposes a Conventional Commit message and the next version, and pushes the commit with a `vX.Y.Z` tag after you approve.

## Requirements

- `bash`, `git`, and `jq`
- One provider CLI, signed in: [Claude Code](https://github.com/anthropics/claude-code) (`claude`, the default), [Codex](https://github.com/openai/codex) (`codex`), or [Gemini CLI](https://github.com/google-gemini/gemini-cli) (`gemini`)
- A checked-out branch with an upstream (`git push -u` once)

## Install

From a clone of this repository:

```sh
ln -s "$PWD/publi.sh" ~/.local/bin/publi.sh
```

Any directory on your `PATH` works in place of `~/.local/bin`.

## Usage

```sh
git add src/auth.ts
publi.sh
```

`publi.sh` shows the staged files, the proposed commit, and the version change, then waits for a key:

```text
 src/auth.ts | 12 ++++++++++++
 1 file changed, 12 insertions(+)

commit: feat(auth.ts): add jwt signing
version: 1.4.2 => 1.5.0

enter to approve
esc to cancel
m to bump major
p to bump patch
```

The current version comes from `package.json` when the current directory has one, and from the highest `vX.Y.Z` tag otherwise. Without either, the first release is `1.0.0`.

On approval it creates the change commit and pushes the branch and a `vX.Y.Z` tag together. With a `package.json`, it also commits `chore: bump to X.Y.Z` with the new version, changing nothing else in the file, and tags that commit; otherwise it tags the change commit.

| Option | Description |
|---|---|
| `--stage` | Stage all changes first. This is also what happens when nothing is staged. |
| `-p`, `--provider` | `claude` (default), `codex`, or `gemini`. |
| `-m`, `--model` | Model override. Defaults to `haiku` for `claude` and the CLI's own default otherwise. |
| `-h`, `--help` | Show help. |

Cancelling, with `esc`, Ctrl-C, or any failure before the change commit, restores staging exactly as it was. The run also stops before committing when the tag already exists locally or on the remote.

## Privacy

The staged diff, truncated to 100,000 characters, is sent to the selected provider. Each provider runs without tools: Claude in safe mode with no tools, Codex in a read-only sandbox, and Gemini with a deny-all tool policy.
