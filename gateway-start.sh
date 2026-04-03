#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  void-claude — Start/restart the gateway watchdog            ║
# ╚══════════════════════════════════════════════════════════════╝

# Kill existing watchdog + gateway
kill "$(cat /tmp/void-claude-watchdog.pid 2>/dev/null)" 2>/dev/null
kill "$(cat /tmp/void-claude.pid 2>/dev/null)" 2>/dev/null
sleep 1
rm -f /tmp/void-claude-watchdog.pid /tmp/void-claude.pid

# Start fresh watchdog in background
nohup /opt/gateway-watchdog.sh >> /tmp/void-claude-watchdog.log 2>&1 &
echo "[gateway] Watchdog started (PID $!)"
echo "[gateway] Logs: tail -f /tmp/void-claude-watchdog.log"

# Wait briefly for gateway to come up
sleep 3
if curl -sk --connect-timeout 1 https://localhost:8443/_health >/dev/null 2>&1; then
  echo "[gateway] Gateway is running"
else
  echo "[gateway] Gateway starting up... check: gateway-watchdog-logs"
fi
