---
name: ralph
description: The ralph AFK agent loop - operating it, diagnosing a stop, and changing ralph itself. Use when queueing or running issues through ralph (`ralph run`, `ralph process-issue`), when a run ends in a handback or another stop outcome, when editing the ralph package or its eval fixtures, or when this skill has drifted from the code.
---

# Ralph

Ralph drains a queue of hand-triaged GitHub issues into reviewed PRs, running
`claude -p` once per stage: implement, gate, draft PR, verify, review, converge.

`$(ralph home)/README.md` is the manual. It carries the stage pipeline, every
env var, the label lifecycle, the sandbox and its threat model, and the eval
harness. Read it for anything mechanical. This skill carries what the README
cannot: which command fits the situation, how to read a stop, and how to change
ralph without breaking the repos that install it.

## Install and state

`ralph home` is the **install**, and ralph never writes there. `.ralph/` in the
repo you run from is the **state**: `config.sh` committed, `.env` and `logs/`
gitignored. One install drives every repo.

Wiring goes in `.ralph/config.sh`. `lib.sh` sources it before the packaged
defaults, so write only the values that differ. `ralph config` prints every
resolved value and the file it came from. A shell env var beats both files, for
one run.

## Operate

```bash
ralph doctor              # prerequisites: gh auth, docker, jq, flock, the three skills
ralph run --dry           # what the queue would pick up right now, then exit
ralph process-issue 40    # ONE issue, end to end; it claims the label itself
ralph run                 # drain the queue and every stranded review, then exit
ralph status              # queue, open PRs, throughput from .ralph/logs/metrics.csv
```

The live log is `.ralph/logs/issue-<n>.log`. Ralph un-drafts an approved PR and
stops there: the merge is the human checkpoint.

`RALPH_AFK=1` is the default and the standing rule. Ralph retries until the gate
is green, so a handback is a bug in ralph or in the ticket rather than a normal
outcome. Bound a first run with `RALPH_MAX_ATTEMPTS` and `RALPH_ISSUE_BUDGET`
instead of turning AFK off.

## Two traps

**Aim the gate at the code under review.** `TEST_DIR` is a single directory. In a
monorepo, a gate pointed at package A approves an issue that only touched
package B, because A's lint and tests pass either way. Point `TEST_DIR` at the
repo root and give the root `lint` and `test` scripts that fan out to every
package. The gate exists so approval does not rest on the agent's own claim, so
a gate blind to the diff is worse than no gate: it reports a pass it never
checked.

**Worktrees come from the base branch.** `ralph process-issue` cuts `../wt-<n>`
from `BASE_BRANCH`, so everything the gate calls - an npm script, an eslint
ignore, a Makefile target - must be committed and pushed there first. A gate
command that exists only on your feature branch dies with `Missing script`.

## Diagnose a stop

`ralph status` names the outcome and `.ralph/logs/metrics.csv` carries the reason
column. Read [`reference/stops.md`](reference/stops.md) for the outcome
vocabulary and the fix for each one.

## Change ralph

Ralph is bash with no dependencies. Work in a checkout of
`spasoye-json/ralph`, not in a consumer's `node_modules`.

1. Read the code you are changing. `lib.sh` holds the config layering, the
   helpers and the review loop; `process-issue.sh` is one issue end to end;
   `run.sh` is the loop and the stranded-PR sweeps; `bin/ralph` is the dispatcher.
2. Make the change. Keep the seam: anything toolchain-shaped is a command string
   or a directory list in config, so ralph stays language agnostic.
3. Run `ralph eval`. It pins the guard logic offline and free.
4. Give new guard, parse or classifier logic a fixture in `eval/`, so the next
   change cannot break it silently.
5. Verify from a real consumer repo: `ralph config` resolves as expected and
   `ralph run --dry` reads the queue.
6. Push to `main`. A consumer takes the change with `npm update ralph-afk`, or
   `npm install -g github:spasoye-json/ralph` for a global install. A global
   install lands in the active node version, so reinstall it after switching.

The change is done when eval is green, every new guard has a fixture, and one
consumer has run against it.

Consumers are the repos holding a `.ralph/` directory:
`find ~ -maxdepth 5 -type d -name .ralph`.

## Update this skill

This skill lives in `skills/ralph/` in the ralph repo, so it versions with the
code and reaches consumers through the same `npm update`.

Update it in the same change that alters behaviour. Check every command, path,
file name and outcome named here and in `reference/stops.md` against the
installed ralph; a name that no longer resolves is the failure mode. When the
README grows the answer, delete it here and point at the README instead.
