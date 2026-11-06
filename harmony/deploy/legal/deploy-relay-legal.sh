#!/bin/bash
# Deploy the relay with the legal pages (privacy policy + user agreement).
#
# The relay serves them itself (GET /legal/...), so the pages are reachable through
# **every** address of the relay: the IP, the domain and the Cloudflare tunnel ✓
set -e

APP_DIR=/opt/dsh-harmony
SRC=$APP_DIR/src
SITE=$APP_DIR/site/legal
STAMP=$(date +%Y%m%d-%H%M%S)

# ------------------------------------------------------------------ the source
sudo cp "$SRC/server.js" "$SRC/server.js.bak-$STAMP"
sudo cp "$SRC/cli.js" "$SRC/cli.js.bak-$STAMP"
sudo cp /tmp/server.js "$SRC/server.js"
sudo cp /tmp/cli.js "$SRC/cli.js"
sudo chown dshrelay:dshrelay "$SRC/server.js" "$SRC/cli.js"
echo "[ok] the relay source is updated (backup: *.$STAMP)"

# ------------------------------------------------------------------ the pages
sudo mkdir -p "$SITE"
sudo cp /tmp/legal-index.html "$SITE/index.html"
sudo cp /tmp/legal-user-agreement.html "$SITE/user-agreement.html"
sudo chown -R dshrelay:dshrelay "$SITE"
echo "[ok] the legal pages are in $SITE"

# ------------------------------------------------------------------ the service
UNIT=/etc/systemd/system/dsh-harmony-relay.service
if ! sudo grep -q -- '--legal-dir' "$UNIT"; then
  sudo python3 - "$UNIT" <<'PY'
import sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as fh:
    text = fh.read()
text = text.replace(
    '  --public-url https://dsh-relay.example.com',
    '  --public-url https://dsh-relay.example.com \\\n  --legal-dir /opt/dsh-harmony/site/legal')
with open(path, 'w', encoding='utf-8') as fh:
    fh.write(text)
print('[ok] --legal-dir added to the unit')
PY
else
  echo "[skip] --legal-dir is already in the unit"
fi
sudo systemctl daemon-reload
sudo systemctl restart dsh-harmony-relay
sleep 3
systemctl is-active dsh-harmony-relay
echo '[done] the relay is running again'
