#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  void-claude — Auto-start on container boot                  ║
# ║  Generates certs, config, extracts OAuth, starts gateway    ║
# ╚══════════════════════════════════════════════════════════════╝

# Never fail — gateway is best-effort, must not block container startup

GW_BIN="/opt/void-claude/void-claude"
GW_DATA="/opt/.gateway-data"
CERTS_DIR="$GW_DATA/certs"
CONFIG_FILE="$GW_DATA/config.yaml"
CREDS_FILE="$HOME/.claude/.credentials.json"
LOG_FILE="/tmp/void-claude.log"
PID_FILE="/tmp/void-claude.pid"
ADMIN_TOKEN_FILE="$GW_DATA/.admin-token"

# ── Check binary exists ────────────────────────────────────────
if [ ! -x "$GW_BIN" ]; then
  echo "[gateway] Binary not found at $GW_BIN — skipping"
  exit 0
fi

# ── Create data dirs (handle permission issues from bind mount) ─
# The bind mount from host may create /opt/.gateway-data as root
# Fix ownership first, then create subdirs
if [ -d "$GW_DATA" ] && [ ! -w "$GW_DATA" ]; then
  sudo chown -R "$(id -u):$(id -g)" "$GW_DATA" 2>/dev/null
fi
mkdir -p "$CERTS_DIR" "$GW_DATA/audit" 2>/dev/null
if [ ! -d "$CERTS_DIR" ]; then
  # Last resort: sudo create + chown
  sudo mkdir -p "$CERTS_DIR" "$GW_DATA/audit" 2>/dev/null
  sudo chown -R "$(id -u):$(id -g)" "$GW_DATA" 2>/dev/null
fi
if [ ! -d "$CERTS_DIR" ]; then
  echo "[gateway] ERROR: Cannot create $CERTS_DIR — check bind mount permissions"
  exit 0
fi

# ── Generate TLS certs if missing ──────────────────────────────
if [ ! -f "$CERTS_DIR/cert.pem" ] || [ ! -f "$CERTS_DIR/key.pem" ]; then
  echo "[gateway] Generating TLS certificates..."

  openssl genrsa -out "$CERTS_DIR/ca.key" 2048 2>/dev/null
  openssl req -x509 -new -nodes -key "$CERTS_DIR/ca.key" \
    -sha256 -days 3650 -out "$CERTS_DIR/ca.crt" \
    -subj "/CN=void-claude CA" 2>/dev/null

  openssl genrsa -out "$CERTS_DIR/key.pem" 2048 2>/dev/null
  openssl req -new -key "$CERTS_DIR/key.pem" \
    -out "$CERTS_DIR/_server.csr" -subj "/CN=void-claude" 2>/dev/null

  cat > "$CERTS_DIR/_san.cnf" <<SANEOF
[req]
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_ext]
subjectAltName = DNS:localhost,DNS:void-claude,IP:127.0.0.1,IP:0.0.0.0
SANEOF

  openssl x509 -req -in "$CERTS_DIR/_server.csr" \
    -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial -out "$CERTS_DIR/cert.pem" \
    -days 3650 -sha256 \
    -extfile "$CERTS_DIR/_san.cnf" -extensions v3_ext 2>/dev/null

  rm -f "$CERTS_DIR/_server.csr" "$CERTS_DIR/_san.cnf" "$CERTS_DIR/ca.srl"
  echo "[gateway] Certificates generated"
fi

# ── Generate config if missing or empty ────────────────────────
if [ ! -s "$CONFIG_FILE" ]; then
  echo "[gateway] Generating config (medium mode)..."
  cp /opt/void-claude/config.example.yaml "$CONFIG_FILE"

  DEVICE_ID=$(openssl rand -hex 32)
  TOKEN_1="gw-$(openssl rand -hex 24)"
  TOKEN_2="gw-$(openssl rand -hex 24)"
  ADMIN_TOKEN=$(openssl rand -hex 16)

  echo "$ADMIN_TOKEN" > "$ADMIN_TOKEN_FILE"
  chmod 600 "$ADMIN_TOKEN_FILE"

  node -e "
    const yaml = require('/opt/void-claude/node_modules/yaml');
    const fs = require('fs');
    const config = yaml.parse(fs.readFileSync('$CONFIG_FILE', 'utf-8'));

    config.server = config.server || {};
    config.server.port = 8443;
    config.server.tls = { cert: '$CERTS_DIR/cert.pem', key: '$CERTS_DIR/key.pem' };

    config.identity.device_id = '$DEVICE_ID';
    if (config.auth && config.auth.tokens) {
      config.auth.tokens[0].token = '$TOKEN_1';
      if (config.auth.tokens[1]) config.auth.tokens[1].token = '$TOKEN_2';
    }
    config.admin = { token: '$ADMIN_TOKEN', auto_register: true };
    config.logging = config.logging || {};
    config.logging.level = 'info';
    config.logging.audit = true;
    config.logging.audit_dir = '$GW_DATA/audit';
    config.logging.audit_max_days = 30;
    config.logging.audit_max_size_mb = 500;
    config.rate_limit = { default_requests_per_minute: 6000, default_requests_per_hour: 360000 };

    fs.writeFileSync('$CONFIG_FILE', yaml.stringify(config));
  " 2>/dev/null || echo "[gateway] WARNING: config generation failed"

  echo ""
  echo "  ┌──────────────────────────────────────────────────────────┐"
  echo "  │  void-claude — First Run                                  │"
  echo "  │  Admin token: $ADMIN_TOKEN"
  echo "  │  Config: $CONFIG_FILE"
  echo "  │  Mode: medium (edit config to change)                    │"
  echo "  │  Auto-register: ON                                       │"
  echo "  └──────────────────────────────────────────────────────────┘"
  echo ""
fi

# ── Inject OAuth token from Claude credentials ─────────────────
HAS_VALID_TOKEN="no"

if [ -f "$CREDS_FILE" ]; then
  REFRESH_TOKEN=$(node -e "
    try {
      const d = JSON.parse(require('fs').readFileSync('$CREDS_FILE', 'utf-8'));
      const rt = d.claudeAiOauth && d.claudeAiOauth.refreshToken;
      if (rt && rt.startsWith('sk-ant-')) process.stdout.write(rt);
    } catch(e) {}
  " 2>/dev/null)

  if [ -n "$REFRESH_TOKEN" ]; then
    export _OAUTH_TOKEN="$REFRESH_TOKEN"
    node -e "
      const yaml = require('/opt/void-claude/node_modules/yaml');
      const fs = require('fs');
      const config = yaml.parse(fs.readFileSync('$CONFIG_FILE', 'utf-8'));
      config.oauth = config.oauth || {};
      config.oauth.refresh_token = process.env._OAUTH_TOKEN;
      fs.writeFileSync('$CONFIG_FILE', yaml.stringify(config));
    " 2>/dev/null && HAS_VALID_TOKEN="yes" && echo "[gateway] OAuth token extracted from credentials"
    unset _OAUTH_TOKEN
  fi
fi

# Check if config has a real token (might have been set manually or from previous run)
if [ "$HAS_VALID_TOKEN" = "no" ]; then
  HAS_VALID_TOKEN=$(node -e "
    const yaml = require('/opt/void-claude/node_modules/yaml');
    const fs = require('fs');
    const c = yaml.parse(fs.readFileSync('$CONFIG_FILE', 'utf-8'));
    const rt = c.oauth && c.oauth.refresh_token;
    if (rt && rt.startsWith('sk-ant-') && rt !== 'your-refresh-token-here') process.stdout.write('yes');
  " 2>/dev/null)
fi

if [ "$HAS_VALID_TOKEN" != "yes" ]; then
  echo ""
  echo "  ┌──────────────────────────────────────────────────────────┐"
  echo "  │  No OAuth token found. To set up:                        │"
  echo "  │                                                          │"
  echo "  │    1. Run:  claude /login                                │"
  echo "  │    2. Run:  gateway-start                                │"
  echo "  │                                                          │"
  echo "  │  That's it. Gateway will auto-extract the token.         │"
  echo "  └──────────────────────────────────────────────────────────┘"
  echo ""
  exit 0
fi

# ── Kill old gateway if running ────────────────────────────────
if [ -f "$PID_FILE" ]; then
  kill "$(cat "$PID_FILE")" 2>/dev/null
  sleep 1
  rm -f "$PID_FILE"
fi

# ── Start gateway ──────────────────────────────────────────────
echo "[gateway] Starting void-claude..."
"$GW_BIN" "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
GW_PID=$!
echo "$GW_PID" > "$PID_FILE"

# Wait for health
for i in $(seq 1 15); do
  if curl -sk https://localhost:8443/_health > /dev/null 2>&1; then
    echo "[gateway] Running (PID $GW_PID)"
    echo "[gateway] Claude Code is pre-configured to route through the gateway."
    echo "[gateway] Just run: claude"
    exit 0
  fi
  sleep 1
done

# Check if process died
if ! kill -0 "$GW_PID" 2>/dev/null; then
  echo "[gateway] Gateway process died. Log:"
  tail -5 "$LOG_FILE" 2>/dev/null
  echo ""
  echo "[gateway] Likely OAuth token expired. Run: claude /login && gateway-start"
else
  echo "[gateway] WARNING: started but health check timed out — check: gateway-logs"
fi
exit 0
