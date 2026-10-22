#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""m4b_disasm.py — chained-fixups 二进制的符号化反汇编

用法：
  python m4b_disasm.py func 0x10000xxxx
  python m4b_disasm.py sel "setupMessagePortServer"
  python m4b_disasm.py strings            # 把所有 CFString / 字符串常量列出来
  python m4b_disasm.py calls 0x10000xxxx  # 只看调用与引用
"""
import struct, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m0_fixups import MachO
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64 import ARM64_OP_REG, ARM64_OP_IMM, ARM64_OP_MEM

PATH = os.environ.get('TARGET_BIN', 'x/Payload/RealBackstage.app/RealBackstage')
m = MachO(PATH)
d = m.d
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True


# ---------- 函数边界（LC_FUNCTION_STARTS，ULEB128 增量） ----------
def load_func_starts():
    lc = 32
    off = size = None
    for _ in range(m.ncmds):
        cmd, cmdsize = struct.unpack_from('<II', d, lc)
        if cmd == 0x26:
            off, size = struct.unpack_from('<II', d, lc + 8)
        lc += cmdsize
    starts = []
    if off is None:
        return starts
    p, addr = off, m.base + m.sects.get('__text', (0x100008000,))[0] - m.base
    addr = m.sects['__text'][0]
    while p < off + size:
        v, shift = 0, 0
        while True:
            b = d[p]; p += 1
            v |= (b & 0x7F) << shift; shift += 7
            if not (b & 0x80):
                break
        if v == 0:
            break
        addr += v
        starts.append(addr)
    return starts


FUNC_STARTS = load_func_starts()


def func_end(vm):
    import bisect
    i = bisect.bisect_right(FUNC_STARTS, vm)
    return FUNC_STARTS[i] if i < len(FUNC_STARTS) else vm + 0x1000


# ---------- 符号化 ----------
SECT_SELREFS = m.sects.get('__objc_selrefs', (0, 0, 0))
SECT_CLASSREFS = m.sects.get('__objc_classrefs', (0, 0, 0))
SECT_CFSTR = m.sects.get('__cfstring', (0, 0, 0))
SECT_GOT = m.sects.get('__got', (0, 0, 0))
SECT_STUBS = m.sects.get('__stubs', (0, 0, 0))
SECT_TEXT = m.sects.get('__text', (0, 0, 0))


def in_sect(vm, s):
    return s[1] and s[0] <= vm < s[0] + s[1]


def sel_of_slot(vm):
    r = m.decode_slot(vm)
    if r and r[0] == 'rebase':
        s = m.cstr(r[1])
        if s and all(32 <= ord(c) < 127 for c in s):
            return s
    o = m.vm_to_off(vm)
    if o:
        raw = struct.unpack_from('<Q', d, o)[0]
        return None
    return None


def classname_of_slot(vm):
    r = m.decode_slot(vm)
    if r and r[0] == 'rebase':
        cls = r[1]
        ro = m.ptr(cls + 32)
        if ro and ro[0] == 'rebase':
            return m.cstr(ro[1] + 24)
        # 外部类（bind）
    if r and r[0] == 'bind':
        nm = r[1]
        return nm.replace('_OBJC_CLASS_$_', '').replace('OBJC_CLASS_$_', '')
    return None


def cfstring_of(vm):
    """__cfstring 里的 CFString -> 内容字符串"""
    o = m.vm_to_off(vm)
    if o is None:
        return None
    # isa, flags, cstr, len
    p = m.ptr(vm + 16)
    if p and p[0] == 'rebase':
        return m.cstr(p[1])
    raw = struct.unpack_from('<Q', d, o + 16)[0]
    return m.cstr(raw) if raw else None


def stub_target(vm):
    """__stubs 里的 stub -> 导入符号名"""
    o = m.vm_to_off(vm)
    if o is None:
        return None
    code = d[o:o + 16]
    for ins in md.disasm(code, vm):
        if ins.mnemonic == 'adrp':
            page = ins.operands[1].imm
        elif ins.mnemonic == 'ldr' and len(ins.operands) >= 2 and ins.operands[1].type == ARM64_OP_MEM:
            mem = ins.operands[1].mem
            addr = page + mem.disp
            r = m.decode_slot(addr)
            if r and r[0] == 'bind':
                return r[1]
            return None
    return None


def symbolize(vm, code, n=0x400):
    lines = []
    page_regs = {}
    for ins in md.disasm(code, vm):
        txt = '%08x  %-8s %s' % (ins.address, ins.mnemonic, ins.op_str)
        note = ''
        ops = ins.operands
        if ins.mnemonic == 'adrp' and len(ops) == 2 and ops[1].type == ARM64_OP_IMM:
            page_regs[ins.reg_name(ops[0].reg)] = ops[1].imm
        elif ins.mnemonic in ('ldr', 'ldrsw', 'ldrb') and len(ops) == 2 and ops[1].type == ARM64_OP_MEM:
            mem = ops[1].mem
            base = ins.reg_name(mem.base) if mem.base else ''
            addr = page_regs.get(base, 0) + mem.disp
            if in_sect(addr, SECT_SELREFS):
                s = sel_of_slot(addr)
                if s:
                    note = '; "%s" (SEL)' % s
            elif in_sect(addr, SECT_CLASSREFS):
                c = classname_of_slot(addr)
                if c:
                    note = '; class(%s)' % c
            elif in_sect(addr, SECT_GOT):
                r = m.decode_slot(addr)
                if r and r[0] == 'bind':
                    note = '; %s' % r[1]
            elif in_sect(addr, SECT_CFSTR):
                pass
        elif ins.mnemonic == 'add' and len(ops) == 3 and ops[2].type == ARM64_OP_IMM:
            base = ins.reg_name(ops[1].reg) if ops[1].type == ARM64_OP_REG else ''
            addr = page_regs.get(base, 0) + ops[2].imm
            if in_sect(addr, SECT_CFSTR):
                s = cfstring_of(addr)
                if s:
                    note = '; CFSTR("%s")' % s
        elif ins.mnemonic in ('bl', 'b') and len(ops) == 1 and ops[0].type == ARM64_OP_IMM:
            tgt = ops[0].imm
            if in_sect(tgt, SECT_STUBS):
                nm = stub_target(tgt)
                if nm:
                    note = '; -> %s' % nm
            elif in_sect(tgt, SECT_TEXT):
                note = '; sub_%x' % tgt
        if note:
            txt = '%-58s %s' % (txt, note)
        lines.append(txt)
        if n and ins.address - vm > n:
            break
    return lines


def find_sel(name):
    a, size, off = m.sects.get('__objc_methlist', (0, 0, 0))
    # 直接在 __objc_methname 里找字符串，然后找引用它的位置较麻烦；
    # 这里从方法元数据反查 imp
    import json
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


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return
    cmd = sys.argv[1]
    if cmd == 'func':
        vm = int(sys.argv[2], 16)
        end = func_end(vm)
        print('; func %#x .. %#x (%d bytes)' % (vm, end, end - vm))
        print('\n'.join(symbolize(vm, d[m.vm_to_off(vm):m.vm_to_off(end)], end - vm)))
    elif cmd == 'sel':
        for cls, sel, imp in find_sel(sys.argv[2]):
            print('; %s %s @ %#x' % (cls, sel, imp))
            end = func_end(imp)
            print('\n'.join(symbolize(imp, d[m.vm_to_off(imp):m.vm_to_off(end)], end - imp)))
            print()
    elif cmd == 'calls':
        vm = int(sys.argv[2], 16)
        end = func_end(vm)
        for line in symbolize(vm, d[m.vm_to_off(vm):m.vm_to_off(end)], end - vm):
            if ';' in line:
                print(line)
    elif cmd == 'strings':
        a, size, off = m.sects['__cfstring']
        for i in range(size // 32):
            vm = a + i * 32
            s = cfstring_of(vm)
            if s:
                print('%#x  %r' % (vm, s))


if __name__ == '__main__':
    main()
