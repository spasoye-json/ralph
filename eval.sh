#!/usr/bin/env bash
# ralph/eval.sh — offline regression harness for Ralph's deterministic guard
# logic. A small evaluation harness is the highest-leverage thing here: the
# pure-bash decisions silently regress when a prompt or guard is edited, so they
# need pinning. Ralph's metrics track live outcomes; this pins the rest. It runs
# NO agents and makes no network calls; it asserts:
#   - the capability boundary (INJECTION_GUARD) is present and prohibits the key actions
#   - the correctness-verdict parse, escalation sentinel, secret scan
# Run it before and after changing any guard/prompt logic:  ./ralph/eval.sh
# Exit status is non-zero if any assertion fails (usable as a CI/pre-push gate).

export RALPH_REQUIRE_ALLOWLIST=0   # tests pure functions; no allowlist to offer
export RALPH_TRIM_MCP=0            # offline: never shell out to `claude --help` for the strict-mcp-config probe
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

# tdd is the sandboxed writer: sandbox on, edits accepted, IMPL_DISALLOW carried.
[ "$(sp tdd sandbox)" = 1 ]                          && ok || bad "tdd sandbox=1"
[ "$(sp tdd accept_edits)" = 1 ]                     && ok || bad "tdd accept_edits=1"
printf '%s' "$(sp tdd disallow)" | grep -q 'gh pr merge' && ok || bad "tdd disallow carries IMPL_DISALLOW"

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

# Every writer (tdd, fix, conflict) carries IMPL_DISALLOW + accepts edits.
for w in tdd fix conflict; do
  printf '%s' "$(sp "$w" disallow)" | grep -q 'gh pr merge' && ok || bad "$w must carry IMPL_DISALLOW"
  [ "$(sp "$w" accept_edits)" = 1 ]                          && ok || bad "$w accept_edits=1"
done

# No role may drop the base capability boundary (INJECTION_GUARD).
for r in tdd fix conflict pr review verify rubric; do
  [ "$(sp "$r" guard_has_base)" = 1 ] && ok || bad "$r must carry base INJECTION_GUARD"
done

# Role -> model-tier map: pin which MODEL_* var each stage runs on, so a config
# drift (e.g. silently moving the reviewer onto the implementer's tier) is caught.
[ "$(sp tdd model_var)" = MODEL_TDD ]           && ok || bad "tdd -> MODEL_TDD"
[ "$(sp fix model_var)" = MODEL_FIX ]           && ok || bad "fix -> MODEL_FIX"
[ "$(sp conflict model_var)" = MODEL_CONFLICT ] && ok || bad "conflict -> MODEL_CONFLICT"
[ "$(sp pr model_var)" = MODEL_PR ]             && ok || bad "pr -> MODEL_PR"
[ "$(sp review model_var)" = MODEL_REVIEW ]     && ok || bad "review -> MODEL_REVIEW"
[ "$(sp verify model_var)" = MODEL_VERIFY ]     && ok || bad "verify -> MODEL_VERIFY"
[ "$(sp rubric model_var)" = MODEL_REVIEW ]     && ok || bad "rubric -> MODEL_REVIEW"

# Unknown role fails loudly (fail-safe, like parse_verdict).
if stage_policy bogus-role >/dev/null 2>&1; then bad "unknown role must fail"; else ok; fi

# --- summary --------------------------------------------------------------------
printf '\n== eval: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
