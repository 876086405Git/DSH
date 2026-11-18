"""Run with the guest's Python, including with libraries on /workspace."""
import array
import csv
import ctypes
import datetime
import decimal
import io
import math
import select
import socket
import sqlite3
import ssl
import sys
import unicodedata
import zlib

assert math.isclose(math.sqrt(2) ** 2, 2)
assert zlib.decompress(zlib.compress(b"dsh-ios")) == b"dsh-ios"
assert array.array("i", [1, 2]).tolist() == [1, 2]
assert select.select([], [], [], 0) == ([], [], [])
with socket.socket() as sock:
    assert sock.fileno() >= 0
assert ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
assert ctypes.sizeof(ctypes.c_void_p) == 8
with sqlite3.connect(":memory:") as db:
    assert db.execute("select 6 * 7").fetchone() == (42,)
assert datetime.date(2026, 11, 11).isoformat() == "2026-11-11"
assert decimal.Decimal("0.1") + decimal.Decimal("0.2") == decimal.Decimal("0.3")
assert next(csv.reader(io.StringIO("a,b\n"))) == ["a", "b"]
assert unicodedata.normalize("NFC", "e\u0301") == "\u00e9"
print("PYTHON_MODULES_OK", sys.version.split()[0], sys.executable)
print("math:", math.__file__)
print("ssl:", ssl.OPENSSL_VERSION)
