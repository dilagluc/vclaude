#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  void-claude — On-demand OAuth login                         ║
# ║  Runs 'claude auth login', captures token, activates gateway ║
# ╚══════════════════════════════════════════════════════════════╝

CREDS_FILE="$HOME/.claude/.credentials.json"
CONFIG_FILE="/opt/.gateway-data/config.yaml"
YAML_MOD="/opt/void-claude/node_modules/yaml"

# Ensure fnm/node in PATH
export FNM_DIR="$HOME/.fnm"
export PATH="$FNM_DIR:$HOME/.local/bin:$PATH"
eval "$("$FNM_DIR/fnm" env 2>/dev/null)" 2>/dev/null || true

echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  void-claude — OAuth Authentication                       │"
echo "  │                                                          │"
echo "  │  A URL will appear below. Open it in your browser        │"
echo "  │  to authenticate with your Anthropic account.            │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""

# Run claude auth login (bypasses gateway env vars so it talks direct to Anthropic)
ANTHROPIC_BASE_URL="" NODE_EXTRA_CA_CERTS="" claude auth login

# Check if login succeeded
if [ ! -f "$CREDS_FILE" ]; then
  echo ""
  echo "[void-claude] Login failed or cancelled."
  exit 1
fi

# Verify token exists
TOKEN=$(node -e "
  try {
    const d = JSON.parse(require('fs').readFileSync('$CREDS_FILE', 'utf-8'));
    const rt = d.claudeAiOauth && d.claudeAiOauth.refreshToken;
    if (rt && rt.startsWith('sk-ant-')) process.stdout.write(rt);
  } catch(e) {}
" 2>/dev/null)

if [ -z "$TOKEN" ]; then
  echo "[void-claude] Could not extract token from credentials."
  exit 1
fi

# Inject token into gateway config
export _OAUTH_TOKEN="$TOKEN"
node -e "
  const yaml = require('$YAML_MOD');
  const fs = require('fs');
  const config = yaml.parse(fs.readFileSync('$CONFIG_FILE', 'utf-8'));
  config.oauth = config.oauth || {};
  config.oauth.refresh_token = process.env._OAUTH_TOKEN;
  fs.writeFileSync('$CONFIG_FILE', yaml.stringify(config));
" 2>/dev/null
unset _OAUTH_TOKEN

echo ""
echo "[void-claude] Token injected. Gateway activating..."

# Wait for gateway hot-reload to pick up the new token
for i in $(seq 1 10); do
  if curl -sk --connect-timeout 1 https://localhost:8443/_health 2>/dev/null | grep -q '"ok"'; then
    echo "[void-claude] Gateway is active!"
    echo ""
    echo "  Run 'claude' to start — all traffic routes through the privacy gateway."
    echo ""
    exit 0
  fi
  sleep 1
done

echo "[void-claude] Gateway didn't activate yet. Run 'gateway-status' to check."
echo "[void-claude] You may need to run 'gateway-start' to restart the watchdog."
