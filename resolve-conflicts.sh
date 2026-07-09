#!/usr/bin/env bash
# ralph/resolve-conflicts.sh <pr-number> <branch>
#
# Brings a Ralph PR branch up to date with master, resolving any merge conflicts
# via an agent, then re-runs the code review. Called by run.sh's
# maintenance sweep when an open Ralph PR goes CONFLICTING (because master moved
# under it). On success the PR is re-approved and ready for a human merge;
# if conflicts can't be resolved cleanly it's handed to a human.

source "$(dirname "$0")/lib.sh"

num="${1:?usage: resolve-conflicts.sh <pr-number> <branch>}"
branch="${2:?usage: resolve-conflicts.sh <pr-number> <branch>}"
n="${branch#issue/}"
wt="$WORKTREE_ROOT/wt-$n"
mkdir -p "$LOG_DIR"
ilog="$LOG_DIR/issue-$n.log"
pr_url="$(gh pr view "$num" --json url -q .url 2>/dev/null || echo "$num")"

OLDPWD_ROOT="$PWD"
cleanup() {
  cd "$OLDPWD_ROOT" 2>/dev/null || true
  git worktree remove --force "$wt" 2>/dev/null || true
}
trap cleanup EXIT

git fetch origin "$BASE_BRANCH" "$branch" >>"$ilog" 2>&1 || { log "#$n: fetch failed — skipping"; exit 1; }

git worktree prune
if [ -e "$wt" ]; then
  git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
fi
git worktree add -B "$branch" "$wt" "origin/$branch" >>"$ilog" 2>&1
cd "$wt"

log "#$n: rebasing $branch onto origin/$BASE_BRANCH (linear history, no merge commit)"
if git rebase "origin/$BASE_BRANCH" >>"$ilog" 2>&1; then
  log "#$n: rebased cleanly (no conflicts)"
else
  log "#$n: conflicts during rebase — agent resolving"
  run_stage conflict "$n" "$ilog" "You are in a git worktree on branch '$branch', part-way through 'git rebase origin/$BASE_BRANCH' which has STOPPED on a conflict. Drive the rebase to completion: resolve the conflicts in the current commit so both this PR's intent (GitHub issue #$n) and the changes already on $BASE_BRANCH are preserved, 'git add' the resolved files, run 'git rebase --continue', and REPEAT until 'git status' shows no rebase in progress. Keep the $TEST_DIR test suite ('$TEST_CMD') and lint ('$LINT_CMD') green. Do NOT run 'git rebase --abort' and do NOT push." \
    >/dev/null || true

  # If a rebase is still in progress, it wasn't fully resolved — bail to a human.
  if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
    log "#$n: rebase NOT completed — aborting + handing to human"
    git rebase --abort >>"$ilog" 2>&1 || true
    hand_back "$pr_url" "$n" "$ilog" "Ralph could not auto-rebase onto \`$BASE_BRANCH\`; this PR needs a human."
    record_metric "$n" conflict-unresolved "" "" "auto-rebase onto $BASE_BRANCH could not be completed"
    exit 1
  fi
fi

# Rebase rewrites history, so the push must be a (lease-guarded) force.
git push --force-with-lease origin "$branch" >>"$ilog" 2>&1 || { log "#$n: force-push after rebase failed"; exit 1; }

# Re-review the updated PR; on APPROVED it is ready for a human merge again. In
# AFK mode review_and_resolve does NOT hand back — it returns REVIEW_FAIL_REASON
# and we re-review. This runs inside run.sh's maintenance sweep, so it must not
# loop forever: cap the re-reviews, and fall back to an explicit human handback on
# a reason this path can't fix (a red gate / leaked secret needs the full build
# loop in process-issue.sh) or once the cap is hit. This is a documented rare
# maintenance exception to the otherwise handback-free AFK flow.
passes=0; cap="${RALPH_MAX_ATTEMPTS:-0}"; [ "$cap" -gt 0 ] || cap=$(( ${RALPH_INFRA_RETRIES:-3} + 2 ))
until review_and_resolve "$pr_url" "$branch" "$n" "$ilog"; do
  passes=$((passes+1))
  case "${REVIEW_FAIL_REASON:-threads}" in
    threads)
      if [ "$passes" -ge "$cap" ]; then
        hand_back "$pr_url" "$n" "$ilog"
        record_metric "$n" handback "${LAST_REVIEW_CYCLES:-}" "" "post-rebase review did not converge in $passes passes"
        exit 1
      fi
      log "#$n: post-rebase review not converged — re-reviewing (pass $passes)" ;;
    secret)
      hand_back "$pr_url" "$n" "$ilog"
      record_metric "$n" secret-detected "${LAST_REVIEW_CYCLES:-}" "" "secret in diff during post-rebase review — safety stop"
      exit 1 ;;
    *)  # gate: a review fix left lint/tests red; the conflict path can't rebuild
      hand_back "$pr_url" "$n" "$ilog"
      record_metric "$n" test-fail "${LAST_REVIEW_CYCLES:-}" "" "lint/tests red after post-rebase review — needs the full build loop"
      exit 1 ;;
  esac
done
record_metric "$n" approved "${LAST_REVIEW_CYCLES:-}" "" "re-approved after rebase onto $BASE_BRANCH"
log "#$n: conflicts resolved + re-approved — PR $pr_url"
