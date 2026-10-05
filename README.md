# merge-when-green

Merges a pull request once a required check has passed on its head commit, for repositories where GitHub's own auto-merge and required status checks are unavailable (a private repository on the Free plan).

A pull request is merged when all of these hold: it carries the opt-in label, it isn't a draft, it still has the commit being checked at its head, no review thread is unresolved, and the named check run succeeded on that commit. The merge is pinned to that commit with `--match-head-commit`, so a push made after the check passed is never merged unseen. Nothing stops anyone merging by hand; this only saves waiting.

## Use

The action has no triggers of its own, so a workflow supplies them: run it when CI finishes, and again when the label is added or the pull request leaves draft, so labelling an already-green pull request merges it at once.

```yaml
name: Merge when green

on:
  workflow_run:
    workflows: [CI]
    types: [completed]
  pull_request_target:
    types: [labeled, ready_for_review]

concurrency:
  group: merge-when-green-${{ github.event.workflow_run.head_sha || github.event.pull_request.head.sha }}
  cancel-in-progress: false

permissions:
  contents: read
  pull-requests: read
  checks: read

jobs:
  merge:
    if: >-
      (github.event_name == 'workflow_run' && github.event.workflow_run.event == 'pull_request' && github.event.workflow_run.conclusion == 'success')
      || (github.event_name == 'pull_request_target' && contains(github.event.pull_request.labels.*.name, 'automerge'))
    runs-on: ubuntu-latest
    steps:
      - uses: ExaDev/merge-when-green@v1
        with:
          merge-token: ${{ secrets.MERGE_TOKEN }}
          required-check: Required checks
```

Do not add a checkout step. Running no pull request code is what makes the `pull_request_target` trigger safe.

## Inputs

| Input | Default | Meaning |
|-------|---------|---------|
| `merge-token` | required | Token that performs the merge. Use a personal access token or app token rather than `GITHUB_TOKEN` when the merge should start workflows (a release on `main`), because GitHub does not start workflows from pushes made with `GITHUB_TOKEN`. It needs permission to merge pull requests. |
| `required-check` | required | Name of the check run that must have succeeded on the head commit. Point it at one aggregate job that `needs` every other job and runs with `if: always()`, so it passes only when they all did. |
| `label` | `automerge` | Label that opts a pull request in. |
| `merge-method` | `rebase` | `rebase`, `squash` or `merge`. |
| `read-token` | `github.token` | Token used to read pull requests, checks and review threads. |
| `head-sha` | event's head commit | Commit to act on. |

A pull request with more than one page of review threads counts as having an unresolved one.

## Development

`test/merge.test.sh` runs `merge.sh` against a fake `gh`; CI also runs `shellcheck`.
