#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""m5_sim.py — 用 Unicorn 跑单个函数，把运行时 XOR 解出来的字符串捞出来

用法：
  python m5_sim.py 0x10003b6b4            # 跑该地址的函数
  python m5_sim.py --sel setupMessagePortServer
  python m5_sim.py --scan                 # 扫描所有含解密桩的函数并全部跑一遍

原理：这个 App 把敏感字符串（端口名、路径、URL）逐字节 XOR 存到 __DATA，
运行时解密到 __DATA 的缓冲区。静态看是密文，跑一遍就有了。
"""
import struct, sys, os, json, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m0_fixups import MachO
from unicorn import *
from unicorn.arm64_const import *

PATH = os.environ.get('TARGET_BIN', 'x/Payload/RealBackstage.app/RealBackstage')
m = MachO(PATH)
d = m.d

STACK_TOP = 0x300000000
STACK_SIZE = 0x100000


def build_uc():
    uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    for name, vmaddr, vmsize, fileoff, filesize in m.segs:
        if vmsize == 0:
            continue
        base = vmaddr & ~0xFFF
        size = ((vmaddr + vmsize + 0xFFF) & ~0xFFF) - base
        try:
            uc.mem_map(base, size, UC_PROT_ALL)
        except UcError:
            continue
        if filesize:
            uc.mem_write(vmaddr, d[fileoff:fileoff + filesize])
    uc.mem_map(STACK_TOP - STACK_SIZE, STACK_SIZE, UC_PROT_ALL)
    uc.reg_write(UC_ARM64_REG_SP, STACK_TOP - 0x100)
    return uc


def snap(uc):
    out = {}
    for name, vmaddr, vmsize, fileoff, filesize in m.segs:
        if name in ('__text', '__LINKEDIT', '__PAGEZERO'):
            continue
        try:
            out[name] = uc.mem_read(vmaddr, vmsize)
        except UcError:
            pass
    return out


def diff_strings(before, after, minlen=4):
    found = []
    for seg, buf in after.items():
        old = before.get(seg, b'\0' * len(buf))
        i = 0
        n = len(buf)
        while i < n:
            if i < len(old) and buf[i] == old[i]:
                i += 1
                continue
            # 变化区起点，向后读到 \0
            j = i
            while j < n and buf[j] != 0:
                j += 1
            chunk = bytes(buf[i:j])
            i = j + 1
            if len(chunk) < minlen:
                continue
            try:
                s = chunk.decode('utf-8')
            except Exception:
                continue
            if all(ch.isprintable() for ch in s):
                found.append((seg, hex(0x0), s))
    return found


def run_func(vm, steps=200000):
    uc = build_uc()
    before = snap(uc)
    stop = {'reason': '', 'pc': 0}
    text_lo = m.sects['__text'][0]
    text_hi = text_lo + m.sects['__text'][1]

    def on_code(uc_, addr, size, user):
        if not (text_lo <= addr < text_hi):
            stop['reason'] = 'left text at %#x' % addr
            uc_.emu_stop()

    def on_unmapped(uc_, access, addr, size, value, user):
        stop['reason'] = 'unmapped %#x' % addr
        stop['pc'] = uc_.reg_read(UC_ARM64_REG_PC)
        return False

    uc.hook_add(UC_HOOK_CODE, on_code)
    uc.hook_add(UC_HOOK_MEM_UNMAPPED, on_unmapped)
    try:
        uc.emu_start(vm, 0, count=steps)
    except UcError as e:
        stop['reason'] = 'uc error: %s' % e
    after = snap(uc)
    return diff_strings(before, after), stop


def find_sel(name):
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'analysis', 'objc2.json')
    if not os.path.exists(p):
        return []
    j = json.load(open(p, encoding='utf-8'))
    hits = []
    for c in j['classes'] + j['categories']:
        for mm in c.get('methods', []) + c.get('instance_methods', []) + c.get('class_methods', []):
            if mm['sel'] == name:
                hits.append((c.get('name') or c.get('class'), mm['sel'], mm['imp']))
    return hits


def scan_candidates():
    """找含解密桩的函数：eor + strb 密集的短函数"""
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    a, size, off = m.sects['__text']
    code = d[off:off + size]
    ins = list(md.disasm(code, a))
    # 按函数分段
    import bisect
    starts = []
    lc = 32
    for _ in range(m.ncmds):
        cmd, csz = struct.unpack_from('<II', d, lc)
        if cmd == 0x26:
            fo, fs = struct.unpack_from('<II', d, lc + 8)
            p, addr = fo, a
            while p < fo + fs:
                v, sh = 0, 0
                while True:
                    b = d[p]; p += 1
                    v |= (b & 0x7F) << sh; sh += 7
                    if not (b & 0x80):
                        break
                if v == 0:
                    break
                addr += v
                starts.append(addr)
        lc += csz
    out = []
    for i, s in enumerate(starts):
        e = starts[i + 1] if i + 1 < len(starts) else a + size
        body = [x for x in ins if s <= x.address < e]
        eor = sum(1 for x in body if x.mnemonic == 'eor')
        strb = sum(1 for x in body if x.mnemonic == 'strb')
        if eor >= 4 and strb >= 4:
            out.append((s, e, eor, strb))
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    if sys.argv[1] == '--sel':
        for cls, sel, imp in find_sel(sys.argv[2]):
            print('=== %s %s @ %#x ===' % (cls, sel, imp))
            found, stop = run_func(imp)
            for _, _, s in found:
                print('   %r' % s)
            print('   [stop] %s' % stop['reason'])
    elif sys.argv[1] == '--scan':
        cands = scan_candidates()
        print('候选函数 %d 个' % len(cands))
        seen = set()
        for s, e, eor, strb in cands:
            found, stop = run_func(s, steps=4000)
            for _, _, txt in found:
                if txt not in seen:
                    seen.add(txt)
                    print('%#x  %r' % (s, txt))
    else:
        vm = int(sys.argv[1], 16)
        found, stop = run_func(vm)
        for _, _, s in found:
            print('%r' % s)
        print('[stop] %s' % stop['reason'])


if __name__ == '__main__':
    main()
