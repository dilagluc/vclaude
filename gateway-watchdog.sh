#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  void-claude — Gateway Watchdog Service                      ║
# ║  Runs in background. Waits for OAuth, starts gateway,       ║
# ║  monitors health, restarts on crash.                         ║
# ╚══════════════════════════════════════════════════════════════╝

# Ensure node is in PATH (fnm may not be initialized in non-interactive shells)
export FNM_DIR="$HOME/.fnm"
export PATH="$FNM_DIR:$HOME/.local/bin:$PATH"
eval "$("$FNM_DIR/fnm" env 2>/dev/null)" 2>/dev/null || true

GW_BIN="/opt/void-claude/void-claude"
GW_DATA="/opt/.gateway-data"
CERTS_DIR="$GW_DATA/certs"
CONFIG_FILE="$GW_DATA/config.yaml"
CREDS_FILE="$HOME/.claude/.credentials.json"
GW_LOG="/tmp/void-claude.log"
GW_PID_FILE="/tmp/void-claude.pid"
WD_LOG="/tmp/void-claude-watchdog.log"
WD_PID_FILE="/tmp/void-claude-watchdog.pid"
YAML_MOD="/opt/void-claude/node_modules/yaml"

# ── Logging ────────────────────────────────────────────────────
log() { echo "[$(date -u +%H:%M:%S)] [watchdog] $1" >> "$WD_LOG"; }

# ── Single instance lock ──────────────────────────────────────
LOCK_FILE="/tmp/void-claude-watchdog.lock"
if [ -f "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE" 2>/dev/null)" 2>/dev/null; then
  exit 0  # another instance is already running
fi
echo $$ > "$LOCK_FILE"
echo $$ > "$WD_PID_FILE"

# ── Check binary ──────────────────────────────────────────────
if [ ! -x "$GW_BIN" ]; then
  log "Binary not found at $GW_BIN — exiting"
  exit 0
fi

# ══════════════════════════════════════════════════════════════
# Phase 1: Setup dirs, certs, config (once)
# ══════════════════════════════════════════════════════════════

# Fix bind mount permissions
if [ -d "$GW_DATA" ] && [ ! -w "$GW_DATA" ]; then
  sudo chown -R "$(id -u):$(id -g)" "$GW_DATA" 2>/dev/null
fi
mkdir -p "$CERTS_DIR" "$GW_DATA/audit" 2>/dev/null || {
  sudo mkdir -p "$CERTS_DIR" "$GW_DATA/audit" 2>/dev/null
  sudo chown -R "$(id -u):$(id -g)" "$GW_DATA" 2>/dev/null
}

# Generate TLS certs
if [ ! -f "$CERTS_DIR/cert.pem" ] || [ ! -f "$CERTS_DIR/key.pem" ]; then
  log "Generating TLS certificates..."
  openssl genrsa -out "$CERTS_DIR/ca.key" 2048 2>/dev/null
  openssl req -x509 -new -nodes -key "$CERTS_DIR/ca.key" \
    -sha256 -days 3650 -out "$CERTS_DIR/ca.crt" \
    -subj "/CN=void-claude CA" 2>/dev/null
  openssl genrsa -out "$CERTS_DIR/key.pem" 2048 2>/dev/null
  openssl req -new -key "$CERTS_DIR/key.pem" \
    -out "$CERTS_DIR/_s.csr" -subj "/CN=void-claude" 2>/dev/null
  cat > "$CERTS_DIR/_san.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_ext]
subjectAltName = DNS:localhost,DNS:void-claude,IP:127.0.0.1,IP:0.0.0.0
EOF
  openssl x509 -req -in "$CERTS_DIR/_s.csr" -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial -out "$CERTS_DIR/cert.pem" -days 3650 -sha256 \
    -extfile "$CERTS_DIR/_san.cnf" -extensions v3_ext 2>/dev/null
  rm -f "$CERTS_DIR/_s.csr" "$CERTS_DIR/_san.cnf" "$CERTS_DIR/ca.srl"
  log "Certificates generated"
fi

# Generate config
if [ ! -s "$CONFIG_FILE" ]; then
  log "Generating config (medium mode)..."
  cp /opt/void-claude/config.example.yaml "$CONFIG_FILE"
  DEVICE_ID=$(openssl rand -hex 32)
  ADMIN_TOKEN=$(openssl rand -hex 16)
  echo "$ADMIN_TOKEN" > "$GW_DATA/.admin-token"
  chmod 600 "$GW_DATA/.admin-token"

  node -e "
    const yaml = require('$YAML_MOD');
    const fs = require('fs');
    const config = yaml.parse(fs.readFileSync('$CONFIG_FILE', 'utf-8'));
    config.server = { port: 8443, tls: { cert: '$CERTS_DIR/cert.pem', key: '$CERTS_DIR/key.pem' } };
    config.identity.device_id = '$DEVICE_ID';
    config.auth = config.auth || {};
    config.auth.default_mode = 'medium';
    config.auth.tokens = [];
    config.admin = { token: '$ADMIN_TOKEN', auto_register: true };
    config.logging = { level: 'info', audit: true, audit_dir: '$GW_DATA/audit', audit_max_days: 30, audit_max_size_mb: 500 };
    config.rate_limit = { default_requests_per_minute: 6000, default_requests_per_hour: 360000 };
    fs.writeFileSync('$CONFIG_FILE', yaml.stringify(config));
  " 2>/dev/null || log "WARNING: config generation failed"

  log "Config ready (admin: $ADMIN_TOKEN)"
fi

# ══════════════════════════════════════════════════════════════
# Helper functions
# ══════════════════════════════════════════════════════════════

get_oauth_token() {
  # Priority 1: config.yaml (gateway persists rotated tokens here)
  local from_config
  from_config=$(node -e "
    try {
      const yaml = require('$YAML_MOD');
      const fs = require('fs');
      const c = yaml.parse(fs.readFileSync('$CONFIG_FILE', 'utf-8'));
      const rt = c.oauth && c.oauth.refresh_token;
      if (rt && rt.startsWith('sk-ant-') && rt !== 'your-refresh-token-here') process.stdout.write(rt);
    } catch(e) {}
  " 2>/dev/null)
  [ -n "$from_config" ] && echo "$from_config" && return

  # Priority 2: credentials.json (from claude login)
  node -e "
    try {
      const d = JSON.parse(require('fs').readFileSync('$CREDS_FILE', 'utf-8'));
      const rt = d.claudeAiOauth && d.claudeAiOauth.refreshToken;
      if (rt && rt.startsWith('sk-ant-')) process.stdout.write(rt);
    } catch(e) {}
  " 2>/dev/null
}

inject_token() {
  local token="$1"
  [ -z "$token" ] && return 1
  _OAUTH_TOKEN="$token" node -e "
    const yaml = require('$YAML_MOD');
    const fs = require('fs');
    const config = yaml.parse(fs.readFileSync('$CONFIG_FILE', 'utf-8'));
    config.oauth = config.oauth || {};
    config.oauth.refresh_token = process.env._OAUTH_TOKEN;
    fs.writeFileSync('$CONFIG_FILE', yaml.stringify(config));
  " 2>/dev/null
}

start_gateway() {
  # Kill old process
  if [ -f "$GW_PID_FILE" ]; then
    kill "$(cat "$GW_PID_FILE")" 2>/dev/null
    sleep 1
  fi

  log "Starting gateway..."
  "$GW_BIN" "$CONFIG_FILE" > "$GW_LOG" 2>&1 &
  local pid=$!
  echo "$pid" > "$GW_PID_FILE"

  # Wait for health
  for i in $(seq 1 15); do
    if curl -sk --connect-timeout 1 https://localhost:8443/_health >/dev/null 2>&1; then
      log "Gateway running (PID $pid)"
      return 0
    fi
    sleep 1
  done

  # Check if process died
  if ! kill -0 "$pid" 2>/dev/null; then
    log "Gateway failed to start: $(tail -1 "$GW_LOG" 2>/dev/null)"
    return 1
  fi
  log "Gateway started but health check slow (PID $pid)"
  return 0
}

gateway_healthy() {
  local health
  health=$(curl -sk --connect-timeout 2 https://localhost:8443/_health 2>/dev/null)
  # Check both that gateway responds AND oauth is valid
  echo "$health" | grep -q '"ok"'
}

gateway_alive() {
  [ -f "$GW_PID_FILE" ] && kill -0 "$(cat "$GW_PID_FILE")" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════
# Phase 2: Wait for OAuth token
# ══════════════════════════════════════════════════════════════

TOKEN=$(get_oauth_token)
if [ -z "$TOKEN" ]; then
  log "Waiting for OAuth token... Run 'claude' to login"
  while true; do
    TOKEN=$(get_oauth_token)
    [ -n "$TOKEN" ] && break
    sleep 5
  done
  log "OAuth token detected"

  # Wait for claude to exit (it rotates the token during its session)
  # Read the LATEST token after claude is done
  log "Waiting for claude to finish (token may rotate)..."
  sleep 3
  while pgrep -x claude >/dev/null 2>&1; do
    sleep 2
  done
  sleep 1

  # Re-read token (claude updates credentials.json on exit with rotated token)
  TOKEN=$(get_oauth_token)
  log "Token ready (after claude exit)"
fi

# Inject and start
inject_token "$TOKEN"
start_gateway
CREDS_MTIME=$(stat -c %Y "$CREDS_FILE" 2>/dev/null || echo "0")

# ══════════════════════════════════════════════════════════════
# Phase 3: Monitor loop (runs forever)
# ══════════════════════════════════════════════════════════════

while true; do
  sleep 5

  # Check if credentials.json changed (user did /login again)
  NEW_MTIME=$(stat -c %Y "$CREDS_FILE" 2>/dev/null || echo "0")
  if [ "$NEW_MTIME" != "$CREDS_MTIME" ]; then
    CREDS_MTIME="$NEW_MTIME"
    NEW_TOKEN=$(get_oauth_token)
    if [ -n "$NEW_TOKEN" ]; then
      log "Credentials updated, re-injecting token and restarting gateway"
      inject_token "$NEW_TOKEN"
      start_gateway
      continue
    fi
  fi

  # Health check — "ok" means gateway running AND oauth valid
  if gateway_healthy; then
    continue
  fi

  # Not healthy — kill whatever is running and restart fresh
  if gateway_alive; then
    log "Gateway unhealthy, restarting with fresh credentials"
    kill "$(cat "$GW_PID_FILE")" 2>/dev/null
    sleep 1
  else
    log "Gateway process not running"
  fi

  # Always re-read credentials before restart (token may have rotated)
  TOKEN=$(get_oauth_token)
  if [ -n "$TOKEN" ]; then
    inject_token "$TOKEN"
    CREDS_MTIME=$(stat -c %Y "$CREDS_FILE" 2>/dev/null || echo "0")
    start_gateway || {
      log "Restart failed, retrying in 15s"
      sleep 15
    }
  else
    log "No token available, waiting for login..."
    while true; do
      TOKEN=$(get_oauth_token)
      [ -n "$TOKEN" ] && break
      sleep 5
    done
    inject_token "$TOKEN"
    CREDS_MTIME=$(stat -c %Y "$CREDS_FILE" 2>/dev/null || echo "0")
    start_gateway
  fi
done
