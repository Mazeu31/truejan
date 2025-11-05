#!/bin/bash
set -euo pipefail

CONFIG_FILE="/usr/local/etc/trojan/config.json"
TROJAN_BIN="/usr/local/bin/trojan"
SERVICE_NAME="trojan"
PORT=2443

GREEN="\e[32m"; RED="\e[31m"; YELLOW="\e[33m"; RESET="\e[0m"

echo -e "${YELLOW}=== Trojan Fix Script ===${RESET}"

# 1️⃣ Validate JSON
echo -e "${YELLOW}Checking config.json syntax...${RESET}"
if python3 -m json.tool "$CONFIG_FILE" >/dev/null 2>&1; then
    echo -e "${GREEN}Config JSON is valid.${RESET}"
else
    echo -e "${RED}Config JSON is invalid. Please fix ${CONFIG_FILE}.${RESET}"
    exit 1
fi

# 2️⃣ Check Trojan binary
echo -e "${YELLOW}Checking Trojan binary...${RESET}"
if [ ! -x "$TROJAN_BIN" ]; then
    echo -e "${RED}Trojan binary not found or not executable at $TROJAN_BIN${RESET}"
    exit 1
else
    ARCH=$(file "$TROJAN_BIN")
    echo -e "${GREEN}Trojan binary exists: $ARCH${RESET}"
fi

# 3️⃣ Check port
echo -e "${YELLOW}Checking if port $PORT is free...${RESET}"
if ss -tlnp | grep ":$PORT" >/dev/null 2>&1; then
    echo -e "${RED}Port $PORT is already in use. Stop the conflicting service or change Trojan port.${RESET}"
    ss -tlnp | grep ":$PORT"
    exit 1
else
    echo -e "${GREEN}Port $PORT is free.${RESET}"
fi

# 4️⃣ Fix certificate permissions
echo -e "${YELLOW}Fixing certificate permissions...${RESET}"
chmod 644 /usr/local/etc/trojan/server.crt
chmod 600 /usr/local/etc/trojan/server.key
chown root:root /usr/local/etc/trojan/server.*

# 5️⃣ Test run manually
echo -e "${YELLOW}Testing Trojan manual start...${RESET}"
if "$TROJAN_BIN" -c "$CONFIG_FILE" >/tmp/trojan-test.log 2>&1 & then
    sleep 2
    pkill -f "$TROJAN_BIN"
    echo -e "${GREEN}Manual test successful.${RESET}"
else
    echo -e "${RED}Manual start failed. Check log below:${RESET}"
    tail -n 20 /tmp/trojan-test.log
    exit 1
fi

# 6️⃣ Restart systemd service
echo -e "${YELLOW}Restarting Trojan service...${RESET}"
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME" || systemctl start "$SERVICE_NAME" || true

sleep 2
systemctl status "$SERVICE_NAME" --no-pager

echo -e "${GREEN}✅ Trojan service should now be running.${RESET}"
