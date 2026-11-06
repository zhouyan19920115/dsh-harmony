# -*- coding: utf-8 -*-
"""读 HarmonyOS 发布/内部测试 Profile(.p7b) 的关键字段。

用法:
    python tools/p7b-info.py <profile.p7b> [--udid <设备UDID>]

p7b 是 CMS SignedData, 明文 JSON 就在二进制里(不用验签就能读)。
"""
from __future__ import annotations

import json
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def read_text_fields(data: bytes) -> dict:
    out: dict[str, str] = {}
    for key in (b"type", b"version-name", b"version-code", b"bundle-name",
                b"app-identifier", b"app-distribution-type", b"apl",
                b"developer-id", b"uuid"):
        i = data.find(b'"' + key + b'"')
        if i < 0:
            continue
        m = re.match(rb'"[a-z-]+"\s*:\s*"([^"]*)"', data[i:])
        if m:
            out[key.decode()] = m.group(1).decode("utf-8", "replace")
    return out


def find_udid(data: bytes, udid: str) -> bool:
    """UDID 在 profile 里可能是裸串, 也可能是数组/对象里的字段。"""
    if not udid:
        return False
    if udid.lower().encode() in data.lower():
        return True
    # 有的实现把 UDID 拆成多段存
    parts = [udid[i:i + 8] for i in range(0, len(udid), 8)]
    return all(p.lower().encode() in data.lower() for p in parts)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    want_udid = ""
    if "--udid" in sys.argv:
        want_udid = sys.argv[sys.argv.index("--udid") + 1]

    with open(path, "rb") as fh:
        data = fh.read()

    fields = read_text_fields(data)
    print(f"=== {path} ===")
    for k in ("type", "app-distribution-type", "bundle-name", "version-name",
              "version-code", "app-identifier", "apl", "uuid"):
        print(f"  {k:<24} {fields.get(k, '(未找到)')}")

    m = re.search(rb'"validity"\s*:\s*\{[^}]*\}', data)
    if m:
        print(f"  {'validity':<24} {m.group(0).decode('utf-8', 'replace')}")
        nb = re.search(rb'"not-before"\s*:\s*(\d+)', m.group(0))
        na = re.search(rb'"not-after"\s*:\s*(\d+)', m.group(0))
        if nb and na:
            import datetime
            f = lambda t: datetime.datetime.fromtimestamp(int(t)).strftime("%Y-%m-%d")
            print(f"  {'有效期':<24} {f(nb.group(1))} ~ {f(na.group(1))}")

    # 设备列表
    dev = re.search(rb'"device-info"\s*:\s*\[(.*?)\]', data, re.S)
    if dev:
        ids = re.findall(rb'"([0-9A-Fa-f]{32,})"', dev.group(1))
        print(f"  {'device-info':<24} {len(ids)} 台")
        for i in ids:
            print(f"      {i.decode()}")
    else:
        print(f"  {'device-info':<24} (无 —— 这是普通 app_gallery 发布 Profile，"
              f"不是内部测试 Profile)")

    if want_udid:
        ok = find_udid(data, want_udid)
        print(f"  {'包含目标设备 UDID':<24} {'✓ 是' if ok else '✗ 否'}")
        print(f"      目标: {want_udid}")

    print()
    print("判定:")
    t = fields.get("type", "")
    dt = fields.get("app-distribution-type", "")
    if t == "release" and dt == "app_gallery":
        print("  普通发布 Profile(app_gallery) —— **hdc 装不上**, 只能走 AGC 邀请测试分发")
    elif t == "release":
        print("  发布类 Profile —— 可能是内部测试 Profile, 可以装")
    elif t == "debug":
        print("  debug Profile —— hdc 可以直接装")
    else:
        print("  类型未知, 看上面的字段人工判断")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
