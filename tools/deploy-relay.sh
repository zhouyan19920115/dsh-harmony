#!/usr/bin/env bash
# Deploy the DSH Harmony relay on a Linux machine — one command, nothing to configure by hand.
#
#   bash tools/deploy-relay.sh --domain relay.example.com --email you@example.com
#
# What it does:
#   1. installs Node.js 20+ when it is missing
#   2. creates an unprivileged user and copies the relay into a directory
#   3. gets a certificate: Let's Encrypt when certbot is there, otherwise a self signed one
#   4. writes relay.config.json
#   5. writes a systemd unit — the relay itself never runs as root
#   6. puts a reverse proxy in front of it, so only port 443 is open
#   7. prints the deployment notes
#
# The script is idempotent: run it again after an update and it only changes what is needed.
#
# NOTE: this file is UTF-8 without a BOM and uses LF line endings.
set -euo pipefail

DSH_DOMAIN=""
DSH_EMAIL=""
DSH_DIR="/opt/dsh-harmony"
DSH_USER=""
DSH_PLAIN_PORT="8788"
DSH_PROXY="nginx"
DSH_SKIP_CERT="no"
DSH_SKIP_NODE="no"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '[deploy] %s\n' "$*"; }
warn() { printf '[deploy] WARN  %s\n' "$*" >&2; }
die()  { printf '[deploy] ERROR %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
dsh-harmony-relay deployment

Usage:
  bash tools/deploy-relay.sh --domain <your.domain> [options]

Options:
  --domain <name>     the domain of the relay, e.g. relay.example.com   [required]
  --email <address>   the address Let's Encrypt writes the expiry notice to
  --dir <path>        where the relay is installed (default /opt/dsh-harmony)
  --user <name>       the user the relay runs as (default: dsh-harmony)
  --plain-port <n>    the port of the relay behind the proxy (default 8788)
  --proxy <name>      nginx or none (default nginx)
  --skip-cert         keep the certificate that is already there
  --skip-node         do not install Node.js
  --help              show this text

The relay never runs as root. Only port 443 is opened; the plain port of the relay
is bound to 127.0.0.1 and only the reverse proxy reaches it.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)      DSH_DOMAIN="${2:-}"; shift 2 ;;
    --email)       DSH_EMAIL="${2:-}"; shift 2 ;;
    --dir)         DSH_DIR="${2:-}"; shift 2 ;;
    --user)        DSH_USER="${2:-}"; shift 2 ;;
    --plain-port)  DSH_PLAIN_PORT="${2:-}"; shift 2 ;;
    --proxy)       DSH_PROXY="${2:-}"; shift 2 ;;
    --skip-cert)   DSH_SKIP_CERT="yes"; shift ;;
    --skip-node)   DSH_SKIP_NODE="yes"; shift ;;
    --help|-h)     usage; exit 0 ;;
    *)             printf '[deploy] ERROR unknown option %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$DSH_DOMAIN" ] || { usage; die "--domain is required"; }
case "$DSH_DOMAIN" in
  *://*|/*|:* ) die "the domain must be a plain name, e.g. relay.example.com" ;;
esac
case "$DSH_PLAIN_PORT" in
  ''|*[!0-9]*) die "the plain port must be a number" ;;
esac

[ "$DSH_PROXY" = "nginx" ] || [ "$DSH_PROXY" = "none" ] || die "the proxy must be nginx or none"

STATE_DIR="$DSH_DIR/var"
CERT_DIR="$DSH_DIR/etc"
UNIT_NAME="dsh-harmony-relay"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
  RUN_USER="${DSH_USER:-dsh-harmony}"
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
  RUN_USER="${DSH_USER:-$(id -un)}"
else
  SUDO=""
  RUN_USER="${DSH_USER:-$(id -un)}"
fi
if [ -n "$DSH_USER" ]; then
  RUN_USER="$DSH_USER"
fi

# ---------------------------------------------------------------- 1. node

install_node() {
  if [ "$DSH_SKIP_NODE" = "yes" ]; then
    log "node.js installation skipped"
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    local version
    version="$(node --version)"
    log "node.js is there: $version"
    return 0
  fi
  log "node.js is missing, installing it ..."
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq nodejs npm
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y -q nodejs npm
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y -q nodejs npm
  elif command -v apk >/dev/null 2>&1; then
    $SUDO apk add --no-cache nodejs npm
  else
    die "no package manager found — install Node.js 20 or newer and run the script again"
  fi
  command -v node >/dev/null 2>&1 || die "node.js is still missing after the installation"
  log "node.js installed: $(node --version)"
}

install_node

NODE_BIN="$(command -v node)"
NODE_MAJOR="$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 20 ]; then
  warn "node.js $NODE_MAJOR is old, the relay wants 20 or newer"
fi

# ---------------------------------------------------------------- 2. the user and the files

if [ "$RUN_USER" != "root" ]; then
  if ! id "$RUN_USER" >/dev/null 2>&1; then
    log "creating the user $RUN_USER"
    $SUDO useradd --system --create-home --shell /usr/sbin/nologin "$RUN_USER" 2>/dev/null \
      || $SUDO useradd --system --create-home --shell /bin/false "$RUN_USER" \
      || die "the user $RUN_USER could not be created"
  fi
else
  warn "the relay would run as root — that is not intended, please pass --user"
  exit 1
fi

log "installing the relay into $DSH_DIR"
$SUDO mkdir -p "$DSH_DIR" "$STATE_DIR" "$CERT_DIR"
$SUDO cp -R "$SOURCE_DIR/relay" "$DSH_DIR/relay"
if [ -f "$SOURCE_DIR/package.json" ]; then
  $SUDO cp "$SOURCE_DIR/package.json" "$DSH_DIR/package.json"
fi
if [ -f "$SOURCE_DIR/bridge/package.json" ]; then
  $SUDO mkdir -p "$DSH_DIR/bridge"
  $SUDO cp "$SOURCE_DIR/bridge/package.json" "$DSH_DIR/bridge/package.json"
fi
$SUDO chown -R "$RUN_USER":"$RUN_USER" "$DSH_DIR"
$SUDO chmod 750 "$STATE_DIR"

# ---------------------------------------------------------------- 3. the certificate

CERT_FILE="$CERT_DIR/relay.crt"
KEY_FILE="$CERT_DIR/relay.key"

get_certificate() {
  if [ "$DSH_SKIP_CERT" = "yes" ]; then
    log "the certificate is left alone"
    return 0
  fi
  if command -v certbot >/dev/null 2>&1; then
    log "asking Let's Encrypt for a certificate ..."
    CERTBOT_LOG="$(mktemp)"
    if [ -n "$DSH_EMAIL" ]; then
      EMAIL_ARG="--email $DSH_EMAIL"
    else
      EMAIL_ARG="--register-unsafely-without-email"
    fi
    # The ACME challenge answers on port 80, so it has to be open while certbot runs.
    if command -v ufw >/dev/null 2>&1; then
      $SUDO ufw allow 80/tcp >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null 2>&1; then
      $SUDO firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
      $SUDO firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    # shellcheck disable=SC2086
    if $SUDO certbot certonly --non-interactive --agree-tos $EMAIL_ARG \
        --standalone -d "$DSH_DOMAIN" >"$CERTBOT_LOG" 2>&1; then
      tail -n 3 "$CERTBOT_LOG" || true
      CERT_FILE="/etc/letsencrypt/live/$DSH_DOMAIN/fullchain.pem"
      KEY_FILE="/etc/letsencrypt/live/$DSH_DOMAIN/privkey.pem"
      rm -f "$CERTBOT_LOG"
      log "the certificate is there: $CERT_FILE"
      return 0
    fi
    tail -n 3 "$CERTBOT_LOG" >&2 || true
    rm -f "$CERTBOT_LOG"
    warn "Let's Encrypt did not answer, a self signed certificate is used instead"
  fi
  if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    log "the self signed certificate is already there"
    return 0
  fi
  log "creating a self signed certificate ..."
  $SUDO openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "$KEY_FILE" -out "$CERT_FILE" \
    -subj "/CN=$DSH_DOMAIN" >/dev/null 2>&1 \
    || die "the self signed certificate could not be created"
  $SUDO chown "$RUN_USER":"$RUN_USER" "$CERT_FILE" "$KEY_FILE"
  $SUDO chmod 600 "$KEY_FILE"
  log "the certificate is there: $CERT_FILE"
  log "the phones and the desktop have to trust it — see the notes below"
}

get_certificate

# ---------------------------------------------------------------- 4. the config file

CONFIG_FILE="$DSH_DIR/relay.config.json"
log "writing $CONFIG_FILE"
if [ "$DSH_PROXY" = "nginx" ]; then
  RELAY_TLS_PORT=0
  RELAY_TLS_CERT=""
  RELAY_TLS_KEY=""
else
  RELAY_TLS_PORT=443
  RELAY_TLS_CERT="$CERT_FILE"
  RELAY_TLS_KEY="$KEY_FILE"
fi

$SUDO tee "$CONFIG_FILE" >/dev/null <<CONFIG
{
  "port": $DSH_PLAIN_PORT,
  "host": "127.0.0.1",
  "tlsPort": $RELAY_TLS_PORT,
  "tlsCert": "$RELAY_TLS_CERT",
  "tlsKey": "$RELAY_TLS_KEY",
  "publicUrl": "https://$DSH_DOMAIN",
  "accountsFile": "$STATE_DIR/accounts.json",
  "bridgePort": 8787
}
CONFIG
$SUDO chown "$RUN_USER":"$RUN_USER" "$CONFIG_FILE"

# ---------------------------------------------------------------- 5. the account registry

ACCOUNTS_FILE="$STATE_DIR/accounts.json"
if [ ! -f "$ACCOUNTS_FILE" ]; then
  log "creating the first account of the relay ..."
  $SUDO -u "$RUN_USER" "$NODE_BIN" "$DSH_DIR/relay/src/cli.js" \
    --config "$CONFIG_FILE" --account-create --account-name "relay $DSH_DOMAIN" \
    --account-file "$ACCOUNTS_FILE" || die "the account could not be created"
  $SUDO chown "$RUN_USER":"$RUN_USER" "$ACCOUNTS_FILE"
  $SUDO chmod 600 "$ACCOUNTS_FILE"
fi

# ---------------------------------------------------------------- 6. the systemd unit

UNIT_FILE="/etc/systemd/system/$UNIT_NAME.service"
log "writing $UNIT_FILE"
$SUDO tee "$UNIT_FILE" >/dev/null <<UNIT
[Unit]
Description=DSH Harmony relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_USER
WorkingDirectory=$DSH_DIR
ExecStart=$NODE_BIN $DSH_DIR/relay/src/cli.js --config $CONFIG_FILE
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$STATE_DIR

[Install]
WantedBy=multi-user.target
UNIT

$SUDO systemctl daemon-reload
$SUDO systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || true
$SUDO systemctl restart "$UNIT_NAME"

# ---------------------------------------------------------------- 7. the reverse proxy

if [ "$DSH_PROXY" = "nginx" ]; then
  if ! command -v nginx >/dev/null 2>&1; then
    log "installing nginx ..."
    if command -v apt-get >/dev/null 2>&1; then
      $SUDO apt-get update -qq
      $SUDO apt-get install -y -qq nginx
    elif command -v dnf >/dev/null 2>&1; then
      $SUDO dnf install -y -q nginx
    elif command -v yum >/dev/null 2>&1; then
      $SUDO yum install -y -q nginx
    else
      die "nginx could not be installed — install it and run the script again, or use --proxy none"
    fi
  fi
  SITE_FILE="/etc/nginx/sites-available/$UNIT_NAME"
  log "writing $SITE_FILE"
  $SUDO tee "$SITE_FILE" >/dev/null <<NGINX
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DSH_DOMAIN;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;

    location / {
        proxy_pass http://127.0.0.1:$DSH_PLAIN_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINX
  if command -v ufw >/dev/null 2>&1; then
    $SUDO ufw allow 443/tcp >/dev/null 2>&1 || true
    $SUDO ufw deny 8788/tcp >/dev/null 2>&1 || true
    # Port 80 stays open: it is only used for the ACME challenge of the renewal.
    $SUDO ufw allow 80/tcp >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1; then
    $SUDO firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
    $SUDO firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
    $SUDO firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  $SUDO ln -sf "$SITE_FILE" "/etc/nginx/sites-enabled/$UNIT_NAME" 2>/dev/null || true
  $SUDO rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  if $SUDO nginx -t >/dev/null 2>&1; then
    $SUDO systemctl reload nginx || $SUDO systemctl restart nginx
  else
    warn "the nginx configuration is broken — run: nginx -t"
  fi
fi

# ---------------------------------------------------------------- the notes

sleep 1
if $SUDO systemctl is-active --quiet "$UNIT_NAME"; then
  STATUS="the relay runs"
else
  STATUS="the relay does NOT run — look at: journalctl -u $UNIT_NAME"
fi

cat <<NOTES

[deploy] ------------------------------------------------------------------
[deploy] $STATUS
[deploy] the domain is: https://$DSH_DOMAIN
[deploy] the desktop bridge points at it with: wss://$DSH_DOMAIN/bridge
[deploy] the config file of the desktop is: %USERPROFILE%\\.dsh-harmony-bridge\\bridge.config.json
[deploy]
[deploy] the desktop side — write this file on the computer:
[deploy]
[deploy]   {
[deploy]     "relay": "wss://$DSH_DOMAIN/bridge",
[deploy]     "relayPublicUrl": "https://$DSH_DOMAIN",
[deploy]     "deviceName": "my computer"
[deploy]   }
[deploy]
[deploy] the commands that show what is going on:
[deploy]   systemctl status $UNIT_NAME
[deploy]   journalctl -u $UNIT_NAME -f
[deploy]   nginx -t
[deploy]
[deploy] only port 443 carries the relay. The plain port $DSH_PLAIN_PORT of the relay is
[deploy] bound to 127.0.0.1, so only the reverse proxy reaches it.
[deploy] port 80 is open for the ACME challenge only (the renewal of the certificate);
[deploy] close it with: ufw deny 80/tcp — but then the renewal has to be done by hand.
[deploy] ------------------------------------------------------------------

NOTES
