#!/bin/bash
# 看 Parse Error 爆发那个窗口里, 中继到底在跟谁说话。
set -u

echo "=== 中继监听的端口 ==="
sudo ss -tlnp 2>/dev/null | grep -E 'node|LISTEN' | head -12

echo
echo "=== nginx 里跟 relay 有关的 server 块 ==="
sudo nginx -T 2>/dev/null | grep -nE 'server_name|listen|proxy_pass|dsh-harmony|8788' | head -30

echo
echo "=== 14:02:20 - 14:03:10 的完整日志 ==="
sudo journalctl -u dsh-harmony-relay --since '2026-10-25 14:02:20' --until '2026-10-25 14:03:10' --no-pager -o short-iso | head -60

echo
echo "=== 今天所有 Parse Error 的时间分布(按分钟) ==="
sudo journalctl -u dsh-harmony-relay --since '2026-10-25 00:00' --no-pager -o short-iso \
  | grep 'Parse Error' | cut -c1-16 | sort | uniq -c | sort -rn | head -20
