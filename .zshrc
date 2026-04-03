# shellcheck shell=bash
# Zsh configuration for void-claude devcontainer

# Add Claude Code to PATH
export PATH="$HOME/.local/bin:$PATH"

# fnm (Fast Node Manager)
export FNM_DIR="$HOME/.fnm"
export PATH="$FNM_DIR:$PATH"
eval "$(fnm env --use-on-cd)"

# History settings
export HISTFILE=/commandhistory/.zsh_history
export HISTSIZE=200000
export SAVEHIST=200000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY

# Directory navigation
setopt AUTO_CD
setopt AUTO_PUSHD
setopt PUSHD_IGNORE_DUPS
setopt PUSHD_SILENT

# Completion
setopt COMPLETE_IN_WORD
setopt ALWAYS_TO_END

# Aliases
alias fd=fdfind
alias sg=ast-grep
alias claude-yolo='claude --dangerously-skip-permissions'
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'

# fzf configuration
export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --follow --exclude .git'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND='fdfind --type d --hidden --follow --exclude .git'
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border --info=inline'

_fzf_compgen_path() {
  fdfind --hidden --follow --exclude .git . "$1"
}
_fzf_compgen_dir() {
  fdfind --type d --hidden --follow --exclude .git . "$1"
}

eval "$(fzf --zsh)"

# ── void-claude gateway ─────────────────────────────────────────
alias gateway-start='/opt/gateway-start.sh'
alias gateway-stop='kill $(cat /tmp/void-claude.pid 2>/dev/null) 2>/dev/null && echo "Gateway stopped" || echo "Gateway not running"'
alias gateway-logs='tail -f /tmp/void-claude.log'
alias gateway-status='curl -sk https://localhost:8443/_health 2>/dev/null | python3 -m json.tool || echo "Gateway not running"'
alias gateway-restart='gateway-stop; sleep 1; gateway-start'
alias gateway-config='${EDITOR:-nano} /opt/.gateway-data/config.yaml'

# Set gateway env vars only if certs exist (avoids SSL errors before first setup)
export ANTHROPIC_BASE_URL="https://localhost:8443"
if [ -f "/opt/.gateway-data/certs/ca.crt" ]; then
  export NODE_EXTRA_CA_CERTS="/opt/.gateway-data/certs/ca.crt"
fi

# Smart claude wrapper: bypasses gateway when it's down, auto-starts after login
claude() {
  local gw_was_down=false
  if ! curl -sk --connect-timeout 1 https://localhost:8443/_health >/dev/null 2>&1; then
    gw_was_down=true
    # Gateway not running — talk directly to Anthropic
    ANTHROPIC_BASE_URL="" NODE_EXTRA_CA_CERTS="" command claude "$@"
    # After claude exits, try to start gateway (credentials now exist)
    if [ -f "$HOME/.claude/.credentials.json" ]; then
      echo ""
      echo "[void-claude] Starting gateway with fresh credentials..."
      /opt/gateway-start.sh
    fi
  else
    command claude "$@"
  fi
}
