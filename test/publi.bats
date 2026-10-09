#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../publi.sh"

setup() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/claude-args"
cat >"$BATS_TEST_TMPDIR/claude-stdin"
[ -n "${CLAUDE_STUB_FAIL:-}" ] && exit 1
printf '%s' "$CLAUDE_STUB_OUTPUT"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  for provider in codex gemini; do
    cat >"$BATS_TEST_TMPDIR/bin/$provider" <<'EOF'
#!/usr/bin/env bash
provider=${0##*/}
printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/$provider-args"
cat >"$BATS_TEST_TMPDIR/$provider-stdin"
[ -n "${PROVIDER_STUB_FAIL:-}" ] && exit 1
case $provider in
  codex)
    while [ "$#" -gt 0 ]; do
      case $1 in
        --output-schema) cp "$2" "$BATS_TEST_TMPDIR/codex-schema"; shift ;;
        --output-last-message) output_file=$2; shift ;;
      esac
      shift
    done
    [ -n "${CODEX_STUB_NO_OUTPUT:-}" ] && exit 0
    printf '%s' "$PROVIDER_STUB_OUTPUT" >"$output_file"
    printf 'provider progress output\n'
    ;;
  gemini)
    while [ "$#" -gt 0 ]; do
      case $1 in
        --policy) cp "$2" "$BATS_TEST_TMPDIR/gemini-policy"; shift ;;
      esac
      shift
    done
    if [ -n "${GEMINI_STUB_OUTPUT:-}" ]; then
      printf '%s' "$GEMINI_STUB_OUTPUT"
    else
      jq -n --arg response "$PROVIDER_STUB_OUTPUT" '{response: $response}'
    fi
    ;;
esac
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/$provider"
  done
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  git init -q --bare -b main "$BATS_TEST_TMPDIR/remote.git"
  git init -q -b main "$BATS_TEST_TMPDIR/repo"
  cd "$BATS_TEST_TMPDIR/repo"
  cat >package.json <<'EOF'
{
  "name": "demo",
  "version": "0.1.0",
  "private": true
}
EOF
  git add package.json
  git commit -q -m "initial"
  git remote add origin "$BATS_TEST_TMPDIR/remote.git"
  git push -q -u origin main

  echo 'export const sign = () => "jwt"' >auth.ts
  stub_claude feat auth.ts "add authentication with JWT"
}

stub_claude() {
  export CLAUDE_STUB_OUTPUT="{\"is_error\":false,\"structured_output\":{\"type\":\"$1\",\"scope\":\"$2\",\"message\":\"$3\"}}"
  export PROVIDER_STUB_OUTPUT="{\"type\":\"$1\",\"scope\":\"$2\",\"message\":\"$3\"}"
}

publish() {
  run bash -c 'printf "%b" "$1" | "$2" "${@:3}"' _ "$1" "$SCRIPT" "${@:2}"
}

remote_log() {
  git --git-dir="$BATS_TEST_TMPDIR/remote.git" log --format=%s main
}

version() {
  jq -r .version package.json
}

@test "shows the proposed commit and version bump before asking" {
  publish '\e'
  [[ $output == *"commit: feat(auth.ts): add authentication with JWT"* ]]
  [[ $output == *"version: 0.1.0 => 0.2.0"* ]]
  [[ $output == *"enter to approve"* ]]
  [[ $output == *"esc to cancel"* ]]
  [[ $output == *"m to bump major"$'\n'"p to bump patch"* ]]
}

@test "shows the files being committed before asking" {
  publish '\e'
  [[ $output == *"auth.ts | 1 +"* ]]
}

@test "sends the diff of the changes to claude" {
  publish '\e'
  grep -q 'export const sign' "$BATS_TEST_TMPDIR/claude-stdin"
}

@test "sends a truncated diff with a file summary when the diff is too large" {
  head -c 300000 /dev/zero | tr '\0' 'a' >big.txt
  publish '\e'
  [ "$(wc -c <"$BATS_TEST_TMPDIR/claude-stdin")" -lt 101000 ]
  grep -q 'big.txt *|' "$BATS_TEST_TMPDIR/claude-stdin"
  grep -q 'auth.ts *|' "$BATS_TEST_TMPDIR/claude-stdin"
  tail -n1 "$BATS_TEST_TMPDIR/claude-stdin" | grep -q 'diff truncated to 100000 characters'
}

@test "approving a feat commits the change, bumps minor, and pushes both commits" {
  publish '\n'
  [ "$status" -eq 0 ]
  [ "$(version)" = 0.2.0 ]
  [ "$(remote_log)" = "$(printf '%s\n' 'chore: bump to 0.2.0' 'feat(auth.ts): add authentication with JWT' initial)" ]
}

@test "approving tags the bump commit and pushes the tag" {
  publish '\n'
  [ "$(git --git-dir="$BATS_TEST_TMPDIR/remote.git" rev-list -n1 v0.2.0)" = "$(git rev-parse HEAD)" ]
  [ "$(git --git-dir="$BATS_TEST_TMPDIR/remote.git" cat-file -t v0.2.0)" = tag ]
}

@test "fails without committing when the tag already exists" {
  git tag v0.2.0
  publish '\n'
  [ "$status" -eq 1 ]
  [[ $output == *"tag v0.2.0 already exists"* ]]
  [ "$(git log --format=%s)" = initial ]
}

@test "fails without committing when the tag already exists only on the remote" {
  git tag -a v0.2.0 -m other
  git push -q origin v0.2.0
  git tag -d v0.2.0 >/dev/null
  publish '\n'
  [ "$status" -eq 1 ]
  [[ $output == *"tag v0.2.0 already exists on origin"* ]]
  [ "$(git log --format=%s)" = initial ]
  [ "$(git status --porcelain)" = "?? auth.ts" ]
}

@test "fails before calling the provider when the branch has no upstream" {
  git branch -q --unset-upstream
  publish '\n'
  [ "$status" -eq 1 ]
  [[ $output == *"branch main has no upstream"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/claude-stdin" ]
}

@test "the change commit holds the diff and the bump commit holds only package.json" {
  publish '\n'
  [ "$(git show --format= --name-only HEAD~1)" = auth.ts ]
  [ "$(git show --format= --name-only HEAD)" = package.json ]
}

@test "non-feat types bump minor by default" {
  stub_claude fix auth.ts "handle expired tokens"
  publish '\n'
  [ "$(version)" = 0.2.0 ]
  [ "$(git log -1 --format=%s HEAD~1)" = "fix(auth.ts): handle expired tokens" ]
}

@test "an empty scope is left out of the commit message" {
  stub_claude chore "" "tidy up"
  publish '\n'
  [ "$(git log -1 --format=%s HEAD~1)" = "chore: tidy up" ]
}

@test "pressing m switches to a major bump and waits for approval" {
  publish 'm\n'
  [ "$status" -eq 0 ]
  [[ $output == *"version: 0.1.0 => 1.0.0"* ]]
  [ "$(version)" = 1.0.0 ]
  [ "$(git log -1 --format=%s)" = "chore: bump to 1.0.0" ]
}

@test "pressing p switches to a patch bump and waits for approval" {
  publish 'p\n'
  [ "$status" -eq 0 ]
  [[ $output == *"version: 0.1.0 => 0.1.1"* ]]
  [ "$(version)" = 0.1.1 ]
  [ "$(git log -1 --format=%s)" = "chore: bump to 0.1.1" ]
}

@test "escape cancels without committing and leaves changes unstaged" {
  publish '\e'
  [ "$status" -eq 1 ]
  [ "$(git log --format=%s)" = initial ]
  [ "$(version)" = 0.1.0 ]
  [ "$(git status --porcelain)" = "?? auth.ts" ]
}

@test "closed input cancels" {
  run bash -c "'$SCRIPT' </dev/null"
  [ "$status" -eq 1 ]
  [ "$(git log --format=%s)" = initial ]
}

@test "only staged changes are committed when something is staged" {
  echo 'notes' >notes.md
  git add auth.ts
  publish '\n'
  [ "$(git show --format= --name-only HEAD~1)" = auth.ts ]
  [ "$(git status --porcelain)" = "?? notes.md" ]
}

@test "--stage commits everything even when something is already staged" {
  echo 'notes' >notes.md
  git add auth.ts
  publish '\n' --stage
  [ "$status" -eq 0 ]
  [ "$(git show --format= --name-only HEAD~1)" = "$(printf 'auth.ts\nnotes.md')" ]
  [ -z "$(git status --porcelain)" ]
}

@test "cancelling after --stage restores the exact previous staging" {
  printf 'one\n' >notes.md
  git add notes.md
  printf 'one\ntwo\n' >notes.md
  before=$(git status --porcelain)
  publish '\e' --stage
  [ "$status" -eq 1 ]
  [ "$(git status --porcelain)" = "$before" ]
  [ "$(git show :notes.md)" = one ]
}

@test "a rejected change commit restores the exact previous staging" {
  printf '#!/bin/sh\nexit 1\n' >.git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  printf 'one\n' >notes.md
  git add notes.md
  printf 'one\ntwo\n' >notes.md
  before=$(git status --porcelain)
  publish '\n' --stage
  [ "$status" -eq 1 ]
  [ "$(git log --format=%s)" = initial ]
  [ "$(git status --porcelain)" = "$before" ]
  [ "$(git show :notes.md)" = one ]
}

@test "terminating at the prompt restores the exact previous staging" {
  printf 'one\n' >notes.md
  git add notes.md
  printf 'one\ntwo\n' >notes.md
  before=$(git status --porcelain)
  mkfifo "$BATS_TEST_TMPDIR/input"
  sleep 30 >"$BATS_TEST_TMPDIR/input" 3>&- &
  writer=$!
  "$SCRIPT" --stage <"$BATS_TEST_TMPDIR/input" >"$BATS_TEST_TMPDIR/output" 2>&1 3>&- &
  pid=$!
  for _ in $(seq 50); do
    grep -q 'enter to approve' "$BATS_TEST_TMPDIR/output" && break
    sleep 0.1
  done
  kill -TERM "$pid"
  status=0
  wait "$pid" || status=$?
  kill "$writer"
  [ "$status" -ne 0 ]
  [ "$(git log --format=%s)" = initial ]
  [ "$(git status --porcelain)" = "$before" ]
  [ "$(git show :notes.md)" = one ]
}

@test "rejects unknown options" {
  publish '\n' --bogus
  [ "$status" -eq 1 ]
  [[ $output == *"unknown option: --bogus"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/claude-stdin" ]
}

@test "defaults to claude haiku in safe mode and accepts an explicit claude provider" {
  publish '\e' --provider claude
  grep -qx -- '--safe-mode' "$BATS_TEST_TMPDIR/claude-args"
  grep -A1 -x -- '--model' "$BATS_TEST_TMPDIR/claude-args" | grep -qx haiku
  [ ! -e "$BATS_TEST_TMPDIR/codex-stdin" ]
  [ ! -e "$BATS_TEST_TMPDIR/gemini-stdin" ]
}

@test "--model overrides the claude model" {
  publish '\e' --model sonnet
  grep -A1 -x -- '--model' "$BATS_TEST_TMPDIR/claude-args" | grep -qx sonnet
}

@test "codex publishes a structured commit using the CLI default model" {
  publish '\n' --provider codex
  [ "$status" -eq 0 ]
  [ "$(version)" = 0.2.0 ]
  [ "$(remote_log)" = "$(printf '%s\n' 'chore: bump to 0.2.0' 'feat(auth.ts): add authentication with JWT' initial)" ]
  grep -q 'export const sign' "$BATS_TEST_TMPDIR/codex-stdin"
  grep -A1 -x -- '--sandbox' "$BATS_TEST_TMPDIR/codex-args" | grep -qx read-only
  ! grep -qx -- '--model' "$BATS_TEST_TMPDIR/codex-args"
  jq -e '.required == ["type", "scope", "message"]' "$BATS_TEST_TMPDIR/codex-schema"
  [ ! -e "$BATS_TEST_TMPDIR/claude-stdin" ]
}

@test "gemini publishes a structured commit using the CLI default model" {
  stub_claude fix auth.ts "handle expired tokens"
  publish '\n' --provider gemini
  [ "$status" -eq 0 ]
  [ "$(version)" = 0.2.0 ]
  [ "$(remote_log)" = "$(printf '%s\n' 'chore: bump to 0.2.0' 'fix(auth.ts): handle expired tokens' initial)" ]
  grep -q 'export const sign' "$BATS_TEST_TMPDIR/gemini-stdin"
  grep -qx 'decision = "deny"' "$BATS_TEST_TMPDIR/gemini-policy"
  ! grep -qx -- '--model' "$BATS_TEST_TMPDIR/gemini-args"
  [ ! -e "$BATS_TEST_TMPDIR/claude-stdin" ]
}

@test "provider and model support equals syntax and combine with --stage" {
  echo notes >notes.md
  git add auth.ts
  publish '\n' --model=custom-model --provider=codex --stage
  [ "$status" -eq 0 ]
  grep -A1 -x -- '--model' "$BATS_TEST_TMPDIR/codex-args" | grep -qx custom-model
  [ "$(git show --format= --name-only HEAD~1)" = "$(printf 'auth.ts\nnotes.md')" ]
}

@test "short provider and model options preserve the model as a single argument" {
  publish '\e' -m 'custom model' -p gemini
  [[ $output == *"commit: feat(auth.ts): add authentication with JWT"* ]]
  grep -A1 -x -- '--model' "$BATS_TEST_TMPDIR/gemini-args" | grep -qx 'custom model'
}

@test "rejects unsupported providers before changing staging" {
  git add auth.ts
  before=$(git write-tree)
  publish '\n' --provider unknown
  [ "$status" -eq 1 ]
  [[ $output == *"unsupported provider: unknown"* ]]
  [ "$(git write-tree)" = "$before" ]
  [ ! -e "$BATS_TEST_TMPDIR/claude-stdin" ]
}

@test "rejects a missing provider executable before changing staging" {
  mkdir "$BATS_TEST_TMPDIR/only-bash"
  ln -s "$(command -v bash)" "$BATS_TEST_TMPDIR/only-bash/bash"
  git add auth.ts
  before=$(git write-tree)
  run env PATH="$BATS_TEST_TMPDIR/only-bash" "$SCRIPT" --provider codex --stage
  [ "$status" -eq 1 ]
  [[ $output == *"codex not found on PATH"* ]]
  [ "$(git write-tree)" = "$before" ]
}

@test "rejects missing and empty provider or model values before calling a provider" {
  for option in --provider --model -p -m; do
    publish '\n' "$option"
    [ "$status" -eq 1 ]
    [[ $output == *"requires a value"* ]]
    publish '\n' "$option" --stage
    [ "$status" -eq 1 ]
    [[ $output == *"requires a value"* ]]
    publish '\n' "$option" ''
    [ "$status" -eq 1 ]
  done
  for option in --provider= --model=; do
    publish '\n' "$option"
    [ "$status" -eq 1 ]
  done
  [ ! -e "$BATS_TEST_TMPDIR/claude-stdin" ]
  [ "$(git status --porcelain)" = "?? auth.ts" ]
}

@test "shows help outside a package or git repository" {
  cd "$BATS_TEST_TMPDIR"
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ $output == *"--provider claude|codex|gemini"* ]]
  [[ $output == *"--model MODEL"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/claude-stdin" ]
}

@test "provider failures restore the exact staging before --stage" {
  export PROVIDER_STUB_FAIL=1
  printf 'one\n' >notes.md
  git add notes.md
  printf 'one\ntwo\n' >notes.md
  before=$(git status --porcelain)
  for provider in codex gemini; do
    publish '\n' --stage --provider "$provider"
    [ "$status" -eq 1 ]
    [[ $output == *"$provider failed"* ]]
    [ "$(git log --format=%s)" = initial ]
    [ "$(git status --porcelain)" = "$before" ]
    [ "$(git show :notes.md)" = one ]
  done
}

@test "invalid provider messages fail without committing and restore staging" {
  for response in 'not json' '{}' '[]' '{"type":"unknown","scope":"","message":"oops"}' \
    '{"type":"fix","scope":null,"message":"oops"}' \
    '{"type":"fix","scope":"","message":false}' \
    '{"type":"fix","scope":"","message":""}' \
    '{"type":"fix","scope":"","message":"first\nsecond"}'; do
    export PROVIDER_STUB_OUTPUT="$response"
    export CLAUDE_STUB_OUTPUT="{\"structured_output\":$response}"
    for provider in claude codex gemini; do
      publish '\n' --provider "$provider"
      [ "$status" -eq 1 ]
      [[ $output == *"no commit message"* ]]
      [ "$(git log --format=%s)" = initial ]
      [ "$(git status --porcelain)" = "?? auth.ts" ]
    done
  done
}

@test "rejects multiple commit objects from codex without committing" {
  export PROVIDER_STUB_OUTPUT='{"type":"fix","scope":"","message":"first"}
{"type":"fix","scope":"","message":"second"}'
  publish '\n' --provider codex
  [ "$status" -eq 1 ]
  [[ $output == *"invalid commit message"* ]]
  [ "$(git log --format=%s)" = initial ]
  [ "$(git status --porcelain)" = "?? auth.ts" ]
}

@test "rejects a gemini error response without committing" {
  export GEMINI_STUB_OUTPUT='{"response":"{\"type\":\"feat\",\"scope\":\"\",\"message\":\"oops\"}","error":{"message":"failed"}}'
  publish '\n' --provider gemini
  [ "$status" -eq 1 ]
  [[ $output == *"no commit message"* ]]
  [ "$(git status --porcelain)" = "?? auth.ts" ]
}

@test "rejects a successful codex run without a final message" {
  export CODEX_STUB_NO_OUTPUT=1
  publish '\n' --provider codex
  [ "$status" -eq 1 ]
  [[ $output == *"no commit message"* ]]
  [ "$(git status --porcelain)" = "?? auth.ts" ]
}

@test "cancelling cleans up provider temporary files and restores staging" {
  for provider in codex gemini; do
    publish '\e' --provider "$provider"
    [ "$status" -eq 1 ]
    [ "$(git status --porcelain)" = "?? auth.ts" ]
    case $provider in
      codex) option=--output-schema ;;
      gemini) option=--policy ;;
    esac
    path=$(awk -v option="$option" '$0 == option { getline; print }' "$BATS_TEST_TMPDIR/$provider-args")
    [ -n "$path" ]
    [ ! -e "${path%/*}" ]
  done
}

@test "preserves package.json formatting other than the version" {
  publish '\n'
  [ "$(cat package.json)" = "$(printf '{\n  "name": "demo",\n  "version": "0.2.0",\n  "private": true\n}')" ]
}

@test "fails when there is nothing to commit" {
  rm auth.ts
  publish '\n'
  [ "$status" -eq 1 ]
  [[ $output == *"nothing to commit"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/claude-stdin" ]
}

@test "fails without committing when claude fails" {
  export CLAUDE_STUB_FAIL=1
  publish '\n'
  [ "$status" -eq 1 ]
  [ "$(git log --format=%s)" = initial ]
  [ "$(git status --porcelain)" = "?? auth.ts" ]
}

@test "fails without committing when claude returns no message" {
  export CLAUDE_STUB_OUTPUT='{"is_error":true,"result":"oops"}'
  publish '\n'
  [ "$status" -eq 1 ]
  [[ $output == *"no commit message"* ]]
  [ "$(git log --format=%s)" = initial ]
}

@test "rejects a version that is not X.Y.Z" {
  for bad in 1.0.0-beta.1 1.08.0 01.0.0; do
    sed -i.bak "s/\"version\": \"[^\"]*\"/\"version\": \"$bad\"/" package.json && rm package.json.bak
    git commit -q -am "set $bad"
    publish '\n'
    [ "$status" -eq 1 ]
    [[ $output == *"version '$bad' is not X.Y.Z"* ]]
  done
}

@test "refuses to bump when package.json has unstaged edits alongside staged changes" {
  git add auth.ts
  sed -i.bak 's/"private": true/"private": false/' package.json && rm package.json.bak
  publish '\n'
  [ "$status" -eq 1 ]
  [[ $output == *"package.json has unstaged changes"* ]]
  [ "$(git log --format=%s)" = initial ]
}

@test "without package.json, bumps the highest vX.Y.Z tag and tags the change commit" {
  git rm -q package.json
  git commit -q -m "drop package.json"
  git tag v1.2.0
  git tag v1.10.0
  git tag v2.0.0-rc.1
  git push -q origin main
  publish '\n'
  [ "$status" -eq 0 ]
  [[ $output == *"version: 1.10.0 => 1.11.0"* ]]
  [ "$(remote_log)" = "$(printf '%s\n' 'feat(auth.ts): add authentication with JWT' 'drop package.json' initial)" ]
  [ "$(git --git-dir="$BATS_TEST_TMPDIR/remote.git" rev-list -n1 v1.11.0)" = "$(git rev-parse HEAD)" ]
  [ ! -e package.json ]
}

@test "without package.json or version tags, publishes the first commit of a new repository as 1.0.0" {
  git init -q --bare -b main "$BATS_TEST_TMPDIR/fresh.git"
  git init -q -b main "$BATS_TEST_TMPDIR/fresh"
  cd "$BATS_TEST_TMPDIR/fresh"
  git remote add origin "$BATS_TEST_TMPDIR/fresh.git"
  git config branch.main.remote origin
  git config branch.main.merge refs/heads/main
  echo 'echo hello' >hello.sh
  publish '\n'
  [ "$status" -eq 0 ]
  [[ $output == *"version: 1.0.0"$'\n'* ]]
  [[ $output != *"to bump"* ]]
  [ "$(git --git-dir="$BATS_TEST_TMPDIR/fresh.git" log --format=%s main)" = 'feat(auth.ts): add authentication with JWT' ]
  [ "$(git --git-dir="$BATS_TEST_TMPDIR/fresh.git" rev-list -n1 v1.0.0)" = "$(git rev-parse HEAD)" ]
}
