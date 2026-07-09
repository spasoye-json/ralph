#!/usr/bin/env bash
# ralph/run.sh — CONTINUOUS drain loop. Runs until you stop it (Ctrl-C / kill).
#
# Each cycle: refresh master, process every eligible (ready-for-agent, unblocked)
# issue back-to-back, then sleep POLL_INTERVAL and poll again — picking up tickets
# added or unblocked since the last cycle. There is no per-agent turn cap; each
# /implement, review, and resolve session runs to completion.
#
# Usage:   ./ralph/run.sh                       (runs forever; Ctrl-C to stop)
# Dry run: DRY_RUN=1 ./ralph/run.sh             (lists eligible once, exits)
# Tunable: POLL_INTERVAL=900 ./ralph/run.sh     (poll every 15 min instead of 30)

source "$(dirname "$0")/lib.sh"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Not a git repo"; exit 1; }

mkdir -p "$LOG_DIR"

# Single-instance guard: a second run.sh would race the label-claim.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOG_DIR/.run.lock"
  flock -n 9 || { echo "Another ralph/run.sh holds $LOG_DIR/.run.lock — exiting."; exit 1; }
fi

run_log="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$run_log") 2>&1

# Per-run outcome trail for the circuit breaker (ok|fail, one per issue).
RUN_OUTCOMES="$LOG_DIR/.outcomes-$$"; : > "$RUN_OUTCOMES"
trap 'rm -f "$RUN_OUTCOMES" 2>/dev/null || true' EXIT

log "=== Ralph loop start. Pickup: $READY_LABEL  Handback: $HUMAN_LABEL  Base: $BASE_BRANCH  Poll: ${POLL_INTERVAL}s ==="

trap 'log "=== Ralph loop stopped (signal received). ==="; exit 0' INT TERM

if [ "${DRY_RUN:-0}" = "1" ]; then
  log "DRY RUN — eligible issues right now:"
  ready_issues | while read -r n; do
    log "  would process #$n — $(gh issue view "$n" --json title -q .title)"
  done
  log "DRY RUN complete. No changes made."
  exit 0
fi

# Maintenance sweep over Ralph's own open PRs (head issue/*), skipping handed-
# back drafts: resolve master-conflicts (then re-review) and hand back approved
# PRs whose CI is failing. Approved + green PRs are left alone — the merge is the
# human's checkpoint; Ralph never merges and never enables auto-merge.
maintain_prs() {
  local prs num branch draft mergeable n ci state
  prs="$(gh pr list --state open --json number,headRefName,isDraft,mergeable \
        -q '.[] | select(.headRefName | startswith("issue/")) | [.number,.headRefName,.isDraft,.mergeable] | @tsv' 2>/dev/null || true)"
  [ -z "$prs" ] && { log "  (no open Ralph PRs to maintain)"; return 0; }
  while IFS=$'\t' read -r num branch draft mergeable; do
    [ -z "$num" ] && continue
    [ "$draft" = "true" ] && continue        # handed-back PRs are the human's
    n="${branch#issue/}"

    # mergeable==CONFLICTING is an ORTHOGONAL axis to the Ralph-state enum, and the
    # conflict path is intentionally NOT gated on approval — it fires for ANY
    # non-draft PR (preserved behaviour). So check it FIRST, before the lifecycle
    # switch, and resolve+re-review without consulting pr_state.
    if [ "$mergeable" = CONFLICTING ]; then
      log "  PR #$num ($branch) conflicts with $BASE_BRANCH — resolving + re-reviewing"
      "$RALPH_DIR/resolve-conflicts.sh" "$num" "$branch" || log "  PR #$num conflict handling incomplete"
      continue
    fi

    # Lifecycle dispatch. "approved" is exactly Ralph's verified approval marker
    # with no post-approval human commit (classify_pr's safety property) — a
    # non-draft PR that isn't approved is human-managed (un-drafted, or pushed past
    # approval) and left alone. Only act on the MERGEABLE bucket; an UNKNOWN/other
    # mergeable status is re-checked next cycle, as before.
    state="$(pr_state "$num")" || { log "  PR #$num state unreadable — re-checking next cycle"; continue; }
    case "$state" in
      approved)
        if [ "$mergeable" != MERGEABLE ]; then
          log "  PR #$num approved but mergeable=$mergeable — re-checking next cycle"
          continue
        fi
        # Approved + no conflicts, but is CI actually green? CI is an orthogonal
        # axis to the enum. A persistently-red PR would sit unmergeable on the
        # human's desk, so detect failures and hand back explicitly.
        ci="$(gh pr checks "$num" --json bucket -q '[.[].bucket] | join(",")' 2>/dev/null)" || true
        if printf '%s' "$ci" | grep -q 'fail'; then
          log "  PR #$num approved but CI failing ($ci) — handing back to human"
          hand_back "$num" "$n" "" "Automated check: PR is approved + mergeable but required CI is failing — needs a human."
          record_metric "$n" ci-fail "" "" "approved + mergeable but required CI failing ($ci)"
          continue
        fi
        # Approved + green: nothing to do — the merge is the human checkpoint.
        log "  PR #$num approved & green — awaiting your merge"
        ;;
      *)
        log "  PR #$num state=$state mergeable=$mergeable — leaving alone (human-managed / re-checking)"
        ;;
    esac
  done <<< "$prs"
}

# Process one issue end to end (backgrounded by the dispatch loop). Always exits
# 0 so `wait` in the pool never trips set -e.
process_one() {
  local n="$1" rc=0
  "$RALPH_DIR/process-issue.sh" "$n" || rc=$?
  case "$rc" in
    0) log "<<< #$n completed"; echo ok ;;
    3) log "<<< #$n handed to human (infra error)"; echo infra ;;
    *) log "<<< #$n handed to human"; echo fail ;;
  esac >> "$RUN_OUTCOMES"
  return 0
}

# Fast-forward the main checkout's local BASE_BRANCH ref to origin so freshly-
# merged PRs are reflected locally. NEVER switches branches: if the human is
# parked on a feature branch (or detached), the ref is updated in place via a
# fast-forward-only fetch refspec (no leading '+', so it never rewrites local
# commits — same safety property as --ff-only); only when BASE_BRANCH is already
# checked out is the working tree fast-forwarded too. On divergence it logs and
# leaves the commits for a manual pull/rebase. Ralph itself doesn't need this
# (worktrees are cut from origin/$BASE_BRANCH), but it keeps the human's
# checkout current — run each cycle and once more on exit, since the loop drains
# and exits before the next cycle-start refresh would otherwise run.
refresh_base() {
  local head
  git fetch origin "$BASE_BRANCH" -q 2>/dev/null || return 0
  head="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 0
  if [ "$head" = "$BASE_BRANCH" ]; then
    git merge --ff-only "origin/$BASE_BRANCH" -q 2>/dev/null \
      || log "  local $BASE_BRANCH not fast-forwarded (diverged / local commits?) — pull manually"
  else
    git fetch origin "$BASE_BRANCH:$BASE_BRANCH" -q 2>/dev/null \
      || log "  local $BASE_BRANCH not fast-forwarded (diverged / local commits?) — pull manually"
  fi
}

# Re-queue issues stuck in WORKING_LABEL with no open PR — orphaned by a
# crash between claiming an issue and opening its PR.
reap_stale_working() {
  local n
  for n in $(gh issue list --label "$WORKING_LABEL" --state open --json number -q '.[].number' 2>/dev/null); do
    has_open_pr "$n" && continue   # has a PR — handled by resume/maintain / a human
    log "  reaped orphaned #$n (claude-working, no PR) — returning to $READY_LABEL"
    gh issue edit "$n" --remove-label "$WORKING_LABEL" --add-label "$READY_LABEL" >/dev/null 2>&1 || true
  done
}

# Resume issues stranded mid-review: an open DRAFT issue/* PR whose issue is still
# WORKING_LABEL and whose title is NOT a handback ([HUMAN_LABEL] prefix). At cycle
# start the worker pool is fully drained, so nothing is legitimately mid-review —
# such a PR was abandoned by a crash. Re-enter review via resolve-conflicts.sh
# (its rebase is a no-op when the branch is already current).
resume_stranded() {
  local prs num branch n labels
  prs="$(gh pr list --state open --json number,headRefName,isDraft \
        -q '.[] | select(.headRefName|startswith("issue/")) | select(.isDraft==true) | [.number,.headRefName]|@tsv' 2>/dev/null || true)"
  [ -z "$prs" ] && return 0
  while IFS=$'\t' read -r num branch; do
    [ -z "$num" ] && continue
    # "working" = draft AND not a handback ([HUMAN_LABEL]-prefixed) — pr_state
    # subsumes the old draft + title-prefix checks. The claude-working ISSUE label
    # is a separate, orthogonal signal (the crash-orphan marker), kept below.
    [ "$(pr_state "$num")" = working ] || continue
    n="${branch#issue/}"
    labels="$(gh issue view "$n" --json labels -q '[.labels[].name]|join(",")' 2>/dev/null || echo "")"
    case ",$labels," in
      *",$WORKING_LABEL,"*)
        log "  PR #$num ($branch) stranded mid-review (draft + $WORKING_LABEL) — resuming"
        "$RALPH_DIR/resolve-conflicts.sh" "$num" "$branch" || log "  PR #$num resume incomplete"
        ;;
    esac
  done <<< "$prs"
}

cycle=0
[ "$POLL_MIN" -ge 1 ] 2>/dev/null || POLL_MIN=1          # never a 0s poll
[ "$POLL_BACKOFF" -ge 1 ] 2>/dev/null || POLL_BACKOFF=2  # never collapse the idle delay to 0
cur_sleep="$POLL_MIN"   # adaptive: POLL_MIN while busy, backing off toward POLL_INTERVAL when idle
while :; do
  cycle=$((cycle+1))

  # Refresh local master each cycle so newly-merged PRs are reflected. (process-
  # issue.sh also fetches origin and branches from origin/master, so this is just
  # to keep the main checkout current.)
  refresh_base

  log "--- Cycle $cycle: reaping orphaned in-progress issues ---"
  reap_stale_working || log "  reaper errored (continuing)"
  resume_stranded || log "  resume sweep errored (continuing)"

  log "--- Cycle $cycle: maintaining open PRs (conflicts + CI health) ---"
  maintain_prs || log "  maintenance sweep errored (continuing)"

  mapfile -t batch < <(ready_issues)
  conc="$RALPH_CONCURRENCY"; [ "$conc" -ge 1 ] 2>/dev/null || conc=1
  log "--- Cycle $cycle: ${#batch[@]} eligible issue(s), concurrency $conc ---"

  for n in "${batch[@]}"; do
    is_blocked "$n" && { log "#$n now blocked, skipping"; continue; }
    # Bounded worker pool: block until a slot frees, then launch in the background.
    while [ "$(jobs -rp | wc -l)" -ge "$conc" ]; do wait -n || true; done
    log ">>> Processing #$n"
    process_one "$n" &
  done
  wait || true   # drain the pool before sleeping

  # Circuit breaker. Two thresholds, both reset by the first 'ok': a FAST one for
  # consecutive infra errors (broken sandbox/skill/auth — systemic, no point
  # continuing) and the GENERAL one for any consecutive handback. Guards against a
  # systemic problem quietly burning budget.
  if [ "${RALPH_MAX_INFRA_ERRORS:-0}" -gt 0 ]; then
    istreak="$(awk '$0=="infra"{s++} $0!="infra"{s=0} END{print s+0}' "$RUN_OUTCOMES" 2>/dev/null || echo 0)"
    if [ "${istreak:-0}" -ge "$RALPH_MAX_INFRA_ERRORS" ]; then
      log "!!! circuit breaker: $istreak consecutive infra errors (>= RALPH_MAX_INFRA_ERRORS=$RALPH_MAX_INFRA_ERRORS) — likely a broken sandbox/skill/auth. Stopping; fix it, then restart."
      exit 1
    fi
  fi
  if [ "${RALPH_MAX_HANDBACKS:-0}" -gt 0 ]; then
    streak="$(awk '$0=="ok"{s=0} $0!="ok"{s++} END{print s+0}' "$RUN_OUTCOMES" 2>/dev/null || echo 0)"
    if [ "${streak:-0}" -ge "$RALPH_MAX_HANDBACKS" ]; then
      log "!!! circuit breaker: $streak consecutive failures (>= RALPH_MAX_HANDBACKS=$RALPH_MAX_HANDBACKS) — stopping. Investigate, then restart."
      exit 1
    fi
  fi

  # Terminal condition: exit once nothing is eligible AND nothing is in flight.
  # "In flight" = draft issue/* PRs still mid-review that are NOT handed-back.
  # Approved PRs do NOT count — they wait for the human's merge, which can happen
  # long after the loop exits; blocking exit on them would poll forever. A merge
  # that lands unblocks its dependents — re-run the loop (or leave it running with
  # issues still queued) to pick those up. Ralph self-terminates when the queue is
  # clear and no review is mid-flight.
  inflight="$(gh pr list --state open --json headRefName,isDraft,title \
      -q '[.[] | select(.headRefName|startswith("issue/")) | select(.isDraft and ((.title|startswith("['"$HUMAN_LABEL"']")) | not))] | length' 2>/dev/null || echo 0)"
  remaining="$(ready_count)"
  if [ "${remaining:-0}" -eq 0 ] && [ "${inflight:-0}" -eq 0 ]; then
    refresh_base   # land the human on a current master (the last merges happened after the last cycle-start refresh)
    log "=== Queue drained, nothing mid-review — Ralph loop done (approved PRs await your merge). ==="
    exit 0
  fi

  # Adaptive cadence: reset to the fast floor whenever there was work to do;
  # otherwise back off geometrically toward the idle ceiling (waiting on stranded
  # reviews to converge or new tickets to arrive).
  if [ "${#batch[@]}" -gt 0 ]; then
    cur_sleep="$POLL_MIN"
  else
    cur_sleep=$(( cur_sleep * POLL_BACKOFF ))
    [ "$cur_sleep" -gt "$POLL_INTERVAL" ] && cur_sleep="$POLL_INTERVAL"
    [ "$cur_sleep" -lt "$POLL_MIN" ] && cur_sleep="$POLL_MIN"
  fi
  log "--- Cycle $cycle done. ${remaining} eligible, ${inflight} PR(s) in flight. Sleeping ${cur_sleep}s (Ctrl-C to stop) ---"
  sleep "$cur_sleep"
done
