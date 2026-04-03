# shellcheck shell=bash
# Zsh configuration for void-claude devcontainer

# ── Auto-restore .claude.json if corrupted ─────────────────────
if [ ! -f "$HOME/.claude/.claude.json" ]; then
  _backup=$(ls -t "$HOME/.claude/backups/.claude.json.backup."* 2>/dev/null | head -1)
  [ -n "$_backup" ] && cp "$_backup" "$HOME/.claude/.claude.json" 2>/dev/null
fi

# ── Auto-start gateway watchdog if not running ─────────────────
if [ -x /opt/gateway-watchdog.sh ]; then
  if ! kill -0 "$(cat /tmp/void-claude-watchdog.pid 2>/dev/null)" 2>/dev/null; then
    nohup /opt/gateway-watchdog.sh >> /tmp/void-claude-watchdog.log 2>&1 &
    disown 2>/dev/null
  fi
fi

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
alias gateway-login='source /opt/gateway-login.sh'
alias gateway-start='/opt/gateway-start.sh'
alias gateway-stop='kill $(cat /tmp/void-claude.pid 2>/dev/null) 2>/dev/null && echo "Gateway stopped" || echo "Gateway not running"'
alias gateway-logs='tail -f /tmp/void-claude.log'
alias gateway-watchdog-logs='tail -f /tmp/void-claude-watchdog.log'
alias gateway-status='curl -sk https://localhost:8443/_health 2>/dev/null | python3 -m json.tool || echo "Gateway not running"'
alias gateway-restart='/opt/gateway-start.sh'
alias gateway-config='${EDITOR:-nano} /opt/.gateway-data/config.yaml'

# ── Gateway env vars ────────────────────────────────────────────
# ANTHROPIC_API_KEY → claude uses x-api-key header (no OAuth on client side)
# Gateway validates the client token and injects real OAuth Bearer token
export ANTHROPIC_BASE_URL="https://localhost:8443"
[ -f "/opt/.gateway-data/certs/ca.crt" ] && export NODE_EXTRA_CA_CERTS="/opt/.gateway-data/certs/ca.crt"
[ -f "/opt/.gateway-data/.client-token" ] && export ANTHROPIC_API_KEY=$(cat /opt/.gateway-data/.client-token)

# Unset any OAuth env vars so claude uses x-api-key exclusively
unset ANTHROPIC_AUTH_TOKEN 2>/dev/null
unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null
unset CLAUDE_CODE_OAUTH_REFRESH_TOKEN 2>/dev/null

# Show status on shell open
if [ -x /opt/void-claude/void-claude ]; then
  _health=$(curl -sk --connect-timeout 1 https://localhost:8443/_health 2>/dev/null || echo "")
  if echo "$_health" | grep -q '"ok"'; then
    echo "  [void-claude] Gateway active — all traffic anonymized"
  elif echo "$_health" | grep -q '"degraded"'; then
    echo ""
    echo "  [void-claude] Gateway running — no OAuth token yet"
    echo "  [void-claude] Run 'gateway-login' to authenticate"
    echo ""
  fi
fi
