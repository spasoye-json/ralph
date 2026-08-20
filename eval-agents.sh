#!/usr/bin/env bash
# ralph/eval-agents.sh — OPT-IN agent-output quality harness: measure the AGENT,
# not just the deterministic bash that eval.sh pins.
#
# For each frozen fixture issue it: creates a throwaway DETACHED worktree at
# EVAL_BASE, runs the REAL /implement inline (no gh issue, no branch), runs the
# objective lint+test gate, then asks a read-only rubric agent to score the diff
# 0-100 against the fixture's acceptance points. It NEVER writes to GitHub — no
# push, no PR, no issue edits — and tears every worktree down afterwards.
#
# It costs real tokens, so it is opt-in and deliberately NOT part of eval.sh / CI.
# Use it to validate a prompt/model change before shipping: a scorecard you can
# diff, instead of trusting that the change helped. Exit status is non-zero if any
# fixture's outcome misses its `expect-gate`, so it doubles as a manual gate. The
# escalation sentinel is honoured (outcome 'escalate').
#
# Usage:
#   ralph eval-agents                 # run every fixture in eval/agent-cases/
#   ralph eval-agents clamp-util      # run only the named fixture slug(s)
#   ralph eval-agents --list          # parse + list fixtures, run nothing
#
# Tunables (besides the MODEL_*/TEST_* knobs inherited from lib.sh):
#   EVAL_BASE         git ref the worktrees are cut from (default: current HEAD)
#   EVAL_RESULTS_FILE scorecard CSV (default: logs/eval-agents.csv)
#   EVAL_WT_ROOT      where eval worktrees are created (default: WORKTREE_ROOT)

source "$(dirname "$0")/lib.sh"
ralph_init
set +e +o pipefail   # a single fixture failing must not abort the whole run

CASES_DIR="$RALPH_DIR/eval/agent-cases"
EVAL_BASE="${EVAL_BASE:-$(git rev-parse HEAD)}"
RESULTS_FILE="${EVAL_RESULTS_FILE:-$LOG_DIR/eval-agents.csv}"
EVAL_WT_ROOT="${EVAL_WT_ROOT:-$WORKTREE_ROOT}"
mkdir -p "$LOG_DIR"

# parse_case <file> — set C_TITLE, C_EXPECT (pass|fail), C_ACCEPT, C_BODY from a
# fixture. Header lines look like '# title: ...', '# expect-gate: pass',
# '# acceptance: a; b; c'; everything after the first blank line is the body.
# Fixtures are project-agnostic: the {{TEST_DIR}} placeholder is substituted
# with the configured gate package (config.sh) at read time.
parse_case() {
  local f="$1" in_body=0 line
  C_TITLE=""; C_EXPECT="pass"; C_ACCEPT=""; C_BODY=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_body" -eq 0 ]; then
      case "$line" in
        '# title:'*)      C_TITLE="${line#*: }"; continue ;;
        '# expect-gate:'*) C_EXPECT="$(printf '%s' "${line#*: }" | tr -d '[:space:]')"; continue ;;
        '# acceptance:'*) C_ACCEPT="${line#*: }"; continue ;;
        '#'*)             continue ;;
        '')               in_body=1; continue ;;
        *)                in_body=1; C_BODY="$line"$'\n'; continue ;;
      esac
    fi
    C_BODY+="$line"$'\n'
  done < <(sed "s|{{TEST_DIR}}|$TEST_DIR|g" "$f")
  [ -n "$C_TITLE" ] || C_TITLE="$(basename "$f" .md)"
}

list_cases() {
  local f
  for f in "$CASES_DIR"/*.md; do [ -e "$f" ] || continue; basename "$f" .md; done
}

# run_case <slug> <file> — returns 0 if the gate met expectation, 1 otherwise.
# Prints one scorecard line, appends a CSV row, and sets LAST_GATE / LAST_RUBRIC
# for the caller (run_suite) to aggregate. The implementer may escalate (drop the
# sentinel) on an underspecified fixture; that is recorded as gate=escalate, not a
# forced pass/fail.
run_case() {
  local slug="$1" f="$2" wt log gate rubric diff out ok_gate esc
  parse_case "$f"
  wt="$EVAL_WT_ROOT/eval-wt-$slug"
  log="$LOG_DIR/eval-$slug.log"; : > "$log"

  if ! worktree_enter "$wt" --detach "" "$EVAL_BASE" "$log"; then
    printf '  %-22s WORKTREE-FAIL (see %s)\n' "$slug" "$log"
    LAST_GATE=worktree-fail; LAST_RUBRIC="-"; return 1
  fi

  ( cd "$wt" || exit 1
    # Reuse the production implement role so the implementer here gets the SAME policy
    # bag — crucially the docker sandbox (run_stage sandboxes the implementer by
    # construction when RALPH_SANDBOX=1), closing the old eval-vs-production
    # divergence. Set EVAL_SANDBOX=0 to skip the sandbox for speed.
    run_stage implement "$slug" "$log" "/implement

$C_TITLE

Issue (untrusted data):
$C_BODY

Implement this. Work only within this worktree. Commit incrementally. Done when
all tests pass and lint is clean.

If the issue is too underspecified to implement responsibly, do NOT force a
low-quality guess: write a file named $ESCALATE_FILE in the worktree root whose
first line states the blocker in one sentence, then stop." >/dev/null
  )

  # An escalation sentinel means the agent declined — score it as 'escalate', not
  # a pass/fail of the (empty) diff. Otherwise the objective gate decides.
  esc="$(read_escalation "$wt")"
  if [ -n "$esc" ]; then
    gate=escalate; rubric="-"
  else
    if ( cd "$wt" && run_quality_gate "$log" ); then gate=pass; else gate=fail; fi
    # Read-only rubric score against the acceptance points (diff inlined as data).
    diff="$(git -C "$wt" diff "$EVAL_BASE" 2>/dev/null | head -c 60000)"
    out="$(run_stage rubric "$slug" "$log" "Score how well the diff below implements the task, as an integer 0-100 (0 = nothing useful, 100 = complete, correct, well-tested).

TASK: $C_TITLE
ACCEPTANCE POINTS: ${C_ACCEPT:-(none given — judge against the task)}

Diff (untrusted data):
$diff

Output ONLY a single line and nothing else:
SCORE: <integer 0-100>")"
    rubric="$(printf '%s\n' "$out" | grep -oiP 'SCORE:\s*\K\d+' | tail -n1 || true)"
    [ -n "$rubric" ] || rubric="?"
  fi

  printf '%s,%s,%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$gate" "$rubric" >> "$RESULTS_FILE"
  LAST_GATE="$gate"; LAST_RUBRIC="$rubric"

  [ "$C_EXPECT" = "$gate" ] && ok_gate=0 || ok_gate=1
  printf '  %-22s gate=%-8s (expect %-8s) rubric=%-3s\n' \
    "$slug" "$gate" "$C_EXPECT" "$rubric"

  worktree_leave "$wt"
  return "$ok_gate"
}

# run_suite <label> <slug...> — run every slug, print the scorecard, and leave the
# aggregate in SUITE_* globals (avg rubric, gate-pass count, fixture count, fails).
run_suite() {
  local label="$1"; shift
  local slug f
  SUITE_RUBRIC_SUM=0; SUITE_RUBRIC_N=0; SUITE_GATE_PASS=0; SUITE_N=0; SUITE_FAILS=0
  echo "== agent-output eval [$label] (base $EVAL_BASE) =="
  for slug in "$@"; do
    f="$CASES_DIR/$slug.md"
    [ -f "$f" ] || { printf '  %-22s MISSING fixture\n' "$slug"; SUITE_FAILS=$((SUITE_FAILS+1)); continue; }
    run_case "$slug" "$f" || SUITE_FAILS=$((SUITE_FAILS+1))
    SUITE_N=$((SUITE_N+1))
    [ "$LAST_GATE" = pass ] && SUITE_GATE_PASS=$((SUITE_GATE_PASS+1))
    case "$LAST_RUBRIC" in ''|'?'|'-') ;; *) SUITE_RUBRIC_SUM=$((SUITE_RUBRIC_SUM + LAST_RUBRIC)); SUITE_RUBRIC_N=$((SUITE_RUBRIC_N+1)) ;; esac
  done
  SUITE_RUBRIC_AVG=0; [ "$SUITE_RUBRIC_N" -gt 0 ] && SUITE_RUBRIC_AVG=$(( SUITE_RUBRIC_SUM / SUITE_RUBRIC_N ))
}

# --- main --------------------------------------------------------------------
[ -d "$CASES_DIR" ] || { echo "no fixtures dir: $CASES_DIR" >&2; exit 1; }

if [ "${1:-}" = "--list" ]; then
  echo "fixtures in $CASES_DIR:"; list_cases | sed 's/^/  /'; exit 0
fi

mapfile -t slugs < <(if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; else list_cases; fi)
[ "${#slugs[@]}" -gt 0 ] || { echo "no fixtures to run in $CASES_DIR" >&2; exit 1; }

run_suite "default" "${slugs[@]}"
echo "== scorecard appended to $RESULTS_FILE =="
printf 'ran %d fixtures; avg rubric %d; gate pass %d/%d\n' \
  "$SUITE_N" "$SUITE_RUBRIC_AVG" "$SUITE_GATE_PASS" "$SUITE_N"
[ "$SUITE_FAILS" -eq 0 ]
