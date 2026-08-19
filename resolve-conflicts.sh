#!/usr/bin/env bash
# ralph/resolve-conflicts.sh <pr-number> <branch>
#
# Brings a Ralph PR branch up to date with master, resolving any merge conflicts
# via an agent, then re-runs the code review. Called by run.sh's
# maintenance sweep when an open Ralph PR goes CONFLICTING (because master moved
# under it). On success the PR is re-approved and ready for a human merge;
# if conflicts can't be resolved cleanly it's handed to a human.

source "$(dirname "$0")/lib.sh"
ralph_init

num="${1:?usage: resolve-conflicts.sh <pr-number> <branch>}"
branch="${2:?usage: resolve-conflicts.sh <pr-number> <branch>}"
n="${branch#issue/}"
wt="$WORKTREE_ROOT/wt-$n"
mkdir -p "$LOG_DIR"
ilog="$LOG_DIR/issue-$n.log"
pr_url="$(gh pr view "$num" --json url -q .url 2>/dev/null || echo "$num")"

# fail_pr <outcome> <cycles> <reason> [pr-comment] — this sweep's one terminal
# hand-back transaction: draft + retitle the PR, relabel the issue, record the
# metric, stop. Four copy-pasted blocks used to do this.
fail_pr() {
  hand_back "$pr_url" "$n" "$ilog" "${4:-}"
  record_metric "$n" "$1" "$2" "" "$3"
  exit 1
}

OLDPWD_ROOT="$PWD"
cleanup() {
  cd "$OLDPWD_ROOT" 2>/dev/null || true
  worktree_leave "$wt"
}
trap cleanup EXIT

if [ "${RALPH_SANDBOX:-0}" = 1 ]; then
  sandbox_preflight || { log "#$n: writer sandbox unavailable — aborting (set RALPH_SANDBOX=0 to run on host)"; exit 1; }
fi

if ! worktree_enter "$wt" -B "$branch" "origin/$branch" "$ilog" "$BASE_BRANCH" "$branch"; then
  log "#$n: worktree setup failed (fetch or worktree add — see issue-$n.log) — skipping"
  exit 1
fi
cd "$wt"

log "#$n: rebasing $branch onto origin/$BASE_BRANCH (linear history, no merge commit)"
if git rebase "origin/$BASE_BRANCH" >>"$ilog" 2>&1; then
  log "#$n: rebased cleanly (no conflicts)"
else
  log "#$n: conflicts during rebase — agent resolving"
  run_stage conflict "$n" "$ilog" "You are in a git worktree on branch '$branch', part-way through 'git rebase origin/$BASE_BRANCH' which has STOPPED on a conflict. Drive the rebase to completion: resolve the conflicts in the current commit so both this PR's intent (GitHub issue #$n) and the changes already on $BASE_BRANCH are preserved, 'git add' the resolved files, run 'git rebase --continue', and REPEAT until 'git status' shows no rebase in progress. Keep $(gate_cmds_text) green in $TEST_DIR. Do NOT run 'git rebase --abort' and do NOT push." \
    >/dev/null || true

  # If a rebase is still in progress, it wasn't fully resolved — bail to a human.
  if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
    log "#$n: rebase NOT completed — aborting + handing to human"
    git rebase --abort >>"$ilog" 2>&1 || true
    fail_pr conflict-unresolved "" "auto-rebase onto $BASE_BRANCH could not be completed" \
      "Ralph could not auto-rebase onto \`$BASE_BRANCH\`; this PR needs a human."
  fi
fi

# Rebase rewrites history, so the push must be a (lease-guarded) force.
git push --force-with-lease origin "$branch" >>"$ilog" 2>&1 || { log "#$n: force-push after rebase failed"; exit 1; }

# Re-review the updated PR; on APPROVED it is ready for a human merge again.
# review_and_resolve never hands back — it prints '<outcome> <cycles>' and this
# caller routes it. This runs inside run.sh's maintenance sweep, so it must not
# loop forever: cap the re-review passes via the retry budget (attempts-only —
# RALPH_MAX_ATTEMPTS, or infra-retries+2 when attempts are unlimited, since the
# sweep must still terminate), and hand back on a reason this path can't fix
# (a red gate / leaked secret needs the full build loop in process-issue.sh) or
# once the cap is hit. This is a documented rare maintenance exception to the
# otherwise handback-free AFK flow.
cap="${RALPH_MAX_ATTEMPTS:-0}"; [ "$cap" -gt 0 ] || cap=$(( ${RALPH_INFRA_RETRIES:-3} + 2 ))
budget_start "$cap" 0
until review="$(review_and_resolve "$pr_url" "$branch" "$n" "$ilog")"; do
  cycles="${review##* }"
  case "${review%% *}" in
    threads)
      if ! budget_attempt; then
        fail_pr handback "$cycles" "post-rebase review did not converge in $(budget_attempts) passes"
      fi
      log "#$n: post-rebase review not converged — re-reviewing (pass $(budget_attempts))" ;;
    secret)
      fail_pr secret-detected "$cycles" "secret in diff during post-rebase review — safety stop" ;;
    *)  # gate: a review fix left lint/tests red; the conflict path can't rebuild
      fail_pr test-fail "$cycles" "lint/tests red after post-rebase review — needs the full build loop" ;;
  esac
done
record_metric "$n" approved "${review##* }" "" "re-approved after rebase onto $BASE_BRANCH"
log "#$n: conflicts resolved + re-approved — PR $pr_url"
