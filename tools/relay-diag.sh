#!/bin/bash
# 中继日志诊断: 把 "Parse Error" 的时间戳和 nginx 的 400 放在一起对。
#
# 目的: 搞清楚那些 Parse Error 到底是**我们的流量**打坏了, 还是**公网扫描器**在敲门。
# (公网上每个开放的 443 端口都会持续收到扫描: TLS 握手字节、HTTP/2 前言、CONNECT 代理探测…)
set -u
LOG=/var/log/nginx/access.log
JL=$(sudo journalctl -u dsh-harmony-relay --since '2026-10-25 00:00' --no-pager -o short-iso)

echo "=== Parse Error 的时间戳 (最近 15 条) ==="
echo "$JL" | grep 'Parse Error' | cut -c1-19 | tail -15

echo
echo "=== Parse Error 总数 ==="
echo "$JL" | grep -c 'Parse Error'

echo
echo "=== nginx 的 400 (最近 15 条, 带时间) ==="
if [ -f "$LOG" ]; then
  grep ' 400 ' "$LOG" | tail -15 | sed 's/.*\(\[[^]]*\]\).*"[^"]*" 400 \([0-9]*\).*/\1  status=400 bytes=\2/'
else
  echo "(没有 $LOG)"
fi

echo
echo "=== nginx 的 400 里, 有多少是"请求行明显不是 HTTP"的(扫描器) ==="
if [ -f "$LOG" ]; then
  grep ' 400 ' "$LOG" | grep -c -v '"[A-Z]\{3\} /'
fi

echo
echo "=== nginx 的 400 里, 有多少来自 127.0.0.1 或本机 IP(我们自己的流量) ==="
if [ -f "$LOG" ]; then
  grep ' 400 ' "$LOG" | grep -c -E '127\.0\.0\.1|119\.91\.123\.134'
fi

echo
echo "=== 中继自己的流量统计(最近 1 小时) ==="
echo "$JL" | tail -400 | grep -c -E 'the stream .* is open|a relay owned request was discarded'
