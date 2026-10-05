#!/usr/bin/env bash
# Runs merge.sh against a fake `gh` whose answers are set per case, and asserts whether `gh pr merge` was called and with which flags.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

cat >"$work/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/"*"/pulls") if [ -n "${OPEN_PULLS-7}" ]; then echo "${OPEN_PULLS-7}"; fi ;;
  "api repos/"*"/check-runs") echo "${CHECK_PASSED-1}" ;;
  "api graphql") echo "${UNRESOLVED-0}" ;;
  "pr view") printf '{"headRefOid":"%s","isDraft":%s,"baseRefName":"main","headRefName":"topic","isCrossRepository":%s,"labels":[{"name":"%s"}]}\n' "${PR_HEAD-abc}" "${PR_DRAFT-false}" "${PR_FORK-false}" "${PR_LABEL-automerge}" ;;
  "pr merge") echo "$*" >>"$MERGE_LOG" ;;
  *) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$work/bin/gh"

# Records fast-forward pushes in the merge log, and fails them when PUSH_FAILS is set, as a push onto a moved base branch would.
cat >"$work/bin/git" <<'FAKE'
#!/usr/bin/env bash
shift 2 # -C <dir>
while [ "$1" = -c ]; do shift 2; done
case "$1" in
  init | fetch | checkout) ;;
  rebase)
    if [ -n "${REBASE_FAILS-}" ] && [ "$2" != --abort ]; then exit 1; fi
    ;;
  push)
    # A fast-forward onto the base fails when PUSH_FAILS is set; pushing the head branch back (the update) always works.
    case "$*" in
      *refs/heads/main) if [ -n "${PUSH_FAILS-}" ]; then exit 1; fi ;;
    esac
    echo "push ${*:3}" >>"$MERGE_LOG"
    ;;
  *) echo "unexpected git call: $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$work/bin/git"

failures=0
# run <name> <expect: merged|skipped> [VAR=value ...]
run() {
  local name="$1" expect="$2"
  shift 2
  : >"$work/merges"
  if ! env PATH="$work/bin:$PATH" MERGE_LOG="$work/merges" GH_TOKEN=read MERGE_TOKEN=write \
    REPO=o/r HEAD_SHA=abc LABEL=automerge REQUIRED_CHECK="Required checks" MERGE_METHOD=rebase "$@" \
    "$root/merge.sh" >"$work/out" 2>&1; then
    echo "FAIL $name: exited non-zero"; cat "$work/out"; failures=$((failures + 1)); return
  fi
  if [ "$expect" = merged ] && [ ! -s "$work/merges" ]; then
    echo "FAIL $name: expected a merge"; failures=$((failures + 1))
  elif [ "$expect" = skipped ] && [ -s "$work/merges" ]; then
    echo "FAIL $name: merged but should not have"; failures=$((failures + 1))
  else
    echo "ok   $name"
  fi
}

run "green labelled pull request merges" merged
run "required check not passed" skipped CHECK_PASSED=0
run "no open pull request for the commit" skipped OPEN_PULLS=
run "draft" skipped PR_DRAFT=true
run "label missing" skipped PR_LABEL=other
run "head moved on" skipped PR_HEAD=def
run "unresolved thread" skipped UNRESOLVED=1
run "more threads than one page" skipped UNRESOLVED=100

run "squash method flag" merged MERGE_METHOD=squash
grep -q -- "--squash --match-head-commit abc" "$work/merges" || { echo "FAIL squash flags: $(cat "$work/merges")"; failures=$((failures + 1)); }
run "rebase method flag" merged
grep -q -- "--rebase --match-head-commit abc" "$work/merges" || { echo "FAIL rebase flags: $(cat "$work/merges")"; failures=$((failures + 1)); }

run "fast-forward pushes the head commit to the base branch" merged MERGE_METHOD=fast-forward SSH_KEY=key MERGE_TOKEN=
grep -q "push git@github.com:o/r.git abc:refs/heads/main" "$work/merges" || { echo "FAIL fast-forward refspec: $(cat "$work/merges")"; failures=$((failures + 1)); }
run "fast-forward onto a moved base is left alone" skipped MERGE_METHOD=fast-forward SSH_KEY=key MERGE_TOKEN= PUSH_FAILS=1

run "behind: update-behind rebases and pushes the head branch" merged MERGE_METHOD=fast-forward SSH_KEY=key MERGE_TOKEN= PUSH_FAILS=1 UPDATE_BEHIND=true
grep -q "push git@github.com:o/r.git HEAD:refs/heads/topic --force-with-lease=refs/heads/topic:abc" "$work/merges" || { echo "FAIL update push: $(cat "$work/merges")"; failures=$((failures + 1)); }
run "behind: a fork is not updated" skipped MERGE_METHOD=fast-forward SSH_KEY=key MERGE_TOKEN= PUSH_FAILS=1 UPDATE_BEHIND=true PR_FORK=true
run "behind: a conflicting rebase pushes nothing" skipped MERGE_METHOD=fast-forward SSH_KEY=key MERGE_TOKEN= PUSH_FAILS=1 UPDATE_BEHIND=true REBASE_FAILS=1
run "behind: left alone without update-behind" skipped MERGE_METHOD=fast-forward SSH_KEY=key MERGE_TOKEN= PUSH_FAILS=1

for missing in "MERGE_METHOD=fast-forward MERGE_TOKEN=w SSH_KEY=" "MERGE_METHOD=rebase MERGE_TOKEN= SSH_KEY=k"; do
  # shellcheck disable=SC2086 # the pairs are plain VAR=value words.
  if env PATH="$work/bin:$PATH" MERGE_LOG="$work/merges" GH_TOKEN=r REPO=o/r HEAD_SHA=abc LABEL=automerge REQUIRED_CHECK=x $missing \
    "$root/merge.sh" >/dev/null 2>&1; then
    echo "FAIL accepted a method without its credential: $missing"; failures=$((failures + 1))
  else
    echo "ok   method without its credential rejected"
  fi
done

if env PATH="$work/bin:$PATH" MERGE_LOG="$work/merges" GH_TOKEN=r MERGE_TOKEN=w REPO=o/r HEAD_SHA=abc LABEL=automerge \
  REQUIRED_CHECK=x MERGE_METHOD=ff "$root/merge.sh" >/dev/null 2>&1; then
  echo "FAIL unknown merge method accepted"; failures=$((failures + 1))
else
  echo "ok   unknown merge method rejected"
fi

[ "$failures" = 0 ]
