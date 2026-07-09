#!/usr/bin/env bash
# ralph/process-issue.sh — implement ONE issue, PR-first, matching the workflow:
#
#   1. /implement implements the issue (own context)
#   2. push + open the PR up front as a DRAFT
#   3. /code-review reviews the DRAFT PR in a FRESH session, resolving
#      addressed threads and posting NEW findings as inline review threads
#   4. a NEW agent (fresh session) reads the open threads and fixes them,
#      pushing to the branch (it never resolves threads — the reviewer does)
#   5. repeat 3-4 until the unresolved-thread count hits 0 (the verdict is the
#      count, NOT a parsed APPROVED/CHANGES keyword), or give up after MAX_REVIEW_CYCLES
#   6. approved -> un-draft the PR and leave it for run.sh's CI-gated auto-merge
#
# Each review and each resolve is a separate `claude -p` process, so neither
# inherits the other's context — the reviewer stays unbiased by construction.
# The /implement and /code-review skills live globally in ~/.claude/skills and
# are left untouched.
#
# Usage:  ralph/process-issue.sh <issue-number>
# Run from the repo root; gh + claude must be on PATH.

source "$(dirname "$0")/lib.sh"

n="${1:?usage: process-issue.sh <issue-number>}"
branch="issue/$n"
wt="$WORKTREE_ROOT/wt-$n"
mkdir -p "$LOG_DIR"
ilog="$LOG_DIR/issue-$n.log"
START_TS="$(date +%s)"
elapsed() { echo $(( $(date +%s) - START_TS )); }

# Verify the implementer sandbox is usable before claiming work, so a misconfigured
# sandbox aborts cleanly instead of churning labels or (worse) silently running the
# agent on the host. Opt out with RALPH_SANDBOX=0.
if [ "${RALPH_SANDBOX:-0}" = "1" ]; then
  sandbox_preflight || { log "#$n: implementer sandbox unavailable — aborting (set RALPH_SANDBOX=0 to run on host)"; exit 1; }
fi

# Claim the issue so a second invocation never double-picks it. Issues reach the
# queue already triaged by hand, so there is no pre-flight readiness gate here.
gh issue edit "$n" --add-label "$WORKING_LABEL" --remove-label "$READY_LABEL" >/dev/null

OLDPWD_ROOT="$PWD"
cleanup() {
  cd "$OLDPWD_ROOT" 2>/dev/null || true
  git worktree remove --force "$wt" 2>/dev/null || true
  # Once the worktree is gone the branch is no longer checked out and is always
  # recreatable from origin, so drop the local branch — otherwise every processed
  # issue leaves an issue/* branch behind and they pile up indefinitely.
  git branch -D "$branch" 2>/dev/null || true
}
trap cleanup EXIT

# Serialize ref/worktree setup so parallel issues (RALPH_CONCURRENCY>1) don't race
# git's ref/worktree locks. The long agent work below runs unlocked, in parallel.
exec 7>"$LOG_DIR/.worktree.lock"; flock 7

# Defensive: an interrupted prior run can leave a stale worktree dir/branch that
# makes 'git worktree add -b' fail. Clear them, unless an open PR needs the branch.
git worktree prune
if [ -e "$wt" ]; then
  git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
fi
if git show-ref --quiet "refs/heads/$branch"; then
  if [ -n "$(gh pr list --head "$branch" --state open --json number -q '.[].number' 2>/dev/null)" ]; then
    log "#$n: $branch already has an open PR — skipping to avoid clobbering it"
    gh issue edit "$n" --remove-label "$WORKING_LABEL" --add-label "$HUMAN_LABEL" >/dev/null
    exit 1
  fi
  git branch -D "$branch" >/dev/null 2>&1 || true
fi

# Refresh the base from origin so the worktree branches from the latest master,
# not a stale local ref. Abort rather than silently building on a stale base.
if ! git fetch origin "$BASE_BRANCH" >>"$ilog" 2>&1; then
  log "#$n: 'git fetch origin $BASE_BRANCH' failed — aborting to avoid a stale base"
  gh issue edit "$n" --remove-label "$WORKING_LABEL" --add-label "$HUMAN_LABEL" >/dev/null
  exit 1
fi

log "#$n: creating worktree $wt on $branch (from origin/$BASE_BRANCH)"
git worktree add -b "$branch" "$wt" "origin/$BASE_BRANCH" >>"$ilog" 2>&1
flock -u 7   # ref setup done; release so other parallel issues can set up
cd "$wt"

# --- Maker: one /implement run in its OWN context (one attempt of the build loop)
# run_impl_here [extra-context] — run /implement once in the CURRENT worktree,
# capturing its exit code in IMPL_RC. build_until_green calls this repeatedly
# until green.
run_impl_here() {
  # The tdd role's full policy bag — model, allowlist, IMPL_DISALLOW, acceptEdits,
  # guard AND the docker sandbox + MCP-trim blanking — is resolved inside run_stage
  # (the sandbox shadow stays confined there, so later host stages keep bare claude).
  # cwd is the worktree (we cd'd in above), which run_stage mounts as the container
  # worktree. Keep the exit code: the gate below tells an infra crash from a no-op.
  run_stage tdd "$n" "$ilog" "/implement #$n

Implement GitHub issue #$n. Work only within this worktree.
The full issue is included below — work from it directly; do not call gh or fetch
anything over the network.
Commit incrementally. You are DONE only when all tests pass and lint is clean.
Do not stop early and do not hand back: if the work is hard, keep going until
'$LINT_CMD' and '$TEST_CMD' both pass in $TEST_DIR. This loop will re-run you
with the exact failures until that objective gate is green.

${1:-}" \
    >/dev/null && IMPL_RC=0 || IMPL_RC=$?
}

# --- AFK retry machinery -----------------------------------------------------
# No quality handbacks: the implementer is re-run, with each failure fed back,
# until the objective gate is green. The only stops are safety/systemic ones that
# retrying cannot clear (leaked secret, repeated /implement crash). RALPH_MAX_ATTEMPTS
# (default 0 = unlimited) is an optional brake; RALPH_INFRA_RETRIES bounds crashes.
ATTEMPTS=0; INFRA_STRIKES=0
attempt_cap_hit() { [ "${RALPH_MAX_ATTEMPTS:-0}" -gt 0 ] && [ "$ATTEMPTS" -ge "${RALPH_MAX_ATTEMPTS}" ]; }
budget_exceeded() { [ "${RALPH_ISSUE_BUDGET:-0}" -gt 0 ] && [ "$(elapsed)" -ge "${RALPH_ISSUE_BUDGET}" ]; }
has_commits()     { ! git diff --quiet "origin/$BASE_BRANCH"...HEAD; }

# stop_issue <outcome> <exit-code> <reason> — relabel and record a terminal stop.
# exit 3 is an infra error and exit 5 a safety stop (leaked secret) — both go to a
# human, never back to the queue (run.sh maps 5 to a generic fail for the circuit
# breaker); other codes re-queue the issue (ready-for-agent) so a later run
# retries from a fresh worktree.
stop_issue() {
  local outcome="$1" code="$2" reason="$3" lbl="$READY_LABEL"
  case "$code" in 3|5) lbl="$HUMAN_LABEL" ;; esac
  log "#$n: $reason — ${lbl}"
  gh issue edit "$n" --remove-label "$WORKING_LABEL" --add-label "$lbl" >/dev/null
  record_metric "$n" "$outcome" "" "$(elapsed)" "$reason"
  exit "$code"
}

# build_until_green <feedback> — run the implementer, then loop until the OBJECTIVE
# lint+test gate passes, feeding each failure back. Commits accumulate across
# attempts. Returns 0 (green), 1 (optional attempt cap hit), 3 (repeated crash).
build_until_green() {
  local feedback="$1" gate_tail
  while :; do
    budget_exceeded && return 4
    run_impl_here "$feedback"
    if ! has_commits; then
      if [ "${IMPL_RC:-0}" -ne 0 ]; then
        INFRA_STRIKES=$((INFRA_STRIKES+1))
        log "#$n: /implement crashed (exit $IMPL_RC) with no commits — infra strike $INFRA_STRIKES/${RALPH_INFRA_RETRIES}"
        [ "$INFRA_STRIKES" -ge "${RALPH_INFRA_RETRIES:-3}" ] && return 3
        feedback="The previous run did not complete. Implement issue #$n from scratch in this worktree and commit your work."
        continue
      fi
      ATTEMPTS=$((ATTEMPTS+1)); attempt_cap_hit && return 1
      log "#$n: /implement produced no commits — re-running with a firmer instruction (attempt $ATTEMPTS)"
      feedback="You produced NO commits. You MUST implement issue #$n and commit the code now — write the implementation and its tests, then commit."
      continue
    fi
    INFRA_STRIKES=0
    if run_quality_gate "$ilog"; then return 0; fi
    ATTEMPTS=$((ATTEMPTS+1)); attempt_cap_hit && return 1
    gate_tail="$(tail -n 80 "$ilog" 2>/dev/null || true)"
    log "#$n: lint/tests still red — re-running implementer with the failure output (attempt $ATTEMPTS)"
    feedback="Your previous attempt left lint or tests FAILING in $TEST_DIR. Fix them until '$LINT_CMD' and '$TEST_CMD' both pass. The objective gate output was:

$gate_tail"
  done
}

# --- 1. Build until the objective gate is green ------------------------------
log "#$n: /implement starting — building until lint+tests pass"
# Fetch the issue on the host and inject it, so the sandboxed implementer needs no
# gh and no GitHub token inside the container.
issue_ctx="$(gh issue view "$n" --json title,body \
  -q '"## Issue #'"$n"': " + .title + "\n\n" + (.body // "_(no description)_")' 2>/dev/null || true)"

build_until_green "The issue to implement:

$issue_ctx" && bg=0 || bg=$?
case $bg in
  0) : ;;
  3) stop_issue tdd-error 3 "/implement crashed with no commits ${RALPH_INFRA_RETRIES}x (infra error; see issue-$n.log)" ;;
  4) stop_issue budget-exceeded 1 "wall-clock budget RALPH_ISSUE_BUDGET=${RALPH_ISSUE_BUDGET}s exceeded before lint/tests passed — re-queued" ;;
  *) stop_issue test-fail  1 "attempt cap RALPH_MAX_ATTEMPTS=${RALPH_MAX_ATTEMPTS} reached before lint/tests passed" ;;
esac

# Accidental-secret gate (SAFETY, not quality): never open a PR whose diff leaks a
# high-confidence secret. This is the one quality-independent hard stop that
# retrying cannot safely clear, so it still goes to a human even in AFK mode.
if ! run_safety_scan "$ilog"; then
  stop_issue secret-detected 5 "high-confidence secret in PR diff — safety stop (see issue-$n.log)"
fi

# --- 2. Open the PR up front (agent-authored title + body) -------------------
log "#$n: pushing branch and drafting PR"
git push -u origin "$branch" >>"$ilog" 2>&1

# Let an agent author the PR so it matches the repo's house style instead of a
# canned stub. It reads the issue + the diff and mirrors recent merged PRs. A
# (haiku) PR-author that fails to create a PR is retried; persistent failure is
# an infra error, not a quality handback.
create_pr() {
  run_stage pr "$n" "$ilog" "Open a GitHub pull request for the commits on branch '$branch' (implements issue #$n).

- Read the issue: gh issue view $n
- Inspect the change: 'git log origin/$BASE_BRANCH..HEAD' and 'git diff origin/$BASE_BRANCH...HEAD'
- Match THIS repo's merged-PR style — skim 'gh pr list --state merged --limit 5' then 'gh pr view <num>' on a couple. They use a Conventional-Commit title (e.g. 'feat(scope): ...') and a body with sections: ## What, ## Changes (or ## Approach), ## Acceptance criteria (checkboxes from the issue), ## Testing.

Create it with: gh pr create --draft --base $BASE_BRANCH --head $branch --title \"<conventional-commit title, NOT 'Issue #$n'>\" --body-file <file>
The body MUST end with a line 'Closes #$n'." \
    >/dev/null || true   # the PR-URL lookup decides success
  pr_url="$(gh pr view "$branch" --json url -q .url 2>/dev/null || true)"
  [ -n "$pr_url" ]
}
pr_tries=0
until create_pr; do
  pr_tries=$((pr_tries+1))
  [ "$pr_tries" -ge "${RALPH_INFRA_RETRIES:-3}" ] && \
    stop_issue pr-failed 3 "PR-author created no PR on $branch after ${pr_tries} tries (infra error)"
  log "#$n: PR not created — retrying PR author (try $pr_tries)"
done
log "#$n: PR $pr_url"

# Backstop the agent-authored body: the blocker gate (lib.sh) only releases a
# dependent issue when a MERGED PR auto-closes its blocker, which needs a
# 'Closes #n' trailer. The PR-author is told to add it, but nothing guarantees a
# (haiku) agent did — append it deterministically if absent. Without this a
# forgotten trailer silently deadlocks every dependent (the same fail-open
# coupling class as the blocker-format bug).
pr_body="$(gh pr view "$pr_url" --json body -q .body 2>/dev/null || true)"
if ! body_closes_issue "$pr_body" "$n"; then
  log "#$n: PR body missing a 'Closes #$n' trailer — appending it"
  gh pr edit "$pr_url" --body "$(printf '%s\n\nCloses #%s' "$pr_body" "$n")" >>"$ilog" 2>&1 \
    || log "#$n: could not append Closes trailer (gh pr edit failed)"
fi

# rebuild_or_stop <feedback> <cap-outcome> — re-run build_until_green (the verifier
# or reviewer asked for more implementation work) and route its terminal codes.
# Returns to the caller only on success (gate green), having pushed the new commits.
rebuild_or_stop() {
  local fb="$1" cap_outcome="$2" rc
  build_until_green "$fb" && rc=0 || rc=$?
  case $rc in
    0) git push origin "$branch" >>"$ilog" 2>&1 || true ;;
    3) stop_issue tdd-error 3 "/implement crashed during a fix loop ${RALPH_INFRA_RETRIES}x (infra error)" ;;
    4) stop_issue budget-exceeded 1 "wall-clock budget RALPH_ISSUE_BUDGET=${RALPH_ISSUE_BUDGET}s exceeded during a fix loop — re-queued" ;;
    *) stop_issue "$cap_outcome" 1 "attempt cap RALPH_MAX_ATTEMPTS=${RALPH_MAX_ATTEMPTS} reached during a fix loop" ;;
  esac
}

# --- 3. Correctness gate: retry until the change actually solves the ticket --
# A fresh, independent, read-only verifier judges the diff against the issue's
# acceptance criteria + edge cases. In AFK mode a fail re-runs the implementer
# (which keeps the gate green) until the verifier passes — never a handback.
while ! verify_issue "$pr_url" "$n" "$ilog"; do
  budget_exceeded && stop_issue budget-exceeded 1 "wall-clock budget RALPH_ISSUE_BUDGET=${RALPH_ISSUE_BUDGET}s exceeded before the correctness gate passed — re-queued"
  # Count each failed verification against RALPH_MAX_ATTEMPTS here, before the
  # rebuild: build_until_green only bumps ATTEMPTS on a red gate or no commits, so
  # a verifier that keeps failing cheap-but-green rebuilds would otherwise spin
  # uncapped (only the wall-clock budget, default off, would stop it).
  ATTEMPTS=$((ATTEMPTS+1))
  attempt_cap_hit && stop_issue verify-fail 1 "attempt cap RALPH_MAX_ATTEMPTS=${RALPH_MAX_ATTEMPTS} reached before the correctness gate passed"
  log "#$n: correctness gap vs ticket — re-running implementer to satisfy issue #$n"
  rebuild_or_stop "An independent reviewer judged the change does NOT fully satisfy issue #$n: a stated acceptance criterion or an edge case (boundaries, empty or missing input, error paths) is unmet. Re-read issue #$n and strengthen the implementation and its tests so every acceptance criterion and edge case is covered." verify-fail
done

# --- 4. Review <-> resolve: retry until the review converges -----------------
# review_and_resolve runs MAX_REVIEW_CYCLES of review<->fix per call and, in AFK
# mode, returns non-zero WITHOUT handing back, exposing REVIEW_FAIL_REASON. Route
# the retry: a red gate rebuilds, a leaked secret stops, anything else re-reviews.
until review_and_resolve "$pr_url" "$branch" "$n" "$ilog"; do
  ATTEMPTS=$((ATTEMPTS + ${LAST_REVIEW_CYCLES:-1}))
  case "${REVIEW_FAIL_REASON:-threads}" in
    secret) stop_issue secret-detected 5 "secret appeared in the diff during review — safety stop" ;;
    gate)
      log "#$n: a review fix left lint/tests red — rebuilding until green"
      rebuild_or_stop "A change made during code review left lint or tests FAILING in $TEST_DIR. Fix them until '$LINT_CMD' and '$TEST_CMD' both pass." handback ;;
    *)
      budget_exceeded && stop_issue budget-exceeded 1 "wall-clock budget RALPH_ISSUE_BUDGET=${RALPH_ISSUE_BUDGET}s exceeded before review converged — re-queued"
      attempt_cap_hit && stop_issue handback 1 "attempt cap RALPH_MAX_ATTEMPTS=${RALPH_MAX_ATTEMPTS} reached before review converged"
      log "#$n: review not converged this pass — re-reviewing" ;;
  esac
done

# --- 5. Approved: enable CI-gated auto-merge inline --------------------------
# GitHub merges the PR the moment required checks pass — after this process (and
# the loop) have exited. NB: no --delete-branch here. gh runs it from inside the
# worktree where issue/N is checked out, so deleting the LOCAL branch needs to
# switch to master (held by another worktree) and gh exits non-zero EVEN WHEN the
# merge/enable succeeded — the old misleading "did not enable" log. Remote-branch
# cleanup is handed to the repo's delete-branch-on-merge setting instead; the local
# branch + worktree are removed in cleanup(). So trust the PR STATE, not $?.
record_metric "$n" approved "${LAST_REVIEW_CYCLES:-}" "$(elapsed)"
log "#$n: approved — enabling CI-gated auto-merge"
approve_pr "$pr_url" "$n" "$ilog"
state="$(gh pr view "$pr_url" --json state -q .state 2>/dev/null || echo UNKNOWN)"
auto_on="$(gh pr view "$pr_url" --json autoMergeRequest -q '(.autoMergeRequest!=null)' 2>/dev/null || echo false)"
case "$state" in
  MERGED) log "#$n: PR merged — $pr_url" ;;
  *) if [ "$auto_on" = "true" ]; then
       log "#$n: auto-merge enabled — GitHub will merge when CI passes — $pr_url"
     else
       log "#$n: WARNING — PR neither merged nor auto-merge-enabled (state: $state) — $pr_url needs attention"
     fi ;;
esac
