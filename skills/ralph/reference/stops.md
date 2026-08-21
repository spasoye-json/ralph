# Stop outcomes

Every issue ralph finishes records one outcome in `.ralph/logs/metrics.csv`
(`timestamp,issue,outcome,cycles,seconds,reason`). `ralph status` aggregates
them. The vocabulary is `RALPH_OUTCOMES` in `lib.sh`; the reason column is the
first place to read, and `.ralph/logs/issue-<n>.log` is the second.

The exit code carries the class: 5 and 6 are safety, 3 is infra, 1 is everything
else.

## It worked

**`approved`** - the unresolved-thread count reached zero and the PR is
un-drafted, waiting for your merge. Nothing to do but review and merge.

## Safety stops - read the diff before retrying

These are the stops that exist because retrying is the wrong move.

**`secret-detected`** (exit 5) - the scan found a high-confidence secret in the
PR diff. Read the diff, rotate anything real, and strip the value before the
issue goes back in the queue. Re-running first would push the secret again.

**`escalated`** (exit 6) - the implementer declined the ticket and wrote its
reason into the escalation sentinel rather than forcing a bad PR. The reason is
in the metrics row. This is a ticket bug: the issue is underspecified or
self-contradictory. Rewrite the acceptance criteria, then re-queue.

## Infra stops - ralph or the host is broken

Retrying without a fix reproduces these.

**`implement-error`** (exit 3) - `/implement` crashed with no commits,
`RALPH_INFRA_RETRIES` times. Run `ralph doctor`. The usual causes are a skill
symlink dangling after a plugin update (`ralph link-skills`), a missing sandbox
image (`ralph sandbox-build`), or an expired token in `.ralph/.env`.

**`pr-failed`** (exit 3) - the PR-author produced no PR after several tries.
Check `gh auth status` and that the branch pushed.

## Quality caps - the ticket or the gate is the problem

Ralph tried and hit a bound. Under `RALPH_AFK=1` each of these means the retry
budget ran out, so read the log for what it kept failing on.

**`test-fail`** - the gate stayed red to the attempt cap. Either the change is
wrong or the gate is pointed at a suite that was already failing. Check whether
`LINT_CMD` and `TEST_CMD` are green on `BASE_BRANCH` before blaming the agent.

**`no-commits`** - `/implement` ran but committed nothing, repeatedly. Usually
the ticket asks for something already done, or the worktree lacks the
dependencies the agent needed to work.

**`verify-fail`** - the correctness verifier kept rejecting the change against
the issue. The implementation and the acceptance criteria disagree; read both.

**`handback`** - the review loop did not converge within
`RALPH_MAX_ATTEMPTS`, or `RALPH_AFK=0` handed it back on the first failure. Read
the open review threads on the PR: a reviewer looping on the same thread means
the finding is real and the fixer cannot see it.

**`conflict-unresolved`** - the rebase onto the base branch could not be
resolved. Rebase it by hand.

**`ci-fail`** - a stranded PR failed its required check after approval. Read the
CI log; the local gate and CI disagree, which usually means the gate is missing
something CI runs.

## Budget

**`budget-exceeded`** - `RALPH_ISSUE_BUDGET` seconds elapsed. The issue is
**re-queued**, not handed back, and the fail outcome counts toward the circuit
breaker. One ticket eating the budget twice is a ticket to split.

A stop that leaves the PR open does not lose the work. `ralph process-issue <n>`
resumes an open PR: it re-enters at the gate, the correctness check and the
review loop, and never re-implements from the base. Raise the budget on the
resume run, because the second run starts its own budget.
