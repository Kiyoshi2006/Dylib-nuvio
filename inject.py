#!/usr/bin/env python3
import struct, sys
exe, name = sys.argv[1], sys.argv[2]
buf = bytearray(open(exe, 'rb').read())
magic, = struct.unpack_from('<I', buf, 0)
assert magic == 0xFEEDFACF, 'Expected thin 64-bit Mach-O arm64 executable'
ncmds, sizeofcmds = struct.unpack_from('<II', buf, 16)
off, minoff = 32, 1 << 62
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', buf, off)
    if cmd in (0x0C, 0x80000018):
        nameoff, = struct.unpack_from('<I', buf, off + 8)
        if bytes(buf[off + nameoff:off + size]).split(b'\0')[0].decode(errors='ignore') == name:
            print('Already injected:', name); sys.exit(0)
    if cmd == 0x19:
        nsects, = struct.unpack_from('<I', buf, off + 64)
        so = off + 72
        for _ in range(nsects):
            sz, = struct.unpack_from('<Q', buf, so + 40)
            so_off, = struct.unpack_from('<I', buf, so + 48)
            if so_off and sz: minoff = min(minoff, so_off)
            so += 80
    off += size
raw = name.encode() + b'\0'
cmdsize = (24 + len(raw) + 7) & ~7
used = 32 + sizeofcmds
assert used + cmdsize <= minoff, 'Not enough unused header space'
cmdbytes = struct.pack('<IIIIII', 0x80000018, cmdsize, 24, 2, 0x10000, 0x10000) + raw
cmdbytes += b'\0' * (cmdsize - len(cmdbytes))
assert all(b == 0 for b in buf[used:used + cmdsize]), 'Header destination is not zero-filled'
buf[used:used + cmdsize] = cmdbytes
struct.pack_into('<II', buf, 16, ncmds + 1, sizeofcmds + cmdsize)
open(exe, 'wb').write(buf)
print('Injected', name, '-', cmdsize, 'bytes')
