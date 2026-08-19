#!/usr/bin/env bash
# ralph/config.sh — project wiring. Edit this file when dropping ralph into a
# project. Every value is env-overridable (env wins over what is written here).
# Sourced by lib.sh (all entry points) and status.sh; keep it side-effect free.
#
# Ralph is language and framework agnostic. It knows how to drive GitHub, git and
# claude; it knows nothing about your toolchain. Everything toolchain-shaped is a
# command string or a directory list below. Recipes for common stacks are at the
# bottom of this file.

# GitHub triage labels (Matt Pocock vocabulary). Must exist on the repo.
READY_LABEL="${READY_LABEL:-ready-for-agent}"   # the queue: issues the AFK agent may pick up
WORKING_LABEL="${WORKING_LABEL:-claude-working}" # transient "in progress" marker
HUMAN_LABEL="${HUMAN_LABEL:-ready-for-human}"    # handback: issues a human must handle

# Branch PRs target and merge into.
BASE_BRANCH="${BASE_BRANCH:-main}"

# --- Objective quality gate --------------------------------------------------
# The orchestrator (never the agent) runs these in the worktree, so approval does
# not depend on an agent's honest "tests pass" claim.
#
# TEST_DIR is the dir the gate runs in, relative to the repo root. LINT_CMD and
# TEST_CMD also appear verbatim in the agent prompts, so keep them copy-pasteable
# shell commands. An EMPTY command is SKIPPED — by the gate and by the prompts
# alike — so a project with no linter just leaves LINT_CMD empty.
#
# Leaving BOTH empty makes the gate a no-op. Ralph logs a warning every cycle in
# that case rather than reporting a pass it never checked.
TEST_DIR="${TEST_DIR:-.}"
LINT_CMD="${LINT_CMD:-}"
TEST_CMD="${TEST_CMD:-}"

# Dependency install, run in TEST_DIR before LINT_CMD and TEST_CMD. Empty = the
# project needs no install step.
#
# SETUP_MARKER is the directory SETUP_CMD populates. When it is missing or EMPTY,
# the install re-runs. The empty case is load-bearing: the sandbox bind-mounts
# that directory, and docker leaves an empty root-owned mountpoint behind on
# container exit — without the check the host gate would run with no toolchain
# installed and could never pass. SETUP_LOCK re-runs the install when the
# lockfile is newer than the marker.
#
# Leave SETUP_MARKER empty to run SETUP_CMD every cycle. That is right for a
# toolchain whose install is already a cheap no-op when warm (`go mod download`,
# `cargo fetch`), and wrong for one that is not (`npm ci`).
SETUP_CMD="${SETUP_CMD:-}"
SETUP_MARKER="${SETUP_MARKER:-}"
SETUP_LOCK="${SETUP_LOCK:-}"

# Advisory dependency audit, run in TEST_DIR when RALPH_AUDIT=1. Logged, never
# blocks a PR. Empty = no audit is wired up for this stack.
AUDIT_CMD="${AUDIT_CMD:-}"

# --- Sandbox -----------------------------------------------------------------
# Docker image tag for the writer sandbox (built from ralph/sandbox). The
# Dockerfile takes a BASE_IMAGE build arg, so one Dockerfile serves every
# toolchain — see ralph/sandbox/Dockerfile.
RALPH_SANDBOX_IMAGE="${RALPH_SANDBOX_IMAGE:-ralph-impl}"

# In-repo dependency caches bind-mounted from the repo root into the sandbox
# worktree, so the offline-of-GitHub agent can lint and test without
# re-downloading. Every WORKSPACE_DIR x DEP_DIR pair that exists on the host is
# mounted at the same relative path inside the worktree; missing pairs are
# skipped. List every workspace package the gate touches.
RALPH_WORKSPACE_DIRS=(".")
if [ "$TEST_DIR" != "." ]; then RALPH_WORKSPACE_DIRS+=("$TEST_DIR"); fi
RALPH_DEP_DIRS=()

# Toolchain caches that live outside the repo, in the container's $HOME. That
# HOME is empty and thrown away on exit, so without these every run re-downloads
# the world. Each entry is one docker -v spec. Use a NAMED VOLUME, not a host
# path: a host path would hand the sandboxed agent a writable directory on your
# machine, which is the thing the sandbox exists to prevent.
RALPH_CACHE_MOUNTS=()

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
