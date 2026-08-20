# Ralph

Ralph is an AFK agent loop for GitHub issues. It is a small set of bash
scripts, no server and no framework, that drains a queue of hand-triaged
issues by running Claude Code (`claude -p`) in separate single-purpose
sessions per stage: implement, objectively gate, open a draft PR, verify,
review, converge. You come back to approved PRs waiting for your merge.
Ralph never merges.

It automates the back half of Matt Pocock's agent workflow. The front half
stays manual and human: you write and triage the tickets (the author uses a
`/grill-with-docs`, `/to-spec`, `/to-tickets` skill chain for that, but any
process that produces well-scoped issues works), and only issues you have
labeled `ready-for-agent` by hand are ever picked up. Ralph polls while work
is in flight and exits once the queue is empty and nothing is mid-review.

A TypeScript sibling built on `@ai-hero/sandcastle` lives at
[spasoye-json/sandcastle-template](https://github.com/spasoye-json/sandcastle-template);
Ralph is the dependency-free bash equivalent.

## The loop at a glance

```
you: triage an issue, label it ready-for-agent
                    |
                    v
   run.sh ── polls the queue, one process-issue.sh per issue
     1. /implement writes the change in a Docker-sandboxed worktree
     2. objective lint+test gate (orchestrator-run, retried until green)
     3. a draft PR is opened with a house-style body
     4. an independent read-only verifier judges the diff against the issue
     5. /code-review posts inline threads; a fix agent resolves them; repeat
     6. gate re-runs; on zero unresolved threads the PR is un-drafted
                    |
                    v
you: merge the approved PR (the one deliberate human checkpoint)
```

Each stage is a fresh `claude -p` process, so the reviewer never inherits the
implementer's context and stays unbiased. The verdict is objective where it
can be: the lint+test gate is run by the orchestrator, not claimed by the
agent, and review approval is the count of unresolved GitHub review threads
reaching zero, not a parsed keyword.

## What it does, per issue

1. `/implement` implements the issue in its own worktree and context (no turn
   cap; it runs to completion). The skill itself works test-first via `/tdd`
   and self-reviews with `/code-review` before finishing.
2. The orchestrator runs an **objective lint+test gate** (`RALPH_TEST_GATE`),
   independent of the agent's "tests pass" claim and mirroring the required CI
   check, in the worktree **before opening the PR**. In **AFK mode** (default,
   `RALPH_AFK=1`) a red gate is **not** a handback: the implementer is re-run
   with the exact lint and test output fed back, looping **until the gate is
   green** (see [AFK: retry until green](#afk-retry-until-green)). It runs your
   `SETUP_CMD` in `TEST_DIR` when the dependencies are missing, so the first
   gate per worktree can be slow. A **secret scan** (`RALPH_SECRET_SCAN`) over the diff
   is the one quality-independent **hard stop**: a leaked key still goes to a
   human.
3. An agent opens a **draft** PR up front, authoring a Conventional-Commit
   title and a body in the repo's house style (`## What / Changes / Acceptance
   criteria / Testing`, ending in `Closes #N`). It stays draft until approved.
4. `/code-review` reviews the **open PR** in a **fresh session** (fixed point
   `origin/<base>`, spec = the issue) and posts each finding as an **inline
   review thread**, resolving the ones it judges genuinely fixed. The verdict
   is the count of **unresolved review threads** (`ralph/threads.sh`): 0 means
   approved.
5. While threads remain unresolved, a **new agent** (fresh session) reads
   them, resolves them, and pushes. Between PR-open and review, an independent
   read-only **correctness verifier** judges the diff against the issue's
   acceptance criteria and edge cases; in AFK mode a fail re-runs the
   implementer until it passes (never a handback).
6. Steps 4 and 5 repeat until zero unresolved threads. Approval requires the
   reviewer process to **exit cleanly *and* report zero unresolved threads**;
   a crashed or timed-out reviewer never counts as an approval. Even with
   every thread resolved, the **objective lint+test gate runs again before
   approval**, so a clean review can't approve a red worktree. In AFK mode a
   pass that doesn't approve is not a handback: a red gate rebuilds, anything
   else re-reviews, looping until it converges (`MAX_REVIEW_CYCLES` is the
   per-pass budget, not a give-up point).
7. On approval, the PR is un-drafted (`gh pr ready`) and **left for you to
   merge**. Ralph never merges and never enables auto-merge: the merge is the
   one deliberate human checkpoint at the end of the loop, and branch
   protection's required CI check still keeps a red PR from landing. Success
   is judged from the PR **state** (open and no longer draft), not `gh`'s exit
   code. When you merge, the head branch is deleted by the repo's
   **delete-branch-on-merge** setting (so enable it); the local branch and
   worktree are removed in `cleanup()`.

## AFK: retry until green

Ralph is **away-from-keyboard by default** (`RALPH_AFK=1`): a failing attempt
is never handed back as work for you. The implementer is re-run, with the
exact failure fed back as context, until the objective gate is green; the
correctness verifier and the review loop re-loop the same way. The only exits
that still reach a human are **safety and systemic stops** that retrying
cannot clear:

- **Leaked secret** in the diff (safety: merging one is unrecoverable).
- **Repeated `/implement` crash** with no commits (`RALPH_INFRA_RETRIES`,
  default 3), meaning a broken sandbox, skill, or auth. Surfaced as
  `implement-error` and caught by the infra circuit breaker.
- **Explicit escalation**: the implementer may decline an issue that is too
  underspecified or contradictory to implement responsibly by writing the
  `.ralph-needs-human` sentinel (first line = the blocker) instead of forcing
  a bad PR. Surfaced as `escalated` and labeled `ready-for-human` — a clean
  escalation beats a confident wrong answer.
- **Unresolvable rebase conflict** or unfixable post-rebase review, in the
  rare maintenance path (`resolve-conflicts.sh`). It runs inside the sweep and
  can't block forever, so it bounds its retries then hands back.

`RALPH_MAX_ATTEMPTS` (default `8`; `0` = unlimited) is a brake on attempts per
issue. It counts implementer attempts, review rounds, and failed
correctness-verifier rounds, so the cap bounds the verifier loop too; on hit,
the issue is **re-queued** (`ready-for-agent`), not handed to a human. Set
`RALPH_AFK=0` to restore the legacy hand-back-on-first-failure behavior.
**Caveat:** with `RALPH_CONCURRENCY=1` and the brakes set to `0` (unlimited),
"retry until green" on a genuinely-impossible ticket grinds that issue and
blocks the queue behind it. The default cap avoids that.

`RALPH_ISSUE_BUDGET` (default `7200`; `0` = off) is a second, wall-clock brake
for the same grind: an issue that is still looping after the budget (seconds)
is **re-queued** with a `budget-exceeded` metric row. This matters for the
circuit breaker: an endlessly-grinding issue never records an outcome, so
without a budget the breaker cannot see it burning tokens. With a budget set,
each grind terminates, records a fail outcome, and consecutive grinds trip
`RALPH_MAX_HANDBACKS` as intended.

## Install

Ralph installs as a package. Nothing is copied into your repo except one config
file, so taking a new version is `npm update`, not a re-copy and a manual diff.
It is **language and framework agnostic** — it drives GitHub, git and claude,
and shells out to your toolchain through command strings in `.ralph/config.sh`.
Node, Go, Rust, Python, Ruby, JVM and mixed monorepos all work; the starter
config carries a copy-paste recipe for each.

1. Install it. Per repo, so the version is pinned in your lockfile along with
   everything else:

   ```bash
   npm install --save-dev github:spasoye-json/ralph
   ```

   Or once for every repo on the machine:

   ```bash
   npm install --global github:spasoye-json/ralph
   ```

   A local install puts `ralph` on PATH inside npm scripts and under `npx`; a
   global install puts it on your shell PATH. Take a later version with
   `npm update ralph-afk`.
2. `npx ralph init` — writes `.ralph/config.sh`, `.ralph/.env` and
   `.ralph/.gitignore` in the repo root. Commit `config.sh`. The other two stay
   out of git.
3. Edit `.ralph/config.sh`: base branch, `TEST_DIR`, your toolchain commands
   (`SETUP_CMD`, `LINT_CMD`, `TEST_CMD`, `AUDIT_CMD`), the dependency caches the
   sandbox mounts (`RALPH_DEP_DIRS`, `RALPH_CACHE_MOUNTS`) and
   `RALPH_SANDBOX_BASE`. Start from the recipe for your stack in that file.
   Write only what differs from the defaults — `npx ralph config` prints every
   resolved value and where it came from.
4. Put `CLAUDE_CODE_OAUTH_TOKEN` in `.ralph/.env` (`claude setup-token`). Only
   the sandboxed implementer uses it; the host stages use your logged-in
   `~/.claude`.
5. Create the labels:
   `for l in ready-for-agent claude-working ready-for-human; do gh label create "$l"; done`
6. `npx ralph sandbox-build` — builds the writer sandbox from
   `RALPH_SANDBOX_BASE`. The `EXTRA_PACKAGES` and `SETUP_SNIPPET` build args add
   anything else your gate needs.
7. Install the skills:
   `claude plugin install mattpocock-skills@claude-plugins-official`, then
   `npx ralph link-skills`. It links `/implement`, `/tdd` and `/code-review`
   from the plugin into `~/.claude/skills/` so they resolve on the host and
   inside the sandbox. Re-run it after a plugin update.
8. Protect the base branch: require your lint+test check, and turn on
   delete-branch-on-merge for the repo.
9. `npx ralph doctor` checks everything else — `claude`, `gh` authenticated,
   `docker` running, `jq`, `flock`, the three skills. Then `npx ralph eval`
   (offline and free) and `npx ralph status`.

### Install vs. state

`ralph home` is the **install**: these scripts, the sandbox Dockerfile, the eval
cases, the packaged config defaults. Ralph never writes there, so `npm update`
can replace it wholesale.

`.ralph/` in the repo you run from is the **state**: `config.sh` (committed),
plus `.env` and `logs/` with the metrics (both gitignored). One install
therefore drives every repo on the machine, and reinstalling ralph can never
wipe a project's throughput history. Set `RALPH_STATE` to put it elsewhere.

> **GNU/Linux only.** The scripts rely on GNU `grep -P`, gawk `IGNORECASE`,
> GNU `date -d`, and `flock`. On macOS `parse_blockers` and `pr_fields`
> silently break.

## Run

```bash
DRY_RUN=1 ralph run   # list what it would pick up right now, then exit
ralph run             # continuous loop; runs until you Ctrl-C or kill it
```

`run.sh` takes a `flock` lock, so a second concurrent instance exits rather
than racing the label-claim. The lock is per-clone (it lives in the clone's
log dir), so two ralph instances in separate clones of the same repo are not
mutually excluded and will race the label claim. Run one instance per repo.
Each cycle it refreshes the base branch (never switching the branch you have
checked out: when you are parked on another branch the base ref is
fast-forwarded in place via a fetch refspec), processes every eligible issue,
then **polls adaptively**: fast (`POLL_MIN`, default 2 min) while the queue
has work, backing off geometrically (`POLL_BACKOFF`) toward the idle ceiling
`POLL_INTERVAL` (default 30 min) while only waiting on stranded reviews to
converge, picking up tickets added or unblocked since the last cycle. It
**exits** once nothing is eligible and nothing is mid-review. Approved PRs do
not block exit: they wait for your merge, which can happen long after the loop
is gone; a merge that lands unblocks its dependents, which the next run (or a
still-running loop with queued work) picks up.

Eligible issues are worked in **ascending issue-number order**: the safe
filters (label, not blocked, no open PR) decide the candidate set, and the
lowest number goes first. `DRY_RUN=1 ralph run` prints the issues it
would pick up.

Each **agent stage runs on a fixed model** (see Tunables): the writing stages
(`/implement`, fixes, conflict resolution, PR authoring) run on Claude Opus 5,
and the judging stages (review, verification) run on Claude Fable 5.

Issues can be implemented **concurrently** (`RALPH_CONCURRENCY`, default 1 =
sequential), each in its own worktree, with git ref and worktree setup
serialized by a `flock`. Concurrency is gated by your Claude API rate and
token limits, **not CPU**; raise it with care.

Each finished issue appends a **metrics row** (`METRICS_FILE`:
`timestamp,issue,outcome,cycles,duration,reason`; the outcome vocabulary is
the `RALPH_OUTCOMES` array in `lib.sh`); run **`ralph/status.sh`** for a
live snapshot: queue label counts, open `issue/*` PRs, throughput (approval
rate, avg cycles, avg duration), and a **review-convergence** trend (older vs
recent approvals, i.e. is the loop needing fewer review rounds over time?).

A **circuit breaker** stops the loop if a systemic problem starts burning
budget. Two thresholds, both reset by an approval: `RALPH_MAX_INFRA_ERRORS`
(default 2; 0 disables) trips fast on consecutive **infra errors**, meaning a
`/implement` that crashed before any commit (`implement-error`), e.g. a broken
sandbox, skill, or auth; and `RALPH_MAX_HANDBACKS` (default 6; 0 disables)
trips on any consecutive handbacks.

At the **start of each cycle** a reaper re-queues orphans: an issue still in
`claude-working` with no open PR (a crash between claiming and opening a PR)
is moved back to `ready-for-agent`. It also **resumes issues stranded
mid-review** by a crash: an issue still `claude-working` with an open *draft*
PR that isn't a handback is re-entered into the review loop via
`resolve-conflicts.sh`.

Also at the **start of each cycle** it runs a maintenance sweep over its own
open PRs (head `issue/*`): a PR that has gone **CONFLICTING** with the base
branch is rebased and re-reviewed (`resolve-conflicts.sh`). Because a PR is
un-drafted only on approval, a **non-draft** `issue/*` PR reliably means
*approved*. Approved and green PRs are left alone, waiting for your merge. An
approved, mergeable PR whose required CI check is **failing** would sit
unmergeable on your desk, so it is handed back explicitly: re-drafted, title
prefixed, issue relabeled. Issues that already have an open PR are **never
re-picked** for fresh work.

> Issues are processed up to `RALPH_CONCURRENCY` at a time (default 1 =
> sequential), each branched from the latest `origin/<base>`. Several eligible
> issues in one cycle still produce several PRs based on the *same* base; the
> conflict sweep rebases and re-reviews whichever you don't merge first. For
> tightly-coupled work prefer `Blocked-by:` lines or concurrency 1 to limit
> rebase churn (the conflict sweep handles the rest).

### Writer sandbox (host safety, on by default)

The three stages that write and run un-reviewed generated code — the
`/implement` implementer, the review-fix stage, and the conflict resolver — each
run inside a throwaway Docker container (`RALPH_SANDBOX=1`, default). It sees **only** the worktree, the shared git dir, the global skills
(read-only) and the dependency caches (read-only). Inside the shared git dir,
`.git/config` and `.git/hooks` are shadow-mounted read-only, so the agent
cannot plant hooks or config that would later execute on the host. The host
`$HOME` (ssh, aws, and claude credentials) is never mounted, capabilities are
dropped, and the container is removed on exit. The box has no `gh` and no
GitHub token: the issue text is injected into the prompt and all git and PR
work happens on the host. Network stays on (claude must reach the API), so
this stops host damage and credential theft, not network exfiltration.

One-time build, then drop the token the sandboxed claude authenticates with
into the gitignored `.ralph/.env` that `ralph init` wrote (auto-loaded by ralph):

```bash
ralph sandbox-build          # builds from RALPH_SANDBOX_BASE; re-run after a Dockerfile change
$EDITOR .ralph/.env          # set CLAUDE_CODE_OAUTH_TOKEN (or ANTHROPIC_API_KEY)
```

The token is only needed for the sandboxed writers; the host stages
(reviewer, PR author, verifier) use your logged-in `~/.claude`. A plain
`export CLAUDE_CODE_OAUTH_TOKEN=...` in your shell works too.

`process-issue.sh` and `resolve-conflicts.sh` run a **preflight** before
claiming any work: if docker,
the `ralph-impl` image, or the token is missing it aborts loudly rather than
silently running the agent on the host. Set `RALPH_SANDBOX=0` to opt out; flip
`RALPH_DEP_MOUNT_MODE=rw` if a test runner insists on writing into a mounted
dependency cache. Only the writers are sandboxed: the reviewer is already
read-only, and the PR-author and verifier need `gh` on the host.

## Labels (Matt Pocock vocabulary)

- `ready-for-agent` is the queue. Issues with this label get picked up. You
  apply it by hand, after triaging the issue yourself; Ralph runs no triage of
  its own.
- `ready-for-human` is the handback. If review can't be satisfied in
  `MAX_REVIEW_CYCLES`, or `/implement` produces nothing, the issue is moved
  here.
- `claude-working` is a transient marker so a run never double-picks an issue.

Blocked issues are skipped: put `Blocked-by: #131, #138` in an issue body and
it won't be picked up until all referenced issues are closed (their PRs
merged). Re-checked live each cycle, so a dependent is picked up on the next
cycle after you merge its blocker.

## Files

```
<host repo>/.github/workflows/…   your required CI gate (lint + test), referenced
                            by the base branch's protection rule
<host repo>/.claude/settings.json allowlist; lib.sh reads it and passes it to each
                            claude -p via --allowedTools (project settings are
                            ignored inside the untrusted per-issue worktrees)
<host repo>/.ralph/config.sh      ← the config seam: labels, base branch, gate dir
                            and toolchain commands, sandbox base image,
                            dep-cache mounts. Committed.
<host repo>/.ralph/.env           CLAUDE_CODE_OAUTH_TOKEN for the sandboxed
                            implementer. Gitignored.
<host repo>/.ralph/logs/          metrics.csv, per-run logs, the run lock.
                            Gitignored.

--- the install (`ralph home`), never written to ---
bin/ralph                   ← the one entry point: run, status, config, init,
                            doctor, sandbox-build, link-skills, eval
config.sh                   packaged DEFAULTS for every knob. Do not edit —
                            .ralph/config.sh overrides it and survives updates
templates/config.sh         the .ralph/config.sh starter `ralph init` copies,
                            with a recipe per language
link-skills.sh              link /implement, /tdd, /code-review from the
                            mattpocock-skills plugin, and ralph's own skill from
                            this install, into ~/.claude/skills
skills/ralph/               the /ralph skill: operating the loop, reading a stop
                            outcome, and changing ralph itself
run.sh                      ← the continuous loop you start and Ctrl-C to stop
process-issue.sh            one issue, end to end (implement → PR → review)
resolve-conflicts.sh        rebase a PR onto the base, resolve, re-review
threads.sh                  count unresolved review threads (the verdict)
status.sh                   live snapshot: queue, open PRs, throughput
eval.sh                     offline regression gate for the learning/guard logic
eval-agents.sh              OPT-IN agent-output quality harness (real /implement, no GitHub writes)
eval/                       fixtures: secret cases, agent-cases/
lib.sh                      config + helpers + review_and_resolve (sourced)
sandbox/Dockerfile          the writer sandbox, BASE_IMAGE picks the toolchain
```

The `/implement`, `/tdd`, and `/code-review` skills come from the
mattpocock-skills plugin. `ralph link-skills` links them into
`~/.claude/skills/` and never edits them; the sandbox mounts the link targets
read-only.

### Permissions (per role)

The reviewer runs with a deliberately **read-only** allowlist, with no `Edit`
or `Write`, no push, no merge: it only reads the diff and resolves or posts
review threads (plus `Task`, so `/code-review` can fan its two axes out as
sub-agents that inherit the same read-only allowlist). The **PR-author** runs
with its own tight allowlist (read plus `gh pr create` plus one body-file
write), since it never edits source. The implementer and conflict-resolver
agents use the broad project allowlist but are **denied `gh pr merge`** (via
`--disallowedTools`), so they cannot self-merge and bypass the review gate.

Every stage also runs with **ambient MCP servers trimmed off**
(`RALPH_TRIM_MCP`, default on): no Ralph stage needs a globally-registered MCP
server (Figma, Slack, Notion, GCP, …), so each `claude -p` runs under
`--strict-mcp-config` with an empty `--mcp-config`, keeping unused tool
definitions out of context. The CLI flag is probed once at startup and
**degrades gracefully** (normal run) if it's absent.

## Tunables (env vars, override before running)

```bash
# polling & concurrency
POLL_INTERVAL=900   ralph run     # idle poll ceiling, 15 min (default 1800 = 30 min)
POLL_MIN=60         ralph run     # fast poll floor while busy (default 120 = 2 min)
POLL_BACKOFF=3      ralph run     # idle backoff multiplier toward the ceiling (default 2)
RALPH_CONCURRENCY=2 ralph run     # issues implemented in parallel (default 1 = sequential)

# review cycles, timeout, base (approved PRs are un-drafted and wait for your merge)
MAX_REVIEW_CYCLES=8 ralph run     # review<->resolve rounds (default 5)
AGENT_TIMEOUT=7200  ralph run     # allow 2h per agent (default 3600 = 1h)
BASE_BRANCH=develop ralph run     # default main (set in config.sh)

# per-stage models (CLI --model alias or full ID; empty = your CLI default)
MODEL_IMPLEMENT=claude-opus-5 ralph run # implementation (default claude-opus-5)
MODEL_REVIEW=claude-fable-5 ralph run  # quality review (default claude-fable-5)
MODEL_FIX=claude-opus-5    ralph run   # apply review fixes (default claude-opus-5)
MODEL_CONFLICT=claude-opus-5 ralph run # resolve rebase conflicts (default claude-opus-5)
MODEL_PR=claude-opus-5     ralph run   # author the PR title and body (default claude-opus-5)

# gates
RALPH_TEST_GATE=0   ralph run     # disable the objective lint+test gate (default 1)
TEST_DIR=packages/app ralph run   # package dir the gate runs in (default . as set in config.sh)
LINT_CMD="go vet ./..." ralph run # lint command for the gate (empty = skipped)
TEST_CMD="go test ./..." ralph run # test command for the gate (empty = skipped)
SETUP_CMD="go mod download" ralph run # dependency install before the gate (empty = skipped)
RALPH_SECRET_SCAN=0 ralph run     # disable the pre-merge secret scan (default 1)
RALPH_AUDIT=1       ralph run     # run the advisory AUDIT_CMD from config.sh (default 0; never blocks)

# MCP trimming
RALPH_TRIM_MCP=0    ralph run     # keep ambient MCP servers loaded per stage (default 1 = trim them off)

# metrics
METRICS_FILE=logs/metrics.csv ralph run # per-issue outcome log, gitignored (default logs/metrics.csv)

# AFK / retry-until-green
RALPH_AFK=0           ralph run     # 0 = legacy hand-back-on-failure; 1 = retry until green (default)
RALPH_MAX_ATTEMPTS=0  ralph run     # cap attempts per issue: implementer + review + failed verifier rounds (default 8; 0 = unlimited)
RALPH_INFRA_RETRIES=5 ralph run     # consecutive /implement crashes tolerated before declaring an infra error (default 3)
RALPH_ISSUE_BUDGET=14400 ralph run  # per-issue wall-clock budget in seconds (default 7200; 0 = off); on hit the issue is re-queued, not handed back

# circuit breaker
RALPH_MAX_HANDBACKS=10 ralph run    # stop after N consecutive handbacks (default 6; 0 = disabled)
RALPH_MAX_INFRA_ERRORS=3 ralph run  # stop after N consecutive infra errors (default 2; 0 = disabled)
```

## Regression gate

`ralph eval` is an offline harness (no agents, no network) that pins the
deterministic guard logic, meaning the capability boundary, the
correctness-verdict parse, the escalation sentinel, and the secret scan,
against labeled fixtures (`ralph/eval/`). A small eval harness is the
highest-leverage thing you can build here: *without it you're optimizing by
vibes.* Run it before and after touching any guard or prompt logic; it exits
non-zero on any failure, so it works as a pre-push or CI check.

`ralph eval` pins the *bash*; `ralph eval-agents` measures the
*agent*. It is **opt-in** (real tokens) and runs the real `/implement` against
a frozen fixture suite (`ralph/eval/agent-cases/`, ~14 cases spanning utils,
an array and string mix, a bugfix-with-regression-test, a component-style
display helper, an `expect-gate: escalate` underspecified case, and an
`expect-gate: fail` contradictory case). Each fixture runs in a throwaway
worktree, with `/implement` inside the **same Docker sandbox as production**;
the shared stage runner applies the sandbox by role, so eval exercises the
implementer exactly as the live loop does (set `EVAL_SANDBOX=0` to skip it for
speed). It then runs the objective gate, classifies the outcome (`pass`,
`fail`, or `escalate`; the escalation sentinel is honoured here too), and
scores the diff 0 to 100 with a read-only rubric agent. It **never writes to
GitHub** (no push, PR, or issue edits) and exits non-zero if any fixture's
outcome misses its `expect-gate`, so it doubles as a manual quality gate.

```bash
ralph eval-agents --list          # parse + list fixtures, run nothing (free)
ralph eval-agents round-to        # run one named fixture (cheap)
ralph eval-agents                 # run the whole suite once
```

This is the **standing regression baseline** for prompt and model changes: run
it before and after a change, track the scorecard, and **retire anything that
doesn't move it**, keeping the loop simple (add complexity only when the
improvement is demonstrable). It is deliberately **not** wired into the
always-run offline `eval.sh` or CI, because it spends real tokens.

## Before the first unattended run

- The `claude -p` flags (`--permission-mode acceptEdits`,
  `--append-system-prompt`, `--allowedTools`, `--disallowedTools`) and the
  `timeout` wrapper match your installed Claude CLI (`claude --help`). They
  live in `process-issue.sh`, `resolve-conflicts.sh`, and `lib.sh`.
- Your account can run the default model IDs (`claude-opus-5`,
  `claude-fable-5`); otherwise set the `MODEL_*` vars to other IDs or empty
  (CLI default).
- MCP trimming uses `--strict-mcp-config --mcp-config <empty>`. Ralph probes
  for `--strict-mcp-config` once at startup and **degrades gracefully**
  (normal run) if it's absent. Set `RALPH_TRIM_MCP=0` to keep ambient MCP
  servers loaded.
- `TEST_DIR` and the toolchain commands match your repo, and you accept the
  `SETUP_CMD` cost of the local gate (run once per worktree when the
  dependencies are missing). Leaving both `LINT_CMD` and `TEST_CMD` empty makes
  the gate a no-op, and Ralph logs a warning every cycle saying so.
- The verdict is the count of **unresolved review threads** on the PR,
  computed by `ralph/threads.sh`; there is no parsed keyword. The reviewer is
  expected to post each finding as an inline review thread and resolve the
  ones it fixes.
- The merge is **yours**: Ralph never merges and never enables auto-merge. An
  approved PR is un-drafted and waits for you; the base branch's required
  lint+test CI check (the check name is yours to define in branch protection)
  still keeps a red PR from landing when you merge. Enable the repo's
  **"Automatically delete head branches"** setting (`delete_branch_on_merge`)
  so merged head branches are cleaned up after your merge; the local branch
  and worktree are removed in `cleanup()`.

## Security and threat model

The tool allowlist is **not** a security sandbox; treat it as a convenience
filter, not a boundary. Any allowlist broad enough to let an agent build and
test your project also permits arbitrary code execution and network egress,
which defeats a `curl` or `wget` deny entry, and a broad `gh` entry is full
GitHub API access via your auth token. The allowlist is optional: with no
`.claude/settings.json` the writer roles run under `bypassPermissions`, and the
sandbox is the boundary that actually holds. The per-issue input is attacker-influenceable: issue bodies are fed to
`/implement`, so a crafted issue can prompt-inject the implementer.

As a prompt-level mitigation, every agent stage is given a fixed **capability
boundary** in its system prompt (`INJECTION_GUARD`): treat issue bodies, PR
diffs, review-thread text and command output as untrusted *data*, never
instructions, and never skip a gate, exfiltrate data, or run destructive
commands regardless of what that content says. Inlined untrusted content (the
issue queue, review findings, the diff under review) is labelled as untrusted
data where it appears. This is defence-in-depth alongside the allowlist, not a
sandbox.

As an accidental-mistake guard (not an adversarial one), the **pre-merge
secret scan** (`RALPH_SECRET_SCAN`, default on) blocks a PR whose diff
contains a high-confidence secret (AWS, GitHub, Slack, or Google keys,
private-key blocks, or an obvious `secret = "<long opaque value>"` assignment)
tuned for precision, so it catches a committed key without crying wolf on
every PR.

Every writer runs inside **OS-level isolation** by default; see
[Writer sandbox](#writer-sandbox-host-safety-on-by-default). That
contains host damage and credential theft, but the container keeps network
access, so it is **not** a defence against an agent exfiltrating the repo (the
worktree it can already read) to an arbitrary host. For that, restrict egress
to the Anthropic API, and still don't rely on the allowlist: use a
**least-privilege, repo-scoped token** for the host-side `gh` work, and enable
**branch protection** on the base branch requiring the CI check, so the merge
gate holds even if an agent misbehaves. Since every merge is performed by a
human, you can also require an approving review without breaking the flow:
Ralph never submits a GitHub review approval (its approval is a comment marker
plus zero unresolved threads), so the approving review is simply part of your
merge step. The implementer and conflict agents are denied `gh pr merge`, and
Ralph itself never calls it, so nothing lands without you.
