#!/usr/bin/env bash
# ralph/status.sh — read-only status dashboard for the Ralph unattended loop.
# Sources lib.sh for the config and the metrics/PR read helpers but never calls
# ralph_init, so it stays free of side effects and safe to run anytime; every gh
# call is guarded so a transient API error never aborts.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

hr() { printf '%s\n' "------------------------------------------------------------"; }

label_count() {
  gh issue list --label "$1" --state open --json number -q 'length' 2>/dev/null || echo 0
}

# --- 1. Queue ---------------------------------------------------------------
printf '== Queue (open issues) ==\n'
{
  printf 'label\tcount\n'
  printf '%s\t%s\n' "$READY_LABEL"   "$(label_count "$READY_LABEL")"
  printf '%s\t%s\n' "$WORKING_LABEL" "$(label_count "$WORKING_LABEL")"
  printf '%s\t%s\n' "$HUMAN_LABEL"   "$(label_count "$HUMAN_LABEL")"
} | column -t -s $'\t'
printf '\n'

# --- 2. Open Ralph PRs ------------------------------------------------------
printf '== Open Ralph PRs (head issue/*) ==\n'
pr_lines="$(ralph_open_prs \
  | awk -F'\t' '{ printf "#%s\t%s\t%s\t%s\t%s\n", $1, ($3=="true" ? "DRAFT" : "ready"), $4, $2, $5 }')"

if [ -z "$pr_lines" ]; then
  printf '(no open PRs on issue/* branches)\n'
else
  {
    printf 'pr\tstate\tmergeable\tbranch\ttitle\n'
    printf '%s\n' "$pr_lines"
  } | column -t -s $'\t'

  total_pr="$(printf '%s\n' "$pr_lines" | grep -c . || true)"
  draft_pr="$(printf '%s\n' "$pr_lines" | grep -c $'\tDRAFT\t' || true)"
  ready_pr="$(printf '%s\n' "$pr_lines" | grep -c $'\tready\t' || true)"
  printf '\ntotal: %s   (draft: %s, ready: %s)\n' "$total_pr" "$draft_pr" "$ready_pr"
fi
printf '\n'

# --- 3. Throughput ----------------------------------------------------------
printf '== Throughput (metrics) ==\n'
metrics_summary
if [ -f "$METRICS_FILE" ]; then
  printf '\nRecent (last 10):\n'
  metrics_recent 10

  # Diagnosis surface: the last handbacks with their recorded reason, so "why did
  # Ralph hand these back?" is answerable from metrics alone (no log archaeology).
  printf '\nRecent handbacks (with reason):\n'
  metrics_handbacks 10
fi
printf '\n'

# --- 4. Review convergence --------------------------------------------------
# Whole-loop health signal: are approvals taking fewer review cycles over time?
# A rising trend points at prompt/model drift worth investigating by hand.
printf '== Review convergence ==\n'
metrics_trend
