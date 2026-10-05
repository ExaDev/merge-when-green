#!/usr/bin/env bash
# Merges each open, non-draft pull request that carries $LABEL, has $HEAD_SHA at its head, has no unresolved review thread, and whose $REQUIRED_CHECK check run succeeded on $HEAD_SHA.
# Inputs (environment): GH_TOKEN, MERGE_TOKEN, REPO, HEAD_SHA, LABEL, REQUIRED_CHECK, MERGE_METHOD (rebase, squash or merge).
set -euo pipefail

case "$MERGE_METHOD" in
  rebase | squash | merge) ;;
  *)
    echo "merge-method must be rebase, squash or merge, not \"$MERGE_METHOD\"." >&2
    exit 1
    ;;
esac

owner="${REPO%%/*}"
name="${REPO##*/}"

pulls=$(gh api "repos/$REPO/commits/$HEAD_SHA/pulls" --jq '.[] | select(.state == "open") | .number')
if [ -z "$pulls" ]; then
  echo "No open pull request has $HEAD_SHA at its head."
  exit 0
fi

passed=$(gh api "repos/$REPO/commits/$HEAD_SHA/check-runs" -f check_name="$REQUIRED_CHECK" --method GET \
  --jq '[.check_runs[] | select(.conclusion == "success")] | length')
if [ "$passed" = "0" ]; then
  echo "\"$REQUIRED_CHECK\" hasn't passed on $HEAD_SHA yet."
  exit 0
fi

for number in $pulls; do
  pr=$(gh pr view "$number" --repo "$REPO" --json headRefOid,isDraft,labels)
  if [ "$(jq -r '.headRefOid' <<<"$pr")" != "$HEAD_SHA" ]; then
    echo "#$number has moved on from $HEAD_SHA; its own CI run decides."
    continue
  fi
  if [ "$(jq -r '.isDraft' <<<"$pr")" = "true" ]; then
    echo "#$number is a draft."
    continue
  fi
  if ! jq -e --arg label "$LABEL" 'any(.labels[]; .name == $label)' <<<"$pr" >/dev/null; then
    echo "#$number isn't labelled $LABEL."
    continue
  fi
  # More than 100 threads cannot all be seen, so that counts as unresolved rather than risk merging past one.
  # shellcheck disable=SC2016 # $owner, $name and $number are GraphQL variables, not shell ones.
  unresolved=$(gh api graphql -F owner="$owner" -F name="$name" -F number="$number" -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100) { pageInfo { hasNextPage } nodes { isResolved } }
        }
      }
    }' --jq '.data.repository.pullRequest.reviewThreads
      | if .pageInfo.hasNextPage then 100 else [.nodes[] | select(.isResolved | not)] | length end')
  if [ "$unresolved" != "0" ]; then
    echo "#$number has unresolved review thread(s)."
    continue
  fi
  GH_TOKEN="$MERGE_TOKEN" gh pr merge "$number" --repo "$REPO" "--$MERGE_METHOD" --match-head-commit "$HEAD_SHA"
  echo "Merged #$number."
done
