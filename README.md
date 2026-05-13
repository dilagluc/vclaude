<div align="center">
  <h1>vclaude</h1>
  <p><strong>Your identity enters the void. Nothing comes out.</strong></p>
  <p>Self-contained Claude Code sandbox with <a href="https://github.com/dilagluc/void-claude">void-claude</a> privacy gateway built in.</p>
</div>

---

## What is this

A devcontainer that runs Claude Code with a privacy gateway. Everything is inside — gateway starts automatically, Claude routes through it, your identity is anonymized. No ports exposed. No setup needed.

Based on [trailofbits/claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer).

---

## Prerequisites

- **Docker** — running on your machine (`docker info` to check)
- **Git LFS** — required for the gateway binary (119MB)
  ```bash
  # Ubuntu/Debian
  sudo apt-get install git-lfs

  # macOS
  brew install git-lfs

  # Then initialize
  git lfs install
  ```
- **GitHub access** — this is a private repo. Authenticate with:
  ```bash
  # Install GitHub CLI if needed: https://cli.github.com
  gh auth login
  # Pick: GitHub.com → HTTPS → Login with a web browser
  # This stores credentials so git clone works over HTTPS (no SSH keys needed)
  ```

## Install

```bash
# Clone the repo (requires git-lfs + GitHub auth)
git clone https://github.com/dilagluc/vclaude.git ~/.vclaude

# Install the vclaude command to PATH
cd ~/.vclaude && bash install.sh self-install

# Verify
vclaude help
```

## Start a Project

```bash
# Go to any project directory
cd ~/my-project

# Install template + build + start (first time ~5 min)
vclaude .
```

This automatically:
- Creates `.devcontainer/` in your project
- Creates `.gateway-data/` (hidden, for config/certs/audit)
- Builds the Docker image with Claude Code + void-claude gateway
- Starts the container
- Generates TLS certs, config, identity, tokens
- Extracts OAuth from `~/.claude/.credentials.json`
- Starts the gateway in medium mode (100 req/s default)

## Use Claude Code

```bash
# Launch Claude directly (routed through gateway)
vclaude claude

# Or open a shell and use claude inside
vclaude shell
claude        # just works — all traffic goes through the gateway
```

## Gateway Management (inside container)

```bash
vclaude shell

gateway-status           # health check — shows mode, OAuth, clients
gateway-logs             # tail gateway logs in real time
gateway-config           # edit config (mode, rules, templates, limits)
gateway-login            # switch upstream provider (Anthropic / Kimi / Moonshot / Z.ai)
gateway-restart          # restart gateway after config changes
gateway-stop             # stop the gateway
gateway-start            # start the gateway

cch-selftest             # verify gateway's CCH seed matches the local claude binary
```

## CCH seed self-test

The gateway re-signs the `cch=` attestation hash in every `/v1/messages`
request, using a seed that is hardcoded per Claude Code version. Anthropic
rotates this seed occasionally; when they do, the gateway's signatures stop
matching and requests start failing.

`cch-selftest` catches that drift. It's a standalone binary shipped inside the
container — no source checkout needed:

```bash
vclaude shell
cch-selftest                              # uses `which claude`
cch-selftest --binary /path/to/claude     # specific binary
```

On success it prints `✅ PASS — seed for X.Y.Z is correct.` and exits 0. On
mismatch it prints a boxed warning (observed vs computed CCH, gateway seed,
pointer to the RE location in 2.1.140) and exits 1. Run it after every
`claude upgrade` to confirm the gateway still authenticates correctly. Full
reference: [CCH-SELFTEST.md in the gateway source repo](https://github.com/dilagluc/void-claude/blob/main/CCH-SELFTEST.md).

## Switching upstream providers

`gateway-login` is a menu-driven setup for pointing the gateway at a different upstream. Hot-reload picks up the change immediately — no restart needed.

```
gateway-login

  1) Anthropic OAuth  (Claude.ai subscription, PKCE flow)
  2) Anthropic API key  (sk-ant-…)
  3) Custom provider  (Kimi Coding / Moonshot / Z.ai)    ← DEFAULT
     └── kimi       → https://api.kimi.com/coding/       ← default
         moonshot   → https://api.moonshot.ai/anthropic
         zai        → https://api.z.ai/api/anthropic
         custom     → enter your own URL / model / auth style
```

Hitting `Enter` twice walks straight into the Kimi Coding flow.

**Kimi Coding subscription (default)** — paste your `sk-kimi-...` key from [kimi.com/code](https://www.kimi.com/code). The script writes `upstream.url`, `api_key`, `auth_style: bearer`, `provider: custom`, and `model_map: "*": kimi-for-coding`. Inside Claude Code, press `Tab` before a prompt to enable K2.5 Thinking for that turn.

**Force thinking on every request** — the script asks whether to force-enable extended thinking (default: no). Pick `y` for batch / non-interactive pipelines that can't press Tab. Leave it off for interactive use.

**Switching back to Anthropic** — run `gateway-login` → `1` (OAuth) or `2` (API key). The script cleanly wipes any leftover custom-provider settings from the previous login.

See [PROVIDERS.md in void-claude](https://github.com/dilagluc/void-claude/blob/main/PROVIDERS.md) for the full config reference, auth styles, and provider cookbook.

## Admin Endpoint (from host)

No ports are exposed by default. Access admin from the host:

```bash
# Quick stats + client list
vclaude admin

# Access the dashboard in your browser
vclaude admin --expose
# Then open: https://localhost:18443/_dashboard
```

## Edit Config from Host

Gateway config is bind-mounted from `.gateway-data/` in your project:

```bash
# Edit directly on host (any editor)
nano ~/my-project/.gateway-data/config.yaml

# Changes auto-reload every 2 seconds
# Or force reload:
vclaude exec curl -sk -X POST \
  -H "Authorization: Bearer $(cat .gateway-data/.admin-token)" \
  https://localhost:8443/_admin/reload
```

## Change Security Mode

```bash
# From inside the container
vclaude shell
gateway-config
# Change: default_mode: hard
gateway-restart

# Or edit from host
nano .gateway-data/config.yaml
```

| Mode | Telemetry | Analytics | Team Features | Core API |
|------|:---------:|:---------:|:-------------:|:--------:|
| **low** | Anonymized | Anonymized | Yes | Yes |
| **medium** | Blocked | Blocked | Yes | Yes |
| **hard** | Blocked | Blocked | Blocked | Yes |

## Lifecycle Commands

```bash
vclaude .                # first time: install template + start
vclaude up               # start container (after vclaude down)
vclaude down             # stop container
vclaude rebuild          # rebuild image (preserves config/auth)
vclaude destroy          # remove everything (container + volumes + image)
vclaude claude           # launch Claude Code through the gateway
vclaude shell            # open interactive shell
vclaude admin            # show gateway stats
vclaude admin --expose   # forward gateway port to host (dashboard)
vclaude exec <cmd>       # run any command inside the container
vclaude upgrade          # upgrade Claude Code to latest
vclaude mount <h> <c>    # add a host mount to the container
```

## Upgrading from an older version

When new gateway binaries (including `cch-selftest`) or Dockerfile changes
ship to this repo, existing installs need to pull the new state from GitHub
and then rebuild their container.

### TL;DR

```bash
vclaude update           # git pull --ff-only in your ~/.vclaude clone
cd <your project>
vclaude rebuild          # rebuild container with the new image (auth preserved)
```

`vclaude update` runs `git pull --ff-only` inside your vclaude clone
(typically `~/.vclaude`), which fetches the new Dockerfile **and** the
LFS-tracked binaries under `_gateway/`. `vclaude rebuild` then runs
`devcontainer up --remove-existing-container`, which stops the old container,
rebuilds the image from the updated Dockerfile, and starts a fresh container.
Your auth state (Claude OAuth tokens, gateway config) lives in Docker volumes
and is preserved across rebuilds.

If you have multiple projects, run `vclaude rebuild` inside each.

### If `vclaude update` is unavailable or fails

Older installs may not have the `update` subcommand, or `vclaude` itself may
not be on `PATH`. Do the equivalent by hand:

```bash
cd ~/.vclaude            # or wherever you cloned vclaude
git lfs install          # idempotent — ensures LFS smudge filter is active
git pull --ff-only       # fetches new commits + new LFS binaries
```

If the clone is broken or you want a clean slate of the repo (auth is **not**
in the clone, it's in Docker volumes — safe to delete):

```bash
# Prerequisites — same as a first install
sudo apt-get install -y git-lfs        # or: brew install git-lfs
gh auth login                          # vclaude is a private repo
git lfs install

# Re-clone from GitHub
rm -rf ~/.vclaude
git clone https://github.com/dilagluc/vclaude.git ~/.vclaude

# Re-install the vclaude command to ~/.local/bin
cd ~/.vclaude && bash install.sh self-install
vclaude help                           # sanity check
```

Then rebuild each project's container:

```bash
cd <project>
vclaude rebuild
```

### Cleaning up old Docker images

`vclaude rebuild` doesn't auto-prune old image layers. After upgrading:

```bash
docker image prune        # remove dangling images (safe)
docker image prune -a     # remove ALL unused images (more aggressive)
```

To start fully fresh on a single project (drops that project's auth + config too):

```bash
vclaude destroy           # nuke container, volumes, image for current project
vclaude .                 # reinstall template and start
```

### Verify the upgrade

```bash
vclaude shell
cch-selftest              # ✅ PASS — seed for X.Y.Z is correct.
```

If `cch-selftest` is not found, the new image didn't land — re-check that
`vclaude update` actually pulled new commits (`git -C ~/.vclaude log --oneline -3`)
and that `vclaude rebuild` ran without errors.

## Architecture

```
Host                                    Container (nothing exposed)
────                                    ─────────────────────────────
~/my-project/ ──(bind mount)──────────▶ /workspace (Claude sees only this)
~/my-project/.gateway-data/ ──────────▶ /opt/.gateway-data/ (invisible to Claude)
                                        /opt/void-claude/ (binary, invisible)

                                        Claude Code
                                           │
                                           ▼
                                        localhost:8443 (void-claude gateway)
                                           │
                                        Identity rewritten
                                        Telemetry controlled
                                        40+ dimensions anonymized
                                           │
                                           ▼
                                        api.anthropic.com
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `vclaude: command not found` | Run `export PATH="$HOME/.local/bin:$PATH"` or add to `~/.bashrc` |
| Container won't start | Check Docker is running: `docker info` |
| OAuth token expired | Re-login: `claude` on host, then `vclaude rebuild` |
| Gateway not starting | `vclaude shell` then `gateway-logs` to check errors |
| Want to reset everything | `vclaude destroy` then `rm -rf .gateway-data .devcontainer` then `vclaude .` |

## License

Apache 2.0 — see [LICENSE](LICENSE)
