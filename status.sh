#!/usr/bin/env bash
# ralph/status.sh — read-only status dashboard for the Ralph unattended loop.
# Does NOT source lib.sh (which hard-exits on an empty allowlist). Safe to run
# anytime; every gh call is guarded so a transient API error never aborts.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/config.sh"
LOG_DIR="${LOG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logs}"
METRICS_FILE="${METRICS_FILE:-$LOG_DIR/metrics.csv}"

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
pr_lines="$(gh pr list --state open \
  --json number,headRefName,isDraft,mergeable,title \
  -q '.[] | select(.headRefName|startswith("issue/")) | "#\(.number)\t\(if .isDraft then "DRAFT" else "ready" end)\t\(.mergeable)\t\(.headRefName)\t\(.title)"' \
  2>/dev/null || true)"

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
if [ ! -f "$METRICS_FILE" ]; then
  printf '(no metrics recorded yet)\n'
else
  awk -F, '
    {
      total++
      outcome[$3]++
      if ($3 == "approved") { app_cnt++; cyc_sum += $4; dur_sum += $5 }
      if ($3 == "handback") { hb_cnt++ }
    }
    END {
      printf "total rows: %d\n", total
      if (total == 0) { print "(file is empty)"; exit }

      print ""
      print "by outcome:"
      n = split("approved handback verify-fail no-commits tdd-error test-fail pr-failed escalated secret-detected ci-fail conflict-unresolved budget-exceeded", order, " ")
      for (i = 1; i <= n; i++) {
        o = order[i]
        if (o in outcome) { printf "  %-12s %d\n", o, outcome[o]; seen[o] = 1 }
      }
      for (o in outcome) { if (!(o in seen)) printf "  %-12s %d\n", o, outcome[o] }

      print ""
      denom = app_cnt + hb_cnt
      if (denom > 0) printf "approval rate: %.1f%% (%d / %d approved+handback)\n", (app_cnt / denom) * 100, app_cnt, denom
      else           printf "approval rate: n/a (no approved/handback rows)\n"

      if (app_cnt > 0) {
        printf "avg review cycles (approved): %.2f\n", cyc_sum / app_cnt
        avg_dur = dur_sum / app_cnt
        printf "avg duration (approved): %.0f s (%.1f min)\n", avg_dur, avg_dur / 60
      } else {
        printf "avg review cycles (approved): n/a\n"
        printf "avg duration (approved): n/a\n"
      }
    }
  ' "$METRICS_FILE" || true

  printf '\nRecent (last 10):\n'
  tail -n 10 "$METRICS_FILE" 2>/dev/null || true

  # Diagnosis surface: the last handbacks with their recorded reason, so "why did
  # Ralph hand these back?" is answerable from metrics alone (no log archaeology).
  printf '\nRecent handbacks (with reason):\n'
  awk -F, '$3!="approved" && NF { printf "  #%-5s %-18s %s\n", $2, $3, ($6==""?"(no reason recorded)":$6) }' \
    "$METRICS_FILE" 2>/dev/null | tail -n 10 || true
fi
printf '\n'

# --- 4. Review convergence --------------------------------------------------
# Whole-loop health signal: are approvals taking fewer review cycles over time?
# A rising trend points at prompt/model drift worth investigating by hand.
printf '== Review convergence ==\n'
if [ -f "$METRICS_FILE" ]; then
  awk -F, '
    $3=="approved" && $4!="" { c[++k]=$4 }
    END {
      if (k < 4) { print "review-cycle trend: n/a (need >=4 approvals)"; exit }
      h=int(k/2); old=0; new=0
      for (i=1;i<=h;i++) old+=c[i]
      for (i=h+1;i<=k;i++) new+=c[i]
      oa=old/h; na=new/(k-h)
      trend=(na < oa-0.05)?"improving":((na > oa+0.05)?"drifting":"stable")
      printf "review-cycle trend (older->recent approvals): %.2f -> %.2f  [%s]\n", oa, na, trend
    }' "$METRICS_FILE" || true
else
  printf '(no metrics recorded yet)\n'
fi
