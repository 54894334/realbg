#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""第 1 步：Mach-O 头部 + 全部 load command + section 布局"""
import struct, sys, os, json

PATH = sys.argv[1] if len(sys.argv) > 1 else r"D:\qq系统\工具压缩包\懒触连点器可逆向.dylib"
d = open(PATH, 'rb').read()

magic = d[:4]
print('size      :', len(d))
print('magic     :', magic.hex(), '=>', 'MH_MAGIC_64 (thin arm64)' if magic == b'\xcf\xfa\xed\xfe' else 'other')

cputype, cpusub, ftype, ncmds, sizeofcmds, flags, res = struct.unpack_from('<IIIIIII', d, 4)
print('cputype   : 0x%x  subtype 0x%x  filetype %d' % (cputype, cpusub, ftype))
print('ncmds     :', ncmds, ' sizeofcmds', sizeofcmds, ' flags 0x%x' % flags)

LC = {
    0x19: 'LC_SEGMENT_64', 0x2: 'LC_SYMTAB', 0xb: 'LC_DYSYMTAB',
    0x22: 'LC_DYLD_INFO', 0x80000022: 'LC_DYLD_INFO_ONLY',
    0x26: 'LC_FUNCTION_STARTS', 0x29: 'LC_CODE_SIGNATURE',
    0x1d: 'LC_CODE_SIGNATURE', 0x2c: 'LC_ENCRYPTION_INFO_64',
    0xc: 'LC_LOAD_DYLIB', 0x18: 'LC_LOAD_WEAK_DYLIB', 0x1f: 'LC_REEXPORT_DYLIB',
    0x80000034: 'LC_BUILD_VERSION', 0x32: 'LC_BUILD_VERSION',
    0x80000028: 'LC_MAIN', 0x80000033: 'LC_DYLD_CHAINED_FIXUPS',
    0x80000035: 'LC_DYLD_EXPORTS_TRIE', 0x1b: 'LC_UUID', 0xe: 'LC_LOAD_DYLINKER',
    0x8000001c: 'LC_RPATH', 0x25: 'LC_DATA_IN_CODE', 0x2a: 'LC_SOURCE_VERSION',
}
LC.setdefault(0x1d, 'LC_CODE_SIGNATURE')
LC[0x1d] = 'LC_CODE_SIGNATURE'
LC[0x29] = 'LC_CODE_SIGNATURE'

off = 32
cmds = []
segs = []
for i in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<II', d, off)
    name = LC.get(cmd, 'CMD_0x%x' % cmd)
    info = ''
    if cmd == 0x19:  # SEGMENT_64
        segname = d[off + 8:off + 8 + 16].rstrip(b'\0').decode('utf-8', 'replace')
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', d, off + 24)
        maxprot, initprot, nsects, flags2 = struct.unpack_from('<IIII', d, off + 56)
        info = '%-12s vm=0x%x size=0x%x fileoff=0x%x filesize=0x%x nsects=%d' % (
            segname, vmaddr, vmsize, fileoff, filesize, nsects)
        so = off + 72
        sect = []
        for s in range(nsects):
            sname = d[so:so + 16].rstrip(b'\0').decode('utf-8', 'replace')
            sgname = d[so + 16:so + 32].rstrip(b'\0').decode('utf-8', 'replace')
            addr, size = struct.unpack_from('<QQ', d, so + 32)
            offset, align, reloff, nreloc, sflags = struct.unpack_from('<IIIII', d, so + 48)
            sect.append((sgname, sname, addr, size, offset, sflags))
            so += 80
        segs.append(dict(seg=segname, vmaddr=vmaddr, vmsize=vmsize, fileoff=fileoff,
                         filesize=filesize, nsects=nsects, sections=sect))
    elif cmd == 0x2:
        symoff, nsyms, stroff, strsize = struct.unpack_from('<IIII', d, off + 8)
        info = 'symoff=0x%x nsyms=%d stroff=0x%x strsize=%d' % (symoff, nsyms, stroff, strsize)
    elif cmd == 0x26:
        dataoff, datasize = struct.unpack_from('<II', d, off + 8)
        info = 'off=0x%x size=%d' % (dataoff, datasize)
    elif cmd in (0x29, 0x1d):
        dataoff, datasize = struct.unpack_from('<II', d, off + 8)
        info = 'off=0x%x size=%d' % (dataoff, datasize)
    elif cmd in (0xc, 0x18, 0x1f):
        nameoff = struct.unpack_from('<I', d, off + 8)[0]
        s = d[off + nameoff:].split(b'\0')[0].decode('utf-8', 'replace')
        info = s
    elif cmd == 0x80000034 or cmd == 0x32:
        platform, minos, sdk, ntools = struct.unpack_from('<IIII', d, off + 8)
        info = 'platform=%d minos=0x%x sdk=0x%x' % (platform, minos, sdk)
    elif cmd == 0x80000033:
        dataoff, datasize = struct.unpack_from('<II', d, off + 8)
        info = 'off=0x%x size=%d' % (dataoff, datasize)
    elif cmd == 0x80000035:
        dataoff, datasize = struct.unpack_from('<II', d, off + 8)
        info = 'off=0x%x size=%d' % (dataoff, datasize)
    elif cmd == 0x1b:
        info = d[off + 8:off + 24].hex()
    cmds.append((name, cmdsize, info))
    off += cmdsize

for name, size, info in cmds:
    print('%-24s %s' % (name, info))

print('\n=== SECTIONS ===')
for sg in segs:
    print('\n[%s] vm=0x%x fileoff=0x%x' % (sg['seg'], sg['vmaddr'], sg['fileoff']))
    for g, n, addr, size, offset, fl in sg['sections']:
        print('   %-12s %-20s addr=0x%08x size=0x%-7x off=0x%-7x flags=0x%08x' % (g, n, addr, size, offset, fl))

json.dump(dict(segs=[{k: v for k, v in s.items() if k != 'sections'} for s in segs],
               cmds=[list(c) for c in cmds]),
          open(os.path.join(os.path.dirname(__file__), '..', 'analysis', 'header.json'), 'w'), indent=1)
