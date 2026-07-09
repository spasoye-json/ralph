#!/usr/bin/env bash
# ralph/threads.sh — GitHub PR review-thread helpers (resolvable findings).
#
# The review loop posts each finding as an inline review thread (which has a
# resolved/unresolved state) and the *next* reviewer resolves the ones that are
# genuinely fixed. The verdict is derived from the unresolved count, not a parsed
# keyword. Used by the orchestrator (list/count) and by the review agent
# (resolve/comment) — hence it's referenced by absolute path and allowlisted.
#
# Subcommands:
#   list <pr>                          unresolved threads: "<id>\t<path>:<line>\t<finding>"
#   count <pr>                         number of unresolved threads
#   resolve <threadId>                 mark a thread resolved
#   comment <pr> <path> <line> <body>  post an inline finding (creates a thread)

set -euo pipefail

read -r OWNER REPO < <(gh repo view --json owner,name -q '"\(.owner.login) \(.name)"')

cmd="${1:?usage: threads.sh list|count|resolve|comment ...}"; shift

_list() {
  local resp
  resp="$(gh api graphql -F owner="$OWNER" -F repo="$REPO" -F pr="$1" -f query='
    query($owner:String!,$repo:String!,$pr:Int!){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$pr){
          reviewThreads(first:100){ pageInfo{hasNextPage} nodes{ id isResolved path line comments(first:1){nodes{body}} } }
        }}}')"
  if [ "$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')" = "true" ]; then
    echo "threads.sh: WARNING — PR $1 has >100 review threads; only the first 100 are counted (verdict may be wrong)." >&2
  fi
  printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved==false)
        | "\(.id)\t\(.path // "?"):\(.line // "?")\t\((.comments.nodes[0].body // "") | gsub("[\r\n]+";" "))"'
}

case "$cmd" in
  list)    _list "${1:?pr}" ;;
  count)   _list "${1:?pr}" | grep -c . || true ;;
  resolve)
    gh api graphql -F id="${1:?threadId}" -f query='
      mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' >/dev/null
    echo "resolved ${1}"
    ;;
  comment)
    pr="${1:?pr}"; path="${2:?path}"; line="${3:?line}"; body="${4:?body}"
    sha="$(gh pr view "$pr" --json headRefOid -q .headRefOid)"
    # A failed post must NOT look like success: an unposted finding silently drops
    # the unresolved-thread count and can let a real problem pass review. Surface
    # the error and exit non-zero so the reviewer retries with a valid diff line.
    if ! err="$(gh api "repos/$OWNER/$REPO/pulls/$pr/comments" \
          -f body="$body" -f commit_id="$sha" -f path="$path" -F line="$line" -f side=RIGHT 2>&1 >/dev/null)"; then
      echo "threads.sh: FAILED to post finding on $path:$line — it was NOT recorded as a review thread." >&2
      echo "  $err" >&2
      echo "  Pick a <line> that appears on the RIGHT (added/context) side of 'gh pr diff $pr' and retry." >&2
      exit 1
    fi
    echo "posted finding on $path:$line"
    ;;
  *) echo "unknown subcommand: $cmd" >&2; exit 2 ;;
esac
