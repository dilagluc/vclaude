#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  void-claude — Prepare binary for devcontainer build         ║
# ║  Compiles TypeScript → bundles → creates standalone binary  ║
# ║  Run this BEFORE building the devcontainer image.           ║
# ╚══════════════════════════════════════════════════════════════╝

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GW_SRC="${GW_SRC:-$(cd "$SCRIPT_DIR/../void-claude" 2>/dev/null && pwd || echo "")}"
STAGING="$SCRIPT_DIR/_gateway"

if [ ! -f "$GW_SRC/package.json" ]; then
  echo "ERROR: Gateway source not found at $GW_SRC"
  echo "Set GW_SRC=/path/to/void-claude or place this repo next to void-claude/"
  exit 1
fi

echo "=== void-claude Binary Build ==="
echo "  Source: $GW_SRC"
echo "  Output: $STAGING/"
echo ""

cd "$GW_SRC"

# 1. Install deps if needed
if [ ! -d "node_modules" ]; then
  echo "[1/5] Installing dependencies..."
  npm install --silent
else
  echo "[1/5] Dependencies OK"
fi

# 2. Compile TypeScript
echo "[2/5] Compiling TypeScript..."
npm run build --silent

# 3. Create CJS entry wrapper (handles top-level await)
echo "[3/5] Creating CJS entry..."
cat > dist/sea-entry.js <<'ENTRY'
(async () => {
  const { resolve } = require('path');
  const { loadConfig } = require('./config.js');
  const { setLogLevel, log } = require('./logger.js');
  const { initOAuth } = require('./oauth.js');
  const { startProxy, updateConfig } = require('./proxy.js');
  const { watchConfig } = require('./reload.js');
  const configPath = process.argv[2] || resolve(process.cwd(), 'config.yaml');
  try {
    const config = loadConfig(configPath);
    setLogLevel(config.logging.level);
    log('info', 'void-claude starting...');
    await initOAuth(config.oauth.refresh_token);
    startProxy(config, configPath);
    watchConfig(configPath, (newConfig) => { updateConfig(newConfig); });
  } catch (err) {
    console.error('Fatal: ' + (err instanceof Error ? err.message : err));
    process.exit(1);
  }
})();
ENTRY

# 4. Bundle into single CJS file
echo "[4/5] Bundling with esbuild..."
npx esbuild dist/sea-entry.js --bundle --platform=node --target=node22 \
  --format=cjs --outfile=dist/sea-bundle.cjs

# 5. Create Node.js SEA binary
echo "[5/5] Creating standalone binary (Node.js SEA)..."
echo '{"main":"dist/sea-bundle.cjs","output":"dist/sea-prep.blob","disableExperimentalSEAWarning":true}' > sea-config.json
node --experimental-sea-config sea-config.json

cp "$(command -v node)" dist/void-claude
npx postject dist/void-claude NODE_SEA_BLOB dist/sea-prep.blob \
  --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2 || true
chmod +x dist/void-claude

# Cleanup temp files
rm -f sea-config.json dist/sea-entry.js dist/sea-bundle.cjs dist/sea-prep.blob

# Stage into _gateway/
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp dist/void-claude "$STAGING/"
cp config.example.yaml "$STAGING/"
cp config_documentation.yaml "$STAGING/"

# Include yaml package for gateway-start.sh config generation
mkdir -p "$STAGING/node_modules"
cp -r node_modules/yaml "$STAGING/node_modules/"

BINARY_SIZE=$(du -sh "$STAGING/void-claude" | cut -f1)
echo ""
echo "=== Done ==="
echo "  Binary:  $STAGING/void-claude ($BINARY_SIZE)"
echo "  Config:  $STAGING/config.example.yaml"
echo "  Docs:    $STAGING/config_documentation.yaml"
echo ""
echo "  Next: build the devcontainer image"
