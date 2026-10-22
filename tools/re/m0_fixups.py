#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""m0_fixups.py — Mach-O chained fixups 解码

老工具（m2/m4）假设 rebase/bind 表可用；iOS 16+ 的二进制普遍改成
LC_DYLD_CHAINED_FIXUPS，__objc_classlist 里的"指针"其实是 64 位压缩链指针，
直接当地址读会得到垃圾。这个模块把任意 vm 地址的槽位还原成
  ('rebase', 目标vm地址)  或  ('bind', 符号名)
"""
import struct, sys, os, json

PTR_64 = 2
PTR_64_OFFSET = 6
PTR_ARM64E = 1
PTR_ARM64E_OFFSET = 7
PTR_ARM64E_USERLAND = 9
PTR_ARM64E_USERLAND24 = 12


class MachO(object):
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        d = self.d
        magic, cputype, cpusub, ftype, ncmds = struct.unpack_from('<IiiII', d, 0)
        assert magic == 0xfeedfacf, 'only thin arm64 MH_MAGIC_64 supported, got %#x' % magic
        self.cputype = cputype
        self.ncmds = ncmds
        self.segs = []          # (name, vmaddr, vmsize, fileoff, filesize)
        self.sects = {}         # sectname -> (vmaddr, size, fileoff)
        self.dylibs = []
        self.fixups_lc = None   # (dataoff, datasize)
        self.symtab = None
        self.export_lc = None
        self.base = None

        lc = 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from('<II', d, lc)
            if cmd == 0x19:
                name = d[lc + 8:lc + 24].rstrip(b'\0').decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', d, lc + 24)
                nsects = struct.unpack_from('<I', d, lc + 64)[0]
                self.segs.append((name, vmaddr, vmsize, fileoff, filesize))
                if name == '__TEXT':
                    self.base = vmaddr
                so = lc + 72
                for _s in range(nsects):
                    sname = d[so:so + 16].rstrip(b'\0').decode()
                    addr, size = struct.unpack_from('<QQ', d, so + 32)
                    off = struct.unpack_from('<I', d, so + 48)[0]
                    self.sects[sname] = (addr, size, off)
                    so += 80
            elif cmd == 0xc:
                noff = struct.unpack_from('<I', d, lc + 8)[0]
                self.dylibs.append(d[lc + noff:].split(b'\0')[0].decode('utf8', 'replace'))
            elif cmd == 0x80000034:   # LC_DYLD_CHAINED_FIXUPS
                self.fixups_lc = struct.unpack_from('<II', d, lc + 8)
            elif cmd == 0x2:          # LC_SYMTAB
                self.symtab = struct.unpack_from('<IIII', d, lc + 8)
            elif cmd == 0x80000022:   # LC_DYLD_EXPORTS_TRIE
                self.export_lc = struct.unpack_from('<II', d, lc + 8)
            lc += cmdsize

        self.symbols = []
        if self.symtab:
            symoff, nsyms, stroff, strsize = self.symtab
            strtab = d[stroff:stroff + strsize]
            for i in range(nsyms):
                n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from('<IBBHQ', d, symoff + i * 16)
                if n_type & 0x01:      # N_STAB
                    continue
                e = strtab.find(b'\0', n_strx)
                self.symbols.append((strtab[n_strx:e].decode('utf8', 'replace'), n_value, n_type))

        self.chains = {}       # seg_offset -> (page_size,pointer_format,page_start list)
        self.imports = []      # (name, lib_ordinal)
        self._starts_off = None
        if self.fixups_lc:
            self._parse_fixups()

    # ---------- 字符串 / 地址换算 ----------
    def vm_to_off(self, vm):
        for name, vmaddr, vmsize, fileoff, filesize in self.segs:
            if vmaddr <= vm < vmaddr + vmsize and filesize:
                return fileoff + (vm - vmaddr)
        return None

    def cstr(self, vm):
        o = self.vm_to_off(vm)
        if o is None:
            return '<bad %#x>' % vm
        e = self.d.find(b'\0', o)
        return self.d[o:e].decode('utf8', 'replace')

    # ---------- chained fixups ----------
    def _parse_fixups(self):
        d = self.d
        base_off, size = self.fixups_lc
        hdr = base_off
        (fixups_version, starts_offset, imports_offset, symbols_offset,
         imports_count, imports_format, symbols_format) = struct.unpack_from('<IIIIIII', d, hdr)
        self.imports_format = imports_format
        # 符号表（导入名）
        sym_base = hdr + symbols_offset
        for i in range(imports_count):
            fo = hdr + imports_offset
            if imports_format == 1:      # DYLD_CHAINED_IMPORT
                v = struct.unpack_from('<I', d, fo + i * 4)[0]
                lib = v & 0xff
                weak = (v >> 8) & 1
                name_off = v >> 9
            elif imports_format == 2:    # DYLD_CHAINED_IMPORT_ADDEND
                v, addend = struct.unpack_from('<Ii', d, fo + i * 8)
                lib = v & 0xff
                weak = (v >> 8) & 1
                name_off = v >> 9
            elif imports_format == 3:    # DYLD_CHAINED_IMPORT_ADDEND64
                v, addend = struct.unpack_from('<QI', d, fo + i * 8)
                lib = v & 0xffff
                weak = (v >> 16) & 1
                name_off = v >> 32
            else:
                raise ValueError('imports_format %d' % imports_format)
            e = d.find(b'\0', sym_base + name_off)
            self.imports.append((d[sym_base + name_off:e].decode('utf8', 'replace'), lib))

        starts = hdr + starts_offset
        seg_count = struct.unpack_from('<I', d, starts)[0]
        self.seg_starts = []
        for i in range(seg_count):
            o = struct.unpack_from('<I', d, starts + 4 + i * 4)[0]
            self.seg_starts.append(None if o == 0 else starts + o)
        # 解析每段
        for i, so in enumerate(self.seg_starts):
            if so is None or i >= len(self.segs):
                continue
            ssize, page_size, pointer_format, segment_offset = struct.unpack_from('<IHHQ', d, so)
            # dyld_chained_starts_in_segment: +16 是 max_valid_pointer(uint32)，
            # +20 才是 page_count(uint16)，+22 起是 page_start[]
            max_valid, page_count = struct.unpack_from('<IH', d, so + 16)
            pages = [struct.unpack_from('<H', d, so + 22 + k * 2)[0] for k in range(page_count)]
            self.chains[segment_offset] = (page_size, pointer_format, pages, so, page_count)

    def decode_slot(self, vm):
        """返回 ('rebase', target_vm) / ('bind', name, lib_ordinal) / None"""
        d = self.d
        for name, vmaddr, vmsize, fileoff, filesize in self.segs:
            if not (vmaddr <= vm < vmaddr + vmsize):
                continue
            seg_off = vmaddr - self.base       # segment_offset 是相对 image base 的 vm 偏移
            if seg_off not in self.chains:
                return None
            page_size, fmt, pages, so, page_count = self.chains[seg_off]
            rel = vm - vmaddr
            page = rel // page_size
            if page >= page_count:
                return None
            raw = pages[page]
            if raw == 0xFFFF:
                return None
            if raw & 0x8000:                   # DYLD_CHAINED_PTR_START_MULTI
                idx = raw & 0x7FFF
                # 多重起始表：so + 22 + page_count*2 + idx*2
                p = so + 22 + page_count * 2 + idx * 2
                chain_off = struct.unpack_from('<H', d, p)[0]
                while True:
                    cand_vm = vmaddr + page * page_size + chain_off
                    if cand_vm == vm:
                        break
                    v = struct.unpack_from('<Q', d, self.vm_to_off(cand_vm))[0]
                    nxt = self._next_of(v, fmt)
                    if nxt == 0:
                        return None
                    chain_off += nxt * 4
            else:
                chain_off = raw
            slot_vm = vmaddr + page * page_size + chain_off
            while slot_vm <= vm:
                off = self.vm_to_off(slot_vm)
                if off is None:
                    return None
                v = struct.unpack_from('<Q', d, off)[0]
                if slot_vm == vm:
                    return self._decode_value(v, fmt)
                nxt = self._next_of(v, fmt)
                if nxt == 0:
                    return None
                slot_vm += nxt * 4
        return None

    @staticmethod
    def _next_of(v, fmt):
        if fmt in (PTR_64, PTR_64_OFFSET):
            return (v >> 51) & 0x7ff
        if fmt in (PTR_ARM64E, PTR_ARM64E_OFFSET, PTR_ARM64E_USERLAND, PTR_ARM64E_USERLAND24):
            return (v >> 51) & 0x7ff
        return 0

    def _decode_value(self, v, fmt):
        if fmt in (PTR_64, PTR_64_OFFSET):
            is_bind = (v >> 63) & 1
            nxt = (v >> 51) & 0x7ff
            if is_bind:
                ordinal = v & 0xFFFFFF
                nm = self.imports[ordinal][0] if ordinal < len(self.imports) else '?'
                return ('bind', nm, self.imports[ordinal][1] if ordinal < len(self.imports) else -1, nxt)
            target = v & 0xFFFFFFFFF
            if fmt == PTR_64_OFFSET:
                # DYLD_CHAINED_PTR_64_OFFSET：36 位就是「相对 image base 的偏移」，
                # 没有 high8 概念（把 high8 拼进 bit56 会得到 0x10000000047b76 这种鬼地址）
                target += self.base
            else:
                high8 = (v >> 36) & 0xff
                target |= high8 << 56
            return ('rebase', target, None, nxt)
        if fmt in (PTR_ARM64E, PTR_ARM64E_OFFSET, PTR_ARM64E_USERLAND, PTR_ARM64E_USERLAND24):
            is_bind = (v >> 62) & 1
            nxt = (v >> 51) & 0x7ff
            if is_bind:
                if fmt == PTR_ARM64E_USERLAND24:
                    ordinal = v & 0xFFFFFF
                else:
                    ordinal = v & 0xFFFF
                nm = self.imports[ordinal][0] if ordinal < len(self.imports) else '?'
                return ('bind', nm, -1, nxt)
            target = v & 0x7FFFFFFFFFF
            if fmt in (PTR_ARM64E_OFFSET, PTR_ARM64E_USERLAND, PTR_ARM64E_USERLAND24):
                target += self.base
            return ('rebase', target, None, nxt)
        return None

    def ptr(self, vm):
        """把槽位还原成最终地址 / 符号名"""
        r = self.decode_slot(vm)
        if r is None:
            # 可能不是链指针（比如纯数据），直接读
            o = self.vm_to_off(vm)
            if o is None:
                return None
            return ('raw', struct.unpack_from('<Q', self.d, o)[0])
        if r[0] == 'bind':
            return ('bind', r[1])
        return ('rebase', r[1])


if __name__ == '__main__':
    m = MachO(sys.argv[1])
    print('base %#x  fixups=%s  imports=%d' % (m.base, m.fixups_lc, len(m.imports)))
    for i, (nm, lib) in enumerate(m.imports[:20]):
        print('  imp[%d] %-50s lib=%d' % (i, nm, lib))
    print('--- seg starts ---')
    for k, v in m.chains.items():
        print('  seg_off %#x page_size=%d fmt=%d pages=%d' % (k, v[0], v[1], len(v[2])))
