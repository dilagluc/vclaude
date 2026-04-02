#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  void-claude — Auto-start on container boot                  ║
# ║  Generates certs, config, extracts OAuth, starts gateway    ║
# ╚══════════════════════════════════════════════════════════════╝

set -e

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

# ── Create data dirs ───────────────────────────────────────────
mkdir -p "$CERTS_DIR" "$GW_DATA/audit"

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

  # Save admin token for CLI access
  echo "$ADMIN_TOKEN" > "$ADMIN_TOKEN_FILE"
  chmod 600 "$ADMIN_TOKEN_FILE"

  # Use node (available in devcontainer) for safe YAML editing
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

    fs.writeFileSync('$CONFIG_FILE', yaml.stringify(config));
  " 2>/dev/null || echo "[gateway] WARNING: config generation used fallback (no yaml module)"

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
if [ -f "$CREDS_FILE" ]; then
  REFRESH_TOKEN=$(node -e "
    try {
      const d = JSON.parse(require('fs').readFileSync('$CREDS_FILE', 'utf-8'));
      const rt = d.claudeAiOauth && d.claudeAiOauth.refreshToken;
      if (rt && rt.startsWith('sk-ant-')) process.stdout.write(rt);
    } catch(e) {}
  " 2>/dev/null)

  if [ -n "$REFRESH_TOKEN" ]; then
    node -e "
      const yaml = require('/opt/void-claude/node_modules/yaml');
      const fs = require('fs');
      const config = yaml.parse(fs.readFileSync('$CONFIG_FILE', 'utf-8'));
      config.oauth = config.oauth || {};
      config.oauth.refresh_token = '$REFRESH_TOKEN';
      fs.writeFileSync('$CONFIG_FILE', yaml.stringify(config));
    " 2>/dev/null
    echo "[gateway] OAuth token extracted from credentials"
  fi
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

echo "[gateway] WARNING: started but health check failed — check: tail -f $LOG_FILE"
