# ralph/sandbox/Dockerfile — the writer sandbox image.
#
# Host safety: the writer roles (/implement, the review-fix stage, the conflict
# resolver) are the only stages that run un-reviewed generated code. Running them
# here instead of on the host means a buggy or hostile agent sees ONLY the
# bind-mounted worktree — never the host $HOME, ssh/aws/claude credentials, or the
# wider filesystem. They need no gh and no GitHub token: the loop injects the
# issue text into the prompt and does all git and PR work on the host.
#
# Language agnostic: BASE_IMAGE picks the toolchain, so one Dockerfile serves
# every project. Any Debian- or Ubuntu-based image works (the layers below use
# apt-get and the shadow tools). Build from the repo root:
#
#   docker build -t ralph-impl --build-arg BASE_IMAGE=node:22-bookworm     ralph/sandbox
#   docker build -t ralph-impl --build-arg BASE_IMAGE=golang:1.23-bookworm ralph/sandbox
#   docker build -t ralph-impl --build-arg BASE_IMAGE=python:3.12-bookworm ralph/sandbox
#   docker build -t ralph-impl --build-arg BASE_IMAGE=ruby:3.3-bookworm    ralph/sandbox
#   docker build -t ralph-impl --build-arg BASE_IMAGE=rust:1-bookworm      ralph/sandbox
#
# Add apt packages the gate needs with EXTRA_PACKAGES, and extra install steps
# with SETUP_SNIPPET (one shell command, run as the agent user):
#
#   docker build -t ralph-impl \
#     --build-arg BASE_IMAGE=python:3.12-bookworm \
#     --build-arg SETUP_SNIPPET='curl -LsSf https://astral.sh/uv/install.sh | sh' \
#     ralph/sandbox
#
# If your host uid/gid differ from 1000, pass them so worktree writes aren't
# root-owned:
#   docker build --build-arg AGENT_UID=$(id -u) --build-arg AGENT_GID=$(id -g) ...

ARG BASE_IMAGE=debian:bookworm-slim
FROM ${BASE_IMAGE}

ARG EXTRA_PACKAGES=""
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates ${EXTRA_PACKAGES} \
    && rm -rf /var/lib/apt/lists/*

# Align the image user with the host so files written into the bind-mounted
# worktree are owned by the host user, not root. Language base images differ:
# node and ruby ship a uid-1000 user, golang and python do not. Rename and
# re-number whoever holds the uid, or create the user when it is free.
ARG AGENT_UID=1000
ARG AGENT_GID=1000
RUN set -eux; \
    grp="$(getent group "$AGENT_GID" | cut -d: -f1 || true)"; \
    if [ -n "$grp" ]; then \
      [ "$grp" = agent ] || groupmod -n agent "$grp"; \
    else \
      groupadd -o -g "$AGENT_GID" agent; \
    fi; \
    usr="$(getent passwd "$AGENT_UID" | cut -d: -f1 || true)"; \
    if [ -n "$usr" ]; then \
      [ "$usr" = agent ] || usermod -l agent "$usr"; \
      usermod -o -u "$AGENT_UID" -g "$AGENT_GID" -d /home/agent -m agent; \
    else \
      useradd -o -u "$AGENT_UID" -g "$AGENT_GID" -d /home/agent -m agent; \
    fi; \
    mkdir -p /home/agent; \
    chown "$AGENT_UID:$AGENT_GID" /home/agent
USER ${AGENT_UID}:${AGENT_GID}

# Claude Code CLI (authenticated at runtime via CLAUDE_CODE_OAUTH_TOKEN).
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/agent/.local/bin:${PATH}"

# Per-toolchain extras: a uv or golangci-lint install, a corepack enable, whatever
# the gate needs beyond the base image. Runs as the agent user, so it can write to
# $HOME. The default is a no-op.
ARG SETUP_SNIPPET="true"
RUN sh -c "${SETUP_SNIPPET}"

WORKDIR /home/agent
# Clear the base image's entrypoint so `docker run ralph-impl claude -p ...` runs
# claude directly.
ENTRYPOINT []
