#!/usr/bin/env python3
"""在云中继服务器上跑一条命令。

密码**不写在这个文件里** ⇒ 从环境变量 RELAY_PASSWORD 或者一个指定的文件读 ⇒
仓库里不落明文口令 ✓

用法:
    python tools/relay-ssh.py "ls -la /opt/dsh-harmony"
    python tools/relay-ssh.py --stdin < 本地文件 > 远端文件
"""
import argparse
import os
import sys

import paramiko

HOST = os.environ.get('RELAY_HOST', 'YOUR_RELAY_IP')
USER = os.environ.get('RELAY_USER', 'ubuntu')


def password() -> str:
    from_env = os.environ.get('RELAY_PASSWORD')
    if from_env:
        return from_env.strip()
    path = os.environ.get('RELAY_PASSWORD_FILE', r'C:\Users\YourName\Desktop\key.txt')
    with open(path, 'r', encoding='utf-8') as handle:
        return handle.read().strip()


def main() -> int:
    # Windows 控制台默认是 GBK, 远端日志里有非 GBK 的字符 ⇒ 直接崩 ⇒ 换成 UTF-8 且容错 ✓
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except AttributeError:
        pass

    parser = argparse.ArgumentParser()
    parser.add_argument('command', nargs='*')
    parser.add_argument('--stdin', action='store_true', help='把标准输入送到远端')
    parser.add_argument('--upload', help='本地文件路径(配合 --stdin)')
    args = parser.parse_args()

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=password(), timeout=20,
                   look_for_keys=False, allow_agent=False)

    if args.stdin:
        payload = sys.stdin.buffer.read()
        # 传的是 shell 脚本 ⇒ 必须换成 LF。Windows 上写出来的文件是 CRLF,
        # 直接扔给 bash 会报 `$'\r': command not found` ⇒ 这里换掉 ✓
        if payload.endswith(b'\r\n') or b'\r\n' in payload:
            payload = payload.replace(b'\r\n', b'\n')
        sftp = client.open_sftp()
        remote = args.upload or '/tmp/upload.bin'
        with sftp.open(remote, 'wb') as handle:
            handle.write(payload)
        sftp.close()
        print(f'uploaded {len(payload)} bytes -> {remote}')
        client.close()
        return 0

    command = ' '.join(args.command)
    stdin, stdout, stderr = client.exec_command(command, timeout=180)
    out = stdout.read().decode('utf-8', 'replace')
    err = stderr.read().decode('utf-8', 'replace')
    code = stdout.channel.recv_exit_status()
    sys.stdout.write(out)
    if err:
        sys.stderr.write(err)
    client.close()
    return code


if __name__ == '__main__':
    sys.exit(main())
