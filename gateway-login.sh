#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  void-claude — Gateway login                                 ║
# ║  Supports three upstream auth methods:                       ║
# ║    1) Anthropic OAuth (PKCE, for Claude.ai subscribers)      ║
# ║    2) Anthropic API key (x-api-key, sk-ant-…)                ║
# ║    3) Custom provider (Kimi K2 / Moonshot / Z.ai / …)        ║
# ╚══════════════════════════════════════════════════════════════╝

export CONFIG_FILE="/opt/.gateway-data/config.yaml"
export CLIENT_TOKEN_FILE="/opt/.gateway-data/.client-token"
export YAML_MOD="/opt/void-claude/node_modules/yaml"

# Ensure node in PATH
export FNM_DIR="$HOME/.fnm"
export PATH="$FNM_DIR:$HOME/.local/bin:$PATH"
eval "$("$FNM_DIR/fnm" env 2>/dev/null)" 2>/dev/null || true

# This script should be SOURCED (not executed) so env vars take effect.
# The alias in .zshrc does: alias gateway-login='source /opt/gateway-login.sh'

# ── Menu ───────────────────────────────────────────────────────
echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  void-claude — Gateway login                             │"
echo "  │                                                          │"
echo "  │  Choose how the gateway authenticates to upstream:       │"
echo "  │    1) Anthropic OAuth  (Claude.ai subscription)          │"
echo "  │    2) Anthropic API key  (sk-ant-…)                      │"
echo "  │    3) Custom provider  (Kimi Coding / Moonshot / Z.ai)   │"
echo "  │       ← DEFAULT (Kimi Coding subscription)               │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
printf "  Select [1/2/3] (default: 3): "
read -r _GATEWAY_LOGIN_CHOICE
echo ""

case "$_GATEWAY_LOGIN_CHOICE" in
  1)    _GATEWAY_LOGIN_MODE="oauth" ;;
  2)    _GATEWAY_LOGIN_MODE="apikey_anthropic" ;;
  3|"") _GATEWAY_LOGIN_MODE="apikey_custom" ;;
  *)    echo "[void-claude] Invalid choice: $_GATEWAY_LOGIN_CHOICE"; return 1 2>/dev/null || exit 1 ;;
esac

# ── Mode 1: OAuth (PKCE manual code flow) ──────────────────────
if [ "$_GATEWAY_LOGIN_MODE" = "oauth" ]; then
node -e '
const crypto = require("crypto");
const https = require("https");
const fs = require("fs");

const CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const TOKEN_URL = "https://platform.claude.com/v1/oauth/token";
const AUTHORIZE_URL = "https://claude.com/cai/oauth/authorize";
const MANUAL_REDIRECT = "https://platform.claude.com/oauth/code/callback";
const SCOPES = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";

function base64URLEncode(buf) {
  return buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

const codeVerifier = base64URLEncode(crypto.randomBytes(32));
const codeChallenge = base64URLEncode(crypto.createHash("sha256").update(codeVerifier).digest());
const state = base64URLEncode(crypto.randomBytes(32));

const authUrl = new URL(AUTHORIZE_URL);
authUrl.searchParams.set("code", "true");
authUrl.searchParams.set("client_id", CLIENT_ID);
authUrl.searchParams.set("response_type", "code");
authUrl.searchParams.set("redirect_uri", MANUAL_REDIRECT);
authUrl.searchParams.set("scope", SCOPES);
authUrl.searchParams.set("code_challenge", codeChallenge);
authUrl.searchParams.set("code_challenge_method", "S256");
authUrl.searchParams.set("state", state);

console.log("");
console.log("  ┌──────────────────────────────────────────────────────────┐");
console.log("  │  void-claude — OAuth Authentication                       │");
console.log("  │                                                          │");
console.log("  │  1. Open this URL in your browser:                       │");
console.log("  └──────────────────────────────────────────────────────────┘");
console.log("");
console.log("  " + authUrl.toString());
console.log("");
console.log("  2. Sign in with your Anthropic account");
console.log("  3. Copy the code shown on the page");
console.log("");

// Read code with masking (show first 4 chars + asterisks)
process.stdout.write("  Paste the code here: ");
let code = "";
process.stdin.setRawMode(true);
process.stdin.resume();
process.stdin.setEncoding("utf-8");
process.stdin.on("data", (ch) => {
  if (ch === "\r" || ch === "\n") {
    process.stdin.setRawMode(false);
    process.stdin.pause();
    process.stdout.write("\n");
    handleCode();
  } else if (ch === "\x03") { // Ctrl+C
    process.stdout.write("\n");
    process.exit(0);
  } else if (ch === "\x7f" || ch === "\b") { // Backspace
    if (code.length > 0) {
      code = code.slice(0, -1);
      process.stdout.write("\b \b");
    }
  } else {
    code += ch;
    process.stdout.write(code.length <= 4 ? ch : "*");
  }
});
function handleCode() {
  code = code.trim().split("#")[0];
  if (!code) { console.error("[void-claude] No code provided."); process.exit(1); }

  const body = JSON.stringify({
    grant_type: "authorization_code",
    code: code,
    redirect_uri: MANUAL_REDIRECT,
    client_id: CLIENT_ID,
    code_verifier: codeVerifier,
    state: state,
  });

  const url = new URL(TOKEN_URL);
  const req = https.request({
    hostname: url.hostname,
    port: 443,
    path: url.pathname,
    method: "POST",
    headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) },
  }, (res) => {
    const chunks = [];
    res.on("data", (c) => chunks.push(c));
    res.on("end", () => {
      const raw = Buffer.concat(chunks).toString();
      let data;
      try { data = JSON.parse(raw); } catch(e) {
        console.error("[void-claude] Invalid response:", raw.substring(0, 200));
        process.exit(1);
      }
      if (res.statusCode !== 200) {
        console.error("[void-claude] Token exchange failed (" + res.statusCode + "):", JSON.stringify(data));
        process.exit(1);
      }

      const refreshToken = data.refresh_token;
      if (!refreshToken) { console.error("[void-claude] No refresh token in response"); process.exit(1); }

      console.log("");
      console.log("[void-claude] Authentication successful!");

      try {
        const yaml = require(process.env.YAML_MOD);
        const config = yaml.parse(fs.readFileSync(process.env.CONFIG_FILE, "utf-8"));
        config.oauth = config.oauth || {};
        config.oauth.refresh_token = refreshToken;
        // Clear any previously configured upstream API key so OAuth wins.
        if (config.upstream && config.upstream.api_key) {
          delete config.upstream.api_key;
          delete config.upstream.auth_style;
          delete config.upstream.provider;
          delete config.upstream.model_map;
          delete config.upstream.thinking;
        }
        // Reset upstream URL to Anthropic in case the user was previously on a custom provider.
        config.upstream = config.upstream || {};
        config.upstream.url = "https://api.anthropic.com";
        fs.writeFileSync(process.env.CONFIG_FILE, yaml.stringify(config));
        console.log("[void-claude] Refresh token injected into gateway config");
      } catch(e) {
        console.error("[void-claude] Failed to inject token:", e.message);
        process.exit(1);
      }
      process.exit(0);
    });
  });
  req.on("error", (e) => { console.error("[void-claude] Request failed:", e.message); process.exit(1); });
  req.write(body);
  req.end();
}
'
_NODE_EXIT=$?
if [ $_NODE_EXIT -ne 0 ]; then
  echo "[void-claude] OAuth login failed"
  unset _GATEWAY_LOGIN_CHOICE _GATEWAY_LOGIN_MODE _NODE_EXIT
  return 1 2>/dev/null || exit 1
fi
fi  # end OAuth branch

# ── Mode 2 & 3: API key (Anthropic or custom provider) ─────────
if [ "$_GATEWAY_LOGIN_MODE" = "apikey_anthropic" ] || [ "$_GATEWAY_LOGIN_MODE" = "apikey_custom" ]; then

  if [ "$_GATEWAY_LOGIN_MODE" = "apikey_custom" ]; then
    echo "  Provider presets:"
    echo "    kimi        → https://api.kimi.com/coding/            (Kimi Coding subscription — DEFAULT)"
    echo "                   model: kimi-for-coding, auth: bearer (ANTHROPIC_AUTH_TOKEN)"
    echo "                   Thinking toggled via Claude Code Tab key (extended thinking)"
    echo "    moonshot    → https://api.moonshot.ai/anthropic       (Moonshot platform PAYG)"
    echo "                   model: kimi-k2-thinking, auth: x-api-key"
    echo "    zai         → https://api.z.ai/api/anthropic          (Z.ai / GLM)"
    echo "                   model: glm-4.6, auth: x-api-key"
    echo "    custom      → enter your own base URL / model / auth style"
    echo ""
    printf "  Provider [kimi/moonshot/zai/custom] (default: kimi): "
    read -r _PROVIDER_PRESET
    case "$_PROVIDER_PRESET" in
      kimi|"")
        _UPSTREAM_URL="https://api.kimi.com/coding/"
        _UPSTREAM_MODEL="kimi-for-coding"
        _UPSTREAM_AUTH_STYLE="bearer"
        ;;
      moonshot)
        _UPSTREAM_URL="https://api.moonshot.ai/anthropic"
        _UPSTREAM_MODEL="kimi-k2-thinking"
        _UPSTREAM_AUTH_STYLE="x-api-key"
        ;;
      zai)
        _UPSTREAM_URL="https://api.z.ai/api/anthropic"
        _UPSTREAM_MODEL="glm-4.6"
        _UPSTREAM_AUTH_STYLE="x-api-key"
        ;;
      custom|*)
        printf "  Upstream base URL (e.g. https://api.example.com/anthropic): "
        read -r _UPSTREAM_URL
        printf "  Default model (leave empty to pass Claude model names through): "
        read -r _UPSTREAM_MODEL
        printf "  Auth style [x-api-key/bearer] (default: x-api-key): "
        read -r _UPSTREAM_AUTH_STYLE
        _UPSTREAM_AUTH_STYLE="${_UPSTREAM_AUTH_STYLE:-x-api-key}"
        ;;
    esac
    if [ -z "$_UPSTREAM_URL" ]; then
      echo "[void-claude] No upstream URL provided"
      unset _GATEWAY_LOGIN_CHOICE _GATEWAY_LOGIN_MODE _PROVIDER_PRESET _UPSTREAM_URL _UPSTREAM_MODEL _UPSTREAM_AUTH_STYLE
      return 1 2>/dev/null || exit 1
    fi
    echo ""
    echo "  Using: $_UPSTREAM_URL  (model=${_UPSTREAM_MODEL:-passthrough}, auth=$_UPSTREAM_AUTH_STYLE)"
    echo ""

    # ── Force thinking mode? ─────────────────────────────────────
    # When enabled, the gateway injects `thinking: { enabled, budget }` into
    # every /v1/messages request — you don't need to press Tab in Claude Code.
    # Tradeoff: even trivial tool-use turns (file reads, ls, bash) will reason.
    # Default: no (use Tab per-query, as Kimi intends).
    echo "  Force thinking mode on every request?"
    echo "    - no  (default): press Tab in Claude Code when you want thinking"
    echo "    - yes:           gateway always requests thinking (good for batch/"
    echo "                     non-interactive use; wastes tokens on tool turns)"
    printf "  Force thinking? [y/N]: "
    read -r _FORCE_THINKING_ANSWER
    case "$_FORCE_THINKING_ANSWER" in
      y|Y|yes|YES)
        _UPSTREAM_FORCE_THINKING="true"
        printf "  Thinking budget_tokens (default 8000): "
        read -r _UPSTREAM_THINKING_BUDGET
        _UPSTREAM_THINKING_BUDGET="${_UPSTREAM_THINKING_BUDGET:-8000}"
        ;;
      *)
        _UPSTREAM_FORCE_THINKING="false"
        _UPSTREAM_THINKING_BUDGET="8000"
        ;;
    esac
    echo ""
  else
    _UPSTREAM_URL="https://api.anthropic.com"
    _UPSTREAM_MODEL=""
    _UPSTREAM_AUTH_STYLE="x-api-key"
    _UPSTREAM_FORCE_THINKING="false"
    _UPSTREAM_THINKING_BUDGET="8000"
  fi

  # Read the API key with masking
  printf "  Paste your API key: "
  # Read silently then print a masked preview
  stty -echo 2>/dev/null
  read -r _UPSTREAM_API_KEY
  stty echo 2>/dev/null
  echo ""
  if [ -z "$_UPSTREAM_API_KEY" ]; then
    echo "[void-claude] No API key provided"
    unset _GATEWAY_LOGIN_CHOICE _GATEWAY_LOGIN_MODE _UPSTREAM_URL _UPSTREAM_MODEL _UPSTREAM_API_KEY _PROVIDER_PRESET
    return 1 2>/dev/null || exit 1
  fi
  _KEY_PREVIEW="$(printf '%s' "$_UPSTREAM_API_KEY" | cut -c1-8)…$(printf '%s' "$_UPSTREAM_API_KEY" | tail -c 4)"
  echo "  Key accepted: $_KEY_PREVIEW"
  echo ""

  export _UPSTREAM_URL _UPSTREAM_MODEL _UPSTREAM_API_KEY _UPSTREAM_AUTH_STYLE _UPSTREAM_FORCE_THINKING _UPSTREAM_THINKING_BUDGET _GATEWAY_LOGIN_MODE

  node -e '
    const fs = require("fs");
    const yaml = require(process.env.YAML_MOD);
    const configPath = process.env.CONFIG_FILE;
    const config = yaml.parse(fs.readFileSync(configPath, "utf-8"));

    config.upstream = config.upstream || {};
    config.upstream.url = process.env._UPSTREAM_URL;
    config.upstream.api_key = process.env._UPSTREAM_API_KEY;
    config.upstream.auth_style = process.env._UPSTREAM_AUTH_STYLE || "x-api-key";

    if (process.env._GATEWAY_LOGIN_MODE === "apikey_custom") {
      config.upstream.provider = "custom";
      if (process.env._UPSTREAM_MODEL) {
        // Map all Claude model names to the provider model — the gateway
        // applies this rewrite on outbound /v1/messages requests.
        config.upstream.model_map = { "*": process.env._UPSTREAM_MODEL };
      } else {
        delete config.upstream.model_map;
      }
      // Forced thinking mode (gateway injects body.thinking on every request)
      if (process.env._UPSTREAM_FORCE_THINKING === "true") {
        config.upstream.thinking = {
          enabled: true,
          budget_tokens: parseInt(process.env._UPSTREAM_THINKING_BUDGET || "8000", 10),
        };
      } else {
        delete config.upstream.thinking;
      }
    } else {
      // Anthropic API key: clear any leftover custom-provider settings.
      delete config.upstream.provider;
      delete config.upstream.model_map;
      delete config.upstream.thinking;
    }

    // Clear OAuth refresh token so the gateway picks the API-key path
    // unambiguously (API key takes precedence anyway, but be explicit).
    if (config.oauth) {
      config.oauth.refresh_token = "";
    }

    fs.writeFileSync(configPath, yaml.stringify(config));
    console.log("[void-claude] Upstream API key injected into gateway config");
    console.log("[void-claude]   upstream:  " + config.upstream.url);
    console.log("[void-claude]   auth:      " + config.upstream.auth_style);
    if (config.upstream.provider) {
      console.log("[void-claude]   provider:  " + config.upstream.provider);
    }
    if (config.upstream.model_map) {
      console.log("[void-claude]   model map: " + JSON.stringify(config.upstream.model_map));
    }
    if (config.upstream.thinking && config.upstream.thinking.enabled) {
      console.log("[void-claude]   thinking:  forced (budget=" + config.upstream.thinking.budget_tokens + ")");
    } else {
      console.log("[void-claude]   thinking:  per-query (Tab key in Claude Code)");
    }
  '
  _NODE_EXIT=$?
  unset _UPSTREAM_API_KEY _UPSTREAM_MODEL _UPSTREAM_URL _UPSTREAM_AUTH_STYLE _PROVIDER_PRESET _KEY_PREVIEW _FORCE_THINKING_ANSWER _UPSTREAM_FORCE_THINKING _UPSTREAM_THINKING_BUDGET
  if [ $_NODE_EXIT -ne 0 ]; then
    echo "[void-claude] Failed to write API key to gateway config"
    unset _GATEWAY_LOGIN_CHOICE _GATEWAY_LOGIN_MODE _NODE_EXIT
    return 1 2>/dev/null || exit 1
  fi
fi  # end API key branch

# ── Common post-setup (runs for all modes) ─────────────────────
# 1) Ensure a client token exists in the gateway config
# 2) Wait for the gateway to become healthy
# 3) Export ANTHROPIC_API_KEY = client token in the current shell
# 4) Clear claude-code OAuth state so it uses x-api-key to talk to the gateway
# 5) Pre-approve the key in ~/.claude/.claude.json

node -e '
  const crypto = require("crypto");
  const fs = require("fs");
  const yaml = require(process.env.YAML_MOD);
  const configPath = process.env.CONFIG_FILE;
  const clientTokenFile = process.env.CLIENT_TOKEN_FILE;

  let clientToken;
  try {
    clientToken = fs.readFileSync(clientTokenFile, "utf-8").trim();
  } catch(e) {
    clientToken = "gw-" + crypto.randomBytes(24).toString("hex");
    fs.writeFileSync(clientTokenFile, clientToken);
    console.log("[void-claude] Client token generated");
  }

  try {
    const config = yaml.parse(fs.readFileSync(configPath, "utf-8"));
    config.auth = config.auth || {};
    config.auth.tokens = config.auth.tokens || [];
    if (!config.auth.tokens.find(t => t.token === clientToken)) {
      config.auth.tokens.push({
        name: "local-client",
        token: clientToken,
        mode: config.auth.default_mode || "medium",
        is_admin: true,
      });
      fs.writeFileSync(configPath, yaml.stringify(config));
      console.log("[void-claude] Client token registered in gateway config");
    }
  } catch(e) { /* non-fatal */ }
'

# Wait for gateway to become healthy (watchdog will pick up config changes)
echo "[void-claude] Waiting for gateway to activate..."
_ATTEMPTS=0
while [ $_ATTEMPTS -lt 15 ]; do
  if curl -sk --connect-timeout 1 https://localhost:8443/_health 2>/dev/null | grep -q '"status":"ok"'; then
    echo "[void-claude] Gateway is active!"
    break
  fi
  _ATTEMPTS=$((_ATTEMPTS + 1))
  sleep 1
done
unset _ATTEMPTS

# Export ANTHROPIC_API_KEY for the current shell (claude → gateway auth)
if [ -f "$CLIENT_TOKEN_FILE" ]; then
  export ANTHROPIC_API_KEY=$(cat "$CLIENT_TOKEN_FILE")

  # Clear ALL claude-code OAuth state so it uses x-api-key, not Authorization: Bearer
  # (isClaudeAISubscriber() returns true if OAuth creds are present, which would
  # make claude-code send Bearer and bypass the gateway's client auth.)
  rm -f "$HOME/.claude/.credentials.json" 2>/dev/null
  node -e "
    const fs = require('fs');
    const p = process.env.HOME + '/.claude/.claude.json';
    try {
      let c = JSON.parse(fs.readFileSync(p, 'utf-8'));
      delete c.claudeAiOauth;
      delete c.oauthAccount;
      fs.writeFileSync(p, JSON.stringify(c, null, 2));
    } catch(e) {}
  " 2>/dev/null

  # Pre-approve the API key in claude-code's config (skips the "Detected custom
  # API key" onboarding prompt). Claude truncates to the last 20 chars — see
  # claude-code/src/utils/authPortable.ts:normalizeApiKeyForConfig.
  _KEY_TRUNCATED=$(echo -n "$ANTHROPIC_API_KEY" | tail -c 20)
  node -e "
    const fs = require('fs');
    const p = process.env.HOME + '/.claude/.claude.json';
    let config = {};
    try { config = JSON.parse(fs.readFileSync(p, 'utf-8')); } catch(e) {}
    config.customApiKeyResponses = config.customApiKeyResponses || {};
    config.customApiKeyResponses.approved = config.customApiKeyResponses.approved || [];
    const trunc = '$_KEY_TRUNCATED';
    if (!config.customApiKeyResponses.approved.includes(trunc)) {
      config.customApiKeyResponses.approved.push(trunc);
    }
    config.hasCompletedOnboarding = true;
    fs.mkdirSync(process.env.HOME + '/.claude', { recursive: true });
    fs.writeFileSync(p, JSON.stringify(config, null, 2));
  " 2>/dev/null
  unset _KEY_TRUNCATED
fi

echo ""
echo "  Run 'claude' to start — all traffic routes through the privacy gateway."
echo ""

unset _GATEWAY_LOGIN_CHOICE _GATEWAY_LOGIN_MODE _NODE_EXIT
