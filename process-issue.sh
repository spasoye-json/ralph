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
#   6. approved -> un-draft the PR and leave it for a HUMAN to merge
#
# Each review and each resolve is a separate `claude -p` process, so neither
# inherits the other's context — the reviewer stays unbiased by construction.
# The /implement and /code-review skills come from the mattpocock-skills
# plugin, linked into ~/.claude/skills by ralph link-skills and left
# untouched.
#
# Usage:  ralph/process-issue.sh <issue-number>
# Run from the repo root; gh + claude must be on PATH.

source "$(dirname "$0")/lib.sh"
ralph_init

n="${1:?usage: process-issue.sh <issue-number>}"
branch="issue/$n"
wt="$WORKTREE_ROOT/wt-$n"
mkdir -p "$LOG_DIR"
ilog="$LOG_DIR/issue-$n.log"
budget_start   # attempts: RALPH_MAX_ATTEMPTS, wall clock: RALPH_ISSUE_BUDGET

# Verify the implementer sandbox is usable before claiming work, so a misconfigured
# sandbox aborts cleanly instead of churning labels or (worse) silently running the
# agent on the host. Opt out with RALPH_SANDBOX=0.
if [ "${RALPH_SANDBOX:-0}" = "1" ]; then
  sandbox_preflight || { log "#$n: writer sandbox unavailable — aborting (set RALPH_SANDBOX=0 to run on host)"; exit 1; }
fi

# Claim the issue so a second invocation never double-picks it. Issues reach the
# queue already triaged by hand, so there is no pre-flight readiness gate here.
issue_claim "$n"

OLDPWD_ROOT="$PWD"
cleanup() {
  cd "$OLDPWD_ROOT" 2>/dev/null || true
  worktree_leave "$wt" "$branch"
}
trap cleanup EXIT

# An open PR on this issue means an earlier run already pushed work, so RESUME
# that branch: skip the build-from-scratch and the PR creation, and re-enter at
# the gate + verify + review stages below. The old guard also required a local
# refs/heads/$branch, but cleanup() deletes that ref on every exit — so a second
# hand-run re-cut the branch from $BASE_BRANCH, silently abandoned the PR's
# commits, and then reviewed the open PR against work it never pushed.
RESUME_NUM="$(open_pr_num "$n")"
RESUME_PR=""
if [ -n "$RESUME_NUM" ]; then
  RESUME_PR="$(gh pr view "$RESUME_NUM" --json url -q .url 2>/dev/null || echo "$RESUME_NUM")"
  log "#$n: open PR $RESUME_PR (state: $(pr_state "$RESUME_NUM" || echo unreadable)) — resuming it"
fi

# worktree_enter fetches the refs first, so the worktree is cut from the latest
# origin state rather than a stale local ref, and fails rather than silently
# building on a stale base.
if [ -n "$RESUME_PR" ]; then
  log "#$n: creating worktree $wt on $branch (from origin/$branch)"
  worktree_enter_branch "$wt" "$branch" "$ilog" && wrc=0 || wrc=$?
else
  log "#$n: creating worktree $wt on $branch (from origin/$BASE_BRANCH)"
  worktree_enter "$wt" -b "$branch" "origin/$BASE_BRANCH" "$ilog" "$BASE_BRANCH" && wrc=0 || wrc=$?
fi
if [ "$wrc" != 0 ]; then
  log "#$n: worktree setup failed (fetch or worktree add — see issue-$n.log)"
  issue_release "$n" "$HUMAN_LABEL"
  exit 1
fi
cd "$wt"

# --- Maker: one /implement run in its OWN context (one attempt of the build loop)
# run_impl_here [extra-context] — run /implement once in the CURRENT worktree,
# capturing its exit code in IMPL_RC. build_until_green calls this repeatedly
# until green.
run_impl_here() {
  # The implement role's full policy bag — model, allowlist, IMPL_DISALLOW, acceptEdits,
  # guard AND the docker sandbox + MCP-trim blanking — is resolved inside run_stage
  # (the sandbox shadow stays confined there, so later host stages keep bare claude).
  # cwd is the worktree (we cd'd in above), which run_stage mounts as the container
  # worktree. Keep the exit code: the gate below tells an infra crash from a no-op.
  run_stage implement "$n" "$ilog" "/implement #$n

Implement GitHub issue #$n. Work only within this worktree.
The full issue is included below — work from it directly; do not call gh or fetch
anything over the network.

SCOPE. The issue's acceptance criteria are the whole job. Before you change a
file, name the criterion that asks for it; if none does, do not change it. Work
nobody asked for is a defect here, not a bonus: an independent verifier reads
this diff against the ticket and fails it for anything out of scope, which sends
you round again. If you find a real problem the ticket does not cover, say so in
your final message and leave the code alone.

Commit incrementally. You are DONE only when all tests pass and lint is clean.
Do not stop early: if the work is merely hard, keep going until $(gate_cmds_text)
pass in $TEST_DIR. This loop will re-run you with the exact failures until that
objective gate is green.
If — and only if — the issue is too underspecified or contradictory to implement
responsibly, do NOT force a low-quality guess: write a file named $ESCALATE_FILE
in the worktree root whose first line states the blocker in one sentence, then
stop. A clean escalation beats a confident wrong answer.

${1:-}" \
    >/dev/null && IMPL_RC=0 || IMPL_RC=$?
}

# --- AFK retry machinery -----------------------------------------------------
# No quality handbacks: the implementer is re-run, with each failure fed back,
# until the objective gate is green. The only stops are safety/systemic ones that
# retrying cannot clear (leaked secret, repeated /implement crash, an explicit
# escalation). The accounting lives in lib.sh's retry budget (budget_start above):
# RALPH_MAX_ATTEMPTS (0 = unlimited) is an optional brake, RALPH_INFRA_RETRIES
# bounds crashes, RALPH_ISSUE_BUDGET bounds wall-clock.
has_commits() { ! git diff --quiet "origin/$BASE_BRANCH"...HEAD; }

# stop_issue <outcome> <exit-code> <reason> — relabel and record a terminal stop.
# exit 3 is an infra error, 5 a safety stop (leaked secret) and 6 an implementer
# escalation — all three go to a human, never back to the queue (run.sh maps 5/6
# to a generic fail for the circuit breaker); other codes re-queue the issue
# (ready-for-agent) so a later run retries from a fresh worktree.
stop_issue() {
  local outcome="$1" code="$2" reason="$3" lbl="$READY_LABEL"
  case "$code" in 3|5|6) lbl="$HUMAN_LABEL" ;; esac
  log "#$n: $reason — ${lbl}"
  issue_release "$n" "$lbl"
  record_metric "$n" "$outcome" "" "$(budget_elapsed)" "$reason"
  exit "$code"
}

# build_until_green <feedback> — run the implementer, then loop until the OBJECTIVE
# lint+test gate passes, feeding each failure back. Commits accumulate across
# attempts. Returns the shared budget protocol — 0 (green), 1 (attempt cap),
# 3 (repeated crash), 4 (wall-clock budget) — plus 6 (implementer escalated).
build_until_green() {
  local feedback="$1" gate_tail brc
  while :; do
    brc=0; budget_check || brc=$?
    [ "$brc" = 4 ] && return 4
    run_impl_here "$feedback"
    if [ -n "$(read_escalation "$PWD")" ]; then return 6; fi
    if ! has_commits; then
      if [ "${IMPL_RC:-0}" -ne 0 ]; then
        brc=0; budget_strike || brc=$?
        log "#$n: /implement crashed (exit $IMPL_RC) with no commits — infra strike $(budget_strikes)/${RALPH_INFRA_RETRIES}"
        [ "$brc" = 3 ] && return 3
        feedback="The previous run did not complete. Implement issue #$n from scratch in this worktree and commit your work."
        continue
      fi
      brc=0; budget_attempt || brc=$?
      [ "$brc" != 0 ] && return "$brc"
      log "#$n: /implement produced no commits — re-running with a firmer instruction (attempt $(budget_attempts))"
      feedback="You produced NO commits. You MUST implement issue #$n and commit the code now — write the implementation and its tests, then commit."
      continue
    fi
    budget_strike_reset
    if run_quality_gate "$ilog"; then return 0; fi
    brc=0; budget_attempt || brc=$?
    [ "$brc" != 0 ] && return "$brc"
    gate_tail="$(tail -n 80 "$ilog" 2>/dev/null || true)"
    log "#$n: lint/tests still red — re-running implementer with the failure output (attempt $(budget_attempts))"
    feedback="Your previous attempt left lint or tests FAILING in $TEST_DIR. Fix them until $(gate_cmds_text) pass. The objective gate output was:

$gate_tail"
  done
}

# route_build_rc <rc> <cap-outcome> <phase> — the ONE decoder for
# build_until_green's return protocol (two near-identical case blocks used to
# drift). Returns only on 0 (green); every other code is a terminal stop.
route_build_rc() {
  local rc="$1" cap_outcome="$2" phase="$3"
  case "$rc" in
    0) return 0 ;;
    3) stop_issue implement-error 3 "/implement crashed with no commits ${RALPH_INFRA_RETRIES}x $phase (infra error; see issue-$n.log)" ;;
    4) stop_issue budget-exceeded 1 "wall-clock budget RALPH_ISSUE_BUDGET=${RALPH_ISSUE_BUDGET}s exceeded $phase — re-queued" ;;
    6) stop_issue escalated 6 "implementer escalated: $(read_escalation "$PWD")" ;;
    *) stop_issue "$cap_outcome" 1 "attempt cap RALPH_MAX_ATTEMPTS=${RALPH_MAX_ATTEMPTS} reached $phase" ;;
  esac
}

# rebuild_or_stop <feedback> <cap-outcome> — re-run build_until_green (the verifier
# or reviewer asked for more implementation work) and route its terminal codes.
# Returns to the caller only on success (gate green), having pushed the new commits.
rebuild_or_stop() {
  local fb="$1" cap_outcome="$2" rc
  build_until_green "$fb" && rc=0 || rc=$?
  route_build_rc "$rc" "$cap_outcome" "during a fix loop"
  push_branch "$branch" "$n" "$ilog" || \
    stop_issue pr-failed 3 "the rebuilt branch could not be pushed — the PR would review stale code (infra error; see issue-$n.log)"
}

# --- 1. Build until the objective gate is green ------------------------------
# Fetch the issue on the host and inject it, so the sandboxed implementer needs no
# gh and no GitHub token inside the container.
issue_ctx="$(gh issue view "$n" --json title,body \
  -q '"## Issue #'"$n"': " + .title + "\n\n" + (.body // "_(no description)_")' 2>/dev/null || true)"

if [ -n "$RESUME_PR" ]; then
  # The resumed branch already carries an implementation, so the implementer only
  # runs if the objective gate is red. A green gate goes straight to verify+review.
  log "#$n: resuming — running the objective gate on the pushed branch"
  if ! run_quality_gate "$ilog"; then
    log "#$n: resumed branch has lint/tests red — rebuilding until green"
    rebuild_or_stop "The branch for issue #$n has lint or tests FAILING in $TEST_DIR. Fix them until $(gate_cmds_text) pass.

$issue_ctx" test-fail
  fi
else
  log "#$n: /implement starting — building until lint+tests pass"
  build_until_green "The issue to implement:

$issue_ctx" && bg=0 || bg=$?
  route_build_rc "$bg" test-fail "before lint/tests passed"
fi

# Accidental-secret gate (SAFETY, not quality): never open a PR whose diff leaks a
# high-confidence secret. This is the one quality-independent hard stop that
# retrying cannot safely clear, so it still goes to a human even in AFK mode.
if ! run_safety_scan "$ilog"; then
  stop_issue secret-detected 5 "high-confidence secret in PR diff — safety stop (see issue-$n.log)"
fi

# --- 2. Open the PR up front (agent-authored title + body) -------------------
# On a resume the PR is already open, so this whole stage is skipped: pr_url is
# the PR found above, and rebuild_or_stop has already pushed any new commits.

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
  # Require an OPEN PR: without the state filter 'gh pr view <branch>' falls back
  # to the most recent PR on the branch — including a MERGED/CLOSED one — so a
  # failed create after an earlier merged PR would read as success.
  pr_url="$(gh pr view "$branch" --json url,state -q 'select(.state=="OPEN") | .url' 2>/dev/null || true)"
  [ -n "$pr_url" ]
}
if [ -n "$RESUME_PR" ]; then
  pr_url="$RESUME_PR"
else
  log "#$n: pushing branch and drafting PR"
  git push -u origin "$branch" >>"$ilog" 2>&1 || \
    push_branch "$branch" "$n" "$ilog" || \
    stop_issue pr-failed 3 "the branch could not be pushed, so no PR can be opened (infra error; see issue-$n.log)"
  pr_tries=0
  until create_pr; do
    pr_tries=$((pr_tries+1))
    [ "$pr_tries" -ge "${RALPH_INFRA_RETRIES:-3}" ] && \
      stop_issue pr-failed 3 "PR-author created no PR on $branch after ${pr_tries} tries (infra error)"
    log "#$n: PR not created — retrying PR author (try $pr_tries)"
  done
fi
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

# --- 3. Correctness gate: retry until the change actually solves the ticket --
# A fresh, independent, read-only verifier judges the diff against the issue's
# acceptance criteria + edge cases. In AFK mode a fail re-runs the implementer
# (which keeps the gate green) until the verifier passes — never a handback.
while ! verify_issue "$pr_url" "$n" "$ilog"; do
  # Charge each failed verification against the budget here, before the rebuild:
  # build_until_green only charges attempts on a red gate or no commits, so a
  # verifier that keeps failing cheap-but-green rebuilds would otherwise spin
  # uncapped (only the wall-clock budget, default off, would stop it).
  brc=0; budget_attempt || brc=$?
  [ "$brc" = 4 ] && stop_issue budget-exceeded 1 "wall-clock budget RALPH_ISSUE_BUDGET=${RALPH_ISSUE_BUDGET}s exceeded before the correctness gate passed — re-queued"
  [ "$brc" = 1 ] && stop_issue verify-fail 1 "attempt cap RALPH_MAX_ATTEMPTS=${RALPH_MAX_ATTEMPTS} reached before the correctness gate passed"
  log "#$n: correctness gap vs ticket — re-running implementer to satisfy issue #$n"
  rebuild_or_stop "An independent verifier judged this change against issue #$n and FAILED it, on correctness, on scope, or on both. Its words follow. Act on them exactly: close a correctness gap by strengthening the implementation and its tests, and remove out-of-scope work rather than justifying it. Change nothing else.

$VERIFY_REASON" verify-fail
done

# --- 4. Review <-> resolve: retry until the review converges -----------------
# review_and_resolve runs MAX_REVIEW_CYCLES of review<->fix per call, never hands
# back, and prints '<outcome> <cycles>' (approved|threads|gate|secret). Route a
# non-approving outcome: a red gate rebuilds, a leaked secret stops, anything
# else re-reviews (AFK) or hands back to a human (RALPH_AFK=0).
until review="$(review_and_resolve "$pr_url" "$branch" "$n" "$ilog")"; do
  brc=0; budget_charge "${review##* }" || brc=$?
  case "${review%% *}" in
    secret) stop_issue secret-detected 5 "secret appeared in the diff during review — safety stop" ;;
    gate)
      log "#$n: a review fix left lint/tests red — rebuilding until green"
      rebuild_or_stop "A change made during code review left lint or tests FAILING in $TEST_DIR. Fix them until $(gate_cmds_text) pass." handback ;;
    *)
      if [ "${RALPH_AFK:-1}" != "1" ]; then
        log "#$n: review did not converge — handing PR to human (RALPH_AFK=0)"
        hand_back "$pr_url" "$n" "$ilog"
        stop_issue handback 1 "review did not converge — handed to a human (RALPH_AFK=0)"
      fi
      [ "$brc" = 4 ] && stop_issue budget-exceeded 1 "wall-clock budget RALPH_ISSUE_BUDGET=${RALPH_ISSUE_BUDGET}s exceeded before review converged — re-queued"
      [ "$brc" = 1 ] && stop_issue handback 1 "attempt cap RALPH_MAX_ATTEMPTS=${RALPH_MAX_ATTEMPTS} reached before review converged"
      log "#$n: review not converged this pass — re-reviewing" ;;
  esac
done

# --- 5. Approved: un-draft and leave the merge to a human --------------------
# Ralph never merges and never enables auto-merge — approve_pr un-drafts the PR
# and posts the approval marker; you merge it when you're ready (the one human
# checkpoint). Remote-branch cleanup is handed to the repo's
# delete-branch-on-merge setting; the local branch + worktree are removed in
# cleanup(). Verify by PR STATE, not gh's exit code.
record_metric "$n" approved "${review##* }" "$(budget_elapsed)"
log "#$n: approved — un-drafting; the merge is yours"
approve_pr "$pr_url" "$n" "$ilog"
state="$(gh pr view "$pr_url" --json state,isDraft -q '"\(.state) \(.isDraft)"' 2>/dev/null || echo "UNKNOWN true")"
case "$state" in
  "MERGED "*)  log "#$n: PR already merged — $pr_url" ;;
  "OPEN false") log "#$n: approved and ready for your merge — $pr_url" ;;
  *) log "#$n: WARNING — PR not un-drafted as expected (state/draft: $state) — $pr_url needs attention" ;;
esac
