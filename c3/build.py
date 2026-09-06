"""Compile fresh C3 scripts and pack its existing 128 KiB LuaDB partition.

Layout: openLuat/LuatOS luat/vfs/luat_fs_luadb.c. No device writes.
"""
import hashlib
import os
import gzip
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parent
COMPILER = os.environ.get("LUAC", "luac_536")
SOURCES = ["main", "config", "modem", "euicc", "sms", "debug_link", "settings", "web", "outbound", "forward", "lpa", "bpp", "notifications", "radio"]


def tlv(kind, data):
    return bytes([kind, len(data)]) + data


def header(data):
    data += b"\xfe\x02"
    return data + struct.pack("<H", sum(data) & 0xffff)


def main():
    out = ROOT / "build"
    out.mkdir(exist_ok=True)
    files, sizes = [], {}
    for name in SOURCES:
        src, dest = ROOT / (name + ".lua"), out / (name + ".luac")
        subprocess.run([str(COMPILER), "-s", "-o", str(dest), str(src)], check=True)
        data = dest.read_bytes()
        assert data[:17] == bytes.fromhex("1b4c7561530019930d0a1a0a0404040404"), "Need Lua 5.3 / 32-bit compiler"
        files.append((dest.name.encode(), data))
        sizes[src.name] = {"source": src.stat().st_size, "compiled": len(data)}
    page = gzip.compress((ROOT / "panel.html").read_bytes(), mtime=0)
    files.append((b"panel.html.gz", page))
    sizes["panel.html.gz"] = {"compiled": len(page)}
    magic = tlv(1, bytes.fromhex("5aa55aa5"))
    database = header(magic + tlv(2, struct.pack("<H", 2)) +
                      tlv(3, struct.pack("<I", 24)) + tlv(4, struct.pack("<H", len(files))))
    for name, data in files:
        database += header(magic + tlv(2, name) + tlv(3, struct.pack("<I", len(data)))) + data
    assert len(database) <= 0x20000, "Script partition full"
    (out / "script.bin").write_bytes(database)
    report = {"files": sizes, "script_bytes": len(database), "partition_bytes": 0x20000,
              "remaining_bytes": 0x20000 - len(database), "flash_offset": "0x390000",
              "sha256": hashlib.sha256(database).hexdigest()}
    (out / "size-report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
