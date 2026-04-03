#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  void-claude — OAuth Login (PKCE manual code flow)          ║
# ║  Replicates claude's OAuth flow for headless environments   ║
# ╚══════════════════════════════════════════════════════════════╝

CONFIG_FILE="/opt/.gateway-data/config.yaml"
CLIENT_TOKEN_FILE="/opt/.gateway-data/.client-token"
YAML_MOD="/opt/void-claude/node_modules/yaml"

# Ensure node in PATH
export FNM_DIR="$HOME/.fnm"
export PATH="$FNM_DIR:$HOME/.local/bin:$PATH"
eval "$("$FNM_DIR/fnm" env 2>/dev/null)" 2>/dev/null || true

# ── Run the PKCE OAuth flow via node ───────────────────────────
node -e '
const crypto = require("crypto");
const https = require("https");
const fs = require("fs");
const readline = require("readline");

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

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
rl.question("  Paste the code here: ", (code) => {
  rl.close();
  code = code.trim().split("#")[0];  // Strip #state fragment if browser appends it
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

      // Inject refresh token into gateway config
      try {
        const yaml = require(process.env.YAML_MOD || "/opt/void-claude/node_modules/yaml");
        const config = yaml.parse(fs.readFileSync(process.env.CONFIG_FILE || "/opt/.gateway-data/config.yaml", "utf-8"));
        config.oauth = config.oauth || {};
        config.oauth.refresh_token = refreshToken;
        fs.writeFileSync(process.env.CONFIG_FILE || "/opt/.gateway-data/config.yaml", yaml.stringify(config));
        console.log("[void-claude] Token injected into gateway config");
      } catch(e) {
        console.error("[void-claude] Failed to inject token:", e.message);
        process.exit(1);
      }

      // Generate client token if not exists
      const clientTokenFile = process.env.CLIENT_TOKEN_FILE || "/opt/.gateway-data/.client-token";
      let clientToken;
      try {
        clientToken = fs.readFileSync(clientTokenFile, "utf-8").trim();
      } catch(e) {
        clientToken = "gw-" + crypto.randomBytes(24).toString("hex");
        fs.writeFileSync(clientTokenFile, clientToken);
        console.log("[void-claude] Client token generated");

        // Add to gateway config
        try {
          const yaml = require(process.env.YAML_MOD || "/opt/void-claude/node_modules/yaml");
          const config = yaml.parse(fs.readFileSync(process.env.CONFIG_FILE || "/opt/.gateway-data/config.yaml", "utf-8"));
          config.auth = config.auth || {};
          config.auth.tokens = config.auth.tokens || [];
          if (!config.auth.tokens.find(t => t.token === clientToken)) {
            config.auth.tokens.push({ name: "local-client", token: clientToken, mode: config.auth.default_mode || "medium", is_admin: true });
            fs.writeFileSync(process.env.CONFIG_FILE || "/opt/.gateway-data/config.yaml", yaml.stringify(config));
          }
        } catch(e) { /* non-fatal */ }
      }

      // Wait for gateway to activate
      console.log("[void-claude] Waiting for gateway to activate...");
      let attempts = 0;
      const check = () => {
        const hreq = https.get("https://localhost:8443/_health", { rejectUnauthorized: false }, (hres) => {
          const hchunks = [];
          hres.on("data", (c) => hchunks.push(c));
          hres.on("end", () => {
            if (Buffer.concat(hchunks).toString().includes('"ok"')) {
              console.log("[void-claude] Gateway is active!");
              console.log("");
              console.log("  Run \x27claude\x27 to start — all traffic routes through the privacy gateway.");
              console.log("");
              process.exit(0);
            }
            if (++attempts < 15) setTimeout(check, 1000);
            else { console.log("[void-claude] Gateway not yet healthy. Run \x27gateway-status\x27 to check."); process.exit(0); }
          });
        });
        hreq.on("error", () => {
          if (++attempts < 15) setTimeout(check, 1000);
          else { console.log("[void-claude] Gateway not responding."); process.exit(0); }
        });
      };
      setTimeout(check, 2000);
    });
  });
  req.on("error", (e) => { console.error("[void-claude] Request failed:", e.message); process.exit(1); });
  req.write(body);
  req.end();
});
'
