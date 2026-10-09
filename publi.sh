#!/usr/bin/env bash
set -euo pipefail

PROMPT='Summarize this git diff as a single Conventional Commit.
- type: the conventional commit type.
- scope: the main file or module changed (e.g. auth.ts), or "" when changes span unrelated areas.
- message: imperative mood, lowercase, no trailing period, at most 60 characters.
Use only the provided diff. Do not use tools or change files.'

SCHEMA='{"type":"object","additionalProperties":false,"required":["type","scope","message"],"properties":{
  "type":{"type":"string","enum":["feat","fix","perf","refactor","docs","test","build","ci","style","chore"]},
  "scope":{"type":"string"},
  "message":{"type":"string","minLength":1}}}'

MAX_DIFF_CHARS=100000
VERSION_RE='(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'

index_before=
tmp_dir=
stage_all=0
provider=claude
model=
USAGE='usage: publi.sh [--stage] [--provider claude|codex|gemini] [--model MODEL]'

die() {
  printf 'publi.sh: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [ -n "$index_before" ]; then git read-tree "$index_before" || true; fi
  if [ -n "$tmp_dir" ]; then rm -rf "$tmp_dir"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_value() {
  [ -n "$2" ] && [[ $2 != -* ]] || die "$1 requires a value ($USAGE)"
}

bump() {
  local major minor patch
  if [ -z "$1" ]; then
    echo 1.0.0
    return
  fi
  IFS=. read -r major minor patch <<<"$1"
  case $2 in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --stage) stage_all=1 ;;
    --provider | -p)
      require_value --provider "${2-}"
      provider=$2
      shift
      ;;
    --provider=*)
      provider=${1#*=}
      require_value --provider "$provider"
      ;;
    --model | -m)
      require_value --model "${2-}"
      model=$2
      shift
      ;;
    --model=*)
      model=${1#*=}
      require_value --model "$model"
      ;;
    --help | -h)
      printf '%s\n\n%s\n' "$USAGE" \
        '  --stage          stage all changes (default when nothing is staged)
  -p, --provider   AI CLI to use (default: claude)
  -m, --model      model override (default: haiku for claude, CLI default otherwise)
  -h, --help       show this help'
      exit 0
      ;;
    *) die "unknown option: $1 ($USAGE)" ;;
  esac
  shift
done

case $provider in
  claude | codex | gemini) ;;
  *) die "unsupported provider: $provider (choose claude, codex, or gemini)" ;;
esac
command -v "$provider" >/dev/null 2>&1 || die "$provider not found on PATH"

has_package=0
if [ -f package.json ]; then
  has_package=1
  current=$(jq -r '.version // empty' package.json)
  [[ $current =~ ^$VERSION_RE$ ]] || die "package.json version '$current' is not X.Y.Z"
else
  tags=$(git tag --list 'v*' --sort=-v:refname) || die "could not list tags"
  current=$(grep -Em1 "^v$VERSION_RE\$" <<<"$tags" || true)
  current=${current#v}
fi

branch=$(git symbolic-ref -q --short HEAD) || die "HEAD is detached"
remote=$(git config "branch.$branch.remote") && upstream=$(git config "branch.$branch.merge") \
  || die "branch $branch has no upstream"

index_before=$(git write-tree)
if [ "$stage_all" = 1 ] || git diff --cached --quiet; then
  git add -A
  git diff --cached --quiet && die "nothing to commit"
fi
[ "$has_package" = 0 ] || git diff --quiet -- package.json || die "package.json has unstaged changes"

diff=$(git diff --cached)
if [ "${#diff}" -gt "$MAX_DIFF_CHARS" ]; then
  diff="$(git diff --cached --stat)

$diff"
  diff="${diff:0:MAX_DIFF_CHARS}
[diff truncated to $MAX_DIFF_CHARS characters]"
fi

tmp_dir=$(mktemp -d) || die "could not create temporary directory"
set --
if [ -n "$model" ]; then set -- --model "$model"; fi

case $provider in
  claude)
    response=$(printf '%s\n' "$diff" | claude --safe-mode -p "$PROMPT" --model "${model:-haiku}" --tools "" \
      --output-format json --json-schema "$SCHEMA") || die "claude failed"
    response=$(jq -ce 'select(.is_error != true) | .structured_output // empty' <<<"$response") \
      || die "claude returned no commit message"
    ;;
  codex)
    printf '%s\n' "$SCHEMA" >"$tmp_dir/schema.json" || die "could not write output schema"
    printf '%s\n' "$diff" | codex exec "$@" --sandbox read-only \
      --output-schema "$tmp_dir/schema.json" --output-last-message "$tmp_dir/response.json" \
      "$PROMPT" >/dev/null || die "codex failed"
    response=$(cat "$tmp_dir/response.json") || die "codex returned no commit message"
    ;;
  gemini)
    printf '%s\n' '[[rule]]' 'toolName = "*"' 'decision = "deny"' 'priority = 999' \
      >"$tmp_dir/policy.toml" || die "could not write tool policy"
    response=$(printf '%s\n' "$diff" | gemini -p "$PROMPT
Return only JSON matching this schema, without markdown fences or other text:
$SCHEMA" "$@" --output-format json --policy "$tmp_dir/policy.toml") || die "gemini failed"
    response=$(jq -ce 'select(.error == null) | .response | fromjson' <<<"$response") \
      || die "gemini returned no commit message"
    ;;
esac

response=$(jq -sce --argjson schema "$SCHEMA" '
  select(length == 1) | .[0]
  | select(type == "object")
  | select(.type as $type | $schema.properties.type.enum | index($type))
  | select(.scope | type == "string")
  | select(.message | type == "string" and length > 0)
  | select([.type, .scope, .message] | all(test("[\r\n]") | not))
' <<<"$response") || die "$provider returned no commit message or an invalid commit message"
type=$(jq -r '.type' <<<"$response")
scope=$(jq -r '.scope' <<<"$response")
message=$(jq -r '.message' <<<"$response")

commit_msg="$type${scope:+($scope)}: $message"
level=minor

printf '\n%s\n' "$(git diff --cached --stat)"
while :; do
  next=$(bump "$current" "$level")
  printf '\ncommit: %s\nversion: %s\n\nenter to approve\nesc to cancel\n' "$commit_msg" "${current:+$current => }$next"
  if [ -n "$current" ]; then
    [ "$level" = major ] || printf 'm to bump major\n'
    [ "$level" = patch ] || printf 'p to bump patch\n'
  fi
  IFS= read -rsn1 key || key=$'\e'
  case $key in
    '') break ;;
    m | M) level=major ;;
    p | P) level=patch ;;
    $'\e') die "cancelled" ;;
  esac
done

if [ "$has_package" = 1 ]; then
  tmp="$tmp_dir/package.json"
  awk -v cur="$current" -v new="$next" '
    !done && match($0, /"version"[[:space:]]*:[[:space:]]*"/) {
      rest = substr($0, RSTART + RLENGTH)
      if (index(rest, cur "\"") == 1) {
        $0 = substr($0, 1, RSTART + RLENGTH - 1) new substr(rest, length(cur) + 1)
        done = 1
      }
    }
    { print }' package.json >"$tmp"
  [ "$(jq -r .version "$tmp")" = "$next" ] || die "could not update version in package.json"
fi
tag="v$next"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "tag $tag already exists"
remote_tag=$(git ls-remote --tags "$remote" "refs/tags/$tag") || die "could not reach $remote"
[ -z "$remote_tag" ] || die "tag $tag already exists on $remote"

git commit -q -m "$commit_msg" || die "commit failed"
index_before=
if [ "$has_package" = 1 ]; then
  cat "$tmp" >package.json
  git commit -q -m "chore: bump to $next" package.json
  git tag -a "$tag" -m "chore: bump to $next"
else
  git tag -a "$tag" -m "$commit_msg"
fi
git push -q --atomic "$remote" "HEAD:$upstream" "refs/tags/$tag"
printf '\npushed %s (%s)\n' "$tag" "$commit_msg"
