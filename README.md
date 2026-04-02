<div align="center">
  <h1>vclaude</h1>
  <p><strong>Your identity enters the void. Nothing comes out.</strong></p>
  <p>Self-contained Claude Code sandbox with <a href="https://github.com/dilagluc/void-claude">void-claude</a> privacy gateway built in.</p>
</div>

---

## What is this

A devcontainer that runs Claude Code with a privacy gateway. Everything is inside — gateway starts automatically, Claude routes through it, your identity is anonymized. No ports exposed. No setup needed.

Based on [trailofbits/claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer).

## Quick Start

```bash
# Install the vclaude command
bash install.sh self-install

# Start in your project directory
cd /path/to/your/project
vclaude .

# Launch Claude Code (routed through void-claude gateway)
vclaude claude
```

First start auto-generates everything: TLS certs, config, identity, tokens, OAuth extraction.

## Commands

```
vclaude .                     Install template + start container
vclaude up                    Start container
vclaude claude                Launch Claude Code through the gateway
vclaude shell                 Open interactive shell
vclaude admin                 Show gateway stats and client list
vclaude admin --expose        Forward gateway port to host (dashboard)
vclaude rebuild               Rebuild container (preserves auth)
vclaude down                  Stop container
vclaude destroy               Remove container + volumes + image
vclaude exec <cmd>            Run command in container
vclaude upgrade               Upgrade Claude Code
```

## Inside the Container

```bash
claude                        # just works — routes through gateway

gateway-status                # health check
gateway-logs                  # tail gateway logs
gateway-config                # edit config (mode, rules, templates)
gateway-restart               # apply config changes
```

## Security Modes

```yaml
# Edit: gateway-config
auth:
  default_mode: medium        # low | medium | hard
```

| Mode | Telemetry | Analytics | Team Features | Core API |
|------|:---------:|:---------:|:-------------:|:--------:|
| **low** | Anonymized | Anonymized | Yes | Yes |
| **medium** | Blocked | Blocked | Yes | Yes |
| **hard** | Blocked | Blocked | Blocked | Yes |

## Architecture

```
Inside container (nothing exposed to host by default)
─────────────────────────────────────────────────────
/workspace              Your project (only thing Claude sees)
/opt/void-claude/       Gateway binary (invisible to Claude)
/opt/.gateway-data/     Config + certs (invisible to Claude)

Claude Code → localhost:8443 → void-claude gateway → api.anthropic.com
                                  │
                        Identity rewritten
                        Telemetry controlled
                        40+ dimensions anonymized
```

## Config on Host

Gateway config is bind-mounted from `.gateway-data/` in your project:

```bash
# Edit from host
nano .gateway-data/config.yaml

# Changes auto-reload (2s poll)
```

## License

Apache 2.0 — see [LICENSE](LICENSE)
