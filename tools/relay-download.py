#!/usr/bin/env python3
"""Download a file from the relay server (SFTP, binary safe).

    python tools/relay-download.py <remote path> <local path>
"""
import os
import sys

import paramiko

HOST = os.environ.get('RELAY_HOST', 'YOUR_RELAY_IP')
USER = os.environ.get('RELAY_USER', 'ubuntu')
PASSWORD_FILE = os.environ.get('RELAY_PASSWORD_FILE', r'C:\Users\YourName\Desktop\key.txt')


def main() -> int:
    if len(sys.argv) < 3:
        print('usage: relay-download.py <remote path> <local path>')
        return 2
    remote_path, local_path = sys.argv[1], sys.argv[2]
    with open(PASSWORD_FILE, 'r', encoding='utf-8') as handle:
        password = handle.read().strip()

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=password, timeout=20,
                   look_for_keys=False, allow_agent=False)
    sftp = client.open_sftp()
    sftp.get(remote_path, local_path)
    sftp.close()
    print(f'downloaded {remote_path} -> {local_path}')
    client.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
