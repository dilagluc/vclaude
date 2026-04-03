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

## Install

```bash
# Clone the repo
git clone git@github.com:dilagluc/vclaude.git ~/.vclaude

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
gateway-restart          # restart gateway after config changes
gateway-stop             # stop the gateway
gateway-start            # start the gateway
```

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
