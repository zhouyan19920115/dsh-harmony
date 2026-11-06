#!/bin/bash
# 给 dsh-relay.example.com 这个站点也加上静态的隐私政策/用户协议(/legal/)。
# 之前只有 YOUR_RELAY_IP 那个 vhost 有 —— 现在对外只用域名, IP 不再对外展示 ✓
set -e
CONF=/etc/nginx/sites-enabled/dsh-relay-dsh-relay.example.com
python3 - "$CONF" <<'PY'
import sys
path = sys.argv[1]
block = '''    # DSH Harmony privacy policy / user agreement (static pages).
    location = /legal { return 301 /legal/; }

    location /legal/ {
        alias /var/www/dsh-legal/;
        index index.html;
        try_files $uri $uri/ =404;
    }
'''
with open(path, 'r', encoding='utf-8') as fh:
    text = fh.read()
if 'location /legal/' in text:
    print('[skip] /legal/ already in', path)
else:
    marker = '    location / {'
    idx = text.find(marker)
    if idx < 0:
        raise SystemExit('marker not found')
    text = text[:idx] + block + text[idx:]
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(text)
    print('[ok] inserted /legal/ into', path)
PY
sudo nginx -t
sudo systemctl reload nginx
echo '[done] nginx reloaded'
