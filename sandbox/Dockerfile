# ralph/sandbox/Dockerfile — the implementer ("/implement") sandbox image.
#
# Host safety: the implementer is the only stage that runs un-reviewed generated
# code (it writes tests + source and runs them). Running it here instead of on the
# host means a buggy/hostile agent sees ONLY the bind-mounted worktree — never the
# host $HOME, ssh/aws/claude credentials, or the wider filesystem. It needs no gh
# and no GitHub token: process-issue.sh injects the issue text into the prompt and
# does all git/PR work on the host.
#
# Build (from the repo root):
#   docker build -t ralph-impl ralph/sandbox
# If your host uid/gid differ from 1000, pass them so worktree writes aren't
# root-owned:
#   docker build --build-arg AGENT_UID=$(id -u) --build-arg AGENT_GID=$(id -g) \
#     -t ralph-impl ralph/sandbox

FROM node:22-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Align the image user with the host so files written into the bind-mounted
# worktree are owned by the host user, not root. node:22 ships a uid/gid-1000
# "node" user — rename and re-number it to match.
ARG AGENT_UID=1000
ARG AGENT_GID=1000
RUN groupmod -o -g "$AGENT_GID" node \
 && usermod  -o -u "$AGENT_UID" -g "$AGENT_GID" -d /home/agent -m -l agent node
USER ${AGENT_UID}:${AGENT_GID}

# Claude Code CLI (authenticated at runtime via CLAUDE_CODE_OAUTH_TOKEN).
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/agent/.local/bin:${PATH}"

WORKDIR /home/agent
# Clear the base image's entrypoint so `docker run ralph-impl claude -p ...` runs
# claude directly.
ENTRYPOINT []
