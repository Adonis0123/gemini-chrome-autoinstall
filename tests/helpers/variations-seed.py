#!/usr/bin/env python3
"""Build or inspect a minimal Chrome stored-seed record for tests.

  variations-seed.py write <path> <session_country> <permanent_country> [zstd]
  variations-seed.py read <path>   -> prints "<session>,<permanent>"
"""
import shutil
import subprocess
import sys

ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"


def field(number, value):
    return bytes([(number << 3) | 2, len(value)]) + value


def build(session, permanent):
    return (
        field(1, b"seed-data")
        + bytes([3 << 3, 0x99, 0x01])  # varint 153 (multi-byte), exercises wire type 0
        + field(6, session.encode())
        + field(7, permanent.encode())
        + field(8, b"153.0.8010.53")
    )


def read_varint(data, i):
    result = shift = 0
    while True:
        byte = data[i]
        i += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return result, i


def countries(data):
    found = {}
    i = 0
    while i < len(data):
        key, i = read_varint(data, i)
        number, wire = key >> 3, key & 7
        if wire == 0:
            _, i = read_varint(data, i)
        else:
            length, i = read_varint(data, i)
            found[number] = data[i:i + length].decode()
            i += length
    return found.get(6, ""), found.get(7, "")


def main():
    if sys.argv[1] == "write":
        path, session, permanent = sys.argv[2:5]
        data = build(session, permanent)
        if len(sys.argv) > 5 and sys.argv[5] == "zstd":
            data = subprocess.run(["zstd", "-qc"], input=data, stdout=subprocess.PIPE, check=True).stdout
        with open(path, "wb") as handle:
            handle.write(data)
        return
    with open(sys.argv[2], "rb") as handle:
        data = handle.read()
    if data.startswith(ZSTD_MAGIC):
        if shutil.which("zstd") is None:
            sys.exit("zstd required")
        data = subprocess.run(["zstd", "-dc"], input=data, stdout=subprocess.PIPE, check=True).stdout
    print(",".join(countries(data)))


main()
