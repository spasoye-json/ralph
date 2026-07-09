#!/usr/bin/env bash
# ralph/config.sh — project wiring. Edit this file when dropping ralph into a
# project. Every value is env-overridable (env wins over what is written here).
# Sourced by lib.sh (all entry points) and status.sh; keep it side-effect free.

# GitHub triage labels (Matt Pocock vocabulary). Must exist on the repo.
READY_LABEL="${READY_LABEL:-ready-for-agent}"   # the queue: issues the AFK agent may pick up
WORKING_LABEL="${WORKING_LABEL:-claude-working}" # transient "in progress" marker
HUMAN_LABEL="${HUMAN_LABEL:-ready-for-human}"    # handback: issues a human must handle

# Branch PRs target and merge into.
BASE_BRANCH="${BASE_BRANCH:-main}"

# Objective quality gate: the package dir (relative to the repo root) the gate
# runs in, and the lint/test commands it runs there. These also appear verbatim
# in the agent prompts, so keep them copy-pasteable shell commands.
TEST_DIR="${TEST_DIR:-.}"
LINT_CMD="${LINT_CMD:-npm run lint}"
TEST_CMD="${TEST_CMD:-npm test}"

# Docker image tag for the implementer sandbox (built from ralph/sandbox).
RALPH_SANDBOX_IMAGE="${RALPH_SANDBOX_IMAGE:-ralph-impl}"

# Package dirs (relative to the repo root) whose node_modules are bind-mounted
# read-only into the sandbox worktree so the offline implementer can lint/test.
# List every workspace package the gate touches; missing dirs are skipped.
RALPH_NM_DIRS=(".")
if [ "$TEST_DIR" != "." ]; then RALPH_NM_DIRS+=("$TEST_DIR"); fi
