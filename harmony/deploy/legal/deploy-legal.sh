#!/bin/bash
# 在广州中继机的 nginx 里加一个静态站点: /legal/ => 隐私政策 / 用户协议
# 只在 /legal/ 前缀上生效, 其余路径照旧反代给 relay(8788) ✓
set -e
CONF=/etc/nginx/sites-enabled/zz-dsh-harmony-relay.conf
BLOCK='    # DSH Harmony privacy policy / user agreement (static pages).
    location /legal/ {
        alias /var/www/dsh-legal/;
        index index.html;
        try_files $uri $uri/ =404;
    }
'
if grep -q "location /legal/" "$CONF"; then
  echo "[skip] /legal/ already in $CONF"
else
  python3 - "$CONF" <<'PY'
import sys
path = sys.argv[1]
block = '''    # DSH Harmony privacy policy / user agreement (static pages).
    location /legal/ {
        alias /var/www/dsh-legal/;
        index index.html;
        try_files $uri $uri/ =404;
    }
'''
with open(path, 'r', encoding='utf-8') as fh:
    text = fh.read()
marker = '    location / {'
idx = text.find(marker)
if idx < 0:
    raise SystemExit('marker not found')
text = text[:idx] + block + text[idx:]
with open(path, 'w', encoding='utf-8') as fh:
    fh.write(text)
print('[ok] inserted /legal/ location')
PY
fi
sudo nginx -t
sudo systemctl reload nginx
echo '[done] nginx reloaded'
