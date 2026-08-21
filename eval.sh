#!/usr/bin/env bash
# ralph/eval.sh — offline regression harness for Ralph's deterministic guard
# logic. A small evaluation harness is the highest-leverage thing here: the
# pure-bash decisions silently regress when a prompt or guard is edited, so they
# need pinning. Ralph's metrics track live outcomes; this pins the rest. It runs
# NO agents and makes no network calls; it asserts:
#   - the capability boundary (INJECTION_GUARD) is present and prohibits the key actions
#   - the correctness-verdict parse, escalation sentinel, secret scan
# Run it before and after changing any guard/prompt logic:  ralph eval
# Exit status is non-zero if any assertion fails (usable as a CI/pre-push gate).

# Sourcing lib.sh is side-effect free; the effectful init (allowlist load, claude
# probe, file writes) lives in ralph_init, which this harness never calls.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/lib.sh"
set +e +o pipefail   # lib.sh enables -e; a failing assertion must be COUNTED, not abort

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$*" >&2; }

# --- 4. capability boundary present + prohibits the key actions -----------------
printf '== capability boundary (INJECTION_GUARD) ==\n'
[ -n "$INJECTION_GUARD" ] && ok || bad "INJECTION_GUARD is empty"
g="$(printf '%s' "$INJECTION_GUARD" | tr '[:upper:]' '[:lower:]')"
printf '%s' "$g" | grep -q 'untrusted data'                      && ok || bad "guard should name inputs as untrusted data"
printf '%s' "$g" | grep -Eq 'test|lint|ci'                       && ok || bad "guard should prohibit weakening tests/lint/CI"
printf '%s' "$g" | grep -q 'exfiltrate'                          && ok || bad "guard should prohibit exfiltration"
printf '%s' "$g" | grep -q 'destructive'                         && ok || bad "guard should prohibit destructive commands"

# --- 6. metacognitive escalation sentinel ---------------------------------------
printf '== escalation sentinel (read_escalation) ==\n'
ed="$(mktemp -d)"
[ -z "$(read_escalation "$ed")" ] && ok || bad "no sentinel should read empty"
printf '   needs a design decision on the schema  \nextra detail line\n' > "$ed/$ESCALATE_FILE"
got="$(read_escalation "$ed")"
[ "$got" = "needs a design decision on the schema" ] && ok || bad "escalation reason got '$got'"
rm -rf "$ed"

# --- 6c. correctness verdict parse ----------------------------------------------
printf '== verdict parse (parse_verdict) ==\n'
[ "$(parse_verdict 'VERDICT: pass')" = pass ] && ok || bad "pass parse"
[ "$(parse_verdict 'reasoning...
VERDICT: FAIL')" = fail ] && ok || bad "fail parse (multiline, uppercase)"
[ "$(parse_verdict 'VERDICT: Pass — solves the ticket')" = pass ] && ok || bad "pass parse (trailing text)"
[ "$(parse_verdict 'no verdict at all')" = fail ] && ok || bad "unparseable should default to fail"
[ "$(parse_verdict 'VERDICT: maybe')" = fail ] && ok || bad "unknown value should default to fail"

# --- 6d. blocker parse ----------------------------------------------------------
printf '== blocker parse (parse_blockers) ==\n'
# helper: join parsed blocker numbers with commas for a stable comparison
pb() { parse_blockers "$1" | paste -sd, -; }
[ "$(pb 'Blocked-by: #96, #97')" = "96,97" ]                        && ok || bad "inline form"
[ "$(pb '## Blocked by

- #97')" = "97" ]                                              && ok || bad "section form (single)"
[ "$(pb '## Blocked by

- #96
- #97

## Acceptance')" = "96,97" ]                                  && ok || bad "section form (list, bounded by next header)"
[ -z "$(pb '## Blocked by

None - can start immediately')" ]                              && ok || bad "section 'None' yields no blockers"
[ -z "$(pb 'this unblocks #99 later but is not itself blocked')" ]  && ok || bad "stray #ref outside marker is ignored"
[ "$(pb '## Blocked by

- #97
- #97')" = "97" ]                                              && ok || bad "duplicate refs deduped"

# --- 6e. PR closing-trailer check (body_closes_issue) ---------------------------
printf '== closing trailer (body_closes_issue) ==\n'
bc() { body_closes_issue "$1" "$2" && echo yes || echo no; }
[ "$(bc 'Some body

Closes #96' 96)" = yes ]                              && ok || bad "Closes #96"
[ "$(bc 'fixes #96' 96)" = yes ]                                       && ok || bad "fixes (lowercase)"
[ "$(bc 'This Resolves #96 nicely' 96)" = yes ]                        && ok || bad "Resolves mid-line"
[ "$(bc 'Closed #96' 96)" = yes ]                                      && ok || bad "Closed variant"
[ "$(bc 'Closes #960' 96)" = no ]                                      && ok || bad "#960 must not satisfy #96 (word boundary)"
[ "$(bc 'See #96 for context' 96)" = no ]                              && ok || bad "bare ref without keyword is not a close"
[ "$(bc 'Closes #97' 96)" = no ]                                       && ok || bad "closes a different issue"
[ "$(bc '' 96)" = no ]                                                 && ok || bad "empty body"

# --- 6f. PR Ralph-state classifier ----------------------------------------------
printf '== PR state (classify_pr) ==\n'
# Literal epochs, no clock dependency. Titles use $HUMAN_LABEL so the
# "[ready-for-human] " convention matches exactly how a handback writes it.
H="$HUMAN_LABEL"
cs() { classify_pr "$1" "$2" "$3" "$4"; }
[ "$(cs 1 'feat: x' '' '')" = working ]                && ok || bad "draft, no marker -> working"
[ "$(cs 1 "[$H] feat: x" '' '')" = handback ]          && ok || bad "draft + [HUMAN] -> handback"
[ "$(cs 0 "[$H] feat: x" 100 50)" = handback ]         && ok || bad "[HUMAN] title beats marker -> handback"
[ "$(cs 0 'feat: x' 100 '')" = approved ]              && ok || bad "marker + no commit -> approved (trust-marker)"
[ "$(cs 0 'feat: x' 100 90)" = approved ]              && ok || bad "marker, commit before -> approved"
[ "$(cs 0 'feat: x' 100 100)" = approved ]             && ok || bad "marker, commit == marker -> approved (<= boundary)"
[ "$(cs 0 'feat: x' 100 110)" = human ]                && ok || bad "commit after marker -> human (safety property)"
[ "$(cs 0 'feat: x' '' '')" = human ]                  && ok || bad "non-draft + no marker -> human (not approved)"
[ "$(cs 1 'feat: x' 100 90)" = working ]               && ok || bad "draft is never approved -> working"

# --- 7. pre-merge secret scan ---------------------------------------------------
printf '== secret scan (diff_has_secret) ==\n'
scases="$HERE/eval/secret-cases.tsv"
if [ -f "$scases" ]; then
  while IFS=$'\t' read -r expect line; do
    case "$expect" in ''|'#'*) continue ;; esac
    if diff_has_secret "$line"; then got=secret; else got=safe; fi
    if [ "$got" = "$expect" ]; then ok; else bad "secret scan expected $expect, got $got — $line"; fi
  done < "$scases"
else
  bad "fixtures missing: $scases"
fi
# Provider-shaped tokens (GitHub / Slack / Google) — assembled from fragments so
# the contiguous key pattern never appears in the repo source and upstream secret
# scanners (e.g. GitGuardian) don't flag this fixture, while still exercising the
# matching branches of diff_has_secret at runtime.
gh_tok="ghp_""aBcD1234567890aBcD1234567890aBcD12"
sl_tok="xox""b-123456789012-abcdefABCDEF"
gg_tok="AIza""SyA1234567890abcdefghijklmnopqrstuv"
for tok in "$gh_tok" "$sl_tok" "$gg_tok"; do
  if diff_has_secret "$tok"; then ok; else bad "provider token should be flagged: ${tok:0:6}…"; fi
done
# Disabled scanner must flag nothing (opt-out honoured).
if RALPH_SECRET_SCAN=0 diff_has_secret 'AKIAIOSFODNN7EXAMPLE'; then bad "disabled scanner should not flag"; else ok; fi

# --- 8. stage policy resolver ---------------------------------------------------
# Pin the role→policy table that run_stage and eval-agents both resolve through, so
# a future edit to one role's flag bag can't silently drift from the others.
printf '== stage policy (stage_policy) ==\n'
# sp <role> <key> — print the value of one key=value line from stage_policy.
sp() { stage_policy "$1" | grep -m1 "^$2=" | cut -d= -f2-; }

# implement is the sandboxed writer: sandbox on, edits accepted, IMPL_DISALLOW carried.
[ "$(sp implement sandbox)" = 1 ]                    && ok || bad "implement sandbox=1"
[ "$(sp implement accept_edits)" = 1 ]               && ok || bad "implement accept_edits=1"
printf '%s' "$(sp implement disallow)" | grep -q 'gh pr merge' && ok || bad "implement disallow carries IMPL_DISALLOW"

# Readers (review, verify, rubric) accept no edits and hold no write tools.
[ "$(sp review accept_edits)" = 0 ]                  && ok || bad "review accept_edits=0"
[ "$(sp verify accept_edits)" = 0 ]                  && ok || bad "verify accept_edits=0"
for r in review verify rubric; do
  t="$(sp "$r" tools)"
  printf '%s' "$t" | grep -qw Edit         && bad "$r tools must not contain Edit"        || ok
  printf '%s' "$t" | grep -qw Write        && bad "$r tools must not contain Write"       || ok
  printf '%s' "$t" | grep -q 'gh pr merge' && bad "$r tools must not contain gh pr merge" || ok
  printf '%s' "$t" | grep -q 'git push'    && bad "$r tools must not allow push"          || ok
done

# Every writer (implement, fix, conflict) carries IMPL_DISALLOW + accepts edits.
for w in implement fix conflict; do
  printf '%s' "$(sp "$w" disallow)" | grep -q 'gh pr merge' && ok || bad "$w must carry IMPL_DISALLOW"
  [ "$(sp "$w" accept_edits)" = 1 ]                          && ok || bad "$w accept_edits=1"
  [ "$(sp "$w" sandbox)" = 1 ]                               && ok || bad "$w sandbox=1"
done

# No role may drop the base capability boundary (INJECTION_GUARD).
for r in implement fix conflict pr review verify rubric; do
  [ "$(sp "$r" guard_has_base)" = 1 ] && ok || bad "$r must carry base INJECTION_GUARD"
done

# Role -> model-tier map: pin which MODEL_* var each stage runs on, so a config
# drift (e.g. silently moving the reviewer onto the implementer's tier) is caught.
[ "$(sp implement model_var)" = MODEL_IMPLEMENT ] && ok || bad "implement -> MODEL_IMPLEMENT"
[ "$(sp fix model_var)" = MODEL_FIX ]           && ok || bad "fix -> MODEL_FIX"
[ "$(sp conflict model_var)" = MODEL_CONFLICT ] && ok || bad "conflict -> MODEL_CONFLICT"
[ "$(sp pr model_var)" = MODEL_PR ]             && ok || bad "pr -> MODEL_PR"
[ "$(sp review model_var)" = MODEL_REVIEW ]     && ok || bad "review -> MODEL_REVIEW"
[ "$(sp verify model_var)" = MODEL_VERIFY ]     && ok || bad "verify -> MODEL_VERIFY"
[ "$(sp rubric model_var)" = MODEL_REVIEW ]     && ok || bad "rubric -> MODEL_REVIEW"

# Unknown role fails loudly (fail-safe, like parse_verdict).
if stage_policy bogus-role >/dev/null 2>&1; then bad "unknown role must fail"; else ok; fi

# --- 9. review outcome classifier -------------------------------------------------
# Pin the pure decision half of review_and_resolve (the same classifier/adapter
# split as classify_pr): threads > gate > secret > approved, failing safe on an
# unreadable thread count.
printf '== review outcome (review_outcome) ==\n'
[ "$(review_outcome 1 0 1 1)" = approved ]  && ok || bad "clean review + gate + scan -> approved"
[ "$(review_outcome 0 0 1 1)" = threads ]   && ok || bad "inconclusive review -> threads (never approve on a crashed reviewer)"
[ "$(review_outcome 1 3 1 1)" = threads ]   && ok || bad "open threads -> threads"
[ "$(review_outcome 1 0 0 1)" = gate ]      && ok || bad "red gate -> gate"
[ "$(review_outcome 1 0 1 0)" = secret ]    && ok || bad "leaked secret -> secret"
[ "$(review_outcome 1 '' 1 1)" = threads ]  && ok || bad "unreadable thread count fails safe -> threads"
[ "$(review_outcome 1 3 0 0)" = threads ]   && ok || bad "threads win over gate/secret (precedence)"

# --- 10. retry budget --------------------------------------------------------------
# Pin the shared return protocol (0 keep going, 1 attempt cap, 3 infra strikes,
# 4 wall clock) that every AFK retry loop routes on.
printf '== retry budget (budget_*) ==\n'
budget_start 2 0
budget_attempt; [ "$?" = 0 ]  && ok || bad "attempt 1/2 keeps going"
budget_attempt; [ "$?" = 1 ]  && ok || bad "attempt 2/2 returns 1 (cap)"
budget_start 0 0
budget_attempt; budget_attempt; budget_attempt
[ "$?" = 0 ]                  && ok || bad "max_attempts=0 is unlimited"
[ "$(budget_attempts)" = 3 ]  && ok || bad "attempts counted (got $(budget_attempts))"
budget_start 3 0
budget_charge 3; [ "$?" = 1 ] && ok || bad "charge k cycles hits the cap"
budget_start 0 0
RALPH_INFRA_RETRIES=2 budget_strike; [ "$?" = 0 ] && ok || bad "strike 1/2 keeps going"
RALPH_INFRA_RETRIES=2 budget_strike; [ "$?" = 3 ] && ok || bad "strike 2/2 returns 3 (infra)"
budget_strike_reset
RALPH_INFRA_RETRIES=2 budget_strike; [ "$?" = 0 ] && ok || bad "strike streak resets on progress"
budget_start 5 0
budget_check; [ "$?" = 0 ]    && ok || bad "fresh budget checks clean"

# --- 10b. toolchain-agnostic gate wiring ---------------------------------------
# Ralph shells out to config.sh commands and assumes no toolchain. Pin the two
# pure deciders so a node assumption cannot creep back in.
printf '== gate wiring (gate_cmds_text, needs_setup) ==\n'
(
  LINT_CMD="npm run lint"; TEST_CMD="npm test"
  [ "$(gate_cmds_text)" = "'npm run lint' and 'npm test'" ] && exit 0 || exit 1
) && ok || bad "gate_cmds_text joins both commands"
( LINT_CMD=""; TEST_CMD="go test ./..."; [ "$(gate_cmds_text)" = "'go test ./...'" ] ) \
  && ok || bad "gate_cmds_text drops an empty LINT_CMD"
( LINT_CMD="cargo clippy"; TEST_CMD=""; [ "$(gate_cmds_text)" = "'cargo clippy'" ] ) \
  && ok || bad "gate_cmds_text drops an empty TEST_CMD"
( LINT_CMD=""; TEST_CMD=""; printf '%s' "$(gate_cmds_text)" | grep -q "''" ) \
  && bad "gate_cmds_text must not emit empty quotes when both are unset" || ok

sfix="$(mktemp -d)"
(
  cd "$sfix" || exit 1
  SETUP_CMD=""; SETUP_MARKER=""; SETUP_LOCK=""
  needs_setup && exit 1                                  # no SETUP_CMD: never
  SETUP_CMD="npm ci"
  needs_setup || exit 1                                  # no marker: always
  SETUP_MARKER="deps"
  needs_setup || exit 1                                  # marker missing
  mkdir -p deps
  needs_setup || exit 1                                  # marker EMPTY (docker mountpoint)
  touch deps/installed
  needs_setup && exit 1                                  # marker populated
  SETUP_LOCK="lock"; touch lock
  needs_setup || exit 1                                  # lock newer than marker
  touch deps
  needs_setup && exit 1                                  # marker newer than lock
  exit 0
) && ok || bad "needs_setup: marker/lock staleness rules"
rm -rf "$sfix"

# No entry point may hardcode a toolchain: every command comes from config.sh.
for f in "$HERE"/lib.sh "$HERE"/process-issue.sh "$HERE"/run.sh "$HERE"/resolve-conflicts.sh; do
  grep -nE '(^|[^A-Za-z_-])(npm|npx|yarn|pnpm|cargo|bundle|pytest|gradlew)([^A-Za-z_-]|$)' "$f" \
    | grep -v '^[0-9]*:[[:space:]]*#' | grep -q . \
    && bad "$(basename "$f") hardcodes a toolchain command outside a comment" || ok
done

# --- 11. metrics outcome vocabulary -------------------------------------------------
# Pin the one outcome enum record_metric validates and status.sh iterates.
printf '== outcome vocabulary (metric_outcome_valid) ==\n'
for o in approved handback verify-fail implement-error test-fail pr-failed escalated \
         secret-detected ci-fail conflict-unresolved budget-exceeded; do
  metric_outcome_valid "$o" && ok || bad "outcome '$o' must be in RALPH_OUTCOMES"
done
metric_outcome_valid bogus-outcome && bad "unknown outcome must be invalid" || ok

# Pin the readers against a fixture CSV — no network, no live metrics file.
mfix="$(mktemp)"
printf '%s\n' \
  '2026-01-01T00:00:00Z,1,approved,2,600,' \
  '2026-01-02T00:00:00Z,2,handback,3,,review did not converge' \
  '2026-01-03T00:00:00Z,3,approved,1,300,' > "$mfix"
metrics_summary "$mfix" | grep -q 'total rows: 3'                    && ok || bad "metrics_summary row count"
metrics_summary "$mfix" | grep -q 'approval rate: 66.7%'             && ok || bad "metrics_summary approval rate"
[ "$(metrics_recent 1 "$mfix")" = '2026-01-03T00:00:00Z,3,approved,1,300,' ] && ok || bad "metrics_recent tail"
metrics_handbacks 10 "$mfix" | grep -q 'review did not converge'     && ok || bad "metrics_handbacks reason"
rm -f "$mfix"

# --- 12. approve_pr marker idempotency (stubbed gh) --------------------------------
# The second adapter at the gh seam: a PATH-stubbed gh serving canned reads and
# recording writes, still offline. Pins the regression this repo already shipped
# once: approve_pr must read the approval marker through pr_fields (comments from
# the END) and must NOT post a duplicate marker when one is present.
printf '== approve_pr marker idempotency (stubbed gh) ==\n'
stubd="$(mktemp -d)"
cat > "$stubd/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    case "$*" in
      *"--json number"*) echo 42 ;;
      *"--json title"*)  echo "feat: x" ;;
    esac ;;
  "pr comment") echo "comment $*" >> "$GH_STUB_LOG" ;;
  "api graphql")
    if [ "${GH_STUB_MARKER:-0}" = 1 ]; then
      printf '{"data":{"repository":{"pullRequest":{"isDraft":false,"title":"feat: x","comments":{"nodes":[{"body":"%s — all done","createdAt":"2026-01-01T00:00:00Z"}]},"commits":{"nodes":[{"commit":{"committedDate":"2025-12-31T00:00:00Z"}}]}}}}}' "$APPROVAL_MARKER"
    else
      printf '{"data":{"repository":{"pullRequest":{"isDraft":false,"title":"feat: x","comments":{"nodes":[]},"commits":{"nodes":[{"commit":{"committedDate":"2025-12-31T00:00:00Z"}}]}}}}}'
    fi ;;
  *) : ;;
esac
STUB
chmod +x "$stubd/gh"
export APPROVAL_MARKER GH_STUB_LOG="$stubd/writes.log"
: > "$GH_STUB_LOG"
PATH="$stubd:$PATH" GH_STUB_MARKER=1 approve_pr "https://example/pr/42" 7 /dev/null
[ ! -s "$GH_STUB_LOG" ] && ok || bad "approve_pr must NOT re-post an existing approval marker"
: > "$GH_STUB_LOG"
PATH="$stubd:$PATH" GH_STUB_MARKER=0 approve_pr "https://example/pr/42" 7 /dev/null
grep -q '^comment' "$GH_STUB_LOG" && ok || bad "approve_pr must post the marker when absent"
rm -rf "$stubd"

# --- 11b. the branch must never be silently unpublished --------------------------
# A plain `git push || true` at three sites hid a rejected push. When a stage
# rebased the branch the push was non-fast-forward, the PR head stayed behind, and
# every later review round re-posted findings the local code had already fixed.
printf '== push_branch (rejected push is never swallowed) ==\n'
stubd="$(mktemp -d)"; : > "$stubd/calls"
cat > "$stubd/git" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_CALLS"
case "$1 $2" in
  "push origin")                 [ "${STUB_REJECT:-0}" = 1 ] && exit 1 || exit 0 ;;
  "rev-parse refs/remotes/"*)    echo deadbeefcafe ;;
  "push --force-with-lease"*)    [ "${STUB_FORCE_FAILS:-0}" = 1 ] && exit 1 || exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$stubd/git"
export STUB_CALLS="$stubd/calls"
pb() { : > "$STUB_CALLS"; PATH="$stubd:$PATH" push_branch issue/7 7 /dev/null; }
STUB_REJECT=0 pb && ok || bad "a clean push must succeed"
grep -qv 'force-with-lease' "$STUB_CALLS" && ok || bad "a clean push must not force"
STUB_REJECT=1 STUB_FORCE_FAILS=0 pb && ok || bad "a rejected push must be retried with --force-with-lease"
grep -q 'force-with-lease' "$STUB_CALLS" && ok || bad "the retry must carry a lease, never a bare --force"
STUB_REJECT=1 STUB_FORCE_FAILS=1 pb && bad "a branch that stayed unpublished must FAIL, not return 0" || ok
unset STUB_CALLS; rm -rf "$stubd"
grep -q 'push_branch' "$HERE/process-issue.sh"  && ok || bad "process-issue must publish through push_branch"
! grep -q 'git push origin "$branch" >>"$ilog" 2>&1 || true' "$HERE/lib.sh" \
  && ok || bad "no push site may swallow its failure with || true"

# --- 12a. sandbox credential passthrough (offline, array-only) ---------------------
# The writer sandbox must inherit the agent's credentials and endpoint BY NAME.
# A value on the docker command line would land in the process table and in every
# log that echoes the command, and an unset name passed anyway makes the CLI read
# an empty value and fall back silently.
printf '== sandbox env passthrough (sandbox_impl_cmd) ==\n'
stub_out="$(mktemp)"
( export ANTHROPIC_BASE_URL=https://example.invalid/anthropic ANTHROPIC_AUTH_TOKEN=tok-do-not-leak
  unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_MODEL
  declare -a sc; sandbox_impl_cmd /tmp/eval-wt sc
  printf '%s\n' "${sc[@]}" > "$stub_out" )
grep -qx 'ANTHROPIC_BASE_URL' "$stub_out"   && ok || bad "a set endpoint var must be passed by name"
grep -qx 'ANTHROPIC_AUTH_TOKEN' "$stub_out" && ok || bad "a set credential var must be passed by name"
! grep -q 'tok-do-not-leak' "$stub_out"     && ok || bad "a credential VALUE must never reach the docker command line"
! grep -qx 'ANTHROPIC_API_KEY' "$stub_out"  && ok || bad "an unset var must be dropped, not passed empty"
rm -f "$stub_out"; unset stub_out

# --- 12b. review rounds: the reviewer's memory lives on the PR ---------------------
# next_round/last_round_sha decide which round a pass claims and which commit it
# diffs against. Getting either wrong un-does the convergence property: a repeated
# round number, or an empty fixed point, sends the reviewer back over the whole
# diff with fresh eyes — the failure this replaced.
printf '== review rounds (next_round, last_round_sha) ==\n'
r2="$(printf '1\t81aaaba\n2\t82b533ac\n')"
[ "$(next_round "")" = 1 ]                    && ok || bad "no rounds recorded -> round 1"
[ -z "$(last_round_sha "")" ]                 && ok || bad "no rounds recorded -> no fixed point"
[ "$(next_round "$r2")" = 3 ]                 && ok || bad "two rounds -> round 3"
[ "$(last_round_sha "$r2")" = 82b533ac ]      && ok || bad "fixed point is the highest round's sha"
# Highest+1, not count+1: a dropped or duplicated journal comment must never let
# two passes claim the same round.
[ "$(next_round "$(printf '1\taaaaaaa\n3\tccccccc\n')")" = 4 ]      && ok || bad "gap in the rounds -> highest+1"
[ "$(last_round_sha "$(printf '3\tccccccc\n1\taaaaaaa\n')")" = ccccccc ] && ok || bad "out-of-order rounds -> highest wins"
[ "$(next_round "$(printf '2\tbbbbbbb\n2\tbbbbbbb\n')")" = 3 ]      && ok || bad "duplicated round -> highest+1"
[ "$(next_round "$(printf 'garbage line\n')")" = 1 ]                   && ok || bad "unparseable input -> round 1"

printf '== reviewer memory + scope guardrail (prompts) ==\n'
lib="$HERE/lib.sh"; pi="$HERE/process-issue.sh"; ts="$HERE/threads.sh"
grep -q 'history) _history' "$ts"                    && ok || bad "threads.sh must expose the full thread history"
grep -q 'journal)' "$ts"                             && ok || bad "threads.sh must expose the round journal"
grep -q 'rounds)' "$ts"                              && ok || bad "threads.sh must expose the recorded rounds"
grep -q 'hist="\$("\$threads_sh" history' "$lib"     && ok || bad "review_pass must read the thread history"
grep -q 'rounds="\$("\$threads_sh" rounds' "$lib"    && ok || bad "review_pass must read its earlier rounds"
grep -q 'git diff \$prev_sha\.\.\.HEAD' "$lib"        && ok || bad "a later round must diff from the previous round's commit"
grep -q 'journal \$pr_num \$round \$head_sha' "$lib"  && ok || bad "a review pass must journal the round it just ran"
grep -q 'VERIFY_REASON' "$lib"                       && ok || bad "the verifier must hand its reasons back"
grep -q 'VERIFY_REASON' "$pi"                        && ok || bad "the rebuild prompt must carry the verifier's reasons"
grep -q 'name the criterion that asks for it' "$pi"  && ok || bad "the implement prompt must carry the scope rule"
grep -q 'Judge SCOPE as the second axis' "$lib"      && ok || bad "the verifier must judge scope"

# --- 13. resume an issue whose PR is already open (stubbed gh + source) ------------
# Pins the regression: a hand-run `ralph process-issue N` used to gate the
# open-PR check on a LOCAL refs/heads/issue/N, which cleanup() deletes on every
# exit — so the second run re-cut the branch from the base and abandoned the
# PR's commits. The decision must come from the PR listing alone.
printf '== resume on an open PR (open_pr_num + process-issue) ==\n'
stubd="$(mktemp -d)"
cat > "$stubd/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list")
    case "${GH_STUB_PRS:-none}" in
      none) : ;;
      fail) exit 1 ;;
      *)    printf '%s\n' $GH_STUB_PRS ;;
    esac ;;
  *) : ;;
esac
STUB
chmod +x "$stubd/gh"
opn() { PATH="$stubd:$PATH" GH_STUB_PRS="$1" open_pr_num 62; }
hop() { PATH="$stubd:$PATH" GH_STUB_PRS="$1" has_open_pr 62 && echo yes || echo no; }
[ -z "$(opn none)" ]        && ok || bad "no open PR must read empty"
[ "$(opn 70)" = 70 ]        && ok || bad "one open PR must read its number"
[ "$(opn '70 71')" = 70 ]   && ok || bad "several open PRs must read the first (no pipefail abort)"
[ -z "$(opn fail)" ]        && ok || bad "a failing gh must read empty, not abort"
[ "$(hop none)" = no ]      && ok || bad "has_open_pr must agree with open_pr_num (none)"
[ "$(hop 70)" = yes ]       && ok || bad "has_open_pr must agree with open_pr_num (open)"
rm -rf "$stubd"
pi="$HERE/process-issue.sh"
grep -q 'RESUME_PR="\$(gh pr view' "$pi" \
  && ok || bad "process-issue must resolve the open PR into RESUME_PR"
grep -q 'worktree_enter_branch "\$wt"' "$pi" \
  && ok || bad "a resumed issue must branch from origin/issue/N, not the base"
! grep -q 'show-ref --quiet "refs/heads/\$branch"' "$pi" \
  && ok || bad "the resume decision must not depend on a local branch ref (cleanup deletes it)"

# --- summary --------------------------------------------------------------------
printf '\n== eval: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
