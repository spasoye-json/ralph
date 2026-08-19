#!/usr/bin/env bash
# ralph/link-skills.sh — make the /implement, /tdd and /code-review skills
# resolve as personal skills (~/.claude/skills), sourced from the newest
# installed mattpocock-skills Claude Code plugin. Personal-skill symlinks
# resolve identically on the host and inside the implementer sandbox (lib.sh
# mounts each link target read-only), and a personal skill outranks the
# plugin namespace, so the bare /implement form in the stage prompts always
# resolves. Idempotent — re-run after `claude plugin update mattpocock-skills`
# so the links follow the new version directory.
set -euo pipefail

SKILLS=(implement tdd code-review)
DEST="$HOME/.claude/skills"
INSTALLED="$HOME/.claude/plugins/installed_plugins.json"

# Resolve the plugin's install path from the install metadata; fall back to the
# newest matching cache directory when the metadata is missing or unreadable.
src=""
if [ -f "$INSTALLED" ] && command -v jq >/dev/null 2>&1; then
  src="$(jq -r '.plugins | to_entries[]
                | select(.key | startswith("mattpocock-skills@"))
                | .value[0].installPath // empty' "$INSTALLED" 2>/dev/null | head -n1)"
  [ -n "$src" ] && src="$src/skills/engineering"
fi
if [ ! -d "${src:-/nonexistent}" ]; then
  src="$(ls -dt "$HOME"/.claude/plugins/cache/*/mattpocock-skills/*/skills/engineering 2>/dev/null | head -n1 || true)"
fi
[ -d "${src:-/nonexistent}" ] || {
  echo "link-skills: mattpocock-skills plugin not found under ~/.claude/plugins" >&2
  echo "link-skills: install it first: claude plugin install mattpocock-skills@claude-plugins-official" >&2
  exit 1
}

mkdir -p "$DEST"
for s in "${SKILLS[@]}"; do
  tgt="$src/$s"
  [ -r "$tgt/SKILL.md" ] || { echo "link-skills: $tgt/SKILL.md missing — plugin layout changed?" >&2; exit 1; }
  cur="$DEST/$s"
  if [ -L "$cur" ]; then
    ln -sfn "$tgt" "$cur"
  elif [ -e "$cur" ]; then
    echo "link-skills: $cur exists and is not a symlink — left alone (it outranks the plugin)" >&2
    continue
  else
    ln -s "$tgt" "$cur"
  fi
  echo "linked $cur -> $tgt"
done
