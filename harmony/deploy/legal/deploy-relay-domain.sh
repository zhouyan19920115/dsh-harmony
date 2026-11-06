#!/bin/bash
# 让 dsh-relay.example.com 这个域名真正能用:
#   1) nginx 80 端口上给这个域名开一个块 —— /legal/ 给静态的隐私政策/用户协议,
#      其余路径照旧反代给 relay(8788) ✓
#   2) cloudflared 的 ingress 里补上这个域名(之前漏了 ⇒ 域名请求全被 catch-all 打成 404)✓
set -e

# ------------------------------------------------------------------ nginx (80)
CONF=/etc/nginx/sites-enabled/dsh-relay-dsh-relay-example-http.conf
cat > /tmp/dsh-relay-example-http.conf <<'NGINX'
# dsh-relay.example.com over plain http.
#
# The Cloudflare tunnel talks to this port (it terminates the tls at the edge),
# so the privacy policy and the user agreement are served from here too.
server {
    listen 80;
    listen [::]:80;
    server_name dsh-relay.example.com;

    access_log /var/log/nginx/dsh-relay-example-http.access.log;
    error_log  /var/log/nginx/dsh-relay-example-http.error.log;

    location = /legal { return 301 /legal/; }

    # DSH Harmony privacy policy / user agreement (static pages).
    location /legal/ {
        alias /var/www/dsh-legal/;
        index index.html;
        try_files $uri $uri/ =404;
    }

    # everything else is the relay itself (rest + websocket)
    location / {
        proxy_pass http://127.0.0.1:8788;
        proxy_http_version 1.1;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 30s;
        proxy_socket_keepalive on;
    }
}
NGINX
sudo cp /tmp/dsh-relay-example-http.conf "$CONF"
sudo nginx -t
sudo systemctl reload nginx
echo '[ok] nginx: the http vhost for dsh-relay.example.com is in place'

# ------------------------------------------------------------------ cloudflared
TUNNEL=/etc/cloudflared/config.yml
python3 - "$TUNNEL" <<'PY'
import sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as fh:
    text = fh.read()
if 'hostname: dsh-relay.example.com' in text:
    print('[skip] the tunnel already knows dsh-relay.example.com')
else:
    rule = ('  - hostname: dsh-relay.example.com\n'
            '    service: http://127.0.0.1:80\n')
    marker = '  - service: http_status:404'
    idx = text.find(marker)
    if idx < 0:
        raise SystemExit('ingress marker not found')
    text = text[:idx] + rule + text[idx:]
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(text)
    print('[ok] tunnel: dsh-relay.example.com -> nginx :80')
PY
sudo systemctl restart cloudflared-dsh-relay-tunnel
sleep 5
systemctl is-active cloudflared-dsh-relay-tunnel
echo '[done]'
