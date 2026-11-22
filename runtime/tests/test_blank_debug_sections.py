#!/usr/bin/env python3
"""The packaged Node/ORT copies lose only their DWARF bytes; nothing else in the ELF moves."""
import importlib.util
from pathlib import Path
import struct
import sys
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('rtbuild', HERE / 'lib/rtbuild.py')
rt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rt)


def elf(debug_offset=0x100):
    """ELF64: one PT_LOAD over [0, 0x100), .text inside it, .debug_info, .shstrtab, section table."""
    names = b'\0.text\0.debug_info\0.shstrtab\0'
    data = bytearray(0x140)
    struct.pack_into('<16sHHIQQQIHHHHHH', data, 0, b'\x7fELF\x02\x01\x01' + bytes(9), 3, 183, 1, 0,
                     64, 0x140, 0, 64, 56, 1, 64, 4, 3)
    struct.pack_into('<IIQQQQQQ', data, 64, 1, 5, 0, 0, 0, 0x100, 0x100, 0x1000)
    data[0x78:0x88] = b'\xaa' * 16
    data[0x100:0x120] = b'\xdb' * 32
    data[0x120:0x120 + len(names)] = names
    for i, (name, typ, flags, off, size) in enumerate([
            (0, 0, 0, 0, 0), (1, 1, 6, 0x78, 16), (7, 1, 0, debug_offset, 32), (19, 3, 0, 0x120, len(names))]):
        data += struct.pack('<IIQQQQIIQQ', name, typ, flags, 0, off, size, 0, 0, 1, 0)
    return bytes(data)


class BlankDebugSectionsTest(unittest.TestCase):
    def test_only_debug_bytes_and_their_size_change(self):
        original = elf()
        blanked = rt.blank_debug_sections(original)
        self.assertEqual(len(blanked), len(original))
        self.assertEqual(blanked[0x100:0x120], bytes(32))
        size_field = 0x140 + 2 * 64 + 32
        self.assertEqual(struct.unpack_from('<Q', blanked, size_field)[0], 0)
        rest = lambda b: b[:0x100] + b[0x120:size_field] + b[size_field + 8:]
        self.assertEqual(rest(blanked), rest(original))  # headers, PT_LOAD, .text, section table
        with self.assertRaises(SystemExit):  # a debug section inside PT_LOAD is never touched
            rt.blank_debug_sections(elf(debug_offset=0x80))


if __name__ == '__main__':
    unittest.main()
