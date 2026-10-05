#!/usr/bin/env bash
# Merges each open, non-draft pull request that carries $LABEL, has $HEAD_SHA at its head, has no unresolved review thread, and whose $REQUIRED_CHECK check run succeeded on $HEAD_SHA.
# Inputs (environment): GH_TOKEN, REPO, HEAD_SHA, LABEL, REQUIRED_CHECK, MERGE_METHOD, and either MERGE_TOKEN (rebase, squash or merge, through the API) or SSH_KEY (fast-forward, a push of the head commit to the base branch over SSH).
# A fast-forward push fails when the base branch has moved on, so a pull request that is behind is left for its owner to update rather than rewritten.
set -euo pipefail

case "$MERGE_METHOD" in
  rebase | squash | merge)
    : "${MERGE_TOKEN:?merge-token is required for merge-method $MERGE_METHOD}"
    ;;
  fast-forward)
    : "${SSH_KEY:?ssh-key is required for merge-method fast-forward}"
    key_file=$(mktemp)
    trap 'rm -f "$key_file"' EXIT
    chmod 600 "$key_file"
    printf '%s\n' "$SSH_KEY" >"$key_file"
    export GIT_SSH_COMMAND="ssh -i $key_file -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    ;;
  *)
    echo "merge-method must be rebase, squash, merge or fast-forward, not \"$MERGE_METHOD\"." >&2
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
  pr=$(gh pr view "$number" --repo "$REPO" --json headRefOid,isDraft,labels,baseRefName)
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
  if [ "$MERGE_METHOD" = fast-forward ]; then
    base=$(jq -r '.baseRefName' <<<"$pr")
    remote="git@github.com:$REPO.git"
    work=$(mktemp -d)
    git -C "$work" init -q
    git -C "$work" fetch -q "$remote" "refs/pull/$number/head"
    if ! git -C "$work" push -q "$remote" "${HEAD_SHA}:refs/heads/$base"; then
      echo "#$number can't be fast-forwarded onto $base; it needs updating first."
      rm -rf "$work"
      continue
    fi
    rm -rf "$work"
  else
    GH_TOKEN="$MERGE_TOKEN" gh pr merge "$number" --repo "$REPO" "--$MERGE_METHOD" --match-head-commit "$HEAD_SHA"
  fi
  echo "Merged #$number."
done
