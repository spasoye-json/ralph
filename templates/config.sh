# .ralph/config.sh — this project's ralph wiring. Commit it.
#
# Only write what differs from the packaged defaults: lib.sh sources this file
# first and the install's config.sh second, so anything left out keeps its
# default, and a knob added in a later ralph version needs no edit here.
# Keep the ${VAR:-value} idiom so an env var still overrides a run.
# Run `ralph config` to print every resolved value.

# Branch PRs target and merge into.
BASE_BRANCH="${BASE_BRANCH:-main}"

# The objective quality gate. The orchestrator runs these in TEST_DIR, so
# approval never depends on an agent's own "tests pass" claim. An EMPTY command
# is skipped, by the gate and by the agent prompts alike. Leaving BOTH empty
# makes the gate a no-op and ralph warns every cycle.
TEST_DIR="${TEST_DIR:-.}"
LINT_CMD="${LINT_CMD:-}"
TEST_CMD="${TEST_CMD:-}"

# Dependency install, run in TEST_DIR before the gate. SETUP_MARKER is the
# directory it populates: the install re-runs when that directory is missing or
# empty, or when SETUP_LOCK is newer than it. Leave SETUP_MARKER empty to run
# SETUP_CMD every cycle, which is right only when the install is a cheap no-op
# when warm (`go mod download`), not when it is not (`npm ci`).
SETUP_CMD="${SETUP_CMD:-}"
SETUP_MARKER="${SETUP_MARKER:-}"
SETUP_LOCK="${SETUP_LOCK:-}"

# Advisory dependency audit, run when RALPH_AUDIT=1. Logged, never blocks a PR.
AUDIT_CMD="${AUDIT_CMD:-}"

# In-repo dependency caches bind-mounted read-only into the sandbox worktree, so
# the agent can lint and test without network. Every WORKSPACE x DEP pair that
# exists on the host is mounted at the same relative path; missing pairs are
# skipped. List every workspace package the gate touches.
RALPH_WORKSPACE_DIRS=(".")
RALPH_DEP_DIRS=()

# Toolchain caches outside the repo, in the container's throwaway $HOME. Each
# entry is one `docker -v` spec. Use a NAMED VOLUME, never a host path: a host
# path hands the sandboxed agent a writable directory on your machine, which is
# the thing the sandbox exists to prevent.
RALPH_CACHE_MOUNTS=()

# Base image the sandbox is built FROM, i.e. this project's toolchain.
# `ralph sandbox-build` passes it as the BASE_IMAGE build arg.
RALPH_SANDBOX_BASE="${RALPH_SANDBOX_BASE:-debian:bookworm-slim}"

# GitHub triage labels. They must already exist on the repo.
# READY_LABEL="${READY_LABEL:-ready-for-agent}"
# WORKING_LABEL="${WORKING_LABEL:-claude-working}"
# HUMAN_LABEL="${HUMAN_LABEL:-ready-for-human}"

# --- Per-language recipes ----------------------------------------------------
# Copy the block for your stack over the values above.
#
# Node (npm):
#   LINT_CMD="npm run lint"; TEST_CMD="npm test"
#   SETUP_CMD="npm ci"; SETUP_MARKER="node_modules"; SETUP_LOCK="package-lock.json"
#   AUDIT_CMD="npm audit --audit-level=high"
#   RALPH_DEP_DIRS=(node_modules)
#   docker build -t ralph-impl --build-arg BASE_IMAGE=node:22-bookworm ralph/sandbox
#
# Node (pnpm): as above, but
#   SETUP_CMD="pnpm install --frozen-lockfile"; SETUP_LOCK="pnpm-lock.yaml"
#   AUDIT_CMD="pnpm audit --audit-level high"
#
# Go:
#   LINT_CMD="go vet ./... && test -z \"$(gofmt -l .)\""; TEST_CMD="go test ./..."
#   SETUP_CMD="go mod download"
#   AUDIT_CMD="govulncheck ./..."
#   RALPH_CACHE_MOUNTS=(-v ralph-gomod:/home/agent/go/pkg/mod -v ralph-gobuild:/home/agent/.cache/go-build)
#   docker build -t ralph-impl --build-arg BASE_IMAGE=golang:1.23-bookworm ralph/sandbox
#
# Rust:
#   LINT_CMD="cargo clippy -- -D warnings && cargo fmt --check"; TEST_CMD="cargo test"
#   SETUP_CMD="cargo fetch"
#   AUDIT_CMD="cargo audit"
#   RALPH_CACHE_MOUNTS=(-v ralph-cargo:/home/agent/.cargo/registry)
#   docker build -t ralph-impl --build-arg BASE_IMAGE=rust:1-bookworm ralph/sandbox
#
# Python (uv):
#   LINT_CMD="uv run ruff check . && uv run mypy ."; TEST_CMD="uv run pytest"
#   SETUP_CMD="uv sync --frozen"; SETUP_MARKER=".venv"; SETUP_LOCK="uv.lock"
#   AUDIT_CMD="uv run pip-audit"
#   RALPH_DEP_DIRS=(.venv)
#   docker build -t ralph-impl --build-arg BASE_IMAGE=python:3.12-bookworm ralph/sandbox
#
# Ruby:
#   LINT_CMD="bundle exec rubocop"; TEST_CMD="bundle exec rspec"
#   SETUP_CMD="bundle install"; SETUP_MARKER="vendor/bundle"; SETUP_LOCK="Gemfile.lock"
#   AUDIT_CMD="bundle exec bundler-audit check --update"
#   RALPH_DEP_DIRS=(vendor/bundle)
#   docker build -t ralph-impl --build-arg BASE_IMAGE=ruby:3.3-bookworm ralph/sandbox
#
# JVM (Gradle):
#   LINT_CMD="./gradlew check -x test"; TEST_CMD="./gradlew test"
#   SETUP_CMD="./gradlew dependencies --quiet"
#   RALPH_CACHE_MOUNTS=(-v ralph-gradle:/home/agent/.gradle)
#   docker build -t ralph-impl --build-arg BASE_IMAGE=eclipse-temurin:21-jdk-jammy ralph/sandbox
#
# Mixed-language monorepo: point the commands at whatever your CI already runs.
#   LINT_CMD="make lint"; TEST_CMD="make test"; SETUP_CMD="make deps"
