# void-claude Devcontainer
# Self-contained: gateway + Claude Code in one container.
# Based on trailofbits/claude-code-devcontainer (Apache 2.0)
FROM ghcr.io/astral-sh/uv:0.10@sha256:10902f58a1606787602f303954cea099626a4adb02acbac4c69920fe9d278f82 AS uv
FROM mcr.microsoft.com/devcontainers/base:ubuntu24.04@sha256:4bcb1b466771b1ba1ea110e2a27daea2f6093f9527fb75ee59703ec89b5561cb

ARG TZ
ENV TZ="$TZ"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install system packages (base image includes git, curl, sudo)
RUN apt-get update && apt-get install -y --no-install-recommends \
  # Sandboxing support for Claude Code
  bubblewrap \
  socat \
  # Modern CLI tools
  fd-find \
  ripgrep \
  tmux \
  zsh \
  # Build tools
  build-essential \
  # Utilities
  jq \
  nano \
  unzip \
  vim \
  # Network tools (security testing + gateway)
  dnsutils \
  ipset \
  iptables \
  iproute2 \
  # TLS cert generation (for gateway)
  openssl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install git-delta
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  curl -fsSL "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" -o /tmp/git-delta.deb && \
  dpkg -i /tmp/git-delta.deb && rm /tmp/git-delta.deb

# Install uv (Python package manager)
COPY --from=uv /uv /usr/local/bin/uv

# Install fzf
ARG FZF_VERSION=0.70.0
RUN ARCH=$(dpkg --print-architecture) && \
  case "${ARCH}" in amd64) FZF_ARCH="linux_amd64" ;; arm64) FZF_ARCH="linux_arm64" ;; *) exit 1 ;; esac && \
  curl -fsSL "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-${FZF_ARCH}.tar.gz" | tar -xz -C /usr/local/bin

# Create directories
RUN mkdir -p /commandhistory /workspace /home/vscode/.claude /opt/void-claude /opt/.gateway-data/certs /opt/.gateway-data/audit && \
  touch /commandhistory/.bash_history /commandhistory/.zsh_history && \
  chown -R vscode:vscode /commandhistory /workspace /home/vscode/.claude /opt/void-claude /opt/.gateway-data

ENV DEVCONTAINER=true
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

WORKDIR /workspace
USER vscode
ENV PATH="/home/vscode/.local/bin:$PATH"

# Install Claude Code + plugins
RUN curl -fsSL https://claude.ai/install.sh | bash && \
  claude plugin marketplace add anthropics/skills && \
  claude plugin marketplace add trailofbits/skills && \
  claude plugin marketplace add trailofbits/skills-curated

# Install Python 3.13
RUN uv python install 3.13 --default

# Install ast-grep
RUN uv tool install ast-grep-cli

# Install fnm + Node 22
ARG NODE_VERSION=22
ENV FNM_DIR="/home/vscode/.fnm"
RUN curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$FNM_DIR" --skip-shell && \
  export PATH="$FNM_DIR:$PATH" && eval "$(fnm env)" && \
  fnm install ${NODE_VERSION} && fnm default ${NODE_VERSION}

# Install Oh My Zsh
ARG ZSH_IN_DOCKER_VERSION=1.2.1
RUN sh -c "$(curl -fsSL https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- -p git -x

# ── void-claude binary (pre-compiled, no source code) ──────────
COPY --chown=vscode:vscode _gateway/void-claude /opt/void-claude/void-claude
COPY --chown=vscode:vscode _gateway/config.example.yaml /opt/void-claude/config.example.yaml
COPY --chown=vscode:vscode _gateway/config_documentation.yaml /opt/void-claude/config_documentation.yaml
COPY --chown=vscode:vscode _gateway/node_modules /opt/void-claude/node_modules
RUN chmod +x /opt/void-claude/void-claude

# ── Gateway startup script ─────────────────────────────────────
COPY --chown=vscode:vscode gateway-start.sh /opt/gateway-start.sh
RUN chmod +x /opt/gateway-start.sh

# ── Shell + post-install config ────────────────────────────────
COPY --chown=vscode:vscode .zshrc /home/vscode/.zshrc.custom
RUN echo 'source ~/.zshrc.custom' >> /home/vscode/.zshrc
COPY --chown=vscode:vscode post_install.py /opt/post_install.py
