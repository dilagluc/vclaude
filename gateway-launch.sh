#!/bin/bash
# Launches the gateway watchdog in the background.
# This script exits immediately — the watchdog continues running.
nohup /opt/gateway-watchdog.sh >> /tmp/void-claude-watchdog.log 2>&1 &
echo "[gateway] Watchdog started (PID $!)"
exit 0
