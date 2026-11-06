#!/usr/bin/env python3
"""Upload a file to the relay server **in binary** (SFTP).

The helper `tools/relay-ssh.py --stdin` converts CRLF to LF (it is meant for shell scripts),
which would corrupt a binary file such as a zip ⇒ this one is byte exact.

    python tools/relay-upload.py <local file> <remote path>
"""
import os
import sys

import paramiko

HOST = os.environ.get('RELAY_HOST', 'YOUR_RELAY_IP')
USER = os.environ.get('RELAY_USER', 'ubuntu')
PASSWORD_FILE = os.environ.get('RELAY_PASSWORD_FILE', r'C:\Users\YourName\Desktop\key.txt')


def main() -> int:
    if len(sys.argv) < 3:
        print('usage: relay-upload.py <local file> <remote path>')
        return 2
    local_path, remote_path = sys.argv[1], sys.argv[2]
    with open(PASSWORD_FILE, 'r', encoding='utf-8') as handle:
        password = handle.read().strip()

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=password, timeout=20,
                   look_for_keys=False, allow_agent=False)
    sftp = client.open_sftp()
    sftp.put(local_path, remote_path)
    sftp.close()
    size = os.path.getsize(local_path)
    print(f'uploaded {size} bytes -> {remote_path}')
    client.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
