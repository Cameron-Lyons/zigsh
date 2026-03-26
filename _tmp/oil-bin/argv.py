#!/usr/bin/env python3
import os
import sys


def py2_bytes_repr(b: bytes) -> str:
    out = []
    for by in b:
        if by == 0x5C:  # backslash
            out.append('\\\\')
        elif by == 0x27:  # single quote
            out.append("\\'")
        elif by == 0x09:
            out.append('\\t')
        elif by == 0x0A:
            out.append('\\n')
        elif by == 0x0D:
            out.append('\\r')
        elif 0x20 <= by <= 0x7E:
            out.append(chr(by))
        else:
            out.append(f'\\x{by:02x}')
    return "'" + ''.join(out) + "'"


parts = [py2_bytes_repr(os.fsencode(a)) for a in sys.argv[1:]]
sys.stdout.write('[' + ', '.join(parts) + ']\n')
